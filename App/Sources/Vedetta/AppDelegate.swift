import AppKit
import VedettaKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private lazy var codexIngress = CodexIngressCoordinator(store: store)
    private var panelController: NotchPanelController?
    private var statusItemController: StatusItemController?
    private var eventServer: EventServer?
    private var refreshTimer: Timer?
    private var codexWatchers: [CodexWatcher] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsDefaults.register()
        UsageModel.shared.applyPreferredProvider(
            UserDefaults.standard.string(forKey: SettingsKey.preferredUsageProvider) ?? "auto"
        )
        NotificationCenter.default.addObserver(
            forName: .vedettaOpenSettings,
            object: nil,
            queue: .main
        ) { note in
            let page = (note.userInfo?["page"] as? String)
                .flatMap(SettingsView.Page.init(rawValue:))
            Task { @MainActor in SettingsWindowController.shared.show(page: page) }
        }
        if ProcessInfo.processInfo.arguments.contains("--mock") {
            MockSessions.seed(into: store)
        } else {
            TerminalPersistence.load(into: store)
            SessionBootstrap.adoptRecentSessions(into: store)
            reloadCodexHomes()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(codexHomesChanged),
                name: .vedettaCodexHomesChanged,
                object: nil
            )
            JumpService.installVSCodeExtension()
            UsageModel.shared.start()
            let store = self.store
            let timer = Timer(timeInterval: 15, repeats: true) { _ in
                Task { @MainActor in
                    SessionBootstrap.refreshScannedSessions(
                        in: store,
                        coordinator: self.codexIngress
                    )
                    SessionBootstrap.sweepDeadTerminals(in: store)
                    TerminalPersistence.save(from: store)
                    store.touch()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
        if ProcessInfo.processInfo.arguments.contains("--install-hooks") {
            do {
                try VedettaSetup.ensureRuntimeLayout()
                let report = VedettaSetup.installAgentHooks()
                NSLog("Vedetta: hook install Claude=\(String(describing: report.claude)) Codex=\(String(describing: report.codex))")
            } catch {
                NSLog("Vedetta: runtime setup failed before hook install: \(error)")
            }
        }

        do {
            try VedettaSetup.ensureRuntimeLayout()
        } catch {
            NSLog("Vedetta: runtime setup failed: \(error)")
        }
        // Heal each source independently: a malformed config for one agent
        // must not disable the other agent or prevent the socket from starting.
        do {
            try VedettaSetup.healClaudeHooks()
        } catch {
            NSLog("Vedetta: Claude hook heal failed: \(error)")
        }
        do {
            try VedettaSetup.healCodexHooks()
        } catch {
            NSLog("Vedetta: Codex hook heal failed: \(error)")
        }
        // A Codex question (request_user_input, TUI-only) mirrors into the
        // notch: chirp + panel expansion, answered in the terminal.
        codexIngress.onUserInputRequest = {
            SoundEngine.shared.play(.question)
            NotificationCenter.default.post(
                name: .vedettaCodexQuestionPending, object: nil
            )
        }

        do {
            EventDispatcher.store = store
            EventDispatcher.codexCoordinator = codexIngress
            let server = EventServer(socketPath: VedettaSetup.socketPath) { data in
                await EventDispatcher.handle(data)
            }
            try server.start()
            eventServer = server
        } catch {
            NSLog("Vedetta: EventServer failed to start: \(error)")
        }

        let panelController = NotchPanelController(store: store)
        self.panelController = panelController
        statusItemController = StatusItemController(panelController: panelController)
        panelController.show()

        if !ProcessInfo.processInfo.arguments.contains("--mock") {
            OnboardingController.shared.showIfNeeded()
            askUpdateConsentIfNeeded()
            UpdateChecker.shared.start()
        }
    }

    /// The update check never runs unsolicited. New users answer in
    /// onboarding; installs that predate the feature get the question
    /// once, here, before the first check happens.
    private func askUpdateConsentIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKey.updateConsentAsked) else { return }
        defer { defaults.set(true, forKey: SettingsKey.updateConsentAsked) }
        // A first-run install answers inside the onboarding wizard.
        guard !OnboardingController.shared.shouldShow else { return }

        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = """
        Meowtch can ask GitHub once a day whether a newer release exists, \
        and install it after verifying its signature.

        No account, no telemetry. You can change this any time in \
        Settings → General.
        """
        alert.addButton(withTitle: "Yes, check daily")
        alert.addButton(withTitle: "No, I'll check myself")
        NSApp.activate(ignoringOtherApps: true)
        let allowed = alert.runModal() == .alertFirstButtonReturn
        defaults.set(allowed, forKey: SettingsKey.updateAutoCheck)
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer?.stop()
        codexWatchers.forEach { $0.stop() }
    }

    @objc private func codexHomesChanged() {
        reloadCodexHomes()
    }

    private func reloadCodexHomes() {
        codexWatchers.forEach { $0.stop() }
        let homes = VedettaSetup.codexHomes
        SessionBootstrap.adoptCodexSessions(
            into: store,
            coordinator: codexIngress,
            homes: homes
        )
        codexWatchers = homes.filter(\.isAvailable).map { codexHome in
            CodexWatcher(
                root: codexHome.path,
                onRollout: { [weak self] path in
                    Task { @MainActor in
                        guard let self else { return }
                        SessionBootstrap.ingestCodexRollout(
                            path: path,
                            coordinator: self.codexIngress
                        )
                        self.store.touch()
                    }
                },
                onIndex: { [weak self] path in
                    Task { @MainActor in
                        guard let self else { return }
                        SessionBootstrap.ingestCodexIndex(
                            path: path,
                            coordinator: self.codexIngress
                        )
                        self.store.touch()
                    }
                }
            )
        }
        codexWatchers.forEach { $0.start() }
    }
}

extension Notification.Name {
    static let vedettaCodexHomesChanged = Notification.Name("VedettaCodexHomesChanged")
}

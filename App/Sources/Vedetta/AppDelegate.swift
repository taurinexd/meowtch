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
        if ProcessInfo.processInfo.arguments.contains("--mock") {
            MockSessions.seed(into: store)
        } else {
            TerminalPersistence.load(into: store)
            // The VI map contributes set parity and titles for the sessions
            // it knows, but it freezes the moment VI quits: the transcript
            // sweep must always fill in what the (possibly stale) map
            // misses. Both skip ids already in the store.
            _ = VIMapImport.adopt(into: store)
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
        }
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

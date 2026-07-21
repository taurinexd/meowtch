import AppKit
import VedettaKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var panelController: NotchPanelController?
    private var statusItemController: StatusItemController?
    private var eventServer: EventServer?
    private var refreshTimer: Timer?
    private var codexWatcher: CodexWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--mock") {
            MockSessions.seed(into: store)
        } else {
            TerminalPersistence.load(into: store)
            if !VIMapImport.adopt(into: store) {
                SessionBootstrap.adoptRecentSessions(into: store)
            }
            SessionBootstrap.adoptCodexSessions(into: store)
            // Keep watching Codex rollouts as a fallback for sessions that
            // started before our hooks were installed. Hook events take
            // ownership as soon as that session emits one.
            let codexWatcher = CodexWatcher(root: NSHomeDirectory() + "/.codex/sessions") { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    SessionBootstrap.ingestCodexRollout(path: path, into: self.store)
                    self.store.touch()
                }
            }
            codexWatcher.start()
            self.codexWatcher = codexWatcher
            JumpService.installVSCodeExtension()
            UsageModel.shared.start()
            let store = self.store
            let timer = Timer(timeInterval: 15, repeats: true) { _ in
                Task { @MainActor in
                    SessionBootstrap.refreshScannedSessions(in: store)
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
    }
}

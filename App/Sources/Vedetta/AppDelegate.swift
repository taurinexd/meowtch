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
            // Codex has no hooks: a file-events watcher on its rollouts keeps
            // the cards live (state, tool, messages) between periodic passes.
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
                let changed = try VedettaSetup.installClaudeHooks()
                NSLog("Vedetta: hooks \(changed ? "installed" : "already present")")
            } catch {
                NSLog("Vedetta: hook install failed: \(error)")
            }
        }

        do {
            try VedettaSetup.ensureRuntimeLayout()
            // Repair hooks that drifted since install (new events shipped in
            // an update won't otherwise reach the bridge). No-op unless we
            // were already installed and something is now missing.
            try VedettaSetup.healClaudeHooks()
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

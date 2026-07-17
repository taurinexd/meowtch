import AppKit
import VedettaKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var panelController: NotchPanelController?
    private var statusItemController: StatusItemController?
    private var eventServer: EventServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--mock") {
            MockSessions.seed(into: store)
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer?.stop()
    }
}

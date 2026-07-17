import AppKit
import VedettaKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var panelController: NotchPanelController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MockSessions.seed(into: store)

        let panelController = NotchPanelController(store: store)
        self.panelController = panelController
        statusItemController = StatusItemController(panelController: panelController)
        panelController.show()
    }
}

import AppKit
import SwiftUI

/// The Settings window: standard macOS sidebar-style preferences (like the
/// original's), opened from the notch's gear icon or the status-bar menu.
/// Shared page selection, so deep links (gear icon, socket, future "↗"
/// links) can land on a specific page.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var page: SettingsView.Page = .general
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(page: SettingsView.Page? = nil) {
        if let page { SettingsRouter.shared.page = page }
        show()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Meowtch Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable,
                                .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 940, height: 700))
            window.minSize = NSSize(width: 760, height: 520)
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        // An LSUIElement app has no Dock presence: activate explicitly so
        // the window comes to the front and takes keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    /// Open the Settings window (posted by the notch's gear icon and the
    /// debug socket command).
    static let vedettaOpenSettings = Notification.Name("vedettaOpenSettings")
}

import AppKit
import VedettaKit

/// The single place that decides whether Meowtch's windows appear in screen
/// captures. `sharingType` is a per-window flag, so one forgotten surface
/// defeats the whole feature: windows register themselves at creation, and
/// every mode change re-sweeps whatever AppKit already owns.
///
/// The mode is deliberately NOT persisted across launches. A mode that hides
/// the app's own interface must never come back silently after a restart.
@MainActor
final class ScreenPrivacy: ObservableObject {
    static let shared = ScreenPrivacy()

    @Published private(set) var mode: CallMode = .code

    private var keyWindowObserver: NSObjectProtocol?

    private init() {
        // Windows AppKit creates on its own — alerts, save panels — never call
        // register(). Catching them as they become key is the safety net.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            // Deliberately captures nothing: touching `self` from a closure
            // built inside init is a needless compile-time hazard, and the
            // closure only ever runs long after `shared` exists.
            let window = note.object as? NSWindow
            Task { @MainActor in
                guard let window else { return }
                ScreenPrivacy.shared.register(window)
            }
        }
    }

    func setMode(_ mode: CallMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        applyToAllWindows()
    }

    /// Call from a window's init. Idempotent.
    func register(_ window: NSWindow) {
        apply(to: window)
    }

    private func applyToAllWindows() {
        for window in NSApp.windows { apply(to: window) }
    }

    private func apply(to window: NSWindow) {
        // .readOnly is AppKit's default: capture allowed, no remote control.
        window.sharingType = mode.hidesFromScreenCapture ? .none : .readOnly
    }
}

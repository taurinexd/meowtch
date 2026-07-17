import AppKit
import SwiftUI
import VedettaKit

/// Owns the notch panel. The panel window is kept at a fixed maximum size,
/// fully transparent, anchored to the top-center of the target screen;
/// all expand/collapse animation happens inside SwiftUI (clicks over the
/// transparent margins fall through to the windows beneath).
@MainActor
final class NotchPanelController {
    private let panel: NotchPanel
    private let store: SessionStore
    private let uiModel = NotchUIModel()
    private var collapseWorkItem: DispatchWorkItem?

    /// Window is sized to fit the expanded panel plus its shadow.
    private static let windowSize = NSSize(width: 680, height: 620)

    init(store: SessionStore) {
        self.store = store
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize))
        // Shadow is drawn in SwiftUI: an AppKit window shadow would lag
        // behind the animated shape and leave artifacts.
        panel.hasShadow = false

        let rootView = NotchView(
            store: store,
            model: uiModel,
            geometry: Self.notchGeometry(for: Self.targetScreen()),
            onHoverChange: { [weak self] hovering in
                self?.hoverChanged(hovering)
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        // Never let SwiftUI resize the window: the panel must stay a fixed,
        // notch-centered rect and animate only its drawn content.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        positionWindow()

        // Screen/session transitions (display changes, unlocks) can knock the
        // panel off screen: reposition and re-order it whenever they happen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.userHidden else { return }
                self.show()
            }
        }
    }

    /// True while the user has explicitly hidden the panel from the menu.
    private var userHidden = false

    func show() {
        positionWindow()
        panel.orderFrontRegardless()
        // Dev aid: `Vedetta --expanded` starts with the panel open, so the
        // expanded layout can be exercised and screenshotted without hovering.
        if ProcessInfo.processInfo.arguments.contains("--expanded") {
            setExpanded(true)
        }
    }

    func toggleVisibility() {
        if panel.isVisible {
            userHidden = true
            panel.orderOut(nil)
        } else {
            userHidden = false
            show()
        }
    }

    // MARK: - Screen & geometry

    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private static func notchGeometry(for screen: NSScreen?) -> NotchGeometry {
        guard let screen else {
            return NotchGeometry(hasNotch: false, notchWidth: 180, barHeight: 32)
        }
        let hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch {
            let notchWidth: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchWidth = screen.frame.width - left.width - right.width
            } else {
                notchWidth = 180
            }
            return NotchGeometry(
                hasNotch: true,
                notchWidth: notchWidth,
                barHeight: screen.safeAreaInsets.top
            )
        }
        // Screens without a notch get a floating bar; the "notch width" is
        // just the gap kept clear between the two content clusters.
        return NotchGeometry(hasNotch: false, notchWidth: 120, barHeight: 32)
    }

    private func positionWindow() {
        guard let screen = Self.targetScreen() else { return }
        let size = Self.windowSize
        let geometry = Self.notchGeometry(for: screen)
        // Flush with the top edge on notched screens; just below the menu
        // bar on plain ones.
        let topOffset: CGFloat = geometry.hasNotch
            ? 0
            : (screen.frame.maxY - screen.visibleFrame.maxY) + 6
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topOffset - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Hover

    private func hoverChanged(_ hovering: Bool) {
        collapseWorkItem?.cancel()
        if hovering {
            setExpanded(true)
        } else {
            // Small delay so the panel doesn't flicker when the pointer
            // grazes the edge.
            let workItem = DispatchWorkItem { [weak self] in
                self?.setExpanded(false)
            }
            collapseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard uiModel.isExpanded != expanded else { return }
        uiModel.isExpanded = expanded
    }
}

/// Observable UI state shared between the controller and the SwiftUI views.
@MainActor
final class NotchUIModel: ObservableObject {
    @Published var isExpanded = false
}

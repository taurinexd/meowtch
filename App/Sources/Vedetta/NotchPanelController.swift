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

    /// Window spans the full screen height so a long expanded panel can
    /// scroll instead of clipping; transparent areas stay click-through.
    private static var windowSize: NSSize {
        let height = targetScreen()?.frame.height ?? 900
        return NSSize(width: 680, height: height)
    }

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

        // Approvals take over the notch: expand on arrival with a chirp,
        // settle back once the queue drains.
        ApprovalCenter.shared.onArrival = { [weak self] in
            SoundEngine.shared.play(.approvalRequest)
            self?.panel.orderFrontRegardless()
            self?.setExpanded(true)
        }
        ApprovalCenter.shared.onDrain = { [weak self] in
            guard let self, !self.pinnedExpanded else { return }
            self.setExpanded(false)
        }

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

        // A card jump raises the target window: collapse right away so the
        // panel gets out of the way, like the original.
        NotificationCenter.default.addObserver(
            forName: .vedettaDidJump,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.pinnedExpanded else { return }
                self.setExpanded(false)
            }
        }

        // A turn just finished: when the user is looking at another app,
        // the notch auto-opens on a peek of that session for a few
        // seconds, like the original.
        NotificationCenter.default.addObserver(
            forName: .vedettaSessionFinished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let sessionId = note.userInfo?["sessionId"] as? String
            Task { @MainActor in
                guard let self, let sessionId else { return }
                self.maybePeek(sessionId: sessionId)
            }
        }
    }

    // MARK: - Finished-session peek

    private var peekCloseWorkItem: DispatchWorkItem?
    private var peekKeyMonitor: Any?
    /// How long the peek stays open without interaction (tuned live
    /// against the original: 6s read as one second too long).
    private let peekDuration: TimeInterval = 5
    /// A session won't re-peek within this window: during live work every
    /// turn end fires a Stop, and popping the notch open at each one reads
    /// as the panel expanding on its own (the original peeks occasionally,
    /// not at every turn).
    private let peekThrottle: TimeInterval = 120
    private var lastPeekAt: [String: Date] = [:]

    private func maybePeek(sessionId: String) {
        guard !pinnedExpanded, !uiModel.isExpanded, !isHovering else { return }
        if let last = lastPeekAt[sessionId],
           Date().timeIntervalSince(last) < peekThrottle { return }
        // Only when the user is elsewhere: a Stop in the frontmost
        // terminal needs no notification.
        let terminal = store.terminal(for: sessionId)
        if let bundleId = terminal?.bundleIdentifier,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
            return
        }
        lastPeekAt[sessionId] = Date()
        uiModel.peekSessionId = sessionId
        panel.orderFrontRegardless()
        setExpanded(true)

        peekCloseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering else { return }
            self.setExpanded(false)
        }
        peekCloseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + peekDuration, execute: work)

        // ^G jumps to the peeked session from anywhere (the chip hints it).
        if peekKeyMonitor == nil {
            peekKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.contains(.control),
                      event.charactersIgnoringModifiers?.lowercased() == "g" else { return }
                Task { @MainActor in
                    guard let self, let id = self.uiModel.peekSessionId,
                          let session = self.store.sessions.first(where: { $0.id == id }) else { return }
                    JumpService.jump(to: session, terminal: self.store.terminal(for: id))
                    self.setExpanded(false)
                }
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

    /// Preference: keep the panel on an external display (floating bar)
    /// instead of the notch screen — handy when comparing with another
    /// notch app, or when the external is the main working display.
    static var preferExternalDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: "panelDisplayExternal") }
        set { UserDefaults.standard.set(newValue, forKey: "panelDisplayExternal") }
    }

    private static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if preferExternalDisplay,
           let external = screens.first(where: { $0.safeAreaInsets.top == 0 }) {
            return external
        }
        return screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Re-evaluates the target screen and geometry (display toggle).
    func relocate() {
        let rootView = NotchView(
            store: store,
            model: uiModel,
            geometry: Self.notchGeometry(for: Self.targetScreen()),
            onHoverChange: { [weak self] hovering in
                self?.hoverChanged(hovering)
            }
        )
        (panel.contentView as? NSHostingView<NotchView>)?.rootView = rootView
        positionWindow()
        panel.orderFrontRegardless()
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
        // Flush with the top edge everywhere: the floating bar hugs the
        // top of plain displays exactly like the notch extension does.
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Hover

    /// Dev aid: with `--expanded` the panel stays pinned open regardless
    /// of hover, so screenshots are deterministic.
    private let pinnedExpanded = ProcessInfo.processInfo.arguments.contains("--expanded")

    private var isHovering = false
    private var cooldownWorkItem: DispatchWorkItem?
    private var primeWorkItem: DispatchWorkItem?
    /// After a collapse, a brief window during which returning the cursor
    /// does not immediately re-expand — so a quick flick back into the
    /// area the panel just vacated doesn't reopen it, like the original.
    private var cooldownUntil: Date?
    /// Must outlast the post-collapse content unmount (0.65s) so the
    /// oversized settling hover region can never re-open the panel.
    private let cooldown: TimeInterval = 0.7
    private var unmountWorkItem: DispatchWorkItem?
    /// Hover-to-open delay, during which the bar swells slightly (prime).
    /// ~3 frames on the original's recording before the expansion starts.
    private let primeDelay: TimeInterval = 0.10

    /// Debug trace of hover transitions: every event with the real cursor
    /// position, panel frame and state — evidence for hover-region bugs.
    /// Opt-in: launch with VEDETTA_HOVER_LOG=1 in the environment.
    private func logHover(_ hovering: Bool) {
        guard ProcessInfo.processInfo.environment["VEDETTA_HOVER_LOG"] != nil else { return }
        let mouse = NSEvent.mouseLocation
        let line = String(
            format: "%@ hover=%d mouse=(%.0f,%.0f) panel=(%.0f,%.0f %.0fx%.0f) expanded=%d peek=%@\n",
            ISO8601DateFormatter().string(from: Date()),
            hovering ? 1 : 0,
            mouse.x, mouse.y,
            panel.frame.origin.x, panel.frame.origin.y,
            panel.frame.width, panel.frame.height,
            uiModel.isExpanded ? 1 : 0,
            uiModel.peekSessionId ?? "-"
        )
        let path = NSHomeDirectory() + "/.vedetta/run/hover.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        logHover(hovering)
        if pinnedExpanded { return }
        isHovering = hovering
        collapseWorkItem?.cancel()
        cooldownWorkItem?.cancel()

        if hovering {
            guard !uiModel.isExpanded else { return }
            // Trust the real cursor, not the tracking event: while the
            // expanded content is mounted (transition settling) the hover
            // region is larger than the visible bar, and spurious enters
            // from that area must never open the panel.
            guard cursorOverCollapsedBar() else { return }
            if let until = cooldownUntil, Date() < until {
                // In cooldown: don't reopen now. Re-check when it ends and
                // expand only if the cursor is REALLY on the bar. isHovering
                // can be stale here: while the collapse animation retreats
                // from under a stationary cursor SwiftUI emits no hover-exit,
                // so trusting it would reopen the panel on a quick flick.
                let remaining = until.timeIntervalSinceNow
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isHovering, self.cursorOverCollapsedBar() else { return }
                    self.setExpanded(true)
                }
                cooldownWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            } else {
                // Prime first (slight swell), then open — like the original.
                uiModel.isPrimed = true
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isHovering else { return }
                    self.setExpanded(true)
                }
                primeWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + primeDelay, execute: work)
            }
        } else {
            primeWorkItem?.cancel()
            uiModel.isPrimed = false
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
        uiModel.isPrimed = false
        if !expanded {
            uiModel.peekSessionId = nil
            peekCloseWorkItem?.cancel()
            if let monitor = peekKeyMonitor {
                NSEvent.removeMonitor(monitor)
                peekKeyMonitor = nil
            }
        }
        unmountWorkItem?.cancel()
        guard uiModel.isExpanded != expanded else { return }
        if expanded {
            uiModel.collapseSettling = false
            uiModel.isExpanded = true
        } else {
            // Keep the expanded content mounted while the shape shrinks
            // over it (the original's swallow effect), then unmount so the
            // hover tracking region goes back to just the bar.
            uiModel.collapseSettling = true
            uiModel.isExpanded = false
            cooldownUntil = Date().addingTimeInterval(cooldown)
            let work = DispatchWorkItem { [weak self] in
                self?.uiModel.collapseSettling = false
            }
            unmountWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
        }
    }

    /// True when the mouse is inside the collapsed bar's rect right now —
    /// queried directly (NSEvent) because hover state can go stale while
    /// the collapse animation moves the shape away from a still cursor.
    private func cursorOverCollapsedBar() -> Bool {
        guard let screen = Self.targetScreen() else { return false }
        let geometry = Self.notchGeometry(for: screen)
        // Wings + flares as drawn by NotchView, with a small margin.
        let barWidth = geometry.notchWidth + 40 + 23 + 8 + 24
        let barHeight = geometry.barHeight + 8
        let rect = NSRect(
            x: screen.frame.midX - barWidth / 2,
            y: screen.frame.maxY - barHeight,
            width: barWidth,
            height: barHeight
        )
        return rect.contains(NSEvent.mouseLocation)
    }
}

extension Notification.Name {
    /// Posted by a session card when the user jumps to its terminal.
    static let vedettaDidJump = Notification.Name("vedettaDidJump")
    /// Posted when a session's turn ends (Stop), for the finished peek.
    static let vedettaSessionFinished = Notification.Name("vedettaSessionFinished")
}

/// Observable UI state shared between the controller and the SwiftUI views.
@MainActor
final class NotchUIModel: ObservableObject {
    @Published var isExpanded = false
    /// Cursor is on the collapsed bar but the panel hasn't opened yet:
    /// the bar swells slightly as touch-style feedback.
    @Published var isPrimed = false
    /// When set, the expanded panel shows the "finished" peek for this
    /// session (auto-opened on Stop while the user is elsewhere) instead
    /// of the session list, like the original.
    @Published var peekSessionId: String?
    /// True while the collapse animation swallows the expanded content:
    /// it stays mounted through it, then unmounts so the hover tracking
    /// region shrinks back to the bar alone.
    @Published var collapseSettling = false
}

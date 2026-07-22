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
            },
            onShapeFrameChange: { [weak self] frame in
                self?.shapeFrameChanged(frame)
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
            self?.focusInterrupt()
        }
        ApprovalCenter.shared.onDrain = { [weak self] in
            self?.collapseIfNoInterrupt()
        }
        // Questions are interactive interrupts too — same take-over: expand
        // focused on the single interrupting card (the chirp is played by the
        // dispatcher), collapse once nothing is left to answer.
        QuestionStore.shared.onArrival = { [weak self] in
            self?.focusInterrupt()
        }
        QuestionStore.shared.onResolve = { [weak self] in
            self?.collapseIfNoInterrupt()
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

        // A Codex question pends in the TUI: surface it like an interrupt
        // (expand with the orange card on top; the answer stays remote).
        NotificationCenter.default.addObserver(
            forName: .vedettaCodexQuestionPending,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.pinnedExpanded else { return }
                self.panel.orderFrontRegardless()
                self.setExpanded(true)
            }
        }

        // The Settings window's display toggle relocates the panel.
        NotificationCenter.default.addObserver(
            forName: .vedettaPanelDisplayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relocate() }
        }

        // Dev aid: the socket's setExpanded command drives the open/close
        // animation without a cursor (used to measure animation smoothness).
        NotificationCenter.default.addObserver(
            forName: .vedettaDebugSetExpanded,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let expanded = note.userInfo?["expanded"] as? Bool ?? false
            Task { @MainActor in
                self?.panel.orderFrontRegardless()
                self?.setExpanded(expanded)
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
    private var peekDuration: TimeInterval {
        max(2, UserDefaults.standard.double(forKey: SettingsKey.expandDwellSeconds))
    }
    /// A session won't re-peek within this window: during live work every
    /// turn end fires a Stop, and popping the notch open at each one reads
    /// as the panel expanding on its own (the original peeks occasionally,
    /// not at every turn).
    private let peekThrottle: TimeInterval = 120
    private var lastPeekAt: [String: Date] = [:]

    private func maybePeek(sessionId: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.expandPanelForCompletions)
        else { return }
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
            },
            onShapeFrameChange: { [weak self] frame in
                self?.shapeFrameChanged(frame)
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
    private var primeWorkItem: DispatchWorkItem?
    private var unmountWorkItem: DispatchWorkItem?
    /// Hover-to-open delay, during which the bar swells slightly (prime).
    /// ~3 frames on the original's recording by default; user-tunable.
    private var primeDelay: TimeInterval {
        UserDefaults.standard.double(forKey: SettingsKey.hoverExpandDelay)
    }

    /// The shape's target frame in window coordinates. Layout callbacks
    /// report only the endpoints of a transition (SwiftUI animates at the
    /// render layer), so the controller reconstructs the in-flight geometry
    /// itself: same curve as the view (NotchAnimation), interpolated from
    /// the previous frame. Hover decisions test against THAT — the real
    /// shrinking shape — so the area the panel already vacated can never
    /// reopen it. No cooldown needed.
    private var shapeFrameInWindow: CGRect = .zero
    private var shapeTransitionFrom: CGRect = .zero
    private var shapeTransitionAt: Date = .distantPast
    private var shapeExpanding = false
    private var animLogStart: Date?

    private func shapeFrameChanged(_ frame: CGRect) {
        guard frame != shapeFrameInWindow else { return }
        if shapeFrameInWindow == .zero {
            // First report: no transition to animate from.
            shapeTransitionFrom = frame
        } else if Date().timeIntervalSince(shapeTransitionAt) > 0.08 {
            shapeTransitionFrom = shapeFrameInWindow
            shapeTransitionAt = Date()
        }
        // else: a second layout pass a few ms into the same transition —
        // keep the original starting geometry and clock.
        shapeExpanding = frame.height > shapeTransitionFrom.height
        shapeFrameInWindow = frame
        logAnimationFrame(frame)
    }

    /// The shape's frame as rendered right now: the transition endpoints
    /// interpolated along the shared animation curve.
    private func currentShapeRect() -> CGRect {
        let elapsed = Date().timeIntervalSince(shapeTransitionAt)
        let progress = NotchAnimation.progress(
            elapsed: elapsed,
            expanding: shapeExpanding
        )
        guard progress < 1 else { return shapeFrameInWindow }
        let from = shapeTransitionFrom
        let to = shapeFrameInWindow
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            a + (b - a) * CGFloat(progress)
        }
        return CGRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        )
    }

    /// Opt-in animation telemetry (VEDETTA_ANIM_LOG=1): one line per layout
    /// tick with elapsed time and frame — evidence for animation-smoothness
    /// bugs, analyzed offline.
    private func logAnimationFrame(_ frame: CGRect) {
        guard ProcessInfo.processInfo.environment["VEDETTA_ANIM_LOG"] != nil else { return }
        let now = Date()
        if let start = animLogStart, now.timeIntervalSince(start) > 3 {
            animLogStart = now
        } else if animLogStart == nil {
            animLogStart = now
        }
        let elapsed = now.timeIntervalSince(animLogStart ?? now)
        let line = String(
            format: "%.4f %.2f %.2f %.2f %.2f\n",
            elapsed, frame.minX, frame.minY, frame.width, frame.height
        )
        let path = NSHomeDirectory() + "/.vedetta/run/anim.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

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
        // A real tracking event means SwiftUI's hover state is live again:
        // the post-collapse resync watchdog is no longer needed.
        stopHoverResync()
        isHovering = hovering
        collapseWorkItem?.cancel()

        if hovering {
            guard !uiModel.isExpanded else { return }
            guard UserDefaults.standard.bool(forKey: SettingsKey.hoverToExpandEnabled) else {
                return
            }
            // Trust the real cursor against the REAL shape, not the tracking
            // event: while the expanded content is mounted (collapse
            // settling) the hover region is larger than the visible shape,
            // and an enter from the area the panel already vacated must
            // never reopen it. The shape frame is interpolated per query,
            // so mid-collapse the still-covered area legitimately reopens.
            if cursorOverShape() {
                primeAndExpand()
            } else {
                // Entered the oversized settling region on the way to the
                // bar: SwiftUI fires no further enter events while inside,
                // so follow the cursor against the live shape until it
                // lands on it (open) or leaves the region (stop).
                startHoverPoll()
            }
        } else {
            stopHoverPoll()
            primeWorkItem?.cancel()
            uiModel.isPrimed = false
            guard UserDefaults.standard.bool(forKey: SettingsKey.autoCollapseOnMouseLeave)
            else { return }
            // Small delay so the panel doesn't flicker when the pointer
            // grazes the edge.
            let workItem = DispatchWorkItem { [weak self] in
                self?.setExpanded(false)
            }
            collapseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    /// Slight swell first, then open — like the original. Re-checked at
    /// fire time: the shape may have shrunk away from the cursor during the
    /// prime delay, in which case the poll takes over instead of opening.
    private func primeAndExpand() {
        uiModel.isPrimed = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isHovering, self.cursorOverShape() else {
                self.uiModel.isPrimed = false
                if self.isHovering { self.startHoverPoll() }
                return
            }
            self.setExpanded(true)
        }
        primeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + primeDelay, execute: work)
    }

    /// Lightweight cursor-vs-shape tracker for the window in which hover
    /// events can't help: inside the tracking region but not yet on the
    /// shape. Self-terminates on exit, expansion, or when it opens.
    private var hoverPollTimer: Timer?

    private func startHoverPoll() {
        guard hoverPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isHovering, !self.uiModel.isExpanded else {
                    self.stopHoverPoll()
                    return
                }
                if self.cursorOverShape() {
                    self.stopHoverPoll()
                    self.primeAndExpand()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
    }

    private func stopHoverPoll() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    /// An interactive interrupt takes over the notch: bring it forward and
    /// expand, focused on the single interrupting card (the expanded view
    /// shows only the .needsApproval session). "Show all" is cleared so a
    /// fresh interrupt always re-focuses, like the original's focusedSession.
    private func focusInterrupt() {
        panel.orderFrontRegardless()
        uiModel.showAllSessions = false
        setExpanded(true)
    }

    /// Collapse only once every interactive interrupt is gone — an approval
    /// draining must not close a panel that still has a question to answer,
    /// and vice versa.
    private func collapseIfNoInterrupt() {
        // Never yank the panel out from under the cursor: if the user is
        // hovering, the normal hover-exit collapse takes over when they leave.
        guard !pinnedExpanded,
              !isHovering,
              ApprovalCenter.shared.pending.isEmpty,
              QuestionStore.shared.live.isEmpty else { return }
        setExpanded(false)
    }

    private func setExpanded(_ expanded: Bool) {
        uiModel.isPrimed = false
        if !expanded {
            uiModel.peekSessionId = nil
            uiModel.showAllSessions = false
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
            let work = DispatchWorkItem { [weak self] in
                self?.uiModel.collapseSettling = false
            }
            unmountWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
            // A programmatic collapse (jump, peek close, interrupt drain)
            // can leave SwiftUI's tracking convinced the cursor is still
            // inside: the next enter never fires and the bar stops opening
            // until the cursor leaves and returns. Follow the cursor
            // directly until a real hover event resyncs the state.
            startHoverResync()
        }
    }

    /// Post-collapse watchdog: opens the bar when the cursor reaches the
    /// shape while hover events are desynced. Stops on the first real hover
    /// event, on expansion, or after its deadline.
    private var resyncPollTimer: Timer?
    private var resyncDeadline = Date.distantPast

    private func startHoverResync() {
        resyncDeadline = Date().addingTimeInterval(60)
        guard resyncPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Date() > self.resyncDeadline || self.uiModel.isExpanded {
                    self.stopHoverResync()
                    return
                }
                if self.cursorOverShape(),
                   UserDefaults.standard.bool(forKey: SettingsKey.hoverToExpandEnabled) {
                    // The cursor IS here, whatever the tracking believes.
                    self.isHovering = true
                    self.stopHoverResync()
                    self.primeAndExpand()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resyncPollTimer = timer
    }

    private func stopHoverResync() {
        resyncPollTimer?.invalidate()
        resyncPollTimer = nil
    }

    /// True when the mouse is inside the shape as rendered RIGHT NOW —
    /// queried directly (NSEvent) because hover state can go stale while
    /// the collapse animation moves the shape away from a still cursor.
    /// Mid-animation the frame is the interpolated one, so this follows
    /// the shrinking shape instead of any fixed rect.
    private func cursorOverShape() -> Bool {
        guard shapeFrameInWindow != .zero else { return cursorOverCollapsedBar() }
        let shape = currentShapeRect()
        let window = panel.frame
        // SwiftUI window coords are top-left origin; screen coords bottom-left.
        var rect = NSRect(
            x: window.minX + shape.minX,
            y: window.maxY - shape.maxY,
            width: shape.width,
            height: shape.height
        )
        // Reach a few points PAST the screen top: NSRect.contains excludes its
        // max edge, so without this a cursor glued to the very top edge
        // (mouseLocation.y == maxY) reads as outside the shape and never opens it.
        rect.size.height += 6
        return rect.contains(NSEvent.mouseLocation)
    }

    /// Static fallback for the instant before the first layout tick reports
    /// the real shape frame.
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
            height: barHeight + 6
        )
        return rect.contains(NSEvent.mouseLocation)
    }
}

extension Notification.Name {
    /// A Codex request_user_input question appeared in a rollout.
    static let vedettaCodexQuestionPending = Notification.Name("vedettaCodexQuestionPending")
    /// Posted when the Settings display toggle changes the target screen.
    static let vedettaPanelDisplayChanged = Notification.Name("vedettaPanelDisplayChanged")
    /// Debug: drive the expand/collapse animation from the socket.
    static let vedettaDebugSetExpanded = Notification.Name("vedettaDebugSetExpanded")
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
    /// Set when the user taps "Show all" during an interrupt, to reveal the
    /// whole list instead of the single focused card; reset on collapse.
    @Published var showAllSessions = false
    /// True while the collapse animation swallows the expanded content:
    /// it stays mounted through it, then unmounts so the hover tracking
    /// region shrinks back to the bar alone.
    @Published var collapseSettling = false
}

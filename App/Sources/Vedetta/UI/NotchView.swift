import AppKit
import SwiftUI
import VedettaKit

/// Geometry of the physical notch on the target screen, provided by the
/// controller so the collapsed bar can flank the camera housing.
struct NotchGeometry {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var barHeight: CGFloat
}

/// Root view of the panel. The window is always at its maximum size and
/// fully transparent; this view draws (and animates) the black notch
/// extension itself, so expand/collapse is a single fluid SwiftUI animation.
struct NotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchUIModel
    @ObservedObject private var usage = UsageModel.shared
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var questions = QuestionStore.shared
    @AppStorage(SessionMetadataPresentation.defaultsKey)
    private var showSessionMetadata = false
    var geometry: NotchGeometry
    var onHoverChange: (Bool) -> Void
    /// Reports the shape's rendered frame (window coords) on every layout
    /// tick, animation frames included: the controller hit-tests the cursor
    /// against the REAL shrinking shape, not a static rect.
    var onShapeFrameChange: (CGRect) -> Void = { _ in }

    /// Wing sizes measured pixel-exact against the original: the flat part
    /// of the bar extends 40pt left and 23pt right of the physical notch
    /// (asymmetric: the sprite needs more room than the counter), plus the
    /// concave top flare on each side. The flare deepens when expanded
    /// (both measured on the original at identical capture scale).
    private let leftWing: CGFloat = 40
    private let rightWing: CGFloat = 23
    private let collapsedFlare: CGFloat = 4
    private let expandedFlare: CGFloat = 14

    private var topFlare: CGFloat { model.isExpanded ? expandedFlare : collapsedFlare }
    /// 1 while the cursor primes the collapsed bar (slight swell), 0 otherwise.
    private var primeBoost: CGFloat { model.isPrimed && !model.isExpanded ? 1 : 0 }

    private var collapsedWidth: CGFloat {
        geometry.notchWidth + leftWing + rightWing + collapsedFlare * 2
    }
    private var collapsedHeight: CGFloat { geometry.barHeight + 1 }
    /// Keeps the notch centered while the bar extends asymmetrically.
    private var collapsedOffset: CGFloat { (rightWing - leftWing) / 2 }
    /// Flat width 602pt (measured on the original) + the top flare insets.
    private var expandedWidth: CGFloat { 602 + expandedFlare * 2 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(
                    topRadius: topFlare,
                    bottomRadius: model.isExpanded ? 26 : 14
                )
                .fill(.black)

                // The expanded content stays mounted through the collapse:
                // the original does not fade it — it stays put and the
                // shrinking panel clips it away (measured frame-by-frame on
                // a recording), with only a late fade near the end. Once
                // settled it UNMOUNTS: its overflowing geometry would keep
                // the hover tracking region panel-sized when collapsed.
                if model.isExpanded || model.collapseSettling {
                    expandedContent
                        .opacity(model.isExpanded ? 1 : 0)
                        .allowsHitTesting(model.isExpanded)
                        .animation(
                            model.isExpanded
                                ? .easeOut(duration: 0.10)
                                : .easeIn(duration: 0.15).delay(0.30),
                            value: model.isExpanded
                        )
                }
                collapsedContent
                    .opacity(model.isExpanded ? 0 : 1)
                    .allowsHitTesting(!model.isExpanded)
                    .animation(
                        model.isExpanded
                            ? .easeOut(duration: 0.10)
                            : .easeOut(duration: 0.15).delay(0.35),
                        value: model.isExpanded
                    )
            }
            .frame(width: model.isExpanded ? expandedWidth : collapsedWidth)
            // The prime swell is height-only: on the recording the bar grows
            // ~2.5pt taller on hover, width unchanged. Top-anchored so the
            // clipped content stays put while the frame shrinks.
            .frame(
                height: model.isExpanded ? nil : collapsedHeight + primeBoost * 2.5,
                alignment: .top
            )
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                onShapeFrameChange(frame)
            }
            // The animated shape swallows/reveals the content while it
            // resizes — this is what makes the collapse "compact".
            .clipShape(NotchShape(
                topRadius: topFlare,
                bottomRadius: model.isExpanded ? 26 : 14
            ))
            .offset(x: model.isExpanded ? 0 : collapsedOffset)
            // The collapsed bar reads as part of the bezel: no shadow at all.
            .shadow(
                color: model.isExpanded ? .black.opacity(0.35) : .clear,
                radius: model.isExpanded ? 24 : 0,
                y: model.isExpanded ? 6 : 0
            )
            .contentShape(NotchShape(topRadius: topFlare))
            .onHover(perform: onHoverChange)
            // Both curves measured on the recording: expand ~0.35s with a
            // barely-there overshoot; collapse slower (~0.6s), monotonic,
            // with a long soft settle. Defined in NotchAnimation, shared
            // with the controller's hover hit-test interpolation.
            .animation(
                model.isExpanded ? NotchAnimation.expand : NotchAnimation.collapse,
                value: model.isExpanded
            )
            .animation(.easeOut(duration: 0.12), value: model.isPrimed)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Collapsed

    /// Content flanks the physical notch: nothing may sit under the camera.
    private var collapsedContent: some View {
        HStack(spacing: 6) {
            PixelSprite(pattern: PixelSprite.lookout, color: statusColor, pixelSize: 2)
                .padding(.leading, collapsedFlare + 8)
            if let topState = collapsedTopState {
                StateIndicator(state: topState, scale: 0.75)
            }
            Spacer()
            if !visibleSessions.isEmpty {
                Text("\(visibleSessions.count)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.trailing, collapsedFlare + 9)
            }
        }
        .frame(width: collapsedWidth, height: collapsedHeight)
    }

    /// Sessions with a visible terminal window render as full rows;
    /// the rest (minimized, or adopted with no live terminal) collapse
    /// to compact lines at the bottom, like the original.
    @ObservedObject private var archive = ArchiveStore.shared

    private var visibleSessions: [AgentSession] {
        store.sessions.filter { !archive.isArchived($0.id) }
    }

    /// Full row = window known AND attention-worthy: working, awaiting a
    /// decision, or just-stopped (a short grace so the result is readable);
    /// idle sessions collapse. Activity is the real last-message time.
    private static let fullRowGrace: TimeInterval = 10 * 60

    private func deservesFullRow(_ session: AgentSession) -> Bool {
        guard !session.isMinimized else { return false }
        // Claude cards need a live terminal. Codex rollout fallbacks may not
        // have one, so an active Codex session still earns a full card; hook-
        // driven Codex sessions carry the same jump identity as Claude.
        if session.agent == .claude, store.terminal(for: session.id) == nil { return false }
        if session.state == .running || session.state == .needsApproval
            || session.state == .compacting { return true }
        return session.lastActivityAt.timeIntervalSinceNow > -Self.fullRowGrace
    }

    private var fullSessions: [AgentSession] {
        visibleSessions.filter { deservesFullRow($0) }
    }

    private var compactSessions: [AgentSession] {
        visibleSessions.filter { !deservesFullRow($0) }
    }

    /// Sprite/indicator state for the collapsed bar: the highest-priority
    /// state across visible sessions (approval > working > waiting).
    private var collapsedTopState: SessionState? {
        visibleSessions.map(\.state).min()
    }

    /// Color of the sprite: the most urgent state across sessions.
    private var statusColor: Color {
        guard let topState = collapsedTopState else {
            return Theme.secondaryText
        }
        return Theme.color(for: topState)
    }

    // MARK: - Expanded

    @State private var listContentHeight: CGFloat = 0

    /// Max height for the session list before it scrolls: the screen
    /// minus the top bar and a bottom margin.
    private var listHeightCap: CGFloat {
        (NSScreen.main?.frame.height ?? 900) - geometry.barHeight - 140
    }

    /// The single card the panel focuses on: an interactive interrupt
    /// takes over, like the original's focusedSession; otherwise the
    /// finished-session peek, if one is open. "Show all" overrides both to
    /// reveal the whole list. The takeover requires an interrupt the user
    /// can act on here: a bare `.needsApproval` (the decision is pending in
    /// the terminal, not in the notch) must not hijack the whole panel.
    private var focusedSession: AgentSession? {
        if model.showAllSessions { return nil }
        if let interrupt = visibleSessions.first(where: { session in
            session.state == .needsApproval
                && (approvals.firstPending(for: session.id) != nil
                    || questions.first(for: session.id) != nil)
        }) {
            return interrupt
        }
        if let peekId = model.peekSessionId {
            return store.sessions.first { $0.id == peekId }
        }
        return nil
    }

    private var expandedContent: some View {
        // All paddings below are measured from the panel's flat edges, so
        // the flare inset is applied first (values pixel-measured on the
        // original: text column x=64, sprite x=18, sections every 26pt).
        VStack(alignment: .leading, spacing: 20) {
            topBar
            if let session = focusedSession {
                peekContent(session)
            } else {
                sessionList
            }
        }
        // +4: the reference crop sits 4pt inside the real flat edges.
        .padding(.horizontal, expandedFlare + 4)
        .padding(.bottom, 18)
        .frame(width: expandedWidth, alignment: .top)
    }

    // MARK: - Finished-session peek

    /// Auto-opened view for a just-finished session: its card (with the
    /// ^G jump hint), an inset panel with the last prompt, "Done" and the
    /// full reply in monospace, then a link back to the whole list —
    /// anatomy and colors measured on the original.
    private func peekContent(_ session: AgentSession) -> some View {
        // An interrupt (approval/question) shows ONLY its card — its Allow/Deny
        // or question bar lives inside SessionRowView; a finished session also
        // gets the prompt/reply inset. Section gaps measured on the recording:
        // 13.5pt card→inset→link.
        let isInterrupt = session.state == .needsApproval
        let terminal = store.terminal(for: session.id)
        return VStack(alignment: .leading, spacing: 13) {
            SessionRowView(
                session: session,
                terminal: terminal,
                showSessionMetadata: showSessionMetadata,
                showJumpHint: !isInterrupt && terminal?.isJumpable == true
            )
            if !isInterrupt {
                peekReplyPanel(session)
            }
            HStack {
                Spacer()
                Button {
                    model.peekSessionId = nil
                    model.showAllSessions = true
                } label: {
                    Text("Show all \(visibleSessions.count) sessions")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }

    private func peekReplyPanel(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("You: \(session.lastMessage ?? "")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("Done")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            Text(session.lastAssistantMessage ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.78))
                // 14pt leading on the recording (11pt mono + ~1.5).
                .lineSpacing(1.5)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Line the box up with the cards' content instead of running to the
        // panel walls (same lateral inset as SessionRowView).
        .padding(.leading, 18)
        .padding(.trailing, 15)
    }

    private var sessionList: some View {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(fullSessions) { session in
                        SessionRowView(
                            session: session,
                            terminal: store.terminal(for: session.id),
                            showSessionMetadata: showSessionMetadata
                        )
                    }
                    ForEach(compactSessions) { session in
                        SessionRowView(
                            session: session,
                            terminal: store.terminal(for: session.id),
                            isCompact: true,
                            showSessionMetadata: false
                        )
                    }
                }
                // Breathing room so the first/last card (and their hover
                // highlight) aren't shaved by the ScrollView clip edges.
                .padding(.vertical, 8)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ListHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            }
            .onPreferenceChange(ListHeightKey.self) { listContentHeight = $0 }
            // Hug the content until the cap, then scroll like the original.
            .frame(height: min(max(listContentHeight, 1), listHeightCap))
    }

    private struct ListHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    @AppStorage(SettingsKey.showUsageLimits) private var showUsageLimits = true

    /// Usage summary on the left, volume + settings icons on the right.
    private var topBar: some View {
        HStack(spacing: 14) {
            if showUsageLimits {
                usageSummary
            }
            Spacer()
            Image(systemName: SoundEngine.shared.isMuted
                ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .contentShape(Rectangle())
                .onTapGesture { SoundEngine.shared.isMuted.toggle() }
            Image(systemName: "gearshape.fill")
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(
                        name: .vedettaOpenSettings, object: nil
                    )
                }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.secondaryText)
        .padding(.leading, 18)
        .padding(.trailing, 21)
        .padding(.top, 8)
    }

    /// Real quota strip: Claude's 5h/7d windows plus any Codex windows (tagged
    /// "cx"), separated by thin bars; dots when nothing is known yet.
    private var usageSummary: some View {
        let provider = usage.displayProvider
        let entries = provider.map { usage.windows(for: $0) } ?? []
        return HStack(spacing: 5) {
            if let provider, !entries.isEmpty {
                providerIcon(provider)
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        Text("|").foregroundStyle(Theme.secondaryText.opacity(0.5))
                    }
                    usageWindow(label: entry.label, window: entry.window)
                }
            } else {
                Text("· · ·").foregroundStyle(Theme.secondaryText.opacity(0.5))
            }
        }
        .font(.system(size: 10))
        // Tap anywhere on the strip to cycle providers (Claude → Codex → …),
        // so only one fits left of the physical notch at a time.
        .contentShape(Rectangle())
        .onTapGesture { usage.cycleProvider() }
    }

    /// Provider badge (Claude / Codex) on a black rounded background, left of
    /// the usage numbers, from the bundled PNGs.
    private func providerIcon(_ provider: UsageModel.Provider) -> some View {
        // Claude ships a full-colour logo; Codex ships a monochrome template
        // mark, tinted white so it reads on the black badge.
        let name = provider == .claude ? "provider-claude" : "provider-codex"
        let isTemplate = provider == .codex
        return Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                if isTemplate {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .foregroundStyle(.white)
                } else {
                    Image(nsImage: image).resizable().interpolation(.high)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 14, height: 14)
        .padding(2)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func usageWindow(label: String, window: UsageModel.Window) -> some View {
        Text(label).bold().foregroundStyle(Theme.primaryText)
        Text("\(window.percent)%").bold().foregroundStyle(usageColor(window.percent))
        if let reset = window.resetLabel {
            Text(reset).foregroundStyle(Theme.secondaryText)
        }
    }

    private func usageColor(_ percent: Int) -> Color {
        if percent >= 80 { return Color(red: 0.92, green: 0.34, blue: 0.34) }
        if percent >= 50 { return Theme.claudeOrange }
        return Color(red: 0.42, green: 0.78, blue: 0.48)
    }
}

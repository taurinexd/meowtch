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
    var geometry: NotchGeometry
    var onHoverChange: (Bool) -> Void

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

                Group {
                    if model.isExpanded {
                        expandedContent
                    } else {
                        collapsedContent
                    }
                }
            }
            .frame(width: model.isExpanded ? expandedWidth : collapsedWidth)
            .frame(height: model.isExpanded ? nil : collapsedHeight)
            .fixedSize(horizontal: false, vertical: true)
            .offset(x: model.isExpanded ? 0 : collapsedOffset)
            // The collapsed bar reads as part of the bezel: no shadow at all.
            .shadow(
                color: model.isExpanded ? .black.opacity(0.35) : .clear,
                radius: model.isExpanded ? 24 : 0,
                y: model.isExpanded ? 6 : 0
            )
            .contentShape(NotchShape(topRadius: topFlare))
            .onHover(perform: onHoverChange)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isExpanded)

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
        // Instant removal: a fading copy would linger over the expanded
        // panel because the ticking TimelineView keeps invalidating it.
        .transition(.identity)
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
        guard !session.isMinimized, store.terminal(for: session.id) != nil else { return false }
        if session.state == .running || session.state == .needsApproval { return true }
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

    private var expandedContent: some View {
        // All paddings below are measured from the panel's flat edges, so
        // the flare inset is applied first (values pixel-measured on the
        // original: text column x=64, sprite x=18, sections every 26pt).
        VStack(alignment: .leading, spacing: 20) {
            topBar
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(fullSessions) { session in
                        SessionRowView(session: session, terminal: store.terminal(for: session.id))
                    }
                    ForEach(compactSessions) { session in
                        SessionRowView(session: session, terminal: store.terminal(for: session.id), isCompact: true)
                    }
                }
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
        // +4: the reference crop sits 4pt inside the real flat edges.
        .padding(.horizontal, expandedFlare + 4)
        .padding(.bottom, 18)
        .frame(width: expandedWidth, alignment: .top)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private struct ListHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Usage summary on the left, volume + settings icons on the right.
    private var topBar: some View {
        HStack(spacing: 14) {
            usageSummary
            Spacer()
            Image(systemName: "speaker.wave.2.fill")
            Image(systemName: "gearshape.fill")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.secondaryText)
        .padding(.leading, 18)
        .padding(.trailing, 21)
        .padding(.top, 8)
    }

    /// Real quota strip when rate_limits data is available; dots otherwise.
    private var usageSummary: some View {
        HStack(spacing: 5) {
            if let fiveHour = usage.fiveHour {
                usageWindow(label: "5h", window: fiveHour)
            }
            if usage.fiveHour != nil && usage.sevenDay != nil {
                Text("|").foregroundStyle(Theme.secondaryText.opacity(0.5))
            }
            if let sevenDay = usage.sevenDay {
                usageWindow(label: "7d", window: sevenDay)
            }
            if usage.fiveHour == nil && usage.sevenDay == nil {
                Text("· · ·").foregroundStyle(Theme.secondaryText.opacity(0.5))
            }
        }
        .font(.system(size: 11))
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

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
            if let topState = store.sessions.filter({ !$0.isMinimized }).map(\.state).min() {
                StateIndicator(state: topState, scale: 0.75)
            }
            Spacer()
            if !store.sessions.isEmpty {
                Text("\(store.sessions.count)")
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

    /// Color of the sprite: the most urgent state across sessions.
    private var statusColor: Color {
        guard let topState = store.sessions.map(\.state).min() else {
            return Theme.secondaryText
        }
        return Theme.color(for: topState)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        // All paddings below are measured from the panel's flat edges, so
        // the flare inset is applied first (values pixel-measured on the
        // original: text column x=64, sprite x=18, sections every 26pt).
        VStack(alignment: .leading, spacing: 20) {
            topBar
            ForEach(store.sessions) { session in
                SessionRowView(session: session, tasks: MockSessions.tasks[session.id])
            }
        }
        // +4: the reference crop sits 4pt inside the real flat edges.
        .padding(.horizontal, expandedFlare + 4)
        .padding(.bottom, 18)
        .frame(width: expandedWidth, alignment: .top)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    /// Usage summary on the left, volume + settings icons on the right.
    private var topBar: some View {
        HStack(spacing: 14) {
            usageSummary
            Spacer()
            Image(systemName: "speaker.wave.2.fill")
            Image(systemName: "gearshape.fill")
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.secondaryText)
        .padding(.leading, 18)
        .padding(.trailing, 21)
        .padding(.top, 8)
    }

    /// Mock of the quota strip ("5h 67% 44m | 7d 23% 4d0h") until M7.
    private var usageSummary: some View {
        HStack(spacing: 5) {
            Text("5h").bold().foregroundStyle(Theme.primaryText)
            Text("67%").bold().foregroundStyle(Theme.claudeOrange)
            Text("44m").foregroundStyle(Theme.secondaryText)
            Text("|").foregroundStyle(Theme.secondaryText.opacity(0.5))
            Text("7d").bold().foregroundStyle(Theme.primaryText)
            Text("23%").bold().foregroundStyle(.green)
            Text("4d0h").foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 13))
    }
}

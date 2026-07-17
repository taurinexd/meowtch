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

    /// Wing sizes measured against the original: the left wing hosts the
    /// sprite and is wider than the right one, which only fits the counter.
    private let leftWing: CGFloat = 46
    private let rightWing: CGFloat = 30

    private var collapsedWidth: CGFloat { geometry.notchWidth + leftWing + rightWing }
    private var collapsedHeight: CGFloat { geometry.barHeight + 4 }
    private let expandedWidth: CGFloat = 605

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: model.isExpanded ? 26 : 14)
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
            .shadow(color: .black.opacity(0.55), radius: model.isExpanded ? 18 : 6, y: 4)
            .contentShape(NotchShape())
            .onHover(perform: onHoverChange)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isExpanded)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Collapsed

    /// Content flanks the physical notch: nothing may sit under the camera.
    private var collapsedContent: some View {
        HStack {
            PixelSprite(pattern: PixelSprite.lookout, color: statusColor, pixelSize: 2)
                .padding(.leading, 12)
            Spacer()
            if !store.sessions.isEmpty {
                Text("\(store.sessions.count)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.trailing, 10)
            }
        }
        .frame(width: collapsedWidth, height: collapsedHeight)
        .transition(.opacity)
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
        VStack(alignment: .leading, spacing: 22) {
            topBar
            ForEach(store.sessions) { session in
                SessionRowView(session: session, tasks: MockSessions.tasks[session.id])
            }
        }
        .padding(.bottom, 22)
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
        .padding(.horizontal, 20)
        .padding(.top, 12)
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

import SwiftUI
import VedettaKit

/// One agent session, laid out like the original: sprite on the left,
/// title with chips on the first row, "You: …" and the running tool below,
/// optionally followed by the inset tasks widget.
struct SessionRowView: View {
    let session: AgentSession
    var tasks: MockTaskList?

    var body: some View {
        if session.isMinimized {
            compactRow
        } else {
            fullRow
        }
    }

    /// Sessions whose terminal window is minimized collapse to one line.
    private var compactRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.secondaryText.opacity(0.5))
                .frame(width: 8, height: 8)
            (
                Text(session.directoryName).fontWeight(.bold)
                + Text(" · ").foregroundStyle(Theme.secondaryText)
                + Text(session.title).fontWeight(.bold)
            )
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            Spacer(minLength: 8)
            chips
        }
        .padding(.leading, 16)
        .padding(.trailing, 18)
    }

    /// Layout measured on the original: a 46pt sprite column (sprite at
    /// x=18, vertically centered on the text block), text column at x=64,
    /// tasks widget full-width below both.
    private var fullRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    PixelSprite(
                        pattern: PixelSprite.lookout,
                        color: Theme.color(for: session.state),
                        pixelSize: 2.2
                    )
                    StateIndicator(state: session.state)
                }
                .frame(width: 46, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.directoryName)
                            .fontWeight(.bold)
                        + Text(" · ")
                            .foregroundStyle(Theme.secondaryText)
                        + Text(session.title)
                            .fontWeight(.bold)
                        Spacer(minLength: 8)
                        chips
                    }
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)

                    // While the agent waits, the panel shows its last words;
                    // while it works, what the user asked plus the tool.
                    if session.state == .running || session.state == .needsApproval {
                        if let message = session.lastMessage {
                            Text("You: \(message)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    } else if let reply = session.lastAssistantMessage {
                        Text(reply)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(3)
                    }

                    if session.state == .running, let tool = session.currentTool {
                        HStack(spacing: 6) {
                            Text(tool)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.toolBlue)
                            if let detail = session.currentToolDetail {
                                Text(detail)
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 12.5))
                    }
                }
            }

            if let tasks {
                TasksWidget(tasks: tasks)
                    .padding(.top, 16)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
    }

    private var chips: some View {
        HStack(spacing: 5) {
            Chip(text: session.agent.displayName, tint: Theme.claudeOrange)
            if !session.isMinimized {
                Chip(text: "VS Code")
            }
            if session.state == .waitingForInput && !session.isMinimized {
                Circle()
                    .fill(Theme.color(for: .waitingForInput))
                    .frame(width: 7, height: 7)
                    .padding(.leading, 4)
                    .padding(.trailing, 11)
            } else {
                Chip(text: session.startedAt.vedettaAge)
            }
        }
    }
}

/// Small rounded metadata chip ("Claude", "VS Code", "<1m", "BYPASS"…).
struct Chip: View {
    var text: String
    var tint: Color = Color.white.opacity(0.75)
    var background: Color = Color.white.opacity(0.09)

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Mock of the session task list until real transcript data arrives (M4).
struct MockTaskList {
    var done: Int
    var inProgress: String
    var completedVisible: [String]
}

/// Inset "Tasks" widget mirroring the original's anatomy.
struct TasksWidget: View {
    let tasks: MockTaskList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Tasks")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("(\(tasks.done) done, 1 in progress, 0 open)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 8) {
                Circle().fill(Theme.toolBlue).frame(width: 7, height: 7)
                Text(tasks.inProgress)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }
            ForEach(tasks.completedVisible, id: \.self) { item in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.opacity(0.6))
                    Text(item)
                        .font(.system(size: 12.5))
                        .strikethrough()
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Text("… +\(max(tasks.done - tasks.completedVisible.count, 0)) completed")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
                .padding(.leading, 18)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension Date {
    /// Compact age label like the original's chips: "<1m", "9m", "2h".
    var vedettaAge: String {
        let minutes = Int(-timeIntervalSinceNow / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

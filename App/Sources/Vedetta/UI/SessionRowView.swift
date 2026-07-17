import SwiftUI
import VedettaKit

/// One agent session, laid out like the original: sprite on the left,
/// title with chips on the first row, "You: …" and the running tool below,
/// optionally followed by the inset tasks widget.
struct SessionRowView: View {
    let session: AgentSession
    var terminal: TerminalInfo?
    /// Compact = the session has no visible terminal window to jump to
    /// (minimized, or adopted from transcripts with no live terminal).
    var isCompact = false
    @State private var isHovered = false
    @ObservedObject private var approvals = ApprovalCenter.shared

    var body: some View {
        Group {
            if isCompact {
                compactRow
            } else {
                fullRow
            }
        }
        // Hover highlight like the original: a soft rounded backdrop fades
        // in under the row the cursor is on, and out when it leaves.
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(0.07))
                .padding(.horizontal, 8)
                .opacity(isHovered ? 1 : 0)
        )
        .padding(.vertical, -8)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        // The whole card rect must react to the cursor, not just the
        // rendered glyphs inside it.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            JumpService.jump(to: session, terminal: terminal)
            // Jumping collapses the panel at once, like the original.
            NotificationCenter.default.post(name: .vedettaDidJump, object: nil)
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
            .font(.system(size: 12))
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
                HStack(alignment: .center, spacing: 6) {
                    PixelSprite(
                        pattern: PixelSprite.lookout,
                        color: Theme.color(for: session.state),
                        pixelSize: 2.2
                    )
                    if session.subagentCount > 0 {
                        PixelSprite(
                            pattern: PixelSprite.lookout,
                            color: Theme.color(for: session.state).opacity(0.8),
                            pixelSize: 1.4
                        )
                    }
                    StateIndicator(state: session.state)
                }
                .frame(minWidth: 46, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    // Text block and chips are COLUMNS: the You:/tool/reply
                    // lines truncate before the chips' left edge and never
                    // run under them (measured on the original). Only the
                    // recap below escapes the split and spans full width.
                    // Top-aligned; the chips strip is given the title line's
                    // exact height so the chips center on the title line.
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            (
                                Text(session.directoryName)
                                    .fontWeight(.bold)
                                + Text(" · ")
                                    .foregroundStyle(Theme.secondaryText)
                                + Text(session.title)
                                    .fontWeight(.bold)
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)

                            if session.recap == nil || session.recap?.isEmpty == true {
                                // Like the original: the user's last words
                                // always visible, then the running tool while
                                // working or the agent's reply otherwise.
                                if let message = session.lastMessage {
                                    Text("You: \(message)")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(1)
                                }
                                if session.state == .compacting {
                                    CompactingLine(startedAt: session.compactingStartedAt ?? session.lastActivityAt)
                                } else if session.state == .running, let tool = session.currentTool {
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
                                    .font(.system(size: 11.5))
                                } else if let reply = session.lastAssistantMessage {
                                    Text(reply)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(session.lastMessage != nil ? 1 : 3)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        chips
                            .frame(height: Self.titleLineHeight)
                    }

                    // The away-recap replaces the You:/reply lines and runs
                    // full width, under the chips column, like the original.
                    if let recap = session.recap, !recap.isEmpty {
                        Text(recap)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(3)
                    }
                }
            }

            if let pending = approvals.firstPending(for: session.id) {
                approvalBar(pending)
                    .padding(.top, 10)
            }

            // The widget earns its space only while there is work left;
            // an all-done list disappears, like the original.
            if let tasks = session.tasks,
               !tasks.inProgress.isEmpty || !tasks.open.isEmpty {
                TasksWidget(tasks: tasks)
                    .padding(.top, 16)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
    }

    /// Pending request UI: Allow/Deny strip for tools, option buttons for
    /// questions, a Markdown preview with approve/reject for plans.
    @ViewBuilder
    private func approvalBar(_ pending: ApprovalCenter.Pending) -> some View {
        switch pending.kind {
        case .tool:
            toolApprovalBar(pending)
        case .question(let text, let options):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 11))
                    Text("Question")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .foregroundStyle(Theme.color(for: .needsApproval))
                Text(text)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        ApprovalCenter.shared.decide(
                            id: pending.id,
                            allow: false,
                            message: "L'utente ha scelto: \(option)"
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(Theme.color(for: .needsApproval).opacity(0.8))
                                .foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(option)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.primaryText)
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.color(for: .needsApproval).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        case .plan(let markdown):
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                ScrollView {
                    Text((try? AttributedString(
                        markdown: markdown,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    )) ?? AttributedString(markdown))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        ApprovalCenter.shared.decide(id: pending.id, allow: false)
                    } label: {
                        Text("Reject")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        ApprovalCenter.shared.decide(id: pending.id, allow: true)
                    } label: {
                        Text("Approve")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func toolApprovalBar(_ pending: ApprovalCenter.Pending) -> some View {
        HStack(spacing: 8) {
            Text(pending.toolName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.color(for: .needsApproval))
            if let detail = pending.toolDetail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Button {
                ApprovalCenter.shared.decide(id: pending.id, allow: false)
            } label: {
                Text("Deny")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button {
                ApprovalCenter.shared.decide(id: pending.id, allow: true)
            } label: {
                Text("Allow")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Theme.color(for: .needsApproval).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Height of the bold 12pt title line: the chips strip takes exactly
    /// this height so its (taller) chips center on the title line.
    private static let titleLineHeight: CGFloat = {
        let font = NSFont.boldSystemFont(ofSize: 12)
        return font.ascender - font.descender + font.leading
    }()

    private var chips: some View {
        HStack(spacing: 5) {
            Chip(text: session.agent.displayName, tint: Theme.claudeOrange)
            // The host chip follows the terminal, not the row style: compact
            // rows with a known window still show it, like the original.
            if terminal?.termProgram == "vscode" || terminal?.bundleIdentifier == "com.microsoft.VSCode" {
                Chip(text: "VS Code")
            }
            trailingSlot
        }
    }

    /// Trailing element (age / status dot / archive on hover). Hidden
    /// reference chips reserve a width that is the same on EVERY row (not
    /// this row's own age), so the chips to its left all start at the same
    /// distance from the right edge across rows. Everything sits CENTERED
    /// in the slot, measured on the original: archive icon cx identical to
    /// the short age chips' cx (±1px) on full cards and compact rows alike.
    private var trailingSlot: some View {
        ZStack {
            Chip(text: "<1m").hidden()
            Chip(text: "59m").hidden()
            Chip(text: "23h").hidden()
            if isHovered {
                Button {
                    ArchiveStore.shared.archive(session.id)
                } label: {
                    Image(systemName: "tray")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            } else if session.state == .waitingForInput && !isCompact {
                Circle()
                    .fill(Theme.color(for: .waitingForInput))
                    .frame(width: 7, height: 7)
            } else {
                Chip(text: session.lastActivityAt.vedettaAge)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The context-compaction line shown in place of the tool line, like the
/// original: "Compacting · 29s" in purple (text #8E2FA4, sampled), with
/// the elapsed time ticking. Isolated in its own view so only this line
/// re-renders on the clock, not the whole row.
struct CompactingLine: View {
    @ObservedObject private var clock = PixelClock.shared
    let startedAt: Date

    var body: some View {
        let seconds = max(0, Int(clock.now.timeIntervalSince(startedAt)))
        let label = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        HStack(spacing: 6) {
            Text("Compacting").fontWeight(.semibold)
            Text("· \(label)")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.compactingText)
    }
}

/// Small rounded metadata chip ("Claude", "VS Code", "<1m", "BYPASS"…).
struct Chip: View {
    var text: String
    var tint: Color = Color.white.opacity(0.75)
    var background: Color = Color.white.opacity(0.09)

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Inset "Tasks" widget mirroring the original's anatomy: in-progress
/// items with a blue dot, open items with empty checkboxes (capped),
/// the first completed ones struck through, the rest as a counter.
struct TasksWidget: View {
    let tasks: SessionTasks
    private let openCap = 5
    private let doneCap = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Tasks")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("(\(tasks.done.count) done, \(tasks.inProgress.count) in progress, \(tasks.open.count) open)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(tasks.inProgress, id: \.id) { item in
                HStack(spacing: 8) {
                    Circle().fill(Theme.toolBlue).frame(width: 7, height: 7)
                    Text(item.subject)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
            }
            ForEach(tasks.open.prefix(openCap), id: \.id) { item in
                HStack(spacing: 8) {
                    Image(systemName: "square")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.opacity(0.6))
                    Text(item.subject)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.primaryText.opacity(0.85))
                        .lineLimit(1)
                }
            }
            ForEach(tasks.done.prefix(doneCap), id: \.id) { item in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.opacity(0.6))
                    Text(item.subject)
                        .font(.system(size: 11.5))
                        .strikethrough()
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            if tasks.done.count > doneCap {
                Text("… +\(tasks.done.count - doneCap) completed")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.opacity(0.7))
                    .padding(.leading, 18)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension Date {
    /// Compact age label like the original's chips: "<1m", "9m", "2h".
    /// Days above 24h keep the label within the fixed trailing slot.
    var vedettaAge: String {
        let minutes = Int(-timeIntervalSinceNow / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

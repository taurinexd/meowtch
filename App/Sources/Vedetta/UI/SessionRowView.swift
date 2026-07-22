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
    /// One global future-Settings preference; compact rows never use it.
    var showSessionMetadata = false
    /// Adds the teal "^G ↗" jump-shortcut chip (finished-session peek).
    var showJumpHint = false
    @State private var isHovered = false
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var questions = QuestionStore.shared

    private var hasPending: Bool {
        approvals.firstPending(for: session.id) != nil
            || questions.first(for: session.id) != nil
    }

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
                // While a request is pending the interaction is with the
                // buttons inside (each with its own hover), so the whole
                // card must not light up under the cursor, like the original.
                .opacity(isHovered && !hasPending ? 1 : 0)
        )
        .padding(.vertical, -8)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        // The whole card rect must react to the cursor, not just the
        // rendered glyphs inside it.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !UserDefaults.standard.bool(forKey: SettingsKey.disableClickToJump)
            else { return }
            guard terminal?.isJumpable == true else { return }
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
                    if SessionMetadataPresentation.shouldShow(
                        enabled: showSessionMetadata,
                        isCompact: isCompact,
                        metadata: session.presentationMetadata
                    ) {
                        Text(session.presentationMetadata.joined(separator: " · "))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText.opacity(0.72))
                            .lineLimit(1)
                    }
                }
            }

            if let pending = approvals.firstPending(for: session.id) {
                approvalBar(pending)
                    .padding(.top, 10)
            }

            if let live = questions.first(for: session.id) {
                questionBar(live)
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

    /// The live AskUserQuestion(s) shown in the notch. Each question lists
    /// its options (with descriptions); clicking one raises the terminal
    /// and drives the native picker to that choice.
    private func questionBar(_ live: QuestionStore.Live) -> some View {
        // One question at a time, like the original's WizardQuestionView and
        // the terminal's tabbed picker — never stacked. Selections accumulate
        // and answer on an explicit Invia (or Enter); Skip abandons the prompt
        // and Terminale hands it back to the native picker.
        let multi = live.questions.count > 1
        let current = questions.currentIndex(sessionId: live.sessionId)
        let qIndex = multi ? current : 0
        let question = live.questions[qIndex]
        return VStack(alignment: .leading, spacing: 10) {
            if multi {
                // Header chips as tabs: one per question, current highlighted,
                // answered ones ticked; a chip jumps straight to that question.
                HStack(spacing: 4) {
                    ForEach(Array(live.questions.enumerated()), id: \.element.id) { index, q in
                        questionTab(live, index: index, label: q.header ?? "Q\(index + 1)", isCurrent: index == current)
                    }
                    Spacer(minLength: 4)
                    Text("\(current + 1)/\(live.questions.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 11))
                    Text(question.header ?? "Question")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .foregroundStyle(Theme.color(for: .needsApproval))
                Text(question.prompt)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                ForEach(Array(question.choices.enumerated()), id: \.element.id) { index, choice in
                    QuestionOption(
                        index: index,
                        label: choice.label,
                        detail: choice.detail,
                        selected: questions.isSelected(
                            sessionId: live.sessionId, questionIndex: qIndex, optionIndex: index
                        )
                    ) {
                        questions.toggle(
                            sessionId: live.sessionId,
                            questionIndex: qIndex,
                            optionIndex: index,
                            multiSelect: question.multiSelect
                        )
                        // A single-select in the wizard advances to the next
                        // unanswered question, like the original.
                        if multi && !question.multiSelect {
                            questions.advanceToNextUnanswered(sessionId: live.sessionId)
                        }
                    }
                }
            }
            // Skip · Invia — one row. (No "Terminale" button: the native
            // picker is already shown in the terminal while we block, so the
            // user can answer there directly; a button for it is redundant.)
            HStack(spacing: 8) {
                questionFooterButton("Skip") { questions.skip(sessionId: live.sessionId) }
                Spacer(minLength: 0)
                Button {
                    questions.submit(sessionId: live.sessionId)
                } label: {
                    Text("Invia")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 5)
                        .background(questions.canSubmit(sessionId: live.sessionId)
                            ? Theme.color(for: .needsApproval) : Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!questions.canSubmit(sessionId: live.sessionId))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color(for: .needsApproval).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// A question tab in the multi-question wizard: shows the header, ticks it
    /// when answered, highlights the current one; tapping switches to it.
    private func questionTab(_ live: QuestionStore.Live, index: Int, label: String, isCurrent: Bool) -> some View {
        let answered = questions.isAnswered(sessionId: live.sessionId, questionIndex: index)
        return Button {
            questions.setCurrentIndex(sessionId: live.sessionId, index)
        } label: {
            HStack(spacing: 3) {
                if answered {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(isCurrent ? Color.black : (answered ? Theme.color(for: .needsApproval) : Theme.secondaryText))
            .background(isCurrent ? Theme.color(for: .needsApproval) : Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A subtle secondary action in the question footer (Skip / Terminale).
    private func questionFooterButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Pending request UI: Allow/Deny strip for tools, a Markdown preview
    /// with approve/reject for plans.
    @ViewBuilder
    private func approvalBar(_ pending: ApprovalCenter.Pending) -> some View {
        switch pending.kind {
        case .tool:
            toolApprovalBar(pending)
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
            if showJumpHint {
                Chip(
                    text: "^G ↗",
                    tint: Color(red: 0.31, green: 0.72, blue: 0.80),
                    background: Color(red: 0.07, green: 0.20, blue: 0.23)
                )
            }
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

/// One selectable answer in a Question card. Its own hover state so the
/// cursor highlights the single option under it, not the whole card, like
/// the original.
private struct QuestionOption: View {
    let index: Int
    let label: String
    var detail: String? = nil
    var selected: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Theme.color(for: .needsApproval).opacity(selected ? 1 : 0.8))
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.color(for: .needsApproval))
                }
            }
            .padding(8)
            .background(Color.white.opacity(selected ? 0.13 : (hovered ? 0.15 : 0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.color(for: .needsApproval).opacity(selected ? 0.6 : 0), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
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

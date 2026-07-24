import AppKit
import SwiftUI
import VedettaKit

/// Provider → accounts quota view, swapped in for the session list when
/// the user taps the usage strip. Every Claude account gets a row with
/// its 5h/7d windows; stale data shows its age, never a bare percentage.
/// Tapping a row copies a ready login/switch command to the clipboard.
/// Rows share the session cards' metrics: content at leading 18 /
/// trailing 15, hover highlight instead of a permanent backdrop.
struct UsageDrilldownView: View {
    @ObservedObject var usage: UsageModel
    @ObservedObject var store: SessionStore
    @State private var hoveredAccountId: String?
    @State private var switchingId: String?
    @State private var feedback: (id: String, text: String)?
    @State private var switchNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("CLAUDE")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(usage.claudeUsages) { entry in
                    accountRow(entry)
                }
            }
            if let switchNote {
                Text(switchNote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.opacity(0.85))
                    .padding(.leading, 18)
                    .padding(.trailing, 15)
                    .transition(.opacity)
            }
            let codexWindows = usage.windows(for: .codex)
            if !codexWindows.isEmpty {
                sectionHeader("CODEX")
                HStack(spacing: 10) {
                    ForEach(Array(codexWindows.enumerated()), id: \.offset) { _, entry in
                        windowCell(label: entry.label, window: entry.window)
                    }
                    Spacer()
                }
                .padding(.leading, 18)
                .padding(.trailing, 15)
            }
        }
        .padding(.top, 2)
    }

    /// The account currently in the default slot — the one a click made
    /// active, that plain `claude` everywhere resolves to.
    private var activeAccountPath: String {
        AccountSwitcher.activeDefaultPath
    }

    /// email · plan under the account name, when known.
    private func accountDetail(_ account: ClaudeAccount) -> String? {
        let parts = [account.email, account.subscriptionType].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .kerning(2)
            .foregroundStyle(Theme.secondaryText)
            .padding(.leading, 18)
    }

    private func accountRow(_ entry: UsageModel.ClaudeAccountUsage) -> some View {
        let isActive = entry.account.path == activeAccountPath
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? Theme.color(for: .waitingForInput) : .clear)
                    .frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.account.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if let detail = accountDetail(entry.account) {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondaryText.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if switchingId == entry.id {
                    Text("switching…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.color(for: .running))
                } else if feedback?.id == entry.id {
                    Text(feedback?.text ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.color(for: .needsApproval))
                } else if isActive {
                    Text("active")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.opacity(0.6))
                }
            }
            if switchingId != entry.id {
                accountBody(entry)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
        .padding(.vertical, 10)
        // The cards' hover idiom: a soft rounded backdrop under the row
        // the cursor is on (identical geometry to SessionRowView's).
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(0.07))
                .padding(.horizontal, 8)
                .opacity(hoveredAccountId == entry.id ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.18), value: hoveredAccountId)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredAccountId = hovering ? entry.id : nil
        }
        .onTapGesture { switchTo(entry.account) }
    }

    /// The meters (or a hint) below the account header.
    @ViewBuilder
    private func accountBody(_ entry: UsageModel.ClaudeAccountUsage) -> some View {
        if !entry.meters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if entry.isStale, let sample = entry.sample {
                    Text("Last updated \(age(of: sample.at)) ago")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                }
                ForEach(Array(entry.meters.enumerated()), id: \.offset) { _, meter in
                    meterView(meter)
                }
            }
            .padding(.leading, 13)
        } else {
            Text("run a session or turn on network refresh")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText.opacity(0.5))
                .padding(.leading, 13)
        }
    }

    /// One `/usage`-style meter: label, a severity-colored bar with the
    /// percentage, and the reset line.
    private func meterView(_ meter: UsageMeter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meter.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.10))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(meterColor(meter.severity))
                            .frame(width: max(2, geo.size.width * CGFloat(min(meter.percent, 100)) / 100))
                    }
                }
                .frame(height: 8)
                Text("\(meter.percent)% used")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
            }
            if let reset = meter.resetsAt {
                Text(resetText(reset))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
        }
    }

    private func meterColor(_ severity: UsageMeter.Severity) -> Color {
        switch severity {
        case .normal: Color(red: 0.42, green: 0.78, blue: 0.48)
        case .warning: Theme.claudeOrange
        case .critical: Color(red: 0.92, green: 0.34, blue: 0.34)
        }
    }

    /// "Resets 5:50pm (Europe/Rome)" today, "Resets Jul 25 at 12:59am
    /// (Europe/Rome)" otherwise — mirroring /usage.
    private func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = Calendar.current.isDateInToday(date)
            ? "h:mma"
            : "MMM d 'at' h:mma"
        let time = formatter.string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
        return "Resets \(time) (\(TimeZone.current.identifier))"
    }

    private func windowCell(label: String, window: UsageModel.Window) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(Theme.secondaryText)
            Text("\(window.percent)%")
                .bold()
                .foregroundStyle(usageColor(window.percent))
            if let reset = window.resetLabel {
                Text(reset).foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
        }
        .font(.system(size: 10, design: .monospaced))
    }

    /// Same thresholds as the strip (NotchView.usageColor).
    private func usageColor(_ percent: Int) -> Color {
        if percent >= 80 { return Color(red: 0.92, green: 0.34, blue: 0.34) }
        if percent >= 50 { return Theme.claudeOrange }
        return Color(red: 0.42, green: 0.78, blue: 0.48)
    }

    private func age(of date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds >= 3600 { return "\(seconds / 3600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// Global switch: make this account the default one every terminal
    /// uses (credential swap in the shared Keychain slot, like `/login`).
    /// Off the main thread — the Keychain write may pause for a prompt.
    /// The write is instant, but running sessions re-read the token on
    /// their next request, so the UI holds a visible "switching…" state
    /// and then says so, rather than pretending the switch is immediate.
    private func switchTo(_ account: ClaudeAccount) {
        guard account.path != activeAccountPath else { return }
        switchingId = account.id
        feedback = nil
        switchNote = nil
        let started = Date()
        DispatchQueue.global().async {
            let result = AccountSwitcher.switchDefault(to: account)
            // Keep the loading state visible for at least a beat even when
            // the Keychain write returns in milliseconds.
            let remaining = max(0, 0.7 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                switchingId = nil
                switch result {
                case .ok:
                    usage.activeClaudeAccountPath =
                        ClaudeAccountRegistry.canonical(account.path)
                    usage.refresh()
                    setSwitchNote(
                        "\(account.displayName) is now the default — open terminals update on their next request."
                    )
                case .noCredential:
                    showFeedback("log in first", for: account.id)
                case .failed:
                    showFeedback("switch failed", for: account.id)
                }
            }
        }
    }

    private func setSwitchNote(_ text: String) {
        withAnimation(.easeInOut(duration: 0.2)) { switchNote = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if switchNote == text {
                withAnimation(.easeInOut(duration: 0.3)) { switchNote = nil }
            }
        }
    }

    private func showFeedback(_ text: String, for id: String) {
        feedback = (id, text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if feedback?.id == id { feedback = nil }
        }
    }
}

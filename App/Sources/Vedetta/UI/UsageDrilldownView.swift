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
    @State private var copiedAccountId: String?
    @State private var hoveredAccountId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("CLAUDE")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(usage.claudeUsages) { entry in
                    accountRow(entry)
                }
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

    /// The account whose sessions were active most recently (nil tag =
    /// the default account).
    private var activeAccountPath: String? {
        let defaultPath = VedettaSetup.claudeAccounts.first?.path
        return store.sessions
            .filter { $0.agent == .claude && $0.state != .completed }
            .max { $0.lastActivityAt < $1.lastActivityAt }
            .map { $0.claudeConfigDir ?? defaultPath ?? "" }
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
        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Theme.color(for: .waitingForInput) : .clear)
                .frame(width: 5, height: 5)
            Text(entry.account.displayName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if copiedAccountId == entry.id {
                Text("command copied")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.color(for: .waitingForInput))
            } else if let sample = entry.sample {
                if entry.isStale {
                    Text("stale \(age(of: sample.at))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                } else {
                    HStack(spacing: 10) {
                        if let fiveHour = entry.fiveHour {
                            windowCell(label: "5h", window: fiveHour)
                        }
                        if let sevenDay = entry.sevenDay {
                            windowCell(label: "7d", window: sevenDay)
                        }
                    }
                }
            } else {
                Text("no data")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.opacity(0.5))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
        .padding(.vertical, 8)
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
        .onTapGesture { copyLoginCommand(entry.account) }
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

    /// The nice-to-have: hand the user a ready login/switch command. No
    /// terminal is raised and no focus moves — it lands in the clipboard.
    private func copyLoginCommand(_ account: ClaudeAccount) {
        let command = account.isDefault
            ? "claude"
            : "CLAUDE_CONFIG_DIR=\(account.path) claude"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedAccountId = account.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedAccountId == account.id { copiedAccountId = nil }
        }
    }
}

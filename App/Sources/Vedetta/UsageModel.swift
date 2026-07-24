import Foundation
import Combine
import VedettaKit

/// Real quota data for the usage strip, harvested from the statusline
/// hook's rate_limits dump (`~/.vedetta/cache/rl.json`). Tolerant parser:
/// it looks for window objects carrying a utilization percentage and a
/// reset timestamp, wherever the provider puts them.
@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    struct Window: Equatable, Sendable {
        var percent: Int
        var resetsAt: Date?
        var windowMinutes: Int?
    }

    @Published private(set) var fiveHour: Window?
    @Published private(set) var sevenDay: Window?
    /// Codex quota (from `codex app-server`), shown alongside Claude's.
    @Published private(set) var codexPrimary: Window?
    @Published private(set) var codexSecondary: Window?
    private var lastCodexProbe: Date?

    // MARK: - Provider switcher

    /// One provider's windows show at a time (so the strip stays clear of the
    /// physical notch); tapping the strip cycles Claude → Codex → … → Claude.
    enum Provider: Equatable { case claude, codex }

    @Published var selectedProvider: Provider = .claude

    /// Providers that currently have any window to show.
    var availableProviders: [Provider] {
        var list: [Provider] = []
        if fiveHour != nil || sevenDay != nil { list.append(.claude) }
        if codexPrimary != nil || codexSecondary != nil { list.append(.codex) }
        return list
    }

    /// The provider actually shown: the selection if it has data, else the
    /// first available.
    var displayProvider: Provider? {
        let available = availableProviders
        return available.contains(selectedProvider) ? selectedProvider : available.first
    }

    func cycleProvider() {
        let available = availableProviders
        guard available.count > 1, let current = displayProvider,
              let index = available.firstIndex(of: current) else { return }
        selectedProvider = available[(index + 1) % available.count]
        // "Auto" restores the last provider the user cycled to.
        UserDefaults.standard.set(
            selectedProvider == .codex ? "lastCodex" : "lastClaude",
            forKey: SettingsKey.lastUsageProvider
        )
    }

    /// Applies the Settings "Preferred Provider" choice: a fixed provider
    /// selects it outright; Auto restores the last one the user cycled to.
    func applyPreferredProvider(_ raw: String) {
        switch raw {
        case "claude": selectedProvider = .claude
        case "codex": selectedProvider = .codex
        default:
            let last = UserDefaults.standard.string(forKey: SettingsKey.lastUsageProvider)
            selectedProvider = last == "lastCodex" ? .codex : .claude
        }
    }

    /// The windows (with short labels) for a provider, in display order. The
    /// provider icon disambiguates, so Codex needs no "cx" prefix.
    func windows(for provider: Provider) -> [(label: String, window: Window)] {
        switch provider {
        case .claude:
            return [fiveHour.map { (label: "5h", window: $0) },
                    sevenDay.map { (label: "7d", window: $0) }].compactMap { $0 }
        case .codex:
            return [codexPrimary, codexSecondary]
                .compactMap { $0 }
                .map { (label: $0.durationLabel, window: $0) }
        }
    }

    private var timer: Timer?
    /// The statusline harvester's drop. If another statusline owns the
    /// Claude Code slot, Settings → Usage offers to take it over.
    private static var cachePaths: [String] {
        [NSHomeDirectory() + "/.vedetta/cache/rl.json"]
    }

    func start() {
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh(forceCodex: Bool = false) {
        if forceCodex { lastCodexProbe = nil }
        let fm = FileManager.default
        let freshest = Self.cachePaths
            .compactMap { path -> (path: String, modified: Date)? in
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modified = attrs[.modificationDate] as? Date else { return nil }
                return (path, modified)
            }
            .max { $0.modified < $1.modified }
        guard let freshest,
              let data = fm.contents(atPath: freshest.path) else { return }

        let parsed = RateLimitHarvest.windows(from: data)
        fiveHour = parsed.fiveHour.map(Window.init(quota:))
        sevenDay = parsed.sevenDay.map(Window.init(quota:))

        Task { await refreshCodex() }
    }

    /// Codex quota via the shared warm `codex app-server` connection. Keeps
    /// the last-known windows on failure.
    private func refreshCodex() async {
        if let last = lastCodexProbe, Date().timeIntervalSince(last) < 240 { return }
        guard let snapshot = await CodexAppServerClient.shared.rateLimits() else { return }
        lastCodexProbe = Date()
        codexPrimary = snapshot.primary.map {
            Window(
                percent: $0.usedPercent,
                resetsAt: $0.resetsAt,
                windowMinutes: $0.windowDurationMinutes
            )
        }
        codexSecondary = snapshot.secondary.map {
            Window(
                percent: $0.usedPercent,
                resetsAt: $0.resetsAt,
                windowMinutes: $0.windowDurationMinutes
            )
        }
    }

}

extension UsageModel.Window {
    init(quota: QuotaWindow) {
        self.init(
            percent: quota.percent, resetsAt: quota.resetsAt,
            windowMinutes: quota.windowMinutes
        )
    }
}

extension UsageModel.Window {
    /// Label from the window's own duration: "5h", "7d", "" when unknown.
    var durationLabel: String {
        guard let minutes = windowMinutes else { return "" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// Compact remaining-time label like the original: "1h44m", "3d6h".
    var resetLabel: String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSinceNow)
        guard seconds > 0 else { return nil }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

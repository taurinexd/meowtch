import Foundation
import Combine

/// Real quota data for the usage strip, harvested from the statusline
/// hook's rate_limits dump (`~/.vedetta/cache/rl.json`). Tolerant parser:
/// it looks for window objects carrying a utilization percentage and a
/// reset timestamp, wherever the provider puts them.
@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    struct Window: Equatable {
        var percent: Int
        var resetsAt: Date?
    }

    @Published private(set) var fiveHour: Window?
    @Published private(set) var sevenDay: Window?

    private var timer: Timer?
    private static var cachePath: String { NSHomeDirectory() + "/.vedetta/cache/rl.json" }

    func start() {
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard let data = FileManager.default.contents(atPath: Self.cachePath),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return }

        var windows: [(key: String, window: Window)] = []
        collectWindows(from: root, keyPath: "", into: &windows)

        fiveHour = windows.first {
            $0.key.contains("5h") || $0.key.contains("five_hour") || $0.key.contains("primary")
        }?.window
        sevenDay = windows.first {
            $0.key.contains("7d") || $0.key.contains("seven_day") || $0.key.contains("secondary")
        }?.window
    }

    private func collectWindows(
        from object: [String: Any],
        keyPath: String,
        into result: inout [(key: String, window: Window)]
    ) {
        let percent = (object["utilization"] as? NSNumber)?.intValue
            ?? (object["used_percent"] as? NSNumber)?.intValue
        if let percent {
            var resetsAt: Date?
            if let reset = object["resets_at"] as? String {
                resetsAt = ISO8601DateFormatter().date(from: reset)
            } else if let epoch = object["resets_at"] as? NSNumber {
                resetsAt = Date(timeIntervalSince1970: epoch.doubleValue)
            }
            result.append((keyPath.lowercased(), Window(percent: percent, resetsAt: resetsAt)))
        }
        for (key, value) in object {
            if let nested = value as? [String: Any] {
                collectWindows(from: nested, keyPath: keyPath + "/" + key, into: &result)
            }
        }
    }
}

extension UsageModel.Window {
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

import Foundation

public struct QuotaWindow: Equatable, Sendable {
    public var percent: Int
    public var resetsAt: Date?
    public var windowMinutes: Int?

    public init(percent: Int, resetsAt: Date? = nil, windowMinutes: Int? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

/// Tolerant rate-limit parser shared by the statusline cache files and the
/// oauth/usage response: finds window objects carrying a utilization
/// percentage and a reset timestamp wherever the provider puts them.
public enum RateLimitHarvest {
    public static func windows(from data: Data) -> (fiveHour: QuotaWindow?, sevenDay: QuotaWindow?) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return (nil, nil) }
        var found: [(key: String, window: QuotaWindow)] = []
        collect(from: root, keyPath: "", into: &found)
        let fiveHour = found.first {
            $0.key.contains("5h") || $0.key.contains("five_hour") || $0.key.contains("primary")
        }?.window
        let sevenDay = found.first {
            $0.key.contains("7d") || $0.key.contains("seven_day") || $0.key.contains("secondary")
        }?.window
        return (fiveHour, sevenDay)
    }

    private static func collect(
        from object: [String: Any],
        keyPath: String,
        into result: inout [(key: String, window: QuotaWindow)]
    ) {
        let percent = (object["used_percentage"] as? NSNumber)?.intValue
            ?? (object["utilization"] as? NSNumber)?.intValue
            ?? (object["used_percent"] as? NSNumber)?.intValue
        if let percent {
            var resetsAt: Date?
            if let reset = object["resets_at"] as? String {
                resetsAt = ISO8601DateFormatter().date(from: reset)
            } else if let epoch = object["resets_at"] as? NSNumber {
                resetsAt = Date(timeIntervalSince1970: epoch.doubleValue)
            }
            result.append((keyPath.lowercased(), QuotaWindow(percent: percent, resetsAt: resetsAt)))
        }
        for (key, value) in object {
            if let nested = value as? [String: Any] {
                collect(from: nested, keyPath: keyPath + "/" + key, into: &result)
            }
        }
    }
}

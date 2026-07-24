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

/// One labeled quota meter for the account drill-down: a named limit with
/// its used percentage, reset time, and severity — mirrors what `/usage`
/// shows ("Current session", "Current week (all models)", per-model week).
public struct UsageMeter: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case normal, warning, critical }

    public var label: String
    public var percent: Int
    public var resetsAt: Date?
    public var severity: Severity

    public init(label: String, percent: Int, resetsAt: Date?, severity: Severity) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
    }

    public var id: String { label }
}

/// The two condensed windows (for the strip) plus the full meter list (for
/// the drill-down), parsed from one payload.
public struct ParsedUsage: Equatable, Sendable {
    public var fiveHour: QuotaWindow?
    public var sevenDay: QuotaWindow?
    public var meters: [UsageMeter]

    public init(fiveHour: QuotaWindow?, sevenDay: QuotaWindow?, meters: [UsageMeter]) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.meters = meters
    }
}

/// Tolerant rate-limit parser shared by the statusline cache files and the
/// oauth/usage response. Prefers the endpoint's rich `limits` array for the
/// meters; falls back to five_hour/seven_day when only those are present
/// (the statusline case).
public enum RateLimitHarvest {
    public static func windows(from data: Data) -> (fiveHour: QuotaWindow?, sevenDay: QuotaWindow?) {
        let parsed = parse(from: data)
        return (parsed.fiveHour, parsed.sevenDay)
    }

    public static func parse(from data: Data) -> ParsedUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return ParsedUsage(fiveHour: nil, sevenDay: nil, meters: [])
        }
        var found: [(key: String, window: QuotaWindow)] = []
        collect(from: root, keyPath: "", into: &found)
        let fiveHour = pick(found, names: ["5h", "five_hour", "primary"])
        let sevenDay = pick(found, names: ["7d", "seven_day", "secondary"])

        var meters: [UsageMeter] = []
        if let limits = root["limits"] as? [[String: Any]] {
            meters = limits.compactMap(meter(fromLimit:))
        }
        if meters.isEmpty {
            if let fiveHour {
                meters.append(UsageMeter(
                    label: "Current session", percent: fiveHour.percent,
                    resetsAt: fiveHour.resetsAt, severity: severity(for: fiveHour.percent)
                ))
            }
            if let sevenDay {
                meters.append(UsageMeter(
                    label: "Current week (all models)", percent: sevenDay.percent,
                    resetsAt: sevenDay.resetsAt, severity: severity(for: sevenDay.percent)
                ))
            }
        }
        return ParsedUsage(fiveHour: fiveHour, sevenDay: sevenDay, meters: meters)
    }

    // MARK: - limits array (endpoint)

    private static func meter(fromLimit dict: [String: Any]) -> UsageMeter? {
        guard let percent = (dict["percent"] as? NSNumber)?.intValue else { return nil }
        let kind = dict["kind"] as? String ?? ""
        let model = ((dict["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        let label: String
        switch kind {
        case "session": label = "Current session"
        case "weekly_all": label = "Current week (all models)"
        case "weekly_scoped": label = model.map { "Current week (\($0))" } ?? "Current week (scoped)"
        default: label = kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let severity = UsageMeter.Severity(rawValue: dict["severity"] as? String ?? "")
            ?? self.severity(for: percent)
        return UsageMeter(
            label: label, percent: percent,
            resetsAt: parseDate(dict["resets_at"]), severity: severity
        )
    }

    private static func severity(for percent: Int) -> UsageMeter.Severity {
        if percent >= 80 { return .critical }
        if percent >= 50 { return .warning }
        return .normal
    }

    // MARK: - tolerant window scan

    private static func pick(
        _ found: [(key: String, window: QuotaWindow)], names: [String]
    ) -> QuotaWindow? {
        let exact = found.first {
            guard let component = $0.key.split(separator: "/").last else { return false }
            return names.contains(String(component))
        }
        return (exact ?? found.first { entry in
            names.contains { entry.key.contains($0) }
        })?.window
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
            result.append((
                keyPath.lowercased(),
                QuotaWindow(percent: percent, resetsAt: parseDate(object["resets_at"]))
            ))
        }
        for (key, value) in object {
            if let nested = value as? [String: Any] {
                collect(from: nested, keyPath: keyPath + "/" + key, into: &result)
            }
        }
    }

    /// Reset timestamps come as epoch ints (statusline) or ISO8601 strings
    /// with fractional seconds and an offset (endpoint).
    private static func parseDate(_ value: Any?) -> Date? {
        if let epoch = value as? NSNumber { return Date(timeIntervalSince1970: epoch.doubleValue) }
        guard let string = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

import Foundation

public struct CodexHome: Equatable, Sendable, Identifiable {
    public let path: String
    public let isDefault: Bool
    public let isAvailable: Bool

    public init(path: String, isDefault: Bool, isAvailable: Bool) {
        self.path = path
        self.isDefault = isDefault
        self.isAvailable = isAvailable
    }

    public var id: String { path }
    public var hooksPath: String { path + "/hooks.json" }
    public var configPath: String { path + "/config.toml" }
    public var sessionsPath: String { path + "/sessions" }
    public var sessionIndexPath: String { path + "/session_index.jsonl" }
}

public enum CodexHomeRegistry {
    public static func resolve(
        defaultPath: String,
        customPaths: [String],
        directoryExists: (String) -> Bool
    ) -> [CodexHome] {
        let canonicalDefault = canonical(defaultPath)
        var seen = Set<String>()
        return ([canonicalDefault] + customPaths.map(canonical)).compactMap { path in
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            return CodexHome(
                path: path,
                isDefault: path == canonicalDefault,
                isAvailable: directoryExists(path)
            )
        }
    }

    public static func canonical(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

public enum CodexFeatureConfig {
    public static func hooksExplicitlyDisabled(in toml: String) -> Bool {
        var section = ""
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = rawLine.prefix { $0 != "#" }
            let line = content.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            let compact = line.replacingOccurrences(of: " ", with: "")
            if (section.isEmpty || section == "features"), compact == "hooks=false" {
                return true
            }
        }
        return false
    }
}

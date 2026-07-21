import Foundation

public enum HookConfigFileStoreError: Error, LocalizedError {
    case malformedConfiguration(URL)

    public var errorDescription: String? {
        switch self {
        case .malformedConfiguration(let url):
            "Configurazione JSON non valida: \(url.path)"
        }
    }
}

public struct HookConfigMutationResult: Equatable {
    public let changed: Bool
    public let backupURL: URL?
}

/// Filesystem boundary for coding-agent hook configuration. Parsing and
/// serialization finish before the original file is backed up and atomically
/// replaced, so malformed input can never be mistaken for an empty config.
public struct HookConfigFileStore: Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func read(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        do {
            guard let dictionary = try JSONSerialization.jsonObject(
                with: strippingLineComments(from: data)
            ) as? [String: Any] else {
                throw HookConfigFileStoreError.malformedConfiguration(url)
            }
            return dictionary
        } catch is HookConfigFileStoreError {
            throw HookConfigFileStoreError.malformedConfiguration(url)
        } catch {
            throw HookConfigFileStoreError.malformedConfiguration(url)
        }
    }

    private func strippingLineComments(from data: Data) -> Data {
        let bytes = Array(data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }
            if byte == 0x22 {
                inString = true
                output.append(byte)
                index += 1
                continue
            }
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                index += 2
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    index += 1
                }
                continue
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    public func mutate(
        at url: URL,
        backupDirectory: URL,
        backupName: String,
        transform: ([String: Any]) throws -> ([String: Any], changed: Bool)
    ) throws -> HookConfigMutationResult {
        let existed = FileManager.default.fileExists(atPath: url.path)
        let current = try read(at: url)
        let (updated, changed) = try transform(current)
        guard changed else {
            return HookConfigMutationResult(changed: false, backupURL: nil)
        }

        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        )

        var backupURL: URL?
        if existed {
            try FileManager.default.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true
            )
            let destination = availableBackupURL(
                directory: backupDirectory,
                name: backupName
            )
            try FileManager.default.copyItem(at: url, to: destination)
            backupURL = destination
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return HookConfigMutationResult(changed: true, backupURL: backupURL)
    }

    private func availableBackupURL(directory: URL, name: String) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        let base = directory.appendingPathComponent("\(name).\(formatter.string(from: now()))")
        guard FileManager.default.fileExists(atPath: base.path) else { return base }

        var suffix = 1
        while FileManager.default.fileExists(atPath: "\(base.path).\(suffix)") {
            suffix += 1
        }
        return URL(fileURLWithPath: "\(base.path).\(suffix)")
    }
}

public enum HookAgentOperationOutcome: Equatable {
    case unchanged
    case changed
    case failed(String)
}

public struct HookAgentOperationReport: Equatable {
    public let claude: HookAgentOperationOutcome
    public let codex: HookAgentOperationOutcome

    public var anyChanged: Bool {
        claude == .changed || codex == .changed
    }

    public var hasFailures: Bool {
        if case .failed = claude { return true }
        if case .failed = codex { return true }
        return false
    }

    public static func run(
        claude: () throws -> Bool,
        codex: () throws -> Bool
    ) -> HookAgentOperationReport {
        HookAgentOperationReport(
            claude: capture(claude),
            codex: capture(codex)
        )
    }

    private static func capture(_ operation: () throws -> Bool) -> HookAgentOperationOutcome {
        do {
            return try operation() ? .changed : .unchanged
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

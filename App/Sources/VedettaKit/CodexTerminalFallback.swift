import Foundation

/// Parses the process/file records emitted by the same macOS `lsof -F`
/// mechanism VI uses to associate an open rollout with its Codex writer.
public enum CodexOpenRolloutFiles {
    public static func parse(lsofOutput: String) -> [String: Int32] {
        var ownerPID: Int32?
        var result: [String: Int32] = [:]

        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                ownerPID = Int32(value)
            case "n":
                guard let ownerPID,
                      value.contains("/sessions/"),
                      (value as NSString).lastPathComponent.hasPrefix("rollout-"),
                      value.hasSuffix(".jsonl") else { continue }
                result[value] = ownerPID
            default:
                continue
            }
        }
        return result
    }
}

/// Builds the terminal identity for a rollout-only Codex session from the
/// writer process. Hooks may later replace this fallback with a more precise
/// window identity; until then the writer ancestry is sufficient for the IDE
/// extension to select the exact integrated terminal.
public enum CodexTerminalFallback {
    public static func shouldRefreshWriter(
        cachedOwnerPID: Int32?,
        isProcessAlive: (Int32) -> Bool
    ) -> Bool {
        guard let cachedOwnerPID else { return true }
        return !isProcessAlive(cachedOwnerPID)
    }

    public static func resolve(
        ownerPID: Int32,
        parentOf: (Int32) -> Int32?,
        bundleIdentifierOf: (Int32) -> String?
    ) -> TerminalInfo? {
        var chain: [Int] = []
        var current = ownerPID
        var hostBundle: String?

        for _ in 0..<15 {
            chain.append(Int(current))
            if bundleIdentifierOf(current) == "com.microsoft.VSCode" {
                hostBundle = "com.microsoft.VSCode"
            }
            guard let parent = parentOf(current), parent > 1 else { break }
            current = parent
        }

        guard let hostBundle else { return nil }
        return TerminalInfo(
            termProgram: "vscode",
            bundleIdentifier: hostBundle,
            pid: ownerPID,
            pidChain: chain,
            isWriterFallback: true
        )
    }
}

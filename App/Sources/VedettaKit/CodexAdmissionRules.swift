import Foundation

/// Filters background-only Codex workers observed in the original and live
/// Codex/Claude companion artifacts. Rules are intentionally prefix/metadata
/// based so ordinary user conversations mentioning these terms remain visible.
public enum CodexAdmissionRules {
    private static let blockedTitlePrefixes = [
        "codex companion task:",
        "guardian:",
        "guardian ",
        "autoreview ",
        "memory writer",
        "memory consolidation",
        "chronicle ",
        "codex app suggested prompt",
        "git helper",
    ]

    private static let blockedWorkerKinds: Set<String> = [
        "task-worker", "guardian", "autoreview", "memory-writer",
        "memory-consolidation", "chronicle", "suggested-prompts", "git-helper",
    ]

    private static let blockedOriginators: Set<String> = [
        "codex desktop", "claude code",
    ]

    public static func shouldAdmit(
        title: String?,
        metadata: [String: String] = [:]
    ) -> Bool {
        let normalizedMetadata = metadata.values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if let originator = metadata["originator"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           blockedOriginators.contains(originator) {
            return false
        }
        if normalizedMetadata.contains(where: blockedWorkerKinds.contains) {
            return false
        }
        guard let title else { return true }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !blockedTitlePrefixes.contains { normalized.hasPrefix($0) }
    }
}

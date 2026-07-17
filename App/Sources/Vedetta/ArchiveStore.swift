import Foundation
import Combine

/// Sessions the user archived from the panel (tray icon on hover).
/// Persisted so they stay hidden across restarts, like the original.
@MainActor
final class ArchiveStore: ObservableObject {
    static let shared = ArchiveStore()
    private let key = "archivedSessionIds"

    @Published private(set) var archivedIds: Set<String>

    private init() {
        archivedIds = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func archive(_ sessionId: String) {
        archivedIds.insert(sessionId)
        UserDefaults.standard.set(Array(archivedIds), forKey: key)
    }

    func isArchived(_ sessionId: String) -> Bool {
        archivedIds.contains(sessionId)
    }
}

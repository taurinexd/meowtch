import Foundation
import Combine

/// Pending permission requests and their suspended replies. Each request
/// keeps the bridge connection open (checked continuation) until the user
/// decides from the notch — that's what makes remote approval possible.
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    enum Kind {
        case tool
        case question(text: String, options: [String])
        case plan(markdown: String)
    }

    struct Pending: Identifiable {
        let id: Int
        let sessionId: String
        let toolName: String
        let toolDetail: String?
        let kind: Kind
        let receivedAt: Date
    }

    @Published private(set) var pending: [Pending] = []
    private var continuations: [Int: CheckedContinuation<(allow: Bool, message: String?), Never>] = [:]
    private var nextId = 1

    /// Called when a new request arrives (expand the panel, play a sound).
    var onArrival: (() -> Void)?
    /// Called when the queue empties again.
    var onDrain: (() -> Void)?

    func requestDecision(
        sessionId: String,
        toolName: String,
        toolDetail: String?,
        kind: Kind = .tool
    ) async -> (allow: Bool, message: String?) {
        let id = nextId
        nextId += 1
        pending.append(Pending(
            id: id,
            sessionId: sessionId,
            toolName: toolName,
            toolDetail: toolDetail,
            kind: kind,
            receivedAt: Date()
        ))
        onArrival?()
        return await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func decide(id: Int, allow: Bool, message: String? = nil) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: (allow, message))
        if pending.isEmpty { onDrain?() }
    }

    func firstPending(for sessionId: String) -> Pending? {
        pending.first { $0.sessionId == sessionId }
    }
}

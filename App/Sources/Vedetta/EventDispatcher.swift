import Foundation
import VedettaKit

/// Main-actor endpoint for bridge envelopes: decodes the JSON, feeds the
/// reducer, and produces the reply the bridge relays back to the hook.
/// Static access keeps the EventServer's handler capture-free, which is
/// what lets raw Data cross the actor boundary under strict concurrency.
@MainActor
enum EventDispatcher {
    static var store: SessionStore?

    static func handle(_ data: Data) -> Data {
        let empty = Data("{}".utf8)
        guard let store,
              let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any] else { return empty }

        // Debug introspection: `{"cmd":"dump"}` returns the current store,
        // used by the data-correctness comparison loop against the original.
        if envelope["cmd"] as? String == "dump" {
            let sessions = store.sessions.map { session -> [String: Any] in
                [
                    "id": session.id,
                    "title": session.title,
                    "directory": session.directory,
                    "state": String(describing: session.state),
                    "lastMessage": session.lastMessage ?? "",
                    "lastAssistantMessage": session.lastAssistantMessage ?? "",
                    "currentTool": session.currentTool ?? "",
                    "currentToolDetail": session.currentToolDetail ?? "",
                ]
            }
            return (try? JSONSerialization.data(withJSONObject: ["sessions": sessions])) ?? empty
        }

        if let event = envelope["event"] as? [String: Any],
           let sessionId = event["session_id"] as? String {
            SessionBootstrap.liveEventIds.insert(sessionId)
        }
        SessionEventReducer.apply(envelope, to: store)
        return empty
    }
}

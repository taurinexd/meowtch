import Foundation
import VedettaKit

/// Main-actor endpoint for bridge envelopes: decodes the JSON, feeds the
/// reducer, and produces the reply the bridge relays back to the hook.
/// Permission requests suspend here until the user decides from the notch.
/// Static access keeps the EventServer's handler capture-free, which is
/// what lets raw Data cross the actor boundary under strict concurrency.
@MainActor
enum EventDispatcher {
    static var store: SessionStore?

    static func handle(_ data: Data) async -> Data {
        let empty = Data("{}".utf8)
        guard let store,
              let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any] else { return empty }

        if let command = envelope["cmd"] as? String {
            return handleCommand(command, envelope: envelope, store: store) ?? empty
        }

        guard let event = envelope["event"] as? [String: Any],
              let name = event["hook_event_name"] as? String,
              let sessionId = event["session_id"] as? String else { return empty }

        SessionBootstrap.liveEventIds.insert(sessionId)

        if name == "PermissionRequest" {
            // The reducer first: it creates the session lazily (the request
            // can be the first thing we ever hear from a session), records
            // the terminal identity and enriches title/messages.
            SessionEventReducer.apply(envelope, to: store)
            return await handlePermissionRequest(event, sessionId: sessionId, store: store)
        }

        SessionEventReducer.apply(envelope, to: store)
        return empty
    }

    // MARK: - Blocking approvals

    private static func handlePermissionRequest(
        _ event: [String: Any],
        sessionId: String,
        store: SessionStore
    ) async -> Data {
        let toolName = event["tool_name"] as? String ?? "?"
        let toolInput = event["tool_input"] as? [String: Any]
        let detail = (toolInput?["command"] as? String)
            ?? (toolInput?["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (toolInput?["description"] as? String)

        store.transition(id: sessionId, to: .needsApproval)

        let allow = await ApprovalCenter.shared.requestDecision(
            sessionId: sessionId,
            toolName: toolName,
            toolDetail: detail
        )

        store.transition(id: sessionId, to: .running)

        let reply: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": allow ? "allow" : "deny"],
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
    }

    // MARK: - Debug commands

    private static func handleCommand(
        _ command: String,
        envelope: [String: Any],
        store: SessionStore
    ) -> Data? {
        switch command {
        case "dump":
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
            return try? JSONSerialization.data(withJSONObject: ["sessions": sessions])

        case "pending":
            let items = ApprovalCenter.shared.pending.map { pending -> [String: Any] in
                [
                    "id": pending.id,
                    "sessionId": pending.sessionId,
                    "toolName": pending.toolName,
                    "toolDetail": pending.toolDetail ?? "",
                ]
            }
            return try? JSONSerialization.data(withJSONObject: ["pending": items])

        case "decide":
            guard let id = envelope["id"] as? Int else { return nil }
            let allow = envelope["allow"] as? Bool ?? false
            ApprovalCenter.shared.decide(id: id, allow: allow)
            return Data(#"{"ok":true}"#.utf8)

        default:
            return nil
        }
    }
}

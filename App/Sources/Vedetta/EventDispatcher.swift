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

        // Archived cards resurface on new user action: a fresh prompt or a
        // request waiting for a decision, like the original.
        if name == "UserPromptSubmit" || name == "PermissionRequest" {
            ArchiveStore.shared.unarchive(sessionId)
        }

        if name == "PermissionRequest" {
            // The reducer first: it creates the session lazily (the request
            // can be the first thing we ever hear from a session), records
            // the terminal identity and enriches title/messages.
            SessionEventReducer.apply(envelope, to: store)
            return await handlePermissionRequest(event, sessionId: sessionId, store: store)
        }

        SessionEventReducer.apply(envelope, to: store)

        // Names and task lists live anywhere in the transcript: refresh
        // them in the background at turn boundaries. Registering the path
        // also lets the periodic pass re-peek the recap for live sessions.
        if ["Stop", "UserPromptSubmit", "SessionStart"].contains(name),
           let path = event["transcript_path"] as? String {
            SessionBootstrap.registerScannedPath(path, for: sessionId)
            FullScanScheduler.schedule(path: path, sessionId: sessionId)
        }

        // Task tool calls mutate the live task files: refresh the widget
        // right away so it tracks the agent's list mid-turn, like VI.
        if name == "PostToolUse",
           (event["tool_name"] as? String)?.hasPrefix("Task") == true {
            FullScanScheduler.reloadTasks(sessionId: sessionId)
        }

        // A finished turn may deserve the auto-opened peek (the panel
        // controller decides based on what's frontmost).
        if name == "Stop" {
            NotificationCenter.default.post(
                name: .vedettaSessionFinished,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
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

        // Questions and plan reviews ride the same channel with richer UI.
        var kind: ApprovalCenter.Kind = .tool
        if toolName == "AskUserQuestion",
           let questions = toolInput?["questions"] as? [[String: Any]],
           let first = questions.first,
           let text = first["question"] as? String {
            let options = (first["options"] as? [[String: Any]])?
                .compactMap { $0["label"] as? String } ?? []
            kind = .question(text: text, options: options)
            SoundEngine.shared.play(.question)
        } else if toolName == "ExitPlanMode" || toolName == "EnterPlanMode",
                  let plan = toolInput?["plan"] as? String {
            kind = .plan(markdown: plan)
        }

        store.transition(id: sessionId, to: .needsApproval)

        let decision = await ApprovalCenter.shared.requestDecision(
            sessionId: sessionId,
            toolName: toolName,
            toolDetail: detail,
            kind: kind
        )

        store.transition(id: sessionId, to: .running)

        var decisionObject: [String: Any] = ["behavior": decision.allow ? "allow" : "deny"]
        if let message = decision.message, !decision.allow {
            decisionObject["message"] = message
        }
        let reply: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decisionObject,
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
                    "recap": session.recap ?? "",
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

        case "axdump":
            var options = AXTitleReader.Options()
            if let bundle = envelope["bundle"] as? String { options.bundleIdentifier = bundle }
            if let maxNodes = envelope["maxNodes"] as? Int { options.maxNodes = maxNodes }
            if let maxDepth = envelope["maxDepth"] as? Int { options.maxDepth = maxDepth }
            if let window = envelope["window"] as? String { options.windowFilter = window }
            if let role = envelope["role"] as? String { options.roleFilter = role }
            let nodes = AXTitleReader.dump(options: options).map { node -> [String: Any] in
                ["role": node.role, "title": node.title, "depth": node.depth, "window": node.window]
            }
            return try? JSONSerialization.data(withJSONObject: [
                "trusted": AXTitleReader.isTrusted,
                "nodes": nodes,
            ])

        case "decide":
            guard let id = envelope["id"] as? Int else { return nil }
            let allow = envelope["allow"] as? Bool ?? false
            ApprovalCenter.shared.decide(
                id: id,
                allow: allow,
                message: envelope["message"] as? String
            )
            return Data(#"{"ok":true}"#.utf8)

        default:
            return nil
        }
    }
}

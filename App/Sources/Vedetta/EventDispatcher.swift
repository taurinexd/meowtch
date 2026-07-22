import Foundation
import AppKit
import VedettaKit

/// Main-actor endpoint for bridge envelopes: decodes the JSON, feeds the
/// reducer, and produces the reply the bridge relays back to the hook.
/// Permission requests suspend here until the user decides from the notch.
/// Static access keeps the EventServer's handler capture-free, which is
/// what lets raw Data cross the actor boundary under strict concurrency.
@MainActor
enum EventDispatcher {
    static var store: SessionStore?
    static var codexCoordinator: CodexIngressCoordinator?

    static func handle(_ data: Data) async -> Data {
        let empty = Data("{}".utf8)
        guard let store,
              let object = try? JSONSerialization.jsonObject(with: data),
              var envelope = object as? [String: Any] else { return empty }

        if let command = envelope["cmd"] as? String {
            return handleCommand(command, envelope: envelope, store: store) ?? empty
        }

        var codexHook: CodexHookEvent?
        if envelope["source"] as? String == "codex" {
            do {
                let hook = try CodexHookEvent(envelope: envelope)
                codexHook = hook
                envelope = hook.normalizedEnvelope
            } catch {
                logHookMetadata(envelope, result: "rejected: \(error.localizedDescription)")
                return empty
            }
        }
        logHookMetadata(envelope, result: "accepted")

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
            if let codexHook {
                codexCoordinator?.apply(hook: codexHook)
                let request = CodexApprovalRequest(
                    threadID: codexHook.threadID,
                    turnID: codexHook.turnID,
                    toolUseID: codexHook.toolUseID,
                    permissionPolicy: codexHook.permissionMode,
                    configuredReviewer: codexHook.configuredReviewer,
                    sandboxPolicy: codexHook.sandboxPolicy,
                    autoReviewed: codexHook.autoReviewed
                )
                let mode = CodexApprovalMode(
                    rawValue: UserDefaults.standard.string(
                        forKey: "codexApprovalMode"
                    ) ?? ""
                ) ?? .followFocus
                let focusedBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let terminalFocused = focusedBundle != nil
                    && focusedBundle == codexHook.terminal.bundleIdentifier
                guard CodexApprovalPolicy.route(
                    mode: mode,
                    terminalIsFocused: terminalFocused,
                    request: request
                ) == .notch else { return empty }
                return await handlePermissionRequest(
                    event,
                    source: "codex",
                    sessionId: sessionId,
                    store: store,
                    fingerprint: CodexApprovalPolicy.fingerprint(for: request)
                )
            } else {
                SessionEventReducer.apply(envelope, to: store)
                if ClaudeApprovalPolicy.route(
                    deferToNative: UserDefaults.standard.bool(
                        forKey: "deferClaudeApprovalsToNative"
                    )
                ) == .terminal {
                    return empty
                }
            }
            return await handlePermissionRequest(
                event,
                source: envelope["source"] as? String ?? "claude",
                sessionId: sessionId,
                store: store,
                fingerprint: nil
            )
        }

        if let codexHook {
            codexCoordinator?.apply(hook: codexHook)
        } else {
            SessionEventReducer.apply(envelope, to: store)
        }

        // Event chirps ride the hook path itself (instant, like a user's
        // own afplay hooks); each one is individually silenceable from
        // Settings (approval/question chirps live in their own flows).
        switch name {
        case "SessionStart":
            // Not on compaction restarts, and never for sessions that made
            // no card (the resume picker's ghosts).
            if event["source"] as? String != "compact",
               store.sessions.contains(where: { $0.id == sessionId }) {
                SoundEngine.shared.play(.sessionStart)
            }
        case "UserPromptSubmit":
            SoundEngine.shared.play(.taskAcknowledge)
        case "StopFailure":
            SoundEngine.shared.play(.taskError)
        case "PreCompact":
            SoundEngine.shared.play(.contextLimit)
        default:
            break
        }

        // A pending request goes stale when the tool proceeds without our
        // decision (bypass mode) or the user answers in the terminal: the
        // tool's PostToolUse — or the turn moving on — is the signal to
        // clear our now-orphaned notch card.
        if ["PostToolUse", "Stop", "StopFailure", "SessionEnd", "UserPromptSubmit"].contains(name) {
            ApprovalCenter.shared.resolveStale(sessionId: sessionId)
            // The question's picker is done (answered anywhere) or abandoned.
            QuestionStore.shared.dismiss(sessionId: sessionId)
        }

        // A fresh process run (startup/resume — NOT compact, which keeps
        // the live context) resets the task-list freshness baseline: lists
        // whose files predate it belong to a closed run.
        if name == "SessionStart", envelope["source"] as? String != "codex",
           ["startup", "resume", "clear"].contains(event["source"] as? String ?? "") {
            let at = (envelope["capturedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
            SessionRunRegistry.recordRunStart(sessionId: sessionId, at: at)
        }

        // Names and task lists live anywhere in the transcript: refresh
        // them in the background at turn boundaries. Registering the path
        // also lets the periodic pass re-peek the recap for live sessions.
        if ["Stop", "UserPromptSubmit", "SessionStart"].contains(name),
           let path = event["transcript_path"] as? String {
            SessionBootstrap.registerScannedPath(path, for: sessionId)
            FullScanScheduler.schedule(path: path, sessionId: sessionId)
        }

        // Task tool calls mutate the live task files: refresh the widget
        // right away so it tracks the agent's list mid-turn, like the original.
        if name == "PostToolUse",
           (event["tool_name"] as? String)?.hasPrefix("Task") == true {
            FullScanScheduler.reloadTasks(sessionId: sessionId)
        }

        // A finished turn chirps right here on the hook path — as instant
        // as a user's own Stop-hook afplay — and may deserve the
        // auto-opened peek (the panel controller decides on frontmost).
        if name == "Stop" {
            SoundEngine.shared.play(.sessionComplete)
            NotificationCenter.default.post(
                name: .vedettaSessionFinished,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
        return codexHook?.nonBlockingResponseData ?? empty
    }

    // MARK: - Blocking approvals

    private static func handlePermissionRequest(
        _ event: [String: Any],
        source: String,
        sessionId: String,
        store: SessionStore,
        fingerprint: String?
    ) async -> Data {
        let toolName = event["tool_name"] as? String ?? "?"
        let toolInput = event["tool_input"] as? [String: Any]

        let detail = (toolInput?["command"] as? String)
            ?? (toolInput?["cmd"] as? String)
            ?? (toolInput?["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (toolInput?["path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (toolInput?["description"] as? String)

        // AskUserQuestion rides the SAME blocking channel as an approval: we
        // hold the hook open, mirror the question in the notch, and when the
        // user answers there we hand the answers back as DATA through
        // decision.updatedInput.answers. Claude Code then resolves the tool
        // with those answers and never shows its terminal picker — no
        // keystroke injection, no focus, nothing to corrupt the terminal.
        if source == "claude", toolName == "AskUserQuestion",
           let questions = QuestionStore.parse(toolInput) {
            store.transition(id: sessionId, to: .needsApproval)
            SoundEngine.shared.play(.question)
            let answers = await QuestionStore.shared.awaitAnswer(
                sessionId: sessionId, questions: questions
            )
            // An abandoned question resumes AFTER the event that dismissed it
            // (often Stop): only the approval state may be cleared, never a
            // state the lifecycle already moved past.
            store.clearApprovalState(id: sessionId)
            // Abandoned (nil): reply "{}" so the bridge stays silent and
            // Claude Code falls back to its own picker.
            guard let answers, var updatedInput = toolInput else { return Data("{}".utf8) }
            updatedInput["answers"] = answers
            let reply: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput,
                    ],
                ],
            ]
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        }

        // Plan reviews still ride the blocking allow/deny channel.
        var kind: ApprovalCenter.Kind = .tool
        if toolName == "ExitPlanMode" || toolName == "EnterPlanMode",
           let plan = toolInput?["plan"] as? String {
            kind = .plan(markdown: plan)
        }

        store.transition(id: sessionId, to: .needsApproval)

        let decision = await ApprovalCenter.shared.requestDecision(
            sessionId: sessionId,
            toolName: toolName,
            toolDetail: detail,
            kind: kind,
            fingerprint: fingerprint
        )

        // A handoff resumes AFTER the event that resolved it (often Stop):
        // only the approval state may be cleared, never a state the
        // lifecycle already moved past.
        store.clearApprovalState(id: sessionId)

        guard case .decision(let allow, let message) = decision else {
            return Data("{}".utf8)
        }

        var decisionObject: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if let message, !allow {
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

    /// Opt-in compatibility diagnostics intentionally exclude prompts, tool
    /// input/output, and every other payload body.
    private static func logHookMetadata(_ envelope: [String: Any], result: String) {
        guard ProcessInfo.processInfo.environment["VEDETTA_HOOK_LOG"] == "1" else { return }
        let event = envelope["event"] as? [String: Any]
        let source = envelope["source"] as? String ?? "unknown"
        let name = event?["hook_event_name"] as? String ?? "unknown"
        let session = event?["session_id"] as? String ?? "missing"
        let turn = (event?["codex_turn_id"] as? String)
            ?? (event?["turn_id"] as? String)
            ?? "missing"
        NSLog(
            "Vedetta hook source=%@ event=%@ session=%@ turn=%@ result=%@",
            source, name, session, turn, result
        )
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
                var entry: [String: Any] = [
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
                if let terminal = store.terminal(for: session.id) {
                    entry["terminal"] = [
                        "jumpable": terminal.isJumpable,
                        "tty": terminal.tty ?? "",
                        "termProgram": terminal.termProgram ?? "",
                        "bundleIdentifier": terminal.bundleIdentifier ?? "",
                        "pid": terminal.pid.map(Int.init) ?? 0,
                        "windowId": terminal.windowId ?? 0,
                        "pidChain": terminal.pidChain ?? [],
                        "writerFallback": terminal.isWriterFallback ?? false,
                    ]
                }
                return entry
            }
            return try? JSONSerialization.data(withJSONObject: ["sessions": sessions])

        case "pending":
            let items = ApprovalCenter.shared.pending.map { pending -> [String: Any] in
                [
                    "id": pending.id,
                    "sessionId": pending.sessionId,
                    "toolName": pending.toolName,
                    "toolDetail": pending.toolDetail ?? "",
                    "fingerprint": pending.fingerprint ?? "",
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

        case "usage":
            let usage = UsageModel.shared
            usage.refresh(forceCodex: true)
            let describe: (UsageModel.Window?) -> String = {
                $0.map { "\($0.percent)%" } ?? "-"
            }
            return try? JSONSerialization.data(withJSONObject: [
                "claude5h": describe(usage.fiveHour),
                "claude7d": describe(usage.sevenDay),
                "codexPrimary": describe(usage.codexPrimary),
                "codexSecondary": describe(usage.codexSecondary),
                "selected": String(describing: usage.selectedProvider),
                "display": String(describing: usage.displayProvider),
            ])

        case "openSettings":
            var userInfo: [String: Any] = [:]
            if let page = envelope["page"] as? String { userInfo["page"] = page }
            NotificationCenter.default.post(
                name: .vedettaOpenSettings, object: nil, userInfo: userInfo
            )
            return Data(#"{"ok":true}"#.utf8)

        case "setExpanded":
            NotificationCenter.default.post(
                name: .vedettaDebugSetExpanded,
                object: nil,
                userInfo: ["expanded": envelope["value"] as? Bool ?? false]
            )
            return Data(#"{"ok":true}"#.utf8)

        case "decide":
            guard let id = envelope["id"] as? Int else { return nil }
            let allow = envelope["allow"] as? Bool ?? false
            ApprovalCenter.shared.decide(
                id: id,
                allow: allow,
                message: envelope["message"] as? String,
                fingerprint: envelope["fingerprint"] as? String
            )
            return Data(#"{"ok":true}"#.utf8)

        default:
            return nil
        }
    }
}

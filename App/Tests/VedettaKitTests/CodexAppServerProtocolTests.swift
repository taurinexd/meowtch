import Foundation
import Testing
@testable import VedettaKit

struct CodexAppServerProtocolTests {
    @Test func multiplexesOutOfOrderResponsesAndNotifications() {
        var inbox = CodexRPCInbox()
        inbox.ingest(Data("""
        {"jsonrpc":"2.0","id":2,"result":{"value":"second"}}
        {"jsonrpc":"2.0","method":"hook/completed","params":{"id":"hook-1"}}
        {"jsonrpc":"2.0","id":1,"result":{"value":"first"}}
        """.appending("\n").utf8))

        #expect(inbox.takeResponse(id: 1) == .object(["value": .string("first")]))
        #expect(inbox.takeResponse(id: 2) == .object(["value": .string("second")]))
        #expect(inbox.notifications == [CodexRPCNotification(
            method: "hook/completed",
            params: .object(["id": .string("hook-1")])
        )])
    }

    @Test func buffersPartialFramesAndIgnoresMalformedLines() {
        var inbox = CodexRPCInbox()
        inbox.ingest(Data("not-json\n{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":".utf8))
        #expect(inbox.takeResponse(id: 3) == nil)
        inbox.ingest(Data("true}}\n".utf8))
        #expect(inbox.takeResponse(id: 3) == .object(["ok": .bool(true)]))
    }

    @Test func acceptsZeroPercentWindowsFromRealServerResponse() throws {
        // Real codex 0.145 response shape: usedPercent 0 and secondary null.
        // JSONSerialization bridges 0 to a Bool-castable NSNumber, which used
        // to turn usedPercent into .bool(false) and reject the whole payload
        // — the usage strip stayed empty exactly when the quota was fresh.
        let payload = """
        {"rateLimits":{"limitId":"codex","limitName":null,\
        "primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1785309299},\
        "secondary":null,"planType":"team"},\
        "rateLimitsByLimitId":{},"rateLimitResetCredits":{"availableCount":3}}
        """
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        let result = try #require(JSONValue(any: object))

        var accumulator = CodexRateLimitAccumulator()
        let accepted = accumulator.accept(result)
        #expect(accepted)
        #expect(accumulator.snapshot?.primary?.usedPercent == 0)
        #expect(accumulator.snapshot?.secondary == nil)
    }

    @Test func jsonValueKeepsBoolsAndZerosApart() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"zero":0,"one":1,"yes":true,"no":false}"#.utf8)
        )
        guard case .object(let values)? = JSONValue(any: object) else {
            Issue.record("not an object")
            return
        }
        #expect(values["zero"] == .number(0))
        #expect(values["one"] == .number(1))
        #expect(values["yes"] == .bool(true))
        #expect(values["no"] == .bool(false))
    }

    @Test func validatesAccountRateLimitsAndKeepsLastGoodSnapshot() {
        var accumulator = CodexRateLimitAccumulator()
        let valid: JSONValue = .object([
            "rateLimits": .object([
                "primary": .object([
                    "usedPercent": .number(27),
                    "resetsAt": .number(2_000),
                    "windowDurationMins": .number(300),
                ]),
                "secondary": .object([
                    "usedPercent": .number(8),
                    "windowDurationMins": .number(10_080),
                ]),
            ]),
        ])
        let accepted = accumulator.accept(valid)
        #expect(accepted)
        #expect(accumulator.snapshot?.primary?.usedPercent == 27)
        #expect(accumulator.snapshot?.secondary?.windowDurationMinutes == 10_080)

        let rejectedEmpty = accumulator.accept(.object(["rateLimits": .object([:])]))
        #expect(!rejectedEmpty)
        #expect(accumulator.snapshot?.primary?.usedPercent == 27)
        let rejectedInvalid = accumulator.accept(.object([
            "rateLimits": .object([
                "primary": .object(["usedPercent": .number(101)]),
            ]),
        ]))
        #expect(!rejectedInvalid)
        #expect(accumulator.snapshot?.primary?.usedPercent == 27)
    }

    @Test func parsesHookTrustFeatureAndManualStates() {
        let verified = CodexHookTrustSnapshot.parse(.object([
            "handlers": .array([
                .object(["eventName": .string("Stop"), "command": .string("vedetta-bridge")]),
            ]),
            "authorized": .bool(true),
        ]))
        #expect(verified.state == .verified)
        #expect(verified.handlers.count == 1)

        #expect(CodexHookTrustSnapshot.parse(.object([
            "hooksEnabled": .bool(false),
        ])).state == .disabled)
        #expect(CodexHookTrustSnapshot.parse(.object([
            "handlers": .array([]),
            "authorizationSupported": .bool(false),
        ])).state == .manualConfirmationRequired)
    }

    @Test func parsesCurrentHooksListSchemaAndTrustPerHandler() {
        let result: JSONValue = .object([
            "data": .array([
                .object([
                    "cwd": .string("/tmp/project"),
                    "errors": .array([]),
                    "warnings": .array([]),
                    "hooks": .array([
                        .object([
                            "eventName": .string("stop"),
                            "command": .string("vedetta-bridge --source codex"),
                            "enabled": .bool(true),
                            "trustStatus": .string("trusted"),
                        ]),
                        .object([
                            "eventName": .string("permissionRequest"),
                            "command": .string("foreign-hook"),
                            "enabled": .bool(true),
                            "trustStatus": .string("modified"),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let snapshot = CodexHookTrustSnapshot.parse(result)
        #expect(snapshot.state == .manualConfirmationRequired)
        #expect(snapshot.handlers == [
            CodexConfiguredHook(eventName: "stop", command: "vedetta-bridge --source codex"),
            CodexConfiguredHook(eventName: "permissionRequest", command: "foreign-hook"),
        ])
    }
}

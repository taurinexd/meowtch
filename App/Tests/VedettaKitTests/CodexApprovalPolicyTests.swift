import Testing
@testable import VedettaKit

struct CodexApprovalPolicyTests {
    private let request = CodexApprovalRequest(
        threadID: "thread-1",
        turnID: "turn-1",
        toolUseID: "call-1",
        permissionPolicy: "on-request",
        configuredReviewer: "user",
        sandboxPolicy: .object(["type": .string("workspace-write")]),
        autoReviewed: false
    )

    @Test func routesAllFourObservedModes() {
        #expect(CodexApprovalPolicy.route(
            mode: .followFocus, terminalIsFocused: false, request: request
        ) == .notch)
        #expect(CodexApprovalPolicy.route(
            mode: .followFocus, terminalIsFocused: true, request: request
        ) == .terminal)
        #expect(CodexApprovalPolicy.route(
            mode: .alwaysNotch, terminalIsFocused: true, request: request
        ) == .notch)
        #expect(CodexApprovalPolicy.route(
            mode: .alwaysTerminal, terminalIsFocused: false, request: request
        ) == .terminal)
        #expect(CodexApprovalPolicy.route(
            mode: .nativeCodex, terminalIsFocused: false, request: request
        ) == .terminal)
    }

    @Test func autoReviewedAndAmbiguousRequestsStayNative() {
        var auto = request
        auto.autoReviewed = true
        #expect(CodexApprovalPolicy.route(
            mode: .alwaysNotch, terminalIsFocused: false, request: auto
        ) == .terminal)

        var missingTurn = request
        missingTurn.turnID = nil
        #expect(CodexApprovalPolicy.route(
            mode: .alwaysNotch, terminalIsFocused: false, request: missingTurn
        ) == .terminal)
    }

    @Test func fingerprintCoversEveryPolicyIdentityField() {
        let baseline = CodexApprovalPolicy.fingerprint(for: request)
        var variants: [CodexApprovalRequest] = []
        var value = request; value.threadID = "thread-2"; variants.append(value)
        value = request; value.turnID = "turn-2"; variants.append(value)
        value = request; value.toolUseID = "call-2"; variants.append(value)
        value = request; value.permissionPolicy = "never"; variants.append(value)
        value = request; value.configuredReviewer = "guardian"; variants.append(value)
        value = request; value.sandboxPolicy = .object(["type": .string("read-only")]); variants.append(value)

        #expect(variants.allSatisfy { CodexApprovalPolicy.fingerprint(for: $0) != baseline })
        #expect(CodexApprovalPolicy.fingerprint(for: request) == baseline)
    }
}

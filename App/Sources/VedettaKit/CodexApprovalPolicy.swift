import Foundation

public enum CodexApprovalMode: String, CaseIterable, Codable, Sendable {
    case followFocus
    case alwaysNotch
    case alwaysTerminal
    case nativeCodex
}

public enum CodexApprovalRoute: Equatable, Sendable {
    case notch
    case terminal
}

public struct CodexApprovalRequest: Equatable, Sendable {
    public var threadID: String
    public var turnID: String?
    public var toolUseID: String?
    public var permissionPolicy: String?
    public var configuredReviewer: String?
    public var sandboxPolicy: JSONValue?
    public var autoReviewed: Bool

    public init(
        threadID: String,
        turnID: String?,
        toolUseID: String?,
        permissionPolicy: String?,
        configuredReviewer: String?,
        sandboxPolicy: JSONValue?,
        autoReviewed: Bool
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.toolUseID = toolUseID
        self.permissionPolicy = permissionPolicy
        self.configuredReviewer = configuredReviewer
        self.sandboxPolicy = sandboxPolicy
        self.autoReviewed = autoReviewed
    }
}

public enum CodexApprovalPolicy {
    public static func route(
        mode: CodexApprovalMode,
        terminalIsFocused: Bool,
        request: CodexApprovalRequest
    ) -> CodexApprovalRoute {
        guard !request.autoReviewed,
              !request.threadID.isEmpty,
              request.turnID?.isEmpty == false,
              request.toolUseID?.isEmpty == false else { return .terminal }
        switch mode {
        case .followFocus:
            return terminalIsFocused ? .terminal : .notch
        case .alwaysNotch:
            return .notch
        case .alwaysTerminal, .nativeCodex:
            return .terminal
        }
    }

    /// Stable identity for rejecting stale or cross-policy decisions. Length
    /// prefixes prevent delimiter collisions; sandbox JSON uses sorted keys.
    public static func fingerprint(for request: CodexApprovalRequest) -> String {
        let values = [
            request.threadID,
            request.turnID ?? "",
            request.toolUseID ?? "",
            request.permissionPolicy ?? "",
            request.configuredReviewer ?? "",
            canonical(request.sandboxPolicy),
        ]
        return values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func canonical(_ value: JSONValue?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(
                withJSONObject: value.anyValue,
                options: [.sortedKeys]
              ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

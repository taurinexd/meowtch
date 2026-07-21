import Foundation

public struct CodexRPCNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }
}

/// Incremental newline-delimited JSON-RPC demultiplexer used by the persistent
/// app-server process. Responses are keyed by request ID, not arrival order.
public struct CodexRPCInbox: Sendable {
    public private(set) var notifications: [CodexRPCNotification] = []
    private var pending = Data()
    private var responses: [Int: JSONValue] = [:]

    public init() {}

    public mutating func ingest(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            if let id = (object["id"] as? NSNumber)?.intValue,
               let result = JSONValue(any: object["result"]) {
                responses[id] = result
            } else if let method = object["method"] as? String {
                notifications.append(CodexRPCNotification(
                    method: method,
                    params: JSONValue(any: object["params"]) ?? .object([:])
                ))
            }
        }
    }

    public mutating func takeResponse(id: Int) -> JSONValue? {
        responses.removeValue(forKey: id)
    }
}

public struct CodexRateLimitWindow: Equatable, Sendable {
    public let usedPercent: Int
    public let resetsAt: Date?
    public let windowDurationMinutes: Int?
}

public struct CodexRateLimitSnapshot: Equatable, Sendable {
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
}

public struct CodexRateLimitAccumulator: Sendable {
    public private(set) var snapshot: CodexRateLimitSnapshot?

    public init() {}

    @discardableResult
    public mutating func accept(_ result: JSONValue) -> Bool {
        guard case .object(let root) = result,
              case .object(let rateLimits)? = root["rateLimits"] else { return false }
        let primary = Self.window(rateLimits["primary"])
        let secondary = Self.window(rateLimits["secondary"])
        guard primary != nil || secondary != nil else { return false }
        snapshot = CodexRateLimitSnapshot(primary: primary, secondary: secondary)
        return true
    }

    private static func window(_ value: JSONValue?) -> CodexRateLimitWindow? {
        guard case .object(let object)? = value,
              let percent = object["usedPercent"]?.integerValue,
              (0...100).contains(percent) else { return nil }
        let reset = object["resetsAt"]?.numberValue.map(Date.init(timeIntervalSince1970:))
        return CodexRateLimitWindow(
            usedPercent: percent,
            resetsAt: reset,
            windowDurationMinutes: object["windowDurationMins"]?.integerValue
        )
    }
}

public struct CodexConfiguredHook: Equatable, Sendable {
    public let eventName: String
    public let command: String
}

public struct CodexHookTrustSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case verified
        case manualConfirmationRequired
        case disabled
        case unverified
        case unavailable
    }

    public let state: State
    public let handlers: [CodexConfiguredHook]

    public init(state: State, handlers: [CodexConfiguredHook]) {
        self.state = state
        self.handlers = handlers
    }

    public static func parse(_ result: JSONValue) -> CodexHookTrustSnapshot {
        guard case .object(let root) = result else {
            return CodexHookTrustSnapshot(state: .unverified, handlers: [])
        }
        if case .array(let entries)? = root["data"] {
            var handlers: [CodexConfiguredHook] = []
            var trustStatuses: [String] = []
            for entry in entries {
                guard case .object(let object) = entry,
                      case .array(let hooks)? = object["hooks"] else { continue }
                for hook in hooks {
                    guard case .object(let metadata) = hook,
                          metadata["enabled"]?.boolValue != false,
                          let event = metadata["eventName"]?.stringValue,
                          let command = metadata["command"]?.stringValue else { continue }
                    handlers.append(CodexConfiguredHook(eventName: event, command: command))
                    if let trust = metadata["trustStatus"]?.stringValue {
                        trustStatuses.append(trust)
                    }
                }
            }
            let state: State
            if trustStatuses.contains(where: { $0 == "untrusted" || $0 == "modified" }) {
                state = .manualConfirmationRequired
            } else if !handlers.isEmpty,
                      trustStatuses.allSatisfy({ $0 == "trusted" || $0 == "managed" }) {
                state = .verified
            } else {
                state = .unverified
            }
            return CodexHookTrustSnapshot(state: state, handlers: handlers)
        }

        // Compatibility with the compact shape observed in older app-server
        // builds and retained in captured VI fixtures.
        let handlers: [CodexConfiguredHook]
        if case .array(let values)? = root["handlers"] {
            handlers = values.compactMap { value in
                guard case .object(let object) = value,
                      let event = object["eventName"]?.stringValue,
                      let command = object["command"]?.stringValue else { return nil }
                return CodexConfiguredHook(eventName: event, command: command)
            }
        } else {
            handlers = []
        }

        let state: State
        if root["hooksEnabled"]?.boolValue == false {
            state = .disabled
        } else if root["authorized"]?.boolValue == true {
            state = .verified
        } else if root["authorizationSupported"]?.boolValue == false {
            state = .manualConfirmationRequired
        } else {
            state = .unverified
        }
        return CodexHookTrustSnapshot(state: state, handlers: handlers)
    }
}

public extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        numberValue.map(Int.init)
    }
}

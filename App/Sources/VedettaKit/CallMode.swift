import Foundation

/// What the notch currently is. CODE is the agent-session panel Meowtch has
/// always been; CALL turns it into the in-call copilot and keeps every window
/// out of screen shares.
public enum CallMode: String, CaseIterable, Sendable {
    case code
    case call

    /// Only CALL asks AppKit to keep the window out of screen captures.
    public var hidesFromScreenCapture: Bool { self == .call }
}

import Foundation

extension TerminalInfo {
    /// The session runs in VS Code's integrated terminal.
    public var isVSCode: Bool {
        termProgram == "vscode" || bundleIdentifier == "com.microsoft.VSCode"
    }
}

/// Whether the session cards still need their "Claude" / "VS Code" chips.
/// A chip earns its place only when it tells rows apart: with a single
/// agent across the list, or VS Code as the only known host, it is noise.
public struct ChipVisibility: Equatable, Sendable {
    public var showAgent: Bool
    public var showHost: Bool

    public init(showAgent: Bool, showHost: Bool) {
        self.showAgent = showAgent
        self.showHost = showHost
    }

    /// `sessions` = every visible session's agent and captured terminal.
    /// Only terminals that name their host app count: rows with an unknown
    /// host never carry a host chip anyway.
    public init(sessions: [(agent: AgentKind, terminal: TerminalInfo?)]) {
        showAgent = Set(sessions.map(\.agent)).count > 1
        showHost = sessions.contains { entry in
            guard let terminal = entry.terminal,
                  terminal.termProgram != nil || terminal.bundleIdentifier != nil else { return false }
            return !terminal.isVSCode
        }
    }
}

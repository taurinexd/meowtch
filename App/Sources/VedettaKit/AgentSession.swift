import Foundation

/// The CLI agent a session belongs to.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Lifecycle state of an agent session, in display-priority order
/// (the original ranks a working agent above one merely waiting):
/// approval first, then running (blue), compacting (purple),
/// waiting (green), completed.
public enum SessionState: Int, Codable, Sendable, Comparable, CaseIterable {
    case needsApproval = 0
    case running = 1
    case compacting = 2
    case waitingForInput = 3
    case completed = 4

    public static func < (lhs: SessionState, rhs: SessionState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One live (or recently finished) agent session shown as a card in the panel.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public let id: String
    public var agent: AgentKind
    public var title: String
    public var directory: String
    public var gitBranch: String?
    public var model: String?
    /// Original Codex identities retained alongside Vedetta's namespaced ID.
    public var codexThreadID: String?
    public var currentTurnID: String?
    public var currentToolUseID: String?
    public var permissionMode: String?
    public var currentTool: String?
    public var currentToolDetail: String?
    public var lastMessage: String?
    public var lastAssistantMessage: String?
    /// Claude's away-recap: when present it replaces the You:/reply lines
    /// on the card, like the original. Cleared by any new user prompt.
    public var recap: String?
    public var state: SessionState
    public var startedAt: Date
    public var lastActivityAt: Date
    /// When the context compaction started (drives the "Compacting · 29s"
    /// elapsed label) and what triggered it ("manual" or "auto") — the
    /// trigger decides which state the session returns to afterwards.
    public var compactingStartedAt: Date?
    public var compactTrigger: String?
    /// True when the terminal window that hosts the session is minimized:
    /// the panel renders it as a compact single line at the bottom.
    public var isMinimized: Bool
    /// The session's task list, rebuilt from the transcript.
    public var tasks: SessionTasks?
    /// Live subagents spawned by the session.
    public var subagentCount: Int

    public init(
        id: String,
        agent: AgentKind,
        title: String,
        directory: String,
        gitBranch: String? = nil,
        model: String? = nil,
        codexThreadID: String? = nil,
        currentTurnID: String? = nil,
        currentToolUseID: String? = nil,
        permissionMode: String? = nil,
        currentTool: String? = nil,
        currentToolDetail: String? = nil,
        lastMessage: String? = nil,
        lastAssistantMessage: String? = nil,
        recap: String? = nil,
        state: SessionState,
        startedAt: Date,
        lastActivityAt: Date,
        isMinimized: Bool = false,
        tasks: SessionTasks? = nil,
        subagentCount: Int = 0
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.directory = directory
        self.gitBranch = gitBranch
        self.model = model
        self.codexThreadID = codexThreadID
        self.currentTurnID = currentTurnID
        self.currentToolUseID = currentToolUseID
        self.permissionMode = permissionMode
        self.currentTool = currentTool
        self.currentToolDetail = currentToolDetail
        self.lastMessage = lastMessage
        self.lastAssistantMessage = lastAssistantMessage
        self.recap = recap
        self.state = state
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.isMinimized = isMinimized
        self.tasks = tasks
        self.subagentCount = subagentCount
    }

    /// Last path component of the working directory, used as the card title prefix.
    public var directoryName: String {
        (directory as NSString).lastPathComponent
    }
}

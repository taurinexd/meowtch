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

/// Lifecycle state of an agent session, in display-priority order.
public enum SessionState: Int, Codable, Sendable, Comparable, CaseIterable {
    case needsApproval = 0
    case waitingForInput = 1
    case running = 2
    case completed = 3

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
    public var currentTool: String?
    public var currentToolDetail: String?
    public var lastMessage: String?
    public var lastAssistantMessage: String?
    public var state: SessionState
    public var startedAt: Date
    public var lastActivityAt: Date
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
        currentTool: String? = nil,
        currentToolDetail: String? = nil,
        lastMessage: String? = nil,
        lastAssistantMessage: String? = nil,
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
        self.currentTool = currentTool
        self.currentToolDetail = currentToolDetail
        self.lastMessage = lastMessage
        self.lastAssistantMessage = lastAssistantMessage
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

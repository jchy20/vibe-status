import Foundation

public enum AgentKind: String, Sendable, Hashable, Codable, CaseIterable {
    case codex
    case claudeCode

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

public enum TaskDisplayStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case needsAttention
    case working
    case ready

    public var displayName: String {
        switch self {
        case .needsAttention: "Needs Attention"
        case .working: "Working"
        case .ready: "Ready"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .needsAttention: 0
        case .working: 1
        case .ready: 2
        }
    }
}

public struct SessionSnapshot: Identifiable, Sendable, Hashable {
    public let hostID: String
    public let agent: AgentKind
    public let threadID: String
    public let name: String
    public let cwd: String?
    public let updatedAt: Date
    public let status: TaskDisplayStatus

    public var id: String { "\(hostID):\(agent.rawValue):\(threadID)" }

    public var workingDirectoryName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let value = URL(fileURLWithPath: cwd).lastPathComponent
        return value.isEmpty ? cwd : value
    }

    public init(
        hostID: String,
        agent: AgentKind = .codex,
        threadID: String,
        name: String,
        cwd: String? = nil,
        updatedAt: Date,
        status: TaskDisplayStatus
    ) {
        self.hostID = hostID
        self.agent = agent
        self.threadID = threadID
        self.name = name
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.status = status
    }
}

public enum HostIssueKind: String, Sendable, Hashable, Codable {
    case disconnected
    case systemError
    case protocolError
    case compatibility
}

public struct HostIssue: Identifiable, Sendable, Hashable {
    public let id: String
    public let hostID: String
    public let agent: AgentKind
    public let kind: HostIssueKind
    public let message: String
    public let updatedAt: Date

    public init(
        id: String? = nil,
        hostID: String,
        agent: AgentKind = .codex,
        kind: HostIssueKind,
        message: String,
        updatedAt: Date = Date()
    ) {
        self.id = id ?? "\(hostID):\(agent.rawValue):\(kind.rawValue)"
        self.hostID = hostID
        self.agent = agent
        self.kind = kind
        self.message = message
        self.updatedAt = updatedAt
    }
}

public struct StatusCounts: Sendable, Hashable, Equatable {
    public let needsAttention: Int
    public let working: Int
    public let ready: Int

    public init(needsAttention: Int, working: Int, ready: Int) {
        self.needsAttention = needsAttention
        self.working = working
        self.ready = ready
    }

    public static let zero = StatusCounts(
        needsAttention: 0,
        working: 0,
        ready: 0
    )
}

public struct DashboardSnapshot: Sendable, Hashable {
    public let sessions: [SessionSnapshot]
    public let issues: [HostIssue]

    public init(
        sessions: [SessionSnapshot] = [],
        issues: [HostIssue] = []
    ) {
        self.sessions = sessions.sorted(by: Self.sessionOrdering)
        self.issues = issues.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.hostID.localizedStandardCompare($1.hostID) == .orderedAscending
        }
    }

    public static let empty = DashboardSnapshot()

    public var counts: StatusCounts {
        sessions.reduce(into: StatusCounts.zero) { counts, session in
            switch session.status {
            case .needsAttention:
                counts = .init(
                    needsAttention: counts.needsAttention + 1,
                    working: counts.working,
                    ready: counts.ready
                )
            case .working:
                counts = .init(
                    needsAttention: counts.needsAttention,
                    working: counts.working + 1,
                    ready: counts.ready
                )
            case .ready:
                counts = .init(
                    needsAttention: counts.needsAttention,
                    working: counts.working,
                    ready: counts.ready + 1
                )
            }
        }
    }

    public func sessions(with status: TaskDisplayStatus) -> [SessionSnapshot] {
        sessions.filter { $0.status == status }
    }

    private static func sessionOrdering(
        _ lhs: SessionSnapshot,
        _ rhs: SessionSnapshot
    ) -> Bool {
        if lhs.status.sortOrder != rhs.status.sortOrder {
            return lhs.status.sortOrder < rhs.status.sortOrder
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.hostID != rhs.hostID {
            return lhs.hostID.localizedStandardCompare(rhs.hostID) == .orderedAscending
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

public struct HostSnapshot: Sendable, Hashable {
    public let hostID: String
    public let agent: AgentKind
    public let sessions: [SessionSnapshot]
    public let issues: [HostIssue]

    public init(
        hostID: String,
        agent: AgentKind = .codex,
        sessions: [SessionSnapshot] = [],
        issues: [HostIssue] = []
    ) {
        self.hostID = hostID
        self.agent = agent
        self.sessions = sessions
        self.issues = issues
    }
}

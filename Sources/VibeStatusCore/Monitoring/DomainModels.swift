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

public struct UsageWindowSnapshot: Identifiable, Sendable, Hashable {
    public let hostID: String
    public let agent: AgentKind
    /// Stable only for the life of the app and used to merge hosts that report
    /// the same provider quota. It is never shown or persisted.
    public let accountScopeID: String?
    public let limitID: String
    public let windowID: String
    public let limitName: String?
    public let usedPercentage: Double
    public let windowDurationMinutes: Int
    public let resetsAt: Date
    public let updatedAt: Date

    public var id: String {
        "\(hostID):\(agent.rawValue):\(limitID):\(windowID)"
    }

    public var remainingPercentage: Double {
        100 - usedPercentage
    }

    public init(
        hostID: String,
        agent: AgentKind,
        accountScopeID: String? = nil,
        limitID: String,
        windowID: String,
        limitName: String? = nil,
        usedPercentage: Double,
        windowDurationMinutes: Int,
        resetsAt: Date,
        updatedAt: Date = Date()
    ) {
        self.hostID = hostID
        self.agent = agent
        self.accountScopeID = accountScopeID
        self.limitID = limitID
        self.windowID = windowID
        self.limitName = limitName
        self.usedPercentage = min(100, max(0, usedPercentage))
        self.windowDurationMinutes = max(1, windowDurationMinutes)
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
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
    public let usage: [UsageWindowSnapshot]
    public let issues: [HostIssue]

    public init(
        sessions: [SessionSnapshot] = [],
        usage: [UsageWindowSnapshot] = [],
        issues: [HostIssue] = []
    ) {
        self.sessions = sessions.sorted(by: Self.sessionOrdering)
        self.usage = Self.deduplicatedUsage(usage).sorted(by: Self.usageOrdering)
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

    private static func usageOrdering(
        _ lhs: UsageWindowSnapshot,
        _ rhs: UsageWindowSnapshot
    ) -> Bool {
        if lhs.agent != rhs.agent {
            return lhs.agent == .codex
        }
        if lhs.hostID != rhs.hostID {
            return lhs.hostID.localizedStandardCompare(rhs.hostID) == .orderedAscending
        }
        if lhs.windowDurationMinutes != rhs.windowDurationMinutes {
            return lhs.windowDurationMinutes < rhs.windowDurationMinutes
        }
        return lhs.windowID < rhs.windowID
    }

    private static func deduplicatedUsage(
        _ usage: [UsageWindowSnapshot]
    ) -> [UsageWindowSnapshot] {
        struct Key: Hashable {
            let agent: AgentKind
            let scopeID: String
            let limitID: String
            let windowID: String
        }

        var newestByWindow: [Key: UsageWindowSnapshot] = [:]
        for window in usage {
            let key = Key(
                agent: window.agent,
                scopeID: window.accountScopeID ?? "host:\(window.hostID)",
                limitID: window.limitID,
                windowID: window.windowID
            )
            guard let existing = newestByWindow[key] else {
                newestByWindow[key] = window
                continue
            }
            if window.updatedAt > existing.updatedAt
                || (window.updatedAt == existing.updatedAt
                    && window.hostID.localizedStandardCompare(existing.hostID)
                        == .orderedAscending) {
                newestByWindow[key] = window
            }
        }
        return Array(newestByWindow.values)
    }
}

public struct HostSnapshot: Sendable, Hashable {
    public let hostID: String
    public let agent: AgentKind
    public let sessions: [SessionSnapshot]
    public let usage: [UsageWindowSnapshot]
    public let issues: [HostIssue]

    public init(
        hostID: String,
        agent: AgentKind = .codex,
        sessions: [SessionSnapshot] = [],
        usage: [UsageWindowSnapshot] = [],
        issues: [HostIssue] = []
    ) {
        self.hostID = hostID
        self.agent = agent
        self.sessions = sessions
        self.usage = usage
        self.issues = issues
    }
}

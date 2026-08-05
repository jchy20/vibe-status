import Foundation

public enum CodexThreadStatusKind: Sendable, Hashable {
    case notLoaded
    case idle
    case active
    case systemError
    case unknown(String)

    public var wireValue: String {
        switch self {
        case .notLoaded: "notLoaded"
        case .idle: "idle"
        case .active: "active"
        case .systemError: "systemError"
        case let .unknown(value): value
        }
    }
}

public struct CodexThreadStatus: Sendable, Hashable, Codable {
    public var kind: CodexThreadStatusKind
    public var activeFlags: Set<String>

    public init(kind: CodexThreadStatusKind, activeFlags: Set<String> = []) {
        self.kind = kind
        self.activeFlags = activeFlags
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case status
        case activeFlags
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            kind = Self.kind(for: raw)
            activeFlags = []
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .status)
            ?? "unknown"
        kind = Self.kind(for: raw)
        activeFlags = Set(
            try container.decodeIfPresent([String].self, forKey: .activeFlags) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.wireValue, forKey: .type)
        if !activeFlags.isEmpty {
            try container.encode(activeFlags.sorted(), forKey: .activeFlags)
        }
    }

    private static func kind(for raw: String) -> CodexThreadStatusKind {
        switch raw {
        case "notLoaded": .notLoaded
        case "idle": .idle
        case "active": .active
        case "systemError": .systemError
        default: .unknown(raw)
        }
    }
}

public struct CodexThread: Sendable, Hashable, Decodable {
    public let id: String
    public var name: String?
    public var preview: String?
    public var cwd: String?
    public var updatedAt: Date?
    public var recencyAt: Date?
    public var sessionID: String?
    public var forkedFromID: String?
    public var parentThreadID: String?
    public var ephemeral: Bool
    public var status: CodexThreadStatus
    public var source: JSONValue?
    public var agentRole: String?
    public var agentNickname: String?

    public init(
        id: String,
        name: String? = nil,
        preview: String? = nil,
        cwd: String? = nil,
        updatedAt: Date? = nil,
        recencyAt: Date? = nil,
        sessionID: String? = nil,
        forkedFromID: String? = nil,
        parentThreadID: String? = nil,
        ephemeral: Bool = false,
        status: CodexThreadStatus,
        source: JSONValue? = nil,
        agentRole: String? = nil,
        agentNickname: String? = nil
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.sessionID = sessionID
        self.forkedFromID = forkedFromID
        self.parentThreadID = parentThreadID
        self.ephemeral = ephemeral
        self.status = status
        self.source = source
        self.agentRole = agentRole
        self.agentNickname = agentNickname
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case preview
        case cwd
        case updatedAt
        case recencyAt
        case sessionId
        case forkedFromId
        case parentThreadId
        case ephemeral
        case status
        case source
        case agentRole
        case agentNickname
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionId)
        forkedFromID = try container.decodeIfPresent(String.self, forKey: .forkedFromId)
        parentThreadID = try container.decodeIfPresent(String.self, forKey: .parentThreadId)
        ephemeral = try container.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? false
        status = try container.decodeIfPresent(CodexThreadStatus.self, forKey: .status)
            ?? .init(kind: .unknown("missing"))
        source = try container.decodeIfPresent(JSONValue.self, forKey: .source)
        agentRole = try container.decodeIfPresent(String.self, forKey: .agentRole)
        agentNickname = try container.decodeIfPresent(String.self, forKey: .agentNickname)
        updatedAt = try Self.decodeDate(container, key: .updatedAt)
        recencyAt = try Self.decodeDate(container, key: .recencyAt)
    }

    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date? {
        guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else {
            return nil
        }
        switch value {
        case let .number(timestamp):
            let seconds = timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp
            return Date(timeIntervalSince1970: seconds)
        case let .string(value):
            if let timestamp = Double(value) {
                let seconds = timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp
                return Date(timeIntervalSince1970: seconds)
            }
            return ISO8601DateFormatter().date(from: value)
        default:
            return nil
        }
    }
}

public struct CodexLoadedThreadsResponse: Sendable, Decodable {
    /// Thread identifiers returned by Codex 0.145.0. Callers must issue a
    /// metadata-only `thread/read` for each identifier.
    public let data: [String]
    public let nextCursor: String?

    public init(data: [String], nextCursor: String? = nil) {
        self.data = data
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case threads
        case nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let identifiers = try? container.decode([String].self, forKey: .data) {
            data = identifiers
        } else if let identifiers = try? container.decode([String].self, forKey: .threads) {
            data = identifiers
        } else if let threads = try? container.decode([CodexThread].self, forKey: .data) {
            // Tolerate an anticipated richer response without making callers
            // rely on inline metadata that may be incomplete.
            data = threads.map(\.id)
        } else if let threads = try? container.decode([CodexThread].self, forKey: .threads) {
            data = threads.map(\.id)
        } else {
            data = []
        }
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

public struct CodexThreadReadResponse: Sendable, Decodable {
    public let thread: CodexThread

    public init(thread: CodexThread) {
        self.thread = thread
    }
}

public struct CodexAccount: Sendable, Hashable, Decodable {
    public let type: String
    public let email: String?
    public let planType: String?

    public init(type: String, email: String? = nil, planType: String? = nil) {
        self.type = type
        self.email = email
        self.planType = planType
    }
}

public struct CodexAccountResponse: Sendable, Hashable, Decodable {
    public let account: CodexAccount?
    public let requiresOpenAIAuth: Bool

    public init(account: CodexAccount?, requiresOpenAIAuth: Bool) {
        self.account = account
        self.requiresOpenAIAuth = requiresOpenAIAuth
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }

    public var usageScopeID: String? {
        guard account?.type == "chatgpt",
              let email = account?.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !email.isEmpty
        else {
            return nil
        }
        return "chatgpt:\(email)"
    }
}

public struct CodexRateLimitWindow: Sendable, Hashable, Decodable {
    public let usedPercent: Double
    public let windowDurationMins: Double
    public let resetsAt: TimeInterval

    public init(
        usedPercent: Double,
        windowDurationMins: Double,
        resetsAt: TimeInterval
    ) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct CodexRateLimitBucket: Sendable, Hashable, Decodable {
    public let limitID: String
    public let limitName: String?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?

    public init(
        limitID: String,
        limitName: String? = nil,
        primary: CodexRateLimitWindow? = nil,
        secondary: CodexRateLimitWindow? = nil
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
    }

    private enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName
        case primary
        case secondary
    }
}

public struct CodexRateLimitsResponse: Sendable, Hashable, Decodable {
    public let rateLimits: CodexRateLimitBucket?
    public let rateLimitsByLimitID: [String: CodexRateLimitBucket]?

    public init(
        rateLimits: CodexRateLimitBucket?,
        rateLimitsByLimitID: [String: CodexRateLimitBucket]? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitID = rateLimitsByLimitID
    }

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }

    public func usageSnapshots(
        hostID: String,
        accountScopeID: String? = nil,
        now: Date = Date()
    ) -> [UsageWindowSnapshot] {
        let buckets: [CodexRateLimitBucket]
        if let rateLimits {
            buckets = [rateLimits]
        } else {
            buckets = rateLimitsByLimitID?.values.sorted {
                $0.limitID < $1.limitID
            } ?? []
        }

        return buckets.flatMap { bucket in
            [
                bucket.primary.map {
                    usageSnapshot(
                        hostID: hostID,
                        accountScopeID: accountScopeID,
                        bucket: bucket,
                        window: $0,
                        windowID: "primary",
                        now: now
                    )
                },
                bucket.secondary.map {
                    usageSnapshot(
                        hostID: hostID,
                        accountScopeID: accountScopeID,
                        bucket: bucket,
                        window: $0,
                        windowID: "secondary",
                        now: now
                    )
                },
            ].compactMap { $0 }
        }
    }

    private func usageSnapshot(
        hostID: String,
        accountScopeID: String?,
        bucket: CodexRateLimitBucket,
        window: CodexRateLimitWindow,
        windowID: String,
        now: Date
    ) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            hostID: hostID,
            agent: .codex,
            accountScopeID: accountScopeID,
            limitID: bucket.limitID,
            windowID: windowID,
            limitName: bucket.limitName,
            usedPercentage: window.usedPercent,
            windowDurationMinutes: Int(window.windowDurationMins.rounded()),
            resetsAt: Date(timeIntervalSince1970: window.resetsAt),
            updatedAt: now
        )
    }
}

public enum CodexMonitoringEvent: Sendable, Hashable {
    case started(CodexThread)
    case statusChanged(threadID: String, status: CodexThreadStatus)
    case nameUpdated(threadID: String, name: String?)
    case removed(threadID: String)
    case accountUpdated
    case rateLimitsUpdated
    case unknown(method: String)

    public init(notification: JSONRPCNotification) throws {
        switch notification.method {
        case "thread/started":
            guard let params = notification.params else {
                throw CodexProtocolError.missingNotificationParams(notification.method)
            }
            if let wrapped = try? params.decode(ThreadStartedParams.self) {
                self = .started(wrapped.thread)
            } else {
                self = .started(try params.decode(CodexThread.self))
            }
        case "thread/status/changed":
            guard let params = notification.params else {
                throw CodexProtocolError.missingNotificationParams(notification.method)
            }
            let value = try params.decode(ThreadStatusChangedParams.self)
            self = .statusChanged(threadID: value.threadID, status: value.status)
        case "thread/name/updated":
            guard let params = notification.params else {
                throw CodexProtocolError.missingNotificationParams(notification.method)
            }
            let value = try params.decode(ThreadNameUpdatedParams.self)
            self = .nameUpdated(threadID: value.threadID, name: value.resolvedName)
        case "thread/closed", "thread/archived", "thread/deleted":
            guard let params = notification.params else {
                throw CodexProtocolError.missingNotificationParams(notification.method)
            }
            let value = try params.decode(ThreadIDParams.self)
            self = .removed(threadID: value.threadID)
        case "account/rateLimits/updated":
            self = .rateLimitsUpdated
        case "account/updated":
            self = .accountUpdated
        default:
            self = .unknown(method: notification.method)
        }
    }
}

private struct ThreadStartedParams: Decodable {
    let thread: CodexThread
}

private struct ThreadStatusChangedParams: Decodable {
    let threadID: String
    let status: CodexThreadStatus

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }
}

private struct ThreadNameUpdatedParams: Decodable {
    let threadID: String
    let name: String?
    let threadName: String?
    var resolvedName: String? { threadName ?? name }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case name
        case threadName
    }
}

private struct ThreadIDParams: Decodable {
    let threadID: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public enum CodexProtocolError: Error, Sendable, Equatable {
    case disconnected
    case timedOut(method: String)
    case unsupportedOutboundMethod(String)
    case missingResult(method: String)
    case missingNotificationParams(String)
    case malformedResponse(method: String)
}

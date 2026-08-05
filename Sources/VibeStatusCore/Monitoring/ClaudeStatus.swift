import Foundation

public struct ClaudeStatusRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: String
    public let name: String?
    public let cwd: String?
    public let status: TaskDisplayStatus
    public let updatedAt: TimeInterval

    public init(
        schemaVersion: Int = 1,
        sessionID: String,
        name: String? = nil,
        cwd: String? = nil,
        status: TaskDisplayStatus,
        updatedAt: TimeInterval
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.name = name
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case name
        case cwd
        case status
        case updatedAt = "updated_at"
    }
}

public struct ClaudeUsageWindow: Codable, Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: TimeInterval

    public init(usedPercentage: Double, resetsAt: TimeInterval) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

public struct ClaudeUsageRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let updatedAt: TimeInterval

    public init(
        schemaVersion: Int = 1,
        fiveHour: ClaudeUsageWindow? = nil,
        sevenDay: ClaudeUsageWindow? = nil,
        updatedAt: TimeInterval
    ) {
        self.schemaVersion = schemaVersion
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case updatedAt = "updated_at"
    }
}

public struct ClaudeStatusPayload: Decodable, Equatable, Sendable {
    public let sessions: [ClaudeStatusRecord]
    public let usage: ClaudeUsageRecord?

    public init(
        sessions: [ClaudeStatusRecord],
        usage: ClaudeUsageRecord? = nil
    ) {
        self.sessions = sessions
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
        case usage
    }

    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer()
            .decode([ClaudeStatusRecord].self) {
            sessions = legacy
            usage = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([ClaudeStatusRecord].self, forKey: .sessions)
        usage = try container.decodeIfPresent(ClaudeUsageRecord.self, forKey: .usage)
    }
}

public struct ClaudeStatusProjector: Sendable {
    public let maximumAge: TimeInterval
    public let maximumNameLength: Int

    public init(
        maximumAge: TimeInterval = 24 * 60 * 60,
        maximumNameLength: Int = 80
    ) {
        self.maximumAge = max(60.0, maximumAge)
        self.maximumNameLength = max(8, maximumNameLength)
    }

    public func hostSnapshot(
        hostID: String,
        records: [ClaudeStatusRecord],
        usage: ClaudeUsageRecord? = nil,
        now: Date = Date()
    ) -> HostSnapshot {
        let cutoff = now.timeIntervalSince1970 - maximumAge
        var newestBySession: [String: ClaudeStatusRecord] = [:]

        for record in records
        where record.schemaVersion == 1
            && !record.sessionID.isEmpty
            && record.updatedAt >= cutoff
            && record.updatedAt <= now.timeIntervalSince1970 + 60 {
            if let existing = newestBySession[record.sessionID],
               existing.updatedAt >= record.updatedAt {
                continue
            }
            newestBySession[record.sessionID] = record
        }

        let sessions = newestBySession.values.map { record in
            SessionSnapshot(
                hostID: hostID,
                agent: .claudeCode,
                threadID: record.sessionID,
                name: displayName(for: record),
                cwd: nonempty(record.cwd),
                updatedAt: Date(timeIntervalSince1970: record.updatedAt),
                status: record.status
            )
        }
        return HostSnapshot(
            hostID: hostID,
            agent: .claudeCode,
            sessions: sessions,
            usage: usageSnapshots(hostID: hostID, usage: usage, now: now)
        )
    }

    private func usageSnapshots(
        hostID: String,
        usage: ClaudeUsageRecord?,
        now: Date
    ) -> [UsageWindowSnapshot] {
        guard let usage,
              usage.schemaVersion == 1,
              usage.updatedAt >= now.timeIntervalSince1970 - maximumAge,
              usage.updatedAt <= now.timeIntervalSince1970 + 60
        else {
            return []
        }

        let updatedAt = Date(timeIntervalSince1970: usage.updatedAt)
        let accountScopeID = sharedQuotaScopeID(for: usage)
        return [
            usage.fiveHour.flatMap {
                usageSnapshot(
                    hostID: hostID,
                    accountScopeID: accountScopeID,
                    window: $0,
                    windowID: "five-hour",
                    durationMinutes: 5 * 60,
                    updatedAt: updatedAt,
                    now: now
                )
            },
            usage.sevenDay.flatMap {
                usageSnapshot(
                    hostID: hostID,
                    accountScopeID: accountScopeID,
                    window: $0,
                    windowID: "seven-day",
                    durationMinutes: 7 * 24 * 60,
                    updatedAt: updatedAt,
                    now: now
                )
            },
        ].compactMap { $0 }
    }

    private func usageSnapshot(
        hostID: String,
        accountScopeID: String?,
        window: ClaudeUsageWindow,
        windowID: String,
        durationMinutes: Int,
        updatedAt: Date,
        now: Date
    ) -> UsageWindowSnapshot? {
        guard window.resetsAt >= now.timeIntervalSince1970 - 60 else {
            return nil
        }
        return UsageWindowSnapshot(
            hostID: hostID,
            agent: .claudeCode,
            accountScopeID: accountScopeID,
            limitID: "claude",
            windowID: windowID,
            usedPercentage: window.usedPercentage,
            windowDurationMinutes: durationMinutes,
            resetsAt: Date(timeIntervalSince1970: window.resetsAt),
            updatedAt: updatedAt
        )
    }

    /// Claude's status-line payload has no account identifier. Two complete
    /// quota records with identical reset instants are treated as the same
    /// account-wide quota; partial records remain host-scoped to avoid a weak
    /// match merging unrelated accounts.
    private func sharedQuotaScopeID(
        for usage: ClaudeUsageRecord
    ) -> String? {
        guard let fiveHour = usage.fiveHour,
              let sevenDay = usage.sevenDay
        else {
            return nil
        }
        return "claude:\(Int64(fiveHour.resetsAt.rounded())):"
            + "\(Int64(sevenDay.resetsAt.rounded()))"
    }

    public func displayName(for record: ClaudeStatusRecord) -> String {
        if let name = nonempty(record.name) {
            return truncated(name)
        }
        if let cwd = nonempty(record.cwd) {
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            if !basename.isEmpty {
                return truncated(basename)
            }
        }
        return String(record.sessionID.prefix(8))
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func truncated(_ value: String) -> String {
        guard value.count > maximumNameLength else { return value }
        let end = value.index(
            value.startIndex,
            offsetBy: maximumNameLength - 1
        )
        return "\(value[..<end])…"
    }
}

public protocol ClaudeStatusLoading: Sendable {
    func load() async throws -> ClaudeStatusPayload
}

public enum ClaudeStatusLoaderError: Error, Equatable, LocalizedError {
    case sshExited(alias: String, status: Int32, diagnostics: String)
    case malformedSnapshot

    public var errorDescription: String? {
        switch self {
        case let .sshExited(alias, status, diagnostics):
            let detail = diagnostics
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return "Claude Code status on \(alias) exited with status \(status).\(suffix)"
        case .malformedSnapshot:
            return "Claude Code returned a malformed status snapshot."
        }
    }
}

public struct SSHClaudeStatusLoader: ClaudeStatusLoading, Sendable {
    public let alias: String
    public let runner: SSHOneShotCommandRunner

    public init(
        alias: String,
        runner: SSHOneShotCommandRunner = .init(timeout: 10)
    ) {
        self.alias = alias
        self.runner = runner
    }

    public func load() async throws -> ClaudeStatusPayload {
        let plan = try SSHCommandBuilder.claudeStatusSnapshotPlan(alias: alias)
        let result = try await runner.run(plan)
        guard result.termination.status == 0 else {
            throw ClaudeStatusLoaderError.sshExited(
                alias: alias,
                status: result.termination.status,
                diagnostics: result.standardErrorText
            )
        }
        do {
            return try JSONDecoder().decode(
                ClaudeStatusPayload.self,
                from: result.standardOutput
            )
        } catch {
            throw ClaudeStatusLoaderError.malformedSnapshot
        }
    }
}

public actor ClaudeStatusSupervisor {
    public let hostID: String

    private let engine: MonitoringEngine
    private let loader: any ClaudeStatusLoading
    private let pollInterval: TimeInterval
    private let reconnectPolicy: ReconnectPolicy
    private let projector: ClaudeStatusProjector

    private var lifecycleTask: Task<Void, Never>?
    private var generation = 0

    public init(
        hostID: String,
        engine: MonitoringEngine,
        loader: any ClaudeStatusLoading,
        pollInterval: TimeInterval = 5,
        reconnectPolicy: ReconnectPolicy = .init(),
        projector: ClaudeStatusProjector = .init()
    ) {
        self.hostID = hostID
        self.engine = engine
        self.loader = loader
        self.pollInterval = max(1, pollInterval)
        self.reconnectPolicy = reconnectPolicy
        self.projector = projector
    }

    public func start() {
        guard lifecycleTask == nil else { return }
        generation += 1
        let lifecycleGeneration = generation
        lifecycleTask = Task { [weak self] in
            await self?.run(generation: lifecycleGeneration)
        }
    }

    public func stop(removeHost: Bool = true) async {
        let task = lifecycleTask
        lifecycleTask = nil
        generation += 1
        task?.cancel()
        if removeHost {
            await engine.removeHost(hostID, agent: .claudeCode)
        }
    }

    public func suspend() async {
        await stop(removeHost: true)
    }

    public func resume() {
        start()
    }

    private func run(generation: Int) async {
        var failureCount = 0

        while !Task.isCancelled, generation == self.generation {
            do {
                let payload = try await loader.load()
                try Task.checkCancellation()
                guard generation == self.generation else { break }
                failureCount = 0
                await engine.replaceHost(
                    projector.hostSnapshot(
                        hostID: hostID,
                        records: payload.sessions,
                        usage: payload.usage
                    )
                )
                try await Self.sleep(seconds: pollInterval)
            } catch is CancellationError {
                break
            } catch {
                guard generation == self.generation else { break }
                failureCount += 1
                await engine.markHostDisconnected(
                    hostID: hostID,
                    agent: .claudeCode,
                    message: Self.issueMessage(hostID: hostID, error: error)
                )
                let delay = reconnectPolicy.delay(
                    forFailureCount: failureCount,
                    jitterUnit: Double.random(in: -1 ... 1)
                )
                do {
                    try await Self.sleep(seconds: delay)
                } catch {
                    break
                }
            }
        }
    }

    private static func issueMessage(
        hostID: String,
        error: any Error
    ) -> String {
        let detail = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        return "\(hostID) Claude Code monitoring disconnected: \(detail)"
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

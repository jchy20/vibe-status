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
            sessions: sessions
        )
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
    func load() async throws -> [ClaudeStatusRecord]
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

    public func load() async throws -> [ClaudeStatusRecord] {
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
                [ClaudeStatusRecord].self,
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
                let records = try await loader.load()
                try Task.checkCancellation()
                guard generation == self.generation else { break }
                failureCount = 0
                await engine.replaceHost(
                    projector.hostSnapshot(
                        hostID: hostID,
                        records: records
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

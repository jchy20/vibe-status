import Foundation

public actor ClusterSupervisor {
    public typealias SessionFactory =
        @Sendable () -> any CodexMonitoringSession

    private enum SupervisorSignal: Error {
        case eventStreamEnded
    }

    private enum StandaloneDiscoveryOutcome: Sendable {
        case unavailable
        case unsupported
        case success(Set<String>)
        case failure(String)
    }

    private struct StandaloneThreadRead: Sendable {
        let threads: [String: CodexThread]
        let failedStatusIDs: Set<String>
    }

    private struct StandaloneTurnStatuses: Sendable {
        let values: [String: CodexTurnStatus]
        let failedIDs: Set<String>
    }

    public let hostID: String

    private let engine: MonitoringEngine
    private let sessionFactory: SessionFactory
    private let reconnectPolicy: ReconnectPolicy
    private let reconcilePolicy: ReconcilePolicy
    private let projector: ThreadProjector
    private let standaloneSessionDiscovery:
        (any StandaloneCodexSessionDiscovering)?

    private var lifecycleTask: Task<Void, Never>?
    private var activeSession: (any CodexMonitoringSession)?
    private var generation = 0
    private var threads: [String: CodexThread] = [:]
    private var usage: [UsageWindowSnapshot] = []
    private var usageAccountScopeID: String?
    private var reconciliationInProgress = false
    private var reconciliationRequested = false
    private var standaloneThreads: [String: CodexThread] = [:]
    private var standaloneDiscoveryIssue: HostIssue?
    private var standaloneDiscoveryFailureCount = 0
    private var standaloneStatusFailureCounts: [String: Int] = [:]

    public init(
        hostID: String,
        engine: MonitoringEngine,
        sessionFactory: @escaping SessionFactory,
        standaloneSessionDiscovery:
            (any StandaloneCodexSessionDiscovering)? = nil,
        reconnectPolicy: ReconnectPolicy = .init(),
        reconcilePolicy: ReconcilePolicy = .init(),
        projector: ThreadProjector = .init()
    ) {
        self.hostID = hostID
        self.engine = engine
        self.sessionFactory = sessionFactory
        self.standaloneSessionDiscovery = standaloneSessionDiscovery
        self.reconnectPolicy = reconnectPolicy
        self.reconcilePolicy = reconcilePolicy
        self.projector = projector
    }

    public func start() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop(removeHost: Bool = true) async {
        let task = lifecycleTask
        lifecycleTask = nil
        task?.cancel()
        if let activeSession {
            await activeSession.close()
        }
        activeSession = nil
        threads.removeAll()
        usage.removeAll()
        usageAccountScopeID = nil
        standaloneThreads.removeAll()
        standaloneDiscoveryIssue = nil
        standaloneDiscoveryFailureCount = 0
        standaloneStatusFailureCounts.removeAll()
        generation += 1
        if removeHost {
            await engine.removeHost(hostID, agent: .codex)
        }
    }

    public func suspend() async {
        await stop(removeHost: true)
    }

    public func resume() {
        start()
    }

    private func run() async {
        var failureCount = 0

        while !Task.isCancelled {
            generation += 1
            let connectionGeneration = generation
            let session = sessionFactory()
            activeSession = session
            threads.removeAll()
            usage.removeAll()
            usageAccountScopeID = nil
            standaloneThreads.removeAll()
            standaloneDiscoveryIssue = nil
            standaloneDiscoveryFailureCount = 0
            standaloneStatusFailureCounts.removeAll()
            let connectedAt = Date()

            do {
                try await session.connectAndInitialize()
                try Task.checkCancellation()
                try await reconcile(
                    session: session,
                    generation: connectionGeneration
                )
                await refreshAccountAndUsage(
                    session: session,
                    generation: connectionGeneration
                )
                try await superviseConnected(
                    session: session,
                    generation: connectionGeneration
                )
            } catch is CancellationError {
                await session.close()
                break
            } catch {
                await session.close()
                guard connectionGeneration == generation else { continue }
                activeSession = nil
                threads.removeAll()
                usage.removeAll()
                usageAccountScopeID = nil
                standaloneThreads.removeAll()
                standaloneDiscoveryIssue = nil
                standaloneDiscoveryFailureCount = 0
                standaloneStatusFailureCounts.removeAll()
                await engine.markHostDisconnected(
                    hostID: hostID,
                    message: Self.issueMessage(hostID: hostID, error: error)
                )

                if Date().timeIntervalSince(connectedAt)
                    >= reconnectPolicy.stableConnectionResetInterval {
                    failureCount = 0
                }
                failureCount += 1
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

        if activeSession != nil {
            await activeSession?.close()
        }
        activeSession = nil
        if lifecycleTask?.isCancelled == true {
            lifecycleTask = nil
        }
    }

    private func superviseConnected(
        session: any CodexMonitoringSession,
        generation: Int
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                while !Task.isCancelled,
                      let event = try await session.nextEvent() {
                    guard let self else { return }
                    try await self.process(
                        event,
                        session: session,
                        generation: generation
                    )
                }
                throw SupervisorSignal.eventStreamEnded
            }

            group.addTask { [weak self, reconcilePolicy] in
                while !Task.isCancelled {
                    let delay = reconcilePolicy.delay(
                        jitterUnit: Double.random(in: -1 ... 1)
                    )
                    try await Self.sleep(seconds: delay)
                    guard let self else { return }
                    try await self.reconcile(
                        session: session,
                        generation: generation
                    )
                }
            }

            defer { group.cancelAll() }
            _ = try await group.next()
            throw SupervisorSignal.eventStreamEnded
        }
    }

    private func process(
        _ event: CodexMonitoringEvent,
        session: any CodexMonitoringSession,
        generation: Int
    ) async throws {
        guard generation == self.generation else { return }

        switch event {
        case let .started(thread):
            // Initialization subscribes this connection to newly started
            // threads. Unsubscribe before retaining or rendering any metadata.
            try await session.unsubscribe(threadID: thread.id)
            guard generation == self.generation else { return }
            threads[thread.id] = thread
            await publish()
        case let .statusChanged(threadID, status):
            guard threads[threadID] != nil else {
                try await reconcile(session: session, generation: generation)
                return
            }
            threads[threadID]?.status = status
            threads[threadID]?.updatedAt = Date()
            threads[threadID]?.recencyAt = Date()
            await publish()
        case let .nameUpdated(threadID, name):
            guard threads[threadID] != nil else {
                try await reconcile(session: session, generation: generation)
                return
            }
            threads[threadID]?.name = name
            threads[threadID]?.updatedAt = Date()
            threads[threadID]?.recencyAt = Date()
            await publish()
        case let .removed(threadID):
            threads.removeValue(forKey: threadID)
            await publish()
        case .accountUpdated, .rateLimitsUpdated:
            await refreshAccountAndUsage(
                session: session,
                generation: generation
            )
        case .unknown:
            // High-volume and future notification methods are intentionally
            // ignored. The periodic loaded-list snapshot heals any drift.
            break
        }
    }

    private func reconcile(
        session: any CodexMonitoringSession,
        generation: Int
    ) async throws {
        guard generation == self.generation else { return }
        if reconciliationInProgress {
            reconciliationRequested = true
            return
        }

        reconciliationInProgress = true
        defer { reconciliationInProgress = false }

        repeat {
            reconciliationRequested = false
            async let standaloneDiscovery = discoverStandaloneThreadIDs()
            let loadedIdentifiers = try await fetchAllThreadIDs(session: session)
            try Task.checkCancellation()
            guard generation == self.generation else { return }

            // Unsubscription is a safety invariant for a passive observer. Do
            // it before any optional cross-process discovery can delay this
            // client or expose it to an approval or input request.
            for identifier in loadedIdentifiers {
                try await session.unsubscribe(threadID: identifier)
            }

            switch await standaloneDiscovery {
            case let .success(discovered):
                if let standaloneRead = await readStandaloneThreads(
                    writerLockedIDs: discovered,
                    session: session
                ) {
                    standaloneDiscoveryFailureCount = 0
                    standaloneStatusFailureCounts = standaloneStatusFailureCounts
                        .filter { standaloneRead.threads[$0.key] != nil }
                    standaloneThreads = standaloneRead.threads
                    if standaloneRead.failedStatusIDs.isEmpty {
                        standaloneDiscoveryIssue = nil
                    } else {
                        standaloneDiscoveryIssue = standaloneIssue(
                            "Codex could not read the latest status for "
                                + "\(standaloneRead.failedStatusIDs.count) "
                                + "standalone task(s)."
                        )
                    }
                } else {
                    recordStandaloneDiscoveryFailure(
                        "Codex could not enumerate standalone interactive tasks."
                    )
                }
            case let .failure(message):
                recordStandaloneDiscoveryFailure(message)
            case .unsupported:
                standaloneDiscoveryFailureCount = 0
                standaloneStatusFailureCounts.removeAll()
                standaloneThreads.removeAll()
                standaloneDiscoveryIssue = nil
            case .unavailable:
                break
            }
            try Task.checkCancellation()
            guard generation == self.generation else { return }

            let loadedThreads = await readThreads(
                loadedIdentifiers,
                session: session,
                retaining: threads
            )
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            let reconciledThreads = loadedThreads.map { loadedThread in
                var thread = loadedThread
                // Codex 0.145 rebuilds pathless ephemeral threads for
                // metadata-only thread/read and can omit forkedFromId even
                // though thread/started included it. Retain the relationship
                // learned on this connection so a running /side task remains
                // projected onto its main task after reconciliation.
                if thread.ephemeral,
                   thread.forkedFromID == nil,
                   let knownParentID = threads[thread.id]?.forkedFromID {
                    thread.forkedFromID = knownParentID
                }
                return thread
            }
            var reconciledByID = Dictionary(
                uniqueKeysWithValues: reconciledThreads.map { ($0.id, $0) }
            )
            // A separately owned writer lock is stronger runtime evidence than
            // the managed daemon's process-local status for the same ID.
            for thread in standaloneThreads.values {
                reconciledByID[thread.id] = thread
            }
            threads = reconciledByID
            await publish()
        } while reconciliationRequested
    }

    private func fetchAllThreadIDs(
        session: any CodexMonitoringSession
    ) async throws -> [String] {
        var identifiers: [String] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        repeat {
            let page = try await session.loadedThreads(
                cursor: cursor,
                limit: reconcilePolicy.pageSize
            )
            identifiers.append(contentsOf: page.data)
            guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else {
                cursor = nil
                break
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw CodexProtocolError.malformedResponse(
                    method: CodexClientMethod.loadedThreads.rawValue
                )
            }
            cursor = nextCursor
        } while cursor != nil

        var seen: Set<String> = []
        return identifiers.filter { seen.insert($0).inserted }
    }

    private func readThreads(
        _ identifiers: [String],
        session: any CodexMonitoringSession,
        retaining knownThreads: [String: CodexThread]
    ) async -> [CodexThread] {
        var result: [String: CodexThread] = [:]
        let batchSize = reconcilePolicy.readConcurrency
        var startIndex = 0

        while startIndex < identifiers.count {
            let endIndex = min(startIndex + batchSize, identifiers.count)
            let batch = identifiers[startIndex ..< endIndex]
            await withTaskGroup(of: (String, CodexThread?).self) { group in
                for identifier in batch {
                    group.addTask {
                        (
                            identifier,
                            try? await session.readThread(id: identifier)
                        )
                    }
                }
                for await (identifier, thread) in group {
                    if let thread {
                        result[identifier] = thread
                    } else if let knownThread = knownThreads[identifier] {
                        // A transient per-thread read failure must not erase a
                        // task that the authoritative ID snapshot still lists.
                        result[identifier] = knownThread
                    }
                }
            }
            startIndex = endIndex
        }
        return Array(result.values)
    }

    private func discoverStandaloneThreadIDs() async -> StandaloneDiscoveryOutcome {
        guard let standaloneSessionDiscovery else { return .unavailable }
        do {
            return .success(
                try await standaloneSessionDiscovery.activeThreadIDs()
            )
        } catch StandaloneCodexSessionDiscoveryError.unsupported {
            return .unsupported
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return .failure(detail)
        }
    }

    private func readStandaloneThreads(
        writerLockedIDs: Set<String>,
        session: any CodexMonitoringSession
    ) async -> StandaloneThreadRead? {
        guard !writerLockedIDs.isEmpty else {
            return StandaloneThreadRead(threads: [:], failedStatusIDs: [])
        }
        guard let listedThreads = try? await fetchAllInteractiveThreads(
            session: session
        ) else {
            return nil
        }

        let candidates = listedThreads.filter {
            writerLockedIDs.contains($0.id)
        }
        let statuses = await readStandaloneTurnStatuses(
            Set(candidates.map(\.id)),
            session: session
        )
        let threads = Dictionary(
            uniqueKeysWithValues: candidates.map { candidate in
                var thread = candidate
                if statuses.failedIDs.contains(thread.id) {
                    let failureCount =
                        standaloneStatusFailureCounts[thread.id, default: 0]
                            + 1
                    standaloneStatusFailureCounts[thread.id] = failureCount
                    if failureCount == 1,
                       let knownStatus = standaloneThreads[thread.id]?.status {
                        thread.status = knownStatus
                    } else {
                        thread.status = .init(kind: .idle)
                    }
                } else {
                    standaloneStatusFailureCounts[thread.id] = nil
                    thread.status = .init(
                        kind: standaloneThreadStatus(
                            latestTurnStatus: statuses.values[thread.id]
                        )
                    )
                }
                return (thread.id, thread)
            }
        )
        return StandaloneThreadRead(
            threads: threads,
            failedStatusIDs: statuses.failedIDs
        )
    }

    private func fetchAllInteractiveThreads(
        session: any CodexMonitoringSession
    ) async throws -> [CodexThread] {
        var threads: [CodexThread] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        repeat {
            let page = try await session.listThreads(
                cursor: cursor,
                limit: reconcilePolicy.pageSize
            )
            threads.append(contentsOf: page.data)
            guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else {
                break
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw CodexProtocolError.malformedResponse(
                    method: CodexClientMethod.listThreads.rawValue
                )
            }
            cursor = nextCursor
        } while cursor != nil

        var seen: Set<String> = []
        return threads.filter { seen.insert($0.id).inserted }
    }

    private func readStandaloneTurnStatuses(
        _ identifiers: Set<String>,
        session: any CodexMonitoringSession
    ) async -> StandaloneTurnStatuses {
        var statuses: [String: CodexTurnStatus] = [:]
        var failedIDs: Set<String> = []
        let orderedIdentifiers = identifiers.sorted()
        var startIndex = 0

        while startIndex < orderedIdentifiers.count {
            let endIndex = min(
                startIndex + reconcilePolicy.readConcurrency,
                orderedIdentifiers.count
            )
            let batch = orderedIdentifiers[startIndex ..< endIndex]
            await withTaskGroup(
                of: (String, CodexTurnStatus?, Bool).self
            ) { group in
                for identifier in batch {
                    group.addTask {
                        do {
                            return (
                                identifier,
                                try await session.latestTurnStatus(
                                    threadID: identifier
                                ),
                                true
                            )
                        } catch {
                            return (identifier, nil, false)
                        }
                    }
                }
                for await (identifier, status, succeeded) in group {
                    if !succeeded {
                        failedIDs.insert(identifier)
                    }
                    if let status {
                        statuses[identifier] = status
                    }
                }
            }
            startIndex = endIndex
        }
        return StandaloneTurnStatuses(
            values: statuses,
            failedIDs: failedIDs
        )
    }

    private func standaloneIssue(_ message: String) -> HostIssue {
        HostIssue(
            id: "\(hostID):codex:standaloneDiscovery",
            hostID: hostID,
            agent: .codex,
            kind: .compatibility,
            message: message
        )
    }

    private func recordStandaloneDiscoveryFailure(_ message: String) {
        standaloneDiscoveryFailureCount += 1
        // Preserve one last-known snapshot across a transient failure, but do
        // not leave a closed standalone task visible indefinitely.
        if standaloneDiscoveryFailureCount >= 2 {
            standaloneThreads.removeAll()
            standaloneStatusFailureCounts.removeAll()
        }
        standaloneDiscoveryIssue = standaloneIssue(message)
    }

    private func standaloneThreadStatus(
        latestTurnStatus: CodexTurnStatus?
    ) -> CodexThreadStatusKind {
        switch latestTurnStatus {
        case .inProgress:
            .active
        case .completed, .interrupted, .failed, .unknown, nil:
            .idle
        }
    }

    private func publish() async {
        let projected = projector.hostSnapshot(
            hostID: hostID,
            threads: Array(threads.values)
        )
        await engine.replaceHost(
            HostSnapshot(
                hostID: hostID,
                agent: .codex,
                sessions: projected.sessions,
                usage: usage,
                issues: projected.issues + [standaloneDiscoveryIssue].compactMap { $0 }
            )
        )
    }

    private func refreshUsage(
        session: any CodexMonitoringSession,
        generation: Int
    ) async {
        guard generation == self.generation else { return }
        guard let response = try? await session.rateLimits() else {
            return
        }
        guard generation == self.generation else { return }
        usage = response.usageSnapshots(
            hostID: hostID,
            accountScopeID: usageAccountScopeID
        )
        await publish()
    }

    private func refreshAccountAndUsage(
        session: any CodexMonitoringSession,
        generation: Int
    ) async {
        guard generation == self.generation else { return }
        do {
            usageAccountScopeID = try await session.account().usageScopeID
        } catch {
            usageAccountScopeID = nil
        }
        await refreshUsage(session: session, generation: generation)
    }

    private static func issueMessage(
        hostID: String,
        error: any Error
    ) -> String {
        let detail = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        return "\(hostID) disconnected: \(detail)"
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

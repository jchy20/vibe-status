import Foundation

public actor ClusterSupervisor {
    public typealias SessionFactory =
        @Sendable () -> any CodexMonitoringSession

    private enum SupervisorSignal: Error {
        case eventStreamEnded
    }

    public let hostID: String

    private let engine: MonitoringEngine
    private let sessionFactory: SessionFactory
    private let reconnectPolicy: ReconnectPolicy
    private let reconcilePolicy: ReconcilePolicy
    private let projector: ThreadProjector

    private var lifecycleTask: Task<Void, Never>?
    private var activeSession: (any CodexMonitoringSession)?
    private var generation = 0
    private var threads: [String: CodexThread] = [:]
    private var reconciliationInProgress = false
    private var reconciliationRequested = false

    public init(
        hostID: String,
        engine: MonitoringEngine,
        sessionFactory: @escaping SessionFactory,
        reconnectPolicy: ReconnectPolicy = .init(),
        reconcilePolicy: ReconcilePolicy = .init(),
        projector: ThreadProjector = .init()
    ) {
        self.hostID = hostID
        self.engine = engine
        self.sessionFactory = sessionFactory
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
            let connectedAt = Date()

            do {
                try await session.connectAndInitialize()
                try Task.checkCancellation()
                try await reconcile(
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
            let identifiers = try await fetchAllThreadIDs(session: session)
            try Task.checkCancellation()
            guard generation == self.generation else { return }

            // Unsubscription is a safety invariant for a passive observer. A
            // failure tears down the long-lived connection instead of leaving
            // this client able to receive an approval or input request.
            for identifier in identifiers {
                try await session.unsubscribe(threadID: identifier)
            }

            let loadedThreads = await readThreads(
                identifiers,
                session: session
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
            threads = Dictionary(
                uniqueKeysWithValues: reconciledThreads.map { ($0.id, $0) }
            )
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
        session: any CodexMonitoringSession
    ) async -> [CodexThread] {
        var result: [CodexThread] = []
        let batchSize = reconcilePolicy.readConcurrency
        var startIndex = 0

        while startIndex < identifiers.count {
            let endIndex = min(startIndex + batchSize, identifiers.count)
            let batch = identifiers[startIndex ..< endIndex]
            await withTaskGroup(of: CodexThread?.self) { group in
                for identifier in batch {
                    group.addTask {
                        try? await session.readThread(id: identifier)
                    }
                }
                for await thread in group {
                    if let thread {
                        result.append(thread)
                    }
                }
            }
            startIndex = endIndex
        }
        return result
    }

    private func publish() async {
        await engine.replaceHost(
            projector.hostSnapshot(
                hostID: hostID,
                threads: Array(threads.values)
            )
        )
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

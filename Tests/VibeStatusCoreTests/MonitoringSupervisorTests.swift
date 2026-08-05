import Foundation
import XCTest
@testable import VibeStatusCore

final class MonitoringSupervisorTests: XCTestCase {
    func testInitialSnapshotReadsIDsAndUnsubscribesBeforeRendering() async throws {
        let session = FakeMonitoringSession(
            threads: [
                "root": CodexThread(
                    id: "root",
                    name: "Root task",
                    sessionID: "root",
                    status: .init(kind: .idle)
                ),
                "child": CodexThread(
                    id: "child",
                    parentThreadID: "root",
                    status: .init(kind: .active)
                ),
            ]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "host-a",
            engine: engine,
            sessionFactory: { session },
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let populated = await waitUntil {
            await engine.currentSnapshot().sessions.count == 1
        }
        XCTAssertTrue(populated)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.sessions.first?.threadID, "root")
        let unsubscribed = await session.unsubscribedIDs()
        XCTAssertEqual(Set(unsubscribed), ["root", "child"])
        await supervisor.stop()
    }

    func testStatusNotificationUpdatesExistingRootImmediately() async throws {
        let session = FakeMonitoringSession(
            threads: [
                "root": CodexThread(
                    id: "root",
                    name: "Root task",
                    sessionID: "root",
                    status: .init(kind: .idle)
                ),
            ]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "host-b",
            engine: engine,
            sessionFactory: { session },
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )
        await supervisor.start()
        let becameReady = await waitUntil {
            await engine.currentSnapshot().counts.ready == 1
        }
        XCTAssertTrue(becameReady)

        await session.push(
            .statusChanged(
                threadID: "root",
                status: .init(kind: .active)
            )
        )
        let becameWorking = await waitUntil {
            await engine.currentSnapshot().counts.working == 1
        }
        XCTAssertTrue(becameWorking)
        await supervisor.stop()
    }

    func testPublishesCodexRateLimitWindowWithoutAssumingFiveHours() async {
        let session = FakeMonitoringSession(
            threads: [:],
            account: CodexAccountResponse(
                account: .init(type: "chatgpt", email: "shared@example.com"),
                requiresOpenAIAuth: true
            ),
            rateLimits: CodexRateLimitsResponse(
                rateLimits: .init(
                    limitID: "codex",
                    primary: .init(
                        usedPercent: 52,
                        windowDurationMins: 10_080,
                        resetsAt: 1_900_000_000
                    )
                )
            )
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "host-a",
            engine: engine,
            sessionFactory: { session },
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let populated = await waitUntil {
            await engine.currentSnapshot().usage.first?.usedPercentage == 52
        }
        XCTAssertTrue(populated)
        let usage = await engine.currentSnapshot().usage
        XCTAssertEqual(usage.map(\.windowDurationMinutes), [10_080])
        XCTAssertEqual(usage.first?.accountScopeID, "chatgpt:shared@example.com")
        await supervisor.stop()
    }

    func testReconciliationRetainsSideConversationParentRelationship() async throws {
        let root = CodexThread(
            id: "root",
            name: "Root task",
            sessionID: "root",
            status: .init(kind: .idle)
        )
        let sideWithoutReadableParent = CodexThread(
            id: "side",
            name: "Side task",
            sessionID: "side",
            ephemeral: true,
            status: .init(kind: .active)
        )
        let session = FakeMonitoringSession(
            threads: [
                "root": root,
                "side": sideWithoutReadableParent,
            ]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "host-a",
            engine: engine,
            sessionFactory: { session },
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 0.1, jitterFraction: 0)
        )

        await supervisor.start()
        let initiallyReady = await waitUntil {
            await engine.currentSnapshot().counts.ready == 1
        }
        XCTAssertTrue(initiallyReady)

        var startedSide = sideWithoutReadableParent
        startedSide.forkedFromID = "root"
        await session.push(.started(startedSide))
        let becameWorking = await waitUntil {
            await engine.currentSnapshot().counts.working == 1
        }
        XCTAssertTrue(becameWorking)

        try await Task.sleep(nanoseconds: 250_000_000)
        let afterReconciliation = await engine.currentSnapshot()
        XCTAssertEqual(afterReconciliation.sessions.map(\.threadID), ["root"])
        XCTAssertEqual(afterReconciliation.counts.working, 1)
        XCTAssertEqual(afterReconciliation.counts.ready, 0)
        await supervisor.stop()
    }

    func testInitialReconciliationFoldsActiveSideConversationUsingUniqueCWD() async {
        let root = CodexThread(
            id: "root",
            name: "Root task",
            cwd: "/repo",
            sessionID: "root",
            status: .init(kind: .idle)
        )
        let sideWithoutForkMetadata = CodexThread(
            id: "side",
            name: "Side task",
            cwd: "/repo",
            sessionID: "side",
            ephemeral: true,
            status: .init(kind: .active)
        )
        let session = FakeMonitoringSession(
            threads: [
                "root": root,
                "side": sideWithoutForkMetadata,
            ]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "host-a",
            engine: engine,
            sessionFactory: { session },
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 10, jitterFraction: 0)
        )

        await supervisor.start()
        let becameWorking = await waitUntil {
            let snapshot = await engine.currentSnapshot()
            return snapshot.sessions.map(\.threadID) == ["root"]
                && snapshot.counts.working == 1
                && snapshot.counts.ready == 0
        }
        XCTAssertTrue(becameWorking)
        await supervisor.stop()
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private actor FakeMonitoringSession: CodexMonitoringSession {
    private let threads: [String: CodexThread]
    private let accountResponse: CodexAccountResponse
    private let rateLimitsResponse: CodexRateLimitsResponse?
    private var unsubscribed: [String] = []
    private var events: [CodexMonitoringEvent] = []
    private var eventWaiter:
        CheckedContinuation<CodexMonitoringEvent?, Error>?

    init(
        threads: [String: CodexThread],
        account: CodexAccountResponse = .init(
            account: nil,
            requiresOpenAIAuth: false
        ),
        rateLimits: CodexRateLimitsResponse? = nil
    ) {
        self.threads = threads
        accountResponse = account
        rateLimitsResponse = rateLimits
    }

    func connectAndInitialize() async throws {}

    func loadedThreads(
        cursor: String?,
        limit: Int
    ) async throws -> CodexLoadedThreadsResponse {
        .init(data: threads.keys.sorted())
    }

    func readThread(id: String) async throws -> CodexThread {
        guard let thread = threads[id] else {
            throw CodexProtocolError.malformedResponse(method: "thread/read")
        }
        return thread
    }

    func unsubscribe(threadID: String) async throws {
        unsubscribed.append(threadID)
    }

    func account() async throws -> CodexAccountResponse {
        accountResponse
    }

    func rateLimits() async throws -> CodexRateLimitsResponse? {
        rateLimitsResponse
    }

    func nextEvent() async throws -> CodexMonitoringEvent? {
        if !events.isEmpty {
            return events.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            eventWaiter = continuation
        }
    }

    func close() async {
        eventWaiter?.resume(returning: nil)
        eventWaiter = nil
    }

    func push(_ event: CodexMonitoringEvent) {
        if let eventWaiter {
            self.eventWaiter = nil
            eventWaiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    func unsubscribedIDs() -> [String] {
        unsubscribed
    }
}

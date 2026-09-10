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

    func testIncludesStandaloneCLIRootOutsideDaemonLoadedSet() async throws {
        let pipeline = CodexThread(
            id: "pipeline-root",
            name: "pipeline - in depth",
            cwd: "/projects/opsd-fail",
            sessionID: "pipeline-root",
            status: .init(kind: .notLoaded),
            source: .string("cli")
        )
        let session = FakeMonitoringSession(
            threads: [
                "daemon-root": CodexThread(
                    id: "daemon-root",
                    name: "Daemon task",
                    sessionID: "daemon-root",
                    status: .init(kind: .idle)
                ),
                pipeline.id: pipeline,
            ],
            loadedIDs: ["daemon-root"],
            listedThreads: [pipeline],
            latestTurnStatuses: [pipeline.id: .inProgress]
        )
        let discovery = FakeStandaloneCodexSessionDiscovery(
            threadIDs: [pipeline.id]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "dcc-cpu",
            engine: engine,
            sessionFactory: { session },
            standaloneSessionDiscovery: discovery,
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let populated = await waitUntil {
            await engine.currentSnapshot().sessions.count == 2
        }
        XCTAssertTrue(populated)
        let snapshot = await engine.currentSnapshot()
        let standalone = try XCTUnwrap(
            snapshot.sessions.first { $0.threadID == pipeline.id }
        )
        XCTAssertEqual(standalone.name, "pipeline - in depth")
        XCTAssertEqual(standalone.status, .working)
        XCTAssertEqual(standalone.workingDirectoryName, "opsd-fail")
        let unsubscribed = await session.unsubscribedIDs()
        XCTAssertEqual(unsubscribed, ["daemon-root"])
        await supervisor.stop()
    }

    func testWriterLockedRootOverridesDaemonLocalNotLoadedStatus() async {
        let external = CodexThread(
            id: "external-root",
            name: "pipeline - in depth",
            sessionID: "external-root",
            status: .init(kind: .notLoaded),
            source: .string("cli")
        )
        let session = FakeMonitoringSession(
            threads: [external.id: external],
            loadedIDs: [external.id],
            listedThreads: [external],
            latestTurnStatuses: [external.id: .inProgress]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "dcc-cpu",
            engine: engine,
            sessionFactory: { session },
            standaloneSessionDiscovery: FakeStandaloneCodexSessionDiscovery(
                threadIDs: [external.id]
            ),
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let working = await waitUntil {
            let snapshot = await engine.currentSnapshot()
            return snapshot.sessions.count == 1
                && snapshot.sessions.first?.threadID == external.id
                && snapshot.sessions.first?.status == .working
        }
        XCTAssertTrue(working)
        await supervisor.stop()
    }

    func testCompletedStandaloneCLIRootIsReady() async throws {
        let external = CodexThread(
            id: "external-root",
            name: "launch script tuning",
            sessionID: "external-root",
            status: .init(kind: .notLoaded),
            source: .string("cli")
        )
        let session = FakeMonitoringSession(
            threads: [external.id: external],
            loadedIDs: [],
            listedThreads: [external],
            latestTurnStatuses: [external.id: .completed]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "dcc-cpu",
            engine: engine,
            sessionFactory: { session },
            standaloneSessionDiscovery: FakeStandaloneCodexSessionDiscovery(
                threadIDs: [external.id]
            ),
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let populated = await waitUntil {
            await engine.currentSnapshot().sessions.first?.threadID == external.id
        }
        XCTAssertTrue(populated)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.sessions.first?.status, .ready)
        await supervisor.stop()
    }

    func testStandaloneDiscoveryFailureKeepsDaemonTaskAndReportsIssue() async {
        let session = FakeMonitoringSession(
            threads: [
                "daemon-root": CodexThread(
                    id: "daemon-root",
                    name: "Daemon task",
                    sessionID: "daemon-root",
                    status: .init(kind: .idle)
                ),
            ]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "dcc-cpu",
            engine: engine,
            sessionFactory: { session },
            standaloneSessionDiscovery: FailingStandaloneDiscovery(),
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let populated = await waitUntil {
            let snapshot = await engine.currentSnapshot()
            return snapshot.sessions.map(\.threadID) == ["daemon-root"]
                && snapshot.issues.contains {
                    $0.id == "dcc-cpu:codex:standaloneDiscovery"
                }
        }
        XCTAssertTrue(populated)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["daemon-root"])
        XCTAssertEqual(snapshot.issues.first?.kind, .compatibility)
        XCTAssertEqual(
            snapshot.issues.first?.message,
            "Standalone task discovery failed."
        )
        await supervisor.stop()
    }

    func testUnsupportedStandaloneDiscoveryKeepsDaemonTaskWithoutIssue() async {
        let session = FakeMonitoringSession(
            threads: [
                "daemon-root": CodexThread(
                    id: "daemon-root",
                    name: "Daemon task",
                    sessionID: "daemon-root",
                    status: .init(kind: .idle)
                ),
            ]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "remote-mac",
            engine: engine,
            sessionFactory: { session },
            standaloneSessionDiscovery: UnsupportedStandaloneDiscovery(),
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let populated = await waitUntil {
            await engine.currentSnapshot().sessions.map(\.threadID)
                == ["daemon-root"]
        }
        XCTAssertTrue(populated)
        let snapshot = await engine.currentSnapshot()
        XCTAssertTrue(snapshot.issues.isEmpty)
        await supervisor.stop()
    }

    func testUnsubscribesBeforeStandaloneDiscoveryCompletes() async {
        let session = FakeMonitoringSession(
            threads: [
                "daemon-root": CodexThread(
                    id: "daemon-root",
                    name: "Daemon task",
                    sessionID: "daemon-root",
                    status: .init(kind: .idle)
                ),
            ]
        )
        let discovery = GatedStandaloneDiscovery()
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "dcc-cpu",
            engine: engine,
            sessionFactory: { session },
            standaloneSessionDiscovery: discovery,
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 60, jitterFraction: 0)
        )

        await supervisor.start()
        let unsubscribedWhileDiscoveryWasBlocked = await waitUntil {
            let unsubscribed = await session.unsubscribedIDs()
            let discoveryIsWaiting = await discovery.isWaiting()
            return unsubscribed == ["daemon-root"] && discoveryIsWaiting
        }
        XCTAssertTrue(unsubscribedWhileDiscoveryWasBlocked)
        await discovery.release()
        await supervisor.stop()
    }

    func testStandaloneStatusFailureRetainsLastKnownWorkingState() async {
        let external = CodexThread(
            id: "external-root",
            name: "pipeline - in depth",
            sessionID: "external-root",
            status: .init(kind: .notLoaded),
            source: .string("cli")
        )
        let session = FakeMonitoringSession(
            threads: [external.id: external],
            loadedIDs: [],
            listedThreads: [external],
            latestTurnStatuses: [external.id: .inProgress]
        )
        let engine = MonitoringEngine()
        let supervisor = ClusterSupervisor(
            hostID: "dcc-cpu",
            engine: engine,
            sessionFactory: { session },
            standaloneSessionDiscovery: FakeStandaloneCodexSessionDiscovery(
                threadIDs: [external.id]
            ),
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 0.1, jitterFraction: 0)
        )

        await supervisor.start()
        let initiallyWorking = await waitUntil {
            await engine.currentSnapshot().sessions.first?.status == .working
        }
        XCTAssertTrue(initiallyWorking)
        await session.setFailingLatestTurnStatusIDs([external.id])
        let reportedFailure = await waitUntil {
            await engine.currentSnapshot().issues.contains {
                $0.id == "dcc-cpu:codex:standaloneDiscovery"
            }
        }

        XCTAssertTrue(reportedFailure)
        let afterFailure = await engine.currentSnapshot()
        XCTAssertEqual(afterFailure.sessions.first?.threadID, external.id)
        XCTAssertEqual(afterFailure.sessions.first?.status, .working)

        let degradedAfterRepeatedFailure = await waitUntil {
            let snapshot = await engine.currentSnapshot()
            return snapshot.sessions.first?.threadID == external.id
                && snapshot.sessions.first?.status == .ready
        }
        XCTAssertTrue(degradedAfterRepeatedFailure)
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

    func testTransientThreadReadFailureRetainsEnumeratedSession() async {
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
            hostID: "host-a",
            engine: engine,
            sessionFactory: { session },
            reconnectPolicy: .init(delays: [10], jitterFraction: 0),
            reconcilePolicy: .init(interval: 0.1, jitterFraction: 0)
        )

        await supervisor.start()
        let initiallyVisible = await waitUntil {
            await engine.currentSnapshot().sessions.map(\.threadID) == ["root"]
        }
        XCTAssertTrue(initiallyVisible)
        await session.setFailingReadIDs(["root"])
        try? await Task.sleep(for: .milliseconds(250))

        let afterFailure = await engine.currentSnapshot()
        XCTAssertEqual(afterFailure.sessions.map(\.threadID), ["root"])
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
    private let loadedIDs: [String]
    private let listedThreads: [CodexThread]
    private let latestTurnStatuses: [String: CodexTurnStatus]
    private let accountResponse: CodexAccountResponse
    private let rateLimitsResponse: CodexRateLimitsResponse?
    private var failingReadIDs: Set<String> = []
    private var failingLatestTurnStatusIDs: Set<String> = []
    private var unsubscribed: [String] = []
    private var events: [CodexMonitoringEvent] = []
    private var eventWaiter:
        CheckedContinuation<CodexMonitoringEvent?, Error>?

    init(
        threads: [String: CodexThread],
        loadedIDs: [String]? = nil,
        listedThreads: [CodexThread]? = nil,
        latestTurnStatuses: [String: CodexTurnStatus] = [:],
        account: CodexAccountResponse = .init(
            account: nil,
            requiresOpenAIAuth: false
        ),
        rateLimits: CodexRateLimitsResponse? = nil
    ) {
        self.threads = threads
        self.loadedIDs = loadedIDs ?? threads.keys.sorted()
        self.listedThreads = listedThreads ?? Array(threads.values)
        self.latestTurnStatuses = latestTurnStatuses
        accountResponse = account
        rateLimitsResponse = rateLimits
    }

    func connectAndInitialize() async throws {}

    func loadedThreads(
        cursor: String?,
        limit: Int
    ) async throws -> CodexLoadedThreadsResponse {
        .init(data: loadedIDs)
    }

    func listThreads(
        cursor: String?,
        limit: Int
    ) async throws -> CodexThreadListResponse {
        .init(data: listedThreads)
    }

    func readThread(id: String) async throws -> CodexThread {
        guard !failingReadIDs.contains(id), let thread = threads[id] else {
            throw CodexProtocolError.malformedResponse(method: "thread/read")
        }
        return thread
    }

    func latestTurnStatus(threadID: String) async throws -> CodexTurnStatus? {
        guard !failingLatestTurnStatusIDs.contains(threadID) else {
            throw CodexProtocolError.malformedResponse(
                method: "thread/turns/list"
            )
        }
        return latestTurnStatuses[threadID]
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

    func setFailingReadIDs(_ identifiers: Set<String>) {
        failingReadIDs = identifiers
    }

    func setFailingLatestTurnStatusIDs(_ identifiers: Set<String>) {
        failingLatestTurnStatusIDs = identifiers
    }
}

private struct FakeStandaloneCodexSessionDiscovery:
    StandaloneCodexSessionDiscovering {
    let threadIDs: Set<String>

    func activeThreadIDs() async throws -> Set<String> {
        threadIDs
    }
}

private struct FailingStandaloneDiscovery:
    StandaloneCodexSessionDiscovering {
    func activeThreadIDs() async throws -> Set<String> {
        throw FakeStandaloneDiscoveryError.failed
    }
}

private struct UnsupportedStandaloneDiscovery:
    StandaloneCodexSessionDiscovering {
    func activeThreadIDs() async throws -> Set<String> {
        throw StandaloneCodexSessionDiscoveryError.unsupported
    }
}

private actor GatedStandaloneDiscovery: StandaloneCodexSessionDiscovering {
    private var continuation: CheckedContinuation<Set<String>, Never>?

    func activeThreadIDs() async throws -> Set<String> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func release() {
        continuation?.resume(returning: [])
        continuation = nil
    }
}

private enum FakeStandaloneDiscoveryError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Standalone task discovery failed."
    }
}

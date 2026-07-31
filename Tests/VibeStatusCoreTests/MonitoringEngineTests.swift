import Foundation
import XCTest
@testable import VibeStatusCore

final class MonitoringEngineTests: XCTestCase {
    func testMergesHostsAndDropsSessionsImmediatelyOnDisconnect() async {
        let engine = MonitoringEngine()
        let date = Date(timeIntervalSince1970: 10)
        await engine.replaceHost(
            .init(
                hostID: "host-a",
                sessions: [
                    .init(
                        hostID: "host-a",
                        threadID: "a",
                        name: "A",
                        updatedAt: date,
                        status: .ready
                    ),
                ]
            )
        )
        await engine.replaceHost(
            .init(
                hostID: "host-b",
                sessions: [
                    .init(
                        hostID: "host-b",
                        threadID: "b",
                        name: "B",
                        updatedAt: date,
                        status: .working
                    ),
                ]
            )
        )

        var snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.counts, .init(needsAttention: 0, working: 1, ready: 1))

        await engine.markHostDisconnected(
            hostID: "host-b",
            message: "Connection lost",
            at: date
        )
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.sessions.map(\.hostID), ["host-a"])
        XCTAssertEqual(snapshot.issues.first?.kind, .disconnected)
    }

    func testSnapshotStreamYieldsInitialAndReplacementValues() async {
        let engine = MonitoringEngine()
        let stream = await engine.snapshots()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, .empty)

        await engine.replaceHost(
            .init(
                hostID: "host-a",
                sessions: [
                    .init(
                        hostID: "host-a",
                        threadID: "a",
                        name: "A",
                        updatedAt: .distantPast,
                        status: .ready
                    ),
                ]
            )
        )
        let replacement = await iterator.next()
        XCTAssertEqual(replacement?.counts.ready, 1)
    }

    func testMergesCodexAndClaudeSourcesOnTheSameHost() async {
        let engine = MonitoringEngine()
        let date = Date(timeIntervalSince1970: 10)
        await engine.replaceHost(
            .init(
                hostID: "host-a",
                agent: .codex,
                sessions: [
                    .init(
                        hostID: "host-a",
                        agent: .codex,
                        threadID: "codex",
                        name: "Codex",
                        updatedAt: date,
                        status: .working
                    ),
                ]
            )
        )
        await engine.replaceHost(
            .init(
                hostID: "host-a",
                agent: .claudeCode,
                sessions: [
                    .init(
                        hostID: "host-a",
                        agent: .claudeCode,
                        threadID: "claude",
                        name: "Claude",
                        updatedAt: date,
                        status: .needsAttention
                    ),
                ]
            )
        )

        var snapshot = await engine.currentSnapshot()
        XCTAssertEqual(Set(snapshot.sessions.map(\.agent)), [.codex, .claudeCode])
        XCTAssertEqual(
            snapshot.counts,
            .init(needsAttention: 1, working: 1, ready: 0)
        )

        await engine.markHostDisconnected(
            hostID: "host-a",
            agent: .claudeCode,
            message: "Claude status unavailable",
            at: date
        )
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.sessions.map(\.agent), [.codex])
        XCTAssertEqual(snapshot.issues.map(\.agent), [.claudeCode])
    }

    func testReconnectAndReconcilePolicyEdges() {
        let reconnect = ReconnectPolicy()
        XCTAssertEqual(reconnect.delay(forFailureCount: 1, jitterUnit: 0), 1)
        XCTAssertEqual(reconnect.delay(forFailureCount: 6, jitterUnit: 0), 30)
        XCTAssertEqual(reconnect.delay(forFailureCount: 99, jitterUnit: 1), 36)
        XCTAssertEqual(reconnect.delay(forFailureCount: 1, jitterUnit: -1), 0.8)

        let reconcile = ReconcilePolicy(interval: 15, jitterFraction: 0.2)
        XCTAssertEqual(reconcile.delay(jitterUnit: -1), 12)
        XCTAssertEqual(reconcile.delay(jitterUnit: 1), 18)
    }
}

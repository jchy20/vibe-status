import Foundation
import XCTest
@testable import VibeStatusCore

final class ClaudeStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_720_000_000)

    func testDecodesHookSnapshotAndProjectsProvider() throws {
        let data = Data(
            """
            [{
              "schema_version": 1,
              "session_id": "claude-session",
              "name": "Implement the parser",
              "cwd": "/work/repository",
              "status": "needsAttention",
              "updated_at": 1720000000
            }]
            """.utf8
        )
        let records = try JSONDecoder().decode(
            [ClaudeStatusRecord].self,
            from: data
        )
        let snapshot = ClaudeStatusProjector().hostSnapshot(
            hostID: "host-a",
            records: records,
            now: now
        )

        XCTAssertEqual(snapshot.agent, .claudeCode)
        XCTAssertEqual(snapshot.sessions.first?.agent, .claudeCode)
        XCTAssertEqual(snapshot.sessions.first?.threadID, "claude-session")
        XCTAssertEqual(snapshot.sessions.first?.name, "Implement the parser")
        XCTAssertEqual(snapshot.sessions.first?.workingDirectoryName, "repository")
        XCTAssertEqual(snapshot.sessions.first?.status, .needsAttention)
    }

    func testDropsStaleFutureAndUnsupportedRecords() {
        let projector = ClaudeStatusProjector(maximumAge: 60)
        let records = [
            record(id: "visible", updatedAt: now.timeIntervalSince1970),
            record(id: "stale", updatedAt: now.timeIntervalSince1970 - 61),
            record(id: "future", updatedAt: now.timeIntervalSince1970 + 61),
            ClaudeStatusRecord(
                schemaVersion: 2,
                sessionID: "unsupported",
                status: .ready,
                updatedAt: now.timeIntervalSince1970
            ),
        ]

        let snapshot = projector.hostSnapshot(
            hostID: "host-a",
            records: records,
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["visible"])
    }

    func testProjectsFiveHourAndWeeklyUsage() throws {
        let data = Data(
            """
            {
              "sessions": [],
              "usage": {
                "schema_version": 1,
                "five_hour": {
                  "used_percentage": 23.5,
                  "resets_at": 1720003600
                },
                "seven_day": {
                  "used_percentage": 41.2,
                  "resets_at": 1720600000
                },
                "updated_at": 1720000000
              }
            }
            """.utf8
        )
        let payload = try JSONDecoder().decode(ClaudeStatusPayload.self, from: data)
        let snapshot = ClaudeStatusProjector().hostSnapshot(
            hostID: "host-a",
            records: payload.sessions,
            usage: payload.usage,
            now: now
        )

        XCTAssertEqual(snapshot.usage.map(\.windowDurationMinutes), [300, 10_080])
        XCTAssertEqual(snapshot.usage.map(\.usedPercentage), [23.5, 41.2])
        XCTAssertEqual(snapshot.usage.map(\.remainingPercentage), [76.5, 58.8])
        XCTAssertEqual(Set(snapshot.usage.compactMap(\.accountScopeID)).count, 1)
        XCTAssertTrue(snapshot.usage.allSatisfy { $0.agent == .claudeCode })
    }

    func testDeduplicatesSharedClaudeQuotaAcrossHosts() async {
        let usage = ClaudeUsageRecord(
            fiveHour: .init(
                usedPercentage: 23,
                resetsAt: now.timeIntervalSince1970 + 3_600
            ),
            sevenDay: .init(
                usedPercentage: 41,
                resetsAt: now.timeIntervalSince1970 + 600_000
            ),
            updatedAt: now.timeIntervalSince1970
        )
        let projector = ClaudeStatusProjector()
        let engine = MonitoringEngine()
        await engine.replaceHost(
            projector.hostSnapshot(
                hostID: "host-a",
                records: [],
                usage: usage,
                now: now
            )
        )
        await engine.replaceHost(
            projector.hostSnapshot(
                hostID: "host-b",
                records: [],
                usage: usage,
                now: now
            )
        )

        let dashboardUsage = await engine.currentSnapshot().usage
        XCTAssertEqual(dashboardUsage.count, 2)
        XCTAssertEqual(
            Set(dashboardUsage.map(\.windowDurationMinutes)),
            [300, 10_080]
        )
    }

    func testKeepsPartialClaudeQuotaHostScoped() {
        let usage = ClaudeUsageRecord(
            sevenDay: .init(
                usedPercentage: 41,
                resetsAt: now.timeIntervalSince1970 + 600_000
            ),
            updatedAt: now.timeIntervalSince1970
        )
        let snapshot = ClaudeStatusProjector().hostSnapshot(
            hostID: "host-a",
            records: [],
            usage: usage,
            now: now
        )

        XCTAssertEqual(snapshot.usage.count, 1)
        XCTAssertNil(snapshot.usage.first?.accountScopeID)
    }

    func testUsesNewestRecordForDuplicateSession() {
        let records = [
            record(
                id: "same",
                name: "Old",
                status: .working,
                updatedAt: now.timeIntervalSince1970 - 1
            ),
            record(
                id: "same",
                name: "New",
                status: .ready,
                updatedAt: now.timeIntervalSince1970
            ),
        ]

        let snapshot = ClaudeStatusProjector().hostSnapshot(
            hostID: "host-a",
            records: records,
            now: now
        )

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.name, "New")
        XCTAssertEqual(snapshot.sessions.first?.status, .ready)
    }

    func testSupervisorPublishesClaudeSnapshot() async {
        let loader = FakeClaudeStatusLoader(
            records: [
                record(
                    id: "claude",
                    status: .working,
                    updatedAt: Date().timeIntervalSince1970
                ),
            ]
        )
        let engine = MonitoringEngine()
        let supervisor = ClaudeStatusSupervisor(
            hostID: "host-a",
            engine: engine,
            loader: loader,
            pollInterval: 60
        )

        await supervisor.start()
        let populated = await waitUntil {
            await engine.currentSnapshot().sessions.first?.agent == .claudeCode
        }
        XCTAssertTrue(populated)
        await supervisor.stop()
    }

    private func record(
        id: String,
        name: String? = nil,
        status: TaskDisplayStatus = .ready,
        updatedAt: TimeInterval
    ) -> ClaudeStatusRecord {
        ClaudeStatusRecord(
            sessionID: id,
            name: name,
            cwd: "/work/repository",
            status: status,
            updatedAt: updatedAt
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor FakeClaudeStatusLoader: ClaudeStatusLoading {
    let records: [ClaudeStatusRecord]

    init(records: [ClaudeStatusRecord]) {
        self.records = records
    }

    func load() async throws -> ClaudeStatusPayload {
        ClaudeStatusPayload(sessions: records)
    }
}

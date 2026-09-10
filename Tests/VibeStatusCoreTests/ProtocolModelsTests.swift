import Foundation
import XCTest
@testable import VibeStatusCore

final class ProtocolModelsTests: XCTestCase {
    func testDecodesLoadedThreadIdentifiersFromCodex0145Shape() throws {
        let response = try JSONDecoder().decode(
            CodexLoadedThreadsResponse.self,
            from: Data(#"{"data":["one","two"],"nextCursor":"page-2"}"#.utf8)
        )

        XCTAssertEqual(response.data, ["one", "two"])
        XCTAssertEqual(response.nextCursor, "page-2")
    }

    func testRejectsMalformedLoadedThreadPageInsteadOfReportingNoTasks() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CodexLoadedThreadsResponse.self,
                from: Data(#"{"data":{"unexpected":true}}"#.utf8)
            )
        )
    }

    func testDecodesActiveStatusAndUnknownFields() throws {
        let thread = try JSONDecoder().decode(
            CodexThread.self,
            from: Data(
                #"""
                {
                  "id":"root",
                  "sessionId":"root",
                  "forkedFromId":"parent",
                  "ephemeral":true,
                  "status":{
                    "type":"active",
                    "activeFlags":["waitingOnApproval"],
                    "newFlag":true
                  },
                  "updatedAt":1720000000000,
                  "futureObject":{"anything":"goes"}
                }
                """#.utf8
            )
        )

        XCTAssertEqual(thread.status.kind, .active)
        XCTAssertEqual(thread.status.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(thread.forkedFromID, "parent")
        XCTAssertTrue(thread.ephemeral)
        let timestamp = try XCTUnwrap(thread.updatedAt).timeIntervalSince1970
        XCTAssertEqual(timestamp, 1_720_000_000, accuracy: 0.001)
    }

    func testMissingEphemeralMetadataUsesPersistentRootDefaults() throws {
        let thread = try JSONDecoder().decode(
            CodexThread.self,
            from: Data(#"{"id":"root","status":{"type":"idle"}}"#.utf8)
        )

        XCTAssertNil(thread.forkedFromID)
        XCTAssertFalse(thread.ephemeral)
    }

    func testPreservesUnknownStatusInsteadOfFailingDecode() throws {
        let status = try JSONDecoder().decode(
            CodexThreadStatus.self,
            from: Data(#"{"type":"pausedByScheduler","newData":123}"#.utf8)
        )
        XCTAssertEqual(status.kind, .unknown("pausedByScheduler"))
    }

    func testDecodesLatestPersistedTurnWithoutItems() throws {
        let response = try JSONDecoder().decode(
            CodexThreadTurnsResponse.self,
            from: Data(
                #"{"data":[{"id":"turn-1","status":"inProgress","items":[]}]}"#.utf8
            )
        )

        XCTAssertEqual(response.data.first?.id, "turn-1")
        XCTAssertEqual(response.data.first?.status, .inProgress)
    }

    func testMapsKnownThreadNotifications() throws {
        let notification = JSONRPCNotification(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string("thread-1"),
                "status": .object([
                    "type": .string("active"),
                    "activeFlags": .array([.string("waitingOnUserInput")]),
                ]),
            ])
        )

        let event = try CodexMonitoringEvent(notification: notification)
        XCTAssertEqual(
            event,
            .statusChanged(
                threadID: "thread-1",
                status: .init(
                    kind: .active,
                    activeFlags: ["waitingOnUserInput"]
                )
            )
        )
    }
}

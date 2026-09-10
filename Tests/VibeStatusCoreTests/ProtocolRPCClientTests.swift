import Foundation
import XCTest
@testable import VibeStatusCore

final class ProtocolRPCClientTests: XCTestCase {
    func testInitializationAndLoadedListAlwaysSendParamsObject() async throws {
        let transport = AutoRespondingTransport()
        let client = CodexRPCClient(
            transport: transport,
            clientInformation: .init(version: "1.0"),
            requestTimeout: 1
        )

        try await client.connectAndInitialize()
        let page = try await client.loadedThreads(cursor: nil, limit: 100)
        XCTAssertEqual(page.data, ["root-1"])

        let sent = await transport.sentMessages()
        let initializeRequest = try XCTUnwrap(sent.first { text in
            text.contains(#""method":"initialize""#)
        })
        let initializeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(initializeRequest.utf8))
                as? [String: Any]
        )
        let initializeParams = try XCTUnwrap(
            initializeObject["params"] as? [String: Any]
        )
        let capabilities = try XCTUnwrap(
            initializeParams["capabilities"] as? [String: Any]
        )
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
        XCTAssertEqual(capabilities["requestAttestation"] as? Bool, false)
        XCTAssertFalse(
            (capabilities["optOutNotificationMethods"] as? [String])?.isEmpty
                ?? true
        )
        XCTAssertFalse(
            (initializeParams["optOutNotificationMethods"] as? [String])?.isEmpty
                ?? true
        )

        let loadedRequest = try XCTUnwrap(sent.first { text in
            text.contains(#""method":"thread/loaded/list""#)
        })
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(loadedRequest.utf8))
                as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual((params["limit"] as? NSNumber)?.intValue, 100)
        await client.close()
    }

    func testCorrelatesOutOfOrderResponses() async throws {
        let transport = ManualTextTransport()
        let client = CodexRPCClient(
            transport: transport,
            clientInformation: .init(version: "1.0"),
            requestTimeout: 1
        )
        try await transport.connect()

        // Exercise correlation through a fresh client connection after arranging
        // initialization's response manually.
        let connectTask = Task { try await client.connectAndInitialize() }
        let initialize = await transport.waitForSentMessage()
        let initializeID = try requestID(from: initialize)
        await transport.push(
            try JSONRPCCodec().encodeResponseForTest(
                id: initializeID,
                result: .object([:])
            )
        )
        try await connectTask.value

        let first = Task {
            try await client.request(
                .readThread,
                params: .object(["threadId": .string("one")])
            )
        }
        let second = Task {
            try await client.request(
                .readThread,
                params: .object(["threadId": .string("two")])
            )
        }
        let requestA = try await transport.waitForSentRequest()
        let requestB = try await transport.waitForSentRequest()
        let idA = try requestID(from: requestA)
        let idB = try requestID(from: requestB)

        await transport.push(
            try JSONRPCCodec().encodeResponseForTest(
                id: idB,
                result: .string("second")
            )
        )
        await transport.push(
            try JSONRPCCodec().encodeResponseForTest(
                id: idA,
                result: .string("first")
            )
        )
        let values = try await (first.value, second.value)
        XCTAssertEqual(Set([values.0.stringValue, values.1.stringValue]), ["first", "second"])
        await client.close()
    }

    func testReadsAccountRateLimits() async throws {
        let transport = AutoRespondingTransport()
        let client = CodexRPCClient(
            transport: transport,
            clientInformation: .init(version: "1.0"),
            requestTimeout: 1
        )

        try await client.connectAndInitialize()
        let account = try await client.account()
        let response = try await client.rateLimits()
        let limits = try XCTUnwrap(response)
        let usage = limits.usageSnapshots(
            hostID: "host-a",
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(account.usageScopeID, "chatgpt:user@example.com")
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.usedPercentage, 37)
        XCTAssertEqual(usage.first?.windowDurationMinutes, 10_080)
        await client.close()
    }

    func testReadsLatestPersistedTurnStatusWithoutLoadingItems() async throws {
        let transport = AutoRespondingTransport()
        let client = CodexRPCClient(
            transport: transport,
            clientInformation: .init(version: "1.0"),
            requestTimeout: 1
        )

        try await client.connectAndInitialize()
        let status = try await client.latestTurnStatus(threadID: "external-root")
        XCTAssertEqual(status, .inProgress)

        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(sent.first { text in
            text.contains(#""method":"thread/turns/list""#)
        })
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.utf8))
                as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "external-root")
        XCTAssertEqual((params["limit"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
        XCTAssertEqual(params["itemsView"] as? String, "notLoaded")
        await client.close()
    }

    func testListsPersistedInteractiveThreadsForStandaloneIntersection() async throws {
        let transport = AutoRespondingTransport()
        let client = CodexRPCClient(
            transport: transport,
            clientInformation: .init(version: "1.0"),
            requestTimeout: 1
        )

        try await client.connectAndInitialize()
        let page = try await client.listThreads(cursor: nil, limit: 100)
        XCTAssertEqual(page.data.map(\.id), ["external-root"])

        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(sent.first { text in
            text.contains(#""method":"thread/list""#)
        })
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.utf8))
                as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["sortKey"] as? String, "recency_at")
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
        XCTAssertEqual(params["useStateDbOnly"] as? Bool, true)
        XCTAssertEqual((params["sourceKinds"] as? [Any])?.count, 0)
        await client.close()
    }

    private func requestID(from text: String) throws -> JSONRPCID {
        guard case let .request(id, _, _) = try JSONRPCCodec().decode(text) else {
            throw TestFailure.unexpectedMessage
        }
        return id
    }
}

private enum TestFailure: Error {
    case unexpectedMessage
}

private extension JSONRPCCodec {
    func encodeResponseForTest(
        id: JSONRPCID,
        result: JSONValue
    ) throws -> String {
        let idValue: Any
        switch id {
        case let .integer(value): idValue = value
        case let .string(value): idValue = value
        }
        let resultData = try JSONEncoder().encode(result)
        let resultObject = try JSONSerialization.jsonObject(
            with: resultData,
            options: [.fragmentsAllowed]
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["id": idValue, "result": resultObject],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

private actor AutoRespondingTransport: CodexTextTransport {
    private var sent: [String] = []
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String?, Error>?

    func connect() async throws {}

    func send(_ text: String) async throws {
        sent.append(text)
        guard case let .request(id, method, _) = try JSONRPCCodec().decode(text) else {
            return
        }
        let result: JSONValue
        if method == CodexClientMethod.loadedThreads.rawValue {
            result = .object(["data": .array([.string("root-1")])])
        } else if method == CodexClientMethod.listThreads.rawValue {
            result = .object([
                "data": .array([
                    .object([
                        "id": .string("external-root"),
                        "name": .string("pipeline - in depth"),
                        "sessionId": .string("external-root"),
                        "status": .object(["type": .string("notLoaded")]),
                    ]),
                ]),
            ])
        } else if method == CodexClientMethod.listThreadTurns.rawValue {
            result = .object([
                "data": .array([
                    .object([
                        "id": .string("turn-1"),
                        "status": .string("inProgress"),
                    ]),
                ]),
            ])
        } else if method == CodexClientMethod.readAccount.rawValue {
            result = .object([
                "account": .object([
                    "type": .string("chatgpt"),
                    "email": .string("User@Example.com"),
                    "planType": .string("pro"),
                ]),
                "requiresOpenaiAuth": .bool(true),
            ])
        } else if method == CodexClientMethod.readRateLimits.rawValue {
            result = .object([
                "rateLimits": .object([
                    "limitId": .string("codex"),
                    "primary": .object([
                        "usedPercent": .number(37),
                        "windowDurationMins": .number(10_080),
                        "resetsAt": .number(1_800_000_000),
                    ]),
                ]),
            ])
        } else {
            result = .object([:])
        }
        enqueue(try JSONRPCCodec().encodeResponseForTest(id: id, result: result))
    }

    func receive() async throws -> String? {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func sentMessages() -> [String] {
        sent
    }

    private func enqueue(_ text: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: text)
        } else {
            incoming.append(text)
        }
    }
}

private actor ManualTextTransport: CodexTextTransport {
    private var sent: [String] = []
    private var sentWaiters: [CheckedContinuation<String, Never>] = []
    private var incoming: [String] = []
    private var receiveWaiter: CheckedContinuation<String?, Error>?

    func connect() async throws {}

    func send(_ text: String) async throws {
        if let waiter = sentWaiters.first {
            sentWaiters.removeFirst()
            waiter.resume(returning: text)
        } else {
            sent.append(text)
        }
    }

    func receive() async throws -> String? {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
        }
    }

    func close() async {
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func push(_ text: String) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: text)
        } else {
            incoming.append(text)
        }
    }

    func waitForSentMessage() async -> String {
        if !sent.isEmpty {
            return sent.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            sentWaiters.append(continuation)
        }
    }

    func waitForSentRequest() async throws -> String {
        while true {
            let text = await waitForSentMessage()
            if case .request = try JSONRPCCodec().decode(text) {
                return text
            }
        }
    }
}

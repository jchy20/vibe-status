import Foundation

/// A text-message transport for the Codex app-server WebSocket. The concrete
/// implementation owns framing, masking, limits, and the underlying SSH pipes.
public protocol CodexTextTransport: Sendable {
    func connect() async throws
    func send(_ text: String) async throws
    func receive() async throws -> String?
    func close() async
}

public enum CodexClientMethod: String, Sendable, CaseIterable {
    case initialize
    case initialized
    case listThreads = "thread/list"
    case loadedThreads = "thread/loaded/list"
    case readThread = "thread/read"
    case listThreadTurns = "thread/turns/list"
    case unsubscribeThread = "thread/unsubscribe"
    case readAccount = "account/read"
    case readRateLimits = "account/rateLimits/read"
}

public struct CodexClientInformation: Sendable, Hashable, Codable {
    public let name: String
    public let title: String
    public let version: String

    public init(
        name: String = "vibe_status",
        title: String = "Vibe Status",
        version: String
    ) {
        self.name = name
        self.title = title
        self.version = version
    }
}

public protocol CodexMonitoringSession: Sendable {
    func connectAndInitialize() async throws
    func listThreads(cursor: String?, limit: Int) async throws -> CodexThreadListResponse
    func loadedThreads(cursor: String?, limit: Int) async throws -> CodexLoadedThreadsResponse
    func readThread(id: String) async throws -> CodexThread
    func latestTurnStatus(threadID: String) async throws -> CodexTurnStatus?
    func unsubscribe(threadID: String) async throws
    func account() async throws -> CodexAccountResponse
    func rateLimits() async throws -> CodexRateLimitsResponse?
    func nextEvent() async throws -> CodexMonitoringEvent?
    func close() async
}

public extension CodexMonitoringSession {
    func listThreads(
        cursor: String?,
        limit: Int
    ) async throws -> CodexThreadListResponse {
        throw CodexProtocolError.unsupportedOutboundMethod(
            CodexClientMethod.listThreads.rawValue
        )
    }

    func latestTurnStatus(threadID: String) async throws -> CodexTurnStatus? {
        throw CodexProtocolError.unsupportedOutboundMethod(
            CodexClientMethod.listThreadTurns.rawValue
        )
    }

    func account() async throws -> CodexAccountResponse {
        .init(account: nil, requiresOpenAIAuth: false)
    }

    func rateLimits() async throws -> CodexRateLimitsResponse? { nil }
}

public actor CodexRPCClient: CodexMonitoringSession {
    public static let defaultOptOutNotificationMethods: [String] = [
        "item/agentMessage/delta",
        "item/commandExecution/outputDelta",
        "item/fileChange/outputDelta",
        "item/mcpToolCall/progress",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "item/started",
        "item/completed",
        "turn/diff/updated",
        "turn/plan/updated",
        "turn/started",
        "turn/completed",
    ]

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let transport: any CodexTextTransport
    private let codec: JSONRPCCodec
    private let clientInformation: CodexClientInformation
    private let optOutNotificationMethods: [String]
    private let requestTimeout: TimeInterval

    private var nextRequestID: Int64 = 1
    private var pending: [JSONRPCID: PendingRequest] = [:]
    private var receiveTask: Task<Void, Never>?
    private var notificationQueue: [JSONRPCNotification] = []
    private var notificationWaiter:
        CheckedContinuation<JSONRPCNotification?, Error>?
    private var terminalError: (any Error)?
    private var connected = false

    public init(
        transport: any CodexTextTransport,
        clientInformation: CodexClientInformation,
        optOutNotificationMethods: [String] = CodexRPCClient.defaultOptOutNotificationMethods,
        requestTimeout: TimeInterval = 10,
        codec: JSONRPCCodec = .init()
    ) {
        self.transport = transport
        self.clientInformation = clientInformation
        self.optOutNotificationMethods = optOutNotificationMethods
        self.requestTimeout = requestTimeout
        self.codec = codec
    }

    deinit {
        receiveTask?.cancel()
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CodexProtocolError.disconnected)
        }
        notificationWaiter?.resume(throwing: CodexProtocolError.disconnected)
    }

    public func connectAndInitialize() async throws {
        guard !connected else { return }
        terminalError = nil
        try await transport.connect()
        connected = true
        startReceiveLoop()

        let params = try JSONValue.encode(
            InitializeParams(
                clientInfo: clientInformation,
                capabilities: .init(
                    experimentalApi: true,
                    requestAttestation: false,
                    optOutNotificationMethods: optOutNotificationMethods
                ),
                optOutNotificationMethods: optOutNotificationMethods
            )
        )
        _ = try await request(.initialize, params: params)
        try await notify(.initialized, params: .object([:]))
    }

    public func loadedThreads(
        cursor: String?,
        limit: Int = 100
    ) async throws -> CodexLoadedThreadsResponse {
        var params: [String: JSONValue] = [
            "limit": .number(Double(limit)),
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        // Codex 0.145.0 rejects a missing `params` field for this method, so an
        // object is always sent even if a future caller requests no options.
        let result = try await request(.loadedThreads, params: .object(params))
        do {
            return try result.decode(CodexLoadedThreadsResponse.self)
        } catch {
            throw CodexProtocolError.malformedResponse(
                method: CodexClientMethod.loadedThreads.rawValue
            )
        }
    }

    public func listThreads(
        cursor: String?,
        limit: Int = 100
    ) async throws -> CodexThreadListResponse {
        var params: [String: JSONValue] = [
            "limit": .number(Double(limit)),
            "sortKey": .string("recency_at"),
            "sortDirection": .string("desc"),
            // Standalone presence is established independently from writer
            // locks, so indexed metadata is sufficient and avoids a rollout
            // scan-and-repair on every reconciliation.
            "useStateDbOnly": .bool(true),
            // An empty list asks Codex for all interactive source kinds while
            // keeping spawned subagents out of the persisted root catalog.
            "sourceKinds": .array([]),
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        let result = try await request(.listThreads, params: .object(params))
        do {
            return try result.decode(CodexThreadListResponse.self)
        } catch {
            throw CodexProtocolError.malformedResponse(
                method: CodexClientMethod.listThreads.rawValue
            )
        }
    }

    public func readThread(id: String) async throws -> CodexThread {
        let result = try await request(
            .readThread,
            params: .object([
                "threadId": .string(id),
                "includeTurns": .bool(false),
            ])
        )
        if let wrapped = try? result.decode(CodexThreadReadResponse.self) {
            return wrapped.thread
        }
        if let direct = try? result.decode(CodexThread.self) {
            return direct
        }
        throw CodexProtocolError.malformedResponse(
            method: CodexClientMethod.readThread.rawValue
        )
    }

    public func latestTurnStatus(
        threadID: String
    ) async throws -> CodexTurnStatus? {
        let result = try await request(
            .listThreadTurns,
            params: .object([
                "threadId": .string(threadID),
                "limit": .number(1),
                "sortDirection": .string("desc"),
                "itemsView": .string("notLoaded"),
            ])
        )
        do {
            return try result.decode(CodexThreadTurnsResponse.self).data.first?.status
        } catch {
            throw CodexProtocolError.malformedResponse(
                method: CodexClientMethod.listThreadTurns.rawValue
            )
        }
    }

    public func unsubscribe(threadID: String) async throws {
        _ = try await request(
            .unsubscribeThread,
            params: .object(["threadId": .string(threadID)])
        )
    }

    public func account() async throws -> CodexAccountResponse {
        let result = try await request(
            .readAccount,
            params: .object(["refreshToken": .bool(false)])
        )
        do {
            return try result.decode(CodexAccountResponse.self)
        } catch {
            throw CodexProtocolError.malformedResponse(
                method: CodexClientMethod.readAccount.rawValue
            )
        }
    }

    public func rateLimits() async throws -> CodexRateLimitsResponse? {
        let result = try await request(
            .readRateLimits,
            params: .object([:])
        )
        do {
            return try result.decode(CodexRateLimitsResponse.self)
        } catch {
            throw CodexProtocolError.malformedResponse(
                method: CodexClientMethod.readRateLimits.rawValue
            )
        }
    }

    public func nextEvent() async throws -> CodexMonitoringEvent? {
        while let notification = try await nextNotification() {
            return try CodexMonitoringEvent(notification: notification)
        }
        return nil
    }

    public func close() async {
        guard connected || receiveTask != nil else { return }
        connected = false
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        finish(with: CodexProtocolError.disconnected)
    }

    /// Exposed for protocol tests and diagnostic tooling. Production callers
    /// should use the typed methods above.
    public func request(
        _ method: CodexClientMethod,
        params: JSONValue
    ) async throws -> JSONValue {
        guard method != .initialized else {
            throw CodexProtocolError.unsupportedOutboundMethod(method.rawValue)
        }
        guard connected else { throw CodexProtocolError.disconnected }

        let id = JSONRPCID.integer(nextRequestID)
        nextRequestID += 1
        let text = try codec.encodeRequest(
            id: id,
            method: method.rawValue,
            params: params
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutNanoseconds = UInt64(
                    max(0, requestTimeout) * 1_000_000_000
                )
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(id: id)
                }
                pending[id] = PendingRequest(
                    method: method.rawValue,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    await self?.transmit(text, for: id)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(id: id)
            }
        }
    }

    public func notify(
        _ method: CodexClientMethod,
        params: JSONValue
    ) async throws {
        guard method == .initialized else {
            throw CodexProtocolError.unsupportedOutboundMethod(method.rawValue)
        }
        guard connected else { throw CodexProtocolError.disconnected }
        try await transport.send(
            codec.encodeNotification(method: method.rawValue, params: params)
        )
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self, transport] in
            do {
                while !Task.isCancelled,
                      let text = try await transport.receive() {
                    await self?.handleIncoming(text)
                }
                if !Task.isCancelled {
                    await self?.transportEnded(CodexProtocolError.disconnected)
                }
            } catch {
                if !Task.isCancelled {
                    await self?.transportEnded(error)
                }
            }
        }
    }

    private func transmit(_ text: String, for id: JSONRPCID) async {
        do {
            try await transport.send(text)
        } catch {
            failRequest(id: id, error: error)
        }
    }

    private func handleIncoming(_ text: String) async {
        do {
            switch try codec.decode(text) {
            case let .response(id, result, error):
                guard let request = pending.removeValue(forKey: id) else { return }
                request.timeoutTask.cancel()
                if let error {
                    request.continuation.resume(throwing: error)
                } else if let result {
                    request.continuation.resume(returning: result)
                } else {
                    request.continuation.resume(
                        throwing: CodexProtocolError.missingResult(method: request.method)
                    )
                }
            case let .notification(notification):
                yield(notification)
            case let .request(id, _, _):
                // This observer never accepts approvals or user input. A server
                // request is rejected explicitly instead of being silently held.
                let response = try codec.encodeErrorResponse(
                    id: id,
                    error: .init(code: -32601, message: "Method not supported by observer")
                )
                try await transport.send(response)
            }
        } catch {
            transportEnded(error)
        }
    }

    private func timeOut(id: JSONRPCID) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: CodexProtocolError.timedOut(method: request.method)
        )
    }

    private func cancelRequest(id: JSONRPCID) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func failRequest(id: JSONRPCID, error: any Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func nextNotification() async throws -> JSONRPCNotification? {
        if !notificationQueue.isEmpty {
            return notificationQueue.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                precondition(
                    notificationWaiter == nil,
                    "CodexRPCClient supports one notification consumer"
                )
                notificationWaiter = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelNotificationWaiter()
            }
        }
    }

    private func yield(_ notification: JSONRPCNotification) {
        if let waiter = notificationWaiter {
            notificationWaiter = nil
            waiter.resume(returning: notification)
        } else {
            notificationQueue.append(notification)
            if notificationQueue.count > 256 {
                notificationQueue.removeFirst(notificationQueue.count - 256)
            }
        }
    }

    private func cancelNotificationWaiter() {
        guard let waiter = notificationWaiter else { return }
        notificationWaiter = nil
        waiter.resume(throwing: CancellationError())
    }

    private func transportEnded(_ error: any Error) {
        guard connected else { return }
        connected = false
        receiveTask?.cancel()
        receiveTask = nil
        finish(with: error)
    }

    private func finish(with error: any Error) {
        terminalError = error
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
        if let waiter = notificationWaiter {
            notificationWaiter = nil
            waiter.resume(throwing: error)
        }
    }
}

private struct InitializeParams: Encodable {
    let clientInfo: CodexClientInformation
    let capabilities: InitializeCapabilities
    /// Codex 0.145 used this top-level field. Keep sending it while newer
    /// servers read the nested capability so the passive-observer contract is
    /// preserved across both protocol generations.
    let optOutNotificationMethods: [String]
}

private struct InitializeCapabilities: Encodable {
    let experimentalApi: Bool
    let requestAttestation: Bool
    let optOutNotificationMethods: [String]
}

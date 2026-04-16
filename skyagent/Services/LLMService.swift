import Foundation
import Network

// MARK: - LLM Service (OpenAI compatible)

actor LLMService {
    private static let firstTokenTimeout: TimeInterval = 90
    private static let streamIdleTimeout: TimeInterval = 45
    private static let overallResponseTimeout: TimeInterval = 1800

    private var settings: AppSettings
    private let session: URLSession
    private var currentTask: Task<CompletionResponse, Error>?
    private var currentTaskID: UUID?

    /// 网络连接状态
    private(set) var isNetworkAvailable: Bool = true
    /// 连续失败计数
    private var consecutiveFailures: Int = 0
    /// 最大自动重试次数
    private let maxAutoRetries = 3
    /// 重试基础延迟（秒）
    private let retryBaseDelay: TimeInterval = 2.0

    init(settings: AppSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = Self.overallResponseTimeout
        config.timeoutIntervalForResource = Self.overallResponseTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func updateSettings(_ s: AppSettings) {
        self.settings = s
    }

    func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        currentTaskID = nil
    }

    // MARK: - Network Monitoring

    /// 检测网络是否可用（通过连接 API 域名检测）
    func checkNetworkStatus() async -> Bool {
        isNetworkAvailable = await hasViableNetworkPath()
        return isNetworkAvailable
    }

    /// 判断错误是否为网络相关
    private func isConnectivityError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // NSURLError 域的常见网络错误
        let networkCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff,
        ]
        return nsError.domain == NSURLErrorDomain && networkCodes.contains(nsError.code)
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    /// 指数退避重试延迟
    private func retryDelay(for attempt: Int) -> TimeInterval {
        return retryBaseDelay * pow(2.0, Double(attempt))
    }

    // MARK: - Chat Completion

    struct ChatMessage: Codable {
        let role: String
        let content: String
        let imageDataURL: String?
        let toolCallId: String?
        let toolCalls: [ToolCallRecord]?

        init(role: String, content: String, imageDataURL: String? = nil, toolCallId: String? = nil, toolCalls: [ToolCallRecord]? = nil) {
            self.role = role
            self.content = content
            self.imageDataURL = imageDataURL
            self.toolCallId = toolCallId
            self.toolCalls = toolCalls
        }
    }

    typealias StreamCallback = @Sendable (String) async -> Void
    typealias ToolCallHintCallback = @Sendable (ToolCallRecord) async -> Void

    struct CompletionResponse {
        let content: String
        let toolCalls: [ToolCallRecord]
    }

    func complete(
        messages: [ChatMessage],
        toolDefinitions: [[String: Any]]? = nil,
        trackAsCurrentTask: Bool = true,
        traceContext: TraceContext? = nil,
        extraLogMetadata: [String: LogValue] = [:],
        onToolCallHint: ToolCallHintCallback? = nil,
        onDelta: @escaping StreamCallback
    ) async throws -> CompletionResponse {
        guard !settings.apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }
        guard let requestURL = URL(string: settings.apiURL) else {
            throw LLMError.invalidResponse
        }
        if await hasViableNetworkPath() == false {
            isNetworkAvailable = false
            throw LLMError.networkUnavailable
        }

        var messagesPayload = messages.map { messagePayload(for: $0) }

        if !settings.systemPrompt.isEmpty {
            messagesPayload.insert(["role": "system", "content": settings.systemPrompt], at: 0)
        }

        var body: [String: Any] = [
            "model": settings.model,
            "messages": messagesPayload,
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature,
            "stream": true
        ]

        if let toolDefinitions, !toolDefinitions.isEmpty {
            body["tools"] = toolDefinitions
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Self.overallResponseTimeout
        let requestStartedAt = Date()
        await LoggerService.shared.log(
            category: .llm,
            event: "llm_request_started",
            traceContext: traceContext,
            status: .started,
            summary: "开始请求模型",
            metadata: [
                "model": .string(settings.model),
                "message_count": .int(messages.count),
                "payload_message_count": .int(messagesPayload.count),
                "tool_definition_count": .int(toolDefinitions?.count ?? 0),
                "system_prompt_length": .int(settings.systemPrompt.count)
            ].merging(extraLogMetadata) { _, new in new }
        )

        let requestTask = Task<CompletionResponse, Error> {
            let timeoutState = StreamTimeoutState(
                requestStartedAt: requestStartedAt,
                firstTokenTimeout: Self.firstTokenTimeout,
                streamIdleTimeout: Self.streamIdleTimeout
            )
            let processingTask = Task<CompletionResponse, Error> {
            do {
                let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                do {
                    let result = try await session.bytes(for: request)
                    bytes = result.0
                    response = result.1
                    isNetworkAvailable = true
                } catch {
                    if isConnectivityError(error) {
                        isNetworkAvailable = false
                        throw LLMError.networkUnavailable
                    }
                    if isTimeoutError(error) {
                        throw LLMError.requestTimedOut
                    }
                    throw error
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LLMError.invalidResponse
                }

                if httpResponse.statusCode != 200 {
                    let body = try? await String.collectingErrorBody(from: bytes)
                    if [408, 504, 524].contains(httpResponse.statusCode) {
                        throw LLMError.requestTimedOut
                    }
                    throw LLMError.httpError(httpResponse.statusCode, body ?? "")
                }

                var toolCallsBuffer: [Int: PartialToolCall] = [:]
                var emittedToolCallHintIndexes: Set<Int> = []
                var collectedContent = ""
                var firstResponseLogged = false

                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    await timeoutState.markActivity()

                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { break }

                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any] else {
                        continue
                    }

                    if !firstResponseLogged,
                       (delta["content"] as? String)?.isEmpty == false || delta["tool_calls"] != nil {
                        firstResponseLogged = true
                        await timeoutState.markFirstTokenReceived()
                        await LoggerService.shared.log(
                            category: .llm,
                            event: "llm_first_token_received",
                            traceContext: traceContext,
                            status: .progress,
                            durationMs: Date().timeIntervalSince(requestStartedAt) * 1000,
                            summary: "收到模型首个增量",
                            metadata: extraLogMetadata
                        )
                    }

                    if let content = delta["content"] as? String {
                        collectedContent += content
                        await onDelta(content)
                    }

                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for tc in toolCalls {
                            let index = tc["index"] as? Int ?? 0
                            if toolCallsBuffer[index] == nil {
                                toolCallsBuffer[index] = PartialToolCall()
                            }
                            if let id = tc["id"] as? String {
                                toolCallsBuffer[index]?.id = id
                            }
                            if let fn = tc["function"] as? [String: Any] {
                                if let name = fn["name"] as? String {
                                    toolCallsBuffer[index]?.name = name
                                }
                                if let args = fn["arguments"] as? String {
                                    toolCallsBuffer[index]?.arguments += args
                                }
                            }

                            if !emittedToolCallHintIndexes.contains(index),
                               let partial = toolCallsBuffer[index],
                               let id = partial.id,
                               let name = partial.name {
                                emittedToolCallHintIndexes.insert(index)
                                await onToolCallHint?(ToolCallRecord(id: id, name: name, arguments: partial.arguments))
                            }
                        }
                    }
                }

                let toolCalls = toolCallsBuffer.keys.sorted().compactMap { idx -> ToolCallRecord? in
                    guard let tc = toolCallsBuffer[idx],
                          let id = tc.id,
                          let name = tc.name else { return nil }
                    return ToolCallRecord(id: id, name: name, arguments: tc.arguments)
                }

                if !toolCalls.isEmpty {
                    await LoggerService.shared.log(
                        category: .llm,
                        event: "llm_tool_calls_ready",
                        traceContext: traceContext,
                        status: .progress,
                        durationMs: Date().timeIntervalSince(requestStartedAt) * 1000,
                        summary: "模型已返回工具调用",
                        metadata: [
                            "tool_call_count": .int(toolCalls.count)
                        ].merging(extraLogMetadata) { _, new in new }
                    )
                }

                await LoggerService.shared.log(
                    category: .llm,
                    event: "llm_stream_finished",
                    traceContext: traceContext,
                    status: .succeeded,
                    durationMs: Date().timeIntervalSince(requestStartedAt) * 1000,
                    summary: "模型流式响应完成",
                    metadata: [
                        "content_length": .int(collectedContent.count),
                        "tool_call_count": .int(toolCalls.count)
                    ].merging(extraLogMetadata) { _, new in new }
                )

                return CompletionResponse(content: collectedContent, toolCalls: toolCalls)
            } catch {
                await LoggerService.shared.log(
                    level: .error,
                    category: .llm,
                    event: "llm_request_failed",
                    traceContext: traceContext,
                    status: .failed,
                    durationMs: Date().timeIntervalSince(requestStartedAt) * 1000,
                    summary: "模型请求失败",
                    metadata: LogMetadataBuilder.failure(
                        errorKind: logErrorKind(for: error),
                        recoveryAction: .retry,
                        isUserVisible: false,
                        extra: [
                            "error_message": .string(error.localizedDescription)
                        ]
                    ).merging(extraLogMetadata) { _, new in new }
                )
                throw error
            }
            }

            let timeoutWatcher = Task<Void, Never> {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let timeoutError = await timeoutState.triggeredTimeoutIfNeeded() {
                        processingTask.cancel()
                        await LoggerService.shared.log(
                            level: .warn,
                            category: .llm,
                            event: "llm_timeout_triggered",
                            traceContext: traceContext,
                            status: .timeout,
                            durationMs: Date().timeIntervalSince(requestStartedAt) * 1000,
                            summary: timeoutError.timeoutSummary,
                            metadata: [
                                "timeout_stage": .string(timeoutError.timeoutStage),
                                "timeout_seconds": .int(Int(timeoutError.timeoutThreshold))
                            ].merging(extraLogMetadata) { _, new in new }
                        )
                        return
                    }
                }
            }

            defer {
                timeoutWatcher.cancel()
            }

            do {
                return try await processingTask.value
            } catch {
                if let timeoutError = await timeoutState.consumeTriggeredTimeout() {
                    throw timeoutError
                }
                throw error
            }
        }

        let taskID = UUID()
        if trackAsCurrentTask {
            currentTask?.cancel()
            currentTask = requestTask
            currentTaskID = taskID
        }

        defer {
            if trackAsCurrentTask, currentTaskID == taskID {
                currentTask = nil
                currentTaskID = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await requestTask.value
        } onCancel: {
            requestTask.cancel()
        }
    }

    private func logErrorKind(for error: Error) -> LogErrorKind {
        if case LLMError.requestTimedOut = error {
            return .timeout
        }
        if case LLMError.firstTokenTimedOut = error {
            return .timeout
        }
        if case LLMError.streamIdleTimedOut = error {
            return .timeout
        }
        if case LLMError.networkUnavailable = error {
            return .network
        }
        if case LLMError.connectionLost = error {
            return .network
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return .network
            default:
                break
            }
        }
        return .unknown
    }

    func chat(
        messages: [ChatMessage],
        toolDefinitions: [[String: Any]]? = nil,
        trackAsCurrentTask: Bool = true,
        traceContext: TraceContext? = nil,
        extraLogMetadata: [String: LogValue] = [:],
        onDelta: @escaping StreamCallback
    ) async throws {
        _ = try await complete(
            messages: messages,
            toolDefinitions: toolDefinitions,
            trackAsCurrentTask: trackAsCurrentTask,
            traceContext: traceContext,
            extraLogMetadata: extraLogMetadata,
            onDelta: onDelta
        )
    }

    private func messagePayload(for message: ChatMessage) -> [String: Any] {
        var payload: [String: Any] = ["role": message.role]

        if let imageDataURL = message.imageDataURL, message.role == "user" {
            payload["content"] = [
                [
                    "type": "text",
                    "text": message.content.isEmpty ? "请分析这张图片。" : message.content
                ],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": imageDataURL
                    ]
                ]
            ]
        } else {
            payload["content"] = message.content
        }

        if let toolCallId = message.toolCallId {
            payload["tool_call_id"] = toolCallId
        }

        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            payload["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ]
            }
        }

        return payload
    }

    private func hasViableNetworkPath(timeout: TimeInterval = 1.0) async -> Bool {
        await withCheckedContinuation { continuation in
            final class FinishState {
                let lock = NSLock()
                var finished = false
            }

            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "SkyAgent.NetworkProbe")
            let state = FinishState()

            let finish: @Sendable (Bool) -> Void = { value in
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.finished else { return }
                state.finished = true
                monitor.cancel()
                continuation.resume(returning: value)
            }

            monitor.pathUpdateHandler = { path in
                switch path.status {
                case .satisfied:
                    finish(true)
                case .unsatisfied:
                    finish(false)
                case .requiresConnection:
                    finish(false)
                @unknown default:
                    finish(true)
                }
            }

            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(true)
            }
        }
    }
}

private struct PartialToolCall: Sendable {
    var id: String?
    var name: String?
    var arguments: String = ""

    nonisolated init(id: String? = nil, name: String? = nil, arguments: String = "") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Errors

enum LLMError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case networkUnavailable
    case connectionLost
    case requestTimedOut
    case firstTokenTimedOut(timeout: TimeInterval)
    case streamIdleTimedOut(timeout: TimeInterval)
    case maxRetriesExceeded(underlying: Error)

    var timeoutStage: String {
        switch self {
        case .firstTokenTimedOut:
            return "first_token"
        case .streamIdleTimedOut:
            return "stream_idle"
        case .requestTimedOut:
            return "request"
        default:
            return "unknown"
        }
    }

    var timeoutThreshold: TimeInterval {
        switch self {
        case .firstTokenTimedOut(let timeout),
             .streamIdleTimedOut(let timeout):
            return timeout
        case .requestTimedOut:
            return 0
        default:
            return 0
        }
    }

    var timeoutSummary: String {
        switch self {
        case .firstTokenTimedOut:
            return "等待模型首个响应超时"
        case .streamIdleTimedOut:
            return "模型流式输出长时间无新数据"
        case .requestTimedOut:
            return "模型请求超时"
        default:
            return "模型请求异常"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "请先在设置中配置 API Key"
        case .invalidResponse: return "无效响应"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .networkUnavailable: return "网络连接不可用，请检查网络设置"
        case .connectionLost: return "网络连接已断开，正在尝试重连..."
        case .requestTimedOut: return "请求超时。通常是模型生成内容过大、工具参数过长，或服务响应过慢导致的，并不一定是本地断网。"
        case .firstTokenTimedOut: return "等待模型首个响应超时。服务端长时间没有返回首个 token。"
        case .streamIdleTimedOut: return "模型开始响应后长时间没有新的流式数据，已按超时处理。"
        case .maxRetriesExceeded(let underlying): return "多次重试失败：\(underlying.localizedDescription)"
        }
    }
}

private actor StreamTimeoutState {
    private let requestStartedAt: Date
    private let firstTokenTimeout: TimeInterval
    private let streamIdleTimeout: TimeInterval

    private var firstTokenReceived = false
    private var lastActivityAt: Date
    private var triggeredTimeout: LLMError?

    init(
        requestStartedAt: Date,
        firstTokenTimeout: TimeInterval,
        streamIdleTimeout: TimeInterval
    ) {
        self.requestStartedAt = requestStartedAt
        self.firstTokenTimeout = firstTokenTimeout
        self.streamIdleTimeout = streamIdleTimeout
        self.lastActivityAt = requestStartedAt
    }

    func markActivity(at date: Date = Date()) {
        lastActivityAt = date
    }

    func markFirstTokenReceived(at date: Date = Date()) {
        firstTokenReceived = true
        lastActivityAt = date
    }

    func triggeredTimeoutIfNeeded(now: Date = Date()) -> LLMError? {
        if let triggeredTimeout {
            return triggeredTimeout
        }

        if !firstTokenReceived {
            if now.timeIntervalSince(requestStartedAt) >= firstTokenTimeout {
                let error = LLMError.firstTokenTimedOut(timeout: firstTokenTimeout)
                triggeredTimeout = error
                return error
            }
            return nil
        }

        if now.timeIntervalSince(lastActivityAt) >= streamIdleTimeout {
            let error = LLMError.streamIdleTimedOut(timeout: streamIdleTimeout)
            triggeredTimeout = error
            return error
        }

        return nil
    }

    func consumeTriggeredTimeout() -> LLMError? {
        let timeout = triggeredTimeout
        triggeredTimeout = nil
        return timeout
    }
}

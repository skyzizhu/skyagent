import Foundation
import Network

// MARK: - LLM Service (OpenAI compatible)

actor LLMService {
    private static let initialResponseTimeout: TimeInterval = 300
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
        config.timeoutIntervalForRequest = Self.initialResponseTimeout
        config.timeoutIntervalForResource = Self.overallResponseTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldUsePipelining = true
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
        let toolCallId: String?
        let toolCalls: [ToolCallRecord]?

        init(role: String, content: String, toolCallId: String? = nil, toolCalls: [ToolCallRecord]? = nil) {
            self.role = role
            self.content = content
            self.toolCallId = toolCallId
            self.toolCalls = toolCalls
        }
    }

    typealias StreamCallback = @Sendable (String) async -> Void

    struct CompletionResponse {
        let content: String
        let toolCalls: [ToolCallRecord]
    }

    func complete(messages: [ChatMessage], toolDefinitions: [[String: Any]]? = nil, onDelta: @escaping StreamCallback) async throws -> CompletionResponse {
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

        var body: [String: Any] = [
            "model": settings.model,
            "messages": messages.map { messagePayload(for: $0) },
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature,
            "stream": true
        ]

        if let toolDefinitions, !toolDefinitions.isEmpty {
            body["tools"] = toolDefinitions
        }

        // System prompt
        if !settings.systemPrompt.isEmpty {
            var msgs: [[String: Any]] = [["role": "system", "content": settings.systemPrompt]]
            let existingMsgs = body["messages"] as! [[String: Any]]
            for msg in existingMsgs {
                msgs.append(msg)
            }
            body["messages"] = msgs
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Self.initialResponseTimeout

        let requestTask = Task<CompletionResponse, Error> {
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
            var collectedContent = ""

            for try await line in bytes.lines {
                try Task.checkCancellation()

                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else {
                    continue
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
                    }
                }
            }

            let toolCalls = toolCallsBuffer.keys.sorted().compactMap { idx -> ToolCallRecord? in
                guard let tc = toolCallsBuffer[idx],
                      let id = tc.id,
                      let name = tc.name else { return nil }
                return ToolCallRecord(id: id, name: name, arguments: tc.arguments)
            }

            return CompletionResponse(content: collectedContent, toolCalls: toolCalls)
        }

        let taskID = UUID()
        currentTask?.cancel()
        currentTask = requestTask
        currentTaskID = taskID

        defer {
            if currentTaskID == taskID {
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

    func chat(messages: [ChatMessage], toolDefinitions: [[String: Any]]? = nil, onDelta: @escaping StreamCallback) async throws {
        _ = try await complete(messages: messages, toolDefinitions: toolDefinitions, onDelta: onDelta)
    }

    private func messagePayload(for message: ChatMessage) -> [String: Any] {
        var payload: [String: Any] = [
            "role": message.role,
            "content": message.content
        ]

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
            let queue = DispatchQueue(label: "MiniAgent.NetworkProbe")
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

private struct PartialToolCall {
    var id: String?
    var name: String?
    var arguments: String = ""
}

// MARK: - Errors

enum LLMError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case networkUnavailable
    case connectionLost
    case requestTimedOut
    case maxRetriesExceeded(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "请先在设置中配置 API Key"
        case .invalidResponse: return "无效响应"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .networkUnavailable: return "网络连接不可用，请检查网络设置"
        case .connectionLost: return "网络连接已断开，正在尝试重连..."
        case .requestTimedOut: return "请求超时。通常是模型生成内容过大、工具参数过长，或服务响应过慢导致的，并不一定是本地断网。"
        case .maxRetriesExceeded(let underlying): return "多次重试失败：\(underlying.localizedDescription)"
        }
    }
}

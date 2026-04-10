import Foundation

enum MCPTransportKind: String, Codable, CaseIterable, Sendable {
    case stdio
    case streamableHTTP = "streamable_http"

    var displayName: String {
        switch self {
        case .stdio:
            return "Local stdio"
        case .streamableHTTP:
            return "Streamable HTTP"
        }
    }
}

enum MCPAuthorizationKind: String, Codable, CaseIterable, Sendable {
    case none
    case bearer
    case customHeader = "custom_header"

    var displayName: String {
        switch self {
        case .none:
            return "No Auth"
        case .bearer:
            return "Bearer Token"
        case .customHeader:
            return "Custom Header"
        }
    }
}

struct MCPCapabilitySnapshot: Sendable {
    let tools: [MCPListedTool]
    let resources: [MCPListedResource]
    let prompts: [MCPListedPrompt]
}

struct MCPToolMetadataHints: Sendable {
    let title: String?
    let readOnlyHint: Bool?
    let destructiveHint: Bool?
    let idempotentHint: Bool?
    let openWorldHint: Bool?
}

struct MCPListedTool: Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let hints: MCPToolMetadataHints
}

struct MCPListedResource: Sendable {
    let uri: String
    let name: String
    let description: String
    let mimeType: String?
}

struct MCPListedPromptArgument: Sendable {
    let name: String
    let description: String
    let isRequired: Bool
}

struct MCPListedPrompt: Sendable {
    let name: String
    let description: String
    let arguments: [MCPListedPromptArgument]
}

final class MCPConnectionManager: @unchecked Sendable {
    static let shared = MCPConnectionManager()

    private let stdioTransport: MCPStdioTransport
    private let streamableHTTPTransport: MCPStreamableHTTPTransport
    private let keychainStore: MCPKeychainStore

    init(protocolVersion: String = "2025-11-25", keychainStore: MCPKeychainStore? = nil) {
        self.stdioTransport = MCPStdioTransport(protocolVersion: protocolVersion)
        self.keychainStore = keychainStore ?? .shared
        self.streamableHTTPTransport = MCPStreamableHTTPTransport(protocolVersion: protocolVersion, keychainStore: self.keychainStore)
    }

    func inspectServer(_ server: MCPServerConfig) async throws -> MCPCapabilitySnapshot {
        switch server.transportKind {
        case .stdio:
            return try await stdioTransport.inspectServer(server)
        case .streamableHTTP:
            return try await streamableHTTPTransport.inspectServer(server)
        }
    }

    func callTool(
        _ toolName: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        switch server.transportKind {
        case .stdio:
            return try await stdioTransport.callTool(toolName, arguments: arguments, on: server, onProgress: onProgress)
        case .streamableHTTP:
            return try await streamableHTTPTransport.callTool(toolName, arguments: arguments, on: server, onProgress: onProgress)
        }
    }

    func readResource(_ uri: String, on server: MCPServerConfig, onProgress: ((String) -> Void)? = nil) async throws -> String {
        switch server.transportKind {
        case .stdio:
            return try await stdioTransport.readResource(uri, on: server, onProgress: onProgress)
        case .streamableHTTP:
            return try await streamableHTTPTransport.readResource(uri, on: server, onProgress: onProgress)
        }
    }

    func getPrompt(
        _ name: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [String: Any] {
        switch server.transportKind {
        case .stdio:
            return try await stdioTransport.getPrompt(name, arguments: arguments, on: server, onProgress: onProgress)
        case .streamableHTTP:
            return try await streamableHTTPTransport.getPrompt(name, arguments: arguments, on: server, onProgress: onProgress)
        }
    }

    func invalidate(serverID: UUID) async {
        await stdioTransport.invalidate(serverID: serverID)
        await streamableHTTPTransport.invalidate(serverID: serverID)
    }
}

private actor MCPStreamableHTTPTransport {
    private let protocolVersion: String
    private let session: URLSession
    private let keychainStore: MCPKeychainStore
    private var sessionIDs: [UUID: String] = [:]
    private var nextRequestID = 1

    init(protocolVersion: String, keychainStore: MCPKeychainStore) {
        self.protocolVersion = protocolVersion
        self.keychainStore = keychainStore
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    func inspectServer(_ server: MCPServerConfig) async throws -> MCPCapabilitySnapshot {
        try await ensureInitialized(for: server)
        let toolPayload = try await sendRequest(method: "tools/list", params: [:], to: server)
        let resourcePayload = (try? await sendRequest(method: "resources/list", params: [:], to: server)) ?? [:]
        let promptPayload = (try? await sendRequest(method: "prompts/list", params: [:], to: server)) ?? [:]
        return MCPCapabilitySnapshot(
            tools: MCPStdioTransport.parseTools(toolPayload),
            resources: MCPStdioTransport.parseResources(resourcePayload),
            prompts: MCPStdioTransport.parsePrompts(promptPayload)
        )
    }

    func callTool(
        _ toolName: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        onProgress?("正在连接 MCP server")
        try await ensureInitialized(for: server)
        onProgress?("MCP 已连接，正在发送工具调用")
        let payload = try await sendRequest(
            method: "tools/call",
            params: [
                "name": toolName,
                "arguments": arguments
            ],
            to: server
        )
        return MCPStdioTransport.renderToolResult(payload)
    }

    func readResource(_ uri: String, on server: MCPServerConfig, onProgress: ((String) -> Void)? = nil) async throws -> String {
        onProgress?("正在连接 MCP server")
        try await ensureInitialized(for: server)
        onProgress?("MCP 已连接，正在读取 resource")
        let payload = try await sendRequest(
            method: "resources/read",
            params: ["uri": uri],
            to: server
        )
        return MCPStdioTransport.renderResourceResult(payload)
    }

    func getPrompt(
        _ name: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [String: Any] {
        onProgress?("正在连接 MCP server")
        try await ensureInitialized(for: server)
        onProgress?("MCP 已连接，正在解析 prompt")
        return try await sendRequest(
            method: "prompts/get",
            params: [
                "name": name,
                "arguments": arguments
            ],
            to: server
        )
    }

    func invalidate(serverID: UUID) {
        sessionIDs.removeValue(forKey: serverID)
    }

    private func ensureInitialized(for server: MCPServerConfig) async throws {
        if sessionIDs[server.id] != nil {
            return
        }

        let startedAt = Date()
        await LoggerService.shared.log(
            category: .mcp,
            event: "mcp_initialize_started",
            status: .started,
            summary: "开始初始化 MCP HTTP 会话：\(server.name)",
            metadata: [
                "server_name": .string(server.name),
                "transport": .string(server.transportKind.rawValue)
            ]
        )

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "protocolVersion": protocolVersion,
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "SkyAgent",
                        "version": "1.0"
                    ]
                ],
                to: server,
                attachSessionID: false
            )

            _ = try? await sendNotification(
                method: "notifications/initialized",
                params: nil,
                to: server
            )
            await LoggerService.shared.log(
                category: .mcp,
                event: "mcp_initialize_completed",
                status: .succeeded,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: "MCP HTTP 会话初始化完成：\(server.name)",
                metadata: [
                    "server_name": .string(server.name),
                    "transport": .string(server.transportKind.rawValue)
                ]
            )
        } catch {
            await LoggerService.shared.log(
                level: .error,
                category: .mcp,
                event: "mcp_initialize_failed",
                status: .failed,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: "MCP HTTP 会话初始化失败：\(server.name)",
                metadata: [
                    "server_name": .string(server.name),
                    "transport": .string(server.transportKind.rawValue),
                    "error": .string(error.localizedDescription)
                ]
            )
            throw error
        }
    }

    private func sendNotification(
        method: String,
        params: [String: Any]?,
        to server: MCPServerConfig
    ) async throws {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        _ = try await performJSONRequest(payload: payload, to: server, attachSessionID: true, retryOnMissingSession: false)
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        to server: MCPServerConfig,
        attachSessionID: Bool = true
    ) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": makeRequestID(),
            "method": method,
            "params": params
        ]
        return try await performJSONRequest(
            payload: payload,
            to: server,
            attachSessionID: attachSessionID,
            retryOnMissingSession: attachSessionID
        )
    }

    private func makeRequestID() -> Int {
        let requestID = nextRequestID
        nextRequestID &+= 1
        if nextRequestID <= 0 {
            nextRequestID = 1
        }
        return requestID
    }

    private func performJSONRequest(
        payload: [String: Any],
        to server: MCPServerConfig,
        attachSessionID: Bool,
        retryOnMissingSession: Bool
    ) async throws -> [String: Any] {
        try await performJSONRequest(
            payload: payload,
            to: server,
            attachSessionID: attachSessionID,
            retryOnMissingSession: retryOnMissingSession,
            retryAttempt: 0
        )
    }

    private func performJSONRequest(
        payload: [String: Any],
        to server: MCPServerConfig,
        attachSessionID: Bool,
        retryOnMissingSession: Bool,
        retryAttempt: Int
    ) async throws -> [String: Any] {
        let endpoint = try resolvedEndpointURL(for: server)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        applyAuthorization(for: server, to: &request)

        if attachSessionID, let sessionID = sessionIDs[server.id], !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "MCPHTTPTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "MCP HTTP 响应无效。"])
        }

        if let sessionID = httpResponse.value(forHTTPHeaderField: "MCP-Session-Id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            sessionIDs[server.id] = sessionID
        }

        if httpResponse.statusCode == 404, attachSessionID, retryOnMissingSession {
            sessionIDs.removeValue(forKey: server.id)
            try await ensureInitialized(for: server)
            return try await performJSONRequest(
                payload: payload,
                to: server,
                attachSessionID: true,
                retryOnMissingSession: false,
                retryAttempt: retryAttempt
            )
        }

        if shouldRetry(statusCode: httpResponse.statusCode, attempt: retryAttempt) {
            let delayNanoseconds = UInt64((retryAttempt + 1) * 400_000_000)
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return try await performJSONRequest(
                payload: payload,
                to: server,
                attachSessionID: attachSessionID,
                retryOnMissingSession: retryOnMissingSession,
                retryAttempt: retryAttempt + 1
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = body.isEmpty ? "HTTP \(httpResponse.statusCode)" : "HTTP \(httpResponse.statusCode): \(body)"
            throw NSError(domain: "MCPHTTPTransport", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return try parseResponseBody(data, contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"))
    }

    private func resolvedEndpointURL(for server: MCPServerConfig) throws -> URL {
        let trimmed = server.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            throw NSError(domain: "MCPHTTPTransport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Streamable HTTP server 需要有效的 URL。"])
        }
        return url
    }

    private func applyAuthorization(for server: MCPServerConfig, to request: inout URLRequest) {
        for (headerName, value) in server.additionalHeaders {
            let trimmedName = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !trimmedValue.isEmpty else { continue }
            request.setValue(trimmedValue, forHTTPHeaderField: trimmedName)
        }
        for (headerName, value) in keychainStore.additionalSecretHeaders(for: server.id) {
            let trimmedName = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !trimmedValue.isEmpty else { continue }
            request.setValue(trimmedValue, forHTTPHeaderField: trimmedName)
        }

        let token = keychainStore.token(for: server.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? server.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        switch server.authKind {
        case .none:
            return
        case .bearer:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .customHeader:
            let header = server.authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !header.isEmpty else { return }
            request.setValue(token, forHTTPHeaderField: header)
        }
    }

    private func shouldRetry(statusCode: Int, attempt: Int) -> Bool {
        guard attempt < 1 else { return false }
        switch statusCode {
        case 408, 429:
            return true
        case 500...599:
            return true
        default:
            return false
        }
    }

    private func parseResponseBody(_ data: Data, contentType: String?) throws -> [String: Any] {
        let normalizedType = contentType?.lowercased() ?? ""

        if normalizedType.contains("text/event-stream") {
            return try parseSSEPayload(data)
        }

        guard !data.isEmpty else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(domain: "MCPHTTPTransport", code: 3, userInfo: [NSLocalizedDescriptionKey: "MCP HTTP 返回了无法解析的响应：\(raw)"])
        }

        if let errorPayload = json["error"] as? [String: Any] {
            let message = (errorPayload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? String(describing: errorPayload)
            throw NSError(domain: "MCPHTTPTransport", code: errorPayload["code"] as? Int ?? 4, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return json["result"] as? [String: Any] ?? json
    }

    private func parseSSEPayload(_ data: Data) throws -> [String: Any] {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MCPHTTPTransport", code: 5, userInfo: [NSLocalizedDescriptionKey: "SSE 响应无法解码。"])
        }

        let events = raw
            .components(separatedBy: "\n\n")
            .compactMap { block -> [String: Any]? in
                let dataLines = block
                    .components(separatedBy: .newlines)
                    .filter { $0.hasPrefix("data:") }
                    .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                guard !dataLines.isEmpty else { return nil }
                let combined = dataLines.joined(separator: "\n")
                guard let payloadData = combined.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                    return nil
                }
                return json
            }

        guard let message = events.last else {
            throw NSError(domain: "MCPHTTPTransport", code: 6, userInfo: [NSLocalizedDescriptionKey: "未在 SSE 响应中解析到 MCP 数据。"])
        }

        if let errorPayload = message["error"] as? [String: Any] {
            let messageText = (errorPayload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? String(describing: errorPayload)
            throw NSError(domain: "MCPHTTPTransport", code: errorPayload["code"] as? Int ?? 7, userInfo: [NSLocalizedDescriptionKey: messageText])
        }

        return message["result"] as? [String: Any] ?? message
    }
}

private actor MCPStdioTransport {
    let protocolVersion: String
    private let sessionPool: MCPStdioSessionPool

    init(protocolVersion: String) {
        self.protocolVersion = protocolVersion
        self.sessionPool = MCPStdioSessionPool(protocolVersion: protocolVersion)
    }

    func inspectServer(_ server: MCPServerConfig) async throws -> MCPCapabilitySnapshot {
        try await sessionPool.inspectServer(server)
    }

    func callTool(
        _ toolName: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        try await sessionPool.callTool(toolName, arguments: arguments, on: server, onProgress: onProgress)
    }

    func readResource(_ uri: String, on server: MCPServerConfig, onProgress: ((String) -> Void)? = nil) async throws -> String {
        try await sessionPool.readResource(uri, on: server, onProgress: onProgress)
    }

    func getPrompt(
        _ name: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [String: Any] {
        try await sessionPool.getPrompt(name, arguments: arguments, on: server, onProgress: onProgress)
    }

    func invalidate(serverID: UUID) async {
        await sessionPool.invalidate(serverID: serverID)
    }

    nonisolated static func renderToolResult(_ payload: [String: Any]) -> String {
        if let content = payload["content"] as? [[String: Any]] {
            let textItems = content.compactMap { item -> String? in
                guard let type = item["type"] as? String else { return nil }
                if type == "text" {
                    return item["text"] as? String
                }
                return nil
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if !textItems.isEmpty {
                return textItems.joined(separator: "\n\n")
            }
        }

        if let structured = payload["structuredContent"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        return "\(payload)"
    }

    nonisolated static func renderResourceResult(_ payload: [String: Any]) -> String {
        let contents = payload["contents"] as? [[String: Any]] ?? []
        guard !contents.isEmpty else {
            if JSONSerialization.isValidJSONObject(payload),
               let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return "\(payload)"
        }

        let rendered = contents.compactMap { item -> String? in
            let uri = (item["uri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mimeType = (item["mimeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let text = item["text"] as? String {
                var sections: [String] = []
                if !uri.isEmpty { sections.append("URI: \(uri)") }
                if !mimeType.isEmpty { sections.append("MIME: \(mimeType)") }
                sections.append(text)
                return sections.joined(separator: "\n")
            }
            if let blob = item["blob"] as? String {
                var sections: [String] = []
                if !uri.isEmpty { sections.append("URI: \(uri)") }
                if !mimeType.isEmpty { sections.append("MIME: \(mimeType)") }
                sections.append("Blob(base64): \(blob)")
                return sections.joined(separator: "\n")
            }
            return nil
        }

        if !rendered.isEmpty {
            return rendered.joined(separator: "\n\n")
        }
        return "\(payload)"
    }

    nonisolated static func parseTools(_ payload: [String: Any]) -> [MCPListedTool] {
        let tools = payload["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
            return MCPListedTool(
                name: name,
                description: (tool["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "MCP tool",
                inputSchema: tool["inputSchema"] as? [String: Any] ?? [:],
                hints: parseToolHints(tool)
            )
        }
    }

    nonisolated static func parseToolHints(_ tool: [String: Any]) -> MCPToolMetadataHints {
        let annotations = tool["annotations"] as? [String: Any] ?? [:]
        let topLevelTitle = (tool["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotationTitle = (annotations["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = [topLevelTitle, annotationTitle]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .first
        return MCPToolMetadataHints(
            title: title,
            readOnlyHint: annotations["readOnlyHint"] as? Bool,
            destructiveHint: annotations["destructiveHint"] as? Bool,
            idempotentHint: annotations["idempotentHint"] as? Bool,
            openWorldHint: annotations["openWorldHint"] as? Bool
        )
    }

    nonisolated static func parseResources(_ payload: [String: Any]) -> [MCPListedResource] {
        let resources = payload["resources"] as? [[String: Any]] ?? []
        return resources.compactMap { resource -> MCPListedResource? in
            guard let uri = resource["uri"] as? String, !uri.isEmpty else { return nil }
            let fallbackName = uri.components(separatedBy: "/").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = (resource["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmedMimeType = (resource["mimeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return MCPListedResource(
                uri: uri,
                name: trimmedName.isEmpty ? (fallbackName ?? uri) : trimmedName,
                description: (resource["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                mimeType: trimmedMimeType.isEmpty ? nil : trimmedMimeType
            )
        }
    }

    nonisolated static func parsePrompts(_ payload: [String: Any]) -> [MCPListedPrompt] {
        let prompts = payload["prompts"] as? [[String: Any]] ?? []
        return prompts.compactMap { prompt in
            guard let name = prompt["name"] as? String, !name.isEmpty else { return nil }
            let arguments = (prompt["arguments"] as? [[String: Any]] ?? []).compactMap { argument -> MCPListedPromptArgument? in
                guard let argumentName = argument["name"] as? String, !argumentName.isEmpty else { return nil }
                return MCPListedPromptArgument(
                    name: argumentName,
                    description: (argument["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    isRequired: argument["required"] as? Bool ?? false
                )
            }
            return MCPListedPrompt(
                name: name,
                description: (prompt["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                arguments: arguments
            )
        }
    }
}

private actor MCPStdioSessionPool {
    private struct Entry {
        let signature: String
        let channel: MCPStdioChannel
    }

    private let protocolVersion: String
    private var entries: [UUID: Entry] = [:]

    init(protocolVersion: String) {
        self.protocolVersion = protocolVersion
    }

    func inspectServer(_ server: MCPServerConfig) async throws -> MCPCapabilitySnapshot {
        try await perform(on: server) { channel in
            try await channel.inspectServer()
        }
    }

    func callTool(
        _ toolName: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        try await perform(on: server) { channel in
            try await channel.callTool(toolName, arguments: arguments, onProgress: onProgress)
        }
    }

    func readResource(_ uri: String, on server: MCPServerConfig, onProgress: ((String) -> Void)? = nil) async throws -> String {
        try await perform(on: server) { channel in
            try await channel.readResource(uri, onProgress: onProgress)
        }
    }

    func getPrompt(
        _ name: String,
        arguments: [String: Any],
        on server: MCPServerConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [String: Any] {
        try await perform(on: server) { channel in
            try await channel.getPrompt(name, arguments: arguments, onProgress: onProgress)
        }
    }

    func invalidate(serverID: UUID) async {
        guard let entry = entries.removeValue(forKey: serverID) else { return }
        await entry.channel.shutdown()
    }

    private func perform<T>(
        on server: MCPServerConfig,
        action: @escaping (MCPStdioChannel) async throws -> T
    ) async throws -> T {
        let initialChannel = try await channel(for: server)
        do {
            return try await action(initialChannel)
        } catch {
            await initialChannel.shutdown()
            entries.removeValue(forKey: server.id)
            let retryChannel = try await channel(for: server)
            return try await action(retryChannel)
        }
    }

    private func channel(for server: MCPServerConfig) async throws -> MCPStdioChannel {
        let signature = sessionSignature(for: server)
        if let existing = entries[server.id], existing.signature == signature {
            return existing.channel
        }

        if let existing = entries.removeValue(forKey: server.id) {
            await existing.channel.shutdown()
        }

        let channel = try MCPStdioChannel(server: server, protocolVersion: protocolVersion)
        entries[server.id] = Entry(signature: signature, channel: channel)
        return channel
    }

    private func sessionSignature(for server: MCPServerConfig) -> String {
        let environmentSignature = server.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let transportSignature = [
            server.command,
            server.arguments.joined(separator: "\u{1F}"),
            server.workingDirectory,
            environmentSignature
        ].joined(separator: "\u{1E}")
        return transportSignature
    }
}

private actor MCPStdioChannel {
    private let session: MCPStdioSession
    private let protocolVersion: String
    private let serverName: String
    private let transportKind: MCPTransportKind
    private var isInitialized = false
    private var cachedSnapshot: MCPCapabilitySnapshot?
    private var cachedSnapshotDate: Date?

    init(server: MCPServerConfig, protocolVersion: String) throws {
        self.session = try MCPStdioSession(server: server)
        self.protocolVersion = protocolVersion
        self.serverName = server.name
        self.transportKind = server.transportKind
    }

    func inspectServer() async throws -> MCPCapabilitySnapshot {
        if let cachedSnapshot,
           let cachedSnapshotDate,
           Date().timeIntervalSince(cachedSnapshotDate) < 8 {
            return cachedSnapshot
        }

        try await ensureInitialized()
        let toolPayload = try await session.sendRequest(method: "tools/list", params: [:], timeout: 12)
        let resourcePayload = (try? await session.sendRequest(method: "resources/list", params: [:], timeout: 12)) ?? [:]
        let promptPayload = (try? await session.sendRequest(method: "prompts/list", params: [:], timeout: 12)) ?? [:]
        let snapshot = MCPCapabilitySnapshot(
            tools: MCPStdioTransport.parseTools(toolPayload),
            resources: MCPStdioTransport.parseResources(resourcePayload),
            prompts: MCPStdioTransport.parsePrompts(promptPayload)
        )
        cachedSnapshot = snapshot
        cachedSnapshotDate = Date()
        return snapshot
    }

    func callTool(_ toolName: String, arguments: [String: Any], onProgress: ((String) -> Void)? = nil) async throws -> String {
        onProgress?("正在初始化 MCP 会话")
        try await ensureInitialized()
        onProgress?("MCP 已连接，正在等待工具结果")
        let payload = try await session.sendRequest(
            method: "tools/call",
            params: [
                "name": toolName,
                "arguments": arguments
            ],
            timeout: 90,
            onProgress: onProgress
        )
        return MCPStdioTransport.renderToolResult(payload)
    }

    func readResource(_ uri: String, onProgress: ((String) -> Void)? = nil) async throws -> String {
        onProgress?("正在初始化 MCP 会话")
        try await ensureInitialized()
        onProgress?("MCP 已连接，正在等待 resource 内容")
        let payload = try await session.sendRequest(
            method: "resources/read",
            params: ["uri": uri],
            timeout: 45,
            onProgress: onProgress
        )
        return MCPStdioTransport.renderResourceResult(payload)
    }

    func getPrompt(_ name: String, arguments: [String: Any], onProgress: ((String) -> Void)? = nil) async throws -> [String: Any] {
        onProgress?("正在初始化 MCP 会话")
        try await ensureInitialized()
        onProgress?("MCP 已连接，正在等待 prompt 结果")
        return try await session.sendRequest(
            method: "prompts/get",
            params: [
                "name": name,
                "arguments": arguments
            ],
            timeout: 45,
            onProgress: onProgress
        )
    }

    func shutdown() {
        session.shutdown()
    }

    private func ensureInitialized() async throws {
        guard !isInitialized else { return }
        let startedAt = Date()
        await LoggerService.shared.log(
            category: .mcp,
            event: "mcp_initialize_started",
            status: .started,
            summary: "开始初始化 MCP stdio 会话：\(serverName)",
            metadata: [
                "server_name": .string(serverName),
                "transport": .string(transportKind.rawValue)
            ]
        )
        do {
            _ = try await session.initialize(protocolVersion: protocolVersion)
            try session.sendNotification(method: "notifications/initialized", params: nil)
            isInitialized = true
            await LoggerService.shared.log(
                category: .mcp,
                event: "mcp_initialize_completed",
                status: .succeeded,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: "MCP stdio 会话初始化完成：\(serverName)",
                metadata: [
                    "server_name": .string(serverName),
                    "transport": .string(transportKind.rawValue)
                ]
            )
        } catch {
            await LoggerService.shared.log(
                level: .error,
                category: .mcp,
                event: "mcp_initialize_failed",
                status: .failed,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: "MCP stdio 会话初始化失败：\(serverName)",
                metadata: [
                    "server_name": .string(serverName),
                    "transport": .string(transportKind.rawValue),
                    "error": .string(error.localizedDescription)
                ]
            )
            throw error
        }
    }
}

private final class MCPStdioSession: @unchecked Sendable {
    private let process: Process
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let ioQueue = DispatchQueue(label: "com.skyagent.mcp.stdio.io", qos: .userInitiated)
    private let lock = NSLock()
    nonisolated(unsafe) private var nextRequestID = 1
    nonisolated(unsafe) private var buffer = Data()
    nonisolated(unsafe) private var pendingContinuations: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    nonisolated(unsafe) private var pendingTimeoutTasks: [Int: Task<Void, Never>] = [:]
    nonisolated(unsafe) private var stderrBuffer = Data()
    nonisolated(unsafe) private var activeProgressHandler: ((String) -> Void)?
    nonisolated(unsafe) private var activeRequestMethod: String?
    nonisolated(unsafe) private var activeRequestStartedAt: Date?
    nonisolated(unsafe) private var lastProgressMessage: String?
    nonisolated(unsafe) private var lastProgressAt: Date?

    nonisolated init(server: MCPServerConfig) throws {
        self.process = Process()
        self.inputPipe = Pipe()
        self.outputPipe = Pipe()
        self.errorPipe = Pipe()

        let command = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw NSError(domain: "MCPStdioSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "MCP server command 不能为空。"])
        }

        let compatibilityBinPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".skyagent/bin")
            .path
        let environment = ProcessExecutionEnvironment.shared.resolvedEnvironment(
            additional: server.environment,
            prependPathEntries: [compatibilityBinPath]
        )
        let launchArguments = Self.effectiveArguments(for: server, command: command)

        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            process.arguments = launchArguments
        } else if let resolvedCommand = ProcessExecutionEnvironment.shared.resolveCommandPath(command, environment: environment) {
            process.executableURL = URL(fileURLWithPath: resolvedCommand)
            process.arguments = launchArguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + launchArguments
        }

        if !server.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (server.workingDirectory as NSString).expandingTildeInPath)
        }

        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.ioQueue.async { [weak self] in
                self?.receiveOutput(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.ioQueue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.stderrBuffer.append(data)
                self.reportProgressFromStderrLocked(data)
                self.lock.unlock()
            }
        }

        try process.run()
    }

    nonisolated private static func effectiveArguments(for server: MCPServerConfig, command: String) -> [String] {
        let basename = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        guard basename == "npx" || command.lowercased() == "npx" else {
            return server.arguments
        }
        if server.arguments.contains("-y") || server.arguments.contains("--yes") {
            return server.arguments
        }
        return ["-y"] + server.arguments
    }

    nonisolated func initialize(protocolVersion: String) async throws -> [String: Any] {
        try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": protocolVersion,
                "capabilities": [:],
                "clientInfo": [
                    "name": "SkyAgent",
                    "version": "1.0"
                ]
            ],
            timeout: 20
        )
    }

    nonisolated func sendNotification(method: String, params: [String: Any]?) throws {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try write(payload)
    }

    nonisolated func sendRequest(
        method: String,
        params: [String: Any],
        timeout: TimeInterval,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [String: Any] {
        let requestID: Int = {
            lock.lock()
            defer { lock.unlock() }
            let current = nextRequestID
            nextRequestID += 1
            activeProgressHandler = onProgress
            activeRequestMethod = method
            activeRequestStartedAt = Date()
            lastProgressMessage = nil
            lastProgressAt = nil
            return current
        }()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pendingContinuations[requestID] = continuation
                pendingTimeoutTasks[requestID] = timeoutTask(for: requestID, method: method, timeout: timeout)
                lock.unlock()

                do {
                    try writeSynchronouslyOnIOQueue([
                        "jsonrpc": "2.0",
                        "id": requestID,
                        "method": method,
                        "params": params
                    ])
                } catch {
                    completeRequest(requestID, result: .failure(error))
                }
            }
        } onCancel: {
            completeRequest(
                requestID,
                result: .failure(
                    NSError(domain: "MCPStdioSession", code: 7, userInfo: [NSLocalizedDescriptionKey: "MCP 请求已取消：\(method)"])
                )
            )
        }
    }

    nonisolated func shutdown() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForReading.closeFile()
        errorPipe.fileHandleForReading.closeFile()
        failAllPendingRequests()

        if process.isRunning {
            process.terminate()
        }
    }

    nonisolated private func write(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let messageData = String(data: data, encoding: .utf8)?
            .appending("\n")
            .data(using: .utf8) else {
            throw NSError(domain: "MCPStdioSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "MCP 请求编码失败。"])
        }
        inputPipe.fileHandleForWriting.write(messageData)
    }

    nonisolated private func writeSynchronouslyOnIOQueue(_ payload: [String: Any]) throws {
        var capturedError: Error?
        ioQueue.sync {
            do {
                try write(payload)
            } catch {
                capturedError = error
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    nonisolated private func receiveOutput(_ data: Data) {
        lock.lock()
        buffer.append(data)
        parseMessagesLocked()
        lock.unlock()
    }

    nonisolated private func parseMessagesLocked() {
        while !buffer.isEmpty {
            if tryParseHeaderFramedMessageLocked() {
                continue
            }
            if tryParseLineDelimitedMessageLocked() {
                continue
            }
            return
        }
    }

    nonisolated private func tryParseHeaderFramedMessageLocked() -> Bool {
        guard buffer.starts(with: Data("Content-Length:".utf8)) else { return false }

        let headerSeparator: Data
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            headerSeparator = Data("\r\n\r\n".utf8)
            return parseHeaderFramedMessageLocked(separator: headerSeparator, range: range)
        }
        if let range = buffer.range(of: Data("\n\n".utf8)) {
            headerSeparator = Data("\n\n".utf8)
            return parseHeaderFramedMessageLocked(separator: headerSeparator, range: range)
        }
        return false
    }

    nonisolated private func parseHeaderFramedMessageLocked(separator: Data, range: Range<Data.Index>) -> Bool {
        let headerData = buffer.subdata(in: 0..<range.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            buffer.removeSubrange(0..<range.upperBound)
            return true
        }

        let contentLengthLine = headerString
            .components(separatedBy: CharacterSet.newlines)
            .first { $0.lowercased().hasPrefix("content-length:") }
        let contentLength = contentLengthLine
            .flatMap { $0.split(separator: ":").dropFirst().first }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        guard let contentLength else {
            buffer.removeSubrange(0..<range.upperBound)
            return true
        }

        let bodyStart = range.upperBound
        let totalLength = bodyStart + contentLength
        guard buffer.count >= totalLength else { return false }

        let bodyData = buffer.subdata(in: bodyStart..<totalLength)
        buffer.removeSubrange(0..<totalLength)
        handleMessageLocked(bodyData)
        return true
    }

    nonisolated private func tryParseLineDelimitedMessageLocked() -> Bool {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return false }

        let lineData = buffer.subdata(in: 0..<newlineIndex)
        buffer.removeSubrange(0...newlineIndex)

        let trimmed = String(data: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        guard let messageData = trimmed.data(using: .utf8) else { return true }

        handleMessageLocked(messageData)
        return true
    }

    nonisolated private func handleMessageLocked(_ bodyData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            if let errorPayload = json["error"] as? [String: Any] {
                let message = (errorPayload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? String(describing: errorPayload)
                completeRequestLocked(
                    id,
                    result: .failure(
                        NSError(domain: "MCPStdioSession", code: errorPayload["code"] as? Int ?? 6, userInfo: [NSLocalizedDescriptionKey: message])
                    )
                )
            } else {
                completeRequestLocked(id, result: .success(json["result"] as? [String: Any] ?? [:]))
            }
            clearProgressContextIfNeededLocked()
        } else if let method = json["method"] as? String {
            reportProgressFromNotificationLocked(method: method, params: json["params"] as? [String: Any])
        }
    }

    nonisolated private func timeoutDescription(for method: String) -> String {
        let stderr = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stderr.isEmpty {
            return "MCP 请求超时：\(method)"
        }
        return "MCP 请求超时：\(method)\n\(stderr)"
    }

    nonisolated private func clearProgressContextIfNeededLocked() {
        activeProgressHandler = nil
        activeRequestMethod = nil
        activeRequestStartedAt = nil
        lastProgressMessage = nil
        lastProgressAt = nil
    }

    nonisolated private func timeoutTask(for requestID: Int, method: String, timeout: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            self?.completeRequest(
                requestID,
                result: .failure(
                    NSError(domain: "MCPStdioSession", code: 3, userInfo: [NSLocalizedDescriptionKey: self?.timeoutDescription(for: method) ?? "MCP 请求超时：\(method)"])
                )
            )
        }
    }

    nonisolated private func completeRequest(_ requestID: Int, result: Result<[String: Any], Error>) {
        lock.lock()
        completeRequestLocked(requestID, result: result)
        lock.unlock()
    }

    nonisolated private func completeRequestLocked(_ requestID: Int, result: Result<[String: Any], Error>) {
        let continuation = pendingContinuations.removeValue(forKey: requestID)
        let timeoutTask = pendingTimeoutTasks.removeValue(forKey: requestID)
        timeoutTask?.cancel()
        guard let continuation else { return }
        switch result {
        case .success(let payload):
            continuation.resume(returning: payload)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    nonisolated private func failAllPendingRequests() {
        lock.lock()
        let continuations = pendingContinuations
        let timeoutTasks = pendingTimeoutTasks
        pendingContinuations.removeAll()
        pendingTimeoutTasks.removeAll()
        clearProgressContextIfNeededLocked()
        lock.unlock()

        timeoutTasks.values.forEach { $0.cancel() }
        let error = NSError(domain: "MCPStdioSession", code: 8, userInfo: [NSLocalizedDescriptionKey: "MCP 会话已关闭。"])
        continuations.values.forEach { $0.resume(throwing: error) }
    }

    nonisolated private func reportProgressFromNotificationLocked(method: String, params: [String: Any]?) {
        let message = progressMessage(for: method, params: params)
        reportProgressLocked(message)
    }

    nonisolated private func reportProgressFromStderrLocked(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        let lines = chunk
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return }
        reportProgressLocked(lastLine)
    }

    nonisolated private func reportProgressLocked(_ rawMessage: String?) {
        guard let handler = activeProgressHandler else { return }
        let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        let now = Date()
        if trimmed == lastProgressMessage,
           let lastProgressAt,
           now.timeIntervalSince(lastProgressAt) < 0.8 {
            return
        }
        lastProgressMessage = trimmed
        lastProgressAt = now
        handler(trimmed)
    }

    nonisolated private func progressMessage(for method: String, params: [String: Any]?) -> String {
        switch method {
        case "$/progress", "notifications/progress":
            if let progressToken = params?["progressToken"] {
                return "MCP 正在处理中 · \(progressToken)"
            }
            if let message = (params?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                return message
            }
            return "MCP 正在处理中"
        case "notifications/message":
            if let data = params?["data"] as? String, !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return data
            }
            if let message = params?["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            return "MCP 正在输出消息"
        case "notifications/log", "notifications/logMessage":
            if let message = (params?["data"] as? String) ?? (params?["message"] as? String),
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            return "MCP 正在记录日志"
        case "notifications/cancelled":
            return "MCP 调用已被取消"
        default:
            if let message = (params?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                return message
            }
            let request = activeRequestMethod?.replacingOccurrences(of: "/", with: " ")
            return request == nil ? "MCP 正在处理中" : "MCP 正在处理 \(request!)"
        }
    }
}

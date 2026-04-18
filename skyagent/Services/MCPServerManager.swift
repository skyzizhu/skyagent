import Foundation
import Combine

enum MCPServerScope: String, Codable, CaseIterable, Sendable {
    case user
    case project

    var displayName: String {
        switch self {
        case .user:
            return "User"
        case .project:
            return "Project"
        }
    }
}

struct MCPServerConfig: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var scope: MCPServerScope
    var transportKind: MCPTransportKind
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String
    var endpointURL: String
    var authKind: MCPAuthorizationKind
    var authToken: String
    var authHeaderName: String
    var additionalHeaders: [String: String]
    var secretAdditionalHeaderNames: [String]
    var toolExecutionPolicy: MCPToolExecutionPolicy
    var allowedToolNames: [String]
    var blockedToolNames: [String]
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        scope: MCPServerScope = .user,
        transportKind: MCPTransportKind = .stdio,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String = "",
        endpointURL: String = "",
        authKind: MCPAuthorizationKind = .none,
        authToken: String = "",
        authHeaderName: String = "",
        additionalHeaders: [String: String] = [:],
        secretAdditionalHeaderNames: [String] = [],
        toolExecutionPolicy: MCPToolExecutionPolicy = .allowAll,
        allowedToolNames: [String] = [],
        blockedToolNames: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.transportKind = transportKind
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.endpointURL = endpointURL
        self.authKind = authKind
        self.authToken = authToken
        self.authHeaderName = authHeaderName
        self.additionalHeaders = additionalHeaders
        self.secretAdditionalHeaderNames = secretAdditionalHeaderNames
        self.toolExecutionPolicy = toolExecutionPolicy
        self.allowedToolNames = allowedToolNames
        self.blockedToolNames = blockedToolNames
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scope = (try? container.decode(MCPServerScope.self, forKey: .scope)) ?? .user
        transportKind = (try? container.decode(MCPTransportKind.self, forKey: .transportKind)) ?? .stdio
        command = (try? container.decode(String.self, forKey: .command)) ?? ""
        arguments = (try? container.decode([String].self, forKey: .arguments)) ?? []
        environment = (try? container.decode([String: String].self, forKey: .environment)) ?? [:]
        workingDirectory = (try? container.decode(String.self, forKey: .workingDirectory)) ?? ""
        endpointURL = (try? container.decode(String.self, forKey: .endpointURL)) ?? ""
        authKind = (try? container.decode(MCPAuthorizationKind.self, forKey: .authKind)) ?? .none
        authToken = (try? container.decode(String.self, forKey: .authToken)) ?? ""
        authHeaderName = (try? container.decode(String.self, forKey: .authHeaderName)) ?? ""
        additionalHeaders = (try? container.decode([String: String].self, forKey: .additionalHeaders)) ?? [:]
        secretAdditionalHeaderNames = (try? container.decode([String].self, forKey: .secretAdditionalHeaderNames)) ?? []
        toolExecutionPolicy = (try? container.decode(MCPToolExecutionPolicy.self, forKey: .toolExecutionPolicy)) ?? .allowAll
        allowedToolNames = (try? container.decode([String].self, forKey: .allowedToolNames)) ?? []
        blockedToolNames = (try? container.decode([String].self, forKey: .blockedToolNames)) ?? []
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scope, forKey: .scope)
        try container.encode(transportKind, forKey: .transportKind)
        try container.encode(command, forKey: .command)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(endpointURL, forKey: .endpointURL)
        try container.encode(authKind, forKey: .authKind)
        try container.encode("", forKey: .authToken)
        try container.encode(authHeaderName, forKey: .authHeaderName)
        try container.encode(additionalHeaders, forKey: .additionalHeaders)
        try container.encode(secretAdditionalHeaderNames, forKey: .secretAdditionalHeaderNames)
        try container.encode(toolExecutionPolicy, forKey: .toolExecutionPolicy)
        try container.encode(allowedToolNames, forKey: .allowedToolNames)
        try container.encode(blockedToolNames, forKey: .blockedToolNames)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    var normalizedAllowedToolNames: [String] {
        allowedToolNames.map(Self.normalizeToolRuleName).filter { !$0.isEmpty }
    }

    var normalizedBlockedToolNames: [String] {
        blockedToolNames.map(Self.normalizeToolRuleName).filter { !$0.isEmpty }
    }

    var connectionSummary: String {
        switch transportKind {
        case .stdio:
            return ([command] + arguments).joined(separator: " ")
        case .streamableHTTP:
            return endpointURL
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, scope, transportKind, command, arguments, environment, workingDirectory, endpointURL, authKind, authToken, authHeaderName, additionalHeaders, secretAdditionalHeaderNames, toolExecutionPolicy, allowedToolNames, blockedToolNames, isEnabled
    }

    nonisolated static func normalizeToolRuleName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum MCPToolExecutionPolicy: String, Codable, CaseIterable, Sendable {
    case askEveryTime = "ask_every_time"
    case readOnlyOnly = "read_only_only"
    case allowAll = "allow_all"

    var displayName: String {
        switch self {
        case .askEveryTime:
            return "Ask Before Tool Calls"
        case .readOnlyOnly:
            return "Read-Only Only"
        case .allowAll:
            return "Allow All Tools"
        }
    }
}

private enum MCPAuthorizationRisk {
    case safeAutoAllow
    case requiresApproval
}

enum MCPToolRuleSelection: String, CaseIterable, Sendable {
    case inherit
    case allow
    case block

    var displayName: String {
        switch self {
        case .inherit:
            return "Default"
        case .allow:
            return "Allow"
        case .block:
            return "Block"
        }
    }
}

struct MCPServerRuntimeState {
    var isRefreshing = false
    var toolCount = 0
    var resourceCount = 0
    var promptCount = 0
    var lastError: String?
}

struct MCPToolDescriptor: Identifiable {
    let id: String
    let callName: String
    let toolName: String
    let toolTitle: String?
    let toolDescription: String
    let serverID: UUID
    let serverName: String
    let inputSchema: [String: Any]
    let hints: MCPToolMetadataHints
}

struct MCPResourceDescriptor: Identifiable {
    let id: String
    let uri: String
    let name: String
    let resourceDescription: String
    let mimeType: String?
    let serverID: UUID
    let serverName: String
}

struct MCPPromptArgumentDescriptor: Identifiable {
    let id: String
    let name: String
    let argumentDescription: String
    let isRequired: Bool
}

struct MCPPromptDescriptor: Identifiable {
    let id: String
    let name: String
    let promptDescription: String
    let serverID: UUID
    let serverName: String
    let arguments: [MCPPromptArgumentDescriptor]
}

struct MCPCandidateTooling {
    let definitions: [[String: Any]]
    let catalogPrompt: String?
}

enum MCPActivityStatus: String, Codable, Sendable {
    case success
    case failed
    case denied
}

struct MCPActivityLog: Identifiable, Codable, Sendable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let action: String
    let target: String
    let status: MCPActivityStatus
    let detail: String
    let createdAt: Date
    let durationMilliseconds: Int?
}

enum MCPAuthorizationDecision {
    case allowed
    case requiresApproval(OperationPreview)
    case rejected(ToolExecutionOutcome)
}

private struct MCPCandidateSelection {
    let servers: [MCPServerConfig]
    let tools: [MCPToolDescriptor]
    let resources: [MCPResourceDescriptor]
    let prompts: [MCPPromptDescriptor]
}

private struct MCPDiscoveryResult {
    let server: MCPServerConfig
    let snapshot: MCPCapabilitySnapshot?
    let errorDescription: String?
    let startedAt: Date
}

private struct MCPImportParseResult {
    let servers: [MCPServerConfig]
    let sourceDescription: String
    let sourceCount: Int
}

struct MCPImportSummary: Sendable {
    let importedCount: Int
    let skippedDuplicateCount: Int
    let sourceDescription: String
    let sourceCount: Int

    var message: String {
        if importedCount > 0 {
            return "Imported \(importedCount) server(s) from \(sourceDescription). Skipped \(skippedDuplicateCount) duplicate(s)."
        }
        return "No new servers were imported from \(sourceDescription). Skipped \(skippedDuplicateCount) duplicate(s) out of \(sourceCount) detected item(s)."
    }
}

private struct MCPServerConfigFile: Codable {
    let mcpServers: [MCPServerConfig]
}

@MainActor
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()
    private let largeVisibleOutputLimit = 24_000
    private let largeModelOutputLimit = 8_000

    @Published private(set) var servers: [MCPServerConfig] = []
    @Published private(set) var discoveredTools: [MCPToolDescriptor] = []
    @Published private(set) var discoveredResources: [MCPResourceDescriptor] = []
    @Published private(set) var discoveredPrompts: [MCPPromptDescriptor] = []
    @Published private(set) var activityLogs: [MCPActivityLog] = []
    @Published var lastErrorMessage: String?
    @Published var lastImportSummaryMessage: String?

    private let persistenceURL: URL
    private let activityLogURL: URL
    private var runtimeStates: [UUID: MCPServerRuntimeState] = [:]
    private let connectionManager: MCPConnectionManager
    private let keychainStore: MCPKeychainStore
    private var userServers: [MCPServerConfig] = []
    private var projectServers: [MCPServerConfig] = []

    init(
        persistenceURL: URL? = nil,
        activityLogURL: URL? = nil,
        connectionManager: MCPConnectionManager? = nil,
        keychainStore: MCPKeychainStore? = nil
    ) {
        self.persistenceURL = persistenceURL ?? AppStoragePaths.mcpServersFile
        self.activityLogURL = activityLogURL ?? AppStoragePaths.mcpActivityLogFile
        self.connectionManager = connectionManager ?? .shared
        self.keychainStore = keychainStore ?? .shared
        AppStoragePaths.prepareDataDirectories()
        AppStoragePaths.migrateMCPDataIfNeeded()
        loadServers()
        loadProjectScopedServers()
        rebuildPublishedServers()
        loadActivityLogs()
        migratePersistedTokensToKeychainIfNeeded()
        Task {
            await refreshTools()
        }
    }

    var userConfigURL: URL {
        persistenceURL
    }

    var projectConfigURL: URL? {
        currentProjectMCPConfigURL()
    }

    func state(for serverID: UUID) -> MCPServerRuntimeState {
        runtimeStates[serverID] ?? MCPServerRuntimeState()
    }

    private func normalizedLargeOutcome(
        output: String,
        toolLabel: String,
        followupContextMessage: String? = nil,
        operation: FileOperationRecord? = nil
    ) -> ToolExecutionOutcome {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("[错误]"),
              !trimmed.hasPrefix("⚠️"),
              output.count > largeVisibleOutputLimit else {
            return ToolExecutionOutcome(
                output: output,
                operation: operation,
                followupContextMessage: followupContextMessage
            )
        }

        let summary = summarizedLargeText(
            output,
            label: toolLabel,
            visibleCharacterLimit: largeVisibleOutputLimit,
            modelCharacterLimit: largeModelOutputLimit
        )

        let followupHint = """
        上一个 MCP 结果过长，系统已自动摘要。
        请直接用自然语言继续回应用户，不要要求用户展开工具详情。
        如果用户是在做统计、计数、查多少个、列举文件/资源这类问题，优先返回总数和少量样例，不要再次输出完整长列表。
        """

        let clippedOriginalFollowup = followupContextMessage.map {
            String($0.prefix(largeModelOutputLimit))
        }
        let mergedFollowupContext = [clippedOriginalFollowup, followupHint]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return ToolExecutionOutcome(
            output: summary.visibleOutput,
            modelOutput: summary.modelOutput,
            operation: operation,
            followupContextMessage: mergedFollowupContext.isEmpty ? nil : mergedFollowupContext
        )
    }

    private func summarizedLargeText(
        _ text: String,
        label: String,
        visibleCharacterLimit: Int,
        modelCharacterLimit: Int
    ) -> (visibleOutput: String, modelOutput: String) {
        let allLines = text.components(separatedBy: .newlines)
        let nonEmptyLines = allLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let nonEmptyLineCount = nonEmptyLines.count
        let lineBased = shouldPreferLineSummary(for: nonEmptyLines)
        let sampleLineLimit = lineBased ? min(20, nonEmptyLineCount) : min(8, nonEmptyLineCount)
        let sampleLines = Array(nonEmptyLines.prefix(sampleLineLimit))
        let visiblePreview = lineBased
            ? sampleLines.joined(separator: "\n")
            : String(text.prefix(visibleCharacterLimit))
        let modelPreview = lineBased
            ? Array(nonEmptyLines.prefix(min(12, nonEmptyLineCount))).joined(separator: "\n")
            : String(text.prefix(modelCharacterLimit))

        let visibleSummaryLine: String
        let modelSummaryLine: String
        if lineBased {
            visibleSummaryLine = "结果较长：共约 \(nonEmptyLineCount.formatted()) 项，下面仅展示前 \(sampleLineLimit.formatted()) 项样例。"
            modelSummaryLine = "MCP 结果较长：共约 \(nonEmptyLineCount) 项。请优先基于计数和样例继续回答，不要复述完整列表。"
        } else {
            visibleSummaryLine = "结果较长：共 \(text.count.formatted()) 个字符，下面仅展示开头摘要。"
            modelSummaryLine = "MCP 结果较长：共 \(text.count) 个字符。请基于摘要继续回答，不要复述完整长文本。"
        }

        let visibleOutput = """
        \(visibleSummaryLine)
        工具: \(label)
        总长度: \(text.count.formatted()) 个字符
        总行数: \(nonEmptyLineCount.formatted()) 行

        \(lineBased ? "样例：" : "摘要预览：")
        \(visiblePreview)
        """

        let modelOutput = """
        \(modelSummaryLine)
        工具: \(label)
        总长度: \(text.count) 个字符
        总行数: \(nonEmptyLineCount) 行

        \(lineBased ? "前若干项样例：" : "摘要预览：")
        \(modelPreview)
        """

        return (visibleOutput, modelOutput)
    }

    private func shouldPreferLineSummary(for lines: [String]) -> Bool {
        guard lines.count >= 8 else { return false }
        let averageLength = lines.reduce(0) { $0 + $1.count } / max(lines.count, 1)
        return averageLength <= 180
    }

    func addServer(
        name: String,
        transportKind: MCPTransportKind,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        endpointURL: String,
        authKind: MCPAuthorizationKind,
        authToken: String,
        authHeaderName: String,
        additionalHeaders: [String: String],
        toolExecutionPolicy: MCPToolExecutionPolicy,
        allowedToolNames: [String],
        blockedToolNames: [String]
    ) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpointURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthHeaderName = authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerSplit = splitAdditionalHeaders(additionalHeaders)

        guard !trimmedName.isEmpty else {
            lastErrorMessage = "MCP server 的名称不能为空。"
            return
        }

        switch transportKind {
        case .stdio:
            guard !trimmedCommand.isEmpty else {
                lastErrorMessage = "Local stdio MCP server 需要 command。"
                return
            }
        case .streamableHTTP:
            guard !trimmedEndpointURL.isEmpty, URL(string: trimmedEndpointURL) != nil else {
                lastErrorMessage = "Streamable HTTP MCP server 需要有效的 URL。"
                return
            }
        }

        if authKind == .customHeader, trimmedAuthToken.isEmpty == false, trimmedAuthHeaderName.isEmpty {
            lastErrorMessage = "自定义 Header 鉴权需要填写 Header Name。"
            return
        }

        let server = MCPServerConfig(
            name: trimmedName,
            scope: .user,
            transportKind: transportKind,
            command: trimmedCommand,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            endpointURL: trimmedEndpointURL,
            authKind: authKind,
            authToken: "",
            authHeaderName: trimmedAuthHeaderName,
            additionalHeaders: headerSplit.plainHeaders,
            secretAdditionalHeaderNames: headerSplit.secretHeaders.keys.sorted(),
            toolExecutionPolicy: toolExecutionPolicy,
            allowedToolNames: allowedToolNames,
            blockedToolNames: blockedToolNames
        )
        persistToken(trimmedAuthToken, for: server)
        persistAdditionalSecretHeaders(headerSplit.secretHeaders, for: server)
        userServers.append(server)
        lastErrorMessage = nil
        persistServers()
        rebuildPublishedServers()
        await refreshTools()
    }

    func removeServer(_ serverID: UUID) async {
        guard userServers.contains(where: { $0.id == serverID }) else { return }
        await connectionManager.invalidate(serverID: serverID)
        userServers.removeAll { $0.id == serverID }
        keychainStore.deleteToken(for: serverID)
        keychainStore.deleteAdditionalSecretHeaders(for: serverID)
        runtimeStates.removeValue(forKey: serverID)
        discoveredTools.removeAll { $0.serverID == serverID }
        discoveredResources.removeAll { $0.serverID == serverID }
        discoveredPrompts.removeAll { $0.serverID == serverID }
        activityLogs.removeAll { $0.serverID == serverID }
        persistServers()
        persistActivityLogs()
        rebuildPublishedServers()
        await refreshTools()
    }

    func setEnabled(_ isEnabled: Bool, for serverID: UUID) async {
        guard let index = userServers.firstIndex(where: { $0.id == serverID }) else { return }
        userServers[index].isEnabled = isEnabled
        persistServers()
        rebuildPublishedServers()
        await connectionManager.invalidate(serverID: serverID)
        await refreshTools()
    }

    func editableServerConfig(for serverID: UUID) -> MCPServerConfig? {
        guard var server = userServers.first(where: { $0.id == serverID }) else { return nil }
        server.authToken = keychainStore.token(for: serverID) ?? ""
        let mergedHeaders = server.additionalHeaders.merging(secretHeaders(from: server)) { _, new in new }
        server.additionalHeaders = mergedHeaders
        return server
    }

    func updateServer(
        serverID: UUID,
        name: String,
        transportKind: MCPTransportKind,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        endpointURL: String,
        authKind: MCPAuthorizationKind,
        authToken: String,
        authHeaderName: String,
        additionalHeaders: [String: String],
        toolExecutionPolicy: MCPToolExecutionPolicy,
        allowedToolNames: [String],
        blockedToolNames: [String]
    ) async {
        guard let index = userServers.firstIndex(where: { $0.id == serverID }) else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpointURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthHeaderName = authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerSplit = splitAdditionalHeaders(additionalHeaders)

        guard !trimmedName.isEmpty else {
            lastErrorMessage = "MCP server 的名称不能为空。"
            return
        }

        switch transportKind {
        case .stdio:
            guard !trimmedCommand.isEmpty else {
                lastErrorMessage = "Local stdio MCP server 需要 command。"
                return
            }
        case .streamableHTTP:
            guard !trimmedEndpointURL.isEmpty, URL(string: trimmedEndpointURL) != nil else {
                lastErrorMessage = "Streamable HTTP MCP server 需要有效的 URL。"
                return
            }
        }

        if authKind == .customHeader, trimmedAuthToken.isEmpty == false, trimmedAuthHeaderName.isEmpty {
            lastErrorMessage = "自定义 Header 鉴权需要填写 Header Name。"
            return
        }

        userServers[index].name = trimmedName
        userServers[index].transportKind = transportKind
        userServers[index].command = trimmedCommand
        userServers[index].arguments = arguments
        userServers[index].environment = environment
        userServers[index].workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        userServers[index].endpointURL = trimmedEndpointURL
        userServers[index].authKind = authKind
        userServers[index].authToken = ""
        userServers[index].authHeaderName = trimmedAuthHeaderName
        userServers[index].additionalHeaders = headerSplit.plainHeaders
        userServers[index].secretAdditionalHeaderNames = headerSplit.secretHeaders.keys.sorted()
        userServers[index].toolExecutionPolicy = toolExecutionPolicy
        userServers[index].allowedToolNames = normalizedToolRuleNames(allowedToolNames)
        userServers[index].blockedToolNames = normalizedToolRuleNames(blockedToolNames)

        persistToken(trimmedAuthToken, for: userServers[index])
        persistAdditionalSecretHeaders(headerSplit.secretHeaders, for: userServers[index])
        lastErrorMessage = nil
        persistServers()
        rebuildPublishedServers()
        await connectionManager.invalidate(serverID: serverID)
        await refreshTools()
    }

    func setToolExecutionPolicy(_ policy: MCPToolExecutionPolicy, for serverID: UUID) {
        guard let index = userServers.firstIndex(where: { $0.id == serverID }) else { return }
        userServers[index].toolExecutionPolicy = policy
        persistServers()
        rebuildPublishedServers()
    }

    func setAllowedToolNames(_ toolNames: [String], for serverID: UUID) {
        guard let index = userServers.firstIndex(where: { $0.id == serverID }) else { return }
        userServers[index].allowedToolNames = normalizedToolRuleNames(toolNames)
        persistServers()
        rebuildPublishedServers()
    }

    func setBlockedToolNames(_ toolNames: [String], for serverID: UUID) {
        guard let index = userServers.firstIndex(where: { $0.id == serverID }) else { return }
        userServers[index].blockedToolNames = normalizedToolRuleNames(toolNames)
        persistServers()
        rebuildPublishedServers()
    }

    func toolRuleSelection(for toolName: String, serverID: UUID) -> MCPToolRuleSelection {
        guard let server = servers.first(where: { $0.id == serverID }) else { return .inherit }
        let normalizedToolName = MCPServerConfig.normalizeToolRuleName(toolName)
        if server.normalizedBlockedToolNames.contains(normalizedToolName) {
            return .block
        }
        if server.normalizedAllowedToolNames.contains(normalizedToolName) {
            return .allow
        }
        return .inherit
    }

    func setToolRuleSelection(_ selection: MCPToolRuleSelection, for toolName: String, serverID: UUID) {
        guard let index = userServers.firstIndex(where: { $0.id == serverID }) else { return }

        let normalizedToolName = MCPServerConfig.normalizeToolRuleName(toolName)
        var allowedToolNames = userServers[index].allowedToolNames.filter {
            MCPServerConfig.normalizeToolRuleName($0) != normalizedToolName
        }
        var blockedToolNames = userServers[index].blockedToolNames.filter {
            MCPServerConfig.normalizeToolRuleName($0) != normalizedToolName
        }

        switch selection {
        case .inherit:
            break
        case .allow:
            allowedToolNames.append(normalizedToolName)
        case .block:
            blockedToolNames.append(normalizedToolName)
        }

        userServers[index].allowedToolNames = normalizedToolRuleNames(allowedToolNames)
        userServers[index].blockedToolNames = normalizedToolRuleNames(blockedToolNames)
        persistServers()
        rebuildPublishedServers()
    }

    func exportServers(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(userServers)
        try data.write(to: url, options: [.atomic])
    }

    func importServers(from url: URL) async throws -> MCPImportSummary {
        let data = try Data(contentsOf: url)
        let parsed = try parseImportedServers(from: data)
        let imported = parsed.servers
        guard !imported.isEmpty else {
            let summary = MCPImportSummary(
                importedCount: 0,
                skippedDuplicateCount: 0,
                sourceDescription: parsed.sourceDescription,
                sourceCount: parsed.sourceCount
            )
            lastImportSummaryMessage = "No importable MCP servers were found in \(parsed.sourceDescription)."
            lastErrorMessage = nil
            return summary
        }

        let existingFingerprints = Set(userServers.map(serverFingerprint))
        var merged = userServers
        var seenFingerprints = existingFingerprints
        var importedCount = 0
        var skippedDuplicateCount = 0

        for server in imported {
            let fingerprint = serverFingerprint(server)
            guard seenFingerprints.insert(fingerprint).inserted else {
                skippedDuplicateCount += 1
                continue
            }

            let headerSplit = splitAdditionalHeaders(server.additionalHeaders)

            merged.append(
                MCPServerConfig(
                    name: server.name,
                    scope: .user,
                    transportKind: server.transportKind,
                    command: server.command,
                    arguments: server.arguments,
                    environment: server.environment,
                    workingDirectory: server.workingDirectory,
                    endpointURL: server.endpointURL,
                    authKind: server.authKind,
                    authToken: "",
                    authHeaderName: server.authHeaderName,
                    additionalHeaders: headerSplit.plainHeaders,
                    secretAdditionalHeaderNames: mergedSecretHeaderNames(
                        existing: server.secretAdditionalHeaderNames,
                        added: Array(headerSplit.secretHeaders.keys)
                    ),
                    toolExecutionPolicy: server.toolExecutionPolicy,
                    allowedToolNames: server.allowedToolNames,
                    blockedToolNames: server.blockedToolNames,
                    isEnabled: server.isEnabled
                )
            )
            if let importedServer = merged.last {
                persistToken(server.authToken, for: importedServer)
                persistAdditionalSecretHeaders(headerSplit.secretHeaders, for: importedServer)
            }
            importedCount += 1
        }

        userServers = merged
        persistServers()
        rebuildPublishedServers()
        await refreshTools()

        let summary = MCPImportSummary(
            importedCount: importedCount,
            skippedDuplicateCount: skippedDuplicateCount,
            sourceDescription: parsed.sourceDescription,
            sourceCount: parsed.sourceCount
        )
        lastImportSummaryMessage = summary.message
        lastErrorMessage = nil
        return summary
    }

    func refreshTools() async {
        loadProjectScopedServers()
        rebuildPublishedServers()
        let currentServers = servers
        var nextTools: [MCPToolDescriptor] = []
        var nextResources: [MCPResourceDescriptor] = []
        var nextPrompts: [MCPPromptDescriptor] = []

        for server in currentServers {
            runtimeStates[server.id, default: MCPServerRuntimeState()].isRefreshing = true
            runtimeStates[server.id, default: MCPServerRuntimeState()].lastError = nil

            guard server.isEnabled else {
                runtimeStates[server.id] = MCPServerRuntimeState(isRefreshing: false, toolCount: 0, resourceCount: 0, promptCount: 0, lastError: nil)
                continue
            }
        }

        let enabledServers = currentServers.filter(\.isEnabled)
        let discoveryResults = await withTaskGroup(of: MCPDiscoveryResult.self, returning: [MCPDiscoveryResult].self) { group in
            for server in enabledServers {
                let connectionManager = self.connectionManager
                group.addTask {
                    let startedAt = Date()
                    do {
                        let snapshot = try await connectionManager.inspectServer(server)
                        return MCPDiscoveryResult(
                            server: server,
                            snapshot: snapshot,
                            errorDescription: nil,
                            startedAt: startedAt
                        )
                    } catch {
                        return MCPDiscoveryResult(
                            server: server,
                            snapshot: nil,
                            errorDescription: error.localizedDescription,
                            startedAt: startedAt
                        )
                    }
                }
            }

            var results: [MCPDiscoveryResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        for result in discoveryResults {
            let server = result.server
            if let snapshot = result.snapshot {
                let descriptors = snapshot.tools.map { tool in
                    MCPToolDescriptor(
                        id: toolCallName(serverID: server.id, toolName: tool.name),
                        callName: toolCallName(serverID: server.id, toolName: tool.name),
                        toolName: tool.name,
                        toolTitle: tool.hints.title,
                        toolDescription: tool.description,
                        serverID: server.id,
                        serverName: server.name,
                        inputSchema: tool.inputSchema,
                        hints: tool.hints
                    )
                }
                let resourceDescriptors = snapshot.resources.map { resource in
                    MCPResourceDescriptor(
                        id: "\(server.id.uuidString)::\(resource.uri)",
                        uri: resource.uri,
                        name: resource.name,
                        resourceDescription: resource.description,
                        mimeType: resource.mimeType,
                        serverID: server.id,
                        serverName: server.name
                    )
                }
                let promptDescriptors = snapshot.prompts.map { prompt in
                    MCPPromptDescriptor(
                        id: "\(server.id.uuidString)::\(prompt.name)",
                        name: prompt.name,
                        promptDescription: prompt.description,
                        serverID: server.id,
                        serverName: server.name,
                        arguments: prompt.arguments.map { argument in
                            MCPPromptArgumentDescriptor(
                                id: "\(server.id.uuidString)::\(prompt.name)::\(argument.name)",
                                name: argument.name,
                                argumentDescription: argument.description,
                                isRequired: argument.isRequired
                            )
                        }
                    )
                }
                nextTools.append(contentsOf: descriptors)
                nextResources.append(contentsOf: resourceDescriptors)
                nextPrompts.append(contentsOf: promptDescriptors)
                runtimeStates[server.id] = MCPServerRuntimeState(
                    isRefreshing: false,
                    toolCount: descriptors.count,
                    resourceCount: resourceDescriptors.count,
                    promptCount: promptDescriptors.count,
                    lastError: nil
                )
                appendLog(
                    serverID: server.id,
                    serverName: server.name,
                    action: "discover",
                    target: server.transportKind.displayName,
                    status: .success,
                    detail: "Discovered \(descriptors.count) tools, \(resourceDescriptors.count) resources, \(promptDescriptors.count) prompts.",
                    startedAt: result.startedAt
                )
            } else {
                let errorDescription = result.errorDescription ?? "Unknown MCP discovery error."
                runtimeStates[server.id] = MCPServerRuntimeState(
                    isRefreshing: false,
                    toolCount: 0,
                    resourceCount: 0,
                    promptCount: 0,
                    lastError: errorDescription
                )
                appendLog(
                    serverID: server.id,
                    serverName: server.name,
                    action: "discover",
                    target: server.transportKind.displayName,
                    status: .failed,
                    detail: errorDescription,
                    startedAt: result.startedAt
                )
            }
        }

        discoveredTools = nextTools.sorted {
            if $0.serverName != $1.serverName {
                return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
            }
            return $0.toolName.localizedCaseInsensitiveCompare($1.toolName) == .orderedAscending
        }
        discoveredResources = nextResources.sorted {
            if $0.serverName != $1.serverName {
                return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        discoveredPrompts = nextPrompts.sorted {
            if $0.serverName != $1.serverName {
                return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func tooling(for conversation: Conversation?) -> MCPCandidateTooling {
        let selection = candidateSelection(for: conversation)
        var definitions = selection.tools.map { descriptor in
            let parameters = normalizedSchema(from: descriptor.inputSchema)
            let toolLabel = descriptor.toolTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? descriptor.toolTitle!
                : descriptor.toolName
            return [
                "type": "function",
                "function": [
                    "name": descriptor.callName,
                    "description": "[MCP][\(descriptor.serverName)] \(toolLabel) - \(descriptor.toolDescription)",
                    "parameters": parameters
                ]
            ]
        }

        if !selection.resources.isEmpty {
            definitions.append(
                [
                    "type": "function",
                    "function": [
                        "name": "mcp_list_resources",
                        "description": "列出已发现的 MCP resources。可选传 server_id 或 server_name 过滤到指定 server。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "server_id": ["type": "string", "description": "MCP server UUID，可选"],
                                "server_name": ["type": "string", "description": "MCP server 名称，可选"]
                            ],
                            "required": []
                        ]
                    ]
                ]
            )
        }

        if !selection.resources.isEmpty {
            definitions.append(
                [
                    "type": "function",
                    "function": [
                        "name": "mcp_read_resource",
                        "description": "读取已发现的 MCP resource 内容。需要提供 uri，并建议同时提供 server_id 或 server_name。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "server_id": ["type": "string", "description": "MCP server UUID，可选但推荐"],
                                "server_name": ["type": "string", "description": "MCP server 名称，可选"],
                                "uri": ["type": "string", "description": "Resource URI"],
                            ],
                            "required": ["uri"]
                        ]
                    ]
                ]
            )
        }

        if !selection.prompts.isEmpty {
            definitions.append(
                [
                    "type": "function",
                    "function": [
                        "name": "mcp_list_prompts",
                        "description": "列出已发现的 MCP prompts。可选传 server_id 或 server_name 过滤到指定 server。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "server_id": ["type": "string", "description": "MCP server UUID，可选"],
                                "server_name": ["type": "string", "description": "MCP server 名称，可选"]
                            ],
                            "required": []
                        ]
                    ]
                ]
            )
            definitions.append(
                [
                    "type": "function",
                    "function": [
                        "name": "mcp_get_prompt",
                        "description": "解析并读取 MCP prompt。需要提供 prompt 名称，可选 arguments 对象。",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "server_id": ["type": "string", "description": "MCP server UUID，可选但推荐"],
                                "server_name": ["type": "string", "description": "MCP server 名称，可选"],
                                "name": ["type": "string", "description": "Prompt 名称"],
                                "arguments": ["type": "object", "description": "Prompt 参数对象", "properties": [:]]
                            ],
                            "required": ["name"]
                        ]
                    ]
                ]
            )
        }

        return MCPCandidateTooling(
            definitions: definitions,
            catalogPrompt: buildCatalogPrompt(for: selection)
        )
    }

    func toolDefinitions() -> [[String: Any]] {
        tooling(for: nil).definitions
    }

    func handlesTool(named name: String) -> Bool {
        if discoveredTools.contains(where: { $0.callName == name }) {
            return true
        }
        return ["mcp_list_resources", "mcp_read_resource", "mcp_list_prompts", "mcp_get_prompt"].contains(name)
    }

    func logs(for serverID: UUID) -> [MCPActivityLog] {
        activityLogs.filter { $0.serverID == serverID }
    }

    func toolDescriptor(named callName: String) -> MCPToolDescriptor? {
        discoveredTools.first(where: { $0.callName == callName })
    }

    func serverConfig(for serverID: UUID) -> MCPServerConfig? {
        servers.first(where: { $0.id == serverID })
    }

    func authorizationDecision(
        for toolCallName: String,
        arguments: String,
        operationId: String
    ) -> MCPAuthorizationDecision {
        guard !["mcp_list_resources", "mcp_read_resource", "mcp_list_prompts", "mcp_get_prompt"].contains(toolCallName) else {
            return .allowed
        }

        guard let descriptor = discoveredTools.first(where: { $0.callName == toolCallName }),
              let server = servers.first(where: { $0.id == descriptor.serverID }) else {
            return .rejected(ToolExecutionOutcome(output: "[错误] 未找到对应的 MCP 工具：\(toolCallName)"))
        }

            let normalizedToolName = descriptor.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let blockedTools = Set(server.normalizedBlockedToolNames)
        if blockedTools.contains(normalizedToolName) {
            appendLog(
                serverID: server.id,
                serverName: server.name,
                action: "tool_call",
                target: descriptor.toolName,
                status: .denied,
                detail: "Rejected by blocked tools rule.",
                startedAt: nil
            )
            return .rejected(
                ToolExecutionOutcome(
                    output: """
                    ⚠️ 已阻止 MCP 工具调用
                    Server: \(server.name)
                    Tool: \(descriptor.toolName)
                    原因: 该工具命中了当前 server 的 blocked tools 规则。
                    """
                )
            )
        }

        let allowedTools = Set(server.normalizedAllowedToolNames)
        if !allowedTools.isEmpty, !allowedTools.contains(normalizedToolName) {
            appendLog(
                serverID: server.id,
                serverName: server.name,
                action: "tool_call",
                target: descriptor.toolName,
                status: .denied,
                detail: "Rejected by allowed tools rule.",
                startedAt: nil
            )
            return .rejected(
                ToolExecutionOutcome(
                    output: """
                    ⚠️ 已阻止 MCP 工具调用
                    Server: \(server.name)
                    Tool: \(descriptor.toolName)
                    原因: 该工具不在当前 server 的 allowed tools 白名单中。
                    """
                )
            )
        }

        switch server.toolExecutionPolicy {
        case .allowAll:
            return .allowed
        case .readOnlyOnly:
            appendLog(
                serverID: server.id,
                serverName: server.name,
                action: "tool_call",
                target: descriptor.toolName,
                status: .denied,
                detail: "Rejected by read-only policy.",
                startedAt: nil
            )
            return .rejected(
                ToolExecutionOutcome(
                    output: """
                    ⚠️ 已阻止 MCP 工具调用
                    Server: \(server.name)
                    Tool: \(descriptor.toolName)
                    原因: 当前 server 被设置为 Read-Only Only，只允许读取 resources/prompts，不允许执行第三方 tools/call。
                    """
                )
            )
        case .askEveryTime:
            return .allowed
        }
    }

    func recordApprovalDenied(for toolCallName: String) {
        guard let descriptor = discoveredTools.first(where: { $0.callName == toolCallName }) else { return }
        appendLog(
            serverID: descriptor.serverID,
            serverName: descriptor.serverName,
            action: "tool_call",
            target: descriptor.toolName,
            status: .denied,
            detail: "User denied approval.",
            startedAt: nil
        )
    }

    func executeTool(
        named toolCallName: String,
        arguments: String,
        operationId: String,
        traceContext: TraceContext? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async -> ToolExecutionOutcome {
        if ["mcp_list_resources", "mcp_read_resource", "mcp_list_prompts", "mcp_get_prompt"].contains(toolCallName) {
            return await executeCapabilityTool(
                named: toolCallName,
                arguments: arguments,
                operationId: operationId,
                traceContext: traceContext,
                onProgress: onProgress
            )
        }

        guard let descriptor = discoveredTools.first(where: { $0.callName == toolCallName }),
              let server = servers.first(where: { $0.id == descriptor.serverID }) else {
            return ToolExecutionOutcome(output: "[错误] 未找到对应的 MCP 工具：\(toolCallName)")
        }

        do {
            let startedAt = Date()
            onProgress?("正在通过 MCP 调用 \(descriptor.serverName) / \(descriptor.toolName)")
            await Task.yield()
            let parsedArguments = try decodeArguments(arguments)
            onProgress?("参数已准备完成，正在等待 \(descriptor.serverName) 响应")
            await Task.yield()
            let result = try await connectionManager.callTool(
                descriptor.toolName,
                arguments: parsedArguments,
                on: server,
                onProgress: onProgress
            )
            onProgress?("MCP 已返回结果，正在整理输出")
            await Task.yield()
            let rendered = """
            [MCP Tool Result]
            Server: \(descriptor.serverName)
            Tool: \(descriptor.toolName)

            \(result)
            """
            let operation = FileOperationRecord(
                id: operationId,
                toolName: toolCallName,
                title: ChatStatusComposer.formattedMCPTitle(serverName: descriptor.serverName, actionName: descriptor.toolName),
                summary: "通过 \(descriptor.serverName) 执行 MCP 工具",
                detailLines: [
                    "Server: \(descriptor.serverName)",
                    "Tool: \(descriptor.toolName)"
                ],
                createdAt: Date(),
                undoAction: nil,
                isUndone: false
            )
            let outcome = normalizedLargeOutcome(
                output: rendered,
                toolLabel: toolCallName,
                operation: operation
            )
            appendLog(
                serverID: server.id,
                serverName: server.name,
                action: "tool_call",
                target: descriptor.toolName,
                status: .success,
                detail: "Tool call completed.",
                startedAt: startedAt,
                traceContext: traceContext
            )
            return outcome
        } catch {
            appendLog(
                serverID: server.id,
                serverName: server.name,
                action: "tool_call",
                target: descriptor.toolName,
                status: .failed,
                detail: error.localizedDescription,
                startedAt: nil,
                traceContext: traceContext
            )
            return ToolExecutionOutcome(
                output: """
                [错误] MCP 工具调用失败
                Server: \(descriptor.serverName)
                Tool: \(descriptor.toolName)
                原因: \(error.localizedDescription)
                """
            )
        }
    }

    func tools(for serverID: UUID) -> [MCPToolDescriptor] {
        discoveredTools.filter { $0.serverID == serverID }
    }

    func resources(for serverID: UUID) -> [MCPResourceDescriptor] {
        discoveredResources.filter { $0.serverID == serverID }
    }

    func prompts(for serverID: UUID) -> [MCPPromptDescriptor] {
        discoveredPrompts.filter { $0.serverID == serverID }
    }

    func testTool(callName: String, arguments: String) async -> String {
        guard let descriptor = discoveredTools.first(where: { $0.callName == callName }),
              let server = servers.first(where: { $0.id == descriptor.serverID }) else {
            return "[错误] 未找到对应的 MCP 工具。"
        }

        let normalizedToolName = MCPServerConfig.normalizeToolRuleName(descriptor.toolName)
        if server.normalizedBlockedToolNames.contains(normalizedToolName) {
            appendLog(serverID: server.id, serverName: server.name, action: "tool_test", target: descriptor.toolName, status: .denied, detail: "Blocked by tool rule.", startedAt: nil)
            return """
            [MCP Test]
            Server: \(server.name)
            Tool: \(descriptor.toolName)

            [错误] 当前工具已被 blocked rules 禁止。
            """
        }
        if !server.normalizedAllowedToolNames.isEmpty, !server.normalizedAllowedToolNames.contains(normalizedToolName) {
            appendLog(serverID: server.id, serverName: server.name, action: "tool_test", target: descriptor.toolName, status: .denied, detail: "Rejected by allowlist.", startedAt: nil)
            return """
            [MCP Test]
            Server: \(server.name)
            Tool: \(descriptor.toolName)

            [错误] 当前工具不在 allowed tools 白名单中。
            """
        }
        if server.toolExecutionPolicy == .readOnlyOnly {
            appendLog(serverID: server.id, serverName: server.name, action: "tool_test", target: descriptor.toolName, status: .denied, detail: "Rejected by read-only policy.", startedAt: nil)
            return """
            [MCP Test]
            Server: \(server.name)
            Tool: \(descriptor.toolName)

            [错误] 当前 server 为 Read-Only Only，不允许执行 tools/call。
            """
        }

        do {
            let parsedArguments = try decodeArguments(arguments)
            let startedAt = Date()
            let result = try await connectionManager.callTool(descriptor.toolName, arguments: parsedArguments, on: server)
            appendLog(serverID: server.id, serverName: server.name, action: "tool_test", target: descriptor.toolName, status: .success, detail: "Manual tool test completed.", startedAt: startedAt)
            return normalizedLargeOutcome(
                output: """
                [MCP Tool Test]
                Server: \(server.name)
                Tool: \(descriptor.toolName)

                \(result)
                """,
                toolLabel: "mcp_test_tool"
            ).output
        } catch {
            appendLog(serverID: server.id, serverName: server.name, action: "tool_test", target: descriptor.toolName, status: .failed, detail: error.localizedDescription, startedAt: nil)
            return """
            [MCP Tool Test]
            Server: \(server.name)
            Tool: \(descriptor.toolName)

            [错误] \(error.localizedDescription)
            """
        }
    }

    func testResource(serverID: UUID, uri: String) async -> String {
        guard let resource = discoveredResources.first(where: { $0.serverID == serverID && $0.uri == uri }),
              let server = servers.first(where: { $0.id == serverID }) else {
            return "[错误] 未找到对应的 MCP resource。"
        }

        do {
            let startedAt = Date()
            let content = try await connectionManager.readResource(resource.uri, on: server)
            appendLog(serverID: server.id, serverName: server.name, action: "resource_test", target: resource.name, status: .success, detail: resource.uri, startedAt: startedAt)
            return normalizedLargeOutcome(
                output: """
                [MCP Resource Test]
                Server: \(server.name)
                Name: \(resource.name)
                URI: \(resource.uri)

                \(content)
                """,
                toolLabel: "mcp_test_resource"
            ).output
        } catch {
            appendLog(serverID: server.id, serverName: server.name, action: "resource_test", target: resource.name, status: .failed, detail: error.localizedDescription, startedAt: nil)
            return """
            [MCP Resource Test]
            Server: \(server.name)
            Name: \(resource.name)

            [错误] \(error.localizedDescription)
            """
        }
    }

    func testPrompt(serverID: UUID, name: String, arguments: String) async -> String {
        guard let prompt = discoveredPrompts.first(where: { $0.serverID == serverID && $0.name == name }),
              let server = servers.first(where: { $0.id == serverID }) else {
            return "[错误] 未找到对应的 MCP prompt。"
        }

        do {
            let parsedArguments = try decodeArguments(arguments)
            let startedAt = Date()
            let result = try await connectionManager.getPrompt(prompt.name, arguments: parsedArguments, on: server)
            appendLog(serverID: server.id, serverName: server.name, action: "prompt_test", target: prompt.name, status: .success, detail: "Manual prompt resolution completed.", startedAt: startedAt)
            return normalizedLargeOutcome(
                output: renderPromptResolution(serverName: server.name, promptName: prompt.name, payload: result),
                toolLabel: "mcp_test_prompt"
            ).output
        } catch {
            appendLog(serverID: server.id, serverName: server.name, action: "prompt_test", target: prompt.name, status: .failed, detail: error.localizedDescription, startedAt: nil)
            return """
            [MCP Prompt Test]
            Server: \(server.name)
            Prompt: \(prompt.name)

            [错误] \(error.localizedDescription)
            """
        }
    }

    func buildCatalogPrompt() -> String? {
        buildCatalogPrompt(for: candidateSelection(for: nil))
    }

    private func buildCatalogPrompt(for selection: MCPCandidateSelection) -> String? {
        let enabledServers = servers.filter(\.isEnabled)
        guard !selection.servers.isEmpty else { return nil }

        var lines: [String] = [
            "[MCP Catalog]",
            enabledServers.count > selection.servers.count
                ? "以下是与当前任务最相关的 MCP server 候选。优先在这些候选中选择，避免一次性探索全部 server："
                : "已启用的 MCP server 能力如下。使用 MCP 专属工具时，优先先列出再读取：",
            "1. 要找 resources，先用 mcp_list_resources；需要具体内容时再用 mcp_read_resource。",
            "2. 要找 prompts，先用 mcp_list_prompts；需要把模板解析成消息时再用 mcp_get_prompt。",
            "3. 如果某个 server 还暴露了专属 tools，也可以直接调用对应的 mcp__... 动态工具。",
            ""
        ]

        for server in selection.servers {
            let state = runtimeStates[server.id] ?? MCPServerRuntimeState()
            let transport = server.transportKind.displayName
            lines.append("- \(server.name) [\(transport)] | tools: \(state.toolCount) | resources: \(state.resourceCount) | prompts: \(state.promptCount)")
            let toolNames = selection.tools
                .filter { $0.serverID == server.id }
                .prefix(3)
                .map(\.toolName)
            if !toolNames.isEmpty {
                lines.append("  tools: \(toolNames.joined(separator: ", "))")
            }
            let resourceNames = selection.resources
                .filter { $0.serverID == server.id }
                .prefix(2)
                .map(\.name)
            if !resourceNames.isEmpty {
                lines.append("  resources: \(resourceNames.joined(separator: ", "))")
            }
            let promptNames = selection.prompts
                .filter { $0.serverID == server.id }
                .prefix(2)
                .map(\.name)
            if !promptNames.isEmpty {
                lines.append("  prompts: \(promptNames.joined(separator: ", "))")
            }
        }

        if enabledServers.count > selection.servers.count {
            lines.append("")
            lines.append("当前只暴露了 \(selection.servers.count) 个候选 server；如果这些候选不足以完成任务，再回头考虑其他 MCP server。")
        }

        lines.append("[/MCP Catalog]")
        return lines.joined(separator: "\n")
    }

    private func loadServers() {
        guard let data = try? Data(contentsOf: persistenceURL) else {
            userServers = []
            return
        }
        let decoded: [MCPServerConfig]
        if let wrapped = try? JSONDecoder().decode(MCPServerConfigFile.self, from: data) {
            decoded = wrapped.mcpServers
        } else if let legacyArray = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            decoded = legacyArray
        } else {
            userServers = []
            return
        }

        userServers = decoded.map { server in
            var mutable = server
            mutable.scope = .user
            return mutable
        }
    }

    private func loadProjectScopedServers() {
        guard let configURL = currentProjectMCPConfigURL(),
              let data = try? Data(contentsOf: configURL),
              let parsed = try? parseImportedServers(from: data) else {
            projectServers = []
            return
        }
        projectServers = parsed.servers.map { server in
            var mutable = server
            mutable.scope = .project
            return mutable
        }
    }

    private func rebuildPublishedServers() {
        var mergedByName: [String: MCPServerConfig] = [:]
        for server in userServers {
            mergedByName[normalizedServerScopeKey(for: server)] = server
        }
        for server in projectServers {
            mergedByName[normalizedServerScopeKey(for: server)] = server
        }
        servers = mergedByName.values.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return lhs.scope == .project
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func normalizedServerScopeKey(for server: MCPServerConfig) -> String {
        server.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func currentProjectMCPConfigURL() -> URL? {
        let sandboxDir = AppSettings.load().ensureSandboxDir()
        let expandedSandboxDir = (sandboxDir as NSString).expandingTildeInPath
        guard !expandedSandboxDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var candidateURL = URL(fileURLWithPath: expandedSandboxDir, isDirectory: true)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory) {
            return nil
        }
        if !isDirectory.boolValue {
            candidateURL.deleteLastPathComponent()
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        while true {
            let configURL = candidateURL.appendingPathComponent(".mcp.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: configURL.path) {
                return configURL
            }
            let parentURL = candidateURL.deletingLastPathComponent()
            if parentURL.path == candidateURL.path || candidateURL.path == homePath {
                break
            }
            candidateURL = parentURL
        }
        return nil
    }

    private func loadActivityLogs() {
        guard let data = try? Data(contentsOf: activityLogURL),
              let decoded = try? JSONDecoder().decode([MCPActivityLog].self, from: data) else {
            activityLogs = []
            return
        }
        activityLogs = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func migratePersistedTokensToKeychainIfNeeded() {
        var didSanitize = false
        for index in userServers.indices {
            let token = userServers[index].authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                persistToken(token, for: userServers[index])
                userServers[index].authToken = ""
                didSanitize = true
            }

            let headerSplit = splitAdditionalHeaders(userServers[index].additionalHeaders)
            if !headerSplit.secretHeaders.isEmpty {
                persistAdditionalSecretHeaders(headerSplit.secretHeaders, for: userServers[index])
                userServers[index].additionalHeaders = headerSplit.plainHeaders
                userServers[index].secretAdditionalHeaderNames = mergedSecretHeaderNames(
                    existing: userServers[index].secretAdditionalHeaderNames,
                    added: Array(headerSplit.secretHeaders.keys)
                )
                didSanitize = true
            }
        }
        if didSanitize {
            persistServers()
            rebuildPublishedServers()
        }
    }

    private func persistServers() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(MCPServerConfigFile(mcpServers: userServers)) else { return }
        try? data.write(to: persistenceURL, options: [.atomic])
    }

    private func persistActivityLogs() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(activityLogs) else { return }
        try? data.write(to: activityLogURL, options: [.atomic])
    }

    private func persistToken(_ token: String, for server: MCPServerConfig) {
        _ = keychainStore.setToken(token, for: server.id)
    }

    private func persistAdditionalSecretHeaders(_ headers: [String: String], for server: MCPServerConfig) {
        _ = keychainStore.setAdditionalSecretHeaders(headers, for: server.id)
    }

    private func parseImportedServers(from data: Data) throws -> MCPImportParseResult {
        if let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            return MCPImportParseResult(
                servers: decoded,
                sourceDescription: "SkyAgent export",
                sourceCount: decoded.count
            )
        }

        if let wrapped = try? JSONDecoder().decode(MCPServerConfigFile.self, from: data) {
            return MCPImportParseResult(
                servers: wrapped.mcpServers,
                sourceDescription: "SkyAgent mcpServers config",
                sourceCount: wrapped.mcpServers.count
            )
        }

        let object = try JSONSerialization.jsonObject(with: data)

        if let root = object as? [String: Any] {
            if let mcpServers = root["mcpServers"] as? [String: Any] {
                let servers = mcpServers.compactMap { name, rawValue in
                    parseExternalServer(named: name, rawValue: rawValue)
                }
                return MCPImportParseResult(
                    servers: servers,
                    sourceDescription: "mcpServers config",
                    sourceCount: mcpServers.count
                )
            }

            if let mcpServersArray = root["mcpServers"] as? [[String: Any]] {
                let servers = mcpServersArray.compactMap { entry in
                    let name = stringValue(entry["name"]) ?? stringValue(entry["id"]) ?? "Imported MCP Server"
                    return parseExternalServer(named: name, rawValue: entry)
                }
                return MCPImportParseResult(
                    servers: servers,
                    sourceDescription: "mcpServers array config",
                    sourceCount: mcpServersArray.count
                )
            }

            if let serverEntries = root["servers"] as? [[String: Any]] {
                let servers = serverEntries.compactMap { entry in
                    let name = stringValue(entry["name"]) ?? stringValue(entry["id"]) ?? "Imported MCP Server"
                    return parseExternalServer(named: name, rawValue: entry)
                }
                return MCPImportParseResult(
                    servers: servers,
                    sourceDescription: "servers array config",
                    sourceCount: serverEntries.count
                )
            }
        }

        if let array = object as? [[String: Any]] {
            let servers = array.compactMap { entry in
                let name = stringValue(entry["name"]) ?? stringValue(entry["id"]) ?? "Imported MCP Server"
                return parseExternalServer(named: name, rawValue: entry)
            }
            return MCPImportParseResult(
                servers: servers,
                sourceDescription: "generic MCP server array",
                sourceCount: array.count
            )
        }

        throw NSError(
            domain: "MCPServerManager",
            code: 30,
            userInfo: [NSLocalizedDescriptionKey: "无法识别该 MCP 配置格式。当前支持 SkyAgent 导出格式，以及包含 mcpServers 的常见第三方配置格式。"]
        )
    }

    private func decodeArguments(_ rawArguments: String) throws -> [String: Any] {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MCPServerManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "MCP 工具参数必须是 JSON 对象。"])
        }
        return object
    }

    private func parseExternalServer(named name: String, rawValue: Any) -> MCPServerConfig? {
        guard let dictionary = rawValue as? [String: Any] else { return nil }

        let resolverEnvironment = ProcessExecutionEnvironment.shared.resolvedEnvironment()
        let command = expandConfigVariables(in: stringValue(dictionary["command"]) ?? "", environment: resolverEnvironment)
        let endpointURL = expandConfigVariables(
            in: stringValue(dictionary["url"])
                ?? stringValue(dictionary["endpointURL"])
                ?? stringValue(dictionary["endpoint"])
                ?? "",
            environment: resolverEnvironment
        )
        let arguments = (stringArrayValue(dictionary["args"])
            ?? stringArrayValue(dictionary["arguments"])
            ?? [])
            .map { expandConfigVariables(in: $0, environment: resolverEnvironment) }
        let environment = (stringDictionaryValue(dictionary["env"])
            ?? stringDictionaryValue(dictionary["environment"])
            ?? [:])
            .mapValues { expandConfigVariables(in: $0, environment: resolverEnvironment) }
        let workingDirectory = expandConfigVariables(
            in: stringValue(dictionary["cwd"])
                ?? stringValue(dictionary["workingDirectory"])
                ?? "",
            environment: resolverEnvironment
        )

        let typeHint = stringValue(dictionary["type"])?.lowercased()
        let transportHint = stringValue(dictionary["transport"])?.lowercased()
        let transportKind: MCPTransportKind
        if typeHint == "http" || typeHint == "streamable_http" || transportHint == "http" || transportHint == "streamable_http" || (!endpointURL.isEmpty && command.isEmpty) {
            transportKind = .streamableHTTP
        } else {
            transportKind = .stdio
        }

        let headers = (stringDictionaryValue(dictionary["headers"]) ?? [:])
            .mapValues { expandConfigVariables(in: $0, environment: resolverEnvironment) }
        let (authKind, authToken, authHeaderName, additionalHeaders) = authFields(from: headers)

        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard transportKind == .streamableHTTP || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard transportKind == .stdio || !endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return MCPServerConfig(
            name: name,
            transportKind: transportKind,
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            endpointURL: endpointURL,
            authKind: authKind,
            authToken: authToken,
            authHeaderName: authHeaderName,
            additionalHeaders: additionalHeaders,
            toolExecutionPolicy: .allowAll,
            allowedToolNames: [],
            blockedToolNames: [],
            isEnabled: true
        )
    }

    private func expandConfigVariables(in value: String, environment: [String: String]) -> String {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else { return value }

        var expanded = value
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let fullRange = match.range(at: 0)
            let keyRange = match.range(at: 1)
            guard fullRange.location != NSNotFound, keyRange.location != NSNotFound else { continue }

            let key = nsValue.substring(with: keyRange)
            let defaultValue: String? = {
                guard match.numberOfRanges >= 4 else { return nil }
                let range = match.range(at: 3)
                guard range.location != NSNotFound else { return nil }
                return nsValue.substring(with: range)
            }()

            let replacement = environment[key] ?? defaultValue ?? nsValue.substring(with: fullRange)
            if let swiftRange = Range(fullRange, in: expanded) {
                expanded.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return expanded
    }

    private func toolCallName(serverID: UUID, toolName: String) -> String {
        let serverToken = serverID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let sanitizedToolName = toolName.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return "mcp__\(serverToken)__\(String(sanitizedToolName))"
    }

    private func normalizedSchema(from schema: [String: Any]) -> [String: Any] {
        guard let type = schema["type"] as? String, type == "object" else {
            return [
                "type": "object",
                "properties": [:],
                "required": []
            ]
        }
        var normalized = schema
        if normalized["properties"] == nil {
            normalized["properties"] = [:]
        }
        if normalized["required"] == nil {
            normalized["required"] = []
        }
        return normalized
    }

    private func authFields(from headers: [String: String]) -> (MCPAuthorizationKind, String, String, [String: String]) {
        guard !headers.isEmpty else {
            return (.none, "", "", [:])
        }

        if let authorizationEntry = headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            let authorizationValue = authorizationEntry.value
            let trimmed = authorizationValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let remainingHeaders = headers.filter { key, _ in
                key.caseInsensitiveCompare("Authorization") != .orderedSame
            }
            if trimmed.lowercased().hasPrefix("bearer ") {
                let token = String(trimmed.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (.bearer, token, "", remainingHeaders)
            }
            return (.customHeader, trimmed, "Authorization", remainingHeaders)
        }

        if headers.count == 1, let (headerName, value) = headers.first {
            return (.customHeader, value, headerName, [:])
        }

        if let authLikeHeader = headers.first(where: { looksLikeAuthenticationHeader(name: $0.key) }) {
            let remainingHeaders = headers.filter { key, _ in
                key.caseInsensitiveCompare(authLikeHeader.key) != .orderedSame
            }
            return (.customHeader, authLikeHeader.value, authLikeHeader.key, remainingHeaders)
        }

        return (.none, "", "", headers)
    }

    private func stringValue(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stringArrayValue(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        return array.compactMap { item in
            (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func stringDictionaryValue(_ value: Any?) -> [String: String]? {
        guard let dictionary = value as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, rawValue) in dictionary {
            if let string = rawValue as? String {
                result[key] = string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    private func candidateSelection(
        for conversation: Conversation?,
        maxServerCount: Int = 4,
        maxToolCount: Int = 12
    ) -> MCPCandidateSelection {
        let enabledServers = servers.filter(\.isEnabled)
        guard !enabledServers.isEmpty else {
            return MCPCandidateSelection(servers: [], tools: [], resources: [], prompts: [])
        }

        guard let conversation else {
            return MCPCandidateSelection(
                servers: enabledServers,
                tools: discoveredTools,
                resources: discoveredResources,
                prompts: discoveredPrompts
            )
        }

        let fragments = queryFragments(from: conversation.memoryRetrievalQuery)
        let selectedServers = candidateServers(from: enabledServers, fragments: fragments, limit: maxServerCount)
        let selectedServerIDs = Set(selectedServers.map(\.id))

        let candidateResources = discoveredResources.filter { selectedServerIDs.contains($0.serverID) }
        let candidatePrompts = discoveredPrompts.filter { selectedServerIDs.contains($0.serverID) }
        let candidateTools = rankedTools(from: discoveredTools.filter { selectedServerIDs.contains($0.serverID) }, fragments: fragments, limit: maxToolCount)

        return MCPCandidateSelection(
            servers: selectedServers,
            tools: candidateTools,
            resources: candidateResources,
            prompts: candidatePrompts
        )
    }

    private func candidateServers(
        from enabledServers: [MCPServerConfig],
        fragments: [String],
        limit: Int
    ) -> [MCPServerConfig] {
        let scored = enabledServers.map { server in
            let tools = discoveredTools.filter { $0.serverID == server.id }
            let resources = discoveredResources.filter { $0.serverID == server.id }
            let prompts = discoveredPrompts.filter { $0.serverID == server.id }
            let searchDocument = [
                server.name,
                tools.map(\.toolName).joined(separator: " "),
                tools.map(\.toolDescription).joined(separator: " "),
                resources.map(\.name).joined(separator: " "),
                resources.map(\.resourceDescription).joined(separator: " "),
                prompts.map(\.name).joined(separator: " "),
                prompts.map(\.promptDescription).joined(separator: " ")
            ].joined(separator: "\n")
            let queryScore = score(searchDocument, against: fragments)
            let capabilityScore = (tools.count * 2) + resources.count + prompts.count
            return (server, queryScore, capabilityScore)
        }

        let positive = scored.filter { $0.1 > 0 }
        let ranked = (positive.isEmpty ? scored : positive).sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }

        return Array(ranked.prefix(limit).map(\.0))
    }

    private func rankedTools(
        from tools: [MCPToolDescriptor],
        fragments: [String],
        limit: Int
    ) -> [MCPToolDescriptor] {
        let scored = tools.map { descriptor in
            let searchDocument = [
                descriptor.serverName,
                descriptor.toolName,
                descriptor.toolDescription
            ].joined(separator: "\n")
            return (descriptor, score(searchDocument, against: fragments))
        }

        let positive = scored.filter { $0.1 > 0 }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.serverName != rhs.0.serverName {
                return lhs.0.serverName.localizedCaseInsensitiveCompare(rhs.0.serverName) == .orderedAscending
            }
            return lhs.0.toolName.localizedCaseInsensitiveCompare(rhs.0.toolName) == .orderedAscending
        }

        if !positive.isEmpty {
            return Array(positive.prefix(limit).map(\.0))
        }

        return Array(
            tools.sorted {
                if $0.serverName != $1.serverName {
                    return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
                }
                return $0.toolName.localizedCaseInsensitiveCompare($1.toolName) == .orderedAscending
            }
            .prefix(limit)
        )
    }

    private func queryFragments(from query: String) -> [String] {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var fragments: [String] = []
        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        fragments.append(contentsOf: lines.prefix(4))

        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "，。！？；：（）【】《》、|/\\"))
        let tokens = normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 24 }
        fragments.append(contentsOf: tokens)

        var ordered: [String] = []
        var seen: Set<String> = []
        for fragment in fragments.sorted(by: { $0.count > $1.count }) {
            if seen.insert(fragment).inserted {
                ordered.append(fragment)
            }
        }
        return Array(ordered.prefix(12))
    }

    private func score(_ text: String, against fragments: [String]) -> Int {
        guard !fragments.isEmpty else { return 0 }
        let haystack = text.lowercased()
        var total = 0
        for fragment in fragments {
            guard haystack.contains(fragment) else { continue }
            switch fragment.count {
            case 10...:
                total += 8
            case 6...:
                total += 5
            case 3...:
                total += 3
            default:
                total += 1
            }
        }
        return total
    }

    private func executeCapabilityTool(
        named toolCallName: String,
        arguments: String,
        operationId: String,
        traceContext: TraceContext?,
        onProgress: ((String) -> Void)?
    ) async -> ToolExecutionOutcome {
        do {
            let parsedArguments = try decodeArguments(arguments)
            switch toolCallName {
            case "mcp_list_resources":
                let filteredResources = try resolveResources(from: parsedArguments)
                if let server = try resolveServer(from: parsedArguments) {
                    appendLog(serverID: server.id, serverName: server.name, action: "list_resources", target: "resources", status: .success, detail: "Listed \(filteredResources.count) resources.", startedAt: nil, traceContext: traceContext)
                }
                let operation = capabilityOperationRecord(
                    id: operationId,
                    toolName: toolCallName,
                    title: "MCP · Resources",
                    summary: "查看 MCP resources 列表",
                    detailLines: filteredResources.prefix(6).map { "\($0.serverName): \($0.name)" }
                )
                return normalizedLargeOutcome(
                    output: renderResourceList(filteredResources),
                    toolLabel: toolCallName,
                    operation: operation
                )
            case "mcp_read_resource":
                let resource = try resolveResource(from: parsedArguments)
                guard let server = servers.first(where: { $0.id == resource.serverID }) else {
                    return ToolExecutionOutcome(output: "[错误] 未找到对应的 MCP server。")
                }
                let startedAt = Date()
                onProgress?("正在读取 MCP resource：\(resource.serverName) / \(resource.name)")
                let content = try await connectionManager.readResource(resource.uri, on: server, onProgress: onProgress)
                appendLog(serverID: server.id, serverName: server.name, action: "read_resource", target: resource.name, status: .success, detail: resource.uri, startedAt: startedAt, traceContext: traceContext)
                let rendered = """
                [MCP Resource]
                Server: \(resource.serverName)
                Name: \(resource.name)
                URI: \(resource.uri)

                \(content)
                """
                let operation = capabilityOperationRecord(
                    id: operationId,
                    toolName: toolCallName,
                    title: "MCP · \(resource.name)",
                    summary: "读取 MCP resource",
                    detailLines: [
                        "Server: \(resource.serverName)",
                        "URI: \(resource.uri)"
                    ]
                )
                return normalizedLargeOutcome(
                    output: rendered,
                    toolLabel: toolCallName,
                    operation: operation
                )
            case "mcp_list_prompts":
                let filteredPrompts = try resolvePrompts(from: parsedArguments)
                if let server = try resolveServer(from: parsedArguments) {
                    appendLog(serverID: server.id, serverName: server.name, action: "list_prompts", target: "prompts", status: .success, detail: "Listed \(filteredPrompts.count) prompts.", startedAt: nil, traceContext: traceContext)
                }
                let operation = capabilityOperationRecord(
                    id: operationId,
                    toolName: toolCallName,
                    title: "MCP · Prompts",
                    summary: "查看 MCP prompts 列表",
                    detailLines: filteredPrompts.prefix(6).map { "\($0.serverName): \($0.name)" }
                )
                return normalizedLargeOutcome(
                    output: renderPromptList(filteredPrompts),
                    toolLabel: toolCallName,
                    operation: operation
                )
            case "mcp_get_prompt":
                let promptDescriptor = try resolvePrompt(from: parsedArguments)
                guard let server = servers.first(where: { $0.id == promptDescriptor.serverID }) else {
                    return ToolExecutionOutcome(output: "[错误] 未找到对应的 MCP server。")
                }
                let promptArguments = (parsedArguments["arguments"] as? [String: Any]) ?? [:]
                let startedAt = Date()
                onProgress?("正在解析 MCP prompt：\(promptDescriptor.serverName) / \(promptDescriptor.name)")
                let result = try await connectionManager.getPrompt(
                    promptDescriptor.name,
                    arguments: promptArguments,
                    on: server,
                    onProgress: onProgress
                )
                appendLog(serverID: server.id, serverName: server.name, action: "get_prompt", target: promptDescriptor.name, status: .success, detail: "Resolved MCP prompt.", startedAt: startedAt, traceContext: traceContext)
                let rendered = renderPromptResolution(serverName: promptDescriptor.serverName, promptName: promptDescriptor.name, payload: result)
                let operation = capabilityOperationRecord(
                    id: operationId,
                    toolName: toolCallName,
                    title: "MCP · \(promptDescriptor.name)",
                    summary: "解析 MCP prompt",
                    detailLines: [
                        "Server: \(promptDescriptor.serverName)",
                        "Prompt: \(promptDescriptor.name)"
                    ]
                )
                return normalizedLargeOutcome(
                    output: rendered,
                    toolLabel: toolCallName,
                    followupContextMessage: "上一个 MCP prompt 已解析完成，请直接基于工具结果继续，不要重复展开或再次输出完整模板内容。",
                    operation: operation
                )
            default:
                return ToolExecutionOutcome(output: "[错误] 未知 MCP capability 工具：\(toolCallName)")
            }
        } catch {
            if let server = try? resolveServer(from: (try? decodeArguments(arguments)) ?? [:]) {
                appendLog(serverID: server.id, serverName: server.name, action: toolCallName, target: toolCallName, status: .failed, detail: error.localizedDescription, startedAt: nil, traceContext: traceContext)
            }
            return ToolExecutionOutcome(output: "[错误] MCP capability 调用失败：\(error.localizedDescription)")
        }
    }

    private func appendLog(
        serverID: UUID,
        serverName: String,
        action: String,
        target: String,
        status: MCPActivityStatus,
        detail: String,
        startedAt: Date?,
        traceContext: TraceContext? = nil
    ) {
        let durationMilliseconds = startedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        activityLogs.insert(
            MCPActivityLog(
                id: UUID(),
                serverID: serverID,
                serverName: serverName,
                action: action,
                target: target,
                status: status,
                detail: detail,
                createdAt: Date(),
                durationMilliseconds: durationMilliseconds
            ),
            at: 0
        )
        if activityLogs.count > 120 {
            activityLogs = Array(activityLogs.prefix(120))
        }
        persistActivityLogs()
        let logStatus: LogStatus
        let logLevel: LogLevel
        let metadata: [String: LogValue]
        let baseMetadata: [String: LogValue] = [
            "server_id": .string(serverID.uuidString),
            "server_name": .string(serverName),
            "action": .string(action),
            "target": .string(target),
            "detail_preview": .string(LogRedactor.preview(detail))
        ]
        switch status {
        case .success:
            logStatus = .succeeded
            logLevel = .info
            metadata = baseMetadata
        case .failed:
            logStatus = .failed
            logLevel = .error
            metadata = LogMetadataBuilder.failure(
                errorKind: detail.lowercased().contains("timeout") || detail.contains("超时") ? .timeout : .unknown,
                recoveryAction: .fallback,
                isUserVisible: true,
                extra: baseMetadata
            )
        case .denied:
            logStatus = .skipped
            logLevel = .warn
            metadata = LogMetadataBuilder.failure(
                errorKind: .permission,
                recoveryAction: .abort,
                isUserVisible: true,
                extra: baseMetadata
            )
        }
        Task {
            await LoggerService.shared.log(
                level: logLevel,
                category: .mcp,
                event: "mcp_\(action)",
                traceContext: traceContext,
                status: logStatus,
                durationMs: durationMilliseconds.map(Double.init),
                summary: "MCP \(action)：\(serverName) / \(target)",
                metadata: metadata
            )
        }
    }

    private func authorizationRisk(for descriptor: MCPToolDescriptor) -> MCPAuthorizationRisk {
        if descriptor.hints.destructiveHint == true {
            return .requiresApproval
        }
        if descriptor.hints.readOnlyHint == true {
            return .safeAutoAllow
        }
        if descriptor.hints.idempotentHint == true && descriptor.hints.openWorldHint != true {
            return .safeAutoAllow
        }
        return .requiresApproval
    }

    private func serverFingerprint(_ server: MCPServerConfig) -> String {
        let headerFingerprint = server.additionalHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key.lowercased())=\($0.value.lowercased())" }
            .joined(separator: "\u{1F}")
        let secretHeaderFingerprint = server.secretAdditionalHeaderNames
            .map { $0.lowercased() }
            .sorted()
            .joined(separator: "\u{1F}")
        return [
            server.transportKind.rawValue,
            server.name.lowercased(),
            server.command.lowercased(),
            server.arguments.joined(separator: "\u{1F}").lowercased(),
            server.endpointURL.lowercased(),
            server.authKind.rawValue,
            server.authHeaderName.lowercased(),
            headerFingerprint,
            secretHeaderFingerprint
        ].joined(separator: "\u{1E}")
    }

    private func normalizedToolRuleNames(_ toolNames: [String]) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        for item in toolNames {
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    private func splitAdditionalHeaders(_ headers: [String: String]) -> (plainHeaders: [String: String], secretHeaders: [String: String]) {
        var plainHeaders: [String: String] = [:]
        var secretHeaders: [String: String] = [:]

        for (rawName, rawValue) in headers {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            if looksLikeAuthenticationHeader(name: name) {
                secretHeaders[name] = value
            } else {
                plainHeaders[name] = value
            }
        }

        return (plainHeaders, secretHeaders)
    }

    private func mergedSecretHeaderNames(existing: [String], added: [String]) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        for name in existing + added {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func secretHeaders(from server: MCPServerConfig) -> [String: String] {
        let split = splitAdditionalHeaders(server.additionalHeaders)
        if !split.secretHeaders.isEmpty {
            return split.secretHeaders
        }
        return server.secretAdditionalHeaderNames.reduce(into: [String: String]()) { result, name in
            if let value = keychainStore.additionalSecretHeaders(for: server.id)[name] {
                result[name] = value
            }
        }
    }

    private func looksLikeAuthenticationHeader(name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("token")
            || normalized.contains("auth")
            || normalized.contains("api-key")
            || normalized.contains("apikey")
            || normalized == "x-api-key"
    }

    private func resolveServer(from arguments: [String: Any]) throws -> MCPServerConfig? {
        let serverID = (arguments["server_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serverName = (arguments["server_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !serverID.isEmpty, let uuid = UUID(uuidString: serverID), let server = servers.first(where: { $0.id == uuid }) {
            return server
        }

        if !serverName.isEmpty {
            let matches = servers.filter { $0.name.compare(serverName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            if let single = matches.first, matches.count == 1 {
                return single
            }
            if matches.count > 1 {
                throw NSError(domain: "MCPServerManager", code: 20, userInfo: [NSLocalizedDescriptionKey: "存在多个同名 MCP server，请改用 server_id。"])
            }
        }

        return nil
    }

    private func resolveResources(from arguments: [String: Any]) throws -> [MCPResourceDescriptor] {
        if let server = try resolveServer(from: arguments) {
            return resources(for: server.id)
        }
        return discoveredResources
    }

    private func resolveResource(from arguments: [String: Any]) throws -> MCPResourceDescriptor {
        guard let uri = (arguments["uri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !uri.isEmpty else {
            throw NSError(domain: "MCPServerManager", code: 21, userInfo: [NSLocalizedDescriptionKey: "读取 MCP resource 需要提供 uri。"])
        }

        let candidates: [MCPResourceDescriptor]
        if let server = try resolveServer(from: arguments) {
            candidates = resources(for: server.id)
        } else {
            candidates = discoveredResources
        }

        let matches = candidates.filter { $0.uri == uri }
        guard let resource = matches.first else {
            throw NSError(domain: "MCPServerManager", code: 22, userInfo: [NSLocalizedDescriptionKey: "未找到匹配的 MCP resource：\(uri)"])
        }
        if matches.count > 1 {
            throw NSError(domain: "MCPServerManager", code: 23, userInfo: [NSLocalizedDescriptionKey: "多个 server 中存在相同 resource URI，请补充 server_id。"])
        }
        return resource
    }

    private func resolvePrompts(from arguments: [String: Any]) throws -> [MCPPromptDescriptor] {
        if let server = try resolveServer(from: arguments) {
            return prompts(for: server.id)
        }
        return discoveredPrompts
    }

    private func resolvePrompt(from arguments: [String: Any]) throws -> MCPPromptDescriptor {
        guard let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw NSError(domain: "MCPServerManager", code: 24, userInfo: [NSLocalizedDescriptionKey: "读取 MCP prompt 需要提供 name。"])
        }

        let candidates: [MCPPromptDescriptor]
        if let server = try resolveServer(from: arguments) {
            candidates = prompts(for: server.id)
        } else {
            candidates = discoveredPrompts
        }

        let matches = candidates.filter { $0.name == name }
        guard let prompt = matches.first else {
            throw NSError(domain: "MCPServerManager", code: 25, userInfo: [NSLocalizedDescriptionKey: "未找到匹配的 MCP prompt：\(name)"])
        }
        if matches.count > 1 {
            throw NSError(domain: "MCPServerManager", code: 26, userInfo: [NSLocalizedDescriptionKey: "多个 server 中存在同名 prompt，请补充 server_id。"])
        }
        return prompt
    }

    private func renderResourceList(_ resources: [MCPResourceDescriptor]) -> String {
        guard !resources.isEmpty else {
            return "[MCP Resources]\n当前没有可用的 MCP resource。"
        }
        let lines = resources.map { resource in
            var line = "- [\(resource.serverName)] \(resource.name) -> \(resource.uri)"
            if let mimeType = resource.mimeType, !mimeType.isEmpty {
                line += " (\(mimeType))"
            }
            if !resource.resourceDescription.isEmpty {
                line += "\n  \(resource.resourceDescription)"
            }
            return line
        }
        return "[MCP Resources]\n" + lines.joined(separator: "\n")
    }

    private func renderPromptList(_ prompts: [MCPPromptDescriptor]) -> String {
        guard !prompts.isEmpty else {
            return "[MCP Prompts]\n当前没有可用的 MCP prompt。"
        }
        let lines = prompts.map { prompt in
            let args = prompt.arguments.map { argument in
                argument.isRequired ? "\(argument.name)*" : argument.name
            }.joined(separator: ", ")
            var line = "- [\(prompt.serverName)] \(prompt.name)"
            if !args.isEmpty {
                line += " (args: \(args))"
            }
            if !prompt.promptDescription.isEmpty {
                line += "\n  \(prompt.promptDescription)"
            }
            return line
        }
        return "[MCP Prompts]\n" + lines.joined(separator: "\n")
    }

    private func renderPromptResolution(serverName: String, promptName: String, payload: [String: Any]) -> String {
        var sections: [String] = [
            "[MCP Prompt]",
            "Server: \(serverName)",
            "Prompt: \(promptName)"
        ]

        if let description = payload["description"] as? String, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Description: \(description.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let messages = (payload["messages"] as? [[String: Any]] ?? []).compactMap { message -> String? in
            let role = (message["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "message"
            let content = renderPromptMessageContent(message["content"])
            guard !content.isEmpty else { return nil }
            return "\(role): \(content)"
        }

        if !messages.isEmpty {
            sections.append("")
            sections.append("Resolved Messages:")
            sections.append(contentsOf: messages.map { "- \($0)" })
        }

        return sections.joined(separator: "\n")
    }

    private func renderPromptMessageContent(_ content: Any?) -> String {
        if let string = content as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = content as? [[String: Any]] {
            let parts = array.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let type = item["type"] as? String, let data = item["data"] {
                    return "\(type): \(String(describing: data))"
                }
                return nil
            }.filter { !$0.isEmpty }
            return parts.joined(separator: "\n")
        }
        if let dictionary = content as? [String: Any], JSONSerialization.isValidJSONObject(dictionary),
           let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return ""
    }

    private func capabilityOperationRecord(
        id: String,
        toolName: String,
        title: String,
        summary: String,
        detailLines: [String]
    ) -> FileOperationRecord {
        FileOperationRecord(
            id: id,
            toolName: toolName,
            title: title,
            summary: summary,
            detailLines: detailLines,
            createdAt: Date(),
            undoAction: nil,
            isUndone: false
        )
    }
}

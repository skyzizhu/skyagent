import Foundation

enum AgentEvent {
    case knowledgeRetrieved([RetrievalHit])
    case assistantTurnStarted
    case assistantDelta(String)
    case assistantToolCalls([ToolCallRecord])
    case toolMatched(ToolExecutionRecord)
    case toolStarted(ToolExecutionRecord, String)
    case toolProgress(ToolExecutionRecord, String)
    case toolCompleted(ToolExecutionRecord, String, FileOperationRecord?, String?, String?, [String]?)
}

enum AgentError: Error, LocalizedError {
    case toolLoopLimitExceeded
    case emptyAssistantResponse

    var errorDescription: String? {
        switch self {
        case .toolLoopLimitExceeded:
            return "工具调用轮次过多，已停止以避免死循环"
        case .emptyAssistantResponse:
            return "模型没有返回可见回复"
        }
    }
}

final class AgentOrchestrator {
    private struct KnowledgeContextPayload {
        let context: String
        let hits: [RetrievalHit]
    }

    private struct KnowledgeRouteCandidate: Sendable {
        let libraryID: UUID
        let libraryName: String
        let routeScore: Double
        let documentCount: Int
        let isWorkspaceLibrary: Bool
    }

    private let llm: LLMService
    private let maxToolRounds = 8
    private let toolExecutionQueue = DispatchQueue(label: "SkyAgent.ToolExecution", qos: .userInitiated)
    private let repeatProtectedTools: Set<String> = [
        ToolDefinition.ToolName.runSkillScript.rawValue,
        ToolDefinition.ToolName.writeFile.rawValue,
        ToolDefinition.ToolName.writeAssistantContentToFile.rawValue,
        ToolDefinition.ToolName.writeMultipleFiles.rawValue,
        ToolDefinition.ToolName.movePaths.rawValue,
        ToolDefinition.ToolName.deletePaths.rawValue
    ]

    init(llm: LLMService) {
        self.llm = llm
    }

    func run(
        conversation: Conversation,
        settings: AppSettings,
        traceContext: TraceContext? = nil,
        preActivatedSkillIDs: [String] = [],
        requestApproval: @escaping (OperationPreview) async -> Bool,
        onEvent: @escaping (AgentEvent) async -> Void
    ) async throws {
        let effectiveTraceContext = traceContext?.with(conversationID: conversation.id) ?? TraceContext(conversationID: conversation.id)
        let contextPreparationStartedAt = Date()
        await LoggerService.shared.log(
            category: .context,
            event: "context_prepare_started",
            traceContext: effectiveTraceContext,
            status: .started,
            summary: "开始准备模型上下文",
            metadata: [
                "conversation_message_count": .int(conversation.messages.count),
                "preactivated_skill_count": .int(preActivatedSkillIDs.count)
            ]
        )

        let availableSkills = SkillManager.shared.availableSkills
        let mergedActivatedSkillIDs = Array(NSOrderedSet(array: conversation.activatedSkillIDs + preActivatedSkillIDs)) as? [String] ?? conversation.activatedSkillIDs
        var effectiveConversation = conversation
        effectiveConversation.activatedSkillIDs = mergedActivatedSkillIDs
        let activatedSkillMessages = SkillManager.shared.activationMessages(for: mergedActivatedSkillIDs)
        let mcpTooling = MCPServerManager.shared.tooling(for: effectiveConversation)

        ToolRunner.shared.configure(
            for: effectiveConversation,
            globalSandboxDir: settings.ensureSandboxDir(),
            allowedReadRoots: SkillManager.shared.readableRoots
        )
        let toolDefinitions = ToolDefinition.definitions(for: conversation.filePermissionMode, hasSkills: !availableSkills.isEmpty) + mcpTooling.definitions

        var rawMessages = conversation.messages
        if MemoryService.shared.shouldCompress(messages: rawMessages) {
            rawMessages = MemoryService.shared.compress(messages: rawMessages, contextState: effectiveConversation.contextState)
        }

        var preparedMessages: [Message] = []
        let memoryBuildStartedAt = Date()
        let workspacePath = effectiveConversation.sandboxDir.isEmpty ? settings.ensureSandboxDir() : effectiveConversation.sandboxDir
        WorkspaceMemoryService.shared.ensureWorkspaceArtifacts(for: workspacePath)
        let workspaceMemoryContext = WorkspaceMemoryService.shared.loadWorkspaceMemoryContext(for: workspacePath, maxCharacters: 900)
        let workspaceProfileContext = WorkspaceMemoryService.shared.loadWorkspaceProfileContext(for: workspacePath, maxCharacters: 700)
        let globalMemoryContext = MemoryService.shared.buildMemoryContext(
            query: effectiveConversation.memoryRetrievalQuery,
            maxResults: 4,
            maxTokens: 80
        )
        let sessionMemoryContext = effectiveConversation.contextState.systemContext()
        let workspaceMemoryTokens = ChatContextUsageEstimator.estimateTokenCount(for: workspaceMemoryContext)
        let workspaceProfileTokens = ChatContextUsageEstimator.estimateTokenCount(for: workspaceProfileContext)
        let globalMemoryTokens = ChatContextUsageEstimator.estimateTokenCount(for: globalMemoryContext)
        let sessionMemoryTokens = ChatContextUsageEstimator.estimateTokenCount(for: sessionMemoryContext)
        let totalMemoryTokens = workspaceMemoryTokens + workspaceProfileTokens + globalMemoryTokens + sessionMemoryTokens
        let knowledgeContextStartedAt = Date()
        let knowledgePayload = await buildKnowledgeContext(for: effectiveConversation, traceContext: effectiveTraceContext)
        let knowledgeContext = knowledgePayload.context
        let knowledgeTokens = ChatContextUsageEstimator.estimateTokenCount(for: knowledgeContext)
        await LoggerService.shared.log(
            category: .memory,
            event: "memory_context_built",
            traceContext: effectiveTraceContext,
            status: .succeeded,
            durationMs: Date().timeIntervalSince(memoryBuildStartedAt) * 1000,
            summary: (workspaceMemoryContext.isEmpty && workspaceProfileContext.isEmpty && globalMemoryContext.isEmpty && sessionMemoryContext.isEmpty) ? "未命中会话、工作区与长期记忆上下文" : "已构建会话、工作区与长期记忆上下文",
            metadata: [
                "workspace_path": .string(LogRedactor.preview(workspacePath, maxLength: 120)),
                "workspace_memory_length": .int(workspaceMemoryContext.count),
                "workspace_memory_tokens": .int(workspaceMemoryTokens),
                "workspace_profile_length": .int(workspaceProfileContext.count),
                "workspace_profile_tokens": .int(workspaceProfileTokens),
                "query_preview": .string(LogRedactor.preview(effectiveConversation.memoryRetrievalQuery, maxLength: 100)),
                "global_memory_length": .int(globalMemoryContext.count),
                "global_memory_tokens": .int(globalMemoryTokens),
                "session_memory_length": .int(sessionMemoryContext.count),
                "session_memory_tokens": .int(sessionMemoryTokens),
                "memory_total_tokens": .int(totalMemoryTokens),
                "knowledge_context_length": .int(knowledgeContext.count),
                "knowledge_context_tokens": .int(knowledgeTokens),
                "knowledge_context_ms": .double(Date().timeIntervalSince(knowledgeContextStartedAt) * 1000)
            ]
        )
        if !workspaceMemoryContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: workspaceMemoryContext))
        }
        if !workspaceProfileContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: workspaceProfileContext))
        }
        if !globalMemoryContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: globalMemoryContext))
        }
        if !knowledgeContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: knowledgeContext))
        }
        preparedMessages.append(
            Message(
                role: .system,
                content: """
                [文件操作规则]
                1. 如果用户要求重命名、移动、批量修改后缀，请优先使用 move_paths。
                2. 如果用户要求删除文件或目录，请优先使用 delete_paths。
                3. 不要为了重命名、删除、批量改后缀而创建 shell 脚本、bash 文件或辅助命令文件。
                4. 如果用户要求“把 10 个 txt 改成 ini”这类后缀变更，请优先基于现有文件名构造 move_paths；必要时先用 list_files 确认文件列表。
                5. 如果用户要求“删除刚刚创建的文件”，请优先直接调用 delete_paths；不要生成 delete.sh、delete_files.sh 或类似脚本。
                6. 如果是 skill 脚本，只在确实需要时调用一次；不要在同一轮里重复执行相同参数的脚本。
                7. 如果任务是把长篇 Markdown、TXT、PRD、方案、总结等正文写入单个文件，优先先在 assistant 正文里完整生成内容，再使用 write_assistant_content_to_file 落盘；不要把整段长文重新塞进 write_file 的 content 参数。
                [/文件操作规则]
                """
            )
        )
        preparedMessages.append(
            Message(
                role: .system,
                content: """
                [列表与计数规则]
                1. 当用户要求“总共有多少个”“统计数量”“看一下有多少张图片/多少个文件”时，优先返回数量结论，不要输出完整列表。
                2. 当结果集很大时，只返回总数、必要分类和少量样例（例如前 10-20 条），不要把成百上千条路径、文件名或全文直接输出给用户。
                3. 简单浅层浏览可以优先使用 list_files；但只要问题涉及递归统计、按扩展名/类型过滤、跨多层目录树计数，就不要依赖顶层 list_files 结果直接下结论。
                4. 对“统计图片数量”“统计某类文件数量”这类问题，必须先完成真实计数，再回答结论；如果顶层只看到文件夹，不能直接推断目标数量为 0。
                5. 当需要递归统计、按扩展名过滤或快速返回总数时，优先使用能直接返回数量和少量样例的 shell，不要生成会输出完整大列表的命令。
                6. 如果工具结果已经被系统标记为“大输出摘要”，请直接基于摘要回答，不要再次尝试打印完整结果。
                [/列表与计数规则]
                """
            )
        )
        preparedMessages.append(
            Message(
                role: .system,
                content: """
                [Skill 优先路由规则]
                1. 如果当前请求强匹配某个已安装 skill 的 name、description、trigger hints、default_prompt 等元数据，先 activate_skill，再继续执行。
                2. 当 skill 已经覆盖当前任务时，不要先做无关的通用目录探索或文件阅读；只有当用户明确要求本地文件作为依据，或 skill 说明要求读取本地文件时，才去 list_files、read_file。
                3. 如果请求既可能是 skill 任务，也可能涉及项目上下文，优先结合当前对话、记忆和已知信息先执行 skill；只有缺少关键事实时，才补充读取工作区文件。
                [/Skill 优先路由规则]
                """
            )
        )
        if let mcpCatalogPrompt = mcpTooling.catalogPrompt {
            preparedMessages.append(Message(role: .system, content: mcpCatalogPrompt))
        }
        if let catalogPrompt = SkillManager.shared.buildCatalogPrompt(for: availableSkills) {
            preparedMessages.append(Message(role: .system, content: catalogPrompt))
        }
        if !sessionMemoryContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: sessionMemoryContext))
        }
        preparedMessages.append(contentsOf: activatedSkillMessages.map { Message(role: .system, content: $0) })
        preparedMessages.append(contentsOf: rawMessages)
        if let summary = MemoryService.shared.loadSummary(
            convId: conversation.id,
            segmentStartedAt: effectiveConversation.contextState.segmentStartedAt
        ) {
            let summaryMsg = Message(role: .system, content: "[本次对话的历史摘要]\n\(summary)")
            preparedMessages.insert(summaryMsg, at: 0)
        }

        var workingMessages = Self.buildChatMessages(from: preparedMessages)
        await LoggerService.shared.log(
            category: .context,
            event: "context_prepare_finished",
            traceContext: effectiveTraceContext,
            status: .succeeded,
            durationMs: Date().timeIntervalSince(contextPreparationStartedAt) * 1000,
            summary: "模型上下文准备完成",
            metadata: [
                "prepared_message_count": .int(preparedMessages.count),
                "working_message_count": .int(workingMessages.count),
                "tool_definition_count": .int(toolDefinitions.count),
                "activated_skill_count": .int(mergedActivatedSkillIDs.count),
                "mcp_tool_count": .int(mcpTooling.definitions.count)
            ]
        )
        var remainingToolRounds = maxToolRounds
        var executedToolSignatures: [String: ToolExecutionOutcome] = [:]
        var successfulSkillScriptRuns: Set<String> = []

        if !knowledgePayload.hits.isEmpty {
            await onEvent(.knowledgeRetrieved(knowledgePayload.hits))
        }

        while true {
            try Task.checkCancellation()
            await onEvent(.assistantTurnStarted)

            let response = try await llm.complete(
                messages: workingMessages,
                toolDefinitions: toolDefinitions,
                traceContext: effectiveTraceContext,
                onToolCallHint: { partialToolCall in
                    let execution = ToolExecutionRecord(
                        id: partialToolCall.id,
                        name: partialToolCall.name,
                        arguments: partialToolCall.arguments
                    )
                    await onEvent(.toolMatched(execution))
                }
            ) { delta in
                await onEvent(.assistantDelta(delta))
            }

            if !response.toolCalls.isEmpty {
                await onEvent(.assistantToolCalls(response.toolCalls))
            }

            workingMessages.append(
                LLMService.ChatMessage(
                    role: "assistant",
                    content: response.content,
                    toolCalls: response.toolCalls.isEmpty ? nil : response.toolCalls
                )
            )

            guard !response.toolCalls.isEmpty else { return }

            remainingToolRounds -= 1
            guard remainingToolRounds >= 0 else {
                throw AgentError.toolLoopLimitExceeded
            }

            for call in response.toolCalls {
                try Task.checkCancellation()

                let execution = ToolExecutionRecord(id: call.id, name: call.name, arguments: call.arguments)
                let toolTraceContext = effectiveTraceContext.with(operationID: call.id)
                let toolStartedAt = Date()
                await LoggerService.shared.log(
                    category: Self.logCategory(for: call.name),
                    event: "tool_started",
                    traceContext: toolTraceContext,
                    status: .started,
                    summary: Self.toolStartSummary(for: call),
                    metadata: [
                        "tool_name": .string(call.name),
                        "arguments_preview": .string(LogRedactor.preview(call.arguments))
                    ]
                )
                await onEvent(.toolStarted(execution, Self.toolStartSummary(for: call)))
                await Task.yield()
                let signature = Self.toolSignature(for: call)
                let skillScriptRunKey = Self.skillScriptRunKey(for: call)
                let outcome: ToolExecutionOutcome
                if repeatProtectedTools.contains(call.name), let previous = executedToolSignatures[signature] {
                    outcome = ToolExecutionOutcome(
                        output: "⚠️ 已跳过重复工具调用：\(call.name)\n同一轮中相同参数的调用已经执行过一次，不再重复执行。\n请直接基于上一次结果继续。",
                        operation: nil,
                        activatedSkillID: previous.activatedSkillID,
                        skillContextMessage: previous.skillContextMessage,
                        followupContextMessage: "检测到同一轮里的重复工具调用 \(call.name)。系统已跳过重复执行，请不要再次调用相同参数，直接基于第一次结果继续。"
                    )
                    await LoggerService.shared.log(
                        level: .warn,
                        category: Self.logCategory(for: call.name),
                        event: "tool_skipped_repeat",
                        traceContext: toolTraceContext,
                        status: .skipped,
                        durationMs: Date().timeIntervalSince(toolStartedAt) * 1000,
                        summary: "已跳过重复工具调用：\(call.name)",
                        metadata: ["tool_name": .string(call.name)]
                    )
                } else if call.name == ToolDefinition.ToolName.runSkillScript.rawValue,
                          let skillScriptRunKey,
                          successfulSkillScriptRuns.contains(skillScriptRunKey) {
                    outcome = ToolExecutionOutcome(
                        output: """
                        ⚠️ 已跳过重复 skill 脚本执行：\(call.name)
                        同一轮里，skill 脚本 \(skillScriptRunKey) 已成功执行过一次。
                        请直接基于第一次脚本结果继续，不要重复再次运行同一个脚本。
                        """,
                        operation: nil,
                        followupContextMessage: "同一轮中，run_skill_script 对同一个 skill/path 已成功执行过一次。除非用户明确要求再次运行，否则不要重复执行同一个脚本，请直接基于第一次结果继续。"
                    )
                    await LoggerService.shared.log(
                        level: .warn,
                        category: .skill,
                        event: "tool_skipped_repeat",
                        traceContext: toolTraceContext,
                        status: .skipped,
                        durationMs: Date().timeIntervalSince(toolStartedAt) * 1000,
                        summary: "已跳过重复 skill 脚本执行",
                        metadata: [
                            "tool_name": .string(call.name),
                            "skill_script_key": .string(skillScriptRunKey)
                        ]
                    )
                } else {
                    outcome = await executeToolCall(
                        call,
                        execution: execution,
                        traceContext: toolTraceContext,
                        assistantContentForToolCall: response.content,
                        requestApproval: requestApproval,
                        onEvent: onEvent
                    )
                    if repeatProtectedTools.contains(call.name) {
                        executedToolSignatures[signature] = outcome
                    }
                    if call.name == ToolDefinition.ToolName.runSkillScript.rawValue,
                       let skillScriptRunKey,
                       Self.toolOutcomeIndicatesSuccess(outcome, toolName: call.name) {
                        successfulSkillScriptRuns.insert(skillScriptRunKey)
                    }
                }
                await LoggerService.shared.log(
                    level: Self.logLevel(for: outcome, toolName: call.name),
                    category: Self.logCategory(for: call.name),
                    event: Self.logEventName(for: outcome, toolName: call.name),
                    traceContext: toolTraceContext,
                    status: Self.logStatus(for: outcome, toolName: call.name),
                    durationMs: Date().timeIntervalSince(toolStartedAt) * 1000,
                    summary: Self.logSummary(for: outcome, call: call),
                    metadata: Self.logMetadata(for: outcome, call: call)
                )
                await onEvent(.toolCompleted(
                    execution,
                    outcome.output,
                    outcome.operation,
                    outcome.activatedSkillID,
                    outcome.previewImagePath,
                    outcome.previewImagePaths
                ))

                workingMessages.append(
                    LLMService.ChatMessage(
                        role: "tool",
                        content: outcome.modelOutput ?? outcome.output,
                        toolCallId: call.id
                    )
                )

                if let skillContextMessage = outcome.skillContextMessage {
                    workingMessages.append(
                        LLMService.ChatMessage(
                            role: "system",
                            content: skillContextMessage
                        )
                    )
                }

                if let followupContextMessage = outcome.followupContextMessage {
                    workingMessages.append(
                        LLMService.ChatMessage(
                            role: "system",
                            content: followupContextMessage
                        )
                    )
                }
            }
        }
    }

    private static func toolSignature(for call: ToolCallRecord) -> String {
        let normalizedArguments = call.arguments
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard let tool = ToolDefinition.ToolName(rawValue: call.name),
              let params = ToolArgumentParser.parse(arguments: normalizedArguments, for: tool) else {
            return "\(call.name)\n\(normalizedArguments)"
        }

        switch tool {
        case .runSkillScript:
            var canonical: [String: Any] = [:]
            canonical["skill_name"] = normalizedString(params["skill_name"])
            canonical["path"] = normalizedPathString(params["path"])
            canonical["args"] = normalizedStringArray(params["args"])
            canonical["stdin"] = normalizedStringPreservingBody(params["stdin"])
            return serializedToolSignature(name: call.name, payload: canonical)

        case .writeAssistantContentToFile:
            var canonical: [String: Any] = [:]
            canonical["path"] = normalizedPathString(params["path"])
            return serializedToolSignature(name: call.name, payload: canonical)

        case .writeMultipleFiles:
            let files = (params["files"] as? [[String: Any]] ?? [])
                .map { file in
                    [
                        "path": normalizedPathString(file["path"]),
                        "content": normalizedStringPreservingBody(file["content"])
                    ]
                }
                .sorted { ($0["path"] ?? "") < ($1["path"] ?? "") }
            return serializedToolSignature(name: call.name, payload: ["files": files])

        case .movePaths:
            let items = (params["items"] as? [[String: Any]] ?? [])
                .map { item in
                    [
                        "source_path": normalizedPathString(item["source_path"]),
                        "destination_path": normalizedPathString(item["destination_path"])
                    ]
                }
                .sorted {
                    let lhs = ($0["source_path"] ?? "") + "->" + ($0["destination_path"] ?? "")
                    let rhs = ($1["source_path"] ?? "") + "->" + ($1["destination_path"] ?? "")
                    return lhs < rhs
                }
            return serializedToolSignature(name: call.name, payload: ["items": items])

        case .deletePaths:
            let paths = normalizedStringArray(params["paths"]).sorted()
            return serializedToolSignature(name: call.name, payload: ["paths": paths])

        case .writeFile:
            let canonical: [String: Any] = [
                "path": normalizedPathString(params["path"]),
                "content": normalizedStringPreservingBody(params["content"])
            ]
            return serializedToolSignature(name: call.name, payload: canonical)

        default:
            return "\(call.name)\n\(normalizedArguments)"
        }
    }

    private static func skillScriptRunKey(for call: ToolCallRecord) -> String? {
        guard call.name == ToolDefinition.ToolName.runSkillScript.rawValue,
              let tool = ToolDefinition.ToolName(rawValue: call.name),
              let params = ToolArgumentParser.parse(arguments: call.arguments, for: tool) else {
            return nil
        }

        let skillName = normalizedString(params["skill_name"]).lowercased()
        let path = normalizedPathString(params["path"]).lowercased()
        guard !skillName.isEmpty, !path.isEmpty else { return nil }
        return "\(skillName)::\(path)"
    }

    private static func toolOutcomeIndicatesSuccess(_ outcome: ToolExecutionOutcome, toolName: String) -> Bool {
        if toolName == ToolDefinition.ToolName.runSkillScript.rawValue {
            return outcome.output.contains("[Skill script result]") && outcome.output.contains("Status: success")
        }
        return !outcome.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[错误]")
    }

    private static func serializedToolSignature(name: String, payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "\(name)\n\(payload)"
        }
        return "\(name)\n\(json)"
    }

    private static func normalizedString(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func normalizedStringPreservingBody(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func normalizedPathString(_ value: Any?) -> String {
        let string = normalizedString(value)
        guard !string.isEmpty else { return "" }
        return NSString(string: string).standardizingPath
    }

    private static func normalizedStringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            guard let string = element as? String else { return nil }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
        }
    }

    private static func normalizedInteger(_ value: Any?) -> Int {
        if let intValue = value as? Int {
            return intValue
        }
        if let stringValue = value as? String, let intValue = Int(stringValue) {
            return intValue
        }
        return 0
    }

    private func executeToolCall(
        _ call: ToolCallRecord,
        execution: ToolExecutionRecord,
        traceContext: TraceContext?,
        assistantContentForToolCall: String,
        requestApproval: @escaping (OperationPreview) async -> Bool,
        onEvent: @escaping (AgentEvent) async -> Void
    ) async -> ToolExecutionOutcome {
        let progressHandler: (String) -> Void = { progress in
            Task {
                await onEvent(.toolProgress(execution, progress))
            }
        }

        if MCPServerManager.shared.handlesTool(named: call.name) {
            switch MCPServerManager.shared.authorizationDecision(
                for: call.name,
                arguments: call.arguments,
                operationId: call.id
            ) {
            case .allowed:
                break
            case .requiresApproval(let preview):
                let approved = await requestApproval(preview)
                guard approved else {
                    MCPServerManager.shared.recordApprovalDenied(for: call.name)
                    return ToolExecutionOutcome(
                        output: """
                        ⚠️ 已取消 MCP 工具调用
                        Server preview: \(preview.summary)
                        """
                    )
                }
            case .rejected(let outcome):
                return outcome
            }
            await onEvent(.toolProgress(execution, Self.toolRunningSummary(for: call)))
            await Task.yield()
            return await MCPServerManager.shared.executeTool(
                named: call.name,
                arguments: call.arguments,
                operationId: call.id,
                traceContext: traceContext,
                onProgress: progressHandler
            )
        }

        if call.name == ToolDefinition.ToolName.webFetch.rawValue
            || call.name == ToolDefinition.ToolName.webSearch.rawValue {
            await onEvent(.toolProgress(execution, Self.toolRunningSummary(for: call)))
            await Task.yield()
            return await ToolRunner.shared.execute(
                name: call.name,
                arguments: call.arguments,
                operationId: call.id,
                assistantContentOverride: call.name == ToolDefinition.ToolName.writeAssistantContentToFile.rawValue ? assistantContentForToolCall : nil,
                onProgress: progressHandler
            )
        }

        await onEvent(.toolProgress(execution, Self.toolRunningSummary(for: call)))
        await Task.yield()
        return await withCheckedContinuation { continuation in
            toolExecutionQueue.async {
                let outcome = ToolRunner.shared.executeBlocking(
                    name: call.name,
                    arguments: call.arguments,
                    operationId: call.id,
                    assistantContentOverride: call.name == ToolDefinition.ToolName.writeAssistantContentToFile.rawValue ? assistantContentForToolCall : nil,
                    onProgress: progressHandler
                )
                continuation.resume(returning: outcome)
            }
        }
    }

    private static func buildChatMessages(from messages: [Message]) -> [LLMService.ChatMessage] {
        messages.compactMap { message in
            switch message.role {
            case .user, .assistant, .system:
                return LLMService.ChatMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    imageDataURL: message.imageDataURL,
                    toolCalls: message.toolCalls
                )

            case .tool:
                return LLMService.ChatMessage(
                    role: "tool",
                    content: message.content,
                    toolCallId: message.toolExecution?.id
                )
            }
        }
    }

    private static func toolStartSummary(for call: ToolCallRecord) -> String {
        "准备调用 \(ChatStatusComposer.friendlyToolTitle(for: call.name))"
    }

    private static func toolRunningSummary(for call: ToolCallRecord) -> String {
        "正在调用 \(ChatStatusComposer.friendlyToolTitle(for: call.name))"
    }

    private static func logCategory(for toolName: String) -> LogCategory {
        if MCPServerManager.shared.handlesTool(named: toolName) {
            return .mcp
        }

        switch ToolDefinition.ToolName(rawValue: toolName) {
        case .activateSkill, .installSkill, .readSkillResource, .runSkillScript:
            return .skill
        case .shell:
            return .shell
        default:
            return .tool
        }
    }

    private static func logStatus(for outcome: ToolExecutionOutcome, toolName: String) -> LogStatus {
        let output = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("[Skill script timeout]") {
            return .timeout
        }
        if output.contains("已跳过重复工具调用") || output.contains("已跳过重复 skill 脚本执行") {
            return .skipped
        }
        if toolOutcomeIndicatesSuccess(outcome, toolName: toolName) {
            return .succeeded
        }
        return .failed
    }

    private static func logLevel(for outcome: ToolExecutionOutcome, toolName: String) -> LogLevel {
        switch logStatus(for: outcome, toolName: toolName) {
        case .succeeded:
            return .info
        case .skipped, .timeout:
            return .warn
        case .failed:
            return .error
        default:
            return .info
        }
    }

    private static func logEventName(for outcome: ToolExecutionOutcome, toolName: String) -> String {
        switch logStatus(for: outcome, toolName: toolName) {
        case .succeeded:
            return "tool_completed"
        case .skipped:
            return "tool_skipped"
        case .timeout:
            return "tool_timeout"
        case .failed:
            return "tool_failed"
        default:
            return "tool_completed"
        }
    }

    private static func logSummary(for outcome: ToolExecutionOutcome, call: ToolCallRecord) -> String {
        switch logStatus(for: outcome, toolName: call.name) {
        case .succeeded:
            return "工具执行完成：\(call.name)"
        case .skipped:
            return "工具已跳过：\(call.name)"
        case .timeout:
            return "工具执行超时：\(call.name)"
        case .failed:
            return "工具执行失败：\(call.name)"
        default:
            return "工具执行完成：\(call.name)"
        }
    }

    private static func logMetadata(for outcome: ToolExecutionOutcome, call: ToolCallRecord) -> [String: LogValue] {
        let base: [String: LogValue] = [
            "tool_name": .string(call.name),
            "output_preview": .string(LogRedactor.preview(outcome.output))
        ]
        switch logStatus(for: outcome, toolName: call.name) {
        case .timeout:
            return LogMetadataBuilder.failure(
                errorKind: .timeout,
                recoveryAction: .abort,
                isUserVisible: true,
                extra: base
            )
        case .failed:
            return LogMetadataBuilder.failure(
                errorKind: logErrorKind(for: outcome, toolName: call.name),
                recoveryAction: .fallback,
                isUserVisible: true,
                extra: base
            )
        case .skipped:
            return LogMetadataBuilder.failure(
                errorKind: .invalidState,
                recoveryAction: .none,
                isUserVisible: false,
                extra: base
            )
        default:
            return base
        }
    }

    private static func logErrorKind(for outcome: ToolExecutionOutcome, toolName: String) -> LogErrorKind {
        let output = outcome.output.lowercased()
        if toolName == ToolDefinition.ToolName.shell.rawValue, output.contains("exit code:") {
            return .processExitNonzero
        }
        if output.contains("权限") || output.contains("permission") {
            return .permission
        }
        if output.contains("dependency") || output.contains("依赖") {
            return .dependencyMissing
        }
        if output.contains("参数") || output.contains("argument") {
            return .invalidArgs
        }
        return .unknown
    }

    private func buildKnowledgeContext(for conversation: Conversation, traceContext: TraceContext) async -> KnowledgeContextPayload {
        let libraryIDs = conversation.knowledgeLibraryIDs
        guard !libraryIDs.isEmpty else { return KnowledgeContextPayload(context: "", hits: []) }

        let queryText = conversation.messages.reversed().first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackQuery = conversation.memoryRetrievalQuery
        let query = (queryText?.isEmpty == false) ? queryText! : fallbackQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return KnowledgeContextPayload(context: "", hits: [])
        }

        let startedAt = Date()
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_query_started",
            traceContext: traceContext,
            status: .started,
            summary: "知识库检索开始",
            metadata: [
                "library_count": .int(libraryIDs.count),
                "query": .string(query)
            ]
        )

        let routedLibraries = routedKnowledgeLibraries(
            from: libraryIDs,
            query: query,
            workspacePath: conversation.sandboxDir
        )
        let librariesToQuery = Array(routedLibraries.prefix(routedLibraries.count <= 3 ? routedLibraries.count : 4))
        guard !librariesToQuery.isEmpty else {
            return KnowledgeContextPayload(context: "", hits: [])
        }

        await LoggerService.shared.log(
            category: .rag,
            event: "kb_route_selected",
            traceContext: traceContext,
            status: .succeeded,
            summary: "已完成知识库路由",
            metadata: [
                "candidate_count": .int(routedLibraries.count),
                "queried_count": .int(librariesToQuery.count),
                "libraries": .string(librariesToQuery.map(\.libraryName).joined(separator: " | "))
            ]
        )

        var hits: [RetrievalHit] = []
        let maxHitsTotal = 4
        let topKPerLibrary = librariesToQuery.count == 1 ? 4 : 3
        var hitsByLibraryID: [UUID: [RetrievalHit]] = [:]

        await withTaskGroup(of: (KnowledgeRouteCandidate, Result<[RetrievalHit], KnowledgeBaseSidecarError>).self) { group in
            for candidate in librariesToQuery {
                group.addTask {
                    let result = await self.queryKnowledgeWithTimeout(
                        libraryId: candidate.libraryID,
                        query: query,
                        topK: topKPerLibrary
                    )
                    return (candidate, result)
                }
            }

            for await (candidate, result) in group {
                switch result {
                case .success(let libraryHits):
                    hitsByLibraryID[candidate.libraryID] = libraryHits
                case .failure(let error):
                    await LoggerService.shared.log(
                        level: .warn,
                        category: .rag,
                        event: "kb_query_failed",
                        traceContext: traceContext,
                        status: .failed,
                        summary: "知识库检索失败",
                        metadata: [
                            "library_id": .string(candidate.libraryID.uuidString),
                            "library_name": .string(candidate.libraryName),
                            "error": .string(error.description)
                        ]
                    )
                }
            }
        }

        var mergedHits: [(hit: RetrievalHit, combinedScore: Double, routeOrder: Int)] = []
        var seenHitKeys = Set<String>()
        for (routeOrder, candidate) in librariesToQuery.enumerated() {
            let libraryHits = hitsByLibraryID[candidate.libraryID] ?? []
            for hit in libraryHits {
                let hitKey = [
                    hit.documentID?.uuidString ?? "",
                    hit.citation ?? "",
                    hit.source ?? "",
                    String(hit.snippet.prefix(120))
                ].joined(separator: "|")

                guard seenHitKeys.insert(hitKey).inserted else { continue }

                let combinedScore = hit.score + candidate.routeScore * 0.08 - Double(routeOrder) * 0.01
                mergedHits.append((hit: hit, combinedScore: combinedScore, routeOrder: routeOrder))
            }
        }

        mergedHits.sort {
            if $0.combinedScore == $1.combinedScore {
                return $0.routeOrder < $1.routeOrder
            }
            return $0.combinedScore > $1.combinedScore
        }
        hits = mergedHits.prefix(maxHitsTotal).map(\.hit)

        let durationMs = Date().timeIntervalSince(startedAt) * 1000
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_query_finished",
            traceContext: traceContext,
            status: .succeeded,
            durationMs: durationMs,
            summary: hits.isEmpty ? "知识库检索无命中" : "知识库检索完成",
            metadata: [
                "library_count": .int(libraryIDs.count),
                "queried_library_count": .int(librariesToQuery.count),
                "hit_count": .int(hits.count),
                "queried_libraries": .strings(librariesToQuery.map(\.libraryName)),
                "hit_libraries": .strings(orderedHitLibraryNames(from: hits)),
                "top_titles": .strings(
                    hits.prefix(3).compactMap {
                        let title = $0.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return title?.isEmpty == false ? title : nil
                    }
                )
            ]
        )

        guard !hits.isEmpty else { return KnowledgeContextPayload(context: "", hits: []) }

        var lines: [String] = []
        lines.append("[知识库检索结果]")
        lines.append("以下内容来自用户启用的个人知识库，仅供当前回答参考，请在回答中明确引用来源。")
        for (index, hit) in hits.enumerated() {
            let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let libraryName = hit.libraryName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let citation = hit.citation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(index + 1). \(title?.isEmpty == false ? title! : "参考资料")")
            if let libraryName, !libraryName.isEmpty {
                lines.append("知识库：\(libraryName)")
            }
            if !snippet.isEmpty {
                lines.append("片段：\(snippet)")
            }
            if let citation, !citation.isEmpty {
                lines.append("引用：\(citation)")
            }
        }
        return KnowledgeContextPayload(context: lines.joined(separator: "\n"), hits: hits)
    }

    private func queryKnowledgeWithTimeout(
        libraryId: UUID,
        query: String,
        topK: Int,
        timeout: TimeInterval = 4.0
    ) async -> Result<[RetrievalHit], KnowledgeBaseSidecarError> {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            func finish(_ result: Result<[RetrievalHit], KnowledgeBaseSidecarError>) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: result)
            }

            Task.detached(priority: .utility) {
                let result = await KnowledgeBaseService.shared.queryKnowledge(
                    libraryId: libraryId,
                    query: query,
                    topK: topK
                )
                finish(result)
            }

            Task.detached(priority: .utility) {
                let timeoutNs = UInt64(max(1, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNs)
                finish(.failure(.message("知识库检索超时，已跳过本次检索。")))
            }
        }
    }

    private func routedKnowledgeLibraries(
        from libraryIDs: [String],
        query: String,
        workspacePath: String
    ) -> [KnowledgeRouteCandidate] {
        let normalizedWorkspacePath = AppStoragePaths.normalizeSandboxPath(workspacePath)
        let queryText = query.lowercased()
        let queryTokens = Self.routeTokens(from: query)

        return libraryIDs.compactMap { rawID in
            guard let id = UUID(uuidString: rawID),
                  let library = KnowledgeBaseService.shared.library(by: id) else {
                return nil
            }

            let libraryName = library.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceRoot = library.sourceRoot ?? ""
            let sourceTail = sourceRoot.isEmpty ? "" : URL(fileURLWithPath: sourceRoot, isDirectory: true).lastPathComponent
            let metadataTokens = Self.routeTokens(from: "\(libraryName) \(sourceTail)")
            let tokenMatches = queryTokens.intersection(metadataTokens).count
            let normalizedName = libraryName.lowercased()
            let normalizedSourceTail = sourceTail.lowercased()
            let isWorkspaceLibrary = !normalizedWorkspacePath.isEmpty && sourceRoot == normalizedWorkspacePath

            var routeScore = 0.0
            if isWorkspaceLibrary {
                routeScore += 1.35
            }
            if !normalizedName.isEmpty && queryText.contains(normalizedName) {
                routeScore += 0.85
            }
            if !normalizedSourceTail.isEmpty && queryText.contains(normalizedSourceTail) {
                routeScore += 0.6
            }
            routeScore += Double(tokenMatches) * 0.12
            routeScore += min(Double(max(library.documentCount, 1)).squareRoot() * 0.03, 0.18)

            if library.status == .failed {
                routeScore -= 0.8
            }
            if library.documentCount == 0 || library.chunkCount == 0 {
                routeScore -= 0.55
            }

            return KnowledgeRouteCandidate(
                libraryID: id,
                libraryName: libraryName.isEmpty ? "Knowledge Library" : libraryName,
                routeScore: routeScore,
                documentCount: library.documentCount,
                isWorkspaceLibrary: isWorkspaceLibrary
            )
        }
        .sorted {
            if $0.routeScore == $1.routeScore {
                if $0.isWorkspaceLibrary != $1.isWorkspaceLibrary {
                    return $0.isWorkspaceLibrary && !$1.isWorkspaceLibrary
                }
                if $0.documentCount == $1.documentCount {
                    return $0.libraryName.localizedCaseInsensitiveCompare($1.libraryName) == .orderedAscending
                }
                return $0.documentCount > $1.documentCount
            }
            return $0.routeScore > $1.routeScore
        }
    }

    private static func routeTokens(from text: String) -> Set<String> {
        let lowered = text.lowercased()
        var tokens = Set(
            lowered
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
        )

        if let regex = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fff]{2,}", options: []) {
            let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
            for match in regex.matches(in: lowered, options: [], range: range) {
                guard let tokenRange = Range(match.range, in: lowered) else { continue }
                tokens.insert(String(lowered[tokenRange]))
            }
        }

        return tokens
    }

    private func orderedHitLibraryNames(from hits: [RetrievalHit]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for hit in hits {
            let libraryName = hit.libraryName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let libraryName, !libraryName.isEmpty else {
                continue
            }
            guard seen.insert(libraryName).inserted else { continue }
            ordered.append(libraryName)
        }

        return ordered
    }
}

extension AgentOrchestrator: @unchecked Sendable {}

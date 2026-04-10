import Foundation

enum AgentEvent {
    case assistantTurnStarted
    case assistantDelta(String)
    case assistantToolCalls([ToolCallRecord])
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
        let globalMemoryContext = MemoryService.shared.buildMemoryContext(query: effectiveConversation.memoryRetrievalQuery)
        await LoggerService.shared.log(
            category: .memory,
            event: "memory_context_built",
            traceContext: effectiveTraceContext,
            status: .succeeded,
            durationMs: Date().timeIntervalSince(memoryBuildStartedAt) * 1000,
            summary: globalMemoryContext.isEmpty ? "未命中长期记忆上下文" : "已构建长期记忆上下文",
            metadata: [
                "query_preview": .string(LogRedactor.preview(effectiveConversation.memoryRetrievalQuery, maxLength: 100)),
                "memory_context_length": .int(globalMemoryContext.count)
            ]
        )
        if !globalMemoryContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: globalMemoryContext))
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
                3. 能用 list_files、read_file 等结构化工具完成时，不要为了计数和列举去调用 shell。
                4. 如果必须使用 shell 来统计，请优先使用能直接返回数量和少量样例的命令组合，不要生成会输出完整大列表的命令。
                5. 如果工具结果已经被系统标记为“大输出摘要”，请直接基于摘要回答，不要再次尝试打印完整结果。
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
        let contextPrompt = effectiveConversation.contextState.systemContext()
        if !contextPrompt.isEmpty {
            preparedMessages.append(Message(role: .system, content: contextPrompt))
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

        while true {
            try Task.checkCancellation()
            await onEvent(.assistantTurnStarted)

            let response = try await llm.complete(
                messages: workingMessages,
                toolDefinitions: toolDefinitions,
                traceContext: effectiveTraceContext
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
            return await MCPServerManager.shared.executeTool(
                named: call.name,
                arguments: call.arguments,
                operationId: call.id,
                traceContext: traceContext,
                onProgress: progressHandler
            )
        }

        if call.name == ToolDefinition.ToolName.webFetch.rawValue {
            return await ToolRunner.shared.execute(
                name: call.name,
                arguments: call.arguments,
                operationId: call.id,
                assistantContentOverride: call.name == ToolDefinition.ToolName.writeAssistantContentToFile.rawValue ? assistantContentForToolCall : nil,
                onProgress: progressHandler
            )
        }

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
        switch ToolDefinition.ToolName(rawValue: call.name) {
        case .activateSkill:
            return "正在激活 skill"
        case .installSkill:
            return "正在下载并安装 skill"
        case .readSkillResource:
            return "正在读取 skill 资源"
        case .runSkillScript:
            return "正在执行 skill 脚本"
        case .readUploadedAttachment:
            return "正在读取上传文件内容"
        case .previewImage:
            return "正在预览图片"
        case .readFile:
            return "正在读取文件"
        case .writeFile:
            return "正在写入文件"
        case .writeAssistantContentToFile:
            return "正在写入正文文件"
        case .writeMultipleFiles:
            return "正在批量写入文件"
        case .movePaths:
            return L10n.tr("chat.tool.move_paths")
        case .deletePaths:
            return L10n.tr("chat.tool.delete_paths")
        case .writeDOCX:
            return "正在写入 Word"
        case .writeXLSX:
            return "正在写入 Excel"
        case .replaceDOCXSection:
            return "正在更新 Word 章节"
        case .insertDOCXSection:
            return "正在插入 Word 章节"
        case .appendXLSXRows:
            return "正在更新 Excel 工作表"
        case .updateXLSXCell:
            return "正在更新 Excel 单元格"
        case .listFiles:
            return "正在查看目录"
        case .webFetch:
            return "正在抓取网页"
        case .importFile, .importDirectory:
            return "正在导入文件"
        case .exportFile, .exportDirectory:
            return "正在导出文件"
        case .exportPDF:
            return "正在导出 PDF"
        case .exportDOCX:
            return "正在导出 Word"
        case .exportXLSX:
            return "正在导出 Excel"
        case .importFileContent:
            return "正在读取外部文件内容"
        case .listExternalFiles:
            return "正在查看外部目录"
        case .shell:
            return "正在执行 shell 命令"
        case .none:
            return "正在执行工具 \(call.name)"
        }
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
}

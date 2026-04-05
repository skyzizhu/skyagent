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

    var errorDescription: String? {
        switch self {
        case .toolLoopLimitExceeded:
            return "工具调用轮次过多，已停止以避免死循环"
        }
    }
}

final class AgentOrchestrator {
    private let llm: LLMService
    private let maxToolRounds = 8
    private let toolExecutionQueue = DispatchQueue(label: "MiniAgent.ToolExecution", qos: .userInitiated)

    init(llm: LLMService) {
        self.llm = llm
    }

    func run(
        conversation: Conversation,
        settings: AppSettings,
        preActivatedSkillIDs: [String] = [],
        requestApproval: @escaping (OperationPreview) async -> Bool,
        onEvent: @escaping (AgentEvent) async -> Void
    ) async throws {
        let availableSkills = SkillManager.shared.availableSkills
        let mergedActivatedSkillIDs = Array(NSOrderedSet(array: conversation.activatedSkillIDs + preActivatedSkillIDs)) as? [String] ?? conversation.activatedSkillIDs
        var effectiveConversation = conversation
        effectiveConversation.activatedSkillIDs = mergedActivatedSkillIDs
        let activatedSkillMessages = SkillManager.shared.activationMessages(for: mergedActivatedSkillIDs)

        ToolRunner.shared.configure(
            for: effectiveConversation,
            globalSandboxDir: settings.ensureSandboxDir(),
            allowedReadRoots: SkillManager.shared.readableRoots
        )
        let toolDefinitions = ToolDefinition.definitions(for: conversation.filePermissionMode, hasSkills: !availableSkills.isEmpty)

        var rawMessages = conversation.messages
        if MemoryService.shared.shouldCompress(messages: rawMessages) {
            rawMessages = MemoryService.shared.compress(messages: rawMessages, contextState: effectiveConversation.contextState)
        }

        var preparedMessages: [Message] = []
        if let catalogPrompt = SkillManager.shared.buildCatalogPrompt(for: availableSkills) {
            preparedMessages.append(Message(role: .system, content: catalogPrompt))
        }
        let contextPrompt = effectiveConversation.contextState.systemContext()
        if !contextPrompt.isEmpty {
            preparedMessages.append(Message(role: .system, content: contextPrompt))
        }
        preparedMessages.append(contentsOf: activatedSkillMessages.map { Message(role: .system, content: $0) })
        preparedMessages.append(contentsOf: rawMessages)
        if let summary = MemoryService.shared.loadSummary(convId: conversation.id) {
            let summaryMsg = Message(role: .system, content: "[本次对话的历史摘要]\n\(summary)")
            preparedMessages.insert(summaryMsg, at: 0)
        }

        var workingMessages = Self.buildChatMessages(from: preparedMessages)
        var remainingToolRounds = maxToolRounds

        while true {
            try Task.checkCancellation()
            await onEvent(.assistantTurnStarted)

            let response = try await llm.complete(messages: workingMessages, toolDefinitions: toolDefinitions) { delta in
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
                await onEvent(.toolStarted(execution, Self.toolStartSummary(for: call)))
                let outcome = await executeToolCall(call, execution: execution, onEvent: onEvent)
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
                        content: outcome.output,
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

    private func executeToolCall(
        _ call: ToolCallRecord,
        execution: ToolExecutionRecord,
        onEvent: @escaping (AgentEvent) async -> Void
    ) async -> ToolExecutionOutcome {
        await withCheckedContinuation { continuation in
            toolExecutionQueue.async {
                let outcome = ToolRunner.shared.execute(
                    name: call.name,
                    arguments: call.arguments,
                    operationId: call.id,
                    onProgress: { progress in
                        Task {
                            await onEvent(.toolProgress(execution, progress))
                        }
                    }
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
        case .writeMultipleFiles:
            return "正在批量写入文件"
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
}

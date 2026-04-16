import Foundation

struct ChatContextUsageSnapshot: Sendable {
    let isCompressed: Bool
    let budgetTokens: Int
    let serializedToolDefinitions: String
    let serializedMessages: [String]
}

enum ChatContextUsageEstimator {
    nonisolated static func estimateTokenCount(for text: String) -> Int {
        estimatedTokenCount(for: text)
    }

    static func makeSnapshot(
        for conversation: Conversation,
        modelName: String,
        maxTokens: Int,
        availableSkills: [AgentSkill],
        activatedSkillMessages: [String]
    ) -> ChatContextUsageSnapshot {
        var rawMessages = conversation.messages
        let isCompressed = MemoryService.shared.shouldCompress(messages: rawMessages)

        if isCompressed {
            rawMessages = MemoryService.shared.compress(messages: rawMessages, contextState: conversation.contextState)
        }

        var preparedMessages: [Message] = []
        let mcpTooling = MCPServerManager.shared.tooling(for: conversation)
        let workspacePath = conversation.sandboxDir.isEmpty ? AppSettings.defaultSandboxDir : conversation.sandboxDir
        WorkspaceMemoryService.shared.ensureWorkspaceArtifacts(for: workspacePath)
        let workspaceMemoryContext = WorkspaceMemoryService.shared.loadWorkspaceMemoryContext(for: workspacePath, maxCharacters: 900)
        let workspaceProfileContext = WorkspaceMemoryService.shared.loadWorkspaceProfileContext(for: workspacePath, maxCharacters: 700)
        let globalMemoryContext = MemoryService.shared.buildMemoryContext(query: conversation.memoryRetrievalQuery, maxResults: 4, maxTokens: 80)
        if !workspaceMemoryContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: workspaceMemoryContext, hiddenFromTranscript: true))
        }
        if !workspaceProfileContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: workspaceProfileContext, hiddenFromTranscript: true))
        }
        if !globalMemoryContext.isEmpty {
            preparedMessages.append(Message(role: .system, content: globalMemoryContext, hiddenFromTranscript: true))
        }
        if let summary = MemoryService.shared.loadSummary(
            convId: conversation.id,
            segmentStartedAt: conversation.contextState.segmentStartedAt
        ), !summary.isEmpty {
            preparedMessages.append(Message(role: .system, content: "[本次对话的历史摘要]\n\(summary)", hiddenFromTranscript: true))
        }
        if let catalogPrompt = SkillManager.shared.buildCatalogPrompt(for: availableSkills) {
            preparedMessages.append(Message(role: .system, content: catalogPrompt, hiddenFromTranscript: true))
        }
        if let mcpCatalogPrompt = mcpTooling.catalogPrompt {
            preparedMessages.append(Message(role: .system, content: mcpCatalogPrompt, hiddenFromTranscript: true))
        }
        let contextPrompt = conversation.contextState.systemContext()
        if !contextPrompt.isEmpty {
            preparedMessages.append(Message(role: .system, content: contextPrompt, hiddenFromTranscript: true))
        }
        preparedMessages.append(contentsOf: activatedSkillMessages.map {
            Message(role: .system, content: $0, hiddenFromTranscript: true)
        })
        preparedMessages.append(contentsOf: rawMessages)

        let toolDefinitions = ToolDefinition.definitions(
            for: conversation.filePermissionMode,
            hasSkills: !availableSkills.isEmpty
        ) + mcpTooling.definitions
        return ChatContextUsageSnapshot(
            isCompressed: isCompressed,
            budgetTokens: estimatedContextBudget(for: modelName, completionBudget: maxTokens),
            serializedToolDefinitions: serializeJSONCompatible(toolDefinitions),
            serializedMessages: preparedMessages.map { Self.serializeMessagePayload($0) }
        )
    }

    nonisolated static func estimate(from snapshot: ChatContextUsageSnapshot) -> ContextUsageStatus {
        let estimatedUsedTokens =
            estimatedTokenCount(for: snapshot.serializedToolDefinitions)
            + snapshot.serializedMessages.reduce(into: 0) { partialResult, payload in
                partialResult += estimatedTokenCount(for: payload)
            }
        return ContextUsageStatus(
            usedTokens: max(1, estimatedUsedTokens),
            budgetTokens: snapshot.budgetTokens,
            isCompressed: snapshot.isCompressed
        )
    }

    private static func estimatedContextBudget(for modelName: String, completionBudget: Int) -> Int {
        let lowercased = modelName.lowercased()
        if lowercased.contains("claude") {
            return 200_000
        }
        if lowercased.contains("gpt-4o") || lowercased.contains("gpt-4.1") || lowercased.contains("o3") || lowercased.contains("o4") {
            return 128_000
        }
        if lowercased.contains("gemini") {
            return 128_000
        }
        if lowercased.contains("deepseek") {
            return 64_000
        }
        if lowercased.contains("glm") {
            return 32_768
        }
        if lowercased.contains("qwen") {
            return 32_768
        }
        return max(8_192, completionBudget * 8)
    }

    nonisolated private static func serializeMessagePayload(_ message: Message) -> String {
        var payload: [String: Any] = ["role": message.role.rawValue]

        if let imageDataURL = message.imageDataURL, message.role == .user {
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

        if let toolExecution = message.toolExecution {
            payload["tool_call_id"] = toolExecution.id
            payload["tool_execution_name"] = toolExecution.name
            payload["tool_execution_arguments"] = toolExecution.arguments
        }

        return serializeJSONCompatible(payload)
    }

    nonisolated private static func serializeJSONCompatible(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    nonisolated private static func estimatedTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var total = 0
        var latinRun = 0
        var digitRun = 0

        func flushLatinRun() {
            guard latinRun > 0 else { return }
            total += Int(ceil(Double(latinRun) / 4.0))
            latinRun = 0
        }

        func flushDigitRun() {
            guard digitRun > 0 else { return }
            total += Int(ceil(Double(digitRun) / 3.0))
            digitRun = 0
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushLatinRun()
                flushDigitRun()
                continue
            }

            if CharacterSet.decimalDigits.contains(scalar) {
                flushLatinRun()
                digitRun += 1
                continue
            }

            if CharacterSet.letters.contains(scalar), scalar.value < 128 {
                flushDigitRun()
                latinRun += 1
                continue
            }

            flushLatinRun()
            flushDigitRun()
            total += 1
        }

        flushLatinRun()
        flushDigitRun()
        return total
    }
}

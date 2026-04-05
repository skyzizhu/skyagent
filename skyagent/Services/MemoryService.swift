import Foundation

/// 记忆系统：全局记忆 + LLM 生成摘要 + 智能压缩 + 记忆检索
class MemoryService {
    static let shared = MemoryService()

    private let baseDir: URL
    private let memoryDir: URL
    private let globalMemoryURL: URL
    private let conversationSummaryDir: URL

    /// 全局记忆内容（缓存）
    private var cachedGlobalMemory: String?

    /// 日期格式化
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 压缩阈值
    private let compressThreshold = 14
    /// 压缩时保留最近 N 条消息
    private let keepRecentCount = 8
    /// 全局记忆最大长度
    private let maxGlobalMemoryLength = 3000

    init() {
        AppStoragePaths.migrateLegacyDataIfNeeded()
        self.baseDir = AppStoragePaths.dataDir
        self.memoryDir = AppStoragePaths.memoriesDir
        self.globalMemoryURL = AppStoragePaths.globalMemoryFile
        self.conversationSummaryDir = AppStoragePaths.conversationSummaryDir
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: conversationSummaryDir, withIntermediateDirectories: true)
    }

    // MARK: - 1. 全局记忆文件

    /// 读取全局记忆
    func loadGlobalMemory() -> String {
        if let cached = cachedGlobalMemory { return cached }
        let content = (try? String(contentsOf: globalMemoryURL, encoding: .utf8)) ?? ""
        cachedGlobalMemory = content
        return content
    }

    /// 追加到全局记忆
    func appendToGlobalMemory(_ entry: String) {
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var existing = loadGlobalMemory()
        let timestamp = formatDate(Date())

        let newEntry = "\n## \(timestamp)\n\(entry)\n"
        existing += newEntry

        // 超过最大长度时，截断保留最新部分
        if existing.count > maxGlobalMemoryLength {
            let truncated = String(existing.suffix(maxGlobalMemoryLength))
            // 找到第一个 ## 标题，确保从完整的段落开始
            if let range = truncated.range(of: "## ") {
                existing = String(truncated[range.lowerBound...])
            } else {
                existing = truncated
            }
        }

        try? existing.write(to: globalMemoryURL, atomically: true, encoding: .utf8)
        cachedGlobalMemory = existing
    }

    // MARK: - 2. 新对话注入记忆

    /// 生成记忆上下文，用于注入 system prompt
    /// maxTokens: 大约的 token 预算（1 token ≈ 1.5 字符）
    func buildMemoryContext(maxTokens: Int = 500) -> String {
        let memory = loadGlobalMemory()
        guard !memory.isEmpty else { return "" }

        let maxChars = maxTokens * 2
        let context: String
        if memory.count > maxChars {
            context = String(memory.suffix(maxChars))
        } else {
            context = memory
        }

        return """
        [你的记忆 - 来自之前对话的重要信息]
        \(context)
        [记忆结束 - 请自然地利用这些信息，不要主动提及"记忆"系统]
        """
    }

    // MARK: - 3. LLM 生成摘要

    /// 让 LLM 生成对话摘要（通过 API 调用）
    /// 如果 LLM 不可用，回退到本地摘要
    func generateSummary(messages: [Message], llmService: LLMService?, settings: AppSettings) async -> String {
        // 尝试用 LLM 生成摘要
        if let llm = llmService, !settings.apiKey.isEmpty {
            let conversation = messages.map { msg in
                let role = msg.role == .user ? "用户" : msg.role == .assistant ? "助手" : "系统"
                return "\(role): \(String(msg.content.prefix(300)))"
            }.joined(separator: "\n")

            let prompt = """
            请用简洁的中文总结以下对话的关键信息（不超过 200 字）：
            - 讨论了什么主题
            - 做了什么操作/决策
            - 重要的结论或结果

            对话内容：
            \(String(conversation.prefix(2000)))
            """

            do {
                let collector = StreamCollector()
                let chatMessages = [LLMService.ChatMessage(role: "user", content: prompt)]
                try await llm.chat(messages: chatMessages, toolDefinitions: nil) { delta in
                    await collector.append(delta)
                }
                let result = await collector.value
                if !result.isEmpty {
                    return result
                }
            } catch {
                // LLM 调用失败，回退到本地摘要
            }
        }

        // 本地回退摘要
        return generateLocalSummary(messages: messages)
    }

    /// 本地摘要（不依赖 LLM）
    private func generateLocalSummary(messages: [Message]) -> String {
        var topics: [String] = []
        var tools: [String] = []
        var keyDecisions: [String] = []
        var activatedSkills: [String] = []

        for msg in messages {
            if msg.role == .user {
                let firstLine = msg.content.components(separatedBy: "\n").first ?? ""
                if !firstLine.isEmpty {
                    topics.append(String(firstLine.prefix(80)))
                }
            }
            if let toolExecution = msg.toolExecution {
                tools.append(toolExecution.name)
                if toolExecution.name == "activate_skill",
                   let skillName = extractActivatedSkillName(from: msg.content) {
                    activatedSkills.append(skillName)
                }
            }
            if msg.role == .assistant, msg.content.count > 100 {
                let summary = String(msg.content.prefix(100)).replacingOccurrences(of: "\n", with: " ")
                keyDecisions.append(summary)
            }
        }

        var parts: [String] = []
        if !topics.isEmpty {
            parts.append("主题: " + Array(Set(topics)).prefix(3).joined(separator: "、"))
        }
        if !tools.isEmpty {
            parts.append("工具: " + Array(Set(tools)).joined(separator: "、"))
        }
        if !activatedSkills.isEmpty {
            parts.append("Skills: " + Array(Set(activatedSkills)).joined(separator: "、"))
        }
        if !keyDecisions.isEmpty {
            parts.append("要点: " + keyDecisions.prefix(2).joined(separator: "；"))
        }

        return parts.isEmpty ? "简短对话" : parts.joined(separator: "。")
    }

    // MARK: - 对话结束后的记忆处理

    /// 对话结束后：生成摘要 → 保存到文件 → 更新全局记忆
    func processConversationEnd(convId: UUID, title: String, messages: [Message], llmService: LLMService?, settings: AppSettings) async {
        guard !messages.isEmpty else { return }

        // 生成摘要
        let summary = await generateSummary(messages: messages, llmService: llmService, settings: settings)

        // 保存对话摘要文件
        let content = "# \(title)\n\n\(summary)\n\n## 消息数\n- 用户: \(messages.filter { $0.role == .user }.count)\n- 助手: \(messages.filter { $0.role == .assistant }.count)\n"
        let dateStr = Self.dateFormatter.string(from: Date())
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        let fileName = "\(dateStr)_\(safeTitle).md"
        let url = memoryDir.appendingPathComponent(fileName)
        try? content.write(to: url, atomically: true, encoding: .utf8)

        let conversationURL = conversationSummaryDir.appendingPathComponent("\(convId.uuidString).md")
        try? summary.write(to: conversationURL, atomically: true, encoding: .utf8)

        // 更新全局记忆
        let globalEntry = """
        ### \(title)
        \(summary)
        """
        appendToGlobalMemory(globalEntry)
    }

    // MARK: - 4. 智能压缩

    /// 判断是否需要压缩
    func shouldCompress(messages: [Message]) -> Bool {
        return messages.count > compressThreshold
    }

    /// 智能压缩：优先保留结构化状态、技能激活里程碑、最早起点和最近消息
    func compress(messages: [Message], contextState: ConversationContextState? = nil) -> [Message] {
        guard messages.count > compressThreshold else { return messages }

        var result: [Message] = []

        // 1. 优先保留最新结构化会话状态
        if let contextState {
            let context = contextState.systemContext()
            if !context.isEmpty {
                result.append(Message(role: .system, content: context, hiddenFromTranscript: true))
            }
        }

        // 2. 仅保留对模型仍有价值的 system 消息，尽量过滤掉临时隐藏分析噪音
        let preservedSystemMsgs = messages.filter {
            guard $0.role == .system else { return false }
            let content = $0.content
            if content.contains("[当前会话状态]") { return false }
            if $0.hiddenFromTranscript == true && content.contains("[本地文件意图分析]") { return false }
            return $0.hiddenFromTranscript != true || content.contains("[本次对话的历史摘要]")
        }
        result.append(contentsOf: preservedSystemMsgs)

        // 3. 保留 skill 激活工具消息，避免长对话压缩后丢失这类关键里程碑
        let activationToolMsgs = messages.filter {
            $0.role == .tool && $0.toolExecution?.name == "activate_skill"
        }
        result.append(contentsOf: activationToolMsgs)

        // 4. 保留第一条用户消息（通常是对话的起点）
        if let firstUser = messages.first(where: { $0.role == .user }) {
            if !result.contains(where: { $0.id == firstUser.id }) {
                result.append(firstUser)
            }
        }

        // 5. 生成中间部分的摘要
        let recentMsgs = Array(messages.suffix(keepRecentCount))
        let systemIds = Set(preservedSystemMsgs.map(\.id))
        let activationIds = Set(activationToolMsgs.map(\.id))
        let recentIds = Set(recentMsgs.map(\.id))
        let middleMsgs = messages.filter {
            !systemIds.contains($0.id) &&
            !activationIds.contains($0.id) &&
            !recentIds.contains($0.id) &&
            !($0.role == .system && $0.hiddenFromTranscript == true)
        }

        if !middleMsgs.isEmpty {
            var summaryParts = ["[以下是之前对话的状态摘要]"]
            if let contextState, !contextState.isEmpty {
                if !contextState.taskSummary.isEmpty {
                    summaryParts.append("任务: \(contextState.taskSummary)")
                }
                if !contextState.activeTargets.isEmpty {
                    summaryParts.append("目标: \(contextState.activeTargets.prefix(3).joined(separator: "；"))")
                }
                if !contextState.activeConstraints.isEmpty {
                    summaryParts.append("约束: \(contextState.activeConstraints.prefix(4).joined(separator: "；"))")
                }
                if !contextState.activeSkillNames.isEmpty {
                    summaryParts.append("技能: \(contextState.activeSkillNames.joined(separator: "、"))")
                }
                if !contextState.recentResults.isEmpty {
                    summaryParts.append("结果: \(contextState.recentResults.prefix(3).joined(separator: "；"))")
                }
                if !contextState.openQuestions.isEmpty {
                    summaryParts.append("待确认: \(contextState.openQuestions.joined(separator: "；"))")
                }
            }
            for msg in middleMsgs {
                let role: String
                switch msg.role {
                case .user: role = "用户"
                case .assistant: role = "助手"
                case .tool:
                    role = msg.toolExecution?.name == "read_skill_resource" ? "Skill资源" : "工具"
                case .system:
                    role = "系统"
                }
                let content = String(msg.content.prefix(150)).replacingOccurrences(of: "\n", with: " ")
                summaryParts.append("\(role): \(content)")
            }
            summaryParts.append("[摘要结束]")
            let summaryMsg = Message(role: .system, content: summaryParts.joined(separator: "\n"))
            result.append(summaryMsg)
        }

        // 6. 保留最近的消息，同时避免重复加入已经保留过的消息
        for msg in recentMsgs where !result.contains(where: { $0.id == msg.id }) {
            result.append(msg)
        }

        return result
    }

    // MARK: - 5. 记忆检索

    /// 读取对话摘要（按 convId 查找最新的摘要文件）
    func loadSummary(convId: UUID) -> String? {
        let url = conversationSummaryDir.appendingPathComponent("\(convId.uuidString).md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 根据当前话题检索相关的历史记忆
    func searchRelevantMemory(query: String, maxResults: Int = 3) -> [String] {
        let globalMemory = loadGlobalMemory()
        guard !globalMemory.isEmpty else { return [] }

        // 按段落分割
        let paragraphs = globalMemory.components(separatedBy: "### ")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // 简单关键词匹配排序
        let queryWords = query.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count >= 2 }

        let scored = paragraphs.map { para -> (String, Int) in
            let lower = para.lowercased()
            let score = queryWords.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            return ("### " + para, score)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }

        return Array(scored.prefix(maxResults)).map { $0.0 }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func extractActivatedSkillName(from content: String) -> String? {
        let prefix = "✅ 已激活 skill："
        guard let line = content.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return line.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor StreamCollector {
    private var storage = ""

    func append(_ delta: String) {
        storage += delta
    }

    var value: String {
        storage
    }
}

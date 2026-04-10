import Foundation
import CryptoKit

private struct SemanticMemoryEntry: Codable, Hashable {
    let id: String
    var category: String
    var slot: String?
    var content: String
    var sourceConversationID: String
    var updatedAt: Date

    init(
        id: String,
        category: String,
        slot: String? = nil,
        content: String,
        sourceConversationID: String,
        updatedAt: Date
    ) {
        self.id = id
        self.category = category
        self.slot = slot
        self.content = content
        self.sourceConversationID = sourceConversationID
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(String.self, forKey: .category)
        slot = try container.decodeIfPresent(String.self, forKey: .slot)
        content = try container.decode(String.self, forKey: .content)
        sourceConversationID = try container.decode(String.self, forKey: .sourceConversationID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, slot, content, sourceConversationID, updatedAt
    }
}

private struct ConversationMemoryCheckpoint: Codable {
    var messageCount: Int
    var messageFingerprint: String
    var lastMessageTimestamp: Date
    var updatedAt: Date

    init(messageCount: Int, messageFingerprint: String, lastMessageTimestamp: Date, updatedAt: Date) {
        self.messageCount = messageCount
        self.messageFingerprint = messageFingerprint
        self.lastMessageTimestamp = lastMessageTimestamp
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        messageFingerprint = try container.decode(String.self, forKey: .messageFingerprint)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastMessageTimestamp = try container.decodeIfPresent(Date.self, forKey: .lastMessageTimestamp) ?? updatedAt
    }
}

private struct MemoryIndex: Codable {
    var semanticEntries: [SemanticMemoryEntry] = []
    var conversationCheckpoints: [String: ConversationMemoryCheckpoint] = [:]
}

private struct SemanticMemoryCandidate: Hashable {
    let category: String
    let slot: String?
    let content: String
}

private struct MemoryMatch {
    let rendered: String
    let score: Int
    let updatedAt: Date
}

private struct SummaryRecord {
    let cacheKey: String
    let convId: UUID
    let segmentStartedAt: Date?
    let summary: String
}

/// 记忆系统：手动记忆 + 语义记忆 + 对话级摘要 + 智能压缩
final class MemoryService {
    static let shared = MemoryService()

    private let memoryDir: URL
    private let manualMemoryURL: URL
    private let generatedMemoryURL: URL
    private let memoryIndexURL: URL
    private let conversationSummaryDir: URL
    private let stateQueue = DispatchQueue(label: "SkyAgent.MemoryService", qos: .utility)

    private var cachedManualMemory: String?
    private var cachedGeneratedMemory: String?
    private var cachedMemoryContexts: [String: (sourceSignature: String, context: String)] = [:]
    private var cachedMemoryIndex: MemoryIndex?
    private var cachedSummaries: [String: SummaryRecord] = [:]
    private var summaryCacheLoaded = false

    private static let archiveFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    private let compressThreshold = 14
    private let keepRecentCount = 8
    private let maxManualMemoryLength = 3000

    init() {
        AppStoragePaths.migrateLegacyDataIfNeeded()
        self.memoryDir = AppStoragePaths.memoriesDir
        self.manualMemoryURL = AppStoragePaths.globalMemoryFile
        self.generatedMemoryURL = AppStoragePaths.generatedMemoryFile
        self.memoryIndexURL = AppStoragePaths.memoryIndexFile
        self.conversationSummaryDir = AppStoragePaths.conversationSummaryDir
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: conversationSummaryDir, withIntermediateDirectories: true)
        stateQueue.sync {
            preloadSummaryCacheIfNeeded()
        }
    }

    // MARK: - Memory Loading

    func loadGlobalMemory() -> String {
        stateQueue.sync {
            loadGlobalMemoryUnsafe()
        }
    }

    func appendToGlobalMemory(_ entry: String) {
        let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEntry.isEmpty else { return }

        stateQueue.sync {
            var existing = loadManualMemoryUnsafe()
            let timestamp = formatTimestamp(Date())
            let newEntry = "\n## \(timestamp)\n\(trimmedEntry)\n"
            existing += newEntry

            if existing.count > maxManualMemoryLength {
                let truncated = String(existing.suffix(maxManualMemoryLength))
                if let range = truncated.range(of: "## ") {
                    existing = String(truncated[range.lowerBound...])
                } else {
                    existing = truncated
                }
            }

            try? existing.write(to: manualMemoryURL, atomically: true, encoding: .utf8)
            cachedManualMemory = existing
            cachedMemoryContexts.removeAll()
        }
    }

    func buildMemoryContext(query: String, maxResults: Int = 4, maxTokens: Int = 500) -> String {
        stateQueue.sync {
            let normalizedQuery = normalizedMemoryContent(query).lowercased()
            let cacheKey = "\(maxTokens)|\(maxResults)|\(normalizedQuery)"
            let sourceSignature = memoryContextSourceSignatureUnsafe(query: normalizedQuery, maxResults: maxResults)
            if let cached = cachedMemoryContexts[cacheKey], cached.sourceSignature == sourceSignature {
                return cached.context
            }

            let sections = relevantMemorySectionsUnsafe(query: normalizedQuery, maxResults: maxResults)
            guard !sections.isEmpty else { return "" }

            let maxChars = maxTokens * 2
            let context = truncateMemorySections(sections, maxChars: maxChars)
            let built = """
            [与你当前任务相关的记忆]
            以下内容仅包含与当前任务最相关的长期记忆和历史约定。
            只在确实相关时自然利用，不要主动提及“记忆系统”。

            \(context)
            [记忆结束]
            """
            cachedMemoryContexts[cacheKey] = (sourceSignature, built)
            return built
        }
    }

    // MARK: - Summaries

    func generateSummary(messages: [Message], llmService: LLMService?, settings: AppSettings) async -> String {
        await generateSummary(messages: messages, existingSummary: nil, llmService: llmService, settings: settings)
    }

    func processConversationEnd(
        convId: UUID,
        title: String,
        messages: [Message],
        contextState: ConversationContextState?,
        llmService: LLMService?,
        settings: AppSettings
    ) async {
        let relevantMessages = memoryRelevantMessages(from: messages)
        guard !relevantMessages.isEmpty else { return }
        let summaryKey = summaryCacheKey(convId: convId, segmentStartedAt: contextState?.segmentStartedAt)
        let key = checkpointKey(convId: convId, segmentStartedAt: contextState?.segmentStartedAt)
        let fingerprint = messageFingerprint(for: relevantMessages)
        let lastMessageTimestamp = relevantMessages.last?.timestamp ?? .distantPast
        let snapshot = stateQueue.sync {
            preloadSummaryCacheIfNeeded()
            let index = loadMemoryIndexUnsafe()
            let existingCheckpoint = index.conversationCheckpoints[key]
            if existingCheckpoint?.messageFingerprint == fingerprint {
                return (previousSummary: String, deltaMessages: [Message], shouldUpdateIncrementally: Bool)?.none
            }

            let previousSummary = cachedSummaries[summaryKey]?.summary ?? ""
            let deltaMessages = incrementalDeltaMessages(from: relevantMessages, checkpoint: existingCheckpoint)
            let shouldUpdateIncrementally =
                existingCheckpoint != nil &&
                !deltaMessages.isEmpty &&
                deltaMessages.count < relevantMessages.count &&
                !previousSummary.isEmpty
            return (previousSummary, deltaMessages, shouldUpdateIncrementally)
        }
        guard let snapshot else { return }

        let summary: String
        if snapshot.shouldUpdateIncrementally {
            summary = await generateSummary(
                messages: snapshot.deltaMessages,
                existingSummary: snapshot.previousSummary.isEmpty ? nil : snapshot.previousSummary,
                llmService: llmService,
                settings: settings
            )
        } else {
            summary = await generateSummary(
                messages: relevantMessages,
                existingSummary: nil,
                llmService: llmService,
                settings: settings
            )
        }

        let semanticCandidates = await extractSemanticMemoryCandidates(
            title: title,
            summary: summary,
            messages: snapshot.deltaMessages.isEmpty ? relevantMessages : snapshot.deltaMessages,
            llmService: llmService,
            settings: settings
        )

        stateQueue.sync {
            preloadSummaryCacheIfNeeded()
            var index = loadMemoryIndexUnsafe()
            if let currentCheckpoint = index.conversationCheckpoints[key] {
                if currentCheckpoint.messageFingerprint == fingerprint {
                    return
                }
                if currentCheckpoint.lastMessageTimestamp > lastMessageTimestamp {
                    return
                }
                if currentCheckpoint.lastMessageTimestamp == lastMessageTimestamp,
                   currentCheckpoint.messageCount > relevantMessages.count {
                    return
                }
            }

            persistConversationSummaryUnsafe(
                convId: convId,
                segmentStartedAt: contextState?.segmentStartedAt,
                title: title,
                summary: summary,
                messages: relevantMessages
            )

            if !semanticCandidates.isEmpty {
                index.semanticEntries = mergeSemanticEntries(
                    existing: index.semanticEntries,
                    candidates: semanticCandidates,
                    sourceConversationID: key
                )
                renderGeneratedMemoryUnsafe(entries: index.semanticEntries)
            }

            index.conversationCheckpoints[key] = ConversationMemoryCheckpoint(
                messageCount: relevantMessages.count,
                messageFingerprint: fingerprint,
                lastMessageTimestamp: lastMessageTimestamp,
                updatedAt: Date()
            )
            saveMemoryIndexUnsafe(index)
        }
    }

    // MARK: - Compression

    func shouldCompress(messages: [Message]) -> Bool {
        messages.count > compressThreshold
    }

    func compress(messages: [Message], contextState _: ConversationContextState? = nil) -> [Message] {
        guard messages.count > compressThreshold else { return messages }

        var result: [Message] = []

        let preservedSystemMessages = messages.filter {
            guard $0.role == .system else { return false }
            let content = $0.content
            if content.contains("[当前会话状态]") { return false }
            if $0.hiddenFromTranscript == true && content.contains("[本地文件意图分析]") { return false }
            return $0.hiddenFromTranscript != true || content.contains("[本次对话的历史摘要]")
        }
        result.append(contentsOf: preservedSystemMessages)

        let activationToolMessages = messages.filter {
            $0.role == .tool && $0.toolExecution?.name == "activate_skill"
        }
        result.append(contentsOf: activationToolMessages)

        if let firstUser = messages.first(where: { $0.role == .user }),
           !result.contains(where: { $0.id == firstUser.id }) {
            result.append(firstUser)
        }

        let recentMessages = Array(messages.suffix(keepRecentCount))
        let preservedSystemIDs = Set(preservedSystemMessages.map(\.id))
        let activationIDs = Set(activationToolMessages.map(\.id))
        let recentIDs = Set(recentMessages.map(\.id))
        let middleMessages = messages.filter {
            !preservedSystemIDs.contains($0.id) &&
            !activationIDs.contains($0.id) &&
            !recentIDs.contains($0.id) &&
            !($0.role == .system && $0.hiddenFromTranscript == true)
        }

        if !middleMessages.isEmpty {
            var summaryParts = ["[以下是之前对话的状态摘要]"]
            for message in middleMessages {
                let role: String
                switch message.role {
                case .user:
                    role = "用户"
                case .assistant:
                    role = "助手"
                case .tool:
                    role = message.toolExecution?.name == "read_skill_resource" ? "Skill资源" : "工具"
                case .system:
                    role = "系统"
                }
                let content = String(message.content.prefix(150)).replacingOccurrences(of: "\n", with: " ")
                summaryParts.append("\(role): \(content)")
            }
            summaryParts.append("[摘要结束]")
            result.append(Message(role: .system, content: summaryParts.joined(separator: "\n")))
        }

        for message in recentMessages where !result.contains(where: { $0.id == message.id }) {
            result.append(message)
        }

        return result
    }

    // MARK: - Retrieval

    func loadSummary(convId: UUID, segmentStartedAt: Date? = nil) -> String? {
        stateQueue.sync {
            preloadSummaryCacheIfNeeded()
            let exactKey = summaryCacheKey(convId: convId, segmentStartedAt: segmentStartedAt)
            if let exact = cachedSummaries[exactKey]?.summary {
                return exact
            }

            if segmentStartedAt != nil {
                return nil
            }

            return latestSummaryRecordUnsafe(for: convId)?.summary
        }
    }

    func searchRelevantMemory(query: String, maxResults: Int = 3) -> [String] {
        let normalizedQueryTerms = tokenize(query)
        return stateQueue.sync {
            relevantMemoryMatchesUnsafe(queryTerms: normalizedQueryTerms, maxResults: maxResults)
                .map(\.rendered)
        }
    }

    // MARK: - Internal Summary Helpers

    private func generateSummary(
        messages: [Message],
        existingSummary: String?,
        llmService: LLMService?,
        settings: AppSettings
    ) async -> String {
        if let llm = llmService, !settings.apiKey.isEmpty {
            let payload = summarizePayload(for: messages)
            let prompt: String
            if let existingSummary, !existingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = """
                你在维护一个 agent 的 episodic memory。请根据已有摘要和新增消息，输出更新后的中文摘要，不超过 220 字。
                摘要要覆盖：
                - 当前目标 / 正在处理的对象
                - 已完成动作与产物
                - 稳定约束、偏好、工作方式
                - 未完成事项 / 待确认点

                已有摘要：
                \(existingSummary)

                新增消息：
                \(payload)
                """
            } else {
                prompt = """
                请为一个 agent 生成中文工作记忆摘要，不超过 220 字。
                摘要要覆盖：
                - 当前目标 / 处理对象
                - 已完成动作与产物
                - 关键约束、偏好、工作方式
                - 未完成事项 / 待确认点

                对话内容：
                \(payload)
                """
            }

            do {
                let collector = StreamCollector()
                try await llm.chat(messages: [LLMService.ChatMessage(role: "user", content: prompt)], toolDefinitions: nil) { delta in
                    await collector.append(delta)
                }
                let result = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty {
                    return result
                }
            } catch {
                // 回退到本地摘要
            }
        }

        if let existingSummary, !existingSummary.isEmpty {
            return mergeLocalSummary(existingSummary: existingSummary, delta: generateLocalSummary(messages: messages))
        }
        return generateLocalSummary(messages: messages)
    }

    private func generateLocalSummary(messages: [Message]) -> String {
        var topics: [String] = []
        var tools: [String] = []
        var outputs: [String] = []
        var pendingItems: [String] = []

        for message in messages {
            switch message.role {
            case .user:
                let firstLine = message.content.components(separatedBy: .newlines).first ?? ""
                let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    topics.append(String(trimmed.prefix(80)))
                }
                if trimmed.contains("?") || trimmed.contains("待确认") {
                    pendingItems.append(String(trimmed.prefix(60)))
                }
            case .assistant:
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 24 {
                    outputs.append(String(trimmed.prefix(90)).replacingOccurrences(of: "\n", with: " "))
                }
            case .tool:
                if let toolName = message.toolExecution?.name {
                    tools.append(toolName)
                }
            case .system:
                continue
            }
        }

        var parts: [String] = []
        if !topics.isEmpty {
            parts.append("目标: " + deduplicated(topics).prefix(2).joined(separator: "；"))
        }
        if !tools.isEmpty {
            parts.append("动作: " + deduplicated(tools).prefix(4).joined(separator: "、"))
        }
        if !outputs.isEmpty {
            parts.append("结果: " + deduplicated(outputs).prefix(2).joined(separator: "；"))
        }
        if !pendingItems.isEmpty {
            parts.append("待确认: " + deduplicated(pendingItems).prefix(2).joined(separator: "；"))
        }

        let joined = parts.joined(separator: "。")
        return joined.isEmpty ? "简短对话" : String(joined.prefix(220))
    }

    private func mergeLocalSummary(existingSummary: String, delta: String) -> String {
        let trimmedExisting = existingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else { return trimmedDelta }
        guard !trimmedDelta.isEmpty else { return trimmedExisting }
        if trimmedExisting.contains(trimmedDelta) {
            return trimmedExisting
        }
        let merged = "\(trimmedExisting)；\(trimmedDelta)"
        return String(merged.prefix(220))
    }

    private func summarizePayload(for messages: [Message]) -> String {
        messages.map { message in
            let role: String
            switch message.role {
            case .user:
                role = "用户"
            case .assistant:
                role = "助手"
            case .tool:
                role = "工具[\(message.toolExecution?.name ?? "unknown")]"
            case .system:
                role = "系统"
            }
            let content = String(message.content.prefix(260)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(role): \(content)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Semantic Memory

    private func extractSemanticMemoryCandidates(
        title: String,
        summary: String,
        messages: [Message],
        llmService: LLMService?,
        settings: AppSettings
    ) async -> [SemanticMemoryCandidate] {
        if let llm = llmService, !settings.apiKey.isEmpty {
            do {
                let collector = StreamCollector()
                let prompt = """
                你在维护一个 agent 的 semantic memory。
                请从下面内容中提取“未来仍长期有用”的记忆，只保留：
                1. 用户稳定偏好
                2. 项目约定 / 输出格式约定
                3. 长期有效的工作方式或工具偏好
                4. 长期约束

                不要保留：
                - 一次性任务
                - 临时文件名
                - 短期执行结果
                - 明显只对当前一轮有效的信息

                返回严格 JSON 数组，每项格式：
                {"category":"preference|project|workflow|constraint","slot":"可选的稳定槽位","content":"..."}
                其中 slot 仅在这类信息可被未来覆盖时填写，例如：
                - output_format
                - overwrite_strategy
                - response_language
                - delivery_style
                - tool_preference
                如果没有长期记忆，返回 []。

                会话标题：
                \(title)

                当前摘要：
                \(summary)

                最近消息：
                \(summarizePayload(for: messages))
                """
                try await llm.chat(messages: [LLMService.ChatMessage(role: "user", content: prompt)], toolDefinitions: nil) { delta in
                    await collector.append(delta)
                }
                let response = await collector.value
                let parsed = parseSemanticMemoryCandidates(from: response)
                if !parsed.isEmpty {
                    return parsed
                }
            } catch {
                // 回退到本地启发式
            }
        }

        return heuristicSemanticMemoryCandidates(from: messages, summary: summary)
    }

    private func parseSemanticMemoryCandidates(from raw: String) -> [SemanticMemoryCandidate] {
        guard let jsonString = extractJSONArray(from: raw),
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return deduplicated(
            json.compactMap { item in
                guard let category = item["category"] as? String,
                      let content = item["content"] as? String else {
                    return nil
                }
                let normalizedCategory = normalizeCategory(category)
                let normalizedSlot = normalizeSlot(item["slot"] as? String) ?? inferredSlot(for: content, category: normalizedCategory)
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedContent.isEmpty else { return nil }
                return SemanticMemoryCandidate(category: normalizedCategory, slot: normalizedSlot, content: trimmedContent)
            }
        )
    }

    private func heuristicSemanticMemoryCandidates(from messages: [Message], summary: String) -> [SemanticMemoryCandidate] {
        var candidates: [SemanticMemoryCandidate] = []
        let joinedUserText = messages
            .filter { $0.role == .user }
            .map(\.content)
            .joined(separator: "\n")
            .lowercased()

        if joinedUserText.contains("markdown") || joinedUserText.contains(".md") {
            candidates.append(.init(category: "project", slot: "output_format", content: "默认使用 Markdown 作为交付格式。"))
        }
        if joinedUserText.contains("pdf") {
            candidates.append(.init(category: "project", slot: "output_format", content: "涉及正式导出时，优先输出结构完整且可校验的 PDF。"))
        }
        if joinedUserText.contains("docx") || joinedUserText.contains("word") {
            candidates.append(.init(category: "project", slot: "output_format", content: "涉及正式文档时，默认输出 Word / DOCX 格式。"))
        }
        if joinedUserText.contains("xlsx") || joinedUserText.contains("excel") {
            candidates.append(.init(category: "project", slot: "output_format", content: "涉及结构化表格时，默认输出 Excel / XLSX 格式。"))
        }
        if summary.contains("不要覆盖") || summary.contains("保留原文件") {
            candidates.append(.init(category: "constraint", slot: "overwrite_strategy", content: "修改文件时优先保留原文件，避免直接覆盖。"))
        }
        if joinedUserText.contains("中文") || joinedUserText.contains("汉语") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用中文沟通与输出。"))
        }
        if joinedUserText.contains("英文") || joinedUserText.contains("english") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用英文沟通与输出。"))
        }

        return deduplicated(candidates)
    }

    private func mergeSemanticEntries(
        existing: [SemanticMemoryEntry],
        candidates: [SemanticMemoryCandidate],
        sourceConversationID: String
    ) -> [SemanticMemoryEntry] {
        var entriesByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for candidate in candidates {
            let normalizedContent = normalizedMemoryContent(candidate.content)
            guard !normalizedContent.isEmpty else { continue }
            let normalizedSlot = normalizeSlot(candidate.slot) ?? inferredSlot(for: normalizedContent, category: candidate.category)

            if let normalizedSlot {
                for entry in entriesByID.values where effectiveSlot(for: entry) == normalizedSlot {
                    entriesByID.removeValue(forKey: entry.id)
                }
            }

            let id = semanticMemoryID(for: candidate.category, slot: normalizedSlot, content: normalizedContent)
            if var existingEntry = entriesByID[id] {
                existingEntry.category = candidate.category
                existingEntry.slot = normalizedSlot
                existingEntry.content = candidate.content
                existingEntry.updatedAt = Date()
                existingEntry.sourceConversationID = sourceConversationID
                entriesByID[id] = existingEntry
            } else {
                entriesByID[id] = SemanticMemoryEntry(
                    id: id,
                    category: candidate.category,
                    slot: normalizedSlot,
                    content: candidate.content,
                    sourceConversationID: sourceConversationID,
                    updatedAt: Date()
                )
            }
        }

        return entriesByID.values
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.content < rhs.content
            }
            .prefix(40)
            .map { $0 }
    }

    private func renderGeneratedMemoryUnsafe(entries: [SemanticMemoryEntry]) {
        let grouped = Dictionary(grouping: entries, by: \.category)
        let orderedCategories = ["preference", "project", "workflow", "constraint"]
        var lines: [String] = [
            "# Generated Semantic Memory",
            "",
            "以下内容由系统从历史对话中提炼，只保留长期有用的信息。",
            ""
        ]

        for category in orderedCategories {
            guard let items = grouped[category], !items.isEmpty else { continue }
            lines.append("## \(displayTitle(for: category))")
            for item in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                lines.append("- \(item.content)")
            }
            lines.append("")
        }

        let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        try? markdown.write(to: generatedMemoryURL, atomically: true, encoding: .utf8)
        cachedGeneratedMemory = markdown
        cachedMemoryContexts.removeAll()
    }

    // MARK: - Persistence

    private func persistConversationSummaryUnsafe(
        convId: UUID,
        segmentStartedAt: Date?,
        title: String,
        summary: String,
        messages: [Message]
    ) {
        let content = """
        # \(title)

        \(summary)

        ## 消息数
        - 用户: \(messages.filter { $0.role == .user }.count)
        - 助手: \(messages.filter { $0.role == .assistant }.count)
        """

        let conversationURL = summaryFileURL(convId: convId, segmentStartedAt: segmentStartedAt)
        try? summary.write(to: conversationURL, atomically: true, encoding: .utf8)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = summaryCacheKey(convId: convId, segmentStartedAt: segmentStartedAt)
        cachedSummaries[cacheKey] = SummaryRecord(
            cacheKey: cacheKey,
            convId: convId,
            segmentStartedAt: segmentStartedAt,
            summary: trimmedSummary
        )

        let safeTitle = sanitizedArchiveTitle(title)
        let timestamp = Self.archiveFormatter.string(from: Date())
        let segmentSuffix = segmentStartedAt.map { "_segment-\(summarySegmentIdentifier(from: $0))" } ?? ""
        let archiveName = "\(timestamp)_\(safeTitle)_\(convId.uuidString.prefix(8))\(segmentSuffix).md"
        let archiveURL = memoryDir.appendingPathComponent(archiveName)
        try? content.write(to: archiveURL, atomically: true, encoding: .utf8)
    }

    private func loadMemoryIndexUnsafe() -> MemoryIndex {
        if let cachedMemoryIndex {
            return cachedMemoryIndex
        }
        guard let data = try? Data(contentsOf: memoryIndexURL),
              let index = try? JSONDecoder().decode(MemoryIndex.self, from: data) else {
            let empty = MemoryIndex()
            cachedMemoryIndex = empty
            return empty
        }
        cachedMemoryIndex = index
        return index
    }

    private func saveMemoryIndexUnsafe(_ index: MemoryIndex) {
        cachedMemoryIndex = index
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: memoryIndexURL, options: .atomic)
        }
    }

    // MARK: - Low-Level Helpers

    private func loadManualMemoryUnsafe() -> String {
        if let cachedManualMemory {
            return cachedManualMemory
        }
        let content = (try? String(contentsOf: manualMemoryURL, encoding: .utf8)) ?? ""
        cachedManualMemory = content
        return content
    }

    private func loadGeneratedMemoryUnsafe() -> String {
        if let cachedGeneratedMemory {
            return cachedGeneratedMemory
        }
        let content = (try? String(contentsOf: generatedMemoryURL, encoding: .utf8)) ?? ""
        cachedGeneratedMemory = content
        return content
    }

    private func preloadSummaryCacheIfNeeded() {
        guard !summaryCacheLoaded else { return }
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: conversationSummaryDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var summaries: [String: SummaryRecord] = [:]
        for url in fileURLs where url.pathExtension == "md" {
            guard let record = summaryRecord(from: url) else {
                continue
            }
            summaries[record.cacheKey] = record
        }

        cachedSummaries = summaries
        summaryCacheLoaded = true
    }

    private func loadGlobalMemoryUnsafe() -> String {
        let manual = loadManualMemoryUnsafe()
        let generated = loadGeneratedMemoryUnsafe()
        return [manual, generated]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func memoryRelevantMessages(from messages: [Message]) -> [Message] {
        messages.filter { message in
            switch message.role {
            case .system:
                if message.hiddenFromTranscript == true && message.content.contains("[本地文件意图分析]") {
                    return false
                }
                return message.content.contains("[本次对话的历史摘要]") || message.hiddenFromTranscript != true
            case .assistant:
                return !(message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (message.toolCalls?.isEmpty ?? true))
            default:
                return true
            }
        }
    }

    private func incrementalDeltaMessages(
        from messages: [Message],
        checkpoint: ConversationMemoryCheckpoint?
    ) -> [Message] {
        guard let checkpoint,
              checkpoint.messageCount > 0,
              checkpoint.messageCount < messages.count else {
            return messages
        }
        return Array(messages.suffix(from: checkpoint.messageCount))
    }

    private func messageFingerprint(for messages: [Message]) -> String {
        let joined = messages.map { message in
            [
                message.role.rawValue,
                message.content,
                message.toolExecution?.name ?? "",
                message.attachmentID ?? "",
                message.timestamp.ISO8601Format()
            ].joined(separator: "|")
        }.joined(separator: "\n")

        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func semanticMemoryID(for category: String, slot: String?, content: String) -> String {
        let identity = slot.map { "\(category)|slot|\($0)" } ?? "\(category)|content|\(content)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizeCategory(_ raw: String) -> String {
        let normalized = raw.lowercased()
        switch normalized {
        case "preference", "preferences":
            return "preference"
        case "project", "project_convention":
            return "project"
        case "workflow", "process":
            return "workflow"
        case "constraint", "constraints":
            return "constraint"
        default:
            return "project"
        }
    }

    private func displayTitle(for category: String) -> String {
        switch category {
        case "preference":
            return "User Preferences"
        case "project":
            return "Project Conventions"
        case "workflow":
            return "Workflow Preferences"
        case "constraint":
            return "Constraints"
        default:
            return "General"
        }
    }

    private func renderSemanticMemoryEntry(_ entry: SemanticMemoryEntry) -> String {
        "- [\(displayTitle(for: entry.category))] \(entry.content)"
    }

    private func checkpointKey(convId: UUID, segmentStartedAt: Date?) -> String {
        summaryCacheKey(convId: convId, segmentStartedAt: segmentStartedAt)
    }

    private func summaryCacheKey(convId: UUID, segmentStartedAt: Date?) -> String {
        if let segmentStartedAt {
            return "\(convId.uuidString)|segment|\(summarySegmentIdentifier(from: segmentStartedAt))"
        }
        return convId.uuidString
    }

    private func summaryFileURL(convId: UUID, segmentStartedAt: Date?) -> URL {
        let fileName: String
        if let segmentStartedAt {
            fileName = "\(convId.uuidString)__segment-\(summarySegmentIdentifier(from: segmentStartedAt)).md"
        } else {
            fileName = "\(convId.uuidString).md"
        }
        return conversationSummaryDir.appendingPathComponent(fileName)
    }

    private func summarySegmentIdentifier(from date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    private func latestSummaryRecordUnsafe(for convId: UUID) -> SummaryRecord? {
        cachedSummaries.values
            .filter { $0.convId == convId }
            .sorted { lhs, rhs in
                let lhsDate = lhs.segmentStartedAt ?? .distantPast
                let rhsDate = rhs.segmentStartedAt ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private func summaryRecord(from url: URL) -> SummaryRecord? {
        let baseName = url.deletingPathExtension().lastPathComponent
        let parts = baseName.components(separatedBy: "__segment-")
        guard let convId = UUID(uuidString: parts[0]),
              let rawContent = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        let segmentStartedAt: Date?
        if parts.count == 2, let timestamp = TimeInterval(parts[1]) {
            segmentStartedAt = Date(timeIntervalSince1970: timestamp)
        } else {
            segmentStartedAt = nil
        }

        let cacheKey = summaryCacheKey(convId: convId, segmentStartedAt: segmentStartedAt)
        return SummaryRecord(
            cacheKey: cacheKey,
            convId: convId,
            segmentStartedAt: segmentStartedAt,
            summary: content
        )
    }

    private func relevantMemorySectionsUnsafe(query: String, maxResults: Int) -> [String] {
        let queryTerms = tokenize(query)
        let matches = relevantMemoryMatchesUnsafe(queryTerms: queryTerms, maxResults: maxResults)
        if !matches.isEmpty {
            return matches.map(\.rendered)
        }

        let fallbackSemantic = loadMemoryIndexUnsafe().semanticEntries
            .sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
            .prefix(maxResults)
            .map(renderSemanticMemoryEntry)
        let fallbackManual = manualMemorySections(from: loadManualMemoryUnsafe()).suffix(1)
        return Array(fallbackSemantic) + fallbackManual
    }

    private func relevantMemoryMatchesUnsafe(queryTerms: [String], maxResults: Int) -> [MemoryMatch] {
        let semanticMatches = loadMemoryIndexUnsafe().semanticEntries.compactMap { entry -> MemoryMatch? in
            let slot = effectiveSlot(for: entry)
            let haystack = [entry.category, slot ?? "", entry.content]
                .joined(separator: " ")
                .lowercased()
            let score = scoreMatch(in: haystack, queryTerms: queryTerms)
                + (slot == nil ? 0 : 2)
                + recencyBoost(for: entry.updatedAt)
            guard queryTerms.isEmpty ? slot != nil : score > 0 else {
                return nil
            }
            return MemoryMatch(
                rendered: renderSemanticMemoryEntry(entry),
                score: score,
                updatedAt: entry.updatedAt
            )
        }

        let manualMatches = manualMemorySections(from: loadManualMemoryUnsafe()).compactMap { section -> MemoryMatch? in
            let score = scoreMatch(in: section.lowercased(), queryTerms: queryTerms)
            guard !queryTerms.isEmpty, score > 0 else { return nil }
            return MemoryMatch(rendered: section, score: score, updatedAt: .distantPast)
        }

        return Array((semanticMatches + manualMatches)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.rendered.count < rhs.rendered.count
            }
            .prefix(maxResults))
    }

    private func memoryContextSourceSignatureUnsafe(query: String, maxResults: Int) -> String {
        let index = loadMemoryIndexUnsafe()
        let latestSemanticTimestamp = index.semanticEntries.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let manualLength = loadManualMemoryUnsafe().count
        return "\(query)|\(maxResults)|\(index.semanticEntries.count)|\(latestSemanticTimestamp)|\(manualLength)"
    }

    private func extractJSONArray(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start <= end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private func sanitizedArchiveTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMemoryContent(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func normalizeSlot(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "output_format", "format", "delivery_format":
            return "output_format"
        case "overwrite_strategy", "overwrite", "file_overwrite_strategy":
            return "overwrite_strategy"
        case "response_language", "language", "output_language":
            return "response_language"
        case "delivery_style", "response_style", "tone":
            return "delivery_style"
        case "tool_preference", "tooling", "tool":
            return "tool_preference"
        default:
            return trimmed.replacingOccurrences(of: " ", with: "_")
        }
    }

    private func inferredSlot(for content: String, category: String) -> String? {
        let lowercased = content.lowercased()
        if lowercased.contains("markdown") || lowercased.contains("pdf") || lowercased.contains("docx") || lowercased.contains("word") || lowercased.contains("xlsx") || lowercased.contains("excel") {
            return "output_format"
        }
        if lowercased.contains("保留原文件") || lowercased.contains("不要覆盖") || lowercased.contains("覆盖原文件") || lowercased.contains("直接覆盖") {
            return "overwrite_strategy"
        }
        if lowercased.contains("中文") || lowercased.contains("英文") || lowercased.contains("english") || lowercased.contains("chinese") {
            return "response_language"
        }
        if category == "workflow", lowercased.contains("优先") {
            return "tool_preference"
        }
        return nil
    }

    private func effectiveSlot(for entry: SemanticMemoryEntry) -> String? {
        normalizeSlot(entry.slot) ?? inferredSlot(for: entry.content, category: entry.category)
    }

    private func scoreMatch(in haystack: String, queryTerms: [String]) -> Int {
        guard !queryTerms.isEmpty else { return 0 }
        return queryTerms.reduce(into: 0) { partial, term in
            if haystack.contains(term) {
                partial += 3
            }
        }
    }

    private func recencyBoost(for date: Date) -> Int {
        let age = Date().timeIntervalSince(date)
        switch age {
        case ..<86_400:
            return 2
        case ..<604_800:
            return 1
        default:
            return 0
        }
    }

    private func manualMemorySections(from memory: String) -> [String] {
        memory.components(separatedBy: "## ")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "## " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func truncateMemorySections(_ sections: [String], maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        var collected: [String] = []
        var used = 0

        for section in sections {
            let cost = section.count + (collected.isEmpty ? 0 : 2)
            if !collected.isEmpty, used + cost > maxChars {
                break
            }
            if collected.isEmpty, cost > maxChars {
                collected.append(String(section.prefix(maxChars)))
                break
            }
            collected.append(section)
            used += cost
        }

        return collected.joined(separator: "\n\n")
    }

    private func tokenize(_ text: String) -> [String] {
        let latinTokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        if !latinTokens.isEmpty {
            return latinTokens
        }

        let compact = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard compact.count >= 2 else { return compact.isEmpty ? [] : [compact] }

        let characters = Array(compact)
        return deduplicated((0..<(characters.count - 1)).map { index in
            String(characters[index...index + 1]).lowercased()
        })
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func deduplicated<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
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

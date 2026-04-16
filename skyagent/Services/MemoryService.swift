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
    nonisolated private static let allowedGlobalPreferenceSlots: [String] = [
        "response_language",
        "delivery_style",
        "answer_structure",
        "output_format",
        "overwrite_strategy",
        "tool_preference"
    ]
    nonisolated private static let allowedGlobalPreferenceSlotSet = Set(allowedGlobalPreferenceSlots)
    nonisolated private static let explicitLongTermSignals: [String] = [
        "以后默认", "默认都", "默认用", "以后都", "以后请", "今后默认", "长期偏好", "全局偏好", "习惯上",
        "以後預設", "預設都", "預設用", "以後都", "以後請", "今後預設", "長期偏好", "全域偏好",
        "by default", "default to", "prefer by default", "going forward", "always use", "long-term preference", "global preference",
        "今後はデフォルト", "以後はデフォルト", "長期設定", "グローバル設定", "常に使う",
        "앞으로 기본", "기본적으로", "장기 선호", "전역 선호", "항상 사용",
        "standardmäßig", "künftig standardmäßig", "langfristige präferenz", "globale präferenz", "immer verwenden",
        "par défaut", "à l'avenir", "préférence long terme", "préférence globale", "toujours utiliser"
    ]
    nonisolated private static let localizedPreferenceKeywords: [String] = [
        "语言", "中文", "繁體中文", "英文", "日文", "韩文", "德文", "法文",
        "語言", "繁體中文", "英文", "日文", "韓文", "德文", "法文",
        "风格", "簡潔", "简洁", "详细", "結構", "结构", "格式", "覆盖", "保留原文件", "不要覆盖", "输出", "偏好",
        "language", "english", "chinese", "japanese", "korean", "german", "french", "style", "concise", "detailed", "structure", "format", "overwrite", "keep original file", "output", "preference",
        "言語", "英語", "中国語", "日本語", "韓国語", "ドイツ語", "フランス語", "文体", "簡潔", "詳細", "構成", "形式", "上書き", "元ファイル", "出力", "設定",
        "언어", "영어", "중국어", "일본어", "한국어", "독일어", "프랑스어", "스타일", "간결", "자세히", "구조", "형식", "덮어쓰기", "원본 파일", "출력", "선호",
        "sprache", "englisch", "chinesisch", "japanisch", "koreanisch", "deutsch", "französisch", "stil", "knapp", "detailliert", "struktur", "format", "überschreiben", "originaldatei", "ausgabe", "präferenz",
        "langue", "anglais", "chinois", "japonais", "coréen", "allemand", "français", "style", "concis", "détaillé", "structure", "format", "écraser", "fichier d'origine", "sortie", "préférence",
        "markdown", "pdf", "docx", "word", "excel", "xlsx",
        "response_language", "delivery_style", "output_format", "overwrite_strategy", "answer_structure"
    ]
    nonisolated private static let localizedPreferencePrefixes: [String] = [
        "语言:", "風格:", "风格:", "格式:", "輸出:", "输出:", "偏好:",
        "語言:", "結構:", "覆盖策略:", "覆蓋策略:",
        "language:", "style:", "format:", "output:", "preference:", "response_language:", "delivery_style:", "output_format:", "overwrite_strategy:", "answer_structure:",
        "言語:", "文体:", "形式:", "出力:", "設定:",
        "언어:", "스타일:", "형식:", "출력:", "선호:",
        "sprache:", "stil:", "format:", "ausgabe:", "präferenz:",
        "langue:", "style:", "format:", "sortie:", "préférence:"
    ]

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
    private let maxGlobalSemanticEntries = 12
    private let maxManualGlobalMemorySections = 12

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
            _ = loadManualMemoryUnsafe()
            preloadSummaryCacheIfNeeded()
        }
    }

    // MARK: - Memory Loading

    func loadGlobalMemory() -> String {
        stateQueue.sync {
            loadGlobalMemoryUnsafe()
        }
    }

    @available(*, deprecated, message: "Use appendManualGlobalPreference(_:) for explicit long-term global preferences only.")
    func appendToGlobalMemory(_ entry: String) {
        appendManualGlobalPreference(entry)
    }

    func appendManualGlobalPreference(_ entry: String) {
        let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEntry.isEmpty else { return }
        guard shouldPersistManualGlobalMemory(entry: trimmedEntry) else { return }

        stateQueue.sync {
            var existing = loadManualMemoryUnsafe()
            let timestamp = formatTimestamp(Date())
            let newEntry = "\n## \(timestamp)\n\(trimmedEntry)\n"
            existing += newEntry

            existing = trimmedManualGlobalMemory(existing)

            try? existing.write(to: manualMemoryURL, atomically: true, encoding: .utf8)
            cachedManualMemory = existing
            cachedMemoryContexts.removeAll()
        }
    }

    func buildMemoryContext(query: String, maxResults: Int = 4, maxTokens: Int = 120) -> String {
        stateQueue.sync {
            let normalizedQuery = normalizedMemoryContent(query).lowercased()
            let cacheKey = "\(maxTokens)|\(maxResults)|\(normalizedQuery)"
            let sourceSignature = memoryContextSourceSignatureUnsafe(query: normalizedQuery, maxResults: maxResults)
            if let cached = cachedMemoryContexts[cacheKey], cached.sourceSignature == sourceSignature {
                return cached.context
            }

            let lines = relevantGlobalPreferenceLinesUnsafe(query: normalizedQuery, maxResults: maxResults)
            guard !lines.isEmpty else { return "" }

            let maxChars = max(maxTokens * 2, 240)
            let context = truncateMemorySections(lines, maxChars: maxChars)
            let built = """
            [与你当前任务相关的全局偏好]
            以下仅包含与当前任务相关的用户长期偏好。
            只在确实相关时自然利用。

            \(context)
            [记忆结束]
            """
            cachedMemoryContexts[cacheKey] = (sourceSignature, built)
            return built
        }
    }

    // MARK: - Summaries

    func generateSummary(messages: [Message], llmService: LLMService?, settings: AppSettings) async -> String {
        await generateSummary(messages: messages, existingSummary: nil, llmService: llmService, settings: settings, traceContext: nil)
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
        let memoryTraceContext = TraceContext(conversationID: convId)
        if snapshot.shouldUpdateIncrementally {
            summary = await generateSummary(
                messages: snapshot.deltaMessages,
                existingSummary: snapshot.previousSummary.isEmpty ? nil : snapshot.previousSummary,
                llmService: llmService,
                settings: settings,
                traceContext: memoryTraceContext
            )
        } else {
            summary = await generateSummary(
                messages: relevantMessages,
                existingSummary: nil,
                llmService: llmService,
                settings: settings,
                traceContext: memoryTraceContext
            )
        }

        let semanticCandidates = await extractSemanticMemoryCandidates(
            title: title,
            summary: summary,
            messages: snapshot.deltaMessages.isEmpty ? relevantMessages : snapshot.deltaMessages,
            llmService: llmService,
            settings: settings,
            traceContext: memoryTraceContext
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
        settings: AppSettings,
        traceContext: TraceContext?
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
                try await llm.chat(
                    messages: [LLMService.ChatMessage(role: "user", content: prompt)],
                    toolDefinitions: nil,
                    trackAsCurrentTask: false,
                    traceContext: traceContext,
                    extraLogMetadata: [
                        "request_scope": .string("background_memory"),
                        "request_purpose": .string("summary_generation")
                    ]
                ) { delta in
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
        settings: AppSettings,
        traceContext: TraceContext?
    ) async -> [SemanticMemoryCandidate] {
        if let llm = llmService, !settings.apiKey.isEmpty {
            do {
                let collector = StreamCollector()
                let prompt = """
                你在维护一个 agent 的全局长期记忆。
                请只提取“跨工作区、跨项目、未来仍长期有用”的用户级稳定偏好。
                只有当用户明确表达了“以后默认这样”“今后都这样”“长期偏好”这类长期规则时，才允许写入全局记忆。
                如果某条信息更像当前项目约定、当前工作区习惯、当前任务要求，就不要写入全局记忆。
                只允许提取以下 slot：
                - response_language
                - delivery_style
                - answer_structure
                - output_format
                - overwrite_strategy
                - tool_preference

                不要保留：
                - 当前项目约定
                - 当前工作区规则
                - 一次性任务
                - 临时文件名
                - 短期执行结果
                - 只对当前工作区有效的信息
                - 明显只对当前一轮有效的信息

                返回严格 JSON 数组，每项格式：
                {"category":"preference","slot":"固定槽位名","content":"..."}
                其中 category 必须始终为 preference，slot 必须是上面允许的固定值之一。
                如果没有长期记忆，返回 []。

                会话标题：
                \(title)

                当前摘要：
                \(summary)

                最近消息：
                \(summarizePayload(for: messages))
                """
                try await llm.chat(
                    messages: [LLMService.ChatMessage(role: "user", content: prompt)],
                    toolDefinitions: nil,
                    trackAsCurrentTask: false,
                    traceContext: traceContext,
                    extraLogMetadata: [
                        "request_scope": .string("background_memory"),
                        "request_purpose": .string("semantic_memory_extraction")
                    ]
                ) { delta in
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
                guard let content = item["content"] as? String else {
                    return nil
                }
                let normalizedSlot = normalizeSlot(item["slot"] as? String)
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedContent.isEmpty,
                      let normalizedSlot,
                      Self.allowedGlobalPreferenceSlotSet.contains(normalizedSlot) else {
                    return nil
                }
                return SemanticMemoryCandidate(category: "preference", slot: normalizedSlot, content: trimmedContent)
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

        let hasExplicitLongTermSignal = Self.explicitLongTermSignals.contains { joinedUserText.contains($0) }
        guard hasExplicitLongTermSignal else {
            return []
        }

        if joinedUserText.contains("markdown") || joinedUserText.contains(".md") {
            candidates.append(.init(category: "preference", slot: "output_format", content: "默认使用 Markdown 作为交付格式。"))
        }
        if joinedUserText.contains("pdf") {
            candidates.append(.init(category: "preference", slot: "output_format", content: "涉及正式导出时，优先输出 PDF。"))
        }
        if joinedUserText.contains("docx") || joinedUserText.contains("word") {
            candidates.append(.init(category: "preference", slot: "output_format", content: "涉及正式文档时，默认输出 Word / DOCX 格式。"))
        }
        if joinedUserText.contains("xlsx") || joinedUserText.contains("excel") {
            candidates.append(.init(category: "preference", slot: "output_format", content: "涉及结构化表格时，默认输出 Excel / XLSX 格式。"))
        }
        if summary.contains("不要覆盖") || summary.contains("保留原文件") {
            candidates.append(.init(category: "preference", slot: "overwrite_strategy", content: "修改文件时优先保留原文件，避免直接覆盖。"))
        }
        if summary.contains("覆盖原文件") || summary.contains("直接覆盖") {
            candidates.append(.init(category: "preference", slot: "overwrite_strategy", content: "在用户明确要求时允许直接覆盖原文件。"))
        }
        if joinedUserText.contains("中文") || joinedUserText.contains("汉语") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用中文沟通与输出。"))
        }
        if joinedUserText.contains("繁體中文") || joinedUserText.contains("繁体中文") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用繁體中文沟通与输出。"))
        }
        if joinedUserText.contains("英文") || joinedUserText.contains("english") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用英文沟通与输出。"))
        }
        if joinedUserText.contains("日文") || joinedUserText.contains("日本語") || joinedUserText.contains("japanese") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用日文沟通与输出。"))
        }
        if joinedUserText.contains("韩文") || joinedUserText.contains("韓文") || joinedUserText.contains("한국어") || joinedUserText.contains("korean") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用韩文沟通与输出。"))
        }
        if joinedUserText.contains("德文") || joinedUserText.contains("deutsch") || joinedUserText.contains("german") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用德文沟通与输出。"))
        }
        if joinedUserText.contains("法文") || joinedUserText.contains("français") || joinedUserText.contains("french") {
            candidates.append(.init(category: "preference", slot: "response_language", content: "默认使用法文沟通与输出。"))
        }
        if joinedUserText.contains("简洁") || joinedUserText.contains("精简") {
            candidates.append(.init(category: "preference", slot: "delivery_style", content: "默认回答保持简洁直接，优先给结论。"))
        }
        if joinedUserText.contains("concise") || joinedUserText.contains("concis") || joinedUserText.contains("knapp") || joinedUserText.contains("간결") || joinedUserText.contains("簡潔") {
            candidates.append(.init(category: "preference", slot: "delivery_style", content: "默认回答保持简洁直接，优先给结论。"))
        }
        if joinedUserText.contains("先给结论") || joinedUserText.contains("先说结论") {
            candidates.append(.init(category: "preference", slot: "answer_structure", content: "回答时优先先给结论，再补充必要说明。"))
        }
        if joinedUserText.contains("answer first") || joinedUserText.contains("结论先行") || joinedUserText.contains("先給結論") {
            candidates.append(.init(category: "preference", slot: "answer_structure", content: "回答时优先先给结论，再补充必要说明。"))
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
            guard let normalizedSlot,
                  Self.allowedGlobalPreferenceSlotSet.contains(normalizedSlot) else {
                continue
            }

            for entry in entriesByID.values where effectiveSlot(for: entry) == normalizedSlot {
                entriesByID.removeValue(forKey: entry.id)
            }

            let id = semanticMemoryID(for: candidate.category, slot: normalizedSlot, content: normalizedContent)
            if var existingEntry = entriesByID[id] {
                existingEntry.category = "preference"
                existingEntry.slot = normalizedSlot
                existingEntry.content = candidate.content
                existingEntry.updatedAt = Date()
                existingEntry.sourceConversationID = sourceConversationID
                entriesByID[id] = existingEntry
            } else {
                entriesByID[id] = SemanticMemoryEntry(
                    id: id,
                    category: "preference",
                    slot: normalizedSlot,
                    content: candidate.content,
                    sourceConversationID: sourceConversationID,
                    updatedAt: Date()
                )
            }
        }

        return entriesByID.values
            .filter { entry in
                entry.category == "preference" &&
                effectiveSlot(for: entry).map(Self.allowedGlobalPreferenceSlotSet.contains) == true
            }
            .sorted { lhs, rhs in
                let lhsPriority = slotPriority(for: effectiveSlot(for: lhs))
                let rhsPriority = slotPriority(for: effectiveSlot(for: rhs))
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.content < rhs.content
            }
            .prefix(maxGlobalSemanticEntries)
            .map { $0 }
    }

    private func renderGeneratedMemoryUnsafe(entries: [SemanticMemoryEntry]) {
        let filtered = entries.filter {
            $0.category == "preference" &&
            effectiveSlot(for: $0).map(Self.allowedGlobalPreferenceSlotSet.contains) == true
        }
        let language = L10n.contentLanguage
        var lines: [String] = [
            Self.generatedGlobalPreferencesTitle(for: language),
            "",
            Self.generatedGlobalPreferencesSubtitle(for: language),
            ""
        ]

        if filtered.isEmpty {
            lines.append(Self.generatedGlobalPreferencesEmptyState(for: language))
            lines.append("")
        } else {
            for slot in Self.allowedGlobalPreferenceSlots {
                let items = filtered.filter { effectiveSlot(for: $0) == slot }
                guard !items.isEmpty else { continue }
                lines.append("## \(displayTitle(for: slot))")
                for item in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                    lines.append("- \(item.content)")
                }
                lines.append("")
            }
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
        let rawContent = (try? String(contentsOf: manualMemoryURL, encoding: .utf8)) ?? ""
        let sanitizedContent = sanitizedManualGlobalMemory(rawContent)
        if sanitizedContent != rawContent {
            try? sanitizedContent.write(to: manualMemoryURL, atomically: true, encoding: .utf8)
        }
        cachedManualMemory = sanitizedContent
        return sanitizedContent
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
        let language = L10n.contentLanguage
        switch category {
        case "preference":
            return localizedMemoryLabel(
                zhHans: "用户偏好", zhHant: "使用者偏好", en: "User Preferences", ja: "ユーザー設定",
                ko: "사용자 선호", de: "Benutzerpräferenzen", fr: "Préférences utilisateur",
                language: language
            )
        case "response_language":
            return localizedMemoryLabel(
                zhHans: "回复语言", zhHant: "回覆語言", en: "Response Language", ja: "応答言語",
                ko: "응답 언어", de: "Antwortsprache", fr: "Langue de réponse",
                language: language
            )
        case "delivery_style":
            return localizedMemoryLabel(
                zhHans: "表达风格", zhHant: "表達風格", en: "Delivery Style", ja: "表現スタイル",
                ko: "표현 스타일", de: "Stil", fr: "Style de réponse",
                language: language
            )
        case "answer_structure":
            return localizedMemoryLabel(
                zhHans: "回答结构", zhHant: "回答結構", en: "Answer Structure", ja: "回答構成",
                ko: "답변 구조", de: "Antwortstruktur", fr: "Structure de réponse",
                language: language
            )
        case "output_format":
            return localizedMemoryLabel(
                zhHans: "输出格式", zhHant: "輸出格式", en: "Output Format", ja: "出力形式",
                ko: "출력 형식", de: "Ausgabeformat", fr: "Format de sortie",
                language: language
            )
        case "overwrite_strategy":
            return localizedMemoryLabel(
                zhHans: "覆盖策略", zhHant: "覆蓋策略", en: "Overwrite Strategy", ja: "上書き方針",
                ko: "덮어쓰기 전략", de: "Überschreibstrategie", fr: "Stratégie d'écrasement",
                language: language
            )
        case "tool_preference":
            return localizedMemoryLabel(
                zhHans: "工具偏好", zhHant: "工具偏好", en: "Tool Preference", ja: "ツール設定",
                ko: "도구 선호", de: "Tool-Präferenz", fr: "Préférence d'outil",
                language: language
            )
        case "project":
            return localizedMemoryLabel(
                zhHans: "项目约定", zhHant: "專案約定", en: "Project Conventions", ja: "プロジェクト規約",
                ko: "프로젝트 규칙", de: "Projektregeln", fr: "Règles du projet",
                language: language
            )
        case "workflow":
            return localizedMemoryLabel(
                zhHans: "工作流偏好", zhHant: "工作流偏好", en: "Workflow Preferences", ja: "ワークフロー設定",
                ko: "워크플로 선호", de: "Workflow-Präferenzen", fr: "Préférences de workflow",
                language: language
            )
        case "constraint":
            return localizedMemoryLabel(
                zhHans: "约束", zhHant: "約束", en: "Constraints", ja: "制約",
                ko: "제약", de: "Einschränkungen", fr: "Contraintes",
                language: language
            )
        default:
            return localizedMemoryLabel(
                zhHans: "通用", zhHant: "通用", en: "General", ja: "一般",
                ko: "일반", de: "Allgemein", fr: "Général",
                language: language
            )
        }
    }

    private func renderSemanticMemoryEntry(_ entry: SemanticMemoryEntry) -> String {
        if let slot = effectiveSlot(for: entry) {
            return "- [\(displayTitle(for: slot))] \(entry.content)"
        }
        return "- [\(displayTitle(for: entry.category))] \(entry.content)"
    }

    private func renderCompactGlobalPreferenceEntry(_ entry: SemanticMemoryEntry) -> String {
        if let slot = effectiveSlot(for: entry) {
            return "- \(displayTitle(for: slot)): \(entry.content)"
        }
        return "- \(entry.content)"
    }

    private func localizedMemoryLabel(
        zhHans: String,
        zhHant: String,
        en: String,
        ja: String,
        ko: String,
        de: String,
        fr: String,
        language: AppContentLanguage
    ) -> String {
        switch language {
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        case .en: return en
        case .ja: return ja
        case .ko: return ko
        case .de: return de
        case .fr: return fr
        }
    }

    private static func generatedGlobalPreferencesTitle(for language: AppContentLanguage) -> String {
        switch language {
        case .zhHans: return "# 自动提炼的全局偏好"
        case .zhHant: return "# 自動提煉的全域偏好"
        case .en: return "# Generated Global Preferences"
        case .ja: return "# 自動抽出されたグローバル設定"
        case .ko: return "# 자동 추출된 전역 선호"
        case .de: return "# Automatisch extrahierte globale Präferenzen"
        case .fr: return "# Préférences globales extraites automatiquement"
        }
    }

    private static func generatedGlobalPreferencesSubtitle(for language: AppContentLanguage) -> String {
        switch language {
        case .zhHans: return "以下内容由系统从历史对话中提炼，只保留跨工作区仍然成立的用户长期偏好。"
        case .zhHant: return "以下內容由系統從歷史對話中提煉，只保留跨工作區仍然成立的使用者長期偏好。"
        case .en: return "These preferences were extracted from historical conversations and only keep long-term user preferences that still apply across workspaces."
        case .ja: return "以下は過去の会話から抽出された内容で、ワークスペースをまたいで有効な長期的なユーザー設定のみを残しています。"
        case .ko: return "아래 내용은 과거 대화에서 추출된 것으로, 워크스페이스를 넘어 계속 유효한 장기 사용자 선호만 남깁니다."
        case .de: return "Die folgenden Inhalte wurden aus früheren Unterhaltungen extrahiert und behalten nur langfristige Benutzerpräferenzen bei, die über Workspaces hinweg gültig bleiben."
        case .fr: return "Les éléments ci-dessous sont extraits des conversations passées et ne conservent que les préférences utilisateur durables valables à travers les espaces de travail."
        }
    }

    private static func generatedGlobalPreferencesEmptyState(for language: AppContentLanguage) -> String {
        switch language {
        case .zhHans: return "暂无系统自动提炼的全局偏好。"
        case .zhHant: return "暫無系統自動提煉的全域偏好。"
        case .en: return "No generated global preferences yet."
        case .ja: return "まだ自動抽出されたグローバル設定はありません。"
        case .ko: return "아직 자동 추출된 전역 선호가 없습니다."
        case .de: return "Noch keine automatisch extrahierten globalen Präferenzen."
        case .fr: return "Aucune préférence globale extraite automatiquement pour le moment."
        }
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

    private func relevantGlobalPreferenceLinesUnsafe(query: String, maxResults: Int) -> [String] {
        let queryTerms = tokenize(query)
        let semanticMatches = loadMemoryIndexUnsafe().semanticEntries.compactMap { entry -> MemoryMatch? in
            guard entry.category == "preference" else { return nil }
            let slot = effectiveSlot(for: entry)
            let haystack = [slot ?? "", entry.content].joined(separator: " ").lowercased()
            let score = scoreMatch(in: haystack, queryTerms: queryTerms) + recencyBoost(for: entry.updatedAt) + 2
            guard queryTerms.isEmpty ? slot != nil : score > 0 else { return nil }
            return MemoryMatch(
                rendered: renderCompactGlobalPreferenceEntry(entry),
                score: score,
                updatedAt: entry.updatedAt
            )
        }

        let manualMatches = manualGlobalPreferenceLines(from: loadManualMemoryUnsafe()).compactMap { line -> MemoryMatch? in
            let score = scoreMatch(in: line.lowercased(), queryTerms: queryTerms)
            guard queryTerms.isEmpty ? true : score > 0 else { return nil }
            return MemoryMatch(
                rendered: "- \(line)",
                score: max(score, queryTerms.isEmpty ? 1 : score),
                updatedAt: .distantPast
            )
        }

        let preferred = (semanticMatches + manualMatches)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.rendered.count < rhs.rendered.count
            }
            .prefix(maxResults)
            .map(\.rendered)

        if !preferred.isEmpty {
            return deduplicated(preferred)
        }

        let fallbackSemantic = loadMemoryIndexUnsafe().semanticEntries
            .filter { $0.category == "preference" }
            .sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
            .prefix(maxResults)
            .map(renderCompactGlobalPreferenceEntry)

        if !fallbackSemantic.isEmpty {
            return deduplicated(Array(fallbackSemantic))
        }

        return deduplicated(manualGlobalPreferenceLines(from: loadManualMemoryUnsafe()).prefix(maxResults).map { "- \($0)" })
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

    private func slotPriority(for slot: String?) -> Int {
        guard let slot,
              let index = Self.allowedGlobalPreferenceSlots.firstIndex(of: slot) else {
            return Int.max
        }
        return index
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

    private func sanitizedManualGlobalMemory(_ memory: String) -> String {
        let preferenceLines = manualGlobalPreferenceLines(from: memory)
        guard !preferenceLines.isEmpty else {
            return Self.manualGlobalMemoryTemplate(language: L10n.contentLanguage)
        }

        let renderedLines = deduplicated(preferenceLines).prefix(maxManualGlobalMemorySections).map { "- \($0)" }
        return Self.manualGlobalMemoryTemplate(
            language: L10n.contentLanguage,
            preferenceLines: Array(renderedLines)
        )
    }

    private static func manualGlobalMemoryTemplate(
        language: AppContentLanguage,
        preferenceLines: [String] = []
    ) -> String {
        let renderedPreferenceBlock = preferenceLines.isEmpty
            ? ""
            : "\n" + preferenceLines.joined(separator: "\n")

        switch language {
        case .zhHans:
            return """
            # GLOBAL SKYAGENT

            这里保存跨项目、长期成立的个人偏好。
            只写“以后默认如此”的规则，不要写一次性任务、项目细节或临时执行结果。

            ## 长期偏好\(renderedPreferenceBlock)
            """
        case .zhHant:
            return """
            # GLOBAL SKYAGENT

            這裡保存跨專案、長期成立的個人偏好。
            只寫「之後預設如此」的規則，不要寫一次性的任務、專案細節或臨時執行結果。

            ## 長期偏好\(renderedPreferenceBlock)
            """
        case .en:
            return """
            # GLOBAL SKYAGENT

            Use this file for long-term personal preferences that should apply across projects.
            Only write rules that should remain true by default. Do not put one-off tasks, project details, or temporary results here.

            ## Long-term Preferences\(renderedPreferenceBlock)
            """
        case .ja:
            return """
            # GLOBAL SKYAGENT

            このファイルには、プロジェクトをまたいで長期的に有効な個人設定だけを書いてください。
            一時的なタスク、プロジェクト固有の詳細、臨時の実行結果は書かないでください。

            ## 長期設定\(renderedPreferenceBlock)
            """
        case .ko:
            return """
            # GLOBAL SKYAGENT

            이 파일에는 프로젝트 전반에 걸쳐 장기적으로 유지되는 개인 선호만 적어 주세요.
            일회성 작업, 프로젝트 세부 정보, 임시 실행 결과는 적지 마세요.

            ## 장기 선호\(renderedPreferenceBlock)
            """
        case .de:
            return """
            # GLOBAL SKYAGENT

            Diese Datei ist für langfristige persönliche Präferenzen gedacht, die projektübergreifend gelten.
            Schreiben Sie hier nur Regeln hinein, die standardmäßig dauerhaft gelten sollen. Keine einmaligen Aufgaben, Projektdetails oder temporären Ergebnisse.

            ## Langfristige Präferenzen\(renderedPreferenceBlock)
            """
        case .fr:
            return """
            # GLOBAL SKYAGENT

            Ce fichier sert à conserver les préférences personnelles durables qui doivent s'appliquer à travers les projets.
            N'y mettez que des règles valables par défaut sur le long terme. N'ajoutez pas de tâches ponctuelles, de détails de projet ni de résultats temporaires.

            ## Préférences Long Terme\(renderedPreferenceBlock)
            """
        }
    }

    private func manualGlobalPreferenceLines(from memory: String) -> [String] {
        let lines = memory.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty &&
                !line.hasPrefix("#")
            }
            .map { line -> String in
                if line.hasPrefix("- ") {
                    return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return line
            }
            .filter { isLikelyGlobalPreferenceLine($0) }
            .filter { !$0.isEmpty }

        return deduplicated(Array(lines.prefix(8)))
    }

    private func isLikelyGlobalPreferenceLine(_ line: String) -> Bool {
        let normalized = line.lowercased()
        if Self.explicitLongTermSignals.contains(where: { normalized.contains($0) }) {
            return true
        }

        if Self.localizedPreferenceKeywords.contains(where: { normalized.contains($0) }) {
            return true
        }

        if normalized.contains("：") || normalized.contains(":") {
            let compact = normalized.replacingOccurrences(of: "：", with: ":")
            if Self.localizedPreferencePrefixes.contains(where: { compact.hasPrefix($0) }) {
                return true
            }
        }

        return false
    }

    private func shouldPersistManualGlobalMemory(entry: String) -> Bool {
        let normalized = entry.lowercased()
        return Self.explicitLongTermSignals.contains { normalized.contains($0) }
    }

    private func trimmedManualGlobalMemory(_ memory: String) -> String {
        let sections = manualMemorySections(from: memory)
        let trimmedSections = Array(sections.suffix(maxManualGlobalMemorySections))
        let rebuilt = trimmedSections.joined(separator: "\n\n")

        if rebuilt.count <= maxManualMemoryLength {
            return rebuilt
        }

        let truncated = String(rebuilt.suffix(maxManualMemoryLength))
        if let range = truncated.range(of: "## ") {
            return String(truncated[range.lowerBound...])
        }
        return truncated
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

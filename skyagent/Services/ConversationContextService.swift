import Foundation

final class ConversationContextService {
    nonisolated static let shared = ConversationContextService()

    private let attachmentStore: UploadedAttachmentStore

    init(attachmentStore: UploadedAttachmentStore = .shared) {
        self.attachmentStore = attachmentStore
    }

    nonisolated func buildState(for conversation: Conversation, fallbackSandboxDir: String) -> ConversationContextState {
        let latestIntent = latestIntentContext(in: conversation)
        let segment = currentTaskSegment(in: conversation)
        let scopeStartDate = segment.startDate
        return ConversationContextState(
            taskSummary: buildTaskSummary(conversation: conversation, intent: latestIntent, scopeStartDate: scopeStartDate),
            activeTargets: normalize(buildTargets(conversation: conversation, intent: latestIntent, fallbackSandboxDir: fallbackSandboxDir, scopeStartDate: scopeStartDate), limit: 5),
            activeConstraints: normalize(buildConstraints(conversation: conversation, intent: latestIntent, fallbackSandboxDir: fallbackSandboxDir, scopeStartDate: scopeStartDate), limit: 10),
            activeSkillNames: normalize(conversation.activatedSkillIDs, limit: 4),
            recentResults: normalize(buildRecentResults(conversation: conversation, scopeStartDate: scopeStartDate), limit: 4),
            recentTimeline: normalize(buildRecentTimeline(conversation: conversation, scopeStartDate: scopeStartDate), limit: 6),
            openQuestions: normalize(buildOpenQuestions(intent: latestIntent), limit: 2),
            nextLikelyStep: buildNextLikelyStep(conversation: conversation, intent: latestIntent, scopeStartDate: scopeStartDate),
            blockedBy: buildBlockedBy(conversation: conversation, intent: latestIntent, scopeStartDate: scopeStartDate),
            userDecision: buildUserDecision(conversation: conversation, scopeStartDate: scopeStartDate),
            segmentStartedAt: segment.startDate,
            segmentReason: segment.reason,
            updatedAt: Date()
        )
    }

    private nonisolated func buildTaskSummary(
        conversation: Conversation,
        intent: ParsedIntentContext?,
        scopeStartDate: Date?
    ) -> String {
        if let summary = intent?.summary, !summary.isEmpty {
            return summary
        }
        let scopedMessages = scopedUserMessages(in: conversation, scopeStartDate: scopeStartDate)
        guard !scopedMessages.isEmpty else {
            return ""
        }

        let summary = scopedMessages.suffix(2)
            .map {
                $0.components(separatedBy: .newlines)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
        return String(summary.prefix(120))
    }

    private nonisolated func buildTargets(
        conversation: Conversation,
        intent: ParsedIntentContext?,
        fallbackSandboxDir: String,
        scopeStartDate: Date?
    ) -> [String] {
        var targets: [String] = []
        let effectiveSandboxDir = conversation.sandboxDir.isEmpty ? fallbackSandboxDir : conversation.sandboxDir

        if let targetPath = intent?.targetPath, !targetPath.isEmpty {
            targets.append("优先目标文件：\((targetPath as NSString).lastPathComponent)")
            targets.append("目标路径：\(targetPath)")
        }

        if let attachmentID = intent?.referencedAttachmentID ?? latestAttachmentID(in: conversation, scopeStartDate: scopeStartDate),
           let attachment = attachmentStore.loadDocument(id: attachmentID) {
            targets.append("参考附件：\(attachment.fileName)")
        }

        if let recentPath = recentOperationTargetPath(in: conversation, scopeStartDate: scopeStartDate),
           recentPath != intent?.targetPath {
            targets.append("最近操作文件：\((recentPath as NSString).lastPathComponent)")
        }

        targets.append("当前工作目录：\(effectiveSandboxDir)")
        return targets
    }

    private nonisolated func buildConstraints(
        conversation: Conversation,
        intent: ParsedIntentContext?,
        fallbackSandboxDir: String,
        scopeStartDate: Date?
    ) -> [String] {
        var constraints: [String] = []
        let effectiveSandboxDir = conversation.sandboxDir.isEmpty ? fallbackSandboxDir : conversation.sandboxDir

        constraints.append("权限模式：\(permissionModeLabel(for: conversation.filePermissionMode))")
        constraints.append("工作目录：\(effectiveSandboxDir)")

        switch conversation.filePermissionMode {
        case .sandbox:
            constraints.append("当前工作目录可读写，其他路径只读，网络受限")
        case .open:
            constraints.append("可访问系统路径并允许联网与 shell")
        }

        if let plannedArguments = intent?.plannedArguments {
            if let sheetName = plannedArguments["sheet_name"], !sheetName.isEmpty {
                constraints.append("当前工作表：\(sheetName)")
            }
            if let cell = plannedArguments["cell"], !cell.isEmpty {
                constraints.append("当前单元格：\(cell)")
            }
            if let sectionTitle = plannedArguments["section_title"], !sectionTitle.isEmpty {
                constraints.append("当前章节：\(sectionTitle)")
            }
            if let afterSection = plannedArguments["after_section_title"], !afterSection.isEmpty {
                constraints.append("插入位置：\(afterSection) 之后")
            }
        }

        constraints.append(contentsOf: extractPersistentConstraints(from: conversation, scopeStartDate: scopeStartDate))

        return constraints
    }

    private nonisolated func buildRecentResults(conversation: Conversation, scopeStartDate: Date?) -> [String] {
        conversation.recentOperations
            .filter { scopeStartDate == nil || $0.createdAt >= scopeStartDate! }
            .prefix(3)
            .map { operation in
            let summary = operation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? operation.title : "\(operation.title)：\(summary)"
        }
    }

    private nonisolated func buildRecentTimeline(conversation: Conversation, scopeStartDate: Date?) -> [String] {
        let userEvents = conversation.messages
            .filter { $0.role == .user && (scopeStartDate == nil || $0.timestamp >= scopeStartDate!) }
            .suffix(4)
            .map { message in
                TimelineEvent(
                    timestamp: message.timestamp,
                    text: "用户要求：\(timelineSummary(from: message.content, limit: 70))"
                )
            }

        let operationEvents = conversation.recentOperations
            .filter { scopeStartDate == nil || $0.createdAt >= scopeStartDate! }
            .prefix(4)
            .map { operation in
                let actionPrefix = operation.isUndone ? "已撤销" : "已执行"
                let detail = operation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = detail.isEmpty
                    ? "\(actionPrefix)：\(operation.title)"
                    : "\(actionPrefix)：\(operation.title)（\(timelineSummary(from: detail, limit: 70))）"
                return TimelineEvent(timestamp: operation.createdAt, text: text)
            }

        return (userEvents + operationEvents)
            .sorted { lhs, rhs in lhs.timestamp < rhs.timestamp }
            .suffix(6)
            .map(\.text)
    }

    private nonisolated func buildOpenQuestions(intent: ParsedIntentContext?) -> [String] {
        var questions: [String] = []
        if let clarification = intent?.clarificationQuestion, !clarification.isEmpty {
            questions.append(clarification)
        }
        if let confirmation = intent?.writeConfirmationQuestion, !confirmation.isEmpty {
            questions.append(confirmation)
        }
        return questions
    }

    private nonisolated func buildNextLikelyStep(
        conversation: Conversation,
        intent: ParsedIntentContext?,
        scopeStartDate: Date?
    ) -> String? {
        if let clarification = intent?.clarificationQuestion, !clarification.isEmpty {
            return "等待用户确认后继续：\(clarification)"
        }
        if let confirmation = intent?.writeConfirmationQuestion, !confirmation.isEmpty {
            return "等待写入确认后继续：\(confirmation)"
        }
        if let pending = buildBlockedBy(conversation: conversation, intent: intent, scopeStartDate: scopeStartDate) {
            return "先解除阻塞：\(pending)"
        }

        if let recentOperation = conversation.recentOperations.first(where: { scopeStartDate == nil || $0.createdAt >= scopeStartDate! }) {
            if recentOperation.isUndone {
                return "根据撤销后的状态继续后续处理"
            }
            let summary = recentOperation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                return "基于最近结果继续：\(timelineSummary(from: summary, limit: 80))"
            }
            return "继续处理与 \(recentOperation.title) 相关的后续步骤"
        }

        let recentUserMessages = scopedUserMessages(in: conversation, scopeStartDate: scopeStartDate)
        if let lastUserMessage = recentUserMessages.last, !lastUserMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "继续完成用户刚才提出的请求：\(timelineSummary(from: lastUserMessage, limit: 80))"
        }

        return nil
    }

    private nonisolated func buildBlockedBy(
        conversation: Conversation,
        intent: ParsedIntentContext?,
        scopeStartDate: Date?
    ) -> String? {
        if let clarification = intent?.clarificationQuestion, !clarification.isEmpty {
            return clarification
        }
        if let confirmation = intent?.writeConfirmationQuestion, !confirmation.isEmpty {
            return confirmation
        }

        let recentMessages = conversation.messages
            .filter { scopeStartDate == nil || $0.timestamp >= scopeStartDate! }
            .suffix(6)

        if let lastAssistant = recentMessages.reversed().first(where: { $0.role == .assistant }) {
            let content = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.localizedCaseInsensitiveContains("需要确认")
                || content.localizedCaseInsensitiveContains("请确认")
                || content.localizedCaseInsensitiveContains("等待确认")
                || content.localizedCaseInsensitiveContains("需要你确认") {
                return timelineSummary(from: content, limit: 90)
            }
        }

        return nil
    }

    private nonisolated func buildUserDecision(
        conversation: Conversation,
        scopeStartDate: Date?
    ) -> String? {
        let scopedMessages = conversation.messages
            .filter { $0.role == .user && (scopeStartDate == nil || $0.timestamp >= scopeStartDate!) }
            .suffix(6)
            .map(\.content)

        for message in scopedMessages.reversed() {
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            if normalized.contains("按这个来") || normalized.contains("就这么做") || normalized.contains("可以，继续") || normalized.contains("继续吧") {
                return "用户已确认继续当前方案"
            }
            if normalized.contains("不要覆盖") || normalized.contains("保留原文件") || normalized.contains("另存为") {
                return "用户要求保留原文件，不直接覆盖"
            }
            if normalized.contains("覆盖原文件") || normalized.contains("直接覆盖") {
                return "用户允许直接覆盖原文件"
            }
            if normalized.contains("先不要") || normalized.contains("先不做") || normalized.contains("暂停") {
                return "用户要求暂停或暂不执行当前动作"
            }
        }

        return nil
    }

    private nonisolated func latestAttachmentID(in conversation: Conversation, scopeStartDate: Date?) -> String? {
        conversation.messages
            .filter { scopeStartDate == nil || $0.timestamp >= scopeStartDate! }
            .reversed()
            .compactMap(\.attachmentID)
            .first
    }

    private nonisolated func recentOperationTargetPath(in conversation: Conversation, scopeStartDate: Date?) -> String? {
        for operation in conversation.recentOperations where scopeStartDate == nil || operation.createdAt >= scopeStartDate! {
            for line in operation.detailLines {
                if let path = extractAbsolutePath(from: line) {
                    return path
                }
            }
        }
        return nil
    }

    private nonisolated func extractAbsolutePath(from line: String) -> String? {
        guard let slashIndex = line.firstIndex(of: "/") else { return nil }
        let candidate = String(line[slashIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private nonisolated func latestIntentContext(in conversation: Conversation) -> ParsedIntentContext? {
        guard let content = conversation.messages.reversed().first(where: {
            $0.role == .system &&
            $0.hiddenFromTranscript == true &&
            $0.content.contains("[本地文件意图分析]")
        })?.content else {
            return nil
        }
        return parseIntentContext(from: content)
    }

    private nonisolated func extractPersistentConstraints(from conversation: Conversation, scopeStartDate: Date?) -> [String] {
        let recentUserMessages = scopedUserMessages(in: conversation, scopeStartDate: scopeStartDate)

        guard !recentUserMessages.isEmpty else { return [] }

        let combined = recentUserMessages.joined(separator: "\n")
        let lowercased = combined.lowercased()
        var constraints: [String] = []

        if lowercased.contains("docx") || combined.contains("Word") || combined.contains("word") {
            if lowercased.contains("导出") || lowercased.contains("输出") || lowercased.contains("生成") || lowercased.contains("写入") {
                constraints.append("输出格式：Word")
            }
        }

        if lowercased.contains("xlsx") || combined.contains("Excel") || combined.contains("excel") {
            if lowercased.contains("导出") || lowercased.contains("输出") || lowercased.contains("生成") || lowercased.contains("写入") {
                constraints.append("输出格式：Excel")
            }
        }

        if lowercased.contains("pdf") {
            if lowercased.contains("导出") || lowercased.contains("输出") || lowercased.contains("生成") {
                constraints.append("输出格式：PDF")
            }
        }

        if lowercased.contains("markdown") || lowercased.contains(".md") {
            constraints.append("输出格式：Markdown")
        }

        if combined.contains("不要覆盖") || combined.contains("保留原文件") || combined.contains("另存为") || combined.contains("不要改原文件") {
            constraints.append("覆盖策略：保留原文件")
        } else if combined.contains("覆盖原文件") || combined.contains("直接覆盖") || combined.contains("替换原文件") {
            constraints.append("覆盖策略：允许覆盖原文件")
        }

        if let ratio = extractImageRatio(from: combined) {
            constraints.append("图片比例：\(ratio)")
        }

        if let resolution = extractResolution(from: lowercased) {
            constraints.append("输出分辨率：\(resolution)")
        }

        if let explicitDirectory = extractExplicitDirectory(from: combined) {
            constraints.append("目标目录：\(explicitDirectory)")
        }

        return constraints
    }

    private nonisolated func scopedUserMessages(in conversation: Conversation, scopeStartDate: Date?) -> [String] {
        conversation.messages
            .filter { $0.role == .user && (scopeStartDate == nil || $0.timestamp >= scopeStartDate!) }
            .suffix(8)
            .map(\.content)
    }

    private nonisolated func isContextResetCue(_ text: String) -> Bool {
        let cues = [
            "换一个任务", "换个任务", "重新开始", "重新来", "换一个文件", "换个文件",
            "先不看这个", "先不管这个", "忽略前面", "不看前面的", "另一个任务", "新的任务",
            "换到另一个", "切到另一个", "看下另一个", "处理另一个", "再开一个任务"
        ]
        return cues.contains(where: { text.localizedCaseInsensitiveContains($0) })
    }

    private nonisolated func currentTaskSegment(in conversation: Conversation) -> TaskSegmentBoundary {
        let userMessages = conversation.messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else {
            return TaskSegmentBoundary(startDate: nil, reason: nil)
        }

        var segmentStartDate: Date?
        var segmentReason: String?
        var currentFocusSignals = Set<String>()

        for (index, message) in userMessages.enumerated() {
            let content = normalizedContent(message.content)
            let focusSignals = extractFocusSignals(from: content)

            if isContextResetCue(content) {
                segmentStartDate = message.timestamp
                segmentReason = "explicit_reset"
                currentFocusSignals = focusSignals
                continue
            }

            guard index > 0 else {
                currentFocusSignals = focusSignals
                continue
            }

            if isLikelyTaskPivot(content, currentFocusSignals: currentFocusSignals, nextFocusSignals: focusSignals) {
                segmentStartDate = message.timestamp
                segmentReason = "focus_shift"
                currentFocusSignals = focusSignals
                continue
            }

            currentFocusSignals.formUnion(focusSignals)
        }

        return TaskSegmentBoundary(startDate: segmentStartDate, reason: segmentReason)
    }

    private nonisolated func isLikelyTaskPivot(
        _ text: String,
        currentFocusSignals: Set<String>,
        nextFocusSignals: Set<String>
    ) -> Bool {
        let lowercased = text.lowercased()
        let pivotCues = [
            "另外", "另一个", "顺便", "接下来", "再处理", "再看", "换到", "切到", "改看", "然后看下"
        ]
        let hasPivotCue = pivotCues.contains(where: { lowercased.contains($0) })
        let changedFocus = !nextFocusSignals.isEmpty &&
            !currentFocusSignals.isEmpty &&
            currentFocusSignals.isDisjoint(with: nextFocusSignals)
        let explicitObjectCue = text.contains("目录") || text.contains("文件") || text.contains("项目") || text.contains("仓库")
        return changedFocus && (hasPivotCue || explicitObjectCue)
    }

    private nonisolated func extractFocusSignals(from text: String) -> Set<String> {
        var signals = Set<String>()

        let nsText = text as NSString
        if let pathRegex = try? NSRegularExpression(pattern: #"/[^\s\"\n，。；、,]+"#) {
            let range = NSRange(location: 0, length: nsText.length)
            for match in pathRegex.matches(in: text, range: range) {
                signals.insert(nsText.substring(with: match.range).lowercased())
            }
        }

        if let fileRegex = try? NSRegularExpression(pattern: #"[A-Za-z0-9_\-]+\.[A-Za-z0-9]{1,8}"#) {
            let range = NSRange(location: 0, length: nsText.length)
            for match in fileRegex.matches(in: text, range: range) {
                signals.insert(nsText.substring(with: match.range).lowercased())
            }
        }

        return signals
    }

    private nonisolated func normalizedContent(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func timelineSummary(from text: String, limit: Int) -> String {
        String(normalizedContent(text).prefix(limit))
    }

    private nonisolated func extractImageRatio(from text: String) -> String? {
        let patterns = ["16:9", "9:16", "4:3", "3:4", "1:1", "21:9"]
        return patterns.first(where: { text.localizedCaseInsensitiveContains($0) })
    }

    private nonisolated func extractResolution(from lowercasedText: String) -> String? {
        if lowercasedText.contains("4k") {
            return "4K"
        }
        if lowercasedText.contains("2k") {
            return "2K"
        }
        if lowercasedText.contains("1080p") {
            return "1080P"
        }
        if lowercasedText.contains("720p") {
            return "720P"
        }
        return nil
    }

    private nonisolated func extractExplicitDirectory(from text: String) -> String? {
        let nsText = text as NSString
        let regex = try? NSRegularExpression(pattern: #"/[^\s\"\n，。；、,]+"#)
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex?.firstMatch(in: text, range: range) else { return nil }
        let path = nsText.substring(with: match.range)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。；、,."))

        let directoryHints = ["保存到", "放到", "导出到", "写到", "输出到", "放在"]
        guard directoryHints.contains(where: { text.contains($0) }) else { return nil }
        return path
    }

    private nonisolated func parseIntentContext(from text: String) -> ParsedIntentContext {
        let lines = text.components(separatedBy: .newlines)
        var context = ParsedIntentContext()

        for line in lines {
            if let value = value(in: line, prefix: "摘要：") {
                context.summary = value
            } else if let value = value(in: line, prefix: "优先目标文件：") {
                context.targetPath = value
            } else if let value = value(in: line, prefix: "优先参考附件：") {
                context.referencedAttachmentID = value
            } else if let value = value(in: line, prefix: "建议参数：") {
                context.plannedArguments = parseArguments(from: value)
            } else if let value = value(in: line, prefix: "建议澄清问题：") {
                context.clarificationQuestion = value
            } else if let value = value(in: line, prefix: "建议执行前确认：") {
                context.writeConfirmationQuestion = value
            }
        }

        return context
    }

    private nonisolated func permissionModeLabel(for mode: FilePermissionMode) -> String {
        switch mode {
        case .sandbox:
            return "沙盒模式"
        case .open:
            return "开放模式"
        }
    }

    private nonisolated func parseArguments(from raw: String) -> [String: String] {
        var arguments: [String: String] = [:]
        for pair in raw.components(separatedBy: ", ") {
            let parts = pair.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            arguments[key] = value
        }
        return arguments
    }

    private nonisolated func value(in line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private nonisolated func normalize(_ items: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
            if result.count >= limit { break }
        }

        return result
    }
}

private struct ParsedIntentContext: Sendable {
    var summary: String?
    var targetPath: String?
    var referencedAttachmentID: String?
    var plannedArguments: [String: String] = [:]
    var clarificationQuestion: String?
    var writeConfirmationQuestion: String?

    nonisolated init(
        summary: String? = nil,
        targetPath: String? = nil,
        referencedAttachmentID: String? = nil,
        plannedArguments: [String: String] = [:],
        clarificationQuestion: String? = nil,
        writeConfirmationQuestion: String? = nil
    ) {
        self.summary = summary
        self.targetPath = targetPath
        self.referencedAttachmentID = referencedAttachmentID
        self.plannedArguments = plannedArguments
        self.clarificationQuestion = clarificationQuestion
        self.writeConfirmationQuestion = writeConfirmationQuestion
    }
}

private struct TaskSegmentBoundary: Sendable {
    let startDate: Date?
    let reason: String?
}

private struct TimelineEvent {
    let timestamp: Date
    let text: String
}

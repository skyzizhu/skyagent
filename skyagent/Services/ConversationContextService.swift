import Foundation

final class ConversationContextService {
    static let shared = ConversationContextService()

    private let attachmentStore: UploadedAttachmentStore

    init(attachmentStore: UploadedAttachmentStore = .shared) {
        self.attachmentStore = attachmentStore
    }

    func buildState(for conversation: Conversation, fallbackSandboxDir: String) -> ConversationContextState {
        let latestIntent = latestIntentContext(in: conversation)
        let scopeStartDate = contextScopeStartDate(in: conversation)
        return ConversationContextState(
            taskSummary: buildTaskSummary(conversation: conversation, intent: latestIntent),
            activeTargets: normalize(buildTargets(conversation: conversation, intent: latestIntent, fallbackSandboxDir: fallbackSandboxDir, scopeStartDate: scopeStartDate), limit: 5),
            activeConstraints: normalize(buildConstraints(conversation: conversation, intent: latestIntent, fallbackSandboxDir: fallbackSandboxDir), limit: 10),
            activeSkillNames: normalize(SkillManager.shared.skills(withIDs: conversation.activatedSkillIDs).map(\.name), limit: 4),
            recentResults: normalize(buildRecentResults(conversation: conversation, scopeStartDate: scopeStartDate), limit: 4),
            openQuestions: normalize(buildOpenQuestions(intent: latestIntent), limit: 2),
            updatedAt: Date()
        )
    }

    private func buildTaskSummary(conversation: Conversation, intent: ParsedIntentContext?) -> String {
        if let summary = intent?.summary, !summary.isEmpty {
            return summary
        }
        guard let lastUser = conversation.messages.reversed().first(where: { $0.role == .user })?.content else {
            return ""
        }
        return String(
            lastUser
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(120)
        )
    }

    private func buildTargets(
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

    private func buildConstraints(
        conversation: Conversation,
        intent: ParsedIntentContext?,
        fallbackSandboxDir: String
    ) -> [String] {
        var constraints: [String] = []
        let effectiveSandboxDir = conversation.sandboxDir.isEmpty ? fallbackSandboxDir : conversation.sandboxDir

        constraints.append("权限模式：\(conversation.filePermissionMode.displayName)")
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

        constraints.append(contentsOf: extractPersistentConstraints(from: conversation))

        return constraints
    }

    private func buildRecentResults(conversation: Conversation, scopeStartDate: Date?) -> [String] {
        conversation.recentOperations
            .filter { scopeStartDate == nil || $0.createdAt >= scopeStartDate! }
            .prefix(3)
            .map { operation in
            let summary = operation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? operation.title : "\(operation.title)：\(summary)"
        }
    }

    private func buildOpenQuestions(intent: ParsedIntentContext?) -> [String] {
        var questions: [String] = []
        if let clarification = intent?.clarificationQuestion, !clarification.isEmpty {
            questions.append(clarification)
        }
        if let confirmation = intent?.writeConfirmationQuestion, !confirmation.isEmpty {
            questions.append(confirmation)
        }
        return questions
    }

    private func latestAttachmentID(in conversation: Conversation, scopeStartDate: Date?) -> String? {
        conversation.messages
            .filter { scopeStartDate == nil || $0.timestamp >= scopeStartDate! }
            .reversed()
            .compactMap(\.attachmentID)
            .first
    }

    private func recentOperationTargetPath(in conversation: Conversation, scopeStartDate: Date?) -> String? {
        for operation in conversation.recentOperations where scopeStartDate == nil || operation.createdAt >= scopeStartDate! {
            for line in operation.detailLines {
                if let path = extractAbsolutePath(from: line) {
                    return path
                }
            }
        }
        return nil
    }

    private func extractAbsolutePath(from line: String) -> String? {
        guard let slashIndex = line.firstIndex(of: "/") else { return nil }
        let candidate = String(line[slashIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func latestIntentContext(in conversation: Conversation) -> ParsedIntentContext? {
        guard let content = conversation.messages.reversed().first(where: {
            $0.role == .system &&
            $0.hiddenFromTranscript == true &&
            $0.content.contains("[本地文件意图分析]")
        })?.content else {
            return nil
        }
        return parseIntentContext(from: content)
    }

    private func extractPersistentConstraints(from conversation: Conversation) -> [String] {
        let recentUserMessages = scopedUserMessages(in: conversation)

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

    private func scopedUserMessages(in conversation: Conversation) -> [String] {
        let userMessages = conversation.messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else { return [] }

        if let resetIndex = userMessages.lastIndex(where: { isContextResetCue($0.content) }) {
            return userMessages.suffix(from: resetIndex).suffix(8).map(\.content)
        }

        return userMessages.suffix(8).map(\.content)
    }

    private func contextScopeStartDate(in conversation: Conversation) -> Date? {
        conversation.messages
            .filter { $0.role == .user }
            .last(where: { isContextResetCue($0.content) })?
            .timestamp
    }

    private func isContextResetCue(_ text: String) -> Bool {
        let cues = [
            "换一个任务", "换个任务", "重新开始", "重新来", "换一个文件", "换个文件",
            "先不看这个", "先不管这个", "忽略前面", "不看前面的", "另一个任务", "新的任务"
        ]
        return cues.contains(where: { text.localizedCaseInsensitiveContains($0) })
    }

    private func extractImageRatio(from text: String) -> String? {
        let patterns = ["16:9", "9:16", "4:3", "3:4", "1:1", "21:9"]
        return patterns.first(where: { text.localizedCaseInsensitiveContains($0) })
    }

    private func extractResolution(from lowercasedText: String) -> String? {
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

    private func extractExplicitDirectory(from text: String) -> String? {
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

    private func parseIntentContext(from text: String) -> ParsedIntentContext {
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

    private func parseArguments(from raw: String) -> [String: String] {
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

    private func value(in line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func normalize(_ items: [String], limit: Int) -> [String] {
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

private struct ParsedIntentContext {
    var summary: String?
    var targetPath: String?
    var referencedAttachmentID: String?
    var plannedArguments: [String: String] = [:]
    var clarificationQuestion: String?
    var writeConfirmationQuestion: String?
}

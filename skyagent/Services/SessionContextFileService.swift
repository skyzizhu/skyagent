import Foundation

final class SessionContextFileService {
    static let shared = SessionContextFileService()

    private let queue = DispatchQueue(label: "SkyAgent.SessionContextFileService", qos: .utility)

    func persist(conversation: Conversation, fallbackSandboxDir: String) {
        let snapshot = conversation
        queue.async {
            AppStoragePaths.prepareDataDirectories()
            let directory = AppStoragePaths.sessionContextDirectory(for: snapshot.id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = AppStoragePaths.sessionContextFile(for: snapshot.id)
            let markdown = Self.renderMarkdown(conversation: snapshot, fallbackSandboxDir: fallbackSandboxDir)
            try? markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func remove(conversationID: UUID) {
        queue.async {
            let directory = AppStoragePaths.sessionContextDirectory(for: conversationID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated private static func renderMarkdown(conversation: Conversation, fallbackSandboxDir: String) -> String {
        let contextState = conversation.contextState
        let effectiveSandboxDir = conversation.sandboxDir.isEmpty ? fallbackSandboxDir : conversation.sandboxDir

        var lines: [String] = [
            "# Session Context",
            "",
            "- 会话 ID：\(conversation.id.uuidString)",
            "- 标题：\(conversation.title)",
            "- 权限模式：\(permissionLabel(for: conversation.filePermissionMode))",
            "- 工作目录：\(effectiveSandboxDir)",
            "- 更新时间：\(isoTimestamp(conversation.contextState.updatedAt))",
            ""
        ]

        lines += makeSection("当前任务", items: contextState.taskSummary.isEmpty ? [] : [contextState.taskSummary])
        lines += makeSection("当前目标", items: contextState.activeTargets)
        lines += makeSection("当前约束", items: contextState.activeConstraints)
        lines += makeSection("当前技能", items: contextState.activeSkillNames)
        lines += makeSection("最近结果", items: contextState.recentResults)
        lines += makeSection("任务时间线", items: contextState.recentTimeline)
        lines += makeSection("待确认", items: contextState.openQuestions)
        lines += makeSection("下一步", items: singleItem(contextState.nextLikelyStep))
        lines += makeSection("当前阻塞", items: singleItem(contextState.blockedBy))
        lines += makeSection("用户决策", items: singleItem(contextState.userDecision))

        if let segmentStartedAt = contextState.segmentStartedAt {
            lines += [
                "## 任务分段",
                "",
                "- 开始时间：\(isoTimestamp(segmentStartedAt))",
                "- 原因：\(contextState.segmentReason ?? "unknown")",
                ""
            ]
        }

        if contextState.isEmpty {
            lines += [
                "## 说明",
                "",
                "- 当前会话尚未形成稳定上下文，后续会随着对话和操作自动更新。",
                ""
            ]
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    nonisolated private static func makeSection(_ title: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        return ["## \(title)", ""] + items.map { "- \($0)" } + [""]
    }

    nonisolated private static func singleItem(_ value: String?) -> [String] {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [value]
    }

    nonisolated private static func permissionLabel(for mode: FilePermissionMode) -> String {
        switch mode {
        case .sandbox:
            return "沙盒模式"
        case .open:
            return "开放模式"
        }
    }

    nonisolated private static func isoTimestamp(_ date: Date) -> String {
        date.ISO8601Format()
    }
}

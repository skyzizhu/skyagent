import Foundation

struct ConversationContextState: Codable, Equatable {
    var taskSummary: String
    var activeTargets: [String]
    var activeConstraints: [String]
    var activeSkillNames: [String]
    var recentResults: [String]
    var openQuestions: [String]
    var updatedAt: Date

    static let empty = ConversationContextState(
        taskSummary: "",
        activeTargets: [],
        activeConstraints: [],
        activeSkillNames: [],
        recentResults: [],
        openQuestions: [],
        updatedAt: Date()
    )

    var isEmpty: Bool {
        taskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        activeTargets.isEmpty &&
        activeConstraints.isEmpty &&
        activeSkillNames.isEmpty &&
        recentResults.isEmpty &&
        openQuestions.isEmpty
    }

    func systemContext() -> String {
        guard !isEmpty else { return "" }

        var lines: [String] = ["[当前会话状态]"]

        if !taskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("当前任务：\(taskSummary)")
        }
        if !activeTargets.isEmpty {
            lines.append("当前目标：")
            lines.append(contentsOf: activeTargets.map { "- \($0)" })
        }
        if !activeConstraints.isEmpty {
            lines.append("当前约束：")
            lines.append(contentsOf: activeConstraints.map { "- \($0)" })
        }
        if !activeSkillNames.isEmpty {
            lines.append("当前技能：")
            lines.append(contentsOf: activeSkillNames.map { "- \($0)" })
        }
        if !recentResults.isEmpty {
            lines.append("最近结果：")
            lines.append(contentsOf: recentResults.map { "- \($0)" })
        }
        if !openQuestions.isEmpty {
            lines.append("待确认：")
            lines.append(contentsOf: openQuestions.map { "- \($0)" })
        }

        lines.append("[/当前会话状态]")
        return lines.joined(separator: "\n")
    }
}

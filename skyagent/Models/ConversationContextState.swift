import Foundation

struct ConversationContextState: Codable, Equatable {
    var taskSummary: String
    var activeTargets: [String]
    var activeConstraints: [String]
    var activeSkillNames: [String]
    var recentResults: [String]
    var recentTimeline: [String]
    var openQuestions: [String]
    var segmentStartedAt: Date?
    var segmentReason: String?
    var updatedAt: Date

    static let empty = ConversationContextState(
        taskSummary: "",
        activeTargets: [],
        activeConstraints: [],
        activeSkillNames: [],
        recentResults: [],
        recentTimeline: [],
        openQuestions: [],
        segmentStartedAt: nil,
        segmentReason: nil,
        updatedAt: Date()
    )

    var isEmpty: Bool {
        taskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        activeTargets.isEmpty &&
        activeConstraints.isEmpty &&
        activeSkillNames.isEmpty &&
        recentResults.isEmpty &&
        recentTimeline.isEmpty &&
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
        if !recentTimeline.isEmpty {
            lines.append("任务时间线：")
            lines.append(contentsOf: recentTimeline.map { "- \($0)" })
        }
        if !openQuestions.isEmpty {
            lines.append("待确认：")
            lines.append(contentsOf: openQuestions.map { "- \($0)" })
        }

        lines.append("[/当前会话状态]")
        return lines.joined(separator: "\n")
    }

    nonisolated init(
        taskSummary: String,
        activeTargets: [String],
        activeConstraints: [String],
        activeSkillNames: [String],
        recentResults: [String],
        recentTimeline: [String],
        openQuestions: [String],
        segmentStartedAt: Date?,
        segmentReason: String?,
        updatedAt: Date
    ) {
        self.taskSummary = taskSummary
        self.activeTargets = activeTargets
        self.activeConstraints = activeConstraints
        self.activeSkillNames = activeSkillNames
        self.recentResults = recentResults
        self.recentTimeline = recentTimeline
        self.openQuestions = openQuestions
        self.segmentStartedAt = segmentStartedAt
        self.segmentReason = segmentReason
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskSummary = try container.decodeIfPresent(String.self, forKey: .taskSummary) ?? ""
        activeTargets = try container.decodeIfPresent([String].self, forKey: .activeTargets) ?? []
        activeConstraints = try container.decodeIfPresent([String].self, forKey: .activeConstraints) ?? []
        activeSkillNames = try container.decodeIfPresent([String].self, forKey: .activeSkillNames) ?? []
        recentResults = try container.decodeIfPresent([String].self, forKey: .recentResults) ?? []
        recentTimeline = try container.decodeIfPresent([String].self, forKey: .recentTimeline) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        segmentStartedAt = try container.decodeIfPresent(Date.self, forKey: .segmentStartedAt)
        segmentReason = try container.decodeIfPresent(String.self, forKey: .segmentReason)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case taskSummary
        case activeTargets
        case activeConstraints
        case activeSkillNames
        case recentResults
        case recentTimeline
        case openQuestions
        case segmentStartedAt
        case segmentReason
        case updatedAt
    }
}

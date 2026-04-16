import Foundation

struct ConversationContextState: Codable, Equatable, Sendable {
    var taskSummary: String
    var activeTargets: [String]
    var activeConstraints: [String]
    var activeSkillNames: [String]
    var recentResults: [String]
    var recentTimeline: [String]
    var openQuestions: [String]
    var nextLikelyStep: String?
    var blockedBy: String?
    var userDecision: String?
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
        nextLikelyStep: nil,
        blockedBy: nil,
        userDecision: nil,
        segmentStartedAt: nil,
        segmentReason: nil,
        updatedAt: Date()
    )

    nonisolated var isEmpty: Bool {
        taskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        activeTargets.isEmpty &&
        activeConstraints.isEmpty &&
        activeSkillNames.isEmpty &&
        recentResults.isEmpty &&
        recentTimeline.isEmpty &&
        openQuestions.isEmpty &&
        (nextLikelyStep?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
        (blockedBy?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
        (userDecision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    nonisolated func systemContext() -> String {
        guard !isEmpty else { return "" }

        var lines: [String] = ["[当前会话状态]"]
        let compactTargets = prioritized(activeTargets, limit: 3)
        let compactConstraints = prioritized(activeConstraints, limit: 4)
        let compactResults = prioritized(recentResults, limit: 2)
        let compactOpenQuestions = prioritized(openQuestions, limit: 1)
        let compactSkills = prioritized(activeSkillNames, limit: 2)
        let normalizedNextStep = compactLine(nextLikelyStep, limit: 90)
        let normalizedBlockedBy = compactLine(blockedBy, limit: 90)
        let normalizedUserDecision = compactLine(userDecision, limit: 80)

        if !taskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("当前任务：\(String(taskSummary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))")
        }
        if !compactTargets.isEmpty {
            lines.append("当前目标：")
            lines.append(contentsOf: compactTargets.map { "- \($0)" })
        }
        if !compactConstraints.isEmpty {
            lines.append("当前约束：")
            lines.append(contentsOf: compactConstraints.map { "- \($0)" })
        }
        if !compactResults.isEmpty {
            lines.append("最近结果：")
            lines.append(contentsOf: compactResults.map { "- \($0)" })
        }
        if let normalizedNextStep {
            lines.append("下一步：\(normalizedNextStep)")
        }
        if let normalizedBlockedBy {
            lines.append("当前阻塞：\(normalizedBlockedBy)")
        }
        if !compactOpenQuestions.isEmpty {
            lines.append("待确认：")
            lines.append(contentsOf: compactOpenQuestions.map { "- \($0)" })
        }
        if let normalizedUserDecision {
            lines.append("用户决策：\(normalizedUserDecision)")
        }
        if !compactSkills.isEmpty {
            lines.append("当前技能：\(compactSkills.joined(separator: "、"))")
        }

        lines.append("[/当前会话状态]")
        return lines.joined(separator: "\n")
    }

    nonisolated private func prioritized(_ values: [String], limit: Int) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { String($0.prefix(90)) }
    }

    nonisolated private func compactLine(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    nonisolated init(
        taskSummary: String,
        activeTargets: [String],
        activeConstraints: [String],
        activeSkillNames: [String],
        recentResults: [String],
        recentTimeline: [String],
        openQuestions: [String],
        nextLikelyStep: String?,
        blockedBy: String?,
        userDecision: String?,
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
        self.nextLikelyStep = nextLikelyStep
        self.blockedBy = blockedBy
        self.userDecision = userDecision
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
        nextLikelyStep = try container.decodeIfPresent(String.self, forKey: .nextLikelyStep)
        blockedBy = try container.decodeIfPresent(String.self, forKey: .blockedBy)
        userDecision = try container.decodeIfPresent(String.self, forKey: .userDecision)
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
        case nextLikelyStep
        case blockedBy
        case userDecision
        case segmentStartedAt
        case segmentReason
        case updatedAt
    }
}

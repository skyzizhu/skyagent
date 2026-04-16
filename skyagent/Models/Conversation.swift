import Foundation

// MARK: - 文件权限模式

enum FilePermissionMode: String, Codable, CaseIterable, Sendable {
    case sandbox = "sandbox"
    case open = "open"

    var displayName: String {
        switch self {
        case .sandbox: return L10n.tr("permission.sandbox")
        case .open: return L10n.tr("permission.open")
        }
    }

    var description: String {
        switch self {
        case .sandbox: return L10n.tr("permission.sandbox.description")
        case .open: return L10n.tr("permission.open.description")
        }
    }

    var icon: String {
        switch self {
        case .sandbox: return "lock.shield"
        case .open: return "lock.open"
        }
    }
}

struct Conversation: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var isFavorite: Bool
    var messages: [Message]
    var createdAt: Date
    var lastActiveAt: Date
    /// 文件权限模式
    var filePermissionMode: FilePermissionMode
    /// 当前会话工作目录（两种模式都有效）
    var sandboxDir: String
    var activatedSkillIDs: [String]
    var recentOperations: [FileOperationRecord]
    var contextState: ConversationContextState
    var knowledgeLibraryIDs: [String]

    init(title: String = L10n.tr("conversation.new")) {
        self.id = UUID()
        self.title = title
        self.isFavorite = false
        self.messages = []
        self.createdAt = Date()
        self.lastActiveAt = Date()
        self.filePermissionMode = .sandbox
        self.sandboxDir = ""
        self.activatedSkillIDs = []
        self.recentOperations = []
        self.contextState = .empty
        self.knowledgeLibraryIDs = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        isFavorite = (try? c.decode(Bool.self, forKey: .isFavorite)) ?? false
        messages = try c.decode([Message].self, forKey: .messages)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastActiveAt = (try? c.decode(Date.self, forKey: .lastActiveAt)) ?? createdAt
        filePermissionMode = (try? c.decode(FilePermissionMode.self, forKey: .filePermissionMode)) ?? .sandbox
        sandboxDir = (try? c.decode(String.self, forKey: .sandboxDir)) ?? ""
        activatedSkillIDs = (try? c.decode([String].self, forKey: .activatedSkillIDs)) ?? []
        recentOperations = (try? c.decode([FileOperationRecord].self, forKey: .recentOperations)) ?? []
        contextState = (try? c.decode(ConversationContextState.self, forKey: .contextState)) ?? .empty
        knowledgeLibraryIDs = (try? c.decode([String].self, forKey: .knowledgeLibraryIDs)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, isFavorite, messages, createdAt, lastActiveAt, filePermissionMode, sandboxDir, activatedSkillIDs, recentOperations, contextState, knowledgeLibraryIDs
    }

    var memoryRetrievalQuery: String {
        var parts: [String] = []

        if !contextState.taskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(contextState.taskSummary)
        }

        if let lastUserMessage = messages.reversed().first(where: { $0.role == .user })?.content {
            let normalized = lastUserMessage
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                parts.append(String(normalized.prefix(160)))
            }
        }

        if !contextState.activeTargets.isEmpty {
            let filteredTargets = contextState.activeTargets.filter { target in
                let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                return !trimmed.hasPrefix("当前工作目录：")
                    && !trimmed.hasPrefix("工作目录：")
                    && !trimmed.hasPrefix("目标目录：")
                    && !trimmed.hasPrefix("目标路径：")
            }
            if !filteredTargets.isEmpty {
                parts.append(filteredTargets.prefix(3).joined(separator: "；"))
            }
        }

        if !contextState.activeConstraints.isEmpty {
            let filteredConstraints = contextState.activeConstraints.filter { constraint in
                let trimmed = constraint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                return !trimmed.hasPrefix("工作目录：")
                    && !trimmed.hasPrefix("目标目录：")
            }
            if !filteredConstraints.isEmpty {
                parts.append(filteredConstraints.prefix(3).joined(separator: "；"))
            }
        }

        if !contextState.recentTimeline.isEmpty {
            parts.append(contextState.recentTimeline.prefix(3).joined(separator: "；"))
        }

        return parts.joined(separator: "\n")
    }
}

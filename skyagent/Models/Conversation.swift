import Foundation

// MARK: - 文件权限模式

enum FilePermissionMode: String, Codable, CaseIterable {
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

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
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

    init(title: String = L10n.tr("conversation.new")) {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.lastActiveAt = Date()
        self.filePermissionMode = .sandbox
        self.sandboxDir = ""
        self.activatedSkillIDs = []
        self.recentOperations = []
        self.contextState = .empty
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([Message].self, forKey: .messages)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastActiveAt = (try? c.decode(Date.self, forKey: .lastActiveAt)) ?? createdAt
        filePermissionMode = (try? c.decode(FilePermissionMode.self, forKey: .filePermissionMode)) ?? .sandbox
        sandboxDir = (try? c.decode(String.self, forKey: .sandboxDir)) ?? ""
        activatedSkillIDs = (try? c.decode([String].self, forKey: .activatedSkillIDs)) ?? []
        recentOperations = (try? c.decode([FileOperationRecord].self, forKey: .recentOperations)) ?? []
        contextState = (try? c.decode(ConversationContextState.self, forKey: .contextState)) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, lastActiveAt, filePermissionMode, sandboxDir, activatedSkillIDs, recentOperations, contextState
    }
}

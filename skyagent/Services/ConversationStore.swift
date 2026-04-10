import Foundation
import Combine

@MainActor
class ConversationStore: ObservableObject {
    private static let staleAttachmentLifetime: TimeInterval = 7 * 24 * 60 * 60

    @Published var conversations: [Conversation] = []
    @Published var currentConversationId: UUID?

    @Published var settings: AppSettings

    private let attachmentStore: UploadedAttachmentStore
    private let saveDirURL: URL
    private let persistenceQueue = DispatchQueue(label: "SkyAgent.ConversationPersistence", qos: .utility)
    private let contextRefreshQueue = DispatchQueue(label: "SkyAgent.ContextRefresh", qos: .utility)
    private let attachmentCleanupQueue = DispatchQueue(label: "SkyAgent.AttachmentCleanup", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var contextRefreshWorkItems: [UUID: DispatchWorkItem] = [:]
    private var pendingAttachmentCleanupWorkItem: DispatchWorkItem?

    var currentConversation: Conversation? {
        conversations.first { $0.id == currentConversationId }
    }

    init(
        settings: AppSettings? = nil,
        attachmentStore: UploadedAttachmentStore? = nil,
        saveDir: URL? = nil
    ) {
        AppStoragePaths.migrateLegacyDataIfNeeded()
        self.settings = settings ?? AppSettings.load()
        self.attachmentStore = attachmentStore ?? UploadedAttachmentStore.shared
        self.saveDirURL = saveDir ?? AppStoragePaths.dataDir
        try? FileManager.default.createDirectory(at: self.saveDirURL, withIntermediateDirectories: true)
        loadConversations()
        cleanupStaleAttachments()
        if conversations.isEmpty { newConversation() }
        currentConversationId = conversations.first?.id
    }

    // MARK: - Conversation CRUD

    @discardableResult
    func newConversation() -> Conversation {
        let conv = Conversation(title: L10n.tr("conversation.new"))
        conversations.insert(conv, at: 0)
        refreshConversationContext(conv.id, immediately: true)
        currentConversationId = conv.id
        saveConversations()
        return conv
    }

    func selectConversation(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        currentConversationId = id
        let fallbackSandboxDir = settings.ensureSandboxDir()
        let snapshot = conversation
        let workItem = DispatchWorkItem { [weak self] in
            let state = ConversationContextService.shared.buildState(
                for: snapshot,
                fallbackSandboxDir: fallbackSandboxDir
            )
            DispatchQueue.main.async {
                guard let self,
                      self.currentConversationId == id,
                      let idx = self.conversations.firstIndex(where: { $0.id == id }) else { return }
                self.conversations[idx].contextState = state
            }
        }
        contextRefreshWorkItems[id]?.cancel()
        contextRefreshWorkItems[id] = workItem
        contextRefreshQueue.async(execute: workItem)
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentConversationId == id {
            currentConversationId = conversations.first?.id
        }
        if conversations.isEmpty { newConversation() }
        saveConversations()
        cleanupUnusedAttachments(removeAllOrphans: true)
    }

    // MARK: - Messages

    func appendMessage(_ msg: Message, to convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        conversations[idx].messages.append(msg)
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        scheduleSaveConversations()
    }

    func deleteMessage(_ msgId: UUID) {
        guard let convIdx = conversations.firstIndex(where: { conv in
            conv.messages.contains { $0.id == msgId }
        }) else { return }
        guard let msgIdx = conversations[convIdx].messages.firstIndex(where: { $0.id == msgId }) else { return }
        conversations[convIdx].messages.remove(at: msgIdx)
        if conversations[convIdx].messages.indices.contains(msgIdx),
           conversations[convIdx].messages[msgIdx].hiddenFromTranscript == true,
           conversations[convIdx].messages[msgIdx].role == .system {
            conversations[convIdx].messages.remove(at: msgIdx)
        }
        conversations[convIdx].lastActiveAt = Date()
        refreshConversationContext(conversations[convIdx].id)
        saveConversations()
        cleanupUnusedAttachments(removeAllOrphans: true)
    }

    func clearMessages(_ convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        conversations[idx].messages.removeAll()
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        saveConversations()
        cleanupUnusedAttachments(removeAllOrphans: true)
    }

    func updateConversationTitle(_ id: UUID, title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title
        refreshConversationContext(id)
        saveConversations()
    }

    func toggleFavoriteConversation(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].isFavorite.toggle()
        conversations[idx].lastActiveAt = Date()
        saveConversations()
    }

    // MARK: - 权限模式

    func togglePermissionMode(_ convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        let current = conversations[idx].filePermissionMode
        conversations[idx].filePermissionMode = current == .sandbox ? .open : .sandbox
        refreshConversationContext(convId)
        saveConversations()
    }

    func updateConversationSandboxDir(_ convId: UUID, dir: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        conversations[idx].sandboxDir = dir
        refreshConversationContext(convId)
        saveConversations()
    }

    func setConversationPermission(_ convId: UUID, mode: FilePermissionMode, sandboxDir: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        conversations[idx].filePermissionMode = mode
        conversations[idx].sandboxDir = sandboxDir
        refreshConversationContext(convId)
        saveConversations()
    }

    func markSkillActivated(_ skillID: String, in convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        guard !conversations[idx].activatedSkillIDs.contains(skillID) else { return }
        conversations[idx].activatedSkillIDs.append(skillID)
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        saveConversations()
    }

    func updateLastMessageContent(_ convId: UUID, appending delta: String, refreshContext: Bool = false) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }),
              !conversations[idx].messages.isEmpty else { return }
        conversations[idx].messages[conversations[idx].messages.count - 1].content += delta
        conversations[idx].lastActiveAt = Date()
        if refreshContext {
            refreshConversationContext(convId)
        }
        scheduleSaveConversations()
    }

    func updateLastAssistantToolCalls(_ convId: UUID, toolCalls: [ToolCallRecord]) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }),
              let lastAssistantIdx = conversations[idx].messages.lastIndex(where: { $0.role == .assistant }) else { return }
        conversations[idx].messages[lastAssistantIdx].toolCalls = toolCalls
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        scheduleSaveConversations()
    }

    func addOperation(_ operation: FileOperationRecord, to convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        conversations[idx].recentOperations.insert(operation, at: 0)
        if conversations[idx].recentOperations.count > 20 {
            conversations[idx].recentOperations = Array(conversations[idx].recentOperations.prefix(20))
        }
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        saveConversations()
    }

    func markOperationUndone(_ operationId: String, in convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }),
              let opIdx = conversations[idx].recentOperations.firstIndex(where: { $0.id == operationId }) else { return }
        conversations[idx].recentOperations[opIdx].isUndone = true
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        saveConversations()
    }

    func operation(_ operationId: String, in convId: UUID) -> FileOperationRecord? {
        conversations.first(where: { $0.id == convId })?.recentOperations.first(where: { $0.id == operationId })
    }

    func removeTrailingEmptyAssistantMessage(_ convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }),
              let last = conversations[idx].messages.last,
              last.role == .assistant,
              last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        conversations[idx].messages.removeLast()
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        scheduleSaveConversations()
    }

    func removeLastMessage(_ convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }),
              !conversations[idx].messages.isEmpty else { return }
        conversations[idx].messages.removeLast()
        conversations[idx].lastActiveAt = Date()
        refreshConversationContext(convId)
        scheduleSaveConversations()
    }

    func removeMessage(at index: Int, in convId: UUID) {
        guard let convIdx = conversations.firstIndex(where: { $0.id == convId }),
              conversations[convIdx].messages.indices.contains(index) else { return }
        conversations[convIdx].messages.remove(at: index)
        conversations[convIdx].lastActiveAt = Date()
        refreshConversationContext(convId)
        saveConversations()
        cleanupUnusedAttachments(removeAllOrphans: true)
    }

    func removeLastAssistantMessage(in convId: UUID) {
        guard let convIdx = conversations.firstIndex(where: { $0.id == convId }),
              let msgIdx = conversations[convIdx].messages.lastIndex(where: { $0.role == .assistant }) else { return }
        conversations[convIdx].messages.remove(at: msgIdx)
        conversations[convIdx].lastActiveAt = Date()
        refreshConversationContext(convId)
        saveConversations()
        cleanupUnusedAttachments(removeAllOrphans: true)
    }

    func userMessageCount(_ convId: UUID) -> Int {
        conversations.first(where: { $0.id == convId })?.messages.filter { $0.role == .user }.count ?? 0
    }

    // MARK: - LLM Messages

    func messagesForLLM(_ convId: UUID) -> [LLMService.ChatMessage] {
        conversations.first(where: { $0.id == convId })?.messages.map { message in
            LLMService.ChatMessage(
                role: message.role.rawValue,
                content: message.content,
                imageDataURL: message.imageDataURL,
                toolCallId: message.toolExecution?.id,
                toolCalls: message.toolCalls
            )
        } ?? []
    }

    // MARK: - 导出

    func exportConversation(_ convId: UUID) -> String? {
        guard let conv = conversations.first(where: { $0.id == convId }) else { return nil }
        var lines: [String] = ["# \(conv.title)", ""]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        for msg in conv.messages {
            if msg.hiddenFromTranscript == true {
                continue
            }
            let time = dateFormatter.string(from: msg.timestamp)
            let role: String
            switch msg.role {
            case .user: role = "👤 用户"
            case .assistant: role = "🤖 助手"
            case .system: role = "⚙️ 系统"
            case .tool: role = "🔧 工具"
            @unknown default: role = "未知"
            }
            lines.append("### \(role) (\(time))")
            lines.append("")
            if let toolExecution = msg.toolExecution {
                lines.append("工具：`\(toolExecution.name)`")
                lines.append("")
            }
            lines.append(msg.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 消息编辑后重发

    /// 编辑用户消息，删除该消息之后的所有消息
    func editMessageAndTruncate(_ msgId: UUID, newText: String, in convId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        guard let msgIdx = conversations[idx].messages.firstIndex(where: { $0.id == msgId }) else { return }
        conversations[idx].messages[msgIdx].content = newText
        // 删除该消息之后的所有消息
        conversations[idx].messages.removeSubrange((msgIdx + 1)...)
        refreshConversationContext(convId)
        saveConversations()
        cleanupUnusedAttachments(removeAllOrphans: true)
    }

    // MARK: - Persistence

    func saveConversations() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        let url = saveDir.appendingPathComponent("conversations.json")
        let snapshot = conversations
        persistenceQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadConversations() {
        let url = saveDir.appendingPathComponent("conversations.json")
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = loaded
        currentConversationId = conversations.first?.id
        if let currentConversationId {
            refreshConversationContext(currentConversationId, immediately: true)
        }
    }

    private var saveDir: URL {
        saveDirURL
    }

    private func cleanupStaleAttachments() {
        scheduleAttachmentCleanup(removeAllOrphans: false, delay: 0)
    }

    private func cleanupUnusedAttachments(removeAllOrphans: Bool) {
        scheduleAttachmentCleanup(removeAllOrphans: removeAllOrphans, delay: 0.12)
    }

    private func scheduleAttachmentCleanup(removeAllOrphans: Bool, delay: TimeInterval) {
        let retainedIDs = referencedAttachmentIDs()
        let age = removeAllOrphans ? nil : Self.staleAttachmentLifetime
        pendingAttachmentCleanupWorkItem?.cancel()

        let workItem = DispatchWorkItem { [attachmentStore] in
            _ = attachmentStore.cleanupOrphanedDocuments(
                retaining: retainedIDs,
                olderThan: age
            )
        }
        pendingAttachmentCleanupWorkItem = workItem

        if delay <= 0 {
            attachmentCleanupQueue.async(execute: workItem)
        } else {
            attachmentCleanupQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func referencedAttachmentIDs() -> Set<String> {
        Set(conversations.flatMap { conversation in
            conversation.messages.compactMap(\.attachmentID)
        })
    }

    func refreshConversationContext(_ convId: UUID, immediately: Bool = false) {
        guard let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }

        let snapshot = conversations[idx]
        let expectedMessageCount = snapshot.messages.count
        let expectedLastMessageID = snapshot.messages.last?.id
        let fallbackSandboxDir = settings.ensureSandboxDir()

        contextRefreshWorkItems[convId]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            let state = ConversationContextService.shared.buildState(
                for: snapshot,
                fallbackSandboxDir: fallbackSandboxDir
            )

            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.contextRefreshWorkItems[convId] = nil }
                guard let currentIndex = self.conversations.firstIndex(where: { $0.id == convId }) else { return }
                guard self.conversations[currentIndex].messages.count == expectedMessageCount,
                      self.conversations[currentIndex].messages.last?.id == expectedLastMessageID else { return }
                self.conversations[currentIndex].contextState = state
            }
        }
        contextRefreshWorkItems[convId] = workItem
        if immediately {
            contextRefreshQueue.async(execute: workItem)
        } else {
            contextRefreshQueue.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }
    }

    private func scheduleSaveConversations(delay: TimeInterval = 0.35) {
        pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.saveConversations()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    deinit {
        pendingAttachmentCleanupWorkItem?.cancel()
        contextRefreshWorkItems.values.forEach { $0.cancel() }
    }
}

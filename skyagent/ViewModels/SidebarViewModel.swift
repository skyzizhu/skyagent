import Foundation
import Combine

@MainActor
class SidebarViewModel: ObservableObject {
    struct ConversationRowSnapshot: Identifiable {
        let conversation: Conversation
        let previewText: String
        let timeText: String

        var id: UUID { conversation.id }
    }

    enum ConversationFilter: String, CaseIterable {
        case all
        case favorites
    }

    let store: ConversationStore
    let skillManager: SkillManager

    @Published var searchText = ""
    @Published var showNewConversationSheet = false
    @Published var selectedFilter: ConversationFilter = .all
    @Published private(set) var filteredConversations: [Conversation] = []
    @Published private(set) var filteredConversationRows: [ConversationRowSnapshot] = []

    private var cancellables = Set<AnyCancellable>()
    private var conversationSearchIndex: [UUID: String] = [:]
    private var conversationRowIndex: [UUID: ConversationRowSnapshot] = [:]

    init(store: ConversationStore, skillManager: SkillManager) {
        self.store = store
        self.skillManager = skillManager
        skillManager.reloadSkills()
        bindFiltering()
        rebuildConversationSearchIndex(for: store.conversations)
        recomputeFilteredConversations()
    }

    func newConversation() {
        searchText = ""
        showNewConversationSheet = true
    }

    func createConversation(mode: FilePermissionMode, dir: String) {
        searchText = ""
        let conv = store.newConversation()
        store.setConversationPermission(conv.id, mode: mode, sandboxDir: dir)
        showNewConversationSheet = false
    }

    func selectConversation(_ id: UUID) {
        store.selectConversation(id)
    }

    func deleteConversation(_ id: UUID) {
        store.deleteConversation(id)
    }

    func toggleFavoriteConversation(_ id: UUID) {
        store.toggleFavoriteConversation(id)
    }

    func renameConversation(_ id: UUID, newTitle: String) {
        guard !newTitle.isEmpty else { return }
        store.updateConversationTitle(id, title: newTitle)
    }

    func clearMessages(_ id: UUID) {
        store.clearMessages(id)
    }

    private func bindFiltering() {
        store.$conversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                guard let self else { return }
                self.rebuildConversationSearchIndex(for: conversations)
                self.recomputeFilteredConversations()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            $searchText
                .removeDuplicates()
                .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main),
            $selectedFilter.removeDuplicates()
        )
        .sink { [weak self] _, _ in
            self?.recomputeFilteredConversations()
        }
        .store(in: &cancellables)
    }

    private func recomputeFilteredConversations() {
        let baseConversations: [Conversation]
        switch selectedFilter {
        case .all:
            baseConversations = store.conversations
        case .favorites:
            baseConversations = store.conversations.filter(\.isFavorite)
        }

        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            filteredConversations = baseConversations
            filteredConversationRows = baseConversations.compactMap { conversationRowIndex[$0.id] }
            return
        }

        filteredConversations = baseConversations.filter { conversation in
            if conversation.title.lowercased().contains(needle) {
                return true
            }
            return conversationSearchIndex[conversation.id]?.contains(needle) == true
        }
        filteredConversationRows = filteredConversations.compactMap { conversationRowIndex[$0.id] }
    }

    private func rebuildConversationSearchIndex(for conversations: [Conversation]) {
        conversationSearchIndex = Dictionary(
            uniqueKeysWithValues: conversations.map { conversation in
                let searchableContent = conversation.messages
                    .lazy
                    .filter { !($0.hiddenFromTranscript ?? false) }
                    .map(\.content)
                    .joined(separator: "\n")
                    .lowercased()
                return (conversation.id, searchableContent)
            }
        )

        conversationRowIndex = Dictionary(
            uniqueKeysWithValues: conversations.map { conversation in
                (
                    conversation.id,
                    ConversationRowSnapshot(
                        conversation: conversation,
                        previewText: makePreviewText(for: conversation),
                        timeText: Self.relativeTimeFormatter.localizedString(for: conversation.lastActiveAt, relativeTo: Date())
                    )
                )
            }
        )
    }

    private func makePreviewText(for conversation: Conversation) -> String {
        let lastVisible = conversation.messages.last(where: { $0.isVisibleInTranscript })
            ?? conversation.messages.last(where: { $0.hiddenFromTranscript != true && $0.role != .system })
            ?? conversation.messages.last(where: { $0.role != .system })
        guard let last = lastVisible else { return L10n.tr("conversation.empty") }
        let text = last.content
            .replacingOccurrences(of: "🔧 执行工具: ", with: "🔧 ")
            .replacingOccurrences(of: "📋 结果:", with: "")
            .replacingOccurrences(of: "```", with: "")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .first ?? ""
        return String(text.prefix(50))
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

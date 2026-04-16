import Foundation
import Combine

@MainActor
class SidebarViewModel: ObservableObject {
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

    private var cancellables = Set<AnyCancellable>()
    private var conversationSearchIndex: [UUID: String] = [:]

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
            return
        }

        filteredConversations = baseConversations.filter { conversation in
            if conversation.title.lowercased().contains(needle) {
                return true
            }
            return conversationSearchIndex[conversation.id]?.contains(needle) == true
        }
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
    }
}

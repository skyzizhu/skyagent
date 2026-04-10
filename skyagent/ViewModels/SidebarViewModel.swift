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

    var filteredConversations: [Conversation] {
        let baseConversations: [Conversation]
        switch selectedFilter {
        case .all:
            baseConversations = store.conversations
        case .favorites:
            baseConversations = store.conversations.filter(\.isFavorite)
        }

        if searchText.isEmpty { return baseConversations }
        let q = searchText.lowercased()
        return baseConversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    init(store: ConversationStore, skillManager: SkillManager) {
        self.store = store
        self.skillManager = skillManager
        skillManager.reloadSkills()
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
        store.saveConversations()
    }

    func clearMessages(_ id: UUID) {
        store.clearMessages(id)
    }
}

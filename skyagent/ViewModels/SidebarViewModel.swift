import Foundation
import Combine

@MainActor
class SidebarViewModel: ObservableObject {
    let store: ConversationStore
    let skillManager: SkillManager

    @Published var searchText = ""
    @Published var showNewConversationSheet = false

    var filteredConversations: [Conversation] {
        if searchText.isEmpty { return store.conversations }
        let q = searchText.lowercased()
        return store.conversations.filter {
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

    func renameConversation(_ id: UUID, newTitle: String) {
        guard !newTitle.isEmpty else { return }
        store.updateConversationTitle(id, title: newTitle)
        store.saveConversations()
    }

    func clearMessages() {
        guard let convId = store.currentConversationId else { return }
        store.clearMessages(convId)
    }
}

import SwiftUI
import Combine
import UniformTypeIdentifiers

@main
struct skyagentApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("app.command.new_conversation")) { appState.sidebarVM.newConversation() }
                    .keyboardShortcut("n")
            }
            CommandMenu(L10n.tr("app.command.menu.conversation")) {
                Button(L10n.tr("app.command.clear_current")) { appState.sidebarVM.clearMessages() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button(L10n.tr("app.command.export_current")) {
                    exportCurrentConversation()
                }
                Divider()
                Button(L10n.tr("app.command.toggle_permission")) {
                    if let convId = appState.store.currentConversationId {
                        appState.store.togglePermissionMode(convId)
                    }
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
        Settings {
            SettingsView(viewModel: appState.settingsVM)
        }
    }

    private func exportCurrentConversation() {
        guard let convId = appState.store.currentConversationId,
              let md = appState.store.exportConversation(convId) else { return }
        let panel = NSSavePanel()
        panel.title = L10n.tr("panel.export_conversation.title")
        panel.nameFieldStringValue = L10n.tr("panel.export_conversation.filename")
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let store = ConversationStore()
    let skillManager = SkillManager.shared
    private(set) var sidebarVM: SidebarViewModel!
    private(set) var settingsVM: SettingsViewModel!
    private(set) var chatVM: ChatViewModel!

    init() {
        skillManager.reloadSkills()
        let llm = LLMService(settings: store.settings)
        let orchestrator = AgentOrchestrator(llm: llm)
        self.sidebarVM = SidebarViewModel(store: store, skillManager: skillManager)
        self.settingsVM = SettingsViewModel(store: store, llm: llm, skillManager: skillManager)
        self.chatVM = ChatViewModel(store: store, llm: llm, orchestrator: orchestrator)
    }
}

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
                .preferredColorScheme(appState.preferredColorScheme)
                .environment(\.locale, appState.locale)
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("app.command.new_conversation")) { appState.sidebarVM.newConversation() }
                    .keyboardShortcut("n")
            }
            CommandMenu(L10n.tr("app.command.menu.conversation")) {
                Button(L10n.tr("app.command.clear_current")) {
                    if let convId = appState.store.currentConversationId {
                        appState.sidebarVM.clearMessages(convId)
                    }
                }
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
                .environmentObject(appState)
                .preferredColorScheme(appState.preferredColorScheme)
                .environment(\.locale, appState.locale)
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
    let mcpManager = MCPServerManager.shared
    @Published private(set) var preferredColorScheme: ColorScheme?
    @Published private(set) var locale: Locale
    private(set) var sidebarVM: SidebarViewModel!
    private(set) var settingsVM: SettingsViewModel!
    private(set) var chatVM: ChatViewModel!
    private var cancellables: Set<AnyCancellable> = []

    init() {
        skillManager.reloadSkills()
        let llm = LLMService(settings: store.settings)
        let orchestrator = AgentOrchestrator(llm: llm)
        self.sidebarVM = SidebarViewModel(store: store, skillManager: skillManager)
        self.settingsVM = SettingsViewModel(store: store, llm: llm, skillManager: skillManager, mcpManager: mcpManager)
        self.chatVM = ChatViewModel(store: store, llm: llm, orchestrator: orchestrator)
        self.preferredColorScheme = store.settings.themePreference.colorScheme
        self.locale = store.settings.languagePreference.localeIdentifier.map(Locale.init(identifier:)) ?? .current

        store.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.preferredColorScheme = settings.themePreference.colorScheme
                self?.locale = settings.languagePreference.localeIdentifier.map(Locale.init(identifier:)) ?? .current
            }
            .store(in: &cancellables)
    }
}

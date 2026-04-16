import SwiftUI
import AppKit

struct MainContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: appState.sidebarVM)
                .frame(minWidth: 250, idealWidth: 286, maxWidth: 340)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            WindowPersistence.shared.restore()
            hideWindowTitle()
        }
        .onChange(of: appState.detailRoute) {
            hideWindowTitle()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch appState.detailRoute {
        case .chat:
            ChatView(viewModel: appState.chatVM)
        case .settings(let tab):
            SettingsView(
                viewModel: appState.settingsVM,
                initialTab: tab,
                displayMode: .embedded,
                onClose: { appState.closeSettings() }
            )
            .id("embedded-settings-\(tab.rawValue)")
        }
    }

    private func hideWindowTitle() {
        let applyChrome = {
            NSApp.windows.forEach { window in
                window.title = ""
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            }
        }

        DispatchQueue.main.async(execute: applyChrome)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: applyChrome)
    }
}

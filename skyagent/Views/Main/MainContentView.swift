import SwiftUI
import AppKit

struct MainContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: appState.sidebarVM)
                .frame(minWidth: 250, idealWidth: 286, maxWidth: 340)
        } detail: {
            ChatView(viewModel: appState.chatVM)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            WindowPersistence.shared.restore()
            hideWindowTitle()
        }
    }

    private func hideWindowTitle() {
        DispatchQueue.main.async {
            NSApp.windows.forEach { window in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            }
        }
    }
}

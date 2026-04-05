import SwiftUI
import AppKit

struct MainContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: appState.sidebarVM)
                .frame(minWidth: 220)
        } detail: {
            ChatView(viewModel: appState.chatVM)
        }
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

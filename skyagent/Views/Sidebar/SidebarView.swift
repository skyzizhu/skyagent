import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    private enum PendingDangerousAction {
        case clearMessages(UUID)
        case deleteConversation(UUID)
    }

    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var store: ConversationStore
    @State private var renamingId: UUID? = nil
    @State private var renameText = ""
    @State private var showSearch = false
    @State private var permissionChangeTarget: UUID?
    @State private var showOpenModeConfirmation = false
    @State private var pendingDangerousAction: PendingDangerousAction?
    @Environment(\.openSettings) private var openSettings

    init(viewModel: SidebarViewModel) {
        self.viewModel = viewModel
        self.store = viewModel.store
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            filterTabs
            if showSearch {
                searchField
            }
            Divider()
                .overlay(Color.primary.opacity(0.04))
            conversationList
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.primary.opacity(0.012)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .alert(L10n.tr("sidebar.rename.title"), isPresented: Binding(
            get: { renamingId != nil },
            set: { if !$0 { renamingId = nil } }
        )) {
            TextField(L10n.tr("sidebar.rename.placeholder"), text: $renameText)
            Button(L10n.tr("common.confirm")) {
                if let id = renamingId {
                    viewModel.renameConversation(id, newTitle: renameText)
                }
                renamingId = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) { renamingId = nil }
        }
        .sheet(isPresented: $viewModel.showNewConversationSheet) {
            NewConversationSheet { mode, dir in
                viewModel.createConversation(mode: mode, dir: dir)
            }
        }
        .alert(L10n.tr("sidebar.open_mode.title"), isPresented: $showOpenModeConfirmation) {
            Button(L10n.tr("common.cancel"), role: .cancel) {
                permissionChangeTarget = nil
            }
            Button(L10n.tr("common.switch")) {
                if let id = permissionChangeTarget {
                    store.togglePermissionMode(id)
                }
                permissionChangeTarget = nil
            }
        } message: {
            Text(L10n.tr("sidebar.open_mode.message"))
        }
        .alert(sidebarDangerTitle, isPresented: Binding(
            get: { pendingDangerousAction != nil },
            set: { if !$0 { pendingDangerousAction = nil } }
        )) {
            Button(L10n.tr("common.cancel"), role: .cancel) {
                pendingDangerousAction = nil
            }
            Button(sidebarDangerConfirmTitle, role: .destructive) {
                performPendingDangerousAction()
            }
        } message: {
            Text(sidebarDangerMessage)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.newConversation() }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.tr("sidebar.new_conversation"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.075), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .help(L10n.tr("sidebar.new.help"))

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch.toggle()
                    if !showSearch { viewModel.searchText = "" }
                }
            } label: {
                toolbarIcon(showSearch ? "xmark.circle" : "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help(L10n.tr("sidebar.search.help"))

            Button { openSettings() } label: {
                toolbarIcon("gearshape")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(L10n.tr("sidebar.settings.help"))
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            TextField(L10n.tr("sidebar.search.placeholder"), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.065), lineWidth: 0.8)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var filterTabs: some View {
        HStack(spacing: 6) {
            filterTabButton(
                title: L10n.tr("sidebar.filter.all"),
                systemImage: "text.bubble",
                filter: .all
            )
            filterTabButton(
                title: L10n.tr("sidebar.filter.favorites"),
                systemImage: "star",
                filter: .favorites
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func filterTabButton(title: String, systemImage: String, filter: SidebarViewModel.ConversationFilter) -> some View {
        let isSelected = viewModel.selectedFilter == filter

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.selectedFilter = filter
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.primary.opacity(0.06) : Color.primary.opacity(0.025))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.primary.opacity(0.09) : Color.primary.opacity(0.04), lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.filteredConversations) { conv in
                        Button {
                            viewModel.selectConversation(conv.id)
                        } label: {
                            ConversationRowView(
                                conv: conv,
                                isCurrent: store.currentConversationId == conv.id
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .id(conv.id)
                        .contextMenu {
                            Button(conv.isFavorite ? L10n.tr("sidebar.unfavorite") : L10n.tr("sidebar.favorite")) {
                                viewModel.toggleFavoriteConversation(conv.id)
                            }
                            Divider()
                            Button(L10n.tr("common.rename")) {
                                renameText = conv.title; renamingId = conv.id
                            }
                            Button(L10n.tr("sidebar.export_markdown")) {
                                exportConversation(conv.id)
                            }
                            if conv.filePermissionMode == .sandbox {
                                Button(L10n.tr("sidebar.switch_to_open")) {
                                    requestPermissionChange(for: conv.id, currentMode: conv.filePermissionMode)
                                }
                            } else {
                                Button(L10n.tr("sidebar.switch_to_sandbox")) {
                                    requestPermissionChange(for: conv.id, currentMode: conv.filePermissionMode)
                                }
                            }
                            Button(L10n.tr("sidebar.choose_directory")) {
                                chooseDirFor(conv.id)
                            }
                            Divider()
                            Button(L10n.tr("conversation.clear_messages")) {
                                pendingDangerousAction = .clearMessages(conv.id)
                            }
                            Button(L10n.tr("common.delete"), role: .destructive) {
                                pendingDangerousAction = .deleteConversation(conv.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: store.currentConversationId) {
                guard let currentId = store.currentConversationId else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(currentId, anchor: .center)
                }
            }
            .onChange(of: store.conversations.count) {
                guard let currentId = store.currentConversationId else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(currentId, anchor: .center)
                    }
                }
            }
        }
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.04))
                .frame(width: 28, height: 28)

            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.9))
        }
    }

    private func chooseDirFor(_ convId: UUID) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("panel.choose_workdir.title")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            store.updateConversationSandboxDir(convId, dir: url.path)
        }
    }

    private func requestPermissionChange(for convId: UUID, currentMode: FilePermissionMode) {
        if currentMode == .sandbox {
            permissionChangeTarget = convId
            showOpenModeConfirmation = true
        } else {
            store.togglePermissionMode(convId)
        }
    }

    private func exportConversation(_ convId: UUID) {
        guard let md = store.exportConversation(convId) else { return }
        let panel = NSSavePanel()
        panel.title = L10n.tr("panel.export_conversation.title")
        panel.nameFieldStringValue = L10n.tr("panel.export_conversation.filename")
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var sidebarDangerTitle: String {
        switch pendingDangerousAction {
        case .clearMessages:
            return L10n.tr("sidebar.danger.clear.title")
        case .deleteConversation:
            return L10n.tr("sidebar.danger.delete.title")
        case nil:
            return ""
        }
    }

    private var sidebarDangerMessage: String {
        switch pendingDangerousAction {
        case .clearMessages:
            return L10n.tr("sidebar.danger.clear.message", pendingDangerousConversationTitle)
        case .deleteConversation:
            return L10n.tr("sidebar.danger.delete.message", pendingDangerousConversationTitle)
        case nil:
            return ""
        }
    }

    private var sidebarDangerConfirmTitle: String {
        switch pendingDangerousAction {
        case .clearMessages:
            return L10n.tr("conversation.clear_messages")
        case .deleteConversation:
            return L10n.tr("common.delete")
        case nil:
            return L10n.tr("common.confirm")
        }
    }

    private var pendingDangerousConversationTitle: String {
        let convId: UUID?
        switch pendingDangerousAction {
        case .clearMessages(let id), .deleteConversation(let id):
            convId = id
        case nil:
            convId = nil
        }

        guard let convId,
              let conversation = store.conversations.first(where: { $0.id == convId }) else {
            return L10n.tr("conversation.new")
        }
        return conversation.title
    }

    private func performPendingDangerousAction() {
        defer { pendingDangerousAction = nil }

        switch pendingDangerousAction {
        case .clearMessages(let convId):
            viewModel.clearMessages(convId)
        case .deleteConversation(let convId):
            viewModel.deleteConversation(convId)
        case nil:
            break
        }
    }
}

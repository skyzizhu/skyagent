import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var store: ConversationStore
    @State private var renamingId: UUID? = nil
    @State private var renameText = ""
    @State private var showSearch = false
    @State private var permissionChangeTarget: UUID?
    @State private var showOpenModeConfirmation = false
    @Environment(\.openSettings) private var openSettings

    init(viewModel: SidebarViewModel) {
        self.viewModel = viewModel
        self.store = viewModel.store
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if showSearch {
                searchField
            }
            Divider()
            conversationList
        }
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
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
                Image(systemName: showSearch ? "xmark.circle" : "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("sidebar.search.help"))

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary.opacity(0.9))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(L10n.tr("sidebar.settings.help"))
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
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
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
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
                                isCurrent: store.currentConversationId == conv.id,
                                onRename: { renameText = conv.title; renamingId = conv.id },
                                onClear: { if store.currentConversationId == conv.id { viewModel.clearMessages() } },
                                onDelete: { viewModel.deleteConversation(conv.id) }
                            )
                        }
                        .buttonStyle(.plain)
                        .id(conv.id)
                        .contextMenu {
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
                                if store.currentConversationId == conv.id { viewModel.clearMessages() }
                            }
                            Button(L10n.tr("common.delete"), role: .destructive) {
                                viewModel.deleteConversation(conv.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
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
}

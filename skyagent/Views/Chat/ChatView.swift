import SwiftUI
import AppKit

struct ChatView: View {
    private let initialTranscriptWindowSize = 60
    private let transcriptWindowIncrement = 50

    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var store: ConversationStore
    @State private var inputText = ""
    @State private var pendingAttachment: ComposerAttachment?
    @State private var attachmentStatus: ComposerAttachmentStatus?
    @State private var showOpenModeConfirmation = false
    @State private var pendingScrollTask: DispatchWorkItem?
    @State private var shouldAutoFollowTranscript = true
    @State private var visibleMessageLimit = 90
    @FocusState private var inputFocused: Bool

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        self.store = viewModel.store
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conv = store.currentConversation {
                let allTranscriptMessages = visibleMessages(for: conv)
                let transcriptMessages = Array(allTranscriptMessages.suffix(visibleMessageLimit))
                let hiddenMessageCount = max(0, allTranscriptMessages.count - transcriptMessages.count)
                conversationContent(
                    conv: conv,
                    transcriptMessages: transcriptMessages,
                    hiddenMessageCount: hiddenMessageCount
                )

                if let error = viewModel.errorMessage {
                    errorBar(error)
                }

                ChatInputView(
                    inputText: $inputText,
                    pendingAttachment: $pendingAttachment,
                    attachmentStatus: $attachmentStatus,
                    isLoading: viewModel.isLoading,
                    permissionMode: conv.filePermissionMode,
                    modelName: viewModel.currentModelName,
                    onSend: { handlePrimaryAction() },
                    onTogglePermission: { togglePermission(for: conv) },
                    inputFocused: $inputFocused
                )
            } else {
                EmptyStateView(onNewConversation: {
                    let _ = store.newConversation()
                    inputFocused = true
                })
            }
        }
        .onAppear {
            inputFocused = true
            visibleMessageLimit = initialTranscriptWindowSize
            viewModel.refreshConversationRecoveryStatus()
        }
        .onChange(of: store.currentConversationId) {
            visibleMessageLimit = initialTranscriptWindowSize
            viewModel.refreshConversationRecoveryStatus()
        }
        .alert(L10n.tr("sidebar.open_mode.title"), isPresented: $showOpenModeConfirmation) {
            Button(L10n.tr("common.cancel"), role: .cancel) {}
            Button(L10n.tr("common.switch")) {
                if let convId = store.currentConversation?.id {
                    store.togglePermissionMode(convId)
                }
            }
        } message: {
            Text(L10n.tr("sidebar.open_mode.message"))
        }
        .sheet(item: $viewModel.pendingApproval) { preview in
            approvalSheet(preview)
        }
    }

    @ViewBuilder
    private func conversationContent(conv: Conversation, transcriptMessages: [Message], hiddenMessageCount: Int) -> some View {
        VStack(spacing: 0) {
            topDirectoryBar(for: conv)

            transcriptScrollView(conv: conv, transcriptMessages: transcriptMessages, hiddenMessageCount: hiddenMessageCount)
        }
    }

    private func transcriptScrollView(conv: Conversation, transcriptMessages: [Message], hiddenMessageCount: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    transcriptStack(
                        conv: conv,
                        transcriptMessages: transcriptMessages,
                        hiddenMessageCount: hiddenMessageCount,
                        scrollProxy: proxy
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .background(
                TranscriptScrollObserver { isNearBottom in
                    shouldAutoFollowTranscript = isNearBottom
                }
            )
            .defaultScrollAnchor(.bottom)
            .onChange(of: conv.id) {
                shouldAutoFollowTranscript = true
                visibleMessageLimit = initialTranscriptWindowSize
                scheduleScrollToBottom(with: proxy, animated: false, force: true)
            }
            .onChange(of: conv.messages.count) {
                scheduleScrollToBottom(with: proxy, animated: false)
            }
            .onChange(of: conv.messages.last?.content) {
                scheduleScrollToBottom(with: proxy, animated: false, debounce: 0.06)
            }
            .onChange(of: viewModel.currentActivityStatus?.title) {
                scheduleScrollToBottom(with: proxy, animated: false, debounce: 0.02)
            }
            .onChange(of: viewModel.currentActivityStatus?.detail) {
                scheduleScrollToBottom(with: proxy, animated: false, debounce: 0.02)
            }
            .overlay(alignment: .bottomTrailing) {
                if !shouldAutoFollowTranscript {
                    Button {
                        shouldAutoFollowTranscript = true
                        scheduleScrollToBottom(with: proxy, animated: true, force: true)
                    } label: {
                        Label(L10n.tr("chat.transcript.jump_latest"), systemImage: "arrow.down")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
                    .padding(.trailing, 22)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptStack(
        conv: Conversation,
        transcriptMessages: [Message],
        hiddenMessageCount: Int,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        VStack(spacing: 0) {
            if hiddenMessageCount > 0 {
                transcriptLoadMoreRow(hiddenMessageCount: hiddenMessageCount, scrollProxy: scrollProxy)
                    .id("transcript-load-more")
                    .padding(.bottom, 12)
            }

            ForEach(Array(transcriptMessages.enumerated()), id: \.element.id) { index, msg in
                transcriptRow(
                    msg: msg,
                    nextMessage: transcriptMessages.indices.contains(index + 1) ? transcriptMessages[index + 1] : nil,
                    conversation: conv,
                    transcriptMessages: transcriptMessages
                )
                .padding(.bottom, rowSpacing(after: msg, next: transcriptMessages.indices.contains(index + 1) ? transcriptMessages[index + 1] : nil))
            }

            if let status = viewModel.currentActivityStatus {
                conversationActivityRow(status)
                    .id("conversation-activity-status")
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }

            Color.clear
                .frame(height: 24)
                .id("transcript-bottom")
        }
        .frame(maxWidth: 980, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private func transcriptLoadMoreRow(hiddenMessageCount: Int, scrollProxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer()
            Button {
                let anchorMessageID = store.currentConversation
                    .flatMap { visibleMessages(for: $0).suffix(visibleMessageLimit).first?.id }
                visibleMessageLimit += transcriptWindowIncrement

                guard let anchorMessageID else { return }
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(anchorMessageID, anchor: .top)
                    }
                }
            } label: {
                Text(L10n.tr("chat.transcript.load_older_count", String(hiddenMessageCount)))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.03), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, 2)
    }

    private func conversationActivityRow(_ status: ConversationActivityStatus) -> some View {
        let accentColor = activityAccentColor(for: status.accentStyle)

        return HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(accentColor.opacity(0.12))
                            .frame(width: 28, height: 28)

                        if status.isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.8)
                                .tint(accentColor)
                        } else {
                            Image(systemName: status.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(accentColor)
                        }
                    }

                    Text(status.phaseLabel)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accentColor.opacity(0.08), in: Capsule())

                    ForEach(status.badges.prefix(3), id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.03), in: Capsule())
                    }
                }

                Text(status.title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                if let detail = status.detail,
                   !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let context = status.context,
                   !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(context)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accentColor.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accentColor.opacity(0.1), lineWidth: 0.8)
            )

            Spacer(minLength: 80)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeOut(duration: 0.18), value: status.title)
        .animation(.easeOut(duration: 0.18), value: status.detail ?? "")
    }

    private func activityAccentColor(for style: ActivityAccentStyle) -> Color {
        switch style {
        case .neutral:
            return .secondary
        case .thinking:
            return .purple
        case .reading:
            return .blue
        case .writing:
            return .orange
        case .skill:
            return .pink
        case .network:
            return .teal
        case .shell:
            return .green
        }
    }

    private func transcriptRow(msg: Message, nextMessage: Message?, conversation: Conversation, transcriptMessages: [Message]) -> some View {
        let isLastVisibleMessage = msg.id == transcriptMessages.last?.id
        let isLastAssistant = isLastVisibleMessage && msg.role == .assistant

        return EquatableView(
            content: MessageBubbleView(
                message: msg,
                onDelete: { viewModel.deleteMessage(msg.id) },
                onRegenerate: isLastAssistant ? { Task { await viewModel.regenerateLastReply() } } : nil,
                onEditUserMessage: { msgId, newText in
                    store.editMessageAndTruncate(msgId, newText: newText, in: conversation.id)
                    Task { await viewModel.regenerateLastReply() }
                },
                isLastAssistant: isLastAssistant,
                isStreamingAssistant: isLastAssistant && viewModel.isLoading
            )
        )
        .id(msg.id)
    }

    private func rowSpacing(after message: Message, next: Message?) -> CGFloat {
        guard let next else { return 14 }
        if message.role == .tool && next.role == .tool {
            return 6
        }
        if message.role == .tool || next.role == .tool {
            return 10
        }
        if message.role == .assistant && next.role == .assistant {
            return 12
        }
        return 16
    }

    private func currentDirName(_ conv: Conversation) -> String {
        let dir = currentDirPath(conv)
        return (dir as NSString).lastPathComponent
    }

    private func currentDirPath(_ conv: Conversation) -> String {
        conv.sandboxDir.isEmpty ? AppSettings.defaultSandboxDir : conv.sandboxDir
    }

    private func chooseSandboxDir(for convId: UUID) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("panel.choose_workdir.title")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            store.updateConversationSandboxDir(convId, dir: url.path)
        }
    }

    private func togglePermission(for conv: Conversation) {
        if conv.filePermissionMode == .sandbox {
            showOpenModeConfirmation = true
        } else {
            store.togglePermissionMode(conv.id)
        }
    }

    private func visibleMessages(for conversation: Conversation) -> [Message] {
        let preferred = conversation.messages.filter { message in
            guard message.isVisibleInTranscript else { return false }
            if message.role == .assistant,
               message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (message.toolCalls?.isEmpty ?? true),
               message.toolExecution == nil {
                return false
            }
            return true
        }

        if !preferred.isEmpty {
            return preferred
        }

        let nonHidden = conversation.messages.filter { message in
            message.hiddenFromTranscript != true && message.role != .system
        }
        if !nonHidden.isEmpty {
            return nonHidden
        }

        return conversation.messages.filter { $0.role != .system }
    }

    private func scheduleScrollToBottom(
        with proxy: ScrollViewProxy,
        animated: Bool,
        debounce: TimeInterval = 0.0,
        force: Bool = false
    ) {
        guard force || shouldAutoFollowTranscript else { return }
        pendingScrollTask?.cancel()

        let workItem = DispatchWorkItem {
            let scroll = {
                if animated {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
            }

            if Thread.isMainThread {
                scroll()
            } else {
                DispatchQueue.main.async(execute: scroll)
            }
        }

        pendingScrollTask = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: workItem)
    }

    private func topDirectoryBar(for conv: Conversation) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(currentDirName(conv))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Button {
                        chooseSandboxDir(for: conv.id)
                    } label: {
                        Text(L10n.tr("chat_input.switch_directory"))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.02))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.045), lineWidth: 0.7)
                )
                .help(currentDirPath(conv))

                Spacer()

                if let usage = viewModel.contextUsageStatus {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Text(
                                L10n.tr(
                                    "chat.context_usage.title",
                                    viewModel.formattedContextTokenCount(usage.usedTokens),
                                    viewModel.formattedContextTokenCount(usage.budgetTokens)
                                )
                            )
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.02))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.04), lineWidth: 0.7)
                        )

                        if usage.isCompressed {
                            Text(L10n.tr("chat.context_usage.compressed"))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.08), in: Capsule())
                        }
                    }
                    .help(L10n.tr("chat.context_usage.help"))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, -26)
            .padding(.bottom, 3)

            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(height: 0.7)
                .padding(.horizontal, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    // MARK: - Error Bar
    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Send
    private func handlePrimaryAction() {
        if viewModel.isLoading {
            Task { await viewModel.cancelRequest() }
            return
        }
        send()
    }

    private func send() {
        if attachmentStatus?.phase == .parsing {
            return
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingAttachment
        guard !text.isEmpty || attachment != nil else { return }

        var visibleMessage = text
        if let attachment {
            if !visibleMessage.isEmpty {
                visibleMessage += "\n\n"
            }
            visibleMessage += attachment.userVisibleLabel
        }

        inputText = ""
        pendingAttachment = nil
        attachmentStatus = nil
        shouldAutoFollowTranscript = true
        inputFocused = true  // 发送后重新聚焦输入框
        Task {
            await viewModel.sendMessage(
                visibleMessage,
                hiddenSystemContext: attachment?.modelContext,
                attachmentID: attachment?.attachmentID
            )
        }
    }

    private func approvalSheet(_ preview: OperationPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: approvalIconName(for: preview))
                    .font(.system(size: 22))
                    .foregroundStyle(preview.isDestructive ? .orange : .blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text(preview.title)
                        .font(.system(size: 18, weight: .semibold))
                    Text(preview.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(preview.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            )

            HStack(spacing: 8) {
                statusBadge(approvalRiskTitle(for: preview), color: preview.isDestructive ? .orange : .blue)
                if preview.canUndo {
                    statusBadge(L10n.tr("chat.approval.undo_supported"), color: .green)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button(L10n.tr("common.cancel")) {
                    viewModel.respondToPendingApproval(false)
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("chat.approval.continue")) {
                    viewModel.respondToPendingApproval(true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 320)
    }

    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func approvalIconName(for preview: OperationPreview) -> String {
        if preview.toolName == ToolDefinition.ToolName.exportFile.rawValue ||
            preview.toolName == ToolDefinition.ToolName.exportDirectory.rawValue {
            return "arrow.up.right.square.fill"
        }
        if preview.toolName == ToolDefinition.ToolName.shell.rawValue {
            return "terminal.fill"
        }
        if preview.toolName == ToolDefinition.ToolName.installSkill.rawValue {
            return "square.and.arrow.down.on.square.fill"
        }
        if preview.toolName == ToolDefinition.ToolName.runSkillScript.rawValue {
            return "play.rectangle.fill"
        }
        return preview.isDestructive ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
    }

    private func approvalRiskTitle(for preview: OperationPreview) -> String {
        if preview.toolName == ToolDefinition.ToolName.exportFile.rawValue ||
            preview.toolName == ToolDefinition.ToolName.exportDirectory.rawValue {
            return L10n.tr("chat.approval.risk.external_path")
        }
        if preview.toolName == ToolDefinition.ToolName.shell.rawValue {
            return L10n.tr("chat.approval.risk.command")
        }
        if preview.toolName == ToolDefinition.ToolName.installSkill.rawValue {
            return L10n.tr("chat.approval.risk.skill_install")
        }
        if preview.toolName == ToolDefinition.ToolName.runSkillScript.rawValue {
            return L10n.tr("chat.approval.risk.skill_script")
        }
        return preview.isDestructive ? L10n.tr("chat.approval.risk.high") : L10n.tr("chat.approval.risk.normal")
    }
}

private struct TranscriptScrollObserver: NSViewRepresentable {
    var onNearBottomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNearBottomChange: onNearBottomChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onNearBottomChange = onNearBottomChange
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(to: nsView.enclosingScrollView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        var onNearBottomChange: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var lastValue: Bool?

        init(onNearBottomChange: @escaping (Bool) -> Void) {
            self.onNearBottomChange = onNearBottomChange
        }

        func attachIfNeeded(to scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else { return }
            detach()
            guard let scrollView else { return }

            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.emitPosition()
            }
            emitPosition()
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            scrollView = nil
            lastValue = nil
        }

        private func emitPosition() {
            guard let scrollView,
                  let documentView = scrollView.documentView else { return }
            let visibleRect = scrollView.contentView.bounds
            let distanceToBottom = max(0, documentView.bounds.maxY - visibleRect.maxY)
            let isNearBottom = distanceToBottom < 96
            guard lastValue != isNearBottom else { return }
            lastValue = isNearBottom
            onNearBottomChange(isNearBottom)
        }
    }
}

private struct TopStatusContent {
    let label: String
    let labelColor: Color
    let title: String
    let detail: String
    let context: String?
    let badges: [String]
    let showsProgress: Bool
}

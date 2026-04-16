import SwiftUI
import AppKit

struct ChatView: View {
    private let initialTranscriptWindowSize = 40
    private let transcriptWindowIncrement = 30
    private static let transcriptComputationQueue = DispatchQueue(
        label: "SkyAgent.TranscriptCache",
        qos: .userInitiated
    )

    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var store: ConversationStore
    @ObservedObject private var activityViewModel: ConversationActivityViewModel
    @State private var inputText = ""
    @State private var pendingAttachment: ComposerAttachment?
    @State private var attachmentStatus: ComposerAttachmentStatus?
    @State private var showOpenModeConfirmation = false
    @State private var pendingScrollTask: DispatchWorkItem?
    @State private var pendingTranscriptRestoreTask: DispatchWorkItem?
    @State private var pendingTranscriptRefreshTask: DispatchWorkItem?
    @State private var shouldAutoFollowTranscript = true
    @State private var visibleMessageLimit = 60
    @State private var inputFocusRequestID = 0
    @State private var cachedTranscriptConversationID: UUID?
    @State private var cachedTranscriptMessageCount = 0
    @State private var cachedTranscriptLimit = 0
    @State private var cachedTranscriptLastMessageID: UUID?
    @State private var cachedTranscriptLastMessageSignature = 0
    @State private var cachedTranscriptSnapshot = TranscriptSnapshot(messages: [], hiddenMessageCount: 0)
    @State private var cachedTranscriptItems: [TranscriptItem] = []
    @State private var transcriptPresentationStore = TranscriptPresentationStore()
    @State private var conversationSwitchStartedAt: Date?
    @State private var transcriptRefreshStartedAt: Date?
    @State private var isTranscriptRefreshing = false
    @State private var knowledgeSelectionTarget: KnowledgeSelectionTarget?

    private struct KnowledgeSelectionTarget: Identifiable {
        let id: UUID
    }

    private enum TranscriptItem: Identifiable {
        case message(Message)
        case toolBatch([Message])

        var id: String {
            switch self {
            case .message(let message):
                return message.id.uuidString
            case .toolBatch(let messages):
                return "tool-batch-\(messages.first?.id.uuidString ?? UUID().uuidString)"
            }
        }
    }

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        self.store = viewModel.store
        self._activityViewModel = ObservedObject(initialValue: viewModel.activityViewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conv = store.currentConversation {
                let transcriptSnapshot = resolvedTranscriptSnapshot(for: conv)
                let transcriptItems = resolvedTranscriptItems(for: conv, snapshot: transcriptSnapshot)
                conversationContent(
                    conv: conv,
                    transcriptItems: transcriptItems,
                    hiddenMessageCount: transcriptSnapshot.hiddenMessageCount
                )

                ChatInputView(
                    inputText: $inputText,
                    pendingAttachment: $pendingAttachment,
                    attachmentStatus: $attachmentStatus,
                    isLoading: viewModel.isLoading,
                    permissionMode: conv.filePermissionMode,
                    modelName: viewModel.currentModelName,
                    requireCommandReturnToSend: store.settings.requireCommandReturnToSend,
                    contextUsageStatus: viewModel.contextUsageStatus,
                    onSend: { handlePrimaryAction() },
                    onTogglePermission: { togglePermission(for: conv) },
                    onRequestFocus: { requestInputFocus() },
                    focusRequestID: inputFocusRequestID
                )
            } else {
                EmptyStateView(onNewConversation: {
                    let _ = store.newConversation()
                    requestInputFocus()
                })
            }
        }
        .onAppear {
            requestInputFocus()
            restoreTranscriptPresentationStateForCurrentConversation()
            viewModel.refreshConversationRecoveryStatus()
            refreshTranscriptCache()
        }
        .onChange(of: store.currentConversationId) {
            conversationSwitchStartedAt = Date()
            logUIEvent(
                category: .ui,
                event: "conversation_switch_started",
                status: .started,
                summary: "开始切换会话",
                metadata: [
                    "conversation_id": .string(store.currentConversationId?.uuidString ?? "")
                ]
            )
            viewModel.resetPresentationForConversationSwitch()
            restoreTranscriptPresentationStateForCurrentConversation()
            viewModel.refreshConversationRecoveryStatus()
            requestInputFocus()
            refreshTranscriptCache()
        }
        .onChange(of: viewModel.isLoading) {
            if !viewModel.isLoading {
                DispatchQueue.main.async {
                    requestInputFocus()
                }
            }
        }
        .onChange(of: visibleMessageLimit) {
            refreshTranscriptCache()
        }
        .onChange(of: store.currentConversation?.messages.count) {
            scheduleTranscriptCacheRefresh()
        }
        .onChange(of: store.currentConversation?.messages.last?.id) {
            scheduleTranscriptCacheRefresh()
        }
        .onChange(of: store.currentConversation?.messages.last?.content) {
            scheduleTranscriptCacheRefresh(debounce: 0.05)
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
        .sheet(item: $knowledgeSelectionTarget) { target in
            KnowledgeLibrarySelectionView(
                viewModel: KnowledgeLibrarySelectionViewModel(
                    conversationID: target.id,
                    store: store
                )
            )
        }
    }

    @ViewBuilder
    private func conversationContent(conv: Conversation, transcriptItems: [TranscriptItem], hiddenMessageCount: Int) -> some View {
        VStack(spacing: 0) {
            topDirectoryBar(for: conv)

            ZStack {
                transcriptScrollView(conv: conv, transcriptItems: transcriptItems, hiddenMessageCount: hiddenMessageCount)

                if shouldShowTranscriptLoading(for: conv, transcriptItems: transcriptItems) {
                    transcriptLoadingOverlay
                }
            }
        }
    }

    private func transcriptScrollView(conv: Conversation, transcriptItems: [TranscriptItem], hiddenMessageCount: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    transcriptStack(
                        conv: conv,
                        transcriptItems: transcriptItems,
                        hiddenMessageCount: hiddenMessageCount,
                        scrollProxy: proxy
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .background(
                TranscriptScrollObserver(
                    onMetricsChange: { metrics in
                        if viewModel.isLoading && metrics.didMoveUp {
                            shouldAutoFollowTranscript = false
                        } else {
                            shouldAutoFollowTranscript = metrics.isNearBottom
                        }
                        recordTranscriptPresentation(metrics: metrics)
                    },
                    onScrollViewChange: { scrollView in
                        transcriptPresentationStore.scrollView = scrollView
                    }
                )
            )
            .onDisappear {
                transcriptPresentationStore.scrollView = nil
                pendingTranscriptRestoreTask?.cancel()
            }
            .background(
                Color.clear.onAppear {
                    transcriptPresentationStore.scrollView = nil
                }
            )
            .defaultScrollAnchor(.bottom)
            .onChange(of: conv.id) {
                applySavedTranscriptPresentation(for: conv.id, with: proxy)
            }
            .onChange(of: conv.messages.count) {
                scheduleScrollToBottom(with: proxy, animated: false)
            }
            .onChange(of: conv.messages.last?.content) {
                scheduleScrollToBottom(with: proxy, animated: false, debounce: 0.06)
            }
            .onChange(of: activityViewModel.currentState?.id) {
                scheduleScrollToBottom(with: proxy, animated: false, debounce: 0.02)
            }
            .onChange(of: activityViewModel.currentState?.detail) {
                scheduleScrollToBottom(with: proxy, animated: false, debounce: 0.02)
            }
            .onChange(of: activityViewModel.displayedStates.count) {
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
        transcriptItems: [TranscriptItem],
        hiddenMessageCount: Int,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        VStack(spacing: 0) {
            if hiddenMessageCount > 0 {
                transcriptLoadMoreRow(hiddenMessageCount: hiddenMessageCount, scrollProxy: scrollProxy)
                    .id("transcript-load-more")
                    .padding(.bottom, 12)
            }

            ForEach(Array(transcriptItems.enumerated()), id: \.element.id) { index, item in
                transcriptRow(
                    item: item,
                    nextItem: transcriptItems.indices.contains(index + 1) ? transcriptItems[index + 1] : nil,
                    conversation: conv,
                    transcriptItems: transcriptItems
                )
                .padding(.bottom, rowSpacing(after: item, next: transcriptItems.indices.contains(index + 1) ? transcriptItems[index + 1] : nil))
            }

            if !activityViewModel.displayedStates.isEmpty {
                activityTrailPanel
                    .padding(.top, 4)
                    .padding(.bottom, 10)
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
                    .flatMap { Self.transcriptSnapshot(from: $0.messages, limit: visibleMessageLimit).messages.first?.id }
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

    @ViewBuilder
    private func transcriptRow(item: TranscriptItem, nextItem: TranscriptItem?, conversation: Conversation, transcriptItems: [TranscriptItem]) -> some View {
        switch item {
        case .message(let msg):
            let isLastVisibleMessage = msg.id == lastDisplayMessageID(in: transcriptItems)
            let isLastAssistant = isLastVisibleMessage && msg.role == .assistant

            EquatableView(
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

        case .toolBatch(let messages):
            ToolBatchSummaryView(messages: messages)
                .id(messages.first?.id ?? UUID())
        }
    }

    private func rowSpacing(after item: TranscriptItem, next: TranscriptItem?) -> CGFloat {
        guard let next else { return 14 }
        let currentIsTool = isToolItem(item)
        let nextIsTool = isToolItem(next)
        if currentIsTool && nextIsTool {
            return 6
        }
        if currentIsTool || nextIsTool {
            return 10
        }
        if case .message(let currentMessage) = item,
           case .message(let nextMessage) = next,
           currentMessage.role == .assistant && nextMessage.role == .assistant {
            return 12
        }
        return 16
    }

    private func assistantStatusRow(_ status: ConversationActivityState) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ConversationActivityBarView(state: status)
                .frame(maxWidth: 840, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activityTrailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(activityViewModel.displayedStates.enumerated()), id: \.element.id) { index, state in
                assistantStatusRow(state)
                    .id("assistant-activity-status-\(index)")
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func transcriptItems(from messages: [Message]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var index = 0

        while index < messages.count {
            let current = messages[index]
            guard canBatchToolMessage(current) else {
                items.append(.message(current))
                index += 1
                continue
            }

            var batch = [current]
            var nextIndex = index + 1
            while nextIndex < messages.count {
                let candidate = messages[nextIndex]
                guard canBatchToolMessage(candidate),
                      candidate.toolExecution?.name == current.toolExecution?.name,
                      abs(candidate.timestamp.timeIntervalSince(batch.last?.timestamp ?? candidate.timestamp)) <= 5 else {
                    break
                }
                batch.append(candidate)
                nextIndex += 1
            }

            if batch.count >= 2 {
                items.append(.toolBatch(batch))
            } else {
                items.append(.message(current))
            }
            index = nextIndex
        }

        return items
    }

    private static func canBatchToolMessage(_ message: Message) -> Bool {
        guard message.role == .tool,
              message.toolExecution != nil,
              (message.previewImagePaths?.isEmpty ?? true),
              message.previewImagePath == nil else {
            return false
        }
        return true
    }

    private func isToolItem(_ item: TranscriptItem) -> Bool {
        switch item {
        case .message(let message):
            return message.role == .tool
        case .toolBatch:
            return true
        }
    }

    private func displayMessage(for item: TranscriptItem) -> Message? {
        switch item {
        case .message(let message):
            return message
        case .toolBatch(let messages):
            return messages.last
        }
    }

    private func lastDisplayMessageID(in items: [TranscriptItem]) -> UUID? {
        items.reversed().compactMap(displayMessage(for:)).first?.id
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

    private static func transcriptSnapshot(from messages: [Message], limit: Int) -> TranscriptSnapshot {
        func collect(using predicate: (Message) -> Bool) -> TranscriptSnapshot {
            var visibleCount = 0
            var collected: [Message] = []
            collected.reserveCapacity(limit)

            for message in messages.reversed() {
                guard predicate(message) else { continue }
                visibleCount += 1
                if collected.count < limit {
                    collected.append(message)
                }
            }

            return TranscriptSnapshot(
                messages: collected.reversed(),
                hiddenMessageCount: max(0, visibleCount - collected.count)
            )
        }

        let preferred = collect { message in
            guard message.isVisibleInTranscript else { return false }
            if message.role == .assistant,
               message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (message.toolCalls?.isEmpty ?? true),
               message.toolExecution == nil {
                return false
            }
            return true
        }
        if !preferred.messages.isEmpty {
            return preferred
        }

        let nonHidden = collect { message in
            message.hiddenFromTranscript != true && message.role != .system
        }
        if !nonHidden.messages.isEmpty {
            return nonHidden
        }

        return collect { $0.role != .system }
    }

    private func transcriptCacheKey(for conversation: Conversation) -> TranscriptCacheKey {
        TranscriptCacheKey(
            conversationID: conversation.id,
            messageCount: conversation.messages.count,
            limit: visibleMessageLimit,
            lastMessageID: conversation.messages.last?.id,
            lastMessageSignature: transcriptMessageSignature(for: conversation.messages.last)
        )
    }

    private func transcriptMessageSignature(for message: Message?) -> Int {
        guard let message else { return 0 }
        var hasher = Hasher()
        hasher.combine(message.role.rawValue)
        hasher.combine(message.id)
        hasher.combine(message.renderFingerprint)
        return hasher.finalize()
    }

    private func cachedTranscriptMatches(_ key: TranscriptCacheKey) -> Bool {
        cachedTranscriptConversationID == key.conversationID &&
        cachedTranscriptMessageCount == key.messageCount &&
        cachedTranscriptLimit == key.limit &&
        cachedTranscriptLastMessageID == key.lastMessageID &&
        cachedTranscriptLastMessageSignature == key.lastMessageSignature
    }

    private func resolvedTranscriptSnapshot(for conversation: Conversation) -> TranscriptSnapshot {
        let key = transcriptCacheKey(for: conversation)
        if cachedTranscriptMatches(key) {
            return cachedTranscriptSnapshot
        }
        if cachedTranscriptConversationID == conversation.id {
            return cachedTranscriptSnapshot
        }
        return TranscriptSnapshot(messages: [], hiddenMessageCount: 0)
    }

    private func resolvedTranscriptItems(for conversation: Conversation, snapshot: TranscriptSnapshot) -> [TranscriptItem] {
        let key = transcriptCacheKey(for: conversation)
        if cachedTranscriptMatches(key) {
            return cachedTranscriptItems
        }
        if cachedTranscriptConversationID == conversation.id {
            return cachedTranscriptItems
        }
        return []
    }

    private func refreshTranscriptCache() {
        pendingTranscriptRefreshTask?.cancel()
        guard let conversation = store.currentConversation else {
            isTranscriptRefreshing = false
            transcriptRefreshStartedAt = nil
            cachedTranscriptConversationID = nil
            cachedTranscriptMessageCount = 0
            cachedTranscriptLimit = 0
            cachedTranscriptLastMessageID = nil
            cachedTranscriptLastMessageSignature = 0
            cachedTranscriptSnapshot = TranscriptSnapshot(messages: [], hiddenMessageCount: 0)
            cachedTranscriptItems = []
            return
        }

        let key = transcriptCacheKey(for: conversation)
        guard !cachedTranscriptMatches(key) else { return }
        isTranscriptRefreshing = true
        transcriptRefreshStartedAt = Date()
        let messages = conversation.messages
        let refreshStartedAt = Date()
        logUIEvent(
            category: .ui,
            event: "transcript_cache_refresh_started",
            status: .started,
            summary: "开始刷新会话转录缓存",
            metadata: [
                "conversation_id": .string(conversation.id.uuidString),
                "message_count": .int(messages.count),
                "limit": .int(key.limit)
            ]
        )

        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            let snapshot = Self.transcriptSnapshot(from: messages, limit: key.limit)
            let items = Self.transcriptItems(from: snapshot.messages)

            DispatchQueue.main.async {
                guard workItem?.isCancelled == false,
                      let currentConversation = store.currentConversation,
                      transcriptCacheKey(for: currentConversation) == key else { return }

                cachedTranscriptConversationID = key.conversationID
                cachedTranscriptMessageCount = key.messageCount
                cachedTranscriptLimit = key.limit
                cachedTranscriptLastMessageID = key.lastMessageID
                cachedTranscriptLastMessageSignature = key.lastMessageSignature
                cachedTranscriptSnapshot = snapshot
                cachedTranscriptItems = items
                isTranscriptRefreshing = false
                transcriptRefreshStartedAt = nil
                let durationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
                logUIEvent(
                    category: .ui,
                    event: "transcript_cache_refresh_finished",
                    status: .succeeded,
                    durationMs: durationMs,
                    summary: "会话转录缓存刷新完成",
                    metadata: [
                        "conversation_id": .string(key.conversationID.uuidString),
                        "item_count": .int(items.count),
                        "hidden_message_count": .int(snapshot.hiddenMessageCount)
                    ]
                )
                if let switchStartedAt = conversationSwitchStartedAt {
                    logUIEvent(
                        category: .ui,
                        event: "conversation_switch_finished",
                        status: .succeeded,
                        durationMs: Date().timeIntervalSince(switchStartedAt) * 1000,
                        summary: "会话切换完成",
                        metadata: [
                            "conversation_id": .string(key.conversationID.uuidString),
                            "item_count": .int(items.count)
                        ]
                    )
                    conversationSwitchStartedAt = nil
                }
            }
        }

        if let workItem {
            pendingTranscriptRefreshTask = workItem
            Self.transcriptComputationQueue.async(execute: workItem)
        }
    }

    private func scheduleTranscriptCacheRefresh(debounce: TimeInterval = 0.0) {
        pendingTranscriptRefreshTask?.cancel()
        let effectiveDebounce = max(debounce, transcriptRefreshDebounce)
        let workItem = DispatchWorkItem {
            refreshTranscriptCache()
        }
        pendingTranscriptRefreshTask = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDebounce, execute: workItem)
    }

    private var transcriptRefreshDebounce: TimeInterval {
        guard viewModel.isLoading,
              store.currentConversation?.messages.last?.role == .assistant else {
            return 0.0
        }
        let contentLength = store.currentConversation?.messages.last?.content.count ?? 0
        if contentLength > 8_000 {
            return 0.2
        }
        if contentLength > 2_500 {
            return 0.14
        }
        return 0.08
    }

    private func restoreTranscriptPresentationStateForCurrentConversation() {
        guard let conversationID = store.currentConversationId else {
            visibleMessageLimit = initialTranscriptWindowSize
            shouldAutoFollowTranscript = true
            return
        }

        visibleMessageLimit = initialTranscriptWindowSize
        shouldAutoFollowTranscript = true
        transcriptPresentationStore.pendingRestoreConversationID = conversationID
    }

    private func recordTranscriptPresentation(metrics: TranscriptScrollMetrics) {
        guard let conversationID = store.currentConversationId,
              transcriptPresentationStore.pendingRestoreConversationID != conversationID else { return }

        transcriptPresentationStore.savedStates[conversationID] = SavedTranscriptPresentation(
            visibleMessageLimit: visibleMessageLimit,
            scrollPosition: metrics.isNearBottom ? .bottom : .offset(metrics.offsetY)
        )
    }

    private func applySavedTranscriptPresentation(for conversationID: UUID, with proxy: ScrollViewProxy) {
        pendingTranscriptRestoreTask?.cancel()

        visibleMessageLimit = initialTranscriptWindowSize
        shouldAutoFollowTranscript = true
        transcriptPresentationStore.pendingRestoreConversationID = conversationID

        scheduleTranscriptRestore(for: conversationID, with: proxy)
    }

    private func scheduleTranscriptRestore(
        for conversationID: UUID,
        with proxy: ScrollViewProxy,
        retryCount: Int = 0
    ) {
        pendingTranscriptRestoreTask?.cancel()

        let workItem = DispatchWorkItem {
            guard store.currentConversationId == conversationID else { return }

            let saved = transcriptPresentationStore.savedStates[conversationID]
            let position = saved?.scrollPosition ?? .bottom

            switch position {
            case .bottom:
                scheduleScrollToBottom(with: proxy, animated: false, force: true)
                DispatchQueue.main.async {
                    transcriptPresentationStore.pendingRestoreConversationID = nil
                }

            case .offset(let offsetY):
                guard let scrollView = transcriptPresentationStore.scrollView,
                      let documentView = scrollView.documentView else {
                    if retryCount < 8 {
                        scheduleTranscriptRestore(for: conversationID, with: proxy, retryCount: retryCount + 1)
                    }
                    return
                }

                let maxOffset = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
                let clampedOffset = min(max(offsetY, 0), maxOffset)
                var point = scrollView.contentView.bounds.origin
                point.y = clampedOffset
                scrollView.contentView.setBoundsOrigin(point)
                scrollView.reflectScrolledClipView(scrollView.contentView)

                DispatchQueue.main.async {
                    transcriptPresentationStore.pendingRestoreConversationID = nil
                }
            }
        }

        pendingTranscriptRestoreTask = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (retryCount == 0 ? 0.03 : 0.05), execute: workItem)
    }

    private func logUIEvent(
        category: LogCategory,
        event: String,
        status: LogStatus? = nil,
        durationMs: Double? = nil,
        summary: String,
        metadata: [String: LogValue] = [:]
    ) {
        Task {
            await LoggerService.shared.log(
                category: category,
                event: event,
                status: status,
                durationMs: durationMs,
                summary: summary,
                metadata: metadata
            )
        }
    }

    private func shouldShowTranscriptLoading(for conversation: Conversation, transcriptItems: [TranscriptItem]) -> Bool {
        let hasMessages = !conversation.messages.isEmpty
        if !hasMessages {
            return false
        }
        if transcriptItems.isEmpty {
            return true
        }
        return isTranscriptRefreshing && conversationSwitchStartedAt != nil && transcriptItems.count <= 2
    }

    private var transcriptLoadingOverlay: some View {
        TimelineView(.periodic(from: transcriptRefreshStartedAt ?? Date(), by: 1)) { context in
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(L10n.tr("chat.transcript.loading.title"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(
                    L10n.tr(
                        "chat.transcript.loading.detail",
                        L10n.tr("chat.waiting.elapsed.seconds", String(transcriptLoadingElapsedSeconds(now: context.date)))
                    )
                )
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 6)
        }
    }

    private func transcriptLoadingElapsedSeconds(now: Date) -> Int {
        max(1, Int(now.timeIntervalSince(transcriptRefreshStartedAt ?? now)))
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
        let chromeHeight: CGFloat = 52

        return VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.985)
                WindowChromeInteractionBackground(onDoubleClick: toggleWindowZoom)

                topBarContent(for: conv)
                .padding(.leading, 24)
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: chromeHeight)
            .padding(.top, -chromeHeight)

            Rectangle()
                .fill(Color.primary.opacity(0.03))
                .frame(height: 0.6)
                .padding(.horizontal, 24)
        }
    }

    private func topBarContent(for conv: Conversation) -> some View {
        HStack {
            Text("SkyAgent")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.trailing, 12)

            workspaceCapsule(for: conv)

            if let knowledgeStatus = viewModel.activeKnowledgeStatus {
                knowledgeCapsule(for: conv, status: knowledgeStatus)
            }

            if let skillRouting = viewModel.activeSkillRoutingStatus {
                skillRoutingCapsule(skillRouting)
            }

            Spacer()
        }
    }

    private func workspaceCapsule(for conv: Conversation) -> some View {
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
        .background(capsuleFill)
        .overlay(capsuleStroke(lineWidth: 0.7))
        .help(currentDirPath(conv))
    }

    private func knowledgeCapsule(for conv: Conversation, status: ChatViewModel.KnowledgeStatus) -> some View {
        let iconColor = knowledgeStatusColor(status)
        let subtitleColor = knowledgeStatusTextColor(status)

        return Button {
            knowledgeSelectionTarget = KnowledgeSelectionTarget(id: conv.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor)

                Text(status.title)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(status.subtitle)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)

                if status.hasIssues {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                } else if status.isSuggested {
                    capsuleBadge(
                        text: L10n.tr("chat.knowledge.selector.suggested_badge"),
                        foreground: .accentColor,
                        background: Color.accentColor.opacity(0.12)
                    )
                } else if status.hasRecentUsage {
                    capsuleBadge(
                        text: L10n.tr("chat.knowledge.recent_usage_badge"),
                        foreground: .blue,
                        background: Color.blue.opacity(0.12)
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(capsuleFill)
            .overlay(capsuleStroke(lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .help(status.detail ?? L10n.tr("chat.knowledge.selector.subtitle"))
    }

    private func skillRoutingCapsule(_ skillRouting: SkillRoutingStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(skillRouting.title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(capsuleFill)
        .overlay(capsuleStroke(lineWidth: 0.7))
        .help([skillRouting.detail, skillRouting.reason].compactMap { $0 }.joined(separator: "\n"))
    }

    private var capsuleFill: some ShapeStyle {
        Color.primary.opacity(0.018)
    }

    private func capsuleStroke(lineWidth: CGFloat) -> some View {
        Capsule()
            .stroke(Color.primary.opacity(0.04), lineWidth: lineWidth)
    }

    private func knowledgeStatusColor(_ status: ChatViewModel.KnowledgeStatus) -> Color {
        if status.hasIssues { return .orange }
        if status.isSuggested { return .accentColor }
        return status.isEnabled ? .secondary : Color.secondary.opacity(0.55)
    }

    private func knowledgeStatusTextColor(_ status: ChatViewModel.KnowledgeStatus) -> Color {
        if status.hasIssues { return .orange }
        if status.isSuggested { return .accentColor }
        return status.isEnabled ? .primary : .secondary
    }

    private func capsuleBadge(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
    }

    private func toggleWindowZoom() {
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        targetWindow?.performZoom(nil)
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
        requestInputFocus()
        Task {
            await viewModel.sendMessage(
                visibleMessage,
                hiddenSystemContext: attachment?.modelContext,
                attachmentID: attachment?.attachmentID,
                imageDataURL: attachment?.imageDataURL
            )
        }
    }

    private func requestInputFocus() {
        inputFocusRequestID &+= 1
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

private struct WindowChromeInteractionBackground: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> WindowChromeInteractionNSView {
        let view = WindowChromeInteractionNSView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: WindowChromeInteractionNSView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class WindowChromeInteractionNSView: NSView {
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseUp(with: event)
    }
}

private struct TranscriptScrollObserver: NSViewRepresentable {
    var onMetricsChange: (TranscriptScrollMetrics) -> Void
    var onScrollViewChange: (NSScrollView?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMetricsChange: onMetricsChange, onScrollViewChange: onScrollViewChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMetricsChange = onMetricsChange
        context.coordinator.onScrollViewChange = onScrollViewChange
        DispatchQueue.main.async {
            let scrollView = nsView.enclosingScrollView
            context.coordinator.onScrollViewChange(scrollView)
            context.coordinator.attachIfNeeded(to: scrollView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.onScrollViewChange(nil)
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        var onMetricsChange: (TranscriptScrollMetrics) -> Void
        var onScrollViewChange: (NSScrollView?) -> Void
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var lastMetrics: TranscriptScrollMetrics?

        init(
            onMetricsChange: @escaping (TranscriptScrollMetrics) -> Void,
            onScrollViewChange: @escaping (NSScrollView?) -> Void
        ) {
            self.onMetricsChange = onMetricsChange
            self.onScrollViewChange = onScrollViewChange
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
            lastMetrics = nil
        }

        private func emitPosition() {
            guard let scrollView,
                  let documentView = scrollView.documentView else { return }
            let visibleRect = scrollView.contentView.bounds
            let distanceToBottom = max(0, documentView.bounds.maxY - visibleRect.maxY)
            let previousOffsetY = lastMetrics?.offsetY ?? visibleRect.minY
            let metrics = TranscriptScrollMetrics(
                isNearBottom: distanceToBottom < 96,
                offsetY: visibleRect.minY,
                viewportHeight: visibleRect.height,
                contentHeight: documentView.bounds.height,
                didMoveUp: visibleRect.minY < previousOffsetY - 4
            )
            guard lastMetrics != metrics else { return }
            lastMetrics = metrics
            onMetricsChange(metrics)
        }
    }
}

private struct TranscriptSnapshot {
    let messages: [Message]
    let hiddenMessageCount: Int
}

private struct TranscriptCacheKey: Equatable {
    let conversationID: UUID
    let messageCount: Int
    let limit: Int
    let lastMessageID: UUID?
    let lastMessageSignature: Int
}

private struct TranscriptScrollMetrics: Equatable {
    let isNearBottom: Bool
    let offsetY: CGFloat
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
    let didMoveUp: Bool
}

private struct SavedTranscriptPresentation {
    let visibleMessageLimit: Int
    let scrollPosition: SavedTranscriptScrollPosition
}

private enum SavedTranscriptScrollPosition: Equatable {
    case bottom
    case offset(CGFloat)

    var isPinnedToBottom: Bool {
        if case .bottom = self {
            return true
        }
        return false
    }
}

private final class TranscriptPresentationStore {
    weak var scrollView: NSScrollView?
    var pendingRestoreConversationID: UUID?
    var savedStates: [UUID: SavedTranscriptPresentation] = [:]
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

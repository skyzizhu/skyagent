import Foundation
import SwiftUI
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    private struct TimeoutRecoveryPlan {
        let conversationOverride: Conversation
        let detail: String?
        let reason: String
    }

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pendingApproval: OperationPreview?
    @Published var fileIntentStatus: FileIntentStatus?
    @Published var skillRoutingStatus: SkillRoutingStatus?
    @Published var conversationRecoveryStatus: ConversationRecoveryStatus?
    @Published private(set) var contextUsageStatus: ContextUsageStatus?
    @Published private(set) var activeKnowledgeStatus: KnowledgeStatus?

    let store: ConversationStore
    let activityViewModel = ConversationActivityViewModel()
    private var llm: LLMService
    private let orchestrator: AgentOrchestrator
    private var requestTask: Task<Void, Never>?
    private var pendingAssistantDeltaBuffer = ""
    private var pendingAssistantDeltaConversationId: UUID?
    private var assistantDeltaFlushTask: Task<Void, Never>?
    private var processingFallbackTask: Task<Void, Never>?
    private var contextUsageRefreshTask: Task<Void, Never>?
    private var knowledgeStatusRefreshTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var currentTraceContext: TraceContext?
    private var currentAssistantTurnStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private let chatExecutionQueue = DispatchQueue(label: "SkyAgent.ChatExecution", qos: .userInitiated)

    private let maxRetries = 2
    @Published var networkStatus: NetworkStatus = .unknown

    enum NetworkStatus {
        case unknown, connected, disconnected, reconnecting
    }

    var currentModelName: String { store.settings.model }
    var sandboxDirDisplayName: String {
        guard let conv = store.currentConversation else { return L10n.tr("common.not_set") }
        if conv.filePermissionMode == .open {
            return L10n.tr("permission.open")
        }
        let dir = conv.sandboxDir.isEmpty ? store.settings.ensureSandboxDir() : conv.sandboxDir
        // 只显示最后一级目录名
        return (dir as NSString).lastPathComponent
    }
    var contextInfo: String {
        guard let conv = store.currentConversation else { return "0 messages" }
        let count = conv.messages.count
        return "\(count) msgs"
    }

    var currentActivityState: ConversationActivityState? {
        activityViewModel.currentState
    }

    struct KnowledgeStatus: Sendable {
        let title: String
        let subtitle: String
        let detail: String?
        let isEnabled: Bool
        let hasIssues: Bool
        let isSuggested: Bool
        let hasRecentUsage: Bool
        let recentUsageSummary: String?
    }

    var conversationContextOverviewStatus: ConversationContextOverviewStatus? {
        guard let conversation = store.currentConversation else { return nil }
        return ChatStatusComposer.makeConversationContextOverviewStatus(for: conversation)
    }

    nonisolated private static func recentKnowledgeUsage(
        in conversation: Conversation,
        librariesByID: [String: KnowledgeLibrary]
    ) -> (hasRecentUsage: Bool, summary: String?, detailLines: [String], nameLines: [String]) {
        guard let references = conversation.messages.reversed().compactMap(\.knowledgeReferences).first(where: { !$0.isEmpty }) else {
            return (false, nil, [], [])
        }

        var orderedNames: [String] = []
        var seenNames = Set<String>()

        for reference in references {
            let referenceName = reference.libraryName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mappedName = (
                reference.libraryID
                    .flatMap { librariesByID[$0.uuidString]?.name }
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (referenceName?.isEmpty == false ? referenceName : nil) ??
                (mappedName?.isEmpty == false ? mappedName : nil)

            guard let resolvedName else { continue }
            guard seenNames.insert(resolvedName).inserted else { continue }
            orderedNames.append(resolvedName)
        }

        guard !orderedNames.isEmpty else {
            return (false, nil, [], [])
        }

        let summary: String
        if let firstName = orderedNames.first, orderedNames.count == 1 {
            summary = L10n.tr("chat.knowledge.recent_usage_single", firstName)
        } else {
            summary = L10n.tr("chat.knowledge.recent_usage_multiple", "\(orderedNames.count)")
        }

        return (
            true,
            summary,
            [summary],
            orderedNames.count > 1 ? orderedNames : []
        )
    }

    var activeSkillRoutingStatus: SkillRoutingStatus? {
        guard let currentConversationID = store.currentConversationId,
              skillRoutingStatus?.conversationID == currentConversationID else {
            return nil
        }
        return skillRoutingStatus
    }

    init(store: ConversationStore, llm: LLMService, orchestrator: AgentOrchestrator) {
        self.store = store
        self.llm = llm
        self.orchestrator = orchestrator
        observeStoreChanges()
        refreshConversationRecoveryStatus()
        scheduleKnowledgeStatusRefresh(immediately: true)
        scheduleContextUsageRefresh(immediately: true)
    }

    func updateLLM(_ newLLM: LLMService) {
        self.llm = newLLM
    }

    func formattedContextTokenCount(_ value: Int) -> String {
        if value >= 1000 {
            let scaled = Double(value) / 1000.0
            return scaled >= 10 ? String(format: "%.0fK", scaled) : String(format: "%.1fK", scaled)
        }
        return "\(value)"
    }

    func sendMessage(_ text: String, hiddenSystemContext: String? = nil, attachmentID: String? = nil, imageDataURL: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hiddenSystemContext != nil else { return }

        if store.currentConversation == nil { store.newConversation() }
        guard let convId = store.currentConversationId else { return }
        isLoading = true
        errorMessage = nil
        conversationRecoveryStatus = nil
        cancelProcessingFallback()
        activityViewModel.beginThinking(intentContext: nil, badges: [])

        let existingConversation = store.conversations.first(where: { $0.id == convId })
        let userMsg = Message(role: .user, content: trimmed, attachmentID: attachmentID, imageDataURL: imageDataURL)
        let traceContext = TraceContext(conversationID: convId, messageID: userMsg.id)
        Task {
            await LoggerService.shared.log(
                category: .conversation,
                event: "message_submit_started",
                traceContext: traceContext,
                status: .started,
                summary: "用户提交消息",
                metadata: [
                    "input_length": .int(trimmed.count),
                    "has_attachment": .bool(attachmentID != nil),
                    "has_hidden_context": .bool(hiddenSystemContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ]
            )
        }
        store.appendMessage(userMsg, to: convId)

        let fallbackSandboxDir = store.settings.ensureSandboxDir()
        let fileIntentAnalysis = await analyzeFileIntentInBackground(
            userText: trimmed,
            conversation: existingConversation,
            fallbackSandboxDir: fallbackSandboxDir,
            currentAttachmentID: attachmentID
        )
        fileIntentStatus = fileIntentAnalysis.flatMap(buildFileIntentStatus(from:))
        skillRoutingStatus = nil

        let fileIntentContext = fileIntentAnalysis?.systemContext()
        let countingContext = countingExecutionContext(for: trimmed)
        let mergedHiddenContext = [hiddenSystemContext, countingContext, fileIntentContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if !mergedHiddenContext.isEmpty, !Task.isCancelled {
            let hiddenMessage = Message(
                role: .system,
                content: mergedHiddenContext,
                hiddenFromTranscript: true,
                attachmentID: attachmentID
            )
            store.appendMessage(hiddenMessage, to: convId)
        }

        scheduleContextUsageRefresh()

        if store.userMessageCount(convId) == 1 {
            store.updateConversationTitle(convId, title: String(trimmed.prefix(30)))
        }

        preactivateLikelySkillsIfNeeded(convId: convId, userText: trimmed)

        requestTask?.cancel()
        currentTraceContext = traceContext
        requestTask = Task { [weak self] in
            await self?.performChat(convId: convId, traceContext: traceContext)
        }
        Task {
            await LoggerService.shared.log(
                category: .conversation,
                event: "message_submit_finished",
                traceContext: traceContext,
                status: .succeeded,
                summary: "消息已入队处理",
                metadata: [
                    "conversation_message_count": .int(self.store.currentConversation?.messages.count ?? 0),
                    "has_hidden_context": .bool(!mergedHiddenContext.isEmpty)
                ]
            )
        }
    }

    private func scheduleContextUsageRefresh(immediately: Bool = false) {
        contextUsageRefreshTask?.cancel()

        guard let conversation = store.currentConversation else {
            contextUsageStatus = nil
            return
        }

        let conversationID = conversation.id
        let delay: UInt64 = immediately ? 0 : 120_000_000
        let snapshot = conversation
        let modelName = store.settings.model
        let maxTokens = store.settings.maxTokens
        let availableSkills = SkillManager.shared.availableSkills
        let activatedSkillMessages = SkillManager.shared.activationMessages(for: conversation.activatedSkillIDs)
        contextUsageRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }

            guard let self, !Task.isCancelled else { return }
            let status = await self.estimateContextUsageInBackground(
                for: snapshot,
                modelName: modelName,
                maxTokens: maxTokens,
                availableSkills: availableSkills,
                activatedSkillMessages: activatedSkillMessages
            )
            guard let currentConversation = self.store.currentConversation,
                  currentConversation.id == conversationID else { return }
            guard !Task.isCancelled else { return }
            self.contextUsageStatus = status
        }
    }

    private func estimateContextUsageInBackground(
        for conversation: Conversation,
        modelName: String,
        maxTokens: Int,
        availableSkills: [AgentSkill],
        activatedSkillMessages: [String]
    ) async -> ContextUsageStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let usageSnapshot = ChatContextUsageEstimator.makeSnapshot(
                    for: conversation,
                    modelName: modelName,
                    maxTokens: maxTokens,
                    availableSkills: availableSkills,
                    activatedSkillMessages: activatedSkillMessages
                )
                let status = ChatContextUsageEstimator.estimate(from: usageSnapshot)
                continuation.resume(returning: status)
            }
        }
    }

    private func analyzeFileIntentInBackground(
        userText: String,
        conversation: Conversation?,
        fallbackSandboxDir: String,
        currentAttachmentID: String?
    ) async -> FileIntentAnalysis? {
        guard let conversation else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let analysis = FileIntentResolver.shared.analyze(
                    userText: userText,
                    conversation: conversation,
                    fallbackSandboxDir: fallbackSandboxDir,
                    currentAttachmentID: currentAttachmentID
                )
                continuation.resume(returning: analysis)
            }
        }
    }

    private func countingExecutionContext(for text: String) -> String? {
        let normalized = text.lowercased()
        let asksForCount = containsAny(normalized, [
            "多少", "几张", "几個", "几个", "总共", "總共", "总共有", "總共有", "统计", "統計",
            "count", "how many", "total", "number of"
        ])
        guard asksForCount else { return nil }

        let targetsImagesOrFiles = containsAny(normalized, [
            "图片", "圖片", "图像", "圖像", "照片", "image", "images", "photo", "photos",
            "文件", "檔案", "file", "files", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".webp", ".svg", ".heic", ".heif"
        ])
        guard targetsImagesOrFiles else { return nil }

        return """
        [数量统计执行约束]
        1. 这是数量统计问题，必须先完成真实计数，再给结论。
        2. 不能只看目标目录顶层内容就下结论；如果顶层主要是文件夹，必须继续递归统计。
        3. 如果问题涉及图片或按扩展名过滤的文件数量，优先使用能直接返回总数和少量样例的 shell；不要只用顶层 list_files 推断结果。
        4. 回答时优先给总数，再给 3-10 个样例；不要输出完整大列表。
        [/数量统计执行约束]
        """
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    func deleteMessage(_ msgId: UUID) {
        store.deleteMessage(msgId)
    }

    func resetPresentationForConversationSwitch() {
        errorMessage = nil
        pendingApproval = nil
        fileIntentStatus = nil
        skillRoutingStatus = nil
        conversationRecoveryStatus = nil
        activityViewModel.reset()
        cancelProcessingFallback()
        flushPendingAssistantDelta()
    }

    func regenerateLastReply() async {
        guard !isLoading else { return }
        guard let convId = store.currentConversationId,
              let conv = store.conversations.first(where: { $0.id == convId }) else { return }

        // 如果最后一条是助手消息，先删除
        if let lastMsg = conv.messages.last, lastMsg.role == .assistant {
            store.removeLastAssistantMessage(in: convId)
        }

        requestTask?.cancel()
        let traceContext = TraceContext(
            conversationID: convId,
            messageID: conv.messages.last(where: { $0.role == .user })?.id
        )
        currentTraceContext = traceContext
        requestTask = Task { [weak self] in
            await self?.performChat(convId: convId, traceContext: traceContext)
        }
    }

    func cancelRequest() async {
        flushPendingAssistantDelta()
        requestTask?.cancel()
        requestTask = nil
        await llm.cancelCurrentTask()
        ToolRunner.shared.cancelActiveExecution()
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        pendingApproval = nil
        isLoading = false
        fileIntentStatus = nil
        conversationRecoveryStatus = nil
        activityViewModel.reset()
        errorMessage = L10n.tr("chat.error.stopped")

        guard let convId = store.currentConversationId,
              let conv = store.conversations.first(where: { $0.id == convId }),
              let last = conv.messages.last else { return }

        if last.role == .assistant && last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.removeTrailingEmptyAssistantMessage(convId)
        } else {
            store.requestSave(delay: 0.1)
        }
        scheduleContextUsageRefresh()
    }

    func respondToPendingApproval(_ approved: Bool) {
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
        pendingApproval = nil
        activityViewModel.clearApproval()
    }

    func undoOperation(_ operationId: String) {
        guard let convId = store.currentConversationId,
              let operation = store.operation(operationId, in: convId) else {
            errorMessage = L10n.tr("chat.error.undo_not_found")
            return
        }

        let outcome = ToolRunner.shared.undo(operation: operation)
        if outcome.success {
            store.markOperationUndone(operationId, in: convId)
            store.appendMessage(Message(role: .system, content: outcome.message), to: convId)
            store.requestSave(delay: 0.1)
        } else {
            errorMessage = outcome.message
        }
    }

    // MARK: - Private

    private func performChat(
        convId: UUID,
        traceContext: TraceContext? = nil,
        retryCount: Int = 0,
        conversationOverride: Conversation? = nil
    ) async {
        let effectiveTraceContext = traceContext ?? currentTraceContext ?? TraceContext(conversationID: convId)
        currentTraceContext = effectiveTraceContext
        isLoading = true
        errorMessage = nil
        conversationRecoveryStatus = nil
        cancelProcessingFallback()
        activityViewModel.beginThinking(
            intentContext: runningIntentContext(),
            badges: Array((fileIntentStatus?.badges ?? activeSkillRoutingStatus?.badges ?? []).prefix(3))
        )
        if retryCount == 0 {
            currentAssistantTurnStartedAt = Date()
            await LoggerService.shared.log(
                category: .conversation,
                event: "assistant_turn_started",
                traceContext: effectiveTraceContext,
                status: .started,
                summary: "开始处理本轮对话"
            )
        } else {
            await LoggerService.shared.log(
                level: .warn,
                category: .conversation,
                event: "assistant_turn_retried",
                traceContext: effectiveTraceContext,
                status: .retrying,
                summary: "本轮对话正在重试",
                metadata: LogMetadataBuilder.failure(
                    errorKind: .unknown,
                    retryCount: retryCount,
                    recoveryAction: .retry,
                    isUserVisible: false
                )
            )
        }

        let conversationForRun = conversationOverride ?? store.conversations.first(where: { $0.id == convId })
        guard let conv = conversationForRun else {
            isLoading = false
            return
        }

        let runResult = await runOrchestratorOffMain(
            conversation: conv,
            settings: store.settings,
            traceContext: effectiveTraceContext,
            convId: convId
        )

        var terminalError: Error?

        switch runResult {
        case .success:
            if storeHasDanglingEmptyAssistantMessage(in: convId) {
                errorMessage = AgentError.emptyAssistantResponse.localizedDescription
                activityViewModel.showFailure(errorMessage ?? "执行失败")
                store.removeTrailingEmptyAssistantMessage(convId)
            } else {
                networkStatus = .connected
            }

        case .failure(let error):
            terminalError = error
            if error is CancellationError {
                flushPendingAssistantDelta()
                cancelProcessingFallback()
                networkStatus = .connected
                isLoading = false
                requestTask = nil
                approvalContinuation?.resume(returning: false)
                approvalContinuation = nil
                pendingApproval = nil
                fileIntentStatus = nil
                conversationRecoveryStatus = nil
                activityViewModel.reset()
                store.removeTrailingEmptyAssistantMessage(convId)
                store.requestSave(delay: 0.1)
                scheduleContextUsageRefresh()
                await LoggerService.shared.log(
                    level: .warn,
                    category: .conversation,
                    event: "assistant_turn_cancelled",
                    traceContext: effectiveTraceContext,
                    status: .cancelled,
                    durationMs: elapsedMilliseconds(since: currentAssistantTurnStartedAt),
                    summary: "本轮对话已取消",
                    metadata: LogMetadataBuilder.failure(
                        errorKind: .cancelled,
                        recoveryAction: .abort,
                        isUserVisible: false
                    )
                )
                currentAssistantTurnStartedAt = nil
                currentTraceContext = nil
                return
            }

            if let recoveryPlan = timeoutRecoveryPlan(
                for: error,
                convId: convId,
                retryCount: retryCount
            ) {
                activityViewModel.showRetrying(detail: recoveryPlan.detail)
                if let current = store.conversations.first(where: { $0.id == convId }),
                   current.messages.last?.role == .assistant {
                    store.removeLastAssistantMessage(in: convId)
                }
                await LoggerService.shared.log(
                    level: .warn,
                    category: .conversation,
                    event: "assistant_turn_timeout_recovery_scheduled",
                    traceContext: effectiveTraceContext,
                    status: .retrying,
                    durationMs: elapsedMilliseconds(since: currentAssistantTurnStartedAt),
                    summary: "检测到流式空闲超时，准备恢复重试",
                    metadata: [
                        "retry_count": .int(retryCount),
                        "recovery_reason": .string(recoveryPlan.reason),
                        "timeout_stage": .string(timeoutStage(for: error) ?? "unknown")
                    ]
                )
                let delay = pow(2.0, Double(retryCount))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                isLoading = false
                await performChat(
                    convId: convId,
                    traceContext: effectiveTraceContext,
                    retryCount: retryCount + 1,
                    conversationOverride: recoveryPlan.conversationOverride
                )
                return
            } else if isTimeoutRelated(error) {
                errorMessage = L10n.tr("chat.error.request_timed_out")
                activityViewModel.showFailure(errorMessage ?? "执行失败")
            } else if isNetworkRelated(error) {
                networkStatus = .reconnecting
                activityViewModel.showRetrying(detail: L10n.tr("chat.waiting.retry.detail"))
                if retryCount < maxRetries {
                    if let current = store.conversations.first(where: { $0.id == convId }),
                       current.messages.last?.role == .assistant {
                        store.removeLastAssistantMessage(in: convId)
                    }
                    let delay = pow(2.0, Double(retryCount))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    isLoading = false
                    await performChat(convId: convId, traceContext: effectiveTraceContext, retryCount: retryCount + 1)
                    return
                } else {
                    networkStatus = .disconnected
                    errorMessage = L10n.tr("chat.error.network_disconnected")
                    activityViewModel.showFailure(errorMessage ?? "执行失败")
                }
            } else if retryCount < maxRetries {
                if let current = store.conversations.first(where: { $0.id == convId }),
                   current.messages.last?.role == .assistant {
                    store.removeLastAssistantMessage(in: convId)
                }
                isLoading = false
                await performChat(convId: convId, traceContext: effectiveTraceContext, retryCount: retryCount + 1)
                return
            } else {
                errorMessage = error.localizedDescription
                activityViewModel.showFailure(error.localizedDescription)
            }
            store.removeTrailingEmptyAssistantMessage(convId)
        }

        flushPendingAssistantDelta()
        cancelProcessingFallback()
        isLoading = false
        fileIntentStatus = nil
        requestTask = nil
        if errorMessage == nil {
            activityViewModel.reset()
        }
        store.refreshConversationContext(convId)
        store.requestSave(delay: 0.1)
        scheduleContextUsageRefresh()
        scheduleKnowledgeStatusRefresh()
        let turnDurationMs = elapsedMilliseconds(since: currentAssistantTurnStartedAt)
        if let errorMessage {
            let errorKind = logErrorKind(for: errorMessage)
            var failureMetadata: [String: LogValue] = [
                "error_message": .string(errorMessage)
            ]
            if let terminalError {
                if let timeoutStage = timeoutStage(for: terminalError) {
                    failureMetadata["timeout_stage"] = .string(timeoutStage)
                }
                if let timeoutKind = timeoutFailureKind(for: terminalError) {
                    failureMetadata["timeout_kind"] = .string(timeoutKind)
                }
            }
            await LoggerService.shared.log(
                level: .error,
                category: .conversation,
                event: "assistant_turn_failed",
                traceContext: effectiveTraceContext,
                status: .failed,
                durationMs: turnDurationMs,
                summary: "本轮对话执行失败",
                metadata: LogMetadataBuilder.failure(
                    errorKind: errorKind,
                    retryCount: retryCount,
                    recoveryAction: retryCount < maxRetries ? .retry : .abort,
                    isUserVisible: true,
                    extra: failureMetadata
                )
            )
        } else {
            await LoggerService.shared.log(
                category: .conversation,
                event: "assistant_turn_finished",
                traceContext: effectiveTraceContext,
                status: .succeeded,
                durationMs: turnDurationMs,
                summary: "本轮对话处理完成",
                metadata: [
                    "message_count": .int(store.currentConversation?.messages.count ?? 0)
                ]
            )
        }
        currentAssistantTurnStartedAt = nil
        currentTraceContext = nil

        if let updatedConv = store.conversations.first(where: { $0.id == convId }) {
            let summaryConversation = updatedConv
            let llmService = llm
            let settingsSnapshot = store.settings
            let fallbackSandboxDir = settingsSnapshot.ensureSandboxDir()
            Task.detached(priority: .utility) {
                let refreshedContextState = ConversationContextService.shared.buildState(
                    for: summaryConversation,
                    fallbackSandboxDir: fallbackSandboxDir
                )
                await MemoryService.shared.processConversationEnd(
                    convId: convId,
                    title: summaryConversation.title,
                    messages: summaryConversation.messages,
                    contextState: refreshedContextState,
                    llmService: llmService,
                    settings: settingsSnapshot
                )
            }
        }
    }

    private func elapsedMilliseconds(since startedAt: Date?) -> Double? {
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt) * 1000
    }

    private func runOrchestratorOffMain(
        conversation: Conversation,
        settings: AppSettings,
        traceContext: TraceContext,
        convId: UUID
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            chatExecutionQueue.async { [weak self, orchestrator] in
                guard let self else {
                    continuation.resume(returning: .failure(CancellationError()))
                    return
                }

                Task.detached(priority: .userInitiated) {
                    do {
                        try await orchestrator.run(
                            conversation: conversation,
                            settings: settings,
                            traceContext: traceContext,
                            requestApproval: { [weak self] preview in
                                guard let self else { return false }
                                return await self.requestApproval(preview)
                            }
                        ) { [weak self] event in
                            guard let self else { return }
                            await self.handleAgentEvent(event, convId: convId)
                        }

                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        }
    }

    private func storeHasDanglingEmptyAssistantMessage(in convId: UUID) -> Bool {
        guard let conversation = store.conversations.first(where: { $0.id == convId }),
              let last = conversation.messages.last else {
            return false
        }

        return last.role == .assistant &&
            last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (last.toolCalls?.isEmpty ?? true) &&
            last.toolExecution == nil
    }

    private func handleAgentEvent(_ event: AgentEvent, convId: UUID) async {
        switch event {
        case .knowledgeRetrieved(let hits):
            guard !hits.isEmpty else { return }
            let referenceMessage = Message(
                role: .system,
                content: L10n.tr("chat.knowledge.reference_block_title"),
                knowledgeReferences: knowledgeReferenceRecords(from: hits)
            )
            store.appendMessage(referenceMessage, to: convId)
            scheduleContextUsageRefresh()
            scheduleKnowledgeStatusRefresh()

        case .assistantTurnStarted:
            flushPendingAssistantDelta()
            cancelProcessingFallback()
            if !activityViewModel.hasExecutionTrail {
                activityViewModel.beginThinking(
                    intentContext: runningIntentContext(),
                    badges: Array((fileIntentStatus?.badges ?? activeSkillRoutingStatus?.badges ?? []).prefix(3))
                )
            }
            let assistantMsg = Message(role: .assistant, content: "")
            store.appendMessage(assistantMsg, to: convId)
            scheduleContextUsageRefresh()

        case .assistantDelta(let delta):
            if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activityViewModel.noteAssistantStreaming()
                fileIntentStatus = nil
                conversationRecoveryStatus = nil
                scheduleProcessingFallback()
            }
            queueAssistantDelta(delta, for: convId)

        case .assistantToolCalls(let toolCalls):
            flushPendingAssistantDelta()
            cancelProcessingFallback()
            store.updateLastAssistantToolCalls(convId, toolCalls: toolCalls)
            scheduleContextUsageRefresh()

        case .toolMatched(let execution):
            flushPendingAssistantDelta()
            cancelProcessingFallback()
            activityViewModel.showExecution(for: execution)
            fileIntentStatus = nil
            conversationRecoveryStatus = nil

        case .toolStarted(let execution, _):
            flushPendingAssistantDelta()
            cancelProcessingFallback()
            activityViewModel.showExecution(for: execution, resetVisibilityWindow: true)
            fileIntentStatus = nil
            conversationRecoveryStatus = nil

        case .toolProgress(let execution, _):
            cancelProcessingFallback()
            activityViewModel.showExecution(for: execution)

        case .toolCompleted(let execution, let result, let operation, let activatedSkillID, let previewImagePath, let previewImagePaths):
            flushPendingAssistantDelta()
            cancelProcessingFallback()
            await activityViewModel.ensureMinimumExecutionVisibility(for: execution.id)
            activityViewModel.completeExecution(for: execution)
            let toolMessage = Message(
                role: .tool,
                content: result,
                toolExecution: execution,
                previewImagePath: previewImagePath,
                previewImagePaths: previewImagePaths
            )
            store.appendMessage(toolMessage, to: convId)
            if let operation {
                store.addOperation(operation, to: convId)
            }
            if let activatedSkillID {
                store.markSkillActivated(activatedSkillID, in: convId)
            }
            scheduleContextUsageRefresh()
            scheduleKnowledgeStatusRefresh()
        }
    }

    private func scheduleProcessingFallback() {
        cancelProcessingFallback()
        processingFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.isLoading else { return }
                guard self.activityViewModel.currentState == nil else { return }
                self.activityViewModel.showProcessing()
            }
        }
    }

    private func cancelProcessingFallback() {
        processingFallbackTask?.cancel()
        processingFallbackTask = nil
    }

    private func queueAssistantDelta(_ delta: String, for convId: UUID) {
        pendingAssistantDeltaConversationId = convId
        pendingAssistantDeltaBuffer += delta

        guard assistantDeltaFlushTask == nil else { return }
        assistantDeltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            await MainActor.run {
                self?.flushPendingAssistantDelta()
            }
        }
    }

    private func flushPendingAssistantDelta() {
        assistantDeltaFlushTask?.cancel()
        assistantDeltaFlushTask = nil

        guard let convId = pendingAssistantDeltaConversationId,
              !pendingAssistantDeltaBuffer.isEmpty else {
            pendingAssistantDeltaConversationId = nil
            pendingAssistantDeltaBuffer = ""
            return
        }

        let delta = pendingAssistantDeltaBuffer
        pendingAssistantDeltaBuffer = ""
        pendingAssistantDeltaConversationId = nil
        store.updateLastMessageContent(convId, appending: delta, refreshContext: false)
        scheduleContextUsageRefresh()
    }

    private func requestApproval(_ preview: OperationPreview) async -> Bool {
        pendingApproval = preview
        activityViewModel.showApproval(preview)
        return await withCheckedContinuation { continuation in
            approvalContinuation?.resume(returning: false)
            approvalContinuation = continuation
        }
    }

    private func buildFileIntentStatus(from analysis: FileIntentAnalysis) -> FileIntentStatus? {
        ChatStatusComposer.makeFileIntentStatus(from: analysis)
    }

    private func runningIntentContext() -> String? {
        ChatStatusComposer.runningIntentContext(
            fileIntentStatus: fileIntentStatus,
            skillRoutingStatus: activeSkillRoutingStatus
        )
    }

    func refreshConversationRecoveryStatus() {
        guard let conversation = store.currentConversation else {
            conversationRecoveryStatus = nil
            contextUsageStatus = nil
            activeKnowledgeStatus = nil
            return
        }

        conversationRecoveryStatus = ChatStatusComposer.makeConversationRecoveryStatus(for: conversation)
        scheduleContextUsageRefresh()
    }

    private func isNetworkRelated(_ error: Error) -> Bool {
        let nsError = error as NSError
        let networkCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
        ]
        if nsError.domain == NSURLErrorDomain && networkCodes.contains(nsError.code) {
            return true
        }
        if case LLMError.networkUnavailable = error { return true }
        if case LLMError.connectionLost = error { return true }
        return false
    }

    private func isTimeoutRelated(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        if case LLMError.requestTimedOut = error { return true }
        if case LLMError.firstTokenTimedOut = error { return true }
        if case LLMError.streamIdleTimedOut = error { return true }
        return false
    }

    private func timeoutStage(for error: Error) -> String? {
        if case LLMError.requestTimedOut = error { return "request" }
        if case LLMError.firstTokenTimedOut = error { return "first_token" }
        if case LLMError.streamIdleTimedOut = error { return "stream_idle" }
        return nil
    }

    private func timeoutFailureKind(for error: Error) -> String? {
        if case LLMError.firstTokenTimedOut = error {
            return "first_token_timeout"
        }
        if case LLMError.requestTimedOut = error {
            return "request_timeout"
        }
        if case LLMError.streamIdleTimedOut = error {
            return "stream_idle_timeout"
        }
        return nil
    }

    private func timeoutRecoveryPlan(
        for error: Error,
        convId: UUID,
        retryCount: Int
    ) -> TimeoutRecoveryPlan? {
        guard retryCount == 0,
              case LLMError.streamIdleTimedOut = error,
              var conversation = store.conversations.first(where: { $0.id == convId }) else {
            return nil
        }

        guard let lastAssistantIndex = conversation.messages.lastIndex(where: { $0.role == .assistant }) else {
            return nil
        }

        let lastAssistant = conversation.messages[lastAssistantIndex]
        let trimmedAssistant = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAssistant.isEmpty,
              (lastAssistant.toolCalls?.isEmpty ?? true),
              lastAssistant.toolExecution == nil else {
            return nil
        }

        let lastUserIndex = conversation.messages.lastIndex(where: { $0.role == .user }) ?? 0
        let trailingMessages = conversation.messages.suffix(from: lastUserIndex)
        let hasToolPhaseStarted = trailingMessages.contains { message in
            message.role == .tool
                || !(message.toolCalls?.isEmpty ?? true)
                || message.toolExecution != nil
        }
        guard !hasToolPhaseStarted else {
            return nil
        }

        let recoveryInstruction = """
        [恢复指令]
        上一轮响应在输出开头后中断。不要重复前面的开场白。
        如果需要调用工具，请直接输出工具调用，不要先重复解释。
        如果不需要调用工具，请从未完成处继续补全最终结果。
        只补全剩余内容，避免从头重新回答。
        [/恢复指令]
        """
        conversation.messages.append(
            Message(
                role: .system,
                content: recoveryInstruction,
                hiddenFromTranscript: true
            )
        )
        return TimeoutRecoveryPlan(
            conversationOverride: conversation,
            detail: L10n.tr("chat.waiting.retry.detail"),
            reason: "stream_idle_before_tool_call"
        )
    }

    private func logErrorKind(for errorMessage: String) -> LogErrorKind {
        let normalized = errorMessage.lowercased()
        if normalized.contains("timed out") || normalized.contains("超时") {
            return .timeout
        }
        if normalized.contains("network") || normalized.contains("网络") || normalized.contains("connection") {
            return .network
        }
        if normalized.contains("permission") || normalized.contains("权限") {
            return .permission
        }
        return .unknown
    }

    private func preactivateLikelySkillsIfNeeded(convId: UUID, userText: String) {
        guard let conv = store.conversations.first(where: { $0.id == convId }) else { return }
        let matches = SkillManager.shared.likelyTriggeredSkillMatches(in: userText, excluding: conv.activatedSkillIDs)
        guard !matches.isEmpty else { return }

        if let topMatch = matches.first {
            skillRoutingStatus = ChatStatusComposer.makeSkillRoutingStatus(from: topMatch, conversationID: convId)
            let traceContext = (currentTraceContext ?? TraceContext(conversationID: convId)).with(conversationID: convId)
            Task {
                await LoggerService.shared.log(
                    category: .skill,
                    event: "skill_route_selected",
                    traceContext: traceContext,
                    status: .succeeded,
                    summary: "已命中候选 skill：\(topMatch.skill.name)",
                    metadata: [
                        "skill_name": .string(topMatch.skill.name),
                        "score": .int(topMatch.score),
                        "matched_sources": .strings(topMatch.matchedSignals.map(\.source.rawValue)),
                        "matched_phrases": .strings(topMatch.matchedSignals.map(\.phrase)),
                        "blocked_sources": .strings(topMatch.blockedSignals.map(\.source.rawValue))
                    ]
                )
            }
        }

        for match in matches.prefix(1) {
            store.markSkillActivated(match.skill.id, in: convId)
        }
    }

    private func observeStoreChanges() {
        store.$currentConversationId
            .sink { [weak self] _ in
                self?.scheduleKnowledgeStatusRefresh(immediately: true)
            }
            .store(in: &cancellables)

        store.$conversations
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard !self.isLoading else { return }
                self.scheduleKnowledgeStatusRefresh()
            }
            .store(in: &cancellables)

        store.$settings
            .sink { [weak self] _ in
                self?.scheduleKnowledgeStatusRefresh(immediately: true)
            }
            .store(in: &cancellables)
    }

    private func scheduleKnowledgeStatusRefresh(immediately: Bool = false) {
        knowledgeStatusRefreshTask?.cancel()

        guard let conversation = store.currentConversation else {
            activeKnowledgeStatus = nil
            return
        }

        let snapshot = conversation
        let defaultSandboxDir = store.settings.sandboxDir.isEmpty
            ? AppSettings.defaultSandboxDir
            : store.settings.sandboxDir
        let delay: UInt64 = immediately ? 0 : 180_000_000

        knowledgeStatusRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }

            guard let self, !Task.isCancelled else { return }
            let status = await self.computeKnowledgeStatusInBackground(
                for: snapshot,
                defaultSandboxDir: defaultSandboxDir
            )
            guard !Task.isCancelled else { return }
            guard self.store.currentConversationId == snapshot.id else { return }
            self.activeKnowledgeStatus = status
        }
    }

    private func computeKnowledgeStatusInBackground(
        for conversation: Conversation,
        defaultSandboxDir: String
    ) async -> KnowledgeStatus? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let selectedIDs = conversation.knowledgeLibraryIDs
                let workspacePath = conversation.sandboxDir.isEmpty
                    ? AppStoragePaths.normalizeSandboxPath(defaultSandboxDir)
                    : conversation.sandboxDir
                let knowledgeService = KnowledgeBaseService.shared
                let libraries = knowledgeService.listLibraries()
                let librariesByID = Dictionary(uniqueKeysWithValues: libraries.map { ($0.id.uuidString, $0) })
                let normalizedWorkspacePath = AppStoragePaths.normalizeSandboxPath(workspacePath)
                let workspaceLibraryID = libraries.first {
                    guard let sourceRoot = $0.sourceRoot else { return false }
                    return AppStoragePaths.normalizeSandboxPath(sourceRoot) == normalizedWorkspacePath
                }?.id.uuidString
                let suggestedLibraryIDs = KnowledgeLibrarySuggestionEngine.suggestedLibraryIDs(
                    workspacePath: workspacePath,
                    libraries: libraries,
                    workspaceLibraryID: workspaceLibraryID
                )
                let recentKnowledgeUsage = Self.recentKnowledgeUsage(
                    in: conversation,
                    librariesByID: librariesByID
                )

                if selectedIDs.isEmpty {
                    let suggestedLibraries = libraries.filter { suggestedLibraryIDs.contains($0.id.uuidString) }
                    let suggestionLines = suggestedLibraries.isEmpty
                        ? []
                        : [L10n.tr("chat.knowledge.selector.suggested_summary", "\(suggestedLibraries.count)")] + suggestedLibraries.map(\.name)
                    let detailLines = suggestionLines + recentKnowledgeUsage.detailLines
                    let suggestionDetail = detailLines.isEmpty ? nil : detailLines.joined(separator: "\n")
                    continuation.resume(returning: KnowledgeStatus(
                        title: L10n.tr("chat.knowledge.title"),
                        subtitle: suggestedLibraries.isEmpty
                            ? L10n.tr("chat.knowledge.disabled")
                            : L10n.tr("chat.knowledge.suggested_count", "\(suggestedLibraries.count)"),
                        detail: suggestionDetail,
                        isEnabled: false,
                        hasIssues: false,
                        isSuggested: !suggestedLibraries.isEmpty,
                        hasRecentUsage: recentKnowledgeUsage.hasRecentUsage,
                        recentUsageSummary: recentKnowledgeUsage.summary
                    ))
                    return
                }

                let selectedLibraries = selectedIDs.compactMap { librariesByID[$0] }
                let importJobs = knowledgeService.listImportJobs().filter { selectedIDs.contains($0.libraryId.uuidString) }
                let failedCount = importJobs.filter { $0.status == .failed }.count
                let pendingCount = importJobs.filter { $0.status == .pending || $0.status == .running }.count
                let hasIssues = failedCount > 0 || pendingCount > 0
                let issueSummary = hasIssues
                    ? L10n.tr("chat.knowledge.issue_summary", "\(failedCount)", "\(pendingCount)")
                    : nil

                if let firstLibrary = selectedLibraries.first, selectedLibraries.count == 1 {
                    let detailLines = [
                        firstLibrary.sourceRoot,
                        issueSummary,
                        recentKnowledgeUsage.summary
                    ]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty } + recentKnowledgeUsage.nameLines
                    continuation.resume(returning: KnowledgeStatus(
                        title: L10n.tr("chat.knowledge.title"),
                        subtitle: firstLibrary.name,
                        detail: detailLines.joined(separator: "\n"),
                        isEnabled: true,
                        hasIssues: hasIssues,
                        isSuggested: false,
                        hasRecentUsage: recentKnowledgeUsage.hasRecentUsage,
                        recentUsageSummary: recentKnowledgeUsage.summary
                    ))
                    return
                }

                let summary = L10n.tr("chat.knowledge.multiple", "\(selectedLibraries.count)")
                let detail = (
                    selectedLibraries.map(\.name) +
                    (issueSummary.map { [$0] } ?? []) +
                    (recentKnowledgeUsage.summary.map { [$0] } ?? []) +
                    recentKnowledgeUsage.nameLines
                )
                .joined(separator: "\n")

                continuation.resume(returning: KnowledgeStatus(
                    title: L10n.tr("chat.knowledge.title"),
                    subtitle: summary,
                    detail: detail,
                    isEnabled: true,
                    hasIssues: hasIssues,
                    isSuggested: false,
                    hasRecentUsage: recentKnowledgeUsage.hasRecentUsage,
                    recentUsageSummary: recentKnowledgeUsage.summary
                ))
            }
        }
    }

    private func knowledgeReferenceRecords(from hits: [RetrievalHit]) -> [KnowledgeReferenceRecord] {
        hits.prefix(4).map { hit in
            let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let libraryName = hit.libraryName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = hit.source?.trimmingCharacters(in: .whitespacesAndNewlines)
            let citation = hit.citation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let compactSnippet = snippet.count > 260 ? String(snippet.prefix(260)) + "..." : snippet
            return KnowledgeReferenceRecord(
                libraryID: hit.libraryID,
                libraryName: libraryName?.isEmpty == false ? libraryName : nil,
                documentID: hit.documentID,
                title: title.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.tr("chat.knowledge.reference_default_title"),
                source: source?.isEmpty == false ? source : nil,
                citation: citation?.isEmpty == false ? citation : nil,
                snippet: compactSnippet,
                score: hit.score
            )
        }
    }
}

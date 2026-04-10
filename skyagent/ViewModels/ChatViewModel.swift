import Foundation
import SwiftUI
import Combine

struct RunningToolStatus: Equatable {
    let id: String
    let toolName: String
    var title: String
    var detail: String
    var phaseLabel: String
    var badges: [String]
    var context: String?
}

struct FileIntentStatus: Equatable {
    let title: String
    let detail: String
    let reason: String?
    let badges: [String]
}

struct SkillRoutingStatus: Equatable {
    let conversationID: UUID
    let title: String
    let detail: String
    let reason: String?
    let badges: [String]
}

struct PendingResponseStatus: Equatable {
    let title: String
    let detail: String
    let context: String?
    let badges: [String]
}

struct StreamingResponseStatus: Equatable {
    let title: String
    let detail: String?
    let context: String?
    let badges: [String]
    let forceVisible: Bool
}

struct ConversationRecoveryStatus: Equatable {
    let title: String
    let detail: String
    let context: String?
    let badges: [String]
}

struct ConversationContextOverviewStatus: Equatable {
    let title: String
    let detail: String
    let context: String?
    let badges: [String]
}

struct ConversationActivityStatus: Equatable {
    let title: String
    let detail: String?
    let context: String?
    let badges: [String]
    let phaseLabel: String
    let isBusy: Bool
    let iconName: String
    let accentStyle: ActivityAccentStyle
}

struct ContextUsageStatus: Equatable {
    let usedTokens: Int
    let budgetTokens: Int
    let isCompressed: Bool
}

enum ActivityAccentStyle: Equatable {
    case neutral
    case thinking
    case reading
    case writing
    case skill
    case network
    case shell
    case approval
    case warning
    case error
    case success
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pendingApproval: OperationPreview?
    @Published var runningToolStatus: RunningToolStatus?
    @Published var pendingResponseStatus: PendingResponseStatus?
    @Published var streamingResponseStatus: StreamingResponseStatus?
    @Published var fileIntentStatus: FileIntentStatus?
    @Published var skillRoutingStatus: SkillRoutingStatus?
    @Published var conversationRecoveryStatus: ConversationRecoveryStatus?
    @Published var completedActivityStatus: ConversationActivityStatus?
    @Published private(set) var contextUsageStatus: ContextUsageStatus?

    let store: ConversationStore
    private var llm: LLMService
    private let orchestrator: AgentOrchestrator
    private var requestTask: Task<Void, Never>?
    private var pendingAssistantDeltaBuffer = ""
    private var pendingAssistantDeltaConversationId: UUID?
    private var assistantDeltaFlushTask: Task<Void, Never>?
    private var assistantActivityFallbackTask: Task<Void, Never>?
    private var contextUsageRefreshTask: Task<Void, Never>?
    private var lastAssistantDeltaAt: Date?
    private var completedActivityDismissTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var currentTraceContext: TraceContext?
    private var currentAssistantTurnStartedAt: Date?

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

    var currentActivityStatus: ConversationActivityStatus? {
        ChatStatusComposer.makeCurrentActivityStatus(
            pendingApproval: pendingApproval,
            runningToolStatus: runningToolStatus,
            streamingResponseStatus: streamingResponseStatus,
            pendingResponseStatus: pendingResponseStatus,
            isReconnecting: networkStatus == .reconnecting,
            hasVisibleStreamingAssistantContent: hasVisibleStreamingAssistantContent,
            errorMessage: errorMessage
        ) ?? completedActivityStatus
    }

    private var hasVisibleStreamingAssistantContent: Bool {
        guard isLoading,
              let conversation = store.currentConversation else { return false }

        guard let lastAssistant = conversation.messages.last(where: { $0.role == .assistant }) else {
            return false
        }

        return lastAssistant.isVisibleInTranscript &&
            !lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var conversationContextOverviewStatus: ConversationContextOverviewStatus? {
        guard let conversation = store.currentConversation else { return nil }
        return ChatStatusComposer.makeConversationContextOverviewStatus(for: conversation)
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
        refreshConversationRecoveryStatus()
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
        let existingConversation = store.conversations.first(where: { $0.id == convId })
        let fileIntentAnalysis = existingConversation.flatMap {
            FileIntentResolver.shared.analyze(
                userText: trimmed,
                conversation: $0,
                fallbackSandboxDir: store.settings.ensureSandboxDir(),
                currentAttachmentID: attachmentID
            )
        }
        fileIntentStatus = fileIntentAnalysis.flatMap(buildFileIntentStatus(from:))
        skillRoutingStatus = nil
        completedActivityDismissTask?.cancel()
        completedActivityStatus = nil
        let fileIntentContext = fileIntentAnalysis?.systemContext()
        let mergedHiddenContext = [hiddenSystemContext, fileIntentContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let userMsg = Message(role: .user, content: trimmed, attachmentID: attachmentID, imageDataURL: imageDataURL)
        let traceContext = TraceContext(conversationID: convId, messageID: userMsg.id)
        await LoggerService.shared.log(
            category: .conversation,
            event: "message_submit_started",
            traceContext: traceContext,
            status: .started,
            summary: "用户提交消息",
            metadata: [
                "input_length": .int(trimmed.count),
                "has_attachment": .bool(attachmentID != nil),
                "has_hidden_context": .bool(!mergedHiddenContext.isEmpty)
            ]
        )
        store.appendMessage(userMsg, to: convId)
        conversationRecoveryStatus = nil
        completedActivityDismissTask?.cancel()
        completedActivityStatus = nil

        if !mergedHiddenContext.isEmpty {
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
        await LoggerService.shared.log(
            category: .conversation,
            event: "message_submit_finished",
            traceContext: traceContext,
            status: .succeeded,
            summary: "消息已入队处理",
            metadata: [
                "conversation_message_count": .int(store.currentConversation?.messages.count ?? 0)
            ]
        )
        await requestTask?.value
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
        let usageSnapshot = ChatContextUsageEstimator.makeSnapshot(
            for: snapshot,
            modelName: modelName,
            maxTokens: maxTokens,
            availableSkills: availableSkills,
            activatedSkillMessages: activatedSkillMessages
        )
        contextUsageRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }

            guard let self, !Task.isCancelled else { return }
            let status = await Task.detached(priority: .utility) {
                ChatContextUsageEstimator.estimate(from: usageSnapshot)
            }.value
            guard let currentConversation = self.store.currentConversation,
                  currentConversation.id == conversationID else { return }
            guard !Task.isCancelled else { return }
            self.contextUsageStatus = status
        }
    }

    func deleteMessage(_ msgId: UUID) {
        store.deleteMessage(msgId)
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
        await requestTask?.value
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
        runningToolStatus = nil
        pendingResponseStatus = nil
        fileIntentStatus = nil
        conversationRecoveryStatus = nil
        completedActivityDismissTask?.cancel()
        completedActivityStatus = nil
        errorMessage = L10n.tr("chat.error.stopped")

        guard let convId = store.currentConversationId,
              let conv = store.conversations.first(where: { $0.id == convId }),
              let last = conv.messages.last else { return }

        if last.role == .assistant && last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.removeTrailingEmptyAssistantMessage(convId)
        } else {
            store.saveConversations()
        }
        scheduleContextUsageRefresh()
    }

    func respondToPendingApproval(_ approved: Bool) {
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
        pendingApproval = nil
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
            store.saveConversations()
        } else {
            errorMessage = outcome.message
        }
    }

    // MARK: - Private

    private func performChat(convId: UUID, traceContext: TraceContext? = nil, retryCount: Int = 0) async {
        let effectiveTraceContext = traceContext ?? currentTraceContext ?? TraceContext(conversationID: convId)
        currentTraceContext = effectiveTraceContext
        isLoading = true
        errorMessage = nil
        runningToolStatus = nil
        pendingResponseStatus = buildPendingResponseStatus()
        streamingResponseStatus = nil
        assistantActivityFallbackTask?.cancel()
        assistantActivityFallbackTask = nil
        lastAssistantDeltaAt = nil
        conversationRecoveryStatus = nil
        completedActivityDismissTask?.cancel()
        completedActivityStatus = nil
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

        guard let conv = store.conversations.first(where: { $0.id == convId }) else {
            isLoading = false
            return
        }

        do {
            try await orchestrator.run(
                conversation: conv,
                settings: store.settings,
                traceContext: effectiveTraceContext,
                requestApproval: { [weak self] preview in
                    guard let self else { return false }
                    return await self.requestApproval(preview)
                }
            ) { [weak self] event in
                guard let self else { return }
                await self.handleAgentEvent(event, convId: convId)
            }

            if storeHasDanglingEmptyAssistantMessage(in: convId) {
                throw AgentError.emptyAssistantResponse
            }

            // 发送成功，重置状态
            networkStatus = .connected
        } catch {
            if error is CancellationError {
                flushPendingAssistantDelta()
                networkStatus = .connected
                isLoading = false
                requestTask = nil
                approvalContinuation?.resume(returning: false)
                approvalContinuation = nil
                pendingApproval = nil
                runningToolStatus = nil
                pendingResponseStatus = nil
                streamingResponseStatus = nil
                assistantActivityFallbackTask?.cancel()
                assistantActivityFallbackTask = nil
                lastAssistantDeltaAt = nil
                fileIntentStatus = nil
                conversationRecoveryStatus = nil
                completedActivityDismissTask?.cancel()
                completedActivityStatus = nil
                store.removeTrailingEmptyAssistantMessage(convId)
                store.saveConversations()
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

            // 网络错误自动重试
            if isTimeoutRelated(error) {
                errorMessage = L10n.tr("chat.error.request_timed_out")
            } else if isNetworkRelated(error) {
                networkStatus = .reconnecting
                pendingResponseStatus = PendingResponseStatus(
                    title: L10n.tr("chat.waiting.retry.title"),
                    detail: L10n.tr("chat.waiting.retry.detail"),
                    context: nil,
                    badges: []
                )
                streamingResponseStatus = nil
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
            }
            store.removeTrailingEmptyAssistantMessage(convId)
        }

        flushPendingAssistantDelta()
        isLoading = false
        runningToolStatus = nil
        pendingResponseStatus = nil
        streamingResponseStatus = nil
        assistantActivityFallbackTask?.cancel()
        assistantActivityFallbackTask = nil
        lastAssistantDeltaAt = nil
        fileIntentStatus = nil
        requestTask = nil
        store.refreshConversationContext(convId)
        store.saveConversations()
        scheduleContextUsageRefresh()
        let turnDurationMs = elapsedMilliseconds(since: currentAssistantTurnStartedAt)
        if let errorMessage {
            let errorKind = logErrorKind(for: errorMessage)
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
                    extra: ["error_message": .string(errorMessage)]
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
        case .assistantTurnStarted:
            flushPendingAssistantDelta()
            if pendingResponseStatus == nil {
                pendingResponseStatus = PendingResponseStatus(
                    title: L10n.tr("chat.waiting.reply.title"),
                    detail: L10n.tr("chat.waiting.reply.detail"),
                    context: nil,
                    badges: []
                )
            }
            streamingResponseStatus = nil
            assistantActivityFallbackTask?.cancel()
            assistantActivityFallbackTask = nil
            lastAssistantDeltaAt = nil
            let assistantMsg = Message(role: .assistant, content: "")
            store.appendMessage(assistantMsg, to: convId)
            scheduleContextUsageRefresh()

        case .assistantDelta(let delta):
            if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingResponseStatus = nil
                lastAssistantDeltaAt = Date()
                if runningToolStatus == nil {
                    let intentContext = runningIntentContext()
                    let intentBadges = Array((fileIntentStatus?.badges ?? activeSkillRoutingStatus?.badges ?? []).prefix(3))
                    streamingResponseStatus = StreamingResponseStatus(
                        title: L10n.tr("chat_input.generating"),
                        detail: nil,
                        context: intentContext,
                        badges: intentBadges,
                        forceVisible: false
                    )
                }
                scheduleAssistantActivityFallback()
                fileIntentStatus = nil
                conversationRecoveryStatus = nil
                completedActivityDismissTask?.cancel()
            }
            queueAssistantDelta(delta, for: convId)

        case .assistantToolCalls(let toolCalls):
            flushPendingAssistantDelta()
            store.updateLastAssistantToolCalls(convId, toolCalls: toolCalls)
            scheduleContextUsageRefresh()

        case .toolStarted(let execution, let summary):
            flushPendingAssistantDelta()
            let intentContext = runningIntentContext()
            runningToolStatus = humanReadableRunningStatus(for: execution, intentContext: intentContext) ?? RunningToolStatus(
                id: execution.id,
                toolName: execution.name,
                title: summary,
                detail: L10n.tr("chat.tool.started"),
                phaseLabel: L10n.tr("chat.phase.plan"),
                badges: [],
                context: intentContext
            )
            pendingResponseStatus = nil
            streamingResponseStatus = nil
            assistantActivityFallbackTask?.cancel()
            assistantActivityFallbackTask = nil
            fileIntentStatus = nil
            conversationRecoveryStatus = nil
            completedActivityDismissTask?.cancel()

        case .toolProgress(let execution, let detail):
            if runningToolStatus?.id != execution.id {
                let intentContext = runningIntentContext()
                runningToolStatus = RunningToolStatus(
                    id: execution.id,
                    toolName: execution.name,
                    title: ChatStatusComposer.friendlyToolTitle(for: execution.name),
                    detail: detail,
                    phaseLabel: L10n.tr("chat.phase.running"),
                    badges: [],
                    context: intentContext
                )
            } else {
                runningToolStatus?.detail = detail
                runningToolStatus?.phaseLabel = L10n.tr("chat.phase.running")
            }

        case .toolCompleted(let execution, let result, let operation, let activatedSkillID, let previewImagePath, let previewImagePaths):
            flushPendingAssistantDelta()
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
            if runningToolStatus?.id == execution.id {
                runningToolStatus = nil
            }
            streamingResponseStatus = nil
            assistantActivityFallbackTask?.cancel()
            assistantActivityFallbackTask = nil
            completedActivityDismissTask?.cancel()
            completedActivityStatus = ChatStatusComposer.makeCompletedActivityStatus(
                for: execution,
                result: result,
                operation: operation,
                activatedSkillID: activatedSkillID,
                intentContext: runningIntentContext()
            )
            scheduleCompletedActivityDismiss()
            scheduleContextUsageRefresh()
        }
    }

    private func scheduleCompletedActivityDismiss() {
        completedActivityDismissTask?.cancel()
        completedActivityDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            await MainActor.run {
                self?.completedActivityStatus = nil
            }
        }
    }

    private func buildPendingResponseStatus() -> PendingResponseStatus {
        if let intent = fileIntentStatus {
            let combinedBadges = intent.badges.joined(separator: " ")
            let looksLikeLongformWriting =
                combinedBadges.contains("创建文件") ||
                combinedBadges.contains("重写文档") ||
                combinedBadges.localizedCaseInsensitiveContains(".md") ||
                combinedBadges.localizedCaseInsensitiveContains("markdown") ||
                combinedBadges.localizedCaseInsensitiveContains("txt")

            if looksLikeLongformWriting {
                return PendingResponseStatus(
                    title: "正在整理正文",
                    detail: intent.detail,
                    context: intent.reason,
                    badges: intent.badges
                )
            }

            return PendingResponseStatus(
                title: intent.title,
                detail: L10n.tr("chat.waiting.file.detail"),
                context: intent.reason,
                badges: intent.badges
            )
        }

        return PendingResponseStatus(
            title: L10n.tr("chat.waiting.reply.title"),
            detail: L10n.tr("chat.waiting.reply.detail"),
            context: nil,
            badges: []
        )
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

    private func scheduleAssistantActivityFallback() {
        assistantActivityFallbackTask?.cancel()
        let snapshot = lastAssistantDeltaAt
        assistantActivityFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.isLoading,
                      self.runningToolStatus == nil,
                      self.pendingResponseStatus == nil,
                      self.lastAssistantDeltaAt == snapshot,
                      self.hasVisibleStreamingAssistantContent else { return }

                self.streamingResponseStatus = StreamingResponseStatus(
                    title: L10n.tr("chat.waiting.continue.title"),
                    detail: L10n.tr("chat.waiting.continue.detail"),
                    context: nil,
                    badges: [],
                    forceVisible: true
                )
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
        return await withCheckedContinuation { continuation in
            approvalContinuation?.resume(returning: false)
            approvalContinuation = continuation
        }
    }

    private func buildFileIntentStatus(from analysis: FileIntentAnalysis) -> FileIntentStatus? {
        ChatStatusComposer.makeFileIntentStatus(from: analysis)
    }

    private func humanReadableRunningStatus(for execution: ToolExecutionRecord, intentContext: String?) -> RunningToolStatus? {
        ChatStatusComposer.makeRunningToolStatus(for: execution, intentContext: intentContext)
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
        return false
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
}

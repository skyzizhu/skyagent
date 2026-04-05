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
    @Published var conversationRecoveryStatus: ConversationRecoveryStatus?
    @Published var completedActivityStatus: ConversationActivityStatus?

    let store: ConversationStore
    private var llm: LLMService
    private let orchestrator: AgentOrchestrator
    private var requestTask: Task<Void, Never>?
    private var pendingAssistantDeltaBuffer = ""
    private var pendingAssistantDeltaConversationId: UUID?
    private var assistantDeltaFlushTask: Task<Void, Never>?
    private var assistantActivityFallbackTask: Task<Void, Never>?
    private var lastAssistantDeltaAt: Date?
    private var completedActivityDismissTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

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

    var contextUsageStatus: ContextUsageStatus? {
        guard let conversation = store.currentConversation else { return nil }
        return buildContextUsageStatus(for: conversation)
    }

    var currentActivityStatus: ConversationActivityStatus? {
        if let runningToolStatus {
            return ConversationActivityStatus(
                title: runningToolStatus.title,
                detail: runningToolStatus.detail,
                context: runningToolStatus.context,
                badges: runningToolStatus.badges,
                phaseLabel: runningToolStatus.phaseLabel,
                isBusy: true,
                iconName: iconName(for: runningToolStatus.toolName),
                accentStyle: accentStyle(for: runningToolStatus.toolName)
            )
        }

        if let streamingResponseStatus, streamingResponseStatus.forceVisible || !hasVisibleStreamingAssistantContent {
            return ConversationActivityStatus(
                title: streamingResponseStatus.title,
                detail: streamingResponseStatus.detail,
                context: streamingResponseStatus.context,
                badges: streamingResponseStatus.badges,
                phaseLabel: L10n.tr("chat.phase.running"),
                isBusy: true,
                iconName: "text.cursor",
                accentStyle: .thinking
            )
        }

        if let pendingResponseStatus {
            return ConversationActivityStatus(
                title: pendingResponseStatus.title,
                detail: pendingResponseStatus.detail,
                context: pendingResponseStatus.context,
                badges: pendingResponseStatus.badges,
                phaseLabel: L10n.tr("chat.phase.preparing"),
                isBusy: true,
                iconName: "brain.head.profile",
                accentStyle: .thinking
            )
        }

        if case .reconnecting = networkStatus {
            return ConversationActivityStatus(
                title: L10n.tr("chat.waiting.retry.title"),
                detail: L10n.tr("chat.waiting.retry.detail"),
                context: nil,
                badges: [],
                phaseLabel: L10n.tr("chat.phase.running"),
                isBusy: true,
                iconName: "arrow.triangle.2.circlepath",
                accentStyle: .network
            )
        }

        if let completedActivityStatus {
            return completedActivityStatus
        }

        return nil
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
        let contextState = conversation.contextState
        guard !contextState.isEmpty else { return nil }

        let title = contextState.taskSummary.isEmpty ? L10n.tr("context.overview.title") : contextState.taskSummary

        let target = contextState.activeTargets.first?.replacingOccurrences(of: "优先目标文件：", with: "")
        let constraint = contextState.activeConstraints.first
        let detailParts = [target, constraint].compactMap { $0 }.prefix(2)
        let detail = detailParts.isEmpty
            ? L10n.tr("context.overview.detail")
            : detailParts.joined(separator: " · ")

        let hasPreservedBackground = MemoryService.shared.loadSummary(convId: conversation.id) != nil || conversation.messages.count > 20
        let context = hasPreservedBackground ? L10n.tr("context.overview.background") : nil

        var badges: [String] = []
        if !contextState.activeTargets.isEmpty {
            badges.append(L10n.tr("context.badge.targets", String(contextState.activeTargets.count)))
        }
        if !contextState.activeConstraints.isEmpty {
            badges.append(L10n.tr("context.badge.constraints", String(contextState.activeConstraints.count)))
        }
        if !contextState.activeSkillNames.isEmpty {
            badges.append(contentsOf: contextState.activeSkillNames.prefix(2))
        }

        return ConversationContextOverviewStatus(
            title: title,
            detail: detail,
            context: context,
            badges: badges
        )
    }

    init(store: ConversationStore, llm: LLMService, orchestrator: AgentOrchestrator) {
        self.store = store
        self.llm = llm
        self.orchestrator = orchestrator
        refreshConversationRecoveryStatus()
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

    func sendMessage(_ text: String, hiddenSystemContext: String? = nil, attachmentID: String? = nil) async {
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
        completedActivityDismissTask?.cancel()
        completedActivityStatus = nil
        let fileIntentContext = fileIntentAnalysis?.systemContext()
        let mergedHiddenContext = [hiddenSystemContext, fileIntentContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let userMsg = Message(role: .user, content: trimmed)
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

        if store.userMessageCount(convId) == 1 {
            store.updateConversationTitle(convId, title: String(trimmed.prefix(30)))
        }

        preactivateLikelySkillsIfNeeded(convId: convId, userText: trimmed)

        requestTask?.cancel()
        requestTask = Task { [weak self] in
            await self?.performChat(convId: convId)
        }
        await requestTask?.value
    }

    private func buildContextUsageStatus(for conversation: Conversation) -> ContextUsageStatus {
        let availableSkills = SkillManager.shared.availableSkills
        let activatedSkillMessages = SkillManager.shared.activationMessages(for: conversation.activatedSkillIDs)
        var rawMessages = conversation.messages
        let isCompressed = MemoryService.shared.shouldCompress(messages: rawMessages)

        if isCompressed {
            rawMessages = MemoryService.shared.compress(messages: rawMessages, contextState: conversation.contextState)
        }

        var preparedMessages: [Message] = []
        if let summary = MemoryService.shared.loadSummary(convId: conversation.id), !summary.isEmpty {
            preparedMessages.append(Message(role: .system, content: "[本次对话的历史摘要]\n\(summary)", hiddenFromTranscript: true))
        }
        if let catalogPrompt = SkillManager.shared.buildCatalogPrompt(for: availableSkills) {
            preparedMessages.append(Message(role: .system, content: catalogPrompt, hiddenFromTranscript: true))
        }
        let contextPrompt = conversation.contextState.systemContext()
        if !contextPrompt.isEmpty {
            preparedMessages.append(Message(role: .system, content: contextPrompt, hiddenFromTranscript: true))
        }
        preparedMessages.append(contentsOf: activatedSkillMessages.map {
            Message(role: .system, content: $0, hiddenFromTranscript: true)
        })
        preparedMessages.append(contentsOf: rawMessages)

        let estimatedUsedTokens = preparedMessages.reduce(into: 0) { partialResult, message in
            partialResult += estimatedTokenCount(for: message.content)
            partialResult += message.toolCalls?.reduce(0, { $0 + estimatedTokenCount(for: $1.name) + estimatedTokenCount(for: $1.arguments) }) ?? 0
            partialResult += message.toolExecution.map { estimatedTokenCount(for: $0.name) + estimatedTokenCount(for: $0.arguments) } ?? 0
        }
        let estimatedBudgetTokens = estimatedContextBudget(for: store.settings.model, completionBudget: store.settings.maxTokens)
        return ContextUsageStatus(
            usedTokens: max(1, estimatedUsedTokens),
            budgetTokens: estimatedBudgetTokens,
            isCompressed: isCompressed
        )
    }

    private func estimatedContextBudget(for modelName: String, completionBudget: Int) -> Int {
        let lowercased = modelName.lowercased()
        if lowercased.contains("claude") {
            return 200_000
        }
        if lowercased.contains("gpt-4o") || lowercased.contains("gpt-4.1") || lowercased.contains("o3") || lowercased.contains("o4") {
            return 128_000
        }
        if lowercased.contains("gemini") {
            return 128_000
        }
        if lowercased.contains("deepseek") {
            return 64_000
        }
        if lowercased.contains("glm") {
            return 32_768
        }
        if lowercased.contains("qwen") {
            return 32_768
        }
        return max(8_192, completionBudget * 8)
    }

    private func estimatedTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var total = 0
        var latinRun = 0
        var digitRun = 0

        func flushLatinRun() {
            guard latinRun > 0 else { return }
            total += Int(ceil(Double(latinRun) / 4.0))
            latinRun = 0
        }

        func flushDigitRun() {
            guard digitRun > 0 else { return }
            total += Int(ceil(Double(digitRun) / 3.0))
            digitRun = 0
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushLatinRun()
                flushDigitRun()
                continue
            }

            if CharacterSet.decimalDigits.contains(scalar) {
                flushLatinRun()
                digitRun += 1
                continue
            }

            if CharacterSet.letters.contains(scalar), scalar.value < 128 {
                flushDigitRun()
                latinRun += 1
                continue
            }

            flushLatinRun()
            flushDigitRun()

            if isCJKScalar(scalar) {
                total += 1
            } else {
                total += 1
            }
        }

        flushLatinRun()
        flushDigitRun()
        return total
    }

    private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x3040...0x30FF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
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
        requestTask = Task { [weak self] in
            await self?.performChat(convId: convId)
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

    private func performChat(convId: UUID, retryCount: Int = 0) async {
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

        guard let conv = store.conversations.first(where: { $0.id == convId }) else {
            isLoading = false
            return
        }

        do {
            try await orchestrator.run(
                conversation: conv,
                settings: store.settings,
                requestApproval: { [weak self] preview in
                    guard let self else { return false }
                    return await self.requestApproval(preview)
                }
            ) { [weak self] event in
                guard let self else { return }
                await self.handleAgentEvent(event, convId: convId)
            }

            // 发送成功，重置状态
            networkStatus = .connected

            // 记忆处理
            if let updatedConv = store.conversations.first(where: { $0.id == convId }) {
                await MemoryService.shared.processConversationEnd(
                    convId: convId,
                    title: updatedConv.title,
                    messages: updatedConv.messages,
                    llmService: nil,
                    settings: store.settings
                )
            }
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
                    await performChat(convId: convId, retryCount: retryCount + 1)
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
                await performChat(convId: convId, retryCount: retryCount + 1)
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

        case .assistantDelta(let delta):
            if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingResponseStatus = nil
                lastAssistantDeltaAt = Date()
                if runningToolStatus == nil {
                    streamingResponseStatus = StreamingResponseStatus(
                        title: L10n.tr("chat_input.generating"),
                        detail: nil,
                        context: nil,
                        badges: [],
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
                    title: friendlyToolTitle(for: execution.name),
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
            setCompletedActivityStatus(for: execution, operation: operation)
        }
    }

    private func buildPendingResponseStatus() -> PendingResponseStatus {
        if let intent = fileIntentStatus {
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
    }

    private func requestApproval(_ preview: OperationPreview) async -> Bool {
        pendingApproval = preview
        return await withCheckedContinuation { continuation in
            approvalContinuation?.resume(returning: false)
            approvalContinuation = continuation
        }
    }

    private func buildFileIntentStatus(from analysis: FileIntentAnalysis) -> FileIntentStatus? {
        guard analysis.kind != .unknown else { return nil }

        let targetName = analysis.targetPath.map { ($0 as NSString).lastPathComponent }
            ?? analysis.referencedAttachmentID.map { L10n.tr("chat.intent.attachment_target", String($0.prefix(6))) }
            ?? L10n.tr("chat.intent.unspecified_target")
        let title = L10n.tr("chat.intent.title", targetName)

        let detail: String
        if let writeConfirmationQuestion = analysis.writeConfirmationQuestion, !writeConfirmationQuestion.isEmpty {
            detail = writeConfirmationQuestion
        } else if let clarificationQuestion = analysis.clarificationQuestion, !clarificationQuestion.isEmpty {
            detail = clarificationQuestion
        } else if let executionPlan = analysis.executionPlan, !executionPlan.isEmpty {
            detail = executionPlan
        } else {
            detail = analysis.summary
        }

        return FileIntentStatus(
            title: title,
            detail: detail,
            reason: explainabilityContext(for: analysis),
            badges: Array(analysis.badges.prefix(4))
        )
    }

    private func explainabilityContext(for analysis: FileIntentAnalysis) -> String? {
        if let writeConfirmationQuestion = analysis.writeConfirmationQuestion,
           !writeConfirmationQuestion.isEmpty {
            return L10n.tr("chat.intent.context.high_risk")
        }

        if let clarificationQuestion = analysis.clarificationQuestion,
           !clarificationQuestion.isEmpty {
            return L10n.tr("chat.intent.context.clarify")
        }

        var parts: [String] = []

        switch analysis.kind {
        case .buildWebPage:
            if analysis.suggestedTools.contains(.writeMultipleFiles) {
                parts.append(L10n.tr("chat.intent.context.web_batch_write"))
            }
        case .updateSpreadsheetCell, .appendSpreadsheetRows:
            parts.append(L10n.tr("chat.intent.context.spreadsheet_precise"))
        case .replaceDocumentSection, .insertDocumentSection:
            parts.append(L10n.tr("chat.intent.context.document_precise"))
        default:
            break
        }

        if let targetReason = analysis.targetReason, !targetReason.isEmpty {
            parts.append(targetReason)
        } else if let note = analysis.note, !note.isEmpty {
            parts.append(note)
        }

        let unique = Array(NSOrderedSet(array: parts)) as? [String] ?? parts
        return unique.isEmpty ? nil : unique.joined(separator: " ")
    }

    private func humanReadableRunningStatus(for execution: ToolExecutionRecord, intentContext: String?) -> RunningToolStatus? {
        guard let tool = ToolDefinition.ToolName(rawValue: execution.name),
              let params = decodeToolParams(execution.arguments, tool: tool) else {
            return nil
        }

        func fileName(from path: String?) -> String {
            guard let path, !path.isEmpty else { return L10n.tr("chat.file.untitled") }
            return (path as NSString).lastPathComponent
        }

        func countLabel(_ count: Int, key: String) -> String {
            L10n.tr(key, String(max(count, 0)))
        }

        func makeStatus(title: String, detail: String, badges: [String]) -> RunningToolStatus {
            RunningToolStatus(
                id: execution.id,
                toolName: execution.name,
                title: title,
                detail: detail,
                phaseLabel: L10n.tr("chat.phase.running"),
                badges: badges,
                context: intentContext
            )
        }

        switch tool {
        case .previewImage:
            let path = params["path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.preview_image.title", fileName(from: path)),
                detail: L10n.tr("chat.run.preview_image.detail"),
                badges: [L10n.tr("chat.badge.image_preview")]
            )
        case .writeFile:
            let path = params["path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.write_file.title", fileName(from: path)),
                detail: L10n.tr("chat.run.write_file.detail"),
                badges: [L10n.tr("chat.badge.file_write")]
            )
        case .writeMultipleFiles:
            let files = params["files"] as? [[String: Any]] ?? []
            let count = files.count
            let firstName = files.first.flatMap { $0["path"] as? String }.map(fileName(from:)) ?? L10n.tr("chat.file.untitled")
            let detail = count > 1
                ? L10n.tr("chat.run.write_multiple_files.detail_many", String(count), firstName)
                : L10n.tr("chat.run.write_multiple_files.detail_one", firstName)
            return makeStatus(
                title: count > 1 ? L10n.tr("chat.run.write_multiple_files.title", String(count)) : L10n.tr("chat.tool.write_file"),
                detail: detail,
                badges: [L10n.tr("chat.badge.file_write"), L10n.tr("chat.count.files", String(count))]
            )
        case .writeDOCX:
            let path = params["path"] as? String
            let title = (params["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return makeStatus(
                title: L10n.tr("chat.run.write_docx.title", fileName(from: path)),
                detail: title?.isEmpty == false ? L10n.tr("chat.run.write_docx.detail_with_title", title!) : L10n.tr("chat.run.write_docx.detail"),
                badges: [L10n.tr("chat.badge.word"), L10n.tr("chat.badge.full_write")]
            )
        case .writeXLSX:
            let path = params["path"] as? String
            let sheetCount = (params["sheets"] as? [[String: Any]])?.count ?? 0
            return makeStatus(
                title: L10n.tr("chat.run.write_xlsx.title", fileName(from: path)),
                detail: L10n.tr("chat.run.write_xlsx.detail", countLabel(sheetCount, key: "chat.count.sheets")),
                badges: [L10n.tr("chat.badge.excel"), L10n.tr("chat.badge.full_write")]
            )
        case .replaceDOCXSection:
            let path = params["path"] as? String
            let section = params["section_title"] as? String ?? L10n.tr("chat.word.untitled_section")
            return makeStatus(
                title: L10n.tr("chat.run.update_file.title", fileName(from: path)),
                detail: L10n.tr("chat.run.replace_docx_section.detail", section),
                badges: [L10n.tr("chat.badge.word"), L10n.tr("chat.badge.section_replace"), section]
            )
        case .insertDOCXSection:
            let path = params["path"] as? String
            let section = params["section_title"] as? String ?? L10n.tr("chat.word.untitled_section")
            let after = (params["after_section_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (after?.isEmpty == false)
                ? L10n.tr("chat.run.insert_docx_section.detail_after", after!, section)
                : L10n.tr("chat.run.insert_docx_section.detail_end", section)
            return makeStatus(
                title: L10n.tr("chat.run.update_file.title", fileName(from: path)),
                detail: detail,
                badges: [L10n.tr("chat.badge.word"), L10n.tr("chat.badge.section_insert"), section]
            )
        case .appendXLSXRows:
            let path = params["path"] as? String
            let sheet = params["sheet_name"] as? String ?? L10n.tr("chat.excel.untitled_sheet")
            let rows = (params["rows"] as? [[Any]])?.count ?? (params["rows"] as? [[String]])?.count ?? 0
            return makeStatus(
                title: L10n.tr("chat.run.update_file.title", fileName(from: path)),
                detail: L10n.tr("chat.run.append_xlsx_rows.detail", sheet, countLabel(rows, key: "chat.count.rows")),
                badges: [L10n.tr("chat.badge.excel"), sheet, countLabel(rows, key: "chat.count.rows")]
            )
        case .updateXLSXCell:
            let path = params["path"] as? String
            let sheet = params["sheet_name"] as? String ?? L10n.tr("chat.excel.untitled_sheet")
            let cell = params["cell"] as? String ?? L10n.tr("chat.excel.unknown_cell")
            let value = params["value"] as? String ?? ""
            let preview = value.count > 24 ? String(value.prefix(24)) + "…" : value
            return makeStatus(
                title: L10n.tr("chat.run.update_file.title", fileName(from: path)),
                detail: L10n.tr("chat.run.update_xlsx_cell.detail", sheet, cell, preview),
                badges: [L10n.tr("chat.badge.excel"), sheet, cell]
            )
        case .exportPDF, .exportDOCX, .exportXLSX:
            let path = params["path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.export.title", fileName(from: path)),
                detail: L10n.tr("chat.run.export.detail"),
                badges: [L10n.tr("chat.badge.file_export")]
            )
        case .importFile, .importDirectory:
            let destination = params["destination_path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.import.title", fileName(from: destination)),
                detail: L10n.tr("chat.run.import.detail"),
                badges: [L10n.tr("chat.badge.file_import")]
            )
        default:
            return nil
        }
    }

    private func decodeToolParams(_ arguments: String, tool: ToolDefinition.ToolName) -> [String: Any]? {
        ToolArgumentParser.parse(arguments: arguments, for: tool)
    }

    private func runningIntentContext() -> String? {
        if let reason = fileIntentStatus?.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            return reason
        }
        if let title = fileIntentStatus?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return nil
    }

    func refreshConversationRecoveryStatus() {
        guard let conversation = store.currentConversation else {
            conversationRecoveryStatus = nil
            return
        }

        let summary = MemoryService.shared.loadSummary(convId: conversation.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (summary?.isEmpty == false)
            ? summary!
            : (conversation.contextState.taskSummary.isEmpty ? L10n.tr("context.recovery.detail") : conversation.contextState.taskSummary)

        var badges: [String] = []
        if !conversation.contextState.activeTargets.isEmpty {
            badges.append(L10n.tr("context.badge.targets", String(conversation.contextState.activeTargets.count)))
        }
        if !conversation.contextState.activeConstraints.isEmpty {
            badges.append(L10n.tr("context.badge.constraints", String(conversation.contextState.activeConstraints.count)))
        }
        if !conversation.contextState.activeSkillNames.isEmpty {
            badges.append(contentsOf: conversation.contextState.activeSkillNames.prefix(2))
        }

        let contextSummaryParts = [
            !conversation.contextState.activeTargets.isEmpty ? L10n.tr("context.recovery.targets") : nil,
            !conversation.contextState.activeConstraints.isEmpty ? L10n.tr("context.recovery.constraints") : nil,
            !conversation.contextState.activeSkillNames.isEmpty ? L10n.tr("context.recovery.skills") : nil
        ].compactMap { $0 }

        conversationRecoveryStatus = ConversationRecoveryStatus(
            title: L10n.tr("context.recovery.title", conversation.title),
            detail: detail,
            context: contextSummaryParts.isEmpty ? nil : contextSummaryParts.joined(separator: " · "),
            badges: badges
        )
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

    private func preactivateLikelySkillsIfNeeded(convId: UUID, userText: String) {
        guard let conv = store.conversations.first(where: { $0.id == convId }) else { return }
        let matches = SkillManager.shared.likelyTriggeredSkills(in: userText, excluding: conv.activatedSkillIDs)
        guard !matches.isEmpty else { return }

        for skill in matches.prefix(2) {
            store.markSkillActivated(skill.id, in: convId)
        }
    }

    private func friendlyToolTitle(for toolName: String) -> String {
        switch ToolDefinition.ToolName(rawValue: toolName) {
        case .activateSkill:
            return L10n.tr("chat.tool.activate_skill")
        case .installSkill:
            return L10n.tr("chat.tool.install_skill")
        case .readSkillResource:
            return L10n.tr("chat.tool.read_skill_resource")
        case .runSkillScript:
            return L10n.tr("chat.tool.run_skill_script")
        case .readUploadedAttachment:
            return L10n.tr("chat.tool.read_uploaded_attachment")
        case .previewImage:
            return L10n.tr("chat.tool.preview_image")
        case .readFile:
            return L10n.tr("chat.tool.read_file")
        case .writeFile:
            return L10n.tr("chat.tool.write_file")
        case .writeMultipleFiles:
            return L10n.tr("chat.tool.write_multiple_files")
        case .writeDOCX:
            return L10n.tr("chat.tool.write_docx")
        case .writeXLSX:
            return L10n.tr("chat.tool.write_xlsx")
        case .replaceDOCXSection:
            return L10n.tr("chat.tool.replace_docx_section")
        case .insertDOCXSection:
            return L10n.tr("chat.tool.insert_docx_section")
        case .appendXLSXRows:
            return L10n.tr("chat.tool.append_xlsx_rows")
        case .updateXLSXCell:
            return L10n.tr("chat.tool.update_xlsx_cell")
        case .listFiles:
            return L10n.tr("chat.tool.list_files")
        case .webFetch:
            return L10n.tr("chat.tool.web_fetch")
        case .importFile, .importDirectory:
            return L10n.tr("chat.tool.import_file")
        case .exportFile, .exportDirectory:
            return L10n.tr("chat.tool.export_file")
        case .exportPDF:
            return L10n.tr("chat.tool.export_pdf")
        case .exportDOCX:
            return L10n.tr("chat.tool.export_docx")
        case .exportXLSX:
            return L10n.tr("chat.tool.export_xlsx")
        case .importFileContent:
            return L10n.tr("chat.tool.import_file_content")
        case .listExternalFiles:
            return L10n.tr("chat.tool.list_external_files")
        case .shell:
            return L10n.tr("chat.tool.shell")
        case .none:
            return L10n.tr("chat.tool.default")
        }
    }

    private func setCompletedActivityStatus(for execution: ToolExecutionRecord, operation: FileOperationRecord?) {
        let title: String
        let detail: String?

        if let operation {
            title = L10n.tr("chat.activity.completed")
            detail = operation.summary.isEmpty ? operation.title : operation.summary
        } else {
            title = L10n.tr("chat.activity.completed")
            detail = friendlyToolTitle(for: execution.name)
        }

        completedActivityStatus = ConversationActivityStatus(
            title: title,
            detail: detail,
            context: nil,
            badges: [friendlyToolTitle(for: execution.name)],
            phaseLabel: L10n.tr("chat.phase.done"),
            isBusy: false,
            iconName: "checkmark.circle.fill",
            accentStyle: .neutral
        )

        completedActivityDismissTask?.cancel()
        let status = completedActivityStatus
        completedActivityDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.completedActivityStatus == status {
                withAnimation(.easeOut(duration: 0.22)) {
                    self.completedActivityStatus = nil
                }
            }
        }
    }

    private func iconName(for toolName: String) -> String {
        switch ToolDefinition.ToolName(rawValue: toolName) {
        case .activateSkill:
            return "wand.and.stars"
        case .installSkill:
            return "square.and.arrow.down"
        case .readSkillResource, .readUploadedAttachment, .readFile, .importFileContent:
            return "doc.text.magnifyingglass"
        case .previewImage:
            return "photo"
        case .runSkillScript:
            return "terminal"
        case .writeFile, .writeMultipleFiles:
            return "square.and.pencil"
        case .writeDOCX, .replaceDOCXSection, .insertDOCXSection:
            return "doc.richtext"
        case .writeXLSX, .appendXLSXRows, .updateXLSXCell:
            return "tablecells"
        case .listFiles, .listExternalFiles:
            return "folder"
        case .webFetch:
            return "globe"
        case .importFile, .importDirectory:
            return "square.and.arrow.down.on.square"
        case .exportFile, .exportDirectory, .exportPDF, .exportDOCX, .exportXLSX:
            return "square.and.arrow.up"
        case .shell:
            return "chevron.left.forwardslash.chevron.right"
        case .none:
            return "gearshape.2"
        }
    }

    private func accentStyle(for toolName: String) -> ActivityAccentStyle {
        switch ToolDefinition.ToolName(rawValue: toolName) {
        case .readSkillResource, .readUploadedAttachment, .readFile, .importFileContent, .listFiles, .listExternalFiles, .webFetch, .previewImage:
            return .reading
        case .writeFile, .writeMultipleFiles, .writeDOCX, .writeXLSX, .replaceDOCXSection, .insertDOCXSection, .appendXLSXRows, .updateXLSXCell, .exportFile, .exportDirectory, .exportPDF, .exportDOCX, .exportXLSX:
            return .writing
        case .activateSkill, .installSkill, .runSkillScript:
            return .skill
        case .shell:
            return .shell
        case .importFile, .importDirectory:
            return .reading
        case .none:
            return .neutral
        }
    }
}

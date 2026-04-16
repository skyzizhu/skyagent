import Foundation
import Combine

@MainActor
final class ConversationActivityViewModel: ObservableObject {
    @Published private(set) var displayedStates: [ConversationActivityState] = []

    private enum Mode {
        case idle
        case thinking
        case processing
        case executing
        case approval
        case retrying
        case failed
    }

    private let minimumExecutionVisibility: TimeInterval = 0.45

    private var mode: Mode = .idle
    private var state: ConversationActivityState?
    private var activeExecutionID: String?
    private var activeExecutionStartedAt: Date?

    private(set) var hasExecutionTrail = false

    var currentState: ConversationActivityState? {
        state
    }

    func beginThinking(intentContext: String?, badges: [String]) {
        guard !hasExecutionTrail else { return }

        mode = .thinking
        activeExecutionID = nil
        activeExecutionStartedAt = nil
        state = ConversationActivityFactory.thinking(intentContext: intentContext, badges: badges)
        publish()
    }

    func noteAssistantStreaming() {
        guard mode == .thinking || mode == .processing else { return }
        clearCurrentState(preserveExecutionTrail: true)
    }

    func showProcessing() {
        guard mode != .executing,
              mode != .approval,
              mode != .retrying,
              mode != .failed else { return }

        mode = .processing
        activeExecutionID = nil
        activeExecutionStartedAt = nil
        state = ConversationActivityFactory.processing()
        publish()
    }

    func showApproval(_ preview: OperationPreview) {
        mode = .approval
        state = ConversationActivityFactory.waitingForApproval(preview)
        publish()
    }

    func showRetrying(detail: String?) {
        mode = .retrying
        state = ConversationActivityFactory.retrying(detail: detail)
        publish()
    }

    func showFailure(_ message: String) {
        mode = .failed
        activeExecutionID = nil
        activeExecutionStartedAt = nil
        state = ConversationActivityFactory.failed(message: message)
        publish()
    }

    func showExecution(for execution: ToolExecutionRecord, resetVisibilityWindow: Bool = false) {
        hasExecutionTrail = true
        let startedAt: Date
        if resetVisibilityWindow || activeExecutionID != execution.id {
            startedAt = Date()
        } else {
            startedAt = activeExecutionStartedAt ?? Date()
        }

        activeExecutionID = execution.id
        activeExecutionStartedAt = startedAt
        mode = .executing
        state = ConversationActivityFactory.execution(for: execution, startedAt: startedAt)
        publish()
    }

    func completeExecution(for execution: ToolExecutionRecord) {
        guard activeExecutionID == execution.id else { return }

        clearCurrentState()
    }

    func ensureMinimumExecutionVisibility(for executionID: String) async {
        guard activeExecutionID == executionID,
              let startedAt = activeExecutionStartedAt else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = minimumExecutionVisibility - elapsed
        guard remaining > 0 else { return }

        let nanoseconds = UInt64(remaining * 1_000_000_000)
        if nanoseconds > 0 {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    func clearApproval() {
        guard mode == .approval else { return }
        clearCurrentState()
    }

    func clearTransientState() {
        guard mode != .failed else { return }
        clearCurrentState()
    }

    func reset() {
        hasExecutionTrail = false
        clearCurrentState(preserveExecutionTrail: false)
    }

    private func clearCurrentState(preserveExecutionTrail: Bool = true) {
        mode = .idle
        state = nil
        activeExecutionID = nil
        activeExecutionStartedAt = nil
        if !preserveExecutionTrail {
            hasExecutionTrail = false
        }
        publish()
    }

    private func publish() {
        displayedStates = state.map { [$0] } ?? []
    }
}

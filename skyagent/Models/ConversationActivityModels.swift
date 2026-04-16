import Foundation

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

struct ContextUsageStatus: Equatable {
    let usedTokens: Int
    let budgetTokens: Int
    let isCompressed: Bool
}

enum ConversationWaitPhase: Equatable {
    case thinking
    case processing
    case executing
    case waitingForApproval
    case retrying
    case failed
}

enum ConversationActivityKind: Equatable {
    case assistant
    case tool
    case file
    case skill
    case mcp
    case shell
    case network
    case approval
}

enum ConversationActivityAccent: Equatable {
    case neutral
    case thinking
    case file
    case skill
    case network
    case shell
    case approval
    case warning
    case error
}

struct ConversationActivityState: Identifiable, Equatable {
    let id: String
    let phase: ConversationWaitPhase
    let kind: ConversationActivityKind
    let title: String
    let detail: String?
    let subject: String?
    let context: String?
    let badges: [String]
    let iconName: String
    let accent: ConversationActivityAccent
    let startedAt: Date
    let emittedAt: Date
    let showsElapsedTime: Bool
}

extension ConversationActivityState {
    func elapsedSeconds(at now: Date = Date()) -> Int {
        max(1, Int(now.timeIntervalSince(startedAt)))
    }

    func elapsedLabel(at now: Date = Date()) -> String {
        L10n.tr("chat.waiting.elapsed.seconds", String(elapsedSeconds(at: now)))
    }

    func presentationDetail(at _: Date = Date()) -> String? {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        switch phase {
        case .thinking, .processing:
            return nil
        case .executing, .failed, .waitingForApproval, .retrying:
            return trimmedDetail
        }
    }

    var presentationContext: String? {
        context?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var presentationBadges: [String] {
        Array(badges.prefix(3))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import Foundation

enum ConversationActivityFactory {
    static func thinking(intentContext: String?, badges: [String]) -> ConversationActivityState {
        ConversationActivityState(
            id: "assistant-thinking",
            phase: .thinking,
            kind: .assistant,
            title: L10n.tr("chat.waiting.reply.title"),
            detail: nil,
            subject: nil,
            context: intentContext,
            badges: Array(badges.prefix(3)),
            iconName: "brain.head.profile",
            accent: .thinking,
            startedAt: Date(),
            emittedAt: Date(),
            showsElapsedTime: true
        )
    }

    static func retrying(detail: String?) -> ConversationActivityState {
        ConversationActivityState(
            id: "assistant-retrying",
            phase: .retrying,
            kind: .network,
            title: L10n.tr("chat.waiting.retry.title"),
            detail: detail ?? L10n.tr("chat.waiting.retry.detail"),
            subject: nil,
            context: nil,
            badges: [],
            iconName: "arrow.triangle.2.circlepath",
            accent: .network,
            startedAt: Date(),
            emittedAt: Date(),
            showsElapsedTime: true
        )
    }

    static func processing() -> ConversationActivityState {
        ConversationActivityState(
            id: "assistant-processing",
            phase: .processing,
            kind: .assistant,
            title: L10n.tr("chat.status.processing"),
            detail: nil,
            subject: nil,
            context: nil,
            badges: [],
            iconName: "ellipsis.circle",
            accent: .thinking,
            startedAt: Date(),
            emittedAt: Date(),
            showsElapsedTime: false
        )
    }

    static func failed(message: String) -> ConversationActivityState {
        ConversationActivityState(
            id: "assistant-failed",
            phase: .failed,
            kind: .assistant,
            title: L10n.tr("chat.phase.failed"),
            detail: message,
            subject: nil,
            context: nil,
            badges: [],
            iconName: "exclamationmark.triangle",
            accent: .error,
            startedAt: Date(),
            emittedAt: Date(),
            showsElapsedTime: false
        )
    }

    static func waitingForApproval(_ preview: OperationPreview) -> ConversationActivityState {
        let title = ChatStatusComposer.friendlyToolTitle(for: preview.toolName)
        let detail = preview.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.tr("chat.phase.awaiting_approval")
            : preview.summary
        return ConversationActivityState(
            id: "approval-\(preview.id)",
            phase: .waitingForApproval,
            kind: .approval,
            title: title,
            detail: detail,
            subject: nil,
            context: nil,
            badges: [preview.isDestructive ? L10n.tr("chat.approval.risk.high") : L10n.tr("chat.approval.risk.normal")],
            iconName: "checkmark.shield",
            accent: .approval,
            startedAt: Date(),
            emittedAt: Date(),
            showsElapsedTime: false
        )
    }

    static func execution(
        for execution: ToolExecutionRecord,
        startedAt: Date
    ) -> ConversationActivityState {
        let kind = kind(for: execution.name)
        let subject = ChatStatusComposer.friendlyToolTitle(for: execution.name)

        return ConversationActivityState(
            id: "execution-\(execution.id)",
            phase: .executing,
            kind: kind,
            title: title(for: kind),
            detail: subject,
            subject: subject,
            context: nil,
            badges: [],
            iconName: iconName(for: kind),
            accent: accent(for: kind),
            startedAt: startedAt,
            emittedAt: Date(),
            showsElapsedTime: true
        )
    }

    private static func title(for kind: ConversationActivityKind) -> String {
        switch kind {
        case .mcp:
            return L10n.tr("chat.waiting.execution.mcp")
        case .skill:
            return L10n.tr("chat.waiting.execution.skill")
        case .shell:
            return L10n.tr("chat.waiting.execution.shell")
        case .file:
            return L10n.tr("chat.waiting.execution.file")
        case .tool:
            return L10n.tr("chat.waiting.execution.tool")
        case .assistant, .network, .approval:
            return L10n.tr("chat.waiting.execution.tool")
        }
    }

    private static func kind(for toolName: String) -> ConversationActivityKind {
        if toolName.hasPrefix("mcp__") || toolName.hasPrefix("mcp_") {
            return .mcp
        }

        switch ToolDefinition.ToolName(rawValue: toolName) {
        case .runSkillScript, .activateSkill, .installSkill, .readSkillResource:
            return .skill
        case .shell:
            return .shell
        case .readFile, .writeFile, .writeAssistantContentToFile, .writeMultipleFiles,
             .movePaths, .deletePaths, .writeDOCX, .writeXLSX, .replaceDOCXSection,
             .insertDOCXSection, .appendXLSXRows, .updateXLSXCell, .listFiles,
             .importFile, .importDirectory, .exportFile, .exportDirectory, .exportPDF,
             .exportDOCX, .exportXLSX, .importFileContent, .listExternalFiles,
             .readUploadedAttachment, .previewImage:
            return .file
        default:
            return .tool
        }
    }

    private static func iconName(for kind: ConversationActivityKind) -> String {
        switch kind {
        case .assistant:
            return "brain.head.profile"
        case .file:
            return "doc"
        case .skill:
            return "sparkles"
        case .mcp:
            return "point.3.connected.trianglepath.dotted"
        case .shell:
            return "terminal"
        case .network:
            return "network"
        case .approval:
            return "checkmark.shield"
        case .tool:
            return "hammer"
        }
    }

    private static func accent(for kind: ConversationActivityKind) -> ConversationActivityAccent {
        switch kind {
        case .assistant:
            return .thinking
        case .file:
            return .file
        case .skill:
            return .skill
        case .mcp:
            return .network
        case .shell:
            return .shell
        case .network:
            return .network
        case .approval:
            return .approval
        case .tool:
            return .warning
        }
    }
}

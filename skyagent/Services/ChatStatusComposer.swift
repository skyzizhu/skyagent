import Foundation

enum ChatStatusComposer {
    static func formattedMCPTitle(serverName: String, actionName: String) -> String {
        let trimmedServerName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedActionName = actionName.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedServerName.isEmpty && trimmedActionName.isEmpty {
            return "MCP"
        }
        if trimmedServerName.isEmpty {
            return "MCP · \(trimmedActionName)"
        }
        if trimmedActionName.isEmpty {
            return "MCP · \(trimmedServerName)"
        }
        return "MCP · \(trimmedServerName) · \(trimmedActionName)"
    }

    static func makeConversationContextOverviewStatus(for conversation: Conversation) -> ConversationContextOverviewStatus? {
        let contextState = conversation.contextState
        guard !contextState.isEmpty else { return nil }

        let title = contextState.taskSummary.isEmpty ? L10n.tr("context.overview.title") : contextState.taskSummary
        let target = contextState.activeTargets.first?.replacingOccurrences(of: "优先目标文件：", with: "")
        let constraint = contextState.activeConstraints.first
        let detailParts = [target, constraint].compactMap { $0 }.prefix(2)
        let detail = detailParts.isEmpty
            ? L10n.tr("context.overview.detail")
            : detailParts.joined(separator: " · ")

        let hasPreservedBackground =
            MemoryService.shared.loadSummary(
                convId: conversation.id,
                segmentStartedAt: conversation.contextState.segmentStartedAt
            ) != nil ||
            conversation.messages.count > 20
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

    static func makeConversationRecoveryStatus(for conversation: Conversation) -> ConversationRecoveryStatus {
        let summary = MemoryService.shared.loadSummary(
            convId: conversation.id,
            segmentStartedAt: conversation.contextState.segmentStartedAt
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if let summary, !summary.isEmpty {
            detail = summary
        } else {
            detail = conversation.contextState.taskSummary.isEmpty
                ? L10n.tr("context.recovery.detail")
                : conversation.contextState.taskSummary
        }

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

        return ConversationRecoveryStatus(
            title: L10n.tr("context.recovery.title", conversation.title),
            detail: detail,
            context: contextSummaryParts.isEmpty ? nil : contextSummaryParts.joined(separator: " · "),
            badges: badges
        )
    }

    static func makeFileIntentStatus(from analysis: FileIntentAnalysis) -> FileIntentStatus? {
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

    static func makeSkillRoutingStatus(from match: SkillMatchCandidate, conversationID: UUID) -> SkillRoutingStatus {
        let preferredName = match.skill.displayName ?? match.skill.name
        let title = L10n.tr("chat.skill_route.title", preferredName)

        let badges = Array(
            ([L10n.tr("chat.skill_route.badge")] + match.matchedSignals.prefix(2).map {
                matchSourceLabel(for: $0.source)
            }).prefix(3)
        )

        let detail: String
        if let first = match.matchedSignals.first {
            detail = L10n.tr("chat.skill_route.detail", matchSourceLabel(for: first.source))
        } else {
            detail = L10n.tr("chat.skill_route.detail_fallback")
        }

        let reason = skillRoutingReason(for: match)

        return SkillRoutingStatus(
            conversationID: conversationID,
            title: title,
            detail: detail,
            reason: reason,
            badges: badges
        )
    }

    static func runningIntentContext(fileIntentStatus: FileIntentStatus?, skillRoutingStatus: SkillRoutingStatus?) -> String? {
        if let reason = fileIntentStatus?.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            return reason
        }
        if let reason = skillRoutingStatus?.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            return reason
        }
        if let title = fileIntentStatus?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let title = skillRoutingStatus?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return nil
    }

    static func friendlyToolTitle(for toolName: String) -> String {
        if toolName.hasPrefix("mcp__") {
            if let descriptor = MCPServerManager.shared.toolDescriptor(named: toolName) {
                let actionName = descriptor.toolTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? descriptor.toolName
                return formattedMCPTitle(serverName: descriptor.serverName, actionName: actionName)
            }
            return "MCP"
        }

        switch toolName {
        case "mcp_list_resources":
            return "MCP resources"
        case "mcp_read_resource":
            return "MCP resource"
        case "mcp_list_prompts":
            return "MCP prompts"
        case "mcp_get_prompt":
            return "MCP prompt"
        default:
            break
        }

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
        case .writeAssistantContentToFile:
            return L10n.tr("chat.tool.write_file")
        case .writeMultipleFiles:
            return L10n.tr("chat.tool.write_multiple_files")
        case .movePaths:
            return L10n.tr("chat.tool.move_paths")
        case .deletePaths:
            return L10n.tr("chat.tool.delete_paths")
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
        case .webSearch:
            return L10n.tr("chat.tool.web_search")
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

    private static func explainabilityContext(for analysis: FileIntentAnalysis) -> String? {
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

    private static func skillRoutingReason(for match: SkillMatchCandidate) -> String? {
        let matched = match.matchedSignals.prefix(3).map {
            "\(matchSourceLabel(for: $0.source)): \($0.phrase)"
        }
        let blocked = match.blockedSignals.prefix(2).map {
            "\(matchSourceLabel(for: $0.source)): \($0.phrase)"
        }

        var parts: [String] = []
        if !matched.isEmpty {
            parts.append(L10n.tr("chat.skill_route.reason.matched", matched.joined(separator: " · ")))
        }
        if !blocked.isEmpty {
            parts.append(L10n.tr("chat.skill_route.reason.blocked", blocked.joined(separator: " · ")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func matchSourceLabel(for source: SkillMatchSource) -> String {
        switch source {
        case .name:
            return L10n.tr("chat.skill_route.source.name")
        case .alias:
            return L10n.tr("chat.skill_route.source.alias")
        case .displayName:
            return L10n.tr("chat.skill_route.source.display_name")
        case .description:
            return L10n.tr("chat.skill_route.source.description")
        case .shortDescription:
            return L10n.tr("chat.skill_route.source.short_description")
        case .defaultPrompt:
            return L10n.tr("chat.skill_route.source.default_prompt")
        case .triggerHint:
            return L10n.tr("chat.skill_route.source.trigger_hint")
        case .antiTriggerHint:
            return L10n.tr("chat.skill_route.source.anti_trigger")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

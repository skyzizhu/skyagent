import Foundation

enum ChatStatusComposer {
    static func makeCurrentActivityStatus(
        pendingApproval: OperationPreview?,
        runningToolStatus: RunningToolStatus?,
        streamingResponseStatus: StreamingResponseStatus?,
        pendingResponseStatus: PendingResponseStatus?,
        isReconnecting: Bool,
        hasVisibleStreamingAssistantContent: Bool,
        errorMessage: String?
    ) -> ConversationActivityStatus? {
        if let pendingApproval {
            return makePendingApprovalStatus(for: pendingApproval)
        }

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

        if let streamingResponseStatus {
            let hasSupplementaryInfo =
                !(streamingResponseStatus.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                !(streamingResponseStatus.context?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                !streamingResponseStatus.badges.isEmpty
            if hasVisibleStreamingAssistantContent && !streamingResponseStatus.forceVisible && !hasSupplementaryInfo {
                return nil
            }
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

        if isReconnecting {
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

        if let errorMessage = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !errorMessage.isEmpty {
            return makeErrorActivityStatus(message: errorMessage)
        }

        return nil
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

    static func makeCompletedActivityStatus(
        for execution: ToolExecutionRecord,
        result: String,
        operation: FileOperationRecord?,
        activatedSkillID: String?,
        intentContext: String?
    ) -> ConversationActivityStatus? {
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = operation?.summary.nilIfEmpty ?? summarizedResult(trimmedResult)
        let completionState = completionState(for: trimmedResult)

        var badges: [String] = []
        if execution.name.hasPrefix("mcp__") || execution.name.hasPrefix("mcp_") {
            badges.append("MCP")
        }
        if activatedSkillID != nil || execution.name == ToolDefinition.ToolName.activateSkill.rawValue {
            badges.append("Skill")
        }
        if let operation {
            badges.append(operation.toolName)
        }
        badges.append(badgeLabel(for: completionState))

        return ConversationActivityStatus(
            title: completedTitle(for: execution, operation: operation),
            detail: detail,
            context: intentContext,
            badges: Array(NSOrderedSet(array: badges).array as? [String] ?? badges).prefix(3).map { $0 },
            phaseLabel: phaseLabel(for: completionState),
            isBusy: false,
            iconName: completedIconName(for: execution.name, state: completionState),
            accentStyle: completedAccentStyle(for: execution.name, state: completionState)
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

    static func makeRunningToolStatus(for execution: ToolExecutionRecord, intentContext: String?) -> RunningToolStatus? {
        if let mcpStatus = makeMCPRunningToolStatus(for: execution, intentContext: intentContext) {
            return mcpStatus
        }

        guard let tool = ToolDefinition.ToolName(rawValue: execution.name),
              let params = ToolArgumentParser.parse(arguments: execution.arguments, for: tool) else {
            return nil
        }

        func fileName(from path: String?) -> String {
            guard let path, !path.isEmpty else { return L10n.tr("chat.file.untitled") }
            return (path as NSString).lastPathComponent
        }

        func countLabel(_ count: Int, key: String) -> String {
            L10n.tr(key, String(max(count, 0)))
        }

        func compactPath(_ path: String?) -> String {
            guard let path, !path.isEmpty else { return L10n.tr("chat.file.untitled") }
            return path.count > 44 ? "…" + path.suffix(43) : path
        }

        func compactURL(_ value: String?) -> String {
            guard
                let value,
                let url = URL(string: value),
                let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                !host.isEmpty
            else {
                return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "URL"
            }
            return host
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
        case .activateSkill:
            let skillName = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return makeStatus(
                title: skillName?.isEmpty == false ? skillName! : L10n.tr("chat.tool.activate_skill"),
                detail: L10n.tr("chat.tool.activate_skill"),
                badges: ["Skill"]
            )
        case .installSkill:
            let skillName = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let repo = (params["repo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (params["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = skillName?.isEmpty == false ? skillName! : (repo?.isEmpty == false ? repo! : compactURL(url))
            return makeStatus(
                title: source,
                detail: L10n.tr("chat.tool.install_skill"),
                badges: ["Skill", "Install"]
            )
        case .readSkillResource:
            let skillName = (params["skill_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = (params["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return makeStatus(
                title: path?.isEmpty == false ? compactPath(path) : L10n.tr("chat.tool.read_skill_resource"),
                detail: skillName?.isEmpty == false ? skillName! : L10n.tr("chat.tool.read_skill_resource"),
                badges: ["Skill", "Resource"]
            )
        case .runSkillScript:
            let skillName = (params["skill_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = (params["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let args = (params["args"] as? [String]) ?? []
            var badges = ["Skill", "Script"]
            if !args.isEmpty {
                badges.append("args \(args.count)")
            }
            return makeStatus(
                title: path?.isEmpty == false ? compactPath(path) : L10n.tr("chat.tool.run_skill_script"),
                detail: skillName?.isEmpty == false ? skillName! : L10n.tr("chat.tool.run_skill_script"),
                badges: Array(badges.prefix(3))
            )
        case .readUploadedAttachment:
            let attachmentID = (params["attachment_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title: String
            if let page = params["page_number"] as? Int {
                title = "第 \(page) 页"
            } else if let sheetName = (params["sheet_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sheetName.isEmpty {
                title = sheetName
            } else if let segmentTitle = (params["segment_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !segmentTitle.isEmpty {
                title = segmentTitle
            } else if let chunkIndex = params["chunk_index"] as? Int {
                title = "Chunk \(chunkIndex)"
            } else {
                title = L10n.tr("chat.tool.read_uploaded_attachment")
            }
            return makeStatus(
                title: title,
                detail: attachmentID.isEmpty ? L10n.tr("chat.tool.read_uploaded_attachment") : L10n.tr("chat.intent.attachment_target", String(attachmentID.prefix(6))),
                badges: ["Attachment", "Read"]
            )
        case .previewImage:
            let path = params["path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.preview_image.title", fileName(from: path)),
                detail: L10n.tr("chat.run.preview_image.detail"),
                badges: [L10n.tr("chat.badge.image_preview")]
            )
        case .readFile:
            let path = params["path"] as? String
            return makeStatus(
                title: fileName(from: path),
                detail: compactPath(path),
                badges: ["Read", "File"]
            )
        case .writeFile:
            let path = params["path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.write_file.title", fileName(from: path)),
                detail: L10n.tr("chat.run.write_file.detail"),
                badges: [L10n.tr("chat.badge.file_write")]
            )
        case .writeAssistantContentToFile:
            let path = params["path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.write_file.title", fileName(from: path)),
                detail: "将把本轮已生成的正文直接写入这个文件",
                badges: [L10n.tr("chat.badge.file_write"), "Draft"]
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
        case .movePaths:
            let items = params["items"] as? [[String: Any]] ?? []
            let firstTarget = items.first?["destination_path"] as? String
            return makeStatus(
                title: items.count > 1 ? L10n.tr("chat.tool.move_paths") : fileName(from: firstTarget),
                detail: items.count > 1 ? "将批量重命名或移动 \(items.count) 个项目" : compactPath(firstTarget),
                badges: ["Move", "Batch"]
            )
        case .deletePaths:
            let paths = params["paths"] as? [String] ?? []
            let firstPath = paths.first
            return makeStatus(
                title: paths.count > 1 ? L10n.tr("chat.tool.delete_paths") : fileName(from: firstPath),
                detail: paths.count > 1 ? "将删除 \(paths.count) 个项目" : compactPath(firstPath),
                badges: ["Delete", "Batch"]
            )
        case .writeDOCX:
            let path = params["path"] as? String
            let title = (params["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = if let title, !title.isEmpty {
                L10n.tr("chat.run.write_docx.detail_with_title", title)
            } else {
                L10n.tr("chat.run.write_docx.detail")
            }
            return makeStatus(
                title: L10n.tr("chat.run.write_docx.title", fileName(from: path)),
                detail: detail,
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
        case .exportFile, .exportDirectory:
            let destination = params["destination_path"] as? String
            return makeStatus(
                title: fileName(from: destination),
                detail: compactPath(destination),
                badges: ["Export", "Copy"]
            )
        case .exportPDF, .exportDOCX, .exportXLSX:
            let path = params["path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.export.title", fileName(from: path)),
                detail: L10n.tr("chat.run.export.detail"),
                badges: [L10n.tr("chat.badge.file_export")]
            )
        case .listFiles:
            let path = params["path"] as? String
            let recursive = params["recursive"] as? Bool ?? false
            return makeStatus(
                title: fileName(from: path),
                detail: recursive ? "正在递归扫描目录内容" : "正在查看当前目录内容",
                badges: ["Directory", recursive ? "Recursive" : "Browse"]
            )
        case .webFetch:
            let url = params["url"] as? String
            return makeStatus(
                title: compactURL(url),
                detail: L10n.tr("chat.tool.web_fetch"),
                badges: ["Web", "Fetch"]
            )
        case .importFile, .importDirectory:
            let destination = params["destination_path"] as? String
            return makeStatus(
                title: L10n.tr("chat.run.import.title", fileName(from: destination)),
                detail: L10n.tr("chat.run.import.detail"),
                badges: [L10n.tr("chat.badge.file_import")]
            )
        case .importFileContent:
            let sourcePath = params["source_path"] as? String
            return makeStatus(
                title: fileName(from: sourcePath),
                detail: compactPath(sourcePath),
                badges: ["Import", "Read"]
            )
        case .listExternalFiles:
            let path = params["path"] as? String
            let recursive = params["recursive"] as? Bool ?? false
            return makeStatus(
                title: fileName(from: path),
                detail: recursive ? "正在递归查看外部目录" : "正在查看外部目录",
                badges: ["External", recursive ? "Recursive" : "Browse"]
            )
        case .shell:
            let command = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let preview = command.count > 46 ? String(command.prefix(46)) + "…" : command
            return makeStatus(
                title: preview.isEmpty ? L10n.tr("chat.tool.shell") : preview,
                detail: L10n.tr("chat.tool.shell"),
                badges: ["Shell"]
            )
        }
    }

    static func friendlyToolTitle(for toolName: String) -> String {
        if toolName.hasPrefix("mcp__") {
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

    private static func makeMCPRunningToolStatus(for execution: ToolExecutionRecord, intentContext: String?) -> RunningToolStatus? {
        func makeStatus(toolName: String, title: String, detail: String, badges: [String]) -> RunningToolStatus {
            RunningToolStatus(
                id: execution.id,
                toolName: toolName,
                title: title,
                detail: detail,
                phaseLabel: L10n.tr("chat.phase.running"),
                badges: badges,
                context: intentContext
            )
        }

        let params = ToolArgumentParser.parse(arguments: execution.arguments, for: nil) ?? [:]

        if execution.name.hasPrefix("mcp__"),
           let descriptor = MCPServerManager.shared.toolDescriptor(named: execution.name),
           let server = MCPServerManager.shared.serverConfig(for: descriptor.serverID) {
            let title = descriptor.toolTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? descriptor.toolName
            let detail = server.name
            var badges = ["MCP", server.scope.displayName]
            if descriptor.hints.readOnlyHint == true {
                badges.append("read-only")
            }
            if descriptor.hints.destructiveHint == true {
                badges.append("destructive")
            }
            return makeStatus(
                toolName: execution.name,
                title: title,
                detail: detail,
                badges: Array(badges.prefix(3))
            )
        }

        let mcpToolNames: Set<String> = ["mcp_list_resources", "mcp_read_resource", "mcp_list_prompts", "mcp_get_prompt"]
        guard mcpToolNames.contains(execution.name) else {
            return nil
        }

        let serverID = (params["server_id"] as? String).flatMap(UUID.init(uuidString:))
        let server = serverID.flatMap { MCPServerManager.shared.serverConfig(for: $0) }
        let serverName = server?.name ?? "MCP"
        let scopeBadge = server?.scope.displayName

        switch execution.name {
        case "mcp_list_resources":
            return makeStatus(
                toolName: execution.name,
                title: "MCP resources",
                detail: serverName,
                badges: ["MCP", scopeBadge].compactMap { $0 }
            )
        case "mcp_read_resource":
            let resourceName = (params["uri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "resource"
            return makeStatus(
                toolName: execution.name,
                title: resourceName,
                detail: serverName,
                badges: ["MCP", scopeBadge].compactMap { $0 }
            )
        case "mcp_list_prompts":
            return makeStatus(
                toolName: execution.name,
                title: "MCP prompts",
                detail: serverName,
                badges: ["MCP", scopeBadge].compactMap { $0 }
            )
        case "mcp_get_prompt":
            let promptName = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "prompt"
            return makeStatus(
                toolName: execution.name,
                title: promptName,
                detail: serverName,
                badges: ["MCP", scopeBadge].compactMap { $0 }
            )
        default:
            return nil
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

    private static func completedTitle(for execution: ToolExecutionRecord, operation: FileOperationRecord?) -> String {
        if let operationTitle = operation?.title.trimmingCharacters(in: .whitespacesAndNewlines), !operationTitle.isEmpty {
            return operationTitle
        }
        if let running = makeRunningToolStatus(for: execution, intentContext: nil)?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !running.isEmpty {
            return running
        }
        return friendlyToolTitle(for: execution.name)
    }

    private static func summarizedResult(_ result: String) -> String? {
        guard !result.isEmpty else { return nil }
        let firstLine = result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let firstLine, !firstLine.isEmpty else { return nil }
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }

    private static func makePendingApprovalStatus(for preview: OperationPreview) -> ConversationActivityStatus {
        let toolLabel = friendlyToolTitle(for: preview.toolName)
        let detailLines = preview.detailLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let context = detailLines.prefix(2).joined(separator: " · ").nilIfEmpty
        var badges = [L10n.tr("chat.badge.approval"), approvalRiskLabel(for: preview)]
        if preview.canUndo {
            badges.append(L10n.tr("chat.approval.undo_supported"))
        }

        return ConversationActivityStatus(
            title: preview.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? toolLabel,
            detail: preview.summary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? toolLabel,
            context: context,
            badges: Array(NSOrderedSet(array: badges).array as? [String] ?? badges).prefix(3).map { $0 },
            phaseLabel: L10n.tr("chat.phase.awaiting_approval"),
            isBusy: true,
            iconName: "hand.raised.fill",
            accentStyle: .approval
        )
    }

    private static func makeErrorActivityStatus(message: String) -> ConversationActivityStatus {
        let isStopped = message == L10n.tr("chat.error.stopped")
        return ConversationActivityStatus(
            title: isStopped ? L10n.tr("chat.status.stopped.title") : L10n.tr("chat.status.failed.title"),
            detail: message,
            context: nil,
            badges: [L10n.tr(isStopped ? "chat.badge.canceled" : "chat.badge.failed")],
            phaseLabel: L10n.tr(isStopped ? "chat.phase.blocked" : "chat.phase.failed"),
            isBusy: false,
            iconName: isStopped ? "stop.circle" : "exclamationmark.octagon.fill",
            accentStyle: isStopped ? .warning : .error
        )
    }

    private static func approvalRiskLabel(for preview: OperationPreview) -> String {
        let toolName = preview.toolName
        if toolName.hasPrefix("mcp__") || toolName.hasPrefix("mcp_") {
            return preview.isDestructive ? L10n.tr("chat.approval.risk.high") : "MCP"
        }
        if toolName == ToolDefinition.ToolName.movePaths.rawValue || toolName == ToolDefinition.ToolName.deletePaths.rawValue {
            return L10n.tr("chat.approval.risk.external_path")
        }
        if toolName == ToolDefinition.ToolName.shell.rawValue {
            return L10n.tr("chat.approval.risk.command")
        }
        if toolName == ToolDefinition.ToolName.installSkill.rawValue {
            return L10n.tr("chat.approval.risk.skill_install")
        }
        if toolName == ToolDefinition.ToolName.runSkillScript.rawValue {
            return L10n.tr("chat.approval.risk.skill_script")
        }
        return preview.isDestructive ? L10n.tr("chat.approval.risk.high") : L10n.tr("chat.approval.risk.normal")
    }

    private static func completionState(for result: String) -> ActivityCompletionState {
        if result.hasPrefix("[错误]") {
            return .failed
        }
        if result.hasPrefix("⚠️") {
            let lowered = result.lowercased()
            if lowered.contains("已取消") || lowered.contains("被拒绝") || lowered.contains("跳过") || lowered.contains("不能使用") {
                return .blocked
            }
            return .warning
        }
        return .succeeded
    }

    private static func phaseLabel(for state: ActivityCompletionState) -> String {
        switch state {
        case .succeeded:
            return L10n.tr("chat.phase.done")
        case .blocked:
            return L10n.tr("chat.phase.blocked")
        case .warning:
            return L10n.tr("chat.phase.blocked")
        case .failed:
            return L10n.tr("chat.phase.failed")
        }
    }

    private static func badgeLabel(for state: ActivityCompletionState) -> String {
        switch state {
        case .succeeded:
            return L10n.tr("chat.badge.done")
        case .blocked:
            return L10n.tr("chat.badge.blocked")
        case .warning:
            return L10n.tr("chat.badge.warning")
        case .failed:
            return L10n.tr("chat.badge.failed")
        }
    }

    private static func completedIconName(for toolName: String, state: ActivityCompletionState) -> String {
        switch state {
        case .succeeded:
            return iconName(for: toolName)
        case .blocked:
            return "hand.raised.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "exclamationmark.octagon.fill"
        }
    }

    private static func completedAccentStyle(for toolName: String, state: ActivityCompletionState) -> ActivityAccentStyle {
        switch state {
        case .succeeded:
            return .success
        case .blocked:
            return .warning
        case .warning:
            return .warning
        case .failed:
            return .error
        }
    }

    private static func iconName(for toolName: String) -> String {
        if toolName.hasPrefix("mcp__") {
            return "shippingbox"
        }
        switch toolName {
        case "mcp_list_resources", "mcp_read_resource":
            return "shippingbox"
        case "mcp_list_prompts", "mcp_get_prompt":
            return "text.bubble"
        default:
            break
        }

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
        case .writeFile, .writeAssistantContentToFile, .writeMultipleFiles:
            return "square.and.pencil"
        case .movePaths:
            return "arrow.left.and.right.square"
        case .deletePaths:
            return "trash"
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

    private static func accentStyle(for toolName: String) -> ActivityAccentStyle {
        if toolName.hasPrefix("mcp__") {
            return .skill
        }
        switch toolName {
        case "mcp_list_resources", "mcp_read_resource":
            return .reading
        case "mcp_list_prompts", "mcp_get_prompt":
            return .skill
        default:
            break
        }

        switch ToolDefinition.ToolName(rawValue: toolName) {
        case .readSkillResource, .readUploadedAttachment, .readFile, .importFileContent, .listFiles, .listExternalFiles, .webFetch, .previewImage:
            return .reading
        case .writeFile, .writeAssistantContentToFile, .writeMultipleFiles, .movePaths, .deletePaths, .writeDOCX, .writeXLSX, .replaceDOCXSection, .insertDOCXSection, .appendXLSXRows, .updateXLSXCell, .exportFile, .exportDirectory, .exportPDF, .exportDOCX, .exportXLSX:
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

private enum ActivityCompletionState {
    case succeeded
    case blocked
    case warning
    case failed
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

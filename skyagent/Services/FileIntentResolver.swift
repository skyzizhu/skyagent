import Foundation

enum FileIntentKind: String, Sendable {
    case createFiles
    case renameFiles
    case deleteFiles
    case buildWebPage
    case updateSpreadsheetCell
    case appendSpreadsheetRows
    case replaceDocumentSection
    case insertDocumentSection
    case rewriteDocument
    case rewriteSpreadsheet
    case exportDocument
    case readDocument
    case summarizeDocument
    case compareFiles
    case unknown

    var displayName: String {
        switch self {
        case .createFiles:
            return "创建文件"
        case .renameFiles:
            return "重命名文件"
        case .deleteFiles:
            return "删除文件"
        case .buildWebPage:
            return "生成网页工程"
        case .updateSpreadsheetCell:
            return "更新 Excel 单元格"
        case .appendSpreadsheetRows:
            return "追加 Excel 行"
        case .replaceDocumentSection:
            return "替换 Word 章节"
        case .insertDocumentSection:
            return "插入 Word 章节"
        case .rewriteDocument:
            return "重写文档"
        case .rewriteSpreadsheet:
            return "重写表格"
        case .exportDocument:
            return "导出文件"
        case .readDocument:
            return "读取文件"
        case .summarizeDocument:
            return "总结文件"
        case .compareFiles:
            return "对比文件"
        case .unknown:
            return "未明确文件意图"
        }
    }
}

struct FileIntentAnalysis: Sendable {
    let kind: FileIntentKind
    let summary: String
    let executionPlan: String?
    let targetPath: String?
    let suggestedTools: [ToolDefinition.ToolName]
    let plannedArguments: [String: String]
    let badges: [String]
    let referencedAttachmentID: String?
    let targetReason: String?
    let note: String?
    let ambiguousCandidates: [String]
    let clarificationQuestion: String?
    let writeConfirmationQuestion: String?

    func systemContext() -> String {
        var lines = [
            "[本地文件意图分析]",
            "意图：\(kind.displayName)",
            "摘要：\(summary)"
        ]

        if let targetPath, !targetPath.isEmpty {
            lines.append("优先目标文件：\(targetPath)")
        }

        if let executionPlan, !executionPlan.isEmpty {
            lines.append("执行计划：\(executionPlan)")
        }

        if !suggestedTools.isEmpty {
            lines.append("优先工具：\(suggestedTools.map(\.rawValue).joined(separator: ", "))")
        }

        if !plannedArguments.isEmpty {
            let orderedArguments = plannedArguments
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            lines.append("建议参数：\(orderedArguments)")
        }

        if !badges.isEmpty {
            lines.append("关键标签：\(badges.joined(separator: " · "))")
        }

        if let referencedAttachmentID, !referencedAttachmentID.isEmpty {
            lines.append("优先参考附件：\(referencedAttachmentID)")
        }

        if let targetReason, !targetReason.isEmpty {
            lines.append("命中原因：\(targetReason)")
        }

        if let note, !note.isEmpty {
            lines.append("提示：\(note)")
        }

        if !ambiguousCandidates.isEmpty {
            lines.append("歧义候选：\(ambiguousCandidates.joined(separator: " | "))")
        }

        if let clarificationQuestion, !clarificationQuestion.isEmpty {
            lines.append("建议澄清问题：\(clarificationQuestion)")
        }

        if let writeConfirmationQuestion, !writeConfirmationQuestion.isEmpty {
            lines.append("建议执行前确认：\(writeConfirmationQuestion)")
        }

        if ambiguousCandidates.isEmpty {
            lines.append("如果用户意图与以上分析一致，请优先围绕这个目标文件/附件执行，不要随意改动其他文件。")
        } else {
            lines.append("当前存在多个相近候选文件。除非用户已经明确指定，否则不要直接改写，请先用一句简短的话向用户确认目标文件。")
        }
        if kind == .buildWebPage {
            lines.append("这是网页工程任务。请先规划并分别写入互相关联的 HTML、CSS、JS 文件，不要把三者混写到一个文件里。")
            lines.append("默认优先使用 index.html、styles.css、script.js（除非用户明确指定其他文件名）。")
            lines.append("首轮执行前，只用一句简短的话说明将写哪些文件，然后直接开始写入，不要先输出长篇解释。")
            lines.append("首轮优先使用 write_multiple_files 一次写入互相关联的网页文件。")
            lines.append("HTML 必须通过相对路径正确引用 CSS 和 JS；CSS/JS 中使用的类名、ID、DOM 选择器必须和 HTML 实际结构一致。")
            lines.append("避免内联大段 CSS/JS，避免无意义超长占位内容，优先先搭稳定骨架，再分别补样式和交互。")
            lines.append("写入完成后，不要立刻用 read_file 整体回读大文件做全量验证；如果 read_file 提示“已截断”，那表示读取展示被截断，不代表文件写入失败。")
            lines.append("如果后续进入修复模式，只修改被点名的文件；如果只有一个文件有问题，优先用 write_file 精确修复它，而不是再次整套重写。")
        }
        if ambiguousCandidates.isEmpty, let writeConfirmationQuestion, !writeConfirmationQuestion.isEmpty {
            lines.append("这是一次高风险写入。除非用户已经明确确认，否则请先用一句简短的话确认后再执行写入。")
        }
        lines.append("[/本地文件意图分析]")
        return lines.joined(separator: "\n")
    }
}

private struct FileIntentCandidate {
    enum Source {
        case recentOperation
        case workspace
        case attachment
    }

    let name: String
    let path: String?
    let type: String
    let source: Source
    let attachmentID: String?
}

private struct FileIntentResolution {
    let primary: FileIntentCandidate?
    let ambiguousCandidates: [FileIntentCandidate]
}

private struct RecentOperationContext {
    let targetPath: String?
    let toolName: String?
    let sheetName: String?
    let cell: String?
    let sectionTitle: String?
    let insertedSectionTitle: String?
    let insertedAfterSectionTitle: String?
}

private struct FileIntentScoreContext {
    let currentAttachmentID: String?
    let recentTargetPath: String?
}

final class FileIntentResolver {
    static let shared = FileIntentResolver()

    private let attachmentStore: UploadedAttachmentStore
    private let relevantExtensions: Set<String> = [
        "docx", "xlsx", "pdf", "pptx", "txt", "md", "markdown", "csv", "json", "xml", "yaml", "yml",
        "html", "css", "js"
    ]
    private let skippedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", ".idea", ".vscode",
        "node_modules", "Pods", "DerivedData", "build", "dist", ".build",
        ".next", ".nuxt", ".turbo", ".cache", "__pycache__", ".venv", "venv"
    ]

    init(attachmentStore: UploadedAttachmentStore = .shared) {
        self.attachmentStore = attachmentStore
    }

    func analyze(
        userText: String,
        conversation: Conversation,
        fallbackSandboxDir: String,
        currentAttachmentID: String?
    ) -> FileIntentAnalysis? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recentContext = recentOperationContext(for: conversation)
        let intent = classifyIntent(from: trimmed, recentContext: recentContext)
        guard intent != .unknown else { return nil }
        let scoreContext = FileIntentScoreContext(
            currentAttachmentID: currentAttachmentID,
            recentTargetPath: recentContext?.targetPath
        )

        let candidates = buildCandidates(
            conversation: conversation,
            fallbackSandboxDir: fallbackSandboxDir,
            currentAttachmentID: currentAttachmentID
        )
        let resolution = resolveTarget(
            for: trimmed,
            intent: intent,
            candidates: candidates,
            conversation: conversation,
            recentContext: recentContext,
            scoreContext: scoreContext
        )
        let target = resolution.primary
        let suggestedTools = resolution.ambiguousCandidates.isEmpty ? suggestedTools(for: intent, target: target) : []
        let plannedArguments = extractPlannedArguments(for: trimmed, intent: intent, recentContext: recentContext)
        let badges = makeBadges(for: intent, text: trimmed, target: target, ambiguousCount: resolution.ambiguousCandidates.count)
        let targetReason = targetReason(
            for: trimmed,
            target: target,
            recentContext: recentContext,
            currentAttachmentID: currentAttachmentID
        )
        let note = note(for: intent, target: target, ambiguousCandidates: resolution.ambiguousCandidates)
        let summary = summary(for: intent, text: trimmed, target: target, ambiguousCandidates: resolution.ambiguousCandidates)
        let executionPlan = executionPlan(for: intent, target: target, plannedArguments: plannedArguments, ambiguousCandidates: resolution.ambiguousCandidates)
        let clarificationQuestion = clarificationQuestion(for: intent, ambiguousCandidates: resolution.ambiguousCandidates)
        let writeConfirmationQuestion = writeConfirmationQuestion(
            for: intent,
            text: trimmed,
            target: target,
            ambiguousCandidates: resolution.ambiguousCandidates
        )

        return FileIntentAnalysis(
            kind: intent,
            summary: summary,
            executionPlan: executionPlan,
            targetPath: target?.path,
            suggestedTools: suggestedTools,
            plannedArguments: plannedArguments,
            badges: badges,
            referencedAttachmentID: target?.attachmentID,
            targetReason: targetReason,
            note: note,
            ambiguousCandidates: resolution.ambiguousCandidates.map(\.name),
            clarificationQuestion: clarificationQuestion,
            writeConfirmationQuestion: writeConfirmationQuestion
        )
    }

    private func classifyIntent(from text: String, recentContext: RecentOperationContext?) -> FileIntentKind {
        let normalized = text.lowercased()
        let hasWebSurface = containsAny(normalized, [
            "网页", "页面", "网站", "web", "website", "landing page", "landing",
            "html", "css", "javascript", "js", "前端", "样式", "脚本"
        ])
        let hasWebPageNouns = containsAny(normalized, [
            "网页", "页面", "网站", "website", "landing page", "landing", "前端"
        ])
        let hasMultiFileWebIntent = containsAny(normalized, [
            "html+css+js", "html css js", "分开写", "分别写", "不要写到一块", "不要写在一起",
            "拆成三个文件", "三个文件", "index.html", "styles.css", "script.js"
        ])
        let hasFileSurface = containsAny(normalized, [
            "文件", "文档", "表格", "工作表", "sheet", "章节", "附件", "pdf", "docx", "xlsx",
            "csv", ".md", ".txt", ".json", ".yaml", ".yml", ".html", ".css", ".js"
        ])
        let hasGenericFileReference = containsAny(normalized, [
            "这个文件", "那个文件", "这份文件", "这个文档", "那个文档", "这个表", "那个表", "这个附件", "上传的"
        ])
        let hasExcel = containsAny(normalized, ["excel", "xlsx", "表格", "工作表", "sheet", "单元格", "这个表", "那个表", "刚才那个表", "上一个表", "上一版表", "表的"])
        let hasWord = containsAny(normalized, ["word", "docx", "文档", "章节", "小节", "部分"])
        let hasExport = containsAny(normalized, ["导出", "输出为", "另存为", "保存为", "导成", "导出成"])
        let hasRead = containsAny(normalized, ["读取", "查看", "看看", "打开", "分析", "识别"])
        let hasSummary = containsAny(normalized, ["总结", "摘要", "概括", "提炼"])
        let hasCompare = containsAny(normalized, ["对比", "比较", "diff"])
        let hasDelete = containsAny(normalized, ["删除", "删掉", "移除", "清掉", "清空", "remove", "delete"])
        let hasRename = containsAny(normalized, ["重命名", "改名", "改后缀", "后缀改成", "扩展名改成", "rename", "改成ini", "改成txt", "改成md", "改成json", "改成yaml", "改成yml"])
        let hasCreate = containsAny(normalized, ["创建", "新建", "生成", "写", "做", "产出"]) && containsAny(normalized, ["文件", ".txt", ".md", ".json", ".yaml", ".yml", ".ini", ".html", ".css", ".js"])

        if hasDelete {
            return .deleteFiles
        }

        if hasRename {
            return .renameFiles
        }

        if hasCreate && !hasWebSurface {
            return .createFiles
        }

        if hasWebSurface && (hasWebPageNouns || hasMultiFileWebIntent) {
            if containsAny(normalized, [
                "生成", "创建", "写", "做", "搭", "做一个", "写一个", "生成一个", "创建一个",
                "分开写", "分别写", "不要写到一块", "不要写在一起", "拆成三个文件", "三个文件",
                "继续改这个页面", "继续改这个网页", "这个页面", "这个网页", "这个网站"
            ]) {
                return .buildWebPage
            }
        }

        if hasExcel {
            if text.range(of: #"[A-Za-z]+[0-9]+"#, options: .regularExpression) != nil {
                return .updateSpreadsheetCell
            }
            if containsAny(normalized, ["追加", "新增一行", "添加一行", "增加一行", "补几行", "新增几行"]) {
                return .appendSpreadsheetRows
            }
            if containsAny(normalized, ["重写", "覆盖", "改写整个表", "重新生成表格"]) {
                return .rewriteSpreadsheet
            }
        }

        if hasWord {
            if containsAny(normalized, ["插入", "新增章节", "增加章节", "补一个章节", "补充一个章节", "补一个", "补充一个", "加一个章节", "后面补"]) && containsAny(normalized, ["章节", "小节", "部分", "文档"]) {
                return .insertDocumentSection
            }
            if containsAny(normalized, ["替换", "修改章节", "重写章节", "更新章节"]) {
                return .replaceDocumentSection
            }
            if containsAny(normalized, ["重写", "改写", "重新整理", "覆盖"]) {
                return .rewriteDocument
            }
        }

        if hasExport && (hasFileSurface || hasGenericFileReference || recentContext != nil) {
            return .exportDocument
        }
        if hasCompare && (hasFileSurface || hasGenericFileReference || recentContext != nil) {
            return .compareFiles
        }
        if hasSummary && (hasFileSurface || hasGenericFileReference || recentContext != nil) {
            return .summarizeDocument
        }
        if hasRead && (hasFileSurface || hasGenericFileReference || recentContext != nil) {
            return .readDocument
        }

        if let recentContext, containsAny(normalized, ["继续", "接着", "下一列", "下一行", "上一列", "上一行", "这一章", "这章", "这个章节", "这个表", "这个文档"]) {
            if let toolName = recentContext.toolName {
                if [
                    ToolDefinition.ToolName.updateXLSXCell.rawValue,
                    ToolDefinition.ToolName.appendXLSXRows.rawValue,
                    ToolDefinition.ToolName.writeXLSX.rawValue
                ].contains(toolName) {
                    if containsAny(normalized, ["追加", "新增一行", "添加一行", "增加一行"]) {
                        return .appendSpreadsheetRows
                    }
                    return .updateSpreadsheetCell
                }

                if [
                    ToolDefinition.ToolName.insertDOCXSection.rawValue,
                    ToolDefinition.ToolName.replaceDOCXSection.rawValue,
                    ToolDefinition.ToolName.writeDOCX.rawValue
                ].contains(toolName) {
                    if containsAny(normalized, ["替换", "修改", "重写", "更新"]) {
                        return .replaceDocumentSection
                    }
                    return .insertDocumentSection
                }

                if toolName == ToolDefinition.ToolName.writeFile.rawValue,
                   containsAny(normalized, ["这个页面", "这个网页", "这个网站", "继续", "接着"]) {
                    return .buildWebPage
                }
            }
        }

        return .unknown
    }

    private func buildCandidates(
        conversation: Conversation,
        fallbackSandboxDir: String,
        currentAttachmentID: String?
    ) -> [FileIntentCandidate] {
        var candidates: [FileIntentCandidate] = []

        let recentTargets = conversation.recentOperations.compactMap { operation -> FileIntentCandidate? in
            guard let path = operation.detailLines.first(where: { $0.hasPrefix("目标：") })?
                .replacingOccurrences(of: "目标：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return makePathCandidate(path: path, source: .recentOperation)
        }
        candidates.append(contentsOf: recentTargets)

        let workspaceRoot = conversation.sandboxDir.isEmpty ? fallbackSandboxDir : conversation.sandboxDir
        candidates.append(contentsOf: scanWorkspaceCandidates(root: workspaceRoot, limit: 40))

        let attachmentIDs = Array(NSOrderedSet(array: ([currentAttachmentID].compactMap { $0 } + conversation.messages.compactMap(\.attachmentID).reversed()))) as? [String] ?? []
        for attachmentID in attachmentIDs {
            guard let document = attachmentStore.loadDocument(id: attachmentID) else { continue }
            candidates.append(
                FileIntentCandidate(
                    name: document.fileName,
                    path: nil,
                    type: document.typeName.lowercased(),
                    source: .attachment,
                    attachmentID: document.id
                )
            )
        }

        return uniqueCandidates(candidates)
    }

    private func resolveTarget(
        for text: String,
        intent: FileIntentKind,
        candidates: [FileIntentCandidate],
        conversation: Conversation,
        recentContext: RecentOperationContext?,
        scoreContext: FileIntentScoreContext
    ) -> FileIntentResolution {
        let normalized = text.lowercased()
        let messageHints = recentMessageHints(from: conversation, candidates: candidates)
        let containsGenericReference = containsAny(normalized, ["这个", "那个", "刚才", "上一个", "上一版", "这份", "那个表", "这个表", "这个文档", "那个文档"])

        if let explicitName = explicitFileName(in: text),
           let matched = candidates.first(where: { $0.name.lowercased() == explicitName.lowercased() }) {
            return FileIntentResolution(primary: matched, ambiguousCandidates: [])
        }

        if containsAny(normalized, ["这个附件", "这个文件", "这份文件", "刚上传", "上传的"]) {
            if let attachment = candidates.first(where: { $0.source == .attachment }) {
                return FileIntentResolution(primary: attachment, ambiguousCandidates: [])
            }
        }

        if shouldPreferRecentOperation(for: normalized, intent: intent),
           let recentPath = recentContext?.targetPath,
           let matched = candidates.first(where: { $0.path == recentPath }) {
            return FileIntentResolution(primary: matched, ambiguousCandidates: [])
        }

        let filtered: [FileIntentCandidate]
        switch intent {
        case .createFiles, .renameFiles, .deleteFiles, .compareFiles, .exportDocument:
            filtered = candidates
        case .buildWebPage:
            filtered = candidates.filter { isWebCandidate($0) }
        case .updateSpreadsheetCell, .appendSpreadsheetRows, .rewriteSpreadsheet:
            filtered = candidates.filter { isSpreadsheetCandidate($0) }
        case .replaceDocumentSection, .insertDocumentSection, .rewriteDocument:
            filtered = candidates.filter { isWordCandidate($0) }
        case .summarizeDocument, .readDocument:
            if containsAny(normalized, ["pdf"]) {
                filtered = candidates.filter { $0.type.contains("pdf") || $0.name.lowercased().hasSuffix(".pdf") }
            } else {
                filtered = candidates
            }
        case .unknown:
            filtered = []
        }

        return bestResolution(
            in: filtered,
            for: normalized,
            messageHints: messageHints,
            containsGenericReference: containsGenericReference,
            scoreContext: scoreContext
        )
    }

    private func suggestedTools(for intent: FileIntentKind, target: FileIntentCandidate?) -> [ToolDefinition.ToolName] {
        switch intent {
        case .createFiles:
            return [.writeMultipleFiles]
        case .renameFiles:
            return [.movePaths]
        case .deleteFiles:
            return [.deletePaths]
        case .buildWebPage:
            return [.writeMultipleFiles]
        case .updateSpreadsheetCell:
            return target?.source == .attachment
                ? [.readUploadedAttachment, .writeXLSX]
                : [.updateXLSXCell]
        case .appendSpreadsheetRows:
            return target?.source == .attachment
                ? [.readUploadedAttachment, .writeXLSX]
                : [.appendXLSXRows]
        case .replaceDocumentSection:
            return target?.source == .attachment
                ? [.readUploadedAttachment, .writeDOCX]
                : [.replaceDOCXSection]
        case .insertDocumentSection:
            return target?.source == .attachment
                ? [.readUploadedAttachment, .writeDOCX]
                : [.insertDOCXSection]
        case .rewriteDocument:
            return [.writeDOCX]
        case .rewriteSpreadsheet:
            return [.writeXLSX]
        case .exportDocument:
            return [.exportPDF, .exportDOCX, .exportXLSX]
        case .readDocument, .summarizeDocument:
            return target?.source == .attachment ? [.readUploadedAttachment] : [.readFile]
        case .compareFiles:
            return target?.source == .attachment ? [.readUploadedAttachment] : [.readFile]
        case .unknown:
            return []
        }
    }

    private func extractPlannedArguments(for text: String, intent: FileIntentKind, recentContext: RecentOperationContext?) -> [String: String] {
        switch intent {
        case .buildWebPage:
            let names = inferredWebProjectFiles(from: text)
            return [
                "html_path": names.html,
                "css_path": names.css,
                "js_path": names.js,
                "link_css": names.css,
                "link_js": names.js
            ]
        case .updateSpreadsheetCell:
            var arguments: [String: String] = [:]
            if let sheetName = extractSheetName(from: text) ?? inferredSheetName(from: text, recentContext: recentContext) {
                arguments["sheet_name"] = sheetName
            }
            if let cell = extractCellReference(from: text) ?? inferredCellReference(from: text, recentContext: recentContext) {
                arguments["cell"] = cell
            }
            if let value = extractAssignedValue(from: text) {
                arguments["value"] = value
            }
            return arguments
        case .appendSpreadsheetRows:
            var arguments: [String: String] = [:]
            if let sheetName = extractSheetName(from: text) ?? inferredSheetName(from: text, recentContext: recentContext) {
                arguments["sheet_name"] = sheetName
            }
            return arguments
        case .replaceDocumentSection:
            var arguments: [String: String] = [:]
            if let sectionTitle = extractSectionTitle(from: text, keywords: ["替换", "修改", "重写", "更新"]) ?? inferredSectionTitle(from: text, recentContext: recentContext) {
                arguments["section_title"] = sectionTitle
            }
            return arguments
        case .insertDocumentSection:
            var arguments: [String: String] = [:]
            if let sectionTitle = extractSectionTitle(from: text, keywords: ["插入", "新增", "增加", "补一个", "补充一个", "加一个", "后面补"]) {
                arguments["section_title"] = sectionTitle
            }
            if let afterTitle = extractAfterSectionTitle(from: text) ?? inferredAfterSectionTitle(from: text, recentContext: recentContext) {
                arguments["after_section_title"] = afterTitle
            }
            return arguments
        case .renameFiles:
            if let targetExtension = extractTargetExtension(from: text) {
                return ["target_extension": targetExtension]
            }
            return [:]
        case .createFiles, .deleteFiles, .rewriteDocument, .rewriteSpreadsheet, .exportDocument, .readDocument, .summarizeDocument, .compareFiles, .unknown:
            return [:]
        }
    }

    private func summary(for intent: FileIntentKind, text: String, target: FileIntentCandidate?, ambiguousCandidates: [FileIntentCandidate]) -> String {
        if ambiguousCandidates.count >= 2 {
            return "用户意图大致明确，但当前有多个相近目标文件：\(ambiguousCandidates.map(\.name).joined(separator: "、"))。"
        }
        let targetName = target?.name ?? "未明确文件"
        switch intent {
        case .createFiles:
            return "用户更像是要一次创建一个或多个新文件，而不是修改现有文件。"
        case .renameFiles:
            return "用户更像是要重命名文件、批量改名或修改文件后缀，而不是新建一批新文件。"
        case .deleteFiles:
            return "用户更像是要删除已有文件，而不是生成删除脚本。"
        case .buildWebPage:
            if let targetName = target?.name {
                return "用户更像是要围绕 \(targetName) 继续完成一个由 HTML、CSS、JS 分离的网页工程。"
            }
            return "用户更像是要生成一个由 HTML、CSS、JS 分离、彼此关联的网页工程。"
        case .updateSpreadsheetCell:
            return "用户更像是要精确修改 \(targetName) 的某个单元格。"
        case .appendSpreadsheetRows:
            return "用户更像是要向 \(targetName) 的某个工作表追加新行。"
        case .replaceDocumentSection:
            return "用户更像是要替换 \(targetName) 中某个章节的内容。"
        case .insertDocumentSection:
            return "用户更像是要向 \(targetName) 插入一个新章节。"
        case .rewriteDocument:
            return "用户更像是要重写或覆盖 \(targetName) 的文档内容。"
        case .rewriteSpreadsheet:
            return "用户更像是要重写或覆盖 \(targetName) 的表格内容。"
        case .exportDocument:
            return "用户更像是要把当前内容导出成正式文件。"
        case .readDocument:
            return "用户更像是要读取并理解 \(targetName) 的内容。"
        case .summarizeDocument:
            return "用户更像是要总结 \(targetName) 的内容。"
        case .compareFiles:
            return "用户更像是要对比多个文件，而不是直接改写。"
        case .unknown:
            return text
        }
    }

    private func makeBadges(for intent: FileIntentKind, text: String, target: FileIntentCandidate?, ambiguousCount: Int) -> [String] {
        var badges: [String] = [intent.displayName]
        if ambiguousCount >= 2 {
            badges.append("需要确认")
        }
        if let target {
            badges.append(target.type.uppercased())
        switch target.source {
            case .attachment:
                badges.append("上传附件")
            case .recentOperation:
                badges.append("最近修改")
            case .workspace:
                badges.append("工作目录")
            }
        }

        if let targetExtension = extractTargetExtension(from: text) {
            badges.append(".\(targetExtension)")
        }

        if let cellMatch = text.range(of: #"[A-Za-z]+[0-9]+"#, options: .regularExpression) {
            badges.append(String(text[cellMatch]).uppercased())
        }
        return Array(NSOrderedSet(array: badges)) as? [String] ?? badges
    }

    private func note(for intent: FileIntentKind, target: FileIntentCandidate?, ambiguousCandidates: [FileIntentCandidate]) -> String? {
        if ambiguousCandidates.count >= 2 {
            if intent == .buildWebPage {
                return "这看起来是网页工程任务。请先确定 HTML、CSS、JS 三个关联文件，再分别写入，并确保 HTML 正确引用 CSS 和 JS。"
            }
            return "当前命中了多个相近候选文件。请先让用户确认是哪个文件，再执行写入或修改。"
        }
        if intent == .createFiles {
            return "这是创建文件任务。只要涉及多个文件，就优先一次调用 write_multiple_files，不要循环调用 write_file，也不要先生成额外脚本。"
        }
        if intent == .renameFiles {
            return "这是重命名/改后缀任务。优先一次调用 move_paths 批量改名，不要创建新的副本文件，也不要生成 shell 脚本。"
        }
        if intent == .deleteFiles {
            return "这是删除任务。优先一次调用 delete_paths 删除目标文件，不要生成 delete.sh 之类的辅助脚本。"
        }
        if intent == .buildWebPage {
            return "这是网页工程任务。先用一句短计划确认 HTML、CSS、JS 三个关联文件，再优先一次写入；如果后面只坏了一个文件，就只精确修那个文件。"
        }
        guard let target else { return "当前没有稳定命中的目标文件，必要时请先用 list_files 确认目标。" }
        if target.source == .attachment && [.updateSpreadsheetCell, .appendSpreadsheetRows, .replaceDocumentSection, .insertDocumentSection].contains(intent) {
            return "命中的对象是上传附件。附件适合作为只读参考；如果需要修改，请先读取附件内容，再写回当前工作目录中的新文件。"
        }
        return nil
    }

    private func executionPlan(
        for intent: FileIntentKind,
        target: FileIntentCandidate?,
        plannedArguments: [String: String],
        ambiguousCandidates: [FileIntentCandidate]
    ) -> String? {
        guard ambiguousCandidates.isEmpty else { return nil }

        switch intent {
        case .createFiles:
            return "将优先一次写入全部目标文件；如果有多个文件，会先用 write_multiple_files，而不是逐个调用 write_file。"
        case .renameFiles:
            if let ext = plannedArguments["target_extension"], !ext.isEmpty {
                return "将优先一次调用 move_paths，把命中的文件批量改成 .\(ext) 后缀，而不是重新创建新文件。"
            }
            return "将优先一次调用 move_paths 直接重命名目标文件，不会额外生成脚本。"
        case .deleteFiles:
            return "将优先一次调用 delete_paths 删除目标文件，并尽量移动到废纸篓，而不是生成删除脚本。"
        case .buildWebPage:
            let html = plannedArguments["html_path"] ?? "index.html"
            let css = plannedArguments["css_path"] ?? "styles.css"
            let js = plannedArguments["js_path"] ?? "script.js"
            return "将先写入 \(html)、\(css)、\(js)，并保持三者引用关系一致。"
        case .updateSpreadsheetCell:
            guard let target else { return nil }
            let sheet = plannedArguments["sheet_name"] ?? "Sheet1"
            let cell = plannedArguments["cell"] ?? "A1"
            return "将定位 \(target.name) 的 \(sheet)!\(cell) 并精确更新这个单元格。"
        case .appendSpreadsheetRows:
            guard let target else { return nil }
            let sheet = plannedArguments["sheet_name"] ?? "Sheet1"
            return "将向 \(target.name) 的 \(sheet) 追加新行，不改动其他工作表。"
        case .replaceDocumentSection:
            guard let target else { return nil }
            let section = plannedArguments["section_title"] ?? "目标章节"
            return "将只替换 \(target.name) 中“\(section)”这一章，不重写整份文档。"
        case .insertDocumentSection:
            guard let target else { return nil }
            let section = plannedArguments["section_title"] ?? "新章节"
            if let after = plannedArguments["after_section_title"], !after.isEmpty {
                return "将只在 \(target.name) 的“\(after)”后插入“\(section)”，不改其他章节。"
            }
            return "将只在 \(target.name) 中插入“\(section)”，不改其他章节。"
        case .rewriteDocument:
            guard let target else { return nil }
            return "将重写 \(target.name) 的正文内容。"
        case .rewriteSpreadsheet:
            guard let target else { return nil }
            return "将重写 \(target.name) 的表格内容。"
        case .exportDocument:
            guard let target else { return nil }
            return "将基于 \(target.name) 导出新的结果文件。"
        case .readDocument:
            guard let target else { return nil }
            return "将先读取 \(target.name) 的内容，再继续处理。"
        case .summarizeDocument:
            guard let target else { return nil }
            return "将先读取并总结 \(target.name) 的内容。"
        case .compareFiles:
            return "将先读取相关文件，再进行差异比较。"
        case .unknown:
            return nil
        }
    }

    private func targetReason(
        for text: String,
        target: FileIntentCandidate?,
        recentContext: RecentOperationContext?,
        currentAttachmentID: String?
    ) -> String? {
        guard let target else { return nil }
        let normalized = text.lowercased()

        if let currentAttachmentID, target.attachmentID == currentAttachmentID {
            return "这是当前上传/当前引用的附件。"
        }

        if target.path == recentContext?.targetPath {
            return "这是最近一次真实操作过的目标文件。"
        }

        if containsAny(normalized, ["刚才", "上一个", "上一版", "还是这个", "继续", "接着"]) {
            switch target.source {
            case .recentOperation:
                return "你用了连续指代，系统优先沿用了最近操作的文件。"
            case .attachment:
                return "你用了连续指代，系统优先沿用了当前附件。"
            case .workspace:
                break
            }
        }

        if containsAny(normalized, ["这个附件", "刚上传", "上传的"]) && target.source == .attachment {
            return "你提到了上传附件，所以优先选中了这个附件。"
        }

        if target.source == .workspace {
            return "它是当前工作目录里最匹配的同类文件。"
        }

        return nil
    }

    private func clarificationQuestion(for intent: FileIntentKind, ambiguousCandidates: [FileIntentCandidate]) -> String? {
        guard ambiguousCandidates.count >= 2 else { return nil }
        let names = Array(ambiguousCandidates.prefix(3).map(\.name))
        guard !names.isEmpty else { return nil }

        let joinedNames: String
        if names.count == 2 {
            joinedNames = "\(names[0]) 还是 \(names[1])"
        } else {
            joinedNames = names.dropLast().joined(separator: "、") + " 还是 " + (names.last ?? "")
        }

        switch intent {
        case .createFiles:
            return "你是要创建哪几个文件？"
        case .renameFiles:
            return "你是要重命名 \(joinedNames) 里的哪一些文件？"
        case .deleteFiles:
            return "你是要删除 \(joinedNames) 里的哪一些文件？"
        case .buildWebPage:
            return "你是要继续修改 \(joinedNames) 这几个网页文件中的哪一个？"
        case .updateSpreadsheetCell, .appendSpreadsheetRows, .rewriteSpreadsheet:
            return "你是要操作 \(joinedNames) 这几个表格中的哪一个？"
        case .replaceDocumentSection, .insertDocumentSection, .rewriteDocument:
            return "你是要修改 \(joinedNames) 这几个文档中的哪一个？"
        case .readDocument, .summarizeDocument, .compareFiles, .exportDocument:
            return "你说的是 \(joinedNames) 里的哪一个文件？"
        case .unknown:
            return "你想操作的是 \(joinedNames) 里的哪一个文件？"
        }
    }

    private func writeConfirmationQuestion(
        for intent: FileIntentKind,
        text: String,
        target: FileIntentCandidate?,
        ambiguousCandidates: [FileIntentCandidate]
    ) -> String? {
        guard ambiguousCandidates.isEmpty else { return nil }
        guard let target else { return nil }
        guard target.source != .attachment else { return nil }
        guard let targetPath = target.path, FileManager.default.fileExists(atPath: targetPath) else { return nil }
        guard shouldRequireWriteConfirmation(for: intent, text: text) else { return nil }

        switch intent {
        case .createFiles:
            return nil
        case .deleteFiles:
            return "我准备删除现有文件 \(target.name)，要继续吗？"
        case .renameFiles:
            return "我准备重命名现有文件 \(target.name)，要继续吗？"
        case .buildWebPage:
            return "我准备直接覆盖现有网页文件 \(target.name) 的内容，要继续吗？"
        case .rewriteDocument:
            return "我准备直接覆盖现有文档 \(target.name) 的内容，要继续吗？"
        case .rewriteSpreadsheet:
            return "我准备直接覆盖现有表格 \(target.name) 的内容，要继续吗？"
        case .replaceDocumentSection:
            return "我准备修改 \(target.name) 里的现有章节内容，要继续吗？"
        case .insertDocumentSection:
            return "我准备在 \(target.name) 里插入一个新章节，要继续吗？"
        case .appendSpreadsheetRows:
            return "我准备往 \(target.name) 追加新行数据，要继续吗？"
        case .updateSpreadsheetCell:
            return "我准备修改 \(target.name) 的现有单元格，要继续吗？"
        case .exportDocument, .readDocument, .summarizeDocument, .compareFiles, .unknown:
            return nil
        }
    }

    private func shouldRequireWriteConfirmation(for intent: FileIntentKind, text: String) -> Bool {
        let normalized = text.lowercased()
        if containsAny(normalized, ["确认", "继续", "可以直接", "就这么做", "直接覆盖", "覆盖掉", "覆盖它"]) {
            return false
        }

        switch intent {
        case .deleteFiles:
            return true
        case .renameFiles:
            return containsAny(normalized, ["这个", "那个", "刚才", "上一个", "上一版", "现有", "原来", "已有", "批量"])
        case .createFiles:
            return false
        case .buildWebPage:
            return containsAny(normalized, ["这个", "那个", "刚才", "上一个", "上一版", "现有", "原来", "已有", "重写", "覆盖", "改写"])
        case .rewriteDocument, .rewriteSpreadsheet:
            return true
        case .replaceDocumentSection, .insertDocumentSection, .appendSpreadsheetRows, .updateSpreadsheetCell:
            return containsAny(normalized, ["这个", "那个", "刚才", "上一个", "上一版", "现有", "原来", "已有"])
        case .exportDocument, .readDocument, .summarizeDocument, .compareFiles, .unknown:
            return false
        }
    }

    private func extractTargetExtension(from text: String) -> String? {
        let patterns = [
            #"改成\s*([A-Za-z0-9]+)\s*后缀"#,
            #"后缀改成\s*([A-Za-z0-9]+)"#,
            #"扩展名改成\s*([A-Za-z0-9]+)"#,
            #"改成\s*\.?([A-Za-z0-9]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { continue }
            let value = (text as NSString).substring(with: match.range(at: 1)).lowercased()
            if !value.isEmpty, value.count <= 10 {
                return value
            }
        }
        return nil
    }

    private func extractCellReference(from text: String) -> String? {
        guard let range = text.range(of: #"[A-Za-z]+[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range]).uppercased()
    }

    private func extractSheetName(from text: String) -> String? {
        let patterns = [
            #"[“\"]?([A-Za-z0-9_\-\u4e00-\u9fa5 ]+)[”\"]?\s*的\s*[A-Za-z]+[0-9]+"#,
            #"工作表\s*[“\"]?([A-Za-z0-9_\-\u4e00-\u9fa5 ]+)[”\"]?"#,
            #"sheet\s*[“\"]?([A-Za-z0-9_\-\u4e00-\u9fa5 ]+)[”\"]?"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { continue }
            let raw = (text as NSString).substring(with: match.range(at: 1))
            let value = cleanSheetName(raw)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func cleanSheetName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["把这个表格", "把那个表格", "这个表格", "那个表格", "这个工作表", "那个工作表", "工作表", "sheet", "把这个", "把那个", "这个", "那个", "把"]
        for prefix in prefixes where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.contains(" ") {
            value = value.split(separator: " ").last.map(String.init) ?? value
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inferredSheetName(from text: String, recentContext: RecentOperationContext?) -> String? {
        guard let recentSheet = recentContext?.sheetName,
              containsAny(text.lowercased(), ["继续", "还是这个表", "同一个表", "下一列", "下一行", "上一列", "上一行", "这个表"]) else {
            return nil
        }
        return recentSheet
    }

    private func extractAssignedValue(from text: String) -> String? {
        let patterns = [
            #"(?:改成|改为|设为|更新为|写成|填成|替换为)\s*[“\"]?(.+?)[”\"]?(?:[，。,.\n]|$)"#,
            #"(?:改到|设成)\s*[“\"]?(.+?)[”\"]?(?:[，。,.\n]|$)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { continue }
            let raw = (text as NSString).substring(with: match.range(at: 1))
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private func inferredCellReference(from text: String, recentContext: RecentOperationContext?) -> String? {
        guard let recentCell = recentContext?.cell else { return nil }
        let normalized = text.lowercased()
        if normalized.contains("下一列") {
            return shiftedCell(from: recentCell, columnDelta: 1, rowDelta: 0)
        }
        if normalized.contains("上一列") {
            return shiftedCell(from: recentCell, columnDelta: -1, rowDelta: 0)
        }
        if normalized.contains("下一行") {
            return shiftedCell(from: recentCell, columnDelta: 0, rowDelta: 1)
        }
        if normalized.contains("上一行") {
            return shiftedCell(from: recentCell, columnDelta: 0, rowDelta: -1)
        }
        return nil
    }

    private func extractSectionTitle(from text: String, keywords: [String]) -> String? {
        if let quoted = extractQuotedTitle(before: "章节", in: text) {
            return quoted
        }

        for keyword in keywords {
            let escapedKeyword = NSRegularExpression.escapedPattern(for: keyword)
            let pattern = escapedKeyword + #"\s*([A-Za-z0-9_\-\u4e00-\u9fa5]+)\s*章节"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { continue }
            let title = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private func inferredSectionTitle(from text: String, recentContext: RecentOperationContext?) -> String? {
        guard containsAny(text.lowercased(), ["这一章", "这章", "这个章节"]) else { return nil }
        return recentContext?.insertedSectionTitle ?? recentContext?.sectionTitle
    }

    private func extractAfterSectionTitle(from text: String) -> String? {
        if let range = text.range(of: #"在\s*[“\"]?([A-Za-z0-9_\-\u4e00-\u9fa5 ]+)[”\"]?\s*后面"#, options: .regularExpression) {
            let snippet = String(text[range])
            if let quoted = extractQuotedTitle(before: "后面", in: snippet) {
                return quoted
            }
            let cleaned = snippet
                .replacingOccurrences(of: "在", with: "")
                .replacingOccurrences(of: "后面", with: "")
                .replacingOccurrences(of: "“", with: "")
                .replacingOccurrences(of: "”", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || ["这一章", "这章", "这个章节"].contains(cleaned) {
                return nil
            }
            return cleaned
        }
        return nil
    }

    private func inferredAfterSectionTitle(from text: String, recentContext: RecentOperationContext?) -> String? {
        guard containsAny(text.lowercased(), ["后面再", "这章后面", "这一章后面", "后面补", "后面加"]) else { return nil }
        if let inserted = recentContext?.insertedSectionTitle, inserted != "文末" {
            return inserted
        }
        if let section = recentContext?.sectionTitle, section != "文末" {
            return section
        }
        return nil
    }

    private func extractQuotedTitle(before suffix: String, in text: String) -> String? {
        let pattern = #"[“\"]([^“”\"]+)[”\"]\s*"# + NSRegularExpression.escapedPattern(for: suffix)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        let title = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func shiftedCell(from cell: String, columnDelta: Int, rowDelta: Int) -> String? {
        guard let parsed = parseCellReference(cell) else { return nil }
        let newColumn = parsed.column + columnDelta
        let newRow = parsed.row + rowDelta
        guard newColumn >= 1, newRow >= 1 else { return nil }
        return "\(columnLetters(for: newColumn))\(newRow)"
    }

    private func parseCellReference(_ cell: String) -> (column: Int, row: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"^([A-Za-z]+)([0-9]+)$"#, options: []) else {
            return nil
        }
        let nsText = cell.uppercased() as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: nsText as String, range: range), match.numberOfRanges == 3 else {
            return nil
        }

        let letters = nsText.substring(with: match.range(at: 1))
        let digits = nsText.substring(with: match.range(at: 2))
        guard !letters.isEmpty, let row = Int(digits) else { return nil }

        var column = 0
        for scalar in letters.unicodeScalars {
            let value = Int(scalar.value)
            guard value >= 65, value <= 90 else { return nil }
            column = column * 26 + (value - 64)
        }
        return (column, row)
    }

    private func columnLetters(for index: Int) -> String {
        var value = index
        var letters = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            letters = String(UnicodeScalar(remainder + 65)!) + letters
            value = (value - 1) / 26
        }
        return letters
    }

    private func explicitFileName(in text: String) -> String? {
        let pattern = #"[A-Za-z0-9_\-\u4e00-\u9fa5]+?\.(docx|xlsx|pdf|pptx|txt|md|csv|json|xml|yaml|yml|html|css|js)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (text as NSString).substring(with: match.range)
    }

    private func recentOperationContext(for conversation: Conversation) -> RecentOperationContext? {
        guard let operation = conversation.recentOperations.first else { return nil }

        func detail(_ prefix: String) -> String? {
            operation.detailLines.first(where: { $0.hasPrefix(prefix) })?
                .replacingOccurrences(of: prefix, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return RecentOperationContext(
            targetPath: detail("目标："),
            toolName: operation.toolName,
            sheetName: detail("工作表："),
            cell: detail("单元格："),
            sectionTitle: detail("章节："),
            insertedSectionTitle: detail("新章节："),
            insertedAfterSectionTitle: detail("插入位置：")
        )
    }

    private func shouldPreferRecentOperation(for normalizedText: String, intent: FileIntentKind) -> Bool {
        let continuationPhrases = ["继续", "还是这个", "同一个", "接着", "下一列", "下一行", "上一列", "上一行", "这个表", "这个文档", "这一章", "这章"]
        guard containsAny(normalizedText, continuationPhrases) else { return false }

        switch intent {
        case .createFiles, .renameFiles, .deleteFiles:
            return true
        case .buildWebPage,
             .updateSpreadsheetCell, .appendSpreadsheetRows, .rewriteSpreadsheet,
             .replaceDocumentSection, .insertDocumentSection, .rewriteDocument:
            return true
        case .exportDocument, .readDocument, .summarizeDocument, .compareFiles, .unknown:
            return false
        }
    }

    private func scanWorkspaceCandidates(root: String, limit: Int) -> [FileIntentCandidate] {
        var candidates: [FileIntentCandidate] = []
        var count = 0
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            if skippedDirectoryNames.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard count < limit else { break }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else {
                continue
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            guard relevantExtensions.contains(ext) else { continue }
            candidates.append(makePathCandidate(path: fileURL.path, source: .workspace))
            count += 1
        }
        return candidates
    }

    private func makePathCandidate(path: String, source: FileIntentCandidate.Source) -> FileIntentCandidate {
        let fileURL = URL(fileURLWithPath: path)
        let ext = fileURL.pathExtension.lowercased()
        return FileIntentCandidate(
            name: fileURL.lastPathComponent,
            path: path,
            type: ext.isEmpty ? "file" : ext,
            source: source,
            attachmentID: nil
        )
    }

    private func uniqueCandidates(_ candidates: [FileIntentCandidate]) -> [FileIntentCandidate] {
        var seen = Set<String>()
        var results: [FileIntentCandidate] = []
        for candidate in candidates {
            let key = "\(candidate.source)|\(candidate.path ?? candidate.attachmentID ?? candidate.name)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(candidate)
        }
        return results
    }

    private func bestCandidate(
        in candidates: [FileIntentCandidate],
        for normalizedText: String,
        messageHints: [String]
    ) -> FileIntentCandidate? {
        let defaultScoreContext = FileIntentScoreContext(currentAttachmentID: nil, recentTargetPath: nil)
        return candidates.max { lhs, rhs in
            score(for: lhs, normalizedText: normalizedText, messageHints: messageHints, scoreContext: defaultScoreContext)
                < score(for: rhs, normalizedText: normalizedText, messageHints: messageHints, scoreContext: defaultScoreContext)
        }
    }

    private func bestResolution(
        in candidates: [FileIntentCandidate],
        for normalizedText: String,
        messageHints: [String],
        containsGenericReference: Bool,
        scoreContext: FileIntentScoreContext
    ) -> FileIntentResolution {
        let scored = candidates
            .map { ($0, score(for: $0, normalizedText: normalizedText, messageHints: messageHints, scoreContext: scoreContext)) }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
                }
                return lhs.1 > rhs.1
            }

        guard let first = scored.first, first.1 > 0 else {
            return FileIntentResolution(primary: nil, ambiguousCandidates: [])
        }

        if containsGenericReference, scored.count >= 2 {
            let second = scored[1]
            let closeScores = first.1 - second.1 <= 15
            if closeScores {
                return FileIntentResolution(primary: nil, ambiguousCandidates: [first.0, second.0])
            }
        }

        return FileIntentResolution(primary: first.0, ambiguousCandidates: [])
    }

    private func score(
        for candidate: FileIntentCandidate,
        normalizedText: String,
        messageHints: [String],
        scoreContext: FileIntentScoreContext
    ) -> Int {
        var score = 0
        let normalizedName = candidate.name.lowercased()
        let stem = normalizedName.replacingOccurrences(of: "." + (candidate.name as NSString).pathExtension.lowercased(), with: "")
        let hasCurrentReference = containsAny(normalizedText, ["这个", "这份", "当前", "刚上传", "上传的", "刚才", "上一个", "上一版"])

        switch candidate.source {
        case .recentOperation:
            score += 40
        case .attachment:
            score += 30
        case .workspace:
            score += 10
        }

        if normalizedText.contains(normalizedName) || (!stem.isEmpty && normalizedText.contains(stem)) {
            score += 100
        }

        if hasCurrentReference {
            if candidate.attachmentID == scoreContext.currentAttachmentID {
                score += 90
            }
            if candidate.path == scoreContext.recentTargetPath {
                score += 80
            }
        }

        if containsAny(normalizedText, ["这个", "这份", "刚才", "刚刚", "上一个", "上一版", "那个"]) {
            for (index, hint) in messageHints.enumerated() {
                if hint.contains(normalizedName) || (!stem.isEmpty && hint.contains(stem)) {
                    score += max(0, 80 - index * 10)
                    break
                }
            }
        }

        if isSpreadsheetCandidate(candidate), containsAny(normalizedText, ["表", "表格", "sheet", "excel", "xlsx", "单元格"]) {
            score += 20
        }
        if isWordCandidate(candidate), containsAny(normalizedText, ["文档", "word", "docx", "章节", "小节", "部分"]) {
            score += 20
        }
        if isWebCandidate(candidate), containsAny(normalizedText, ["网页", "页面", "网站", "html", "css", "js", "javascript", "前端", "样式", "脚本"]) {
            score += 22
        }
        if candidate.type.contains("pdf") || normalizedName.hasSuffix(".pdf"), containsAny(normalizedText, ["pdf", "页", "扫描"]) {
            score += 15
        }

        if candidate.attachmentID == scoreContext.currentAttachmentID,
           containsAny(normalizedText, ["pdf", "图片", "文档", "文件", "附件", "这个pdf", "这个文档", "这个文件"]) {
            score += 25
        }

        return score
    }

    private func recentMessageHints(from conversation: Conversation, candidates: [FileIntentCandidate]) -> [String] {
        let candidateTerms = Set(candidates.flatMap { candidate -> [String] in
            let name = candidate.name.lowercased()
            let ext = (candidate.name as NSString).pathExtension.lowercased()
            let stem = name.replacingOccurrences(of: ext.isEmpty ? "" : ".\(ext)", with: "")
            return [name, stem].filter { !$0.isEmpty }
        })

        let recentMessages = conversation.messages.suffix(8).map { $0.content.lowercased() }.reversed()
        var hints: [String] = []
        for message in recentMessages {
            for term in candidateTerms where message.contains(term) {
                hints.append(term)
            }
        }
        return hints
    }

    private func isSpreadsheetCandidate(_ candidate: FileIntentCandidate) -> Bool {
        candidate.type.contains("xlsx") || candidate.name.lowercased().hasSuffix(".xlsx") || candidate.type.contains("excel")
    }

    private func isWordCandidate(_ candidate: FileIntentCandidate) -> Bool {
        candidate.type.contains("docx") || candidate.name.lowercased().hasSuffix(".docx") || candidate.type.contains("word")
    }

    private func isWebCandidate(_ candidate: FileIntentCandidate) -> Bool {
        let normalized = candidate.name.lowercased()
        return ["html", "css", "js"].contains(candidate.type)
            || normalized.hasSuffix(".html")
            || normalized.hasSuffix(".css")
            || normalized.hasSuffix(".js")
    }

    private func inferredWebProjectFiles(from text: String) -> (html: String, css: String, js: String) {
        let explicit = extractExplicitWebFileNames(from: text)
        return (
            html: explicit["html"] ?? "index.html",
            css: explicit["css"] ?? "styles.css",
            js: explicit["js"] ?? "script.js"
        )
    }

    private func extractExplicitWebFileNames(from text: String) -> [String: String] {
        let pattern = #"[A-Za-z0-9_\-\u4e00-\u9fa5]+?\.(html|css|js)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [:]
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)

        var result: [String: String] = [:]
        for match in matches {
            let fileName = (text as NSString).substring(with: match.range)
            let ext = (fileName as NSString).pathExtension.lowercased()
            if result[ext] == nil {
                result[ext] = fileName
            }
        }
        return result
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

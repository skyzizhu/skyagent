import Foundation
import AppKit
import PDFKit
import Darwin

class ToolRunner {
    static let shared = ToolRunner()

    /// 当前会话的权限模式
    var permissionMode: FilePermissionMode = .sandbox
    /// 当前会话工作目录（绝对路径，不带尾部斜杠）
    var sandboxDir: String
    private let undoBaseDir: String
    private let compatibilityBinDir: String
    private let skillManager: SkillManager
    private let attachmentStore: UploadedAttachmentStore
    private let validationService: FileValidationService
    private let webContentFetcher: WebContentFetcher
    private var allowedReadRoots: [String] = []
    private var activeSkillIDs: [String] = []
    private var activeAttachmentIDs: [String] = []
    private var currentConversationID: UUID?
    private var cachedDocumentPythonPath: String?
    private var cachedDocumentPythonModules: [String: Bool]?
    private let documentCapabilityLock = NSLock()
    private var isDocumentCapabilityWarmupInFlight = false
    private let activeProcessLock = NSLock()
    private var activeProcess: Process?
    private var latestAssistantDraft = ""
    private let largeToolVisibleOutputLimit = 24_000
    private let largeToolModelOutputLimit = 8_000

    private final class PipeCollector {
        private let lock = NSLock()
        private var buffer = Data()
        private var pendingLineBuffer = Data()
        private let onLine: ((String) -> Void)?

        init(onLine: ((String) -> Void)? = nil) {
            self.onLine = onLine
        }

        func attach(to pipe: Pipe) {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
                emitLines(from: chunk, flushIncompleteLine: false)
            }
        }

        func finishReading(from pipe: Pipe) -> String {
            pipe.fileHandleForReading.readabilityHandler = nil
            let tail = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            buffer.append(tail)
            let data = buffer
            lock.unlock()
            emitLines(from: tail, flushIncompleteLine: true)
            return String(data: data, encoding: .utf8) ?? ""
        }

        private func emitLines(from chunk: Data, flushIncompleteLine: Bool) {
            guard let onLine else { return }

            lock.lock()
            pendingLineBuffer.append(chunk)

            while let newlineIndex = pendingLineBuffer.firstIndex(of: 0x0A) {
                let lineData = pendingLineBuffer.prefix(upTo: newlineIndex)
                pendingLineBuffer.removeSubrange(...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    lock.unlock()
                    onLine(line)
                    lock.lock()
                }
            }

            if flushIncompleteLine, !pendingLineBuffer.isEmpty {
                if let line = String(data: pendingLineBuffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    pendingLineBuffer.removeAll(keepingCapacity: true)
                    lock.unlock()
                    onLine(line)
                    lock.lock()
                } else {
                    pendingLineBuffer.removeAll(keepingCapacity: true)
                }
            }

            lock.unlock()
        }
    }

    init(
        skillManager: SkillManager = .shared,
        attachmentStore: UploadedAttachmentStore = .shared,
        validationService: FileValidationService = .shared,
        webContentFetcher: WebContentFetcher = .shared
    ) {
        self.skillManager = skillManager
        self.attachmentStore = attachmentStore
        self.validationService = validationService
        self.webContentFetcher = webContentFetcher
        AppStoragePaths.migrateLegacyDataIfNeeded()
        let settings = AppSettings.load()
        self.sandboxDir = settings.ensureSandboxDir()
        self.undoBaseDir = AppStoragePaths.undoDir.path
        self.compatibilityBinDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".skyagent/bin").path
        try? FileManager.default.createDirectory(atPath: undoBaseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: compatibilityBinDir, withIntermediateDirectories: true)
        ensureCompatibilityShims()
        preloadDocumentCapabilitiesIfNeeded()
    }

    /// 切换到指定会话的权限设置
    func configure(for conversation: Conversation, globalSandboxDir: String, allowedReadRoots: [String] = []) {
        self.permissionMode = conversation.filePermissionMode
        self.currentConversationID = conversation.id
        let dir = conversation.sandboxDir.isEmpty ? globalSandboxDir : conversation.sandboxDir
        self.sandboxDir = canonicalExistingPath(dir)
        self.allowedReadRoots = allowedReadRoots.map(canonicalPathForComparison)
        self.activeSkillIDs = conversation.activatedSkillIDs
        self.activeAttachmentIDs = conversation.messages.compactMap(\.attachmentID)
        self.latestAssistantDraft = conversation.messages.last(where: { $0.role == .assistant })?.content ?? ""
        try? FileManager.default.createDirectory(atPath: sandboxDir, withIntermediateDirectories: true)
    }

    private func logExecutionEvent(
        level: LogLevel = .info,
        category: LogCategory,
        event: String,
        operationId: String?,
        status: LogStatus? = nil,
        durationMs: Double? = nil,
        summary: String,
        metadata: [String: LogValue] = [:]
    ) {
        let traceContext = TraceContext(
            conversationID: currentConversationID,
            operationID: operationId
        )
        Task {
            await LoggerService.shared.log(
                level: level,
                category: category,
                event: event,
                traceContext: traceContext,
                status: status,
                durationMs: durationMs,
                summary: summary,
                metadata: metadata
            )
        }
    }

    func cancelActiveExecution() {
        activeProcessLock.lock()
        let process = activeProcess
        activeProcessLock.unlock()

        guard let process, process.isRunning else { return }
        _ = terminateProcess(process, graceSeconds: 1)
    }

    // MARK: - Tool Execution

    func previewExecution(name: String, arguments: String, operationId: String) -> OperationPreview? {
        guard let tool = ToolDefinition.ToolName(rawValue: name),
              let params = decodeParams(arguments, for: tool) else { return nil }

        switch tool {
        case .writeFile:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: exists ? "确认覆盖文件" : "确认新建文件",
                summary: exists ? "将覆盖已有文件内容" : "将在当前会话目录创建新文件",
                detailLines: [
                    "工具：write_file",
                    "目标：\(path)",
                    exists ? "影响：原文件内容会被替换" : "影响：会新增一个文件"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .writeAssistantContentToFile:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: exists ? "确认写入助手正文并覆盖文件" : "确认将助手正文写入文件",
                summary: exists ? "会用当前轮 assistant 正文覆盖已有文件" : "会把当前轮 assistant 正文保存为新文件",
                detailLines: [
                    "工具：write_assistant_content_to_file",
                    "目标：\(path)",
                    exists ? "影响：原文件内容会被替换" : "影响：会新增一个文件"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .writeMultipleFiles:
            let files = params["files"] as? [[String: Any]] ?? []
            let resolvedTargets = files.compactMap { file -> String? in
                guard let path = file["path"] as? String, !path.isEmpty else { return nil }
                return resolvePath(path)
            }
            let overwriteCount = resolvedTargets.filter { FileManager.default.fileExists(atPath: $0) }.count
            let previewLines = resolvedTargets.prefix(3).map { "目标：\($0)" }
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: overwriteCount > 0 ? "确认批量覆盖文件" : "确认批量创建文件",
                summary: "将一次写入 \(resolvedTargets.count) 个文件",
                detailLines: [
                    "工具：write_multiple_files",
                    "文件数：\(resolvedTargets.count)",
                    overwriteCount > 0 ? "影响：其中 \(overwriteCount) 个文件会被覆盖" : "影响：将批量创建新文件"
                ] + previewLines,
                isDestructive: overwriteCount > 0,
                canUndo: false
            )

        case .writeDOCX:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: exists ? "确认覆盖 Word 文件" : "确认创建 Word 文件",
                summary: exists ? "将覆盖现有 DOCX 内容" : "将在当前会话目录创建新的 DOCX 文件",
                detailLines: [
                    "工具：write_docx",
                    "目标：\(path)",
                    exists ? "影响：现有文档内容会被替换" : "影响：会新增一个 Word 文件"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .writeXLSX:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: exists ? "确认覆盖 Excel 文件" : "确认创建 Excel 文件",
                summary: exists ? "将覆盖现有 XLSX 内容" : "将在当前会话目录创建新的 XLSX 文件",
                detailLines: [
                    "工具：write_xlsx",
                    "目标：\(path)",
                    exists ? "影响：现有工作簿内容会被替换" : "影响：会新增一个 Excel 文件"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .replaceDOCXSection:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: "确认更新 Word 章节",
                summary: exists ? "将修改现有 DOCX 中的指定章节" : "目标 DOCX 不存在，无法更新章节",
                detailLines: [
                    "工具：replace_docx_section",
                    "目标：\(path)",
                    "章节：\(params["section_title"] as? String ?? "(未指定)")"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .insertDOCXSection:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: "确认插入 Word 章节",
                summary: exists ? "将向现有 DOCX 插入一个新章节" : "目标 DOCX 不存在，无法插入章节",
                detailLines: [
                    "工具：insert_docx_section",
                    "目标：\(path)",
                    "新章节：\(params["section_title"] as? String ?? "(未指定)")",
                    "插入位置：\(params["after_section_title"] as? String ?? "文末")"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .appendXLSXRows:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: "确认更新 Excel 工作表",
                summary: exists ? "将向现有 XLSX 工作表追加行数据" : "目标 XLSX 不存在，无法追加数据",
                detailLines: [
                    "工具：append_xlsx_rows",
                    "目标：\(path)",
                    "工作表：\(params["sheet_name"] as? String ?? "(未指定)")"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .updateXLSXCell:
            let path = resolvePath(params["path"] as? String ?? "")
            let exists = FileManager.default.fileExists(atPath: path)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: "确认更新 Excel 单元格",
                summary: exists ? "将修改现有 XLSX 的指定单元格内容" : "目标 XLSX 不存在，无法更新单元格",
                detailLines: [
                    "工具：update_xlsx_cell",
                    "目标：\(path)",
                    "工作表：\(params["sheet_name"] as? String ?? "(未指定)")",
                    "单元格：\(params["cell"] as? String ?? "(未指定)")"
                ],
                isDestructive: exists,
                canUndo: true
            )

        case .importFile:
            let source = resolveExternalPath(params["source_path"] as? String ?? "")
            let destination = resolvePath(sanitizedWorkspaceRelativePath(params["destination_path"] as? String, fallbackName: (source as NSString).lastPathComponent))
            let willOverwrite = (params["overwrite"] as? Bool ?? false) || FileManager.default.fileExists(atPath: destination)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: willOverwrite ? "确认覆盖并导入文件" : "确认导入文件",
                summary: willOverwrite ? "将用外部文件覆盖当前会话目录中的目标文件" : "将从外部复制文件到当前会话目录",
                detailLines: [
                    "来源：\(source)",
                    "目标：\(destination)",
                    "说明：只会复制，不会删除外部原文件"
                ],
                isDestructive: willOverwrite,
                canUndo: true
            )

        case .importDirectory:
            let source = resolveExternalPath(params["source_path"] as? String ?? "")
            let destination = resolvePath(sanitizedWorkspaceRelativePath(params["destination_path"] as? String, fallbackName: (source as NSString).lastPathComponent))
            let willOverwrite = (params["overwrite"] as? Bool ?? false) || FileManager.default.fileExists(atPath: destination)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: willOverwrite ? "确认覆盖并导入目录" : "确认导入目录",
                summary: willOverwrite ? "将用外部目录内容覆盖目标目录" : "将从外部递归复制目录到当前会话目录",
                detailLines: [
                    "来源：\(source)",
                    "目标：\(destination)",
                    "说明：只会复制，不会删除外部原目录"
                ],
                isDestructive: willOverwrite,
                canUndo: true
            )

        case .exportFile:
            let source = resolvePath(params["source_path"] as? String ?? "")
            let destination = resolveExternalPath(params["destination_path"] as? String ?? "")
            let willOverwrite = (params["overwrite"] as? Bool ?? false) || FileManager.default.fileExists(atPath: destination)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: willOverwrite ? "确认覆盖并导出文件" : "确认导出文件",
                summary: willOverwrite ? "将覆盖会话目录外的目标文件" : "将把当前会话文件复制到外部路径",
                detailLines: [
                    "来源：\(source)",
                    "目标：\(destination)",
                    "提醒：这会影响当前会话目录之外的路径"
                ],
                isDestructive: true,
                canUndo: true
            )

        case .exportDirectory:
            let source = resolvePath(params["source_path"] as? String ?? "")
            let destination = resolveExternalPath(params["destination_path"] as? String ?? "")
            let willOverwrite = (params["overwrite"] as? Bool ?? false) || FileManager.default.fileExists(atPath: destination)
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: willOverwrite ? "确认覆盖并导出目录" : "确认导出目录",
                summary: willOverwrite ? "将覆盖会话目录外的目标目录" : "将把当前会话目录递归复制到外部路径",
                detailLines: [
                    "来源：\(source)",
                    "目标：\(destination)",
                    "提醒：这会影响当前会话目录之外的路径"
                ],
                isDestructive: true,
                canUndo: true
            )

        case .shell:
            let command = params["command"] as? String ?? ""
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: "确认执行 Shell",
                summary: "将执行一条 shell 命令",
                detailLines: [
                    "工作目录：\(sandboxDir)",
                    "命令：\(command)"
                ],
                isDestructive: true,
                canUndo: false
            )

        case .activateSkill:
            let name = params["name"] as? String ?? ""
            return OperationPreview(
                id: operationId,
                toolName: name,
                title: "确认激活 Skill",
                summary: "将为当前会话加载外部 Agent Skill：\(name)",
                detailLines: [
                    "工具：activate_skill",
                    "Skill：\(name)"
                ],
                isDestructive: false,
                canUndo: false
            )

        case .installSkill:
            let url = params["url"] as? String ?? ""
            let repo = params["repo"] as? String ?? ""
            let path = params["path"] as? String ?? ""
            let name = params["name"] as? String ?? ""
            let source = !url.isEmpty ? url : repo
            return OperationPreview(
                id: operationId,
                toolName: name.isEmpty ? ToolDefinition.ToolName.installSkill.rawValue : name,
                title: "确认下载并安装 Skill",
                summary: "将下载新的 skill 并安装到 ~/.skyagent/skills",
                detailLines: [
                    "来源：\(source.isEmpty ? "(未指定)" : source)",
                    "路径：\(path.isEmpty ? "(仓库根目录)" : path)",
                    "安装目录：\(name.isEmpty ? "(使用 skill 目录名)" : name)",
                    "目标仓库：~/.skyagent/skills"
                ],
                isDestructive: false,
                canUndo: true
            )

        case .readSkillResource:
            return nil

        case .runSkillScript:
            return nil

        case .readUploadedAttachment:
            return nil

        case .previewImage:
            return nil

        default:
            return nil
        }
    }

    private enum PreparedExecution {
        case ready(tool: ToolDefinition.ToolName, params: [String: Any])
        case rejected(ToolExecutionOutcome)
    }

    func execute(
        name: String,
        arguments: String,
        operationId: String,
        assistantContentOverride: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async -> ToolExecutionOutcome {
        switch prepareExecution(name: name, arguments: arguments) {
        case .rejected(let outcome):
            return outcome
        case .ready(let tool, let params):
            if tool == .webFetch {
                let fetchResult = await webFetch(params["url"] as? String ?? "")
                let outcome = ToolExecutionOutcome(
                    output: fetchResult.visibleOutput,
                    modelOutput: fetchResult.modelOutput,
                    operation: nil,
                    followupContextMessage: fetchResult.followupContextMessage
                )
                let normalized = normalizedLargeOutputOutcome(outcome, for: tool)
                return advisedOutcome(for: normalized, tool: tool, params: params)
            }
            if tool == .webSearch {
                let searchResult = await webSearch(
                    params["query"] as? String ?? "",
                    limit: params["limit"] as? Int,
                    engine: params["engine"] as? String
                )
                let outcome = ToolExecutionOutcome(
                    output: searchResult.visibleOutput,
                    modelOutput: searchResult.modelOutput,
                    operation: nil,
                    followupContextMessage: searchResult.followupContextMessage
                )
                let normalized = normalizedLargeOutputOutcome(outcome, for: tool)
                return advisedOutcome(for: normalized, tool: tool, params: params)
            }
            let outcome = await executePreparedAsync(
                tool: tool,
                params: params,
                operationId: operationId,
                assistantContentOverride: assistantContentOverride,
                onProgress: onProgress
            )
            let normalized = normalizedLargeOutputOutcome(outcome, for: tool)
            return advisedOutcome(for: normalized, tool: tool, params: params)
        }
    }

    func executeBlocking(
        name: String,
        arguments: String,
        operationId: String,
        assistantContentOverride: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) -> ToolExecutionOutcome {
        switch prepareExecution(name: name, arguments: arguments) {
        case .rejected(let outcome):
            return outcome
        case .ready(let tool, let params):
            let outcome = executePrepared(
                tool: tool,
                params: params,
                operationId: operationId,
                assistantContentOverride: assistantContentOverride,
                onProgress: onProgress
            )
            let normalized = normalizedLargeOutputOutcome(outcome, for: tool)
            return advisedOutcome(for: normalized, tool: tool, params: params)
        }
    }

    private func prepareExecution(name: String, arguments: String) -> PreparedExecution {
        guard let tool = ToolDefinition.ToolName(rawValue: name) else {
            return .rejected(ToolExecutionOutcome(output: "[错误] 未知工具: \(name)", operation: nil))
        }
        guard let params = decodeParams(arguments, for: tool) else {
            return .rejected(ToolExecutionOutcome(output: argumentParsingFailureMessage(for: tool, rawArguments: arguments), operation: nil))
        }

        // 危险命令检查（所有模式都生效）
        if tool == .shell {
            let cmd = params["command"] as? String ?? ""
            if permissionMode == .sandbox {
                return .rejected(advisedOutcome(
                    for: ToolExecutionOutcome(output: "⚠️ 当前为沙盒模式，不能使用 shell 工具。请改用 read_file、write_file、list_files 等文件工具，或切换到开放模式。", operation: nil),
                    tool: tool,
                    params: params
                ))
            }
            if let bypassMessage = shellBypassMessageIfNeeded(command: cmd) {
                return .rejected(advisedOutcome(
                    for: ToolExecutionOutcome(output: bypassMessage, operation: nil),
                    tool: tool,
                    params: params
                ))
            }
            if Self.isDangerous(command: cmd) {
                return .rejected(advisedOutcome(
                    for: ToolExecutionOutcome(output: "⚠️ 操作被拒绝：该命令可能存在危险（\(cmd)）。如需执行，请修改命令后重试。", operation: nil),
                    tool: tool,
                    params: params
                ))
            }
        }

        // 沙盒模式：检查路径权限
        if permissionMode == .sandbox {
            if let violation = checkSandboxViolation(tool: tool, params: params) {
                return .rejected(advisedOutcome(
                    for: ToolExecutionOutcome(output: violation, operation: nil),
                    tool: tool,
                    params: params
                ))
            }
        }

        return .ready(tool: tool, params: params)
    }

    private func executePrepared(
        tool: ToolDefinition.ToolName,
        params: [String: Any],
        operationId: String,
        assistantContentOverride: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) -> ToolExecutionOutcome {
        let outcome: ToolExecutionOutcome
        switch tool {
        case .shell:
            outcome = ToolExecutionOutcome(output: runShell(params["command"] as? String ?? "", operationId: operationId, onProgress: onProgress), operation: nil)
        case .readFile:
            outcome = ToolExecutionOutcome(output: readFile(params["path"] as? String ?? ""), operation: nil)
        case .previewImage:
            outcome = previewImage(
                singlePath: params["path"] as? String,
                paths: params["paths"] as? [String]
            )
        case .writeFile:
            outcome = writeFile(
                params["path"] as? String ?? "",
                content: params["content"] as? String ?? "",
                operationId: operationId
            )
        case .writeAssistantContentToFile:
            outcome = writeAssistantContentToFile(
                params["path"] as? String ?? "",
                assistantContent: assistantContentOverride,
                operationId: operationId,
                onProgress: onProgress
            )
        case .writeMultipleFiles:
            outcome = writeMultipleFiles(
                decodeFileBatch(params["files"]),
                operationId: operationId
            )
        case .movePaths:
            outcome = movePaths(
                decodeMoveBatch(params["items"]),
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .deletePaths:
            outcome = deletePaths(
                (params["paths"] as? [String]) ?? [],
                operationId: operationId
            )
        case .writeDOCX:
            outcome = writeDOCX(
                to: params["path"] as? String ?? "",
                title: params["title"] as? String,
                content: params["content"] as? String ?? "",
                images: decodeDOCXImages(params["images"]),
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .writeXLSX:
            outcome = writeXLSX(
                to: params["path"] as? String ?? "",
                sheets: decodeSpreadsheetSheets(params["sheets"]),
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .replaceDOCXSection:
            outcome = replaceDOCXSection(
                at: params["path"] as? String ?? "",
                sectionTitle: params["section_title"] as? String ?? "",
                content: params["content"] as? String ?? "",
                images: decodeDOCXImages(params["images"]),
                appendIfMissing: params["append_if_missing"] as? Bool ?? true,
                operationId: operationId
            )
        case .insertDOCXSection:
            outcome = insertDOCXSection(
                at: params["path"] as? String ?? "",
                sectionTitle: params["section_title"] as? String ?? "",
                content: params["content"] as? String ?? "",
                images: decodeDOCXImages(params["images"]),
                afterSectionTitle: params["after_section_title"] as? String,
                operationId: operationId
            )
        case .appendXLSXRows:
            outcome = appendXLSXRows(
                at: params["path"] as? String ?? "",
                sheetName: params["sheet_name"] as? String ?? "",
                rows: decodeSpreadsheetRows(params["rows"]),
                createSheetIfMissing: params["create_sheet_if_missing"] as? Bool ?? true,
                operationId: operationId
            )
        case .updateXLSXCell:
            outcome = updateXLSXCell(
                at: params["path"] as? String ?? "",
                sheetName: params["sheet_name"] as? String ?? "",
                cell: params["cell"] as? String ?? "",
                value: params["value"] as? String ?? "",
                createSheetIfMissing: params["create_sheet_if_missing"] as? Bool ?? true,
                operationId: operationId
            )
        case .webFetch:
            outcome = ToolExecutionOutcome(output: "[错误] web_fetch 需要异步执行", operation: nil)
        case .webSearch:
            outcome = ToolExecutionOutcome(output: "[错误] web_search 需要异步执行", operation: nil)
        case .listFiles:
            outcome = ToolExecutionOutcome(output: listFiles(params["path"] as? String ?? nil, recursive: params["recursive"] as? Bool ?? false), operation: nil)
        case .importFile:
            outcome = importFile(
                from: params["source_path"] as? String ?? "",
                to: params["destination_path"] as? String,
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .importDirectory:
            outcome = importDirectory(
                from: params["source_path"] as? String ?? "",
                to: params["destination_path"] as? String,
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .importFileContent:
            outcome = ToolExecutionOutcome(output: importFileContent(from: params["source_path"] as? String ?? ""), operation: nil)
        case .exportFile:
            outcome = exportFile(
                from: params["source_path"] as? String ?? "",
                to: params["destination_path"] as? String ?? "",
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .exportDirectory:
            outcome = exportDirectory(
                from: params["source_path"] as? String ?? "",
                to: params["destination_path"] as? String ?? "",
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .exportPDF:
            outcome = exportPDF(
                to: params["path"] as? String ?? "",
                title: params["title"] as? String,
                content: params["content"] as? String ?? "",
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .exportDOCX:
            outcome = exportDOCX(
                to: params["path"] as? String ?? "",
                title: params["title"] as? String,
                content: params["content"] as? String ?? "",
                images: decodeDOCXImages(params["images"]),
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .exportXLSX:
            outcome = exportXLSX(
                to: params["path"] as? String ?? "",
                sheets: decodeSpreadsheetSheets(params["sheets"]),
                overwrite: params["overwrite"] as? Bool ?? false,
                operationId: operationId
            )
        case .listExternalFiles:
            outcome = ToolExecutionOutcome(output: listExternalFiles(
                params["path"] as? String ?? "",
                recursive: params["recursive"] as? Bool ?? false
            ), operation: nil)
        case .activateSkill:
            outcome = activateSkill(named: params["name"] as? String ?? "", operationId: operationId)
        case .installSkill:
            outcome = installSkillBlocking(
                url: params["url"] as? String,
                repo: params["repo"] as? String,
                path: params["path"] as? String,
                ref: params["ref"] as? String,
                name: params["name"] as? String,
                operationId: operationId
            )
        case .readSkillResource:
            outcome = ToolExecutionOutcome(
                output: readSkillResource(
                    skillName: params["skill_name"] as? String ?? "",
                    relativePath: params["path"] as? String ?? ""
                ),
                operation: nil
            )
        case .readUploadedAttachment:
            outcome = ToolExecutionOutcome(
                output: readUploadedAttachment(
                    attachmentID: params["attachment_id"] as? String ?? "",
                    chunkIndex: params["chunk_index"] as? Int,
                    startChunk: params["start_chunk"] as? Int,
                    endChunk: params["end_chunk"] as? Int,
                    pageNumber: params["page_number"] as? Int,
                    pageStart: params["page_start"] as? Int,
                    pageEnd: params["page_end"] as? Int,
                    sheetIndex: params["sheet_index"] as? Int,
                    sheetName: params["sheet_name"] as? String,
                    segmentIndex: params["segment_index"] as? Int,
                    segmentTitle: params["segment_title"] as? String
                ),
                operation: nil
            )
        case .runSkillScript:
            outcome = runSkillScript(
                skillName: params["skill_name"] as? String ?? "",
                relativePath: params["path"] as? String ?? "",
                args: params["args"] as? [String] ?? [],
                stdin: params["stdin"] as? String,
                operationId: operationId,
                onProgress: onProgress
            )
        }
        return outcome
    }

    private func executePreparedAsync(
        tool: ToolDefinition.ToolName,
        params: [String: Any],
        operationId: String,
        assistantContentOverride: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async -> ToolExecutionOutcome {
        switch tool {
        case .installSkill:
            return await installSkill(
                url: params["url"] as? String,
                repo: params["repo"] as? String,
                path: params["path"] as? String,
                ref: params["ref"] as? String,
                name: params["name"] as? String,
                operationId: operationId
            )
        default:
            return executePrepared(
                tool: tool,
                params: params,
                operationId: operationId,
                assistantContentOverride: assistantContentOverride,
                onProgress: onProgress
            )
        }
    }

    private func normalizedLargeOutputOutcome(
        _ outcome: ToolExecutionOutcome,
        for tool: ToolDefinition.ToolName
    ) -> ToolExecutionOutcome {
        let text = outcome.output
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("[错误]"),
              !trimmed.hasPrefix("⚠️"),
              text.count > largeToolVisibleOutputLimit else {
            return outcome
        }

        let summary = summarizedLargeText(
            text,
            label: tool.rawValue,
            visibleCharacterLimit: largeToolVisibleOutputLimit,
            modelCharacterLimit: largeToolModelOutputLimit
        )

        let followupHint = """
        上一个工具结果过长，系统已自动摘要。
        请直接用自然语言继续回应用户，不要要求用户展开工具详情。
        如果用户是在做统计、计数、查多少个、列举桌面图片这类问题，优先返回总数和少量样例，不要再次输出完整长列表。
        """

        let clippedOriginalFollowup = outcome.followupContextMessage.map {
            String($0.prefix(largeToolModelOutputLimit))
        }
        let mergedFollowupContext = [clippedOriginalFollowup, followupHint]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return ToolExecutionOutcome(
            output: summary.visibleOutput,
            modelOutput: summary.modelOutput,
            operation: outcome.operation,
            activatedSkillID: outcome.activatedSkillID,
            skillContextMessage: outcome.skillContextMessage,
            followupContextMessage: mergedFollowupContext.isEmpty ? nil : mergedFollowupContext,
            previewImagePath: outcome.previewImagePath,
            previewImagePaths: outcome.previewImagePaths
        )
    }

    private func summarizedLargeText(
        _ text: String,
        label: String,
        visibleCharacterLimit: Int,
        modelCharacterLimit: Int
    ) -> (visibleOutput: String, modelOutput: String) {
        let allLines = text.components(separatedBy: .newlines)
        let nonEmptyLines = allLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let nonEmptyLineCount = nonEmptyLines.count
        let lineBased = shouldPreferLineSummary(for: nonEmptyLines)
        let sampleLineLimit = lineBased ? min(20, nonEmptyLineCount) : min(8, nonEmptyLineCount)
        let sampleLines = Array(nonEmptyLines.prefix(sampleLineLimit))
        let visiblePreview = lineBased
            ? sampleLines.joined(separator: "\n")
            : String(text.prefix(visibleCharacterLimit))
        let modelPreview = lineBased
            ? Array(nonEmptyLines.prefix(min(12, nonEmptyLineCount))).joined(separator: "\n")
            : String(text.prefix(modelCharacterLimit))

        let visibleSummaryLine: String
        let modelSummaryLine: String
        if lineBased {
            visibleSummaryLine = "结果较长：共约 \(nonEmptyLineCount.formatted()) 项，下面仅展示前 \(sampleLineLimit.formatted()) 项样例。"
            modelSummaryLine = "工具结果较长：共约 \(nonEmptyLineCount) 项。请优先基于计数和样例继续回答，不要复述完整列表。"
        } else {
            visibleSummaryLine = "结果较长：共 \(text.count.formatted()) 个字符，下面仅展示开头摘要。"
            modelSummaryLine = "工具结果较长：共 \(text.count) 个字符。请基于摘要继续回答，不要复述完整长文本。"
        }

        let visibleOutput = """
        \(visibleSummaryLine)
        工具: \(label)
        总长度: \(text.count.formatted()) 个字符
        总行数: \(nonEmptyLineCount.formatted()) 行

        \(lineBased ? "样例：" : "摘要预览：")
        \(visiblePreview)
        """

        let modelOutput = """
        \(modelSummaryLine)
        工具: \(label)
        总长度: \(text.count) 个字符
        总行数: \(nonEmptyLineCount) 行

        \(lineBased ? "前若干项样例：" : "摘要预览：")
        \(modelPreview)
        """

        return (visibleOutput, modelOutput)
    }

    private func shouldPreferLineSummary(for lines: [String]) -> Bool {
        guard lines.count >= 8 else { return false }
        let averageLength = lines.reduce(0) { $0 + $1.count } / max(lines.count, 1)
        return averageLength <= 180
    }

    private func previewImage(singlePath: String?, paths: [String]?) -> ToolExecutionOutcome {
        var requestedPaths = (paths ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if requestedPaths.isEmpty, let singlePath {
            let trimmed = singlePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                requestedPaths = [trimmed]
            }
        }

        guard !requestedPaths.isEmpty else {
            return ToolExecutionOutcome(output: "[错误] path 或 paths 不能为空")
        }

        var resolvedImages: [String] = []
        for requestedPath in requestedPaths {
            let resolved = resolvePath(requestedPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return ToolExecutionOutcome(output: "[错误] 图片不存在：\(resolved)")
            }

            let ext = URL(fileURLWithPath: resolved).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else {
                return ToolExecutionOutcome(output: "[错误] 该文件不是可预览的图片格式：\(resolved)")
            }

            guard NSImage(contentsOfFile: resolved) != nil else {
                return ToolExecutionOutcome(output: "[错误] 无法加载图片：\(resolved)")
            }

            resolvedImages.append(resolved)
        }

        let normalizedImages = Array(NSOrderedSet(array: resolvedImages)) as? [String] ?? resolvedImages
        let fileList = normalizedImages.map { "• \(($0 as NSString).lastPathComponent)" }.joined(separator: "\n")
        let summary = normalizedImages.count == 1
            ? "🖼️ 已在会话中预览图片：\((normalizedImages[0] as NSString).lastPathComponent)"
            : "🖼️ 已在会话中预览 \(normalizedImages.count) 张图片"

        return ToolExecutionOutcome(
            output: summary + "\n" + fileList,
            previewImagePath: normalizedImages.first,
            previewImagePaths: normalizedImages
        )
    }

    private func advisedOutcome(for outcome: ToolExecutionOutcome, tool: ToolDefinition.ToolName, params: [String: Any]) -> ToolExecutionOutcome {
        guard outcome.operation == nil else { return outcome }
        let output = outcome.output
        guard isRecoverableFailureOutput(output) else { return outcome }
        guard let advice = failureAdvice(for: tool, params: params, output: output) else { return outcome }
        guard !output.contains("[恢复建议]") else { return outcome }

        return ToolExecutionOutcome(
            output: output + "\n[恢复建议]\n" + advice,
            operation: outcome.operation,
            activatedSkillID: outcome.activatedSkillID,
            skillContextMessage: outcome.skillContextMessage,
            followupContextMessage: outcome.followupContextMessage,
            previewImagePath: outcome.previewImagePath,
            previewImagePaths: outcome.previewImagePaths
        )
    }

    private func isRecoverableFailureOutput(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[错误]") || trimmed.hasPrefix("⚠️")
    }

    private func failureAdvice(for tool: ToolDefinition.ToolName, params: [String: Any], output: String) -> String? {
        if output.contains("不能写入此路径") {
            return "先把目标路径改到当前会话工作目录内，或在确实需要跨目录写入时切换到开放模式后再重试。"
        }

        if output.contains("目标 XLSX 不存在") || output.contains("目标 DOCX 不存在") || output.contains("工作目录内源文件不存在") {
            return "先用 list_files 确认目标文件的真实名称和位置；如果文件还没创建，就先写入新文件，不要直接更新不存在的文件。"
        }

        if output.contains("工作表不存在") {
            return "先确认 sheet_name 是否正确；必要时先读取或查看这个 Excel 的工作表名称，再重试。"
        }

        if output.contains("cell 必须是 A1 形式") {
            return "把 cell 改成标准 A1 形式，例如 B2、C7，不要传“第二列第二行”这类自然语言。"
        }

        if output.contains("section_title 不能为空") {
            return "先明确要修改或插入的章节标题，再调用 Word 章节相关工具。"
        }

        if output.contains("path 不能为空") {
            return "先补全目标文件路径；如果用户只说了‘这个文件’，先确认具体文件名或先用 list_files 查看。"
        }

        if output.contains("不存在第") && output.contains("页") {
            return "先根据附件结构信息确认可用页码范围，再读取对应页或页范围。"
        }

        if output.contains("不存在名为") && output.contains("工作表") {
            return "先确认工作表名称是否完全一致；如果用户只给了口语描述，先让模型根据结构摘要重新定位 sheet_name。"
        }

        if output.contains("不存在标题为") && output.contains("片段") {
            return "先使用附件结构里的真实章节标题，再读取对应 segment_title，不要用模糊称呼直接猜。"
        }

        if tool == .readUploadedAttachment && output.contains("当前会话中没有这个已上传附件") {
            return "先确认 attachment_id 是否来自当前会话；如果用户刚上传了文件，优先使用当前附件的 id。"
        }

        if tool == .runSkillScript && output.contains("当前会话中没有已激活的 skill") {
            return "先调用 activate_skill 激活对应 skill，再执行脚本。"
        }

        if tool == .shell && output.contains("沙盒模式") {
            return "沙盒模式下请优先改用结构化文件工具；只有确实需要 shell 时再切换到开放模式。"
        }

        return nil
    }

    func undo(operation: FileOperationRecord) -> UndoOutcome {
        guard !operation.isUndone else {
            return UndoOutcome(success: false, message: "该操作已经撤销过了")
        }

        guard let undoAction = operation.undoAction else {
            return UndoOutcome(success: false, message: "该操作不支持撤销")
        }

        let fm = FileManager.default

        switch undoAction.kind {
        case .deleteCreatedItem:
            guard fm.fileExists(atPath: undoAction.targetPath) else {
                return UndoOutcome(success: false, message: "目标已不存在，无法撤销：\(undoAction.targetPath)")
            }
            do {
                try fm.removeItem(atPath: undoAction.targetPath)
                cleanupUndoArtifacts(operationId: operation.id)
                return UndoOutcome(success: true, message: "已撤销并删除：\(undoAction.targetPath)")
            } catch {
                return UndoOutcome(success: false, message: "撤销失败：\(error.localizedDescription)")
            }

        case .restoreBackup:
            guard let backupPath = undoAction.backupPath,
                  fm.fileExists(atPath: backupPath) else {
                return UndoOutcome(success: false, message: "备份不存在，无法撤销")
            }

            do {
                if fm.fileExists(atPath: undoAction.targetPath) {
                    try fm.removeItem(atPath: undoAction.targetPath)
                }
                try fm.copyItem(atPath: backupPath, toPath: undoAction.targetPath)
                cleanupUndoArtifacts(operationId: operation.id)
                return UndoOutcome(success: true, message: "已恢复：\(undoAction.targetPath)")
            } catch {
                return UndoOutcome(success: false, message: "恢复失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 沙盒权限检查

    /// 检查工具调用是否违反沙盒限制，返回 nil 表示通过
    private func checkSandboxViolation(tool: ToolDefinition.ToolName, params: [String: Any]) -> String? {
        switch tool {
        case .writeFile:
            let path = params["path"] as? String ?? ""
            guard !path.isEmpty else { return nil }
            let resolved = resolvePath(path)
            if !isInSandbox(resolved) {
                return sandboxWriteDeniedMessage(for: resolved)
            }

        case .writeAssistantContentToFile:
            let path = params["path"] as? String ?? ""
            guard !path.isEmpty else { return nil }
            let resolved = resolvePath(path)
            if !isInSandbox(resolved) {
                return sandboxWriteDeniedMessage(for: resolved)
            }

        case .writeMultipleFiles:
            let files = params["files"] as? [[String: Any]] ?? []
            for file in files {
                guard let path = file["path"] as? String, !path.isEmpty else { continue }
                let resolved = resolvePath(path)
                if !isInSandbox(resolved) {
                    return sandboxWriteDeniedMessage(for: resolved)
                }
            }

        case .writeDOCX, .writeXLSX:
            let path = params["path"] as? String ?? ""
            guard !path.isEmpty else { return nil }
            let resolved = resolvePath(path)
            if !isInSandbox(resolved) {
                return sandboxWriteDeniedMessage(for: resolved)
            }

        case .replaceDOCXSection, .insertDOCXSection, .appendXLSXRows, .updateXLSXCell:
            let path = params["path"] as? String ?? ""
            guard !path.isEmpty else { return nil }
            let resolved = resolvePath(path)
            if !isInSandbox(resolved) {
                return sandboxWriteDeniedMessage(for: resolved)
            }

        case .readFile:
            return nil

        case .listFiles:
            return nil

        case .shell:
            return "⚠️ 当前为沙盒模式，不能使用 shell 工具。"

        case .exportFile, .exportDirectory:
            let destinationPath = params["destination_path"] as? String ?? ""
            guard !destinationPath.isEmpty else { return nil }
            let resolved = resolveExternalPath(destinationPath)
            return sandboxWriteDeniedMessage(for: resolved)

        case .exportPDF, .exportDOCX, .exportXLSX:
            let path = params["path"] as? String ?? ""
            guard !path.isEmpty else { return nil }
            let resolved = resolvePath(path)
            if !isInSandbox(resolved) {
                return sandboxWriteDeniedMessage(for: resolved)
            }
            return nil

        case .importFile, .importDirectory, .importFileContent, .listExternalFiles, .activateSkill, .installSkill, .readSkillResource, .runSkillScript, .readUploadedAttachment:
            return nil
        default:
            break
        }
        return nil
    }

    private func readUploadedAttachment(
        attachmentID: String,
        chunkIndex: Int?,
        startChunk: Int?,
        endChunk: Int?,
        pageNumber: Int?,
        pageStart: Int?,
        pageEnd: Int?,
        sheetIndex: Int?,
        sheetName: String?,
        segmentIndex: Int?,
        segmentTitle: String?
    ) -> String {
        guard !attachmentID.isEmpty else {
            return "[错误] attachment_id 不能为空"
        }
        guard activeAttachmentIDs.contains(attachmentID) else {
            return "[错误] 当前会话中没有这个已上传附件，或你无权读取它。"
        }
        guard let document = attachmentStore.loadDocument(id: attachmentID) else {
            return "[错误] 找不到该附件内容，可能已过期。"
        }

        if let pageNumber {
            guard let segment = attachmentStore.segment(attachmentID: attachmentID, kind: .page, index: pageNumber) else {
                return "[错误] 不存在第 \(pageNumber) 页。"
            }
            return """
            文件名: \(document.fileName)
            类型: \(document.typeName)
            页码: \(segment.index)
            标题: \(segment.title)
            内容:
            \(segment.content)
            """
        }

        if pageStart != nil || pageEnd != nil {
            let start = max(pageStart ?? 1, 1)
            let end = max(pageEnd ?? start, start)
            let pages = attachmentStore.segmentRange(attachmentID: attachmentID, kind: .page, start: start, end: end)
            guard !pages.isEmpty else {
                return "[错误] 这个页码范围内没有可读取的内容。"
            }
            let body = pages.map { page in
                """
                --- 第\(page.index)页 ---
                \(page.content)
                """
            }.joined(separator: "\n\n")
            return """
            文件名: \(document.fileName)
            类型: \(document.typeName)
            页码范围: \(start)-\(end)

            \(body)
            """
        }

        if let sheetIndex {
            guard let segment = attachmentStore.segment(attachmentID: attachmentID, kind: .sheet, index: sheetIndex) else {
                return "[错误] 不存在第 \(sheetIndex) 个工作表。"
            }
            return """
            文件名: \(document.fileName)
            类型: \(document.typeName)
            工作表: \(segment.index)
            标题: \(segment.title)
            内容:
            \(segment.content)
            """
        }

        if let sheetName, !sheetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let segment = attachmentStore.segment(attachmentID: attachmentID, kind: .sheet, title: sheetName) else {
                return "[错误] 不存在名为 \(sheetName) 的工作表。"
            }
            return """
            文件名: \(document.fileName)
            类型: \(document.typeName)
            工作表: \(segment.index)
            标题: \(segment.title)
            内容:
            \(segment.content)
            """
        }

        if let segmentIndex {
            guard let segment = attachmentStore.segment(attachmentID: attachmentID, kind: .segment, index: segmentIndex)
                ?? attachmentStore.segment(attachmentID: attachmentID, kind: .chunk, index: segmentIndex) else {
                return "[错误] 不存在第 \(segmentIndex) 个片段。"
            }
            return """
            文件名: \(document.fileName)
            类型: \(document.typeName)
            片段: \(segment.index)
            标题: \(segment.title)
            内容:
            \(segment.content)
            """
        }

        if let segmentTitle, !segmentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let segment = attachmentStore.segment(attachmentID: attachmentID, kind: .segment, title: segmentTitle)
                ?? attachmentStore.segment(attachmentID: attachmentID, kind: .page, title: segmentTitle)
                ?? attachmentStore.segment(attachmentID: attachmentID, kind: .chunk, title: segmentTitle) else {
                return "[错误] 不存在标题为 \(segmentTitle) 的片段。"
            }
            return """
            文件名: \(document.fileName)
            类型: \(document.typeName)
            片段: \(segment.index)
            标题: \(segment.title)
            内容:
            \(segment.content)
            """
        }

        if let chunkIndex {
            guard let chunk = attachmentStore.chunk(attachmentID: attachmentID, index: chunkIndex) else {
                return "[错误] 不存在第 \(chunkIndex) 块。可用块范围：1-\(document.chunks.count)"
            }
            return """
            文件名: \(document.fileName)
            类型: \(document.typeName)
            分块: \(chunk.index)/\(document.chunks.count)
            标题: \(chunk.title)
            内容:
            \(chunk.content)
            """
        }

        let start = max(startChunk ?? 1, 1)
        let end = min(endChunk ?? min(start + 1, document.chunks.count), document.chunks.count)
        guard start <= end else {
            return "[错误] start_chunk 不能大于 end_chunk"
        }
        let chunks = attachmentStore.chunkRange(attachmentID: attachmentID, start: start, end: end)
        guard !chunks.isEmpty else {
            return "[错误] 这个范围内没有可读取的块。"
        }
        let body = chunks.map { chunk in
            """
            --- 第\(chunk.index)块 / 共\(document.chunks.count)块 ---
            \(chunk.content)
            """
        }.joined(separator: "\n\n")
        return """
        文件名: \(document.fileName)
        类型: \(document.typeName)
        读取范围: \(start)-\(end) / \(document.chunks.count)

        \(body)
        """
    }

    /// 判断绝对路径是否在沙盒内
    private func isInSandbox(_ absolutePath: String) -> Bool {
        let target = canonicalPathForComparison(absolutePath)
        let workspaceRoots = [
            sandboxDir,
            URL(fileURLWithPath: sandboxDir).resolvingSymlinksInPath().path
        ]
        .map(canonicalPathForComparison)
        .filter { !$0.isEmpty }

        return workspaceRoots.contains { root in
            target == root || target.hasPrefix(root + "/")
        }
    }

    private func sandboxWriteDeniedMessage(for path: String) -> String {
        return "⚠️ 当前为沙盒模式，不能写入此路径：\(path)\n当前会话工作目录：\(sandboxDir)\n沙盒模式下当前工作目录可读写，其他路径仅允许读取；如需写入其他路径，请切换到开放模式。"
    }

    private func isInAllowedReadRoots(_ absolutePath: String) -> Bool {
        let target = canonicalPathForComparison(absolutePath)
        return allowedReadRoots.contains { root in
            target == root || target.hasPrefix(root + "/")
        }
    }

    // MARK: - Shell
    private func runShell(_ command: String, onProgress: ((String) -> Void)? = nil) -> String {
        runShell(command, operationId: nil, onProgress: onProgress)
    }

    private func runShell(_ command: String, operationId: String?, onProgress: ((String) -> Void)? = nil) -> String {
        let startedAt = Date()
        let timeoutSeconds = 120
        logExecutionEvent(
            category: .shell,
            event: "shell_started",
            operationId: operationId,
            status: .started,
            summary: "开始执行 shell 命令",
            metadata: ["command_preview": .string(LogRedactor.preview(command))]
        )
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        let reportProgress = throttledProgressReporter(onProgress)
        let stdoutCollector = PipeCollector(onLine: { line in
            reportProgress("stdout: \(line)")
        })
        let stderrCollector = PipeCollector(onLine: { line in
            reportProgress("stderr: \(line)")
        })
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: sandboxDir)
        process.environment = resolvedExecutionEnvironment()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            reportProgress("命令已启动")
            stdoutCollector.attach(to: pipe)
            stderrCollector.attach(to: errPipe)
            let exitSignal = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSignal.signal()
            }
            try process.run()
            registerActiveProcess(process)
            defer { unregisterActiveProcess(process) }
            let waitResult = exitSignal.wait(timeout: .now() + .seconds(timeoutSeconds))
            if waitResult == .timedOut {
                reportProgress("命令执行超时，正在结束进程")
                let terminatedGracefully = terminateProcess(process, graceSeconds: 2)
                let output = stdoutCollector.finishReading(from: pipe)
                let error = stderrCollector.finishReading(from: errPipe)
                logExecutionEvent(
                    level: .warn,
                    category: .shell,
                    event: "shell_timeout",
                    operationId: operationId,
                    status: .timeout,
                    durationMs: Date().timeIntervalSince(startedAt) * 1000,
                    summary: "shell 命令执行超时",
                    metadata: LogMetadataBuilder.failure(
                        errorKind: .timeout,
                        recoveryAction: .abort,
                        isUserVisible: true,
                        extra: [
                            "command_preview": .string(LogRedactor.preview(command)),
                            "timeout_seconds": .int(timeoutSeconds),
                            "termination": .string(terminatedGracefully ? "graceful" : "forced"),
                            "stdout_preview": .string(LogRedactor.preview(output)),
                            "stderr_preview": .string(LogRedactor.preview(error))
                        ]
                    )
                )
                return """
                [Shell timeout]
                Timeout: \(timeoutSeconds)s
                Termination: \(terminatedGracefully ? "graceful" : "forced")
                \(error)\(output)
                """
            }
            let output = stdoutCollector.finishReading(from: pipe)
            let error = stderrCollector.finishReading(from: errPipe)
            if process.terminationStatus != 0 {
                logExecutionEvent(
                    level: .warn,
                    category: .shell,
                    event: "shell_failed",
                    operationId: operationId,
                    status: .failed,
                    durationMs: Date().timeIntervalSince(startedAt) * 1000,
                    summary: "shell 命令执行失败",
                    metadata: [
                        "command_preview": .string(LogRedactor.preview(command)),
                        "exit_code": .int(Int(process.terminationStatus)),
                        "stderr_preview": .string(LogRedactor.preview(error))
                    ]
                )
                return "Exit code: \(process.terminationStatus)\n\(error)\(output)"
            }
            logExecutionEvent(
                category: .shell,
                event: "shell_completed",
                operationId: operationId,
                status: .succeeded,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: "shell 命令执行完成",
                metadata: [
                    "command_preview": .string(LogRedactor.preview(command)),
                    "stdout_preview": .string(LogRedactor.preview(output))
                ]
            )
            return output.isEmpty ? "(无输出)" : output
        } catch {
            logExecutionEvent(
                level: .error,
                category: .shell,
                event: "shell_failed",
                operationId: operationId,
                status: .failed,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: "shell 命令执行异常",
                metadata: [
                    "command_preview": .string(LogRedactor.preview(command)),
                    "error": .string(error.localizedDescription)
                ]
            )
            return "[错误] \(error.localizedDescription)"
        }
    }

    // MARK: - File Operations
    private func readFile(_ path: String) -> String {
        let resolved = resolvePath(path)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
            guard let decoded = decodeTextFile(data) else {
                return "[错误] 读取失败: 无法识别文件编码，当前仅支持可解码的文本文件"
            }
            let content = decoded.content
            let encodingNote = decoded.encodingName == "UTF-8" ? "" : "\n编码: \(decoded.encodingName)"
            if content.count > 50000 {
                let preview = String(content.prefix(50000))
                return """
                文件: \(resolved)
                字符数: \(content.count)
                \(encodingNote.isEmpty ? "" : encodingNote)
                状态: 文件已完整读取；以下仅展示前 50000 个字符用于预览，文件本身未被截断。
                --- BEGIN FILE PREVIEW ---
                \(preview)
                --- END FILE PREVIEW ---
                """
            }
            return encodingNote.isEmpty ? content : "\(content)\n\n[编码]\n\(decoded.encodingName)"
        } catch {
            return "[错误] 读取失败: \(error.localizedDescription)"
        }
    }

    private func writeFile(_ path: String, content: String, operationId: String) -> ToolExecutionOutcome {
        let resolved = resolvePath(path)
        let dir = (resolved as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: resolved)
        let undoAction = prepareUndoAction(operationId: operationId, targetPath: resolved, existedBefore: existed)
        do {
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
            let ext = URL(fileURLWithPath: resolved).pathExtension.lowercased()
            let writeNote = (["html", "css", "js"].contains(ext) || content.count > 20_000)
                ? "\n说明: 文件已完整写入。如果后续 read_file 只返回前 50KB 预览，那是读取展示被截断，不代表写入失败。"
                : ""
            let validationReport = validationService.validateWrittenFiles([(path: resolved, content: content)])
            let validationOutput = renderedValidationSection(validationReport, candidatePaths: [resolved])
            let operation = FileOperationRecord(
                id: operationId,
                toolName: ToolDefinition.ToolName.writeFile.rawValue,
                title: "写入文件",
                summary: existed ? "已覆盖 \(resolved)" : "已新建 \(resolved)",
                detailLines: [
                    "结果：\(existed ? "覆盖现有文件" : "创建新文件")",
                    "目标：\(resolved)"
                ],
                createdAt: Date(),
                undoAction: undoAction,
                isUndone: false
            )
            return ToolExecutionOutcome(
                output: "✅ 写入成功: \(resolved)\n字符数: \(content.count)\(writeNote)\(validationOutput)",
                operation: operation,
                followupContextMessage: validationFollowupContext(validationReport, candidatePaths: [resolved])
            )
        } catch {
            cleanupUndoArtifacts(operationId: operationId)
            return ToolExecutionOutcome(output: "[错误] 写入失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func writeAssistantContentToFile(
        _ path: String,
        assistantContent: String?,
        operationId: String,
        onProgress: ((String) -> Void)? = nil
    ) -> ToolExecutionOutcome {
        let preferredContent = assistantContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackContent = latestAssistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = !(preferredContent ?? "").isEmpty ? preferredContent! : fallbackContent

        guard !content.isEmpty else {
            return ToolExecutionOutcome(
                output: """
                [错误] 当前没有可直接写入的 assistant 正文
                请先在 assistant 正文中生成完整内容，再调用 write_assistant_content_to_file。
                """,
                operation: nil
            )
        }

        onProgress?("已接收正文草稿，正在写入目标文件")
        let outcome = writeFile(path, content: content, operationId: operationId)
        if !outcome.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[错误]") {
            latestAssistantDraft = content
        }
        return outcome
    }

    private func writeMultipleFiles(_ files: [(path: String, content: String)], operationId: String) -> ToolExecutionOutcome {
        guard !files.isEmpty else {
            return ToolExecutionOutcome(output: "[错误] files 不能为空", operation: nil)
        }

        var resolvedFiles: [(path: String, content: String)] = []
        for file in files {
            let trimmedPath = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                return ToolExecutionOutcome(output: "[错误] files 中存在空 path", operation: nil)
            }
            resolvedFiles.append((resolvePath(trimmedPath), file.content))
        }

        for file in resolvedFiles {
            let dir = (file.path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let rollbackDir = (undoBaseDir as NSString).appendingPathComponent("\(operationId)-batch")
        try? FileManager.default.createDirectory(atPath: rollbackDir, withIntermediateDirectories: true)
        var rollbackEntries: [BatchRollbackEntry] = []
        var writtenPaths: [String] = []
        for (index, file) in resolvedFiles.enumerated() {
            do {
                rollbackEntries.append(try prepareBatchRollbackEntry(
                    targetPath: file.path,
                    backupDirectory: rollbackDir,
                    index: index
                ))
                try file.content.write(toFile: file.path, atomically: true, encoding: .utf8)
                writtenPaths.append(file.path)
            } catch {
                rollbackBatchWrites(rollbackEntries)
                try? FileManager.default.removeItem(atPath: rollbackDir)
                return ToolExecutionOutcome(
                    output: "[错误] 批量写入失败: \(error.localizedDescription)\n失败文件: \(file.path)\n已自动回滚本轮较早写入的文件，避免留下半完成状态。",
                    operation: nil
                )
            }
        }
        try? FileManager.default.removeItem(atPath: rollbackDir)

        let operation = FileOperationRecord(
            id: operationId,
            toolName: ToolDefinition.ToolName.writeMultipleFiles.rawValue,
            title: "批量写入文件",
            summary: "已一次写入 \(resolvedFiles.count) 个文件",
            detailLines: ["文件数：\(resolvedFiles.count)"] + writtenPaths.map { "目标：\($0)" },
            createdAt: Date(),
            undoAction: nil,
            isUndone: false
        )

        let previewNames = writtenPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        let validationReport = validationService.validateWrittenFiles(resolvedFiles)
        let validationOutput = renderedValidationSection(validationReport, candidatePaths: writtenPaths)
        return ToolExecutionOutcome(
            output: "✅ 已批量写入 \(resolvedFiles.count) 个文件: \(previewNames)\n说明: 这些文件已在同一轮写入完成，更适合网页工程这类多文件任务。\n如果这是多文件工程，请根据下面的写后校验结果继续自检或修复。\(validationOutput)",
            operation: operation,
            followupContextMessage: validationFollowupContext(validationReport, candidatePaths: writtenPaths)
        )
    }

    private func importFile(from sourcePath: String, to destinationPath: String?, overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !sourcePath.isEmpty else { return ToolExecutionOutcome(output: "[错误] source_path 不能为空", operation: nil) }

        let source = resolveExternalPath(sourcePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), !isDir.boolValue else {
            return ToolExecutionOutcome(output: "[错误] 源文件不存在或不是文件: \(source)", operation: nil)
        }

        let relativeDestination = sanitizedWorkspaceRelativePath(destinationPath, fallbackName: (source as NSString).lastPathComponent)
        let destination = resolvePath(relativeDestination)
        guard isInSandbox(destination) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
        }
        return copyItem(
            from: source,
            to: destination,
            overwrite: overwrite,
            operationId: operationId,
            successPrefix: "✅ 已导入文件",
            operationTitle: "导入文件",
            summary: "已导入 \(source) -> \(destination)",
            toolName: ToolDefinition.ToolName.importFile.rawValue
        )
    }

    private func decodeFileBatch(_ value: Any?) -> [(path: String, content: String)] {
        guard let files = value as? [[String: Any]] else { return [] }
        return files.compactMap { file in
            guard let path = file["path"] as? String,
                  let content = file["content"] as? String else {
                return nil
            }
            return (path, content)
        }
    }

    private func decodeMoveBatch(_ value: Any?) -> [(sourcePath: String, destinationPath: String)] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let sourcePath = item["source_path"] as? String,
                  let destinationPath = item["destination_path"] as? String else {
                return nil
            }
            return (sourcePath, destinationPath)
        }
    }

    private func importDirectory(from sourcePath: String, to destinationPath: String?, overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !sourcePath.isEmpty else { return ToolExecutionOutcome(output: "[错误] source_path 不能为空", operation: nil) }

        let source = resolveExternalPath(sourcePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            return ToolExecutionOutcome(output: "[错误] 源目录不存在或不是目录: \(source)", operation: nil)
        }

        let relativeDestination = sanitizedWorkspaceRelativePath(destinationPath, fallbackName: (source as NSString).lastPathComponent)
        let destination = resolvePath(relativeDestination)
        guard isInSandbox(destination) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
        }
        return copyItem(
            from: source,
            to: destination,
            overwrite: overwrite,
            operationId: operationId,
            successPrefix: "✅ 已导入目录",
            operationTitle: "导入目录",
            summary: "已导入 \(source) -> \(destination)",
            toolName: ToolDefinition.ToolName.importDirectory.rawValue
        )
    }

    private func importFileContent(from sourcePath: String) -> String {
        guard !sourcePath.isEmpty else { return "[错误] source_path 不能为空" }

        let source = resolveExternalPath(sourcePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), !isDir.boolValue else {
            return "[错误] 源文件不存在或不是文件: \(source)"
        }

        do {
            let content = try String(contentsOfFile: source, encoding: .utf8)
            if content.count > 50000 {
                let preview = String(content.prefix(50000))
                return """
                文件: \(source)
                字符数: \(content.count)
                状态: 外部文件已完整读取；以下仅展示前 50000 个字符用于预览，文件本身未被截断。
                --- BEGIN FILE PREVIEW ---
                \(preview)
                --- END FILE PREVIEW ---
                """
            }
            return content
        } catch {
            return "[错误] 读取外部文件失败: \(error.localizedDescription)"
        }
    }

    private func exportFile(from sourcePath: String, to destinationPath: String, overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !sourcePath.isEmpty else { return ToolExecutionOutcome(output: "[错误] source_path 不能为空", operation: nil) }
        guard !destinationPath.isEmpty else { return ToolExecutionOutcome(output: "[错误] destination_path 不能为空", operation: nil) }

        let source = resolvePath(sourcePath)
        guard isInSandbox(source) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: source), operation: nil)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), !isDir.boolValue else {
            return ToolExecutionOutcome(output: "[错误] 工作目录内源文件不存在或不是文件: \(source)", operation: nil)
        }

        let destination = resolveExternalPath(destinationPath)
        return copyItem(
            from: source,
            to: destination,
            overwrite: overwrite,
            operationId: operationId,
            successPrefix: "✅ 已导出文件",
            operationTitle: "导出文件",
            summary: "已导出 \(source) -> \(destination)",
            toolName: ToolDefinition.ToolName.exportFile.rawValue
        )
    }

    private func exportDirectory(from sourcePath: String, to destinationPath: String, overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !sourcePath.isEmpty else { return ToolExecutionOutcome(output: "[错误] source_path 不能为空", operation: nil) }
        guard !destinationPath.isEmpty else { return ToolExecutionOutcome(output: "[错误] destination_path 不能为空", operation: nil) }

        let source = resolvePath(sourcePath)
        guard isInSandbox(source) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: source), operation: nil)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            return ToolExecutionOutcome(output: "[错误] 工作目录内源目录不存在或不是目录: \(source)", operation: nil)
        }

        let destination = resolveExternalPath(destinationPath)
        return copyItem(
            from: source,
            to: destination,
            overwrite: overwrite,
            operationId: operationId,
            successPrefix: "✅ 已导出目录",
            operationTitle: "导出目录",
            summary: "已导出 \(source) -> \(destination)",
            toolName: ToolDefinition.ToolName.exportDirectory.rawValue
        )
    }

    private func movePaths(_ items: [(sourcePath: String, destinationPath: String)], overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !items.isEmpty else {
            return ToolExecutionOutcome(output: "[错误] items 不能为空", operation: nil)
        }

        let fm = FileManager.default
        var summaries: [String] = []

        for item in items {
            let source = resolvePath(item.sourcePath)
            let destination = resolvePath(item.destinationPath)

            guard fm.fileExists(atPath: source) else {
                return ToolExecutionOutcome(output: "[错误] 源路径不存在：\(source)", operation: nil)
            }

            if permissionMode == .sandbox, (!isInSandbox(source) || !isInSandbox(destination)) {
                return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
            }

            let destinationDir = (destination as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: destination) {
                guard overwrite else {
                    return ToolExecutionOutcome(output: "[错误] 目标路径已存在：\(destination)", operation: nil)
                }
                try? fm.removeItem(atPath: destination)
            }

            do {
                try fm.moveItem(atPath: source, toPath: destination)
                summaries.append("\((source as NSString).lastPathComponent) → \((destination as NSString).lastPathComponent)")
            } catch {
                return ToolExecutionOutcome(output: "[错误] 重命名失败：\(error.localizedDescription)\n源路径：\(source)\n目标路径：\(destination)", operation: nil)
            }
        }

        let operation = FileOperationRecord(
            id: operationId,
            toolName: ToolDefinition.ToolName.movePaths.rawValue,
            title: L10n.tr("chat.tool.move_paths"),
            summary: L10n.tr("file.move.summary", items.count),
            detailLines: summaries,
            createdAt: Date(),
            undoAction: nil,
            isUndone: false
        )

        return ToolExecutionOutcome(
            output: L10n.tr("file.move.success", items.count) + "\n" + summaries.joined(separator: "\n"),
            operation: operation
        )
    }

    private func deletePaths(_ paths: [String], operationId: String) -> ToolExecutionOutcome {
        let cleanedPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanedPaths.isEmpty else {
            return ToolExecutionOutcome(output: "[错误] paths 不能为空", operation: nil)
        }

        let fm = FileManager.default
        var summaries: [String] = []

        for rawPath in cleanedPaths {
            let resolved = resolvePath(rawPath)
            guard fm.fileExists(atPath: resolved) else {
                return ToolExecutionOutcome(output: "[错误] 路径不存在：\(resolved)", operation: nil)
            }
            if permissionMode == .sandbox, !isInSandbox(resolved) {
                return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: resolved), operation: nil)
            }

            do {
                var trashedURL: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: resolved), resultingItemURL: &trashedURL)
                summaries.append((resolved as NSString).lastPathComponent)
            } catch {
                return ToolExecutionOutcome(output: "[错误] 删除失败：\(error.localizedDescription)\n路径：\(resolved)", operation: nil)
            }
        }

        let operation = FileOperationRecord(
            id: operationId,
            toolName: ToolDefinition.ToolName.deletePaths.rawValue,
            title: L10n.tr("chat.tool.delete_paths"),
            summary: L10n.tr("file.delete.summary", cleanedPaths.count),
            detailLines: summaries.map { L10n.tr("file.delete.detail", $0) },
            createdAt: Date(),
            undoAction: nil,
            isUndone: false
        )

        return ToolExecutionOutcome(
            output: L10n.tr("file.delete.success", cleanedPaths.count) + "\n" + summaries.joined(separator: "\n"),
            operation: operation
        )
    }

    private func exportPDF(to path: String, title: String?, content: String, overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionOutcome(output: "[错误] content 不能为空", operation: nil)
        }

        let destination = resolvePath(path)
        guard permissionMode == .open || isInSandbox(destination) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
        }

        do {
            let data = try makePDFData(title: title, content: content)
            return writeGeneratedFile(
                data,
                to: destination,
                overwrite: overwrite,
                operationId: operationId,
                successPrefix: "✅ 已导出 PDF",
                operationTitle: "导出 PDF",
                summary: "已导出 PDF 到 \(destination)",
                detailLines: [
                    "格式：PDF",
                    "标题：\(title.flatMap { $0.isEmpty ? nil : $0 } ?? "(未设置)")",
                    "目标：\(destination)"
                ],
                toolName: ToolDefinition.ToolName.exportPDF.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 导出 PDF 失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func exportDOCX(
        to path: String,
        title: String?,
        content: String,
        images: [DOCXImageInput],
        overwrite: Bool,
        operationId: String
    ) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        guard !(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty) else {
            return ToolExecutionOutcome(output: "[错误] content 和 images 不能同时为空", operation: nil)
        }

        let destination = resolvePath(path)
        guard permissionMode == .open || isInSandbox(destination) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
        }

        do {
            let tempURL = try makeDOCXFile(title: title, content: contentWithDOCXImages(content, images: images))
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: destination,
                overwrite: overwrite,
                operationId: operationId,
                successPrefix: "✅ 已导出 Word",
                operationTitle: "导出 Word",
                summary: "已导出 Word 到 \(destination)",
                detailLines: [
                    "格式：DOCX",
                    "标题：\(title.flatMap { $0.isEmpty ? nil : $0 } ?? "(未设置)")",
                    "图片数：\(images.count)",
                    "目标：\(destination)"
                ],
                toolName: ToolDefinition.ToolName.exportDOCX.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 导出 DOCX 失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func exportXLSX(to path: String, sheets: [SpreadsheetSheet], overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        guard !sheets.isEmpty else { return ToolExecutionOutcome(output: "[错误] sheets 不能为空", operation: nil) }

        let destination = resolvePath(path)
        guard permissionMode == .open || isInSandbox(destination) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
        }

        do {
            let tempURL = try makeXLSXFile(sheets: sheets)
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: destination,
                overwrite: overwrite,
                operationId: operationId,
                successPrefix: "✅ 已导出 Excel",
                operationTitle: "导出 Excel",
                summary: "已导出 Excel 到 \(destination)",
                detailLines: [
                    "格式：XLSX",
                    "工作表数：\(sheets.count)",
                    "目标：\(destination)"
                ],
                toolName: ToolDefinition.ToolName.exportXLSX.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 导出 XLSX 失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func writeDOCX(
        to path: String,
        title: String?,
        content: String,
        images: [DOCXImageInput],
        overwrite: Bool,
        operationId: String
    ) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        guard !(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty) else {
            return ToolExecutionOutcome(output: "[错误] content 和 images 不能同时为空", operation: nil)
        }

        let destination = resolvePath(path)
        guard permissionMode == .open || isInSandbox(destination) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
        }

        do {
            let tempURL = try makeDOCXFile(title: title, content: contentWithDOCXImages(content, images: images))
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: destination,
                overwrite: overwrite,
                operationId: operationId,
                successPrefix: "✅ 已写入 Word",
                operationTitle: "写入 Word",
                summary: "已写入 Word 到 \(destination)",
                detailLines: [
                    "格式：DOCX",
                    "标题：\(title.flatMap { $0.isEmpty ? nil : $0 } ?? "(未设置)")",
                    "图片数：\(images.count)",
                    "目标：\(destination)"
                ],
                toolName: ToolDefinition.ToolName.writeDOCX.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 写入 DOCX 失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func writeXLSX(to path: String, sheets: [SpreadsheetSheet], overwrite: Bool, operationId: String) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        guard !sheets.isEmpty else { return ToolExecutionOutcome(output: "[错误] sheets 不能为空", operation: nil) }

        let destination = resolvePath(path)
        guard permissionMode == .open || isInSandbox(destination) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: destination), operation: nil)
        }

        do {
            let tempURL = try makeXLSXFile(sheets: sheets)
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: destination,
                overwrite: overwrite,
                operationId: operationId,
                successPrefix: "✅ 已写入 Excel",
                operationTitle: "写入 Excel",
                summary: "已写入 Excel 到 \(destination)",
                detailLines: [
                    "格式：XLSX",
                    "工作表数：\(sheets.count)",
                    "目标：\(destination)"
                ],
                toolName: ToolDefinition.ToolName.writeXLSX.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 写入 XLSX 失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func replaceDOCXSection(
        at path: String,
        sectionTitle: String,
        content: String,
        images: [DOCXImageInput],
        appendIfMissing: Bool,
        operationId: String
    ) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        guard !sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionOutcome(output: "[错误] section_title 不能为空", operation: nil)
        }
        guard !(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty) else {
            return ToolExecutionOutcome(output: "[错误] content 和 images 不能同时为空", operation: nil)
        }

        let target = resolvePath(path)
        guard permissionMode == .open || isInSandbox(target) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: target), operation: nil)
        }
        guard FileManager.default.fileExists(atPath: target) else {
            return ToolExecutionOutcome(output: "[错误] 目标 DOCX 不存在: \(target)", operation: nil)
        }

        do {
            let original = try readDOCXPlainText(from: target)
            let updated = replaceSection(
                in: original,
                title: sectionTitle,
                newContent: contentWithDOCXImages(content, images: images),
                appendIfMissing: appendIfMissing
            )
            let tempURL = try makeDOCXFile(title: nil, content: updated.content)
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: target,
                overwrite: true,
                operationId: operationId,
                successPrefix: "✅ 已更新 Word 章节",
                operationTitle: "更新 Word 章节",
                summary: updated.replaced ? "已替换 \(sectionTitle) 章节" : "未找到章节，已追加 \(sectionTitle)",
                detailLines: [
                    "格式：DOCX",
                    "章节：\(sectionTitle)",
                    "图片数：\(images.count)",
                    "目标：\(target)"
                ],
                toolName: ToolDefinition.ToolName.replaceDOCXSection.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 更新 DOCX 章节失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func insertDOCXSection(
        at path: String,
        sectionTitle: String,
        content: String,
        images: [DOCXImageInput],
        afterSectionTitle: String?,
        operationId: String
    ) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        let trimmedSectionTitle = sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSectionTitle.isEmpty else {
            return ToolExecutionOutcome(output: "[错误] section_title 不能为空", operation: nil)
        }
        guard !(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty) else {
            return ToolExecutionOutcome(output: "[错误] content 和 images 不能同时为空", operation: nil)
        }

        let target = resolvePath(path)
        guard permissionMode == .open || isInSandbox(target) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: target), operation: nil)
        }
        guard FileManager.default.fileExists(atPath: target) else {
            return ToolExecutionOutcome(output: "[错误] 目标 DOCX 不存在: \(target)", operation: nil)
        }

        do {
            let original = try readDOCXPlainText(from: target)
            let updated = insertSection(
                into: original,
                title: trimmedSectionTitle,
                content: contentWithDOCXImages(content, images: images),
                afterTitle: afterSectionTitle
            )
            let tempURL = try makeDOCXFile(title: nil, content: updated.content)
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: target,
                overwrite: true,
                operationId: operationId,
                successPrefix: "✅ 已插入 Word 章节",
                operationTitle: "插入 Word 章节",
                summary: updated.insertedAfter.map {
                    "已在 \($0) 后插入 \(trimmedSectionTitle)"
                } ?? "已在文末插入 \(trimmedSectionTitle)",
                detailLines: [
                    "格式：DOCX",
                    "新章节：\(trimmedSectionTitle)",
                    "插入位置：\(updated.insertedAfter ?? "文末")",
                    "图片数：\(images.count)",
                    "目标：\(target)"
                ],
                toolName: ToolDefinition.ToolName.insertDOCXSection.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 插入 DOCX 章节失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func appendXLSXRows(
        at path: String,
        sheetName: String,
        rows: [[String]],
        createSheetIfMissing: Bool,
        operationId: String
    ) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        guard !sheetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionOutcome(output: "[错误] sheet_name 不能为空", operation: nil)
        }
        guard !rows.isEmpty else { return ToolExecutionOutcome(output: "[错误] rows 不能为空", operation: nil) }

        let target = resolvePath(path)
        guard permissionMode == .open || isInSandbox(target) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: target), operation: nil)
        }
        guard FileManager.default.fileExists(atPath: target) else {
            return ToolExecutionOutcome(output: "[错误] 目标 XLSX 不存在: \(target)", operation: nil)
        }

        do {
            var workbook = try readXLSXSheets(from: target)
            if let idx = workbook.firstIndex(where: { normalizedOfficeName($0.name) == normalizedOfficeName(sheetName) }) {
                workbook[idx].rows.append(contentsOf: rows)
            } else if createSheetIfMissing {
                workbook.append(SpreadsheetSheet(name: sheetName, rows: rows))
            } else {
                return ToolExecutionOutcome(output: "[错误] 工作表不存在: \(sheetName)", operation: nil)
            }

            let tempURL = try makeXLSXFile(sheets: workbook)
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: target,
                overwrite: true,
                operationId: operationId,
                successPrefix: "✅ 已更新 Excel 工作表",
                operationTitle: "更新 Excel 工作表",
                summary: "已向 \(sheetName) 追加 \(rows.count) 行",
                detailLines: [
                    "格式：XLSX",
                    "工作表：\(sheetName)",
                    "新增行数：\(rows.count)",
                    "目标：\(target)"
                ],
                toolName: ToolDefinition.ToolName.appendXLSXRows.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 更新 XLSX 工作表失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func updateXLSXCell(
        at path: String,
        sheetName: String,
        cell: String,
        value: String,
        createSheetIfMissing: Bool,
        operationId: String
    ) -> ToolExecutionOutcome {
        guard !path.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空", operation: nil) }
        let trimmedSheetName = sheetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSheetName.isEmpty else { return ToolExecutionOutcome(output: "[错误] sheet_name 不能为空", operation: nil) }
        let trimmedCell = cell.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let cellPosition = parseExcelCellReference(trimmedCell) else {
            return ToolExecutionOutcome(output: "[错误] cell 必须是 A1 形式，例如 B3", operation: nil)
        }

        let target = resolvePath(path)
        guard permissionMode == .open || isInSandbox(target) else {
            return ToolExecutionOutcome(output: sandboxWriteDeniedMessage(for: target), operation: nil)
        }
        guard FileManager.default.fileExists(atPath: target) else {
            return ToolExecutionOutcome(output: "[错误] 目标 XLSX 不存在: \(target)", operation: nil)
        }

        do {
            var workbook = try readXLSXSheets(from: target)
            let sheetIndex: Int
            if let existingIndex = workbook.firstIndex(where: { normalizedOfficeName($0.name) == normalizedOfficeName(trimmedSheetName) }) {
                sheetIndex = existingIndex
            } else if createSheetIfMissing {
                workbook.append(SpreadsheetSheet(name: trimmedSheetName, rows: []))
                sheetIndex = workbook.count - 1
            } else {
                return ToolExecutionOutcome(output: "[错误] 工作表不存在: \(trimmedSheetName)", operation: nil)
            }

            while workbook[sheetIndex].rows.count < cellPosition.row {
                workbook[sheetIndex].rows.append([])
            }
            while workbook[sheetIndex].rows[cellPosition.row - 1].count < cellPosition.column {
                workbook[sheetIndex].rows[cellPosition.row - 1].append("")
            }
            workbook[sheetIndex].rows[cellPosition.row - 1][cellPosition.column - 1] = value

            let tempURL = try makeXLSXFile(sheets: workbook)
            defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
            let data = try Data(contentsOf: tempURL)
            return writeGeneratedFile(
                data,
                to: target,
                overwrite: true,
                operationId: operationId,
                successPrefix: "✅ 已更新 Excel 单元格",
                operationTitle: "更新 Excel 单元格",
                summary: "已更新 \(trimmedSheetName) 的 \(trimmedCell)",
                detailLines: [
                    "格式：XLSX",
                    "工作表：\(trimmedSheetName)",
                    "单元格：\(trimmedCell)",
                    "新值：\(value)",
                    "目标：\(target)"
                ],
                toolName: ToolDefinition.ToolName.updateXLSXCell.rawValue
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 更新 XLSX 单元格失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func listExternalFiles(_ path: String, recursive: Bool) -> String {
        guard !path.isEmpty else { return "[错误] path 不能为空" }

        let target = resolveExternalPath(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            return "[错误] 外部目录不存在: \(target)"
        }

        var results: [String] = []
        if recursive {
            guard let enumerator = FileManager.default.enumerator(atPath: target) else { return "[错误] 无法遍历目录" }
            var count = 0
            for case let file as String in enumerator {
                let fullPath = (target as NSString).appendingPathComponent(file)
                var itemIsDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &itemIsDir)
                results.append((itemIsDir.boolValue ? "📁 " : "📄 ") + file)
                count += 1
                if count >= 200 {
                    results.append("... (已截断)")
                    break
                }
            }
        } else {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: target) else { return "[错误] 无法读取目录" }
            for file in contents.sorted() {
                let fullPath = (target as NSString).appendingPathComponent(file)
                var itemIsDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &itemIsDir)
                results.append((itemIsDir.boolValue ? "📁 " : "📄 ") + file)
            }
        }

        return results.isEmpty ? "(空目录)" : results.joined(separator: "\n")
    }

    private func listFiles(_ path: String?, recursive: Bool) -> String {
        let target = resolvePath(path ?? ".")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            return "[错误] 目录不存在: \(target)"
        }
        var results: [String] = []
        if recursive {
            guard let enumerator = FileManager.default.enumerator(atPath: target) else { return "[错误] 无法遍历" }
            var count = 0
            for case let file as String in enumerator {
                let fullPath = (target as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                results.append((isDir.boolValue ? "📁 " : "📄 ") + file)
                count += 1
                if count >= 200 { results.append("... (已截断)"); break }
            }
        } else {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: target) else { return "[错误] 无法读取" }
            for file in contents.sorted() {
                let fullPath = (target as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                results.append((isDir.boolValue ? "📁 " : "📄 ") + file)
            }
        }
        return results.isEmpty ? "(空目录)" : results.joined(separator: "\n")
    }

    // MARK: - Web Fetch
    private func webFetch(_ urlStr: String) async -> WebFetchResult {
        await webContentFetcher.fetchResult(urlString: urlStr)
    }

    // MARK: - Web Search
    private func webSearch(_ query: String, limit: Int?, engine: String?) async -> WebSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeLimit = max(1, min(limit ?? 5, 10))
        return await WebSearchService.shared.search(query: trimmed, limit: safeLimit, engineHint: engine)
    }

    // MARK: - Helpers
    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return canonicalPathForComparison(path)
        }

        if path.hasPrefix("~") {
            let expanded = NSString(string: path).expandingTildeInPath
            return canonicalPathForComparison(expanded)
        }

        let candidate = (sandboxDir as NSString).appendingPathComponent(path)
        return canonicalPathForComparison(candidate)
    }

    private func resolveExternalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return canonicalPathForComparison(expanded)
    }

    private func decodeParams(_ arguments: String, for tool: ToolDefinition.ToolName? = nil) -> [String: Any]? {
        ToolArgumentParser.parse(arguments: arguments, for: tool)
    }

    private func argumentParsingFailureMessage(for tool: ToolDefinition.ToolName, rawArguments: String) -> String {
        if tool == .writeFile || tool == .writeMultipleFiles || tool == .writeDOCX || tool == .replaceDOCXSection || tool == .insertDOCXSection {
            if rawArguments.contains("<") || rawArguments.contains("class=") || rawArguments.contains("{") || rawArguments.contains("function") {
                return """
                [错误] 无法解析参数
                看起来这次工具调用里包含了较长的 HTML/CSS/JS 或文档正文，模型把内容直接塞进了 tool arguments，导致参数不是合法 JSON。
                请重试这次工具调用，并严格使用 JSON 对象，例如：
                \(tool == .writeMultipleFiles
                    ? #"{"files":[{"path":"index.html","content":"..."},{"path":"styles.css","content":"..."},{"path":"script.js","content":"..."}]}"#
                    : #"{"path":"index.html","content":"..."}"#)
                不要把原始 HTML/CSS 直接当作整个 arguments 发送。
                """
            }
        }

        return "[错误] 无法解析参数"
    }

    private func sanitizedWorkspaceRelativePath(_ path: String?, fallbackName: String) -> String {
        let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            return fallbackName
        }

        let normalized = NSString(string: raw).standardizingPath
        if normalized.hasPrefix("/") || normalized.hasPrefix("~") {
            return fallbackName
        }

        return normalized
    }

    private func canonicalExistingPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if let resolved = fileSystemRealPath(expanded) {
            return resolved
        }
        let url = URL(fileURLWithPath: expanded)
        return url.standardizedFileURL.path
    }

    private func canonicalPathForComparison(_ path: String) -> String {
        let standardized = canonicalExistingPath(path)
        if FileManager.default.fileExists(atPath: standardized) {
            return standardized
        }

        let url = URL(fileURLWithPath: standardized)
        let parentPath = fileSystemRealPath(url.deletingLastPathComponent().path) ?? url.deletingLastPathComponent().standardizedFileURL.path
        let parent = URL(fileURLWithPath: parentPath)
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    private func fileSystemRealPath(_ path: String) -> String? {
        path.withCString { cPath in
            guard let resolved = realpath(cPath, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private func copyItem(from source: String, to destination: String, overwrite: Bool, successPrefix: String) -> String {
        copyItem(
            from: source,
            to: destination,
            overwrite: overwrite,
            operationId: UUID().uuidString,
            successPrefix: successPrefix,
            operationTitle: "文件操作",
            summary: "\(source) -> \(destination)",
            toolName: "file_operation"
        ).output
    }

    private func copyItem(
        from source: String,
        to destination: String,
        overwrite: Bool,
        operationId: String,
        successPrefix: String,
        operationTitle: String,
        summary: String,
        toolName: String
    ) -> ToolExecutionOutcome {
        let fm = FileManager.default
        let parentDir = (destination as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let existed = fm.fileExists(atPath: destination)
        if existed, !overwrite {
            return ToolExecutionOutcome(output: "[错误] 目标已存在: \(destination)", operation: nil)
        }

        let undoAction = prepareUndoAction(operationId: operationId, targetPath: destination, existedBefore: existed)

        do {
            if existed {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: source, toPath: destination)
            let operation = FileOperationRecord(
                id: operationId,
                toolName: toolName,
                title: operationTitle,
                summary: summary,
                detailLines: [
                    "结果：\(existed ? "覆盖目标内容" : "创建新目标")",
                    "来源：\(source)",
                    "目标：\(destination)"
                ],
                createdAt: Date(),
                undoAction: undoAction,
                isUndone: false
            )
            return ToolExecutionOutcome(output: "\(successPrefix): \(source) -> \(destination)", operation: operation)
        } catch {
            cleanupUndoArtifacts(operationId: operationId)
            return ToolExecutionOutcome(output: "[错误] 复制失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func writeGeneratedFile(
        _ data: Data,
        to destination: String,
        overwrite: Bool,
        operationId: String,
        successPrefix: String,
        operationTitle: String,
        summary: String,
        detailLines: [String],
        toolName: String
    ) -> ToolExecutionOutcome {
        let fm = FileManager.default
        let parentDir = (destination as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let existed = fm.fileExists(atPath: destination)
        if existed, !overwrite {
            return ToolExecutionOutcome(output: "[错误] 目标已存在: \(destination)", operation: nil)
        }

        let undoAction = prepareUndoAction(operationId: operationId, targetPath: destination, existedBefore: existed)

        do {
            if existed {
                try fm.removeItem(atPath: destination)
            }
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            let operation = FileOperationRecord(
                id: operationId,
                toolName: toolName,
                title: operationTitle,
                summary: summary,
                detailLines: detailLines,
                createdAt: Date(),
                undoAction: undoAction,
                isUndone: false
            )
            let validationReport = validationService.validateGeneratedFile(at: destination)
            let validationOutput = renderedValidationSection(validationReport, candidatePaths: [destination])
            return ToolExecutionOutcome(
                output: "\(successPrefix): \(destination)\(validationOutput)",
                operation: operation,
                followupContextMessage: validationFollowupContext(validationReport, candidatePaths: [destination])
            )
        } catch {
            cleanupUndoArtifacts(operationId: operationId)
            return ToolExecutionOutcome(output: "[错误] 写入导出文件失败: \(error.localizedDescription)", operation: nil)
        }
    }

    private func renderedValidationSection(_ report: FileValidationReport, candidatePaths: [String]) -> String {
        guard !report.isEmpty else { return "" }
        let adviceLines = report.repairAdvice(candidatePaths: candidatePaths)
        var sections: [String] = [
            "\n写后校验：",
            "[校验状态]",
            "- \(report.repairStatusLabel)",
            "[校验结果]",
            report.renderedLines().map { "- \($0)" }.joined(separator: "\n")
        ]

        if !adviceLines.isEmpty {
            sections.append("[修复建议]")
            sections.append(adviceLines.map { "- \($0)" }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n")
    }

    private func validationFollowupContext(_ report: FileValidationReport, candidatePaths: [String]) -> String? {
        guard report.needsRepair else { return nil }
        let repairAdvice = report.repairAdvice(candidatePaths: candidatePaths)
        guard !repairAdvice.isEmpty else { return nil }

        return """
        [写后校验后续动作]
        下一轮请进入“定向修复模式”。
        本轮写入已经完成，但仍有需要继续修复的问题。
        只修改被点名或确实有问题的文件，不要整轮重写无问题文件。
        除非为了定位被点名问题，否则不要先做整文件回读，也不要先输出长篇解释。
        如果只涉及单个文件，优先精确修改该文件；如果涉及多个关联文件，也只重写有问题的那几个文件。
        接下来请优先按下面顺序修复：
        \(repairAdvice.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private func prepareUndoAction(operationId: String, targetPath: String, existedBefore: Bool) -> UndoAction? {
        guard existedBefore else {
            return UndoAction(kind: .deleteCreatedItem, targetPath: targetPath, backupPath: nil)
        }

        let backupDir = (undoBaseDir as NSString).appendingPathComponent(operationId)
        let backupPath = (backupDir as NSString).appendingPathComponent((targetPath as NSString).lastPathComponent)
        try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        do {
            try FileManager.default.copyItem(atPath: targetPath, toPath: backupPath)
            return UndoAction(kind: .restoreBackup, targetPath: targetPath, backupPath: backupPath)
        } catch {
            return nil
        }
    }

    private func cleanupUndoArtifacts(operationId: String) {
        let path = (undoBaseDir as NSString).appendingPathComponent(operationId)
        try? FileManager.default.removeItem(atPath: path)
    }

    private struct BatchRollbackEntry {
        let targetPath: String
        let existedBefore: Bool
        let backupPath: String?
    }

    private func prepareBatchRollbackEntry(targetPath: String, backupDirectory: String, index: Int) throws -> BatchRollbackEntry {
        guard FileManager.default.fileExists(atPath: targetPath) else {
            return BatchRollbackEntry(targetPath: targetPath, existedBefore: false, backupPath: nil)
        }

        let backupName = String(format: "%03d-%@", index, (targetPath as NSString).lastPathComponent)
        let backupPath = (backupDirectory as NSString).appendingPathComponent(backupName)
        try FileManager.default.copyItem(atPath: targetPath, toPath: backupPath)
        return BatchRollbackEntry(targetPath: targetPath, existedBefore: true, backupPath: backupPath)
    }

    private func rollbackBatchWrites(_ entries: [BatchRollbackEntry]) {
        for entry in entries.reversed() {
            if entry.existedBefore {
                if FileManager.default.fileExists(atPath: entry.targetPath) {
                    try? FileManager.default.removeItem(atPath: entry.targetPath)
                }
                if let backupPath = entry.backupPath {
                    try? FileManager.default.copyItem(atPath: backupPath, toPath: entry.targetPath)
                }
            } else if FileManager.default.fileExists(atPath: entry.targetPath) {
                try? FileManager.default.removeItem(atPath: entry.targetPath)
            }
        }
    }

    private func decodeSpreadsheetSheets(_ value: Any?) -> [SpreadsheetSheet] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String,
                  let rowItems = item["rows"] as? [Any] else { return nil }
            let rows = rowItems.compactMap { row -> [String]? in
                if let strings = row as? [String] { return strings }
                if let mixed = row as? [Any] {
                    return mixed.map { "\($0)" }
                }
                return nil
            }
            return SpreadsheetSheet(name: name, rows: rows)
        }
    }

    private func decodeDOCXImages(_ value: Any?) -> [DOCXImageInput] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let rawPath: String?
            if let string = item["path"] as? String {
                rawPath = string
            } else if let string = item["path"] as? NSString {
                rawPath = String(string)
            } else {
                rawPath = nil
            }

            guard let trimmedPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmedPath.isEmpty else {
                return nil
            }

            let width: Double?
            if let number = item["width"] as? NSNumber {
                width = number.doubleValue
            } else if let string = item["width"] as? String,
                      let parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                width = parsed
            } else {
                width = nil
            }

            let caption = (item["caption"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return DOCXImageInput(
                path: trimmedPath,
                widthPoints: width,
                caption: caption?.isEmpty == false ? caption : nil
            )
        }
    }

    private func decodeTextFile(_ data: Data) -> (content: String, encodingName: String)? {
        guard !likelyBinaryData(data) else { return nil }

        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gb2312 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue)))
        let candidates: [(String.Encoding, String)] = [
            (.utf8, "UTF-8"),
            (.unicode, "UTF-16"),
            (.utf16LittleEndian, "UTF-16 LE"),
            (.utf16BigEndian, "UTF-16 BE"),
            (.utf32LittleEndian, "UTF-32 LE"),
            (.utf32BigEndian, "UTF-32 BE"),
            (.ascii, "ASCII"),
            (.isoLatin1, "ISO-8859-1"),
            (gb18030, "GB18030"),
            (gb2312, "GB2312")
        ]

        for (encoding, name) in candidates {
            if let content = String(data: data, encoding: encoding) {
                return (content, name)
            }
        }

        return nil
    }

    private func likelyBinaryData(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(4096)
        if sample.contains(0) {
            return true
        }

        var suspiciousControlCount = 0
        for byte in sample {
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) {
                suspiciousControlCount += 1
            }
        }

        return Double(suspiciousControlCount) / Double(sample.count) > 0.08
    }

    private func decodeSpreadsheetRows(_ value: Any?) -> [[String]] {
        guard let rowItems = value as? [Any] else { return [] }
        return rowItems.compactMap { row -> [String]? in
            if let strings = row as? [String] { return strings }
            if let mixed = row as? [Any] {
                return mixed.map { "\($0)" }
            }
            return nil
        }
    }

    private func readDOCXPlainText(from path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let xml = try unzipEntry("word/document.xml", from: url)
        let text = ToolRunnerXMLTextExtractor.extractPlainText(from: xml)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NSError(domain: "SkyAgent.Export", code: 1001, userInfo: [NSLocalizedDescriptionKey: "DOCX 中没有可读文本"])
        }
        return normalized
    }

    private func readXLSXSheets(from path: String) throws -> [SpreadsheetSheet] {
        let url = URL(fileURLWithPath: path)
        let archiveEntries = try listZipEntries(in: url)
        let workbookSheets = ToolRunnerWorkbookSheetsExtractor.extract(from: try unzipEntry("xl/workbook.xml", from: url))
        let workbookRelationships = try ToolRunnerWorkbookRelationshipsExtractor.extract(from: unzipEntry("xl/_rels/workbook.xml.rels", from: url))
        let sharedStrings = (try? ToolRunnerSharedStringsExtractor.extract(from: unzipEntry("xl/sharedStrings.xml", from: url))) ?? []
        let sheetEntries = archiveEntries
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let orderedSheetEntries: [(title: String, entry: String)] = {
            let mapped = workbookSheets.compactMap { sheet -> (String, String)? in
                guard let target = workbookRelationships[sheet.relationshipID] else { return nil }
                let normalized = normalizeWorkbookTarget(target)
                guard archiveEntries.contains(normalized) else { return nil }
                return (sheet.name, normalized)
            }
            return mapped.isEmpty
                ? sheetEntries.enumerated().map { ("工作表\($0.offset + 1)", $0.element) }
                : mapped
        }()

        let sheets = try orderedSheetEntries.compactMap { item -> SpreadsheetSheet? in
            let xml = try unzipEntry(item.entry, from: url)
            let rows = ToolRunnerWorksheetExtractor.extractRows(from: xml, sharedStrings: sharedStrings)
            guard !rows.isEmpty else { return nil }
            return SpreadsheetSheet(name: item.title, rows: rows)
        }

        guard !sheets.isEmpty else {
            throw NSError(domain: "SkyAgent.Export", code: 1002, userInfo: [NSLocalizedDescriptionKey: "XLSX 中没有可读工作表"])
        }
        return sheets
    }

    private func normalizedOfficeName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }

    private func replaceSection(in content: String, title: String, newContent: String, appendIfMissing: Bool) -> (content: String, replaced: Bool) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNewContent = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = normalizedOfficeName(cleanedOfficeHeadingTitle(from: trimmedTitle))

        let lines = trimmedContent.components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return (appendIfMissing ? "\(trimmedTitle)\n\(trimmedNewContent)" : trimmedContent, false)
        }

        var outputSections: [String] = []
        var currentLines: [String] = []
        var replaced = false

        func flushCurrentSection() {
            guard !currentLines.isEmpty else { return }
            let sectionBody = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionBody.isEmpty else {
                currentLines = []
                return
            }

            let headingLine = currentLines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sectionTitle = normalizedOfficeName(cleanedOfficeHeadingTitle(from: headingLine))
            if !replaced && !normalizedTitle.isEmpty && sectionTitle == normalizedTitle {
                outputSections.append("\(headingLine)\n\(trimmedNewContent)")
                replaced = true
            } else {
                outputSections.append(sectionBody)
            }
            currentLines = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isOfficeSemanticHeading(line), !currentLines.isEmpty {
                flushCurrentSection()
            }
            currentLines.append(rawLine)
        }
        flushCurrentSection()

        if !replaced, appendIfMissing {
            outputSections.append("\(trimmedTitle)\n\(trimmedNewContent)")
        }

        return (outputSections.joined(separator: "\n\n"), replaced)
    }

    private func insertSection(
        into content: String,
        title: String,
        content newContent: String,
        afterTitle: String?
    ) -> (content: String, insertedAfter: String?) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSection = "# \(title)\n\(newContent.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard !trimmedContent.isEmpty else {
            return (newSection, nil)
        }

        let sections = officeSections(from: trimmedContent)
        let normalizedAfterTitle = afterTitle.map { normalizedOfficeName(cleanedOfficeHeadingTitle(from: $0)) }
        var result: [String] = []
        var insertedAfter: String?
        var inserted = false

        for section in sections {
            result.append(section.text)
            if !inserted,
               let normalizedAfterTitle,
               section.normalizedHeading == normalizedAfterTitle {
                result.append(newSection)
                inserted = true
                insertedAfter = section.headingTitle ?? afterTitle
            }
        }

        if !inserted {
            result.append(newSection)
        }

        return (result.joined(separator: "\n\n"), insertedAfter)
    }

    private func officeSections(from content: String) -> [(headingTitle: String?, normalizedHeading: String?, text: String)] {
        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        var sections: [(String?, String?, String)] = []
        var currentLines: [String] = []

        func flushCurrentSection() {
            guard !currentLines.isEmpty else { return }
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                currentLines = []
                return
            }
            let headingLine = currentLines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let headingTitle = isOfficeSemanticHeading(headingLine) ? cleanedOfficeHeadingTitle(from: headingLine) : nil
            let normalized = headingTitle.map(normalizedOfficeName)
            sections.append((headingTitle, normalized, body))
            currentLines = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isOfficeSemanticHeading(line), !currentLines.isEmpty {
                flushCurrentSection()
            }
            currentLines.append(rawLine)
        }
        flushCurrentSection()
        return sections
    }

    private func isOfficeSemanticHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("#") { return true }
        if trimmed.range(of: #"^第[一二三四五六七八九十百千万0-9]+[章节部分篇节卷]([：:\s].*)?$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^[0-9]+(\.[0-9]+)*[\.、]\s*.+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func cleanedOfficeHeadingTitle(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            return trimmed.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        }
        return trimmed
    }

    private func parseExcelCellReference(_ reference: String) -> (column: Int, row: Int)? {
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let match = normalized.range(of: #"^[A-Z]+[1-9][0-9]*$"#, options: .regularExpression) else {
            return nil
        }
        guard match.lowerBound == normalized.startIndex, match.upperBound == normalized.endIndex else {
            return nil
        }

        let letters = normalized.prefix { $0.isLetter }
        let digits = normalized.drop { $0.isLetter }
        guard let row = Int(digits), row > 0 else { return nil }

        var column = 0
        for scalar in letters.unicodeScalars {
            column = column * 26 + Int(scalar.value) - 64
        }
        return column > 0 ? (column, row) : nil
    }

    private func makePDFData(title: String?, content: String) throws -> Data {
        let pageWidth: CGFloat = 595
        let horizontalPadding: CGFloat = 48
        let verticalPadding: CGFloat = 48
        let contentWidth = pageWidth - horizontalPadding * 2

        let attributed = NSMutableAttributedString()
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            attributed.append(NSAttributedString(
                string: title + "\n\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
        }
        attributed.append(NSAttributedString(
            string: content,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        ))

        let textBounds = attributed.boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let pageHeight = max(842, ceil(textBounds.height) + verticalPadding * 2)
        let renderView = PDFRenderView(
            frame: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
            attributedText: attributed,
            contentInsets: NSEdgeInsets(top: verticalPadding, left: horizontalPadding, bottom: verticalPadding, right: horizontalPadding)
        )
        return renderView.dataWithPDF(inside: renderView.bounds)
    }

    private func makeDOCXFile(title: String?, content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("miniagent-docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let relsDir = tempDir.appendingPathComponent("_rels")
        let wordDir = tempDir.appendingPathComponent("word")
        let wordRelsDir = wordDir.appendingPathComponent("_rels")
        let mediaDir = wordDir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let blocks = try documentBlocks(title: title, content: content)
        let embeddedImages = blocks.compactMap { block -> DOCXEmbeddedImage? in
            if case let .image(image) = block { return image }
            return nil
        }
        let paragraphs = documentBodyXML(for: blocks)
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document
          xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
          xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
          xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
          xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
          <w:body>
            \(paragraphs)
            <w:sectPr>
              <w:pgSz w:w="11906" w:h="16838"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        let documentRelationships = docxDocumentRelationshipsXML(imageCount: embeddedImages.count)
        try documentRelationships.write(
            to: wordRelsDir.appendingPathComponent("document.xml.rels"),
            atomically: true,
            encoding: .utf8
        )

        let imageContentTypes = docxContentTypeDefaults(for: embeddedImages)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          \(imageContentTypes)
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try docxStylesXML().write(to: wordDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)

        for (index, image) in embeddedImages.enumerated() {
            try image.data.write(to: mediaDir.appendingPathComponent("image\(index + 1).png"))
        }

        let outputURL = tempDir.appendingPathComponent("document.docx")
        try zipDirectory(source: tempDir, destination: outputURL, excluding: ["document.docx"])
        return outputURL
    }

    private func makeXLSXFile(sheets: [SpreadsheetSheet]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("miniagent-xlsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let relsDir = tempDir.appendingPathComponent("_rels")
        let xlDir = tempDir.appendingPathComponent("xl")
        let xlRelsDir = xlDir.appendingPathComponent("_rels")
        let worksheetsDir = xlDir.appendingPathComponent("worksheets")
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xlRelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worksheetsDir, withIntermediateDirectories: true)

        let workbookSheets = sheets.enumerated().map { index, sheet in
            #"<sheet name="\#(xmlEscapedAttribute(sheet.name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }.joined(separator: "\n      ")

        let workbookRels = sheets.enumerated().map { index, _ in
            #"<Relationship Id="rId\#(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(index + 1).xml"/>"#
        }.joined(separator: "\n  ")

        let contentOverrides = sheets.enumerated().map { index, _ in
            #"<Override PartName="/xl/worksheets/sheet\#(index + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined(separator: "\n  ")

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          \(contentOverrides)
        </Types>
        """.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            \(workbookSheets)
          </sheets>
        </workbook>
        """.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          \(workbookRels)
        </Relationships>
        """.write(to: xlRelsDir.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)

        for (index, sheet) in sheets.enumerated() {
            try worksheetXML(for: sheet).write(
                to: worksheetsDir.appendingPathComponent("sheet\(index + 1).xml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let outputURL = tempDir.appendingPathComponent("workbook.xlsx")
        try zipDirectory(source: tempDir, destination: outputURL, excluding: ["workbook.xlsx"])
        return outputURL
    }

    private func zipDirectory(source: URL, destination: URL, excluding excludedNames: Set<String>) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).filter { !excludedNames.contains($0) }
        process.arguments = ["-qr", destination.path] + entries
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "SkyAgent.Export", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "zip 打包失败" : message])
        }
    }

    private func listZipEntries(in url: URL) throws -> [String] {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "SkyAgent.Export", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "读取压缩目录失败" : message])
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func unzipEntry(_ entry: String, from url: URL) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "SkyAgent.Export", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "读取压缩文件条目失败: \(entry)" : message])
        }
        return data
    }

    private func normalizeWorkbookTarget(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("xl/") { return trimmed }
        if trimmed.hasPrefix("/xl/") { return String(trimmed.dropFirst()) }
        if trimmed.hasPrefix("worksheets/") { return "xl/\(trimmed)" }
        if trimmed.hasPrefix("../") { return "xl/" + trimmed.replacingOccurrences(of: "../", with: "") }
        return "xl/\(trimmed)"
    }

    private func worksheetXML(for sheet: SpreadsheetSheet) -> String {
        let rows = sheet.rows.enumerated().map { rowIndex, row in
            let cells = row.enumerated().map { columnIndex, value in
                let ref = excelColumnName(for: columnIndex) + "\(rowIndex + 1)"
                return #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(xmlEscapedText(value))</t></is></c>"#
            }.joined()
            return #"<row r="\#(rowIndex + 1)">\#(cells)</row>"#
        }.joined(separator: "\n      ")

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            \(rows)
          </sheetData>
        </worksheet>
        """
    }

    private func contentWithDOCXImages(_ content: String, images: [DOCXImageInput]) -> String {
        guard !images.isEmpty else { return content }

        let markers = images.compactMap { image in
            docxImageMarker(for: image)
        }

        guard !markers.isEmpty else { return content }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return markers.joined(separator: "\n")
        }
        return "\(trimmed)\n\n" + markers.joined(separator: "\n")
    }

    private func docxImageMarker(for image: DOCXImageInput) -> String? {
        var payload: [String: Any] = ["path": image.path]
        if let width = image.widthPoints {
            payload["width"] = width
        }
        if let caption = image.caption, !caption.isEmpty {
            payload["caption"] = caption
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return "[[MINIAGENT_DOCX_IMAGE:\(data.base64EncodedString())]]"
    }

    private func documentBlocks(title: String?, content: String) throws -> [DOCXContentBlock] {
        var blocks: [DOCXContentBlock] = []
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.title(title.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let image = try parseDOCXEmbeddedImage(from: line) {
                blocks.append(.image(image))
                continue
            }

            if let heading = parseDOCXHeading(from: line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else {
                blocks.append(.paragraph(line))
            }
        }

        return blocks
    }

    private func parseDOCXHeading(from line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (min(max(hashes.count, 1), 5), text)
    }

    private func parseDOCXEmbeddedImage(from line: String) throws -> DOCXEmbeddedImage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "[[MINIAGENT_DOCX_IMAGE:"
        let suffix = "]]"
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return nil }

        let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
        let encoded = String(trimmed[start..<end])
        guard let data = Data(base64Encoded: encoded),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String else {
            throw NSError(domain: "SkyAgent.Export", code: 1010, userInfo: [NSLocalizedDescriptionKey: "DOCX 图片占位符格式无效"])
        }

        let width: Double?
        if let number = object["width"] as? NSNumber {
            width = number.doubleValue
        } else if let string = object["width"] as? String, let parsed = Double(string) {
            width = parsed
        } else {
            width = nil
        }

        let caption = (object["caption"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try loadDOCXEmbeddedImage(
            input: DOCXImageInput(
                path: path,
                widthPoints: width,
                caption: caption?.isEmpty == false ? caption : nil
            )
        )
    }

    private func loadDOCXEmbeddedImage(input: DOCXImageInput) throws -> DOCXEmbeddedImage {
        let resolvedPath = resolvePath(input.path)
        let url = URL(fileURLWithPath: resolvedPath)
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw NSError(domain: "SkyAgent.Export", code: 1011, userInfo: [NSLocalizedDescriptionKey: "图片不存在: \(resolvedPath)"])
        }

        let rawData = try Data(contentsOf: url)
        let bitmapRep: NSBitmapImageRep?
        if let directRep = NSBitmapImageRep(data: rawData) {
            bitmapRep = directRep
        } else if let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let tiffRep = NSBitmapImageRep(data: tiff) {
            bitmapRep = tiffRep
        } else {
            bitmapRep = nil
        }

        guard let rep = bitmapRep,
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SkyAgent.Export", code: 1012, userInfo: [NSLocalizedDescriptionKey: "无法读取图片: \(resolvedPath)"])
        }

        let pixelWidth = max(rep.pixelsWide, 1)
        let pixelHeight = max(rep.pixelsHigh, 1)
        let maxWidthPoints: CGFloat = 420
        let requestedWidth = CGFloat(input.widthPoints ?? Double(min(pixelWidth, Int(maxWidthPoints))))
        let widthPoints = max(48, min(maxWidthPoints, requestedWidth))
        let heightPoints = widthPoints * CGFloat(pixelHeight) / CGFloat(pixelWidth)

        return DOCXEmbeddedImage(
            originalPath: resolvedPath,
            caption: input.caption,
            data: pngData,
            widthEMU: Int((widthPoints * 12700).rounded()),
            heightEMU: Int((heightPoints * 12700).rounded())
        )
    }

    private func documentBodyXML(for blocks: [DOCXContentBlock]) -> String {
        var imageIndex = 0
        return blocks.map { block in
            switch block {
            case let .title(text):
                return styledDOCXParagraph(text, style: "Title")
            case let .heading(level, text):
                return styledDOCXParagraph(text, style: "Heading\(min(max(level, 1), 5))")
            case let .paragraph(text):
                return styledDOCXParagraph(text, style: nil)
            case let .image(image):
                imageIndex += 1
                return docxImageParagraphXML(image, imageIndex: imageIndex, relationshipID: "rId\(imageIndex + 1)")
            }
        }.joined(separator: "\n")
    }

    private func styledDOCXParagraph(_ text: String, style: String?) -> String {
        let styleXML = style.map { #"<w:pPr><w:pStyle w:val="\#($0)"/></w:pPr>"# } ?? ""
        let escaped = xmlEscapedText(text)
        return """
        <w:p>
          \(styleXML)
          <w:r>
            <w:t xml:space="preserve">\(escaped)</w:t>
          </w:r>
        </w:p>
        """
    }

    private func docxImageParagraphXML(_ image: DOCXEmbeddedImage, imageIndex: Int, relationshipID: String) -> String {
        let captionParagraph: String
        if let caption = image.caption, !caption.isEmpty {
            captionParagraph = """
            <w:p>
              <w:pPr><w:pStyle w:val="Caption"/><w:jc w:val="center"/></w:pPr>
              <w:r><w:t xml:space="preserve">\(xmlEscapedText(caption))</w:t></w:r>
            </w:p>
            """
        } else {
            captionParagraph = ""
        }

        return """
        <w:p>
          <w:pPr><w:jc w:val="center"/></w:pPr>
          <w:r>
            <w:drawing>
              <wp:inline distT="0" distB="0" distL="0" distR="0">
                <wp:extent cx="\(image.widthEMU)" cy="\(image.heightEMU)"/>
                <wp:docPr id="\(imageIndex)" name="Image \(imageIndex)"/>
                <wp:cNvGraphicFramePr/>
                <a:graphic>
                  <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                    <pic:pic>
                      <pic:nvPicPr>
                        <pic:cNvPr id="0" name="image\(imageIndex).png"/>
                        <pic:cNvPicPr/>
                      </pic:nvPicPr>
                      <pic:blipFill>
                        <a:blip r:embed="\(relationshipID)"/>
                        <a:stretch><a:fillRect/></a:stretch>
                      </pic:blipFill>
                      <pic:spPr>
                        <a:xfrm>
                          <a:off x="0" y="0"/>
                          <a:ext cx="\(image.widthEMU)" cy="\(image.heightEMU)"/>
                        </a:xfrm>
                        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                      </pic:spPr>
                    </pic:pic>
                  </a:graphicData>
                </a:graphic>
              </wp:inline>
            </w:drawing>
          </w:r>
        </w:p>
        \(captionParagraph)
        """
    }

    private func docxDocumentRelationshipsXML(imageCount: Int) -> String {
        let imageRelationships = (0..<imageCount).map { index in
            #"<Relationship Id="rId\#(index + 2)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image\#(index + 1).png"/>"#
        }.joined(separator: "\n  ")
        let imageBlock = imageRelationships.isEmpty ? "" : "\n  \(imageRelationships)"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(imageBlock)
        </Relationships>
        """
    }

    private func docxContentTypeDefaults(for images: [DOCXEmbeddedImage]) -> String {
        guard !images.isEmpty else { return "" }
        return #"<Default Extension="png" ContentType="image/png"/>"#
    }

    private func docxStylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:docDefaults>
            <w:rPrDefault>
              <w:rPr>
                <w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:eastAsia="PingFang SC"/>
                <w:sz w:val="24"/>
                <w:szCs w:val="24"/>
              </w:rPr>
            </w:rPrDefault>
          </w:docDefaults>
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
            <w:qFormat/>
          </w:style>
          <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">
            <w:name w:val="Default Paragraph Font"/>
            <w:uiPriority w:val="1"/>
            <w:semiHidden/>
            <w:unhideWhenUsed/>
          </w:style>
          <w:style w:type="table" w:default="1" w:styleId="TableNormal">
            <w:name w:val="Normal Table"/>
            <w:uiPriority w:val="99"/>
            <w:semiHidden/>
            <w:unhideWhenUsed/>
          </w:style>
          <w:style w:type="numbering" w:default="1" w:styleId="NoList">
            <w:name w:val="No List"/>
            <w:uiPriority w:val="99"/>
            <w:semiHidden/>
            <w:unhideWhenUsed/>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Title">
            <w:name w:val="Title"/>
            <w:basedOn w:val="Normal"/>
            <w:qFormat/>
            <w:pPr><w:spacing w:after="240"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="Heading 1"/>
            <w:basedOn w:val="Normal"/>
            <w:next w:val="Normal"/>
            <w:qFormat/>
            <w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading2">
            <w:name w:val="Heading 2"/>
            <w:basedOn w:val="Normal"/>
            <w:next w:val="Normal"/>
            <w:qFormat/>
            <w:pPr><w:spacing w:before="200" w:after="100"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading3">
            <w:name w:val="Heading 3"/>
            <w:basedOn w:val="Normal"/>
            <w:next w:val="Normal"/>
            <w:qFormat/>
            <w:pPr><w:spacing w:before="180" w:after="80"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading4">
            <w:name w:val="Heading 4"/>
            <w:basedOn w:val="Normal"/>
            <w:next w:val="Normal"/>
            <w:qFormat/>
            <w:pPr><w:spacing w:before="160" w:after="60"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading5">
            <w:name w:val="Heading 5"/>
            <w:basedOn w:val="Normal"/>
            <w:next w:val="Normal"/>
            <w:qFormat/>
            <w:pPr><w:spacing w:before="140" w:after="40"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Caption">
            <w:name w:val="Caption"/>
            <w:basedOn w:val="Normal"/>
            <w:qFormat/>
            <w:pPr><w:jc w:val="center"/><w:spacing w:before="40" w:after="160"/></w:pPr>
            <w:rPr><w:i/><w:sz w:val="20"/><w:szCs w:val="20"/><w:color w:val="666666"/></w:rPr>
          </w:style>
        </w:styles>
        """
    }

    private func excelColumnName(for index: Int) -> String {
        var index = index
        var result = ""
        repeat {
            let scalarValue = 65 + (index % 26)
            guard let scalar = UnicodeScalar(scalarValue) else { return result }
            result = String(scalar) + result
            index = index / 26 - 1
        } while index >= 0
        return result
    }

    private func xmlEscapedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func xmlEscapedAttribute(_ value: String) -> String {
        xmlEscapedText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func isDangerous(command: String) -> Bool {
        let lower = command.lowercased()
        let patterns = [
            #"(?:^|[;&|]\s*|\s)rm\s+(-[^\n]*[rf]|--recursive|--force)"#,
            #"(?:^|[;&|]\s*|\s)rmdir\b"#,
            #"(?:^|[;&|]\s*|\s)mkfs(?:\.[a-z0-9_+-]+)?\b"#,
            #"(?:^|[;&|]\s*|\s)dd\s+(?:if|of)="#,
            #"(?:^|[;&|]\s*|\s)del(?:tree)?\b"#,
            #">\s*/dev/(?:r?disk|sd|nvme)"#,
            #"(?:^|[;&|]\s*|\s)(?:shutdown|reboot|halt)\b"#
        ]

        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(location: 0, length: (lower as NSString).length)
            return regex.firstMatch(in: lower, range: range) != nil
        }
    }

    private func activateSkill(named name: String, operationId: String? = nil) -> ToolExecutionOutcome {
        guard let result = skillManager.activateSkill(named: name) else {
            logExecutionEvent(
                level: .warn,
                category: .skill,
                event: "skill_activated",
                operationId: operationId,
                status: .failed,
                summary: "激活 skill 失败",
                metadata: ["skill_name": .string(name)]
            )
            return ToolExecutionOutcome(output: "⚠️ 当前没有找到可激活的 skill：\(name)。请确认它已经安装，且名称与 catalog 中一致。")
        }
        if !activeSkillIDs.contains(result.skillID) {
            activeSkillIDs.append(result.skillID)
        }
        logExecutionEvent(
            category: .skill,
            event: "skill_activated",
            operationId: operationId,
            status: .succeeded,
            summary: "已激活 skill：\(name)",
            metadata: [
                "skill_name": .string(name),
                "skill_id": .string(result.skillID)
            ]
        )

        return ToolExecutionOutcome(
            output: result.output,
            activatedSkillID: result.skillID,
            skillContextMessage: result.contextMessage
        )
    }

    private func installSkill(url: String?, repo: String?, path: String?, ref: String?, name: String?, operationId: String) async -> ToolExecutionOutcome {
        do {
            let installed = try await skillManager.installSkillFromRemoteAsync(
                url: url,
                repo: repo,
                path: path,
                ref: ref,
                name: name
            )
            let normalizedInstalledPath = canonicalPathForComparison(installed.skillDirectory)
            if !allowedReadRoots.contains(normalizedInstalledPath) {
                allowedReadRoots.append(normalizedInstalledPath)
            }
            let operation = FileOperationRecord(
                id: operationId,
                toolName: ToolDefinition.ToolName.installSkill.rawValue,
                title: "安装 Skill",
                summary: "已安装 \(installed.name) 到 ~/.skyagent/skills",
                detailLines: [
                    "Skill：\(installed.name)",
                    "目录：\(installed.skillDirectory)",
                    "来源：\(installed.sourceType.displayName)",
                    installed.hasScripts ? "提示：这个 skill 含有 scripts/；沙盒模式下可执行本地脚本但网络会被拦截，开放模式下可正常访问网络" : "提示：这个 skill 不依赖脚本执行",
                    installed.requiredEnvironmentVariables.isEmpty
                        ? "环境变量：未声明必需环境变量"
                        : "环境变量：\(installed.requiredEnvironmentVariables.joined(separator: ", "))",
                    "下一步：如果当前任务需要使用它，请立即调用 activate_skill"
                ],
                createdAt: Date(),
                undoAction: UndoAction(kind: .deleteCreatedItem, targetPath: installed.skillDirectory, backupPath: nil),
                isUndone: false
            )
            return ToolExecutionOutcome(
                output: """
                ✅ 已安装 skill：\(installed.name)
                目录：\(installed.skillDirectory)
                \(installed.hasScripts ? "该 skill 含有 scripts/；沙盒模式下可执行本地脚本但网络会被拦截，开放模式下可正常访问网络。" : "")
                \(installed.requiredEnvironmentVariables.isEmpty ? "" : "该 skill 声明的环境变量：\(installed.requiredEnvironmentVariables.joined(separator: ", ")).")
                现在这个 skill 已经可用。如果当前任务就要使用它，请继续调用 activate_skill(name: "\(installed.name)").
                """,
                operation: operation
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 下载并安装 skill 失败：\(error.localizedDescription)")
        }
    }

    private func installSkillBlocking(url: String?, repo: String?, path: String?, ref: String?, name: String?, operationId: String) -> ToolExecutionOutcome {
        do {
            let installed = try skillManager.installSkillFromRemote(
                url: url,
                repo: repo,
                path: path,
                ref: ref,
                name: name
            )
            let normalizedInstalledPath = canonicalPathForComparison(installed.skillDirectory)
            if !allowedReadRoots.contains(normalizedInstalledPath) {
                allowedReadRoots.append(normalizedInstalledPath)
            }
            let operation = FileOperationRecord(
                id: operationId,
                toolName: ToolDefinition.ToolName.installSkill.rawValue,
                title: "安装 Skill",
                summary: "已安装 \(installed.name) 到 ~/.skyagent/skills",
                detailLines: [
                    "Skill：\(installed.name)",
                    "目录：\(installed.skillDirectory)",
                    "来源：\(installed.sourceType.displayName)",
                    installed.hasScripts ? "提示：这个 skill 含有 scripts/；沙盒模式下可执行本地脚本但网络会被拦截，开放模式下可正常访问网络" : "提示：这个 skill 不依赖脚本执行",
                    installed.requiredEnvironmentVariables.isEmpty
                        ? "环境变量：未声明必需环境变量"
                        : "环境变量：\(installed.requiredEnvironmentVariables.joined(separator: ", "))",
                    "下一步：如果当前任务需要使用它，请立即调用 activate_skill"
                ],
                createdAt: Date(),
                undoAction: UndoAction(kind: .deleteCreatedItem, targetPath: installed.skillDirectory, backupPath: nil),
                isUndone: false
            )
            return ToolExecutionOutcome(
                output: """
                ✅ 已安装 skill：\(installed.name)
                目录：\(installed.skillDirectory)
                \(installed.hasScripts ? "该 skill 含有 scripts/；沙盒模式下可执行本地脚本但网络会被拦截，开放模式下可正常访问网络。" : "")
                \(installed.requiredEnvironmentVariables.isEmpty ? "" : "该 skill 声明的环境变量：\(installed.requiredEnvironmentVariables.joined(separator: ", ")).")
                现在这个 skill 已经可用。如果当前任务就要使用它，请继续调用 activate_skill(name: "\(installed.name)").
                """,
                operation: operation
            )
        } catch {
            return ToolExecutionOutcome(output: "[错误] 下载并安装 skill 失败：\(error.localizedDescription)")
        }
    }

    private func readSkillResource(skillName: String, relativePath: String) -> String {
        let trimmedSkillName = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSkillName.isEmpty else {
            return "[错误] skill_name 不能为空"
        }
        guard !trimmedPath.isEmpty else {
            return "[错误] path 不能为空"
        }

        guard let skill = skillManager.skill(named: trimmedSkillName, within: activeSkillIDs) else {
            return "⚠️ 当前会话中没有已激活的 skill：\(trimmedSkillName)。请先调用 activate_skill。"
        }

        let normalizedPath = NSString(string: trimmedPath).standardizingPath
        guard !normalizedPath.hasPrefix("/"),
              !normalizedPath.hasPrefix("~"),
              normalizedPath != "..",
              !normalizedPath.hasPrefix("../") else {
            return "[错误] path 必须是 skill 目录内的相对路径"
        }

        let skillRoot = canonicalPathForComparison(skill.skillDirectory)
        let isSkillManifest = normalizedPath.caseInsensitiveCompare("SKILL.md") == .orderedSame
        let resolvedRelativePath = isSkillManifest ? "SKILL.md" : normalizedPath
        let resourcePath = canonicalPathForComparison((skill.skillDirectory as NSString).appendingPathComponent(resolvedRelativePath))
        guard resourcePath == skillRoot || resourcePath.hasPrefix(skillRoot + "/") else {
            return "[错误] 资源路径无效：\(normalizedPath)"
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resourcePath, isDirectory: &isDir), !isDir.boolValue else {
            return "[错误] 资源不存在：\(resolvedRelativePath)"
        }

        let resource = isSkillManifest
            ? AgentSkillResource(relativePath: "SKILL.md", kind: .other)
            : skill.resources.first(where: { $0.relativePath == normalizedPath })

        guard let resource else {
            return "[错误] 在 skill \(skill.name) 中没有找到资源：\(normalizedPath)"
        }

        let header = skillResourceHeader(skill: skill, resource: resource)
        let usageHint = skillResourceUsageHint(for: resource)

        if shouldTreatAsText(resourcePath) {
            do {
                let content = try String(contentsOfFile: resourcePath, encoding: .utf8)
                let limit = resource.kind == .script ? 20000 : 50000
                let clipped = content.count > limit ? String(content.prefix(limit)) + "\n... (已截断)" : content
                let scriptHints = resource.kind == .script ? scriptSummaryHints(from: content) : []
                let metadataBlock = scriptHints.isEmpty ? "" : scriptHints.joined(separator: "\n") + "\n"
                return """
                \(header)
                \(usageHint)
                \(metadataBlock)--- BEGIN RESOURCE ---
                \(clipped)
                --- END RESOURCE ---
                """
            } catch {
                return "[错误] 读取 skill 资源失败：\(error.localizedDescription)"
            }
        }

        return """
        \(header)
        \(usageHint)
        \(binaryResourceSummary(path: resourcePath, resource: resource))
        """
    }

    private func shouldTreatAsText(_ path: String) -> Bool {
        let textExtensions: Set<String> = [
            "md", "txt", "json", "yaml", "yml", "toml", "xml", "html", "css", "js", "ts",
            "tsx", "jsx", "swift", "py", "rb", "sh", "zsh", "bash", "c", "cc", "cpp", "h",
            "hpp", "java", "kt", "sql", "csv"
        ]
        return textExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func runSkillScript(
        skillName: String,
        relativePath: String,
        args: [String],
        stdin: String?,
        operationId: String,
        onProgress: ((String) -> Void)? = nil
    ) -> ToolExecutionOutcome {
        let startedAt = Date()
        let trimmedSkillName = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSkillName.isEmpty else { return ToolExecutionOutcome(output: "[错误] skill_name 不能为空") }
        guard !trimmedPath.isEmpty else { return ToolExecutionOutcome(output: "[错误] path 不能为空") }

        guard let skill = skillManager.skill(named: trimmedSkillName, within: activeSkillIDs) else {
            return ToolExecutionOutcome(output: "⚠️ 当前会话中没有已激活的 skill：\(trimmedSkillName)。请先调用 activate_skill。")
        }

        let normalizedPath = NSString(string: trimmedPath).standardizingPath
        guard normalizedPath.hasPrefix("scripts/"),
              !normalizedPath.hasPrefix("/"),
              !normalizedPath.hasPrefix("~"),
              normalizedPath != "..",
              !normalizedPath.hasPrefix("../") else {
            return ToolExecutionOutcome(output: "[错误] run_skill_script 只允许执行 skill 的 scripts/ 目录中的相对路径")
        }

        guard let resource = skill.resources.first(where: { $0.relativePath == normalizedPath && $0.kind == .script }) else {
            return ToolExecutionOutcome(output: "[错误] 在 skill \(skill.name) 中没有找到可执行脚本：\(normalizedPath)")
        }

        let scriptPath = canonicalPathForComparison((skill.skillDirectory as NSString).appendingPathComponent(resource.relativePath))
        let skillRoot = canonicalPathForComparison(skill.skillDirectory)
        guard scriptPath == skillRoot || scriptPath.hasPrefix(skillRoot + "/") else {
            return ToolExecutionOutcome(output: "[错误] 脚本路径无效：\(normalizedPath)")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptPath, isDirectory: &isDir), !isDir.boolValue else {
            return ToolExecutionOutcome(output: "[错误] 脚本不存在：\(normalizedPath)")
        }

        guard let launch = scriptLaunchConfiguration(for: scriptPath) else {
            return ToolExecutionOutcome(output: "[错误] 暂时无法识别该脚本的解释器或启动方式：\(normalizedPath)")
        }

        if let dependencyIssue = skillScriptDependencyIssue(skill: skill, resource: resource, scriptPath: scriptPath, launch: launch) {
            return ToolExecutionOutcome(output: dependencyIssue)
        }

        let safeTimeout = resolvedSkillScriptTimeout(for: skill)
        logExecutionEvent(
            category: .skill,
            event: "skill_script_started",
            operationId: operationId,
            status: .started,
            summary: "开始执行 skill 脚本",
            metadata: [
                "skill_name": .string(skill.name),
                "script_path": .string(resource.relativePath),
                "timeout_seconds": .int(safeTimeout),
                "arg_count": .int(args.count)
            ]
        )
        let normalizedArgs = normalizedScriptArgumentsForExecution(args)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdinPipe = Pipe()
        let reportProgress = throttledProgressReporter(onProgress)
        let stdoutCollector = PipeCollector(onLine: { line in
            reportProgress("stdout: \(line)")
        })
        let stderrCollector = PipeCollector(onLine: { line in
            reportProgress("stderr: \(line)")
        })

        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments + [scriptPath] + normalizedArgs
        process.currentDirectoryURL = URL(fileURLWithPath: normalizedWorkspaceExecutionDirectory())
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin == nil ? nil : stdinPipe

        var environment = resolvedExecutionEnvironment()
        environment["MINIAGENT_SKILL_DIR"] = skill.skillDirectory
        environment["MINIAGENT_SKILL_NAME"] = skill.name
        environment["MINIAGENT_WORKSPACE_DIR"] = sandboxDir
        environment["MINIAGENT_PERMISSION_MODE"] = permissionMode.rawValue
        process.environment = environment

        do {
            reportProgress("脚本准备启动：\(resource.relativePath)")
            stdoutCollector.attach(to: stdout)
            stderrCollector.attach(to: stderr)
            let exitSignal = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSignal.signal()
            }
            try process.run()
            registerActiveProcess(process)
            defer { unregisterActiveProcess(process) }
            reportProgress("脚本已启动，正在等待结果")

            if let stdin {
                stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? stdinPipe.fileHandleForWriting.close()
            }

            let waitResult = exitSignal.wait(timeout: .now() + .seconds(safeTimeout))
            if waitResult == .timedOut {
                reportProgress("执行超时，正在尝试结束脚本")
                let terminatedGracefully = terminateProcess(process, graceSeconds: 2)
                _ = stdoutCollector.finishReading(from: stdout)
                _ = stderrCollector.finishReading(from: stderr)
                logExecutionEvent(
                    level: .warn,
                    category: .skill,
                    event: "skill_script_timeout",
                    operationId: operationId,
                    status: .timeout,
                    durationMs: Date().timeIntervalSince(startedAt) * 1000,
                    summary: "skill 脚本执行超时",
                    metadata: [
                        "skill_name": .string(skill.name),
                        "script_path": .string(resource.relativePath),
                        "timeout_seconds": .int(safeTimeout),
                        "termination": .string(terminatedGracefully ? "graceful" : "forced")
                    ]
                )
                let output = """
                [Skill script timeout]
                Skill: \(skill.name)
                Script: \(resource.relativePath)
                Mode: \(permissionMode.rawValue)
                Timeout: \(safeTimeout)s
                Termination: \(terminatedGracefully ? "graceful" : "forced")
                """
                return ToolExecutionOutcome(
                    output: output,
                    operation: buildSkillScriptOperation(
                        operationId: operationId,
                        skill: skill,
                        resource: resource,
                        args: args,
                        status: "timeout",
                        exitCode: nil,
                        summary: "脚本执行超时：\(resource.relativePath)",
                        detailLines: [
                            "Skill：\(skill.name)",
                            "脚本：\(resource.relativePath)",
                            "状态：timeout",
                            "模式：\(permissionMode.rawValue)",
                            "超时：\(safeTimeout)s",
                            "终止方式：\(terminatedGracefully ? "graceful" : "forced")",
                            "参数：\(normalizedArgs.isEmpty ? "(none)" : normalizedArgs.joined(separator: " "))"
                        ]
                    )
                )
            }

            let output = stdoutCollector.finishReading(from: stdout)
            let error = stderrCollector.finishReading(from: stderr)
            let clippedStdout = clipScriptOutput(output, limit: 30000)
            let clippedStderr = clipScriptOutput(error, limit: 20000)
            let status = process.terminationStatus == 0 ? "success" : "failure"
            reportProgress(status == "success" ? "脚本执行完成" : "脚本执行失败")
            logExecutionEvent(
                level: status == "success" ? .info : .warn,
                category: .skill,
                event: status == "success" ? "skill_script_completed" : "skill_script_failed",
                operationId: operationId,
                status: status == "success" ? .succeeded : .failed,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: status == "success" ? "skill 脚本执行完成" : "skill 脚本执行失败",
                metadata: [
                    "skill_name": .string(skill.name),
                    "script_path": .string(resource.relativePath),
                    "exit_code": .int(Int(process.terminationStatus)),
                    "stdout_preview": .string(LogRedactor.preview(clippedStdout)),
                    "stderr_preview": .string(LogRedactor.preview(clippedStderr))
                ]
            )
            let stdoutSection = clippedStdout.isEmpty ? "(无 stdout 输出)" : "--- STDOUT ---\n\(clippedStdout)"
            let stderrSection = clippedStderr.isEmpty ? "(无 stderr 输出)" : "--- STDERR ---\n\(clippedStderr)"

            let result = """
            [Skill script result]
            Skill: \(skill.name)
            Script: \(resource.relativePath)
            Mode: \(permissionMode.rawValue)
            Status: \(status)
            Exit code: \(process.terminationStatus)
            CWD: \(sandboxDir)
            Interpreter: \(launch.displayName)
            Args: \(normalizedArgs.isEmpty ? "(none)" : normalizedArgs.joined(separator: " "))
            \(stdoutSection)
            \(stderrSection)
            """
            return ToolExecutionOutcome(
                output: result,
                operation: buildSkillScriptOperation(
                    operationId: operationId,
                    skill: skill,
                    resource: resource,
                    args: args,
                    status: status,
                    exitCode: Int(process.terminationStatus),
                    summary: status == "success" ? "脚本执行成功：\(resource.relativePath)" : "脚本执行失败：\(resource.relativePath)",
                    detailLines: [
                        "Skill：\(skill.name)",
                        "脚本：\(resource.relativePath)",
                        "模式：\(permissionMode.rawValue)",
                        "状态：\(status)",
                        "退出码：\(process.terminationStatus)",
                        "解释器：\(launch.displayName)",
                        "参数：\(normalizedArgs.isEmpty ? "(none)" : normalizedArgs.joined(separator: " "))"
                    ]
                )
            )
        } catch {
            logExecutionEvent(
                level: .error,
                category: .skill,
                event: "skill_script_failed",
                operationId: operationId,
                status: .failed,
                durationMs: Date().timeIntervalSince(startedAt) * 1000,
                summary: "skill 脚本执行异常",
                metadata: [
                    "skill_name": .string(trimmedSkillName),
                    "script_path": .string(trimmedPath),
                    "error": .string(error.localizedDescription)
                ]
            )
            return ToolExecutionOutcome(output: "[错误] 运行 skill 脚本失败：\(error.localizedDescription)")
        }
    }

    private func resolvedSkillScriptTimeout(for skill: AgentSkill) -> Int {
        let declaredTimeout = skill.scriptTimeoutSeconds ?? 60
        return min(max(declaredTimeout, 1), 300)
    }

    private func scriptLaunchConfiguration(for scriptPath: String) -> (executable: String, arguments: [String], displayName: String)? {
        if let content = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           let firstLine = content.components(separatedBy: .newlines).first,
           firstLine.hasPrefix("#!") {
            let shebang = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = shebang.split(separator: " ").map(String.init)
            if let executable = parts.first {
                if executable.contains("/") {
                    return (executable, Array(parts.dropFirst()), shebang)
                }
                return ("/usr/bin/env", parts, shebang)
            }
        }

        switch URL(fileURLWithPath: scriptPath).pathExtension.lowercased() {
        case "py":
            return ((compatibilityBinDir as NSString).appendingPathComponent("miniagent-doc-python"), [], "miniagent-doc-python")
        case "sh", "bash":
            return ("/bin/bash", [], "bash")
        case "zsh":
            return ("/bin/zsh", [], "zsh")
        case "rb":
            return ("/usr/bin/ruby", [], "ruby")
        case "js":
            return ("/usr/bin/env", ["node"], "node")
        default:
            return nil
        }
    }

    private func skillScriptDependencyIssue(
        skill: AgentSkill,
        resource: AgentSkillResource,
        scriptPath: String,
        launch: (executable: String, arguments: [String], displayName: String)
    ) -> String? {
        let executableIssue = resolvedLaunchIssue(for: launch)
        let missingCommands = detectMissingCommands(for: scriptPath)
        let requiredEnvVars = detectRequiredEnvironmentVariables(for: skill, scriptPath: scriptPath)
        let executionEnvironment = resolvedExecutionEnvironment()
        let missingEnvVars = requiredEnvVars.filter {
            executionEnvironment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        let missingPythonModules = detectMissingPythonModules(for: scriptPath, environment: executionEnvironment)

        guard executableIssue != nil || !missingCommands.isEmpty || !missingEnvVars.isEmpty || !missingPythonModules.isEmpty else {
            return nil
        }

        var lines: [String] = [
            "[Skill script blocked]",
            "Skill: \(skill.name)",
            "Script: \(resource.relativePath)"
        ]

        if let executableIssue {
            lines.append("Missing runtime: \(executableIssue)")
        }
        if !missingCommands.isEmpty {
            lines.append("Missing commands: \(missingCommands.joined(separator: ", "))")
        }
        if !missingEnvVars.isEmpty {
            lines.append("Missing environment variables: \(missingEnvVars.joined(separator: ", "))")
        }
        if !missingPythonModules.isEmpty {
            lines.append("Missing Python modules: \(missingPythonModules.joined(separator: ", "))")
            if let documentPython = resolvedDocumentPythonPath(environment: executionEnvironment) {
                lines.append("Document Python: \(documentPython)")
            }
            let installCommand = "\(compatibilityBinDir)/miniagent-doc-pip install python-docx openpyxl pillow"
            lines.append("Document env setup: 使用 `\(installCommand)` 安装常用文档库。")
        }

        lines.append("Next step: 请先补齐缺失依赖，再重新调用 run_skill_script。")
        return lines.joined(separator: "\n")
    }

    private func detectRequiredEnvironmentVariables(for skill: AgentSkill, scriptPath: String) -> [String] {
        let combinedContent = combinedReferencedScriptContent(for: skill, startingAt: scriptPath)
        let declaredMatches = skill.requiredEnvironmentVariables.filter { variable in
            let escaped = NSRegularExpression.escapedPattern(for: variable)
            guard let regex = try? NSRegularExpression(pattern: #"\b\#(escaped)\b"#) else {
                return false
            }
            let range = NSRange(location: 0, length: (combinedContent as NSString).length)
            return regex.firstMatch(in: combinedContent, range: range) != nil
        }
        let patterns = [
            #"\$\{?([A-Z][A-Z0-9_]{2,})"#,
            #"os\.environ\.get\(["']([A-Z][A-Z0-9_]{2,})["']\)"#,
            #"os\.environ\[['"]([A-Z][A-Z0-9_]{2,})['"]\]"#,
            #"ENV\[['"]([A-Z][A-Z0-9_]{2,})['"]\]"#
        ]

        var detected: [String] = []
        let nsContent = combinedContent as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: combinedContent, range: NSRange(location: 0, length: nsContent.length))
            for match in matches where match.numberOfRanges > 1 {
                detected.append(nsContent.substring(with: match.range(at: 1)))
            }
        }

        let declared = Set(skill.requiredEnvironmentVariables)
        let filtered = detected.filter { declared.isEmpty || declared.contains($0) }
        let merged = declaredMatches + filtered
        return Array(NSOrderedSet(array: merged)) as? [String] ?? []
    }

    private func combinedReferencedScriptContent(for skill: AgentSkill, startingAt scriptPath: String) -> String {
        var visited = Set<String>()
        var queue = [scriptPath]
        var combined: [String] = []

        let scriptsByBasename = Dictionary(grouping: skill.scriptResources, by: {
            URL(fileURLWithPath: $0.relativePath).lastPathComponent
        })

        while let currentPath = queue.first {
            queue.removeFirst()
            guard !visited.contains(currentPath) else { continue }
            visited.insert(currentPath)

            guard let content = try? String(contentsOfFile: currentPath, encoding: .utf8) else { continue }
            combined.append(content)

            for (basename, resources) in scriptsByBasename {
                guard content.contains(basename) else { continue }
                for resource in resources {
                    let nextPath = canonicalPathForComparison((skill.skillDirectory as NSString).appendingPathComponent(resource.relativePath))
                    if !visited.contains(nextPath) {
                        queue.append(nextPath)
                    }
                }
            }
        }

        return combined.joined(separator: "\n")
    }

    private func resolvedLaunchIssue(for launch: (executable: String, arguments: [String], displayName: String)) -> String? {
        if launch.executable == "/usr/bin/env" {
            guard let command = launch.arguments.first else { return "/usr/bin/env arguments missing" }
            return resolveCommandPath(command) == nil ? command : nil
        }

        return FileManager.default.isExecutableFile(atPath: launch.executable) ? nil : launch.executable
    }

    private func detectMissingCommands(for scriptPath: String) -> [String] {
        guard let content = try? String(contentsOfFile: scriptPath, encoding: .utf8) else { return [] }
        let candidates = ["python3", "python", "node", "ruby", "jq", "curl", "wget", "ffmpeg", "magick", "convert", "uv", "pip", "pip3"]
        var missing: [String] = []
        for command in candidates {
            if content.contains("\(command) ") || content.contains("/\(command)") {
                if resolveCommandPath(command) == nil {
                    missing.append(command)
                }
            }
        }
        return Array(NSOrderedSet(array: missing)) as? [String] ?? []
    }

    private func detectMissingPythonModules(for scriptPath: String, environment: [String: String]) -> [String] {
        guard let content = try? String(contentsOfFile: scriptPath, encoding: .utf8) else { return [] }

        var required: [String] = []
        let moduleSignals: [(module: String, patterns: [String])] = [
            ("docx", ["import docx", "from docx", "python-docx"]),
            ("openpyxl", ["import openpyxl", "from openpyxl"]),
            ("PIL", ["import PIL", "from PIL", "Image.open("])
        ]

        for signal in moduleSignals {
            if signal.patterns.contains(where: { content.contains($0) }) {
                required.append(signal.module)
            }
        }

        let uniqueRequired = Array(NSOrderedSet(array: required)) as? [String] ?? []
        guard !uniqueRequired.isEmpty,
              let pythonPath = resolvedDocumentPythonPath(environment: environment) else {
            return uniqueRequired
        }

        let available = documentPythonModules(using: pythonPath)
        return uniqueRequired.filter { available[$0] != true }
    }

    private func preloadDocumentCapabilitiesIfNeeded() {
        documentCapabilityLock.lock()
        let shouldStart = cachedDocumentPythonModules == nil && !isDocumentCapabilityWarmupInFlight
        if shouldStart {
            isDocumentCapabilityWarmupInFlight = true
        }
        documentCapabilityLock.unlock()

        guard shouldStart else { return }

        let compatibilityBinDir = self.compatibilityBinDir
        let fallbackEnvironment = ProcessExecutionEnvironment.shared.resolvedEnvironment(
            prependPathEntries: [compatibilityBinDir]
        )

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let pythonPath = self.resolvedDocumentPythonPath(environment: fallbackEnvironment)
            Task { @MainActor in
                let modules = await self.fetchDocumentPythonModulesAsync(using: pythonPath)
                self.storePreloadedDocumentCapabilities(pythonPath: pythonPath, modules: modules)
            }
        }
    }

    private func storePreloadedDocumentCapabilities(pythonPath: String?, modules: [String: Bool]) {
        documentCapabilityLock.lock()
        if let pythonPath, cachedDocumentPythonPath == nil {
            cachedDocumentPythonPath = pythonPath
        }
        if !modules.isEmpty {
            cachedDocumentPythonModules = modules
        }
        isDocumentCapabilityWarmupInFlight = false
        documentCapabilityLock.unlock()
    }

    private func fetchDocumentPythonModulesAsync(using pythonPath: String?) async -> [String: Bool] {
        guard let pythonPath else { return [:] }

        do {
            let result = try await AsyncProcessRunner.shared.run(
                executableURL: URL(fileURLWithPath: pythonPath),
                arguments: [
                    "-c",
                    """
                    import importlib.util, json
                    mods = ["docx", "openpyxl", "PIL"]
                    print(json.dumps({m: importlib.util.find_spec(m) is not None for m in mods}))
                    """
                ],
                timeout: 5
            )
            guard result.terminationStatus == 0,
                  let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Bool] else {
                return [:]
            }
            return object
        } catch {
            return [:]
        }
    }

    private func resolveCommandPath(_ command: String) -> String? {
        ProcessExecutionEnvironment.shared.resolveCommandPath(
            command,
            environment: resolvedExecutionEnvironment()
        )
    }

    private func normalizedWorkspaceExecutionDirectory() -> String {
        URL(fileURLWithPath: sandboxDir).resolvingSymlinksInPath().path
    }

    private func normalizedScriptArgumentsForExecution(_ args: [String]) -> [String] {
        guard permissionMode == .sandbox else { return args }

        return args.map { argument in
            let expanded = NSString(string: argument).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return argument }

            let canonical = canonicalPathForComparison(expanded)
            guard isInSandbox(canonical) else { return expanded }
            return canonical
        }
    }

    private func resolvedExecutionEnvironment() -> [String: String] {
        ensureCompatibilityShims()

        var environment = ProcessExecutionEnvironment.shared.resolvedEnvironment(
            prependPathEntries: [compatibilityBinDir]
        )

        if let documentPython = resolvedDocumentPythonPath(environment: environment) {
            environment["MINIAGENT_DOC_PYTHON"] = documentPython
        }
        environment["MINIAGENT_DOC_PIP"] = (compatibilityBinDir as NSString).appendingPathComponent("miniagent-doc-pip")

        return environment
    }

    private func resolvedDocumentPythonPath(environment: [String: String]? = nil) -> String? {
        if let cachedDocumentPythonPath,
           FileManager.default.isExecutableFile(atPath: cachedDocumentPythonPath) {
            return cachedDocumentPythonPath
        }

        let env = environment ?? ProcessInfo.processInfo.environment
        let explicit = env["MINIAGENT_DOC_PYTHON"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            explicit,
            "/opt/miniconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cachedDocumentPythonPath = candidate
                return candidate
            }
        }

        if let resolved = resolveCommandPath("python3") {
            cachedDocumentPythonPath = resolved
            return resolved
        }
        return nil
    }

    private func documentPythonModules(using pythonPath: String) -> [String: Bool] {
        if let cachedDocumentPythonModules {
            return cachedDocumentPythonModules
        }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            "-c",
            """
            import importlib.util, json
            mods = ["docx", "openpyxl", "PIL"]
            print(json.dumps({m: importlib.util.find_spec(m) is not None for m in mods}))
            """
        ]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
                return [:]
            }
            cachedDocumentPythonModules = object
            return object
        } catch {
            return [:]
        }
    }

    private func ensureCompatibilityShims() {
        let python3Shim = """
        #!/bin/bash
        SELF="$(cd "$(dirname "$0")" && pwd)/python3"
        for candidate in "$MINIAGENT_DOC_PYTHON" /opt/miniconda3/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
          if [ -n "$candidate" ] && [ -x "$candidate" ] && [ "$candidate" != "$SELF" ]; then
            exec "$candidate" "$@"
          fi
        done
        if command -v /usr/bin/python3 >/dev/null 2>&1; then
          exec /usr/bin/python3 "$@"
        fi
        echo "python3: command not found" >&2
        exit 127
        """

        let pythonShim = """
        #!/bin/bash
        exec "$(cd "$(dirname "$0")" && pwd)/python3" "$@"
        """

        let docPythonShim = """
        #!/bin/bash
        exec "$(cd "$(dirname "$0")" && pwd)/python3" "$@"
        """

        let docPipShim = """
        #!/bin/bash
        exec "$(cd "$(dirname "$0")" && pwd)/miniagent-doc-python" -m pip "$@"
        """

        let docEnvShim = """
        #!/bin/bash
        PYTHON_BIN="$(cd "$(dirname "$0")" && pwd)/miniagent-doc-python"
        exec "$PYTHON_BIN" -c 'import importlib.util, json, sys; mods=["docx","openpyxl","PIL"]; print(json.dumps({"python": sys.executable, "modules": {m: importlib.util.find_spec(m) is not None for m in mods}}, ensure_ascii=False))'
        """

        let rgShim = """
        #!/bin/bash
        exec /usr/bin/grep "$@"
        """

        writeShimIfNeeded(name: "python3", content: python3Shim)
        writeShimIfNeeded(name: "python", content: pythonShim)
        writeShimIfNeeded(name: "miniagent-doc-python", content: docPythonShim)
        writeShimIfNeeded(name: "miniagent-doc-pip", content: docPipShim)
        writeShimIfNeeded(name: "miniagent-doc-env", content: docEnvShim)
        writeShimIfNeeded(name: "rg", content: rgShim)
    }

    private func writeShimIfNeeded(name: String, content: String) {
        let path = (compatibilityBinDir as NSString).appendingPathComponent(name)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        guard existing != content else { return }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
        } catch {
            return
        }
    }

    private func skillResourceHeader(skill: AgentSkill, resource: AgentSkillResource) -> String {
        """
        [Skill: \(skill.name)]
        [Resource: \(resource.relativePath)]
        [Kind: \(resource.kind.rawValue)]
        """
    }

    private func skillResourceUsageHint(for resource: AgentSkillResource) -> String {
        if resource.relativePath == "SKILL.md" {
            return "Usage hint: 这是 skill 的主说明文件，适合读取完整规则、执行步骤和注意事项。"
        }
        switch resource.kind {
        case .reference:
            return "Usage hint: 这是参考资料，适合提取规则、步骤、约束和示例。"
        case .template:
            return "Usage hint: 这是模板文件，适合作为输出骨架或起始内容。"
        case .script:
            return "Usage hint: 这是 skill 脚本；你可以先阅读实现，再按需要通过 run_skill_script 执行。skill 脚本走独立运行时，默认允许联网，不受普通 shell 开关影响。"
        case .asset:
            return "Usage hint: 这是资源文件；如果是二进制资产，请结合元信息决定是否需要继续引用或让用户手动查看。"
        case .other:
            return "Usage hint: 这是 skill 附带文件，可按内容类型决定如何使用。"
        }
    }

    private func scriptSummaryHints(from content: String) -> [String] {
        var hints: [String] = []
        let lines = content.components(separatedBy: .newlines)
        if let first = lines.first, first.hasPrefix("#!") {
            hints.append("Script hint: interpreter \(first)")
        }
        if content.contains("--help") || content.contains("argparse") || content.contains("ArgumentParser") || content.contains("click.") {
            hints.append("Script hint: 该脚本很可能支持命令行参数或 --help。")
        }
        if content.contains("stdin") || content.contains("stdout") {
            hints.append("Script hint: 脚本可能通过标准输入/输出交换数据。")
        }
        return hints
    }

    private func clipScriptOutput(_ output: String, limit: Int) -> String {
        guard !output.isEmpty else { return "" }
        if output.count <= limit {
            return output
        }
        return String(output.prefix(limit)) + "\n... (已截断)"
    }

    private func shellBypassMessageIfNeeded(command: String) -> String? {
        let normalizedCommand = command.lowercased()
        let activeSkills = skillManager.skills(withIDs: activeSkillIDs)

        for skill in activeSkills {
            let directoryCandidates = Set([
                skill.skillDirectory,
                canonicalPathForComparison(skill.skillDirectory)
            ].map { $0.lowercased() })

            if directoryCandidates.contains(where: { normalizedCommand.contains($0) }) {
                return """
                ⚠️ 检测到你正尝试通过 shell 直接运行已激活 skill 的目录：\(skill.name)。
                为了保持权限控制、依赖检查和执行进度一致，请改用 run_skill_script(skill_name: "\(skill.name)", path: "scripts/...")
                """
            }

            guard normalizedCommand.contains("scripts/") else { continue }
            for script in skill.scriptResources {
                let relative = script.relativePath.lowercased()
                let basename = URL(fileURLWithPath: script.relativePath).lastPathComponent.lowercased()
                if normalizedCommand.contains(relative) || normalizedCommand.contains(basename) {
                    return """
                    ⚠️ 检测到你正尝试通过 shell 直接运行已激活 skill 的脚本：\(skill.name) / \(script.relativePath)。
                    为了保持权限控制、依赖检查和执行进度一致，请改用 run_skill_script(skill_name: "\(skill.name)", path: "\(script.relativePath)")
                    """
                }
            }
        }

        return nil
    }

    private func throttledProgressReporter(_ callback: ((String) -> Void)?) -> (String) -> Void {
        guard let callback else {
            return { _ in }
        }

        let lock = NSLock()
        var lastEmission = Date.distantPast
        return { rawMessage in
            let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }

            lock.lock()
            let now = Date()
            let shouldEmit = now.timeIntervalSince(lastEmission) >= 0.35
            if shouldEmit {
                lastEmission = now
            }
            lock.unlock()

            if shouldEmit {
                callback(message.count > 220 ? String(message.prefix(220)) + "…" : message)
            }
        }
    }

    private func terminateProcess(_ process: Process, graceSeconds: TimeInterval) -> Bool {
        guard process.isRunning else { return true }

        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(graceSeconds)
        while process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let forcedDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < forcedDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if process.isRunning {
            return false
        }

        process.waitUntilExit()
        return true
    }

    private func registerActiveProcess(_ process: Process) {
        activeProcessLock.lock()
        activeProcess = process
        activeProcessLock.unlock()
    }

    private func unregisterActiveProcess(_ process: Process) {
        activeProcessLock.lock()
        if activeProcess === process {
            activeProcess = nil
        }
        activeProcessLock.unlock()
    }

    private func buildSkillScriptOperation(
        operationId: String,
        skill: AgentSkill,
        resource: AgentSkillResource,
        args: [String],
        status: String,
        exitCode: Int?,
        summary: String,
        detailLines: [String]
    ) -> FileOperationRecord {
        FileOperationRecord(
            id: operationId,
            toolName: ToolDefinition.ToolName.runSkillScript.rawValue,
            title: "运行 Skill 脚本",
            summary: summary,
            detailLines: detailLines + [
                "工作目录：\(sandboxDir)",
                "退出码：\(exitCode.map(String.init) ?? "(none)")"
            ],
            createdAt: Date(),
            undoAction: nil,
            isUndone: false
        )
    }

    private func binaryResourceSummary(path: String, resource: AgentSkillResource) -> String {
        let fileURL = URL(fileURLWithPath: path)
        let ext = fileURL.pathExtension.lowercased()
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        var lines = [
            "该资源是二进制或非 UTF-8 文本，未直接展开内容。",
            "Absolute path: \(path)",
            "Extension: \(ext.isEmpty ? "(none)" : ext)",
            "Size: \(size) bytes"
        ]

        if imageExtensions.contains(ext),
           let rep = NSImageRep(contentsOf: fileURL) {
            lines.append("Image size: \(Int(rep.pixelsWide))x\(Int(rep.pixelsHigh)) px")
        } else if ext == "pdf" {
            lines.append("Document type: PDF")
        } else if resource.kind == .script {
            lines.append("Note: 脚本未被展开，通常说明编码不可直接按 UTF-8 读取。")
        }

        return lines.joined(separator: "\n")
    }

    private var imageExtensions: Set<String> {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg"]
    }
}

private struct DOCXImageInput {
    let path: String
    let widthPoints: Double?
    let caption: String?
}

private struct DOCXEmbeddedImage {
    let originalPath: String
    let caption: String?
    let data: Data
    let widthEMU: Int
    let heightEMU: Int
}

private enum DOCXContentBlock {
    case title(String)
    case heading(level: Int, text: String)
    case paragraph(String)
    case image(DOCXEmbeddedImage)
}

private struct SpreadsheetSheet {
    let name: String
    var rows: [[String]]
}

private final class ToolRunnerXMLTextExtractor: NSObject, XMLParserDelegate {
    private var currentText = ""
    private var currentParagraphText = ""
    private var currentParagraphStyle: String?
    private var blocks: [String] = []

    static func extractPlainText(from data: Data) -> String {
        let extractor = ToolRunnerXMLTextExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        let element = qName ?? elementName
        if element.hasSuffix(":p") || element == "p" {
            currentParagraphText = ""
            currentParagraphStyle = nil
        }

        if element.hasSuffix(":pStyle") || element == "pStyle" {
            currentParagraphStyle = attributeDict["w:val"] ?? attributeDict["val"] ?? currentParagraphStyle
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = qName ?? elementName
        if element.hasSuffix(":t") || element == "t" || element.hasSuffix(":v") || element == "v" {
            if !currentText.isEmpty {
                currentParagraphText += currentText
            }
        } else if element.hasSuffix(":p") || element == "p" {
            let trimmed = currentParagraphText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let headingLevel = headingLevel(for: currentParagraphStyle) {
                    let marker = String(repeating: "#", count: headingLevel)
                    blocks.append("\(marker) \(trimmed)")
                } else {
                    blocks.append(trimmed)
                }
            }
            blocks.append("\n")
            currentParagraphText = ""
            currentParagraphStyle = nil
        } else if element.hasSuffix(":tr") || element == "tr" {
            blocks.append("\n")
        }
        currentText = ""
    }

    private func headingLevel(for style: String?) -> Int? {
        guard let style else { return nil }
        if style == "Title" { return 1 }
        if style.hasPrefix("Heading"), let level = Int(style.replacingOccurrences(of: "Heading", with: "")) {
            return min(max(level, 1), 6)
        }
        return nil
    }
}

private final class ToolRunnerSharedStringsExtractor: NSObject, XMLParserDelegate {
    private var currentText = ""
    private var currentItem = ""
    private var strings: [String] = []

    static func extract(from data: Data) throws -> [String] {
        let extractor = ToolRunnerSharedStringsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.strings
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = qName ?? elementName
        if element.hasSuffix(":t") || element == "t" {
            currentItem += currentText
        } else if element.hasSuffix(":si") || element == "si" {
            strings.append(currentItem.trimmingCharacters(in: .whitespacesAndNewlines))
            currentItem = ""
        }
        currentText = ""
    }
}

private final class ToolRunnerWorksheetExtractor: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentRow: [String] = []
    private var currentCellType: String?
    private var currentValue = ""
    private var collectingValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func extractRows(from data: Data, sharedStrings: [String]) -> [[String]] {
        let extractor = ToolRunnerWorksheetExtractor(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let element = qName ?? elementName
        if element.hasSuffix(":row") || element == "row" {
            currentRow = []
        } else if element.hasSuffix(":c") || element == "c" {
            currentCellType = attributeDict["t"]
            currentValue = ""
        } else if element.hasSuffix(":v") || element == "v" || element.hasSuffix(":t") || element == "t" {
            collectingValue = true
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingValue {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = qName ?? elementName
        if element.hasSuffix(":v") || element == "v" || element.hasSuffix(":t") || element == "t" {
            collectingValue = false
        } else if element.hasSuffix(":c") || element == "c" {
            currentRow.append(resolvedCellValue())
            currentValue = ""
            currentCellType = nil
        } else if element.hasSuffix(":row") || element == "row" {
            if currentRow.contains(where: { !$0.isEmpty }) {
                rows.append(currentRow)
            }
            currentRow = []
        }
    }

    private func resolvedCellValue() -> String {
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if currentCellType == "s", let index = Int(trimmed), sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }
        return trimmed
    }
}

private struct ToolRunnerWorkbookSheetMetadata {
    let name: String
    let relationshipID: String
}

private final class ToolRunnerWorkbookSheetsExtractor: NSObject, XMLParserDelegate {
    private var sheets: [ToolRunnerWorkbookSheetMetadata] = []

    static func extract(from data: Data) -> [ToolRunnerWorkbookSheetMetadata] {
        let extractor = ToolRunnerWorkbookSheetsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let element = qName ?? elementName
        guard element.hasSuffix(":sheet") || element == "sheet" else { return }
        guard let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] else { return }
        sheets.append(ToolRunnerWorkbookSheetMetadata(name: name, relationshipID: relationshipID))
    }
}

private final class ToolRunnerWorkbookRelationshipsExtractor: NSObject, XMLParserDelegate {
    private var relationships: [String: String] = [:]

    static func extract(from data: Data) throws -> [String: String] {
        let extractor = ToolRunnerWorkbookRelationshipsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.relationships
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let element = qName ?? elementName
        guard element.hasSuffix(":Relationship") || element == "Relationship" else { return }
        guard let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        relationships[id] = target
    }
}

private final class PDFRenderView: NSView {
    private let attributedText: NSAttributedString
    private let contentInsets: NSEdgeInsets

    init(frame frameRect: NSRect, attributedText: NSAttributedString, contentInsets: NSEdgeInsets) {
        self.attributedText = attributedText
        self.contentInsets = contentInsets
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.setFill()
        bounds.fill()
        let textRect = bounds.insetBy(dx: contentInsets.left, dy: contentInsets.top)
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

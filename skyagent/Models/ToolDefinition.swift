import Foundation

struct ToolCall: Codable {
    let name: String
    let arguments: String
}

enum ToolError: Error, LocalizedError {
    case notFound(String)
    case executionFailed(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): return "工具不存在: \(name)"
        case .executionFailed(let msg): return "执行失败: \(msg)"
        case .invalidArguments(let msg): return "参数错误: \(msg)"
        }
    }
}

// MARK: - Tool Definitions (OpenAI function format)

enum ToolDefinition {
    enum ToolName: String, CaseIterable {
        case shell = "shell"
        case readFile = "read_file"
        case previewImage = "preview_image"
        case writeFile = "write_file"
        case writeAssistantContentToFile = "write_assistant_content_to_file"
        case writeMultipleFiles = "write_multiple_files"
        case movePaths = "move_paths"
        case deletePaths = "delete_paths"
        case writeDOCX = "write_docx"
        case writeXLSX = "write_xlsx"
        case replaceDOCXSection = "replace_docx_section"
        case insertDOCXSection = "insert_docx_section"
        case appendXLSXRows = "append_xlsx_rows"
        case updateXLSXCell = "update_xlsx_cell"
        case webFetch = "web_fetch"
        case webSearch = "web_search"
        case listFiles = "list_files"
        case importFile = "import_file"
        case importDirectory = "import_directory"
        case importFileContent = "import_file_content"
        case exportFile = "export_file"
        case exportDirectory = "export_directory"
        case exportPDF = "export_pdf"
        case exportDOCX = "export_docx"
        case exportXLSX = "export_xlsx"
        case listExternalFiles = "list_external_files"
        case activateSkill = "activate_skill"
        case installSkill = "install_skill"
        case readSkillResource = "read_skill_resource"
        case runSkillScript = "run_skill_script"
        case readUploadedAttachment = "read_uploaded_attachment"
    }

    /// 按权限模式生成 OpenAI tools 格式
    static func definitions(for mode: FilePermissionMode, hasSkills: Bool = false) -> [[String: Any]] {
        var tools: [[String: Any]] = []

        if mode == .open {
            tools.append(
                function(
                    name: ToolName.shell.rawValue,
                    description: "在当前会话工作目录执行 shell 命令。开放模式下允许访问其他系统路径。仅在结构化工具无法覆盖时使用；如果任务只是统计数量、查找多少个文件、列出少量样例，请优先让命令直接返回计数和少量样例，不要输出完整超长列表。",
                    properties: [
                        "command": [
                            "type": "string",
                            "description": "要执行的 shell 命令"
                        ]
                    ],
                    required: ["command"]
                )
            )
        }

        tools.append(
            function(
                name: ToolName.readFile.rawValue,
                description: mode == .sandbox
                    ? "读取文件内容预览（最大返回前 50KB）。如果文件更大，工具会明确说明这是“预览被截断”，不代表文件本身被截断。沙盒模式下可读取当前会话工作目录和其他系统路径，但只有当前会话工作目录可写。"
                    : "读取文件内容预览（最大返回前 50KB）。如果文件更大，工具会明确说明这是“预览被截断”，不代表文件本身被截断。默认相对当前会话工作目录解析，也可访问其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "文件路径（相对或绝对路径）"
                    ]
                ],
                required: ["path"]
            )
        )

        tools.append(
            function(
                name: ToolName.previewImage.rawValue,
                description: mode == .sandbox
                    ? "在会话中预览一张或多张本地图片。沙盒模式下可读取当前会话工作目录和其他系统路径，但不会修改文件。适用于用户明确要求“预览这张图片”或“在会话里展示这些图片”。"
                    : "在会话中预览一张或多张本地图片。默认相对当前会话工作目录解析，也可读取其他绝对路径。适用于用户明确要求“预览这张图片”或“在会话里展示这些图片”。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "单张图片文件路径（相对或绝对路径）"
                    ],
                    "paths": [
                        "type": "array",
                        "description": "多张图片文件路径列表（相对或绝对路径）",
                        "items": [
                            "type": "string"
                        ]
                    ]
                ],
                required: []
            )
        )

        tools.append(
            function(
                name: ToolName.writeAssistantContentToFile.rawValue,
                description: mode == .sandbox
                    ? "将当前轮 assistant 已生成好的正文直接写入文件（自动创建目录）。这是长篇 Markdown、TXT、方案、PRD、总结等正文写入的默认首选工具，能避免把几千字正文再次塞进 tool arguments 导致等待变慢。调用这个工具前，应先在 assistant 正文里完整给出要写入的内容；工具只负责把这段正文落盘。沙盒模式下只能写入当前会话工作目录及其子目录。"
                    : "将当前轮 assistant 已生成好的正文直接写入文件（自动创建目录）。这是长篇 Markdown、TXT、方案、PRD、总结等正文写入的默认首选工具，能避免把几千字正文再次塞进 tool arguments 导致等待变慢。调用这个工具前，应先在 assistant 正文里完整给出要写入的内容；工具只负责把这段正文落盘。默认相对当前会话工作目录解析，也可写入其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "文件路径"
                    ]
                ],
                required: ["path"]
            )
        )

        tools.append(
            function(
                name: ToolName.writeFile.rawValue,
                description: mode == .sandbox
                    ? "写入文件内容（自动创建目录）。沙盒模式下只能写入当前会话工作目录及其子目录，不能写入其他系统路径。如果需要同时创建或修改多个文件，不要重复调用 write_file，请改用 write_multiple_files 一次完成。如果上一轮写后校验提示需要修复，请优先只修改被点名的单个文件，不要整轮重写无问题文件。这个工具更适合短内容、局部修正和小文件。对于长篇 Markdown、TXT、方案、PRD、总结等正文内容，默认必须优先使用 write_assistant_content_to_file，把当前轮 assistant 已经写好的正文直接落盘；不要把整段长文重新塞进 write_file 的 content 参数。"
                    : "写入文件内容（自动创建目录）。默认相对当前会话工作目录解析，也可写入其他绝对路径。如果需要同时创建或修改多个文件，不要重复调用 write_file，请改用 write_multiple_files 一次完成。如果上一轮写后校验提示需要修复，请优先只修改被点名的单个文件，不要整轮重写无问题文件。这个工具更适合短内容、局部修正和小文件。对于长篇 Markdown、TXT、方案、PRD、总结等正文内容，默认必须优先使用 write_assistant_content_to_file，把当前轮 assistant 已经写好的正文直接落盘；不要把整段长文重新塞进 write_file 的 content 参数。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "文件路径"
                    ],
                    "content": [
                        "type": "string",
                        "description": "文件内容"
                    ]
                ],
                required: ["path", "content"]
            )
        )

        tools.append(
            function(
                name: ToolName.writeMultipleFiles.rawValue,
                description: mode == .sandbox
                    ? "一次写入多个文本文件。适合 HTML+CSS+JS 这类互相关联的网页工程文件。沙盒模式下只能写入当前会话工作目录及其子目录。如果上一轮写后校验提示需要修复，只重写被点名或确实有关联问题的文件集合，不要把整个工程全部重写。"
                    : "一次写入多个文本文件。适合 HTML+CSS+JS 这类互相关联的网页工程文件。默认相对当前会话工作目录解析，也可写入其他绝对路径。如果上一轮写后校验提示需要修复，只重写被点名或确实有关联问题的文件集合，不要把整个工程全部重写。",
                properties: [
                    "files": [
                        "type": "array",
                        "description": "待写入文件列表。请一次性传入所有互相关联的文件，例如 index.html、styles.css、script.js。",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": [
                                    "type": "string",
                                    "description": "文件路径"
                                ],
                                "content": [
                                    "type": "string",
                                    "description": "文件内容"
                                ]
                            ],
                            "required": ["path", "content"]
                        ]
                    ]
                ],
                required: ["files"]
            )
        )

        tools.append(
            function(
                name: ToolName.movePaths.rawValue,
                description: mode == .sandbox
                    ? "批量重命名或移动当前会话工作目录中的文件/目录，也适用于批量修改文件后缀。沙盒模式下 source_path 和 destination_path 都必须位于当前会话工作目录内。需要改名、改后缀、移动文件时，优先使用这个工具，不要生成 shell 脚本。"
                    : "批量重命名或移动文件/目录，也适用于批量修改文件后缀。默认相对当前会话工作目录解析；开放模式下也可处理其他绝对路径。需要改名、改后缀、移动文件时，优先使用这个工具，不要生成 shell 脚本。",
                properties: [
                    "items": [
                        "type": "array",
                        "description": "待移动或重命名的路径映射列表",
                        "items": [
                            "type": "object",
                            "properties": [
                                "source_path": [
                                    "type": "string",
                                    "description": "原路径"
                                ],
                                "destination_path": [
                                    "type": "string",
                                    "description": "目标路径"
                                ]
                            ],
                            "required": ["source_path", "destination_path"]
                        ]
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["items"]
            )
        )

        tools.append(
            function(
                name: ToolName.deletePaths.rawValue,
                description: mode == .sandbox
                    ? "批量删除当前会话工作目录中的文件或目录。默认会尽量移动到系统废纸篓，而不是直接永久删除。沙盒模式下所有路径都必须位于当前会话工作目录内。需要删除文件时，优先使用这个工具，不要生成 shell 脚本。"
                    : "批量删除文件或目录。默认会尽量移动到系统废纸篓，而不是直接永久删除。开放模式下也可处理其他绝对路径。需要删除文件时，优先使用这个工具，不要生成 shell 脚本。",
                properties: [
                    "paths": [
                        "type": "array",
                        "description": "待删除路径列表",
                        "items": [
                            "type": "string"
                        ]
                    ]
                ],
                required: ["paths"]
            )
        )

        tools.append(
            function(
                name: ToolName.writeDOCX.rawValue,
                description: mode == .sandbox
                    ? "把结构化文本内容和可选图片写入或覆盖为 Word(docx) 文件。支持 Markdown 标题映射为 Word Heading 样式，并可内嵌图片。沙盒模式下只能写入当前会话工作目录及其子目录。"
                    : "把结构化文本内容和可选图片写入或覆盖为 Word(docx) 文件。支持 Markdown 标题映射为 Word Heading 样式，并可内嵌图片。默认相对当前会话工作目录解析，也可写入其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "目标 DOCX 路径"
                    ],
                    "title": [
                        "type": "string",
                        "description": "可选，文档标题"
                    ],
                    "content": [
                        "type": "string",
                        "description": "要写入的正文内容，可为空；如果包含 Markdown 标题（如 #、##），会映射为 Word Heading 样式"
                    ],
                    "images": [
                        "type": "array",
                        "description": "可选，要嵌入到文档中的图片列表",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": [
                                    "type": "string",
                                    "description": "图片路径，可为绝对路径或相对当前工作目录路径"
                                ],
                                "width": [
                                    "type": "number",
                                    "description": "可选，图片显示宽度（point）"
                                ],
                                "caption": [
                                    "type": "string",
                                    "description": "可选，图片说明文字"
                                ]
                            ],
                            "required": ["path"]
                        ]
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["path"]
            )
        )

        tools.append(
            function(
                name: ToolName.writeXLSX.rawValue,
                description: mode == .sandbox
                    ? "把结构化表格内容写入或覆盖为 Excel(xlsx) 文件。沙盒模式下只能写入当前会话工作目录及其子目录。"
                    : "把结构化表格内容写入或覆盖为 Excel(xlsx) 文件。默认相对当前会话工作目录解析，也可写入其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "目标 XLSX 路径"
                    ],
                    "sheets": [
                        "type": "array",
                        "description": "工作表列表",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": [
                                    "type": "string",
                                    "description": "工作表名称"
                                ],
                                "rows": [
                                    "type": "array",
                                    "description": "二维表格数据，每一行都是字符串数组",
                                    "items": [
                                        "type": "array",
                                        "items": [
                                            "type": "string"
                                        ]
                                    ]
                                ]
                            ],
                            "required": ["name", "rows"]
                        ]
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["path", "sheets"]
            )
        )

        tools.append(
            function(
                name: ToolName.replaceDOCXSection.rawValue,
                description: mode == .sandbox
                    ? "按章节标题替换现有 Word(docx) 文件中的某一段内容，并支持在该章节后附带图片。沙盒模式下只能修改当前会话工作目录中的文件。"
                    : "按章节标题替换现有 Word(docx) 文件中的某一段内容，并支持在该章节后附带图片。默认相对当前会话工作目录解析，也可在开放模式下修改其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "目标 DOCX 路径"
                    ],
                    "section_title": [
                        "type": "string",
                        "description": "要替换的章节标题"
                    ],
                    "content": [
                        "type": "string",
                        "description": "新的章节内容，可为空"
                    ],
                    "images": [
                        "type": "array",
                        "description": "可选，要跟随该章节一起嵌入的图片列表",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": [
                                    "type": "string",
                                    "description": "图片路径，可为绝对路径或相对当前工作目录路径"
                                ],
                                "width": [
                                    "type": "number",
                                    "description": "可选，图片显示宽度（point）"
                                ],
                                "caption": [
                                    "type": "string",
                                    "description": "可选，图片说明文字"
                                ]
                            ],
                            "required": ["path"]
                        ]
                    ],
                    "append_if_missing": [
                        "type": "boolean",
                        "description": "未找到章节时是否追加到文末"
                    ]
                ],
                required: ["path", "section_title"]
            )
        )

        tools.append(
            function(
                name: ToolName.appendXLSXRows.rawValue,
                description: mode == .sandbox
                    ? "向现有 Excel(xlsx) 的某个工作表追加多行数据。沙盒模式下只能修改当前会话工作目录中的文件。"
                    : "向现有 Excel(xlsx) 的某个工作表追加多行数据。默认相对当前会话工作目录解析，也可在开放模式下修改其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "目标 XLSX 路径"
                    ],
                    "sheet_name": [
                        "type": "string",
                        "description": "要追加的工作表名称"
                    ],
                    "rows": [
                        "type": "array",
                        "description": "要追加的二维表格数据",
                        "items": [
                            "type": "array",
                            "items": [
                                "type": "string"
                            ]
                        ]
                    ],
                    "create_sheet_if_missing": [
                        "type": "boolean",
                        "description": "如果工作表不存在，是否新建"
                    ]
                ],
                required: ["path", "sheet_name", "rows"]
            )
        )

        tools.append(
            function(
                name: ToolName.insertDOCXSection.rawValue,
                description: mode == .sandbox
                    ? "向现有 Word(docx) 文档中插入一个新章节，可指定插入到某个章节之后，并支持在该章节后附带图片。沙盒模式下只能修改当前会话工作目录中的文件。"
                    : "向现有 Word(docx) 文档中插入一个新章节，可指定插入到某个章节之后，并支持在该章节后附带图片。默认相对当前会话工作目录解析，也可在开放模式下修改其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "目标 DOCX 路径"
                    ],
                    "section_title": [
                        "type": "string",
                        "description": "要插入的新章节标题"
                    ],
                    "content": [
                        "type": "string",
                        "description": "新章节内容，可为空"
                    ],
                    "images": [
                        "type": "array",
                        "description": "可选，要跟随该章节一起嵌入的图片列表",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": [
                                    "type": "string",
                                    "description": "图片路径，可为绝对路径或相对当前工作目录路径"
                                ],
                                "width": [
                                    "type": "number",
                                    "description": "可选，图片显示宽度（point）"
                                ],
                                "caption": [
                                    "type": "string",
                                    "description": "可选，图片说明文字"
                                ]
                            ],
                            "required": ["path"]
                        ]
                    ],
                    "after_section_title": [
                        "type": "string",
                        "description": "可选，插入到哪个已有章节之后；不传则追加到文末"
                    ]
                ],
                required: ["path", "section_title"]
            )
        )

        tools.append(
            function(
                name: ToolName.updateXLSXCell.rawValue,
                description: mode == .sandbox
                    ? "更新现有 Excel(xlsx) 文件中某个工作表的指定单元格。沙盒模式下只能修改当前会话工作目录中的文件。"
                    : "更新现有 Excel(xlsx) 文件中某个工作表的指定单元格。默认相对当前会话工作目录解析，也可在开放模式下修改其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "目标 XLSX 路径"
                    ],
                    "sheet_name": [
                        "type": "string",
                        "description": "要更新的工作表名称"
                    ],
                    "cell": [
                        "type": "string",
                        "description": "目标单元格，使用 A1 形式，例如 B3"
                    ],
                    "value": [
                        "type": "string",
                        "description": "要写入的新值"
                    ],
                    "create_sheet_if_missing": [
                        "type": "boolean",
                        "description": "如果工作表不存在，是否新建"
                    ]
                ],
                required: ["path", "sheet_name", "cell", "value"]
            )
        )

        tools.append(
            function(
                name: ToolName.webFetch.rawValue,
                description: "抓取并结构化提取网页正文内容。支持 HTTP 和 HTTPS；会尽量提取标题、摘要、结构标题和正文片段；如果目标站点的 HTTP / HTTPS 配置异常，会返回更明确的诊断信息。",
                properties: [
                    "url": [
                        "type": "string",
                        "description": "网页 URL"
                    ]
                ],
                required: ["url"]
            )
        )

        tools.append(
            function(
                name: ToolName.webSearch.rawValue,
                description: "使用公开搜索引擎进行网页搜索，返回标题、链接与摘要。支持 bing / google / baidu，默认自动选择可用结果最多的引擎。",
                properties: [
                    "query": [
                        "type": "string",
                        "description": "搜索关键词"
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "返回结果数量（1-10）"
                    ],
                    "engine": [
                        "type": "string",
                        "description": "搜索引擎：auto / bing / google / baidu"
                    ]
                ],
                required: ["query"]
            )
        )

        tools.append(
            function(
                name: ToolName.listFiles.rawValue,
                description: mode == .sandbox
                    ? "列出目录文件（支持递归）。沙盒模式下可查看当前会话工作目录和其他系统路径，但只有当前会话工作目录可写。适合目录浏览、确认目标文件或浅层查看；不适合代替递归扩展名统计或大目录树数量统计。"
                    : "列出目录文件（支持递归）。默认相对当前会话工作目录解析，也可查看其他绝对路径。适合目录浏览、确认目标文件或浅层查看；不适合代替递归扩展名统计或大目录树数量统计。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "目录路径（默认为当前会话工作目录）"
                    ],
                    "recursive": [
                        "type": "boolean",
                        "description": "是否递归列出子目录"
                    ]
                ],
                required: []
            )
        )

        tools.append(
            function(
                name: ToolName.importFile.rawValue,
                description: "把工作目录之外的文件复制导入到当前会话工作目录。只会复制，不会删除源文件。",
                properties: [
                    "source_path": [
                        "type": "string",
                        "description": "外部源文件路径（绝对路径或 ~/ 路径）"
                    ],
                    "destination_path": [
                        "type": "string",
                        "description": "导入到当前会话工作目录内的相对路径；不填时使用源文件名"
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["source_path"]
            )
        )

        tools.append(
            function(
                name: ToolName.importDirectory.rawValue,
                description: "把工作目录之外的目录递归复制导入到当前会话工作目录。只会复制，不会删除源目录。",
                properties: [
                    "source_path": [
                        "type": "string",
                        "description": "外部源目录路径（绝对路径或 ~/ 路径）"
                    ],
                    "destination_path": [
                        "type": "string",
                        "description": "导入到当前会话工作目录内的相对路径；不填时使用源目录名"
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["source_path"]
            )
        )

        tools.append(
            function(
                name: ToolName.importFileContent.rawValue,
                description: "读取工作目录之外某个文件的文本内容，供你在当前会话工作目录内生成新文件或继续处理。",
                properties: [
                    "source_path": [
                        "type": "string",
                        "description": "外部文本文件路径（绝对路径或 ~/ 路径）"
                    ]
                ],
                required: ["source_path"]
            )
        )

        tools.append(
            function(
                name: ToolName.exportFile.rawValue,
                description: "把当前会话工作目录内的文件复制导出到外部路径。",
                properties: [
                    "source_path": [
                        "type": "string",
                        "description": "当前会话工作目录内的相对路径"
                    ],
                    "destination_path": [
                        "type": "string",
                        "description": "外部目标路径（绝对路径或 ~/ 路径）"
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["source_path", "destination_path"]
            )
        )

        tools.append(
            function(
                name: ToolName.exportDirectory.rawValue,
                description: "把当前会话工作目录内的目录递归复制导出到外部路径。",
                properties: [
                    "source_path": [
                        "type": "string",
                        "description": "当前会话工作目录内的相对目录路径"
                    ],
                    "destination_path": [
                        "type": "string",
                        "description": "外部目标目录路径（绝对路径或 ~/ 路径）"
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["source_path", "destination_path"]
            )
        )

        tools.append(
            function(
                name: ToolName.exportPDF.rawValue,
                description: mode == .sandbox
                    ? "把文本内容导出为 PDF 文件到当前会话工作目录。沙盒模式下只能写入当前会话工作目录及其子目录。"
                    : "把文本内容导出为 PDF 文件到当前会话工作目录，或开放模式下的其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "输出 PDF 路径"
                    ],
                    "title": [
                        "type": "string",
                        "description": "可选，PDF 标题"
                    ],
                    "content": [
                        "type": "string",
                        "description": "要导出的正文内容"
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["path", "content"]
            )
        )

        tools.append(
            function(
                name: ToolName.exportDOCX.rawValue,
                description: mode == .sandbox
                    ? "把文本内容和可选图片导出为 Word(docx) 文件到当前会话工作目录。支持 Markdown 标题映射为 Word Heading 样式，并可内嵌图片。沙盒模式下只能写入当前会话工作目录及其子目录。"
                    : "把文本内容和可选图片导出为 Word(docx) 文件到当前会话工作目录，或开放模式下的其他绝对路径。支持 Markdown 标题映射为 Word Heading 样式，并可内嵌图片。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "输出 DOCX 路径"
                    ],
                    "title": [
                        "type": "string",
                        "description": "可选，文档标题"
                    ],
                    "content": [
                        "type": "string",
                        "description": "要导出的正文内容，可为空；如果包含 Markdown 标题（如 #、##），会映射为 Word Heading 样式"
                    ],
                    "images": [
                        "type": "array",
                        "description": "可选，要嵌入到文档中的图片列表",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": [
                                    "type": "string",
                                    "description": "图片路径，可为绝对路径或相对当前工作目录路径"
                                ],
                                "width": [
                                    "type": "number",
                                    "description": "可选，图片显示宽度（point）"
                                ],
                                "caption": [
                                    "type": "string",
                                    "description": "可选，图片说明文字"
                                ]
                            ],
                            "required": ["path"]
                        ]
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["path"]
            )
        )

        tools.append(
            function(
                name: ToolName.exportXLSX.rawValue,
                description: mode == .sandbox
                    ? "把结构化表格内容导出为 Excel(xlsx) 文件到当前会话工作目录。沙盒模式下只能写入当前会话工作目录及其子目录。"
                    : "把结构化表格内容导出为 Excel(xlsx) 文件到当前会话工作目录，或开放模式下的其他绝对路径。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "输出 XLSX 路径"
                    ],
                    "sheets": [
                        "type": "array",
                        "description": "工作表列表",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": [
                                    "type": "string",
                                    "description": "工作表名称"
                                ],
                                "rows": [
                                    "type": "array",
                                    "description": "二维表格数据，每一行都是字符串数组",
                                    "items": [
                                        "type": "array",
                                        "items": [
                                            "type": "string"
                                        ]
                                    ]
                                ]
                            ],
                            "required": ["name", "rows"]
                        ]
                    ],
                    "overwrite": [
                        "type": "boolean",
                        "description": "目标已存在时是否覆盖"
                    ]
                ],
                required: ["path", "sheets"]
            )
        )

        tools.append(
            function(
                name: ToolName.listExternalFiles.rawValue,
                description: "列出工作目录之外某个目录的文件清单，便于选择要导入的文件或目录。",
                properties: [
                    "path": [
                        "type": "string",
                        "description": "外部目录路径（绝对路径或 ~/ 路径）"
                    ],
                    "recursive": [
                        "type": "boolean",
                        "description": "是否递归列出子目录"
                    ]
                ],
                required: ["path"]
            )
        )

        tools.append(
            function(
                name: ToolName.installSkill.rawValue,
                description: "下载并安装一个新的 Agent Skill 到 ~/.skyagent/skills。支持 GitHub tree URL，或 repo + path 形式。安装完成后，如果当前任务就要使用它，请继续调用 activate_skill。",
                properties: [
                    "url": [
                        "type": "string",
                        "description": "可选，GitHub tree URL，例如 https://github.com/owner/repo/tree/main/path/to/skill"
                    ],
                    "repo": [
                        "type": "string",
                        "description": "可选，GitHub 仓库名，格式 owner/repo"
                    ],
                    "path": [
                        "type": "string",
                        "description": "可选，仓库中的 skill 目录路径"
                    ],
                    "ref": [
                        "type": "string",
                        "description": "可选，git ref，默认 main"
                    ],
                    "name": [
                        "type": "string",
                        "description": "可选，安装后的目录名；不填时使用 skill 目录名"
                    ]
                ],
                required: []
            )
        )

        tools.append(
            function(
                name: ToolName.activateSkill.rawValue,
                description: "激活当前应用全局可用的 Agent Skill。只有当任务明显匹配某个 skill 时才调用，参数使用 skill 的精确名称。",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "要激活的 skill 名称"
                    ]
                ],
                required: ["name"]
            )
        )

        tools.append(
            function(
                name: ToolName.readSkillResource.rawValue,
                description: "读取一个已激活 Agent Skill 中的资源文件。适合按需读取 SKILL.md、references/templates/scripts/assets 中的具体文件，路径必须使用激活 skill 输出里的相对路径。",
                properties: [
                    "skill_name": [
                        "type": "string",
                        "description": "已激活的 skill 名称"
                    ],
                    "path": [
                        "type": "string",
                        "description": "skill 目录中的相对资源路径，例如 references/guide.md"
                    ]
                ],
                required: ["skill_name", "path"]
            )
        )

        tools.append(
            function(
                name: ToolName.readUploadedAttachment.rawValue,
                description: "读取当前会话中已上传附件的内容。支持按块读取，也支持按 page_number/page_start-page_end、sheet_index/sheet_name、segment_index/segment_title 精确读取。",
                properties: [
                    "attachment_id": [
                        "type": "string",
                        "description": "已上传附件的 ID"
                    ],
                    "chunk_index": [
                        "type": "integer",
                        "description": "要读取的单个块编号（从 1 开始）"
                    ],
                    "start_chunk": [
                        "type": "integer",
                        "description": "可选，范围读取的起始块编号"
                    ],
                    "end_chunk": [
                        "type": "integer",
                        "description": "可选，范围读取的结束块编号"
                    ],
                    "page_number": [
                        "type": "integer",
                        "description": "可选，读取指定页。适用于 PDF 和 PowerPoint。"
                    ],
                    "page_start": [
                        "type": "integer",
                        "description": "可选，读取连续页范围的起始页。适用于 PDF 和 PowerPoint。"
                    ],
                    "page_end": [
                        "type": "integer",
                        "description": "可选，读取连续页范围的结束页。适用于 PDF 和 PowerPoint。"
                    ],
                    "sheet_index": [
                        "type": "integer",
                        "description": "可选，读取指定工作表。适用于 Excel。"
                    ],
                    "sheet_name": [
                        "type": "string",
                        "description": "可选，按工作表名称读取。适用于 Excel。"
                    ],
                    "segment_index": [
                        "type": "integer",
                        "description": "可选，读取指定片段。适用于 Word、文本、Markdown、代码等。"
                    ],
                    "segment_title": [
                        "type": "string",
                        "description": "可选，按片段标题读取。适用于 Word、文本、Markdown、代码，也适用于带标题的 PowerPoint 页。"
                    ]
                ],
                required: ["attachment_id"]
            )
        )

        tools.append(
            function(
                name: ToolName.runSkillScript.rawValue,
                description: "运行一个已激活 Agent Skill 中的脚本。该工具使用独立的 Skill Runtime，默认允许联网，不受普通 shell 开关影响。脚本路径必须使用 skill 中 scripts/ 下的相对路径。",
                properties: [
                    "skill_name": [
                        "type": "string",
                        "description": "已激活的 skill 名称"
                    ],
                    "path": [
                        "type": "string",
                        "description": "skill 中 scripts/ 下的相对路径，例如 scripts/run.py"
                    ],
                    "args": [
                        "type": "array",
                        "description": "传给脚本的参数列表",
                        "items": [
                            "type": "string"
                        ]
                    ],
                    "stdin": [
                        "type": "string",
                        "description": "可选，传给脚本标准输入的文本"
                    ]
                ],
                required: ["skill_name", "path"]
            )
        )

        return tools
    }

    private static func function(name: String, description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ] as [String: Any]
            ]
        ]
    }
}

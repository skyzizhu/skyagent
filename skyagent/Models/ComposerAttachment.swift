import Foundation
import AppKit
import PDFKit
import Vision

struct ComposerAttachment: Identifiable {
    enum Kind {
        case image
        case document
    }

    let id = UUID()
    let kind: Kind
    let fileName: String
    let detail: String
    let previewImage: NSImage?
    let userVisibleLabel: String
    let modelContext: String
    let imageDataURL: String?
    let attachmentID: String?
    let structureSummary: String?
    let structureItems: [String]

    nonisolated private static let maxDocumentCharacters = 24_000
    nonisolated private static let maxPDFOCRPages = 12
    nonisolated private static let maxUploadFileSizeBytes = 25 * 1024 * 1024
    nonisolated private static let chunkSize = 3_500
    nonisolated private static let previewChunkLength = 900
    nonisolated private static let supportedTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "xml", "yaml", "yml",
        "html", "css", "js", "jsx", "ts", "tsx", "py", "swift", "java",
        "c", "cc", "cpp", "h", "hpp", "go", "rs", "rb", "sh", "zsh",
        "bash", "sql", "kt", "m", "mm", "php", "vue"
    ]
    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "heif", "webp"
    ]
    nonisolated private static let officeExtensions: Set<String> = ["docx", "xlsx", "pptx"]

    typealias ProgressHandler = @Sendable (ComposerAttachmentParsingProgress) -> Void

    nonisolated static var supportedFileExtensions: [String] {
        Array(imageExtensions.union(supportedTextExtensions).union(officeExtensions).union(["pdf"])).sorted()
    }

    nonisolated static func parsingKind(forExtension ext: String) -> ComposerAttachmentStatus.Kind {
        let normalized = ext.lowercased()
        if imageExtensions.contains(normalized) {
            return .image
        }
        if normalized == "pdf" {
            return .pdf
        }
        if officeExtensions.contains(normalized) {
            return .office
        }
        if supportedTextExtensions.contains(normalized) {
            return .text
        }
        return .file
    }

    nonisolated static func fromImage(
        _ image: NSImage,
        fileName: String = "image.png",
        progress: ProgressHandler? = nil
    ) throws -> ComposerAttachment {
        guard let imageData = image.tiffRepresentation else {
            throw AttachmentError.failedToReadImage
        }
        return try fromImageData(imageData, fileName: fileName, progress: progress)
    }

    nonisolated static func fromImageData(
        _ imageData: Data,
        fileName: String = "image.png",
        progress: ProgressHandler? = nil
    ) throws -> ComposerAttachment {
        reportProgress(progress, kind: .image, key: "attachment.progress.image.reading")
        guard let image = NSImage(data: imageData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw AttachmentError.failedToReadImage
        }

        reportProgress(progress, kind: .image, key: "attachment.progress.image.normalizing")
        let base64 = pngData.base64EncodedString()
        let dataURL = "data:image/png;base64,\(base64)"
        reportProgress(progress, kind: .image, key: "attachment.progress.image.preparing")
        let context = """
        [上传图片]
        文件名: \(fileName)
        MIME: image/png
        说明: 用户上传了一张图片，请结合用户的问题直接分析图片内容。
        [/上传图片]
        """

        return ComposerAttachment(
            kind: .image,
            fileName: fileName,
            detail: "图片",
            previewImage: image,
            userVisibleLabel: "[已上传图片：\(fileName)]",
            modelContext: context,
            imageDataURL: dataURL,
            attachmentID: nil,
            structureSummary: nil,
            structureItems: []
        )
    }

    nonisolated static func fromFile(
        url: URL,
        progress: ProgressHandler? = nil
    ) throws -> ComposerAttachment {
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            reportProgress(progress, kind: .image, key: "attachment.progress.file.loading")
            return try fromImageData(Data(contentsOf: url), fileName: fileName, progress: progress)
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        let sizeString = ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)

        if fileSize > maxUploadFileSizeBytes {
            throw AttachmentError.fileTooLarge(
                fileName: fileName,
                actualSize: sizeString,
                maxSize: ByteCountFormatter.string(fromByteCount: Int64(maxUploadFileSizeBytes), countStyle: .file)
            )
        }

        if ext == "pdf" {
            reportProgress(progress, kind: .pdf, key: "attachment.progress.pdf.opening")
            guard let pdf = PDFDocument(url: url) else {
                throw AttachmentError.failedToReadPDF
            }
            if pdf.isEncrypted {
                throw AttachmentError.encryptedPDF
            }
            var pages: [String] = []
            var usedOCR = false
            var attemptedOCR = false
            for pageIndex in 0..<pdf.pageCount {
                if shouldReportStepProgress(current: pageIndex + 1, total: pdf.pageCount) {
                    reportProgress(
                        progress,
                        kind: .pdf,
                        key: "attachment.progress.pdf.page",
                        arguments: ["\(pageIndex + 1)", "\(pdf.pageCount)"]
                    )
                }
                if let text = pdf.page(at: pageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    pages.append(text)
                } else if pageIndex < maxPDFOCRPages,
                          let page = pdf.page(at: pageIndex),
                          !page.bounds(for: .mediaBox).isEmpty {
                    attemptedOCR = true
                    reportProgress(
                        progress,
                        kind: .pdf,
                        key: "attachment.progress.pdf.ocr",
                        arguments: ["\(pageIndex + 1)", "\(min(pdf.pageCount, maxPDFOCRPages))"]
                    )
                    if let ocrText = recognizeText(in: page),
                       !ocrText.isEmpty {
                        pages.append("第\(pageIndex + 1)页（OCR）\n\(ocrText)")
                        usedOCR = true
                    }
                }
            }
            let extracted = pages.joined(separator: "\n\n")
            guard !extracted.isEmpty else {
                throw AttachmentError.pdfHasNoReadableContent(ocrAttempted: attemptedOCR)
            }
            let detail = usedOCR ? "PDF(OCR) · \(sizeString)" : "PDF · \(sizeString)"
            reportProgress(progress, kind: .pdf, key: "attachment.progress.pdf.organizing")
            let document = try storeChunkedDocument(
                fileName: fileName,
                typeName: usedOCR ? "PDF(OCR)" : "PDF",
                detail: detail,
                content: extracted,
                segments: pages.enumerated().map { index, pageText in
                    UploadedAttachmentSegment(
                        index: index + 1,
                        kind: .page,
                        title: "第\(index + 1)页",
                        content: pageText
                    )
                }
            )
            reportProgress(progress, kind: .pdf, key: "attachment.progress.common.storing")
            let context = """
            [上传文件]
            文件名: \(fileName)
            类型: \(usedOCR ? "PDF(OCR)" : "PDF")
            路径: \(url.path)
            附件ID: \(document.id)
            分块数: \(document.chunks.count)
            页数: \(pages.count)
            说明: 这是用户上传的 PDF\(usedOCR ? "（包含 OCR 识别结果）" : "")。如果当前预览不够，请使用 read_uploaded_attachment 按块读取，或直接按 page_number 或 page_start/page_end 读取指定页。
            当前预览:
            ```text
            \(document.chunks.first.map { String($0.content.prefix(previewChunkLength)) } ?? "")
            ```
            [/上传文件]
            """
            return ComposerAttachment(
                kind: .document,
                fileName: fileName,
                detail: detail,
                previewImage: nil,
                userVisibleLabel: "[已上传文件：\(fileName) · \(usedOCR ? "PDF(OCR)" : "PDF")]",
                modelContext: context,
                imageDataURL: nil,
                attachmentID: document.id,
                structureSummary: "共 \(pages.count) 页",
                structureItems: pages.enumerated().map { "第\($0.offset + 1)页" }
            )
        }

        if officeExtensions.contains(ext) {
            let extracted: (typeName: String, content: String, segments: [UploadedAttachmentSegment])
            do {
                extracted = try extractOfficeDocument(at: url, ext: ext, progress: progress)
            } catch AttachmentError.failedToReadArchiveEntry {
                throw AttachmentError.failedToReadOfficeDocument(
                    typeDisplayName(for: ext),
                    reason: "文件结构已损坏，或这不是一个有效的\(typeDisplayName(for: ext))文件。"
                )
            } catch AttachmentError.failedToRunExtractor {
                throw AttachmentError.failedToReadOfficeDocument(
                    typeDisplayName(for: ext),
                    reason: "本地提取器运行失败，请稍后重试。"
                )
            } catch let error as AttachmentError {
                throw error
            }
            let detail = "\(extracted.typeName) · \(sizeString)"
            reportProgress(progress, kind: .office, key: "attachment.progress.office.organizing")
            let document = try storeChunkedDocument(
                fileName: fileName,
                typeName: extracted.typeName,
                detail: detail,
                content: extracted.content,
                segments: extracted.segments
            )
            reportProgress(progress, kind: .office, key: "attachment.progress.common.storing")
            let selectorHint: String
            switch ext {
            case "xlsx":
                selectorHint = "或直接按 sheet_index 或 sheet_name 读取指定工作表"
            case "pptx":
                selectorHint = "或直接按 page_number、page_start/page_end，或按 segment_title 读取带标题的页面"
            default:
                selectorHint = "或直接按 segment_index 或 segment_title 读取指定片段"
            }
            let context = """
            [上传文件]
            文件名: \(fileName)
            类型: \(extracted.typeName)
            路径: \(url.path)
            附件ID: \(document.id)
            分块数: \(document.chunks.count)
            结构片段数: \(document.segments.count)
            说明: 以下是从 Office 文件中提取的文本/表格内容。如需查看更多内容，请使用 read_uploaded_attachment 按块读取，\(selectorHint)。
            当前预览:
            ```text
            \(document.chunks.first.map { String($0.content.prefix(previewChunkLength)) } ?? "")
            ```
            [/上传文件]
            """
            return ComposerAttachment(
                kind: .document,
                fileName: fileName,
                detail: detail,
                previewImage: nil,
                userVisibleLabel: "[已上传文件：\(fileName) · \(extracted.typeName)]",
                modelContext: context,
                imageDataURL: nil,
                attachmentID: document.id,
                structureSummary: structureSummary(for: ext, segments: extracted.segments),
                structureItems: extracted.segments.map(\.title)
            )
        }

        guard supportedTextExtensions.contains(ext) else {
            throw AttachmentError.unsupportedFileType(ext.isEmpty ? fileName : ext)
        }

        reportProgress(progress, kind: .text, key: "attachment.progress.file.loading")
        let data = try Data(contentsOf: url)
        reportProgress(progress, kind: .text, key: "attachment.progress.text.decoding")
        let rawText = decodeText(data)
        let language = codeFenceLanguage(for: ext)
        let typeName = typeDisplayName(for: ext)
        let detail = "\(typeName) · \(sizeString)"
        reportProgress(progress, kind: .text, key: "attachment.progress.text.segmenting")
        let document = try storeChunkedDocument(
            fileName: fileName,
            typeName: typeName,
            detail: detail,
            content: rawText,
            segments: makeSemanticSegments(from: rawText)
        )
        reportProgress(progress, kind: .text, key: "attachment.progress.common.storing")
        let context = """
        [上传文件]
        文件名: \(fileName)
        类型: \(typeName)
        路径: \(url.path)
        附件ID: \(document.id)
        分块数: \(document.chunks.count)
        片段数: \(document.segments.count)
        说明: 这是用户上传的\(typeName)文件。如果当前预览不够，请使用 read_uploaded_attachment 按块读取内容，或按 segment_index / segment_title 读取指定片段。
        当前预览:
        ```\(language)
        \(document.chunks.first.map { String($0.content.prefix(previewChunkLength)) } ?? "")
        ```
        [/上传文件]
        """

        return ComposerAttachment(
            kind: .document,
            fileName: fileName,
            detail: detail,
            previewImage: nil,
            userVisibleLabel: "[已上传文件：\(fileName) · \(typeName)]",
            modelContext: context,
            imageDataURL: nil,
            attachmentID: document.id,
            structureSummary: "共 \(document.segments.count) 个片段",
            structureItems: document.segments.map(\.title)
        )
    }

    nonisolated private static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .unicode) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func clippedContent(_ content: String) -> (content: String, notice: String) {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxDocumentCharacters else {
            return (normalized, "")
        }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: maxDocumentCharacters)
        let clipped = String(normalized[..<endIndex])
        return (clipped, "注意：原文件内容较长，这里只附加了前 \(maxDocumentCharacters) 个字符。")
    }

    nonisolated private static func storeChunkedDocument(
        fileName: String,
        typeName: String,
        detail: String,
        content: String,
        segments: [UploadedAttachmentSegment] = []
    ) throws -> UploadedAttachmentDocument {
        let chunks = makeChunks(from: content)
        return try UploadedAttachmentStore.shared.saveDocument(
            fileName: fileName,
            typeName: typeName,
            detail: detail,
            chunks: chunks,
            segments: segments
        )
    }

    nonisolated private static func makeChunks(from content: String) -> [UploadedAttachmentChunk] {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return [UploadedAttachmentChunk(index: 1, title: "第1块", content: "")]
        }

        var chunks: [UploadedAttachmentChunk] = []
        var start = normalized.startIndex
        var chunkIndex = 1

        while start < normalized.endIndex {
            let tentativeEnd = normalized.index(start, offsetBy: chunkSize, limitedBy: normalized.endIndex) ?? normalized.endIndex
            var end = tentativeEnd

            if tentativeEnd < normalized.endIndex,
               let lineBreak = normalized[..<tentativeEnd].lastIndex(of: "\n"),
               lineBreak > start {
                end = lineBreak
            }

            let piece = normalized[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(
                    UploadedAttachmentChunk(
                        index: chunkIndex,
                        title: "第\(chunkIndex)块",
                        content: String(piece)
                    )
                )
                chunkIndex += 1
            }

            start = end == tentativeEnd ? tentativeEnd : normalized.index(after: end)
        }

        return chunks.isEmpty ? [UploadedAttachmentChunk(index: 1, title: "第1块", content: normalized)] : chunks
    }

    nonisolated private static func makeSemanticSegments(from content: String) -> [UploadedAttachmentSegment] {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return [UploadedAttachmentSegment(index: 1, kind: .segment, title: "第1段", content: "")]
        }

        let lines = normalized.components(separatedBy: .newlines)
        var sections: [(title: String, content: String)] = []
        var currentLines: [String] = []
        var currentTitle: String?

        func flushCurrentSection() {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let title = currentTitle ?? semanticTitle(from: body, fallback: "第\(sections.count + 1)段")
            sections.append((title, body))
            currentLines = []
            currentTitle = nil
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                if !currentLines.isEmpty {
                    currentLines.append("")
                }
                continue
            }

            if isSemanticHeading(line) {
                flushCurrentSection()
                currentTitle = cleanedHeadingTitle(from: line)
                currentLines = [line]
            } else {
                currentLines.append(rawLine)
            }
        }

        flushCurrentSection()

        if sections.count <= 1 {
            return makeChunks(from: normalized).map { chunk in
                UploadedAttachmentSegment(
                    index: chunk.index,
                    kind: .segment,
                    title: semanticTitle(from: chunk.content, fallback: chunk.title),
                    content: chunk.content
                )
            }
        }

        return sections.enumerated().map { index, section in
            UploadedAttachmentSegment(index: index + 1, kind: .segment, title: section.title, content: section.content)
        }
    }

    nonisolated private static func isSemanticHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("#") { return true }
        if trimmed.hasPrefix("##") { return true }
        if trimmed.hasPrefix("###") { return true }
        if trimmed.range(of: #"^第[一二三四五六七八九十百千万0-9]+[章节部分篇节卷]([：:\s].*)?$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^[0-9]+(\.[0-9]+)*[\.、]\s*.+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    nonisolated private static func cleanedHeadingTitle(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let stripped = trimmed.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            return semanticTitle(from: stripped, fallback: "未命名片段")
        }
        return semanticTitle(from: trimmed, fallback: "未命名片段")
    }

    nonisolated private static func semanticTitle(from content: String, fallback: String) -> String {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return fallback }
        let title = first.count > 40 ? String(first.prefix(40)) + "…" : first
        return title.isEmpty ? fallback : title
    }

    nonisolated private static func codeFenceLanguage(for ext: String) -> String {
        switch ext {
        case "md", "markdown": return "markdown"
        case "csv": return "csv"
        case "json": return "json"
        case "xml": return "xml"
        case "yaml", "yml": return "yaml"
        case "html": return "html"
        case "css": return "css"
        case "js": return "javascript"
        case "jsx": return "jsx"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "py": return "python"
        case "swift": return "swift"
        case "java": return "java"
        case "c": return "c"
        case "cc", "cpp": return "cpp"
        case "h", "hpp": return "cpp"
        case "go": return "go"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        case "kt": return "kotlin"
        case "php": return "php"
        case "vue": return "vue"
        default: return "text"
        }
    }

    nonisolated private static func typeDisplayName(for ext: String) -> String {
        switch ext {
        case "txt": return "文本"
        case "md", "markdown": return "Markdown"
        case "csv": return "CSV"
        case "json": return "JSON"
        case "xml": return "XML"
        case "yaml", "yml": return "YAML"
        case "html": return "HTML"
        case "css": return "CSS"
        case "js", "jsx", "ts", "tsx", "py", "swift", "java", "c", "cc", "cpp", "h", "hpp", "go", "rs", "rb", "sh", "bash", "zsh", "sql", "kt", "php", "vue":
            return "代码"
        case "docx": return "Word"
        case "xlsx": return "Excel"
        case "pptx": return "PowerPoint"
        default: return ext.uppercased()
        }
    }

    nonisolated private static func structureSummary(for ext: String, segments: [UploadedAttachmentSegment]) -> String? {
        guard !segments.isEmpty else { return nil }
        switch ext {
        case "xlsx":
            return "共 \(segments.count) 个工作表"
        case "pptx":
            return "共 \(segments.count) 页"
        case "docx":
            return "共 \(segments.count) 个章节"
        default:
            return "共 \(segments.count) 个片段"
        }
    }

    nonisolated private static func extractOfficeDocument(
        at url: URL,
        ext: String,
        progress: ProgressHandler? = nil
    ) throws -> (typeName: String, content: String, segments: [UploadedAttachmentSegment]) {
        reportProgress(progress, kind: .office, key: "attachment.progress.office.opening")
        switch ext {
        case "docx":
            reportProgress(progress, kind: .office, key: "attachment.progress.office.word")
            let xml = try unzipEntry("word/document.xml", from: url)
            let text = XMLTextExtractor.extractPlainText(from: xml)
            guard !text.isEmpty else { throw AttachmentError.failedToReadOfficeDocument(typeDisplayName(for: ext), reason: nil) }
            let segments = makeSemanticSegments(from: text)
            return (typeDisplayName(for: ext), text, segments)

        case "pptx":
            let entries = try listZipEntries(in: url)
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let slides = try entries.enumerated().compactMap { index, entry -> UploadedAttachmentSegment? in
                if shouldReportStepProgress(current: index + 1, total: entries.count) {
                    reportProgress(
                        progress,
                        kind: .office,
                        key: "attachment.progress.office.pptx.slide",
                        arguments: ["\(index + 1)", "\(entries.count)"]
                    )
                }
                let xml = try unzipEntry(entry, from: url)
                let text = XMLTextExtractor.extractPlainText(from: xml)
                guard !text.isEmpty else { return nil }
                let pageTitle = semanticTitle(from: text, fallback: "第\(index + 1)页")
                return UploadedAttachmentSegment(
                    index: index + 1,
                    kind: .page,
                    title: pageTitle,
                    content: text
                )
            }
            let joined = slides.map { "\($0.title)\n\($0.content)" }.joined(separator: "\n\n")
            guard !joined.isEmpty else { throw AttachmentError.failedToReadOfficeDocument(typeDisplayName(for: ext), reason: nil) }
            return (typeDisplayName(for: ext), joined, slides)

        case "xlsx":
            let workbookSheets = (try? unzipEntry("xl/workbook.xml", from: url)).map(WorkbookSheetsExtractor.extract) ?? []
            let workbookRelationships = (try? unzipEntry("xl/_rels/workbook.xml.rels", from: url)).map(WorkbookRelationshipsExtractor.extract) ?? [:]
            let sharedStringsData = try? unzipEntry("xl/sharedStrings.xml", from: url)
            let sharedStrings = sharedStringsData.map(SharedStringsExtractor.extract) ?? []
            let archiveEntries = try listZipEntries(in: url)
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
            let sheets = try orderedSheetEntries.enumerated().compactMap { index, item -> UploadedAttachmentSegment? in
                if shouldReportStepProgress(current: index + 1, total: orderedSheetEntries.count) {
                    reportProgress(
                        progress,
                        kind: .office,
                        key: "attachment.progress.office.xlsx.sheet",
                        arguments: ["\(index + 1)", "\(orderedSheetEntries.count)"]
                    )
                }
                let xml = try unzipEntry(item.entry, from: url)
                let rows = WorksheetExtractor.extractRows(from: xml, sharedStrings: sharedStrings)
                guard !rows.isEmpty else { return nil }
                return UploadedAttachmentSegment(
                    index: index + 1,
                    kind: .sheet,
                    title: item.title,
                    content: rows.joined(separator: "\n")
                )
            }
            let joined = sheets.map { "\($0.title)\n\($0.content)" }.joined(separator: "\n\n")
            guard !joined.isEmpty else { throw AttachmentError.failedToReadOfficeDocument(typeDisplayName(for: ext), reason: nil) }
            return (typeDisplayName(for: ext), joined, sheets)

        default:
            throw AttachmentError.unsupportedFileType(ext)
        }
    }

    nonisolated private static func listZipEntries(in url: URL) throws -> [String] {
        let output = try runProcess(launchPath: "/usr/bin/unzip", arguments: ["-Z1", url.path])
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func unzipEntry(_ entry: String, from url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AttachmentError.failedToReadArchiveEntry(entry, errorText)
        }
        return data
    }

    nonisolated private static func runProcess(launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            throw AttachmentError.failedToRunExtractor(errorText)
        }

        return decodeText(outputData)
    }

    nonisolated private static func normalizeWorkbookTarget(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("xl/") {
            return trimmed
        }
        if trimmed.hasPrefix("/xl/") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("worksheets/") {
            return "xl/\(trimmed)"
        }
        if trimmed.hasPrefix("../") {
            return "xl/" + trimmed.replacingOccurrences(of: "../", with: "")
        }
        return "xl/\(trimmed)"
    }

    nonisolated private static func recognizeText(in page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let targetWidth: CGFloat = 1800
        let scale = max(targetWidth / max(bounds.width, 1), 1)
        let imageSize = NSSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        let image = page.thumbnail(of: imageSize, for: .mediaBox)

        guard let cgImage = cgImage(from: image) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return text.isEmpty ? nil : text
    }

    nonisolated private static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.cgImage
    }

    nonisolated private static func reportProgress(
        _ progress: ProgressHandler?,
        kind: ComposerAttachmentStatus.Kind,
        key: String,
        arguments: [String] = []
    ) {
        progress?(ComposerAttachmentParsingProgress(kind: kind, messageKey: key, arguments: arguments))
    }

    nonisolated private static func shouldReportStepProgress(current: Int, total: Int) -> Bool {
        guard total > 0 else { return false }
        if total <= 8 {
            return true
        }
        if current == 1 || current == total {
            return true
        }
        let step = max(2, total / 5)
        return current % step == 0
    }
}

struct ComposerAttachmentParsingProgress: Sendable, Equatable {
    let kind: ComposerAttachmentStatus.Kind
    let messageKey: String
    let arguments: [String]

    nonisolated init(kind: ComposerAttachmentStatus.Kind, messageKey: String, arguments: [String] = []) {
        self.kind = kind
        self.messageKey = messageKey
        self.arguments = arguments
    }
}

struct ComposerAttachmentStatus: Identifiable, Equatable {
    enum Phase: Equatable {
        case parsing
        case ready
        case failed
    }

    enum Kind: Equatable {
        case image
        case pdf
        case office
        case text
        case file
    }

    let id = UUID()
    let phase: Phase
    let kind: Kind
    let fileName: String
    let message: String
    let startedAt: Date

    init(
        phase: Phase,
        kind: Kind,
        fileName: String,
        message: String,
        startedAt: Date = Date()
    ) {
        self.phase = phase
        self.kind = kind
        self.fileName = fileName
        self.message = message
        self.startedAt = startedAt
    }
}

enum AttachmentError: LocalizedError {
    case failedToReadImage
    case failedToReadPDF
    case encryptedPDF
    case pdfHasNoReadableContent(ocrAttempted: Bool)
    case failedToReadOfficeDocument(String, reason: String?)
    case failedToReadArchiveEntry(String, String)
    case failedToRunExtractor(String)
    case fileTooLarge(fileName: String, actualSize: String, maxSize: String)
    case unsupportedFileType(String)

    var errorDescription: String? {
        switch self {
        case .failedToReadImage:
            return "无法读取这张图片。"
        case .failedToReadPDF:
            return "无法读取这个 PDF 文件。"
        case .encryptedPDF:
            return "这个 PDF 已加密，暂时无法直接读取。请先解除密码保护后再上传。"
        case .pdfHasNoReadableContent(let ocrAttempted):
            return ocrAttempted
                ? "这个 PDF 没有可提取文本，OCR 也没有识别出有效内容。请检查文件是否为空白、清晰度是否足够，或尝试更清晰的扫描件。"
                : "这个 PDF 没有可提取文本内容。它可能是扫描件、图片页，或文件本身为空白。"
        case .failedToReadOfficeDocument(let type, let reason):
            return reason ?? "无法从这个 \(type) 文件中提取可读内容。"
        case .failedToReadArchiveEntry(let entry, let message):
            return "读取压缩文件内部内容失败：\(entry)\(message.isEmpty ? "" : " (\(message))")"
        case .failedToRunExtractor(let message):
            return "运行本地文件提取器失败。\(message)"
        case .fileTooLarge(let fileName, let actualSize, let maxSize):
            return "文件 \(fileName) 过大（当前 \(actualSize)）。当前版本最多支持上传 \(maxSize) 的单个文件。"
        case .unsupportedFileType(let type):
            return "暂时不支持上传这种文件类型：\(type)。当前支持图片、PDF、Word、Excel、PowerPoint、文本、Markdown、CSV 和常见代码文件。"
        }
    }
}

private final class XMLTextExtractor: NSObject, XMLParserDelegate {
    nonisolated(unsafe) private var currentText = ""
    nonisolated(unsafe) private var blocks: [String] = []

    nonisolated override init() {
        super.init()
    }

    nonisolated static func extractPlainText(from data: Data) -> String {
        let extractor = XMLTextExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = qName ?? elementName
        if element.hasSuffix(":t") || element == "t" || element.hasSuffix(":v") || element == "v" {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(text)
            }
        } else if element.hasSuffix(":p") || element == "p" || element.hasSuffix(":tr") || element == "tr" {
            blocks.append("\n")
        }
        currentText = ""
    }
}

private final class SharedStringsExtractor: NSObject, XMLParserDelegate {
    nonisolated(unsafe) private var currentText = ""
    nonisolated(unsafe) private var currentItem = ""
    nonisolated(unsafe) private var strings: [String] = []

    nonisolated override init() {
        super.init()
    }

    nonisolated static func extract(from data: Data) -> [String] {
        let extractor = SharedStringsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.strings
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
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

private final class WorksheetExtractor: NSObject, XMLParserDelegate {
    nonisolated private let sharedStrings: [String]
    nonisolated(unsafe) private var rows: [String] = []
    nonisolated(unsafe) private var currentRow: [String] = []
    nonisolated(unsafe) private var currentCellType: String?
    nonisolated(unsafe) private var currentValue = ""
    nonisolated(unsafe) private var collectingValue = false

    nonisolated init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    nonisolated static func extractRows(from data: Data, sharedStrings: [String]) -> [String] {
        let extractor = WorksheetExtractor(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.rows
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
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

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingValue {
            currentValue += string
        }
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = qName ?? elementName
        if element.hasSuffix(":v") || element == "v" || element.hasSuffix(":t") || element == "t" {
            collectingValue = false
        } else if element.hasSuffix(":c") || element == "c" {
            let value = resolvedCellValue()
            if !value.isEmpty {
                currentRow.append(value)
            }
            currentValue = ""
            currentCellType = nil
        } else if element.hasSuffix(":row") || element == "row" {
            let line = currentRow
                .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            if !line.isEmpty {
                rows.append(line)
            }
            currentRow = []
        }
    }

    nonisolated private func resolvedCellValue() -> String {
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if currentCellType == "s", let index = Int(trimmed), sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }
        return trimmed
    }
}

private struct WorkbookSheetMetadata {
    let name: String
    let relationshipID: String
}

private final class WorkbookSheetsExtractor: NSObject, XMLParserDelegate {
    nonisolated(unsafe) private var sheets: [WorkbookSheetMetadata] = []

    nonisolated override init() {
        super.init()
    }

    nonisolated static func extract(from data: Data) -> [WorkbookSheetMetadata] {
        let extractor = WorkbookSheetsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.sheets
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let element = qName ?? elementName
        guard element.hasSuffix(":sheet") || element == "sheet" else { return }
        guard let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] else { return }
        sheets.append(WorkbookSheetMetadata(name: name, relationshipID: relationshipID))
    }
}

private final class WorkbookRelationshipsExtractor: NSObject, XMLParserDelegate {
    nonisolated(unsafe) private var relationships: [String: String] = [:]

    nonisolated override init() {
        super.init()
    }

    nonisolated static func extract(from data: Data) -> [String: String] {
        let extractor = WorkbookRelationshipsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.relationships
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let element = qName ?? elementName
        guard element.hasSuffix(":Relationship") || element == "Relationship" else { return }
        guard let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        relationships[id] = target
    }
}

import Foundation
import PDFKit

enum FileValidationSeverity: String {
    case success
    case warning
    case error
}

struct FileValidationMessage: Equatable {
    let severity: FileValidationSeverity
    let text: String
}

struct FileValidationReport: Equatable {
    var messages: [FileValidationMessage]

    var isEmpty: Bool { messages.isEmpty }
    var hasErrors: Bool { messages.contains { $0.severity == .error } }
    var hasWarnings: Bool { messages.contains { $0.severity == .warning } }
    var needsRepair: Bool { hasErrors || hasWarnings }

    var repairStatusLabel: String {
        if hasErrors { return "需要修复（存在错误）" }
        if hasWarnings { return "建议修复（存在警告）" }
        return "无需修复"
    }

    func renderedLines() -> [String] {
        messages.map { message in
            let prefix: String
            switch message.severity {
            case .success:
                prefix = "✓"
            case .warning:
                prefix = "!"
            case .error:
                prefix = "×"
            }
            return "\(prefix) \(message.text)"
        }
    }

    func repairAdvice(candidatePaths: [String]) -> [String] {
        guard needsRepair else { return [] }

        var advice: [String] = []
        let candidateNames = candidatePaths.map { ($0 as NSString).lastPathComponent }
        let mentionedNames = candidateNames.filter { name in
            messages.contains { $0.text.localizedCaseInsensitiveContains(name) }
        }

        if !mentionedNames.isEmpty {
            advice.append("只修改这些被点名的文件：\(mentionedNames.joined(separator: "、"))")
        } else if !candidateNames.isEmpty {
            advice.append("优先只修改本轮写入的相关文件，不要重写无问题文件")
        }

        if hasErrors {
            advice.append("先修复错误项，再处理警告项")
        }

        if messages.contains(where: { $0.text.contains("尚未引用") || $0.text.contains("未被任何生成的 HTML 引用") }) {
            advice.append("先补齐 HTML 对 CSS/JS 的引用关系，再检查样式和交互是否生效")
        }

        if messages.contains(where: { $0.text.contains("选择器") || $0.text.contains("DOM") }) {
            advice.append("只调整被点名文件中的选择器或 DOM 对应关系，不要整页重写")
        }

        if messages.contains(where: { $0.text.contains("JSON") || $0.text.contains("XML") || $0.text.contains("HTML 结构") }) {
            advice.append("修复结构问题后再继续后续修改，避免基于非法文件继续追加内容")
        }

        return Array(NSOrderedSet(array: advice)) as? [String] ?? advice
    }
}

final class FileValidationService {
    static let shared = FileValidationService()

    func validateWrittenFiles(_ files: [(path: String, content: String)]) -> FileValidationReport {
        var messages: [FileValidationMessage] = []

        messages.append(contentsOf: validateWebProject(files))

        for file in files {
            messages.append(contentsOf: validateStructuredText(path: file.path, content: file.content))
        }

        return FileValidationReport(messages: deduplicated(messages))
    }

    func validateGeneratedFile(at path: String) -> FileValidationReport {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let messages: [FileValidationMessage]

        switch ext {
        case "docx":
            messages = validateDOCX(at: path)
        case "xlsx":
            messages = validateXLSX(at: path)
        case "pdf":
            messages = validatePDF(at: path)
        default:
            messages = []
        }

        return FileValidationReport(messages: deduplicated(messages))
    }

    private func validateWebProject(_ files: [(path: String, content: String)]) -> [FileValidationMessage] {
        let htmlFiles = files.filter { ["html", "htm"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
        let cssFiles = files.filter { URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "css" }
        let jsFiles = files.filter { ["js", "mjs"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }

        guard !htmlFiles.isEmpty, (!cssFiles.isEmpty || !jsFiles.isEmpty) else { return [] }

        var messages: [FileValidationMessage] = []
        let cssByName = Dictionary(uniqueKeysWithValues: cssFiles.map { (($0.path as NSString).lastPathComponent, $0) })
        let jsByName = Dictionary(uniqueKeysWithValues: jsFiles.map { (($0.path as NSString).lastPathComponent, $0) })
        var referencedCSS: Set<String> = []
        var referencedJS: Set<String> = []

        for html in htmlFiles {
            let htmlName = (html.path as NSString).lastPathComponent
            let linkedStyles = referencedAssetNames(in: html.content, pattern: #"<link[^>]+href=["']([^"']+)["']"#)
            let linkedScripts = referencedAssetNames(in: html.content, pattern: #"<script[^>]+src=["']([^"']+)["']"#)
            let htmlClasses = htmlAttributeValues(in: html.content, attribute: "class")
            let htmlIDs = htmlAttributeValues(in: html.content, attribute: "id")

            let matchedStyles = linkedStyles.filter { cssByName[$0] != nil }
            let matchedScripts = linkedScripts.filter { jsByName[$0] != nil }
            referencedCSS.formUnion(matchedStyles)
            referencedJS.formUnion(matchedScripts)

            if !cssFiles.isEmpty && matchedStyles.isEmpty {
                if cssFiles.count == 1, let cssName = cssByName.keys.first {
                    messages.append(.init(severity: .warning, text: "\(htmlName) 尚未引用 \(cssName)"))
                } else {
                    messages.append(.init(severity: .warning, text: "\(htmlName) 尚未引用本轮生成的 CSS 文件"))
                }
            }

            for cssName in matchedStyles {
                guard let css = cssByName[cssName] else { continue }
                let cssClasses = selectorMatches(in: css.content, pattern: #"(?<![A-Za-z0-9_-])\.([A-Za-z_][A-Za-z0-9_-]*)"#)
                let cssIDs = selectorMatches(in: css.content, pattern: #"(?<![A-Za-z0-9_-])#([A-Za-z_][A-Za-z0-9_-]*)"#)
                let classOverlap = cssClasses.intersection(htmlClasses)
                let idOverlap = cssIDs.intersection(htmlIDs)
                if (!cssClasses.isEmpty || !cssIDs.isEmpty) && classOverlap.isEmpty && idOverlap.isEmpty {
                    messages.append(.init(severity: .warning, text: "\(cssName) 中的类名/ID 选择器和 \(htmlName) 没有明显对应，样式可能不会生效"))
                }
            }

            if !jsFiles.isEmpty && matchedScripts.isEmpty {
                if jsFiles.count == 1, let jsName = jsByName.keys.first {
                    messages.append(.init(severity: .warning, text: "\(htmlName) 尚未引用 \(jsName)"))
                } else {
                    messages.append(.init(severity: .warning, text: "\(htmlName) 尚未引用本轮生成的 JS 文件"))
                }
            }

            for jsName in matchedScripts {
                guard let js = jsByName[jsName] else { continue }
                let jsIDs = selectorMatches(in: js.content, pattern: #"getElementById\(\s*["']([A-Za-z_][A-Za-z0-9_-]*)["']\s*\)"#)
                    .union(selectorMatches(in: js.content, pattern: #"querySelector(?:All)?\(\s*["']#([A-Za-z_][A-Za-z0-9_-]*)["']\s*\)"#))
                let jsClasses = selectorMatches(in: js.content, pattern: #"querySelector(?:All)?\(\s*["']\.([A-Za-z_][A-Za-z0-9_-]*)["']\s*\)"#)
                let classOverlap = jsClasses.intersection(htmlClasses)
                let idOverlap = jsIDs.intersection(htmlIDs)
                if (!jsClasses.isEmpty || !jsIDs.isEmpty) && classOverlap.isEmpty && idOverlap.isEmpty {
                    messages.append(.init(severity: .warning, text: "\(jsName) 查询的 DOM 选择器在 \(htmlName) 里没有明显对应，交互可能不会生效"))
                }
            }
        }

        for css in cssFiles {
            let cssName = (css.path as NSString).lastPathComponent
            if !referencedCSS.contains(cssName) {
                messages.append(.init(severity: .warning, text: "\(cssName) 未被任何生成的 HTML 引用"))
            }
        }

        for js in jsFiles {
            let jsName = (js.path as NSString).lastPathComponent
            if !referencedJS.contains(jsName) {
                messages.append(.init(severity: .warning, text: "\(jsName) 未被任何生成的 HTML 引用"))
            }
        }

        if messages.isEmpty {
            messages.append(.init(severity: .success, text: "HTML、CSS、JS 的基础引用关系看起来正常"))
        }

        return messages
    }

    private func validateStructuredText(path: String, content: String) -> [FileValidationMessage] {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [.init(severity: .warning, text: "\((path as NSString).lastPathComponent) 内容为空")]
        }

        switch ext {
        case "json":
            guard let data = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return [.init(severity: .error, text: "\((path as NSString).lastPathComponent) 不是合法 JSON")]
            }
            return [.init(severity: .success, text: "\((path as NSString).lastPathComponent) JSON 语法正常")]
        case "xml":
            guard let data = trimmed.data(using: .utf8) else { return [] }
            let parser = XMLParser(data: data)
            if parser.parse() {
                return [.init(severity: .success, text: "\((path as NSString).lastPathComponent) XML 结构正常")]
            }
            return [.init(severity: .error, text: "\((path as NSString).lastPathComponent) 不是合法 XML")]
        case "html", "htm":
            let fileName = (path as NSString).lastPathComponent
            let hasAnyTag = trimmed.range(of: #"<[A-Za-z!/]"#, options: .regularExpression) != nil
            guard hasAnyTag else {
                return [.init(severity: .error, text: "\(fileName) 没有检测到有效 HTML 标签")]
            }

            if trimmed.localizedCaseInsensitiveContains("<html") || trimmed.localizedCaseInsensitiveContains("<body") {
                return [.init(severity: .success, text: "\(fileName) 基础 HTML 结构存在")]
            }

            return [.init(severity: .success, text: "\(fileName) HTML 片段结构存在")]
        default:
            return []
        }
    }

    private func validateDOCX(at path: String) -> [FileValidationMessage] {
        do {
            let xml = try unzipEntry("word/document.xml", from: URL(fileURLWithPath: path))
            let text = XMLTextExtractor.extractPlainText(from: xml).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return [.init(severity: .error, text: "\((path as NSString).lastPathComponent) 可以打开，但没有可读正文")]
            }
            return [.init(severity: .success, text: "\((path as NSString).lastPathComponent) Word 正文可重新解析")]
        } catch {
            return [.init(severity: .error, text: "\((path as NSString).lastPathComponent) Word 结构校验失败：\(error.localizedDescription)")]
        }
    }

    private func validateXLSX(at path: String) -> [FileValidationMessage] {
        do {
            let url = URL(fileURLWithPath: path)
            let archiveEntries = try listZipEntries(in: url)
            let workbookSheets = WorkbookSheetsExtractor.extract(from: try unzipEntry("xl/workbook.xml", from: url))
            let workbookRelationships = try WorkbookRelationshipsExtractor.extract(from: unzipEntry("xl/_rels/workbook.xml.rels", from: url))
            let sharedStrings = (try? SharedStringsExtractor.extract(from: unzipEntry("xl/sharedStrings.xml", from: url))) ?? []
            let sheetEntries = archiveEntries.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            let orderedEntries = workbookSheets.compactMap { sheet -> (String, String)? in
                guard let target = workbookRelationships[sheet.relationshipID] else { return nil }
                let normalized = normalizeWorkbookTarget(target)
                guard archiveEntries.contains(normalized) else { return nil }
                return (sheet.name, normalized)
            }
            let rows = try orderedEntries.compactMap { item -> SpreadsheetSheet? in
                let xml = try unzipEntry(item.1, from: url)
                let extractedRows = WorksheetExtractor.extractRows(from: xml, sharedStrings: sharedStrings)
                guard !extractedRows.isEmpty else { return nil }
                return SpreadsheetSheet(name: item.0, rows: extractedRows)
            }

            if rows.isEmpty && sheetEntries.isEmpty {
                return [.init(severity: .error, text: "\((path as NSString).lastPathComponent) Excel 中没有可读工作表")]
            }
            if rows.isEmpty {
                return [.init(severity: .warning, text: "\((path as NSString).lastPathComponent) Excel 可打开，但工作表没有可读内容")]
            }
            return [.init(severity: .success, text: "\((path as NSString).lastPathComponent) Excel 工作表可重新解析，共 \(rows.count) 个工作表")]
        } catch {
            return [.init(severity: .error, text: "\((path as NSString).lastPathComponent) Excel 结构校验失败：\(error.localizedDescription)")]
        }
    }

    private func validatePDF(at path: String) -> [FileValidationMessage] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return [.init(severity: .error, text: "\((path as NSString).lastPathComponent) PDF 无法打开")]
        }
        guard document.pageCount > 0 else {
            return [.init(severity: .warning, text: "\((path as NSString).lastPathComponent) PDF 可以打开，但没有有效页面")]
        }
        return [.init(severity: .success, text: "\((path as NSString).lastPathComponent) PDF 可打开，共 \(document.pageCount) 页")]
    }

    private func deduplicated(_ messages: [FileValidationMessage]) -> [FileValidationMessage] {
        var seen: Set<String> = []
        return messages.filter { message in
            let key = "\(message.severity.rawValue)|\(message.text)"
            return seen.insert(key).inserted
        }
    }

    private func referencedAssetNames(in text: String, pattern: String) -> Set<String> {
        Set(selectorMatches(in: text, pattern: pattern).map { ($0 as NSString).lastPathComponent })
    }

    private func htmlAttributeValues(in text: String, attribute: String) -> Set<String> {
        let values = selectorMatches(in: text, pattern: #"\#(attribute)=["']([^"']+)["']"#)
        var result: Set<String> = []
        for value in values {
            value.split(whereSeparator: \.isWhitespace).forEach { token in
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.insert(trimmed)
                }
            }
        }
        return result
    }

    private func selectorMatches(in text: String, pattern: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        })
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
            throw NSError(domain: "SkyAgent.Validation", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "读取压缩目录失败" : message])
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            throw NSError(domain: "SkyAgent.Validation", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "读取压缩文件条目失败: \(entry)" : message])
        }
        return data
    }

    private func normalizeWorkbookTarget(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("xl/") { return trimmed }
        if trimmed.hasPrefix("/xl/") { return String(trimmed.dropFirst()) }
        if trimmed.hasPrefix("worksheets/") { return "xl/\(trimmed)" }
        return "xl/\(trimmed)"
    }
}

private struct SpreadsheetSheet: Equatable {
    let name: String
    let rows: [[String]]
}

private final class XMLTextExtractor: NSObject, XMLParserDelegate {
    private var collected: [String] = []
    private var currentText = ""

    static func extractPlainText(from data: Data) -> String {
        let extractor = XMLTextExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.collected.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.hasSuffix(":t") || elementName == "t" || elementName.hasSuffix(":p") || elementName == "p" {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                collected.append(trimmed)
            }
            currentText = ""
        }
    }
}

private final class SharedStringsExtractor: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var currentText = ""

    static func extract(from data: Data) throws -> [String] {
        let extractor = SharedStringsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.strings
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.hasSuffix(":t") || elementName == "t" {
            strings.append(currentText)
            currentText = ""
        }
    }
}

private final class WorksheetExtractor: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentRow: [String] = []
    private var currentValue = ""
    private var currentType: String?
    private var insideValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func extractRows(from data: Data, sharedStrings: [String]) -> [[String]] {
        let extractor = WorksheetExtractor(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName.hasSuffix(":row") || elementName == "row" {
            currentRow = []
        } else if elementName.hasSuffix(":c") || elementName == "c" {
            currentType = attributeDict["t"]
        } else if elementName.hasSuffix(":v") || elementName == "v" || elementName.hasSuffix(":t") || elementName == "t" {
            insideValue = true
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideValue {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.hasSuffix(":v") || elementName == "v" || elementName.hasSuffix(":t") || elementName == "t" {
            insideValue = false
        } else if elementName.hasSuffix(":c") || elementName == "c" {
            if currentType == "s", let index = Int(currentValue), sharedStrings.indices.contains(index) {
                currentRow.append(sharedStrings[index])
            } else {
                currentRow.append(currentValue)
            }
            currentValue = ""
            currentType = nil
        } else if elementName.hasSuffix(":row") || elementName == "row" {
            if !currentRow.isEmpty {
                rows.append(currentRow)
            }
        }
    }
}

private struct WorkbookSheet {
    let name: String
    let relationshipID: String
}

private final class WorkbookSheetsExtractor: NSObject, XMLParserDelegate {
    private var sheets: [WorkbookSheet] = []

    static func extract(from data: Data) -> [WorkbookSheet] {
        let extractor = WorkbookSheetsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName.hasSuffix(":sheet") || elementName == "sheet" else { return }
        guard let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] else { return }
        sheets.append(.init(name: name, relationshipID: relationshipID))
    }
}

private final class WorkbookRelationshipsExtractor: NSObject, XMLParserDelegate {
    private var relationships: [String: String] = [:]

    static func extract(from data: Data) throws -> [String: String] {
        let extractor = WorkbookRelationshipsExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.relationships
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName.hasSuffix(":Relationship") || elementName == "Relationship" else { return }
        guard let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        relationships[id] = target
    }
}

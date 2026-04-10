import SwiftUI
import Foundation

struct MarkdownRenderer {
    private final class CachedBlocksBox: NSObject {
        let blocks: [Block]

        nonisolated init(blocks: [Block]) {
            self.blocks = blocks
        }
    }

    private final class CachedHTMLBox: NSObject {
        let html: String

        nonisolated init(html: String) {
            self.html = html
        }
    }

    nonisolated(unsafe) private static let renderCache = NSCache<NSString, CachedBlocksBox>()
    nonisolated(unsafe) private static let htmlCache = NSCache<NSString, CachedHTMLBox>()

    enum BlockType: Equatable, Sendable {
        case text, codeBlock, separator, heading(Int), quote
    }

    struct Block: Identifiable, Equatable, Sendable {
        let id = UUID()
        let type: BlockType
        let content: String
        let language: String?

        nonisolated init(type: BlockType, content: String, language: String? = nil) {
            self.type = type
            self.content = content
            self.language = language
        }
    }

    nonisolated static func render(_ markdown: String) -> [Block] {
        let cacheKey = markdown as NSString
        if let cached = renderCache.object(forKey: cacheKey) {
            return cached.blocks
        }

        var blocks: [Block] = []
        var currentLines: [String] = []
        var inCodeBlock = false
        var codeLanguage = ""
        var codeLines: [String] = []

        let lines = markdown.components(separatedBy: "\n")

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(Block(type: .codeBlock, content: codeLines.joined(separator: "\n"), language: codeLanguage))
                    codeLines = []
                    codeLanguage = ""
                    inCodeBlock = false
                } else {
                    flushText(&currentLines, into: &blocks)
                    inCodeBlock = true
                    codeLanguage = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if let heading = headingBlock(for: line) {
                flushText(&currentLines, into: &blocks)
                blocks.append(heading)
                continue
            }

            if trimmedLine == "---" || trimmedLine == "***" {
                flushText(&currentLines, into: &blocks)
                blocks.append(Block(type: .separator, content: ""))
                continue
            }

            if trimmedLine.hasPrefix(">") {
                flushText(&currentLines, into: &blocks)
                let quote = trimmedLine.drop { $0 == ">" || $0 == " " }
                blocks.append(Block(type: .quote, content: String(quote)))
                continue
            }

            if trimmedLine.isEmpty, !currentLines.isEmpty {
                flushText(&currentLines, into: &blocks)
                continue
            }

            currentLines.append(line)
        }

        if inCodeBlock {
            blocks.append(Block(type: .codeBlock, content: codeLines.joined(separator: "\n"), language: codeLanguage))
        } else {
            flushText(&currentLines, into: &blocks)
        }

        renderCache.setObject(CachedBlocksBox(blocks: blocks), forKey: cacheKey)
        return blocks
    }

    nonisolated static func renderHTMLDocument(_ markdown: String) -> String {
        let cacheKey = markdown as NSString
        if let cached = htmlCache.object(forKey: cacheKey) {
            return cached.html
        }

        let body = render(markdown)
            .map(html(for:))
            .joined(separator: "\n")

        let html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        :root {
            color-scheme: light dark;
            --fg: rgba(24, 28, 35, 0.96);
            --muted: rgba(94, 103, 121, 0.92);
            --line: rgba(15, 23, 42, 0.08);
            --soft: rgba(15, 23, 42, 0.035);
            --quote: rgba(10, 132, 255, 0.18);
            --accent: #0a84ff;
            --code-bg: rgba(15, 23, 42, 0.045);
            --pre-bg: rgba(15, 23, 42, 0.055);
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --fg: rgba(242, 245, 250, 0.96);
                --muted: rgba(195, 203, 217, 0.85);
                --line: rgba(255, 255, 255, 0.09);
                --soft: rgba(255, 255, 255, 0.045);
                --quote: rgba(100, 180, 255, 0.28);
                --accent: #67b7ff;
                --code-bg: rgba(255, 255, 255, 0.08);
                --pre-bg: rgba(255, 255, 255, 0.07);
            }
        }
        html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            overflow: hidden;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            color: var(--fg);
            font-size: 14px;
            line-height: 1.68;
            -webkit-font-smoothing: antialiased;
            word-break: break-word;
            user-select: text;
            padding: 2px 0;
        }
        .markdown-root > *:first-child { margin-top: 0; }
        .markdown-root > *:last-child { margin-bottom: 0; }
        p {
            margin: 0 0 0.9em 0;
            color: var(--fg);
        }
        p + p {
            margin-top: -0.15em;
        }
        h1, h2, h3 {
            margin: 0.8em 0 0.38em 0;
            line-height: 1.28;
            font-weight: 680;
            letter-spacing: -0.015em;
        }
        h1 {
            font-size: 1.48em;
            padding-bottom: 0.32em;
            border-bottom: 1px solid var(--line);
        }
        h2 {
            font-size: 1.2em;
        }
        h3 {
            font-size: 1.03em;
        }
        blockquote {
            margin: 0.7em 0;
            padding: 0.6em 0.9em 0.6em 0.95em;
            border-left: 3px solid var(--quote);
            background: color-mix(in srgb, var(--soft) 70%, transparent);
            border-radius: 0 12px 12px 0;
            color: var(--muted);
        }
        ul, ol {
            margin: 0.35em 0 0.9em 1.35em;
            padding: 0;
        }
        li {
            margin: 0.2em 0;
        }
        .task-list {
            list-style: none;
            margin-left: 0;
        }
        .task-list li {
            display: flex;
            align-items: flex-start;
            gap: 0.6em;
        }
        .task-list input {
            margin-top: 0.28em;
            accent-color: var(--accent);
        }
        hr {
            border: 0;
            border-top: 1px solid var(--line);
            margin: 0.95em 0;
        }
        code {
            font-family: "SF Mono", "JetBrains Mono", ui-monospace, monospace;
            font-size: 0.92em;
            background: var(--code-bg);
            padding: 0.12em 0.38em;
            border-radius: 6px;
        }
        pre {
            margin: 0;
            padding: 12px 14px;
            background: var(--pre-bg);
            overflow-x: auto;
        }
        pre code {
            background: transparent;
            padding: 0;
            border-radius: 0;
            display: block;
            white-space: pre;
            line-height: 1.55;
        }
        table {
            border-collapse: collapse;
            font-size: 0.96em;
            min-width: 100%;
            border: 1px solid var(--line);
            background: rgba(255, 255, 255, 0.02);
        }
        th, td {
            border-bottom: 1px solid var(--line);
            padding: 9px 11px;
            text-align: left;
            vertical-align: top;
        }
        th {
            background: var(--soft);
            font-weight: 620;
        }
        tr:last-child td {
            border-bottom: 0;
        }
        .table-wrap {
            margin: 0.8em 0 1em 0;
            overflow-x: auto;
            border-radius: 12px;
            border: 1px solid var(--line);
            background: rgba(255, 255, 255, 0.015);
        }
        .table-wrap table {
            border: 0;
        }
        .table-wrap th, .table-wrap td {
            white-space: nowrap;
        }
        .code-shell {
            margin: 0.85em 0;
            border: 1px solid var(--line);
            border-radius: 14px;
            overflow: hidden;
            background: var(--pre-bg);
            box-shadow: 0 14px 32px rgba(15, 23, 42, 0.06);
        }
        .code-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            min-height: 34px;
            padding: 0 14px;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--muted);
            border-bottom: 1px solid var(--line);
            background: rgba(255, 255, 255, 0.03);
        }
        .code-header-meta {
            display: inline-flex;
            align-items: center;
            gap: 10px;
            min-width: 0;
        }
        .code-traffic {
            display: inline-flex;
            align-items: center;
            gap: 5px;
        }
        .code-traffic span {
            width: 8px;
            height: 8px;
            border-radius: 999px;
            opacity: 0.8;
        }
        .code-traffic span:nth-child(1) { background: #ff5f57; }
        .code-traffic span:nth-child(2) { background: #ffbd2f; }
        .code-traffic span:nth-child(3) { background: #28c840; }
        .code-language {
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .code-copy {
            border: 0;
            background: color-mix(in srgb, var(--soft) 88%, transparent);
            color: var(--muted);
            border-radius: 999px;
            padding: 4px 9px;
            font: inherit;
            font-size: 10px;
            line-height: 1;
            cursor: pointer;
            transition: background 0.18s ease, color 0.18s ease;
        }
        .code-copy:hover {
            background: color-mix(in srgb, var(--accent) 10%, var(--soft));
            color: var(--fg);
        }
        .code-body {
            overflow-x: auto;
        }
        .code-table {
            width: 100%;
            border-collapse: collapse;
            table-layout: fixed;
        }
        .code-table td {
            padding: 0;
            border: 0;
            background: transparent;
        }
        .code-line-no {
            width: 44px;
            padding: 0 10px 0 14px;
            text-align: right;
            color: var(--muted);
            opacity: 0.62;
            user-select: none;
            vertical-align: top;
            font-family: "SF Mono", "JetBrains Mono", ui-monospace, monospace;
            font-size: 11px;
            line-height: 1.68;
        }
        .code-line-code {
            width: calc(100% - 44px);
            padding: 0 14px 0 0;
        }
        .code-line-code code {
            display: block;
            white-space: pre;
            background: transparent;
            padding: 0;
            border-radius: 0;
            line-height: 1.68;
        }
        .token-comment {
            color: color-mix(in srgb, var(--muted) 92%, transparent);
            font-style: italic;
        }
        .token-keyword {
            color: #c447ff;
            font-weight: 600;
        }
        .token-string {
            color: #0f9d58;
        }
        .token-number {
            color: #d46b08;
        }
        .token-type {
            color: #147df5;
        }
        .token-operator {
            color: color-mix(in srgb, var(--fg) 82%, transparent);
        }
        @media (prefers-color-scheme: dark) {
            .code-shell {
                box-shadow: 0 18px 42px rgba(0, 0, 0, 0.24);
            }
            .token-keyword {
                color: #d98cff;
            }
            .token-string {
                color: #7ee787;
            }
            .token-number {
                color: #ffb86c;
            }
            .token-type {
                color: #79c0ff;
            }
        }
        a {
            color: var(--accent);
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        a.local-path {
            display: inline-flex;
            align-items: center;
            max-width: 100%;
            padding: 0.12em 0.52em;
            border-radius: 999px;
            background: color-mix(in srgb, var(--accent) 10%, transparent);
            border: 1px solid color-mix(in srgb, var(--accent) 14%, transparent);
            font-family: "SF Mono", "JetBrains Mono", ui-monospace, monospace;
            font-size: 0.93em;
            overflow-wrap: anywhere;
        }
        img {
            display: block;
            max-width: 100%;
            margin: 0.9em 0;
            border-radius: 14px;
        }
        strong {
            font-weight: 680;
        }
        em {
            font-style: italic;
        }
        del {
            color: var(--muted);
        }
        </style>
        </head>
        <body>
        <div class="markdown-root">
        \(body)
        </div>
        </body>
        </html>
        """
        htmlCache.setObject(CachedHTMLBox(html: html), forKey: cacheKey)
        return html
    }

    nonisolated static func requiresRichHTML(_ markdown: String, blocks: [Block]? = nil) -> Bool {
        let resolvedBlocks = blocks ?? render(markdown)
        if resolvedBlocks.contains(where: { if case .codeBlock = $0.type { return true } else { return false } }) {
            return true
        }

        let lines = markdown.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") || trimmed.hasPrefix("+ [") {
                return true
            }
            if unorderedListItem(from: line) != nil || orderedListItem(from: line) != nil {
                return true
            }
            if trimmed.contains("![") && trimmed.contains("](") {
                return true
            }
            if index + 1 < lines.count,
               isTableRow(line),
               isTableSeparatorLine(lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                return true
            }
        }

        return false
    }

    nonisolated private static func flushText(_ lines: inout [String], into blocks: inout [Block]) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n")
        lines = []
        let normalized = text.replacingOccurrences(
            of: #"\n{3,}$"#,
            with: "\n",
            options: .regularExpression
        )
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(Block(type: .text, content: normalized))
        }
    }

    nonisolated private static func headingBlock(for line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        let hashes = trimmed.prefix { $0 == "#" }
        let level = min(max(hashes.count, 1), 3)
        let title = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return Block(type: .heading(level), content: title)
    }

    @MainActor
    static func renderInline(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let source = String(attributed.characters)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        struct Style {
            let nsRange: NSRange
            let showText: String   // 要显示的文本（去掉标记符号）
            let attrs: AttributeContainer
        }

        var styles: [Style] = []

        // **粗体**
        if let regex = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#) {
            for match in regex.matches(in: source, range: fullRange) {
                guard match.numberOfRanges >= 2,
                      let innerRange = Range(match.range(at: 1), in: source) else { continue }
                var container = AttributeContainer()
                container.font = .body.bold()
                // 标记整个 **xxx** 范围，显示时只保留内部文字
                styles.append(Style(nsRange: match.range, showText: String(source[innerRange]), attrs: container))
            }
        }

        // *斜体*
        if let regex = try? NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)\*(?!\*)"#) {
            for match in regex.matches(in: source, range: fullRange) {
                guard match.numberOfRanges >= 2,
                      let innerRange = Range(match.range(at: 1), in: source) else { continue }
                var container = AttributeContainer()
                container.font = .body.italic()
                styles.append(Style(nsRange: match.range, showText: String(source[innerRange]), attrs: container))
            }
        }

        // `行内代码`
        if let regex = try? NSRegularExpression(pattern: #"`([^`]+)`"#) {
            for match in regex.matches(in: source, range: fullRange) {
                guard match.numberOfRanges >= 2,
                      let innerRange = Range(match.range(at: 1), in: source) else { continue }
                var container = AttributeContainer()
                container.font = .system(size: 12, weight: .medium, design: .monospaced)
                container.foregroundColor = Color.accentColor.opacity(0.95)
                container.backgroundColor = Color.accentColor.opacity(0.12)
                styles.append(Style(nsRange: match.range, showText: String(source[innerRange]), attrs: container))
            }
        }

        // [链接文本](url)
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) {
            for match in regex.matches(in: source, range: fullRange) {
                guard match.numberOfRanges >= 3,
                      let textRange = Range(match.range(at: 1), in: source),
                      let urlRange = Range(match.range(at: 2), in: source) else { continue }
                var container = AttributeContainer()
                container.foregroundColor = .accentColor
                container.underlineStyle = .single
                let urlStr = String(source[urlRange])
                if let url = URL(string: urlStr) {
                    container.link = url
                }
                styles.append(Style(nsRange: match.range, showText: String(source[textRange]), attrs: container))
            }
        }

        // ~~删除线~~
        if let regex = try? NSRegularExpression(pattern: #"~~(.+?)~~"#) {
            for match in regex.matches(in: source, range: fullRange) {
                guard match.numberOfRanges >= 2,
                      let innerRange = Range(match.range(at: 1), in: source) else { continue }
                var container = AttributeContainer()
                container.strikethroughStyle = .single
                container.strikethroughColor = NSColor.secondaryLabelColor
                styles.append(Style(nsRange: match.range, showText: String(source[innerRange]), attrs: container))
            }
        }

        // 按范围从后往前替换，避免偏移
        for style in styles.sorted(by: { $0.nsRange.location > $1.nsRange.location }) {
            guard let range = Range(style.nsRange, in: attributed) else { continue }
            var replacement = AttributedString(style.showText)
            replacement.mergeAttributes(style.attrs)
            attributed.replaceSubrange(range, with: replacement)
        }

        return attributed
    }

    nonisolated private static func html(for block: Block) -> String {
        switch block.type {
        case .text:
            return htmlForTextBlock(block.content)
        case .codeBlock:
            return renderCodeBlockHTML(content: block.content, language: block.language)
        case .heading(let level):
            let tag = "h\(min(max(level, 1), 3))"
            return "<\(tag)>\(renderInlineHTMLWithPathSupport(block.content))</\(tag)>"
        case .quote:
            return "<blockquote><p>\(renderInlineHTMLWithPathSupport(block.content))</p></blockquote>"
        case .separator:
            return "<hr />"
        }
    }

    nonisolated private static func htmlForTextBlock(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var segments: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if isTableSeparatorLine(trimmed), index > 0 {
                index += 1
                continue
            }

            if let unordered = unorderedListItem(from: line) {
                var items: [String] = [unordered]
                index += 1
                while index < lines.count, let next = unorderedListItem(from: lines[index]) {
                    items.append(next)
                    index += 1
                }
                let htmlItems = items.map { "<li>\(renderInlineHTMLWithPathSupport($0))</li>" }.joined()
                segments.append("<ul>\(htmlItems)</ul>")
                continue
            }

            if let ordered = orderedListItem(from: line) {
                var items: [String] = [ordered]
                index += 1
                while index < lines.count, let next = orderedListItem(from: lines[index]) {
                    items.append(next)
                    index += 1
                }
                let htmlItems = items.map { "<li>\(renderInlineHTMLWithPathSupport($0))</li>" }.joined()
                segments.append("<ol>\(htmlItems)</ol>")
                continue
            }

            if let taskItem = taskListItem(from: line) {
                var items: [(checked: Bool, content: String)] = [taskItem]
                index += 1
                while index < lines.count, let next = taskListItem(from: lines[index]) {
                    items.append(next)
                    index += 1
                }
                let htmlItems = items.map { item in
                    let checked = item.checked ? "checked" : ""
                    return "<li><input type=\"checkbox\" disabled \(checked) /><span>\(renderInlineHTMLWithPathSupport(item.content))</span></li>"
                }.joined()
                segments.append("<ul class=\"task-list\">\(htmlItems)</ul>")
                continue
            }

            if index + 1 < lines.count,
               isTableRow(line),
               isTableSeparatorLine(lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                let header = tableCells(from: line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(tableCells(from: lines[index]))
                    index += 1
                }
                segments.append(renderTableHTML(header: header, rows: rows))
                continue
            }

            var paragraphLines: [String] = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                if nextTrimmed.isEmpty ||
                    unorderedListItem(from: next) != nil ||
                    orderedListItem(from: next) != nil ||
                    (index + 1 < lines.count &&
                     isTableRow(next) &&
                     isTableSeparatorLine(lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines))) {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }

            let paragraph = paragraphLines
                .map { renderInlineHTMLWithPathSupport($0) }
                .joined(separator: "<br />")
            segments.append("<p>\(paragraph)</p>")
        }

        return segments.joined(separator: "\n")
    }

    nonisolated private static func renderTableHTML(header: [String], rows: [[String]]) -> String {
        let headerHTML = header.map { "<th>\(renderInlineHTMLWithPathSupport($0))</th>" }.joined()
        let bodyHTML = rows.map { row in
            let cells = row.map { "<td>\(renderInlineHTMLWithPathSupport($0))</td>" }.joined()
            return "<tr>\(cells)</tr>"
        }.joined()
        return "<div class=\"table-wrap\"><table><thead><tr>\(headerHTML)</tr></thead><tbody>\(bodyHTML)</tbody></table></div>"
    }

    nonisolated private static func unorderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefixes = ["- ", "* ", "+ "]
        guard let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) else { return nil }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func orderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) else { return nil }
        return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func taskListItem(from line: String) -> (checked: Bool, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^[-*+]\s+\[( |x|X)\]\s+"#, options: .regularExpression) else { return nil }
        let marker = String(trimmed[range]).lowercased()
        let content = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (marker.contains("[x]"), content)
    }

    nonisolated private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("|") && tableCells(from: trimmed).count >= 2
    }

    nonisolated private static func isTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return false }
        return trimmed.replacingOccurrences(of: "|", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-: "))
            .isEmpty
    }

    nonisolated private static func tableCells(from line: String) -> [String] {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func renderInlineHTML(_ text: String) -> String {
        var html = escapeHTML(text)

        html = replaceMatches(in: html, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { match in
            let alt = match[1].replacingOccurrences(of: "\"", with: "&quot;")
            let src = match[2].replacingOccurrences(of: "\"", with: "%22")
            return #"<img src="\#(src)" alt="\#(alt)" />"#
        }
        html = replaceMatches(in: html, pattern: #"`([^`]+)`"#) { match in
            "<code>\(match[1])</code>"
        }
        html = replaceMatches(in: html, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { match in
            let href = match[2].replacingOccurrences(of: "\"", with: "%22")
            return #"<a href="\#(href)">\#(match[1])</a>"#
        }
        html = replaceMatches(in: html, pattern: #"\*\*(.+?)\*\*"#) { match in
            "<strong>\(match[1])</strong>"
        }
        html = replaceMatches(in: html, pattern: #"(?<!\*)\*(?!\*)(.+?)\*(?!\*)"#) { match in
            "<em>\(match[1])</em>"
        }
        html = replaceMatches(in: html, pattern: #"~~(.+?)~~"#) { match in
            "<del>\(match[1])</del>"
        }

        return html
    }

    nonisolated private static func renderCodeBlockHTML(content: String, language: String?) -> String {
        let languageName = normalizedCodeLanguage(language)
        let header = renderCodeHeader(languageName: languageName)
        let lines = content.components(separatedBy: "\n")
        let rows = lines.enumerated().map { index, line in
            let highlighted = highlightedCodeHTML(for: line, language: languageName)
            let renderedLine = highlighted.isEmpty ? "&nbsp;" : highlighted
            return """
            <tr>
            <td class="code-line-no">\(index + 1)</td>
            <td class="code-line-code"><code>\(renderedLine)</code></td>
            </tr>
            """
        }.joined()

        return """
        <div class="code-shell">
        <div class="code-header">\(header)\(renderCodeCopyButton(for: content))</div>
        <div class="code-body">
        <table class="code-table"><tbody>\(rows)</tbody></table>
        </div>
        </div>
        """
    }

    nonisolated private static func renderCodeHeader(languageName: String?) -> String {
        let label = languageName.map { escapeHTML($0.uppercased()) } ?? "CODE"
        return """
        <div class="code-header-meta">
        <span class="code-traffic"><span></span><span></span><span></span></span>
        <span class="code-language">\(label)</span>
        </div>
        """
    }

    nonisolated private static func highlightedCodeHTML(for line: String, language: String?) -> String {
        var html = escapeHTML(line)
        var placeholders: [String: String] = [:]
        var placeholderIndex = 0

        func capture(pattern: String, cssClass: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let nsHTML = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
            guard !matches.isEmpty else { return }

            for match in matches.reversed() {
                guard let range = Range(match.range, in: html) else { continue }
                let raw = String(html[range])
                let placeholder = "%%CODETOKEN\(placeholderIndex)%%"
                placeholderIndex += 1
                placeholders[placeholder] = "<span class=\"\(cssClass)\">\(raw)</span>"
                html.replaceSubrange(range, with: placeholder)
            }
        }

        switch language {
        case "swift", "javascript", "typescript", "java", "c", "cpp", "csharp", "go", "kotlin", "rust":
            capture(pattern: #"//.*$"#, cssClass: "token-comment")
        case "python", "bash", "shell", "ruby", "yaml", "toml":
            capture(pattern: #"#.*$"#, cssClass: "token-comment")
        case "sql":
            capture(pattern: #"--.*$"#, cssClass: "token-comment")
        case "html", "xml":
            capture(pattern: #"&lt;!--.*?--&gt;"#, cssClass: "token-comment")
        default:
            break
        }

        capture(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, cssClass: "token-string")

        if let keywords = codeKeywords(for: language), !keywords.isEmpty {
            let pattern = #"\b("# + keywords.joined(separator: "|") + #")\b"#
            capture(pattern: pattern, cssClass: "token-keyword")
        }

        capture(pattern: #"\b([A-Z][A-Za-z0-9_]+)\b"#, cssClass: "token-type")
        capture(pattern: #"(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])"#, cssClass: "token-number")
        capture(pattern: #"([=+\-*/%<>!&|?:]+)"#, cssClass: "token-operator")

        for (placeholder, rendered) in placeholders {
            html = html.replacingOccurrences(of: placeholder, with: rendered)
        }

        return html
    }

    nonisolated private static func normalizedCodeLanguage(_ language: String?) -> String? {
        guard let raw = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else { return nil }

        switch raw {
        case "js", "jsx":
            return "javascript"
        case "ts", "tsx":
            return "typescript"
        case "sh", "zsh":
            return "shell"
        case "py":
            return "python"
        case "yml":
            return "yaml"
        case "md":
            return "markdown"
        case "htm":
            return "html"
        default:
            return raw
        }
    }

    nonisolated private static func codeKeywords(for language: String?) -> [String]? {
        switch language {
        case "swift":
            return ["import", "struct", "class", "enum", "protocol", "extension", "func", "let", "var", "if", "else", "guard", "return", "async", "await", "throw", "throws", "try", "case", "switch", "for", "while", "in", "where", "private", "fileprivate", "public", "internal", "nonisolated", "actor", "nil", "true", "false", "self"]
        case "javascript", "typescript":
            return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "import", "from", "export", "default", "class", "extends", "new", "async", "await", "try", "catch", "finally", "null", "true", "false", "undefined", "interface", "type"]
        case "python":
            return ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "try", "except", "finally", "with", "yield", "async", "await", "None", "True", "False", "lambda"]
        case "bash", "shell":
            return ["if", "then", "else", "fi", "for", "do", "done", "case", "esac", "function", "in", "export", "local", "return"]
        case "json":
            return ["true", "false", "null"]
        case "html", "xml":
            return ["html", "head", "body", "div", "span", "script", "style", "meta", "link"]
        case "css":
            return ["display", "position", "color", "background", "font", "border", "padding", "margin", "grid", "flex", "absolute", "relative"]
        case "sql":
            return ["SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "GROUP", "BY", "ORDER", "LIMIT", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE", "CREATE", "TABLE", "AND", "OR", "NOT", "NULL"]
        default:
            return nil
        }
    }

    nonisolated private static func renderInlineHTMLWithPathSupport(_ text: String) -> String {
        guard let detected = detectExistingLocalPath(in: text) else {
            return renderInlineHTML(text)
        }

        let prefixHTML = detected.prefix.isEmpty ? "" : renderInlineHTML(detected.prefix)
        return prefixHTML + renderLocalPathHTML(detected.path)
    }

    nonisolated private static func replaceMatches(
        in source: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return source }

        var result = source
        for match in matches.reversed() {
            let captureStrings: [String] = (0..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: source) else { return nil }
                return String(source[range])
            }
            guard let range = Range(match.range, in: result), captureStrings.count == match.numberOfRanges else { continue }
            result.replaceSubrange(range, with: transform(captureStrings))
        }
        return result
    }

    nonisolated private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    nonisolated private static func escapeHTMLAttribute(_ text: String) -> String {
        escapeHTML(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    nonisolated private static func renderCodeCopyButton(for code: String) -> String {
        let payload = Data(code.utf8).base64EncodedString()
        let label = escapeHTMLAttribute(L10n.tr("common.copy"))
        let copiedLabel = escapeHTMLAttribute(L10n.tr("common.copied"))
        return #"<button class="code-copy" type="button" data-code="\#(payload)" data-default-label="\#(label)" data-copied-label="\#(copiedLabel)">\#(label)</button>"#
    }

    nonisolated private static func renderLocalPathHTML(_ path: String) -> String {
        let href = escapeHTMLAttribute(URL(fileURLWithPath: path).absoluteString)
        let label = escapeHTML(path)
        return #"<a class="local-path" href="\#(href)">\#(label)</a>"#
    }

    nonisolated private static func detectExistingLocalPath(in line: String) -> (prefix: String, path: String)? {
        let nsLine = line as NSString
        let indexes = line.indices.filter { line[$0] == "/" || line[$0] == "~" }

        for index in indexes {
            let location = line.distance(from: line.startIndex, to: index)
            let prefix = nsLine.substring(to: location)
            var candidate = String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)

            while !candidate.isEmpty {
                let expanded = (candidate as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expanded) {
                    return (prefix, expanded)
                }

                let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,.;:!?)，。；：」』》】）"))
                if trimmed == candidate {
                    break
                }
                candidate = trimmed
            }
        }
        return nil
    }
}

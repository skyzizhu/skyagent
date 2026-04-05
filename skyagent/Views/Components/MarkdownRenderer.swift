import SwiftUI
import Foundation

struct MarkdownRenderer {
    private final class CachedBlocksBox: NSObject {
        let blocks: [Block]

        init(blocks: [Block]) {
            self.blocks = blocks
        }
    }

    private static let renderCache = NSCache<NSString, CachedBlocksBox>()

    enum BlockType: Equatable {
        case text, codeBlock, separator, heading(Int), quote
    }

    struct Block: Identifiable, Equatable {
        let id = UUID()
        let type: BlockType
        let content: String
        let language: String?

        init(type: BlockType, content: String, language: String? = nil) {
            self.type = type
            self.content = content
            self.language = language
        }
    }

    static func render(_ markdown: String) -> [Block] {
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

    private static func flushText(_ lines: inout [String], into blocks: inout [Block]) {
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

    private static func headingBlock(for line: String) -> Block? {
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
}

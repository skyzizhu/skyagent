import SwiftUI
import AppKit

struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    private var displayLanguage: String {
        let raw = (language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap { $0.isEmpty ? nil : $0 }
        return raw ?? "code"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(displayLanguage)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.09))
                    )

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.55))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.7)

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(highlightedCode)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 360, alignment: .leading)
            .clipped()
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .textBackgroundColor).opacity(0.98),
                            Color(nsColor: .controlBackgroundColor).opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.9)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 12, y: 4)
    }

    /// 简易语法高亮：基于正则给关键字、字符串、注释上色
    private var highlightedCode: AttributedString {
        var attr = AttributedString(code)
        let keywordColor = Color.purple
        let stringColor = Color(red: 0.77, green: 0.1, blue: 0.09)
        let commentColor = Color.green.opacity(0.7)
        let numberColor = Color.orange

        // 关键字
        let keywords = [
            "import", "class", "struct", "enum", "protocol", "extension", "func", "var", "let", "const",
            "if", "else", "switch", "case", "default", "for", "while", "return", "break", "continue",
            "guard", "try", "catch", "throw", "throws", "async", "await", "public", "private", "static",
            "self", "super", "nil", "true", "false", "init", "deinit",
            "def", "print", "None", "True", "False", "from", "as", "with", "yield", "lambda", "pass",
            "function", "const", "let", "var", "typeof", "new", "this", "null", "undefined",
            "int", "float", "double", "string", "bool", "void", "array", "map",
            "echo", "exit", "fi", "then", "do", "done",
        ]

        let source = String(attr.characters)

        // Comments: // and #
        applyPattern(&attr, source: source, pattern: #"//.*$"#, color: commentColor, options: .anchorsMatchLines)
        applyPattern(&attr, source: source, pattern: #"#.*$"#, color: commentColor, options: .anchorsMatchLines)
        /* Block comments */
        applyPattern(&attr, source: source, pattern: #"/\*[\s\S]*?\*/"#, color: commentColor)

        // Strings
        applyPattern(&attr, source: source, pattern: #""[^"]*""#, color: stringColor)
        applyPattern(&attr, source: source, pattern: #"'[^']*'"#, color: stringColor)

        // Numbers
        applyPattern(&attr, source: source, pattern: #"\b\d+\.?\d*\b"#, color: numberColor)

        // Keywords
        for kw in keywords {
            applyPattern(&attr, source: source, pattern: "\\b\(NSRegularExpression.escapedPattern(for: kw))\\b", color: keywordColor)
        }

        return attr
    }

    private func applyPattern(_ attr: inout AttributedString, source: String, pattern: String, color: Color, options: NSRegularExpression.Options = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, options: [], range: fullRange)

        for match in matches.reversed() {
            guard let range = Range(match.range, in: source),
                  let attrRange = Range(range, in: attr) else { continue }
            attr[attrRange].foregroundColor = color
        }
    }
}

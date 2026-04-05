import SwiftUI
import AppKit

/// Markdown 内容渲染（助手消息）
struct MarkdownContentView: View {
    let content: String
    @State private var blocks: [MarkdownRenderer.Block] = []
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .onAppear {
            blocks = MarkdownRenderer.render(content)
        }
        .onChange(of: content) { _, new in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                blocks = MarkdownRenderer.render(new)
            }
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    @MainActor
    private func blockView(_ block: MarkdownRenderer.Block) -> some View {
        switch block.type {
        case .text:
            return AnyView(
                PathAwareTextBlockView(
                    content: block.content,
                    font: .system(size: 13, weight: .regular, design: .rounded),
                    foregroundColor: Color.primary.opacity(0.92),
                    lineSpacing: 2.2
                )
            )
        case .codeBlock:
            return AnyView(CodeBlockView(code: block.content, language: block.language))
        case .heading(let level):
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text(block.content)
                        .font(headingFont(for: level))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Rectangle()
                        .fill(Color.primary.opacity(level == 1 ? 0.12 : 0.07))
                        .frame(height: level == 1 ? 1 : 0.7)
                }
                .padding(.top, level == 1 ? 5 : 1)
                .padding(.bottom, 0)
            )
        case .quote:
            return AnyView(
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 2.5)

                    PathAwareTextBlockView(
                        content: block.content,
                        font: .system(size: 12, weight: .medium, design: .rounded),
                        foregroundColor: .secondary,
                        lineSpacing: 2.2
                    )
                }
                .padding(.vertical, 1)
            )
        case .separator:
            return AnyView(
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.7)
                    .padding(.vertical, 3)
            )
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 20, weight: .semibold, design: .rounded)
        case 2:
            return .system(size: 16, weight: .semibold, design: .rounded)
        default:
            return .system(size: 14, weight: .semibold, design: .rounded)
        }
    }
}

private struct PathAwareTextBlockView: View {
    let content: String
    let font: Font
    let foregroundColor: Color
    let lineSpacing: CGFloat

    private var lines: [String] {
        content.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let parts = detectExistingLocalPath(in: line) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if !parts.prefix.isEmpty {
                            Text(MarkdownRenderer.renderInline(parts.prefix))
                                .font(font)
                                .foregroundStyle(foregroundColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        PathTextView(path: parts.path, font: font)
                    }
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                } else if line.isEmpty {
                    Color.clear.frame(height: 6)
                } else {
                    Text(MarkdownRenderer.renderInline(line))
                        .font(font)
                        .foregroundStyle(foregroundColor)
                        .lineSpacing(lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func detectExistingLocalPath(in line: String) -> (prefix: String, path: String)? {
        let nsLine = line as NSString
        let slashIndexes = line.indices.filter { line[$0] == "/" || line[$0] == "~" }

        for index in slashIndexes {
            let location = line.distance(from: line.startIndex, to: index)
            let prefix = nsLine.substring(to: location)
            var candidate = String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)

            while !candidate.isEmpty {
                let expanded = (candidate as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expanded) {
                    return (prefix, expanded)
                }

                let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,.;:!?)，。；：」』》】）"))
                if trimmed == candidate { break }
                candidate = trimmed
            }
        }

        return nil
    }
}

private struct PathTextView: View {
    let path: String
    let font: Font

    var body: some View {
        Text(path)
            .font(font)
            .foregroundColor(.accentColor)
            .underline()
            .textSelection(.enabled)
            .contextMenu {
                Button(L10n.tr("common.reveal_in_finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button(L10n.tr("common.open_file")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
            .help(path)
    }
}

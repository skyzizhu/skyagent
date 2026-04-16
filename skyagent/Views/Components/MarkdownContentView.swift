import SwiftUI
import AppKit

/// Markdown 内容渲染（助手消息）
struct MarkdownContentView: View {
    let content: String
    var isStreaming: Bool = false
    private static let renderCache = MarkdownContentRenderCache.shared
    @State private var blocks: [MarkdownRenderer.Block] = []
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastRenderedContent = ""
    @State private var lastRenderedStreamingState: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .onAppear {
            scheduleRender(for: content, immediate: true)
        }
        .onChange(of: content) { _, new in
            scheduleRender(for: new)
        }
        .onChange(of: isStreaming) { _, _ in
            scheduleRender(for: content, immediate: true)
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    private func scheduleRender(for newContent: String, immediate: Bool = false) {
        guard newContent != lastRenderedContent || lastRenderedStreamingState != isStreaming else { return }
        debounceTask?.cancel()

        let cacheKey = Self.cacheKey(for: newContent, isStreaming: isStreaming)
        if let cached = Self.renderCache.payload(for: cacheKey) {
            blocks = cached.blocks
            lastRenderedContent = newContent
            lastRenderedStreamingState = isStreaming
            return
        }

        debounceTask = Task {
            let renderStartedAt = Date()
            if !isStreaming {
                await LoggerService.shared.log(
                    category: .render,
                    event: "markdown_render_started",
                    status: .started,
                    summary: "开始渲染 Markdown",
                    metadata: [
                        "content_length": .int(newContent.count),
                        "is_streaming": .bool(isStreaming)
                    ]
                )
            }
            let delay: UInt64
            if immediate {
                delay = 0
            } else {
                delay = renderDebounceNanoseconds(for: newContent, isStreaming: isStreaming)
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            let renderingModeIsStreaming = isStreaming
            let rendered = await Task.detached(priority: renderingModeIsStreaming ? .utility : .userInitiated) {
                let blocks = MarkdownRenderer.render(newContent)
                return RenderPayload(blocks: blocks)
            }.value
            guard !Task.isCancelled else { return }
            Self.renderCache.store(rendered, for: cacheKey)
            blocks = rendered.blocks
            lastRenderedContent = newContent
            lastRenderedStreamingState = renderingModeIsStreaming
            if !renderingModeIsStreaming {
                await LoggerService.shared.log(
                    category: .render,
                    event: "markdown_render_finished",
                    status: .succeeded,
                    durationMs: Date().timeIntervalSince(renderStartedAt) * 1000,
                    summary: "Markdown 渲染完成",
                    metadata: [
                        "content_length": .int(newContent.count),
                        "block_count": .int(rendered.blocks.count),
                        "uses_rich_html": .bool(false)
                    ]
                )
            }
        }
    }

    fileprivate struct RenderPayload: Sendable {
        let blocks: [MarkdownRenderer.Block]
    }

    private static func cacheKey(for content: String, isStreaming: Bool) -> String {
        "\(isStreaming ? "stream" : "stable")::\(content.hashValue)"
    }

    private func renderDebounceNanoseconds(for content: String, isStreaming: Bool) -> UInt64 {
        guard isStreaming else { return 60_000_000 }
        switch content.count {
        case 0..<1_200:
            return 160_000_000
        case 1_200..<4_000:
            return 260_000_000
        default:
            return 360_000_000
        }
    }

    @MainActor
    private func blockView(_ block: MarkdownRenderer.Block) -> some View {
        switch block.type {
        case .text:
            return AnyView(
                PathAwareTextBlockView(
                    content: block.content,
                    font: .system(size: 13.5, weight: .regular, design: .rounded),
                    foregroundColor: Color.primary.opacity(0.92),
                    lineSpacing: 3.0
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
                        .fill(level == 1 ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                        .frame(height: level == 1 ? 1.2 : 0.8)
                }
                .padding(.top, level == 1 ? 8 : 3)
                .padding(.bottom, level == 1 ? 2 : 0)
            )
        case .quote:
            return AnyView(
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 2.5)

                    PathAwareTextBlockView(
                        content: block.content,
                        font: .system(size: 12.5, weight: .medium, design: .rounded),
                        foregroundColor: Color.secondary.opacity(0.92),
                        lineSpacing: 2.8
                    )
                }
                .padding(.vertical, 2)
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
            return .system(size: 21, weight: .semibold, design: .rounded)
        case 2:
            return .system(size: 17, weight: .semibold, design: .rounded)
        default:
            return .system(size: 14.5, weight: .semibold, design: .rounded)
        }
    }
}

private final class MarkdownContentRenderCache {
    static let shared = MarkdownContentRenderCache()

    private final class CachedPayloadBox: NSObject {
        let payload: MarkdownContentView.RenderPayload

        init(payload: MarkdownContentView.RenderPayload) {
            self.payload = payload
        }
    }

    private let cache = NSCache<NSString, CachedPayloadBox>()

    func payload(for key: String) -> MarkdownContentView.RenderPayload? {
        cache.object(forKey: key as NSString)?.payload
    }

    func store(_ payload: MarkdownContentView.RenderPayload, for key: String) {
        cache.setObject(CachedPayloadBox(payload: payload), forKey: key as NSString)
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
        VStack(alignment: .leading, spacing: 5) {
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
                    Color.clear.frame(height: 5)
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
        if let cached = PathDetectionCache.shared.lookup(line: line) {
            return cached
        }

        let nsLine = line as NSString
        let slashIndexes = line.indices.filter { line[$0] == "/" || line[$0] == "~" }

        for index in slashIndexes {
            let location = line.distance(from: line.startIndex, to: index)
            let prefix = nsLine.substring(to: location)
            var candidate = String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)

            while !candidate.isEmpty {
                let expanded = (candidate as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expanded) {
                    let match = (prefix, expanded)
                    PathDetectionCache.shared.store(line: line, match: match)
                    return match
                }

                let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,.;:!?)，。；：」』》】）"))
                if trimmed == candidate { break }
                candidate = trimmed
            }
        }

        PathDetectionCache.shared.store(line: line, match: nil)
        return nil
    }
}

private final class PathDetectionCache {
    static let shared = PathDetectionCache()

    private let lock = NSLock()
    private var storage: [String: CacheEntry] = [:]

    private struct CachedPathMatch {
        let prefix: String
        let path: String
    }

    private enum CacheEntry {
        case miss
        case hit(CachedPathMatch)
    }

    func lookup(line: String) -> (prefix: String, path: String)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[line] {
            switch cached {
            case .hit(let cached):
                return (cached.prefix, cached.path)
            case .miss:
                return nil
            }
        }
        return nil
    }

    func store(line: String, match: (prefix: String, path: String)?) {
        lock.lock()
        defer { lock.unlock() }
        if let match {
            storage[line] = .hit(CachedPathMatch(prefix: match.prefix, path: match.path))
        } else {
            storage[line] = .miss
        }
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

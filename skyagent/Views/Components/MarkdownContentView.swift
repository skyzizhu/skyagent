import SwiftUI
import AppKit
import WebKit

/// Markdown 内容渲染（助手消息）
struct MarkdownContentView: View {
    let content: String
    var isStreaming: Bool = false
    private static let renderCache = MarkdownContentRenderCache.shared
    @State private var blocks: [MarkdownRenderer.Block] = []
    @State private var renderedHTML = ""
    @State private var renderedHTMLHeight: CGFloat = 28
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastRenderedContent = ""
    @State private var lastRenderedStreamingState: Bool?
    @State private var richRenderCacheKey = ""

    var body: some View {
        Group {
            if shouldUseRichHTMLRenderer {
                RichMarkdownWebView(
                    html: renderedHTML,
                    cacheKey: richRenderCacheKey,
                    measuredHeight: $renderedHTMLHeight
                )
                    .frame(height: max(renderedHTMLHeight, 28))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks) { block in
                        blockView(block)
                    }
                }
                .textSelection(.enabled)
            }
        }
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

    private var shouldUseRichHTMLRenderer: Bool {
        !isStreaming && !renderedHTML.isEmpty
    }

    private func scheduleRender(for newContent: String, immediate: Bool = false) {
        guard newContent != lastRenderedContent || lastRenderedStreamingState != isStreaming else { return }
        debounceTask?.cancel()

        let cacheKey = Self.cacheKey(for: newContent, isStreaming: isStreaming)
        if let cached = Self.renderCache.payload(for: cacheKey) {
            blocks = cached.blocks
            renderedHTML = cached.html
            richRenderCacheKey = Self.contentCacheKey(for: newContent)
            if cached.usesRichHTML,
               let cachedHeight = MarkdownHTMLViewCache.shared.height(for: richRenderCacheKey) {
                renderedHTMLHeight = cachedHeight
            } else if isStreaming || !cached.usesRichHTML {
                renderedHTMLHeight = 28
            }
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
                let shouldUseRichHTML = !renderingModeIsStreaming && MarkdownRenderer.requiresRichHTML(newContent, blocks: blocks)
                let html = shouldUseRichHTML ? MarkdownRenderer.renderHTMLDocument(newContent) : ""
                return RenderPayload(blocks: blocks, html: html, usesRichHTML: shouldUseRichHTML)
            }.value
            guard !Task.isCancelled else { return }
            Self.renderCache.store(rendered, for: cacheKey)
            blocks = rendered.blocks
            renderedHTML = rendered.html
            let htmlCacheKey = Self.contentCacheKey(for: newContent)
            richRenderCacheKey = htmlCacheKey
            if rendered.usesRichHTML,
               let cachedHeight = MarkdownHTMLViewCache.shared.height(for: htmlCacheKey) {
                renderedHTMLHeight = cachedHeight
            } else if renderingModeIsStreaming || !rendered.usesRichHTML {
                renderedHTMLHeight = 28
            }
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
                        "uses_rich_html": .bool(rendered.usesRichHTML)
                    ]
                )
            }
        }
    }

    fileprivate struct RenderPayload: Sendable {
        let blocks: [MarkdownRenderer.Block]
        let html: String
        let usesRichHTML: Bool
    }

    private static func contentCacheKey(for content: String) -> String {
        String(content.hashValue)
    }

    private static func cacheKey(for content: String, isStreaming: Bool) -> String {
        "\(isStreaming ? "stream" : "stable")::\(contentCacheKey(for: content))"
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

private struct RichMarkdownWebView: NSViewRepresentable {
    let html: String
    let cacheKey: String
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredHeight: $measuredHeight, cacheKey: cacheKey)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let resizeScript = WKUserScript(
            source: """
            (function() {
                function reportHeight() {
                    const root = document.documentElement;
                    const body = document.body;
                    const height = Math.max(
                        root ? root.scrollHeight : 0,
                        root ? root.offsetHeight : 0,
                        body ? body.scrollHeight : 0,
                        body ? body.offsetHeight : 0
                    );
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.markdownHeight) {
                        window.webkit.messageHandlers.markdownHeight.postMessage(height);
                    }
                }

                window.addEventListener('load', reportHeight);
                window.addEventListener('resize', reportHeight);
                document.addEventListener('DOMContentLoaded', function() {
                    if (window.ResizeObserver && document.body) {
                        new ResizeObserver(function() {
                            window.requestAnimationFrame(reportHeight);
                        }).observe(document.body);
                    }
                    reportHeight();
                    setTimeout(reportHeight, 0);
                    setTimeout(reportHeight, 120);
                });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let interactionScript = WKUserScript(
            source: """
            (function() {
                document.addEventListener('click', function(event) {
                    const button = event.target.closest('.code-copy');
                    if (!button) {
                        return;
                    }

                    event.preventDefault();
                    const payload = button.getAttribute('data-code') || '';
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.codeCopy) {
                        window.webkit.messageHandlers.codeCopy.postMessage(payload);
                    }

                    const copiedLabel = button.getAttribute('data-copied-label') || button.textContent || '';
                    const defaultLabel = button.getAttribute('data-default-label') || button.textContent || '';
                    button.textContent = copiedLabel;
                    window.clearTimeout(button.__copyResetTimer);
                    button.__copyResetTimer = window.setTimeout(function() {
                        button.textContent = defaultLabel;
                    }, 1400);
                });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(resizeScript)
        contentController.addUserScript(interactionScript)
        contentController.add(context.coordinator, name: Coordinator.messageHandlerName)
        contentController.add(context.coordinator, name: Coordinator.copyHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController

        let webView = PassthroughScrollWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        context.coordinator.lastLoadedHTML = html
        context.coordinator.installScrollMonitor(for: webView)
        webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/"))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.cacheKey = cacheKey
        context.coordinator.installScrollMonitor(for: nsView)
        guard context.coordinator.lastLoadedHTML != html else {
            nsView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
            return
        }

        context.coordinator.lastLoadedHTML = html
        nsView.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/"))
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.removeScrollMonitor()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.copyHandlerName)
        nsView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageHandlerName = "markdownHeight"
        static let copyHandlerName = "codeCopy"

        @Binding var measuredHeight: CGFloat
        var lastLoadedHTML = ""
        var cacheKey: String
        private weak var monitoredWebView: WKWebView?
        private var scrollMonitor: Any?

        init(measuredHeight: Binding<CGFloat>, cacheKey: String) {
            self._measuredHeight = measuredHeight
            self.cacheKey = cacheKey
        }

        deinit {
            removeScrollMonitor()
        }

        func installScrollMonitor(for webView: WKWebView) {
            monitoredWebView = webView
            guard scrollMonitor == nil else { return }

            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self,
                      let webView = self.monitoredWebView,
                      let window = webView.window,
                      event.window === window else {
                    return event
                }

                let location = webView.convert(event.locationInWindow, from: nil)
                guard webView.bounds.contains(location),
                      let outerScrollView = self.ancestorScrollView(for: webView) else {
                    return event
                }

                outerScrollView.scrollWheel(with: event)
                return nil
            }
        }

        func removeScrollMonitor() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
            monitoredWebView = nil
        }

        private func ancestorScrollView(for webView: WKWebView) -> NSScrollView? {
            var candidate = webView.superview
            while let current = candidate {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                candidate = current.superview
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case Self.messageHandlerName:
                guard let rawHeight = message.body as? NSNumber else { return }
                let nextHeight = max(CGFloat(truncating: rawHeight), 28)
                guard abs(nextHeight - measuredHeight) > 1 else { return }
                measuredHeight = nextHeight
                MarkdownHTMLViewCache.shared.storeHeight(nextHeight, for: cacheKey)
            case Self.copyHandlerName:
                guard let payload = message.body as? String,
                      let data = Data(base64Encoded: payload),
                      let code = String(data: data, encoding: .utf8) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

private final class PassthroughScrollWebView: WKWebView {}

private final class MarkdownHTMLViewCache {
    static let shared = MarkdownHTMLViewCache()

    private let lock = NSLock()
    private var heightByKey: [String: CGFloat] = [:]

    func height(for key: String) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return heightByKey[key]
    }

    func storeHeight(_ height: CGFloat, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        heightByKey[key] = height
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

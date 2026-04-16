import Foundation

struct WebSearchResult {
    let query: String
    let engine: String
    let results: [WebSearchItem]
    let elapsedMs: Int
    let warning: String?

    var visibleOutput: String {
        var lines: [String] = []
        lines.append("网页搜索结果（web_search）")
        lines.append("查询：\(query)")
        lines.append("引擎：\(engine)")
        if let warning, !warning.isEmpty {
            lines.append("提示：\(warning)")
        }
        if results.isEmpty {
            lines.append("未找到可用结果，可能被搜索引擎拦截或页面结构变化。")
            return lines.joined(separator: "\n")
        }
        for (index, item) in results.enumerated() {
            lines.append("\(index + 1). \(item.title)")
            lines.append("   URL: \(item.url)")
            if !item.snippet.isEmpty {
                lines.append("   摘要: \(item.snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }

    var modelOutput: String {
        let payload: [String: Any] = [
            "query": query,
            "engine": engine,
            "elapsed_ms": elapsedMs,
            "warning": warning ?? "",
            "results": results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet, "source": $0.source] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return visibleOutput
    }

    var followupContextMessage: String? {
        guard !results.isEmpty else { return nil }
        return "已完成网页搜索，可结合结果继续调用 web_fetch 抓取正文。"
    }
}

struct WebSearchItem {
    let title: String
    let url: String
    let snippet: String
    let source: String
}

final class WebSearchService {
    static let shared = WebSearchService()

    private let session: URLSession
    private let maxHTMLCharacters = 1_200_000

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ", "),
            "Accept-Encoding": "gzip, deflate, br"
        ]
        session = URLSession(configuration: configuration)
    }

    func search(query: String, limit: Int, engineHint: String?) async -> WebSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WebSearchResult(query: query, engine: "auto", results: [], elapsedMs: 0, warning: "搜索关键词为空")
        }

        let engines = enginesToTry(from: engineHint)
        let start = Date()
        var lastWarning: String?

        for engine in engines {
            let (html, warning) = await fetchHTML(for: engine, query: trimmed)
            if let warning { lastWarning = warning }
            guard let html else { continue }
            let clippedHTML = html.count > maxHTMLCharacters ? String(html.prefix(maxHTMLCharacters)) : html

            let items: [WebSearchItem]
            switch engine {
            case .bing:
                items = parseBingResults(from: clippedHTML)
            case .google:
                items = parseGoogleResults(from: clippedHTML)
            case .baidu:
                items = parseBaiduResults(from: clippedHTML)
            case .auto:
                items = []
            }

            if !items.isEmpty {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return WebSearchResult(
                    query: trimmed,
                    engine: engine.rawValue,
                    results: Array(items.prefix(limit)),
                    elapsedMs: elapsed,
                    warning: warning
                )
            }
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return WebSearchResult(
            query: trimmed,
            engine: engines.first?.rawValue ?? "auto",
            results: [],
            elapsedMs: elapsed,
            warning: lastWarning
        )
    }

    private func enginesToTry(from hint: String?) -> [SearchEngine] {
        guard let hint, !hint.isEmpty else {
            return [.bing, .baidu, .google]
        }
        if let engine = SearchEngine(rawValue: hint.lowercased()) {
            return engine == .auto ? [.bing, .baidu, .google] : [engine]
        }
        return [.bing, .baidu, .google]
    }

    private func fetchHTML(for engine: SearchEngine, query: String) async -> (String?, String?) {
        guard let url = searchURL(for: engine, query: query) else {
            return (nil, "搜索引擎地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (nil, "搜索响应无效")
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                return (nil, "搜索响应状态异常：\(httpResponse.statusCode)")
            }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            guard let html, !html.isEmpty else {
                return (nil, "搜索结果为空")
            }

            if looksLikeBlocked(html) {
                return (nil, "搜索引擎可能拦截了请求")
            }
            return (html, nil)
        } catch {
            return (nil, "搜索请求失败：\(error.localizedDescription)")
        }
    }

    private func searchURL(for engine: SearchEngine, query: String) -> URL? {
        switch engine {
        case .bing:
            var components = URLComponents(string: "https://www.bing.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            return components?.url
        case .google:
            let localeCode = Locale.current.language.languageCode?.identifier ?? "en"
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "hl", value: localeCode)
            ]
            return components?.url
        case .baidu:
            var components = URLComponents(string: "https://www.baidu.com/s")
            components?.queryItems = [URLQueryItem(name: "wd", value: query)]
            return components?.url
        case .auto:
            return nil
        }
    }

    private func parseBingResults(from html: String) -> [WebSearchItem] {
        let blocks = captureBlocks(pattern: #"(?is)<li class="b_algo".*?</li>"#, in: html)
        var items: [WebSearchItem] = []
        for block in blocks {
            guard let link = firstCapture(pattern: #"(?is)<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block) else {
                continue
            }
            let url = decodeLink(link.0, engine: .bing)
            let title = cleanText(link.1)
            guard !title.isEmpty, !url.isEmpty else { continue }
            let snippet = cleanText(firstCapture(pattern: #"(?is)<p[^>]*>(.*?)</p>"#, in: block)?.0 ?? "")
            items.append(WebSearchItem(title: title, url: url, snippet: snippet, source: "bing"))
        }
        return dedup(items)
    }

    private func parseGoogleResults(from html: String) -> [WebSearchItem] {
        let blocks = captureBlocks(pattern: #"(?is)<div class="g".*?</div>"#, in: html)
        var items: [WebSearchItem] = []
        for block in blocks {
            guard let link = firstCapture(pattern: #"(?is)<a[^>]+href="([^"]+)"[^>]*>.*?<h3[^>]*>(.*?)</h3>"#, in: block) else {
                continue
            }
            let url = decodeLink(link.0, engine: .google)
            let title = cleanText(link.1)
            guard !title.isEmpty, !url.isEmpty else { continue }
            let snippet = cleanText(
                firstCapture(pattern: #"(?is)<div class="VwiC3b[^"]*">(.*?)</div>"#, in: block)?.0 ??
                firstCapture(pattern: #"(?is)<span class="aCOpRe[^"]*">(.*?)</span>"#, in: block)?.0 ?? ""
            )
            items.append(WebSearchItem(title: title, url: url, snippet: snippet, source: "google"))
        }
        return dedup(items)
    }

    private func parseBaiduResults(from html: String) -> [WebSearchItem] {
        let blocks = captureBlocks(pattern: #"(?is)<div[^>]+class="result[^"]*".*?</div>"#, in: html)
        var items: [WebSearchItem] = []
        for block in blocks {
            guard let link = firstCapture(pattern: #"(?is)<h3[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block) else {
                continue
            }
            let url = decodeLink(link.0, engine: .baidu)
            let title = cleanText(link.1)
            guard !title.isEmpty, !url.isEmpty else { continue }
            let snippet = cleanText(
                firstCapture(pattern: #"(?is)<div class="c-abstract[^"]*">(.*?)</div>"#, in: block)?.0 ??
                firstCapture(pattern: #"(?is)<span class="content-right[^"]*">(.*?)</span>"#, in: block)?.0 ?? ""
            )
            items.append(WebSearchItem(title: title, url: url, snippet: snippet, source: "baidu"))
        }
        return dedup(items)
    }

    private func captureBlocks(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 0), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func firstCapture(pattern: String, in text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let range1 = Range(match.range(at: 1), in: text),
              let range2 = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[range1]), String(text[range2]))
    }

    private func cleanText(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = decodeHTMLEntities(withoutTags)
        return normalizeWhitespace(decoded)
    }

    private func normalizeWhitespace(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private func decodeLink(_ raw: String, engine: SearchEngine) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("/url?") || trimmed.hasPrefix("/url?q=") {
            if let components = URLComponents(string: "https://www.google.com\(trimmed)"),
               let target = components.queryItems?.first(where: { $0.name == "q" })?.value {
                return target.removingPercentEncoding ?? target
            }
        }

        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }

        switch engine {
        case .bing:
            return "https://www.bing.com" + trimmed
        case .google:
            return "https://www.google.com" + trimmed
        case .baidu:
            return "https://www.baidu.com" + trimmed
        case .auto:
            return trimmed
        }
    }

    private func dedup(_ items: [WebSearchItem]) -> [WebSearchItem] {
        var seen: Set<String> = []
        var result: [WebSearchItem] = []
        for item in items {
            guard !item.url.isEmpty else { continue }
            if seen.contains(item.url) { continue }
            seen.insert(item.url)
            result.append(item)
        }
        return result
    }

    private func looksLikeBlocked(_ html: String) -> Bool {
        let lowered = html.lowercased()
        if lowered.contains("captcha") || lowered.contains("unusual traffic") || lowered.contains("sorry") {
            return true
        }
        if lowered.contains("verify you are human") || lowered.contains("detected unusual") {
            return true
        }
        return false
    }
}

private enum SearchEngine: String {
    case auto
    case bing
    case google
    case baidu
}

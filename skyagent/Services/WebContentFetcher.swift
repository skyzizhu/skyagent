import Foundation
import AppKit
import CoreFoundation

final class WebContentFetcher {
    static let shared = WebContentFetcher()

    private let session: URLSession
    private let maxRawExtractCharacters = 32_000
    private let maxStructuredVisibleCharacters = 4_000
    private let maxStructuredModelCharacters = 6_500
    private let maxHeadingCount = 8
    private let maxKeyPointCount = 6
    private let maxChunkCount = 3
    private let maxChunkCharacters = 520
    private let maxHTMLCharacters = 1_800_000
    private let maxHTMLForAttributed = 900_000
    private let fetcherVersionMarker = "web_fetch/v4"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "User-Agent": "SkyAgent/1.0",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ", "),
            "Accept-Encoding": "gzip, deflate, br"
        ]
        session = URLSession(configuration: configuration)
    }

    func fetchResult(urlString: String) async -> WebFetchResult {
        guard let url = normalizedURL(from: urlString) else {
            let message = "[错误] (\(fetcherVersionMarker)) 无效 URL"
            return WebFetchResult(visibleOutput: message, modelOutput: message, followupContextMessage: nil)
        }

        if url.scheme?.lowercased() == "http" {
            let insecureResult = await fetchSingle(url)

            switch insecureResult {
            case .success(let page):
                return buildSuccessResult(for: page, requestedURL: urlString, sourceLabel: fetcherVersionMarker)

            case .failure(let httpFailure):
                let secureURL = upgradedHTTPSURL(from: url)
                let secureResult = await fetchSingle(secureURL)

                switch secureResult {
                case .success(let securePage):
                    return buildSuccessResult(for: securePage, requestedURL: urlString, sourceLabel: fetcherVersionMarker)
                case .failure(let httpsFailure):
                    let message = insecureAndSecureFailureMessage(
                        originalURL: url,
                        httpFailure: httpFailure,
                        secureURL: secureURL,
                        httpsFailure: httpsFailure
                    )
                    return WebFetchResult(visibleOutput: message, modelOutput: message, followupContextMessage: nil)
                }
            }
        }

        let result = await fetchSingle(url)
        switch result {
        case .success(let page):
            return buildSuccessResult(for: page, requestedURL: urlString, sourceLabel: fetcherVersionMarker)
        case .failure(let failure):
            let message = failure.userMessage(versionMarker: fetcherVersionMarker)
            return WebFetchResult(visibleOutput: message, modelOutput: message, followupContextMessage: nil)
        }
    }

    private func fetchSingle(_ url: URL) async -> Result<FetchedWebPage, WebFetchFailure> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                return .failure(.httpStatus(code: httpResponse.statusCode))
            }

            guard let rawHTML = decodeHTML(data: data, response: httpResponse), !rawHTML.isEmpty else {
                return .failure(.decodeFailed)
            }

            let html = boundedHTML(rawHTML)
            let metaDescription = extractMetaDescription(from: html)
            let contentHTML = extractPrimaryContentHTML(from: html)
            let title = extractTitle(from: html) ?? extractTitleFromContent(contentHTML)
            let extractedText = extractVisibleText(from: contentHTML)
            let fallbackText = contentHTML == html ? extractedText : extractVisibleText(from: html)
            let primaryText = extractedText.isEmpty ? fallbackText : extractedText
            guard !primaryText.isEmpty else {
                return .failure(.emptyContent)
            }

            let headings = extractHeadings(from: contentHTML).prefix(maxHeadingCount)
            let paragraphs = cleanedParagraphs(from: primaryText)
            let finalParagraphs = paragraphs.isEmpty ? cleanedParagraphs(from: fallbackText) : paragraphs
            guard !finalParagraphs.isEmpty else {
                return .failure(.emptyContent)
            }

            let rawText = finalParagraphs.joined(separator: "\n\n")
            let truncatedRawText = truncate(rawText, limit: maxRawExtractCharacters)

            return .success(
                FetchedWebPage(
                    finalURL: httpResponse.url ?? url,
                    title: title,
                    metaDescription: metaDescription,
                    headings: Array(headings),
                    paragraphs: finalParagraphs,
                    rawText: truncatedRawText
                )
            )
        } catch {
            return .failure(mapError(error))
        }
    }

    private func normalizedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        if let url = URL(string: "https://\(trimmed)") {
            return url
        }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return nil
        }
        return URL(string: encoded)
    }

    private func upgradedHTTPSURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    private func decodeHTML(data: Data, response: HTTPURLResponse) -> String? {
        if let encodingName = response.textEncodingName,
           let encoding = stringEncoding(fromIANACharset: encodingName),
           let html = String(data: data, encoding: encoding),
           !html.isEmpty {
            return html
        }

        if let metaEncoding = htmlMetaCharset(in: data),
           let html = String(data: data, encoding: metaEncoding),
           !html.isEmpty {
            return html
        }

        let fallbackEncodings: [String.Encoding] = [
            .utf8,
            .unicode,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
            .windowsCP1252,
            .gb18030,
            .gb_18030_2000,
            .big5
        ]

        for encoding in fallbackEncodings {
            if let html = String(data: data, encoding: encoding), !html.isEmpty {
                return html
            }
        }

        return nil
    }

    private func extractVisibleText(from html: String) -> String {
        let sanitizedHTML = html
            .replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<style\\b[^>]*>.*?</style>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<noscript\\b[^>]*>.*?</noscript>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<(?:nav|footer|header|aside|form|svg|canvas|figure|picture|video|audio)\\b[^>]*>.*?</(?:nav|footer|header|aside|form|svg|canvas|figure|picture|video|audio)>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p\\s*>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</div\\s*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</li\\s*>", with: "\n", options: .regularExpression)

        if sanitizedHTML.count <= maxHTMLForAttributed,
           let data = sanitizedHTML.data(using: .utf8),
           let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
           ) {
            let normalized = normalizeWhitespace(in: attributed.string)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let fallback = sanitizedHTML.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return normalizeWhitespace(in: fallback)
    }

    private func extractTitle(from html: String) -> String? {
        let patterns = [
            #"(?is)<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']"#,
            #"(?is)<meta\s+name=["']title["']\s+content=["']([^"']+)["']"#,
            #"(?is)<title[^>]*>(.*?)</title>"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: html) {
                let title = html[range]
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return title
                }
            }
        }

        return nil
    }

    private func extractMetaDescription(from html: String) -> String? {
        let patterns = [
            #"(?is)<meta\s+name=["']description["']\s+content=["']([^"']+)["']"#,
            #"(?is)<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: html) {
                let description = html[range]
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !description.isEmpty {
                    return description
                }
            }
        }

        return nil
    }

    private func extractPrimaryContentHTML(from html: String) -> String {
        let candidates = contentCandidates(from: html)
        guard !candidates.isEmpty else { return html }

        let scored = candidates
            .map { candidate -> (String, Int) in
                let text = extractVisibleText(from: candidate.html)
                let paragraphCount = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                let keywordBonus = candidate.priority
                let score = min(text.count, 20_000) + paragraphCount * 120 + keywordBonus
                return (candidate.html, score)
            }
            .sorted { $0.1 > $1.1 }

        guard let best = scored.first, best.1 >= 800 else {
            return html
        }
        return best.0
    }

    private func contentCandidates(from html: String) -> [HTMLCandidate] {
        let patterns: [(pattern: String, priority: Int)] = [
            (#"(?is)<article\b[^>]*>(.*?)</article>"#, 900),
            (#"(?is)<main\b[^>]*>(.*?)</main>"#, 850),
            (#"(?is)<section\b[^>]*(?:id|class)=["'][^"']*(?:article|content|post|entry|main|body|markdown|richtext|doc|document|prose|readme|page|detail)[^"']*["'][^>]*>(.*?)</section>"#, 760),
            (#"(?is)<div\b[^>]*(?:id|class)=["'][^"']*(?:article|content|post|entry|main|body|markdown|richtext|doc|document|prose|readme|page|detail)[^"']*["'][^>]*>(.*?)</div>"#, 700),
            (#"(?is)<div\b[^>]*(?:id|class)=["'][^"']*(?:post-content|entry-content|article-content|main-content|content-body|markdown-body|post-body|rich-text|content-main)[^"']*["'][^>]*>(.*?)</div>"#, 780)
        ]

        var candidates: [HTMLCandidate] = []
        for item in patterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                guard match.numberOfRanges >= 2,
                      let range = Range(match.range(at: 1), in: html) else { continue }
                let snippet = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard snippet.count >= 200 else { continue }
                candidates.append(HTMLCandidate(html: snippet, priority: item.priority))
            }
        }

        if candidates.isEmpty {
            candidates.append(HTMLCandidate(html: html, priority: 0))
        }

        return candidates
    }

    private func extractHeadings(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<h([1-4])\b[^>]*>(.*?)</h\1>"#) else {
            return []
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var headings: [String] = []
        var seen = Set<String>()

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let range = Range(match.range(at: 2), in: html) else { continue }
            let raw = String(html[range])
            let text = extractVisibleText(from: raw)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { continue }
            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            headings.append(text)
            seen.insert(key)
        }

        return headings
    }

    private func normalizeWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t\\f\\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        return "\(prefix)\n\n[内容已截断，仅显示前 \(limit) 个字符]"
    }

    private func boundedHTML(_ html: String) -> String {
        guard html.count > maxHTMLCharacters else { return html }
        return String(html.prefix(maxHTMLCharacters))
    }

    private func buildSuccessResult(for page: FetchedWebPage, requestedURL: String, sourceLabel: String) -> WebFetchResult {
        let summary = preferredSummary(for: page)
        let headings = Array(page.headings.prefix(maxHeadingCount))
        let bulletLines = keyBulletLines(from: page.paragraphs, limit: maxKeyPointCount)
        let chunks = buildContentChunks(from: page.paragraphs, limit: maxChunkCount, chunkLimit: maxChunkCharacters)

        let requested = requestedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURLString = page.finalURL.absoluteString
        let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        var visibleSections: [String] = ["网页抓取成功（\(sourceLabel)）"]
        visibleSections.append("请求地址：\(requested)")
        if finalURLString != requested {
            visibleSections.append("最终地址：\(finalURLString)")
        }
        if let title, !title.isEmpty {
            visibleSections.append("标题：\(title)")
        }
        if let metaDescription = page.metaDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !metaDescription.isEmpty,
           metaDescription != summary {
            visibleSections.append("页面描述：\n\(metaDescription)")
        }
        if !summary.isEmpty {
            visibleSections.append("摘要：\n\(summary)")
        }
        if !headings.isEmpty {
            visibleSections.append("结构标题：\n" + headings.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !bulletLines.isEmpty {
            visibleSections.append("关键信息：\n" + bulletLines.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !chunks.isEmpty {
            let excerptText = chunks.enumerated().map { index, chunk in
                "[片段\(index + 1)]\n\(chunk)"
            }.joined(separator: "\n\n")
            visibleSections.append("正文片段：\n\(excerptText)")
        }

        let visibleOutput = truncate(
            visibleSections.joined(separator: "\n\n"),
            limit: maxStructuredVisibleCharacters
        )

        let modelBullets = bulletLines.prefix(5).map { "- \($0)" }.joined(separator: "\n")
        let modelHeadings = headings.prefix(6).map { "- \($0)" }.joined(separator: "\n")
        let modelChunks = chunks.enumerated().map { index, chunk in
            "[片段\(index + 1)]\n\(chunk)"
        }.joined(separator: "\n\n")
        let modelOutput = [
            "网页抓取成功。以下是已经清洗过的结构化网页摘要，请直接基于这些信息继续，不要再次抓取同一个 URL，也不要复述整页原文。",
            "请求地址：\(requested)",
            finalURLString != requested ? "最终地址：\(finalURLString)" : nil,
            (title?.isEmpty == false) ? "标题：\(title!)" : nil,
            (page.metaDescription?.isEmpty == false) ? "页面描述：\n\(page.metaDescription!)" : nil,
            !summary.isEmpty ? "摘要：\n\(summary)" : nil,
            !modelHeadings.isEmpty ? "结构标题：\n\(modelHeadings)" : nil,
            !modelBullets.isEmpty ? "关键信息：\n\(modelBullets)" : nil,
            !modelChunks.isEmpty ? "正文片段：\n\(modelChunks)" : nil
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")

        let followupHint = """
        网页内容已经完成抓取、去噪和结构化提取。后续回答时请优先基于“标题、页面描述、摘要、结构标题、关键信息、正文片段”继续。
        如果用户要做总结、信息图、结构梳理、生图提示词，请直接基于这份结构化摘要继续，不要再次抓取同一个 URL，也不要复述整页原文。
        """

        return WebFetchResult(
            visibleOutput: visibleOutput,
            modelOutput: truncate(modelOutput, limit: maxStructuredModelCharacters),
            followupContextMessage: followupHint
        )
    }

    private func cleanedParagraphs(from text: String) -> [String] {
        let rawParagraphs = text
            .components(separatedBy: "\n\n")
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let noiseTokens = [
            "skip to content", "sponsor", "copyright", "all rights reserved",
            "link", "上一篇", "下一篇", "返回顶部", "京icp", "menu", "search",
            "相关阅读", "推荐阅读", "上一篇：", "下一篇：", "目录", "标签", "分类"
        ]

        var seen = Set<String>()
        return rawParagraphs.compactMap { paragraph in
            let lower = paragraph.lowercased()
            if paragraph.count < 12 { return nil }
            if noiseTokens.contains(where: { lower.contains($0) }) { return nil }
            let normalizedKey = lower.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if seen.contains(normalizedKey) { return nil }
            seen.insert(normalizedKey)
            return paragraph
        }
    }

    private func keyBulletLines(from paragraphs: [String], limit: Int) -> [String] {
        var bullets: [String] = []
        for paragraph in paragraphs {
            guard bullets.count < limit else { break }
            let cleaned = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 24 else { continue }
            bullets.append(String(cleaned.prefix(140)))
        }
        return bullets
    }

    private func preferredSummary(for page: FetchedWebPage) -> String {
        if let metaDescription = page.metaDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !metaDescription.isEmpty {
            return String(metaDescription.prefix(260))
        }

        let summaryParagraphs = Array(page.paragraphs.prefix(2))
        let summary = summaryParagraphs.joined(separator: "\n\n")
        return String(summary.prefix(420))
    }

    private func buildContentChunks(from paragraphs: [String], limit: Int, chunkLimit: Int) -> [String] {
        guard !paragraphs.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let paragraphText = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraphText.isEmpty else { continue }
            let candidate = current.isEmpty ? paragraphText : "\(current)\n\n\(paragraphText)"
            if candidate.count <= chunkLimit {
                current = candidate
                continue
            }

            if !current.isEmpty {
                chunks.append(current)
                if chunks.count >= limit { break }
            }

            current = String(paragraphText.prefix(chunkLimit))
        }

        if chunks.count < limit, !current.isEmpty {
            chunks.append(current)
        }

        return Array(chunks.prefix(limit))
    }

    private func htmlMetaCharset(in data: Data) -> String.Encoding? {
        let probe = data.prefix(4096)
        guard let ascii = String(data: probe, encoding: .ascii) else { return nil }

        let patterns = [
            #"(?i)charset\s*=\s*["']?\s*([A-Za-z0-9_\-]+)"#,
            #"(?i)<meta[^>]+content=["'][^"']*charset=([A-Za-z0-9_\-]+)[^"']*["']"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: ascii, range: NSRange(ascii.startIndex..., in: ascii)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: ascii) {
                return stringEncoding(fromIANACharset: String(ascii[range]))
            }
        }

        return nil
    }

    private func stringEncoding(fromIANACharset charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }

    private func extractTitleFromContent(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<h1\b[^>]*>(.*?)</h1>"#) else {
            return nil
        }
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let raw = String(html[range])
        let text = extractVisibleText(from: raw)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func mapError(_ error: Error) -> WebFetchFailure {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timedOut
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return .appTransportSecurityBlocked
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired,
                 NSURLErrorCannotLoadFromNetwork:
                return .tlsFailure(detail: nsError.localizedDescription)
            case NSURLErrorCannotFindHost:
                return .cannotFindHost
            case NSURLErrorCannotConnectToHost:
                return .cannotConnectToHost
            case NSURLErrorNetworkConnectionLost:
                return .networkConnectionLost
            case NSURLErrorNotConnectedToInternet:
                return .notConnectedToInternet
            default:
                break
            }
        }

        let localized = nsError.localizedDescription.lowercased()
        if localized.contains("app transport security") || localized.contains("secure connection") {
            return .appTransportSecurityBlocked
        }
        if localized.contains("ssl") || localized.contains("tls") {
            return .tlsFailure(detail: nsError.localizedDescription)
        }

        return .other(detail: nsError.localizedDescription)
    }

    private func insecureAndSecureFailureMessage(
        originalURL: URL,
        httpFailure: WebFetchFailure,
        secureURL: URL,
        httpsFailure: WebFetchFailure
    ) -> String {
        """
        [错误] (\(fetcherVersionMarker)) 网页抓取失败。
        已先尝试原始 HTTP 地址：\(originalURL.absoluteString)
        HTTP 结果：\(httpFailure.shortDescription)

        又尝试了 HTTPS 地址：\(secureURL.absoluteString)
        HTTPS 结果：\(httpsFailure.shortDescription)
        """
    }
}

struct WebFetchResult {
    let visibleOutput: String
    let modelOutput: String
    let followupContextMessage: String?
}

private struct FetchedWebPage {
    let finalURL: URL
    let title: String?
    let metaDescription: String?
    let headings: [String]
    let paragraphs: [String]
    let rawText: String
}

private struct HTMLCandidate {
    let html: String
    let priority: Int
}

private enum WebFetchFailure: Error {
    case timedOut
    case appTransportSecurityBlocked
    case tlsFailure(detail: String)
    case httpStatus(code: Int)
    case invalidResponse
    case decodeFailed
    case emptyContent
    case cannotFindHost
    case cannotConnectToHost
    case networkConnectionLost
    case notConnectedToInternet
    case other(detail: String)

    var shortDescription: String {
        switch self {
        case .timedOut:
            return "请求超时"
        case .appTransportSecurityBlocked:
            return "系统安全策略阻止了不安全连接"
        case .tlsFailure:
            return "TLS 安全连接失败"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .invalidResponse:
            return "响应无效"
        case .decodeFailed:
            return "网页内容解码失败"
        case .emptyContent:
            return "网页没有可提取的正文"
        case .cannotFindHost:
            return "找不到主机"
        case .cannotConnectToHost:
            return "无法连接到目标主机"
        case .networkConnectionLost:
            return "网络连接中断"
        case .notConnectedToInternet:
            return "当前网络不可用"
        case .other(let detail):
            return detail
        }
    }

    func userMessage(versionMarker: String) -> String {
        switch self {
        case .timedOut:
            return "[超时] (\(versionMarker)) 网页请求超时。"
        case .appTransportSecurityBlocked:
            return "[错误] (\(versionMarker)) 当前应用的系统安全策略禁止抓取不安全的 HTTP 页面，请改用 HTTPS。"
        case .tlsFailure:
            return "[错误] (\(versionMarker)) TLS 错误导致安全连接失败。目标站点可能没有正确配置 HTTPS / 证书链 / 反向代理。"
        case .httpStatus(let code):
            return "[错误] (\(versionMarker)) 网页请求失败，HTTP \(code)。"
        case .invalidResponse:
            return "[错误] (\(versionMarker)) 目标站点返回了无效响应。"
        case .decodeFailed:
            return "[错误] (\(versionMarker)) 网页内容抓取成功，但页面编码无法正确解析。"
        case .emptyContent:
            return "[错误] (\(versionMarker)) 网页抓取成功，但没有提取到可读正文。"
        case .cannotFindHost:
            return "[错误] (\(versionMarker)) 无法解析目标域名。"
        case .cannotConnectToHost:
            return "[错误] (\(versionMarker)) 无法连接到目标站点。"
        case .networkConnectionLost:
            return "[错误] (\(versionMarker)) 与目标站点的网络连接中途中断。"
        case .notConnectedToInternet:
            return "[错误] (\(versionMarker)) 当前设备未连接互联网。"
        case .other(let detail):
            return "[错误] (\(versionMarker)) \(detail)"
        }
    }
}

private extension String.Encoding {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let gb_18030_2000 = String.Encoding.gb18030
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
}

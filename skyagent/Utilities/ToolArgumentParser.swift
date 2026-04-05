import Foundation

enum ToolArgumentParser {
    static func parse(arguments rawArguments: String, for tool: ToolDefinition.ToolName? = nil) -> [String: Any]? {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let object = parseJSONObject(from: trimmed) {
            return object
        }

        if let stringObject = parseStringWrappedJSONObject(from: trimmed) {
            return stringObject
        }

        if let codeFenceContent = stripCodeFence(from: trimmed) {
            if let object = parseJSONObject(from: codeFenceContent) {
                return object
            }
            if let stringObject = parseStringWrappedJSONObject(from: codeFenceContent) {
                return stringObject
            }
        }

        if let tool {
            switch tool {
            case .writeFile, .writeDOCX, .exportPDF, .exportDOCX:
                return recoverPathAndContentArguments(from: trimmed, contentKey: "content")
            case .writeMultipleFiles:
                return recoverMultipleFileArguments(from: trimmed)
            case .replaceDOCXSection, .insertDOCXSection:
                return recoverDOCXSectionArguments(from: trimmed)
            default:
                return nil
            }
        }

        return nil
    }

    private static func parseJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let object = json as? [String: Any] {
            return object
        }

        if let string = json as? String {
            return parse(arguments: string, for: nil)
        }

        return nil
    }

    private static func parseStringWrappedJSONObject(from text: String) -> [String: Any]? {
        guard let decoded = decodeJSONStringFragment(text) else { return nil }
        return parseJSONObject(from: decoded)
    }

    private static func stripCodeFence(from text: String) -> String? {
        guard text.hasPrefix("```"), text.hasSuffix("```") else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return nil }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func recoverPathAndContentArguments(from text: String, contentKey: String) -> [String: Any]? {
        guard let path = extractField("path", from: text),
              let content = extractTrailingField(contentKey, from: text) else {
            return nil
        }

        var result: [String: Any] = [
            "path": path,
            contentKey: content
        ]

        if let overwrite = extractBoolField("overwrite", from: text) {
            result["overwrite"] = overwrite
        }

        if let title = extractField("title", from: text) {
            result["title"] = title
        }

        return result
    }

    private static func recoverDOCXSectionArguments(from text: String) -> [String: Any]? {
        guard let path = extractField("path", from: text),
              let sectionTitle = extractField("section_title", from: text),
              let content = extractTrailingField("content", from: text) else {
            return nil
        }

        var result: [String: Any] = [
            "path": path,
            "section_title": sectionTitle,
            "content": content
        ]

        if let afterTitle = extractField("after_section_title", from: text) {
            result["after_section_title"] = afterTitle
        }

        if let appendIfMissing = extractBoolField("append_if_missing", from: text) {
            result["append_if_missing"] = appendIfMissing
        }

        return result
    }

    private static func recoverMultipleFileArguments(from text: String) -> [String: Any]? {
        let searchText: String
        if let filesArrayStart = firstMatchRange(patterns: [#""files"\s*:\s*\["#], in: text) {
            searchText = String(text[filesArrayStart.lowerBound...])
        } else {
            searchText = text
        }

        let files = recoverFileEntries(from: searchText)
        guard !files.isEmpty else { return nil }
        return ["files": files]
    }

    private static func recoverFileEntries(from text: String) -> [[String: Any]] {
        guard let regex = try? NSRegularExpression(
            pattern: #""path"\s*:\s*"((?:\\.|[^"\\])*)""#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        var files: [[String: Any]] = []

        for (index, match) in matches.enumerated() {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let pathRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let path = decodeJSONStringLikeFragment(String(text[pathRange]))
            let sliceStart = fullRange.lowerBound
            let sliceEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range(at: 0), in: text) {
                sliceEnd = nextRange.lowerBound
            } else {
                sliceEnd = text.endIndex
            }

            let slice = String(text[sliceStart..<sliceEnd])
            guard let content = extractTrailingField("content", from: slice) else {
                continue
            }

            files.append([
                "path": path,
                "content": content
            ])
        }

        return files
    }

    private static func extractField(_ field: String, from text: String) -> String? {
        let patterns = [
            #""\#(field)"\s*:\s*"((?:\\.|[^"\\])*)""#,
            #""\#(field)"\s*:\s*'((?:\\.|[^'\\])*)'"#,
            #"\b\#(field)\b\s*[:=]\s*"((?:\\.|[^"\\])*)""#,
            #"\b\#(field)\b\s*[:=]\s*'((?:\\.|[^'\\])*)'"#
        ]

        for pattern in patterns {
            if let match = firstCapture(pattern: pattern, in: text) {
                return decodeJSONStringLikeFragment(match)
            }
        }
        return nil
    }

    private static func extractBoolField(_ field: String, from text: String) -> Bool? {
        let patterns = [
            #""\#(field)"\s*:\s*(true|false)"#,
            #"\b\#(field)\b\s*[:=]\s*(true|false)"#
        ]

        for pattern in patterns {
            if let match = firstCapture(pattern: pattern, in: text) {
                return match == "true"
            }
        }
        return nil
    }

    private static func extractTrailingField(_ field: String, from text: String) -> String? {
        let patterns = [
            #""\#(field)"\s*:"#,
            #"\b\#(field)\b\s*[:=]"#
        ]

        guard let range = firstMatchRange(patterns: patterns, in: text) else { return nil }
        var trailing = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        if trailing.hasPrefix("\"") || trailing.hasPrefix("'") {
            let quote = trailing.removeFirst()
            trailing = trimTrailingObjectWrapper(from: trailing)
            if trailing.last == quote {
                trailing.removeLast()
            }
        } else {
            trailing = trimTrailingObjectWrapper(from: trailing)
        }

        return decodeJSONStringLikeFragment(trailing)
    }

    private static func trimTrailingObjectWrapper(from text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasSuffix("}") {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.hasSuffix(",") {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func firstMatchRange(patterns: [String], in text: String) -> Range<String.Index>? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, options: [], range: nsRange),
                  let range = Range(match.range(at: 0), in: text) else {
                continue
            }
            return range
        }

        return nil
    }

    private static func decodeJSONStringLikeFragment(_ text: String) -> String {
        if let decoded = decodeJSONStringFragment("\"\(escapeForJSONString(text))\"") {
            return decoded
        }

        return text
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\\t"#, with: "\t")
            .replacingOccurrences(of: #"\\r"#, with: "\r")
            .replacingOccurrences(of: #"\\/"#, with: "/")
            .replacingOccurrences(of: #"\\\\"#, with: "\\")
    }

    private static func decodeJSONStringFragment(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? String else {
            return nil
        }
        return decoded
    }

    private static func escapeForJSONString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

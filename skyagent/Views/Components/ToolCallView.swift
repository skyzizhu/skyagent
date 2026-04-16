import SwiftUI
import Foundation
import AppKit

struct ToolCallView: View {
    let toolExecution: ToolExecutionRecord
    let result: String
    @State private var isExpanded = false
    private let expandedPreviewLimit = 24_000

    private var displayToolName: String {
        ChatStatusComposer.friendlyToolTitle(for: toolExecution.name)
    }

    private var isFailure: Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[错误]") || trimmed.hasPrefix("⚠️")
    }

    private var accentColor: Color {
        isFailure ? .orange : .secondary
    }

    private var titleIcon: String {
        isFailure ? "exclamationmark.triangle" : "chevron.left.forwardslash.chevron.right"
    }

    private var resultPreview: String? {
        let ignoredPrefixes = [
            "工具:",
            "总长度:",
            "总行数:",
            "样例：",
            "摘要预览：",
            "前若干项样例："
        ]

        let normalized = result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                return !ignoredPrefixes.contains { line.hasPrefix($0) }
            }
            .prefix(2)
            .joined(separator: "  ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(180))
    }

    private var previewMeta: String? {
        guard result.count > expandedPreviewLimit else { return nil }
        return L10n.tr("chat.tool.preview_meta", expandedPreviewLimit.formatted(), result.count.formatted())
    }

    private func visibleBlockText(_ text: String) -> String {
        guard text.count > expandedPreviewLimit else { return text }
        return String(text.prefix(expandedPreviewLimit))
            + "\n\n"
            + L10n.tr("chat.tool.preview_truncated", expandedPreviewLimit.formatted(), text.count.formatted())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: titleIcon)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accentColor)

                            Text(verbatim: displayToolName)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.88))

                            Text(isFailure ? L10n.tr("chat.tool.badge.failure") : L10n.tr("chat.detail.tool"))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(accentColor.opacity(0.08), in: Capsule())

                            Spacer()

                            Text(isExpanded ? L10n.tr("chat.tool.collapse") : L10n.tr("common.details"))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)

                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }

                        if let resultPreview, !isExpanded {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(resultPreview)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.9))
                                    .lineLimit(2)

                                if let previewMeta {
                                    Text(previewMeta)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !toolExecution.arguments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionLabel(L10n.tr("settings.section.parameters"))
                            codeBlock(visibleBlockText(toolExecution.arguments))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel(L10n.tr("chat.tool.result_section"))
                        codeBlock(visibleBlockText(result))
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 1)
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 148)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.013))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.03), lineWidth: 0.7)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }
}

struct ToolBatchSummaryView: View {
    let messages: [Message]
    @State private var isExpanded = false

    private struct BatchDetailItem: Identifiable {
        let id: UUID
        let title: String
        let subtitle: String?
        let isFailure: Bool
        let path: String?
    }

    private var rawToolName: String {
        messages.first?.toolExecution?.name ?? "tool"
    }

    private var toolName: String {
        ChatStatusComposer.friendlyToolTitle(for: rawToolName)
    }

    private var count: Int {
        messages.count
    }

    private var hasFailure: Bool {
        messages.contains { message in
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[错误]") || trimmed.hasPrefix("⚠️")
        }
    }

    private var successCount: Int {
        messages.filter { message in
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(trimmed.hasPrefix("[错误]") || trimmed.hasPrefix("⚠️"))
        }.count
    }

    private var failureCount: Int {
        max(0, count - successCount)
    }

    private var accentColor: Color {
        hasFailure ? .orange : .secondary
    }

    private var affectedPaths: [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for message in messages {
            for raw in extractedPaths(from: message) {
                if seen.insert(raw).inserted {
                    paths.append(raw)
                }
            }
        }

        return paths
    }

    private var affectedItemCount: Int {
        max(affectedPaths.count, count)
    }

    private var summaryLine: String {
        switch rawToolName {
        case "write_file":
            return L10n.tr("chat.tool.batch.write_file", String(affectedItemCount))
        case "write_assistant_content_to_file":
            return L10n.tr("chat.tool.batch.write_file", String(affectedItemCount))
        case "move_paths":
            return L10n.tr("chat.tool.batch.move_paths", String(affectedItemCount))
        case "delete_paths":
            return L10n.tr("chat.tool.batch.delete_paths", String(affectedItemCount))
        default:
            return ""
        }
    }

    private var resultCountLine: String {
        if failureCount > 0 {
            return L10n.tr("chat.tool.batch.result_counts_with_failure", String(successCount), String(failureCount))
        }
        return L10n.tr("chat.tool.batch.result_counts_success_only", String(successCount))
    }

    private var pathPreviewLine: String? {
        let names = affectedPaths
            .prefix(3)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.isEmpty }

        guard !names.isEmpty else { return nil }
        if affectedPaths.count > names.count {
            return names.joined(separator: "、") + L10n.tr("chat.tool.batch.more_suffix", String(affectedPaths.count - names.count))
        }
        return names.joined(separator: "、")
    }

    private var previewLines: [String] {
        messages
            .compactMap { message in
                message.content
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
            }
            .prefix(3)
            .map { String($0.prefix(140)) }
    }

    private var detailItems: [BatchDetailItem] {
        messages.map { message in
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isFailure = trimmed.hasPrefix("[错误]") || trimmed.hasPrefix("⚠️")
            let path = extractedPaths(from: message).first
            let title = path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? firstNonEmptyLine(in: message.content)
                ?? toolName
            let subtitle = buildSubtitle(for: message.content, path: path)
            return BatchDetailItem(id: message.id, title: title, subtitle: subtitle, isFailure: isFailure, path: path)
        }
    }

    private func firstNonEmptyLine(in text: String) -> String? {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(140)) }
    }

    private func buildSubtitle(for text: String, path: String?) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let path {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            let remaining = lines.first(where: { !$0.contains(path) && !$0.contains(filename) })
            return remaining.map { String($0.prefix(160)) }
        }

        return lines.dropFirst().first.map { String($0.prefix(160)) }
    }

    private func extractedPaths(from message: Message) -> [String] {
        let structured = structuredPaths(toolName: message.toolExecution?.name, arguments: message.toolExecution?.arguments)
        let fallback = fallbackExtractedPaths(from: message.content)
        let combined = (fallback + structured).reduce(into: [String]()) { partialResult, path in
            if !partialResult.contains(path) {
                partialResult.append(path)
            }
        }
        return combined
    }

    private func structuredPaths(toolName: String?, arguments: String?) -> [String] {
        guard let toolName,
              let arguments,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        switch toolName {
        case "write_file", "write_assistant_content_to_file", "read_file", "write_docx", "write_xlsx", "export_pdf", "export_docx", "export_xlsx", "preview_image":
            return [stringValue(json["path"])].compactMap { $0 }
        case "write_multiple_files":
            return (json["files"] as? [[String: Any]] ?? []).compactMap { stringValue($0["path"]) }
        case "move_paths":
            return (json["items"] as? [[String: Any]] ?? []).flatMap { item in
                [stringValue(item["source_path"]), stringValue(item["destination_path"])].compactMap { $0 }
            }
        case "delete_paths":
            return (json["paths"] as? [String]) ?? []
        default:
            return []
        }
    }

    private func fallbackExtractedPaths(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"/[^\n]+"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            let raw = nsText.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[](){}.,;:!?'\""))
            guard raw.hasPrefix("/") else { return nil }
            return raw
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: hasFailure ? "exclamationmark.triangle" : "square.stack.3d.up")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accentColor)

                            Text(verbatim: toolName)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.88))

                            Spacer()

                            Text(isExpanded ? L10n.tr("chat.tool.collapse") : L10n.tr("common.details"))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)

                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            if !summaryLine.isEmpty {
                                Text(summaryLine)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.9))
                            }
                            Text(resultCountLine)
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(failureCount > 0 ? Color.orange.opacity(0.88) : Color.secondary.opacity(0.68))
                            if let pathPreviewLine {
                                Text(pathPreviewLine)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            } else if let first = previewLines.first {
                                Text(first)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(detailItems.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.isFailure ? .orange : .green)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(item.title)")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }

                                if let path = item.path, FileManager.default.fileExists(atPath: path) {
                                    HStack(spacing: 10) {
                                        Button(L10n.tr("chat.preview.view")) {
                                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)

                                        Button(L10n.tr("chat.preview.reveal")) {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .contextMenu {
                            if let path = item.path, FileManager.default.fileExists(atPath: path) {
                                Button(L10n.tr("chat.preview.view")) {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                }

                                Button(L10n.tr("chat.preview.reveal_in_finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                            }
                        }
                    }

                    if count > detailItems.count {
                        Text(L10n.tr("chat.tool.batch.remaining", String(count - detailItems.count)))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 1)
    }
}

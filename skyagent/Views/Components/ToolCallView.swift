import SwiftUI

struct ToolCallView: View {
    let toolExecution: ToolExecutionRecord
    let result: String
    @State private var isExpanded = false
    private let expandedPreviewLimit = 12_000

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
        let normalized = result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: "  ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(180))
    }

    private var previewMeta: String? {
        guard result.count > expandedPreviewLimit else { return nil }
        return "预览 \(expandedPreviewLimit.formatted()) / \(result.count.formatted()) 字符"
    }

    private func visibleBlockText(_ text: String) -> String {
        guard text.count > expandedPreviewLimit else { return text }
        return text.prefix(expandedPreviewLimit) + "\n\n[预览已截断，仅显示前 \(expandedPreviewLimit) 个字符，总长度 \(text.count) 个字符]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(accentColor.opacity(isFailure ? 0.7 : 0.45))
                        .frame(width: 2, height: isExpanded ? 34 : 18)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: titleIcon)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accentColor)

                            Text(verbatim: toolExecution.name)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.88))

                            Text(isFailure ? "异常" : "工具")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(accentColor.opacity(0.08), in: Capsule())

                            Spacer()

                            Text(isExpanded ? "收起" : "详情")
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
                            sectionLabel("参数")
                            codeBlock(visibleBlockText(toolExecution.arguments))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("结果")
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

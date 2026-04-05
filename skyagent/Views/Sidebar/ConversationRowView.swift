import SwiftUI

struct ConversationRowView: View {
    let conv: Conversation
    let isCurrent: Bool
    let onRename: () -> Void
    let onClear: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var previewText: String {
        let lastVisible = conv.messages.last(where: { $0.isVisibleInTranscript })
            ?? conv.messages.last(where: { $0.hiddenFromTranscript != true && $0.role != .system })
            ?? conv.messages.last(where: { $0.role != .system })
        guard let last = lastVisible else { return L10n.tr("conversation.empty") }
        let text = last.content
            .replacingOccurrences(of: "🔧 执行工具: ", with: "🔧 ")
            .replacingOccurrences(of: "📋 结果:", with: "")
            .replacingOccurrences(of: "```", with: "")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .first ?? ""
        return String(text.prefix(50))
    }

    private var timeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conv.lastActiveAt, relativeTo: Date())
    }

    private var modeText: String {
        conv.filePermissionMode == .sandbox ? L10n.tr("permission.sandbox") : L10n.tr("permission.open")
    }

    private var modeColor: Color {
        conv.filePermissionMode == .sandbox ? .blue : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(isCurrent ? Color.primary.opacity(0.78) : modeColor.opacity(isHovered ? 0.42 : 0.26))
                .frame(width: 3, height: 34)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(conv.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(previewText)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(modeText)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(modeColor.opacity(0.88))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(modeColor.opacity(0.08), in: Capsule())

                    Text(timeText)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize()

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
        .shadow(color: shadowColor, radius: isCurrent ? 10 : 4, x: 0, y: 2)
        .animation(.easeOut(duration: 0.16), value: isCurrent)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(L10n.tr("common.rename")) {
                onRename()
            }
            Button(L10n.tr("conversation.clear_messages")) {
                onClear()
            }
            Divider()
            Button(L10n.tr("common.delete"), role: .destructive) {
                onDelete()
            }
        }
    }

    private var backgroundFill: Color {
        if isCurrent {
            return Color.primary.opacity(0.08)
        }
        if isHovered {
            return Color.primary.opacity(0.04)
        }
        return Color.clear
    }

    private var borderColor: Color {
        if isCurrent {
            return Color.primary.opacity(0.1)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }

    private var shadowColor: Color {
        Color.black.opacity(isCurrent ? 0.035 : 0.01)
    }
}

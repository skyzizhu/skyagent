import SwiftUI

struct ConversationRowView: View {
    let row: SidebarViewModel.ConversationRowSnapshot
    let isCurrent: Bool

    @State private var isHovered = false

    private var modeText: String {
        let conv = row.conversation
        return conv.filePermissionMode == .sandbox ? L10n.tr("permission.sandbox") : L10n.tr("permission.open")
    }

    private var modeColor: Color {
        let conv = row.conversation
        return conv.filePermissionMode == .sandbox ? Color.blue : Color.orange
    }

    var body: some View {
        let conv = row.conversation
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title)
                    .font(.system(size: 11.5, weight: isCurrent ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(row.previewText)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if conv.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow.opacity(0.9))
                    }

                    Text(modeText)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(modeColor.opacity(0.88))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(modeColor.opacity(0.08), in: Capsule())

                    Text(row.timeText)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize()

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
        .shadow(color: shadowColor, radius: isCurrent ? 10 : 4, x: 0, y: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: isCurrent)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundFill: Color {
        if isCurrent {
            return Color.primary.opacity(0.075)
        }
        if isHovered {
            return Color.primary.opacity(0.03)
        }
        return Color.clear
    }

    private var borderColor: Color {
        if isCurrent {
            return Color.primary.opacity(0.09)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    private var shadowColor: Color {
        Color.black.opacity(isCurrent ? 0.025 : 0.008)
    }
}

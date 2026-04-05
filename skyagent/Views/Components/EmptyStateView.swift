import SwiftUI

struct EmptyStateView: View {
    let onNewConversation: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 36)

            VStack(alignment: .leading, spacing: 22) {
                topMark

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("empty_state.title"))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(L10n.tr("empty_state.subtitle"))
                        .font(.system(size: 14.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionRow

                hintRow
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 40)
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.primary.opacity(0.01)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var topMark: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: 28, height: 3)

            Text("SkyAgent")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            Button {
                onNewConversation()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text(L10n.tr("empty_state.new_conversation"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            shortcutPill("⌘N")
            shortcutPill("⌘,")
        }
    }

    private var hintRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            hintLine(systemName: "folder", text: L10n.tr("sidebar.new.help"))
            hintLine(systemName: "paperclip", text: L10n.tr("chat_input.upload.help"))
        }
    }

    private func hintLine(systemName: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(text)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
            )
    }
}

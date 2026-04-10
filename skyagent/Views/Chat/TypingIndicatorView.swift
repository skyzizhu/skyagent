import SwiftUI

struct TypingIndicatorView: View {
    var status: ConversationActivityStatus?
    @State private var pulse = false
    @State private var wave = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .stroke(accentColor.opacity(0.18), lineWidth: 1)
                    .frame(width: 34, height: 34)
                    .scaleEffect(pulse ? 1.16 : 0.92)
                    .opacity(pulse ? 0.1 : 0.42)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)

                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 30, height: 30)

                Image(systemName: status?.iconName ?? "brain.head.profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 999, style: .continuous)
                                .fill(accentColor.opacity(0.32 + Double(index) * 0.08))
                                .frame(width: wave ? [20, 14, 10][index] : [10, 14, 20][index], height: 3)
                                .animation(
                                    .easeInOut(duration: 0.9)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.08),
                                    value: wave
                                )
                        }
                    }
                }

                if let detail = status?.detail,
                   !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                if let context = status?.context,
                   !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(context)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let badges = status?.badges, !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(badges.prefix(3)), id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(0.04),
                            Color.primary.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(0.12), lineWidth: 0.8)
        )
        .onAppear {
            pulse = true
            wave = true
        }
    }

    private var displayTitle: String {
        let title = status?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? L10n.tr("typing.default_title") : title
    }

    private var accentColor: Color {
        switch status?.accentStyle {
        case .thinking:
            return .accentColor
        case .reading:
            return .blue
        case .writing:
            return .orange
        case .skill:
            return .green
        case .network:
            return .mint
        case .shell:
            return .purple
        case .approval:
            return .yellow
        case .warning:
            return .orange
        case .error:
            return .red
        case .success:
            return .green
        case .neutral, .none:
            return Color.secondary
        }
    }
}

import SwiftUI

struct ConversationActivityBarView: View {
    let state: ConversationActivityState

    @State private var pulse = false
    @State private var now = Date()
    @State private var timer: Timer?
    @State private var thinkingDotCount = 1

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(accentColor.opacity(pulse ? 0.9 : 0.45))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                if let detail = secondaryLine {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            pulse = true
            now = Date()
            thinkingDotCount = 1
            let usesTypingDots = state.phase == .thinking || state.phase == .processing
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                now = Date()
                if usesTypingDots {
                    thinkingDotCount = thinkingDotCount == 3 ? 1 : thinkingDotCount + 1
                }
            }
        }
        .onChange(of: state.id) {
            now = Date()
            if state.phase == .thinking || state.phase == .processing {
                thinkingDotCount = 1
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var elapsedLabel: String {
        state.elapsedLabel(at: now)
    }

    private var primaryLine: String {
        if state.phase == .thinking || state.phase == .processing {
            return state.title + String(repeating: ".", count: thinkingDotCount)
        }

        if state.showsElapsedTime {
            return "\(state.title)  \(elapsedLabel)"
        }
        return state.title
    }

    private var secondaryLine: String? {
        if state.phase == .thinking || state.phase == .processing {
            return nil
        }
        return state.presentationDetail(at: now)
    }

    private var accentColor: Color {
        switch state.accent {
        case .neutral:
            return .secondary
        case .thinking:
            return .accentColor
        case .file:
            return .blue
        case .skill:
            return .orange
        case .network:
            return .cyan
        case .shell:
            return .mint
        case .approval:
            return .yellow
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

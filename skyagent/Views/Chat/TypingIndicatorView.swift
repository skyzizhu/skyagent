import SwiftUI

struct TypingIndicatorView: View {
    @State private var phase = false
    @State private var dotCount = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            // 动画点
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 7, height: 7)
                        .offset(y: phase ? -5 : 5)
                        .animation(
                            .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                            value: phase
                        )
                }
            }

            Text("思考中" + String(repeating: ".", count: dotCount))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.3), value: dotCount)
        }
        .onAppear {
            phase = true
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                dotCount = (dotCount + 1) % 4
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

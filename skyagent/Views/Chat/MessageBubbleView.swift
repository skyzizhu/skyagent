import SwiftUI

struct MessageBubbleView: View, Equatable {
    let message: Message
    var onDelete: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onEditUserMessage: ((UUID, String) -> Void)?
    var isLastAssistant: Bool
    var isStreamingAssistant: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(
        message: Message,
        onDelete: (() -> Void)? = nil,
        onRegenerate: (() -> Void)? = nil,
        onEditUserMessage: ((UUID, String) -> Void)? = nil,
        isLastAssistant: Bool = false,
        isStreamingAssistant: Bool = false
    ) {
        self.message = message
        self.onDelete = onDelete
        self.onRegenerate = onRegenerate
        self.onEditUserMessage = onEditUserMessage
        self.isLastAssistant = isLastAssistant
        self.isStreamingAssistant = isStreamingAssistant
    }

    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message == rhs.message &&
        lhs.isLastAssistant == rhs.isLastAssistant &&
        lhs.isStreamingAssistant == rhs.isStreamingAssistant
    }

    private var timeString: String {
        Self.timeFormatter.string(from: message.timestamp)
    }

    private var isAssistantTextMessage: Bool {
        message.role == .assistant
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 180)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                bubbleContent

                timestampLabel
            }
            .frame(
                maxWidth: message.role == .user ? 540 : 840,
                alignment: message.role == .user ? .trailing : .leading
            )
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if message.role == .user { showEditAlert() }
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            } label: {
                Label("复制内容", systemImage: "doc.on.doc")
            }

            if message.role == .user && onEditUserMessage != nil {
                Button { showEditAlert() } label: {
                    Label("编辑消息", systemImage: "pencil")
                }
            }

            if onDelete != nil {
                Button(role: .destructive) { onDelete?() } label: {
                    Label("删除消息", systemImage: "trash")
                }
            }

            if isLastAssistant && onRegenerate != nil {
                Button { onRegenerate?() } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private var timestampLabel: some View {
        HStack(spacing: 6) {
            if isAssistantTextMessage && isStreamingAssistant {
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: 4, height: 4)
            }

            Text(timeString)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.quaternary)
                .tracking(0.2)
        }
        .padding(.horizontal, isAssistantTextMessage ? 2 : 3)
        .opacity(message.role == .user ? 0.58 : 0.46)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .assistant:
            if message.content.isEmpty {
                assistantFlowSurface {
                    TypingIndicatorView()
                }
            } else {
                assistantFlowSurface {
                    MarkdownContentView(content: message.content)
                }
            }

        case .tool:
            if let toolExecution = message.toolExecution {
                VStack(alignment: .leading, spacing: 8) {
                    ToolCallView(toolExecution: toolExecution, result: message.content)
                    let previewPaths = message.previewImagePaths ?? message.previewImagePath.map { [$0] } ?? []
                    if !previewPaths.isEmpty {
                        ConversationImagePreviewGrid(imagePaths: previewPaths)
                    }
                }
            }

        case .user:
            userSurface {
                Text(message.content)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .system:
            systemSurface {
                Text(message.content)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func assistantFlowSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
    }

    private func userSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.accentColor.opacity(0.065))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.085), lineWidth: 0.8)
            )
    }

    private func systemSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
            )
    }

    private func showEditAlert() {
        let alert = NSAlert()
        alert.messageText = "编辑消息"
        alert.informativeText = "修改后将从这条消息开始重新生成回复"
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = message.content
        alert.accessoryView = textField
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newText = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newText.isEmpty {
                onEditUserMessage?(message.id, newText)
            }
        }
    }
}

private struct ConversationImagePreviewGrid: View {
    let imagePaths: [String]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 10, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(imagePaths, id: \.self) { imagePath in
                ConversationImagePreviewCard(imagePath: imagePath)
            }
        }
    }
}

private struct ConversationImagePreviewCard: View {
    let imagePath: String
    @State private var isPresented = false

    var body: some View {
        if let image = NSImage(contentsOfFile: imagePath) {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    isPresented = true
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 190)
                        .background(Color.primary.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Text((imagePath as NSString).lastPathComponent)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(L10n.tr("chat.preview.view")) {
                        isPresented = true
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))

                    Button(L10n.tr("chat.preview.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: imagePath)])
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                }
            }
            .sheet(isPresented: $isPresented) {
                ConversationImagePreviewSheet(image: image, imagePath: imagePath)
            }
        }
    }
}

private struct ConversationImagePreviewSheet: View {
    let image: NSImage
    let imagePath: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text((imagePath as NSString).lastPathComponent)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(imagePath)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(L10n.tr("chat.preview.reveal_in_finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: imagePath)])
                }
                Button(L10n.tr("common.close")) {
                    dismiss()
                }
            }
            .padding(18)

            Divider()

            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: max(geometry.size.width - 40, 200),
                                maxHeight: max(geometry.size.height - 40, 200)
                            )
                            .padding(20)
                    }
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height
                    )
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

private struct StreamingAssistantTextView: View {
    let content: String

    var body: some View {
        Text(content)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

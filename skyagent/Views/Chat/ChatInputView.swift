import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatInputView: View {
    @Binding var inputText: String
    @Binding var pendingAttachment: ComposerAttachment?
    @Binding var attachmentStatus: ComposerAttachmentStatus?
    let isLoading: Bool
    let permissionMode: FilePermissionMode
    let modelName: String
    let requireCommandReturnToSend: Bool
    let contextUsageStatus: ContextUsageStatus?
    let onSend: () -> Void
    let onTogglePermission: () -> Void
    let onRequestFocus: () -> Void
    let focusRequestID: Int
    @State private var editorHeight: CGFloat = 60
    @State private var isDropTargeted = false

    private let minimumEditorHeight: CGFloat = 60
    private let maximumEditorHeight: CGFloat = 168

    var body: some View {
        VStack(spacing: 10) {
            imagePreviewSection
            inputCard
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.96)
        )
    }

    @ViewBuilder
    private var imagePreviewSection: some View {
        if let attachment = pendingAttachment {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let image = attachment.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                                .frame(width: 72, height: 60)
                            Image(systemName: "doc.text")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.fileName)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(attachment.detail)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            statusBadge(.ready, text: L10n.tr("attachment.status.ready"))
                        }

                        if let structureSummary = attachment.structureSummary {
                            Text(structureSummary)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Button {
                        pendingAttachment = nil
                        attachmentStatus = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                if !attachment.structureItems.isEmpty {
                    attachmentOutlineView(items: attachment.structureItems)
                }
            }
            .padding(.horizontal, 16)
        } else if let attachmentStatus {
            TimelineView(.periodic(from: attachmentStatus.startedAt, by: 1)) { context in
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(iconBackground(for: attachmentStatus.phase))
                            .frame(width: 72, height: 60)

                        Group {
                            switch attachmentStatus.phase {
                            case .parsing:
                                ProgressView()
                                    .controlSize(.small)
                            case .ready:
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                            case .failed:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                            }
                        }
                        .foregroundStyle(iconColor(for: attachmentStatus.phase))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachmentStatus.fileName)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            statusBadge(attachmentStatus.phase, text: statusText(for: attachmentStatus.phase))
                            Text(attachmentMessage(for: attachmentStatus, now: context.date))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    if attachmentStatus.phase == .failed {
                        Button {
                            self.attachmentStatus = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func attachmentOutlineView(items: [String]) -> some View {
        let previewItems = Array(items.prefix(6))
        let remainingCount = max(items.count - previewItems.count, 0)

        return FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(previewItems, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.045))
                    )
            }

            if remainingCount > 0 {
                Text("+\(remainingCount)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.03))
                    )
            }
        }
    }

    private var inputCard: some View {
        VStack(spacing: 10) {
            editorRow
            footerRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .textBackgroundColor).opacity(0.92),
                            Color.primary.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.025), radius: 10, x: 0, y: 4)
    }

    private var editorRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            editorSurface
            sendButton
        }
    }

    private var editorSurface: some View {
        HStack(alignment: .top, spacing: 5) {
            uploadButton

            NativePromptEditor(
                text: $inputText,
                focusRequestID: focusRequestID,
                isEditable: true,
                requireCommandReturnToSend: requireCommandReturnToSend,
                onSubmit: onSend,
                measuredHeight: $editorHeight,
                minHeight: minimumEditorHeight,
                maxHeight: maximumEditorHeight,
                placeholder: L10n.tr("chat_input.placeholder")
            )
            .frame(height: editorHeight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    isDropTargeted
                    ? Color.accentColor.opacity(0.06)
                    : Color(nsColor: .windowBackgroundColor).opacity(0.85)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.055), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            onRequestFocus()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleDroppedFiles(providers: providers)
        }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in
            handlePaste(providers: providers)
        }
    }

    private var uploadButton: some View {
        Button {
            selectAttachmentFile()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 32, height: 32)

                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .help(L10n.tr("chat_input.upload.help"))
    }

    private var sendButton: some View {
        let button = Button {
            onSend()
        } label: {
            ZStack {
                Circle()
                    .fill(sendButtonBackground)
                    .frame(width: 38, height: 38)

                Image(systemName: isLoading ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(sendButtonForeground)
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
        .disabled(attachmentStatus?.phase == .parsing)

        if requireCommandReturnToSend {
            return AnyView(button.keyboardShortcut(.return, modifiers: .command))
        }
        return AnyView(button)
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            permissionChip
            Divider()
                .frame(height: 12)
                .overlay(Color.primary.opacity(0.06))
            modelLabel
            Spacer()
            if let contextUsageStatus {
                contextUsageFooter(contextUsageStatus)
            }
        }
        .padding(.horizontal, 2)
    }

    private var permissionChip: some View {
        Button {
            onTogglePermission()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: permissionMode.icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(permissionMode.displayName)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                Capsule()
                    .fill(permissionChipColor.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(permissionChipColor.opacity(0.18), lineWidth: 0.8)
            )
            .foregroundStyle(permissionChipColor)
        }
        .buttonStyle(.plain)
        .help(L10n.tr("chat_input.permission.help", permissionMode.description))
    }

    private var modelLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .semibold))
            Text(modelName)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private func contextUsageFooter(_ usage: ContextUsageStatus) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 9, weight: .semibold))
                Text(
                    L10n.tr(
                        "chat.context_usage.title",
                        formattedContextTokenCount(usage.usedTokens),
                        formattedContextTokenCount(usage.budgetTokens)
                    )
                )
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
            )

            if usage.isCompressed {
                Text(L10n.tr("chat.context_usage.compressed"))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(Color.orange.opacity(0.08), in: Capsule())
            }
        }
        .help(L10n.tr("chat.context_usage.help"))
    }

    private func formattedContextTokenCount(_ value: Int) -> String {
        if value >= 1000 {
            let scaled = Double(value) / 1000.0
            return scaled >= 10 ? String(format: "%.0fK", scaled) : String(format: "%.1fK", scaled)
        }
        return "\(value)"
    }

    private var permissionChipColor: Color {
        permissionMode == .sandbox ? .blue : .orange
    }

    private var sendButtonBackground: Color {
        isLoading ? Color.orange.opacity(0.18) : Color.primary
    }

    private var sendButtonForeground: Color {
        isLoading ? .orange : .white
    }

    private func handlePaste(providers: [NSItemProvider]) {
        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let fileURL = pastedFileURL(from: item) else { return }
                DispatchQueue.main.async {
                    loadFileAttachment(from: fileURL)
                }
            }
            return
        }

        if let pngProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.png.identifier) }) {
            pngProvider.loadItem(forTypeIdentifier: UTType.png.identifier) { item, _ in
                if let data = item as? Data {
                    DispatchQueue.main.async {
                        loadImageAttachment(from: data, fileName: "clipboard.png")
                    }
                }
            }
            return
        }

        if let tiffProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) }) {
            tiffProvider.loadItem(forTypeIdentifier: UTType.tiff.identifier) { item, _ in
                if let data = item as? Data {
                    DispatchQueue.main.async {
                        loadImageAttachment(from: data, fileName: "clipboard.tiff")
                    }
                }
            }
        }
    }

    private func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        guard let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let fileURL = pastedFileURL(from: item) else { return }
            DispatchQueue.main.async {
                loadFileAttachment(from: fileURL)
            }
        }
        return true
    }

    private func pastedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL {
                return url
            }
            return URL(fileURLWithPath: string)
        }
        return nil
    }

    private func selectAttachmentFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("panel.choose_file.title")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ComposerAttachment.supportedFileExtensions.compactMap { UTType(filenameExtension: $0) }

        if panel.runModal() == .OK, let url = panel.url {
            loadFileAttachment(from: url)
        }
    }

    private func loadImageAttachment(from imageData: Data, fileName: String) {
        pendingAttachment = nil
        let startedAt = Date()
        attachmentStatus = ComposerAttachmentStatus(
            phase: .parsing,
            kind: .image,
            fileName: fileName,
            message: L10n.tr("attachment.processing_image"),
            startedAt: startedAt
        )

        Task.detached(priority: .userInitiated) { [imageData, fileName] in
            do {
                let attachment = try ComposerAttachment.fromImageData(
                    imageData,
                    fileName: fileName,
                    progress: { progress in
                        Task { @MainActor in
                            self.updateAttachmentParsingStatus(
                                fileName: fileName,
                                progress: progress,
                                startedAt: startedAt
                            )
                        }
                    }
                )
                await MainActor.run {
                    self.pendingAttachment = attachment
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .ready,
                        kind: .image,
                        fileName: attachment.fileName,
                        message: L10n.tr("attachment.ready_message"),
                        startedAt: startedAt
                    )
                }
            } catch {
                await MainActor.run {
                    self.pendingAttachment = nil
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .failed,
                        kind: .image,
                        fileName: fileName,
                        message: error.localizedDescription,
                        startedAt: startedAt
                    )
                }
            }
        }
    }

    private func loadFileAttachment(from url: URL) {
        let fileName = url.lastPathComponent
        let kind = ComposerAttachment.parsingKind(forExtension: url.pathExtension)
        pendingAttachment = nil
        let startedAt = Date()
        attachmentStatus = ComposerAttachmentStatus(
            phase: .parsing,
            kind: kind,
            fileName: fileName,
            message: initialAttachmentMessage(for: kind),
            startedAt: startedAt
        )

        Task.detached(priority: .userInitiated) { [url, fileName] in
            do {
                let attachment = try ComposerAttachment.fromFile(
                    url: url,
                    progress: { progress in
                        Task { @MainActor in
                            self.updateAttachmentParsingStatus(
                                fileName: fileName,
                                progress: progress,
                                startedAt: startedAt
                            )
                        }
                    }
                )
                await MainActor.run {
                    self.pendingAttachment = attachment
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .ready,
                        kind: kind,
                        fileName: attachment.fileName,
                        message: L10n.tr("attachment.ready_message"),
                        startedAt: startedAt
                    )
                }
            } catch {
                await MainActor.run {
                    self.pendingAttachment = nil
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .failed,
                        kind: kind,
                        fileName: fileName,
                        message: error.localizedDescription,
                        startedAt: startedAt
                    )
                }
            }
        }
    }

    private func statusBadge(_ phase: ComposerAttachmentStatus.Phase, text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusBackground(for: phase), in: Capsule())
            .foregroundStyle(statusForeground(for: phase))
    }

    private func statusText(for phase: ComposerAttachmentStatus.Phase) -> String {
        switch phase {
        case .parsing: return L10n.tr("attachment.status.parsing")
        case .ready: return L10n.tr("attachment.status.ready")
        case .failed: return L10n.tr("attachment.status.failed")
        }
    }

    private func statusBackground(for phase: ComposerAttachmentStatus.Phase) -> Color {
        switch phase {
        case .parsing: return Color.orange.opacity(0.12)
        case .ready: return Color.green.opacity(0.12)
        case .failed: return Color.red.opacity(0.12)
        }
    }

    private func statusForeground(for phase: ComposerAttachmentStatus.Phase) -> Color {
        switch phase {
        case .parsing: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }

    private func iconBackground(for phase: ComposerAttachmentStatus.Phase) -> Color {
        switch phase {
        case .parsing: return Color.orange.opacity(0.08)
        case .ready: return Color.green.opacity(0.08)
        case .failed: return Color.red.opacity(0.08)
        }
    }

    private func iconColor(for phase: ComposerAttachmentStatus.Phase) -> Color {
        switch phase {
        case .parsing: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }

    private func attachmentMessage(for status: ComposerAttachmentStatus, now: Date) -> String {
        guard status.phase == .parsing else { return status.message }

        let elapsedSeconds = max(1, Int(now.timeIntervalSince(status.startedAt)))
        let elapsedLabel = L10n.tr("chat.waiting.elapsed.seconds", String(elapsedSeconds))
        let initialMessage = initialAttachmentMessage(for: status.kind)
        if !status.message.isEmpty, status.message != initialMessage {
            return L10n.tr("attachment.parsing.step_elapsed", status.message, elapsedLabel)
        }
        let stage = max(0, (elapsedSeconds - 1) / 4) % 3

        switch (status.kind, stage) {
        case (.image, 0):
            return L10n.tr("attachment.parsing.image.elapsed", elapsedLabel)
        case (.image, 1):
            return L10n.tr("attachment.parsing.image.running", elapsedLabel)
        case (.image, _):
            return L10n.tr("attachment.parsing.image.long", elapsedLabel)
        case (.pdf, 0):
            return L10n.tr("attachment.parsing.pdf.elapsed", elapsedLabel)
        case (.pdf, 1):
            return L10n.tr("attachment.parsing.pdf.running", elapsedLabel)
        case (.pdf, _):
            return L10n.tr("attachment.parsing.pdf.long", elapsedLabel)
        case (.office, 0):
            return L10n.tr("attachment.parsing.office.elapsed", elapsedLabel)
        case (.office, 1):
            return L10n.tr("attachment.parsing.office.running", elapsedLabel)
        case (.office, _):
            return L10n.tr("attachment.parsing.office.long", elapsedLabel)
        case (.text, 0):
            return L10n.tr("attachment.parsing.text.elapsed", elapsedLabel)
        case (.text, 1):
            return L10n.tr("attachment.parsing.text.running", elapsedLabel)
        case (.text, _):
            return L10n.tr("attachment.parsing.text.long", elapsedLabel)
        case (.file, 0):
            return L10n.tr("attachment.parsing.file.elapsed", elapsedLabel)
        case (.file, 1):
            return L10n.tr("attachment.parsing.file.running", elapsedLabel)
        case (.file, _):
            return L10n.tr("attachment.parsing.file.long", elapsedLabel)
        }
    }

    private func updateAttachmentParsingStatus(
        fileName: String,
        progress: ComposerAttachmentParsingProgress,
        startedAt: Date
    ) {
        guard attachmentStatus?.phase == .parsing, attachmentStatus?.fileName == fileName else {
            return
        }

        attachmentStatus = ComposerAttachmentStatus(
            phase: .parsing,
            kind: progress.kind,
            fileName: fileName,
            message: L10n.tr(progress.messageKey, arguments: progress.arguments),
            startedAt: startedAt
        )
    }

    private func initialAttachmentMessage(for kind: ComposerAttachmentStatus.Kind) -> String {
        switch kind {
        case .image:
            return L10n.tr("attachment.processing_image")
        case .pdf:
            return L10n.tr("attachment.processing_pdf")
        case .office:
            return L10n.tr("attachment.processing_office")
        case .text:
            return L10n.tr("attachment.processing_text")
        case .file:
            return L10n.tr("attachment.processing_file")
        }
    }
}

private struct NativePromptEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequestID: Int
    let isEditable: Bool
    let requireCommandReturnToSend: Bool
    let onSubmit: () -> Void
    @Binding var measuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PromptEditorHostView {
        let hostView = PromptEditorHostView()
        hostView.textView.delegate = context.coordinator
        hostView.textView.string = text
        hostView.textView.isEditable = isEditable
        hostView.placeholderField.stringValue = placeholder
        hostView.textView.requireCommandReturnToSend = requireCommandReturnToSend
        hostView.textView.onSubmit = onSubmit

        hostView.textView.onCompositionStateChange = {
            DispatchQueue.main.async {
                context.coordinator.refreshPlaceholder(in: hostView)
            }
        }

        hostView.onWindowReady = { [weak coordinator = context.coordinator] in
            DispatchQueue.main.async {
                coordinator?.applyPendingFocusIfNeeded()
            }
        }

        context.coordinator.hostView = hostView

        DispatchQueue.main.async {
            context.coordinator.refreshPlaceholder(in: hostView)
            context.coordinator.refreshHeight(in: hostView)
            context.coordinator.applyFocusRequestIfNeeded(self.focusRequestID)
        }

        return hostView
    }

    func updateNSView(_ hostView: PromptEditorHostView, context: Context) {
        if !hostView.textView.hasMarkedText(), hostView.textView.string != text {
            hostView.textView.string = text
        }

        hostView.placeholderField.stringValue = placeholder
        hostView.textView.isEditable = isEditable
        hostView.textView.requireCommandReturnToSend = requireCommandReturnToSend
        hostView.textView.onSubmit = onSubmit

        DispatchQueue.main.async {
            context.coordinator.refreshPlaceholder(in: hostView)
            context.coordinator.refreshHeight(in: hostView)
            context.coordinator.applyFocusRequestIfNeeded(self.focusRequestID)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePromptEditor
        weak var hostView: PromptEditorHostView?
        private var lastAppliedFocusRequestID = 0
        private var pendingFocusRequestID: Int?

        init(parent: NativePromptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let hostView else { return }
            parent.text = hostView.textView.string
            refreshPlaceholder(in: hostView)
            refreshHeight(in: hostView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let hostView else { return }
            refreshPlaceholder(in: hostView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let hostView else { return }
            refreshPlaceholder(in: hostView)
        }

        func refreshPlaceholder(in hostView: PromptEditorHostView) {
            let isEmpty = hostView.textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let shouldShow = isEmpty && !hostView.textView.hasMarkedText()
            hostView.placeholderField.isHidden = !shouldShow
        }

        func refreshHeight(in hostView: PromptEditorHostView) {
            let textView = hostView.textView
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let rawHeight = ceil(usedRect.height) + textView.textContainerInset.height * 2
            let clampedHeight = min(max(rawHeight, parent.minHeight), parent.maxHeight)
            if abs(parent.measuredHeight - clampedHeight) > 0.5 {
                parent.measuredHeight = clampedHeight
            }
        }

        func applyFocusRequestIfNeeded(_ requestID: Int) {
            guard requestID != lastAppliedFocusRequestID else { return }
            guard let hostView else {
                pendingFocusRequestID = requestID
                logFocusFailure(reason: "host_view_missing", requestID: requestID)
                return
            }

            guard hostView.window != nil else {
                pendingFocusRequestID = requestID
                logFocusFailure(reason: "window_not_ready", requestID: requestID)
                return
            }

            guard !hostView.textView.hasMarkedText() else {
                pendingFocusRequestID = requestID
                logFocusFailure(reason: "text_composition_in_progress", requestID: requestID)
                return
            }

            lastAppliedFocusRequestID = requestID
            pendingFocusRequestID = nil

            if hostView.window?.firstResponder !== hostView.textView {
                hostView.window?.makeFirstResponder(hostView.textView)
            }
            hostView.textView.setSelectedRange(NSRange(location: hostView.textView.string.count, length: 0))
        }

        func applyPendingFocusIfNeeded() {
            guard let pendingFocusRequestID else { return }
            applyFocusRequestIfNeeded(pendingFocusRequestID)
        }

        private func logFocusFailure(reason: String, requestID: Int) {
            Task {
                await LoggerService.shared.log(
                    level: .warn,
                    category: .ui,
                    event: "input_focus_failed",
                    status: .failed,
                    summary: "输入框焦点请求未成功应用",
                    metadata: [
                        "reason": .string(reason),
                        "focus_request_id": .int(requestID)
                    ]
                )
            }
        }
    }
}

private final class PromptEditorHostView: NSView {
    let scrollView = NSScrollView()
    let textView = PromptEditorTextView()
    let placeholderField = NSTextField(labelWithString: "")
    var onWindowReady: (() -> Void)?
    private var windowObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        if window != nil {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onWindowReady?()
            }
            onWindowReady?()
        }
    }

    deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== textView {
            window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        }
        super.mouseDown(with: event)
    }

    private func setup() {
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor

        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            container.lineFragmentPadding = 0
        }

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.lineBreakMode = .byTruncatingTail
        placeholderField.maximumNumberOfLines = 1

        addSubview(scrollView)
        addSubview(placeholderField)
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            placeholderField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
        ])
    }
}

private final class PromptEditorTextView: NSTextView {
    var onCompositionStateChange: (() -> Void)?
    var onSubmit: (() -> Void)?
    var requireCommandReturnToSend = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText(),
              event.keyCode == 36 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let expectsCommand = requireCommandReturnToSend
        let isCommandReturn = modifiers.contains(.command)
        let isPlainReturn = modifiers.isEmpty
        let isShiftReturn = modifiers == [.shift]

        if expectsCommand {
            if isCommandReturn {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
            return
        }

        if isPlainReturn {
            onSubmit?()
            return
        }

        if isShiftReturn {
            insertNewline(nil)
            return
        }

        super.keyDown(with: event)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionStateChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionStateChange?()
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    init(spacing: CGFloat = 8, rowSpacing: CGFloat = 8) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = arrangeRows(in: width, subviews: subviews)
        let height = rows.last.map { $0.maxY } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeRows(in: bounds.width, subviews: subviews)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private func arrangeRows(in availableWidth: CGFloat, subviews: Subviews) -> [FlowRow] {
        let maxWidth = max(availableWidth, 1)
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        func flushRow() {
            guard !currentItems.isEmpty else { return }
            let maxY = currentY + rowHeight
            rows.append(FlowRow(items: currentItems, maxY: maxY))
            currentItems = []
            currentX = 0
            currentY = maxY + rowSpacing
            rowHeight = 0
        }

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let fitsCurrentRow = currentItems.isEmpty || (currentX + size.width) <= maxWidth

            if !fitsCurrentRow {
                flushRow()
            }

            let item = FlowItem(index: index, size: size, origin: CGPoint(x: currentX, y: currentY))
            currentItems.append(item)
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        flushRow()
        return rows
    }
}

private struct FlowRow {
    let items: [FlowItem]
    let maxY: CGFloat
}

private struct FlowItem {
    let index: Int
    let size: CGSize
    let origin: CGPoint
}

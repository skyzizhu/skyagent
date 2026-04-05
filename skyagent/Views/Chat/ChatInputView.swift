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
    let onSend: () -> Void
    let onTogglePermission: () -> Void
    @FocusState.Binding var inputFocused: Bool
    @State private var editorHeight: CGFloat = 72
    @State private var editorIsEmpty = true
    @State private var isDropTargeted = false

    private let minimumEditorHeight: CGFloat = 72
    private let maximumEditorHeight: CGFloat = 168

    var body: some View {
        VStack(spacing: 12) {
            imagePreviewSection
            inputCard
        }
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.96)
        )
    }

    @ViewBuilder
    private var imagePreviewSection: some View {
        if let pendingAttachment {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let image = pendingAttachment.previewImage {
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
                        Text(pendingAttachment.fileName)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(pendingAttachment.detail)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            statusBadge(.ready, text: L10n.tr("attachment.status.ready"))
                        }
                        if let structureSummary = pendingAttachment.structureSummary {
                            Text(structureSummary)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Button {
                        self.pendingAttachment = nil
                        self.attachmentStatus = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                if !pendingAttachment.structureItems.isEmpty {
                    attachmentOutlineView(items: pendingAttachment.structureItems)
                }
            }
            .padding(.horizontal, 16)
        } else if let attachmentStatus {
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
                        Text(attachmentStatus.message)
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
        .padding(.top, 10)
        .padding(.bottom, 8)
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

            ZStack(alignment: .topLeading) {
                GrowingTextEditor(
                    text: $inputText,
                    isEmpty: $editorIsEmpty,
                    isFocused: Binding(
                        get: { inputFocused },
                        set: { inputFocused = $0 }
                    ),
                    isEditable: !isLoading,
                    measuredHeight: $editorHeight,
                    minHeight: minimumEditorHeight,
                    maxHeight: maximumEditorHeight
                )
                .frame(height: editorHeight)

                if editorIsEmpty && !inputFocused {
                    Text(L10n.tr("chat_input.placeholder"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleDroppedFiles(providers: providers)
        }
        .onPasteCommand(of: [.png, .tiff, .jpeg]) { providers in
            handlePaste(providers: providers)
        }
    }

    private var uploadButton: some View {
        Button {
            selectImageFile()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
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
        Button {
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
        .keyboardShortcut(.return, modifiers: .command)
        .padding(.bottom, 4)
        .disabled(isLoading || attachmentStatus?.phase == .parsing)
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            permissionChip
            Divider()
                .frame(height: 12)
                .overlay(Color.primary.opacity(0.08))
            modelLabel
            Spacer()
        }
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
                if let data = item as? Data, let image = NSImage(data: data) {
                    DispatchQueue.main.async {
                        loadImageAttachment(image, fileName: "clipboard.png")
                    }
                }
            }
            return
        }

        if let tiffProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) }) {
            tiffProvider.loadItem(forTypeIdentifier: UTType.tiff.identifier) { item, _ in
                if let data = item as? Data, let image = NSImage(data: data) {
                    DispatchQueue.main.async {
                        loadImageAttachment(image, fileName: "clipboard.tiff")
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

    private func selectImageFile() {
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

    private func loadImageAttachment(_ image: NSImage, fileName: String) {
        pendingAttachment = nil
        attachmentStatus = ComposerAttachmentStatus(
            phase: .parsing,
            fileName: fileName,
            message: L10n.tr("attachment.processing_image")
        )

        Task.detached(priority: .userInitiated) {
            do {
                let attachment = try ComposerAttachment.fromImage(image, fileName: fileName)
                await MainActor.run {
                    self.pendingAttachment = attachment
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .ready,
                        fileName: attachment.fileName,
                        message: L10n.tr("attachment.ready_message")
                    )
                }
            } catch {
                await MainActor.run {
                    self.pendingAttachment = nil
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .failed,
                        fileName: fileName,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func loadFileAttachment(from url: URL) {
        let fileName = url.lastPathComponent
        pendingAttachment = nil
        attachmentStatus = ComposerAttachmentStatus(
            phase: .parsing,
            fileName: fileName,
            message: L10n.tr("attachment.processing_file")
        )

        Task.detached(priority: .userInitiated) {
            do {
                let attachment = try ComposerAttachment.fromFile(url: url)
                await MainActor.run {
                    self.pendingAttachment = attachment
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .ready,
                        fileName: attachment.fileName,
                        message: L10n.tr("attachment.ready_message")
                    )
                }
            } catch {
                await MainActor.run {
                    self.pendingAttachment = nil
                    self.attachmentStatus = ComposerAttachmentStatus(
                        phase: .failed,
                        fileName: fileName,
                        message: error.localizedDescription
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
}

private struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEmpty: Bool
    @Binding var isFocused: Bool
    let isEditable: Bool
    @Binding var measuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textView.string = text

        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            container.lineFragmentPadding = 0
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            context.coordinator.updateEmptyState()
            context.coordinator.updateHeight()
            if isFocused, textView.window != nil {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable

        DispatchQueue.main.async {
            context.coordinator.updateEmptyState()
            context.coordinator.updateHeight()

            guard textView.window != nil else { return }
            if isFocused, textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        weak var textView: NSTextView?

        init(_ parent: GrowingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateEmptyState()
            updateHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            updateEmptyState()
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            updateEmptyState()
        }

        func updateEmptyState() {
            guard let textView else { return }
            let isCurrentlyEmpty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if parent.isEmpty != isCurrentlyEmpty {
                parent.isEmpty = isCurrentlyEmpty
            }
        }

        func updateHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
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

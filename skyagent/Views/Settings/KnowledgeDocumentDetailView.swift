import SwiftUI

struct KnowledgeDocumentDetailView: View {
    let document: KnowledgeDocument
    let snippets: [KnowledgeDocumentSnippet]
    let focusedCitation: String?
    let focusedSnippet: String?
    let onOpenSource: () -> Void
    let onClose: () -> Void
    @State private var hasScrolledToFocusedSnippet = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overviewSection
                    snippetsSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("settings.knowledge.document_detail.title"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text(document.name)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(L10n.tr("common.close")) {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var overviewSection: some View {
        sectionCard(
            title: document.name,
            subtitle: document.originalPath ?? ""
        ) {
            HStack(spacing: 12) {
                metricBlock(title: L10n.tr("settings.knowledge.status"), value: statusLabel(document.parseStatus))
                metricBlock(title: L10n.tr("settings.knowledge.chunks"), value: "\(document.chunkCount)")
                metricBlock(title: L10n.tr("settings.knowledge.document_detail.imported_at"), value: Self.dateFormatter.string(from: document.importedAt))
            }

            if let originalPath = document.originalPath, !originalPath.isEmpty {
                Text(originalPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("settings.knowledge.manager.open_source")) {
                    onOpenSource()
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
        }
    }

    private var snippetsSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.document_detail.snippets_title"),
            subtitle: L10n.tr("settings.knowledge.document_detail.snippets_subtitle")
        ) {
            if snippets.isEmpty {
                emptyState(L10n.tr("settings.knowledge.document_detail.snippets_empty"))
            } else {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(snippets) { snippet in
                            let isFocused = isFocusedSnippet(snippet)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if let citation = snippet.citation, !citation.isEmpty {
                                        Text(citation)
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(isFocused ? .accent : .secondary)
                                    }

                                    if isFocused {
                                        Text(L10n.tr("settings.knowledge.document_detail.focused"))
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.accent)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    }

                                    Spacer(minLength: 0)
                                }

                                Text(snippet.snippet)
                                    .font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .id(snippet.id)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(isFocused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(isFocused ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), lineWidth: 0.8)
                            )
                        }
                    }
                    .task(id: snippets.map(\.id)) {
                        guard !hasScrolledToFocusedSnippet,
                              let focusedSnippetID = snippets.first(where: isFocusedSnippet)?.id else {
                            return
                        }
                        hasScrolledToFocusedSnippet = true
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(focusedSnippetID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func sectionCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func metricBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14.5, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func statusLabel(_ status: KnowledgeLibraryStatus) -> String {
        switch status {
        case .idle:
            return L10n.tr("settings.knowledge.status.idle")
        case .indexing:
            return L10n.tr("settings.knowledge.status.indexing")
        case .failed:
            return L10n.tr("settings.knowledge.status.failed")
        }
    }

    private func isFocusedSnippet(_ snippet: KnowledgeDocumentSnippet) -> Bool {
        let normalizedFocusedCitation = focusedCitation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedFocusedSnippet = focusedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedCitation = snippet.citation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedSnippet = snippet.snippet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !normalizedFocusedCitation.isEmpty {
            if normalizedCitation == normalizedFocusedCitation || normalizedCitation.contains(normalizedFocusedCitation) {
                return true
            }
        }

        if !normalizedFocusedSnippet.isEmpty {
            if normalizedSnippet == normalizedFocusedSnippet || normalizedSnippet.contains(normalizedFocusedSnippet) {
                return true
            }
        }

        return false
    }
}

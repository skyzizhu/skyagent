import SwiftUI

struct KnowledgeLibrarySelectionView: View {
    @ObservedObject var viewModel: KnowledgeLibrarySelectionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLibraryForManagement: KnowledgeLibrary?
    @State private var showOverview = false
    @State private var showCreateLibrarySheet = false
    @State private var newLibraryName = ""
    @State private var newLibrarySourceRoot = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    toggleCard
                    librariesCard
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 540)
        .sheet(item: $selectedLibraryForManagement) { library in
            KnowledgeBaseLibraryView(
                viewModel: KnowledgeBaseLibraryViewModel(
                    library: library,
                    conversationStore: viewModel.conversationStore
                )
            )
        }
        .sheet(isPresented: $showOverview) {
            KnowledgeBaseOverviewView(
                viewModel: KnowledgeBaseOverviewViewModel(
                    conversationStore: viewModel.conversationStore
                )
            )
        }
        .sheet(isPresented: $showCreateLibrarySheet) {
            createLibrarySheet
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("chat.knowledge.selector.title"))
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(L10n.tr("chat.knowledge.selector.subtitle"))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { viewModel.isKnowledgeEnabled },
                set: { viewModel.setKnowledgeEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("chat.knowledge.selector.enable"))
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    Text(L10n.tr("chat.knowledge.selector.enable_subtitle"))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let workspaceLibraryID = viewModel.workspaceLibraryID,
               let workspaceLibrary = viewModel.libraries.first(where: { $0.id.uuidString == workspaceLibraryID }) {
                Text(L10n.tr("chat.knowledge.selector.workspace_default", workspaceLibrary.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.suggestedLibraryIDs.isEmpty {
                HStack(spacing: 10) {
                    Text(
                        L10n.tr(
                            "chat.knowledge.selector.suggested_summary",
                            "\(viewModel.suggestedLibraryIDs.count)"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(L10n.tr("chat.knowledge.selector.apply_suggested")) {
                        viewModel.applySuggestedLibraries()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(L10n.tr("chat.knowledge.selector.use_suggested_only")) {
                        viewModel.replaceWithSuggestedLibraries()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.8)
        )
    }

    private var librariesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("chat.knowledge.selector.libraries"))
                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                Text(L10n.tr("chat.knowledge.selector.libraries_subtitle"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                searchField

                Button(L10n.tr("settings.knowledge.overview.new")) {
                    newLibraryName = ""
                    newLibrarySourceRoot = ""
                    showCreateLibrarySheet = true
                }
                .buttonStyle(.bordered)

                Button(L10n.tr("settings.knowledge.overview.title")) {
                    showOverview = true
                }
                .buttonStyle(.bordered)
            }

            Text(
                String(
                    format: L10n.tr("chat.knowledge.selector.results"),
                    viewModel.filteredLibraries.count,
                    viewModel.libraries.count
                )
            )
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)

            if viewModel.libraries.isEmpty {
                Text(L10n.tr("chat.knowledge.selector.empty"))
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.secondary)
            } else if viewModel.filteredLibraries.isEmpty {
                Text(L10n.tr("chat.knowledge.selector.no_results"))
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.filteredLibraries) { library in
                        knowledgeLibraryRow(library)
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.8)
        )
    }

    private func knowledgeLibraryRow(_ library: KnowledgeLibrary) -> some View {
        let libraryID = library.id.uuidString
        let isSelected = viewModel.selectedLibraryIDs.contains(libraryID)
        let isWorkspaceDefault = libraryID == viewModel.workspaceLibraryID
        let isSuggested = viewModel.isSuggestedLibrary(libraryID)
        let health = viewModel.importHealth(for: libraryID)
        let iconColor: Color = {
            if !viewModel.isKnowledgeEnabled {
                return Color.primary.opacity(0.28)
            }
            return isSelected ? .accentColor : .secondary
        }()
        let cardFillColor = isSelected ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.02)
        let cardStrokeColor = isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                guard viewModel.isKnowledgeEnabled else { return }
                viewModel.toggleLibrary(libraryID)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    rowSelectionIcon(isSelected: isSelected, iconColor: iconColor)
                    rowContent(
                        library: library,
                        isWorkspaceDefault: isWorkspaceDefault,
                        isSuggested: isSuggested,
                        health: health
                    )

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()

                Button(L10n.tr("settings.knowledge.manage")) {
                    selectedLibraryForManagement = library
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStrokeColor, lineWidth: 0.8)
        )
        .opacity(viewModel.isKnowledgeEnabled ? 1 : 0.6)
    }

    private func rowSelectionIcon(isSelected: Bool, iconColor: Color) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(iconColor)
            .padding(.top, 2)
    }

    private func rowContent(
        library: KnowledgeLibrary,
        isWorkspaceDefault: Bool,
        isSuggested: Bool,
        health: KnowledgeLibrarySelectionViewModel.LibraryImportHealth
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            rowTitle(libraryName: library.name, isWorkspaceDefault: isWorkspaceDefault, isSuggested: isSuggested)

            if let sourceRoot = library.sourceRoot, !sourceRoot.isEmpty {
                Text(sourceRoot)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            rowStats(library: library)

            if let summary = importSummaryText(health: health) {
                Text(summary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(health.failed > 0 ? .orange : .secondary)
            }

            if let summary = importEffectText(health: health) {
                Text(summary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rowTitle(libraryName: String, isWorkspaceDefault: Bool, isSuggested: Bool) -> some View {
        HStack(spacing: 8) {
            Text(libraryName)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            if isWorkspaceDefault {
                badge(
                    text: L10n.tr("chat.knowledge.selector.workspace_badge"),
                    foreground: .secondary,
                    background: Color.primary.opacity(0.06)
                )
            }

            if isSuggested {
                badge(
                    text: L10n.tr("chat.knowledge.selector.suggested_badge"),
                    foreground: .accentColor,
                    background: Color.accentColor.opacity(0.12)
                )
            }
        }
    }

    private func rowStats(library: KnowledgeLibrary) -> some View {
        Text("\(L10n.tr("settings.knowledge.documents")): \(library.documentCount)  •  \(L10n.tr("settings.knowledge.chunks")): \(library.chunkCount)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func importSummaryText(health: KnowledgeLibrarySelectionViewModel.LibraryImportHealth) -> String? {
        guard health.failed > 0 || health.pending > 0 else { return nil }
        return L10n.tr(
            "settings.knowledge.overview.import_summary",
            "\(health.failed)",
            "\(health.pending)"
        )
    }

    private func importEffectText(health: KnowledgeLibrarySelectionViewModel.LibraryImportHealth) -> String? {
        guard health.completed > 0 || health.imported > 0 || health.skipped > 0 else { return nil }
        return L10n.tr(
            "settings.knowledge.manager.import_effect_summary",
            "\(health.completed)",
            "\(health.imported)",
            "\(health.skipped)"
        )
    }

    private func badge(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(background))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                L10n.tr("chat.knowledge.selector.search.placeholder"),
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }

    private var footer: some View {
        HStack {
            Button(L10n.tr("common.cancel")) {
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(L10n.tr("settings.knowledge.refresh")) {
                viewModel.refresh()
            }
            .buttonStyle(.bordered)

            Button(L10n.tr("common.save")) {
                viewModel.applySelection()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var createLibrarySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("settings.knowledge.overview.new"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(L10n.tr("settings.knowledge.overview.new.subtitle"))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.knowledge.overview.new.name"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                TextField(L10n.tr("settings.knowledge.overview.new.name.placeholder"), text: $newLibraryName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.knowledge.overview.new.source"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                TextField(L10n.tr("settings.knowledge.overview.new.source.placeholder"), text: $newLibrarySourceRoot)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.tr("settings.knowledge.overview.new.source.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button(L10n.tr("common.cancel")) {
                    showCreateLibrarySheet = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(L10n.tr("common.save")) {
                    Task {
                        _ = await viewModel.createLibrary(name: newLibraryName, sourceRoot: newLibrarySourceRoot)
                        showCreateLibrarySheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 280, idealHeight: 320)
    }
}

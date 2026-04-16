import SwiftUI

struct KnowledgeBaseLibraryView: View {
    @ObservedObject var viewModel: KnowledgeBaseLibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteLibraryConfirmation = false
    @State private var documentPendingDeletion: KnowledgeDocument?
    @State private var importWebURL = ""

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
                    statusSection
                    overviewSection
                    storageSection
                    runtimeSection
                    maintenanceSection
                    importSection
                    activitySection
                    querySection
                    documentsSection
                    importsSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 720)
        .task {
            await viewModel.refresh()
            viewModel.presentFocusedDocumentIfNeeded()
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.hasSelectedDocumentPreview },
                set: { if !$0 { viewModel.dismissDocumentDetails() } }
            )
        ) {
            if let document = viewModel.selectedDocument {
                KnowledgeDocumentDetailView(
                    document: document,
                    snippets: viewModel.selectedDocumentSnippets,
                    focusedCitation: viewModel.focusedCitation,
                    focusedSnippet: viewModel.focusedSnippet,
                    onOpenSource: { viewModel.openSource(for: document) },
                    onClose: { viewModel.dismissDocumentDetails() }
                )
            }
        }
        .confirmationDialog(
            L10n.tr("settings.knowledge.manager.delete_library_confirm.title"),
            isPresented: $showDeleteLibraryConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("settings.knowledge.manager.delete_library"), role: .destructive) {
                Task {
                    if await viewModel.deleteLibrary() {
                        dismiss()
                    }
                }
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.knowledge.manager.delete_library_confirm.message"))
        }
        .confirmationDialog(
            L10n.tr("settings.knowledge.manager.delete_document_confirm.title"),
            isPresented: Binding(
                get: { documentPendingDeletion != nil },
                set: { if !$0 { documentPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("settings.knowledge.manager.delete_document"), role: .destructive) {
                if let document = documentPendingDeletion {
                    Task { await viewModel.deleteDocument(document) }
                }
                documentPendingDeletion = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {
                documentPendingDeletion = nil
            }
        } message: {
            Text(L10n.tr("settings.knowledge.manager.delete_document_confirm.message"))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("settings.knowledge.manager.title"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(L10n.tr("settings.knowledge.manager.subtitle"))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.tr("settings.knowledge.refresh")) {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRefreshing)

            Button(L10n.tr("common.close")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = viewModel.statusMessage, !message.isEmpty {
                statusBanner(message, tint: .green)
            }
            if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                statusBanner(errorMessage, tint: .red)
            }
        }
    }

    private var overviewSection: some View {
        sectionCard(
            title: viewModel.library.name,
            subtitle: viewModel.library.sourceRoot ?? viewModel.libraryDirectoryURL.path
        ) {
            HStack(spacing: 12) {
                metricBlock(title: L10n.tr("settings.knowledge.status"), value: statusLabel(viewModel.library.status))
                metricBlock(title: L10n.tr("settings.knowledge.documents"), value: "\(viewModel.library.documentCount)")
                metricBlock(title: L10n.tr("settings.knowledge.chunks"), value: "\(viewModel.library.chunkCount)")
                metricBlock(title: L10n.tr("settings.knowledge.manager.import_count"), value: "\(viewModel.importCount)")
            }

            HStack(spacing: 10) {
                Button(L10n.tr("settings.knowledge.open_library")) {
                    NSWorkspace.shared.open(viewModel.libraryDirectoryURL)
                }
                .buttonStyle(.bordered)

                Button(L10n.tr("settings.knowledge.open_index")) {
                    NSWorkspace.shared.open(AppStoragePaths.knowledgeLibrariesFile)
                }
                .buttonStyle(.bordered)

                Button(L10n.tr("settings.knowledge.open_imports")) {
                    NSWorkspace.shared.open(AppStoragePaths.knowledgeImportsFile)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("settings.knowledge.manager.rebuild")) {
                    Task { await viewModel.rebuildLibrary() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)

                Button(L10n.tr("settings.knowledge.manager.delete_library")) {
                    showDeleteLibraryConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(viewModel.isBusy)
            }
        }
    }

    private var storageSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.manager.storage.title"),
            subtitle: L10n.tr("settings.knowledge.manager.storage.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    metricBlock(
                        title: L10n.tr("settings.knowledge.manager.storage.total"),
                        value: viewModel.formattedTotalStorageSize
                    )

                    ForEach(Array(viewModel.formattedStorageBreakdown.prefix(3).enumerated()), id: \.offset) { _, item in
                        metricBlock(title: item.title, value: item.value)
                    }
                }

                if viewModel.formattedStorageBreakdown.count > 3 {
                    HStack(spacing: 12) {
                        ForEach(Array(viewModel.formattedStorageBreakdown.dropFirst(3).enumerated()), id: \.offset) { _, item in
                            metricBlock(title: item.title, value: item.value)
                        }
                    }
                }
            }
        }
    }

    private var runtimeSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.manager.runtime_title"),
            subtitle: L10n.tr("settings.knowledge.manager.runtime_subtitle")
        ) {
            if let sidecarStatus = viewModel.sidecarStatus {
                HStack(alignment: .top, spacing: 14) {
                    Circle()
                        .fill(sidecarStatus.status == "online" ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(sidecarStatus.status == "online" ? L10n.tr("settings.knowledge.manager.sidecar_online") : L10n.tr("settings.knowledge.manager.sidecar_offline"))
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))

                        if let message = sidecarStatus.message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 12.5, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        if let version = sidecarStatus.version, !version.isEmpty {
                            Text("Version \(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if sidecarStatus.parserBackend != nil || sidecarStatus.indexBackend != nil {
                            HStack(spacing: 8) {
                                if let parserBackend = sidecarStatus.parserBackend, !parserBackend.isEmpty {
                                    runtimeBadge(
                                        L10n.tr("settings.knowledge.manager.runtime_parser"),
                                        parserBackend
                                    )
                                }

                                if let indexBackend = sidecarStatus.indexBackend, !indexBackend.isEmpty {
                                    runtimeBadge(
                                        L10n.tr("settings.knowledge.manager.runtime_index"),
                                        indexBackend
                                    )
                                }
                            }
                        }
                    }
                }
            } else {
                Text(L10n.tr("settings.knowledge.manager.runtime_unknown"))
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var maintenanceSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.manager.maintenance.title"),
            subtitle: L10n.tr("settings.knowledge.manager.maintenance.subtitle")
        ) {
            HStack(spacing: 12) {
                metricBlock(
                    title: L10n.tr("settings.knowledge.status"),
                    value: viewModel.maintenanceStatusText
                )
                metricBlock(
                    title: L10n.tr("settings.knowledge.manager.maintenance.last_run"),
                    value: viewModel.lastMaintenanceDateText ?? L10n.tr("settings.knowledge.manager.maintenance.never")
                )
                metricBlock(
                    title: L10n.tr("settings.knowledge.manager.maintenance.reason"),
                    value: viewModel.lastMaintenanceReasonText ?? L10n.tr("settings.knowledge.manager.maintenance.reason.none")
                )
                metricBlock(
                    title: L10n.tr("settings.knowledge.manager.maintenance.next"),
                    value: viewModel.nextMaintenanceDateText ?? L10n.tr("settings.knowledge.manager.maintenance.never")
                )
            }

            if let resultSummary = viewModel.maintenanceResultSummaryText {
                Text(resultSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let scheduleText = viewModel.maintenanceScheduleText {
                Text(scheduleText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(viewModel.maintenanceCandidate?.isDue == true ? .orange : .secondary)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("settings.knowledge.manager.maintenance.run")) {
                    Task { await viewModel.runIncrementalRefresh() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)

                Spacer()
            }
        }
    }

    private var importSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.manager.import_actions_title"),
            subtitle: L10n.tr("settings.knowledge.manager.import_actions_subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button(L10n.tr("settings.knowledge.import_file")) {
                        let panel = NSOpenPanel()
                        panel.title = L10n.tr("settings.knowledge.import_file.title")
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.urls.first {
                            Task { await viewModel.importFile(from: url) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy)

                    Button(L10n.tr("settings.knowledge.import_folder")) {
                        let panel = NSOpenPanel()
                        panel.title = L10n.tr("settings.knowledge.import_folder.title")
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.urls.first {
                            Task { await viewModel.importFolder(from: url) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy)

                    Spacer()
                }

                HStack(spacing: 10) {
                    TextField(L10n.tr("settings.knowledge.import_web.placeholder"), text: $importWebURL)
                        .textFieldStyle(.roundedBorder)

                    Button(L10n.tr("settings.knowledge.import_web")) {
                        let value = importWebURL
                        Task { await viewModel.importWeb(from: value) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy || importWebURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if viewModel.isImportRunning {
                    Text(L10n.tr("settings.knowledge.import_running"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activitySection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.activity.title"),
            subtitle: L10n.tr("settings.knowledge.activity.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button(L10n.tr("settings.knowledge.activity.open_logs")) {
                        viewModel.openEventLogsFolder()
                    }
                    .buttonStyle(.bordered)

                    Button(L10n.tr("settings.knowledge.activity.open_sidecar_logs")) {
                        viewModel.openSidecarLogsFolder()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                if viewModel.recentActivity.isEmpty {
                    emptyState(L10n.tr("settings.knowledge.activity.empty"))
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.recentActivity) { entry in
                            activityRow(entry)
                        }
                    }
                }
            }
        }
    }

    private var documentsSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.manager.documents_title"),
            subtitle: L10n.tr("settings.knowledge.manager.documents_subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                searchField(
                    placeholder: L10n.tr("settings.knowledge.manager.documents_search"),
                    text: $viewModel.documentSearchText
                )

                Text(String(format: L10n.tr("settings.knowledge.manager.results"), viewModel.filteredDocuments.count, viewModel.documents.count))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if viewModel.documents.isEmpty {
                    emptyState(L10n.tr("settings.knowledge.manager.no_documents"))
                } else if viewModel.filteredDocuments.isEmpty {
                    emptyState(L10n.tr("settings.knowledge.manager.search_empty"))
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.filteredDocuments) { document in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(document.name)
                                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))

                                    if document.id == viewModel.focusedDocumentID {
                                        Text(L10n.tr("settings.knowledge.manager.document_focus"))
                                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    }

                                    Text(sourceTypeLabel(document.sourceType))
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.primary.opacity(0.06)))

                                    Spacer()

                                    Text(Self.dateFormatter.string(from: document.importedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if let originalPath = document.originalPath, !originalPath.isEmpty {
                                    Text(originalPath)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                }

                                HStack(spacing: 10) {
                                    Text("\(L10n.tr("settings.knowledge.chunks")): \(document.chunkCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Button(L10n.tr("settings.knowledge.document_detail.open")) {
                                        viewModel.presentDocumentDetails(document)
                                    }
                                    .buttonStyle(.bordered)

                                    Button(L10n.tr("settings.knowledge.manager.document_reimport")) {
                                        Task { await viewModel.reimportDocument(document) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(viewModel.isBusy || (document.originalPath ?? "").isEmpty)

                                    Button(L10n.tr("settings.knowledge.manager.open_source")) {
                                        viewModel.openSource(for: document)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled((document.originalPath ?? "").isEmpty)

                                    Button(L10n.tr("settings.knowledge.manager.delete_document")) {
                                        documentPendingDeletion = document
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .disabled(viewModel.isBusy)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                            )
                        }
                    }
                }
            }
        }
    }

    private var querySection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.manager.query_title"),
            subtitle: L10n.tr("settings.knowledge.manager.query_subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField(L10n.tr("settings.knowledge.manager.query_placeholder"), text: $viewModel.queryText)
                        .textFieldStyle(.roundedBorder)

                    Button(L10n.tr("settings.knowledge.manager.query_run")) {
                        Task { await viewModel.runQuery() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isQueryRunning || viewModel.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !viewModel.queryResults.isEmpty || !viewModel.queryText.isEmpty {
                        Button(L10n.tr("settings.knowledge.manager.query_clear")) {
                            viewModel.clearQueryResults()
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isQueryRunning)
                    }
                }

                if viewModel.isQueryRunning {
                    Text(L10n.tr("settings.knowledge.manager.query_running"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !viewModel.queryResults.isEmpty {
                    Text(L10n.tr("settings.knowledge.manager.query_result_count", "\(viewModel.queryResults.count)"))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if !viewModel.queryResults.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.queryResults) { hit in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(hit.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? hit.title! : L10n.tr("chat.knowledge.reference_default_title"))
                                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                        .lineLimit(1)

                                    Spacer()

                                    Text(String(format: "%.2f", hit.score))
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                                }

                                if let citation = hit.citation, !citation.isEmpty {
                                    Text(citation)
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Text(hit.snippet)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)

                                HStack(spacing: 10) {
                                    if hit.documentID != nil {
                                        Button(L10n.tr("settings.knowledge.document_detail.open")) {
                                            viewModel.openDocumentFromHit(hit)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button(L10n.tr("settings.knowledge.manager.open_source")) {
                                        viewModel.openSource(for: hit)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled((hit.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && hit.documentID == nil)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                            )
                        }
                    }
                }
            }
        }
    }

    private var importsSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.manager.imports_title"),
            subtitle: L10n.tr("settings.knowledge.manager.imports_subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                searchField(
                    placeholder: L10n.tr("settings.knowledge.manager.imports_search"),
                    text: $viewModel.importSearchText
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(KnowledgeBaseLibraryViewModel.ImportFilter.allCases) { filter in
                            Button {
                                viewModel.selectedImportFilter = filter
                                if filter != .failed {
                                    viewModel.clearFailureReasonFilter()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(viewModel.importFilterTitle(filter))
                                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))

                                    Text("\(viewModel.importFilterCount(filter))")
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(viewModel.selectedImportFilter == filter ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
                                        )
                                }
                                .foregroundStyle(viewModel.selectedImportFilter == filter ? Color.white : Color.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(viewModel.selectedImportFilter == filter ? Color.accentColor : Color.primary.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text(String(format: L10n.tr("settings.knowledge.manager.results"), viewModel.filteredImportJobs.count, viewModel.importJobs.count))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if let activeFailureReasonTitle = viewModel.activeFailureReasonTitle {
                    HStack(spacing: 8) {
                        badge(L10n.tr("settings.knowledge.manager.failed_overview.filtered", activeFailureReasonTitle))

                        Button(L10n.tr("settings.knowledge.manager.failed_overview.clear_filter")) {
                            viewModel.clearFailureReasonFilter()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 10) {
                    Text(L10n.tr("settings.knowledge.manager.import_summary", "\(viewModel.failedImportCount)", "\(viewModel.runningImportCount)"))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(L10n.tr("settings.knowledge.manager.import_effect_summary", "\(viewModel.completedImportCount)", "\(viewModel.totalImportedCount)", "\(viewModel.totalSkippedCount)"))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if viewModel.failedImportCount > 0 {
                        Button(L10n.tr("settings.knowledge.manager.import_retry_all")) {
                            Task { await viewModel.retryFailedImportJobs() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isBusy)

                        Button(L10n.tr("settings.knowledge.manager.import_remove_failed")) {
                            Task { await viewModel.removeFailedImportJobs() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isBusy)
                    }
                }

                if viewModel.failedImportCount > 0 {
                    failedImportsOverview
                }

                if viewModel.importJobs.isEmpty {
                    emptyState(L10n.tr("settings.knowledge.manager.no_imports"))
                } else if viewModel.filteredImportJobs.isEmpty {
                    emptyState(L10n.tr("settings.knowledge.manager.search_empty"))
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.filteredImportJobs.prefix(12)) { job in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(job.title ?? URL(fileURLWithPath: job.source).lastPathComponent)
                                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))

                                    Text(importStatusLabel(job.status))
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(importStatusColor(job.status))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(importStatusColor(job.status).opacity(0.12)))

                                    Spacer()

                                    Text(Self.dateFormatter.string(from: job.updatedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 8) {
                                    badge(sourceTypeLabel(job.sourceType))

                                    if let importedCount = job.importedCount {
                                        badge(L10n.tr("settings.knowledge.manager.import_metric.imported", "\(importedCount)"))
                                    }

                                    if let skippedCount = job.skippedCount {
                                        badge(L10n.tr("settings.knowledge.manager.import_metric.skipped", "\(skippedCount)"))
                                    }

                                    if let failedCount = job.failedCount, failedCount > 0 {
                                        badge(L10n.tr("settings.knowledge.manager.import_metric.failed", "\(failedCount)"))
                                    }

                                    if let lastDurationMs = job.lastDurationMs, lastDurationMs > 0 {
                                        badge(L10n.tr("settings.knowledge.manager.import_metric.duration", "\(Int(lastDurationMs))"))
                                    }
                                }

                                Text(job.source)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)

                                if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

                                HStack(spacing: 10) {
                                    Button(L10n.tr("settings.knowledge.manager.open_source")) {
                                        viewModel.openSource(for: job)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(job.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    if job.status == .failed {
                                        Button(L10n.tr("settings.knowledge.manager.import_retry")) {
                                            Task { await viewModel.retryImportJob(job) }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(viewModel.isBusy || viewModel.mutatingImportJobIDs.contains(job.id))
                                    }

                                    Button(L10n.tr("settings.knowledge.manager.import_remove")) {
                                        Task { await viewModel.removeImportJob(job) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(viewModel.isBusy || viewModel.mutatingImportJobIDs.contains(job.id))
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                            )
                        }
                    }
                }
            }
        }
    }

    private var failedImportsOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.tr("settings.knowledge.manager.failed_overview.title"))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))

                if let summary = viewModel.failedImportReasonSummaryText {
                    Text(summary)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            if let latest = viewModel.latestFailedImportText {
                Text(latest)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.failedImportReasonSummaries.prefix(3)) { summary in
                    failureSummaryCard(summary)
                }
            }

            if viewModel.failedImportReasonSummaries.count > 3 {
                Text(
                    L10n.tr(
                        "settings.knowledge.manager.failed_overview.more",
                        "\(viewModel.failedImportReasonSummaries.count - 3)"
                    )
                )
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.12), lineWidth: 0.8)
        )
    }

    private func failureSummaryCard(_ summary: KnowledgeBaseLibraryViewModel.ImportFailureSummary) -> some View {
        let isSelected = viewModel.selectedFailureReasonID == summary.id
        let backgroundColor = isSelected ? Color.accentColor.opacity(0.14) : Color.orange.opacity(0.08)
        let borderColor = isSelected ? Color.accentColor.opacity(0.28) : Color.orange.opacity(0.16)

        return Button {
            viewModel.selectFailureReason(summary)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(summary.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))

                    badge(L10n.tr("settings.knowledge.manager.failed_overview.count", "\(summary.count)"))

                    Spacer()
                }

                if let detail = summary.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !summary.sourceLabels.isEmpty {
                    Text(L10n.tr("settings.knowledge.manager.failed_overview.sources", summary.sourceLabels.joined(separator: "、")))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func searchField(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
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

    private func activityRow(_ entry: PersistedLogEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(activityTint(entry))
                    .frame(width: 8, height: 8)

                Text(entry.summary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(2)

                Spacer()

                Text(entry.relativeTimestamp)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                badge(activityEventTitle(entry))

                if let durationMs = entry.durationMs {
                    badge("\(Int(durationMs)) ms")
                }

                if let status = entry.status, !status.isEmpty {
                    badge(status.capitalized)
                }

                if let imported = entry.metadata["imported_count"], !imported.isEmpty, imported != "0" {
                    badge(L10n.tr("settings.knowledge.manager.import_metric.imported", imported))
                }

                if let skipped = entry.metadata["skipped_count"], !skipped.isEmpty, skipped != "0" {
                    badge(L10n.tr("settings.knowledge.manager.import_metric.skipped", skipped))
                }

                if let failed = entry.metadata["failed_count"], !failed.isEmpty, failed != "0" {
                    badge(L10n.tr("settings.knowledge.manager.import_metric.failed", failed))
                }
            }

            if let source = entry.metadata["source"], !source.isEmpty {
                Text(String(format: L10n.tr("settings.knowledge.activity.source"), source))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func metricBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func statusBanner(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            Text(text)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 0.8)
        )
    }

    private func sectionCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.8)
        )
    }

    private func runtimeBadge(_ title: String, _ value: String) -> some View {
        Text("\(title): \(value)")
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func activityTint(_ entry: PersistedLogEvent) -> Color {
        if entry.level.lowercased() == "error" { return .red }
        switch entry.status?.lowercased() {
        case "failed":
            return .red
        case "succeeded":
            return .green
        case "started", "progress", "retrying":
            return .orange
        default:
            return .accentColor
        }
    }

    private func activityEventTitle(_ entry: PersistedLogEvent) -> String {
        entry.event
            .replacingOccurrences(of: "kb_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
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

    private func sourceTypeLabel(_ sourceType: KnowledgeSourceType) -> String {
        switch sourceType {
        case .file:
            return L10n.tr("settings.knowledge.manager.source_type.file")
        case .folder:
            return L10n.tr("settings.knowledge.manager.source_type.folder")
        case .web:
            return L10n.tr("settings.knowledge.manager.source_type.web")
        }
    }

    private func importStatusLabel(_ status: KnowledgeImportStatus) -> String {
        switch status {
        case .pending:
            return L10n.tr("settings.knowledge.manager.import_status.pending")
        case .running:
            return L10n.tr("settings.knowledge.manager.import_status.running")
        case .succeeded:
            return L10n.tr("settings.knowledge.manager.import_status.succeeded")
        case .failed:
            return L10n.tr("settings.knowledge.manager.import_status.failed")
        }
    }

    private func importStatusColor(_ status: KnowledgeImportStatus) -> Color {
        switch status {
        case .pending:
            return .orange
        case .running:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}

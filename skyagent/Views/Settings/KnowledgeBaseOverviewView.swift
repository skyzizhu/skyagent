import SwiftUI
import AppKit

struct KnowledgeBaseOverviewView: View {
    @ObservedObject var viewModel: KnowledgeBaseOverviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLibrary: KnowledgeLibrary?
    @State private var showCreateLibrarySheet = false
    @State private var newLibraryName = ""
    @State private var newLibrarySourceRoot = ""
    @State private var pendingImportPreview: KnowledgeLibraryPackagePreview?
    @State private var pendingRestorePreview: KnowledgeBackupPackagePreview?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSection
                    summarySection
                    healthSection
                    migrationSection
                    maintenanceSection
                    activitySection
                    librariesSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 720)
        .task {
            await viewModel.refresh()
        }
        .sheet(item: $selectedLibrary) { library in
            KnowledgeBaseLibraryView(
                viewModel: KnowledgeBaseLibraryViewModel(
                    library: library,
                    conversationStore: viewModel.conversationStoreReference
                )
            )
        }
        .sheet(item: $pendingImportPreview) { preview in
            importPreviewSheet(preview)
        }
        .sheet(item: $pendingRestorePreview) { preview in
            restorePreviewSheet(preview)
        }
        .sheet(isPresented: $showCreateLibrarySheet) {
            createLibrarySheet
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("settings.knowledge.overview.title"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(L10n.tr("settings.knowledge.overview.subtitle"))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.tr("settings.knowledge.refresh")) {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRefreshing)

            Button(L10n.tr("settings.knowledge.overview.new")) {
                newLibraryName = ""
                newLibrarySourceRoot = ""
                showCreateLibrarySheet = true
            }
            .buttonStyle(.bordered)

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

    private var summarySection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.overview.summary"),
            subtitle: L10n.tr("settings.knowledge.overview.summary.subtitle")
        ) {
            HStack(spacing: 12) {
                metricBlock(title: L10n.tr("settings.knowledge.overview.metric.libraries"), value: "\(viewModel.libraryCount)")
                metricBlock(title: L10n.tr("settings.knowledge.overview.metric.active"), value: "\(viewModel.activeConversationLibraryIDs.count)")
                metricBlock(title: L10n.tr("settings.knowledge.overview.metric.documents"), value: "\(viewModel.totalDocumentCount)")
                metricBlock(title: L10n.tr("settings.knowledge.overview.metric.chunks"), value: "\(viewModel.totalChunkCount)")
                metricBlock(
                    title: L10n.tr("settings.knowledge.overview.metric.sidecar"),
                    value: viewModel.sidecarStatus?.status == "online"
                        ? L10n.tr("settings.knowledge.manager.sidecar_online")
                        : L10n.tr("settings.knowledge.manager.sidecar_offline")
                )
            }
        }
    }

    private var migrationSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.overview.migration"),
            subtitle: L10n.tr("settings.knowledge.overview.migration.subtitle")
        ) {
            HStack(alignment: .top, spacing: 12) {
                migrationBlock(
                    title: L10n.tr("settings.knowledge.overview.migration.library.title"),
                    subtitle: L10n.tr("settings.knowledge.overview.migration.library.subtitle"),
                    note: L10n.tr("settings.knowledge.overview.migration.library.note"),
                    recentActivity: viewModel.latestLibraryMigrationActivity,
                    primaryTitle: L10n.tr("settings.knowledge.overview.import"),
                    secondaryTitle: nil,
                    primaryAction: openImportLibraryPanel,
                    secondaryAction: nil
                )

                migrationBlock(
                    title: L10n.tr("settings.knowledge.overview.migration.backup.title"),
                    subtitle: L10n.tr("settings.knowledge.overview.migration.backup.subtitle"),
                    note: L10n.tr("settings.knowledge.overview.migration.backup.note"),
                    recentActivity: viewModel.latestBackupActivity ?? viewModel.latestRestoreActivity,
                    primaryTitle: L10n.tr("settings.knowledge.overview.backup"),
                    secondaryTitle: L10n.tr("settings.knowledge.overview.restore"),
                    primaryAction: openExportBackupPanel,
                    secondaryAction: openRestoreBackupPanel
                )
            }
        }
    }

    private var healthSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.overview.audit"),
            subtitle: L10n.tr("settings.knowledge.overview.audit.subtitle")
        ) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("settings.knowledge.overview.audit.note"))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let latestAuditActivity = viewModel.latestAuditActivity {
                        migrationActivityRow(
                            title: latestAuditActivity.title,
                            detail: latestAuditActivity.detail,
                            timestamp: latestAuditActivity.timestamp,
                            isFailure: latestAuditActivity.isFailure
                        )
                    } else {
                        Text(L10n.tr("settings.knowledge.overview.audit.no_recent"))
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Button(L10n.tr("settings.knowledge.overview.audit.run")) {
                        Task { await viewModel.runAudit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRefreshing)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var maintenanceSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.maintenance.title"),
            subtitle: L10n.tr("settings.knowledge.maintenance.subtitle")
        ) {
            let summary = viewModel.maintenanceSummary

            HStack(spacing: 12) {
                metricBlock(
                    title: L10n.tr("settings.knowledge.status"),
                    value: (summary?.enabled ?? false)
                        ? L10n.tr("settings.knowledge.maintenance.enabled")
                        : L10n.tr("settings.knowledge.maintenance.disabled")
                )
                metricBlock(
                    title: L10n.tr("settings.knowledge.maintenance.last_run"),
                    value: summary?.lastRunAt.map { Self.dateFormatter.string(from: $0) }
                        ?? L10n.tr("settings.knowledge.maintenance.never")
                )
                metricBlock(
                    title: L10n.tr("settings.knowledge.manager.import_count"),
                    value: "\(summary?.lastTriggeredLibraryIDs.count ?? 0)"
                )
                metricBlock(
                    title: L10n.tr("settings.knowledge.maintenance.next_check"),
                    value: viewModel.maintenancePlan?.nextCheckAt.map { Self.dateFormatter.string(from: $0) }
                        ?? L10n.tr("settings.knowledge.maintenance.never")
                )
            }

            if let summary {
                Text(
                    String(
                        format: L10n.tr("settings.knowledge.maintenance.policy"),
                        "\(summary.webHours)",
                        "\(summary.workspaceHours)",
                        "\(summary.minimumIntervalMinutes)"
                    )
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            if let plan = viewModel.maintenancePlan {
                if plan.candidates.isEmpty {
                    Text(L10n.tr("settings.knowledge.maintenance.queue_empty"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("settings.knowledge.maintenance.queue_title"))
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))

                        ForEach(plan.candidates.prefix(4)) { candidate in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(candidate.isDue ? Color.orange : Color.secondary.opacity(0.55))
                                    .frame(width: 6, height: 6)

                                Text(candidate.libraryName)
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))

                                badge(maintenanceReasonLabel(candidate.reason))

                                if candidate.isDue {
                                    badge(L10n.tr("settings.knowledge.maintenance.due_badge"))
                                }

                                Spacer()

                                Text(maintenanceCandidateDate(candidate))
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button(L10n.tr("settings.knowledge.maintenance.run_now")) {
                    Task { await viewModel.runMaintenanceNow() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRefreshing)

                Spacer()
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var librariesSection: some View {
        sectionCard(
            title: L10n.tr("settings.knowledge.overview.list"),
            subtitle: L10n.tr("settings.knowledge.overview.list.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                filtersBar

                if viewModel.libraries.isEmpty {
                    Text(L10n.tr("chat.knowledge.selector.empty"))
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(.secondary)
                } else if viewModel.filteredLibraries.isEmpty {
                    emptySearchState
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.filteredLibraries) { library in
                            libraryRow(library)
                        }
                    }
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

    private var filtersBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField
                filterPicker
            }

            Text(
                String(
                    format: L10n.tr("settings.knowledge.overview.results"),
                    viewModel.filteredLibraryCount,
                    viewModel.libraryCount
                )
            )
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                L10n.tr("settings.knowledge.overview.search.placeholder"),
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

    private var filterPicker: some View {
        Picker("", selection: $viewModel.selectedFilter) {
            ForEach(KnowledgeBaseOverviewFilter.allCases) { filter in
                Text(L10n.tr(filter.titleKey)).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 160, alignment: .leading)
    }

    private var emptySearchState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("settings.knowledge.overview.empty.title"))
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            Text(L10n.tr("settings.knowledge.overview.empty.subtitle"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func libraryRow(_ library: KnowledgeLibrary) -> some View {
        let isWorkspaceLibrary = library.id.uuidString == viewModel.currentWorkspaceLibraryID
        let isActiveForConversation = viewModel.activeConversationLibraryIDs.contains(library.id.uuidString)
        let importHealth = viewModel.importHealth(for: library)
        let maintenanceCandidate = viewModel.maintenanceCandidate(for: library)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(library.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                if isWorkspaceLibrary {
                    badge(L10n.tr("settings.knowledge.overview.badge.workspace"))
                }

                if isActiveForConversation {
                    badge(L10n.tr("settings.knowledge.overview.badge.active"))
                }

                Spacer()

                Text(statusLabel(library.status))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            if let sourceRoot = library.sourceRoot, !sourceRoot.isEmpty {
                Text(sourceRoot)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            } else {
                Text(L10n.tr("settings.knowledge.overview.source.manual"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Text("\(L10n.tr("settings.knowledge.documents")): \(library.documentCount)  •  \(L10n.tr("settings.knowledge.chunks")): \(library.chunkCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if importHealth.failed > 0 || importHealth.pending > 0 {
                Text(
                    L10n.tr(
                        "settings.knowledge.overview.import_summary",
                        "\(importHealth.failed)",
                        "\(importHealth.pending)"
                    )
                )
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(importHealth.failed > 0 ? .orange : .secondary)
            }

            if importHealth.completed > 0 || importHealth.imported > 0 || importHealth.skipped > 0 {
                Text(
                    L10n.tr(
                        "settings.knowledge.manager.import_effect_summary",
                        "\(importHealth.completed)",
                        "\(importHealth.imported)",
                        "\(importHealth.skipped)"
                    )
                )
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            if let maintenanceCandidate {
                Text(maintenanceCandidateLine(maintenanceCandidate))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(maintenanceCandidate.isDue ? .orange : .secondary)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("settings.knowledge.manage")) {
                    selectedLibrary = library
                }
                .buttonStyle(.bordered)

                Button(L10n.tr("settings.knowledge.overview.export")) {
                    openExportLibraryPanel(for: library)
                    }
                .buttonStyle(.bordered)

                Button(L10n.tr("settings.knowledge.open_library")) {
                    viewModel.openLibraryFolder(library)
                }
                .buttonStyle(.bordered)
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

    private func migrationBlock(
        title: String,
        subtitle: String,
        note: String,
        recentActivity: KnowledgeBaseOverviewViewModel.MigrationActivitySummary?,
        primaryTitle: String,
        secondaryTitle: String?,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))

            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(note)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let recentActivity {
                migrationActivityRow(
                    title: recentActivity.title,
                    detail: recentActivity.detail,
                    timestamp: recentActivity.timestamp,
                    isFailure: recentActivity.isFailure
                )
            } else {
                Text(L10n.tr("settings.knowledge.overview.migration.no_recent"))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func migrationActivityRow(
        title: String,
        detail: String,
        timestamp: String,
        isFailure: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isFailure ? Color.red : Color.green)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.tr("settings.knowledge.overview.migration.recent"))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(timestamp)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(2)

                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
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

                if let libraryName = entry.metadata["library_name"], !libraryName.isEmpty {
                    badge(String(format: L10n.tr("settings.knowledge.activity.library"), libraryName))
                }

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

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func statusBanner(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.16), lineWidth: 0.8)
            )
    }

    private func openImportLibraryPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("settings.knowledge.overview.import.title")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            pendingImportPreview = viewModel.inspectLibraryPackage(at: url)
        }
    }

    private func openExportLibraryPanel(for library: KnowledgeLibrary) {
        let panel = NSSavePanel()
        panel.title = L10n.tr("settings.knowledge.overview.export.title")
        panel.nameFieldStringValue = "\(library.name).skykb"
        if panel.runModal() == .OK, let url = panel.url {
            Task { _ = await viewModel.exportLibrary(library, to: url) }
        }
    }

    private func openExportBackupPanel() {
        let panel = NSSavePanel()
        panel.title = L10n.tr("settings.knowledge.overview.backup.title")
        panel.nameFieldStringValue = "SkyAgentKnowledgeBackup.skybackup"
        if panel.runModal() == .OK, let url = panel.url {
            Task { _ = await viewModel.exportBackup(to: url) }
        }
    }

    private func openRestoreBackupPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("settings.knowledge.overview.restore.title")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            pendingRestorePreview = viewModel.inspectBackupPackage(at: url)
        }
    }

    private func importPreviewSheet(_ preview: KnowledgeLibraryPackagePreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("settings.knowledge.overview.import.preview.title"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(L10n.tr("settings.knowledge.overview.import.preview.subtitle"))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                previewRow(L10n.tr("settings.knowledge.overview.import.preview.library"), preview.libraryName)
                previewRow(L10n.tr("settings.knowledge.overview.import.preview.exported_at"), Self.dateFormatter.string(from: preview.exportedAt))
                previewRow(L10n.tr("settings.knowledge.overview.import.preview.documents"), "\(preview.documentCount)")
                previewRow(L10n.tr("settings.knowledge.overview.import.preview.chunks"), "\(preview.chunkCount)")
                previewRow(L10n.tr("settings.knowledge.overview.import.preview.jobs"), "\(preview.importJobCount)")
                previewRow(L10n.tr("settings.knowledge.overview.import.preview.format"), "v\(preview.formatVersion)")
                if let sourceRoot = preview.sourceRoot, !sourceRoot.isEmpty {
                    previewRow(L10n.tr("settings.knowledge.overview.import.preview.source"), sourceRoot, monospace: true)
                }
                previewRow(L10n.tr("settings.knowledge.overview.import.preview.path"), preview.path, monospace: true)
            }

            Spacer()

            HStack {
                Button(L10n.tr("common.cancel")) {
                    pendingImportPreview = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(L10n.tr("settings.knowledge.overview.import")) {
                    let packageURL = URL(fileURLWithPath: preview.path, isDirectory: true)
                    Task {
                        if let library = await viewModel.importLibraryPackage(from: packageURL) {
                            selectedLibrary = library
                        }
                        pendingImportPreview = nil
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 420)
    }

    private func restorePreviewSheet(_ preview: KnowledgeBackupPackagePreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("settings.knowledge.overview.restore.preview.title"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(L10n.tr("settings.knowledge.overview.restore.preview.subtitle"))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                previewRow(L10n.tr("settings.knowledge.overview.restore.preview.exported_at"), Self.dateFormatter.string(from: preview.exportedAt))
                previewRow(L10n.tr("settings.knowledge.overview.restore.preview.libraries"), "\(preview.libraryCount)")
                previewRow(L10n.tr("settings.knowledge.overview.restore.preview.sidecar"), preview.includesSidecarConfig ? L10n.tr("common.yes") : L10n.tr("common.no"))
                previewRow(L10n.tr("settings.knowledge.overview.restore.preview.maintenance"), preview.includesMaintenanceState ? L10n.tr("common.yes") : L10n.tr("common.no"))
                previewRow(L10n.tr("settings.knowledge.overview.restore.preview.format"), "v\(preview.formatVersion)")
                previewRow(L10n.tr("settings.knowledge.overview.restore.preview.path"), preview.path, monospace: true)
            }

            Text(L10n.tr("settings.knowledge.overview.restore.confirm.message"))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Button(L10n.tr("common.cancel")) {
                    pendingRestorePreview = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(L10n.tr("settings.knowledge.overview.restore")) {
                    let packageURL = URL(fileURLWithPath: preview.path, isDirectory: true)
                    Task {
                        _ = await viewModel.restoreBackup(from: packageURL)
                        pendingRestorePreview = nil
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 340, idealHeight: 400)
    }

    private func previewRow(_ title: String, _ value: String, monospace: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospace ? .system(size: 12, design: .monospaced) : .system(size: 12.5, weight: .medium, design: .rounded))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
        )
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

    private func maintenanceReasonLabel(_ reason: String) -> String {
        switch reason {
        case "web_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.web")
        case "workspace_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.workspace")
        default:
            return reason
        }
    }

    private func maintenanceCandidateDate(_ candidate: KnowledgeMaintenanceCandidateSummary) -> String {
        if candidate.isDue {
            return L10n.tr("settings.knowledge.maintenance.queue_due_now")
        }
        return candidate.nextEligibleAt.map { Self.dateFormatter.string(from: $0) }
            ?? L10n.tr("settings.knowledge.maintenance.never")
    }

    private func maintenanceCandidateLine(_ candidate: KnowledgeMaintenanceCandidateSummary) -> String {
        if candidate.isDue {
            return L10n.tr(
                "settings.knowledge.maintenance.library_due",
                maintenanceReasonLabel(candidate.reason)
            )
        }

        if let nextEligibleAt = candidate.nextEligibleAt {
            return L10n.tr(
                "settings.knowledge.maintenance.library_next",
                maintenanceReasonLabel(candidate.reason),
                Self.dateFormatter.string(from: nextEligibleAt)
            )
        }

        return maintenanceReasonLabel(candidate.reason)
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
                        let library = await viewModel.createLibrary(name: newLibraryName, sourceRoot: newLibrarySourceRoot)
                        showCreateLibrarySheet = false
                        selectedLibrary = library
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 280, idealHeight: 320)
    }
}

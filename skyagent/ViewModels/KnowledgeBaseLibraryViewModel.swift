import SwiftUI
import AppKit
import Combine

@MainActor
final class KnowledgeBaseLibraryViewModel: ObservableObject {
    enum ImportFilter: String, CaseIterable, Identifiable {
        case all
        case failed
        case running
        case succeeded

        var id: String { rawValue }
    }

    struct ImportFailureSummary: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let count: Int
        let sourceLabels: [String]
        let latestAt: Date
    }

    @Published private(set) var library: KnowledgeLibrary
    @Published private(set) var documents: [KnowledgeDocument] = []
    @Published private(set) var importJobs: [KnowledgeImportJob] = []
    @Published private(set) var sidecarStatus: KnowledgeBaseSidecarStatus?
    @Published private(set) var maintenancePlan: KnowledgeMaintenancePlan?
    @Published private(set) var recentActivity: [PersistedLogEvent] = []
    @Published private(set) var selectedDocument: KnowledgeDocument?
    @Published private(set) var selectedDocumentSnippets: [KnowledgeDocumentSnippet] = []
    @Published private(set) var queryResults: [RetrievalHit] = []
    @Published private(set) var storageMetrics: KnowledgeLibraryStorageMetrics?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isImportRunning = false
    @Published private(set) var isQueryRunning = false
    @Published private(set) var isRebuilding = false
    @Published private(set) var isIncrementalRefreshing = false
    @Published private(set) var isDeletingLibrary = false
    @Published private(set) var deletingDocumentIDs: Set<UUID> = []
    @Published private(set) var mutatingImportJobIDs: Set<UUID> = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published var documentSearchText = ""
    @Published var importSearchText = ""
    @Published var selectedImportFilter: ImportFilter = .all
    @Published var selectedFailureReasonID: String?
    @Published var queryText = ""

    private let service: KnowledgeBaseService
    private weak var conversationStore: ConversationStore?
    let focusedDocumentID: UUID?
    let focusedCitation: String?
    let focusedSnippet: String?
    private var refreshFromDiskToken = UUID()

    private struct DiskSnapshot {
        let library: KnowledgeLibrary
        let storageMetrics: KnowledgeLibraryStorageMetrics?
        let documents: [KnowledgeDocument]
        let importJobs: [KnowledgeImportJob]
        let maintenancePlan: KnowledgeMaintenancePlan?
        let recentActivity: [PersistedLogEvent]
        let selectedDocument: KnowledgeDocument?
        let selectedDocumentSnippets: [KnowledgeDocumentSnippet]
    }

    init(
        library: KnowledgeLibrary,
        focusDocumentID: UUID? = nil,
        focusCitation: String? = nil,
        focusSnippet: String? = nil,
        conversationStore: ConversationStore? = nil,
        service: KnowledgeBaseService? = nil
    ) {
        self.library = library
        self.focusedDocumentID = focusDocumentID
        self.focusedCitation = focusCitation?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.focusedSnippet = focusSnippet?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.conversationStore = conversationStore
        self.service = service ?? .shared
        refreshFromDisk()
    }

    var libraryDirectoryURL: URL {
        service.libraryDirectoryURL(for: library.id)
    }

    var importCount: Int {
        importJobs.count
    }

    var failedImportJobs: [KnowledgeImportJob] {
        importJobs.filter { $0.status == .failed }
    }

    var failedImportCount: Int {
        failedImportJobs.count
    }

    var actionableFailedImportJobs: [KnowledgeImportJob] {
        if let selectedFailureReasonID, !selectedFailureReasonID.isEmpty {
            return failedImportJobs.filter { failureReasonID(for: $0.errorMessage) == selectedFailureReasonID }
        }
        return failedImportJobs
    }

    var failedImportReasonSummaries: [ImportFailureSummary] {
        var grouped: [String: (title: String, detail: String?, jobs: [KnowledgeImportJob], latestAt: Date)] = [:]

        for job in failedImportJobs {
            let classification = classifyFailureReason(for: job.errorMessage)
            if var existing = grouped[classification.id] {
                existing.jobs.append(job)
                if job.updatedAt > existing.latestAt {
                    existing.latestAt = job.updatedAt
                    if let detail = classification.detail, !detail.isEmpty {
                        existing.detail = detail
                    }
                }
                grouped[classification.id] = existing
            } else {
                grouped[classification.id] = (
                    title: classification.title,
                    detail: classification.detail,
                    jobs: [job],
                    latestAt: job.updatedAt
                )
            }
        }

        return grouped.map { key, item in
                ImportFailureSummary(
                    id: key,
                    title: item.title,
                    detail: item.detail,
                    count: item.jobs.count,
                    sourceLabels: Array(uniqueSourceLabels(for: item.jobs).prefix(3)),
                    latestAt: item.latestAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.latestAt != rhs.latestAt { return lhs.latestAt > rhs.latestAt }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    var latestFailedImportText: String? {
        guard let latest = failedImportJobs.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        return L10n.tr(
            "settings.knowledge.manager.failed_overview.latest",
            displayName(for: latest),
            Self.dateFormatter.string(from: latest.updatedAt)
        )
    }

    var activeFailureReasonTitle: String? {
        guard let selectedFailureReasonID else { return nil }
        return failedImportReasonSummaries.first(where: { $0.id == selectedFailureReasonID })?.title
    }

    var runningImportCount: Int {
        importJobs.filter { $0.status == .running || $0.status == .pending }.count
    }

    var completedImportCount: Int {
        importJobs.filter { $0.status == .succeeded }.count
    }

    var totalImportedCount: Int {
        importJobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
    }

    var totalSkippedCount: Int {
        importJobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
    }

    var filteredDocuments: [KnowledgeDocument] {
        let needle = documentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return documents }
        return documents.filter { document in
            [
                document.name,
                document.originalPath ?? "",
                document.id.uuidString
            ].contains { $0.lowercased().contains(needle) }
        }
    }

    var filteredImportJobs: [KnowledgeImportJob] {
        let needle = importSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredByStatus = importJobs.filter { job in
            switch selectedImportFilter {
            case .all:
                return true
            case .failed:
                return job.status == .failed
            case .running:
                return job.status == .running || job.status == .pending
            case .succeeded:
                return job.status == .succeeded
            }
        }

        let filteredByReason = filteredByStatus.filter { job in
            guard let selectedFailureReasonID, !selectedFailureReasonID.isEmpty else { return true }
            return failureReasonID(for: job.errorMessage) == selectedFailureReasonID
        }

        guard !needle.isEmpty else { return filteredByReason }
        return filteredByReason.filter { job in
            [
                job.title ?? "",
                job.source,
                job.errorMessage ?? "",
                job.id.uuidString
            ].contains { $0.lowercased().contains(needle) }
        }
    }

    func importFilterTitle(_ filter: ImportFilter) -> String {
        switch filter {
        case .all:
            return L10n.tr("settings.knowledge.manager.import_filter.all")
        case .failed:
            return L10n.tr("settings.knowledge.manager.import_filter.failed")
        case .running:
            return L10n.tr("settings.knowledge.manager.import_filter.running")
        case .succeeded:
            return L10n.tr("settings.knowledge.manager.import_filter.succeeded")
        }
    }

    func importFilterCount(_ filter: ImportFilter) -> Int {
        switch filter {
        case .all:
            return importJobs.count
        case .failed:
            return failedImportCount
        case .running:
            return runningImportCount
        case .succeeded:
            return completedImportCount
        }
    }

    func selectFailureReason(_ summary: ImportFailureSummary) {
        selectedImportFilter = .failed
        selectedFailureReasonID = summary.id
    }

    func clearFailureReasonFilter() {
        selectedFailureReasonID = nil
    }

    var isBusy: Bool {
        isRefreshing || isImportRunning || isRebuilding || isIncrementalRefreshing || isDeletingLibrary || !deletingDocumentIDs.isEmpty || !mutatingImportJobIDs.isEmpty
    }

    var hasSelectedDocumentPreview: Bool {
        selectedDocument != nil
    }

    var formattedTotalStorageSize: String {
        Self.byteCountFormatter.string(fromByteCount: storageMetrics?.totalBytes ?? 0)
    }

    var formattedStorageBreakdown: [(title: String, value: String)] {
        guard let storageMetrics else { return [] }
        return [
            (L10n.tr("settings.knowledge.manager.storage.source"), Self.byteCountFormatter.string(fromByteCount: storageMetrics.sourceBytes)),
            (L10n.tr("settings.knowledge.manager.storage.parsed"), Self.byteCountFormatter.string(fromByteCount: storageMetrics.parsedBytes)),
            (L10n.tr("settings.knowledge.manager.storage.chunks"), Self.byteCountFormatter.string(fromByteCount: storageMetrics.chunksBytes)),
            (L10n.tr("settings.knowledge.manager.storage.index"), Self.byteCountFormatter.string(fromByteCount: storageMetrics.indexBytes)),
            (L10n.tr("settings.knowledge.manager.storage.cache"), Self.byteCountFormatter.string(fromByteCount: storageMetrics.cacheBytes)),
            (L10n.tr("settings.knowledge.manager.storage.meta"), Self.byteCountFormatter.string(fromByteCount: storageMetrics.metadataBytes))
        ]
    }

    var failedImportReasonSummaryText: String? {
        let reasonCount = failedImportReasonSummaries.count
        guard failedImportCount > 0 else { return nil }
        return L10n.tr(
            "settings.knowledge.manager.failed_overview.summary",
            "\(failedImportCount)",
            "\(reasonCount)"
        )
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        refreshFromDisk()

        switch await service.sidecarStatus() {
        case .success(let status):
            sidecarStatus = status
        case .failure(let error):
            sidecarStatus = KnowledgeBaseSidecarStatus(
                status: "offline",
                message: error.description,
                version: nil
            )
        }
        maintenancePlan = service.maintenancePlan()
    }

    func presentDocumentDetails(
        _ document: KnowledgeDocument,
        preferredCitation: String? = nil,
        preferredSnippet: String? = nil
    ) {
        selectedDocument = document
        let snippets = service.documentSnippets(documentId: document.id, in: library.id)
        selectedDocumentSnippets = Self.prioritizedSnippets(
            snippets,
            preferredCitation: preferredCitation ?? focusedCitation,
            preferredSnippet: preferredSnippet ?? focusedSnippet
        )
    }

    func dismissDocumentDetails() {
        selectedDocument = nil
        selectedDocumentSnippets = []
    }

    func presentFocusedDocumentIfNeeded() {
        guard selectedDocument == nil, let focusedDocumentID else { return }
        guard let document = documents.first(where: { $0.id == focusedDocumentID }) else { return }
        presentDocumentDetails(document, preferredCitation: focusedCitation, preferredSnippet: focusedSnippet)
    }

    func runQuery() async {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isQueryRunning else { return }

        isQueryRunning = true
        errorMessage = nil
        statusMessage = nil
        defer { isQueryRunning = false }

        let startedAt = Date()
        let result = await service.queryKnowledge(libraryId: library.id, query: trimmed, topK: 6)
        let durationMs = Date().timeIntervalSince(startedAt) * 1000

        switch result {
        case .success(let hits):
            queryResults = hits
            statusMessage = hits.isEmpty
                ? L10n.tr("settings.knowledge.manager.query_empty")
                : L10n.tr("settings.knowledge.manager.query_success", "\(hits.count)")
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_query_preview_finished",
                status: .succeeded,
                durationMs: durationMs,
                summary: hits.isEmpty ? "知识库手动检索无命中" : "知识库手动检索完成",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "query": .string(trimmed),
                    "hit_count": .int(hits.count)
                ]
            )
        case .failure(let error):
            queryResults = []
            errorMessage = error.description
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_query_preview_finished",
                status: .failed,
                durationMs: durationMs,
                summary: "知识库手动检索失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "query": .string(trimmed),
                    "error": .string(error.description)
                ]
            )
        }
    }

    func clearQueryResults() {
        queryResults = []
        queryText = ""
    }

    func openDocumentFromHit(_ hit: RetrievalHit) {
        guard let documentID = hit.documentID,
              let document = documents.first(where: { $0.id == documentID }) ?? service.document(by: documentID, in: library.id) else {
            return
        }
        presentDocumentDetails(document, preferredCitation: hit.citation, preferredSnippet: hit.snippet)
    }

    func rebuildLibrary() async {
        guard !isBusy else { return }
        let startedAt = Date()
        isRebuilding = true
        errorMessage = nil
        statusMessage = L10n.tr("settings.knowledge.manager.rebuild_running")
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_rebuild_started",
            status: .started,
            summary: "知识库重建开始",
            metadata: [
                "library_id": .string(library.id.uuidString),
                "library_name": .string(library.name)
            ]
        )
        defer { isRebuilding = false }

        let jobs = await service.rebuildLibrary(libraryId: library.id)
        await refresh()
        let durationMs = Date().timeIntervalSince(startedAt) * 1000

        if jobs.isEmpty {
            statusMessage = L10n.tr("settings.knowledge.manager.rebuild_empty")
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_rebuild_finished",
                status: .skipped,
                durationMs: durationMs,
                summary: "知识库重建跳过",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "reason": .string("no_import_jobs"),
                    "imported_count": .int(0),
                    "skipped_count": .int(0),
                    "failed_count": .int(0)
                ]
            )
        } else if jobs.contains(where: { $0.status == .failed }) {
            let imported = jobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
            let skipped = jobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
            let failed = jobs.reduce(0) { $0 + max(0, $1.failedCount ?? ($1.status == .failed ? 1 : 0)) }
            errorMessage = L10n.tr("settings.knowledge.manager.rebuild_partial_failed")
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_rebuild_finished",
                status: .failed,
                durationMs: durationMs,
                summary: "知识库重建部分失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "job_count": .int(jobs.count),
                    "imported_count": .int(imported),
                    "skipped_count": .int(skipped),
                    "failed_count": .int(failed)
                ]
            )
        } else {
            let imported = jobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
            let skipped = jobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
            let failed = jobs.reduce(0) { $0 + max(0, $1.failedCount ?? 0) }
            statusMessage = L10n.tr(
                "settings.knowledge.manager.rebuild_success",
                "\(jobs.count)",
                "\(imported)",
                "\(skipped)"
            )
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_rebuild_finished",
                status: .succeeded,
                durationMs: durationMs,
                summary: "知识库重建完成",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "job_count": .int(jobs.count),
                    "imported_count": .int(imported),
                    "skipped_count": .int(skipped),
                    "failed_count": .int(failed)
                ]
            )
        }
    }

    var lastMaintenanceEvent: PersistedLogEvent? {
        recentActivity.first { entry in
            entry.event == "kb_auto_rebuild_finished" || entry.event == "kb_incremental_refresh_finished"
        }
    }

    var lastMaintenanceDateText: String? {
        lastMaintenanceEvent.map { Self.dateFormatter.string(from: $0.timestamp) }
    }

    var lastMaintenanceReasonText: String? {
        guard let reason = lastMaintenanceEvent?.metadata["reason"] else { return nil }
        switch reason {
        case "web_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.web")
        case "workspace_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.workspace")
        case "manual_incremental_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.manual")
        default:
            return reason
        }
    }

    var maintenanceStatusText: String {
        guard let event = lastMaintenanceEvent else {
            return L10n.tr("settings.knowledge.manager.maintenance.never")
        }
        switch event.status {
        case LogStatus.succeeded.rawValue:
            return L10n.tr("settings.knowledge.manager.maintenance.status.succeeded")
        case LogStatus.failed.rawValue:
            return L10n.tr("settings.knowledge.manager.maintenance.status.failed")
        case LogStatus.started.rawValue, LogStatus.progress.rawValue:
            return L10n.tr("settings.knowledge.manager.maintenance.status.running")
        default:
            return L10n.tr("settings.knowledge.manager.maintenance.status.idle")
        }
    }

    var maintenanceResultSummaryText: String? {
        guard let event = lastMaintenanceEvent else { return nil }
        let imported = Int(event.metadata["imported_count"] ?? "") ?? 0
        let skipped = Int(event.metadata["skipped_count"] ?? "") ?? 0
        let failed = Int(event.metadata["failed_count"] ?? "") ?? 0
        let totalJobs = Int(event.metadata["job_count"] ?? "") ?? 0

        guard totalJobs > 0 || imported > 0 || skipped > 0 || failed > 0 else { return nil }
        return L10n.tr(
            "settings.knowledge.manager.maintenance.result_summary",
            "\(imported)",
            "\(skipped)",
            "\(failed)",
            "\(totalJobs)"
        )
    }

    var maintenanceCandidate: KnowledgeMaintenanceCandidateSummary? {
        maintenancePlan?.candidates.first(where: { $0.libraryID == library.id })
    }

    var nextMaintenanceDateText: String? {
        maintenanceCandidate?.nextEligibleAt.map { Self.dateFormatter.string(from: $0) }
    }

    var maintenanceScheduleText: String? {
        guard let candidate = maintenanceCandidate else { return nil }
        if candidate.isDue {
            return L10n.tr(
                "settings.knowledge.manager.maintenance.schedule_due",
                maintenanceReasonLabel(candidate.reason),
                "\(max(1, Int(candidate.stalenessHours.rounded())))"
            )
        }
        guard let nextDate = candidate.nextEligibleAt else { return nil }
        return L10n.tr(
            "settings.knowledge.manager.maintenance.schedule_next",
            maintenanceReasonLabel(candidate.reason),
            Self.dateFormatter.string(from: nextDate)
        )
    }

    func runIncrementalRefresh() async {
        guard !isBusy else { return }
        let startedAt = Date()
        isIncrementalRefreshing = true
        errorMessage = nil
        statusMessage = L10n.tr("settings.knowledge.manager.maintenance.running")
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_incremental_refresh_started",
            status: .started,
            summary: "知识库增量刷新开始",
            metadata: [
                "library_id": .string(library.id.uuidString),
                "library_name": .string(library.name),
                "reason": .string("manual_incremental_refresh")
            ]
        )
        defer { isIncrementalRefreshing = false }

        let jobs = await service.refreshLibraryIncrementally(libraryId: library.id)
        await refresh()
        let durationMs = Date().timeIntervalSince(startedAt) * 1000

        if jobs.isEmpty {
            statusMessage = L10n.tr("settings.knowledge.manager.maintenance.empty")
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_incremental_refresh_finished",
                status: .skipped,
                durationMs: durationMs,
                summary: "知识库增量刷新跳过",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "reason": .string("manual_incremental_refresh"),
                    "job_count": .int(0),
                    "imported_count": .int(0),
                    "skipped_count": .int(0),
                    "failed_count": .int(0)
                ]
            )
        } else if jobs.contains(where: { $0.status == .failed }) {
            let imported = jobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
            let skipped = jobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
            let failed = jobs.reduce(0) { $0 + max(0, $1.failedCount ?? ($1.status == .failed ? 1 : 0)) }
            errorMessage = L10n.tr("settings.knowledge.manager.maintenance.partial_failed")
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_incremental_refresh_finished",
                status: .failed,
                durationMs: durationMs,
                summary: "知识库增量刷新部分失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "reason": .string("manual_incremental_refresh"),
                    "job_count": .int(jobs.count),
                    "imported_count": .int(imported),
                    "skipped_count": .int(skipped),
                    "failed_count": .int(failed)
                ]
            )
        } else {
            let imported = jobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
            let skipped = jobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
            let failed = jobs.reduce(0) { $0 + max(0, $1.failedCount ?? 0) }
            statusMessage = L10n.tr(
                "settings.knowledge.manager.maintenance.success",
                "\(jobs.count)",
                "\(imported)",
                "\(skipped)"
            )
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_incremental_refresh_finished",
                status: .succeeded,
                durationMs: durationMs,
                summary: "知识库增量刷新完成",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "reason": .string("manual_incremental_refresh"),
                    "job_count": .int(jobs.count),
                    "imported_count": .int(imported),
                    "skipped_count": .int(skipped),
                    "failed_count": .int(failed)
                ]
            )
        }
    }

    func deleteDocument(_ document: KnowledgeDocument) async {
        guard !isBusy else { return }
        deletingDocumentIDs.insert(document.id)
        errorMessage = nil
        statusMessage = nil
        defer { deletingDocumentIDs.remove(document.id) }

        let removed = service.removeDocument(id: document.id, from: library.id)
        await refresh()

        if removed {
            statusMessage = L10n.tr("settings.knowledge.manager.document_deleted", document.name)
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_document_deleted",
                status: .succeeded,
                summary: "知识库文档已移除",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "document_id": .string(document.id.uuidString),
                    "document_name": .string(document.name)
                ]
            )
        } else {
            errorMessage = L10n.tr("settings.knowledge.manager.document_delete_failed")
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_document_deleted",
                status: .failed,
                summary: "知识库文档移除失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "document_id": .string(document.id.uuidString),
                    "document_name": .string(document.name)
                ]
            )
        }
    }

    func reimportDocument(_ document: KnowledgeDocument) async {
        guard !isBusy else { return }
        let source = document.originalPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !source.isEmpty else {
            errorMessage = L10n.tr("settings.knowledge.manager.document_reimport_missing_source")
            return
        }

        isImportRunning = true
        errorMessage = nil
        statusMessage = L10n.tr("settings.knowledge.manager.document_reimport_running", document.name)
        let startedAt = Date()
        defer { isImportRunning = false }

        let job = await service.enqueueAndRunImport(
            libraryId: library.id,
            sourceType: document.sourceType,
            source: source,
            title: document.name
        )
        await refresh()
        let durationMs = Date().timeIntervalSince(startedAt) * 1000

        switch job.status {
        case .succeeded:
            statusMessage = L10n.tr(
                "settings.knowledge.manager.document_reimport_success",
                document.name,
                "\(job.importedCount ?? 0)",
                "\(job.skippedCount ?? 0)"
            )
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_document_reimported",
                status: .succeeded,
                durationMs: durationMs,
                summary: "知识库文档已重新导入",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "document_id": .string(document.id.uuidString),
                    "document_name": .string(document.name),
                    "source": .string(source),
                    "imported_count": .int(job.importedCount ?? 0),
                    "skipped_count": .int(job.skippedCount ?? 0),
                    "failed_count": .int(job.failedCount ?? 0)
                ]
            )
        case .failed:
            errorMessage = L10n.tr("settings.knowledge.manager.document_reimport_failed", document.name)
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_document_reimported",
                status: .failed,
                durationMs: durationMs,
                summary: "知识库文档重新导入失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "document_id": .string(document.id.uuidString),
                    "document_name": .string(document.name),
                    "source": .string(source),
                    "error": .string(job.errorMessage ?? "")
                ]
            )
        default:
            statusMessage = L10n.tr("settings.knowledge.import_pending")
        }
    }

    func deleteLibrary() async -> Bool {
        guard !isBusy else { return false }
        isDeletingLibrary = true
        errorMessage = nil
        statusMessage = nil
        defer { isDeletingLibrary = false }

        let libraryID = library.id
        let libraryName = library.name
        service.deleteLibrary(id: libraryID)
        conversationStore?.removeKnowledgeLibraryReference(libraryID.uuidString)
        statusMessage = L10n.tr("settings.knowledge.manager.library_deleted", libraryName)
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_library_deleted",
            status: .succeeded,
            summary: "知识库已删除",
            metadata: [
                "library_id": .string(libraryID.uuidString),
                "library_name": .string(libraryName)
            ]
        )
        return true
    }

    func retryImportJob(_ job: KnowledgeImportJob) async {
        mutatingImportJobIDs.insert(job.id)
        errorMessage = nil
        statusMessage = L10n.tr("settings.knowledge.manager.import_retry_running")
        let startedAt = Date()
        defer { mutatingImportJobIDs.remove(job.id) }

        let result = await service.retryImportJob(id: job.id)
        await refresh()
        let durationMs = Date().timeIntervalSince(startedAt) * 1000

        if let result {
            if result.status == .succeeded {
                statusMessage = L10n.tr("settings.knowledge.manager.import_retry_success")
                await LoggerService.shared.log(
                    category: .rag,
                    event: "kb_import_retry_finished",
                    status: .succeeded,
                    durationMs: durationMs,
                    summary: "知识库导入重试成功",
                    metadata: [
                        "library_id": .string(library.id.uuidString),
                        "job_id": .string(job.id.uuidString),
                        "source": .string(job.source)
                    ]
                )
            } else {
                errorMessage = result.errorMessage ?? L10n.tr("settings.knowledge.manager.import_retry_failed")
                await LoggerService.shared.log(
                    level: .warn,
                    category: .rag,
                    event: "kb_import_retry_finished",
                    status: .failed,
                    durationMs: durationMs,
                    summary: "知识库导入重试失败",
                    metadata: [
                        "library_id": .string(library.id.uuidString),
                        "job_id": .string(job.id.uuidString),
                        "source": .string(job.source)
                    ]
                )
            }
        } else {
            errorMessage = L10n.tr("settings.knowledge.manager.import_retry_failed")
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_import_retry_finished",
                status: .failed,
                durationMs: durationMs,
                summary: "知识库导入重试失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "job_id": .string(job.id.uuidString),
                    "source": .string(job.source)
                ]
            )
        }
    }

    func removeImportJob(_ job: KnowledgeImportJob) async {
        mutatingImportJobIDs.insert(job.id)
        errorMessage = nil
        statusMessage = nil
        defer { mutatingImportJobIDs.remove(job.id) }

        service.removeImportJob(id: job.id)
        await refresh()
        statusMessage = L10n.tr("settings.knowledge.manager.import_removed")
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_import_record_removed",
            status: .succeeded,
            summary: "知识库导入记录已移除",
            metadata: [
                "library_id": .string(library.id.uuidString),
                "job_id": .string(job.id.uuidString),
                "source": .string(job.source)
            ]
        )
    }

    func retryFailedImportJobs() async {
        let jobs = actionableFailedImportJobs
        guard !jobs.isEmpty, !isBusy else { return }

        errorMessage = nil
        statusMessage = L10n.tr("settings.knowledge.manager.import_retry_all_running", "\(jobs.count)")
        let startedAt = Date()
        var succeededCount = 0
        var failedCount = 0

        for job in jobs {
            mutatingImportJobIDs.insert(job.id)
            let result = await service.retryImportJob(id: job.id)
            mutatingImportJobIDs.remove(job.id)

            if result?.status == .succeeded {
                succeededCount += 1
            } else {
                failedCount += 1
            }
        }

        await refresh()
        let durationMs = Date().timeIntervalSince(startedAt) * 1000

        if failedCount == 0 {
            statusMessage = L10n.tr("settings.knowledge.manager.import_retry_all_success", "\(succeededCount)")
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_import_retry_batch_finished",
                status: .succeeded,
                durationMs: durationMs,
                summary: "知识库批量重试成功",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "succeeded_count": .int(succeededCount),
                    "failed_count": .int(failedCount)
                ]
            )
        } else {
            errorMessage = L10n.tr("settings.knowledge.manager.import_retry_all_partial", "\(succeededCount)", "\(failedCount)")
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_import_retry_batch_finished",
                status: .failed,
                durationMs: durationMs,
                summary: "知识库批量重试部分失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "succeeded_count": .int(succeededCount),
                    "failed_count": .int(failedCount)
                ]
            )
        }
    }

    func removeFailedImportJobs() async {
        let jobs = actionableFailedImportJobs
        guard !jobs.isEmpty, !isBusy else { return }

        errorMessage = nil
        statusMessage = L10n.tr("settings.knowledge.manager.import_remove_failed_running", "\(jobs.count)")
        let startedAt = Date()

        for job in jobs {
            mutatingImportJobIDs.insert(job.id)
            service.removeImportJob(id: job.id)
            mutatingImportJobIDs.remove(job.id)
        }

        await refresh()
        statusMessage = L10n.tr("settings.knowledge.manager.import_remove_failed_success", "\(jobs.count)")
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_import_failed_records_removed",
            status: .succeeded,
            durationMs: Date().timeIntervalSince(startedAt) * 1000,
            summary: "知识库失败导入记录已批量移除",
            metadata: [
                "library_id": .string(library.id.uuidString),
                "removed_count": .int(jobs.count)
            ]
        )
    }

    func openSource(for document: KnowledgeDocument) {
        guard let originalPath = document.originalPath, !originalPath.isEmpty else { return }

        if let url = URL(string: originalPath), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }

        let fileURL = URL(fileURLWithPath: originalPath)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    func openSource(for job: KnowledgeImportJob) {
        let source = job.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }

        if let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }

        let fileURL = URL(fileURLWithPath: source)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    func openSource(for hit: RetrievalHit) {
        if let source = hit.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            if let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                return
            }

            let fileURL = URL(fileURLWithPath: source)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return
            }
        }

        guard let documentID = hit.documentID,
              let document = documents.first(where: { $0.id == documentID }) else {
            return
        }
        openSource(for: document)
    }

    func openEventLogsFolder() {
        NSWorkspace.shared.open(AppStoragePaths.eventLogsDir)
    }

    func openSidecarLogsFolder() {
        NSWorkspace.shared.open(AppStoragePaths.knowledgeSidecarLogsDir)
    }

    func importFile(from url: URL) async {
        guard !isBusy else { return }
        await runImport(sourceType: .file, source: url.path, title: url.lastPathComponent)
    }

    func importFolder(from url: URL) async {
        guard !isBusy else { return }
        await runImport(sourceType: .folder, source: url.path, title: url.lastPathComponent)
    }

    func importWeb(from urlString: String) async {
        guard !isBusy else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runImport(sourceType: .web, source: trimmed, title: trimmed)
    }

    private func runImport(sourceType: KnowledgeSourceType, source: String, title: String?) async {
        isImportRunning = true
        errorMessage = nil
        statusMessage = nil
        let job = await KnowledgeBaseService.shared.enqueueAndRunImport(
            libraryId: library.id,
            sourceType: sourceType,
            source: source,
            title: title
        )
        isImportRunning = false
        await refresh()
        applyImportStatus(job)
    }

    private func applyImportStatus(_ job: KnowledgeImportJob) {
        switch job.status {
        case .succeeded:
            statusMessage = L10n.tr(
                "settings.knowledge.import_done_detailed",
                "\(job.importedCount ?? 0)",
                "\(job.skippedCount ?? 0)",
                "\(job.failedCount ?? 0)"
            )
        case .failed:
            errorMessage = L10n.tr("settings.knowledge.import_failed", job.errorMessage ?? "")
        default:
            statusMessage = L10n.tr("settings.knowledge.import_pending")
        }
    }

    private func classifyFailureReason(for message: String?) -> (id: String, title: String, detail: String?) {
        let cleaned = normalizedFailureMessage(message)
        let normalized = cleaned.lowercased()

        if normalized.contains("timed out") || normalized.contains("timeout") || normalized.contains("超时") {
            return ("timeout", L10n.tr("settings.knowledge.manager.failed_overview.reason.timeout"), cleaned)
        }
        if normalized.contains("permission") || normalized.contains("not permitted") || normalized.contains("denied") || normalized.contains("权限") {
            return ("permission", L10n.tr("settings.knowledge.manager.failed_overview.reason.permission"), cleaned)
        }
        if normalized.contains("no such file") || normalized.contains("file doesn") || normalized.contains("not found") || normalized.contains("找不到") || normalized.contains("不存在") {
            return ("missing_source", L10n.tr("settings.knowledge.manager.failed_overview.reason.missing_source"), cleaned)
        }
        if normalized.contains("unsupported") || normalized.contains("不支持") || normalized.contains("unknown format") {
            return ("unsupported", L10n.tr("settings.knowledge.manager.failed_overview.reason.unsupported"), cleaned)
        }
        if normalized.contains("could not connect")
            || normalized.contains("failed to connect")
            || normalized.contains("network connection was lost")
            || normalized.contains("无法连接")
            || normalized.contains("连接被中断")
            || normalized.contains("connection refused")
        {
            return ("network", L10n.tr("settings.knowledge.manager.failed_overview.reason.network"), cleaned)
        }
        if normalized.contains("响应异常") || normalized.contains("status code") || normalized.contains("http") {
            return ("sidecar_response", L10n.tr("settings.knowledge.manager.failed_overview.reason.sidecar_response"), cleaned)
        }
        if normalized.isEmpty {
            return ("unknown", L10n.tr("settings.knowledge.manager.failed_overview.reason.unknown"), nil)
        }
        return ("other", L10n.tr("settings.knowledge.manager.failed_overview.reason.other"), cleaned)
    }

    private func failureReasonID(for message: String?) -> String {
        classifyFailureReason(for: message).id
    }

    private func normalizedFailureMessage(_ message: String?) -> String {
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return ""
        }

        let prefixes = [
            "Sidecar 请求失败：",
            "Sidecar 响应异常：",
            "Sidecar request failed:",
            "Sidecar responded with an unexpected status:"
        ]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let separatorRange = text.range(of: "\n") {
            text = String(text[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func uniqueSourceLabels(for jobs: [KnowledgeImportJob]) -> [String] {
        var seen: Set<String> = []
        var labels: [String] = []
        for job in jobs {
            let label = displayName(for: job)
            if seen.insert(label).inserted {
                labels.append(label)
            }
        }
        return labels
    }

    private func displayName(for job: KnowledgeImportJob) -> String {
        if let title = job.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let source = job.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: source), let host = url.host, !host.isEmpty {
            let last = url.lastPathComponent
            return last.isEmpty ? host : "\(host)/\(last)"
        }
        return URL(fileURLWithPath: source).lastPathComponent
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func refreshFromDisk() {
        let libraryID = library.id
        let currentLibrary = library
        let currentFocusedDocumentID = focusedDocumentID
        let currentFocusedCitation = focusedCitation
        let currentFocusedSnippet = focusedSnippet
        let currentSelectedDocumentID = selectedDocument?.id
        let refreshToken = UUID()
        refreshFromDiskToken = refreshToken
        let service = self.service

        DispatchQueue.global(qos: .utility).async {
            let refreshedLibrary = service.library(by: libraryID) ?? currentLibrary
            let documents = service.listDocuments(libraryId: libraryID)
                .sorted { lhs, rhs in
                    if lhs.id == currentFocusedDocumentID { return true }
                    if rhs.id == currentFocusedDocumentID { return false }
                    if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            let selectedDocument = currentSelectedDocumentID.flatMap { id in
                documents.first(where: { $0.id == id })
            }
            let selectedDocumentSnippets: [KnowledgeDocumentSnippet]
            if let selectedDocument {
                let snippets = service.documentSnippets(documentId: selectedDocument.id, in: libraryID)
                selectedDocumentSnippets = Self.prioritizedSnippets(
                    snippets,
                    preferredCitation: currentFocusedCitation,
                    preferredSnippet: currentFocusedSnippet
                )
            } else {
                selectedDocumentSnippets = []
            }

            let snapshot = DiskSnapshot(
                library: refreshedLibrary,
                storageMetrics: service.storageMetrics(for: libraryID),
                documents: documents,
                importJobs: service.listImportJobs(libraryId: libraryID)
                    .sorted { $0.updatedAt > $1.updatedAt },
                maintenancePlan: service.maintenancePlan(),
                recentActivity: LogFileReader.loadRecentEvents(limit: 300, maxFiles: 7)
                    .filter { entry in
                        entry.category == LogCategory.rag.rawValue &&
                        entry.metadata["library_id"] == libraryID.uuidString
                    }
                    .prefix(12)
                    .map { $0 },
                selectedDocument: selectedDocument,
                selectedDocumentSnippets: selectedDocumentSnippets
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.refreshFromDiskToken == refreshToken else { return }
                self.library = snapshot.library
                self.storageMetrics = snapshot.storageMetrics
                self.documents = snapshot.documents
                self.importJobs = snapshot.importJobs
                self.maintenancePlan = snapshot.maintenancePlan
                self.recentActivity = snapshot.recentActivity
                self.selectedDocument = snapshot.selectedDocument
                self.selectedDocumentSnippets = snapshot.selectedDocumentSnippets
            }
        }
    }

    private func maintenanceReasonLabel(_ reason: String) -> String {
        switch reason {
        case "web_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.web")
        case "workspace_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.workspace")
        case "manual_incremental_refresh":
            return L10n.tr("settings.knowledge.manager.maintenance.reason.manual")
        default:
            return reason
        }
    }

    nonisolated private static func prioritizedSnippets(
        _ snippets: [KnowledgeDocumentSnippet],
        preferredCitation: String?,
        preferredSnippet: String?
    ) -> [KnowledgeDocumentSnippet] {
        let normalizedCitation = preferredCitation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedSnippet = preferredSnippet?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        guard !normalizedCitation.isEmpty || !normalizedSnippet.isEmpty else { return snippets }

        return snippets.sorted { lhs, rhs in
            snippetRank(lhs, citation: normalizedCitation, snippet: normalizedSnippet) <
            snippetRank(rhs, citation: normalizedCitation, snippet: normalizedSnippet)
        }
    }

    nonisolated private static func snippetRank(
        _ snippet: KnowledgeDocumentSnippet,
        citation: String,
        snippet preferredSnippet: String
    ) -> Int {
        let snippetCitation = snippet.citation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let snippetBody = snippet.snippet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !citation.isEmpty && snippetCitation == citation { return 0 }
        if !citation.isEmpty && snippetCitation.contains(citation) { return 1 }
        if !preferredSnippet.isEmpty && snippetBody == preferredSnippet { return 2 }
        if !preferredSnippet.isEmpty && snippetBody.contains(preferredSnippet) { return 3 }
        return 10
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        return formatter
    }()
}

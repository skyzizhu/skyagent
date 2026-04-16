import SwiftUI
import AppKit
import Combine

enum KnowledgeBaseOverviewFilter: String, CaseIterable, Identifiable {
    case all
    case workspace
    case active
    case manual
    case failed

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: return "settings.knowledge.overview.filter.all"
        case .workspace: return "settings.knowledge.overview.filter.workspace"
        case .active: return "settings.knowledge.overview.filter.active"
        case .manual: return "settings.knowledge.overview.filter.manual"
        case .failed: return "settings.knowledge.overview.filter.failed"
        }
    }
}

@MainActor
final class KnowledgeBaseOverviewViewModel: ObservableObject {
    struct LibraryImportHealth {
        let failed: Int
        let pending: Int
        let completed: Int
        let imported: Int
        let skipped: Int
    }

    struct MigrationActivitySummary {
        let title: String
        let detail: String
        let timestamp: String
        let isFailure: Bool
    }

    struct AuditActivitySummary {
        let title: String
        let detail: String
        let timestamp: String
        let isFailure: Bool
    }

    @Published private(set) var libraries: [KnowledgeLibrary] = []
    @Published private(set) var currentWorkspaceLibraryID: String?
    @Published private(set) var activeConversationLibraryIDs: Set<String> = []
    @Published private(set) var sidecarStatus: KnowledgeBaseSidecarStatus?
    @Published private(set) var maintenanceSummary: KnowledgeMaintenanceSummary?
    @Published private(set) var maintenancePlan: KnowledgeMaintenancePlan?
    @Published private(set) var importHealthByLibraryID: [String: LibraryImportHealth] = [:]
    @Published private(set) var recentActivity: [PersistedLogEvent] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedFilter: KnowledgeBaseOverviewFilter = .all

    private let conversationStore: ConversationStore
    private let service: KnowledgeBaseService
    private var cancellables = Set<AnyCancellable>()
    private var snapshotRefreshToken = UUID()

    private struct Snapshot {
        let libraries: [KnowledgeLibrary]
        let currentWorkspaceLibraryID: String?
        let activeConversationLibraryIDs: Set<String>
        let importHealthByLibraryID: [String: LibraryImportHealth]
        let recentActivity: [PersistedLogEvent]
        let maintenanceSummary: KnowledgeMaintenanceSummary?
        let maintenancePlan: KnowledgeMaintenancePlan?
    }

    init(
        conversationStore: ConversationStore,
        service: KnowledgeBaseService? = nil
    ) {
        self.conversationStore = conversationStore
        self.service = service ?? .shared
        bindStore()
        refreshSnapshot()
    }

    var libraryCount: Int {
        libraries.count
    }

    var totalDocumentCount: Int {
        libraries.reduce(0) { $0 + $1.documentCount }
    }

    var totalChunkCount: Int {
        libraries.reduce(0) { $0 + $1.chunkCount }
    }

    var filteredLibraries: [KnowledgeLibrary] {
        libraries.filter { library in
            matchesFilter(library) && matchesSearch(library)
        }
    }

    var filteredLibraryCount: Int {
        filteredLibraries.count
    }

    var latestLibraryMigrationActivity: MigrationActivitySummary? {
        migrationSummary(for: ["kb_library_imported", "kb_library_exported"])
    }

    var latestBackupActivity: MigrationActivitySummary? {
        migrationSummary(for: ["kb_backup_exported"])
    }

    var latestRestoreActivity: MigrationActivitySummary? {
        migrationSummary(for: ["kb_backup_restored"])
    }

    var latestAuditActivity: AuditActivitySummary? {
        guard let entry = recentActivity.first(where: { $0.event == "kb_audit_finished" }) else { return nil }
        let checked = entry.metadata["checked_libraries"] ?? "0"
        let repaired = entry.metadata["repaired_libraries"] ?? "0"
        let mismatches = entry.metadata["metadata_mismatches"] ?? "0"
        let orphans = entry.metadata["orphan_import_jobs"] ?? "0"
        let detail = L10n.tr(
            "settings.knowledge.overview.audit.result",
            checked,
            repaired,
            mismatches,
            orphans
        )
        return AuditActivitySummary(
            title: entry.summary,
            detail: detail,
            timestamp: entry.relativeTimestamp,
            isFailure: (entry.status?.lowercased() == "failed") || entry.level.lowercased() == "error"
        )
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        refreshSnapshot()
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
        maintenanceSummary = service.maintenanceSummary()
        maintenancePlan = service.maintenancePlan()
    }

    func runMaintenanceNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await service.runAutomaticMaintenanceIfNeeded(force: true)
        await refresh()
    }

    func runAudit() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let summary = await performAudit(trigger: "manual")
        statusMessage = L10n.tr(
            "settings.knowledge.overview.audit.success",
            "\(summary.checkedLibraries)",
            "\(summary.repairedLibraries)"
        )
        errorMessage = nil
    }

    func openLibraryFolder(_ library: KnowledgeLibrary) {
        NSWorkspace.shared.open(service.libraryDirectoryURL(for: library.id))
    }

    func openEventLogsFolder() {
        NSWorkspace.shared.open(AppStoragePaths.eventLogsDir)
    }

    func openSidecarLogsFolder() {
        NSWorkspace.shared.open(AppStoragePaths.knowledgeSidecarLogsDir)
    }

    @discardableResult
    func createLibrary(name: String, sourceRoot: String?) async -> KnowledgeLibrary {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceRoot = sourceRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? L10n.tr("settings.knowledge.overview.new.default_name") : trimmedName
        let library = service.createLibrary(
            named: displayName,
            sourceRoot: trimmedSourceRoot?.isEmpty == true ? nil : trimmedSourceRoot
        )
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_library_created",
            status: .succeeded,
            summary: "知识库已创建",
            metadata: [
                "library_id": .string(library.id.uuidString),
                "library_name": .string(displayName),
                "source_root": .string(trimmedSourceRoot ?? "")
            ]
        )
        refreshSnapshot()
        return library
    }

    @discardableResult
    func exportLibrary(_ library: KnowledgeLibrary, to url: URL) async -> URL? {
        do {
            let exportURL = try service.exportLibrary(id: library.id, to: url)
            statusMessage = L10n.tr("settings.knowledge.overview.export.success", library.name)
            errorMessage = nil
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_library_exported",
                status: .succeeded,
                summary: "知识库已导出",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "package_path": .string(exportURL.path)
                ]
            )
            return exportURL
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_library_exported",
                status: .failed,
                summary: "知识库导出失败",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "error": .string(error.localizedDescription)
                ]
            )
            return nil
        }
    }

    @discardableResult
    func importLibraryPackage(from url: URL) async -> KnowledgeLibrary? {
        do {
            let library = try service.importLibraryPackage(from: url)
            let audit = await performAudit(trigger: "library_import", extraMetadata: [
                "package_path": .string(url.path),
                "library_id": .string(library.id.uuidString)
            ])
            let importMessage = L10n.tr("settings.knowledge.overview.import.success", library.name)
            let auditMessage = L10n.tr(
                "settings.knowledge.overview.audit.success",
                "\(audit.checkedLibraries)",
                "\(audit.repairedLibraries)"
            )
            statusMessage = "\(importMessage) · \(auditMessage)"
            errorMessage = nil
            refreshSnapshot()
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_library_imported",
                status: .succeeded,
                summary: "知识库已导入",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "package_path": .string(url.path)
                ]
            )
            return library
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_library_imported",
                status: .failed,
                summary: "知识库导入失败",
                metadata: [
                    "package_path": .string(url.path),
                    "error": .string(error.localizedDescription)
                ]
            )
            return nil
        }
    }

    func inspectLibraryPackage(at url: URL) -> KnowledgeLibraryPackagePreview? {
        do {
            errorMessage = nil
            return try service.inspectLibraryPackage(at: url)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            return nil
        }
    }

    @discardableResult
    func exportBackup(to url: URL) async -> URL? {
        do {
            let exportURL = try service.exportBackup(to: url)
            statusMessage = L10n.tr("settings.knowledge.overview.backup.success", "\(libraries.count)")
            errorMessage = nil
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_backup_exported",
                status: .succeeded,
                summary: "知识库整库备份已导出",
                metadata: [
                    "library_count": .int(libraries.count),
                    "package_path": .string(exportURL.path)
                ]
            )
            return exportURL
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_backup_exported",
                status: .failed,
                summary: "知识库整库备份导出失败",
                metadata: [
                    "error": .string(error.localizedDescription)
                ]
            )
            return nil
        }
    }

    @discardableResult
    func restoreBackup(from url: URL) async -> [KnowledgeLibrary]? {
        do {
            let restoredLibraries = try service.restoreBackup(from: url)
            conversationStore.reconcileKnowledgeLibraryReferences(
                validLibraryIDs: Set(restoredLibraries.map { $0.id.uuidString })
            )
            let audit = await performAudit(trigger: "backup_restore", extraMetadata: [
                "package_path": .string(url.path),
                "restored_libraries": .int(restoredLibraries.count)
            ])
            let restoreMessage = L10n.tr("settings.knowledge.overview.restore.success", "\(restoredLibraries.count)")
            let auditMessage = L10n.tr(
                "settings.knowledge.overview.audit.success",
                "\(audit.checkedLibraries)",
                "\(audit.repairedLibraries)"
            )
            statusMessage = "\(restoreMessage) · \(auditMessage)"
            errorMessage = nil
            refreshSnapshot()
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_backup_restored",
                status: .succeeded,
                summary: "知识库整库备份已恢复",
                metadata: [
                    "library_count": .int(restoredLibraries.count),
                    "package_path": .string(url.path)
                ]
            )
            return restoredLibraries
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_backup_restored",
                status: .failed,
                summary: "知识库整库备份恢复失败",
                metadata: [
                    "package_path": .string(url.path),
                    "error": .string(error.localizedDescription)
                ]
            )
            return nil
        }
    }

    func inspectBackupPackage(at url: URL) -> KnowledgeBackupPackagePreview? {
        do {
            errorMessage = nil
            return try service.inspectBackupPackage(at: url)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            return nil
        }
    }

    private func bindStore() {
        conversationStore.$currentConversationId
            .sink { [weak self] _ in
                self?.refreshSnapshot()
            }
            .store(in: &cancellables)

        conversationStore.$conversations
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSnapshot()
            }
            .store(in: &cancellables)

        conversationStore.$settings
            .sink { [weak self] _ in
                self?.refreshSnapshot()
            }
            .store(in: &cancellables)
    }

    private func refreshSnapshot() {
        let currentConversation = conversationStore.currentConversation
        let settingsSnapshot = conversationStore.settings
        let refreshToken = UUID()
        let service = self.service
        snapshotRefreshToken = refreshToken

        DispatchQueue.global(qos: .utility).async {
            let workspacePath = currentConversation?.sandboxDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (currentConversation?.sandboxDir ?? "")
                : settingsSnapshot.ensureSandboxDir()
            let normalizedWorkspacePath = AppStoragePaths.normalizeSandboxPath(workspacePath)

            var libraries = service.listLibraries()
                .sorted { lhs, rhs in
                    if lhs.sourceRoot != nil && rhs.sourceRoot == nil { return true }
                    if lhs.sourceRoot == nil && rhs.sourceRoot != nil { return false }
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

            let workspaceLibrary = service.ensureLibraryForWorkspace(rootPath: normalizedWorkspacePath)
            if !libraries.contains(where: { $0.id == workspaceLibrary.id }) {
                libraries.insert(workspaceLibrary, at: 0)
            }

            let importJobs = service.listImportJobs()
            let importHealthByLibraryID = Dictionary(
                grouping: importJobs,
                by: { $0.libraryId.uuidString }
            ).mapValues { jobs in
                let failed = jobs.filter { $0.status == .failed }.count
                let pending = jobs.filter { $0.status == .pending || $0.status == .running }.count
                let completed = jobs.filter { $0.status == .succeeded }.count
                let imported = jobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
                let skipped = jobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
                return LibraryImportHealth(
                    failed: failed,
                    pending: pending,
                    completed: completed,
                    imported: imported,
                    skipped: skipped
                )
            }

            let snapshot = Snapshot(
                libraries: libraries,
                currentWorkspaceLibraryID: workspaceLibrary.id.uuidString,
                activeConversationLibraryIDs: Set(currentConversation?.knowledgeLibraryIDs ?? []),
                importHealthByLibraryID: importHealthByLibraryID,
                recentActivity: LogFileReader.loadRecentEvents(limit: 300, maxFiles: 7)
                    .filter { $0.category == LogCategory.rag.rawValue }
                    .prefix(12)
                    .map { $0 },
                maintenanceSummary: service.maintenanceSummary(),
                maintenancePlan: service.maintenancePlan()
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.snapshotRefreshToken == refreshToken else { return }
                self.libraries = snapshot.libraries
                self.currentWorkspaceLibraryID = snapshot.currentWorkspaceLibraryID
                self.activeConversationLibraryIDs = snapshot.activeConversationLibraryIDs
                self.importHealthByLibraryID = snapshot.importHealthByLibraryID
                self.recentActivity = snapshot.recentActivity
                self.maintenanceSummary = snapshot.maintenanceSummary
                self.maintenancePlan = snapshot.maintenancePlan
            }
        }
    }

    @discardableResult
    private func performAudit(
        trigger: String,
        extraMetadata: [String: LogValue] = [:]
    ) async -> KnowledgeAuditSummary {
        let summary = service.auditLibraries()
        var metadata: [String: LogValue] = [
            "trigger": .string(trigger),
            "checked_libraries": .int(summary.checkedLibraries),
            "repaired_libraries": .int(summary.repairedLibraries),
            "metadata_mismatches": .int(summary.metadataMismatches),
            "missing_directories": .int(summary.missingDirectories),
            "orphan_import_jobs": .int(summary.orphanImportJobs),
            "orphan_library_directories": .int(summary.orphanLibraryDirectories)
        ]
        extraMetadata.forEach { metadata[$0.key] = $0.value }
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_audit_finished",
            status: .succeeded,
            summary: summary.repairedLibraries > 0 ? "知识库体检并修复完成" : "知识库体检完成",
            metadata: metadata
        )
        refreshSnapshot()
        return summary
    }

    func importHealth(for library: KnowledgeLibrary) -> LibraryImportHealth {
        importHealthByLibraryID[library.id.uuidString] ?? LibraryImportHealth(
            failed: 0,
            pending: 0,
            completed: 0,
            imported: 0,
            skipped: 0
        )
    }

    var conversationStoreReference: ConversationStore {
        conversationStore
    }

    func maintenanceCandidate(for library: KnowledgeLibrary) -> KnowledgeMaintenanceCandidateSummary? {
        maintenancePlan?.candidates.first(where: { $0.libraryID == library.id })
    }

    private func matchesSearch(_ library: KnowledgeLibrary) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let needle = trimmed.lowercased()
        let haystacks = [
            library.name,
            library.sourceRoot ?? "",
            library.id.uuidString
        ]
        return haystacks.contains { $0.lowercased().contains(needle) }
    }

    private func matchesFilter(_ library: KnowledgeLibrary) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .workspace:
            return library.id.uuidString == currentWorkspaceLibraryID
        case .active:
            return activeConversationLibraryIDs.contains(library.id.uuidString)
        case .manual:
            return (library.sourceRoot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .failed:
            let health = importHealth(for: library)
            return library.status == .failed || health.failed > 0
        }
    }

    private func migrationSummary(for events: Set<String>) -> MigrationActivitySummary? {
        guard let entry = recentActivity.first(where: { events.contains($0.event) }) else { return nil }
        let packagePath = entry.metadata["package_path"] ?? ""
        let packageName = packagePath.isEmpty ? nil : URL(fileURLWithPath: packagePath).lastPathComponent
        let detail = packageName ?? entry.summary
        return MigrationActivitySummary(
            title: entry.summary,
            detail: detail,
            timestamp: entry.relativeTimestamp,
            isFailure: (entry.status?.lowercased() == "failed") || entry.level.lowercased() == "error"
        )
    }
}

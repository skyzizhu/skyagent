import Foundation

final class KnowledgeBaseService {
    static let shared = KnowledgeBaseService()

    private let queue = DispatchQueue(label: "SkyAgent.KnowledgeBaseService", qos: .utility)
    private let indexURL: URL
    private let importsURL: URL
    private let maintenanceStateURL: URL
    private let librariesRoot: URL
    private let fileManager: FileManager
    private var isAutomaticMaintenanceRunning = false

    private struct SidecarDocumentsIndex: Codable {
        let documents: [SidecarDocumentRecord]
    }

    private struct SidecarDocumentRecord: Codable {
        let id: String
        let source: String
        let title: String?
        let sourceType: String?
        let importedAt: Date?
    }

    private struct SidecarChunksIndex: Codable {
        let chunks: [SidecarChunkRecord]
    }

    private struct SidecarChunkRecord: Codable {
        let id: String?
        let documentId: String?
        let source: String?
        let title: String?
        let snippet: String?
        let citation: String?
        let tokens: [String]?
        let tokenCount: Int?
        let importedAt: Date?
    }

    private struct KnowledgeMaintenanceState: Codable {
        var lastRunAt: Date?
        var lastTriggeredLibraryIDs: [String]
    }

    private struct KnowledgeMaintenanceConfig {
        var enabled: Bool
        var minimumIntervalMinutes: Int
        var webHours: Int
        var workspaceHours: Int
        var maxLibrariesPerRun: Int

        static let `default` = KnowledgeMaintenanceConfig(
            enabled: true,
            minimumIntervalMinutes: 180,
            webHours: 24,
            workspaceHours: 12,
            maxLibrariesPerRun: 2
        )
    }

    private struct KnowledgeMaintenanceCandidate {
        let libraryID: UUID
        let libraryName: String
        let reason: String
        let stalenessHours: Double
        let nextEligibleAt: Date?
        let isDue: Bool
    }

    private struct KnowledgeLibraryExportManifest: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let library: KnowledgeLibrary
        let importJobs: [KnowledgeImportJob]
    }

    private struct KnowledgeBaseBackupManifest: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let libraryCount: Int
        let includesSidecarConfig: Bool
        let includesMaintenanceState: Bool
    }

    private init(
        indexURL: URL = AppStoragePaths.knowledgeLibrariesFile,
        importsURL: URL = AppStoragePaths.knowledgeImportsFile,
        maintenanceStateURL: URL = AppStoragePaths.knowledgeMaintenanceStateFile,
        librariesRoot: URL = AppStoragePaths.knowledgeLibrariesRootDir,
        fileManager: FileManager = .default
    ) {
        self.indexURL = indexURL
        self.importsURL = importsURL
        self.maintenanceStateURL = maintenanceStateURL
        self.librariesRoot = librariesRoot
        self.fileManager = fileManager
        AppStoragePaths.prepareDataDirectories()
    }

    func listLibraries() -> [KnowledgeLibrary] {
        queue.sync {
            loadIndex().libraries
        }
    }

    @discardableResult
    func createLibrary(named name: String, sourceRoot: String? = nil) -> KnowledgeLibrary {
        queue.sync {
            var index = loadIndex()
            let library = createLibraryLocked(named: name, sourceRoot: sourceRoot, index: &index)
            persistIndex(index)
            ensureLibraryDirectories(for: library.id)
            writeLibraryMetadata(library)
            return library
        }
    }

    func deleteLibrary(id: UUID) {
        queue.sync {
            var index = loadIndex()
            index.libraries.removeAll { $0.id == id }
            persistIndex(index)
            var imports = loadImports()
            imports.jobs.removeAll { $0.libraryId == id }
            persistImports(imports)
            let dir = librariesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try? fileManager.removeItem(at: dir)
        }
    }

    @discardableResult
    func exportLibrary(id: UUID, to packageURL: URL) throws -> URL {
        try queue.sync {
            guard let library = loadIndex().libraries.first(where: { $0.id == id }) else {
                throw NSError(domain: "KnowledgeBaseService", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: "知识库不存在，无法导出。"
                ])
            }

            let exportURL = normalizedExportPackageURL(packageURL, suggestedName: library.name)
            if fileManager.fileExists(atPath: exportURL.path) {
                try fileManager.removeItem(at: exportURL)
            }
            try fileManager.createDirectory(at: exportURL, withIntermediateDirectories: true)

            let manifest = KnowledgeLibraryExportManifest(
                formatVersion: 1,
                exportedAt: Date(),
                library: library,
                importJobs: loadImports().jobs.filter { $0.libraryId == id }
            )

            let payloadRoot = exportURL.appendingPathComponent("library", isDirectory: true)
            try copyDirectoryContents(from: libraryDirectoryURL(for: id), to: payloadRoot)

            let manifestURL = exportURL.appendingPathComponent("manifest.json", isDirectory: false)
            let encoder = makeJSONEncoder()
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: [.atomic])
            return exportURL
        }
    }

    @discardableResult
    func importLibraryPackage(from packageURL: URL) throws -> KnowledgeLibrary {
        try queue.sync {
            let manifestURL = packageURL.appendingPathComponent("manifest.json", isDirectory: false)
            let payloadRoot = packageURL.appendingPathComponent("library", isDirectory: true)
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: payloadRoot.path) else {
                throw NSError(domain: "KnowledgeBaseService", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "导入包缺少 manifest 或 library 内容。"
                ])
            }

            let decoder = makeJSONDecoder()
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try decoder.decode(KnowledgeLibraryExportManifest.self, from: manifestData)
            let payloadDocuments = try loadSidecarDocumentsIndex(
                from: payloadRoot
                    .appendingPathComponent("index", isDirectory: true)
                    .appendingPathComponent("documents.json", isDirectory: false)
            )
            let payloadChunks = try loadSidecarChunksIndex(
                from: payloadRoot
                    .appendingPathComponent("chunks", isDirectory: true)
                    .appendingPathComponent("chunks.json", isDirectory: false)
            )

            var index = loadIndex()
            let importedLibrary = createLibraryLocked(
                named: deduplicatedLibraryNameLocked(manifest.library.name, index: index),
                sourceRoot: manifest.library.sourceRoot,
                index: &index
            )
            persistIndex(index)
            ensureLibraryDirectories(for: importedLibrary.id)

            let destinationRoot = libraryDirectoryURL(for: importedLibrary.id)
            do {
                try clearDirectoryContents(at: destinationRoot)
                try copyDirectoryContents(from: payloadRoot, to: destinationRoot)

                var restoredLibrary = importedLibrary
                restoredLibrary.status = manifest.library.status
                restoredLibrary.documentCount = payloadDocuments.documents.count
                restoredLibrary.chunkCount = payloadChunks.chunks.count
                restoredLibrary.updatedAt = Date()
                updateLibraryLocked(restoredLibrary, index: &index)
                persistIndex(index)
                writeLibraryMetadata(restoredLibrary)

                var imports = loadImports()
                let now = Date()
                let importedJobs = manifest.importJobs.map { job in
                    KnowledgeImportJob(
                        id: UUID(),
                        libraryId: restoredLibrary.id,
                        sourceType: job.sourceType,
                        source: job.source,
                        title: job.title,
                        status: job.status,
                        createdAt: now,
                        updatedAt: now,
                        errorMessage: job.errorMessage,
                        importedCount: job.importedCount,
                        skippedCount: job.skippedCount,
                        failedCount: job.failedCount,
                        lastDurationMs: job.lastDurationMs
                    )
                }
                imports.jobs.append(contentsOf: importedJobs)
                persistImports(imports)

                return restoredLibrary
            } catch {
                index.libraries.removeAll { $0.id == importedLibrary.id }
                persistIndex(index)
                var imports = loadImports()
                imports.jobs.removeAll { $0.libraryId == importedLibrary.id }
                persistImports(imports)
                try? fileManager.removeItem(at: destinationRoot)
                throw error
            }
        }
    }

    func inspectLibraryPackage(at packageURL: URL) throws -> KnowledgeLibraryPackagePreview {
        try queue.sync {
            let manifestURL = packageURL.appendingPathComponent("manifest.json", isDirectory: false)
            let payloadRoot = packageURL.appendingPathComponent("library", isDirectory: true)
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: payloadRoot.path) else {
                throw NSError(domain: "KnowledgeBaseService", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "导入包缺少 manifest 或 library 内容。"
                ])
            }

            let decoder = makeJSONDecoder()
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try decoder.decode(KnowledgeLibraryExportManifest.self, from: manifestData)

            let tempLibraryID = manifest.library.id
            let documents = (try? loadSidecarDocumentsIndex(
                from: payloadRoot
                    .appendingPathComponent("index", isDirectory: true)
                    .appendingPathComponent("documents.json", isDirectory: false)
            ).documents) ?? []
            let chunks = (try? loadSidecarChunksIndex(
                from: payloadRoot
                    .appendingPathComponent("chunks", isDirectory: true)
                    .appendingPathComponent("chunks.json", isDirectory: false)
            ).chunks) ?? []

            return KnowledgeLibraryPackagePreview(
                path: packageURL.path,
                formatVersion: manifest.formatVersion,
                exportedAt: manifest.exportedAt,
                libraryName: manifest.library.name,
                sourceRoot: manifest.library.sourceRoot,
                documentCount: max(documents.count, manifest.library.documentCount),
                chunkCount: max(chunks.count, manifest.library.chunkCount),
                importJobCount: manifest.importJobs.filter { $0.libraryId == tempLibraryID }.count
            )
        }
    }

    @discardableResult
    func exportBackup(to packageURL: URL) throws -> URL {
        try queue.sync {
            let exportURL = normalizedBackupPackageURL(packageURL)
            if fileManager.fileExists(atPath: exportURL.path) {
                try fileManager.removeItem(at: exportURL)
            }
            try fileManager.createDirectory(at: exportURL, withIntermediateDirectories: true)

            let payloadRoot = exportURL.appendingPathComponent("knowledge", isDirectory: true)
            try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
            try copyItemIfExists(from: indexURL, to: payloadRoot.appendingPathComponent(indexURL.lastPathComponent, isDirectory: false))
            try copyItemIfExists(from: importsURL, to: payloadRoot.appendingPathComponent(importsURL.lastPathComponent, isDirectory: false))
            try copyItemIfExists(from: maintenanceStateURL, to: payloadRoot.appendingPathComponent(maintenanceStateURL.lastPathComponent, isDirectory: false))
            try copyDirectoryContents(from: librariesRoot, to: payloadRoot.appendingPathComponent("libraries", isDirectory: true))

            let sidecarRoot = payloadRoot.appendingPathComponent("sidecar", isDirectory: true)
            try fileManager.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
            let hasSidecarConfig = fileManager.fileExists(atPath: AppStoragePaths.knowledgeSidecarConfigFile.path)
            if hasSidecarConfig {
                try copyItemIfExists(
                    from: AppStoragePaths.knowledgeSidecarConfigFile,
                    to: sidecarRoot.appendingPathComponent("config.json", isDirectory: false)
                )
            }

            let manifest = KnowledgeBaseBackupManifest(
                formatVersion: 1,
                exportedAt: Date(),
                libraryCount: loadIndex().libraries.count,
                includesSidecarConfig: hasSidecarConfig,
                includesMaintenanceState: fileManager.fileExists(atPath: maintenanceStateURL.path)
            )
            let manifestURL = exportURL.appendingPathComponent("manifest.json", isDirectory: false)
            let data = try makeJSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: [.atomic])
            return exportURL
        }
    }

    @discardableResult
    func restoreBackup(from packageURL: URL) throws -> [KnowledgeLibrary] {
        try queue.sync {
            let manifestURL = packageURL.appendingPathComponent("manifest.json", isDirectory: false)
            let payloadRoot = packageURL.appendingPathComponent("knowledge", isDirectory: true)
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: payloadRoot.path) else {
                throw NSError(domain: "KnowledgeBaseService", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "备份包缺少 manifest 或 knowledge 内容。"
                ])
            }

            let manifestData = try Data(contentsOf: manifestURL)
            _ = try makeJSONDecoder().decode(KnowledgeBaseBackupManifest.self, from: manifestData)
            let parentDirectory = AppStoragePaths.knowledgeDir.deletingLastPathComponent()
            let stagingURL = parentDirectory.appendingPathComponent("knowledge-restore-staging-\(UUID().uuidString)", isDirectory: true)
            let rollbackURL = parentDirectory.appendingPathComponent("knowledge-restore-backup-\(UUID().uuidString)", isDirectory: true)
            let currentKnowledgeURL = AppStoragePaths.knowledgeDir

            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try copyDirectoryContents(from: payloadRoot, to: stagingURL)

            let stagedIndexURL = stagingURL.appendingPathComponent(indexURL.lastPathComponent, isDirectory: false)
            if fileManager.fileExists(atPath: stagedIndexURL.path) {
                let stagedIndexData = try Data(contentsOf: stagedIndexURL)
                _ = try makeJSONDecoder().decode(KnowledgeLibrariesIndex.self, from: stagedIndexData)
            }

            var committed = false
            do {
                if fileManager.fileExists(atPath: rollbackURL.path) {
                    try fileManager.removeItem(at: rollbackURL)
                }
                if fileManager.fileExists(atPath: currentKnowledgeURL.path) {
                    try fileManager.moveItem(at: currentKnowledgeURL, to: rollbackURL)
                }
                try fileManager.moveItem(at: stagingURL, to: currentKnowledgeURL)
                AppStoragePaths.prepareDataDirectories()
                committed = true
                if fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.removeItem(at: rollbackURL)
                }
                return loadIndex().libraries
            } catch {
                if !committed {
                    if fileManager.fileExists(atPath: currentKnowledgeURL.path) {
                        try? fileManager.removeItem(at: currentKnowledgeURL)
                    }
                    if fileManager.fileExists(atPath: rollbackURL.path) {
                        try? fileManager.moveItem(at: rollbackURL, to: currentKnowledgeURL)
                    }
                    if fileManager.fileExists(atPath: stagingURL.path) {
                        try? fileManager.removeItem(at: stagingURL)
                    }
                }
                throw error
            }
        }
    }

    func inspectBackupPackage(at packageURL: URL) throws -> KnowledgeBackupPackagePreview {
        try queue.sync {
            let manifestURL = packageURL.appendingPathComponent("manifest.json", isDirectory: false)
            let payloadRoot = packageURL.appendingPathComponent("knowledge", isDirectory: true)
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: payloadRoot.path) else {
                throw NSError(domain: "KnowledgeBaseService", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "备份包缺少 manifest 或 knowledge 内容。"
                ])
            }

            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try makeJSONDecoder().decode(KnowledgeBaseBackupManifest.self, from: manifestData)
            return KnowledgeBackupPackagePreview(
                path: packageURL.path,
                formatVersion: manifest.formatVersion,
                exportedAt: manifest.exportedAt,
                libraryCount: manifest.libraryCount,
                includesSidecarConfig: manifest.includesSidecarConfig,
                includesMaintenanceState: manifest.includesMaintenanceState
            )
        }
    }

    func updateLibrary(_ library: KnowledgeLibrary) {
        queue.sync {
            var index = loadIndex()
            if let idx = index.libraries.firstIndex(where: { $0.id == library.id }) {
                index.libraries[idx] = library
                persistIndex(index)
                writeLibraryMetadata(library)
            }
        }
    }

    func ensureLibraryForWorkspace(rootPath: String) -> KnowledgeLibrary {
        let normalized = AppStoragePaths.normalizeSandboxPath(rootPath)
        return queue.sync {
            var index = loadIndex()
            if let existing = index.libraries.first(where: { $0.sourceRoot == normalized }) {
                return existing
            }
            let name = URL(fileURLWithPath: normalized, isDirectory: true).lastPathComponent
            let library = createLibraryLocked(named: name.isEmpty ? "Workspace Library" : name, sourceRoot: normalized, index: &index)
            persistIndex(index)
            ensureLibraryDirectories(for: library.id)
            writeLibraryMetadata(library)
            return library
        }
    }

    func listImportJobs(libraryId: UUID? = nil) -> [KnowledgeImportJob] {
        queue.sync {
            let jobs = loadImports().jobs
            guard let libraryId else { return jobs }
            return jobs.filter { $0.libraryId == libraryId }
        }
    }

    func listDocuments(libraryId: UUID) -> [KnowledgeDocument] {
        queue.sync {
            let documentsURL = libraryDirectoryURL(for: libraryId)
                .appendingPathComponent("index", isDirectory: true)
                .appendingPathComponent("documents.json", isDirectory: false)
            let chunksURL = libraryDirectoryURL(for: libraryId)
                .appendingPathComponent("chunks", isDirectory: true)
                .appendingPathComponent("chunks.json", isDirectory: false)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let documentsIndex = (try? Data(contentsOf: documentsURL))
                .flatMap { try? decoder.decode(SidecarDocumentsIndex.self, from: $0) }
                ?? SidecarDocumentsIndex(documents: [])

            let chunksIndex = (try? Data(contentsOf: chunksURL))
                .flatMap { try? decoder.decode(SidecarChunksIndex.self, from: $0) }
                ?? SidecarChunksIndex(chunks: [])

            let chunkCounts = chunksIndex.chunks.reduce(into: [String: Int]()) { partialResult, chunk in
                guard let documentId = chunk.documentId else { return }
                partialResult[documentId, default: 0] += 1
            }

            return documentsIndex.documents.compactMap { record in
                guard let documentUUID = UUID(uuidString: record.id) else { return nil }
                let sourceType = KnowledgeSourceType(rawValue: record.sourceType ?? "") ?? .file
                let displayName = (record.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? (record.title ?? "")
                    : URL(fileURLWithPath: record.source).lastPathComponent

                return KnowledgeDocument(
                    id: documentUUID,
                    libraryID: libraryId,
                    name: displayName.isEmpty ? record.source : displayName,
                    sourceType: sourceType,
                    originalPath: record.source,
                    importedAt: record.importedAt ?? .distantPast,
                    parseStatus: .idle,
                    chunkCount: chunkCounts[record.id, default: 0]
                )
            }
            .sorted { $0.importedAt > $1.importedAt }
        }
    }

    func library(by id: UUID) -> KnowledgeLibrary? {
        queue.sync {
            loadIndex().libraries.first(where: { $0.id == id })
        }
    }

    func document(by id: UUID, in libraryId: UUID) -> KnowledgeDocument? {
        listDocuments(libraryId: libraryId).first(where: { $0.id == id })
    }

    func documentSnippets(documentId: UUID, in libraryId: UUID, limit: Int = 8) -> [KnowledgeDocumentSnippet] {
        queue.sync {
            let chunksURL = chunksIndexURL(for: libraryId)
            let decoder = makeJSONDecoder()

            let chunksIndex = (try? Data(contentsOf: chunksURL))
                .flatMap { try? decoder.decode(SidecarChunksIndex.self, from: $0) }
                ?? SidecarChunksIndex(chunks: [])

            return chunksIndex.chunks
                .filter { $0.documentId == documentId.uuidString }
                .compactMap { chunk in
                    let rawSnippet = chunk.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !rawSnippet.isEmpty else { return nil }
                    let compactSnippet = rawSnippet.count > 360 ? String(rawSnippet.prefix(360)) + "..." : rawSnippet
                    return KnowledgeDocumentSnippet(
                        id: UUID(),
                        citation: chunk.citation?.trimmingCharacters(in: .whitespacesAndNewlines),
                        snippet: compactSnippet
                    )
                }
                .prefix(max(1, limit))
                .map { $0 }
        }
    }

    func libraryDirectoryURL(for id: UUID) -> URL {
        librariesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func storageMetrics(for libraryId: UUID) -> KnowledgeLibraryStorageMetrics {
        let root = libraryDirectoryURL(for: libraryId)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let parsed = root.appendingPathComponent("parsed", isDirectory: true)
        let chunks = root.appendingPathComponent("chunks", isDirectory: true)
        let index = root.appendingPathComponent("index", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let metadata = root.appendingPathComponent("meta.json", isDirectory: false)

        let sourceBytes = fileSize(at: source)
        let parsedBytes = fileSize(at: parsed)
        let chunksBytes = fileSize(at: chunks)
        let indexBytes = fileSize(at: index)
        let cacheBytes = fileSize(at: cache)
        let metadataBytes = fileSize(at: metadata)

        return KnowledgeLibraryStorageMetrics(
            totalBytes: sourceBytes + parsedBytes + chunksBytes + indexBytes + cacheBytes + metadataBytes,
            sourceBytes: sourceBytes,
            parsedBytes: parsedBytes,
            chunksBytes: chunksBytes,
            indexBytes: indexBytes,
            cacheBytes: cacheBytes,
            metadataBytes: metadataBytes
        )
    }

    func removeDocument(id: UUID, from libraryId: UUID) -> Bool {
        queue.sync {
            let documentsURL = documentsIndexURL(for: libraryId)
            let chunksURL = chunksIndexURL(for: libraryId)
            let decoder = makeJSONDecoder()

            let documentsIndex = (try? Data(contentsOf: documentsURL))
                .flatMap { try? decoder.decode(SidecarDocumentsIndex.self, from: $0) }
                ?? SidecarDocumentsIndex(documents: [])

            guard let removedRecord = documentsIndex.documents.first(where: { $0.id == id.uuidString }) else {
                return false
            }

            let chunksIndex = (try? Data(contentsOf: chunksURL))
                .flatMap { try? decoder.decode(SidecarChunksIndex.self, from: $0) }
                ?? SidecarChunksIndex(chunks: [])

            let filteredDocuments = documentsIndex.documents.filter { $0.id != id.uuidString }
            let removedSource = removedRecord.source
            let filteredChunks = chunksIndex.chunks.filter { chunk in
                if chunk.documentId == id.uuidString { return false }
                if chunk.source == removedSource { return false }
                return true
            }

            persistDocumentsIndex(SidecarDocumentsIndex(documents: filteredDocuments), libraryId: libraryId)
            persistChunksIndex(SidecarChunksIndex(chunks: filteredChunks), libraryId: libraryId)
            updateLibrarySummaryLocked(
                libraryId: libraryId,
                documentCount: filteredDocuments.count,
                chunkCount: filteredChunks.count,
                status: .idle
            )
            return true
        }
    }

    func rebuildLibrary(libraryId: UUID) async -> [KnowledgeImportJob] {
        let jobsToRun = queue.sync { () -> [KnowledgeImportJob] in
            clearLibraryIndexLocked(libraryId: libraryId, status: .indexing)

            var imports = loadImports()
            var jobs: [KnowledgeImportJob] = []
            let now = Date()

            for index in imports.jobs.indices where imports.jobs[index].libraryId == libraryId {
                imports.jobs[index].status = .pending
                imports.jobs[index].errorMessage = nil
                imports.jobs[index].updatedAt = now
                jobs.append(imports.jobs[index])
            }

            persistImports(imports)
            return jobs.sorted { $0.createdAt < $1.createdAt }
        }

        guard !jobsToRun.isEmpty else {
            updateLibraryStatus(libraryId, status: .idle)
            return []
        }

        var completed: [KnowledgeImportJob] = []
        for job in jobsToRun {
            let finished = await runImportJob(job)
            completed.append(finished)
        }
        return completed
    }

    func refreshLibraryIncrementally(libraryId: UUID) async -> [KnowledgeImportJob] {
        let jobsToRun = queue.sync { () -> [KnowledgeImportJob] in
            let jobs = loadImports().jobs
                .filter { $0.libraryId == libraryId && $0.status == .succeeded }
                .sorted { $0.createdAt < $1.createdAt }
            guard !jobs.isEmpty else { return [] }
            let index = loadIndex()
            let library = index.libraries.first(where: { $0.id == libraryId })
            updateLibrarySummaryLocked(
                libraryId: libraryId,
                documentCount: library?.documentCount ?? 0,
                chunkCount: library?.chunkCount ?? 0,
                status: .indexing
            )
            return jobs
        }

        guard !jobsToRun.isEmpty else {
            updateLibraryStatus(libraryId, status: .idle)
            return []
        }

        var completed: [KnowledgeImportJob] = []
        for job in jobsToRun {
            let finished = await runImportJob(job)
            completed.append(finished)
        }
        return completed
    }

    @discardableResult
    func enqueueImportJob(
        libraryId: UUID,
        sourceType: KnowledgeSourceType,
        source: String,
        title: String? = nil
    ) -> KnowledgeImportJob {
        queue.sync {
            var imports = loadImports()
            let now = Date()
            let job = KnowledgeImportJob(
                id: UUID(),
                libraryId: libraryId,
                sourceType: sourceType,
                source: source,
                title: title,
                status: .pending,
                createdAt: now,
                updatedAt: now,
                errorMessage: nil,
                importedCount: nil,
                skippedCount: nil,
                failedCount: nil,
                lastDurationMs: nil
            )
            imports.jobs.append(job)
            persistImports(imports)
            return job
        }
    }

    @discardableResult
    func enqueueAndRunImport(
        libraryId: UUID,
        sourceType: KnowledgeSourceType,
        source: String,
        title: String? = nil
    ) async -> KnowledgeImportJob {
        let job = enqueueImportJob(
            libraryId: libraryId,
            sourceType: sourceType,
            source: source,
            title: title
        )
        return await runImportJob(job)
    }

    func updateImportJob(_ job: KnowledgeImportJob) {
        queue.sync {
            var imports = loadImports()
            if let idx = imports.jobs.firstIndex(where: { $0.id == job.id }) {
                imports.jobs[idx] = job
                persistImports(imports)
            }
        }
    }

    func removeImportJob(id: UUID) {
        queue.sync {
            var imports = loadImports()
            imports.jobs.removeAll { $0.id == id }
            persistImports(imports)
        }
    }

    func importJob(by id: UUID) -> KnowledgeImportJob? {
        queue.sync {
            loadImports().jobs.first(where: { $0.id == id })
        }
    }

    func sidecarStatus() async -> Result<KnowledgeBaseSidecarStatus, KnowledgeBaseSidecarError> {
        let status = await KnowledgeBaseSidecarManager.shared.status()
        return .success(status)
    }

    func maintenanceSummary() -> KnowledgeMaintenanceSummary {
        queue.sync {
            let config = loadMaintenanceConfig()
            let state = loadMaintenanceState()
            return KnowledgeMaintenanceSummary(
                enabled: config.enabled,
                lastRunAt: state.lastRunAt,
                lastTriggeredLibraryIDs: state.lastTriggeredLibraryIDs,
                minimumIntervalMinutes: config.minimumIntervalMinutes,
                webHours: config.webHours,
                workspaceHours: config.workspaceHours,
                maxLibrariesPerRun: config.maxLibrariesPerRun
            )
        }
    }

    func maintenancePlan() -> KnowledgeMaintenancePlan {
        queue.sync {
            let config = loadMaintenanceConfig()
            let state = loadMaintenanceState()
            let now = Date()
            let nextCheckAt = state.lastRunAt.map {
                $0.addingTimeInterval(Double(max(config.minimumIntervalMinutes, 1)) * 60)
            } ?? now
            let candidates = maintenanceCandidates(config: config, now: now)
                .prefix(max(1, max(config.maxLibrariesPerRun, 1) * 3))
                .map { candidate in
                    KnowledgeMaintenanceCandidateSummary(
                        id: candidate.libraryID.uuidString,
                        libraryID: candidate.libraryID,
                        libraryName: candidate.libraryName,
                        reason: candidate.reason,
                        stalenessHours: candidate.stalenessHours,
                        nextEligibleAt: candidate.nextEligibleAt,
                        isDue: candidate.isDue
                    )
                }

            return KnowledgeMaintenancePlan(
                enabled: config.enabled,
                isRunning: isAutomaticMaintenanceRunning,
                lastRunAt: state.lastRunAt,
                nextCheckAt: nextCheckAt,
                candidates: candidates,
                minimumIntervalMinutes: config.minimumIntervalMinutes,
                webHours: config.webHours,
                workspaceHours: config.workspaceHours,
                maxLibrariesPerRun: config.maxLibrariesPerRun
            )
        }
    }

    func auditLibraries() -> KnowledgeAuditSummary {
        queue.sync {
            var index = loadIndex()
            let imports = loadImports()
            var repairedLibraries = 0
            var metadataMismatches = 0
            var missingDirectories = 0

            for libraryIndex in index.libraries.indices {
                let library = index.libraries[libraryIndex]
                let directoryURL = libraryDirectoryURL(for: library.id)
                if !fileManager.fileExists(atPath: directoryURL.path) {
                    missingDirectories += 1
                    ensureLibraryDirectories(for: library.id)
                }

                let documents = (try? loadSidecarDocumentsIndex(from: documentsIndexURL(for: library.id)).documents) ?? []
                let chunks = (try? loadSidecarChunksIndex(from: chunksIndexURL(for: library.id)).chunks) ?? []
                let hasFailedImports = imports.jobs.contains { $0.libraryId == library.id && $0.status == .failed }
                let expectedStatus: KnowledgeLibraryStatus = hasFailedImports ? .failed : .idle

                if library.documentCount != documents.count ||
                    library.chunkCount != chunks.count ||
                    library.status != expectedStatus {
                    metadataMismatches += 1
                    repairedLibraries += 1
                    index.libraries[libraryIndex].documentCount = documents.count
                    index.libraries[libraryIndex].chunkCount = chunks.count
                    index.libraries[libraryIndex].status = expectedStatus
                    index.libraries[libraryIndex].updatedAt = Date()
                    writeLibraryMetadata(index.libraries[libraryIndex])
                }
            }

            if metadataMismatches > 0 {
                persistIndex(index)
            }

            let validLibraryIDs = Set(index.libraries.map(\.id))
            let orphanImportJobs = imports.jobs.filter { !validLibraryIDs.contains($0.libraryId) }.count

            let orphanLibraryDirectories = ((try? fileManager.contentsOfDirectory(
                at: librariesRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { url in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return false
                }
                guard let id = UUID(uuidString: url.lastPathComponent) else { return false }
                return !validLibraryIDs.contains(id)
            }.count

            return KnowledgeAuditSummary(
                checkedLibraries: index.libraries.count,
                repairedLibraries: repairedLibraries,
                metadataMismatches: metadataMismatches,
                missingDirectories: missingDirectories,
                orphanImportJobs: orphanImportJobs,
                orphanLibraryDirectories: orphanLibraryDirectories
            )
        }
    }

    func runAutomaticMaintenanceIfNeeded(force: Bool = false) async -> [UUID] {
        let plan = queue.sync { () -> (config: KnowledgeMaintenanceConfig, candidates: [KnowledgeMaintenanceCandidate])? in
            if isAutomaticMaintenanceRunning {
                return nil
            }

            let config = loadMaintenanceConfig()
            guard config.enabled else { return nil }

            let state = loadMaintenanceState()
            if !force,
               let lastRunAt = state.lastRunAt,
               Date().timeIntervalSince(lastRunAt) < Double(max(config.minimumIntervalMinutes, 1)) * 60 {
                return nil
            }

            let candidates = Array(
                maintenanceCandidates(config: config, now: Date())
                    .filter(\.isDue)
                    .prefix(max(1, config.maxLibrariesPerRun))
            )
            persistMaintenanceState(
                KnowledgeMaintenanceState(
                    lastRunAt: Date(),
                    lastTriggeredLibraryIDs: candidates.map { $0.libraryID.uuidString }
                )
            )
            isAutomaticMaintenanceRunning = true
            return (config, candidates)
        }

        guard let plan else { return [] }
        defer {
            queue.sync {
                isAutomaticMaintenanceRunning = false
            }
        }

        await LoggerService.shared.log(
            category: .rag,
            event: "kb_auto_maintenance_started",
            status: .started,
            summary: "知识库自动维护开始",
            metadata: [
                "candidate_count": .int(plan.candidates.count),
                "force": .bool(force)
            ]
        )

        guard !plan.candidates.isEmpty else {
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_auto_maintenance_finished",
                status: .succeeded,
                summary: "知识库自动维护无需执行",
                metadata: [
                    "candidate_count": .int(0)
                ]
            )
            return []
        }

        var rebuiltLibraryIDs: [UUID] = []
        for candidate in plan.candidates {
            guard let library = library(by: candidate.libraryID) else { continue }

            await LoggerService.shared.log(
                category: .rag,
                event: "kb_auto_rebuild_started",
                status: .started,
                summary: "知识库自动重建开始",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "reason": .string(candidate.reason),
                    "staleness_hours": .double(candidate.stalenessHours)
                ]
            )

            let jobs = await refreshLibraryIncrementally(libraryId: candidate.libraryID)
            let succeededJobs = jobs.filter { $0.status == .succeeded }.count
            let failedJobs = jobs.filter { $0.status == .failed }.count
            let importedCount = jobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
            let skippedCount = jobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
            let failedCount = jobs.reduce(0) { $0 + max(0, $1.failedCount ?? ($1.status == .failed ? 1 : 0)) }

            await LoggerService.shared.log(
                category: .rag,
                event: "kb_auto_rebuild_finished",
                status: failedJobs > 0 ? .failed : .succeeded,
                summary: failedJobs > 0 ? "知识库自动重建部分失败" : "知识库自动重建完成",
                metadata: [
                    "library_id": .string(library.id.uuidString),
                    "library_name": .string(library.name),
                    "reason": .string(candidate.reason),
                    "job_count": .int(jobs.count),
                    "succeeded_job_count": .int(succeededJobs),
                    "failed_job_count": .int(failedJobs),
                    "imported_count": .int(importedCount),
                    "skipped_count": .int(skippedCount),
                    "failed_count": .int(failedCount)
                ]
            )

            rebuiltLibraryIDs.append(candidate.libraryID)
        }

        await LoggerService.shared.log(
            category: .rag,
            event: "kb_auto_maintenance_finished",
            status: .succeeded,
            summary: "知识库自动维护完成",
            metadata: [
                "candidate_count": .int(plan.candidates.count),
                "rebuilt_count": .int(rebuiltLibraryIDs.count)
            ]
        )

        return rebuiltLibraryIDs
    }

    func queryLibrary(id: UUID, query: String, topK: Int) async -> Result<KnowledgeBaseQueryResponse, KnowledgeBaseSidecarError> {
        let request = KnowledgeBaseQueryRequest(
            libraryId: id.uuidString,
            query: query,
            topK: max(1, min(topK, 10))
        )
        return await KnowledgeBaseSidecarClient.shared.query(request)
    }

    func importSources(libraryId: UUID, sources: [KnowledgeBaseImportSource]) async -> Result<KnowledgeBaseImportResponse, KnowledgeBaseSidecarError> {
        let request = KnowledgeBaseImportRequest(libraryId: libraryId.uuidString, sources: sources)
        let result = await KnowledgeBaseSidecarClient.shared.importSources(request)
        switch result {
        case .success(let response):
            return .success(response)
        case .failure(let error):
            return .failure(error)
        }
    }

    func runImportJob(_ job: KnowledgeImportJob) async -> KnowledgeImportJob {
        let startedAt = Date()
        var updated = job
        updated.status = .running
        updated.updatedAt = Date()
        updated.importedCount = nil
        updated.skippedCount = nil
        updated.failedCount = nil
        updated.lastDurationMs = nil
        updateImportJob(updated)
        updateLibraryStatus(job.libraryId, status: .indexing)
        await LoggerService.shared.log(
            category: .rag,
            event: "kb_import_started",
            status: .started,
            summary: "知识库导入开始",
            metadata: [
                "library_id": .string(job.libraryId.uuidString),
                "source_type": .string(job.sourceType.rawValue),
                "source": .string(job.source)
            ]
        )

        let source = KnowledgeBaseImportSource(
            type: updated.sourceType.rawValue,
            path: updated.source,
            title: updated.title
        )
        let result = await importSources(libraryId: updated.libraryId, sources: [source])
        updated.updatedAt = Date()
        switch result {
        case .success(let response):
            updated.status = .succeeded
            updated.errorMessage = nil
            updated.importedCount = response.imported
            updated.skippedCount = response.skipped ?? 0
            updated.failedCount = response.failed
            refreshLibraryFromDisk(updated.libraryId)
            let durationMs = Date().timeIntervalSince(startedAt) * 1000
            updated.lastDurationMs = durationMs
            await LoggerService.shared.log(
                category: .rag,
                event: "kb_import_finished",
                status: .succeeded,
                durationMs: durationMs,
                summary: "知识库导入完成",
                metadata: [
                    "library_id": .string(job.libraryId.uuidString),
                    "source_type": .string(job.sourceType.rawValue),
                    "source": .string(job.source),
                    "imported_count": .int(response.imported),
                    "skipped_count": .int(response.skipped ?? 0),
                    "failed_count": .int(response.failed)
                ]
            )
        case .failure(let error):
            updated.status = .failed
            updated.errorMessage = error.description
            updated.importedCount = 0
            updated.skippedCount = 0
            updated.failedCount = 1
            updateLibraryStatus(updated.libraryId, status: .failed)
            let durationMs = Date().timeIntervalSince(startedAt) * 1000
            updated.lastDurationMs = durationMs
            await LoggerService.shared.log(
                level: .warn,
                category: .rag,
                event: "kb_import_finished",
                status: .failed,
                durationMs: durationMs,
                summary: "知识库导入失败",
                metadata: [
                    "library_id": .string(job.libraryId.uuidString),
                    "source_type": .string(job.sourceType.rawValue),
                    "source": .string(job.source),
                    "error": .string(error.description)
                ]
            )
        }
        updateImportJob(updated)
        return updated
    }

    func runQueuedImportJobs(libraryId: UUID? = nil) async -> [KnowledgeImportJob] {
        let pendingJobs = listImportJobs(libraryId: libraryId).filter { $0.status == .pending }
        var completed: [KnowledgeImportJob] = []
        for job in pendingJobs {
            let finished = await runImportJob(job)
            completed.append(finished)
        }
        return completed
    }

    func retryImportJob(id: UUID) async -> KnowledgeImportJob? {
        guard let existing = importJob(by: id) else { return nil }

        var updated = existing
        updated.status = .pending
        updated.errorMessage = nil
        updated.updatedAt = Date()
        updateImportJob(updated)
        return await runImportJob(updated)
    }

    func queryKnowledge(
        libraryId: UUID,
        query: String,
        topK: Int = 5
    ) async -> Result<[RetrievalHit], KnowledgeBaseSidecarError> {
        let response = await queryLibrary(id: libraryId, query: query, topK: topK)
        switch response {
        case .success(let data):
            let libraryName = library(by: libraryId)?.name
            let hits = data.hits.map { hit in
                RetrievalHit(
                    id: UUID(),
                    libraryID: libraryId,
                    libraryName: libraryName,
                    documentID: UUID(uuidString: hit.documentId ?? ""),
                    title: hit.title,
                    snippet: hit.snippet,
                    score: hit.score,
                    citation: hit.citation,
                    source: hit.source
                )
            }
            return .success(hits)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func loadIndex() -> KnowledgeLibrariesIndex {
        guard let data = try? Data(contentsOf: indexURL) else {
            return KnowledgeLibrariesIndex(libraries: [])
        }
        let decoder = makeJSONDecoder()
        if let decoded = try? decoder.decode(KnowledgeLibrariesIndex.self, from: data) {
            return decoded
        }
        return KnowledgeLibrariesIndex(libraries: [])
    }

    private func loadImports() -> KnowledgeImportIndex {
        guard let data = try? Data(contentsOf: importsURL) else {
            return KnowledgeImportIndex(jobs: [])
        }
        let decoder = makeJSONDecoder()
        if let decoded = try? decoder.decode(KnowledgeImportIndex.self, from: data) {
            return decoded
        }
        return KnowledgeImportIndex(jobs: [])
    }

    private func loadMaintenanceState() -> KnowledgeMaintenanceState {
        guard let data = try? Data(contentsOf: maintenanceStateURL) else {
            return KnowledgeMaintenanceState(lastRunAt: nil, lastTriggeredLibraryIDs: [])
        }
        let decoder = makeJSONDecoder()
        if let decoded = try? decoder.decode(KnowledgeMaintenanceState.self, from: data) {
            return decoded
        }
        return KnowledgeMaintenanceState(lastRunAt: nil, lastTriggeredLibraryIDs: [])
    }

    private func loadMaintenanceConfig() -> KnowledgeMaintenanceConfig {
        guard let data = try? Data(contentsOf: AppStoragePaths.knowledgeSidecarConfigFile),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = raw["refresh"] as? [String: Any] else {
            return .default
        }

        return KnowledgeMaintenanceConfig(
            enabled: refresh["enabled"] as? Bool ?? KnowledgeMaintenanceConfig.default.enabled,
            minimumIntervalMinutes: refresh["minimumIntervalMinutes"] as? Int ?? KnowledgeMaintenanceConfig.default.minimumIntervalMinutes,
            webHours: refresh["webHours"] as? Int ?? KnowledgeMaintenanceConfig.default.webHours,
            workspaceHours: refresh["workspaceHours"] as? Int ?? KnowledgeMaintenanceConfig.default.workspaceHours,
            maxLibrariesPerRun: refresh["maxLibrariesPerRun"] as? Int ?? KnowledgeMaintenanceConfig.default.maxLibrariesPerRun
        )
    }

    private func persistIndex(_ index: KnowledgeLibrariesIndex) {
        let encoder = makeJSONEncoder()
        if let data = try? encoder.encode(index) {
            try? data.write(to: indexURL, options: [.atomic])
        }
    }

    private func persistImports(_ index: KnowledgeImportIndex) {
        let encoder = makeJSONEncoder()
        if let data = try? encoder.encode(index) {
            try? data.write(to: importsURL, options: [.atomic])
        }
    }

    private func persistMaintenanceState(_ state: KnowledgeMaintenanceState) {
        let encoder = makeJSONEncoder()
        if let data = try? encoder.encode(state) {
            try? data.write(to: maintenanceStateURL, options: [.atomic])
        }
    }

    private func updateLibraryStatus(_ libraryID: UUID, status: KnowledgeLibraryStatus) {
        queue.sync {
            var index = loadIndex()
            guard let idx = index.libraries.firstIndex(where: { $0.id == libraryID }) else { return }
            index.libraries[idx].status = status
            index.libraries[idx].updatedAt = Date()
            persistIndex(index)
            writeLibraryMetadata(index.libraries[idx])
        }
    }

    private func refreshLibraryFromDisk(_ libraryID: UUID) {
        queue.sync {
            let metaURL = librariesRoot
                .appendingPathComponent(libraryID.uuidString, isDirectory: true)
                .appendingPathComponent("meta.json", isDirectory: false)
            guard let data = try? Data(contentsOf: metaURL) else { return }
            let decoder = makeJSONDecoder()
            guard let library = try? decoder.decode(KnowledgeLibrary.self, from: data) else { return }
            var index = loadIndex()
            guard let idx = index.libraries.firstIndex(where: { $0.id == libraryID }) else { return }
            index.libraries[idx] = library
            persistIndex(index)
        }
    }

    private func maintenanceCandidates(
        config: KnowledgeMaintenanceConfig,
        now: Date
    ) -> [KnowledgeMaintenanceCandidate] {
        let libraries = loadIndex().libraries
        let jobsByLibrary = Dictionary(grouping: loadImports().jobs, by: \.libraryId)

        return libraries.compactMap { library in
            guard library.status != .indexing else { return nil }

            let successfulJobs = (jobsByLibrary[library.id] ?? []).filter { $0.status == .succeeded }
            guard !successfulJobs.isEmpty else { return nil }

            let latestActivityAt = ([library.updatedAt] + successfulJobs.map(\.updatedAt)).max() ?? library.updatedAt
            let stalenessHours = now.timeIntervalSince(latestActivityAt) / 3600

            if successfulJobs.contains(where: { $0.sourceType == .web }) {
                let thresholdHours = Double(max(config.webHours, 1))
                let nextEligibleAt = latestActivityAt.addingTimeInterval(thresholdHours * 3600)
                return KnowledgeMaintenanceCandidate(
                    libraryID: library.id,
                    libraryName: library.name,
                    reason: "web_refresh",
                    stalenessHours: stalenessHours,
                    nextEligibleAt: nextEligibleAt,
                    isDue: stalenessHours >= thresholdHours
                )
            }

            let hasWorkspaceShape = library.sourceRoot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                successfulJobs.contains(where: { $0.sourceType == .folder })
            guard hasWorkspaceShape else { return nil }
            let thresholdHours = Double(max(config.workspaceHours, 1))

            return KnowledgeMaintenanceCandidate(
                libraryID: library.id,
                libraryName: library.name,
                reason: "workspace_refresh",
                stalenessHours: stalenessHours,
                nextEligibleAt: latestActivityAt.addingTimeInterval(thresholdHours * 3600),
                isDue: stalenessHours >= thresholdHours
            )
        }
        .sorted {
            if $0.isDue != $1.isDue {
                return $0.isDue && !$1.isDue
            }
            if $0.stalenessHours == $1.stalenessHours {
                return $0.reason < $1.reason
            }
            return $0.stalenessHours > $1.stalenessHours
        }
    }

    private func createLibraryLocked(
        named name: String,
        sourceRoot: String? = nil,
        index: inout KnowledgeLibrariesIndex
    ) -> KnowledgeLibrary {
        let now = Date()
        let library = KnowledgeLibrary(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Library" : name,
            createdAt: now,
            updatedAt: now,
            status: .idle,
            documentCount: 0,
            chunkCount: 0,
            sourceRoot: sourceRoot
        )
        index.libraries.append(library)
        return library
    }

    private func updateLibraryLocked(_ library: KnowledgeLibrary, index: inout KnowledgeLibrariesIndex) {
        if let idx = index.libraries.firstIndex(where: { $0.id == library.id }) {
            index.libraries[idx] = library
        }
    }

    private func deduplicatedLibraryNameLocked(_ name: String, index: KnowledgeLibrariesIndex) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Library" : name
        let existing = Set(index.libraries.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        for number in 2 ... 999 {
            let candidate = "\(base) \(number)"
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return "\(base) \(UUID().uuidString.prefix(6))"
    }

    private func ensureLibraryDirectories(for id: UUID) {
        let root = librariesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let subdirs = [
            "source",
            "parsed",
            "chunks",
            "index",
            "cache"
        ]
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for subdir in subdirs {
            let dir = root.appendingPathComponent(subdir, isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeLibraryMetadata(_ library: KnowledgeLibrary) {
        let encoder = makeJSONEncoder()
        guard let data = try? encoder.encode(library) else { return }
        let metaURL = librariesRoot
            .appendingPathComponent(library.id.uuidString, isDirectory: true)
            .appendingPathComponent("meta.json", isDirectory: false)
        try? data.write(to: metaURL, options: [.atomic])
    }

    private func normalizedExportPackageURL(_ packageURL: URL, suggestedName: String) -> URL {
        if packageURL.pathExtension.lowercased() == "skykb" {
            return packageURL
        }
        if packageURL.hasDirectoryPath {
            let sanitized = suggestedName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            return packageURL
                .appendingPathComponent(sanitized.isEmpty ? "KnowledgeLibrary" : sanitized, isDirectory: true)
                .appendingPathExtension("skykb")
        }
        return packageURL.appendingPathExtension("skykb")
    }

    private func normalizedBackupPackageURL(_ packageURL: URL) -> URL {
        if packageURL.pathExtension.lowercased() == "skybackup" {
            return packageURL
        }
        if packageURL.hasDirectoryPath {
            return packageURL
                .appendingPathComponent("SkyAgentKnowledgeBackup", isDirectory: true)
                .appendingPathExtension("skybackup")
        }
        return packageURL.appendingPathExtension("skybackup")
    }

    private func copyItemIfExists(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: item, to: target)
        }
    }

    private func clearDirectoryContents(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for item in contents {
            try fileManager.removeItem(at: item)
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func documentsIndexURL(for libraryId: UUID) -> URL {
        libraryDirectoryURL(for: libraryId)
            .appendingPathComponent("index", isDirectory: true)
            .appendingPathComponent("documents.json", isDirectory: false)
    }

    private func chunksIndexURL(for libraryId: UUID) -> URL {
        libraryDirectoryURL(for: libraryId)
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent("chunks.json", isDirectory: false)
    }

    private func persistDocumentsIndex(_ index: SidecarDocumentsIndex, libraryId: UUID) {
        let url = documentsIndexURL(for: libraryId)
        let encoder = makeJSONEncoder()
        if let data = try? encoder.encode(index) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func loadSidecarDocumentsIndex(from url: URL) throws -> SidecarDocumentsIndex {
        guard let data = try? Data(contentsOf: url) else {
            return SidecarDocumentsIndex(documents: [])
        }
        return try makeJSONDecoder().decode(SidecarDocumentsIndex.self, from: data)
    }

    private func loadSidecarChunksIndex(from url: URL) throws -> SidecarChunksIndex {
        guard let data = try? Data(contentsOf: url) else {
            return SidecarChunksIndex(chunks: [])
        }
        return try makeJSONDecoder().decode(SidecarChunksIndex.self, from: data)
    }

    private func persistChunksIndex(_ index: SidecarChunksIndex, libraryId: UUID) {
        let url = chunksIndexURL(for: libraryId)
        let encoder = makeJSONEncoder()
        if let data = try? encoder.encode(index) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func clearLibraryIndexLocked(libraryId: UUID, status: KnowledgeLibraryStatus) {
        ensureLibraryDirectories(for: libraryId)
        persistDocumentsIndex(SidecarDocumentsIndex(documents: []), libraryId: libraryId)
        persistChunksIndex(SidecarChunksIndex(chunks: []), libraryId: libraryId)
        updateLibrarySummaryLocked(
            libraryId: libraryId,
            documentCount: 0,
            chunkCount: 0,
            status: status
        )
    }

    private func updateLibrarySummaryLocked(
        libraryId: UUID,
        documentCount: Int,
        chunkCount: Int,
        status: KnowledgeLibraryStatus
    ) {
        var index = loadIndex()
        guard let idx = index.libraries.firstIndex(where: { $0.id == libraryId }) else { return }
        index.libraries[idx].documentCount = documentCount
        index.libraries[idx].chunkCount = chunkCount
        index.libraries[idx].status = status
        index.libraries[idx].updatedAt = Date()
        persistIndex(index)
        writeLibraryMetadata(index.libraries[idx])
    }

    private func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

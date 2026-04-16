import Foundation

enum KnowledgeLibraryStatus: String, Codable, Sendable {
    case idle
    case indexing
    case failed
}

enum KnowledgeSourceType: String, Codable, Sendable {
    case file
    case folder
    case web
}

struct KnowledgeLibrary: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var status: KnowledgeLibraryStatus
    var documentCount: Int
    var chunkCount: Int
    var sourceRoot: String?
}

struct KnowledgeDocument: Codable, Identifiable, Sendable {
    let id: UUID
    let libraryID: UUID
    var name: String
    var sourceType: KnowledgeSourceType
    var originalPath: String?
    var importedAt: Date
    var parseStatus: KnowledgeLibraryStatus
    var chunkCount: Int
}

struct KnowledgeDocumentSnippet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let citation: String?
    let snippet: String
}

struct RetrievalHit: Codable, Identifiable, Sendable {
    let id: UUID
    let libraryID: UUID
    let libraryName: String?
    let documentID: UUID?
    let title: String?
    let snippet: String
    let score: Double
    let citation: String?
    let source: String?
}

struct KnowledgeLibrariesIndex: Codable, Sendable {
    var libraries: [KnowledgeLibrary]
}

struct KnowledgeMaintenanceSummary: Codable, Sendable {
    var enabled: Bool
    var lastRunAt: Date?
    var lastTriggeredLibraryIDs: [String]
    var minimumIntervalMinutes: Int
    var webHours: Int
    var workspaceHours: Int
    var maxLibrariesPerRun: Int
}

struct KnowledgeMaintenanceCandidateSummary: Codable, Identifiable, Sendable {
    let id: String
    let libraryID: UUID
    let libraryName: String
    let reason: String
    let stalenessHours: Double
    let nextEligibleAt: Date?
    let isDue: Bool
}

struct KnowledgeMaintenancePlan: Codable, Sendable {
    let enabled: Bool
    let isRunning: Bool
    let lastRunAt: Date?
    let nextCheckAt: Date?
    let candidates: [KnowledgeMaintenanceCandidateSummary]
    let minimumIntervalMinutes: Int
    let webHours: Int
    let workspaceHours: Int
    let maxLibrariesPerRun: Int
}

struct KnowledgeAuditSummary: Codable, Sendable {
    let checkedLibraries: Int
    let repairedLibraries: Int
    let metadataMismatches: Int
    let missingDirectories: Int
    let orphanImportJobs: Int
    let orphanLibraryDirectories: Int
}

struct KnowledgeLibraryStorageMetrics: Codable, Sendable {
    let totalBytes: Int64
    let sourceBytes: Int64
    let parsedBytes: Int64
    let chunksBytes: Int64
    let indexBytes: Int64
    let cacheBytes: Int64
    let metadataBytes: Int64
}

struct KnowledgeLibraryPackagePreview: Identifiable, Codable, Sendable {
    let path: String
    let formatVersion: Int
    let exportedAt: Date
    let libraryName: String
    let sourceRoot: String?
    let documentCount: Int
    let chunkCount: Int
    let importJobCount: Int

    var id: String { path }
}

struct KnowledgeBackupPackagePreview: Identifiable, Codable, Sendable {
    let path: String
    let formatVersion: Int
    let exportedAt: Date
    let libraryCount: Int
    let includesSidecarConfig: Bool
    let includesMaintenanceState: Bool

    var id: String { path }
}

enum KnowledgeImportStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

struct KnowledgeImportJob: Codable, Identifiable, Sendable {
    let id: UUID
    let libraryId: UUID
    let sourceType: KnowledgeSourceType
    let source: String
    let title: String?
    var status: KnowledgeImportStatus
    var createdAt: Date
    var updatedAt: Date
    var errorMessage: String?
    var importedCount: Int?
    var skippedCount: Int?
    var failedCount: Int?
    var lastDurationMs: Double?
}

struct KnowledgeImportIndex: Codable, Sendable {
    var jobs: [KnowledgeImportJob]
}

import Foundation

struct UploadedAttachmentSegment: Codable {
    enum Kind: String, Codable {
        case page
        case sheet
        case segment
        case chunk

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue {
            case "page":
                self = .page
            case "sheet":
                self = .sheet
            case "segment", "section":
                self = .segment
            case "chunk":
                self = .chunk
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown attachment segment kind: \(rawValue)")
            }
        }
    }

    let index: Int
    let kind: Kind
    let title: String
    let content: String
}

struct UploadedAttachmentChunk: Codable {
    let index: Int
    let title: String
    let content: String
}

struct UploadedAttachmentDocument: Codable {
    let id: String
    let fileName: String
    let typeName: String
    let detail: String
    let createdAt: Date
    let chunks: [UploadedAttachmentChunk]
    let segments: [UploadedAttachmentSegment]
}

final class UploadedAttachmentStore {
    nonisolated static let shared = UploadedAttachmentStore()

    nonisolated private let baseDir: URL

    init(baseDir: URL? = nil) {
        AppStoragePaths.migrateLegacyDataIfNeeded()
        self.baseDir = baseDir ?? AppStoragePaths.attachmentsDir
        try? FileManager.default.createDirectory(at: self.baseDir, withIntermediateDirectories: true)
    }

    @discardableResult
    nonisolated func saveDocument(
        fileName: String,
        typeName: String,
        detail: String,
        chunks: [UploadedAttachmentChunk],
        segments: [UploadedAttachmentSegment] = []
    ) throws -> UploadedAttachmentDocument {
        struct PersistedDocument: Codable {
            let id: String
            let fileName: String
            let typeName: String
            let detail: String
            let createdAt: Date
            let chunks: [UploadedAttachmentChunk]
            let segments: [UploadedAttachmentSegment]
        }

        let document = UploadedAttachmentDocument(
            id: UUID().uuidString,
            fileName: fileName,
            typeName: typeName,
            detail: detail,
            createdAt: Date(),
            chunks: chunks,
            segments: segments
        )
        let persisted = PersistedDocument(
            id: document.id,
            fileName: document.fileName,
            typeName: document.typeName,
            detail: document.detail,
            createdAt: document.createdAt,
            chunks: document.chunks,
            segments: document.segments
        )
        let data = try JSONEncoder().encode(persisted)
        try data.write(to: fileURL(for: document.id), options: .atomic)
        return document
    }

    nonisolated func loadDocument(id: String) -> UploadedAttachmentDocument? {
        loadDocument(at: fileURL(for: id))
    }

    func chunk(attachmentID: String, index: Int) -> UploadedAttachmentChunk? {
        loadDocument(id: attachmentID)?.chunks.first(where: { $0.index == index })
    }

    func chunkRange(attachmentID: String, start: Int, end: Int) -> [UploadedAttachmentChunk] {
        guard let document = loadDocument(id: attachmentID) else { return [] }
        return document.chunks.filter { $0.index >= start && $0.index <= end }
    }

    func segment(attachmentID: String, kind: UploadedAttachmentSegment.Kind, index: Int) -> UploadedAttachmentSegment? {
        loadDocument(id: attachmentID)?.segments.first(where: { $0.kind == kind && $0.index == index })
    }

    func segment(attachmentID: String, kind: UploadedAttachmentSegment.Kind, title: String) -> UploadedAttachmentSegment? {
        guard let document = loadDocument(id: attachmentID) else { return nil }
        let normalizedQuery = normalize(title)
        return document.segments.first {
            $0.kind == kind && normalize($0.title) == normalizedQuery
        } ?? document.segments.first {
            $0.kind == kind && normalize($0.title).contains(normalizedQuery)
        }
    }

    func segmentRange(
        attachmentID: String,
        kind: UploadedAttachmentSegment.Kind,
        start: Int,
        end: Int
    ) -> [UploadedAttachmentSegment] {
        guard let document = loadDocument(id: attachmentID) else { return [] }
        return document.segments.filter { $0.kind == kind && $0.index >= start && $0.index <= end }
    }

    func allDocuments() -> [UploadedAttachmentDocument] {
        documentURLs()
            .filter { $0.pathExtension == "json" }
            .compactMap(loadDocument(at:))
    }

    @discardableResult
    func deleteDocument(id: String) -> Bool {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func cleanupOrphanedDocuments(retaining retainedIDs: Set<String>, olderThan age: TimeInterval? = nil) -> [String] {
        let cutoffDate = age.map { Date().addingTimeInterval(-$0) }
        var deletedIDs: [String] = []

        for url in documentURLs().filter({ $0.pathExtension == "json" }) {
            let id = url.deletingPathExtension().lastPathComponent
            guard !retainedIDs.contains(id) else { continue }

            if let cutoffDate {
                if let fileDate = documentTimestamp(for: url), fileDate >= cutoffDate {
                    continue
                }
                if documentTimestamp(for: url) == nil,
                   let document = loadDocument(at: url),
                   document.createdAt >= cutoffDate {
                    continue
                }
            }

            if deleteDocument(at: url) {
                deletedIDs.append(id)
            }
        }

        return deletedIDs
    }

    nonisolated private func fileURL(for id: String) -> URL {
        baseDir.appendingPathComponent("\(id).json")
    }

    nonisolated private func documentURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    nonisolated private func loadDocument(at url: URL) -> UploadedAttachmentDocument? {
        struct PersistedDocument: Codable {
            let id: String
            let fileName: String
            let typeName: String
            let detail: String
            let createdAt: Date
            let chunks: [UploadedAttachmentChunk]
            let segments: [UploadedAttachmentSegment]
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let persisted = try? JSONDecoder().decode(PersistedDocument.self, from: data) else { return nil }
        return UploadedAttachmentDocument(
            id: persisted.id,
            fileName: persisted.fileName,
            typeName: persisted.typeName,
            detail: persisted.detail,
            createdAt: persisted.createdAt,
            chunks: persisted.chunks,
            segments: persisted.segments
        )
    }

    nonisolated private func documentTimestamp(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }

    @discardableResult
    nonisolated private func deleteDocument(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    nonisolated private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

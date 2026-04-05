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
    static let shared = UploadedAttachmentStore()

    private let baseDir: URL

    init(baseDir: URL? = nil) {
        AppStoragePaths.migrateLegacyDataIfNeeded()
        self.baseDir = baseDir ?? AppStoragePaths.attachmentsDir
        try? FileManager.default.createDirectory(at: self.baseDir, withIntermediateDirectories: true)
    }

    @discardableResult
    func saveDocument(
        fileName: String,
        typeName: String,
        detail: String,
        chunks: [UploadedAttachmentChunk],
        segments: [UploadedAttachmentSegment] = []
    ) throws -> UploadedAttachmentDocument {
        let document = UploadedAttachmentDocument(
            id: UUID().uuidString,
            fileName: fileName,
            typeName: typeName,
            detail: detail,
            createdAt: Date(),
            chunks: chunks,
            segments: segments
        )
        let data = try JSONEncoder().encode(document)
        try data.write(to: fileURL(for: document.id), options: .atomic)
        return document
    }

    func loadDocument(id: String) -> UploadedAttachmentDocument? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UploadedAttachmentDocument.self, from: data)
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
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)) ?? []
        return fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(UploadedAttachmentDocument.self, from: data)
            }
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
        let orphaned = allDocuments().filter { document in
            guard !retainedIDs.contains(document.id) else { return false }
            if let cutoffDate {
                return document.createdAt < cutoffDate
            }
            return true
        }

        var deletedIDs: [String] = []
        for document in orphaned {
            if deleteDocument(id: document.id) {
                deletedIDs.append(document.id)
            }
        }
        return deletedIDs
    }

    private func fileURL(for id: String) -> URL {
        baseDir.appendingPathComponent("\(id).json")
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

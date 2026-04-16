import Foundation

struct KnowledgeReferenceRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let libraryID: UUID?
    let libraryName: String?
    let documentID: UUID?
    let title: String
    let source: String?
    let citation: String?
    let snippet: String
    let score: Double?

    init(
        id: UUID = UUID(),
        libraryID: UUID? = nil,
        libraryName: String? = nil,
        documentID: UUID? = nil,
        title: String,
        source: String? = nil,
        citation: String? = nil,
        snippet: String,
        score: Double? = nil
    ) {
        self.id = id
        self.libraryID = libraryID
        self.libraryName = libraryName
        self.documentID = documentID
        self.title = title
        self.source = source
        self.citation = citation
        self.snippet = snippet
        self.score = score
    }
}

struct ToolCallRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String

    nonisolated init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

struct ToolExecutionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String
}

struct Message: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var toolCalls: [ToolCallRecord]?
    var toolExecution: ToolExecutionRecord?
    var hiddenFromTranscript: Bool?
    var attachmentID: String?
    var imageDataURL: String?
    var previewImagePath: String?
    var previewImagePaths: [String]?
    var knowledgeReferences: [KnowledgeReferenceRecord]?

    enum Role: String, Codable, Sendable {
        case user, assistant, system, tool
    }

    init(
        role: Role,
        content: String,
        toolCalls: [ToolCallRecord]? = nil,
        toolExecution: ToolExecutionRecord? = nil,
        hiddenFromTranscript: Bool? = nil,
        attachmentID: String? = nil,
        imageDataURL: String? = nil,
        previewImagePath: String? = nil,
        previewImagePaths: [String]? = nil,
        knowledgeReferences: [KnowledgeReferenceRecord]? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolCalls = toolCalls
        self.toolExecution = toolExecution
        self.hiddenFromTranscript = hiddenFromTranscript
        self.attachmentID = attachmentID
        self.imageDataURL = imageDataURL
        self.previewImagePath = previewImagePath
        self.previewImagePaths = previewImagePaths
        self.knowledgeReferences = knowledgeReferences
    }

    var hidesAssistantToolCallMarker: Bool {
        role == .assistant &&
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !(toolCalls?.isEmpty ?? true)
    }

    var hidesAssistantToolPreamble: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == .assistant,
              !(toolCalls?.isEmpty ?? true),
              !trimmed.isEmpty,
              trimmed.count <= 120 else {
            return false
        }

        let disallowedMarkers = ["\n\n", "```", "|", "- ", "* ", "1. ", "2. ", "3. "]
        return !disallowedMarkers.contains { trimmed.contains($0) }
    }

    var isVisibleInTranscript: Bool {
        hiddenFromTranscript != true && !hidesAssistantToolCallMarker && !hidesAssistantToolPreamble
    }

    nonisolated var renderFingerprint: String {
        let prefix = String(content.prefix(160))
        let suffix = String(content.suffix(64))
        let toolCallSummary = toolCalls?.map(\.name).joined(separator: "|") ?? ""
        let toolExecutionName = toolExecution?.name ?? ""
        let attachmentSummary = attachmentID ?? ""
        let previewSummary = previewImagePaths?.joined(separator: "|") ?? previewImagePath ?? ""
        let knowledgeSummary = knowledgeReferences?
            .prefix(3)
            .map { "\($0.libraryName ?? "")::\($0.title)::\($0.citation ?? "")" }
            .joined(separator: "|") ?? ""

        return [
            role.rawValue,
            id.uuidString,
            "\(content.count)",
            prefix,
            suffix,
            hiddenFromTranscript == true ? "hidden" : "visible",
            toolCallSummary,
            toolExecutionName,
            attachmentSummary,
            previewSummary,
            knowledgeSummary
        ].joined(separator: "§")
    }
}

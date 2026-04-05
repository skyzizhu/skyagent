import Foundation

struct ToolCallRecord: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let arguments: String

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

struct ToolExecutionRecord: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var toolCalls: [ToolCallRecord]?
    var toolExecution: ToolExecutionRecord?
    var hiddenFromTranscript: Bool?
    var attachmentID: String?
    var previewImagePath: String?
    var previewImagePaths: [String]?

    enum Role: String, Codable {
        case user, assistant, system, tool
    }

    init(
        role: Role,
        content: String,
        toolCalls: [ToolCallRecord]? = nil,
        toolExecution: ToolExecutionRecord? = nil,
        hiddenFromTranscript: Bool? = nil,
        attachmentID: String? = nil,
        previewImagePath: String? = nil,
        previewImagePaths: [String]? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolCalls = toolCalls
        self.toolExecution = toolExecution
        self.hiddenFromTranscript = hiddenFromTranscript
        self.attachmentID = attachmentID
        self.previewImagePath = previewImagePath
        self.previewImagePaths = previewImagePaths
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
}

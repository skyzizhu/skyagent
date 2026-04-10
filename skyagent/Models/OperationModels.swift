import Foundation

struct OperationPreview: Identifiable, Equatable {
    let id: String
    let toolName: String
    let title: String
    let summary: String
    let detailLines: [String]
    let isDestructive: Bool
    let canUndo: Bool
}

enum UndoActionKind: String, Codable {
    case deleteCreatedItem
    case restoreBackup
}

struct UndoAction: Codable {
    let kind: UndoActionKind
    let targetPath: String
    let backupPath: String?
}

struct FileOperationRecord: Identifiable, Codable {
    let id: String
    let toolName: String
    let title: String
    let summary: String
    let detailLines: [String]
    let createdAt: Date
    let undoAction: UndoAction?
    var isUndone: Bool
}

struct ToolExecutionOutcome {
    let output: String
    let modelOutput: String?
    let operation: FileOperationRecord?
    let activatedSkillID: String?
    let skillContextMessage: String?
    let followupContextMessage: String?
    let previewImagePath: String?
    let previewImagePaths: [String]?

    init(
        output: String,
        modelOutput: String? = nil,
        operation: FileOperationRecord? = nil,
        activatedSkillID: String? = nil,
        skillContextMessage: String? = nil,
        followupContextMessage: String? = nil,
        previewImagePath: String? = nil,
        previewImagePaths: [String]? = nil
    ) {
        self.output = output
        self.modelOutput = modelOutput
        self.operation = operation
        self.activatedSkillID = activatedSkillID
        self.skillContextMessage = skillContextMessage
        self.followupContextMessage = followupContextMessage
        self.previewImagePath = previewImagePath
        self.previewImagePaths = previewImagePaths
    }
}

struct UndoOutcome {
    let success: Bool
    let message: String
}

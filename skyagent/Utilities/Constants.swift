import Foundation

enum AppStoragePaths {
    private static let fileManager = FileManager.default
    private static let appFolderName = "SkyAgent"

    static var applicationSupportRoot: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    static var dataDir: URL {
        applicationSupportRoot.appendingPathComponent("data", isDirectory: true)
    }

    static var attachmentsDir: URL {
        dataDir.appendingPathComponent("attachments", isDirectory: true)
    }

    static var memoriesDir: URL {
        dataDir.appendingPathComponent("memories", isDirectory: true)
    }

    static var conversationSummaryDir: URL {
        dataDir.appendingPathComponent("conversation-summaries", isDirectory: true)
    }

    static var globalMemoryFile: URL {
        dataDir.appendingPathComponent("MEMORY.md", isDirectory: false)
    }

    static var conversationsFile: URL {
        dataDir.appendingPathComponent("conversations.json", isDirectory: false)
    }

    static var undoDir: URL {
        dataDir.appendingPathComponent("undo", isDirectory: true)
    }

    static var legacyMiniAgentDataDir: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/workspace-coding/MiniAgent/data", isDirectory: true)
    }

    static func prepareDataDirectories() {
        try? fileManager.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: memoriesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: conversationSummaryDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: undoDir, withIntermediateDirectories: true)
    }

    static func migrateLegacyDataIfNeeded() {
        prepareDataDirectories()

        let legacyRoot = legacyMiniAgentDataDir
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return }

        migrateFileIfNeeded(from: legacyRoot.appendingPathComponent("conversations.json"), to: conversationsFile)
        migrateFileIfNeeded(from: legacyRoot.appendingPathComponent("MEMORY.md"), to: globalMemoryFile)
        migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("attachments", isDirectory: true), to: attachmentsDir)
        migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("memories", isDirectory: true), to: memoriesDir)
        migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("conversation-summaries", isDirectory: true), to: conversationSummaryDir)
        migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("undo", isDirectory: true), to: undoDir)
    }

    private static func migrateFileIfNeeded(from source: URL, to destination: URL) {
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }
        try? fileManager.copyItem(at: source, to: destination)
    }

    private static func migrateDirectoryContentsIfNeeded(from sourceDir: URL, to destinationDir: URL) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else { return }
        try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let sourceContents = (try? fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)) ?? []
        for sourceItem in sourceContents {
            let destinationItem = destinationDir.appendingPathComponent(sourceItem.lastPathComponent, isDirectory: false)
            guard !fileManager.fileExists(atPath: destinationItem.path) else { continue }
            try? fileManager.copyItem(at: sourceItem, to: destinationItem)
        }
    }
}

// Process timeout helper
extension Process {
    var timeout: TimeInterval? {
        get { nil }
        set {
            guard let interval = newValue else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
                if self?.isRunning == true {
                    self?.terminate()
                }
            }
        }
    }
}

extension String {
    static func collectingErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var result = ""
        for try await line in bytes.lines {
            result += line
        }
        return result
    }
}

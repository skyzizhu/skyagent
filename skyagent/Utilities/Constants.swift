import Foundation

enum AppStoragePaths {
    nonisolated(unsafe) private static let fileManager = FileManager.default
    nonisolated private static let appFolderName = "SkyAgent"
    nonisolated private static let userRootFolderName = ".skyagent"

    nonisolated static var userRoot: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(userRootFolderName, isDirectory: true)
    }

    nonisolated static var binDir: URL {
        userRoot.appendingPathComponent("bin", isDirectory: true)
    }

    nonisolated static var skillsDir: URL {
        userRoot.appendingPathComponent("skills", isDirectory: true)
    }

    nonisolated static var workspaceDir: URL {
        userRoot.appendingPathComponent("workspace", isDirectory: true)
    }

    nonisolated static var mcpDir: URL {
        userRoot.appendingPathComponent("mcp", isDirectory: true)
    }

    nonisolated static var logsDir: URL {
        userRoot.appendingPathComponent("logs", isDirectory: true)
    }

    nonisolated static var eventLogsDir: URL {
        logsDir.appendingPathComponent("events", isDirectory: true)
    }

    nonisolated static var mcpServersFile: URL {
        mcpDir.appendingPathComponent("servers.json", isDirectory: false)
    }

    nonisolated static var mcpLogsDir: URL {
        mcpDir.appendingPathComponent("logs", isDirectory: true)
    }

    nonisolated static var mcpActivityLogFile: URL {
        mcpLogsDir.appendingPathComponent("activity-log.json", isDirectory: false)
    }

    nonisolated static var applicationSupportRoot: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    nonisolated static var dataDir: URL {
        applicationSupportRoot.appendingPathComponent("data", isDirectory: true)
    }

    nonisolated static var attachmentsDir: URL {
        dataDir.appendingPathComponent("attachments", isDirectory: true)
    }

    nonisolated static var memoriesDir: URL {
        dataDir.appendingPathComponent("memories", isDirectory: true)
    }

    nonisolated static var conversationSummaryDir: URL {
        dataDir.appendingPathComponent("conversation-summaries", isDirectory: true)
    }

    nonisolated static var globalMemoryFile: URL {
        dataDir.appendingPathComponent("MEMORY.md", isDirectory: false)
    }

    nonisolated static var generatedMemoryFile: URL {
        dataDir.appendingPathComponent("GENERATED_MEMORY.md", isDirectory: false)
    }

    nonisolated static var memoryIndexFile: URL {
        dataDir.appendingPathComponent("memory-index.json", isDirectory: false)
    }

    nonisolated static var conversationsFile: URL {
        dataDir.appendingPathComponent("conversations.json", isDirectory: false)
    }

    nonisolated static var undoDir: URL {
        dataDir.appendingPathComponent("undo", isDirectory: true)
    }

    nonisolated static var legacyMiniAgentDataDir: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/workspace-coding/MiniAgent/data", isDirectory: true)
    }

    nonisolated static func prepareDataDirectories() {
        try? fileManager.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: eventLogsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mcpDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mcpLogsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: memoriesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: conversationSummaryDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: undoDir, withIntermediateDirectories: true)
    }

    nonisolated static func migrateLegacyDataIfNeeded() {
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

    nonisolated static func migrateMCPDataIfNeeded() {
        prepareDataDirectories()
        let legacyMCPServersFile = dataDir.appendingPathComponent("mcp-servers.json", isDirectory: false)
        migrateFileIfNeeded(from: legacyMCPServersFile, to: mcpServersFile)
    }

    nonisolated private static func migrateFileIfNeeded(from source: URL, to destination: URL) {
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }
        try? fileManager.copyItem(at: source, to: destination)
    }

    nonisolated private static func migrateDirectoryContentsIfNeeded(from sourceDir: URL, to destinationDir: URL) {
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

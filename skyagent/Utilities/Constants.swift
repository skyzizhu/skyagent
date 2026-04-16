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

    nonisolated static var skillsRegistryFile: URL {
        skillsDir.appendingPathComponent("skills-registry.json", isDirectory: false)
    }

    nonisolated static var workspaceDir: URL {
        userRoot.appendingPathComponent("default_workspace", isDirectory: true)
    }

    nonisolated static var mcpDir: URL {
        userRoot.appendingPathComponent("mcp", isDirectory: true)
    }

    nonisolated static var logsDir: URL {
        userRoot.appendingPathComponent("logs", isDirectory: true)
    }

    nonisolated static var internalDir: URL {
        userRoot.appendingPathComponent("internal", isDirectory: true)
    }

    nonisolated static var globalInternalDir: URL {
        internalDir.appendingPathComponent("global", isDirectory: true)
    }

    nonisolated static var conversationsRootDir: URL {
        internalDir.appendingPathComponent("conversations", isDirectory: true)
    }

    nonisolated static var workspaceFallbackRootDir: URL {
        internalDir.appendingPathComponent("workspaces", isDirectory: true)
    }

    nonisolated static var eventLogsDir: URL {
        logsDir.appendingPathComponent("events", isDirectory: true)
    }

    nonisolated static var mcpServersFile: URL {
        mcpDir.appendingPathComponent("servers.json", isDirectory: false)
    }

    nonisolated static var mcpLogsDir: URL {
        logsDir.appendingPathComponent("mcp", isDirectory: true)
    }

    nonisolated static var knowledgeDir: URL {
        userRoot.appendingPathComponent("knowledge", isDirectory: true)
    }

    nonisolated static var knowledgeLibrariesFile: URL {
        knowledgeDir.appendingPathComponent("libraries.json", isDirectory: false)
    }

    nonisolated static var knowledgeLibrariesRootDir: URL {
        knowledgeDir.appendingPathComponent("libraries", isDirectory: true)
    }

    nonisolated static var knowledgeImportsFile: URL {
        knowledgeDir.appendingPathComponent("imports.json", isDirectory: false)
    }

    nonisolated static var knowledgeMaintenanceStateFile: URL {
        knowledgeDir.appendingPathComponent("maintenance-state.json", isDirectory: false)
    }

    nonisolated static var knowledgeSidecarDir: URL {
        knowledgeDir.appendingPathComponent("sidecar", isDirectory: true)
    }

    nonisolated static var knowledgeSidecarConfigFile: URL {
        knowledgeSidecarDir.appendingPathComponent("config.json", isDirectory: false)
    }

    nonisolated static var knowledgeSidecarRuntimeDir: URL {
        knowledgeSidecarDir.appendingPathComponent("runtime", isDirectory: true)
    }

    nonisolated static var knowledgeSidecarLogsDir: URL {
        knowledgeSidecarDir.appendingPathComponent("logs", isDirectory: true)
    }

    nonisolated static var knowledgeSidecarScriptFile: URL {
        knowledgeSidecarDir.appendingPathComponent("sidecar.py", isDirectory: false)
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
        userRoot.appendingPathComponent("GLOBAL_SKYAGENT.md", isDirectory: false)
    }

    nonisolated static var generatedMemoryFile: URL {
        globalInternalDir.appendingPathComponent("GENERATED_GLOBAL_MEMORY.md", isDirectory: false)
    }

    nonisolated static var memoryIndexFile: URL {
        globalInternalDir.appendingPathComponent("GLOBAL_MEMORY_INDEX.json", isDirectory: false)
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

    nonisolated static func sessionContextDirectory(for conversationID: UUID) -> URL {
        conversationsRootDir.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    nonisolated static func sessionContextFile(for conversationID: UUID) -> URL {
        sessionContextDirectory(for: conversationID).appendingPathComponent("SESSION_CONTEXT.md", isDirectory: false)
    }

    nonisolated static func workspaceFallbackStateDirectory(for workspaceID: String) -> URL {
        workspaceFallbackRootDir.appendingPathComponent(workspaceID, isDirectory: true)
    }

    nonisolated static func workspaceFallbackProfileFile(for workspaceID: String) -> URL {
        workspaceFallbackStateDirectory(for: workspaceID).appendingPathComponent("WORKSPACE_PROFILE.md", isDirectory: false)
    }

    nonisolated static func workspaceFallbackFileIndexFile(for workspaceID: String) -> URL {
        workspaceFallbackStateDirectory(for: workspaceID).appendingPathComponent("FILE_INDEX.json", isDirectory: false)
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
        try? fileManager.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: knowledgeLibrariesRootDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: knowledgeSidecarDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: knowledgeSidecarRuntimeDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: knowledgeSidecarLogsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: globalInternalDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: conversationsRootDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: workspaceFallbackRootDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: memoriesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: conversationSummaryDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: undoDir, withIntermediateDirectories: true)
        ensureJSONFileExists(at: mcpServersFile, defaultContents: "{\n  \"mcpServers\": []\n}\n")
        ensureJSONFileExists(at: mcpActivityLogFile, defaultContents: "[]\n")
        ensureJSONFileExists(at: knowledgeLibrariesFile, defaultContents: "{\n  \"libraries\": []\n}\n")
        ensureJSONFileExists(at: knowledgeImportsFile, defaultContents: "{\n  \"jobs\": []\n}\n")
        ensureJSONFileExists(at: knowledgeMaintenanceStateFile, defaultContents: "{\n  \"lastRunAt\": null,\n  \"lastTriggeredLibraryIDs\": []\n}\n")
        ensureJSONFileExists(
            at: knowledgeSidecarConfigFile,
            defaultContents: "{\n  \"provider\": \"local\",\n  \"endpoint\": \"http://127.0.0.1:9876\",\n  \"parser\": {\n    \"backend\": \"auto\"\n  },\n  \"index\": {\n    \"backend\": \"auto\"\n  },\n  \"embedding\": {\n    \"model\": \"\",\n    \"endpoint\": \"\"\n  },\n  \"chunk\": {\n    \"strategy\": \"auto\",\n    \"maxTokens\": 800,\n    \"overlap\": 100\n  },\n  \"refresh\": {\n    \"enabled\": true,\n    \"minimumIntervalMinutes\": 180,\n    \"webHours\": 24,\n    \"workspaceHours\": 12,\n    \"maxLibrariesPerRun\": 2\n  }\n}\n"
        )
        ensureTextFileMatches(at: knowledgeSidecarScriptFile, contents: KnowledgeBaseSidecarBootstrap.pythonScript)
    }

    nonisolated static func migrateLegacyDataIfNeeded() {
        prepareDataDirectories()

        let legacyRoot = legacyMiniAgentDataDir
        if fileManager.fileExists(atPath: legacyRoot.path) {
            migrateFileIfNeeded(from: legacyRoot.appendingPathComponent("conversations.json"), to: conversationsFile)
            migrateFileIfNeeded(from: legacyRoot.appendingPathComponent("MEMORY.md"), to: globalMemoryFile)
            migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("attachments", isDirectory: true), to: attachmentsDir)
            migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("memories", isDirectory: true), to: memoriesDir)
            migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("conversation-summaries", isDirectory: true), to: conversationSummaryDir)
            migrateDirectoryContentsIfNeeded(from: legacyRoot.appendingPathComponent("undo", isDirectory: true), to: undoDir)
        }

        let currentAppSupportMemoryFile = dataDir.appendingPathComponent("MEMORY.md", isDirectory: false)
        let currentAppSupportGeneratedFile = dataDir.appendingPathComponent("GENERATED_MEMORY.md", isDirectory: false)
        let currentAppSupportMemoryIndexFile = dataDir.appendingPathComponent("memory-index.json", isDirectory: false)
        let legacyUserRootGeneratedFile = userRoot.appendingPathComponent("GENERATED_GLOBAL_MEMORY.md", isDirectory: false)
        let legacyUserRootIndexFile = userRoot.appendingPathComponent("GLOBAL_MEMORY_INDEX.json", isDirectory: false)
        migrateFileIfNeeded(from: currentAppSupportMemoryFile, to: globalMemoryFile)
        migrateFileIfNeeded(from: currentAppSupportGeneratedFile, to: generatedMemoryFile)
        migrateFileIfNeeded(from: currentAppSupportMemoryIndexFile, to: memoryIndexFile)
        migrateFileIfNeeded(from: legacyUserRootGeneratedFile, to: generatedMemoryFile)
        migrateFileIfNeeded(from: legacyUserRootIndexFile, to: memoryIndexFile)
    }

    nonisolated static func migrateMCPDataIfNeeded() {
        prepareDataDirectories()
        let legacyMCPServersFile = dataDir.appendingPathComponent("mcp-servers.json", isDirectory: false)
        let legacyActivityLogFile = userRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("activity-log.json", isDirectory: false)
        migrateFileIfNeeded(from: legacyMCPServersFile, to: mcpServersFile)
        migrateFileIfNeeded(from: legacyActivityLogFile, to: mcpActivityLogFile)
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

    nonisolated private static func ensureJSONFileExists(at url: URL, defaultContents: String) {
        guard !fileManager.fileExists(atPath: url.path),
              let data = defaultContents.data(using: .utf8) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    nonisolated private static func ensureTextFileMatches(at url: URL, contents: String) {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return
        }
        guard let data = contents.data(using: .utf8) else { return }
        try? data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    nonisolated static func normalizeSandboxPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }

        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
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

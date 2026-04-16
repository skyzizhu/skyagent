import Foundation
import CryptoKit

private struct WorkspaceProfileSnapshot: Codable {
    let workspaceID: String
    let workspacePath: String
    let projectType: String
    let entryFiles: [String]
    let highPriorityDirectories: [String]
    let protectedDirectories: [String]
    let recentFiles: [String]
    let constraints: [String]
    let generatedAt: Date
}

private struct WorkspaceFileIndexEntry: Codable {
    let path: String
    let ext: String
    let category: String
    let tags: [String]
    let isEntry: Bool
    let modifiedAt: Date?
    let size: Int64
}

private struct WorkspaceDirectorySnapshot {
    let id: String
    let rootURL: URL
    let internalDirectoryURL: URL
    let profileURL: URL
    let fileIndexURL: URL
}

final class WorkspaceMemoryService {
    static let shared = WorkspaceMemoryService()

    private static let forcedRefreshDebounceInterval: TimeInterval = 5
    private static let artifactValidationDebounceInterval: TimeInterval = 30

    private let queue = DispatchQueue(label: "SkyAgent.WorkspaceMemoryService", qos: .utility)
    private var cachedWorkspaceContexts: [String: (modificationDate: Date?, context: String)] = [:]
    private var cachedProfileContexts: [String: (modificationDate: Date?, context: String)] = [:]
    private var lastArtifactRefreshDates: [String: Date] = [:]
    private var lastArtifactValidationDates: [String: Date] = [:]

    private init() {}

    func ensureWorkspaceArtifacts(for workspacePath: String, forceRefresh: Bool = false) {
        guard let snapshot = workspaceSnapshot(for: workspacePath) else { return }
        queue.async {
            self.ensureWorkspaceRootFileUnsafe(snapshot)
            self.refreshInternalArtifactsUnsafe(snapshot, forceRefresh: forceRefresh)
        }
    }

    func ensureWorkspaceMemoryFile(for workspacePath: String) {
        ensureWorkspaceArtifacts(for: workspacePath)
    }

    func loadWorkspaceMemoryContext(for workspacePath: String, maxCharacters: Int = 900) -> String {
        guard let snapshot = workspaceSnapshot(for: workspacePath) else { return "" }

        return queue.sync {
            self.ensureWorkspaceRootFileUnsafe(snapshot)
            let fileURL = snapshot.rootURL.appendingPathComponent("SKYAGENT.md", isDirectory: false)
            let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = cachedWorkspaceContexts[snapshot.id], cached.modificationDate == modificationDate {
                return cached.context
            }

            let rawContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                cachedWorkspaceContexts[snapshot.id] = (modificationDate, "")
                return ""
            }
            guard !Self.isWorkspaceTemplateContent(trimmed, workspacePath: snapshot.rootURL.path) else {
                cachedWorkspaceContexts[snapshot.id] = (modificationDate, "")
                return ""
            }

            let focusedMemory = focusedWorkspaceMemoryContent(from: trimmed)
            let truncated = Self.truncate(focusedMemory, maxCharacters: maxCharacters)
            let context = Self.workspaceMemoryContextWrapper(content: truncated, language: L10n.contentLanguage)
            cachedWorkspaceContexts[snapshot.id] = (modificationDate, context)
            return context
        }
    }

    func loadWorkspaceProfileContext(for workspacePath: String, maxCharacters: Int = 700) -> String {
        guard let snapshot = workspaceSnapshot(for: workspacePath) else { return "" }
        ensureWorkspaceArtifacts(for: workspacePath)

        return queue.sync {
            let modificationDate = (try? snapshot.profileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = cachedProfileContexts[snapshot.id], cached.modificationDate == modificationDate {
                return cached.context
            }

            let rawContent = (try? String(contentsOf: snapshot.profileURL, encoding: .utf8)) ?? ""
            let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                cachedProfileContexts[snapshot.id] = (modificationDate, "")
                return ""
            }

            let focusedProfile = focusedWorkspaceProfileContent(from: trimmed)
            let truncated = Self.truncate(focusedProfile, maxCharacters: maxCharacters)
            let context = Self.workspaceProfileContextWrapper(content: truncated, language: L10n.contentLanguage)
            cachedProfileContexts[snapshot.id] = (modificationDate, context)
            return context
        }
    }

    func workspaceMemoryFilePath(for workspacePath: String) -> String {
        guard let snapshot = workspaceSnapshot(for: workspacePath) else { return "" }
        return snapshot.rootURL.appendingPathComponent("SKYAGENT.md", isDirectory: false).path
    }

    func workspaceProfileFilePath(for workspacePath: String) -> String {
        guard let snapshot = workspaceSnapshot(for: workspacePath) else { return "" }
        return snapshot.profileURL.path
    }

    func workspaceFileIndexPath(for workspacePath: String) -> String {
        guard let snapshot = workspaceSnapshot(for: workspacePath) else { return "" }
        return snapshot.fileIndexURL.path
    }

    private func workspaceSnapshot(for workspacePath: String) -> WorkspaceDirectorySnapshot? {
        let normalizedPath = normalizedWorkspacePath(workspacePath)
        guard !normalizedPath.isEmpty else { return nil }
        let workspaceID = workspaceIdentifier(for: normalizedPath)
        let rootURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        let internalDirectoryURL = resolvedWorkspaceInternalDirectory(rootURL: rootURL, workspaceID: workspaceID)
        return WorkspaceDirectorySnapshot(
            id: workspaceID,
            rootURL: rootURL,
            internalDirectoryURL: internalDirectoryURL,
            profileURL: internalDirectoryURL.appendingPathComponent("WORKSPACE_PROFILE.md", isDirectory: false),
            fileIndexURL: internalDirectoryURL.appendingPathComponent("FILE_INDEX.json", isDirectory: false)
        )
    }

    private func normalizedWorkspacePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    private func workspaceIdentifier(for normalizedPath: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedPath.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private func ensureWorkspaceRootFileUnsafe(_ snapshot: WorkspaceDirectorySnapshot) {
        let fileURL = snapshot.rootURL.appendingPathComponent("SKYAGENT.md", isDirectory: false)
        let template = Self.workspaceMemoryTemplate(for: snapshot.rootURL.path, language: L10n.contentLanguage)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.createDirectory(at: snapshot.rootURL, withIntermediateDirectories: true)
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }

        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || Self.isWorkspaceTemplateContent(trimmed, workspacePath: snapshot.rootURL.path) {
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func refreshInternalArtifactsUnsafe(_ snapshot: WorkspaceDirectorySnapshot, forceRefresh: Bool) {
        try? FileManager.default.createDirectory(
            at: snapshot.internalDirectoryURL,
            withIntermediateDirectories: true
        )
        migrateWorkspaceArtifactsIfNeeded(snapshot)

        let now = Date()
        let lastRefreshAt = lastArtifactRefreshDates[snapshot.id]
        if forceRefresh,
           let lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt) < Self.forcedRefreshDebounceInterval {
            return
        }

        let profileExists = FileManager.default.fileExists(atPath: snapshot.profileURL.path)
        let indexExists = FileManager.default.fileExists(atPath: snapshot.fileIndexURL.path)
        let needsProfileRefresh: Bool
        let needsIndexRefresh: Bool

        if forceRefresh || !profileExists || !indexExists {
            needsProfileRefresh = forceRefresh || !profileExists
            needsIndexRefresh = forceRefresh || !indexExists
        } else {
            if let lastValidationAt = lastArtifactValidationDates[snapshot.id],
               now.timeIntervalSince(lastValidationAt) < Self.artifactValidationDebounceInterval {
                return
            }

            let artifactReferenceDate = min(
                (try? snapshot.profileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast,
                (try? snapshot.fileIndexURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            )
            let hasWorkspaceChanges = workspaceHasChangesSince(snapshot.rootURL, referenceDate: artifactReferenceDate)
            lastArtifactValidationDates[snapshot.id] = now
            guard hasWorkspaceChanges else { return }
            needsProfileRefresh = true
            needsIndexRefresh = true
        }

        guard needsProfileRefresh || needsIndexRefresh else { return }

        let scan = scanWorkspace(snapshot.rootURL)
        if needsProfileRefresh {
            let profile = buildProfileMarkdown(from: scan, workspaceID: snapshot.id, workspacePath: snapshot.rootURL.path)
            try? profile.write(to: snapshot.profileURL, atomically: true, encoding: .utf8)
            cachedProfileContexts[snapshot.id] = nil
        }
        if needsIndexRefresh {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(scan.indexEntries) {
                try? data.write(to: snapshot.fileIndexURL, options: .atomic)
            }
        }
        lastArtifactRefreshDates[snapshot.id] = now
        lastArtifactValidationDates[snapshot.id] = now
    }

    private func resolvedWorkspaceInternalDirectory(rootURL: URL, workspaceID: String) -> URL {
        let preferred = rootURL.appendingPathComponent(".skyagent", isDirectory: true)
        if isWritableWorkspaceInternalDirectory(preferred) {
            return preferred
        }
        return AppStoragePaths.workspaceFallbackStateDirectory(for: workspaceID)
    }

    private func isWritableWorkspaceInternalDirectory(_ directoryURL: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let probeURL = directoryURL.appendingPathComponent(".write-test-\(UUID().uuidString)", isDirectory: false)
            try Data().write(to: probeURL, options: .atomic)
            try? fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    private func migrateWorkspaceArtifactsIfNeeded(_ snapshot: WorkspaceDirectorySnapshot) {
        let fileManager = FileManager.default
        let legacyDirectory = AppStoragePaths.userRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(snapshot.id, isDirectory: true)
        let fallbackDirectory = AppStoragePaths.workspaceFallbackStateDirectory(for: snapshot.id)

        let candidateDirectories = [legacyDirectory, fallbackDirectory]
            .filter { $0.path != snapshot.internalDirectoryURL.path }

        for sourceDirectory in candidateDirectories {
            guard fileManager.fileExists(atPath: sourceDirectory.path) else { continue }

            let sourceProfile = sourceDirectory.appendingPathComponent("WORKSPACE_PROFILE.md", isDirectory: false)
            let sourceIndex = sourceDirectory.appendingPathComponent("FILE_INDEX.json", isDirectory: false)

            if !fileManager.fileExists(atPath: snapshot.profileURL.path),
               fileManager.fileExists(atPath: sourceProfile.path) {
                try? fileManager.copyItem(at: sourceProfile, to: snapshot.profileURL)
            }

            if !fileManager.fileExists(atPath: snapshot.fileIndexURL.path),
               fileManager.fileExists(atPath: sourceIndex.path) {
                try? fileManager.copyItem(at: sourceIndex, to: snapshot.fileIndexURL)
            }
        }
    }

    private func scanWorkspace(_ rootURL: URL) -> WorkspaceScanResult {
        let fileManager = FileManager.default

        let entryFileNames: Set<String> = [
            "package.swift", "package.json", "pyproject.toml", "requirements.txt",
            "podfile", "cartfile", "gemfile", "go.mod", "cargo.toml",
            "readme.md", "main.swift", "app.swift", "contentsview.swift",
            "skyagent.md"
        ]

        let topLevelNames = ((try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .map(\.lastPathComponent)

        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )

        var indexEntries: [WorkspaceFileIndexEntry] = []
        var topLevelDirectories: [String] = []
        var keyFiles: [String] = []
        var recentCandidates: [(path: String, date: Date)] = []
        var fileCountByExtension: [String: Int] = [:]

        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let lastPath = fileURL.lastPathComponent

            if Self.skipDirectoryNames.contains(lastPath) {
                enumerator?.skipDescendants()
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            if values?.isDirectory == true, !relativePath.contains("/") {
                topLevelDirectories.append(relativePath)
                continue
            }

            guard values?.isRegularFile == true else { continue }
            if indexEntries.count >= 800 { break }

            let ext = fileURL.pathExtension.lowercased()
            fileCountByExtension[ext, default: 0] += 1

            let lowerName = lastPath.lowercased()
            let isEntry = entryFileNames.contains(lowerName) || lowerName.hasSuffix(".xcodeproj")
            let category = categorizeFile(path: relativePath, ext: ext)
            let tags = tagsForFile(path: relativePath, lowerName: lowerName, ext: ext, isEntry: isEntry)
            let size = Int64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate

            indexEntries.append(
                WorkspaceFileIndexEntry(
                    path: relativePath,
                    ext: ext,
                    category: category,
                    tags: tags,
                    isEntry: isEntry,
                    modifiedAt: modifiedAt,
                    size: size
                )
            )

            if isEntry || tags.contains("workspace-rule") || tags.contains("config") {
                keyFiles.append(relativePath)
            }
            if let modifiedAt {
                recentCandidates.append((relativePath, modifiedAt))
            }
        }

        let projectType = detectProjectType(topLevelNames: topLevelNames, keyFiles: keyFiles, fileCountByExtension: fileCountByExtension)
        let highPriorityDirectories = prioritizeDirectories(topLevelDirectories, keyFiles: keyFiles)
        let protectedDirectories = topLevelDirectories.filter { ["build", "DerivedData", "Pods", ".git", "node_modules"].contains($0) }
        let recentFiles = recentCandidates
            .sorted { $0.date > $1.date }
            .prefix(8)
            .map(\.path)

        let constraints = buildWorkspaceConstraints(projectType: projectType, topLevelNames: topLevelNames, keyFiles: keyFiles)

        return WorkspaceScanResult(
            projectType: projectType,
            entryFiles: deduplicated(Array(keyFiles.prefix(10))),
            highPriorityDirectories: highPriorityDirectories,
            protectedDirectories: protectedDirectories,
            recentFiles: recentFiles,
            constraints: constraints,
            indexEntries: indexEntries.sorted { $0.path < $1.path }
        )
    }

    private func buildProfileMarkdown(from scan: WorkspaceScanResult, workspaceID: String, workspacePath: String) -> String {
        let snapshot = WorkspaceProfileSnapshot(
            workspaceID: workspaceID,
            workspacePath: workspacePath,
            projectType: scan.projectType,
            entryFiles: scan.entryFiles,
            highPriorityDirectories: scan.highPriorityDirectories,
            protectedDirectories: scan.protectedDirectories,
            recentFiles: scan.recentFiles,
            constraints: scan.constraints,
            generatedAt: Date()
        )

        var lines: [String] = [
            "# WORKSPACE PROFILE",
            "",
            "- 工作区 ID：\(snapshot.workspaceID)",
            "- 工作区路径：\(snapshot.workspacePath)",
            "- 项目类型：\(snapshot.projectType)",
            "- 生成时间：\(snapshot.generatedAt.ISO8601Format())",
            ""
        ]

        lines += makeSection("核心入口文件", items: snapshot.entryFiles)
        lines += makeSection("高优先级目录", items: snapshot.highPriorityDirectories)
        lines += makeSection("不建议轻易修改的目录", items: snapshot.protectedDirectories)
        lines += makeSection("最近高频文件", items: snapshot.recentFiles)
        lines += makeSection("当前项目约束", items: snapshot.constraints)

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func workspaceHasChangesSince(_ rootURL: URL, referenceDate: Date) -> Bool {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )

        var inspectedCount = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let lastPath = fileURL.lastPathComponent
            if Self.skipDirectoryNames.contains(lastPath) {
                enumerator?.skipDescendants()
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }

            inspectedCount += 1
            if let modifiedAt = values?.contentModificationDate, modifiedAt > referenceDate {
                return true
            }
            if inspectedCount >= 800 {
                break
            }
        }

        return false
    }

    private func focusedWorkspaceProfileContent(from markdown: String) -> String {
        let preferredSections = [
            ["核心入口文件", "Core Entry Files"],
            ["高优先级目录", "High-Priority Directories"],
            ["不建议轻易修改的目录", "Protected Directories"],
            ["当前项目约束", "Current Project Constraints"]
        ]

        let lines = markdown.components(separatedBy: .newlines)
        var sections: [String: [String]] = [:]
        var currentSection: String?

        for line in lines {
            if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let currentSection {
                    sections[currentSection] = [line]
                }
                continue
            }

            guard let currentSection else { continue }
            sections[currentSection, default: []].append(line)
        }

        let focused = preferredSections.compactMap { aliases -> String? in
            guard let sectionLines = matchingSectionLines(in: sections, aliases: aliases), sectionLines.count > 1 else { return nil }
            return sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return focused.isEmpty ? markdown : focused.joined(separator: "\n\n")
    }

    private func focusedWorkspaceMemoryContent(from markdown: String) -> String {
        let preferredSections = [
            ["项目约定", "項目約定", "Project Rules", "プロジェクト規約", "프로젝트 규칙", "Projektregeln", "Règles du projet"],
            ["特殊说明", "特殊說明", "Special Notes", "補足", "특이 사항", "Besondere Hinweise", "Notes spéciales"],
            ["默认协作规则", "預設協作規則", "Default Collaboration Rules", "既定の協業ルール", "기본 협업 규칙", "Standardregeln für die Zusammenarbeit", "Règles de collaboration par défaut"]
        ]

        let lines = markdown.components(separatedBy: .newlines)
        var sections: [String: [String]] = [:]
        var currentSection: String?

        for line in lines {
            if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let currentSection {
                    sections[currentSection] = [line]
                }
                continue
            }

            guard let currentSection else { continue }
            sections[currentSection, default: []].append(line)
        }

        let focused = preferredSections.compactMap { aliases -> String? in
            guard let sectionLines = matchingSectionLines(in: sections, aliases: aliases), sectionLines.count > 1 else { return nil }
            return sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !focused.isEmpty {
            return focused.joined(separator: "\n\n")
        }

        let fallbackLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        return fallbackLines.prefix(10).joined(separator: "\n")
    }

    private func matchingSectionLines(in sections: [String: [String]], aliases: [String]) -> [String]? {
        let normalizedAliases = Set(aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for (title, sectionLines) in sections {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedAliases.contains(normalizedTitle) {
                return sectionLines
            }
        }
        return nil
    }

    private func detectProjectType(topLevelNames: [String], keyFiles: [String], fileCountByExtension: [String: Int]) -> String {
        let lowerTopLevel = Set(topLevelNames.map { $0.lowercased() })
        let lowerKeyFiles = Set(keyFiles.map { $0.lowercased() })

        if lowerTopLevel.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) ||
            lowerKeyFiles.contains(where: { $0.hasSuffix("package.swift") || $0.hasSuffix("contentview.swift") }) {
            return "Apple / Swift 项目"
        }
        if lowerTopLevel.contains("package.json") || lowerKeyFiles.contains(where: { $0.hasSuffix("package.json") }) {
            return "Node / Web 项目"
        }
        if lowerTopLevel.contains("pyproject.toml") || lowerTopLevel.contains("requirements.txt") {
            return "Python 项目"
        }
        if lowerTopLevel.contains("go.mod") {
            return "Go 项目"
        }
        if lowerTopLevel.contains("cargo.toml") {
            return "Rust 项目"
        }
        if fileCountByExtension["md", default: 0] > 20 && fileCountByExtension["swift", default: 0] == 0 {
            return "文档型项目"
        }
        return "通用工作区"
    }

    private func prioritizeDirectories(_ topLevelDirectories: [String], keyFiles: [String]) -> [String] {
        let priorityNames = ["skyagent", "Sources", "src", "app", "Views", "Services", "Models", "docs"]
        var ranked: [String] = []

        for name in priorityNames {
            if let match = topLevelDirectories.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                ranked.append(match)
            }
        }

        for directory in topLevelDirectories where !ranked.contains(directory) {
            if keyFiles.contains(where: { $0.hasPrefix(directory + "/") }) {
                ranked.append(directory)
            }
        }

        return Array(ranked.prefix(8))
    }

    private func buildWorkspaceConstraints(projectType: String, topLevelNames: [String], keyFiles: [String]) -> [String] {
        var constraints: [String] = ["优先遵守当前工作区根目录中的 SKYAGENT.md。", "需要真实文件内容时再按需读取，不要全量展开目录。"]

        if projectType == "Apple / Swift 项目" {
            constraints.append("这是 Apple / Swift 项目，优先保持现有 SwiftUI / Xcode 结构与命名风格。")
            if topLevelNames.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                constraints.append("涉及构建与验证时，优先考虑 xcodebuild 工作流。")
            }
        }
        if keyFiles.contains(where: { $0.lowercased().contains("package.json") }) {
            constraints.append("如果涉及前端或脚本依赖，优先参考 package.json / 锁文件。")
        }
        if keyFiles.contains(where: { $0.lowercased().contains("readme.md") }) {
            constraints.append("若需理解项目用途，README.md 是高信号入口。")
        }

        return constraints
    }

    private func deduplicated(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }

    private func categorizeFile(path: String, ext: String) -> String {
        let lowercasedPath = path.lowercased()
        if lowercasedPath.contains("asset") || ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "pdf"].contains(ext) {
            return "asset"
        }
        if ["md", "txt", "docx"].contains(ext) {
            return "document"
        }
        if ["json", "yaml", "yml", "toml", "plist", "xcconfig", "env"].contains(ext) {
            return "config"
        }
        if ["swift", "m", "mm", "h", "js", "ts", "tsx", "jsx", "py", "go", "rs", "java", "kt", "rb", "php", "sh", "bash", "zsh", "css", "scss", "html"].contains(ext) {
            return "code"
        }
        return "other"
    }

    private func tagsForFile(path: String, lowerName: String, ext: String, isEntry: Bool) -> [String] {
        var tags: [String] = []
        if isEntry { tags.append("entry") }
        if lowerName == "readme.md" { tags.append("readme") }
        if lowerName == "skyagent.md" { tags.append("workspace-rule") }
        if ["json", "yaml", "yml", "toml", "plist", "xcconfig"].contains(ext) { tags.append("config") }
        if path.lowercased().contains("test") { tags.append("test") }
        if path.lowercased().contains("resource") || path.lowercased().contains("asset") { tags.append("resource") }
        return tags
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let prefix = text.prefix(maxCharacters)
        return "\(prefix)\n\n[以下内容已截断，请按需打开对应文件查看完整内容]"
    }

    private static func workspaceMemoryTemplate(for workspacePath: String, language: AppContentLanguage) -> String {
        switch language {
        case .zhHans:
            return """
            # SKYAGENT

            这是当前工作区的长期协作说明文件。SkyAgent 会在新会话中优先参考这里的规则。
            只写“这个项目以后都成立”的约定，不要写一次性的临时任务。

            ## 工作区

            - 路径：\(workspacePath)

            ## 适合写在这里的内容

            - 项目技术栈与目录约定
            - 默认构建 / 运行 / 验证命令
            - 当前项目长期成立的输出格式、文件策略、协作偏好
            - 需要长期遵守的边界和限制

            ## 不适合写在这里的内容

            - 这一次临时要做的任务
            - 某一轮对话里的短期要求
            - 临时文件名、一次性路径、一次性结果

            ## 默认协作规则

            - 默认使用中文交流。
            - 优先做最小必要改动，避免无关重构。
            - 如需改动多个文件，先保持结构和风格一致。

            ## 项目约定

            - 在这里写当前项目长期成立的技术栈、目录约定、构建命令、输出格式等。

            ## 特殊说明

            - 在这里写当前工作区特有的边界、限制、工具偏好或交付要求。
            """
        case .zhHant:
            return """
            # SKYAGENT

            這是目前工作區的長期協作說明文件。SkyAgent 會在新會話中優先參考這裡的規則。
            只寫「這個專案之後都成立」的約定，不要寫一次性的臨時任務。

            ## 工作區

            - 路徑：\(workspacePath)

            ## 適合寫在這裡的內容

            - 專案技術棧與目錄約定
            - 預設建置 / 執行 / 驗證命令
            - 目前專案長期成立的輸出格式、文件策略、協作偏好
            - 需要長期遵守的邊界與限制

            ## 不適合寫在這裡的內容

            - 這一次臨時要做的任務
            - 某一輪對話裡的短期要求
            - 臨時檔名、一次性路徑、一次性結果

            ## 預設協作規則

            - 預設使用中文交流。
            - 優先做最小必要改動，避免無關重構。
            - 如需修改多個檔案，先保持結構與風格一致。

            ## 專案約定

            - 在這裡寫目前專案長期成立的技術棧、目錄約定、建置命令、輸出格式等。

            ## 特殊說明

            - 在這裡寫目前工作區特有的邊界、限制、工具偏好或交付要求。
            """
        case .en:
            return """
            # SKYAGENT

            This file stores long-term collaboration rules for the current workspace. SkyAgent will prioritize these rules in new conversations.
            Only write conventions that should remain true for this project over time. Do not write one-off temporary tasks here.

            ## Workspace

            - Path: \(workspacePath)

            ## Good Things To Put Here

            - Tech stack and directory conventions
            - Default build / run / validation commands
            - Long-term output formats, file handling preferences, and collaboration habits for this project
            - Boundaries and constraints that should be respected over time

            ## Do Not Put Here

            - Temporary tasks for this round
            - Short-lived requirements from one conversation
            - Temporary file names, one-off paths, or one-off results

            ## Default Collaboration Rules

            - Keep changes as small and focused as possible.
            - Avoid unrelated refactors.
            - Keep structure and style consistent when touching multiple files.

            ## Project Rules

            - Write the project's long-term stack, directory conventions, build commands, and output expectations here.

            ## Special Notes

            - Write any workspace-specific boundaries, restrictions, tool preferences, or delivery expectations here.
            """
        case .ja:
            return """
            # SKYAGENT

            このファイルは、現在のワークスペースで長期的に有効な協業ルールを保存するためのものです。SkyAgent は新しい会話でここに書かれた内容を優先的に参照します。
            このプロジェクトで今後も有効なルールだけを書いてください。一時的なタスクは書かないでください。

            ## ワークスペース

            - パス：\(workspacePath)

            ## ここに書くと良い内容

            - 技術スタックとディレクトリ規約
            - 既定の build / run / 検証コマンド
            - 長期的に有効な出力形式、ファイル方針、協業の好み
            - 継続的に守るべき制約や境界

            ## ここに書かない内容

            - 今回だけの一時タスク
            - その場限りの短期要求
            - 一時的なファイル名、単発パス、単発結果

            ## 既定の協業ルール

            - 変更はできるだけ小さく保つ。
            - 関係のないリファクタは避ける。
            - 複数ファイルを触るときは構成とスタイルを揃える。

            ## プロジェクト規約

            - このプロジェクトで長期的に有効な技術スタック、ディレクトリ規約、ビルドコマンド、出力期待値を書いてください。

            ## 補足

            - このワークスペース固有の制約、制限、ツール方針、納品ルールがあればここに書いてください。
            """
        case .ko:
            return """
            # SKYAGENT

            이 파일은 현재 워크스페이스의 장기 협업 규칙을 저장하는 곳입니다. SkyAgent는 새 대화에서 이 규칙을 우선 참고합니다.
            이 프로젝트에서 앞으로도 계속 유효한 규칙만 적고, 일회성 작업은 적지 마세요.

            ## 워크스페이스

            - 경로: \(workspacePath)

            ## 여기에 적기 좋은 내용

            - 기술 스택과 디렉터리 규칙
            - 기본 build / run / 검증 명령
            - 장기적으로 유지할 출력 형식, 파일 처리 방식, 협업 선호
            - 계속 지켜야 할 경계와 제약

            ## 여기에 적지 말아야 할 내용

            - 이번 한 번만 처리할 임시 작업
            - 특정 대화에서만 유효한 짧은 요구사항
            - 임시 파일명, 일회성 경로, 일회성 결과

            ## 기본 협업 규칙

            - 변경은 가능한 한 작고 집중적으로 유지합니다.
            - 관련 없는 리팩터링은 피합니다.
            - 여러 파일을 수정할 때는 구조와 스타일을 일관되게 유지합니다.

            ## 프로젝트 규칙

            - 이 프로젝트에서 장기적으로 유효한 기술 스택, 디렉터리 규칙, 빌드 명령, 출력 기대치를 여기에 적으세요.

            ## 특이 사항

            - 워크스페이스 고유의 제약, 제한, 도구 선호, 전달 요구사항이 있으면 여기에 적으세요.
            """
        case .de:
            return """
            # SKYAGENT

            Diese Datei speichert langfristige Zusammenarbeitregeln für den aktuellen Workspace. SkyAgent berücksichtigt diese Regeln in neuen Unterhaltungen bevorzugt.
            Schreiben Sie hier nur Regeln hinein, die für dieses Projekt dauerhaft gelten sollen. Einmalige Aufgaben gehören nicht hierher.

            ## Workspace

            - Pfad: \(workspacePath)

            ## Gute Inhalte für diese Datei

            - Tech-Stack und Verzeichnis-Konventionen
            - Standard-Build / Run / Prüf-Befehle
            - Dauerhafte Ausgabeformate, Dateistrategien und Arbeitsweisen für dieses Projekt
            - Grenzen und Einschränkungen, die langfristig beachtet werden sollen

            ## Nicht hier hinein

            - Temporäre Aufgaben für diese Runde
            - Kurzlebige Anforderungen aus einer einzelnen Unterhaltung
            - Temporäre Dateinamen, einmalige Pfade oder einmalige Ergebnisse

            ## Standardregeln für die Zusammenarbeit

            - Änderungen möglichst klein und fokussiert halten.
            - Unnötige Refactorings vermeiden.
            - Bei Änderungen an mehreren Dateien Struktur und Stil konsistent halten.

            ## Projektregeln

            - Schreiben Sie hier den langfristigen Tech-Stack, Verzeichnis-Konventionen, Build-Befehle und Ausgabeerwartungen des Projekts hinein.

            ## Besondere Hinweise

            - Tragen Sie hier workspace-spezifische Grenzen, Einschränkungen, Tool-Präferenzen oder Liefererwartungen ein.
            """
        case .fr:
            return """
            # SKYAGENT

            Ce fichier conserve les règles de collaboration durables pour l'espace de travail actuel. SkyAgent les privilégie dans les nouvelles conversations.
            Écrivez uniquement les conventions qui doivent rester vraies pour ce projet dans la durée. N'y mettez pas de tâches ponctuelles.

            ## Espace de travail

            - Chemin : \(workspacePath)

            ## Contenu adapté à ce fichier

            - Stack technique et conventions de répertoires
            - Commandes par défaut de build / run / validation
            - Formats de sortie, stratégie de fichiers et habitudes de collaboration durables pour ce projet
            - Limites et contraintes à respecter dans la durée

            ## À ne pas mettre ici

            - Les tâches temporaires de cette session
            - Les demandes de courte durée propres à une seule conversation
            - Les noms de fichiers temporaires, chemins ponctuels ou résultats ponctuels

            ## Règles de collaboration par défaut

            - Garder les changements aussi petits et ciblés que possible.
            - Éviter les refactorings sans lien avec la demande.
            - Conserver une structure et un style cohérents lorsque plusieurs fichiers sont modifiés.

            ## Règles du projet

            - Écrivez ici la stack durable du projet, les conventions de répertoires, les commandes de build et les attentes de sortie.

            ## Notes spéciales

            - Écrivez ici les limites, restrictions, préférences d'outils ou attentes de livraison propres à cet espace de travail.
            """
        }
    }

    private static func isWorkspaceTemplateContent(_ content: String, workspacePath: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppContentLanguage.allCases.contains {
            trimmed == workspaceMemoryTemplate(for: workspacePath, language: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func makeSection(_ title: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        return ["## \(title)", ""] + items.map { "- \($0)" } + [""]
    }

    private static func workspaceMemoryContextWrapper(content: String, language: AppContentLanguage) -> String {
        switch language {
        case .zhHans:
            return """
            [当前工作区记忆]
            以下内容来自当前工作区的长期协作规则摘要。
            它优先于全局偏好，但低于当前用户的明确要求与当前会话上下文。
            只在确实相关时自然利用。

            \(content)
            [工作区记忆结束]
            """
        case .zhHant:
            return """
            [目前工作區記憶]
            以下內容來自目前工作區的長期協作規則摘要。
            它優先於全域偏好，但低於目前使用者的明確要求與目前會話上下文。
            只在確實相關時自然利用。

            \(content)
            [工作區記憶結束]
            """
        case .en:
            return """
            [Current Workspace Memory]
            The content below is a summary of long-term collaboration rules for the current workspace.
            It has higher priority than global preferences, but lower priority than explicit user instructions and the current session context.
            Use it naturally only when it is relevant.

            \(content)
            [End Workspace Memory]
            """
        case .ja:
            return """
            [現在のワークスペースメモリ]
            以下は現在のワークスペースにおける長期的な協業ルールの要約です。
            グローバル設定より優先されますが、明示的なユーザー指示と現在の会話コンテキストよりは低い優先度です。
            関連がある場合にのみ自然に利用してください。

            \(content)
            [ワークスペースメモリ終了]
            """
        case .ko:
            return """
            [현재 워크스페이스 메모리]
            아래 내용은 현재 워크스페이스의 장기 협업 규칙 요약입니다.
            전역 선호보다 우선하지만, 명시적인 사용자 요구와 현재 세션 컨텍스트보다는 우선순위가 낮습니다.
            실제로 관련이 있을 때만 자연스럽게 활용하세요.

            \(content)
            [워크스페이스 메모리 끝]
            """
        case .de:
            return """
            [Aktueller Workspace-Speicher]
            Der folgende Inhalt ist eine Zusammenfassung langfristiger Zusammenarbeitsregeln für den aktuellen Workspace.
            Er hat Vorrang vor globalen Präferenzen, aber niedrigeren Vorrang als explizite Benutzeranweisungen und der aktuelle Sitzungs-Kontext.
            Nutzen Sie ihn nur dann natürlich, wenn er tatsächlich relevant ist.

            \(content)
            [Ende Workspace-Speicher]
            """
        case .fr:
            return """
            [Mémoire de l'espace de travail actuel]
            Le contenu ci-dessous résume les règles de collaboration durables de l'espace de travail actuel.
            Il a priorité sur les préférences globales, mais reste moins prioritaire que les consignes explicites de l'utilisateur et le contexte de session actuel.
            N'utilisez ces informations que lorsqu'elles sont réellement pertinentes.

            \(content)
            [Fin de la mémoire de l'espace de travail]
            """
        }
    }

    private static func workspaceProfileContextWrapper(content: String, language: AppContentLanguage) -> String {
        switch language {
        case .zhHans:
            return """
            [当前工作区画像]
            以下内容来自系统自动生成的项目结构摘要。
            仅用于帮助理解当前项目结构与约束，不替代真实文件内容。

            \(content)
            [工作区画像结束]
            """
        case .zhHant:
            return """
            [目前工作區畫像]
            以下內容來自系統自動生成的專案結構摘要。
            僅用於幫助理解目前專案結構與約束，不替代真實檔案內容。

            \(content)
            [工作區畫像結束]
            """
        case .en:
            return """
            [Current Workspace Profile]
            The content below is an automatically generated summary of the project structure.
            It only helps with understanding the current project layout and constraints, and does not replace real file contents.

            \(content)
            [End Workspace Profile]
            """
        case .ja:
            return """
            [現在のワークスペースプロファイル]
            以下はシステムが自動生成したプロジェクト構造の要約です。
            現在のプロジェクト構成と制約を理解する補助にのみ使い、実際のファイル内容の代わりにはしません。

            \(content)
            [ワークスペースプロファイル終了]
            """
        case .ko:
            return """
            [현재 워크스페이스 프로필]
            아래 내용은 시스템이 자동 생성한 프로젝트 구조 요약입니다.
            현재 프로젝트 구조와 제약을 이해하는 데만 사용되며, 실제 파일 내용을 대체하지 않습니다.

            \(content)
            [워크스페이스 프로필 끝]
            """
        case .de:
            return """
            [Aktuelles Workspace-Profil]
            Der folgende Inhalt ist eine automatisch erzeugte Zusammenfassung der Projektstruktur.
            Er dient nur dazu, die aktuelle Projektstruktur und ihre Einschränkungen besser zu verstehen, und ersetzt keine echten Dateiinhalte.

            \(content)
            [Ende Workspace-Profil]
            """
        case .fr:
            return """
            [Profil de l'espace de travail actuel]
            Le contenu ci-dessous est un résumé automatiquement généré de la structure du projet.
            Il sert uniquement à mieux comprendre la structure et les contraintes du projet actuel, sans remplacer le contenu réel des fichiers.

            \(content)
            [Fin du profil de l'espace de travail]
            """
        }
    }
}

private struct WorkspaceScanResult {
    let projectType: String
    let entryFiles: [String]
    let highPriorityDirectories: [String]
    let protectedDirectories: [String]
    let recentFiles: [String]
    let constraints: [String]
    let indexEntries: [WorkspaceFileIndexEntry]
}

private extension WorkspaceMemoryService {
    static let skipDirectoryNames: Set<String> = [
        ".git", ".build", "build", "DerivedData", "node_modules", "Pods",
        ".swiftpm", ".idea", ".vscode", ".deriveddata"
    ]
}

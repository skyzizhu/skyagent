import Foundation
import Combine

final class SkillManager: ObservableObject {
    static let shared = SkillManager()

    @Published private(set) var installedSkills: [AgentSkill] = []
    @Published var lastErrorMessage: String?

    private let fm = FileManager.default
    private let baseDir: URL
    private let appSkillsDir: URL
    private let userStandardDir: URL
    private let registryURL: URL
    private let legacyAppSkillsDir: URL
    private let legacyRegistryURLs: [URL]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseDir = AppStoragePaths.userRoot
        self.appSkillsDir = AppStoragePaths.skillsDir
        self.userStandardDir = home.appendingPathComponent(".agents/skills")
        self.registryURL = AppStoragePaths.skillsRegistryFile
        self.legacyAppSkillsDir = home.appendingPathComponent(".openclaw/workspace-coding/MiniAgent/data/skills")
        self.legacyRegistryURLs = [
            AppStoragePaths.userRoot.appendingPathComponent("skills-registry.json", isDirectory: false),
            AppStoragePaths.skillsDir.appendingPathComponent("registry.json", isDirectory: false)
        ]
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appSkillsDir, withIntermediateDirectories: true)
        migrateLegacySkillsIfNeeded()
        migrateRegistryIfNeeded()
        reloadSkills()
    }

    init(
        baseDir: URL,
        userStandardDir: URL,
        legacyAppSkillsDir: URL
    ) {
        self.baseDir = baseDir
        self.appSkillsDir = baseDir.appendingPathComponent("skills")
        self.userStandardDir = userStandardDir
        self.registryURL = self.appSkillsDir.appendingPathComponent("skills-registry.json")
        self.legacyAppSkillsDir = legacyAppSkillsDir
        self.legacyRegistryURLs = [
            baseDir.appendingPathComponent("skills-registry.json", isDirectory: false),
            self.appSkillsDir.appendingPathComponent("registry.json", isDirectory: false)
        ]
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appSkillsDir, withIntermediateDirectories: true)
        migrateLegacySkillsIfNeeded()
        migrateRegistryIfNeeded()
        reloadSkills()
    }

    func reloadSkills() {
        var skills: [AgentSkill] = []
        skills.append(contentsOf: scanDirectory(userStandardSkillsURL, sourceType: .userStandard))
        skills.append(contentsOf: scanDirectory(appSkillsDir, sourceType: .appData))
        installedSkills = deduplicatedSkills(skills).sorted(by: sortSkillsForDisplay)
        persistRegistry()
    }

    var availableSkills: [AgentSkill] {
        installedSkills
    }

    func installSkill(from folderURL: URL) throws {
        let standardizedSource = folderURL.resolvingSymlinksInPath().standardizedFileURL
        guard fm.fileExists(atPath: standardizedSource.appendingPathComponent("SKILL.md").path) else {
            throw NSError(domain: "SkillManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "所选目录中没有找到 SKILL.md"])
        }

        let baseName = standardizedSource.lastPathComponent
        var destination = appSkillsDir.appendingPathComponent(baseName)
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = appSkillsDir.appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }

        try fm.copyItem(at: standardizedSource, to: destination)
        reloadSkills()
    }

    func uninstallSkill(_ skill: AgentSkill) throws {
        guard skill.isAppManaged else {
            throw NSError(domain: "SkillManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "当前版本仅支持卸载 ~/.skyagent/skills 目录中的 skill"])
        }
        try fm.removeItem(atPath: skill.skillDirectory)
        reloadSkills()
    }

    func skill(withID id: String) -> AgentSkill? {
        availableSkills.first { $0.id == id }
    }

    func skills(withIDs ids: [String]) -> [AgentSkill] {
        let set = Set(ids)
        return availableSkills.filter { set.contains($0.id) }
    }

    func skill(named requestedName: String, within allowedIDs: [String]? = nil) -> AgentSkill? {
        let normalized = normalizeSkillKey(requestedName)
        guard !normalized.isEmpty else { return nil }

        let pool: [AgentSkill]
        if let allowedIDs {
            pool = skills(withIDs: allowedIDs)
        } else {
            pool = availableSkills
        }

        if let exact = pool.first(where: { skill in
            candidateKeys(for: skill).contains(normalized)
        }) {
            return exact
        }

        let partialMatches = pool.filter { skill in
            candidateKeys(for: skill).contains(where: { key in
                key.contains(normalized) || normalized.contains(key)
            })
        }
        return partialMatches.count == 1 ? partialMatches.first : nil
    }

    func buildCatalogPrompt(for skills: [AgentSkill]) -> String? {
        let orderedSkills = skills.sorted(by: sortSkillsForCatalog)
        let lines = orderedSkills.map { skillCatalogLine(for: $0) }
        let catalogSection = lines.isEmpty ? "- 当前还没有已发现的已安装 skills" : lines.joined(separator: "\n")
        return """
        [Available Agent Skills]
        下面这些 skills 已在当前应用中全局可用。
        遵循类似 Codex 的渐进加载方式使用 skills：
        1. 先只根据下面的 skill 名称和描述做发现，不要预先假设 skill 全文和资源内容。
        2. 如果用户在提示词里直接提到了某个 skill 名称，或需求明显匹配某个 skill 描述，你必须先调用 activate_skill 激活它，再继续处理任务。
        3. skill 激活后，只在真正需要时再调用 read_skill_resource 读取具体 references、templates、assets 或 scripts。
        4. 如果某个已激活 skill 含有 scripts/，可以使用 run_skill_script。skill 脚本走独立的 Skill Runtime，默认允许联网，不受普通 shell 是否开放影响；脚本工作目录默认是当前会话工作目录。
        5. 如果用户明确要求下载、安装新的 skill，请调用 install_skill；新 skill 必须安装到 ~/.skyagent/skills。
        6. 如果用户要求“下载并使用”某个 skill，安装成功后不要停下，必须继续 activate_skill，并继续用这个 skill 完成当前任务。
        7. 运行已激活 skill 的脚本时，优先使用 run_skill_script；不要自己用 shell 去 cd 到 skill 目录再手动 bash/python 执行脚本。
        8. 如果当前请求强匹配某个 skill 的 name、description、trigger hints、default_prompt 等元数据，先 activate_skill，再继续处理任务。
        9. 当 skill 已经能覆盖当前任务时，不要先做与 skill 无关的通用目录探索；只有在用户明确要求本地文件作为依据，或 skill 自己的说明要求读取本地文件时，才去 list_files、read_file。
        选择 skill 时，优先激活描述最具体、触发示例最贴近当前需求、名字最明确匹配用户说法的那一个。
        不要重复激活已经激活过的 skill，也不要在未激活前盲目读取 skill 资源。
        \(catalogSection)
        """
    }

    func likelyTriggeredSkills(in text: String, excluding activeSkillIDs: [String] = []) -> [AgentSkill] {
        likelyTriggeredSkillMatches(in: text, excluding: activeSkillIDs).map(\.skill)
    }

    func likelyTriggeredSkillMatches(in text: String, excluding activeSkillIDs: [String] = []) -> [SkillMatchCandidate] {
        let normalizedMessage = normalizeSkillKey(text)
        guard !normalizedMessage.isEmpty else { return [] }

        let activeSet = Set(activeSkillIDs)
        let scored = availableSkills.compactMap { skill -> SkillMatchCandidate? in
            guard !activeSet.contains(skill.id) else { return nil }

            var bestScore = 0
            var matchedSignals: [SkillMatchSignal] = []
            for signal in explicitMatchSignals(for: skill) {
                let normalizedPhrase = normalizeSkillKey(signal.phrase)
                guard explicitMentionKeyIsUseful(normalizedPhrase),
                      normalizedMessage.contains(normalizedPhrase) else {
                    continue
                }
                bestScore = max(bestScore, 120 + min(normalizedPhrase.count, 24))
                matchedSignals.append(signal)
            }

            if !skill.allowImplicitInvocation && bestScore == 0 {
                return nil
            }

            var metadataScore = 0
            for signal in positiveRoutingSignals(for: skill) {
                let normalizedPhrase = normalizeSkillKey(signal.phrase)
                guard normalizedPhrase.count >= 2 else { continue }
                if normalizedMessage.contains(normalizedPhrase) {
                    metadataScore = max(metadataScore, 80 + min(normalizedPhrase.count, 24))
                    matchedSignals.append(signal)
                }
            }

            var blockedSignals: [SkillMatchSignal] = []
            for signal in negativeRoutingSignals(for: skill) {
                let normalizedPhrase = normalizeSkillKey(signal.phrase)
                guard normalizedPhrase.count >= 2 else { continue }
                if normalizedMessage.contains(normalizedPhrase) {
                    metadataScore -= max(10, min(normalizedPhrase.count, 20))
                    blockedSignals.append(signal)
                }
            }

            bestScore = max(bestScore, metadataScore)

            guard bestScore > 0 else { return nil }
            return SkillMatchCandidate(
                skill: skill,
                score: bestScore,
                matchedSignals: deduplicateSignals(matchedSignals),
                blockedSignals: deduplicateSignals(blockedSignals)
            )
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return sortSkillsForCatalog(lhs.skill, rhs.skill)
            }
    }

    private func deduplicateSignals(_ signals: [SkillMatchSignal]) -> [SkillMatchSignal] {
        var seen: Set<String> = []
        var ordered: [SkillMatchSignal] = []
        for signal in signals {
            let key = "\(signal.source.rawValue)::\(normalizeSkillKey(signal.phrase))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(signal)
        }
        return ordered
    }

    func installSkillFromRemote(
        url: String?,
        repo: String?,
        path: String?,
        ref: String?,
        name: String?
    ) throws -> AgentSkill {
        let request = try resolveRemoteInstallRequest(url: url, repo: repo, path: path, ref: ref, name: name)
        let tempDir = fm.temporaryDirectory.appendingPathComponent("skyagent-skill-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let repoURL = "https://github.com/\(request.repo).git"
        var cloneArgs = ["clone", "--depth", "1"]
        if request.path != nil {
            cloneArgs.append(contentsOf: ["--filter=blob:none", "--sparse"])
        }
        if let ref = request.ref {
            cloneArgs.append(contentsOf: ["--branch", ref])
        }
        cloneArgs.append(contentsOf: [repoURL, tempDir.path])
        try runGit(arguments: cloneArgs)

        if let skillPath = request.path {
            try runGit(arguments: ["-C", tempDir.path, "sparse-checkout", "set", skillPath])
        }

        let sourceDir = try resolveInstalledSkillSourceDir(
            clonedRepoDir: tempDir,
            requestedPath: request.path
        )

        let destinationName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : defaultInstalledDirectoryName(for: request, sourceDir: sourceDir)
        let destination = appSkillsDir.appendingPathComponent(destinationName)
        guard !fm.fileExists(atPath: destination.path) else {
            throw NSError(domain: "SkillManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "目标 skill 已存在：\(destinationName)"])
        }

        try fm.copyItem(at: sourceDir, to: destination)
        reloadSkills()

        guard let installed = installedSkills.first(where: { $0.skillDirectory == destination.standardizedFileURL.path }) else {
            throw NSError(domain: "SkillManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "skill 已复制到 ~/.skyagent/skills，但重新加载后没有找到它"])
        }
        return installed
    }

    func activationMessages(for skillIDs: [String]) -> [String] {
        skills(withIDs: skillIDs).map { activationContext(for: $0) }
    }

    func activateSkill(named requestedName: String) -> SkillActivationResult? {
        let normalized = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        guard let skill = skill(named: requestedName) else {
            return nil
        }

        return SkillActivationResult(
            output: "✅ 已激活 skill：\(skill.name)",
            skillID: skill.id,
            contextMessage: activationContext(for: skill)
        )
    }

    var readableRoots: [String] {
        availableSkills.map(\.skillDirectory)
    }

    private func activationContext(for skill: AgentSkill) -> String {
        let body = (try? String(contentsOfFile: skill.skillFile, encoding: .utf8)) ?? ""
        let strippedBody = stripFrontmatter(from: body).trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryExcerpt = activationExcerpt(from: strippedBody)
        let resourceSection = condensedResourceSummary(for: skill)
        let envSection: String
        if skill.requiredEnvironmentVariables.isEmpty {
            envSection = ""
        } else {
            let envLines = skill.requiredEnvironmentVariables.map { "  <env>\($0)</env>" }.joined(separator: "\n")
            envSection = "\n<skill_required_env_vars>\n\(envLines)\n</skill_required_env_vars>"
        }
        return """
        <skill_content name="\(skill.name)">
        Description: \(skill.description)
        \(skill.aliases.isEmpty ? "" : "Aliases: \(skill.aliases.joined(separator: ", "))")
        \(skill.triggerHints.isEmpty ? "" : "Trigger hints: \(skill.triggerHints.joined(separator: "；"))")

        <skill_summary>
        \(summaryExcerpt)
        </skill_summary>

        Skill directory: \(skill.skillDirectory)
        Relative paths in this skill are relative to the skill directory.
        This skill is already activated for the current conversation.
        If you need the full SKILL.md instructions, call read_skill_resource with this skill name and path "SKILL.md".
        Only inspect referenced files when needed by calling read_skill_resource with this skill name and the exact relative path.
        Scripts in this skill may be executed via run_skill_script.
        When you need to execute one of this skill's scripts, prefer run_skill_script instead of invoking it manually through shell.
        In sandbox mode, local script execution is allowed but network requests are blocked by the system sandbox, and only the current workspace directory is writable. In open mode, scripts may access the network.
        If the skill declares required environment variables, check them before running scripts.
        \(resourceSection)
        \(envSection)
        </skill_content>
        """
    }

    private func activationExcerpt(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No summary available." }

        var lines: [String] = []
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count >= 10 { break }
        }

        let excerpt = lines.joined(separator: "\n")
        if excerpt.count <= 1200 {
            return excerpt
        }
        return String(excerpt.prefix(1200)) + "\n... (已截断，完整说明请读取 SKILL.md)"
    }

    private func condensedResourceSummary(for skill: AgentSkill) -> String {
        let scriptLines = skill.scriptResources.prefix(8).map { "  <script>\($0.relativePath)</script>" }
        let referenceLines = skill.referenceResources.prefix(6).map { "  <reference>\($0.relativePath)</reference>" }
        let templateLines = skill.templateResources.prefix(6).map { "  <template>\($0.relativePath)</template>" }
        let assetCount = skill.assetResources.count

        var sections: [String] = []
        sections.append("<skill_resources_overview>")
        sections.append("  <file>SKILL.md</file>")
        sections.append("  <count total=\"\(skill.resources.count)\" scripts=\"\(skill.scriptResources.count)\" references=\"\(skill.referenceResources.count)\" templates=\"\(skill.templateResources.count)\" assets=\"\(assetCount)\" />")
        sections.append("</skill_resources_overview>")

        if !scriptLines.isEmpty {
            sections.append("<skill_scripts>")
            sections.append(contentsOf: scriptLines)
            if skill.scriptResources.count > scriptLines.count {
                sections.append("  <more>\(skill.scriptResources.count - scriptLines.count) more scripts</more>")
            }
            sections.append("</skill_scripts>")
        }

        if !referenceLines.isEmpty {
            sections.append("<skill_references>")
            sections.append(contentsOf: referenceLines)
            if skill.referenceResources.count > referenceLines.count {
                sections.append("  <more>\(skill.referenceResources.count - referenceLines.count) more references</more>")
            }
            sections.append("</skill_references>")
        }

        if !templateLines.isEmpty {
            sections.append("<skill_templates>")
            sections.append(contentsOf: templateLines)
            if skill.templateResources.count > templateLines.count {
                sections.append("  <more>\(skill.templateResources.count - templateLines.count) more templates</more>")
            }
            sections.append("</skill_templates>")
        }

        if assetCount > 0 {
            sections.append("<skill_assets>")
            sections.append("  <count>\(assetCount)</count>")
            sections.append("</skill_assets>")
        }

        return sections.joined(separator: "\n")
    }

    private var userStandardSkillsURL: URL {
        userStandardDir
    }

    private func migrateLegacySkillsIfNeeded() {
        guard fm.fileExists(atPath: legacyAppSkillsDir.path) else { return }
        let children = (try? fm.contentsOfDirectory(at: legacyAppSkillsDir, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            let destination = appSkillsDir.appendingPathComponent(child.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.copyItem(at: child, to: destination)
        }
    }

    private func migrateRegistryIfNeeded() {
        try? fm.createDirectory(at: appSkillsDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: registryURL.path) {
            for legacyURL in legacyRegistryURLs where fm.fileExists(atPath: legacyURL.path) {
                do {
                    try fm.moveItem(at: legacyURL, to: registryURL)
                    break
                } catch {
                    if let data = try? Data(contentsOf: legacyURL) {
                        try? data.write(to: registryURL, options: [.atomic])
                        try? fm.removeItem(at: legacyURL)
                        break
                    }
                }
            }
        }

        for legacyURL in legacyRegistryURLs where fm.fileExists(atPath: legacyURL.path) {
            guard legacyURL.standardizedFileURL != registryURL.standardizedFileURL else { continue }
            try? fm.removeItem(at: legacyURL)
        }
    }

    func resolveRemoteInstallRequest(url: String?, repo: String?, path: String?, ref: String?, name: String?) throws -> RemoteSkillInstallRequest {
        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try parseGitHubURL(url, overrideName: name)
        }

        guard let repo, !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "SkillManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "install_skill 需要提供 GitHub tree url，或者 repo + path"])
        }
        return RemoteSkillInstallRequest(
            repo: repo.trimmingCharacters(in: .whitespacesAndNewlines),
            path: path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            ref: ref?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "main",
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func parseGitHubURL(_ raw: String, overrideName: String?) throws -> RemoteSkillInstallRequest {
        guard let url = URL(string: raw),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            throw NSError(domain: "SkillManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "当前只支持 GitHub URL"])
        }

        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else {
            throw NSError(domain: "SkillManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "GitHub URL 至少需要包含 owner/repo"])
        }

        let repo = "\(parts[0])/\(parts[1])"
        if parts.count == 2 {
            return RemoteSkillInstallRequest(
                repo: repo,
                path: nil,
                ref: nil,
                name: overrideName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        }

        guard parts.count >= 4, parts[2] == "tree" else {
            throw NSError(domain: "SkillManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "GitHub URL 需要是仓库根路径，或具体的 tree 路径，例如 /owner/repo/tree/main/path/to/skill"])
        }

        let refAndPath = try resolveRefAndPath(
            parts: Array(parts.dropFirst(3)),
            knownRefs: fetchRemoteRefs(for: repo)
        )
        return RemoteSkillInstallRequest(
            repo: repo,
            path: refAndPath.path,
            ref: refAndPath.ref,
            name: overrideName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func runGit(arguments: [String]) throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let message = [error, output].filter { !$0.isEmpty }.joined(separator: "\n")
            throw NSError(domain: "SkillManager", code: 9, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "git 命令执行失败" : message])
        }
    }

    private func scanDirectory(_ root: URL, sourceType: AgentSkillSourceType) -> [AgentSkill] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.compactMap { parseSkill(at: $0, sourceType: sourceType) }
    }

    private func resolveInstalledSkillSourceDir(clonedRepoDir: URL, requestedPath: String?) throws -> URL {
        let explicitSourceDir = requestedPath.map { clonedRepoDir.appendingPathComponent($0) } ?? clonedRepoDir
        if fm.fileExists(atPath: explicitSourceDir.appendingPathComponent("SKILL.md").path) {
            return explicitSourceDir
        }

        guard requestedPath == nil else {
            throw NSError(domain: "SkillManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "下载完成，但在目标目录中没有找到 SKILL.md"])
        }

        let discovered = discoverSkillDirectories(in: clonedRepoDir)
        if discovered.count == 1, let only = discovered.first {
            return only
        }

        if let preferred = discovered.first(where: { $0.lastPathComponent.lowercased() == "skill" }) {
            return preferred
        }

        if discovered.isEmpty {
            throw NSError(domain: "SkillManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "下载完成，但在仓库根目录及常见子目录中都没有找到 SKILL.md"])
        }

        let options = discovered.map(\.path).joined(separator: "\n")
        throw NSError(domain: "SkillManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "下载完成，但发现了多个 skill 目录，请显式提供 path：\n\(options)"])
    }

    private func discoverSkillDirectories(in root: URL) -> [URL] {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var matches: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "SKILL.md" else { continue }
            matches.append(fileURL.deletingLastPathComponent())
        }
        return matches.sorted { $0.path < $1.path }
    }

    private func defaultInstalledDirectoryName(for request: RemoteSkillInstallRequest, sourceDir: URL) -> String {
        if request.path == nil {
            return request.repo.components(separatedBy: "/").last ?? sourceDir.lastPathComponent
        }
        return sourceDir.lastPathComponent
    }

    private func parseSkill(at url: URL, sourceType: AgentSkillSourceType) -> AgentSkill? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let skillFile = url.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: skillFile.path),
              let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }

        let frontmatter = parseFrontmatter(from: content)
        let name = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? frontmatter["name"]!
            : url.lastPathComponent
        let description = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? frontmatter["description"]!
            : "No description"
        let aliases = parseListField(from: frontmatter, keys: ["aliases", "alias", "keywords"])
        let body = stripFrontmatter(from: content)
        let openAIConfig = parseOpenAIConfig(in: url)
        let triggerHints = extractTriggerHints(from: body)
        let antiTriggerHints = extractAntiTriggerHints(from: body)
        let requiredEnvironmentVariables = extractRequiredEnvironmentVariables(from: body)
        let resources = enumerateResources(in: url)

        return AgentSkill(
            id: "skill:\(url.standardizedFileURL.path)",
            name: name,
            description: description,
            displayName: openAIConfig["interface.display_name"]?.nilIfEmpty,
            shortDescription: openAIConfig["interface.short_description"]?.nilIfEmpty,
            defaultPrompt: openAIConfig["interface.default_prompt"]?.nilIfEmpty,
            aliases: aliases,
            triggerHints: triggerHints,
            antiTriggerHints: antiTriggerHints,
            allowImplicitInvocation: parseBool(openAIConfig["policy.allow_implicit_invocation"]) ?? true,
            requiredEnvironmentVariables: requiredEnvironmentVariables,
            scriptTimeoutSeconds: parseScriptTimeoutSeconds(frontmatter: frontmatter, openAIConfig: openAIConfig),
            skillDirectory: url.standardizedFileURL.path,
            skillFile: skillFile.standardizedFileURL.path,
            sourceType: sourceType,
            resources: resources,
            hasScripts: resources.contains { $0.kind == .script },
            hasReferences: resources.contains { $0.kind == .reference },
            hasAssets: resources.contains { $0.kind == .asset }
        )
    }

    private func enumerateResources(in skillRoot: URL) -> [AgentSkillResource] {
        guard let enumerator = fm.enumerator(at: skillRoot, includingPropertiesForKeys: nil) else { return [] }
        var resources: [AgentSkillResource] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent != "SKILL.md" else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: skillRoot.path + "/", with: "")
            let kind: AgentSkillResourceKind
            if relativePath.hasPrefix("scripts/") {
                kind = .script
            } else if relativePath.hasPrefix("references/") {
                kind = .reference
            } else if relativePath.hasPrefix("assets/") {
                kind = .asset
            } else if relativePath.hasPrefix("templates/") {
                kind = .template
            } else {
                kind = .other
            }
            resources.append(AgentSkillResource(relativePath: relativePath, kind: kind))
        }
        return resources.sorted { $0.relativePath < $1.relativePath }
    }

    private func parseFrontmatter(from content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var metadata: [String: String] = [:]
        var currentListKey: String?
        var currentListValues: [String] = []

        func flushCurrentList() {
            guard let key = currentListKey, !currentListValues.isEmpty else { return }
            metadata[key] = currentListValues.joined(separator: ", ")
            currentListKey = nil
            currentListValues = []
        }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                flushCurrentList()
                break
            }

            if let _ = currentListKey {
                if trimmed.hasPrefix("- ") {
                    let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        currentListValues.append(value)
                    }
                    continue
                }

                if trimmed.isEmpty {
                    continue
                }

                flushCurrentList()
            }

            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                currentListKey = key
                currentListValues = []
            } else {
                metadata[key] = value
            }
        }
        return metadata
    }

    private func parseListField(from metadata: [String: String], keys: [String]) -> [String] {
        for key in keys {
            guard let raw = metadata[key], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return raw
                .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" || $0 == "|" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func stripFrontmatter(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }

        var endIndex: Int?
        for (index, line) in lines.enumerated().dropFirst() where line.trimmingCharacters(in: .whitespaces) == "---" {
            endIndex = index
            break
        }

        guard let endIndex else { return content }
        return lines.suffix(from: endIndex + 1).joined(separator: "\n")
    }

    private func extractTriggerHints(from body: String) -> [String] {
        extractSectionBullets(
            from: body,
            headings: Set([
            "## when to use",
            "### when to use",
            "## use cases",
            "### use cases",
            "## trigger",
            "### trigger",
            "## triggers",
            "### triggers",
            "## 使用场景",
            "### 使用场景",
            "## 何时使用",
            "### 何时使用",
            "## 适用场景",
            "### 适用场景"
            ])
        )
    }

    private func extractAntiTriggerHints(from body: String) -> [String] {
        extractSectionBullets(
            from: body,
            headings: Set([
                "## when not to use",
                "### when not to use",
                "## avoid",
                "### avoid",
                "## do not use",
                "### do not use",
                "## 不要使用",
                "### 不要使用",
                "## 何时不要使用",
                "### 何时不要使用",
                "## 不适用场景",
                "### 不适用场景"
            ])
        )
    }

    private func extractSectionBullets(from body: String, headings: Set<String>) -> [String] {
        let lines = body.components(separatedBy: .newlines)
        var collecting = false
        var results: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLine = line.lowercased()

            if headings.contains(normalizedLine) {
                collecting = true
                continue
            }

            if collecting && line.hasPrefix("#") {
                break
            }

            guard collecting else { continue }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    results.append(value)
                }
            }
        }

        return Array(results.prefix(6))
    }

    private func extractRequiredEnvironmentVariables(from body: String) -> [String] {
        enum SectionMode {
            case none
            case genericInputs
            case envSpecific
        }

        let lines = body.components(separatedBy: .newlines)
        let genericInputHeadings = Set([
            "## required inputs",
            "### required inputs",
            "## requirements",
            "### requirements",
            "## 必需输入",
            "### 必需输入",
            "## 前置要求",
            "### 前置要求"
        ])
        let envSpecificHeadings = Set([
            "## environment variables",
            "### environment variables",
            "## required environment variables",
            "### required environment variables",
            "## env vars",
            "### env vars",
            "## 环境变量",
            "### 环境变量"
        ])

        let regex = try? NSRegularExpression(pattern: #"(?:`|^|\s)([A-Z][A-Z0-9_]{2,})(?:`|\b)"#)
        var mode: SectionMode = .none
        var variables: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = line.lowercased()

            if envSpecificHeadings.contains(normalized) {
                mode = .envSpecific
                continue
            }

            if genericInputHeadings.contains(normalized) {
                mode = .genericInputs
                continue
            }

            if line.hasPrefix("#") {
                mode = .none
                continue
            }

            guard mode != .none, let regex else { continue }

            let shouldCollectAllMatches = mode == .envSpecific || lineSuggestsEnvironmentVariable(line)
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for match in matches where match.numberOfRanges > 1 {
                let variable = nsLine.substring(with: match.range(at: 1))
                if shouldCollectAllMatches || looksLikeEnvironmentVariableName(variable) {
                    variables.append(variable)
                }
            }
        }

        return Array(NSOrderedSet(array: variables)) as? [String] ?? []
    }

    private func lineSuggestsEnvironmentVariable(_ line: String) -> Bool {
        let normalized = line.lowercased()
        let hints = [
            "env", "environment", "环境变量", "api key", "apikey", "token", "secret", "密钥", "凭证"
        ]
        return hints.contains { normalized.contains($0) }
    }

    private func looksLikeEnvironmentVariableName(_ name: String) -> Bool {
        let normalized = name.uppercased()
        if normalized.contains("_") {
            return true
        }

        let suffixes = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASS", "COOKIE"]
        return suffixes.contains { normalized.hasSuffix($0) }
    }

    private func normalizeSkillKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("$") {
            value.removeFirst()
        }
        value = value.replacingOccurrences(of: " skill", with: "")
        value = value.replacingOccurrences(of: "技能", with: "")
        let filtered = value.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains(scalar)
        }
        return String(String.UnicodeScalarView(filtered))
    }

    private func candidateKeys(for skill: AgentSkill) -> Set<String> {
        var keys = Set<String>()
        keys.insert(normalizeSkillKey(skill.name))
        if let displayName = skill.displayName {
            keys.insert(normalizeSkillKey(displayName))
        }
        keys.insert(normalizeSkillKey(URL(fileURLWithPath: skill.skillDirectory).lastPathComponent))
        for alias in skill.aliases {
            keys.insert(normalizeSkillKey(alias))
        }
        return keys.filter { !$0.isEmpty }
    }

    private func explicitMatchSignals(for skill: AgentSkill) -> [SkillMatchSignal] {
        var signals: [SkillMatchSignal] = [
            SkillMatchSignal(source: .name, phrase: skill.name)
        ]
        if let displayName = skill.displayName, !displayName.isEmpty {
            signals.append(SkillMatchSignal(source: .displayName, phrase: displayName))
        }
        signals.append(contentsOf: skill.aliases.map { SkillMatchSignal(source: .alias, phrase: $0) })
        return signals
    }

    private func explicitMentionKeyIsUseful(_ key: String) -> Bool {
        let containsChinese = key.unicodeScalars.contains {
            CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains($0)
        }
        return containsChinese ? key.count >= 2 : key.count >= 4
    }

    private func positiveRoutingSignals(for skill: AgentSkill) -> [SkillMatchSignal] {
        var candidates: [SkillMatchSignal] = [
            SkillMatchSignal(source: .name, phrase: skill.name)
        ]
        if let displayName = skill.displayName {
            candidates.append(SkillMatchSignal(source: .displayName, phrase: displayName))
        }
        if let shortDescription = skill.shortDescription {
            candidates.append(SkillMatchSignal(source: .shortDescription, phrase: shortDescription))
        }
        if let defaultPrompt = skill.defaultPrompt {
            candidates.append(SkillMatchSignal(source: .defaultPrompt, phrase: defaultPrompt))
        }
        candidates.append(contentsOf: skill.aliases.map { SkillMatchSignal(source: .alias, phrase: $0) })
        candidates.append(contentsOf: extractQuotedPhrases(from: skill.description).map { SkillMatchSignal(source: .description, phrase: $0) })
        candidates.append(contentsOf: extractQuotedPhrases(from: skill.shortDescription ?? "").map { SkillMatchSignal(source: .shortDescription, phrase: $0) })
        candidates.append(contentsOf: extractQuotedPhrases(from: skill.defaultPrompt ?? "").map { SkillMatchSignal(source: .defaultPrompt, phrase: $0) })

        for hint in skill.triggerHints {
            candidates.append(SkillMatchSignal(source: .triggerHint, phrase: hint))
            candidates.append(contentsOf: extractQuotedPhrases(from: hint).map { SkillMatchSignal(source: .triggerHint, phrase: $0) })
            candidates.append(contentsOf: splitTriggerHintFragments(from: hint).map { SkillMatchSignal(source: .triggerHint, phrase: $0) })
        }

        candidates.append(contentsOf: splitTriggerHintFragments(from: skill.description).map { SkillMatchSignal(source: .description, phrase: $0) })
        candidates.append(contentsOf: splitTriggerHintFragments(from: skill.shortDescription ?? "").map { SkillMatchSignal(source: .shortDescription, phrase: $0) })
        candidates.append(contentsOf: splitTriggerHintFragments(from: skill.defaultPrompt ?? "").map { SkillMatchSignal(source: .defaultPrompt, phrase: $0) })
        return deduplicateSignals(
            candidates.map {
                SkillMatchSignal(
                    source: $0.source,
                    phrase: $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }.filter { !$0.phrase.isEmpty }
        )
    }

    private func negativeRoutingSignals(for skill: AgentSkill) -> [SkillMatchSignal] {
        var candidates: [SkillMatchSignal] = []
        for hint in skill.antiTriggerHints {
            candidates.append(SkillMatchSignal(source: .antiTriggerHint, phrase: hint))
            candidates.append(contentsOf: extractQuotedPhrases(from: hint).map { SkillMatchSignal(source: .antiTriggerHint, phrase: $0) })
            candidates.append(contentsOf: splitTriggerHintFragments(from: hint).map { SkillMatchSignal(source: .antiTriggerHint, phrase: $0) })
        }
        return deduplicateSignals(
            candidates.map {
                SkillMatchSignal(
                    source: $0.source,
                    phrase: $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }.filter { !$0.phrase.isEmpty }
        )
    }

    private func extractQuotedPhrases(from text: String) -> [String] {
        let pattern = #"[\"“”'‘’](.*?)[\"“”'‘’]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let value = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private func splitTriggerHintFragments(from text: String) -> [String] {
        var cleaned = text
        let wrappers = [
            "当用户说", "用户说", "用户提到", "用户要求", "用户希望", "当用户", "如果用户",
            "时使用", "时触发", "时调用", "请使用", "适用于", "适合", "用于",
            "when the user", "when user", "use when", "trigger when", "should be used when"
        ]
        for wrapper in wrappers {
            cleaned = cleaned.replacingOccurrences(of: wrapper, with: " ", options: .caseInsensitive)
        }

        let separators = CharacterSet(charactersIn: ",，;；/、|()（）[]【】")
        var fragments = cleaned.components(separatedBy: separators)
        fragments = fragments.flatMap { fragment in
            fragment
                .replacingOccurrences(of: "或者", with: "|")
                .replacingOccurrences(of: "或", with: "|")
                .replacingOccurrences(of: " and ", with: "|", options: .caseInsensitive)
                .replacingOccurrences(of: " or ", with: "|", options: .caseInsensitive)
                .components(separatedBy: "|")
        }

        return fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private func parseOpenAIConfig(in skillRoot: URL) -> [String: String] {
        let candidates = [
            skillRoot.appendingPathComponent("agents/openai.yaml"),
            skillRoot.appendingPathComponent("openai.yaml")
        ]

        for url in candidates {
            guard fm.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            return parseSimpleYAML(content)
        }

        return [:]
    }

    private func parseSimpleYAML(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        var values: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []

        for rawLine in lines {
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") { continue }

            let indent = rawLine.prefix { $0 == " " }.count
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            while let last = stack.last, indent <= last.indent {
                stack.removeLast()
            }

            if value.isEmpty {
                stack.append((indent: indent, key: key))
                continue
            }

            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }

            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            values[path] = value
        }

        return values
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch normalized {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    private func parseScriptTimeoutSeconds(frontmatter: [String: String], openAIConfig: [String: String]) -> Int? {
        let candidates: [String?] = [
            frontmatter["script_timeout_seconds"],
            frontmatter["skill_timeout_seconds"],
            frontmatter["timeout_seconds"],
            openAIConfig["execution.script_timeout_seconds"],
            openAIConfig["runtime.script_timeout_seconds"],
            openAIConfig["runtime.timeout_seconds"]
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if let parsed = parsePositiveInteger(candidate) {
                return min(max(parsed, 1), 300)
            }
        }
        return nil
    }

    private func parsePositiveInteger(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let integer = Int(trimmed), integer > 0 else { return nil }
        return integer
    }

    private func skillCatalogLine(for skill: AgentSkill) -> String {
        var segments: [String] = []
        if !skill.aliases.isEmpty {
            segments.append("别名：\(skill.aliases.joined(separator: " / "))")
        }
        if !skill.triggerHints.isEmpty {
            segments.append("触发示例：\(skill.triggerHints.joined(separator: "；"))")
        }
        if let shortDescription = skill.shortDescription, !shortDescription.isEmpty {
            segments.append("补充说明：\(shortDescription)")
        }
        let suffix = segments.isEmpty ? "" : " [" + segments.joined(separator: " | ") + "]"
        return "- \(skill.name): \(skill.description)\(suffix)"
    }

    func resolveRefAndPath(parts: [String], knownRefs: [String]) throws -> (ref: String, path: String?) {
        guard !parts.isEmpty else {
            throw NSError(domain: "SkillManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "GitHub tree URL 缺少 ref 信息"])
        }

        if let matchedRef = knownRefs
            .sorted(by: { $0.count > $1.count })
            .first(where: { ref in
                let joined = parts.joined(separator: "/")
                return joined == ref || joined.hasPrefix(ref + "/")
            }) {
            let joined = parts.joined(separator: "/")
            let remainder = joined == matchedRef
                ? nil
                : String(joined.dropFirst(matchedRef.count + 1)).nilIfEmpty
            return (matchedRef, remainder)
        }

        return splitRefAndPath(parts)
    }

    private func splitRefAndPath(_ parts: [String]) -> (ref: String, path: String?) {
        guard !parts.isEmpty else { return ("main", nil) }
        if parts.count == 1 {
            return (parts[0], nil)
        }

        for index in stride(from: parts.count - 1, through: 1, by: -1) {
            let refCandidate = parts.prefix(index).joined(separator: "/")
            let remainingPath = parts.dropFirst(index).joined(separator: "/").nilIfEmpty
            if refLooksValid(refCandidate) {
                return (refCandidate, remainingPath)
            }
        }

        return (parts[0], parts.dropFirst().joined(separator: "/").nilIfEmpty)
    }

    private func refLooksValid(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.hasPrefix("/") && !ref.hasSuffix("/")
    }

    private func fetchRemoteRefs(for repo: String) -> [String] {
        let repoURL = "https://github.com/\(repo).git"
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-remote", "--heads", "--tags", repoURL]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output
                .components(separatedBy: .newlines)
                .compactMap { line in
                    guard let refRange = line.range(of: "refs/") else { return nil }
                    let ref = String(line[refRange.lowerBound...])
                    if ref.hasPrefix("refs/heads/") {
                        return String(ref.dropFirst("refs/heads/".count))
                    }
                    if ref.hasPrefix("refs/tags/") {
                        return String(ref.dropFirst("refs/tags/".count))
                    }
                    return nil
                }
        } catch {
            let _ = stderr.fileHandleForReading.readDataToEndOfFile()
            return []
        }
    }

    private func deduplicatedSkills(_ skills: [AgentSkill]) -> [AgentSkill] {
        var bestByIdentity: [String: AgentSkill] = [:]
        for skill in skills {
            let identity = duplicateIdentity(for: skill)
            guard let existing = bestByIdentity[identity] else {
                bestByIdentity[identity] = skill
                continue
            }
            if shouldPrefer(skill, over: existing) {
                bestByIdentity[identity] = skill
            }
        }
        return Array(bestByIdentity.values)
    }

    private func duplicateIdentity(for skill: AgentSkill) -> String {
        let normalizedName = normalizeSkillKey(skill.name)
        let normalizedDirectory = normalizeSkillKey(URL(fileURLWithPath: skill.skillDirectory).lastPathComponent)
        return [normalizedName, normalizedDirectory].joined(separator: "::")
    }

    private func shouldPrefer(_ lhs: AgentSkill, over rhs: AgentSkill) -> Bool {
        if sourcePreferenceScore(lhs.sourceType) != sourcePreferenceScore(rhs.sourceType) {
            return sourcePreferenceScore(lhs.sourceType) > sourcePreferenceScore(rhs.sourceType)
        }
        if metadataCompletenessScore(lhs) != metadataCompletenessScore(rhs) {
            return metadataCompletenessScore(lhs) > metadataCompletenessScore(rhs)
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func sortSkillsForDisplay(_ lhs: AgentSkill, _ rhs: AgentSkill) -> Bool {
        if sourcePreferenceScore(lhs.sourceType) != sourcePreferenceScore(rhs.sourceType) {
            return sourcePreferenceScore(lhs.sourceType) > sourcePreferenceScore(rhs.sourceType)
        }
        if metadataCompletenessScore(lhs) != metadataCompletenessScore(rhs) {
            return metadataCompletenessScore(lhs) > metadataCompletenessScore(rhs)
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func sortSkillsForCatalog(_ lhs: AgentSkill, _ rhs: AgentSkill) -> Bool {
        if catalogPriorityScore(lhs) != catalogPriorityScore(rhs) {
            return catalogPriorityScore(lhs) > catalogPriorityScore(rhs)
        }
        return sortSkillsForDisplay(lhs, rhs)
    }

    private func sourcePreferenceScore(_ sourceType: AgentSkillSourceType) -> Int {
        switch sourceType {
        case .appData:
            return 2
        case .userStandard:
            return 1
        }
    }

    private func metadataCompletenessScore(_ skill: AgentSkill) -> Int {
        var score = 0
        score += min(skill.aliases.count, 5) * 3
        score += min(skill.triggerHints.count, 5) * 4
        if skill.hasReferences { score += 2 }
        if skill.hasScripts { score += 1 }
        if skill.hasAssets { score += 1 }
        score += min(skill.description.count / 80, 3)
        return score
    }

    private func catalogPriorityScore(_ skill: AgentSkill) -> Int {
        metadataCompletenessScore(skill) + sourcePreferenceScore(skill.sourceType) * 2
    }

    private func persistRegistry() {
        if let data = try? JSONEncoder().encode(installedSkills) {
            try? data.write(to: registryURL, options: [.atomic])
        }
    }
}

struct RemoteSkillInstallRequest {
    let repo: String
    let path: String?
    let ref: String?
    let name: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

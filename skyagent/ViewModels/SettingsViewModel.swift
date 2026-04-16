import SwiftUI
import Combine

@MainActor
class SettingsViewModel: ObservableObject {
    let store: ConversationStore
    let llm: LLMService
    let skillManager: SkillManager
    let mcpManager: MCPServerManager

    @Published var draftURL: String
    @Published var draftKey: String
    @Published var draftModel: String
    @Published var draftSystemPrompt: String
    @Published var draftMaxTokens: Double
    @Published var draftTemperature: Double
    @Published var draftSandboxDir: String
    @Published var draftThemePreference: AppThemePreference
    @Published var draftLanguagePreference: AppLanguagePreference
    @Published var draftRequireCommandReturnToSend: Bool
    @Published var draftProfiles: [APIProfile]
    @Published var selectedProfileId: UUID?
    @Published private(set) var logEntries: [PersistedLogEvent] = []
    @Published private(set) var logFiles: [URL] = []
    @Published private(set) var isLoadingLogs = false
    @Published private(set) var logsErrorMessage: String?
    @Published private(set) var logsStatusMessage: String?
    @Published private(set) var currentKnowledgeLibrary: KnowledgeLibrary?
    @Published private(set) var knowledgeLibraryCount = 0
    @Published private(set) var knowledgeImportStatusMessage: String?
    @Published private(set) var isKnowledgeImportRunning = false

    private var cancellables = Set<AnyCancellable>()
    private var knowledgeLibraryRefreshToken = UUID()

    init(store: ConversationStore, llm: LLMService, skillManager: SkillManager, mcpManager: MCPServerManager) {
        self.store = store
        self.llm = llm
        self.skillManager = skillManager
        self.mcpManager = mcpManager
        let s = store.settings
        self.draftURL = s.apiURL
        self.draftKey = s.apiKey
        self.draftModel = s.model
        self.draftSystemPrompt = s.systemPrompt
        self.draftMaxTokens = Double(s.maxTokens)
        self.draftTemperature = s.temperature
        self.draftSandboxDir = s.sandboxDir
        self.draftThemePreference = s.themePreference
        self.draftLanguagePreference = s.languagePreference
        self.draftRequireCommandReturnToSend = s.requireCommandReturnToSend
        self.draftProfiles = s.profiles
        self.selectedProfileId = s.activeProfileId ?? s.profiles.first?.id
        refreshLogs()
        refreshKnowledgeLibrary()
        observeStoreChanges()
    }

    var settings: AppSettings { store.settings }

    func save() {
        var profiles = draftProfiles
        var activeProfileId = selectedProfileId
        if let selectedProfileId,
           let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileId }) {
            profiles[profileIndex].apiURL = draftURL
            profiles[profileIndex].apiKey = draftKey
            profiles[profileIndex].model = draftModel
        } else if activeProfileId == nil {
            activeProfileId = profiles.first?.id
        }

        let newSettings = AppSettings(
            apiURL: draftURL,
            apiKey: draftKey,
            model: draftModel,
            systemPrompt: draftSystemPrompt,
            maxTokens: Int(draftMaxTokens),
            temperature: draftTemperature,
            sandboxDir: draftSandboxDir.isEmpty ? "" : draftSandboxDir,
            themePreference: draftThemePreference,
            languagePreference: draftLanguagePreference,
            requireCommandReturnToSend: draftRequireCommandReturnToSend,
            profiles: profiles,
            activeProfileId: activeProfileId
        )
        store.settings = newSettings
        newSettings.save()
        syncDraft(from: newSettings)
        Task {
            await llm.updateSettings(newSettings)
            await mcpManager.refreshTools()
        }
    }

    func saveSettings(_ s: AppSettings) {
        store.settings = s
        s.save()
        syncDraft(from: s)
        Task {
            await llm.updateSettings(s)
            await mcpManager.refreshTools()
        }
    }

    // MARK: - Profile 管理

    var profiles: [APIProfile] { draftProfiles }
    var activeProfileId: UUID? { store.settings.activeProfileId ?? store.settings.profiles.first?.id }
    var selectedProfile: APIProfile? {
        guard let selectedProfileId else { return nil }
        return draftProfiles.first(where: { $0.id == selectedProfileId })
    }
    var activeProfile: APIProfile? {
        guard let activeProfileId else { return nil }
        return store.settings.profiles.first(where: { $0.id == activeProfileId })
    }
    var hasPendingProfileSelection: Bool {
        selectedProfileId != activeProfileId
    }

    func selectProfile(_ profile: APIProfile) {
        draftURL = profile.apiURL
        draftKey = profile.apiKey
        draftModel = profile.model
        selectedProfileId = profile.id
    }

    func isActiveProfile(_ profile: APIProfile) -> Bool {
        activeProfileId == profile.id
    }

    func isSelectedProfile(_ profile: APIProfile) -> Bool {
        selectedProfileId == profile.id
    }

    func saveCurrentAsProfile(name: String) {
        let profile = APIProfile(name: name, apiURL: draftURL, apiKey: draftKey, model: draftModel)
        draftProfiles.append(profile)
        selectedProfileId = profile.id
    }

    func deleteProfile(_ profile: APIProfile) {
        draftProfiles.removeAll { $0.id == profile.id }
        if selectedProfileId == profile.id {
            selectedProfileId = draftProfiles.first?.id
            if let next = draftProfiles.first {
                selectProfile(next)
            }
        }
    }

    func updateProfileKey(_ profile: APIProfile, key: String) {
        guard let idx = draftProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        draftProfiles[idx].apiKey = key
    }

    func resetDraft() {
        syncDraft(from: store.settings)
    }

    private func syncDraft(from s: AppSettings) {
        draftURL = s.apiURL
        draftKey = s.apiKey
        draftModel = s.model
        draftSystemPrompt = s.systemPrompt
        draftMaxTokens = Double(s.maxTokens)
        draftTemperature = s.temperature
        draftSandboxDir = s.sandboxDir
        draftThemePreference = s.themePreference
        draftLanguagePreference = s.languagePreference
        draftRequireCommandReturnToSend = s.requireCommandReturnToSend
        draftProfiles = s.profiles
        selectedProfileId = s.activeProfileId ?? s.profiles.first?.id
    }

    var installedSkills: [AgentSkill] { skillManager.installedSkills }

    var groupedAvailableSkills: [(source: AgentSkillSourceType, skills: [AgentSkill])] {
        let available = skillManager.availableSkills
        let groups = Dictionary(grouping: available, by: \.sourceType)
        return groups.keys.sorted { $0.sortOrder < $1.sortOrder }.map { key in
            (source: key, skills: groups[key]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    func reloadSkills() {
        skillManager.reloadSkills()
    }

    func installSkill(from folderURL: URL) {
        do {
            try skillManager.installSkill(from: folderURL)
        } catch {
            skillManager.lastErrorMessage = error.localizedDescription
        }
    }

    func uninstallSkill(_ skill: AgentSkill) {
        do {
            try skillManager.uninstallSkill(skill)
        } catch {
            skillManager.lastErrorMessage = error.localizedDescription
        }
    }

    var mcpServers: [MCPServerConfig] { mcpManager.servers }

    var globalMemoryFileURL: URL { AppStoragePaths.globalMemoryFile }

    var generatedGlobalMemoryFileURL: URL { AppStoragePaths.generatedMemoryFile }

    var globalMemoryIndexFileURL: URL { AppStoragePaths.memoryIndexFile }

    var currentWorkspacePath: String {
        let conversationWorkspace = store.currentConversation?.sandboxDir.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let draftWorkspace = draftSandboxDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !conversationWorkspace.isEmpty {
            return conversationWorkspace
        }
        if !draftWorkspace.isEmpty {
            return draftWorkspace
        }
        return store.settings.ensureSandboxDir()
    }

    var knowledgeLibrariesFileURL: URL { AppStoragePaths.knowledgeLibrariesFile }

    var knowledgeImportsFileURL: URL { AppStoragePaths.knowledgeImportsFile }

    var currentKnowledgeLibraryFolderURL: URL? {
        guard let library = currentKnowledgeLibrary else { return nil }
        return AppStoragePaths.knowledgeLibrariesRootDir.appendingPathComponent(library.id.uuidString, isDirectory: true)
    }

    var allKnowledgeLibraries: [KnowledgeLibrary] {
        KnowledgeBaseService.shared.listLibraries()
            .sorted { lhs, rhs in
                if lhs.sourceRoot != nil && rhs.sourceRoot == nil { return true }
                if lhs.sourceRoot == nil && rhs.sourceRoot != nil { return false }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var currentWorkspaceMemoryFileURL: URL {
        URL(fileURLWithPath: WorkspaceMemoryService.shared.workspaceMemoryFilePath(for: currentWorkspacePath))
    }

    func importCurrentWorkspaceLibrary() async {
        guard let library = currentKnowledgeLibrary else { return }
        let sourceRoot = library.sourceRoot ?? currentWorkspacePath
        guard !sourceRoot.isEmpty else { return }
        isKnowledgeImportRunning = true
        knowledgeImportStatusMessage = nil
        let job = await KnowledgeBaseService.shared.enqueueAndRunImport(
            libraryId: library.id,
            sourceType: .folder,
            source: sourceRoot,
            title: URL(fileURLWithPath: sourceRoot, isDirectory: true).lastPathComponent
        )
        isKnowledgeImportRunning = false
        applyKnowledgeImportStatus(job)
    }

    func importKnowledgeFile(_ url: URL) async {
        guard let library = currentKnowledgeLibrary else { return }
        isKnowledgeImportRunning = true
        knowledgeImportStatusMessage = nil
        let job = await KnowledgeBaseService.shared.enqueueAndRunImport(
            libraryId: library.id,
            sourceType: .file,
            source: url.path,
            title: url.lastPathComponent
        )
        isKnowledgeImportRunning = false
        applyKnowledgeImportStatus(job)
    }

    func importKnowledgeFolder(_ url: URL) async {
        guard let library = currentKnowledgeLibrary else { return }
        isKnowledgeImportRunning = true
        knowledgeImportStatusMessage = nil
        let job = await KnowledgeBaseService.shared.enqueueAndRunImport(
            libraryId: library.id,
            sourceType: .folder,
            source: url.path,
            title: url.lastPathComponent
        )
        isKnowledgeImportRunning = false
        applyKnowledgeImportStatus(job)
    }

    func importKnowledgeWeb(_ urlString: String) async {
        guard let library = currentKnowledgeLibrary else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isKnowledgeImportRunning = true
        knowledgeImportStatusMessage = nil
        let job = await KnowledgeBaseService.shared.enqueueAndRunImport(
            libraryId: library.id,
            sourceType: .web,
            source: trimmed,
            title: trimmed
        )
        isKnowledgeImportRunning = false
        applyKnowledgeImportStatus(job)
    }

    private func applyKnowledgeImportStatus(_ job: KnowledgeImportJob) {
        switch job.status {
        case .succeeded:
            knowledgeImportStatusMessage = L10n.tr("settings.knowledge.import_done")
        case .failed:
            knowledgeImportStatusMessage = L10n.tr("settings.knowledge.import_failed", job.errorMessage ?? "")
        default:
            knowledgeImportStatusMessage = L10n.tr("settings.knowledge.import_pending")
        }
    }

    private func observeStoreChanges() {
        store.$currentConversationId
            .sink { [weak self] _ in
                self?.refreshKnowledgeLibrary()
            }
            .store(in: &cancellables)

        store.$conversations
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshKnowledgeLibrary()
            }
            .store(in: &cancellables)

        store.$settings
            .sink { [weak self] _ in
                self?.refreshKnowledgeLibrary()
            }
            .store(in: &cancellables)
    }

    private func refreshKnowledgeLibrary() {
        let workspacePath = AppStoragePaths.normalizeSandboxPath(currentWorkspacePath)
        guard !workspacePath.isEmpty else {
            currentKnowledgeLibrary = nil
            knowledgeLibraryCount = 0
            return
        }

        let refreshToken = UUID()
        knowledgeLibraryRefreshToken = refreshToken

        DispatchQueue.global(qos: .utility).async {
            let service = KnowledgeBaseService.shared
            var libraries = service.listLibraries()
            let library = libraries.first {
                guard let sourceRoot = $0.sourceRoot else { return false }
                return AppStoragePaths.normalizeSandboxPath(sourceRoot) == workspacePath
            } ?? service.ensureLibraryForWorkspace(rootPath: workspacePath)

            if !libraries.contains(where: { $0.id == library.id }) {
                libraries = service.listLibraries()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.knowledgeLibraryRefreshToken == refreshToken else { return }
                guard AppStoragePaths.normalizeSandboxPath(self.currentWorkspacePath) == workspacePath else { return }
                self.currentKnowledgeLibrary = library
                self.knowledgeLibraryCount = libraries.count
            }
        }
    }

    var currentWorkspaceProfileFileURL: URL {
        URL(fileURLWithPath: WorkspaceMemoryService.shared.workspaceProfileFilePath(for: currentWorkspacePath))
    }

    var currentWorkspaceFileIndexURL: URL {
        URL(fileURLWithPath: WorkspaceMemoryService.shared.workspaceFileIndexPath(for: currentWorkspacePath))
    }

    var mcpUserConfigURL: URL { mcpManager.userConfigURL }

    var mcpProjectConfigURL: URL? { mcpManager.projectConfigURL }

    func mcpState(for serverID: UUID) -> MCPServerRuntimeState {
        mcpManager.state(for: serverID)
    }

    func mcpTools(for serverID: UUID) -> [MCPToolDescriptor] {
        mcpManager.tools(for: serverID)
    }

    func mcpResources(for serverID: UUID) -> [MCPResourceDescriptor] {
        mcpManager.resources(for: serverID)
    }

    func mcpPrompts(for serverID: UUID) -> [MCPPromptDescriptor] {
        mcpManager.prompts(for: serverID)
    }

    func mcpLogs(for serverID: UUID) -> [MCPActivityLog] {
        mcpManager.logs(for: serverID)
    }

    func editableMCPServer(_ serverID: UUID) -> MCPServerConfig? {
        mcpManager.editableServerConfig(for: serverID)
    }

    func refreshMCPTools() {
        Task {
            await mcpManager.refreshTools()
        }
    }

    func addMCPServer(
        name: String,
        transportKind: MCPTransportKind,
        command: String,
        argumentsText: String,
        environmentText: String,
        workingDirectory: String,
        endpointURL: String,
        authKind: MCPAuthorizationKind,
        authToken: String,
        authHeaderName: String,
        additionalHeadersText: String,
        toolExecutionPolicy: MCPToolExecutionPolicy,
        allowedToolsText: String,
        blockedToolsText: String
    ) {
        let arguments = lineValues(from: argumentsText)
        let environment = keyValuePairs(from: environmentText)
        let additionalHeaders = keyValuePairs(from: additionalHeadersText)
        let allowedToolNames = lineValues(from: allowedToolsText)
        let blockedToolNames = lineValues(from: blockedToolsText)

        Task {
            await mcpManager.addServer(
                name: name,
                transportKind: transportKind,
                command: command,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                endpointURL: endpointURL,
                authKind: authKind,
                authToken: authToken,
                authHeaderName: authHeaderName,
                additionalHeaders: additionalHeaders,
                toolExecutionPolicy: toolExecutionPolicy,
                allowedToolNames: allowedToolNames,
                blockedToolNames: blockedToolNames
            )
        }
    }

    func updateMCPServer(
        serverID: UUID,
        name: String,
        transportKind: MCPTransportKind,
        command: String,
        argumentsText: String,
        environmentText: String,
        workingDirectory: String,
        endpointURL: String,
        authKind: MCPAuthorizationKind,
        authToken: String,
        authHeaderName: String,
        additionalHeadersText: String,
        toolExecutionPolicy: MCPToolExecutionPolicy,
        allowedToolsText: String,
        blockedToolsText: String
    ) {
        let arguments = lineValues(from: argumentsText)
        let environment = keyValuePairs(from: environmentText)
        let additionalHeaders = keyValuePairs(from: additionalHeadersText)
        let allowedToolNames = lineValues(from: allowedToolsText)
        let blockedToolNames = lineValues(from: blockedToolsText)

        Task {
            await mcpManager.updateServer(
                serverID: serverID,
                name: name,
                transportKind: transportKind,
                command: command,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                endpointURL: endpointURL,
                authKind: authKind,
                authToken: authToken,
                authHeaderName: authHeaderName,
                additionalHeaders: additionalHeaders,
                toolExecutionPolicy: toolExecutionPolicy,
                allowedToolNames: allowedToolNames,
                blockedToolNames: blockedToolNames
            )
        }
    }

    func removeMCPServer(_ serverID: UUID) {
        Task {
            await mcpManager.removeServer(serverID)
        }
    }

    func setMCPServerEnabled(_ isEnabled: Bool, serverID: UUID) {
        Task {
            await mcpManager.setEnabled(isEnabled, for: serverID)
        }
    }

    func setMCPToolExecutionPolicy(_ policy: MCPToolExecutionPolicy, serverID: UUID) {
        mcpManager.setToolExecutionPolicy(policy, for: serverID)
    }

    func setMCPAllowedToolNames(_ text: String, serverID: UUID) {
        mcpManager.setAllowedToolNames(toolRuleNames(from: text), for: serverID)
    }

    func setMCPBlockedToolNames(_ text: String, serverID: UUID) {
        mcpManager.setBlockedToolNames(toolRuleNames(from: text), for: serverID)
    }

    func mcpToolRuleSelection(for toolName: String, serverID: UUID) -> MCPToolRuleSelection {
        mcpManager.toolRuleSelection(for: toolName, serverID: serverID)
    }

    func setMCPToolRuleSelection(_ selection: MCPToolRuleSelection, toolName: String, serverID: UUID) {
        mcpManager.setToolRuleSelection(selection, for: toolName, serverID: serverID)
    }

    func exportMCPServers(to url: URL) throws {
        try mcpManager.exportServers(to: url)
    }

    func importMCPServers(from url: URL) {
        Task {
            do {
                _ = try await mcpManager.importServers(from: url)
            } catch {
                mcpManager.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func toolRuleNames(from text: String) -> [String] {
        lineValues(from: text)
    }

    private func lineValues(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func keyValuePairs(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        text.components(separatedBy: .newlines).forEach { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let separator = trimmed.firstIndex(of: "=") else { return }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = value
        }
        return result
    }

    func runMCPToolTest(callName: String, arguments: String) async -> String {
        await mcpManager.testTool(callName: callName, arguments: arguments)
    }

    func runMCPResourceTest(serverID: UUID, uri: String) async -> String {
        await mcpManager.testResource(serverID: serverID, uri: uri)
    }

    func runMCPPromptTest(serverID: UUID, name: String, arguments: String) async -> String {
        await mcpManager.testPrompt(serverID: serverID, name: name, arguments: arguments)
    }

    func refreshLogs(limit: Int = 250) {
        isLoadingLogs = true
        logsErrorMessage = nil
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                LogFileReader.loadRecentEvents(limit: limit)
            }.value
            let files = await Task.detached(priority: .utility) {
                LogFileReader.availableLogFiles()
            }.value
            self.logEntries = entries
            self.logFiles = files
            self.isLoadingLogs = false
        }
    }

    func clearLogs() {
        logsErrorMessage = nil
        logsStatusMessage = nil
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try LogFileReader.clearAllLogs()
                }.value
                self.logsStatusMessage = "日志已清空。"
                self.refreshLogs()
            } catch {
                self.logsErrorMessage = error.localizedDescription
            }
        }
    }

    func exportLogs(to url: URL) {
        logsErrorMessage = nil
        logsStatusMessage = nil
        Task {
            do {
                let exportURL = try await Task.detached(priority: .utility) {
                    try LogFileReader.exportLogs(to: url)
                }.value
                self.logsStatusMessage = "日志已导出到 \(exportURL.lastPathComponent)。"
            } catch {
                self.logsErrorMessage = error.localizedDescription
            }
        }
    }
}

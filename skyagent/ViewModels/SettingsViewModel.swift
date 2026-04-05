import SwiftUI
import Combine

@MainActor
class SettingsViewModel: ObservableObject {
    let store: ConversationStore
    let llm: LLMService
    let skillManager: SkillManager

    @Published var draftURL: String
    @Published var draftKey: String
    @Published var draftModel: String
    @Published var draftSystemPrompt: String
    @Published var draftMaxTokens: Double
    @Published var draftTemperature: Double
    @Published var draftSandboxDir: String
    @Published var draftProfiles: [APIProfile]
    @Published var selectedProfileId: UUID?

    init(store: ConversationStore, llm: LLMService, skillManager: SkillManager) {
        self.store = store
        self.llm = llm
        self.skillManager = skillManager
        let s = store.settings
        self.draftURL = s.apiURL
        self.draftKey = s.apiKey
        self.draftModel = s.model
        self.draftSystemPrompt = s.systemPrompt
        self.draftMaxTokens = Double(s.maxTokens)
        self.draftTemperature = s.temperature
        self.draftSandboxDir = s.sandboxDir
        self.draftProfiles = s.profiles
        self.selectedProfileId = s.activeProfileId ?? s.profiles.first?.id
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
            profiles: profiles,
            activeProfileId: activeProfileId
        )
        store.settings = newSettings
        newSettings.save()
        syncDraft(from: newSettings)
        Task { await llm.updateSettings(newSettings) }
    }

    func saveSettings(_ s: AppSettings) {
        store.settings = s
        s.save()
        syncDraft(from: s)
        Task { await llm.updateSettings(s) }
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
}

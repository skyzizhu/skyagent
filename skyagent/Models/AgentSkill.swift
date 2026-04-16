import Foundation

enum AgentSkillSourceType: String, Codable, CaseIterable, Sendable {
    case appData
    case userStandard

    var displayName: String {
        switch self {
        case .appData: return ".skyagent"
        case .userStandard: return L10n.tr("settings.skill.source.standard")
        }
    }

    var sectionTitle: String {
        switch self {
        case .userStandard: return L10n.tr("settings.skill.section.standard")
        case .appData: return L10n.tr("settings.skill.section.skyagent")
        }
    }

    var sectionDescription: String {
        switch self {
        case .userStandard: return L10n.tr("settings.skill.section.standard_description")
        case .appData: return L10n.tr("settings.skill.section.skyagent_description")
        }
    }

    var sortOrder: Int {
        switch self {
        case .userStandard: return 0
        case .appData: return 1
        }
    }
}

enum AgentSkillResourceKind: String, Codable, Hashable, Sendable {
    case script
    case reference
    case asset
    case template
    case other
}

struct AgentSkillResource: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let relativePath: String
    let kind: AgentSkillResourceKind

    init(relativePath: String, kind: AgentSkillResourceKind) {
        self.id = relativePath
        self.relativePath = relativePath
        self.kind = kind
    }
}

struct AgentSkill: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let displayName: String?
    let shortDescription: String?
    let defaultPrompt: String?
    let aliases: [String]
    let triggerHints: [String]
    let antiTriggerHints: [String]
    let allowImplicitInvocation: Bool
    let requiredEnvironmentVariables: [String]
    let scriptTimeoutSeconds: Int?
    let skillDirectory: String
    let skillFile: String
    let sourceType: AgentSkillSourceType
    let resources: [AgentSkillResource]
    let hasScripts: Bool
    let hasReferences: Bool
    let hasAssets: Bool

    var isAppManaged: Bool { sourceType == .appData }
    var scriptResources: [AgentSkillResource] { resources.filter { $0.kind == .script } }
    var referenceResources: [AgentSkillResource] { resources.filter { $0.kind == .reference } }
    var assetResources: [AgentSkillResource] { resources.filter { $0.kind == .asset } }
    var templateResources: [AgentSkillResource] { resources.filter { $0.kind == .template } }
}

struct SkillActivationResult: Sendable {
    let output: String
    let skillID: String
    let contextMessage: String
}

enum SkillMatchSource: String, Equatable, Sendable {
    case name
    case alias
    case displayName
    case description
    case shortDescription
    case defaultPrompt
    case triggerHint
    case antiTriggerHint
}

struct SkillMatchSignal: Equatable, Sendable {
    let source: SkillMatchSource
    let phrase: String
}

struct SkillMatchCandidate: Equatable, Sendable {
    let skill: AgentSkill
    let score: Int
    let matchedSignals: [SkillMatchSignal]
    let blockedSignals: [SkillMatchSignal]
}

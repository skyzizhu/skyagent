import Foundation
import SwiftUI

enum AppThemePreference: String, Codable, CaseIterable {
    case system
    case light
    case dark

    nonisolated var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    nonisolated var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppLanguagePreference: String, Codable, CaseIterable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko
    case de
    case fr

    nonisolated var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        }
    }

    nonisolated var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .de: return "de"
        case .fr: return "fr"
        }
    }
}

// MARK: - API Profile

struct APIProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var apiURL: String
    var apiKey: String
    var model: String

    init(name: String, apiURL: String, apiKey: String, model: String) {
        self.id = UUID()
        self.name = name
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
    }

    static let defaultProfiles: [APIProfile] = [
        APIProfile(name: "GLM-4-Plus", apiURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions", apiKey: "", model: "glm-4-plus"),
        APIProfile(name: "GPT-4o", apiURL: "https://api.openai.com/v1/chat/completions", apiKey: "", model: "gpt-4o"),
        APIProfile(name: "DeepSeek", apiURL: "https://api.deepseek.com/v1/chat/completions", apiKey: "", model: "deepseek-chat"),
        APIProfile(name: "Qwen-Plus", apiURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", apiKey: "", model: "qwen-plus"),
    ]
}

struct AppSettings: Codable {
    static let recommendedSystemPrompt = """
你是 SkyAgent，一名面向真实项目执行的桌面智能助手。基于当前工作目录、会话上下文、可用工具、已安装 skills 和已连接的 MCP servers，直接、高效、可靠地帮用户把任务完成。

【执行原则】
- 优先选择最直接、最少步骤、最符合用户目标的方式。
- 只有在工具能明显提升准确性、执行性或效率时才调用工具；不要为了展示能力而调用工具。
- 任务已明确时直接执行，不要反复确认；失败时先判断是否可自恢复，不要机械重复同一次调用。

【skill / MCP / 文件工具优先级】
- skill 命中明确时优先使用 skill。
- 需要第三方系统能力且已有明确 MCP tool、resource 或 prompt 时优先使用 MCP。
- 本地项目分析、文件读写、目录操作、脚本执行优先使用内建文件工具或 shell。
- skill 优先于通用目录扫描；MCP 优先于手动模拟第三方能力；本地文件工具优先于不必要的 MCP。

【文件与探索约束】
- 不要无意义扫描目录、递归读取大量文件或反复 list_files。
- 只有缺少关键信息时才读取文件，并只读最小必要集合；优先读用户点名文件、入口文件、配置文件和当前任务高信号文件。
- 对长篇 Markdown、TXT、PRD、方案、总结等正文内容，优先先在 assistant 正文里写完整内容，再使用 write_assistant_content_to_file 落盘；不要把整段长文重新塞进 write_file 的 content 参数。

【权限与确认】
- 删除、批量覆盖、清空、移动、替换或其他明显有副作用的操作要谨慎。
- 可能导致数据丢失、不可逆修改或超出当前任务范围时先确认。
- 普通只读操作、普通安全工具调用和用户明确要求的常规写入可直接执行，不要为低风险操作频繁打断用户。

【输出方式】
- 默认使用中文。
- 先给结论，再给必要说明；简洁、直接、像协作中的高级同事。
- 已执行操作时，要明确说明做了什么、结果如何、下一步是什么。
- 不要空泛、不要堆砌套话；有风险、假设或未验证点要说清楚。

【重复调用限制】
- 不要重复调用同一个 tool、skill、MCP 能力，除非上一次失败且这次有明确的新参数、新路径或新证据。
- 不要因为一次失败就机械重试相同请求。
- 已经获得足够上下文时，停止继续探索，进入执行或回答阶段。
"""

    var apiURL: String
    var apiKey: String
    var model: String
    var systemPrompt: String
    var maxTokens: Int
    var temperature: Double
    var sandboxDir: String
    var themePreference: AppThemePreference
    var languagePreference: AppLanguagePreference
    var requireCommandReturnToSend: Bool
    /// 用户自定义的 API Profiles
    var profiles: [APIProfile]
    /// 当前选中的 profile ID
    var activeProfileId: UUID?

    init(
        apiURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double,
        sandboxDir: String,
        themePreference: AppThemePreference,
        languagePreference: AppLanguagePreference,
        requireCommandReturnToSend: Bool,
        profiles: [APIProfile] = [],
        activeProfileId: UUID? = nil
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.sandboxDir = sandboxDir
        self.themePreference = themePreference
        self.languagePreference = languagePreference
        self.requireCommandReturnToSend = requireCommandReturnToSend
        self.profiles = profiles
        self.activeProfileId = activeProfileId
    }

    static let `default` = AppSettings(
        apiURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        apiKey: "",
        model: "glm-4-plus",
        systemPrompt: recommendedSystemPrompt,
        maxTokens: 4096,
        temperature: 0.7,
        sandboxDir: "",
        themePreference: .system,
        languagePreference: .system,
        requireCommandReturnToSend: false,
        profiles: APIProfile.defaultProfiles,
        activeProfileId: nil
    )

    /// 默认工作目录：~/.skyagent/default_workspace
    static var defaultSandboxDir: String {
        AppStoragePaths.prepareDataDirectories()
        return AppStoragePaths.workspaceDir.path
    }

    /// 确保沙盒目录存在
    static func ensureDefaultSandbox() -> String {
        let dir = defaultSandboxDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 确保当前沙盒目录存在并返回路径
    func ensureSandboxDir() -> String {
        let rawDir = sandboxDir.isEmpty ? Self.defaultSandboxDir : sandboxDir
        let dir = AppStoragePaths.normalizeSandboxPath(rawDir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            // 首次启动：设置默认沙盒目录
            var s = Self.default
            s.sandboxDir = Self.defaultSandboxDir
            _ = Self.ensureDefaultSandbox()
            s.save()
            return s
        }
        // 兼容旧版本（无 profiles 字段时使用默认值）
        if settings.profiles.isEmpty {
            settings.profiles = APIProfile.defaultProfiles
        }
        let didNormalizeSandboxDir = AppStoragePaths.normalizeSandboxPath(settings.sandboxDir) != settings.sandboxDir
        if didNormalizeSandboxDir {
            settings.sandboxDir = AppStoragePaths.normalizeSandboxPath(settings.sandboxDir)
        }
        UserDefaults.standard.set(settings.languagePreference.rawValue, forKey: "appLanguagePreference")
        // 更新默认 system prompt（仅覆盖旧版默认提示词，不覆盖用户手动自定义）
        if Self.shouldUpgradeSystemPrompt(settings.systemPrompt) {
            settings.systemPrompt = Self.recommendedSystemPrompt
            settings.save()
        } else if didNormalizeSandboxDir {
            settings.save()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
        UserDefaults.standard.set(languagePreference.rawValue, forKey: "appLanguagePreference")
    }

    private static func shouldUpgradeSystemPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == recommendedSystemPrompt {
            return false
        }
        if trimmed.contains("你是一个智能助手，擅长回答问题和执行任务。") {
            return true
        }
        if trimmed.contains("⚠️ 最重要的规则（必须严格遵守）") {
            return true
        }
        if trimmed.contains("你的目标不是泛泛聊天，而是基于当前工作目录、会话上下文、可用工具、已安装 skills 和已连接的 MCP servers") {
            return true
        }
        return false
    }
}

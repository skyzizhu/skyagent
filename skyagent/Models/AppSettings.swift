import Foundation
import SwiftUI

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
    var apiURL: String
    var apiKey: String
    var model: String
    var systemPrompt: String
    var maxTokens: Int
    var temperature: Double
    var sandboxDir: String
    /// 用户自定义的 API Profiles
    var profiles: [APIProfile]
    /// 当前选中的 profile ID
    var activeProfileId: UUID?

    init(apiURL: String, apiKey: String, model: String, systemPrompt: String, maxTokens: Int, temperature: Double, sandboxDir: String, profiles: [APIProfile] = [], activeProfileId: UUID? = nil) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.sandboxDir = sandboxDir
        self.profiles = profiles
        self.activeProfileId = activeProfileId
    }

    static let `default` = AppSettings(
        apiURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        apiKey: "",
        model: "glm-4-plus",
        systemPrompt: "你是一个智能助手，擅长回答问题和执行任务。你可以使用工具来执行 shell 命令、读写文件和搜索网页。\n\n⚠️ 最重要的规则（必须严格遵守）：\n- 回答问题、写文章、写代码时，直接在对话中输出内容，绝对不要使用 write_file 工具\n- 只有当用户明确说出「保存」「写入文件」「创建文件」等要求时，才使用 write_file\n- 用户没有要求保存时，哪怕内容很长，也只在对话中展示",
        maxTokens: 4096,
        temperature: 0.7,
        sandboxDir: "",
        profiles: APIProfile.defaultProfiles,
        activeProfileId: nil
    )

    /// 默认沙盒目录：~/MiniAgent
    static var defaultSandboxDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("MiniAgent")
    }

    /// 确保沙盒目录存在
    static func ensureDefaultSandbox() -> String {
        let dir = defaultSandboxDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 确保当前沙盒目录存在并返回路径
    func ensureSandboxDir() -> String {
        let dir = sandboxDir.isEmpty ? Self.defaultSandboxDir : sandboxDir
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
        // 更新默认 system prompt（如果用户没有自定义过）
        if settings.systemPrompt.contains("你是一个智能助手") && !settings.systemPrompt.contains("⚠️ 最重要的规则") {
            settings.systemPrompt = Self.default.systemPrompt
            settings.save()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
    }
}

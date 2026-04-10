import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var apiURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var step = 0
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 32) {
            switch step {
            case 0:
                welcomeStep
            case 1:
                configStep
            case 2:
                doneStep
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.2)) { appeared = true } }
    }

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "cpu")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(
                    LinearGradient(colors: [.accentColor, .accentColor.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .opacity(appeared ? 1 : 0.3)

            VStack(spacing: 8) {
                Text(L10n.tr("onboarding.welcome.title"))
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text(L10n.tr("onboarding.welcome.subtitle"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(L10n.tr("onboarding.welcome.note"))
                .font(.callout)
                .foregroundStyle(.tertiary)

            Button(L10n.tr("onboarding.welcome.cta")) {
                withAnimation(.spring(response: 0.4)) { step = 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private var configStep: some View {
        VStack(spacing: 20) {
            Text(L10n.tr("onboarding.config.title"))
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("onboarding.config.presets"))
                    .font(.headline)
                HStack(spacing: 12) {
                    presetButton("GLM-4-Plus", model: "glm-4-plus", url: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
                    presetButton("GPT-4o", model: "gpt-4o", url: "https://api.openai.com/v1/chat/completions")
                    presetButton("DeepSeek", model: "deepseek-chat", url: "https://api.deepseek.com/v1/chat/completions")
                    presetButton("Qwen-Plus", model: "qwen-plus", url: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
                }
            }

            Form {
                TextField("API URL", text: $apiURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.tr("onboarding.config.model_name"), text: $model)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 500)

            HStack(spacing: 16) {
                Button(L10n.tr("common.back")) {
                    withAnimation { step = 0 }
                }

                Button(L10n.tr("onboarding.config.finish")) {
                    saveAndContinue()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiURL.isEmpty || apiKey.isEmpty || model.isEmpty)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(
                    LinearGradient(colors: [.green, .green.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text(L10n.tr("onboarding.done.title"))
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text(L10n.tr("onboarding.done.subtitle"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(L10n.tr("onboarding.done.cta")) {
                NotificationCenter.default.post(name: .onboardingComplete, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private func presetButton(_ name: String, model: String, url: String) -> some View {
        Button(name) {
            self.model = model
            self.apiURL = url
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func saveAndContinue() {
        let settings = AppSettings(
            apiURL: apiURL,
            apiKey: apiKey,
            model: model,
            systemPrompt: viewModel.settings.systemPrompt,
            maxTokens: viewModel.settings.maxTokens,
            temperature: viewModel.settings.temperature,
            sandboxDir: viewModel.settings.sandboxDir,
            themePreference: viewModel.settings.themePreference,
            languagePreference: viewModel.settings.languagePreference,
            requireCommandReturnToSend: viewModel.settings.requireCommandReturnToSend
        )
        viewModel.saveSettings(settings)
        withAnimation(.spring(response: 0.4)) { step = 2 }
    }
}

extension Notification.Name {
    static let onboardingComplete = Notification.Name("onboardingComplete")
}

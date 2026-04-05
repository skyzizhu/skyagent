import SwiftUI
import AppKit

struct SettingsView: View {
    enum SkillLibraryTab: String, CaseIterable, Identifiable {
        case standard
        case skyagent

        var id: String { rawValue }

        var sourceType: AgentSkillSourceType {
            switch self {
            case .standard: return .userStandard
            case .skyagent: return .appData
            }
        }
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case models
        case skills
        case general

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .models: return "settings.nav.models"
            case .skills: return "settings.nav.skills"
            case .general: return "settings.nav.general"
            }
        }

        var subtitleKey: String {
            switch self {
            case .models: return "settings.nav.models.subtitle"
            case .skills: return "settings.nav.skills.subtitle"
            case .general: return "settings.nav.general.subtitle"
            }
        }

        var icon: String {
            switch self {
            case .models: return "cpu"
            case .skills: return "wand.and.stars"
            case .general: return "slider.horizontal.3"
            }
        }
    }

    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var skillManager: SkillManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAddProfile = false
    @State private var newProfileName = ""
    @State private var showSkillError = false
    @State private var selectedSkill: AgentSkill?
    @State private var selectedTab: SettingsTab = .models
    @State private var selectedSkillLibraryTab: SkillLibraryTab = .standard

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self._skillManager = ObservedObject(wrappedValue: viewModel.skillManager)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentPanel
        }
        .frame(width: 860, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(L10n.tr("settings.profile.save_new_title"), isPresented: $showAddProfile) {
            TextField(L10n.tr("settings.profile.name"), text: $newProfileName)
            Button(L10n.tr("common.save")) {
                if !newProfileName.isEmpty {
                    viewModel.saveCurrentAsProfile(name: newProfileName)
                    newProfileName = ""
                }
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {
                newProfileName = ""
            }
        } message: {
            Text(L10n.tr("settings.profile.save_new_message"))
        }
        .alert(L10n.tr("settings.skill.error_title"), isPresented: $showSkillError) {
            Button(L10n.tr("common.confirm")) {
                skillManager.lastErrorMessage = nil
            }
        } message: {
            Text(skillManager.lastErrorMessage ?? L10n.tr("common.unknown_error"))
        }
        .sheet(item: $selectedSkill) { skill in
            skillDetailSheet(skill)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("common.settings"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(L10n.tr(selectedTab.subtitleKey))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(width: 210, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.primary.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var contentPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard
                    tabContent
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                if selectedTab == .models {
                    Button(L10n.tr("settings.profile.save_as")) {
                        showAddProfile = true
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(L10n.tr("common.cancel")) {
                    viewModel.resetDraft()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("common.save")) {
                    viewModel.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        }
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: selectedTab.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr(selectedTab.titleKey))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(L10n.tr(selectedTab.subtitleKey))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0.98),
                            Color(nsColor: .textBackgroundColor).opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .models:
            modelsContent
        case .skills:
            skillsContent
        case .general:
            generalContent
        }
    }

    private var modelsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: L10n.tr("settings.section.model")) {
                activeModelOverview
            }

            settingsCard(title: L10n.tr("settings.section.api")) {
                VStack(alignment: .leading, spacing: 16) {
                    selectedProfileHeader

                    VStack(spacing: 14) {
                        labeledTextField(L10n.tr("settings.api_url"), text: $viewModel.draftURL)
                        labeledSecureField(L10n.tr("settings.api_key"), text: $viewModel.draftKey)
                        labeledTextField(L10n.tr("settings.model"), text: $viewModel.draftModel)
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.8)
                        .padding(.vertical, 2)

                    VStack(spacing: 14) {
                        labeledSlider("Max Tokens", value: $viewModel.draftMaxTokens, range: 256...16384, step: 256, formatter: { "\(Int($0))" })
                        labeledSlider("Temperature", value: $viewModel.draftTemperature, range: 0...2, step: 0.1, formatter: { String(format: "%.1f", $0) })
                    }
                }
            }

            settingsCard(title: L10n.tr("settings.models.saved_profiles")) {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.profiles.isEmpty {
                        Text(L10n.tr("settings.profile.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(viewModel.profiles) { profile in
                                profileCard(profile)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button(L10n.tr("settings.models.add_more")) {
                            showAddProfile = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var skillsContent: some View {
        settingsCard(title: L10n.tr("settings.section.skills")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    skillLibraryTabButton(.standard)
                    skillLibraryTabButton(.skyagent)
                    Spacer()
                }

                HStack {
                    Button(L10n.tr("settings.skill.import")) {
                        let panel = NSOpenPanel()
                        panel.title = L10n.tr("settings.skill.import_panel")
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.urls.first {
                            viewModel.installSkill(from: url)
                            showSkillError = skillManager.lastErrorMessage != nil
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(L10n.tr("settings.skill.rescan")) {
                        viewModel.reloadSkills()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                Text(L10n.tr("settings.skill.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if filteredSkills.isEmpty {
                    Text(L10n.tr("settings.skill.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedSkillLibraryTab.sourceType.sectionTitle)
                                .font(.system(size: 12, weight: .semibold))
                            Text(selectedSkillLibraryTab.sourceType.sectionDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(filteredSkills, id: \.id) { skill in
                            skillRow(skill)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: L10n.tr("settings.section.sandbox")) {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(L10n.tr("settings.workdir"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 110, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                TextField("", text: $viewModel.draftSandboxDir)
                                    .textFieldStyle(.roundedBorder)
                                Button(L10n.tr("common.choose")) {
                                    let panel = NSOpenPanel()
                                    panel.title = L10n.tr("settings.choose_sandbox.title")
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = false
                                    panel.allowsMultipleSelection = false
                                    if panel.runModal() == .OK, let url = panel.urls.first {
                                        viewModel.draftSandboxDir = url.path
                                    }
                                }
                            }

                            Text(L10n.tr("settings.workdir.hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            settingsCard(title: L10n.tr("settings.section.system_prompt")) {
                TextEditor(text: $viewModel.draftSystemPrompt)
                    .font(.body)
                    .frame(minHeight: 180)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
            }
        }
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr(tab.titleKey))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.82))
                    Text(L10n.tr(tab.subtitleKey))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0.98),
                            Color(nsColor: .textBackgroundColor).opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 12, x: 0, y: 5)
    }

    private func labeledTextField(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 110, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledSecureField(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 110, alignment: .leading)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: @escaping (Double) -> String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 110, alignment: .leading)

            HStack(spacing: 12) {
                Slider(value: value, in: range, step: step)
                Text(formatter(value.wrappedValue))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private var activeModelOverview: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("settings.profile.active", viewModel.activeProfile?.name ?? viewModel.draftModel))
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                HStack(spacing: 8) {
                    Text(viewModel.activeProfile?.model ?? viewModel.settings.model)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                        .foregroundStyle(Color.accentColor)

                    if viewModel.hasPendingProfileSelection, let selected = viewModel.selectedProfile {
                        Text(L10n.tr("settings.profile.pending_badge"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(.secondary)

                        Text(selected.name)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(viewModel.activeProfile?.apiURL ?? viewModel.settings.apiURL)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(L10n.tr("settings.profile.hint"))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)

                Text(viewModel.hasPendingProfileSelection ? L10n.tr("settings.profile.pending", viewModel.selectedProfile?.name ?? "") : L10n.tr("settings.profile.active_badge"))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(viewModel.hasPendingProfileSelection ? .secondary : Color.accentColor)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.08),
                            Color.accentColor.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 0.9)
        )
    }

    private var selectedProfileHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(viewModel.selectedProfile?.name ?? L10n.tr("settings.profile.name"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))

                if let selected = viewModel.selectedProfile, viewModel.isActiveProfile(selected) {
                    Text(L10n.tr("settings.profile.active_badge"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else if viewModel.hasPendingProfileSelection {
                    Text(L10n.tr("settings.profile.pending_badge"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }

            Text(L10n.tr("settings.profile.hint"))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func profileCard(_ profile: APIProfile) -> some View {
        let isActive = viewModel.isActiveProfile(profile)
        let isSelected = viewModel.isSelectedProfile(profile)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    if isActive {
                        Text(L10n.tr("settings.profile.active_badge"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    } else if isSelected {
                        Text(L10n.tr("settings.profile.pending_badge"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(profile.model)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(profile.apiURL)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))

            Button {
                viewModel.deleteProfile(profile)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((isSelected ? Color.accentColor : Color.primary).opacity(isSelected ? 0.075 : 0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((isSelected ? Color.accentColor : Color.primary).opacity(isSelected ? 0.22 : 0.06), lineWidth: 0.9)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            viewModel.selectProfile(profile)
        }
    }

    private var filteredSkills: [AgentSkill] {
        skillManager.availableSkills
            .filter { $0.sourceType == selectedSkillLibraryTab.sourceType }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func skillLibraryTabButton(_ tab: SkillLibraryTab) -> some View {
        let isSelected = selectedSkillLibraryTab == tab
        return Button {
            selectedSkillLibraryTab = tab
        } label: {
            Text(tab.sourceType.sectionTitle)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(skill.sourceType.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Text(skill.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if skill.hasScripts { skillTag("scripts \(skill.scriptResources.count)") }
                    if skill.hasReferences { skillTag("references") }
                    if skill.hasAssets { skillTag("assets") }
                }
            }

            Spacer()

            Button(L10n.tr("common.details")) {
                selectedSkill = skill
            }
            .buttonStyle(.bordered)

            if skill.isAppManaged {
                Button(L10n.tr("common.uninstall")) {
                    viewModel.uninstallSkill(skill)
                    showSkillError = skillManager.lastErrorMessage != nil
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func skillTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    private func skillDetailSheet(_ skill: AgentSkill) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.system(size: 20, weight: .bold))
                        Text(skill.sourceType.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }

                    Text(skill.description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                detailRow(L10n.tr("settings.skill.directory"), skill.skillDirectory, canReveal: true, canCopy: true)
                detailRow(L10n.tr("settings.skill.entry"), skill.skillFile, canReveal: true, canCopy: true)
                detailRow(L10n.tr("settings.skill.resource_count"), "\(skill.resources.count)")
                if skill.hasScripts {
                    detailRow(L10n.tr("settings.skill.scripts"), L10n.tr("settings.skill.script_count", String(skill.scriptResources.count)))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )

            if !skill.scriptResources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L10n.tr("settings.skill.script_entries"))
                            .font(.system(size: 13, weight: .semibold))
                        skillTag(L10n.tr("settings.skill.open_mode_executable"))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(skill.scriptResources, id: \.id) { resource in
                            HStack(alignment: .top, spacing: 8) {
                                Text(resource.relativePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack(spacing: 6) {
                                    resourceActionButton("doc.on.doc", help: L10n.tr("settings.skill.copy_relative_path")) {
                                        copyToPasteboard(resource.relativePath)
                                    }
                                    resourceActionButton("terminal", help: L10n.tr("settings.skill.copy_script_example")) {
                                        copyToPasteboard(scriptInvocationExample(for: skill, resource: resource))
                                    }
                                    resourceActionButton("folder", help: L10n.tr("common.reveal_in_finder")) {
                                        revealInFinder((skill.skillDirectory as NSString).appendingPathComponent(resource.relativePath))
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("settings.skill.resources"))
                    .font(.system(size: 13, weight: .semibold))

                if skill.resources.isEmpty {
                    Text(L10n.tr("settings.skill.no_resources"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(skill.resources, id: \.id) { resource in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(resource.kind.rawValue)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(nsColor: .windowBackgroundColor))
                                        .foregroundStyle(.secondary)
                                        .clipShape(Capsule())

                                    Text(resource.relativePath)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    HStack(spacing: 6) {
                                        resourceActionButton("doc.on.doc", help: L10n.tr("settings.skill.copy_relative_path")) {
                                            copyToPasteboard(resource.relativePath)
                                        }
                                        resourceActionButton("folder", help: L10n.tr("common.reveal_in_finder")) {
                                            revealInFinder((skill.skillDirectory as NSString).appendingPathComponent(resource.relativePath))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("settings.skill.preview"))
                    .font(.system(size: 13, weight: .semibold))
                ScrollView {
                    Text(skillPreview(for: skill))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.8)
                )
            }

            Spacer()

            HStack {
                Spacer()
                Button(L10n.tr("common.close")) {
                    selectedSkill = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 680)
    }

    private func detailRow(_ title: String, _ value: String, canReveal: Bool = false, canCopy: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if canCopy {
                    resourceActionButton("doc.on.doc", help: L10n.tr("common.copy_path")) {
                        copyToPasteboard(value)
                    }
                }
                if canReveal {
                    resourceActionButton("folder", help: L10n.tr("common.reveal_in_finder")) {
                        revealInFinder(value)
                    }
                }
            }
        }
    }

    private func resourceActionButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func skillPreview(for skill: AgentSkill) -> String {
        guard let content = try? String(contentsOfFile: skill.skillFile, encoding: .utf8) else {
            return L10n.tr("settings.skill.preview_error", skill.skillFile)
        }
        let stripped = stripFrontmatter(from: content)
        if stripped.count > 1600 {
            return String(stripped.prefix(1600)) + "\n\n" + L10n.tr("settings.skill.preview_truncated")
        }
        return stripped
    }

    private func stripFrontmatter(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }
        guard let endIndex = lines.enumerated().dropFirst().first(where: { $0.element.trimmingCharacters(in: .whitespaces) == "---" })?.offset else {
            return content
        }
        return lines.suffix(from: endIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func scriptInvocationExample(for skill: AgentSkill, resource: AgentSkillResource) -> String {
        """
        {
          "name": "run_skill_script",
          "arguments": {
            "skill_name": "\(skill.name)",
            "path": "\(resource.relativePath)",
            "args": [],
            "timeout_seconds": 20
          }
        }
        """
    }
}

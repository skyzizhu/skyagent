import SwiftUI
import AppKit
import UniformTypeIdentifiers

private extension Double {
    var formattedMilliseconds: String {
        "\(Int(self)) ms"
    }
}

struct SettingsView: View {
    struct TraceTimingSummary {
        let firstTokenMs: Int?
        let llmTotalMs: Int?
        let longestToolMs: Int?
        let mcpInitializeMs: Int?
        let skillScriptMs: Int?
        let shellMs: Int?
    }

    struct TraceStageSummary: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let tint: Color
    }

    struct SlowTraceSummary: Identifiable {
        let id: String
        let traceID: String
        let durationMs: Int
        let eventCount: Int
        let errorCount: Int
        let timeoutCount: Int
        let startedAt: Date
    }

    enum LogQuickFilter: String, CaseIterable, Identifiable {
        case all
        case errors
        case timeouts
        case slow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .errors: return "Errors"
            case .timeouts: return "Timeouts"
            case .slow: return "Slow"
            }
        }
    }

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
        case general
        case models
        case skills
        case mcp
        case logs
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return L10n.tr("settings.nav.general")
            case .models: return L10n.tr("settings.nav.models")
            case .skills: return L10n.tr("settings.nav.skills")
            case .mcp: return L10n.tr("settings.nav.mcp")
            case .logs: return "日志"
            case .about: return "关于"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return L10n.tr("settings.nav.general.subtitle")
            case .models: return L10n.tr("settings.nav.models.subtitle")
            case .skills: return L10n.tr("settings.nav.skills.subtitle")
            case .mcp: return L10n.tr("settings.nav.mcp.subtitle")
            case .logs: return "查看最近的 trace、耗时、工具、MCP 与界面事件。"
            case .about: return "版本、数据目录和当前安装信息。"
            }
        }

        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .models: return "cpu"
            case .skills: return "wand.and.stars"
            case .mcp: return "externaldrive.connected.to.line.below"
            case .logs: return "list.bullet.rectangle.portrait"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var skillManager: SkillManager
    @ObservedObject private var mcpManager: MCPServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAddProfile = false
    @State private var newProfileName = ""
    @State private var showSkillError = false
    @State private var selectedSkill: AgentSkill?
    @State private var selectedTab: SettingsTab = .general
    @State private var selectedSkillLibraryTab: SkillLibraryTab = .standard
    @State private var showMCPConfigPaths = false
    @State private var showNewMCPForm = false
    @State private var newMCPName = ""
    @State private var newMCPTransportKind: MCPTransportKind = .stdio
    @State private var newMCPCommand = ""
    @State private var newMCPArguments = ""
    @State private var newMCPEnvironment = ""
    @State private var newMCPWorkingDirectory = ""
    @State private var newMCPEndpointURL = ""
    @State private var newMCPAuthKind: MCPAuthorizationKind = .none
    @State private var newMCPAuthToken = ""
    @State private var newMCPAuthHeaderName = ""
    @State private var newMCPAdditionalHeaders = ""
    @State private var newMCPToolExecutionPolicy: MCPToolExecutionPolicy = .allowAll
    @State private var newMCPAllowedTools = ""
    @State private var newMCPBlockedTools = ""
    @State private var editingMCPServerID: UUID?
    @State private var editMCPShowConnectionDetails = true
    @State private var editMCPShowToolRules = false
    @State private var editMCPShowCapabilities = false
    @State private var editMCPShowTesting = false
    @State private var editMCPShowLogs = false
    @State private var editMCPName = ""
    @State private var editMCPTransportKind: MCPTransportKind = .stdio
    @State private var editMCPCommand = ""
    @State private var editMCPArguments = ""
    @State private var editMCPEnvironment = ""
    @State private var editMCPWorkingDirectory = ""
    @State private var editMCPEndpointURL = ""
    @State private var editMCPAuthKind: MCPAuthorizationKind = .none
    @State private var editMCPAuthToken = ""
    @State private var editMCPAuthHeaderName = ""
    @State private var editMCPAdditionalHeaders = ""
    @State private var editMCPToolExecutionPolicy: MCPToolExecutionPolicy = .allowAll
    @State private var editMCPAllowedTools = ""
    @State private var editMCPBlockedTools = ""
    @State private var mcpSelectedToolCallNames: [UUID: String] = [:]
    @State private var mcpToolTestArguments: [UUID: String] = [:]
    @State private var mcpSelectedResourceURIs: [UUID: String] = [:]
    @State private var mcpSelectedPromptNames: [UUID: String] = [:]
    @State private var mcpPromptTestArguments: [UUID: String] = [:]
    @State private var mcpTestResults: [UUID: String] = [:]
    @State private var mcpRunningTests: Set<UUID> = []
    @State private var selectedLogCategory = "all"
    @State private var logSearchText = ""
    @State private var logTraceFilter = ""
    @State private var selectedLogTraceID: String?
    @State private var selectedLogQuickFilter: LogQuickFilter = .all
    @State private var expandedLogIDs: Set<String> = []

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self._skillManager = ObservedObject(wrappedValue: viewModel.skillManager)
        self._mcpManager = ObservedObject(wrappedValue: viewModel.mcpManager)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
                .overlay(Color.primary.opacity(0.045))
            contentPanel
        }
        .frame(minWidth: 860, idealWidth: 960, maxWidth: 1180, minHeight: 680, idealHeight: 760, maxHeight: 920)
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
                Text(selectedTab.subtitle)
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
        .frame(width: 208, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.primary.opacity(0.018)
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

                if selectedTab == .models || selectedTab == .general {
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
                } else {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.985))
        }
        .background(Color.primary.opacity(0.01))
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    Text(selectedTab.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(selectedTab.subtitle)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                settingsSummaryPill(
                    title: selectedTab == .skills ? "Installed" : "Active",
                    value: selectedTabSummaryPrimaryValue
                )
                settingsSummaryPill(
                    title: selectedTab == .mcp ? "Connected" : "Items",
                    value: selectedTabSummarySecondaryValue
                )
                Spacer()
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0.98),
                            Color(nsColor: .textBackgroundColor).opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.015), radius: 16, x: 0, y: 6)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            generalContent
        case .models:
            modelsContent
        case .skills:
            skillsContent
        case .mcp:
            mcpContent
        case .logs:
            logsContent
        case .about:
            aboutContent
        }
    }

    private var modelsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: L10n.tr("settings.section.model"), subtitle: "当前启用配置与草稿切换一眼可见。") {
                activeModelOverview
            }

            settingsCard(title: L10n.tr("settings.section.api"), subtitle: "这里保留真正需要改动的核心参数，其他信息收在摘要里。") {
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
                        labeledSlider(L10n.tr("settings.max_tokens"), value: $viewModel.draftMaxTokens, range: 256...16384, step: 256, formatter: { "\(Int($0))" })
                        labeledSlider(L10n.tr("settings.temperature"), value: $viewModel.draftTemperature, range: 0...2, step: 0.1, formatter: { String(format: "%.1f", $0) })
                    }
                }
            }

            settingsCard(title: L10n.tr("settings.models.saved_profiles"), subtitle: "切换、删除和新增 profile 都放在这一处。") {
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
        settingsCard(title: L10n.tr("settings.section.skills"), subtitle: "先按来源切换，再对单个 skill 做导入、查看或卸载。") {
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
            settingsCard(title: "主要设置", subtitle: "把最常改的主题、语言和发送方式放在最上面。") {
                VStack(spacing: 14) {
                    labeledPicker(
                        "主题",
                        selection: $viewModel.draftThemePreference,
                        options: AppThemePreference.allCases
                    ) { $0.displayName }

                    labeledPicker(
                        "语言",
                        selection: $viewModel.draftLanguagePreference,
                        options: AppLanguagePreference.allCases
                    ) { $0.displayName }

                    HStack(alignment: .top, spacing: 12) {
                        Text("发送快捷键")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("需要按 ⌘ + 回车发送", isOn: $viewModel.draftRequireCommandReturnToSend)
                                .toggleStyle(.switch)

                            Text("关闭时，回车直接发送；Shift + 回车换行。开启后，回车换行，⌘ + 回车发送。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            settingsCard(title: L10n.tr("settings.section.sandbox"), subtitle: "把日常最常改的工作目录和系统提示词放在同一页。") {
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

            settingsCard(title: L10n.tr("settings.section.system_prompt"), subtitle: "只在需要统一 agent 行为时调整；默认情况下不需要频繁修改。") {
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

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "SkyAgent", subtitle: "当前版本和本地数据位置。") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        mcpMetricCard(title: "版本", value: appVersionText, tint: .accentColor)
                        mcpMetricCard(title: "数据根目录", value: ".skyagent", tint: .green)
                        mcpMetricCard(title: "日志目录", value: "events", tint: .orange)
                    }

                    Text("这里主要用于快速确认版本、定位本地目录，以及打开常用数据位置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsCard(title: "本地路径", subtitle: "常用目录直接打开或在 Finder 中定位。") {
                VStack(alignment: .leading, spacing: 10) {
                    aboutPathRow(title: "用户目录", path: AppStoragePaths.userRoot.path)
                    aboutPathRow(title: "工作目录", path: AppStoragePaths.workspaceDir.path)
                    aboutPathRow(title: "Skills", path: AppStoragePaths.skillsDir.path)
                    aboutPathRow(title: "MCP 配置", path: AppStoragePaths.mcpServersFile.path, canOpenFile: true)
                    aboutPathRow(title: "日志目录", path: AppStoragePaths.logsDir.path)
                }
            }
        }
    }

    private var mcpContent: some View {
        settingsCard(title: "MCP Servers", subtitle: "把高频操作放在上面，连接细节和测试工具折叠到单个 server 里。") {
            VStack(alignment: .leading, spacing: 14) {
                Text("第三方 MCP server 分为 User 和 Project 两层；日常只需要看状态、刷新和编辑单个 server。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                mcpOverviewPanel
                mcpActionBar
                mcpConfigLocationsPanel
                newMCPServerPanel

                if let error = mcpManager.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let summary = mcpManager.lastImportSummaryMessage, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if viewModel.mcpServers.isEmpty {
                    Text("No MCP servers configured yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.mcpServers) { server in
                            mcpServerRow(server, isEditing: editingMCPServerID == server.id)
                        }
                    }
                }
            }
        }
    }

    private var logsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "Logs", subtitle: "先看最近日志，再按 category 或 trace_id 缩小范围。") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Button(viewModel.isLoadingLogs ? "Refreshing..." : "Refresh Logs") {
                            viewModel.refreshLogs()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isLoadingLogs)

                        Button("Open Logs Folder") {
                            NSWorkspace.shared.open(AppStoragePaths.logsDir)
                        }
                        .buttonStyle(.bordered)

                        if let latestFile = viewModel.logFiles.first {
                            Button("Reveal Latest File") {
                                revealInFinder(latestFile.path)
                            }
                            .buttonStyle(.bordered)
                        }

                        Spacer()
                    }

                    HStack(spacing: 10) {
                        mcpMetricCard(title: "Loaded", value: "\(filteredLogEntries.count)", tint: .accentColor)
                        mcpMetricCard(title: "Trace IDs", value: "\(Set(viewModel.logEntries.compactMap(\.traceID)).count)", tint: .green)
                        mcpMetricCard(title: "Files", value: "\(viewModel.logFiles.count)", tint: .orange)
                        mcpMetricCard(title: "Errors", value: "\(viewModel.logEntries.filter { $0.level == "error" }.count)", tint: .red)
                    }

                    HStack(spacing: 8) {
                        ForEach(LogQuickFilter.allCases) { filter in
                            logQuickFilterButton(filter)
                        }
                        Spacer()
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Text("Category")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 72, alignment: .leading)

                        Picker("", selection: $selectedLogCategory) {
                            Text("All").tag("all")
                            ForEach(logCategories, id: \.self) { category in
                                Text(category).tag(category)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Spacer()
                    }

                    labeledTextField("Search", text: $logSearchText)
                    labeledTextField("Trace ID", text: $logTraceFilter)

                    if let traceID = activeLogTraceID,
                       !traceLogEntries(traceID: traceID).isEmpty {
                        logTracePanel(traceID: traceID)
                    }

                    let slowTraces = slowTraceSummaries()
                    if !slowTraces.isEmpty {
                        logSlowTracesPanel(slowTraces)
                    }

                    if let logsErrorMessage = viewModel.logsErrorMessage, !logsErrorMessage.isEmpty {
                        Text(logsErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if filteredLogEntries.isEmpty {
                        Text("No logs matched the current filters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(filteredLogEntries.prefix(120)) { entry in
                                logRow(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
            if tab == .logs {
                viewModel.refreshLogs()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.82))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.045), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func settingsCard<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0.98),
                            Color(nsColor: .textBackgroundColor).opacity(0.93)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.016), radius: 12, x: 0, y: 5)
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

    private func labeledPicker<Value: Hashable>(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 110, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Spacer()
        }
    }

    private func labeledTextEditor(_ title: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 110, alignment: .leading)
                .padding(.top, 8)
            TextEditor(text: text)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(minHeight: minHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                )
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

    private var selectedTabSummaryPrimaryValue: String {
        switch selectedTab {
        case .general:
            return viewModel.draftThemePreference.displayName
        case .models:
            return viewModel.selectedProfile?.name ?? viewModel.draftModel
        case .skills:
            return "\(skillManager.availableSkills.count)"
        case .mcp:
            return "\(viewModel.mcpServers.count)"
        case .logs:
            return "\(viewModel.logEntries.count)"
        case .about:
            return appVersionText
        }
    }

    private var selectedTabSummarySecondaryValue: String {
        switch selectedTab {
        case .general:
            return viewModel.draftRequireCommandReturnToSend ? "⌘↩︎" : "↩︎"
        case .models:
            return "\(viewModel.profiles.count)"
        case .skills:
            return selectedSkillLibraryTab == .standard ? "Standard" : "SkyAgent"
        case .mcp:
            return "\(viewModel.mcpServers.filter { viewModel.mcpState(for: $0.id).lastError == nil && $0.isEnabled }.count)"
        case .logs:
            return "\(Set(viewModel.logEntries.compactMap(\.traceID)).count)"
        case .about:
            return "Paths"
        }
    }

    private func settingsSummaryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
        )
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (.some(version), .some(build)) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        case let (_, .some(build)):
            return build
        default:
            return "Dev Build"
        }
    }

    private func aboutPathRow(title: String, path: String, canOpenFile: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if canOpenFile {
                    Button("打开") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .buttonStyle(.bordered)
                }

                Button("定位") {
                    revealInFinder(path)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private var mcpOverviewPanel: some View {
        HStack(spacing: 10) {
            mcpMetricCard(title: "Servers", value: "\(viewModel.mcpServers.count)", tint: .accentColor)
            mcpMetricCard(title: "Connected", value: "\(viewModel.mcpServers.filter { $0.isEnabled && viewModel.mcpState(for: $0.id).lastError == nil }.count)", tint: .green)
            mcpMetricCard(title: "Project", value: "\(viewModel.mcpServers.filter { $0.scope == .project }.count)", tint: .orange)
            mcpMetricCard(title: "User", value: "\(viewModel.mcpServers.filter { $0.scope == .user }.count)", tint: .secondary, usesTintForValue: false)
        }
    }

    private func mcpMetricCard(title: String, value: String, tint: Color, usesTintForValue: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(usesTintForValue ? tint : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 0.8)
        )
    }

    private var mcpActionBar: some View {
        HStack(spacing: 8) {
            Button(showNewMCPForm ? "Hide New Server" : "New MCP Server") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showNewMCPForm.toggle()
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Refresh MCP") {
                viewModel.refreshMCPTools()
            }
            .buttonStyle(.bordered)

            Button("Import Config") {
                let panel = NSOpenPanel()
                panel.title = "Import MCP Config"
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.json]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.urls.first {
                    viewModel.importMCPServers(from: url)
                }
            }
            .buttonStyle(.bordered)

            Button("Export Config") {
                let panel = NSSavePanel()
                panel.title = "Export MCP Config"
                panel.nameFieldStringValue = "skyagent-mcp-servers.json"
                panel.allowedContentTypes = [.json]
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try viewModel.exportMCPServers(to: url)
                    } catch {
                        mcpManager.lastErrorMessage = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private var mcpConfigLocationsPanel: some View {
        DisclosureGroup(isExpanded: $showMCPConfigPaths) {
            VStack(alignment: .leading, spacing: 12) {
                mcpConfigPathRow(title: "User Config", url: viewModel.mcpUserConfigURL)
                if let projectConfigURL = viewModel.mcpProjectConfigURL {
                    mcpConfigPathRow(title: "Project Config", url: projectConfigURL)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project Config")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("No `.mcp.json` found in the current workspace hierarchy.")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Config Locations")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Spacer()
                Text(showMCPConfigPaths ? "Hide" : "Show")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
        )
    }

    private func mcpConfigPathRow(title: String, url: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(url.path)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button("Open") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)

                    Button("Reveal") {
                        revealInFinder(url.path)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var newMCPServerPanel: some View {
        DisclosureGroup(isExpanded: $showNewMCPForm) {
            VStack(alignment: .leading, spacing: 10) {
                labeledTextField("Server Name", text: $newMCPName)
                labeledPicker("Transport", selection: $newMCPTransportKind, options: MCPTransportKind.allCases) { transport in
                    transport.displayName
                }

                if newMCPTransportKind == .stdio {
                    labeledTextField("Command", text: $newMCPCommand)
                    labeledTextEditor("Arguments", text: $newMCPArguments, minHeight: 72)
                    labeledTextEditor("Environment", text: $newMCPEnvironment, minHeight: 72)
                    labeledTextField("Working Dir", text: $newMCPWorkingDirectory)
                } else {
                    labeledTextField("Endpoint URL", text: $newMCPEndpointURL)
                    labeledPicker("Auth", selection: $newMCPAuthKind, options: MCPAuthorizationKind.allCases) { kind in
                        kind.displayName
                    }
                    if newMCPAuthKind != .none {
                        labeledSecureField("Auth Token", text: $newMCPAuthToken)
                    }
                    if newMCPAuthKind == .customHeader {
                        labeledTextField("Header Name", text: $newMCPAuthHeaderName)
                    }
                    labeledTextEditor("Extra Headers", text: $newMCPAdditionalHeaders, minHeight: 72)
                }

                DisclosureGroup("Advanced Access Rules") {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledPicker("Tool Access", selection: $newMCPToolExecutionPolicy, options: MCPToolExecutionPolicy.allCases) { policy in
                            policy.displayName
                        }
                        labeledTextEditor("Allowed Tools", text: $newMCPAllowedTools, minHeight: 54)
                        labeledTextEditor("Blocked Tools", text: $newMCPBlockedTools, minHeight: 54)
                    }
                    .padding(.top, 8)
                }

                HStack {
                    Spacer()

                    Button("Reset") {
                        resetNewMCPDraft()
                    }
                    .buttonStyle(.bordered)

                    Button("Add MCP Server") {
                        viewModel.addMCPServer(
                            name: newMCPName,
                            transportKind: newMCPTransportKind,
                            command: newMCPCommand,
                            argumentsText: newMCPArguments,
                            environmentText: newMCPEnvironment,
                            workingDirectory: newMCPWorkingDirectory,
                            endpointURL: newMCPEndpointURL,
                            authKind: newMCPAuthKind,
                            authToken: newMCPAuthToken,
                            authHeaderName: newMCPAuthHeaderName,
                            additionalHeadersText: newMCPAdditionalHeaders,
                            toolExecutionPolicy: newMCPToolExecutionPolicy,
                            allowedToolsText: newMCPAllowedTools,
                            blockedToolsText: newMCPBlockedTools
                        )
                        resetNewMCPDraft()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showNewMCPForm = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Add Server")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Spacer()
                Text(showNewMCPForm ? "Hide" : "Show")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
        )
    }

    private func mcpServerRow(_ server: MCPServerConfig, isEditing: Bool) -> some View {
        let state = viewModel.mcpState(for: server.id)

        let tools = viewModel.mcpTools(for: server.id)
        let resources = viewModel.mcpResources(for: server.id)
        let prompts = viewModel.mcpPrompts(for: server.id)
        let logs = viewModel.mcpLogs(for: server.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(server.name)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))

                        Text(server.scope.displayName)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text(mcpStatusText(server: server, state: state))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(mcpStatusColor(state: state, isEnabled: server.isEnabled))
                    Text(server.connectionSummary)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(isEditing ? "Close" : "Edit") {
                    guard server.scope == .user else { return }
                    if isEditing {
                        clearEditingMCPServer()
                    } else {
                        beginEditingMCPServer(server)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(server.scope != .user)

                Button("Remove") {
                    guard server.scope == .user else { return }
                    if editingMCPServerID == server.id {
                        clearEditingMCPServer()
                    }
                    viewModel.removeMCPServer(server.id)
                }
                .buttonStyle(.bordered)
                .disabled(server.scope != .user)
            }

            HStack(spacing: 8) {
                Text(server.transportKind.displayName)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(state.toolCount) tools")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(state.resourceCount) resources")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(state.promptCount) prompts")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if server.scope == .project {
                Text("This server is loaded from the current project’s `.mcp.json` and follows project-scope precedence. Edit the project config file to change it.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if isEditing {
                Divider()
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup(isExpanded: $editMCPShowConnectionDetails) {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledTextField("Server Name", text: $editMCPName)
                            labeledPicker("Transport", selection: $editMCPTransportKind, options: MCPTransportKind.allCases) { transport in
                                transport.displayName
                            }

                            if editMCPTransportKind == .stdio {
                                labeledTextField("Command", text: $editMCPCommand)
                                labeledTextEditor("Arguments", text: $editMCPArguments, minHeight: 72)
                                labeledTextEditor("Environment", text: $editMCPEnvironment, minHeight: 72)
                                labeledTextField("Working Dir", text: $editMCPWorkingDirectory)
                            } else {
                                labeledTextField("Endpoint URL", text: $editMCPEndpointURL)
                                labeledPicker("Auth", selection: $editMCPAuthKind, options: MCPAuthorizationKind.allCases) { kind in
                                    kind.displayName
                                }
                                if editMCPAuthKind != .none {
                                    labeledSecureField("Auth Token", text: $editMCPAuthToken)
                                }
                                if editMCPAuthKind == .customHeader {
                                    labeledTextField("Header Name", text: $editMCPAuthHeaderName)
                                }
                                labeledTextEditor("Extra Headers", text: $editMCPAdditionalHeaders, minHeight: 72)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        sectionDisclosureLabel("Connection Details", subtitle: "名称、传输方式、命令或远程 endpoint。")
                    }

                    DisclosureGroup(isExpanded: $editMCPShowToolRules) {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledPicker("Tool Access", selection: $editMCPToolExecutionPolicy, options: MCPToolExecutionPolicy.allCases) { policy in
                                policy.displayName
                            }
                            labeledTextEditor("Allowed Tools", text: $editMCPAllowedTools, minHeight: 54)
                            labeledTextEditor("Blocked Tools", text: $editMCPBlockedTools, minHeight: 54)

                            if !tools.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("Tool Rules")
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                        Text("Pick per-tool Allow / Block / Default without manually typing names.")
                                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                            .foregroundStyle(.tertiary)
                                    }

                                    ForEach(tools) { tool in
                                        mcpToolRuleRow(tool, serverID: server.id)
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        sectionDisclosureLabel("Access Rules", subtitle: "默认策略、白名单、黑名单和逐工具覆盖。")
                    }

                    HStack(spacing: 10) {
                        Toggle("Enabled", isOn: Binding(
                            get: { server.isEnabled },
                            set: { viewModel.setMCPServerEnabled($0, serverID: server.id) }
                        ))
                        .toggleStyle(.switch)
                        .disabled(server.scope != .user)

                        Spacer()

                        Button("Cancel") {
                            clearEditingMCPServer()
                        }
                        .buttonStyle(.bordered)

                        Button("Save Changes") {
                            viewModel.updateMCPServer(
                                serverID: server.id,
                                name: editMCPName,
                                transportKind: editMCPTransportKind,
                                command: editMCPCommand,
                                argumentsText: editMCPArguments,
                                environmentText: editMCPEnvironment,
                                workingDirectory: editMCPWorkingDirectory,
                                endpointURL: editMCPEndpointURL,
                                authKind: editMCPAuthKind,
                                authToken: editMCPAuthToken,
                                authHeaderName: editMCPAuthHeaderName,
                                additionalHeadersText: editMCPAdditionalHeaders,
                                toolExecutionPolicy: editMCPToolExecutionPolicy,
                                allowedToolsText: editMCPAllowedTools,
                                blockedToolsText: editMCPBlockedTools
                            )
                            clearEditingMCPServer()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let error = state.lastError, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                    }

                    if !server.additionalHeaders.isEmpty {
                        Text("Extra headers: \(server.additionalHeaders.keys.sorted().joined(separator: ", "))")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if !server.secretAdditionalHeaderNames.isEmpty {
                        Text("Secure headers: \(server.secretAdditionalHeaderNames.sorted().joined(separator: ", "))")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if !tools.isEmpty || !resources.isEmpty || !prompts.isEmpty {
                        DisclosureGroup(isExpanded: $editMCPShowCapabilities) {
                            VStack(alignment: .leading, spacing: 8) {
                                mcpCapabilitySection("Tools", items: tools.prefix(6).map { tool in
                                    tool.toolDescription.isEmpty ? tool.toolName : "\(tool.toolName) - \(tool.toolDescription)"
                                })
                                mcpCapabilitySection("Resources", items: resources.prefix(6).map { resource in
                                    resource.uri == resource.name ? resource.name : "\(resource.name) - \(resource.uri)"
                                })
                                mcpCapabilitySection("Prompts", items: prompts.prefix(6).map { prompt in
                                    if prompt.arguments.isEmpty {
                                        return prompt.name
                                    }
                                    let argNames = prompt.arguments.map(\.name).joined(separator: ", ")
                                    return "\(prompt.name) - \(argNames)"
                                })
                            }
                            .padding(.top, 8)
                        } label: {
                            sectionDisclosureLabel("Capabilities", subtitle: "查看当前 server 已暴露的 tools、resources 和 prompts。")
                        }
                    }

                    if !tools.isEmpty || !resources.isEmpty || !prompts.isEmpty {
                        DisclosureGroup(isExpanded: $editMCPShowTesting) {
                            mcpTestConsole(server: server, tools: tools, resources: resources, prompts: prompts)
                                .padding(.top, 8)
                        } label: {
                            sectionDisclosureLabel("Test Console", subtitle: "只在排查问题时展开，避免编辑时信息过载。")
                        }
                    }

                    if !logs.isEmpty {
                        DisclosureGroup(isExpanded: $editMCPShowLogs) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(logs.prefix(4)) { log in
                                    mcpLogRow(log)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            sectionDisclosureLabel("Recent Calls", subtitle: "最近几次 discovery / tool call / prompt 记录。")
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
        )
    }

    private func beginEditingMCPServer(_ server: MCPServerConfig) {
        let editableServer = viewModel.editableMCPServer(server.id) ?? server
        editingMCPServerID = server.id
        editMCPShowConnectionDetails = true
        editMCPShowToolRules = false
        editMCPShowCapabilities = false
        editMCPShowTesting = false
        editMCPShowLogs = false
        editMCPName = editableServer.name
        editMCPTransportKind = editableServer.transportKind
        editMCPCommand = editableServer.command
        editMCPArguments = editableServer.arguments.joined(separator: "\n")
        editMCPEnvironment = formattedKeyValueText(from: editableServer.environment)
        editMCPWorkingDirectory = editableServer.workingDirectory
        editMCPEndpointURL = editableServer.endpointURL
        editMCPAuthKind = editableServer.authKind
        editMCPAuthToken = editableServer.authToken
        editMCPAuthHeaderName = editableServer.authHeaderName
        editMCPAdditionalHeaders = formattedKeyValueText(from: editableServer.additionalHeaders)
        editMCPToolExecutionPolicy = editableServer.toolExecutionPolicy
        editMCPAllowedTools = editableServer.allowedToolNames.joined(separator: "\n")
        editMCPBlockedTools = editableServer.blockedToolNames.joined(separator: "\n")
    }

    private func clearEditingMCPServer() {
        editingMCPServerID = nil
        editMCPShowConnectionDetails = true
        editMCPShowToolRules = false
        editMCPShowCapabilities = false
        editMCPShowTesting = false
        editMCPShowLogs = false
        editMCPName = ""
        editMCPTransportKind = .stdio
        editMCPCommand = ""
        editMCPArguments = ""
        editMCPEnvironment = ""
        editMCPWorkingDirectory = ""
        editMCPEndpointURL = ""
        editMCPAuthKind = .none
        editMCPAuthToken = ""
        editMCPAuthHeaderName = ""
        editMCPAdditionalHeaders = ""
        editMCPToolExecutionPolicy = .allowAll
        editMCPAllowedTools = ""
        editMCPBlockedTools = ""
    }

    private func resetNewMCPDraft() {
        newMCPName = ""
        newMCPTransportKind = .stdio
        newMCPCommand = ""
        newMCPArguments = ""
        newMCPEnvironment = ""
        newMCPWorkingDirectory = ""
        newMCPEndpointURL = ""
        newMCPAuthKind = .none
        newMCPAuthToken = ""
        newMCPAuthHeaderName = ""
        newMCPAdditionalHeaders = ""
        newMCPToolExecutionPolicy = .allowAll
        newMCPAllowedTools = ""
        newMCPBlockedTools = ""
    }

    private func formattedKeyValueText(from values: [String: String]) -> String {
        values.keys.sorted().compactMap { key in
            guard let value = values[key] else { return nil }
            return "\(key)=\(value)"
        }
        .joined(separator: "\n")
    }

    private func mcpStatusText(server: MCPServerConfig, state: MCPServerRuntimeState) -> String {
        if !server.isEnabled {
            return "Disabled"
        }
        if state.isRefreshing {
            return "Refreshing"
        }
        if let error = state.lastError, !error.isEmpty {
            return "Error"
        }
        return "Connected"
    }

    private func mcpStatusColor(state: MCPServerRuntimeState, isEnabled: Bool) -> Color {
        if !isEnabled {
            return .secondary
        }
        if state.isRefreshing {
            return .orange
        }
        if let error = state.lastError, !error.isEmpty {
            return .red
        }
        return .green
    }

    private func sectionDisclosureLabel(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var logCategories: [String] {
        Array(Set(viewModel.logEntries.map(\.category))).sorted()
    }

    private var filteredLogEntries: [PersistedLogEvent] {
        viewModel.logEntries.filter { entry in
            let categoryMatches = selectedLogCategory == "all" || entry.category == selectedLogCategory
            let normalizedTraceFilter = activeLogTraceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let traceMatches = normalizedTraceFilter.isEmpty
                || entry.traceID?.localizedCaseInsensitiveContains(normalizedTraceFilter) == true
            let quickFilterMatches: Bool
            switch selectedLogQuickFilter {
            case .all:
                quickFilterMatches = true
            case .errors:
                quickFilterMatches = entry.level.lowercased() == "error"
            case .timeouts:
                quickFilterMatches = isTimeoutLog(entry)
            case .slow:
                quickFilterMatches = (entry.durationMs ?? 0) >= 1_000
            }
            let search = logSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches: Bool
            if search.isEmpty {
                searchMatches = true
            } else {
                let haystack = [
                    entry.summary,
                    entry.event,
                    entry.category,
                    entry.level,
                    entry.status ?? "",
                    entry.traceID ?? "",
                    entry.operationID ?? "",
                    entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                ].joined(separator: " ")
                searchMatches = haystack.localizedCaseInsensitiveContains(search)
            }
            return categoryMatches && traceMatches && quickFilterMatches && searchMatches
        }
    }

    private var activeLogTraceID: String? {
        let manualFilter = logTraceFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualFilter.isEmpty {
            return manualFilter
        }
        return selectedLogTraceID
    }

    private func traceLogEntries(traceID: String) -> [PersistedLogEvent] {
        viewModel.logEntries
            .filter { $0.traceID == traceID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func traceTimingSummary(traceID: String) -> TraceTimingSummary {
        let entries = traceLogEntries(traceID: traceID)

        func latestDuration(for eventNames: Set<String>) -> Int? {
            entries
                .reversed()
                .first(where: { eventNames.contains($0.event) && $0.durationMs != nil })
                .flatMap { $0.durationMs.map(Int.init) }
        }

        func maxDuration(where predicate: (PersistedLogEvent) -> Bool) -> Int? {
            entries
                .filter(predicate)
                .compactMap(\.durationMs)
                .max()
                .map(Int.init)
        }

        return TraceTimingSummary(
            firstTokenMs: latestDuration(for: ["llm_first_token_received"]),
            llmTotalMs: latestDuration(for: ["llm_stream_finished", "llm_request_failed"]),
            longestToolMs: maxDuration {
                ($0.event == "tool_completed" || $0.event == "tool_failed" || $0.event == "tool_skipped_repeat")
                    && $0.operationID != nil
            },
            mcpInitializeMs: latestDuration(for: ["mcp_initialize_completed", "mcp_initialize_failed"]),
            skillScriptMs: latestDuration(for: ["skill_script_completed", "skill_script_failed", "skill_script_timeout"]),
            shellMs: latestDuration(for: ["shell_completed", "shell_failed", "shell_timeout"])
        )
    }

    private func traceStageSummaries(traceID: String) -> [TraceStageSummary] {
        let entries = traceLogEntries(traceID: traceID)

        func firstEvent(_ names: Set<String>) -> PersistedLogEvent? {
            entries.first(where: { names.contains($0.event) })
        }

        func lastEvent(_ names: Set<String>) -> PersistedLogEvent? {
            entries.last(where: { names.contains($0.event) })
        }

        let contextFinished = lastEvent(["context_prepare_finished"])
        let memoryBuiltCount = entries.filter { $0.event == "memory_context_built" }.count
        let contextSubtitle: String
        if let contextFinished, let durationMs = contextFinished.durationMs {
            contextSubtitle = memoryBuiltCount > 0 ? "ready in \(Int(durationMs)) ms · memory \(memoryBuiltCount)" : "ready in \(Int(durationMs)) ms"
        } else if firstEvent(["context_prepare_started"]) != nil {
            contextSubtitle = "building context"
        } else {
            contextSubtitle = "not recorded"
        }

        let firstToken = lastEvent(["llm_first_token_received"])
        let llmFinished = lastEvent(["llm_stream_finished"])
        let llmFailed = lastEvent(["llm_request_failed"])
        let llmSubtitle: String
        let llmTint: Color
        if let llmFailed, let durationMs = llmFailed.durationMs {
            llmSubtitle = "failed in \(Int(durationMs)) ms"
            llmTint = .red
        } else if let llmFinished {
            let firstTokenText = firstToken?.durationMs.map { "first \($0.formattedMilliseconds)" } ?? "first —"
            let totalText = llmFinished.durationMs.map { "total \($0.formattedMilliseconds)" } ?? "total —"
            llmSubtitle = "\(firstTokenText) · \(totalText)"
            llmTint = .green
        } else if firstEvent(["llm_request_started"]) != nil {
            llmSubtitle = firstToken?.durationMs.map { "first \($0.formattedMilliseconds)" } ?? "waiting first token"
            llmTint = .accentColor
        } else {
            llmSubtitle = "not requested"
            llmTint = .secondary
        }

        let executionEntries = entries.filter {
            $0.event == "tool_started"
            || $0.event == "tool_completed"
            || $0.event == "tool_failed"
            || $0.event == "tool_skipped_repeat"
            || $0.event == "skill_script_started"
            || $0.event == "skill_script_completed"
            || $0.event == "skill_script_failed"
            || $0.event == "skill_script_timeout"
            || $0.event == "shell_started"
            || $0.event == "shell_completed"
            || $0.event == "shell_failed"
            || $0.event == "shell_timeout"
            || $0.event == "mcp_initialize_started"
            || $0.event == "mcp_initialize_completed"
            || $0.event == "mcp_initialize_failed"
        }
        let executionCount = Set(executionEntries.compactMap(\.operationID)).count
        let maxExecutionMs = executionEntries.compactMap(\.durationMs).max().map(Int.init)
        let executionSubtitle: String
        let executionTint: Color
        if executionEntries.contains(where: { $0.level.lowercased() == "error" || $0.status == "failed" || $0.status == "timeout" }) {
            executionSubtitle = executionCount > 0 ? "\(executionCount) ops · max \(maxExecutionMs.map { "\($0) ms" } ?? "—")" : "failed"
            executionTint = .red
        } else if !executionEntries.isEmpty {
            executionSubtitle = executionCount > 0 ? "\(executionCount) ops · max \(maxExecutionMs.map { "\($0) ms" } ?? "—")" : "in progress"
            executionTint = .orange
        } else {
            executionSubtitle = "no tools used"
            executionTint = .secondary
        }

        let finished = lastEvent(["assistant_turn_finished"])
        let failed = lastEvent(["assistant_turn_failed"])
        let completionSubtitle: String
        let completionTint: Color
        if let failed, let durationMs = failed.durationMs {
            completionSubtitle = "failed in \(Int(durationMs)) ms"
            completionTint = .red
        } else if let finished, let durationMs = finished.durationMs {
            completionSubtitle = "done in \(Int(durationMs)) ms"
            completionTint = .green
        } else {
            completionSubtitle = "still running"
            completionTint = .secondary
        }

        return [
            TraceStageSummary(id: "context", title: "Context", subtitle: contextSubtitle, tint: contextFinished == nil && firstEvent(["context_prepare_started"]) == nil ? .secondary : .accentColor),
            TraceStageSummary(id: "llm", title: "LLM", subtitle: llmSubtitle, tint: llmTint),
            TraceStageSummary(id: "execution", title: "Execution", subtitle: executionSubtitle, tint: executionTint),
            TraceStageSummary(id: "finish", title: "Done", subtitle: completionSubtitle, tint: completionTint)
        ]
    }

    private func slowTraceSummaries(limit: Int = 6) -> [SlowTraceSummary] {
        let grouped = Dictionary(grouping: viewModel.logEntries.compactMap { entry -> (String, PersistedLogEvent)? in
            guard let traceID = entry.traceID, !traceID.isEmpty else { return nil }
            return (traceID, entry)
        }, by: \.0)

        return grouped.compactMap { traceID, pairs in
            let entries = pairs.map(\.1).sorted { $0.timestamp < $1.timestamp }
            guard let first = entries.first, let last = entries.last else { return nil }
            let durationMs = Int(max(0, last.timestamp.timeIntervalSince(first.timestamp) * 1_000))
            guard durationMs > 0 else { return nil }
            return SlowTraceSummary(
                id: traceID,
                traceID: traceID,
                durationMs: durationMs,
                eventCount: entries.count,
                errorCount: entries.filter { $0.level.lowercased() == "error" }.count,
                timeoutCount: entries.filter(isTimeoutLog(_:)).count,
                startedAt: first.timestamp
            )
        }
        .sorted {
            if $0.durationMs == $1.durationMs {
                return $0.startedAt > $1.startedAt
            }
            return $0.durationMs > $1.durationMs
        }
        .prefix(limit)
        .map { $0 }
    }

    private func isTimeoutLog(_ entry: PersistedLogEvent) -> Bool {
        if entry.status?.lowercased() == "timeout" {
            return true
        }
        let haystack = [
            entry.event,
            entry.summary,
            entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        ].joined(separator: " ").lowercased()
        return haystack.contains("timeout") || haystack.contains("timed out")
    }

    private func logQuickFilterButton(_ filter: LogQuickFilter) -> some View {
        let isSelected = selectedLogQuickFilter == filter
        return Button(filter.title) {
            selectedLogQuickFilter = filter
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045))
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
    }

    private func logTracePanel(traceID: String) -> some View {
        let entries = traceLogEntries(traceID: traceID)
        let errorCount = entries.filter { $0.level.lowercased() == "error" }.count
        let timeoutCount = entries.filter(isTimeoutLog(_:)).count
        let totalDuration = max(0, (entries.last?.timestamp.timeIntervalSince(entries.first?.timestamp ?? Date()) ?? 0) * 1_000)
        let timing = traceTimingSummary(traceID: traceID)
        let stageSummaries = traceStageSummaries(traceID: traceID)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trace Focus")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(traceID)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button("Only Errors") {
                    selectedLogTraceID = traceID
                    logTraceFilter = traceID
                    selectedLogQuickFilter = .errors
                }
                .buttonStyle(.bordered)

                Button("Clear Trace") {
                    selectedLogTraceID = nil
                    logTraceFilter = ""
                    selectedLogQuickFilter = .all
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                mcpMetricCard(title: "Events", value: "\(entries.count)", tint: .accentColor)
                mcpMetricCard(title: "Errors", value: "\(errorCount)", tint: .red)
                mcpMetricCard(title: "Timeouts", value: "\(timeoutCount)", tint: .orange)
                mcpMetricCard(title: "Span", value: "\(Int(totalDuration)) ms", tint: .green)
            }

            HStack(spacing: 10) {
                mcpMetricCard(title: "First Token", value: timing.firstTokenMs.map { "\($0) ms" } ?? "—", tint: .accentColor)
                mcpMetricCard(title: "LLM Total", value: timing.llmTotalMs.map { "\($0) ms" } ?? "—", tint: .green)
                mcpMetricCard(title: "Longest Tool", value: timing.longestToolMs.map { "\($0) ms" } ?? "—", tint: .orange)
            }

            HStack(spacing: 10) {
                mcpMetricCard(title: "MCP Init", value: timing.mcpInitializeMs.map { "\($0) ms" } ?? "—", tint: .secondary, usesTintForValue: false)
                mcpMetricCard(title: "Skill Script", value: timing.skillScriptMs.map { "\($0) ms" } ?? "—", tint: .purple)
                mcpMetricCard(title: "Shell", value: timing.shellMs.map { "\($0) ms" } ?? "—", tint: .pink)
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(stageSummaries.enumerated()), id: \.element.id) { index, stage in
                    traceStageCard(stage)

                    if index < stageSummaries.count - 1 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 16)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries.suffix(12)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(logLevelColor(entry.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("\(entry.category) · \(entry.event)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                Text(entry.formattedTimestamp)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let durationMs = entry.durationMs {
                                    Text("\(Int(durationMs)) ms")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(entry.summary)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.82))
                                .lineLimit(2)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 0.8)
        )
    }

    private func traceStageCard(_ stage: TraceStageSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stage.title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(stage.tint)
            Text(stage.subtitle)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(stage.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(stage.tint.opacity(0.14), lineWidth: 0.8)
        )
    }

    private func logSlowTracesPanel(_ traces: [SlowTraceSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Slowest Traces")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("优先聚焦跨度最长的几轮请求，快速判断慢点主要落在上下文、LLM 还是执行链。")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(traces) { trace in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trace.traceID)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(trace.durationMs) ms · \(trace.eventCount) events · \(trace.errorCount) errors · \(trace.timeoutCount) timeouts")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Focus") {
                            selectedLogTraceID = trace.traceID
                            logTraceFilter = trace.traceID
                        }
                        .buttonStyle(.bordered)

                        Button("Copy") {
                            copyToPasteboard(trace.traceID)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.1), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func mcpCapabilitySection(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(2)
                }
            }
        }
    }

    private func mcpLogRow(_ log: MCPActivityLog) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(mcpLogColor(log.status))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(log.action) · \(log.target)")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    Text(RelativeDateTimeFormatter().localizedString(for: log.createdAt, relativeTo: Date()))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(log.detail)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let durationMilliseconds = log.durationMilliseconds {
                    Text("\(durationMilliseconds) ms")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func logRow(_ entry: PersistedLogEvent) -> some View {
        let isExpanded = expandedLogIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(logLevelColor(entry.level))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(entry.category) · \(entry.event)")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        Text(entry.formattedTimestamp)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let status = entry.status, !status.isEmpty {
                            Text(status)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        if let durationMs = entry.durationMs {
                            Text("\(Int(durationMs)) ms")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(entry.summary)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.86))

                    HStack(spacing: 8) {
                        Text(entry.level.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(logLevelColor(entry.level))
                    if let traceID = entry.traceID, !traceID.isEmpty {
                        Button {
                            selectedLogTraceID = traceID
                            logTraceFilter = traceID
                            } label: {
                                Text(traceID)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Button("Copy") {
                        copyLogEntry(entry)
                    }
                    .buttonStyle(.bordered)

                    if entry.traceID != nil {
                        Button("Trace") {
                            selectedLogTraceID = entry.traceID
                            logTraceFilter = entry.traceID ?? ""
                        }
                        .buttonStyle(.bordered)

                        Button("Copy Trace") {
                            copyToPasteboard(entry.traceID ?? "")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(isExpanded ? "Hide" : "Show") {
                        if isExpanded {
                            expandedLogIDs.remove(entry.id)
                        } else {
                            expandedLogIDs.insert(entry.id)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let conversationID = entry.conversationID, !conversationID.isEmpty {
                        logMetaLine("conversation", conversationID)
                    }
                    if let operationID = entry.operationID, !operationID.isEmpty {
                        logMetaLine("operation", operationID)
                    }
                    if let requestID = entry.requestID, !requestID.isEmpty {
                        logMetaLine("request", requestID)
                    }
                    ForEach(entry.metadata.keys.sorted(), id: \.self) { key in
                        if let value = entry.metadata[key], !value.isEmpty {
                            logMetaLine(key, value)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 0.8)
        )
    }

    private func logMetaLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .textSelection(.enabled)
        }
    }

    private func copyLogEntry(_ entry: PersistedLogEvent) {
        var lines: [String] = [
            "category: \(entry.category)",
            "event: \(entry.event)",
            "level: \(entry.level)",
            "timestamp: \(entry.formattedTimestamp)",
            "summary: \(entry.summary)"
        ]

        if let traceID = entry.traceID, !traceID.isEmpty {
            lines.append("trace_id: \(traceID)")
        }
        if let status = entry.status, !status.isEmpty {
            lines.append("status: \(status)")
        }
        if let durationMs = entry.durationMs {
            lines.append("duration_ms: \(Int(durationMs))")
        }
        if let conversationID = entry.conversationID, !conversationID.isEmpty {
            lines.append("conversation_id: \(conversationID)")
        }
        if let operationID = entry.operationID, !operationID.isEmpty {
            lines.append("operation_id: \(operationID)")
        }
        if let requestID = entry.requestID, !requestID.isEmpty {
            lines.append("request_id: \(requestID)")
        }
        if !entry.metadata.isEmpty {
            lines.append("metadata:")
            for key in entry.metadata.keys.sorted() {
                if let value = entry.metadata[key], !value.isEmpty {
                    lines.append("  \(key): \(value)")
                }
            }
        }

        copyToPasteboard(lines.joined(separator: "\n"))
    }

    private func logLevelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error":
            return .red
        case "warn":
            return .orange
        case "debug":
            return .secondary
        default:
            return .accentColor
        }
    }

    private func mcpToolRuleRow(_ tool: MCPToolDescriptor, serverID: UUID) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.toolName)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                if !tool.toolDescription.isEmpty {
                    Text(tool.toolDescription)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Picker(
                "",
                selection: Binding(
                    get: { viewModel.mcpToolRuleSelection(for: tool.toolName, serverID: serverID) },
                    set: { viewModel.setMCPToolRuleSelection($0, toolName: tool.toolName, serverID: serverID) }
                )
            ) {
                ForEach(MCPToolRuleSelection.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 108, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 0.8)
        )
    }

    private func mcpTestConsole(
        server: MCPServerConfig,
        tools: [MCPToolDescriptor],
        resources: [MCPResourceDescriptor],
        prompts: [MCPPromptDescriptor]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Test Console")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("Run a tool, read a resource, or resolve a prompt directly from settings.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tool Test")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Picker(
                        "",
                        selection: Binding(
                            get: { mcpSelectedToolCallNames[server.id] ?? tools.first?.callName ?? "" },
                            set: { mcpSelectedToolCallNames[server.id] = $0 }
                        )
                    ) {
                        ForEach(tools) { tool in
                            Text(tool.toolName).tag(tool.callName)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    TextEditor(
                        text: Binding(
                            get: { mcpToolTestArguments[server.id] ?? "{}" },
                            set: { mcpToolTestArguments[server.id] = $0 }
                        )
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
                    )

                    HStack {
                        Button("Run Tool") {
                            let callName = mcpSelectedToolCallNames[server.id] ?? tools.first?.callName ?? ""
                            guard !callName.isEmpty else { return }
                            let arguments = mcpToolTestArguments[server.id] ?? "{}"
                            Task { @MainActor in
                                mcpRunningTests.insert(server.id)
                                let result = await viewModel.runMCPToolTest(callName: callName, arguments: arguments)
                                mcpTestResults[server.id] = result
                                mcpRunningTests.remove(server.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(mcpRunningTests.contains(server.id))
                        Spacer()
                    }
                }
            }

            if !resources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resource Test")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Picker(
                        "",
                        selection: Binding(
                            get: { mcpSelectedResourceURIs[server.id] ?? resources.first?.uri ?? "" },
                            set: { mcpSelectedResourceURIs[server.id] = $0 }
                        )
                    ) {
                        ForEach(resources) { resource in
                            Text(resource.name).tag(resource.uri)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    HStack {
                        Button("Read Resource") {
                            let uri = mcpSelectedResourceURIs[server.id] ?? resources.first?.uri ?? ""
                            guard !uri.isEmpty else { return }
                            Task { @MainActor in
                                mcpRunningTests.insert(server.id)
                                let result = await viewModel.runMCPResourceTest(serverID: server.id, uri: uri)
                                mcpTestResults[server.id] = result
                                mcpRunningTests.remove(server.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(mcpRunningTests.contains(server.id))
                        Spacer()
                    }
                }
            }

            if !prompts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt Test")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Picker(
                        "",
                        selection: Binding(
                            get: { mcpSelectedPromptNames[server.id] ?? prompts.first?.name ?? "" },
                            set: { mcpSelectedPromptNames[server.id] = $0 }
                        )
                    ) {
                        ForEach(prompts) { prompt in
                            Text(prompt.name).tag(prompt.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    TextEditor(
                        text: Binding(
                            get: { mcpPromptTestArguments[server.id] ?? "{}" },
                            set: { mcpPromptTestArguments[server.id] = $0 }
                        )
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
                    )

                    HStack {
                        Button("Resolve Prompt") {
                            let name = mcpSelectedPromptNames[server.id] ?? prompts.first?.name ?? ""
                            guard !name.isEmpty else { return }
                            let arguments = mcpPromptTestArguments[server.id] ?? "{}"
                            Task { @MainActor in
                                mcpRunningTests.insert(server.id)
                                let result = await viewModel.runMCPPromptTest(serverID: server.id, name: name, arguments: arguments)
                                mcpTestResults[server.id] = result
                                mcpRunningTests.remove(server.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(mcpRunningTests.contains(server.id))
                        Spacer()
                    }
                }
            }

            if let result = mcpTestResults[server.id], !result.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last Result")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if mcpRunningTests.contains(server.id) {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    ScrollView {
                        Text(result)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 100, maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 0.8)
                    )
                }
            }
        }
    }

    private func mcpLogColor(_ status: MCPActivityStatus) -> Color {
        switch status {
        case .success:
            return .green
        case .failed:
            return .orange
        case .denied:
            return .red
        }
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
            "args": []
          }
        }
        """
    }
}

import SwiftUI
import AppKit

struct NewConversationSheet: View {
    let onComplete: (FilePermissionMode, String) -> Void

    @State private var permissionMode: FilePermissionMode = .sandbox
    @State private var sandboxDir: String = ""
    @Environment(\.dismiss) private var dismiss

    private var defaultSandboxDir: String {
        AppStoragePaths.prepareDataDirectories()
        return AppStoragePaths.workspaceDir.path
    }

    var body: some View {
        VStack(spacing: 20) {
            // 标题
            VStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text(L10n.tr("new_conversation.title"))
                    .font(.title2.bold())
                Text(L10n.tr("new_conversation.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            // 权限模式选择
            VStack(spacing: 12) {
                permissionCard(
                    mode: .sandbox,
                    icon: "lock.shield",
                    title: L10n.tr("permission.sandbox"),
                    desc: L10n.tr("new_conversation.permission.sandbox"),
                    color: .blue
                )

                permissionCard(
                    mode: .open,
                    icon: "lock.open",
                    title: L10n.tr("permission.open"),
                    desc: L10n.tr("new_conversation.permission.open"),
                    color: .orange
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("new_conversation.workdir"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField(L10n.tr("new_conversation.workdir.placeholder"), text: $sandboxDir)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))

                    Button(L10n.tr("common.choose")) {
                        chooseDirectory()
                    }
                    .buttonStyle(.bordered)
                }

                Text(permissionMode == .sandbox
                    ? L10n.tr("new_conversation.workdir.sandbox_hint")
                    : L10n.tr("new_conversation.workdir.open_hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            Divider()

            // 底部按钮
            HStack {
                Button(L10n.tr("common.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("new_conversation.start")) {
                    let dir = sandboxDir.isEmpty ? defaultSandboxDir : sandboxDir
                    onComplete(permissionMode, dir)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            sandboxDir = defaultSandboxDir
        }
    }

    private func permissionCard(mode: FilePermissionMode, icon: String, title: String, desc: String, color: Color) -> some View {
        let isSelected = permissionMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                permissionMode = mode
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? color : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(color)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? color.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("panel.choose_workdir.title")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: sandboxDir.isEmpty ? defaultSandboxDir : sandboxDir)
        if panel.runModal() == .OK, let url = panel.urls.first {
            sandboxDir = url.path
        }
    }

}

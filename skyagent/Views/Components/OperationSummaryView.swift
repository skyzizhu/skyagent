import SwiftUI
import AppKit

struct OperationSummaryView: View {
    let operations: [FileOperationRecord]
    let onInspect: (FileOperationRecord) -> Void
    let onReveal: (FileOperationRecord) -> Void
    let onUndo: (String) -> Void

    private var displayedOperations: [FileOperationRecord] {
        Array(operations.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("最近操作", systemImage: "checklist")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("最多展示 5 条")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                ForEach(Array(displayedOperations.enumerated()), id: \.element.id) { index, operation in
                    OperationRowView(
                        operation: operation,
                        iconName: iconName(for: operation),
                        onInspect: onInspect,
                        onReveal: onReveal,
                        onUndo: onUndo
                    )

                    if index < displayedOperations.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.04))
                            .frame(height: 0.6)
                            .padding(.leading, 12)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Rectangle()
                .fill(Color.clear)
        )
    }

    private func iconName(for operation: FileOperationRecord) -> String {
        switch operation.toolName {
        case ToolDefinition.ToolName.writeFile.rawValue:
            return "square.and.pencil"
        case ToolDefinition.ToolName.writeMultipleFiles.rawValue:
            return "square.stack.3d.up.fill"
        case ToolDefinition.ToolName.writeDOCX.rawValue:
            return "doc.text.fill"
        case ToolDefinition.ToolName.writeXLSX.rawValue:
            return "tablecells.fill"
        case ToolDefinition.ToolName.replaceDOCXSection.rawValue:
            return "doc.text.magnifyingglass"
        case ToolDefinition.ToolName.insertDOCXSection.rawValue:
            return "text.insert"
        case ToolDefinition.ToolName.appendXLSXRows.rawValue:
            return "tablecells.badge.ellipsis"
        case ToolDefinition.ToolName.updateXLSXCell.rawValue:
            return "tablecells.badge.minus"
        case ToolDefinition.ToolName.importFile.rawValue, ToolDefinition.ToolName.importDirectory.rawValue:
            return "square.and.arrow.down"
        case ToolDefinition.ToolName.exportFile.rawValue, ToolDefinition.ToolName.exportDirectory.rawValue:
            return "square.and.arrow.up"
        case ToolDefinition.ToolName.exportPDF.rawValue:
            return "doc.richtext"
        case ToolDefinition.ToolName.exportDOCX.rawValue:
            return "doc.text"
        case ToolDefinition.ToolName.exportXLSX.rawValue:
            return "tablecells"
        case ToolDefinition.ToolName.installSkill.rawValue:
            return "square.and.arrow.down.on.square"
        case ToolDefinition.ToolName.runSkillScript.rawValue:
            return "play.rectangle"
        default:
            return "doc"
        }
    }
}

private struct OperationRowView: View {
    let operation: FileOperationRecord
    let iconName: String
    let onInspect: (FileOperationRecord) -> Void
    let onReveal: (FileOperationRecord) -> Void
    let onUndo: (String) -> Void

    private var targetPath: String? {
        operation.detailLines.first(where: { $0.hasPrefix("目标：") })?
            .replacingOccurrences(of: "目标：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetFileName: String? {
        guard let targetPath else { return nil }
        return (targetPath as NSString).lastPathComponent
    }

    private var metadataBadges: [String] {
        let keys = ["格式：", "章节：", "新章节：", "工作表：", "单元格：", "插入位置：", "新增行数："]
        let extracted = operation.detailLines.compactMap { line -> String? in
            guard keys.contains(where: { line.hasPrefix($0) }) else { return nil }
            return line
        }
        let time = RelativeDateTimeFormatter().localizedString(for: operation.createdAt, relativeTo: Date())
        return extracted + [time]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(iconColor.opacity(0.7))
                .frame(width: 2, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(operation.title)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    if let targetFileName, !targetFileName.isEmpty {
                        Text(targetFileName)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(operation.summary)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if !metadataBadges.isEmpty {
                    FlexibleBadgeRow(items: metadataBadges)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if targetPath != nil {
                    Button("定位") {
                        onReveal(operation)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                Button("详情") {
                    onInspect(operation)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

                if operation.isUndone {
                    Text("已撤销")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else if operation.undoAction != nil {
                    Button("撤销") {
                        onUndo(operation.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var iconColor: Color {
        if operation.isUndone { return .secondary }
        if operation.toolName == ToolDefinition.ToolName.runSkillScript.rawValue,
           operation.summary.contains("失败") || operation.summary.contains("超时") {
            return .orange
        }
        return .blue
    }
}

private struct FlexibleBadgeRow: View {
    let items: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    badge(item)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        badge(item)
                    }
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.03))
            .clipShape(Capsule())
    }
}

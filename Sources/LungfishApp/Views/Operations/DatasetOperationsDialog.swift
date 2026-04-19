import SwiftUI

struct DatasetOperationsDialog<Detail: View>: View {
    let title: String
    let subtitle: String
    let datasetLabel: String
    let tools: [DatasetOperationToolSidebarItem]
    let selectedToolID: String
    let statusText: String
    let isRunEnabled: Bool
    let primaryActionTitle: String
    let onSelectTool: (String) -> Void
    let onCancel: () -> Void
    let onRun: () -> Void
    @ViewBuilder let detail: () -> Detail

    @MainActor
    init(
        title: String,
        subtitle: String,
        datasetLabel: String,
        tools: [DatasetOperationToolSidebarItem],
        selectedToolID: String,
        statusText: String,
        isRunEnabled: Bool,
        primaryActionTitle: String = "Run",
        onSelectTool: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onRun: @escaping () -> Void,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.title = title
        self.subtitle = subtitle
        self.datasetLabel = datasetLabel
        self.tools = tools
        self.selectedToolID = selectedToolID
        self.statusText = statusText
        self.isRunEnabled = isRunEnabled
        self.primaryActionTitle = primaryActionTitle
        self.onSelectTool = onSelectTool
        self.onCancel = onCancel
        self.onRun = onRun
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 0) {
            toolSidebar
                .frame(width: 260)
                .background(Color.lungfishSidebarBackground)
            Divider()
            VStack(spacing: 0) {
                detailPane
                Divider()
                footerBar
            }
            .background(Color.lungfishCanvasBackground)
        }
        .background(Color.lungfishCanvasBackground)
    }

    private var toolSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(datasetLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(tools) { tool in
                    Button {
                        selectToolIfAvailable(tool)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(tool.title)
                                Spacer(minLength: 8)
                                if let badgeText = tool.availability.badgeText {
                                    Text(badgeText)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(tool.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(sidebarCardBackground(for: tool))
                        .overlay(sidebarCardBorder(for: tool))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelect(tool))
                }
            }
            .padding(16)
        }
    }

    private var detailPane: some View {
        detail()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
            Spacer()
            Button("Cancel", action: onCancel)
            Button(primaryActionTitle, action: runIfEnabled)
                .buttonStyle(.borderedProminent)
                .tint(.lungfishCreamsicleFallback)
                .disabled(!isRunEnabled)
        }
        .padding(16)
        .background(Color.lungfishCanvasBackground)
    }

    func canSelect(_ tool: DatasetOperationToolSidebarItem) -> Bool {
        tool.availability == .available
    }

    func selectToolIfAvailable(_ tool: DatasetOperationToolSidebarItem) {
        guard canSelect(tool) else { return }
        onSelectTool(tool.id)
    }

    func runIfEnabled() {
        guard isRunEnabled else { return }
        onRun()
    }

    private func sidebarCardBackground(for tool: DatasetOperationToolSidebarItem) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                selectedToolID == tool.id
                ? Color.lungfishCreamsicleFallback.opacity(0.18)
                : Color.lungfishCardBackground
            )
    }

    private func sidebarCardBorder(for tool: DatasetOperationToolSidebarItem) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(
                selectedToolID == tool.id
                ? Color.lungfishCreamsicleFallback.opacity(0.35)
                : Color.lungfishStroke,
                lineWidth: 1
            )
    }
}

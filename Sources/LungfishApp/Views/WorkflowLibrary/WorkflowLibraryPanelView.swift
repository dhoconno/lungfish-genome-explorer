import AppKit
import LungfishWorkflow
import SwiftUI

enum WorkflowLibraryAccessibilityID {
    static let window = "workflow-library-window"
    static let root = "workflow-library-root"
    static let toolbarSegmentedControl = "workflow-library-segmented-control"
    static let addWorkflowButton = "workflow-library-add-workflow-button"

    static func workflowCard(_ id: String) -> String {
        "workflow-library-card-\(slug(id))"
    }

    static func workflowGroup(_ id: String) -> String {
        "workflow-library-group-\(slug(id))"
    }

    static func workflowEnableButton(_ id: String) -> String {
        "workflow-library-enable-\(slug(id))"
    }

    private static func slug(_ raw: String) -> String {
        var pieces: [Character] = []
        var previousWasDash = false
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                pieces.append(Character(scalar))
                previousWasDash = false
            } else if !previousWasDash {
                pieces.append("-")
                previousWasDash = true
            }
        }
        return String(pieces).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct WorkflowLibraryPanelView: View {
    @Bindable var viewModel: WorkflowLibraryViewModel

    var body: some View {
        Group {
            switch viewModel.selectedTab {
            case .library:
                libraryView
            case .installed:
                placeholderView(
                    title: "Installed Workflows",
                    message: "Imported and enabled workflow packages will be listed here."
                )
            case .runs:
                placeholderView(
                    title: "Workflow Runs",
                    message: "Workflow run history will appear here as imported workflow execution is enabled."
                )
            }
        }
        .background(Color.lungfishCanvasBackground)
        .tint(.lungfishCreamsicleFallback)
        .accessibilityIdentifier(WorkflowLibraryAccessibilityID.root)
        .frame(minWidth: 600, minHeight: 350)
        .task {
            await viewModel.refreshDependencyStatuses()
        }
        .alert(
            "Workflow Library Error",
            isPresented: $viewModel.showingError,
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var libraryView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(viewModel.builtInSections) { section in
                    builtInSection(section)
                }

                userWorkflowHeader

                ForEach(viewModel.userWorkflowSections) { section in
                    userSection(section)
                }

                if viewModel.userWorkflowSections.isEmpty {
                    emptyUserWorkflowCard
                }
            }
            .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.lungfishCreamsicleFallback)
                    Text("Refreshing workflow status...")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
                .padding(10)
            }
        }
    }

    private func placeholderView(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title2)
                .fontWeight(.medium)
            Text(message)
                .font(.body)
                .foregroundStyle(Color.lungfishSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func builtInSection(_ section: WorkflowLibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.headline)

            ForEach(section.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.lungfishSecondaryText)

                    ForEach(group.items) { item in
                        WorkflowLibraryCard(item: item, viewModel: viewModel)
                            .accessibilityIdentifier(WorkflowLibraryAccessibilityID.workflowCard(item.id))
                    }
                }
                .accessibilityIdentifier(WorkflowLibraryAccessibilityID.workflowGroup(group.id))
            }
        }
    }

    private var userWorkflowHeader: some View {
        HStack {
            Text("User Workflows")
                .font(.headline)

            Spacer()

            Button("Add Workflow...") {
                addWorkflowPackage()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(WorkflowLibraryAccessibilityID.addWorkflowButton)
        }
        .padding(.top, 4)
    }

    private func userSection(_ section: WorkflowLibraryUserSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(section.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.lungfishSecondaryText)

                    ForEach(group.packages, id: \.manifest.id) { package in
                        UserWorkflowPackageCard(package: package, viewModel: viewModel)
                            .accessibilityIdentifier(WorkflowLibraryAccessibilityID.workflowCard(package.manifest.id))
                    }
                }
            }
        }
    }

    private var emptyUserWorkflowCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No User Workflows")
                .font(.headline)
            Text("Import a .lungfishflowpkg package to add Nextflow, Snakemake, or command-based workflows.")
                .font(.callout)
                .foregroundStyle(Color.lungfishSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.lungfishCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.lungfishStroke, lineWidth: 1)
        )
    }

    private func addWorkflowPackage() {
        let panel = NSOpenPanel()
        panel.title = "Add Workflow Package"
        panel.prompt = "Add Workflow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let packageURL = panel.url else { return }
            importWorkflowPackage(at: packageURL)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func importWorkflowPackage(at packageURL: URL) {
        Task {
            do {
                try await viewModel.importWorkflowPackage(at: packageURL)
            } catch {
                viewModel.errorMessage = error.localizedDescription
                viewModel.showingError = true
            }
        }
    }
}

private struct WorkflowLibraryCard: View {
    let item: WorkflowLibraryItem
    @Bindable var viewModel: WorkflowLibraryViewModel

    private var missingPluginPackIDs: [String] {
        viewModel.missingRequiredPluginPackIDs(for: item)
    }

    private var isInstalling: Bool {
        viewModel.installingWorkflowIDs.contains(item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.maturity.displayName)
                            .font(.caption2)
                            .foregroundStyle(Color.lungfishSecondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.lungfishMutedFill)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text(item.subtitle)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .font(.callout)
                }

                Spacer()

                actionView
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .padding(.leading, 14)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.requiredPluginPackIDs, id: \.self) { packID in
                    dependencyRow(packID)
                }
                if item.requiredPluginPackIDs.isEmpty {
                    dependencyRow(nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.lungfishCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.lungfishStroke, lineWidth: 1)
        )
    }

    private func dependencyRow(_ packID: String?) -> some View {
        HStack(spacing: 8) {
            let ready = packID.map { !missingPluginPackIDs.contains($0) } ?? true
            Circle()
                .fill(ready ? Color.lungfishSageFallback : Color.lungfishCreamsicleFallback)
                .frame(width: 8, height: 8)

            Text(packID.map(viewModel.pluginPackName(for:)) ?? "No managed plug-ins required")
                .font(.caption)

            Spacer()

            Text(ready ? "Ready" : "Needs install")
                .font(.caption2)
                .foregroundStyle(ready ? Color.lungfishSageFallback : Color.lungfishSecondaryText)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if item.maturity == .core {
            Text("Enabled")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if isInstalling {
            ProgressView()
        } else if !missingPluginPackIDs.isEmpty {
            Button("Install Dependencies") {
                Task { await viewModel.installDependenciesAndEnable(item) }
            }
            .accessibilityIdentifier(WorkflowLibraryAccessibilityID.workflowEnableButton(item.id))
        } else {
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { viewModel.isEnabled(item) },
                    set: { enabled in
                        Task { await viewModel.setWorkflow(item, enabled: enabled) }
                    }
                )
            )
            .toggleStyle(.switch)
            .accessibilityIdentifier(WorkflowLibraryAccessibilityID.workflowEnableButton(item.id))
        }
    }
}

private struct UserWorkflowPackageCard: View {
    let package: WorkflowPackageValidationResult
    @Bindable var viewModel: WorkflowLibraryViewModel

    private var manifest: WorkflowPackageManifest {
        package.manifest
    }

    private var missingPluginPackIDs: [String] {
        viewModel.missingRequiredPluginPackIDs(for: package)
    }

    private var isInstalling: Bool {
        viewModel.installingWorkflowIDs.contains(manifest.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(manifest.name)
                            .font(.headline)
                        Text(manifest.runner.kind.rawValue.capitalized)
                            .font(.caption2)
                            .foregroundStyle(Color.lungfishSecondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.lungfishMutedFill)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text(manifest.description ?? "User workflow package")
                        .font(.callout)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }

                Spacer()

                actionView
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .padding(.leading, 14)

            VStack(alignment: .leading, spacing: 4) {
                contractRow(
                    label: "Inputs",
                    value: manifest.inputs.map { input in
                        input.bundleTypes.map(\.rawValue).joined(separator: "/")
                    }.joined(separator: ", ")
                )
                contractRow(
                    label: "Outputs",
                    value: manifest.outputs.map(\.bundleType.rawValue).joined(separator: ", ")
                )
                contractRow(
                    label: "Runtime",
                    value: manifest.runtime.kind.rawValue
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.lungfishCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.lungfishStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var actionView: some View {
        if isInstalling {
            ProgressView()
                .controlSize(.small)
        } else if !missingPluginPackIDs.isEmpty {
            Button("Install Dependencies") {
                Task { await viewModel.installDependenciesAndEnable(package) }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(WorkflowLibraryAccessibilityID.workflowEnableButton(manifest.id))
        } else {
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { viewModel.isEnabled(package) },
                    set: { enabled in
                        Task { await viewModel.setWorkflow(package, enabled: enabled) }
                    }
                )
            )
            .toggleStyle(.switch)
            .accessibilityIdentifier(WorkflowLibraryAccessibilityID.workflowEnableButton(manifest.id))
        }
    }

    private func contractRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.lungfishSageFallback)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value.isEmpty ? "None" : value)
                .font(.caption2)
                .foregroundStyle(Color.lungfishSecondaryText)
        }
    }
}

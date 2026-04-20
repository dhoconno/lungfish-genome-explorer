// PluginManagerView.swift - SwiftUI view for browsing, installing, and managing bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import LungfishWorkflow

enum PluginManagerAccessibilityID {
    static let window = "plugin-manager-window"
    static let root = "plugin-manager-root"
    static let toolbarSegmentedControl = "plugin-manager-segmented-control"
    static let installedBrowsePacksButton = "plugin-manager-installed-browse-packs-button"
    static let databasesRefreshButton = "plugin-manager-databases-refresh-button"
    static let storageSettingsButton = "plugin-manager-storage-settings-button"

    static func tab(_ tab: PluginManagerViewModel.Tab) -> String {
        switch tab {
        case .installed:
            "plugin-manager-tab-installed"
        case .packs:
            "plugin-manager-tab-packs"
        case .databases:
            "plugin-manager-tab-databases"
        }
    }

    static func environmentRow(_ name: String) -> String {
        "plugin-manager-environment-\(slug(name))"
    }

    static func environmentRemoveButton(_ name: String) -> String {
        "plugin-manager-environment-remove-\(slug(name))"
    }

    static func packCard(_ id: String) -> String {
        "plugin-manager-pack-\(slug(id))"
    }

    static func packInstallButton(_ id: String) -> String {
        "plugin-manager-pack-install-\(slug(id))"
    }

    static func packRemoveButton(_ id: String) -> String {
        "plugin-manager-pack-remove-\(slug(id))"
    }

    static func databaseRow(_ name: String) -> String {
        "plugin-manager-database-\(slug(name))"
    }

    static func databaseDownloadButton(_ name: String) -> String {
        "plugin-manager-database-download-\(slug(name))"
    }

    static func databaseCancelButton(_ name: String) -> String {
        "plugin-manager-database-cancel-\(slug(name))"
    }

    static func databaseRemoveButton(_ name: String) -> String {
        "plugin-manager-database-remove-\(slug(name))"
    }

    static func databaseDismissErrorButton(_ name: String) -> String {
        "plugin-manager-database-dismiss-error-\(slug(name))"
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

/// Main SwiftUI view for the Plugin Manager window.
///
/// Displays the tool-management tabs controlled by the toolbar segmented control:
/// - **Installed**: Conda environments with expand-to-show-packages.
/// - **Packs**: Curated tool bundles for common workflows.
/// - **Databases**: Kraken2 database download and management.
struct PluginManagerView: View {

    /// The shared view model, owned by ``PluginManagerWindowController``.
    @Bindable var viewModel: PluginManagerViewModel

    var body: some View {
        Group {
            switch viewModel.selectedTab {
            case .installed:
                InstalledTabView(viewModel: viewModel)
                    .accessibilityIdentifier(PluginManagerAccessibilityID.tab(.installed))
            case .packs:
                PacksTabView(viewModel: viewModel)
                    .accessibilityIdentifier(PluginManagerAccessibilityID.tab(.packs))
            case .databases:
                DatabasesTabView(viewModel: viewModel)
                    .accessibilityIdentifier(PluginManagerAccessibilityID.tab(.databases))
            }
        }
        .accessibilityIdentifier(PluginManagerAccessibilityID.root)
        .frame(minWidth: 600, minHeight: 350)
        .background(Color.lungfishCanvasBackground.ignoresSafeArea())
        .tint(.lungfishCreamsicleFallback)
        .alert(
            "Plugin Manager Error",
            isPresented: $viewModel.showingError,
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

// MARK: - Installed Tab

/// Shows installed conda environments and their packages.
private struct InstalledTabView: View {

    @Bindable var viewModel: PluginManagerViewModel

    /// Tracks which environments are expanded to show packages.
    @State private var expandedEnvironments: Set<String> = []

    var body: some View {
        if viewModel.isLoading && viewModel.environments.isEmpty {
            loadingPlaceholder
        } else if viewModel.environments.isEmpty {
            emptyPlaceholder
        } else {
            environmentList
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.lungfishCreamsicleFallback)
            Text("Loading environments...")
                .foregroundStyle(Color.lungfishSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lungfishCanvasBackground)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 16) {
            Text("No Tools Installed")
                .font(.title2)
                .fontWeight(.medium)
            Text("Install the required and optional tool packs to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.lungfishSecondaryText)
                .font(.body)
            Button("Browse Packs") {
                viewModel.selectedTab = .packs
            }
            .controlSize(.large)
            .accessibilityIdentifier(PluginManagerAccessibilityID.installedBrowsePacksButton)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lungfishCanvasBackground)
    }

    private var environmentList: some View {
        List {
            ForEach(viewModel.environments) { env in
                EnvironmentRow(
                    environment: env,
                    isExpanded: expandedEnvironments.contains(env.name),
                    isRemoving: viewModel.removingEnvironments.contains(env.name),
                    packages: viewModel.installedPackages[env.name] ?? [],
                    onToggleExpand: {
                        toggleExpanded(env.name)
                    },
                    onRemove: {
                        viewModel.removeEnvironment(name: env.name)
                    }
                )
                .listRowBackground(Color.lungfishCardBackground)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(Color.lungfishCanvasBackground)
        .overlay(alignment: .topTrailing) {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.lungfishCreamsicleFallback)
                    .padding(8)
            }
        }
    }

    private func toggleExpanded(_ name: String) {
        if expandedEnvironments.contains(name) {
            expandedEnvironments.remove(name)
        } else {
            expandedEnvironments.insert(name)
            if viewModel.installedPackages[name] == nil {
                viewModel.loadPackages(for: name)
            }
        }
    }
}

// MARK: - Environment Row

/// A single installed conda environment with expand/collapse.
private struct EnvironmentRow: View {

    let environment: CondaEnvironment
    let isExpanded: Bool
    let isRemoving: Bool
    let packages: [CondaPackageInfo]
    let onToggleExpand: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .frame(width: 12)

                Circle()
                    .fill(Color.lungfishSageFallback)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.name)
                        .font(.headline)
                    Text("\(environment.packageCount) packages")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }

                Spacer()

                if isRemoving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(role: .destructive) {
                        onRemove()
                    }
                    label: { Text("Remove") }
                    .controlSize(.small)
                    .help("Remove this environment and all its packages")
                    .accessibilityIdentifier(PluginManagerAccessibilityID.environmentRemoveButton(environment.name))
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }

            // Expanded package list
            if isExpanded {
                Divider()
                    .padding(.leading, 32)

                if packages.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .tint(.lungfishCreamsicleFallback)
                        Text("Loading packages...")
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.leading, 32)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(packages) { pkg in
                            HStack(spacing: 8) {
                                Text(pkg.name)
                                    .font(.system(.caption, design: .monospaced))

                                Text(pkg.version)
                                    .font(.caption)
                                    .foregroundStyle(Color.lungfishSecondaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.lungfishMutedFill)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                if !pkg.channel.isEmpty && pkg.channel != "unknown" {
                                    Text(pkg.channel)
                                        .font(.caption2)
                                        .foregroundStyle(Color.lungfishSecondaryText)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.lungfishMutedFill)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .padding(.leading, 32)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .accessibilityIdentifier(PluginManagerAccessibilityID.environmentRow(environment.name))
    }
}

// MARK: - Packs Tab

/// Shows curated plugin packs for common bioinformatics workflows.
private struct PacksTabView: View {

    @Bindable var viewModel: PluginManagerViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingPackStatuses
                && viewModel.requiredSetupPack == nil
                && viewModel.optionalPackStatuses.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.lungfishCreamsicleFallback)
                    Text("Checking installed tools...")
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if let required = viewModel.requiredSetupPack {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Required Setup")
                                        .font(.headline)

                                    PackCard(
                                        status: required,
                                        isInstalling: viewModel.installingPacks.contains(required.pack.id),
                                        progressMessage: viewModel.packProgressMessage[required.pack.id],
                                        onInstallAll: {
                                            viewModel.installPack(
                                                required.pack,
                                                reinstall: required.shouldReinstall
                                            )
                                        },
                                        onRemoveAll: nil
                                    )
                                    .id(required.pack.id)
                                }
                            }

                            if !viewModel.optionalPackStatuses.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Optional Tools")
                                        .font(.headline)

                                    ForEach(viewModel.optionalPackStatuses) { status in
                                        PackCard(
                                            status: status,
                                            isInstalling: viewModel.installingPacks.contains(status.pack.id),
                                            progressMessage: viewModel.packProgressMessage[status.pack.id],
                                            onInstallAll: {
                                                viewModel.installPack(
                                                    status.pack,
                                                    reinstall: status.shouldReinstall
                                                )
                                            },
                                            onRemoveAll: {
                                                viewModel.removePack(status.pack)
                                            }
                                        )
                                        .id(status.pack.id)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isLoadingPackStatuses {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.lungfishCreamsicleFallback)
                                Text("Refreshing tool status...")
                                    .font(.caption)
                                    .foregroundStyle(Color.lungfishSecondaryText)
                            }
                            .padding(10)
                        }
                    }
                    .onAppear {
                        scrollToFocusedPack(with: proxy)
                    }
                    .onChange(of: viewModel.focusedPackID) { _, _ in
                        scrollToFocusedPack(with: proxy)
                    }
                }
            }
        }
    }

    private func scrollToFocusedPack(with proxy: ScrollViewProxy) {
        guard let focusedPackID = viewModel.focusedPackID else { return }
        withAnimation {
            proxy.scrollTo(focusedPackID, anchor: .top)
        }
    }
}

// MARK: - Pack Card

/// A card view for a single plugin pack.
private struct PackCard: View {

    let status: PluginPackStatus
    let isInstalling: Bool
    let progressMessage: String?
    let onInstallAll: () -> Void
    let onRemoveAll: (() -> Void)?

    private var pack: PluginPack {
        status.pack
    }

    /// How many of this pack's tools are ready to use.
    private var installedCount: Int {
        status.toolStatuses.filter(\.isReady).count
    }

    /// Whether this pack is currently ready to use.
    private var isReady: Bool {
        status.state == .ready
    }

    private var installActionTitle: String {
        status.shouldReinstall ? "Reinstall" : (pack.isRequiredBeforeLaunch ? "Install" : "Install All")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(pack.name)
                            .font(.headline)

                        if pack.category != pack.name {
                            Text(pack.category)
                                .font(.caption2)
                                .foregroundStyle(Color.lungfishSecondaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.lungfishMutedFill)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(pack.description)
                        .font(.callout)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }

                Spacer()

                // Progress or actions
                if isInstalling {
                    VStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.lungfishCreamsicleFallback)
                        if let msg = progressMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(Color.lungfishSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 140)
                } else if pack.isRequiredBeforeLaunch {
                    Button {
                        onInstallAll()
                    } label: { Text(installActionTitle) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(PluginManagerAccessibilityID.packInstallButton(pack.id))
                } else if isReady, let onRemoveAll {
                    Button(role: .destructive) {
                        onRemoveAll()
                    } label: { Text("Remove All") }
                    .controlSize(.small)
                    .accessibilityIdentifier(PluginManagerAccessibilityID.packRemoveButton(pack.id))
                } else {
                    Button {
                        onInstallAll()
                    } label: { Text(installActionTitle) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(PluginManagerAccessibilityID.packInstallButton(pack.id))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .padding(.leading, 14)

            // Package list
            VStack(alignment: .leading, spacing: 4) {
                ForEach(status.toolStatuses) { toolStatus in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(toolStatus.isReady ? Color.lungfishSageFallback : Color.lungfishCreamsicleFallback)
                            .frame(width: 8, height: 8)

                        Text(toolStatus.requirement.displayName)
                            .font(.caption)

                        Spacer()

                        Text(toolStatus.statusText)
                            .font(.caption2)
                            .foregroundStyle(toolStatus.isReady ? Color.lungfishSageFallback : Color.lungfishSecondaryText)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Status bar with install count, estimated size, and hook info
            HStack(spacing: 12) {
                Text("\(installedCount) of \(status.toolStatuses.count) ready")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)

                if pack.estimatedSizeMB > 0 {
                    Text(formatPackSize(pack.estimatedSizeMB))
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }

                if !pack.postInstallHooks.isEmpty {
                    Text("\(pack.postInstallHooks.count) post-install \(pack.postInstallHooks.count == 1 ? "step" : "steps")")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .help(pack.postInstallHooks.map(\.description).joined(separator: "\n"))
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(Color.lungfishCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.lungfishStroke, lineWidth: 1)
        )
        .accessibilityIdentifier(PluginManagerAccessibilityID.packCard(pack.id))
    }
}

// MARK: - Databases Tab

/// Shows Kraken2 databases available for download and management.
///
/// Each database row displays the name, download size, RAM requirement,
/// and current status (not installed, downloading, installed). A recommended
/// badge highlights the best choice for the system's RAM. The footer shows
/// the storage directory and total disk usage.
struct DatabasesTabView: View {

    @Bindable var viewModel: PluginManagerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            databaseHeader

            Divider()

            // Database list
            if viewModel.databases.isEmpty {
                loadingPlaceholder
            } else {
                databaseList
            }

            Divider()

            // Footer with storage info
            storageFooter
        }
        .background(Color.lungfishCanvasBackground)
        .onAppear {
            if viewModel.databases.isEmpty {
                viewModel.refreshDatabases()
            }
        }
        .alert(
            "Remove Database",
            isPresented: Binding(
                get: { viewModel.databasePendingRemoval != nil },
                set: { if !$0 { viewModel.databasePendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                viewModel.confirmRemoveDatabase()
            }
            Button("Cancel", role: .cancel) {
                viewModel.databasePendingRemoval = nil
            }
        } message: {
            if let name = viewModel.databasePendingRemoval {
                Text("Are you sure you want to remove the \(name) database? This will delete all database files from disk and free the associated storage space.")
            }
        }
    }

    // MARK: - Header

    private var databaseHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Databases")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.refreshDatabases()
                } label: { Text("Refresh") }
                .controlSize(.small)
                .accessibilityIdentifier(PluginManagerAccessibilityID.databasesRefreshButton)
            }

            if !viewModel.recommendedDatabaseName.isEmpty {
                HStack(spacing: 4) {
                    Text("Recommended for your system (\(formatRAM(viewModel.systemRAMBytes)) RAM): ")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                    Text(viewModel.recommendedDatabaseName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.lungfishCreamsicleFallback)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.lungfishAttentionFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.lungfishCanvasBackground)
    }

    // MARK: - Loading

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.lungfishCreamsicleFallback)
            Text("Loading database catalog...")
                .foregroundStyle(Color.lungfishSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lungfishCanvasBackground)
    }

    // MARK: - Database List (grouped by tool)

    /// Groups databases by their tool property for sectioned display.
    private var groupedDatabases: [(tool: String, title: String, databases: [MetagenomicsDatabaseInfo])] {
        let toolOrder: [MetagenomicsTool] = [.kraken2, .esviritu, .taxtriage]
        var result: [(tool: String, title: String, databases: [MetagenomicsDatabaseInfo])] = []

        for tool in toolOrder {
            let dbs = viewModel.databases.filter { $0.tool == tool.rawValue }
            if !dbs.isEmpty {
                result.append((
                    tool: tool.rawValue,
                    title: tool.databaseSectionTitle,
                    databases: dbs
                ))
            }
        }

        // Any remaining tools not in the explicit order
        let knownTools = Set(toolOrder.map(\.rawValue))
        let otherDbs = viewModel.databases.filter { !knownTools.contains($0.tool) }
        if !otherDbs.isEmpty {
            result.append((tool: "other", title: "Other Databases", databases: otherDbs))
        }

        return result
    }

    private var databaseList: some View {
        List {
            ForEach(groupedDatabases, id: \.tool) { section in
                Section {
                    ForEach(section.databases) { db in
                        DatabaseRow(
                            database: db,
                            isRecommended: db.name == viewModel.recommendedDatabaseName,
                            isDownloading: viewModel.downloadingDatabases.contains(db.name),
                            isRemoving: viewModel.removingDatabases.contains(db.name),
                            progress: viewModel.downloadProgress[db.name],
                            progressMessage: viewModel.downloadMessage[db.name],
                            errorMessage: viewModel.downloadError[db.name],
                            systemRAMBytes: viewModel.systemRAMBytes,
                            onDownload: {
                                viewModel.downloadDatabase(name: db.name)
                            },
                            onCancel: {
                                viewModel.cancelDownload(name: db.name)
                            },
                            onRemove: {
                                viewModel.requestRemoveDatabase(name: db.name)
                            },
                            onDismissError: {
                                viewModel.downloadError.removeValue(forKey: db.name)
                            }
                        )
                        .listRowBackground(Color.lungfishCardBackground)
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(Color.lungfishCanvasBackground)
    }

    // MARK: - Storage Footer

    private var storageFooter: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.storageLocationStatusText)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)

                Text(viewModel.storageLocationPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button("Storage Settings...") {
                viewModel.openStorageSettings()
            }
            .controlSize(.small)
            .font(.caption)
            .accessibilityIdentifier(PluginManagerAccessibilityID.storageSettingsButton)

            Spacer()

            Text("Total: \(formatDatabaseBytes(viewModel.totalDatabaseStorageBytes)) used")
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.lungfishCanvasBackground)
    }
}

// MARK: - Database Row

/// A single database entry with download/remove actions and progress display.
private struct DatabaseRow: View {

    let database: MetagenomicsDatabaseInfo
    let isRecommended: Bool
    let isDownloading: Bool
    let isRemoving: Bool
    let progress: Double?
    let progressMessage: String?
    let errorMessage: String?
    let systemRAMBytes: UInt64
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onDismissError: () -> Void

    /// Whether this database's RAM requirement exceeds system RAM.
    private var exceedsSystemRAM: Bool {
        UInt64(database.recommendedRAM) > systemRAMBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // Status icon
                statusIcon

                // Database info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(database.name)
                            .font(.headline)

                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(Color.lungfishCreamsicleFallback)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.lungfishAttentionFill)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    HStack(spacing: 8) {
                        // Download size
                        Text(formatDatabaseBytes(database.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)

                        // RAM requirement
                        Text(formatDatabaseRAM(database.recommendedRAM))
                            .font(.caption)
                            .foregroundStyle(exceedsSystemRAM ? Color.lungfishCreamsicleFallback : Color.lungfishSecondaryText)

                        if exceedsSystemRAM {
                            Text("(exceeds system RAM)")
                                .font(.caption2)
                                .foregroundStyle(Color.lungfishCreamsicleFallback)
                        }
                    }

                    Text(database.description)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Action area
                actionView
            }
            .padding(.vertical, 4)

            // Error message if download failed
            if let error = errorMessage {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.lungfishCreamsicleFallback)
                        .frame(width: 8, height: 8)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishCreamsicleFallback)
                        .lineLimit(2)

                    Spacer()

                    Button("Dismiss") {
                        onDismissError()
                    }
                    .font(.caption)
                    .controlSize(.mini)
                    .accessibilityIdentifier(PluginManagerAccessibilityID.databaseDismissErrorButton(database.name))
                }
                .padding(.leading, 34)
                .padding(.bottom, 2)
            }

            // Download progress
            if isDownloading, let progressValue = progress {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: progressValue)
                        .tint(.lungfishCreamsicleFallback)
                    if let message = progressMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(Color.lungfishSecondaryText)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
            }
        }
        .accessibilityIdentifier(PluginManagerAccessibilityID.databaseRow(database.name))
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch database.status {
        case .ready:
            Circle()
                .fill(Color.lungfishSageFallback)
                .frame(width: 10, height: 10)
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .tint(.lungfishCreamsicleFallback)
                .frame(width: 20, height: 20)
        case .corrupt:
            Circle()
                .fill(Color.lungfishCreamsicleFallback)
                .frame(width: 10, height: 10)
        case .volumeNotMounted:
            Circle()
                .fill(Color.lungfishCreamsicleFallback)
                .frame(width: 10, height: 10)
        case .missing, .verifying:
            Circle()
                .stroke(Color.lungfishWarmGreyFallback.opacity(0.6), lineWidth: 1)
                .frame(width: 10, height: 10)
        }
    }

    // MARK: - Action View

    @ViewBuilder
    private var actionView: some View {
        if isRemoving {
            ProgressView()
                .controlSize(.small)
                .tint(.lungfishCreamsicleFallback)
        } else if isDownloading {
            Button(role: .cancel) {
                onCancel()
            } label: { Text("Cancel") }
            .controlSize(.small)
            .help("Cancel this download")
            .accessibilityIdentifier(PluginManagerAccessibilityID.databaseCancelButton(database.name))
        } else if database.status == .ready {
            HStack(spacing: 8) {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSageFallback)
                    .fontWeight(.medium)

                Button(role: .destructive) {
                    onRemove()
                } label: { Text("Remove") }
                .controlSize(.small)
                .help("Remove this database and free disk space")
                .accessibilityIdentifier(PluginManagerAccessibilityID.databaseRemoveButton(database.name))
            }
        } else {
            Button {
                onDownload()
            } label: { Text("Download") }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(PluginManagerAccessibilityID.databaseDownloadButton(database.name))
        }
    }
}

// MARK: - Helpers

/// Formats a byte count into a human-readable string.
///
/// This is a free function to avoid `@MainActor` isolation issues
/// when called from `@Sendable` view body closures.
private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

/// Formats a megabyte estimate into a human-readable string.
private func formatPackSize(_ megabytes: Int) -> String {
    if megabytes >= 1000 {
        let gb = Double(megabytes) / 1000.0
        return String(format: "~%.1f GB", gb)
    } else {
        return "~\(megabytes) MB"
    }
}

/// Formats a byte count for database sizes (download size, disk usage).
private func formatDatabaseBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 {
        return String(format: "%.0f GB", gb)
    }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1.0 {
        return String(format: "%.0f MB", mb)
    }
    let kb = Double(bytes) / 1_024
    return String(format: "%.0f KB", kb)
}

/// Formats a RAM requirement in bytes as a human-readable string with
/// the "RAM" suffix (e.g., "8 GB RAM").
private func formatDatabaseRAM(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 {
        return String(format: "%.0f GB RAM", gb)
    }
    let mb = Double(bytes) / 1_048_576
    return String(format: "%.0f MB RAM", mb)
}

/// Formats system RAM from UInt64 bytes to a human-readable string (e.g., "32 GB").
private func formatRAM(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return String(format: "%.0f GB", gb)
}

// PluginManagerView.swift - SwiftUI view for browsing, installing, and managing bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

/// Main SwiftUI view for the Plugin Manager window.
///
/// Displays four tabs controlled by the toolbar segmented control:
/// - **Installed**: Conda environments with expand-to-show-packages.
/// - **Available**: Bioconda package search with install buttons.
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
            case .available:
                AvailableTabView(viewModel: viewModel)
            case .packs:
                PacksTabView(viewModel: viewModel)
            case .databases:
                DatabasesTabView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 600, minHeight: 350)
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
            Text("Loading environments...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Tools Installed")
                .font(.title2)
                .fontWeight(.medium)
            Text("Browse the Available tab to search bioconda,\nor install a curated Pack to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.body)
            Button("Browse Packs") {
                viewModel.selectedTab = .packs
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay(alignment: .topTrailing) {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
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
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.name)
                        .font(.headline)
                    Text("\(environment.packageCount) packages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isRemoving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .help("Remove this environment and all its packages")
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
                        Text("Loading packages...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.leading, 32)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(packages) { pkg in
                            HStack(spacing: 8) {
                                Image(systemName: "cube")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(pkg.name)
                                    .font(.system(.caption, design: .monospaced))

                                Text(pkg.version)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if !pkg.channel.isEmpty && pkg.channel != "unknown" {
                                    Text(pkg.channel)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.quaternary)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
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
    }
}

// MARK: - Available Tab

/// Search bioconda packages and install them.
private struct AvailableTabView: View {

    @Bindable var viewModel: PluginManagerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Inline search bar for clarity (supplements the toolbar search)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search bioconda packages (e.g. samtools, bcftools, bwa)", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.commitSearch()
                    }

                Button("Search") {
                    viewModel.commitSearch()
                }
                .controlSize(.regular)
                .disabled(viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Results area
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Searching bioconda...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.hasSearched {
                searchPrompt
            } else if viewModel.deduplicatedResults.isEmpty {
                noResultsView
            } else {
                resultsList
            }
        }
    }

    private var searchPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Search Bioconda")
                .font(.title2)
                .fontWeight(.medium)
            Text("Search for bioinformatics tools from bioconda\nand conda-forge channels.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.body)

            // Quick search suggestions
            HStack(spacing: 8) {
                ForEach(["samtools", "bcftools", "bwa-mem2", "minimap2"], id: \.self) { suggestion in
                    Button(suggestion) {
                        viewModel.searchText = suggestion
                        viewModel.commitSearch()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Results")
                .font(.title3)
                .fontWeight(.medium)
            Text("No packages found matching your search.\nTry a different term or check the spelling.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        List {
            ForEach(viewModel.deduplicatedResults) { pkg in
                PackageSearchRow(
                    package: pkg,
                    isInstalled: viewModel.installedEnvironmentNames.contains(pkg.name),
                    isInstalling: viewModel.installingPackages.contains(pkg.name),
                    progress: viewModel.installProgress[pkg.name],
                    onInstall: {
                        viewModel.installPackage(pkg)
                    }
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

// MARK: - Package Search Row

/// A single search result row with install button.
private struct PackageSearchRow: View {

    let package: CondaPackageInfo
    let isInstalled: Bool
    let isInstalling: Bool
    let progress: Double?
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            if isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Image(systemName: "cube.box")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }

            // Package info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.headline)

                    Text(package.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                HStack(spacing: 8) {
                    // Channel badge
                    Label(package.channel, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Platform badge
                    if !package.isNativeMacOS && !package.subdir.isEmpty {
                        Text("Linux only")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    // License badge
                    if let license = package.license {
                        Label(license, systemImage: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Size
                    if let size = package.sizeBytes, size > 0 {
                        Text(formatBytes(size))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let desc = package.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Action button
            if isInstalled {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fontWeight(.medium)
            } else if isInstalling {
                VStack(spacing: 4) {
                    ProgressView(value: progress ?? 0)
                        .frame(width: 60)
                    Text("Installing...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    onInstall()
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Packs Tab

/// Shows curated plugin packs for common bioinformatics workflows.
private struct PacksTabView: View {

    @Bindable var viewModel: PluginManagerViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.packs) { pack in
                    PackCard(
                        pack: pack,
                        installedNames: viewModel.installedEnvironmentNames,
                        isInstalling: viewModel.installingPacks.contains(pack.id),
                        progressMessage: viewModel.packProgressMessage[pack.id],
                        onInstallAll: {
                            viewModel.installPack(pack)
                        },
                        onRemoveAll: {
                            viewModel.removePack(pack)
                        }
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Pack Card

/// A card view for a single plugin pack.
private struct PackCard: View {

    let pack: PluginPack
    let installedNames: Set<String>
    let isInstalling: Bool
    let progressMessage: String?
    let onInstallAll: () -> Void
    let onRemoveAll: () -> Void

    /// How many of this pack's packages are already installed.
    private var installedCount: Int {
        pack.packages.filter { installedNames.contains($0) }.count
    }

    /// Whether all packages in the pack are installed.
    private var allInstalled: Bool {
        installedCount == pack.packages.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: pack.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(pack.name)
                            .font(.headline)

                        Text(pack.category)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    Text(pack.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Progress or actions
                if isInstalling {
                    VStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        if let msg = progressMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 140)
                } else if allInstalled {
                    Button(role: .destructive) {
                        onRemoveAll()
                    } label: {
                        Label("Remove All", systemImage: "trash")
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        onInstallAll()
                    } label: {
                        Label("Install All", systemImage: "arrow.down.circle.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .padding(.leading, 62)

            // Package list
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pack.packages, id: \.self) { packageName in
                    HStack(spacing: 8) {
                        if installedNames.contains(packageName) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }

                        Text(packageName)
                            .font(.system(.caption, design: .monospaced))

                        Spacer()

                        if installedNames.contains(packageName) {
                            Text("Installed")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not installed")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.leading, 48)
            .padding(.vertical, 10)

            // Status bar with install count, estimated size, and hook info
            HStack(spacing: 12) {
                Text("\(installedCount) of \(pack.packages.count) installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if pack.estimatedSizeMB > 0 {
                    Text(formatPackSize(pack.estimatedSizeMB))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !pack.postInstallHooks.isEmpty {
                    Label(
                        "\(pack.postInstallHooks.count) post-install \(pack.postInstallHooks.count == 1 ? "step" : "steps")",
                        systemImage: "arrow.down.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(pack.postInstallHooks.map(\.description).joined(separator: "\n"))
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.leading, 48)
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
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
                Image(systemName: "cylinder.split.1x2")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Databases")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.refreshDatabases()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            if !viewModel.recommendedDatabaseName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text("Recommended for your system (\(formatRAM(viewModel.systemRAMBytes)) RAM): ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.recommendedDatabaseName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Loading

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading database catalog...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Database List (grouped by tool)

    /// Groups databases by their tool property for sectioned display.
    private var groupedDatabases: [(tool: String, title: String, symbol: String, databases: [MetagenomicsDatabaseInfo])] {
        let toolOrder: [MetagenomicsTool] = [.kraken2, .esviritu, .taxtriage]
        var result: [(tool: String, title: String, symbol: String, databases: [MetagenomicsDatabaseInfo])] = []

        for tool in toolOrder {
            let dbs = viewModel.databases.filter { $0.tool == tool.rawValue }
            if !dbs.isEmpty {
                result.append((
                    tool: tool.rawValue,
                    title: tool.databaseSectionTitle,
                    symbol: tool.symbolName,
                    databases: dbs
                ))
            }
        }

        // Any remaining tools not in the explicit order
        let knownTools = Set(toolOrder.map(\.rawValue))
        let otherDbs = viewModel.databases.filter { !knownTools.contains($0.tool) }
        if !otherDbs.isEmpty {
            result.append((tool: "other", title: "Other Databases", symbol: "cylinder", databases: otherDbs))
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
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: section.symbol)
                            .foregroundStyle(Color.accentColor)
                        Text(section.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Storage Footer

    private var storageFooter: some View {
        HStack(spacing: 12) {
            Label {
                Text(viewModel.databaseStoragePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Button("Change Location...") {
                viewModel.chooseDatabaseStorageLocation()
            }
            .controlSize(.small)
            .font(.caption)

            Spacer()

            Text("Total: \(formatDatabaseBytes(viewModel.totalDatabaseStorageBytes)) used")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                            Label("Recommended", systemImage: "star.fill")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    HStack(spacing: 8) {
                        // Download size
                        Label(formatDatabaseBytes(database.sizeBytes), systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // RAM requirement
                        Label(formatDatabaseRAM(database.recommendedRAM), systemImage: "memorychip")
                            .font(.caption)
                            .foregroundStyle(exceedsSystemRAM ? .orange : .secondary)

                        if exceedsSystemRAM {
                            Text("(exceeds system RAM)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(database.description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)

                    Spacer()

                    Button("Dismiss") {
                        onDismissError()
                    }
                    .font(.caption)
                    .controlSize(.mini)
                }
                .padding(.leading, 34)
                .padding(.bottom, 2)
            }

            // Download progress
            if isDownloading, let progressValue = progress {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: progressValue)
                    if let message = progressMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch database.status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        case .corrupt:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
        case .volumeNotMounted:
            Image(systemName: "externaldrive.badge.questionmark")
                .foregroundStyle(.orange)
                .font(.title3)
        case .missing, .verifying:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
                .font(.title3)
        }
    }

    // MARK: - Action View

    @ViewBuilder
    private var actionView: some View {
        if isRemoving {
            ProgressView()
                .controlSize(.small)
        } else if isDownloading {
            Button(role: .cancel) {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .controlSize(.small)
            .help("Cancel this download")
        } else if database.status == .ready {
            HStack(spacing: 8) {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fontWeight(.medium)

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .controlSize(.small)
                .help("Remove this database and free disk space")
            }
        } else {
            Button {
                onDownload()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
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

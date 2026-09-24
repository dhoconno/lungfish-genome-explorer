// StorageSettingsTab.swift - Storage preferences tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishWorkflow

/// Storage preferences for shared managed storage.
///
/// Allows the user to choose where Lungfish stores managed third-party tools
/// and databases, and to clean up old local copies after a successful move.
struct StorageSettingsTab: View {
    struct ViewState: Equatable {
        let displayPath: String
        let displayState: ManagedStorageDisplayState
        let previousRootPath: String?
        let locationBadgeText: String
        let locationStatusDescription: String
        let showsMalformedBootstrapWarning: Bool
        let showsCleanupAction: Bool
        let canRevealCurrentLocation: Bool
    }

    @State private var isSharingWithPreview = false
    @State private var displayPath: String = ""
    @State private var displayState: ManagedStorageDisplayState = .defaultRoot
    @State private var previousRootPath: String?
    @State private var currentOperationMessage: String?
    @State private var showingCleanupConfirmation: Bool = false
    @State private var showingErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var isWorking: Bool = false
    @State private var canRevealCurrentLocation: Bool = false
    @State private var dedupeReport: ManagedStorageDedupeReport?
    @State private var showingDedupeConfirmation: Bool = false

    private let storageCoordinator: ManagedStorageCoordinator

    init(storageCoordinator: ManagedStorageCoordinator = ManagedStorageCoordinator()) {
        self.storageCoordinator = storageCoordinator
    }

    @MainActor
    static func makeViewState(
        configStore: ManagedStorageConfigStore = ManagedStorageConfigStore.shared,
        fileManager: FileManager = .default
    ) -> ViewState {
        let bootstrapState = configStore.bootstrapConfigLoadState()
        let displayState: ManagedStorageDisplayState
        switch bootstrapState {
        case .malformed:
            displayState = .malformedBootstrap
        case .loaded(let config):
            let location = ManagedStorageLocation(
                rootURL: URL(fileURLWithPath: config.activeRootPath, isDirectory: true)
            )
            displayState = location.rootURL.standardizedFileURL == configStore.defaultLocation.rootURL.standardizedFileURL
                ? .defaultRoot
                : .customRoot(location)
        case .missing:
            let location = configStore.currentLocation()
            displayState = location.rootURL.standardizedFileURL == configStore.defaultLocation.rootURL.standardizedFileURL
                ? .defaultRoot
                : .customRoot(location)
        }

        let displayPath = switch displayState {
        case .defaultRoot, .malformedBootstrap:
            configStore.defaultLocation.rootURL.path
        case .customRoot(let location):
            location.rootURL.path
        }

        let previousRootPath: String?
        if case .loaded(let config) = bootstrapState,
           config.migrationState == .completed,
           let candidatePath = config.previousRootPath,
           !candidatePath.isEmpty {
            previousRootPath = candidatePath
        } else {
            previousRootPath = nil
        }

        let locationBadgeText = switch displayState {
        case .defaultRoot:
            "Recommended"
        case .customRoot:
            "Custom"
        case .malformedBootstrap:
            "Needs Attention"
        }

        let locationStatusDescription = switch displayState {
        case .defaultRoot:
            "Lungfish is using the default shared storage root."
        case .customRoot(let location):
            "Managed tools and databases are being stored under \(location.rootURL.lastPathComponent)."
        case .malformedBootstrap:
            "The bootstrap config needs attention. The default shared storage root is being used right now."
        }

        return ViewState(
            displayPath: displayPath,
            displayState: displayState,
            previousRootPath: previousRootPath,
            locationBadgeText: configStore.automaticallySharedPreviewLocation != nil ? "Shared with Preview" : locationBadgeText,
            locationStatusDescription: configStore.automaticallySharedPreviewLocation != nil
                ? "Dependency pins match. Debug is using Preview’s tools and databases." : locationStatusDescription,
            showsMalformedBootstrapWarning: displayState == .malformedBootstrap,
            showsCleanupAction: previousRootPath != nil,
            canRevealCurrentLocation: fileManager.fileExists(atPath: displayPath)
        )
    }

    var body: some View {
        Form {
            Section("Storage Location") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Third-Party Tools and Databases are stored at this location.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .foregroundStyle(.secondary)

                        Text(displayPath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier(SettingsAccessibilityID.storagePath)

                        Spacer(minLength: 12)

                        Text(locationBadgeText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(locationBadgeColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(locationBadgeBackground)
                            .clipShape(Capsule())
                            .accessibilityIdentifier(SettingsAccessibilityID.storageBadge)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(locationStatusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(SettingsAccessibilityID.storageStatus)

                    if let currentOperationMessage {
                        Label(currentOperationMessage, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(SettingsAccessibilityID.storageOperation)
                    }

                    if case .malformedBootstrap = displayState {
                        Label(
                            "The managed storage config could not be read. Lungfish is using the default location until you pick a new one.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(SettingsAccessibilityID.storageWarning)
                    }

                    if let previousRootPath {
                        Label(
                            "Old local copies are still present at \(previousRootPath). Remove them after you have confirmed the new location is working.",
                            systemImage: "trash"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(SettingsAccessibilityID.storagePreviousRoot)
                    }

                    HStack(spacing: 12) {
                        Button("Change Location...") {
                            chooseDirectory()
                        }
                        .disabled(isWorking)
                        .accessibilityIdentifier(SettingsAccessibilityID.storageChangeLocationButton)

                        Button("Reveal in Finder") {
                            revealCurrentLocation()
                        }
                        .disabled(!canRevealCurrentLocation || isWorking)
                        .accessibilityIdentifier(SettingsAccessibilityID.storageRevealButton)

                        if displayState != .defaultRoot {
                            Button("Use Default Location") {
                                moveToDefaultLocation()
                            }
                            .disabled(isWorking)
                            .accessibilityIdentifier(SettingsAccessibilityID.storageUseDefaultButton)
                        }

                        Spacer()

                        if previousRootPath != nil {
                            Button("Remove old local copies...") {
                                showingCleanupConfirmation = true
                            }
                            .tint(.lungfishDangerFallback)
                            .disabled(isWorking)
                            .accessibilityIdentifier(SettingsAccessibilityID.storageCleanupButton)
                        }
                    }
                }
            }

            Section("Shared Space") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Preview, stable, and Debug keep separate storage roots, and identical databases and tool packages are stored once as APFS clones. Roots filled before sharing existed may still hold full duplicate copies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let dedupeReport {
                        Text(Self.dedupeSummary(dedupeReport))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(SettingsAccessibilityID.storageDedupeStatus)
                    }

                    Button("Reclaim Duplicate Space...") {
                        scanForDuplicateSpace()
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier(SettingsAccessibilityID.storageDedupeButton)
                }
            }

            Section("About Managed Storage") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Managed tools and downloaded databases share one storage root", systemImage: "folder.badge.gearshape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Changing location migrates databases and reprovisions managed tools", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Use cleanup only after confirming the new storage location works", systemImage: "trash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier(SettingsAccessibilityID.storageForm)
        .onAppear {
            refreshDisplay()
        }
        .confirmationDialog(
            "Remove old local copies?",
            isPresented: $showingCleanupConfirmation
        ) {
            Button("Remove old local copies") {
                removeOldLocalCopies()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let previousRootPath {
                Text("This will delete migrated tool and database files from \(previousRootPath).")
            }
        }
        .confirmationDialog(
            "Reclaim duplicate space?",
            isPresented: $showingDedupeConfirmation
        ) {
            Button("Reclaim \(Self.formatBytes(dedupeReport?.bytesReclaimable ?? 0))") {
                applyDuplicateSpaceReclaim()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let dedupeReport {
                Text("\(dedupeReport.duplicateFiles) duplicate file(s) across \(dedupeReport.roots.count) root(s) will be replaced by verified clones of one kept copy. Open files and files linked outside the roots are left alone.")
            }
        }
        .alert("Storage Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func dedupeSummary(_ report: ManagedStorageDedupeReport) -> String {
        switch report.mode {
        case .dryRun where !report.blockers.isEmpty:
            return "A managed install is in progress. Try again when it finishes."
        case .dryRun where report.bytesReclaimable == 0:
            return "No duplicate space to reclaim across \(report.roots.count) root(s). \(formatBytes(report.bytesAlreadyShared)) already shared."
        case .dryRun:
            return "\(formatBytes(report.bytesReclaimable)) reclaimable in \(report.duplicateFiles) duplicate file(s)."
        case .apply:
            let failures = report.failures.isEmpty ? "" : " \(report.failures.count) file(s) could not be replaced."
            return "Reclaimed \(formatBytes(report.bytesReclaimed)) by replacing \(report.replacements.count) file(s).\(failures)"
        }
    }

    @MainActor
    private func scanForDuplicateSpace() {
        let roots = ManagedStorageChannelRoots.existingRoots()
        isWorking = true
        currentOperationMessage = "Scanning storage roots for duplicate files..."
        Task {
            do {
                let report = try await Task.detached(priority: .utility) {
                    try ManagedStorageDeduplicator().dryRun(ManagedStorageDedupeOptions(roots: roots))
                }.value
                dedupeReport = report
                if report.bytesReclaimable > 0, report.blockers.isEmpty {
                    showingDedupeConfirmation = true
                }
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
            isWorking = false
            currentOperationMessage = nil
        }
    }

    @MainActor
    private func applyDuplicateSpaceReclaim() {
        let roots = ManagedStorageChannelRoots.existingRoots()
        isWorking = true
        currentOperationMessage = "Replacing duplicate files with clones..."
        Task {
            do {
                dedupeReport = try await Task.detached(priority: .utility) {
                    try ManagedStorageDeduplicator().apply(ManagedStorageDedupeOptions(roots: roots))
                }.value
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
            isWorking = false
            currentOperationMessage = nil
        }
    }

    private var locationBadgeText: String {
        if isSharingWithPreview { return "Shared with Preview" }
        switch displayState {
        case .defaultRoot:
            return "Recommended"
        case .customRoot:
            return "Custom"
        case .malformedBootstrap:
            return "Needs Attention"
        }
    }

    private var locationBadgeColor: Color {
        switch displayState {
        case .defaultRoot:
            return .secondary
        case .customRoot:
            return .blue
        case .malformedBootstrap:
            return .orange
        }
    }

    private var locationBadgeBackground: Color {
        switch displayState {
        case .defaultRoot:
            return Color.secondary.opacity(0.12)
        case .customRoot:
            return Color.blue.opacity(0.12)
        case .malformedBootstrap:
            return Color.orange.opacity(0.14)
        }
    }

    private var locationStatusDescription: String {
        if isSharingWithPreview { return "Dependency pins match. Debug is using Preview’s tools and databases." }
        switch displayState {
        case .defaultRoot:
            return "Lungfish is using the default shared storage root."
        case .customRoot(let location):
            return "Managed tools and databases are being stored under \(location.rootURL.lastPathComponent)."
        case .malformedBootstrap:
            return "The bootstrap config needs attention. The default shared storage root is being used right now."
        }
    }

    private func chooseDirectory() {
        let panel = AppFilePanelFactory.managedStorageLocationPanel()

        let completionHandler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            updateManagedStorageLocation(to: url)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completionHandler)
        } else {
            panel.begin(completionHandler: completionHandler)
        }
    }

    private func moveToDefaultLocation() {
        updateManagedStorageLocation(to: ManagedStorageConfigStore.shared.defaultLocation.rootURL)
    }

    private func revealCurrentLocation() {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: displayPath, isDirectory: true)
        ])
    }

    @MainActor
    private func updateManagedStorageLocation(to url: URL) {
        let targetURL = url.standardizedFileURL
        let defaultRoot = ManagedStorageConfigStore.shared.defaultLocation.rootURL
        isWorking = true
        currentOperationMessage = targetURL == defaultRoot
            ? "Moving managed storage to the default location..."
            : "Moving managed storage to the selected location..."

        Task {
            do {
                if case .malformedBootstrap = displayState, targetURL == defaultRoot {
                    try ManagedStorageConfigStore.shared.resetToDefaultLocation()
                } else {
                    try await storageCoordinator.changeLocation(to: targetURL)
                }
                NotificationCenter.default.post(name: .databaseStorageLocationChanged, object: nil)
                refreshDisplay()
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
                refreshDisplay()
            }

            isWorking = false
            currentOperationMessage = nil
        }
    }

    @MainActor
    private func removeOldLocalCopies() {
        isWorking = true
        currentOperationMessage = "Removing old local copies..."

        Task {
            do {
                try await storageCoordinator.removeOldLocalCopies()
                refreshDisplay()
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
                refreshDisplay()
            }

            isWorking = false
            currentOperationMessage = nil
        }
    }

    @MainActor
    private func refreshDisplay() {
        let viewState = Self.makeViewState()
        isSharingWithPreview = ManagedStorageConfigStore.shared.automaticallySharedPreviewLocation != nil
        displayPath = viewState.displayPath
        displayState = viewState.displayState
        previousRootPath = viewState.previousRootPath
        canRevealCurrentLocation = viewState.canRevealCurrentLocation
    }
}

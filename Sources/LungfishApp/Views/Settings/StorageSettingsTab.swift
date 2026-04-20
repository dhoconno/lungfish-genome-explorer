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

    @State private var displayPath: String = ""
    @State private var displayState: ManagedStorageDisplayState = .defaultRoot
    @State private var previousRootPath: String?
    @State private var currentOperationMessage: String?
    @State private var showingCleanupConfirmation: Bool = false
    @State private var showingErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var isWorking: Bool = false
    @State private var canRevealCurrentLocation: Bool = false

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
            locationBadgeText: locationBadgeText,
            locationStatusDescription: locationStatusDescription,
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
                            Button("Remove old local copies...", role: .destructive) {
                                showingCleanupConfirmation = true
                            }
                            .disabled(isWorking)
                            .accessibilityIdentifier(SettingsAccessibilityID.storageCleanupButton)
                        }
                    }
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
            Button("Remove old local copies", role: .destructive) {
                removeOldLocalCopies()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let previousRootPath {
                Text("This will delete migrated tool and database files from \(previousRootPath).")
            }
        }
        .alert("Storage Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var locationBadgeText: String {
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a storage location for managed tools and databases. The full resolved path cannot contain spaces."

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
                await MainActor.run {
                    NotificationCenter.default.post(name: .databaseStorageLocationChanged, object: nil)
                    refreshDisplay()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingErrorAlert = true
                    refreshDisplay()
                }
            }

            await MainActor.run {
                isWorking = false
                currentOperationMessage = nil
            }
        }
    }

    private func removeOldLocalCopies() {
        isWorking = true
        currentOperationMessage = "Removing old local copies..."

        Task {
            do {
                try await storageCoordinator.removeOldLocalCopies()
                await MainActor.run {
                    refreshDisplay()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingErrorAlert = true
                    refreshDisplay()
                }
            }

            await MainActor.run {
                isWorking = false
                currentOperationMessage = nil
            }
        }
    }

    private func refreshDisplay() {
        let viewState = Self.makeViewState()
        displayPath = viewState.displayPath
        displayState = viewState.displayState
        previousRootPath = viewState.previousRootPath
        canRevealCurrentLocation = viewState.canRevealCurrentLocation
    }
}

// WelcomeWindowController.swift - Launch experience and project selection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead - HIG Expert (Role 2)

import AppKit
import SwiftUI
import LungfishCore
import LungfishWorkflow
import os.log

/// Logger for welcome window
private let logger = Logger(subsystem: LogSubsystem.app, category: "WelcomeWindow")

// MARK: - Recent Projects Manager

/// Manages the list of recently opened projects
@MainActor
public final class RecentProjectsManager: ObservableObject {
    /// Singleton instance
    public static let shared = RecentProjectsManager()

    /// Maximum number of recent projects to track
    private let maxRecentProjects = 10

    /// UserDefaults key for recent projects
    private let recentProjectsKey = "com.lungfish.recentProjects"

    /// Last used project key
    private let lastProjectKey = "com.lungfish.lastProject"

    /// Recent project entries
    @Published public private(set) var recentProjects: [RecentProject] = []

    private init() {
        loadRecentProjects()
    }

    /// Adds a project to the recent list
    public func addRecentProject(url: URL, name: String) {
        logger.info("Adding recent project: \(name, privacy: .public) at \(url.path, privacy: .public)")

        // Remove any existing entry for this URL
        recentProjects.removeAll { $0.url == url }

        // Add to front
        let entry = RecentProject(url: url, name: name, lastOpened: Date())
        recentProjects.insert(entry, at: 0)

        // Trim to max size
        if recentProjects.count > maxRecentProjects {
            recentProjects = Array(recentProjects.prefix(maxRecentProjects))
        }

        saveRecentProjects()
        saveLastProject(url: url)
    }

    /// Removes a project from the recent list
    public func removeRecentProject(at index: Int) {
        guard index >= 0 && index < recentProjects.count else { return }
        recentProjects.remove(at: index)
        saveRecentProjects()
    }

    /// Clears all recent projects
    public func clearRecentProjects() {
        recentProjects = []
        saveRecentProjects()
    }

    /// Gets the last opened project URL
    public var lastProjectURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: lastProjectKey) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        // Verify it still exists
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private

    private func loadRecentProjects() {
        guard let data = UserDefaults.standard.data(forKey: recentProjectsKey),
              let projects = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            recentProjects = []
            return
        }

        // Filter out projects that no longer exist
        recentProjects = projects.filter { project in
            FileManager.default.fileExists(atPath: project.url.path)
        }
    }

    private func saveRecentProjects() {
        guard let data = try? JSONEncoder().encode(recentProjects) else { return }
        UserDefaults.standard.set(data, forKey: recentProjectsKey)
    }

    private func saveLastProject(url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastProjectKey)
    }
}

/// Represents a recently opened project
public struct RecentProject: Codable, Identifiable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let lastOpened: Date

    /// Checks if the project still exists on disk
    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Formatted last opened date
    public var lastOpenedFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastOpened, relativeTo: Date())
    }
}

// MARK: - Welcome View Model

@MainActor
final class WelcomeViewModel: ObservableObject {
    @Published var selectedAction: WelcomeAction?
    @Published var isLoading = false
    @Published private(set) var isRefreshingSetup = false
    @Published var isInstallingRequiredSetup = false
    @Published var requiredSetupProgress: Double?
    @Published var requiredSetupProgressMessage: String?
    @Published var requiredSetupItemProgress: [String: Double] = [:]
    @Published var requiredSetupActiveItemID: String?
    @Published private(set) var requiredSetupStatus: PluginPackStatus?
    @Published private(set) var optionalPackStatuses: [PluginPackStatus] = []
    @Published var setupErrorMessage: String?
    @Published var showingSetupDetails = false
    @Published var showingStorageChooser = false
    @Published var pendingStorageSelection: URL?
    @Published var storageValidationResult: ManagedStorageLocation.ValidationResult = .valid
    @Published private(set) var isApplyingStorageSelection = false
    @Published private(set) var storageOperationMessage: String?
    @Published var storageOperationErrorMessage: String?

    let recentProjects = RecentProjectsManager.shared
    private let statusProvider: any PluginPackStatusProviding
    private let storageCoordinator: ManagedStorageCoordinator
    private let storageConfigStore: ManagedStorageConfigStore
    private let notificationCenter: NotificationCenter

    var onCreateProject: ((URL) -> Void)?
    var onOpenProject: ((URL) -> Void)?
    var onOpenOptionalPack: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    init(
        statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared,
        storageCoordinator: ManagedStorageCoordinator? = nil,
        storageConfigStore: ManagedStorageConfigStore? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        let resolvedStorageConfigStore = storageConfigStore ?? ManagedStorageConfigStore.shared
        self.statusProvider = statusProvider
        self.storageConfigStore = resolvedStorageConfigStore
        self.storageCoordinator = storageCoordinator ?? ManagedStorageCoordinator(configStore: resolvedStorageConfigStore)
        self.notificationCenter = notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(handleManagedResourcesDidChange(_:)),
            name: .managedResourcesDidChange,
            object: nil
        )
    }

    @objc private func handleManagedResourcesDidChange(_ notification: Notification) {
        Task { @MainActor in
            await refreshSetup()
        }
    }

    var canLaunch: Bool {
        requiredSetupStatus?.state == .ready && !isInstallingRequiredSetup
    }

    var currentStorageRootURL: URL {
        storageConfigStore.currentLocation().rootURL
    }

    var defaultStorageRootURL: URL {
        storageConfigStore.defaultLocation.rootURL
    }

    private var isUsingDefaultStorageRoot: Bool {
        currentStorageRootURL.resolvingSymlinksInPath().standardizedFileURL
            == defaultStorageRootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    var storageReferenceTitle: String {
        isUsingDefaultStorageRoot ? "Default location" : "Current location"
    }

    var storageReferenceRootURL: URL {
        isUsingDefaultStorageRoot
            ? defaultStorageRootURL.resolvingSymlinksInPath().standardizedFileURL
            : currentStorageRootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    var storageReferenceMessage: String {
        isUsingDefaultStorageRoot
            ? "Close this sheet to keep using the default location."
            : "Close this sheet to keep using the current location."
    }

    var isStorageChooserEnabled: Bool {
        !isInstallingRequiredSetup && !isRefreshingSetup && !isApplyingStorageSelection
    }

    var canConfirmStorageSelection: Bool {
        guard let pendingStorageSelection else {
            return false
        }
        guard isStorageChooserEnabled else {
            return false
        }
        guard case .valid = storageValidationResult else {
            return false
        }
        return pendingStorageSelection != currentStorageRootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    var pendingStorageSelectionPath: String {
        pendingStorageSelection?.path ?? "No alternate storage location selected yet."
    }

    var storageValidationMessage: String? {
        switch storageValidationResult {
        case .valid:
            return nil
        case .invalid(let error):
            return error.errorDescription
        }
    }

    private var pendingConfirmedStorageSelection: URL? {
        guard isStorageChooserEnabled else {
            return nil
        }
        guard case .valid = storageValidationResult, let selection = pendingStorageSelection else {
            return nil
        }
        guard selection != currentStorageRootURL.resolvingSymlinksInPath().standardizedFileURL else {
            return nil
        }
        return selection
    }

    private var shouldAutoInstallRequiredSetupAfterStorageSelection: Bool {
        guard let requiredSetupStatus else {
            return false
        }
        return requiredSetupStatus.state != .ready && !isInstallingRequiredSetup
    }

    func refreshSetup() async {
        isRefreshingSetup = true
        requiredSetupStatus = nil
        optionalPackStatuses = []
        defer { isRefreshingSetup = false }
        let statuses = await statusProvider.visibleStatuses()
        requiredSetupStatus = statuses.first(where: { $0.pack.isRequiredBeforeLaunch })
        optionalPackStatuses = statuses.filter { !$0.pack.isRequiredBeforeLaunch }
    }

    func installRequiredSetup() {
        guard let pack = requiredSetupStatus?.pack else { return }
        isInstallingRequiredSetup = true
        setupErrorMessage = nil
        requiredSetupProgress = 0
        requiredSetupProgressMessage = "Preparing \(pack.name)…"
        requiredSetupItemProgress = [:]
        requiredSetupActiveItemID = nil
        showingSetupDetails = true

        Task {
            defer {
                isInstallingRequiredSetup = false
                requiredSetupActiveItemID = nil
            }
            do {
                try await statusProvider.install(
                    pack: pack,
                    reinstall: requiredSetupStatus?.shouldReinstall == true,
                    progress: { [weak self] event in
                        Task { @MainActor in
                            self?.requiredSetupProgress = min(max(event.overallFraction, 0), 1)
                            self?.requiredSetupProgressMessage = event.message
                            self?.requiredSetupActiveItemID = event.requirementID
                            if let requirementID = event.requirementID {
                                self?.requiredSetupItemProgress[requirementID] = min(max(event.itemFraction, 0), 1)
                            }
                        }
                    }
                )
                await refreshSetup()
                requiredSetupItemProgress = [:]
                requiredSetupProgress = nil
                requiredSetupProgressMessage = nil
            } catch {
                setupErrorMessage = error.localizedDescription
            }
        }
    }

    func validateStorageSelection(_ url: URL) -> ManagedStorageLocation.ValidationResult {
        ManagedStorageLocation.validateSelection(url)
    }

    func chooseAlternateStorageLocation() {
        guard isStorageChooserEnabled else { return }
        storageOperationMessage = nil
        storageOperationErrorMessage = nil
        let currentRoot = currentStorageRootURL.resolvingSymlinksInPath().standardizedFileURL
        let defaultRoot = defaultStorageRootURL.resolvingSymlinksInPath().standardizedFileURL
        if currentRoot != defaultRoot {
            pendingStorageSelection = currentRoot
            storageValidationResult = validateStorageSelection(currentRoot)
        } else {
            pendingStorageSelection = nil
            storageValidationResult = .valid
        }
        showingStorageChooser = true
    }

    func updatePendingStorageSelection(_ url: URL) {
        let selection = url.resolvingSymlinksInPath().standardizedFileURL
        pendingStorageSelection = selection
        storageValidationResult = validateStorageSelection(selection)
        storageOperationErrorMessage = nil
    }

    func dismissStorageChooser() {
        showingStorageChooser = false
        pendingStorageSelection = nil
        storageValidationResult = .valid
        storageOperationMessage = nil
        storageOperationErrorMessage = nil
    }

    func applyPendingStorageSelection() async -> Bool {
        guard let selection = pendingConfirmedStorageSelection else {
            return false
        }

        isApplyingStorageSelection = true
        storageOperationMessage = "Applying the new storage location… Existing managed databases can take a while to copy."
        storageOperationErrorMessage = nil
        defer {
            isApplyingStorageSelection = false
            storageOperationMessage = nil
        }

        logger.info("Applying alternate storage location: \(selection.path, privacy: .public)")

        do {
            try await performStorageLocationChange(to: selection)
            if shouldAutoInstallRequiredSetupAfterStorageSelection {
                installRequiredSetup()
            }
            return true
        } catch {
            logger.error("Failed to apply alternate storage location: \(error.localizedDescription, privacy: .public)")
            storageOperationErrorMessage = error.localizedDescription
            return false
        }
    }

    func confirmAlternateStorageLocation() async throws {
        guard let selection = pendingConfirmedStorageSelection else {
            return
        }

        try await performStorageLocationChange(to: selection)
    }

    private func performStorageLocationChange(to selection: URL) async throws {
        try await storageCoordinator.changeLocation(to: selection)
        await statusProvider.invalidateVisibleStatusesCache()
        NotificationCenter.default.post(name: .databaseStorageLocationChanged, object: nil)
        showingStorageChooser = false
        pendingStorageSelection = nil
        storageValidationResult = .valid
        storageOperationErrorMessage = nil
        storageOperationMessage = "Refreshing setup…"
        await refreshSetup()
    }
}

enum WelcomeAction: String, Identifiable, CaseIterable {
    case createProject = "Create Project"
    case openProject = "Open Project"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .createProject: return "folder.badge.plus"
        case .openProject: return "folder"
        }
    }

    var description: String {
        switch self {
        case .createProject: return "Create a new project folder to organize your work"
        case .openProject: return "Open an existing Lungfish project"
        }
    }
}

enum WelcomeSection: String, Identifiable, CaseIterable {
    case getStarted = "Get Started"
    case recentProjects = "Recent Projects"
    case requiredSetup = "Required Setup"
    case optionalTools = "Optional Tools"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .getStarted: return "sparkles"
        case .recentProjects: return "clock"
        case .requiredSetup: return "checklist"
        case .optionalTools: return "puzzlepiece.extension"
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @ObservedObject var viewModel: WelcomeViewModel
    @State private var hoveredAction: WelcomeAction?
    @State private var selectedSection: WelcomeSection = .getStarted

    private var navigationSections: [WelcomeSection] {
        var sections: [WelcomeSection] = [.getStarted, .recentProjects, .requiredSetup]
        if !viewModel.optionalPackStatuses.isEmpty {
            sections.append(.optionalTools)
        }
        return sections
    }

    var body: some View {
        ZStack {
            Color.lungfishWelcomeBackground
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 18) {
                welcomeSidebar

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        headerRow
                        selectedSectionContent
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 30)
                }
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color.lungfishWelcomeBackground)
                )
            }
            .padding(18)
            .frame(minWidth: 1080, minHeight: 680)
        }
        .alert(
            "Setup Error",
            isPresented: Binding(
                get: { viewModel.setupErrorMessage != nil },
                set: { if !$0 { viewModel.setupErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.setupErrorMessage = nil
            }
        } message: {
            Text(viewModel.setupErrorMessage ?? "")
        }
        .sheet(
            isPresented: $viewModel.showingStorageChooser,
            onDismiss: { viewModel.dismissStorageChooser() }
        ) {
            WelcomeStorageChooserSheet(viewModel: viewModel) {
                Task { @MainActor in
                    await showStorageLocationPanel()
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(sectionTitle)
                    .font(.system(size: 38, weight: .bold))

                Text(sectionSubtitle)
                    .font(.title3)
                    .foregroundStyle(Color.lungfishWelcomeSecondaryText)
            }

            Spacer(minLength: 12)

            if let status = viewModel.requiredSetupStatus {
                StatusPill(
                    title: status.state == .ready ? "Core Tools Installed" : "Setup Needed",
                    color: status.state == .ready ? .lungfishSageFallback : .lungfishCreamsicleFallback
                )
            } else if viewModel.isRefreshingSetup {
                StatusPill(
                    title: "Checking Setup",
                    color: .lungfishWarmGreyFallback
                )
            }
        }
        .padding(.bottom, 4)
    }

    private var sectionTitle: String {
        switch selectedSection {
        case .getStarted:
            return "Start a Project"
        case .recentProjects:
            return "Recent Projects"
        case .requiredSetup:
            return "Required Setup"
        case .optionalTools:
            return "Optional Tools"
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .getStarted:
            return "Create a new project and make sure Lungfish is ready before you begin."
        case .recentProjects:
            return "Reopen the projects you worked on recently."
        case .requiredSetup:
            return "Install the tools and data Lungfish needs before you begin."
        case .optionalTools:
            return "Add more tools when you need them for specific tasks."
        }
    }

    private var emptyRecentProjectsState: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.lungfishWelcomeCardBackground)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                    Text("No recent projects")
                        .font(.headline)
                    Text("Create a project or open an existing one to see it here.")
                        .font(.subheadline)
                        .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                }
                .padding(28)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .getStarted:
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    ForEach(WelcomeAction.allCases) { action in
                        LaunchActionTile(
                            action: action,
                            isHovered: hoveredAction == action,
                            isEnabled: viewModel.canLaunch,
                            onTap: { performAction(action) }
                        )
                        .onHover { isHovered in
                            hoveredAction = isHovered ? action : nil
                        }
                    }
                }

                if viewModel.isRefreshingSetup && viewModel.requiredSetupStatus == nil {
                    SetupLoadingCard(
                        title: "Checking Required Setup",
                        message: "Please wait while Lungfish checks the third-party tools and data it needs before you begin."
                    )
                } else if let requiredStatus = viewModel.requiredSetupStatus {
                    RequiredSetupCard(
                        status: requiredStatus,
                        isInstalling: viewModel.isInstallingRequiredSetup,
                        progressValue: viewModel.requiredSetupProgress,
                        progressMessage: viewModel.requiredSetupProgressMessage,
                        itemProgress: viewModel.requiredSetupItemProgress,
                        activeItemID: viewModel.requiredSetupActiveItemID,
                        showingDetails: $viewModel.showingSetupDetails,
                        onInstall: { viewModel.installRequiredSetup() },
                        onChooseAlternateStorage: { viewModel.chooseAlternateStorageLocation() },
                        isStorageChooserEnabled: viewModel.isStorageChooserEnabled
                    )
                }
            }

        case .recentProjects:
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.isRefreshingSetup && viewModel.requiredSetupStatus == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.lungfishCreamsicleFallback)
                        Text("Checking required setup before recent projects become available.")
                            .font(.subheadline)
                            .foregroundColor(.lungfishWelcomeSecondaryText)
                    }
                } else if !viewModel.canLaunch {
                    Text("Finish required setup before opening a recent project.")
                        .font(.subheadline)
                        .foregroundColor(.lungfishWelcomeSecondaryText)
                }

                if viewModel.recentProjects.recentProjects.isEmpty {
                    emptyRecentProjectsState
                } else {
                    VStack(spacing: 8) {
                        ForEach(viewModel.recentProjects.recentProjects) { project in
                            RecentProjectCard(
                                project: project,
                                isEnabled: viewModel.canLaunch
                            ) {
                                viewModel.onOpenProject?(project.url)
                            }
                        }
                    }
                }
            }

        case .requiredSetup:
            if viewModel.isRefreshingSetup && viewModel.requiredSetupStatus == nil {
                SetupLoadingCard(
                    title: "Checking Required Setup",
                    message: "Lungfish is checking each required third-party tool and required data item."
                )
            } else if let requiredStatus = viewModel.requiredSetupStatus {
                RequiredSetupCard(
                    status: requiredStatus,
                    isInstalling: viewModel.isInstallingRequiredSetup,
                    progressValue: viewModel.requiredSetupProgress,
                    progressMessage: viewModel.requiredSetupProgressMessage,
                    itemProgress: viewModel.requiredSetupItemProgress,
                    activeItemID: viewModel.requiredSetupActiveItemID,
                    showingDetails: $viewModel.showingSetupDetails,
                    onInstall: { viewModel.installRequiredSetup() },
                    onChooseAlternateStorage: { viewModel.chooseAlternateStorageLocation() },
                    isStorageChooserEnabled: viewModel.isStorageChooserEnabled
                )
            }

        case .optionalTools:
            if viewModel.isRefreshingSetup && viewModel.requiredSetupStatus == nil {
                SetupLoadingCard(
                    title: "Checking Optional Tools",
                    message: "Lungfish is checking optional tools that are available in this build."
                )
            } else if viewModel.optionalPackStatuses.isEmpty {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.lungfishWelcomeCardBackground)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.slash")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                            Text("No optional tools available")
                                .font(.headline)
                            Text("Active optional tools will appear here when they are ready to use in Lungfish.")
                                .font(.subheadline)
                                .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .padding(28)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320), spacing: 18)],
                    spacing: 18
                ) {
                    ForEach(viewModel.optionalPackStatuses) { status in
                        OptionalToolCard(
                            status: status,
                            onOpenPack: { viewModel.onOpenOptionalPack?($0) }
                        )
                    }
                }
            }
        }
    }

    private var welcomeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Welcome")
                    .font(.system(size: 28, weight: .bold))

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(navigationSections) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: section.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 18)
                                Text(section.rawValue)
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(selectedSection == section ? Color.lungfishWelcomeSelectionFill : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedSection == section ? Color.lungfishCreamsicleFallback : Color.primary)
                    }
                }
            }

            Spacer(minLength: 28)

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .overlay(Color.lungfishWelcomeStroke)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.4")")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishWelcomeSecondaryText)
            }
            .padding(.top, 22)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.lungfishWelcomeSidebarBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.lungfishWelcomeStroke, lineWidth: 1)
        )
    }

    private func performAction(_ action: WelcomeAction) {
        guard viewModel.canLaunch else { return }

        switch action {
        case .createProject:
            Task { @MainActor in
                await showCreateProjectPanel()
            }
        case .openProject:
            Task { @MainActor in
                await showOpenProjectPanel()
            }
        }
    }

    private func showCreateProjectPanel() async {
        let savePanel = NSSavePanel()
        savePanel.title = "Create New Project"
        savePanel.message = "Choose a location for your new Lungfish project"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = "My Genome Project"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [.folder]
        savePanel.isExtensionHidden = false

        guard let window = NSApp.keyWindow else { return }
        let response = await savePanel.beginSheetModal(for: window)
        if response == .OK, let url = savePanel.url {
            // Create the project directory with .lungfish extension
            let projectURL = url.deletingPathExtension().appendingPathExtension("lungfish")
            viewModel.onCreateProject?(projectURL)
        }
    }

    private func showOpenProjectPanel() async {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open Project"
        openPanel.message = "Select a Lungfish project folder"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false

        guard let window = NSApp.keyWindow else { return }
        let response = await openPanel.beginSheetModal(for: window)
        if response == .OK, let url = openPanel.url {
            viewModel.onOpenProject?(url)
        }
    }

    private func showStorageLocationPanel() async {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Storage Location"
        openPanel.message = "Select a storage location for managed tools and databases. The full resolved path cannot contain spaces."
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = "Choose"

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let response = await openPanel.beginSheetModal(for: window)
        if response == .OK, let url = openPanel.url {
            viewModel.updatePendingStorageSelection(url)
        }
    }
}

// MARK: - Welcome Components

private struct SetupLoadingCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.lungfishCreamsicleFallback)
                Text(title)
                    .font(.title3.weight(.semibold))
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.lungfishWelcomeSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.lungfishWelcomeCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.lungfishWelcomeStroke, lineWidth: 1)
                )
        )
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
    }
}

private struct LaunchActionTile: View {
    let action: WelcomeAction
    let isHovered: Bool
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 22) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.lungfishWelcomeIconBackground)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: action.icon)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.lungfishCreamsicleFallback)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text(action.rawValue)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(action.description)
                        .font(.system(size: 15))
                        .foregroundColor(.lungfishWelcomeSecondaryText)
                        .lineLimit(3)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.lungfishWelcomeCardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(isHovered ? Color.lungfishCreamsicleFallback.opacity(0.35) : Color.lungfishWelcomeStroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.55)
    }
}

// MARK: - Setup Cards

private struct RequiredSetupCard: View {
    let status: PluginPackStatus
    let isInstalling: Bool
    let progressValue: Double?
    let progressMessage: String?
    let itemProgress: [String: Double]
    let activeItemID: String?
    @Binding var showingDetails: Bool
    let onInstall: () -> Void
    let onChooseAlternateStorage: () -> Void
    let isStorageChooserEnabled: Bool

    private var isReady: Bool {
        status.state == .ready
    }

    private var actionTitle: String {
        status.shouldReinstall ? "Reinstall" : "Install"
    }

    private var statusColor: Color {
        isReady ? .lungfishSageFallback : .lungfishCreamsicleFallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 6) {
                    Text(status.pack.name)
                        .font(.title3.weight(.semibold))
                    Text(isReady
                         ? "\(status.pack.name) and required data are installed. You can create a project or open an existing one."
                         : "Lungfish needs a few third-party tools and required data before you can create or open a project.")
                        .font(.subheadline)
                        .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                }

                Spacer()

                StatusPill(
                    title: isReady ? "Ready" : "Needs Attention",
                    color: statusColor
                )
            }

            HStack(spacing: 12) {
                Button(actionTitle) {
                    onInstall()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.lungfishCreamsicleFallback)
                .disabled(isInstalling)

                Button(showingDetails ? "Hide Details" : "Show Details") {
                    showingDetails.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.lungfishCreamsicleFallback)
            }

            if !isReady {
                Button("Need more space? Choose another storage location…") {
                    onChooseAlternateStorage()
                }
                .buttonStyle(.link)
                .disabled(!isStorageChooserEnabled)
            }

            if isInstalling {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: min(max(progressValue ?? 0, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(.lungfishCreamsicleFallback)
                    Text(progressMessage ?? "Installing \(status.pack.name)…")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                }
            }

            if showingDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .overlay(Color.lungfishWelcomeStroke)
                        .padding(.bottom, 8)
                    ForEach(status.toolStatuses) { toolStatus in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Group {
                                    if isInstalling && activeItemID == toolStatus.id {
                                        ProgressView(value: min(max(itemProgress[toolStatus.id] ?? 0, 0), 1))
                                            .progressViewStyle(.circular)
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: statusSymbol(for: toolStatus))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(statusColor(for: toolStatus))
                                    }
                                }
                                .frame(width: 14, height: 14)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(toolStatus.requirement.displayName)
                                            .font(.caption.weight(.medium))
                                        if toolStatus.requirement.managedDatabaseID != nil {
                                            Text("Required Data")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Color.lungfishCreamsicleFallback.opacity(0.12))
                                                .clipShape(Capsule(style: .continuous))
                                        }
                                    }
                                }
                                Spacer()
                                Text(statusLabel(for: toolStatus))
                                    .font(.caption)
                                    .foregroundColor(.lungfishWelcomeSecondaryText)
                            }

                            if isInstalling, activeItemID == toolStatus.id {
                                ProgressView(value: min(max(itemProgress[toolStatus.id] ?? 0, 0), 1))
                                    .progressViewStyle(.linear)
                                    .tint(.lungfishCreamsicleFallback)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.lungfishWelcomeBackground)
                        )
                    }
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.lungfishWelcomeCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(statusColor.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func statusSymbol(for toolStatus: PackToolStatus) -> String {
        if toolStatus.isReady || (itemProgress[toolStatus.id] ?? 0) >= 1 {
            return "checkmark.circle.fill"
        }
        if isInstalling {
            return "circle.dashed"
        }
        return "exclamationmark.circle.fill"
    }

    private func statusColor(for toolStatus: PackToolStatus) -> Color {
        if toolStatus.isReady || (itemProgress[toolStatus.id] ?? 0) >= 1 {
            return .lungfishSageFallback
        }
        if isInstalling {
            return .lungfishWarmGreyFallback
        }
        return .lungfishCreamsicleFallback
    }

    private func statusLabel(for toolStatus: PackToolStatus) -> String {
        if isInstalling && activeItemID == toolStatus.id {
            let percent = Int((itemProgress[toolStatus.id] ?? 0) * 100)
            return "Installing \(percent)%"
        }
        if (itemProgress[toolStatus.id] ?? 0) >= 1 {
            return "Installed"
        }
        if isInstalling {
            return "Waiting…"
        }
        return toolStatus.statusText
    }
}

private struct WelcomeStorageChooserSheet: View {
    @ObservedObject var viewModel: WelcomeViewModel
    let onChooseFolder: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose Another Storage Location")
                .font(.title2.weight(.semibold))

            Text("Lungfish installs managed tools and databases in the default storage root unless you choose a different location before setup.")
                .font(.subheadline)
                .foregroundStyle(Color.lungfishWelcomeSecondaryText)

            VStack(alignment: .leading, spacing: 8) {
                Label(viewModel.storageReferenceTitle, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.lungfishSageFallback)
                Text(viewModel.storageReferenceRootURL.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text(viewModel.storageReferenceMessage)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishWelcomeSecondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.lungfishWelcomeBackground)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Alternate location")
                    .font(.headline)

                Text(viewModel.pendingStorageSelectionPath)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(
                        viewModel.pendingStorageSelection == nil
                            ? Color.lungfishWelcomeSecondaryText
                            : Color.primary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.lungfishWelcomeStroke, lineWidth: 1)
                    )

                if let validationMessage = viewModel.storageValidationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.lungfishCreamsicleFallback)
                }

                if let operationMessage = viewModel.storageOperationMessage {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)

                        Text(operationMessage)
                            .font(.footnote)
                    }
                    .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                }

                if let operationError = viewModel.storageOperationErrorMessage {
                    Label(operationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.lungfishCreamsicleFallback)
                }

                Button("Choose Folder…") {
                    onChooseFolder()
                }
                .buttonStyle(.bordered)
                .tint(.lungfishCreamsicleFallback)
                .disabled(!viewModel.isStorageChooserEnabled)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .disabled(viewModel.isApplyingStorageSelection)
                .keyboardShortcut(.cancelAction)

                Button("Use This Location") {
                    Task { @MainActor in
                        if await viewModel.applyPendingStorageSelection() {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.lungfishCreamsicleFallback)
                .disabled(!viewModel.canConfirmStorageSelection)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560)
        .background(Color.lungfishWelcomeCardBackground)
        .interactiveDismissDisabled(viewModel.isApplyingStorageSelection)
    }
}

private struct OptionalToolCard: View {
    let status: PluginPackStatus
    let onOpenPack: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.lungfishWelcomeIconBackground)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Circle()
                            .fill(status.state == .ready ? Color.lungfishSageFallback : Color.lungfishCreamsicleFallback)
                            .frame(width: 10, height: 10)
                            .offset(x: -13, y: -13)

                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.lungfishCreamsicleFallback)
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text(status.pack.name)
                        .font(.system(size: 19, weight: .semibold))
                    Text(status.pack.description)
                        .font(.subheadline)
                        .foregroundStyle(Color.lungfishWelcomeSecondaryText)
                        .lineLimit(3)
                }

                Spacer()

                Button("Open") {
                    onOpenPack(status.pack.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.lungfishCreamsicleFallback)
            }

            Text(status.state == .ready ? "Installed and ready to use." : "Available to install when you need it.")
                .font(.subheadline)
                .foregroundStyle(Color.lungfishWelcomeSecondaryText)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.lungfishWelcomeCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.lungfishWelcomeStroke, lineWidth: 1)
                )
        )
    }
}

// MARK: - Recent Project Card

private struct RecentProjectCard: View {
    let project: RecentProject
    let isEnabled: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.lungfishWelcomeIconBackground)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.lungfishCreamsicleFallback)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(project.url.path)
                        .font(.system(size: 12))
                        .foregroundColor(.lungfishWelcomeSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                Text(project.lastOpenedFormatted)
                    .font(.caption)
                    .foregroundColor(.lungfishWelcomeSecondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.lungfishWelcomeCardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(isHovered ? Color.lungfishCreamsicleFallback.opacity(0.28) : Color.lungfishWelcomeStroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.55)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Welcome Window Controller

@MainActor
public final class WelcomeWindowController: NSWindowController {

    private var viewModel: WelcomeViewModel!
    private let statusProvider: any PluginPackStatusProviding
    private let storageConfigStore: ManagedStorageConfigStore
    private let storageCoordinator: ManagedStorageCoordinator

    /// Completion handler called when user makes a selection
    public var onProjectSelected: ((URL) -> Void)?
    public var onOptionalPackSelected: ((String) -> Void)?

    public init(
        statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared,
        storageConfigStore: ManagedStorageConfigStore? = nil,
        storageCoordinator: ManagedStorageCoordinator? = nil
    ) {
        let resolvedStorageConfigStore = storageConfigStore ?? ManagedStorageConfigStore.shared
        self.statusProvider = statusProvider
        self.storageConfigStore = resolvedStorageConfigStore
        self.storageCoordinator = storageCoordinator ?? ManagedStorageCoordinator(configStore: resolvedStorageConfigStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Lungfish Genome Explorer"
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 1080, height: 680)
        window.center()

        super.init(window: window)

        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        viewModel = WelcomeViewModel(
            statusProvider: statusProvider,
            storageCoordinator: storageCoordinator,
            storageConfigStore: storageConfigStore
        )

        viewModel.onCreateProject = { [weak self] url in
            logger.info("Creating project at: \(url.path, privacy: .public)")
            self?.createProject(at: url)
        }

        viewModel.onOpenProject = { [weak self] url in
            logger.info("Opening project at: \(url.path, privacy: .public)")
            self?.openProject(at: url)
        }

        viewModel.onOpenOptionalPack = { [weak self] packID in
            logger.info("Opening optional tool pack: \(packID, privacy: .public)")
            self?.onOptionalPackSelected?(packID)
        }

        let welcomeView = WelcomeView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: welcomeView)
        window?.contentView = hostingView

        Task {
            await viewModel.refreshSetup()
        }
    }

    private func createProject(at url: URL) {
        do {
            // Create the project
            let project = try DocumentManager.shared.createProject(
                at: url,
                name: url.deletingPathExtension().lastPathComponent
            )

            // Add to recent projects
            RecentProjectsManager.shared.addRecentProject(
                url: project.url,
                name: project.name
            )

            // Close welcome window and notify
            window?.close()
            onProjectSelected?(project.url)

        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Create Project"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            if let window = self.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func openProject(at url: URL) {
        do {
            // Open the project
            let project = try DocumentManager.shared.openProject(at: url)

            // Add to recent projects
            RecentProjectsManager.shared.addRecentProject(
                url: project.url,
                name: project.name
            )

            // Close welcome window and notify
            window?.close()
            onProjectSelected?(project.url)

        } catch {
            // If it's not a valid .lungfish project, treat it as a working directory
            let alert = NSAlert()
            alert.messageText = "Open as Working Directory?"
            alert.informativeText = "This folder is not a Lungfish project. Would you like to use it as a working directory for downloads and file operations?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Use as Working Directory")
            alert.addButton(withTitle: "Cancel")

            if let window = self.window {
                Task { @MainActor [weak self] in
                    let response = await alert.beginSheetModal(for: window)
                    if response == .alertFirstButtonReturn {
                        // Set as working directory without creating a full project
                        self?.setWorkingDirectory(url)
                    }
                }
            }
        }
    }

    private func setWorkingDirectory(_ url: URL) {
        // Add to recent projects for easy access
        RecentProjectsManager.shared.addRecentProject(
            url: url,
            name: url.lastPathComponent
        )

        // Close welcome window and notify
        window?.close()
        onProjectSelected?(url)
    }

    /// Shows the welcome window
    public func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

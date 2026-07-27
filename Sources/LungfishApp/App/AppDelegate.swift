// AppDelegate.swift - Application lifecycle management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3
import os
import LungfishKit

private final class AppDelegateNotificationObserver: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let token: NSObjectProtocol

    init(notificationCenter: NotificationCenter = .default, token: NSObjectProtocol) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    deinit {
        notificationCenter.removeObserver(token)
    }
}

/// Main application delegate handling app lifecycle and global state.
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate,
    FileMenuActions, ViewMenuActions, SequenceMenuActions, ToolsMenuActions, OperationsMenuActions, HelpMenuActions {

    /// The shared application delegate instance
    public static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    /// Main window controller for the application
    public var mainWindowController: MainWindowController?

    /// All open main windows (strong references for multi-project workflows).
    private var mainWindowControllers: [MainWindowController] = []

    private let projectSessionRegistry = ProjectSessionRegistry()
    internal let projectOpenCoordinator = ProjectOpenCoordinator()
    private var projectStorageCoordinators:
        [ObjectIdentifier: ProjectStorageCoordinator] = [:]
    private var projectStorageBindingGenerations:
        [ObjectIdentifier: UInt64] = [:]

    /// Welcome window controller for project selection
    internal var welcomeWindowController: WelcomeWindowController?

    /// Settings window controller (lazy singleton)
    internal var settingsWindowController: SettingsWindowController?
    internal var aboutWindowController: AboutWindowController?
    internal var workflowBuilderWindowController: NSWindowController?

    /// App-executable updater hooks. Sparkle is linked by the graphical target,
    /// not by LungfishApp, so the shared app module exposes only these closures.
    public var checkForUpdatesHandler: ((Any?) -> Void)?
    public var canCheckForUpdatesHandler: (() -> Bool)?

    /// AI assistant service (lazy singleton), hosted inside Inspector.
    internal var aiAssistantService: AIAssistantService?
    internal var helpWindowController: HelpWindowController?
    private var windowSizeDialogController: WindowSizeDialogController?
    internal var contentTextSizeAnnouncementPoster: any AccessibilityAnnouncementPosting =
        AccessibilityAnnouncementPoster()

    /// AI tool registry for the assistant
    internal var aiToolRegistry: AIToolRegistry?

    /// Current working directory for downloads when no project is active
    internal var workingDirectoryURL: URL?

    /// Last applied temp retention setting in hours.
    private var lastAppliedTempRetentionHours: Int = 24

    /// Last applied experimental feature visibility.
    private var lastAppliedExperimentalFeaturesEnabled = AppSettings.defaultExperimentalFeaturesEnabled

    private var workflowLibraryEnablementObserver: AppDelegateNotificationObserver?

    /// Repeating timer that requests conservative project storage cleanup.
    private var projectTempCleanupTimers: [URL: Timer] = [:]
    private var projectStorageAutomaticCleanupTasks:
        [URL: Task<Void, Never>] = [:]
    private var projectStorageAutomaticCleanupGenerations:
        [URL: UUID] = [:]
    internal var projectStorageAutomaticCleanupRunner:
        @Sendable (URL) async -> ProjectStorageAutomaticCleanupResult = {
            await ProjectStorageAutomaticCleanupService().run(
                projectURL: $0
            )
        }
    internal var projectStorageAutomaticCleanupDidProcessCompletion:
        (@MainActor @Sendable (URL, Bool) -> Void)?
#if DEBUG
    /// Repeating debug-only scan for temp directories that escaped project-local storage.
    private var debugTempEscapeScanTimer: Timer?
#endif
    private var isTerminating = false
    private var manualHaplotypeTerminationTask: Task<Void, Never>?
    private var isReenteringManualHaplotypeTermination = false

    /// Temporary storage for download URL while sheet is dismissing
    /// (relocated from the Direct-Launch Classification section; extensions cannot hold stored properties).
    private var pendingDownloadTempURL: URL?

    /// Temporary storage for multiple download URLs while sheet is dismissing
    /// (relocated from the Direct-Launch Classification section; extensions cannot hold stored properties).
    private var pendingDownloadTempURLs: [URL]?

    /// Backing controller for the Operations panel
    /// (relocated from the OperationsMenuActions section; extensions cannot hold stored properties).
    internal var operationsPanelController: OperationsPanelController?

    internal struct VCFImportHelperEvent: Decodable {
        let event: String
        let progress: Double?
        let message: String?
        let variantCount: Int?
        let error: String?
        let profile: String?
    }

    /// Public accessor for working directory URL
    public func getWorkingDirectoryURL() -> URL? {
        return workingDirectoryURL
    }

    // MARK: - Application Lifecycle

    public func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.load()

        // Install the main menu before app finishes launching
        NSApp.mainMenu = MainMenu.createMainMenu()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Load persisted settings
        AppSettings.load()
        lastAppliedTempRetentionHours = AppSettings.shared.tempFileRetentionHours
        lastAppliedExperimentalFeaturesEnabled = AppSettings.shared.experimentalFeaturesEnabled

        // Register for system notifications
        registerNotifications()

        // Clean up stale temp files from previous sessions
        Task {
            await TempFileManager.shared.setMaxAge(hours: AppSettings.shared.tempFileRetentionHours)
            await TempFileManager.shared.cleanupOnLaunch()
        }

        // Wire up DownloadCenter to handle bundle import when downloads complete.
        // This is the primary mechanism for getting built bundles into the sidebar
        // after background downloads finish. It replaces the fragile callback chain
        // through sheet controllers that get deallocated on dismissal.
        DownloadCenter.shared.onBundleReady = { [weak self] bundleURLs in
            debugLog("DownloadCenter.onBundleReady: Received \(bundleURLs.count) bundle(s)")
            self?.handleMultipleDownloadsSync(bundleURLs)
        }
        DownloadCenter.shared.onBundleReadyWithContext = { [weak self] bundleURLs, routeContext in
            debugLog("DownloadCenter.onBundleReadyWithContext: Received \(bundleURLs.count) bundle(s)")
            self?.handleMultipleDownloadsSync(bundleURLs, routeContext: routeContext)
        }

        // Check for command-line arguments
        let args = ProcessInfo.processInfo.arguments

        // Check for --test-folder argument for automated testing
        if let folderIndex = args.firstIndex(of: "--test-folder"),
           folderIndex + 1 < args.count {
            let folderPath = args[folderIndex + 1]

            // Skip welcome window for automated testing
            showMainWindowWithProject(URL(fileURLWithPath: folderPath))
            return
        }

        // Check for --skip-welcome argument
        let uiTestConfiguration = AppUITestConfiguration.current
        if uiTestConfiguration.scenarioName == "operations-failed-operation" {
            seedOperationsPanelFailureForUITest()
        }
        if uiTestConfiguration.isEnabled,
           let projectURL = uiTestConfiguration.projectPath {
            showMainWindowWithProject(projectURL)
            return
        }

        if args.contains("--skip-welcome") {
            showMainWindowWithoutProject()
            return
        }

        if restoreProjectWindowsFromSavedState() {
            NSApp.activate()
            return
        }

        // Show welcome window for normal launch
        showWelcomeWindow()
    }

    /// Fallback import entry point for callers that have bundle URLs but cannot
    /// rely on DownloadCenter callback wiring (e.g. alternate app startup paths).
    func importReadyBundles(_ bundleURLs: [URL], routeContext: OperationRouteContext? = nil) {
        handleMultipleDownloadsSync(bundleURLs, routeContext: routeContext)
    }

    /// Returns true when `url` is inside `directory`, using resolved paths
    /// (symlink-aware) and path-component prefix matching.
    private func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }

    /// Ensures the sidebar is scoped to the project containing `url` (or a safe
    /// fallback folder), then refreshes and selects the item.
    internal func refreshSidebarAndSelectImportedURL(_ url: URL, in controller: MainWindowController? = nil) {
        let controller = controller ?? mainWindowController
        guard let sidebarController = controller?.mainSplitViewController?.sidebarController else { return }

        let targetRoot: URL?
        if let projectURL = controller?.projectSession.projectURL, isURL(url, inside: projectURL) {
            targetRoot = projectURL
        } else if let workingURL = workingDirectoryURL, isURL(url, inside: workingURL) {
            targetRoot = workingURL
        } else if let sidebarProject = sidebarController.currentProjectURL, isURL(url, inside: sidebarProject) {
            targetRoot = sidebarProject
        } else {
            targetRoot = nil
        }

        if let root = targetRoot {
            if sidebarController.currentProjectURL?.standardizedFileURL != root.standardizedFileURL {
                debugLog("refreshSidebarAndSelectImportedURL: Rebasing sidebar to \(root.path)")
                sidebarController.openProject(at: root)
            }
        } else if sidebarController.currentProjectURL == nil {
            // No project context; mirror disk by showing the containing directory.
            let parent = url.deletingLastPathComponent()
            debugLog("refreshSidebarAndSelectImportedURL: No active project, opening parent \(parent.path)")
            sidebarController.openProject(at: parent)
        }

        sidebarController.reloadFromFilesystem()
        _ = sidebarController.selectItem(forURL: url)

        // Metagenomics results set their own inspector tab via contentMode
        // notification; forcing "document" tab would override it.
        let isMetagenomicsResult = url.lastPathComponent.hasPrefix("naomgs-")
            || url.lastPathComponent.hasPrefix("kraken2-")
            || url.lastPathComponent.hasPrefix("esviritu-")
            || url.lastPathComponent.hasPrefix("taxtriage-")
            || url.lastPathComponent.hasPrefix("nvd-")
        if !isMetagenomicsResult {
            requestInspectorDocumentModeAfterDownload(in: controller)
        }
    }

    /// Ensures post-download imports land on the Inspector's Document tab.
    ///
    /// Download/import workflows should default to bundle/document context, not
    /// selection editing context.
    internal func requestInspectorDocumentModeAfterDownload(in controller: MainWindowController? = nil) {
        var userInfo: [String: Any] = [NotificationUserInfoKey.inspectorTab: "document"]
        if let scope = controller?.projectSession.windowStateScope {
            userInfo[NotificationUserInfoKey.windowStateScope] = scope
        }
        NotificationCenter.default.post(name: .showInspectorRequested, object: nil, userInfo: userInfo)
    }

    deinit {
        workflowLibraryEnablementObserver = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Welcome Window

    private func showWelcomeWindow() {
        let storageConfigStore = ManagedStorageConfigStore.shared
        welcomeWindowController = WelcomeWindowController(
            storageConfigStore: storageConfigStore,
            storageCoordinator: ManagedStorageCoordinator(configStore: storageConfigStore)
        )

        welcomeWindowController?.onProjectSelected = { [weak self] projectURL in
            self?.showMainWindowWithProject(projectURL)
        }

        welcomeWindowController?.onOptionalPackSelected = { packID in
            PluginManagerWindowController.show(packID: packID)
        }

        welcomeWindowController?.show()
    }

    @discardableResult
    internal func createAndShowMainWindow(projectSession: ProjectSession = ProjectSession()) -> MainWindowController {
        let controller = MainWindowController(projectSession: projectSession)
        controller.showWindow(nil)
        mainWindowController = controller
        projectSessionRegistry.register(projectSession, projectURL: projectSession.projectURL)
        if !mainWindowControllers.contains(where: { $0 === controller }) {
            mainWindowControllers.append(controller)
        }
        return controller
    }

    private func controller(forWindowStateScopeID scopeID: UUID?) -> MainWindowController? {
        guard let scopeID else { return nil }
        return mainWindowControllers.first {
            $0.projectSession.windowStateScope.id == scopeID
        }
    }

    private func controller(forProjectURL projectURL: URL?) -> MainWindowController? {
        guard let projectURL else { return nil }
        let canonical = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        if let mainWindowController,
           mainWindowController.projectSession.projectURL?.standardizedFileURL.resolvingSymlinksInPath() == canonical {
            return mainWindowController
        }
        return mainWindowControllers.first {
            $0.projectSession.projectURL?.standardizedFileURL.resolvingSymlinksInPath() == canonical
        }
    }

    func targetMainWindowController(routeContext: OperationRouteContext?) -> MainWindowController? {
        controller(forWindowStateScopeID: routeContext?.windowStateScopeID)
            ?? controller(forProjectURL: routeContext?.projectURL)
            ?? (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? mainWindowController
    }

    internal func activeMainWindowController(sender: Any? = nil) -> MainWindowController? {
        if let view = sender as? NSView,
           let window = view.window,
           let controller = window.windowController as? MainWindowController {
            return controller
        }
        return (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? mainWindowController
    }

    internal func currentOperationRouteContext(for controller: MainWindowController? = nil) -> OperationRouteContext? {
        let controller = controller ?? activeMainWindowController()
        return OperationRouteContext(
            projectURL: controller?.projectSession.projectURL
                ?? controller?.mainSplitViewController?.sidebarController?.currentProjectURL
                ?? workingDirectoryURL,
            windowStateScope: controller?.projectSession.windowStateScope
        )
    }

    func canWriteProjectOutputs(
        projectURL: URL? = nil,
        windowStateScope: WindowStateScope? = nil,
        workflowName: String,
        presentingWindow: NSWindow? = nil
    ) -> Bool {
        guard isProjectWriteBlocked(projectURL: projectURL, windowStateScope: windowStateScope) else {
            return true
        }
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope)
        let controller = targetMainWindowController(routeContext: routeContext)

        ProjectWriteGatePresenter.presentBlockedWrite(
            workflowName: workflowName,
            on: presentingWindow ?? controller?.window
        )
        return false
    }

    private func isProjectWriteBlocked(projectURL: URL?, windowStateScope: WindowStateScope?) -> Bool {
        if let projectURL {
            let canonicalProjectURL = ProjectSessionRegistry.canonicalProjectURL(projectURL)
            if let scopedController = controller(forWindowStateScopeID: windowStateScope?.id),
               scopedController.projectSession.projectURL.map(ProjectSessionRegistry.canonicalProjectURL) == canonicalProjectURL,
               scopedController.projectSession.isReadOnlyRecommended {
                return true
            }
            if let projectController = controller(forProjectURL: projectURL),
               projectController.projectSession.isReadOnlyRecommended {
                return true
            }
            return ProjectOpenWarningState.evaluate(projectURL: projectURL).isReadOnlyRecommended
        }

        if let scopedController = controller(forWindowStateScopeID: windowStateScope?.id) {
            return scopedController.projectSession.isReadOnlyRecommended
        }
        return false
    }

    internal func openProject(_ projectURL: URL, in controller: MainWindowController) {
        if controller.deferManualHaplotypeTransition(
            .projectSwitch,
            mutation: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.openProject(projectURL, in: controller)
            }
        ) {
            return
        }
        invalidateProjectStorage(for: controller)
        let previousProjectURL = controller.projectSession.projectURL
            .map(ProjectSessionRegistry.canonicalProjectURL)
        // Keep global working directory in sync with most recently activated project.
        workingDirectoryURL = projectURL
        mainWindowController = controller
        // Migrate analysis results from legacy derivatives/ location to Analyses/.
        // This is idempotent and safe to run on every project open.
        if let count = try? AnalysesMigration.migrateProject(at: projectURL), count > 0 {
            debugLog("openProject: Migrated \(count) analysis director\(count == 1 ? "y" : "ies") from derivatives/ to Analyses/")
        }

        let result = projectOpenCoordinator.openProject(at: projectURL, using: controller.projectSession)
        switch result {
        case .opened(let project):
            let openedProjectURL =
                ProjectSessionRegistry.canonicalProjectURL(project.url)
            DocumentManager.shared.mirrorProjectSession(controller.projectSession)
            projectSessionRegistry.register(controller.projectSession, projectURL: project.url)
            if let previousProjectURL,
               previousProjectURL != openedProjectURL,
               projectSessionRegistry
                .sessions(forProjectURL: previousProjectURL)
                .isEmpty {
                stopAutomaticProjectStorageCleanup(
                    for: previousProjectURL
                )
            }
            controller.mainSplitViewController?.applyProjectSessionState()
            updateProjectWindowTitle(controller)
            startProjectTempCleanupTimer(for: openedProjectURL)
            debugLog("openProject: Opened project via ProjectSession")
        case .filesystemFallback(let fallback):
            projectSessionRegistry.unregister(controller.projectSession)
            controller.projectSession.closeProject()
            if let previousProjectURL,
               projectSessionRegistry
                .sessions(forProjectURL: previousProjectURL)
                .isEmpty {
                stopAutomaticProjectStorageCleanup(
                    for: previousProjectURL
                )
            }
            controller.window?.title = "\(fallback.name) - Lungfish Genome Explorer"
            debugLog("openProject: Failed via ProjectSession, falling back to filesystem sidebar: \(fallback.error.localizedDescription)")
            controller.mainSplitViewController?.sidebarController.openProject(at: fallback.url)
        }

        // Opening is deliberately read-only with respect to project storage.
        // The timer's first fire occurs later and runs the proof-based cleanup
        // service off the main actor.
        saveApplicationState()
    }

    internal func updateProjectWindowTitle(_ controller: MainWindowController) {
        guard let projectURL = controller.projectSession.projectURL else {
            controller.window?.title = "Lungfish Genome Explorer"
            return
        }
        let projectName = projectURL.deletingPathExtension().lastPathComponent
        let number = projectSessionRegistry.windowNumber(for: controller.projectSession)
        let suffix = controller.projectSession.isReadOnlyRecommended ? " (Read Only)" : ""
        controller.window?.title = "\(projectName) [\(number)]\(suffix) - Lungfish Genome Explorer"
    }

    private func refreshProjectWindowTitles(forProjectURL projectURL: URL?) {
        guard let projectURL else { return }
        let canonicalProjectURL = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        for controller in mainWindowControllers {
            guard controller.projectSession.projectURL.map(ProjectSessionRegistry.canonicalProjectURL) == canonicalProjectURL else {
                continue
            }
            updateProjectWindowTitle(controller)
        }
    }

    private func showMainWindowWithProject(_ projectURL: URL) {
        let controller = createAndShowMainWindow()

        // Activate the app to ensure menu bar switches properly
        NSApp.activate()

        // Close welcome window if open
        welcomeWindowController?.close()
        welcomeWindowController = nil

        openProject(projectURL, in: controller)
    }

    private func showMainWindowWithoutProject() {
        _ = createAndShowMainWindow()

        // Activate the app to ensure menu bar switches properly
        NSApp.activate()

        // Close welcome window if open
        welcomeWindowController?.close()
        welcomeWindowController = nil
    }

    @IBAction func newWindowForCurrentProject(_ sender: Any?) {
        guard let sourceController = activeMainWindowController(sender: sender),
              let projectURL = sourceController.projectSession.projectURL
                ?? sourceController.mainSplitViewController?.sidebarController?.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Open a project before creating another window for it.")
            return
        }

        let controller = createAndShowMainWindow()
        NSApp.activate()
        openProject(projectURL, in: controller)
    }

    @discardableResult
    func testingNewWindowForCurrentProject() -> MainWindowController? {
        let before = Set(mainWindowControllers.map(ObjectIdentifier.init))
        newWindowForCurrentProject(nil)
        return mainWindowControllers.first { !before.contains(ObjectIdentifier($0)) }
    }

    /// Loads project folder contents with proper background threading.
    ///
    /// Three-phase loading flow:
    /// 1. **Scan** - Fast folder scan (synchronous, just reads directory entries)
    /// 2. **Populate** - Populate sidebar immediately with placeholder items
    /// 3. **Load** - Load each file in background, update sidebar as each completes
    ///
    /// This approach follows professional genome browser patterns (IGV, UCSC) and:
    public func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true

        // Cancel and invalidate project-bound storage work before AppKit tears
        // down its originating windows.
        let storageCoordinators = Array(projectStorageCoordinators.values)
        projectStorageCoordinators.removeAll()
        storageCoordinators.forEach { $0.invalidate() }
        projectStorageBindingGenerations.removeAll()

        // Ensure app-managed imports/workflows and any native tool descendants
        // are stopped before AppKit tears down the process.
        OperationCenter.shared.cancelAll()
        NativeProcessRegistry.shared.terminateAll(gracePeriod: 0.5)

        // Save application state
        saveApplicationState()

        // Stop periodic project temp cleanup timer.
        projectTempCleanupTimers.values.forEach { $0.invalidate() }
        projectTempCleanupTimers.removeAll()
        projectStorageAutomaticCleanupTasks.values.forEach { $0.cancel() }
        projectStorageAutomaticCleanupTasks.removeAll()
        projectStorageAutomaticCleanupGenerations.removeAll()
#if DEBUG
        debugTempEscapeScanTimer?.invalidate()
        debugTempEscapeScanTimer = nil
#endif

        // Clean up any temp files created during this session
        // Note: This is synchronous since we're terminating
        Task {
            await TempFileManager.shared.cleanupSessionFiles()
        }
    }

    public func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        applicationShouldTerminate {
            [weak sender] shouldTerminate in
            sender?.reply(
                toApplicationShouldTerminate: shouldTerminate
            )
        }
    }

    private func applicationShouldTerminate(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if isReenteringManualHaplotypeTermination {
            isReenteringManualHaplotypeTermination = false
            return .terminateNow
        }
        if manualHaplotypeTerminationTask != nil {
            return .terminateLater
        }
        let dirtyControllers = mainWindowControllers.filter(
            \.requiresManualHaplotypeTransitionCoordination
        )
        guard !dirtyControllers.isEmpty else {
            return .terminateNow
        }
        manualHaplotypeTerminationTask =
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allowed =
                    await self
                        .prepareForManualHaplotypeTermination(
                            controllers: { [weak self] in
                                self?.mainWindowControllers ?? []
                            }
                        )
                self.manualHaplotypeTerminationTask = nil
                if allowed {
                    self.isReenteringManualHaplotypeTermination = true
                }
                reply(allowed)
            }
        return .terminateLater
    }

    private func prepareForManualHaplotypeTermination(
        controllers controllerSnapshot:
            @escaping @MainActor () -> [MainWindowController]
    ) async -> Bool {
        typealias PendingResolution = (
            controller: MainWindowController,
            resolution:
                MainWindowController
                    .ManualHaplotypeTransitionResolution
        )
        struct FinalizedDraftState {
            let revisionToken: UUID?
        }
        var resolutions: [ObjectIdentifier: PendingResolution] = [:]
        var finalizedDrafts:
            [ObjectIdentifier: FinalizedDraftState] = [:]

        func cancelAllResolutions() {
            for item in resolutions.values {
                item.controller.cancelManualHaplotypeTransitionCommit(
                    item.resolution
                )
            }
            resolutions.removeAll()
        }

        func pruneInvalidResolutions(
            currentControllerIDs: Set<ObjectIdentifier>
        ) {
            let invalid = resolutions.compactMap {
                identifier, item -> ObjectIdentifier? in
                guard currentControllerIDs.contains(identifier),
                      item.controller
                        .isManualHaplotypeTransitionResolutionCurrent(
                            item.resolution
                        ) else {
                    return identifier
                }
                return nil
            }
            for identifier in invalid {
                guard let item = resolutions.removeValue(
                    forKey: identifier
                ) else {
                    continue
                }
                item.controller.cancelManualHaplotypeTransitionCommit(
                    item.resolution
                )
            }
        }

        func pruneInvalidFinalizedDrafts(
            controllers: [MainWindowController]
        ) {
            let currentByID = Dictionary(
                uniqueKeysWithValues: controllers.map {
                    (ObjectIdentifier($0), $0)
                }
            )
            let invalid = finalizedDrafts.compactMap {
                identifier, finalized -> ObjectIdentifier? in
                guard let controller = currentByID[identifier],
                      controller.manualHaplotypeDraftRevisionToken
                        == finalized.revisionToken else {
                    return identifier
                }
                return nil
            }
            for identifier in invalid {
                finalizedDrafts[identifier] = nil
            }
        }

        func hasStableSnapshot(
            _ controllers: [MainWindowController]
        ) -> Bool {
            let currentControllers = controllerSnapshot()
            guard Set(currentControllers.map(ObjectIdentifier.init))
                == Set(controllers.map(ObjectIdentifier.init)) else {
                return false
            }
            for controller in currentControllers {
                let identifier = ObjectIdentifier(controller)
                if controller.requiresManualHaplotypeTransitionCoordination,
                   resolutions[identifier] == nil,
                   finalizedDrafts[identifier] == nil {
                    return false
                }
            }
            guard resolutions.values.allSatisfy({
                $0.controller
                    .isManualHaplotypeTransitionResolutionCurrent(
                        $0.resolution
                    )
            }) else {
                return false
            }
            return finalizedDrafts.allSatisfy {
                identifier, finalized in
                guard let controller = currentControllers.first(where: {
                    ObjectIdentifier($0) == identifier
                }) else {
                    return false
                }
                return controller.manualHaplotypeDraftRevisionToken
                    == finalized.revisionToken
            }
        }

        // A continuously mutating draft must veto termination rather than
        // spin forever or commit a stale decision.
        let maximumResolutionPasses = 32
        for _ in 0..<maximumResolutionPasses {
            let controllers = controllerSnapshot()
            let controllerIDs = Set(
                controllers.map(ObjectIdentifier.init)
            )
            pruneInvalidResolutions(
                currentControllerIDs: controllerIDs
            )
            pruneInvalidFinalizedDrafts(
                controllers: controllers
            )

            var sawCancellation = false
            for controller in controllers {
                let identifier = ObjectIdentifier(controller)
                guard controller
                    .requiresManualHaplotypeTransitionCoordination,
                      resolutions[identifier] == nil,
                      finalizedDrafts[identifier] == nil else {
                    continue
                }
                let resolution =
                    await controller.resolveManualHaplotypeTransition(
                        .appQuit
                    )
                if resolution.isCancelled {
                    controller.cancelManualHaplotypeTransitionCommit(
                        resolution
                    )
                    sawCancellation = true
                    continue
                }
                resolutions[identifier] = (controller, resolution)
            }
            if sawCancellation {
                cancelAllResolutions()
                return false
            }

            guard hasStableSnapshot(controllers) else {
                pruneInvalidResolutions(
                    currentControllerIDs: Set(
                        controllerSnapshot().map(
                            ObjectIdentifier.init
                        )
                    )
                )
                await Task.yield()
                continue
            }
            guard !resolutions.isEmpty else {
                return true
            }

            let ordered = controllers.compactMap {
                resolutions[ObjectIdentifier($0)]
            }
            let saves = ordered.filter {
                $0.resolution.decision == .save
            }
            let discards = ordered.filter {
                $0.resolution.decision == .discard
            }
            var savePreflightFailed = false
            var draftChangedDuringSavePreflight = false
            for item in saves {
                guard item.controller
                    .isManualHaplotypeTransitionResolutionCurrent(
                        item.resolution
                    ) else {
                    draftChangedDuringSavePreflight = true
                    break
                }
                let prepared = await item.controller
                    .prepareManualHaplotypeTransitionCommit(
                        item.resolution
                    )
                guard item.controller
                    .isManualHaplotypeTransitionResolutionCurrent(
                        item.resolution
                    ) else {
                    draftChangedDuringSavePreflight = true
                    break
                }
                guard prepared else {
                    savePreflightFailed = true
                    break
                }
            }
            if draftChangedDuringSavePreflight {
                cancelAllResolutions()
                await Task.yield()
                continue
            }
            if savePreflightFailed {
                cancelAllResolutions()
                return false
            }

            guard hasStableSnapshot(controllerSnapshot()) else {
                cancelAllResolutions()
                await Task.yield()
                continue
            }

            for item in saves + discards {
                guard item.controller
                    .isManualHaplotypeTransitionResolutionCurrent(
                        item.resolution
                    ),
                      await item.controller
                        .finalizeManualHaplotypeTransitionCommit(
                            item.resolution
                        ) else {
                    cancelAllResolutions()
                    return false
                }
                resolutions[ObjectIdentifier(item.controller)] = nil
                finalizedDrafts[ObjectIdentifier(item.controller)] =
                    FinalizedDraftState(
                        revisionToken:
                            item.controller
                                .manualHaplotypeDraftRevisionToken
                    )
            }
        }
        cancelAllResolutions()
        return false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even when all windows are closed (standard macOS behavior)
        return false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when dock icon is clicked
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        if let activeController = activeMainWindowController() {
            mainWindowController = activeController
            projectSessionRegistry.markFrontmost(activeController.projectSession)
            DocumentManager.shared.mirrorProjectSession(activeController.projectSession)
        }
    }

    // MARK: - File Handling

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Handle opening files via Finder or drag-drop to dock
        let url = URL(fileURLWithPath: filename)
        return openDocument(at: url)
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Handle opening multiple files
        let allQueued = filenames
            .map { URL(fileURLWithPath: $0) }
            .allSatisfy { openDocument(at: $0) }
        sender.reply(toOpenOrPrint: allQueued ? .success : .failure)
    }

    // MARK: - Private Methods

    private func registerNotifications() {
        // Register for relevant system notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        // Register for annotation update notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationUpdated(_:)),
            name: .annotationUpdated,
            object: nil
        )

        // Register for annotation delete notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationDeleted(_:)),
            name: .annotationDeleted,
            object: nil
        )

        // Register for annotation color applied to type notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationColorAppliedToType(_:)),
            name: .annotationColorAppliedToType,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppSettingsChanged(_:)),
            name: .appSettingsChanged,
            object: nil
        )

        let workflowLibraryToken = NotificationCenter.default.addObserver(
            forName: .workflowLibraryEnablementChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWorkflowLibraryEnablementChanged()
            }
        }
        workflowLibraryEnablementObserver = AppDelegateNotificationObserver(token: workflowLibraryToken)

        // Register for AI assistant show request
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowAIAssistant(_:)),
            name: .showAIAssistantRequested,
            object: nil
        )

        // Update AI tool registry when a bundle loads
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleDidLoadForAI(_:)),
            name: .bundleDidLoad,
            object: nil
        )

    }

    /// Handles annotation updates from the inspector.
    @objc private func handleAnnotationUpdated(_ notification: Notification) {
        guard let annotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation else {
            return
        }

        let viewerController = viewerController(for: notification)

        // Update in-memory document annotations if available
        if let document = viewerController?.currentDocument,
           let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) {
            document.annotations[index] = annotation
        }

        // Update the viewer (handles both document and bundle mode)
        viewerController?.viewerView.updateAnnotation(annotation)
    }

    /// Handles annotation deletions from the inspector.
    @objc private func handleAnnotationDeleted(_ notification: Notification) {
        guard let annotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation else {
            return
        }

        // Remove the annotation from the current document
        let viewerController = viewerController(for: notification)
        guard let document = viewerController?.currentDocument else { return }

        // Remove the annotation
        document.annotations.removeAll { $0.id == annotation.id }
        // Refresh the viewer
        viewerController?.viewerView.setAnnotations(document.annotations)
        viewerController?.viewerView.needsDisplay = true
    }

    /// Handles applying a color to all annotations of a specific type.
    ///
    /// Updates all matching annotations in both the document (if loaded) and
    /// the viewer's bundle caches, then triggers a redraw.
    @objc private func handleAnnotationColorAppliedToType(_ notification: Notification) {
        guard let annotationType = notification.userInfo?[NotificationUserInfoKey.annotationType] as? AnnotationType,
              let annotationColor = notification.userInfo?[NotificationUserInfoKey.annotationColor] as? AnnotationColor else {
            return
        }

        let viewerController = viewerController(for: notification)

        // Update in-memory document annotations if available
        if let document = viewerController?.currentDocument {
            for (index, annotation) in document.annotations.enumerated() where annotation.type == annotationType {
                var updated = annotation
                updated.color = annotationColor
                document.annotations[index] = updated
            }
        }

        // Update the viewer (handles both document and bundle mode)
        viewerController?.viewerView.applyColorToType(annotationType, color: annotationColor)

        // The applyColorToType method already schedules a view state save via the
        // viewController reference, so no additional save trigger is needed here.
    }

    private func viewerController(for notification: Notification) -> ViewerViewController? {
        if let scope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope {
            return controller(forWindowStateScopeID: scope.id)?.mainSplitViewController?.viewerController
        }
        return activeMainWindowController()?.mainSplitViewController?.viewerController
    }

    /// Applies runtime settings that require service reconfiguration.
    @objc private func handleAppSettingsChanged(_ notification: Notification) {
        let experimentalFeaturesEnabled = AppSettings.shared.experimentalFeaturesEnabled
        if experimentalFeaturesEnabled != lastAppliedExperimentalFeaturesEnabled {
            lastAppliedExperimentalFeaturesEnabled = experimentalFeaturesEnabled
            NSApp.mainMenu = MainMenu.createMainMenu(
                experimentalFeaturesEnabled: experimentalFeaturesEnabled,
                workflowFeatureAvailability: .current()
            )
        }

        let retentionHours = AppSettings.shared.tempFileRetentionHours
        guard retentionHours != lastAppliedTempRetentionHours else { return }
        lastAppliedTempRetentionHours = retentionHours

        Task {
            await TempFileManager.shared.setMaxAge(hours: retentionHours)
            // Apply reduced retention immediately instead of waiting for restart.
            await TempFileManager.shared.cleanupOnLaunch()
        }
    }

    private func handleWorkflowLibraryEnablementChanged() {
        NSApp.mainMenu = MainMenu.createMainMenu(
            experimentalFeaturesEnabled: AppSettings.shared.experimentalFeaturesEnabled,
            workflowFeatureAvailability: .current()
        )
    }

    // MARK: - Project Temp Cleanup

    private func startProjectTempCleanupTimer(for projectURL: URL) {
        let key = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        guard projectTempCleanupTimers[key] == nil else { return }

        // Schedule proof-based cleanup every 4 hours. Project open itself
        // performs no storage traversal or mutation.
        projectTempCleanupTimers[key] = Timer.scheduledTimer(
            withTimeInterval: 4 * 60 * 60,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scheduleAutomaticProjectStorageCleanup(
                        projectURL
                    )
                }
            }
        }

#if DEBUG
        // In debug builds, scan for escaped temp dirs every 5 minutes.
        debugTempEscapeScanTimer?.invalidate()
        debugTempEscapeScanTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.debugScanForEscapedTempDirs()
                }
            }
        }
#endif
    }

    private func scheduleAutomaticProjectStorageCleanup(
        _ projectURL: URL
    ) {
        let key = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        projectStorageAutomaticCleanupTasks[key]?.cancel()
        let generation = UUID()
        projectStorageAutomaticCleanupGenerations[key] = generation
        let runner = projectStorageAutomaticCleanupRunner
        projectStorageAutomaticCleanupTasks[key] =
            Task.detached(priority: .utility) { [weak self] in
                let result = await runner(key)
                await MainActor.run {
                    guard let self else { return }
                    let isCurrent =
                        self
                        .projectStorageAutomaticCleanupGenerations[key]
                        == generation
                    self
                        .projectStorageAutomaticCleanupDidProcessCompletion?(
                            key,
                            isCurrent
                        )
                    guard isCurrent else {
                        return
                    }
                    self.projectStorageAutomaticCleanupTasks[key] = nil
                    self.projectStorageAutomaticCleanupGenerations[key] = nil
                    switch result.state {
                    case .noEligibleEntries:
                        debugLog(
                            "Automatic project storage cleanup found "
                                + "no proven removable temporary entries"
                        )
                    case .completed:
                        debugLog(
                            "Automatic project storage cleanup moved "
                                + "\(result.selectedEntryCount) "
                                + "proven entries to Trash"
                        )
                    case .retryRecommended:
                        for warning in result.warnings {
                            let path =
                                warning.relativePath ?? "<project>"
                            appDelegateLogger.warning(
                                "Automatic project storage cleanup will retry \(path, privacy: .public): \(warning.message, privacy: .public)"
                            )
                        }
                    case .cancelled:
                        break
                    }
                }
            }
    }

    private func stopAutomaticProjectStorageCleanup(
        for projectURL: URL
    ) {
        let key = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        projectTempCleanupTimers.removeValue(forKey: key)?.invalidate()
        projectStorageAutomaticCleanupTasks.removeValue(forKey: key)?
            .cancel()
        projectStorageAutomaticCleanupGenerations[key] = nil
    }

    internal func testingRunAutomaticProjectStorageCleanup(
        _ projectURL: URL
    ) {
        scheduleAutomaticProjectStorageCleanup(projectURL)
    }

    internal func testingWaitForAutomaticProjectStorageCleanup(
        _ projectURL: URL
    ) async {
        let key = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        while let task = projectStorageAutomaticCleanupTasks[key] {
            await task.value
        }
    }

    internal func testingHasTrackedAutomaticProjectStorageCleanup(
        _ projectURL: URL
    ) -> Bool {
        let key = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        return projectStorageAutomaticCleanupTasks[key] != nil
    }

    internal func testingHasAutomaticProjectStorageCleanupLifecycle(
        _ projectURL: URL
    ) -> Bool {
        let key = ProjectSessionRegistry.canonicalProjectURL(projectURL)
        return projectTempCleanupTimers[key] != nil
            || projectStorageAutomaticCleanupTasks[key] != nil
            || projectStorageAutomaticCleanupGenerations[key] != nil
    }

#if DEBUG
    /// Timestamp captured at app launch — the debug scanner only asserts on
    /// directories created after this point, avoiding false positives from
    /// test fixtures or stale temp dirs from previous sessions.
    private let debugSessionStartDate = Date()

    /// Prefixes used exclusively by test fixtures — never match these in the
    /// escaped-temp scanner since they are test artifacts, not runtime escapes.
    private static let testFixturePrefixes = [
        "esviritu-test-",
        "esviritu-test-db-",
        "test-esviritu-",
        "test-esviritu-db-",
    ]

    /// Scans system temp for lungfish-* directories that should be in project .tmp/.
    /// Called periodically in debug builds to catch regressions.
    ///
    /// Only asserts on directories created during the current app session and
    /// excludes known test fixture prefixes to prevent false positives.
    private func debugScanForEscapedTempDirs() {
        let systemTemp = FileManager.default.temporaryDirectory
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: systemTemp,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Every prefix used by ProjectTempDirectory.create/createFromContext across
        // the codebase. Matches both old-style "lungfish-*" and new short prefixes.
        let escapedPrefixes = [
            // ReadExtractionService
            "lungfish-extract-", "lungfish-bam-dedup-", "lungfish-bam-extract-",
            // LungfishWorkflow pipelines
            "esviritu-", "taxtriage-", "lungfish-spades-", "lungfish-orient-",
            "lungfish-demux-", "lungfish-scout-", "lungfish-bbtools-",
            // FASTQDerivativeService
            "lungfish-virtual-orient-", "lungfish-demux-trim-", "lungfish-trim-",
            "lungfish-fasta-orient-", "lungfish-fasta-demux-trim-",
            "lungfish-fasta-trim-", "lungfish-fasta-postrim-", "bbduk-primer-",
            "fastq-export-", "fastq-derive-", "pe-search-",
            // AppDelegate materialization + export
            "minimap2-", "orient-", "classify-", "export-", "export-decomp-",
            "vcf-import-",
            // Classifier extraction controllers
            "esviritu-extract-", "naomgs-extract-", "nvd-extract-", "taxtriage-extract-",
            // ViewModels + services
            "genbank-", "sequence-", "genome-", "assembly-", "fasta-preview-",
            "ref-", "ref-import-", "extract-", "fastq-ingest-", "batch-",
            // CLI commands
            "bbmerge-", "bbrepair-", "lungfish-cli-ref-import-", ".lungfish-temp-",
        ]

        for item in contents {
            let name = item.lastPathComponent

            // Skip known test fixture prefixes
            let isTestFixture = Self.testFixturePrefixes.contains { name.hasPrefix($0) }
            guard !isTestFixture else { continue }

            let matchesPrefix = escapedPrefixes.contains { name.hasPrefix($0) }
            guard matchesPrefix else { continue }

            // Only check directories created during the current app session
            let attrs = try? item.resourceValues(forKeys: [.creationDateKey])
            guard let created = attrs?.creationDate, created > debugSessionStartDate else { continue }

            // Read provenance marker for policy-based decision
            let marker = ProjectTempDirectory.readMarker(from: item)

            if let marker = marker {
                // Marker present — decide based on policy
                if marker.policy == .requireProjectContext {
                    // Real violation: requireProjectContext escaped to system temp
                    appDelegateLogger.error("DEBUG: Policy violation — requireProjectContext temp escaped to system temp: \(name, privacy: .public) (caller: \(marker.caller, privacy: .public))")
                    assertionFailure("Escaped temp dir (requireProjectContext) in system temp: \(name) — caller: \(marker.caller)")
                } else {
                    // Allowed fallback (preferProjectContext or systemOnly)
                    appDelegateLogger.debug("DEBUG: Allowed system temp dir: \(name, privacy: .public) (policy: \(marker.policy.rawValue, privacy: .public))")
                }
            } else {
                // No marker — legacy callsite, warn but don't crash during migration
                appDelegateLogger.warning("DEBUG: Unmarked temp dir in system temp: \(name, privacy: .public). Consider migrating to policy-aware create API.")
            }
        }
    }
#endif

    /// Reviews project temporary files after user confirmation and moves only
    /// individually proven, unlocked, non-retained children to Trash.
    @objc func clearProjectTempFiles(_ sender: Any?) {
        guard let projectURL = mainWindowController?.mainSplitViewController?.sidebarController?.currentProjectURL else {
            let alert = NSAlert()
            alert.messageText = "No Project Open"
            alert.informativeText = "Please open a project before clearing temporary files."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.applyLungfishBranding()
            if let window = mainWindowController?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        let projectName = projectURL.deletingPathExtension().lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Review Temporary Files"
        alert.informativeText =
            "Move temporary items in \"\(projectName)\" to Trash only "
            + "when Lungfish can prove they are completed or orphaned, "
            + "unlocked, and not retained? Active, unmarked, or unsafe "
            + "items will remain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Review and Clear")
        alert.addButton(withTitle: "Cancel")
        alert.applyLungfishBranding()

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else { return }

        alert.beginSheetModal(for: window) { [weak window] response in
            guard response == .alertFirstButtonReturn else { return }

            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) {
                    await ProjectStorageAutomaticCleanupService().run(
                        projectURL: projectURL,
                        trigger: .userRequested
                    )
                }.value
                guard let window else { return }
                let resultAlert = NSAlert()
                switch result.state {
                case .completed:
                    resultAlert.messageText = "Temporary Files Moved to Trash"
                    resultAlert.informativeText =
                        "Moved \(result.selectedEntryCount) verified "
                        + "temporary item"
                        + (result.selectedEntryCount == 1 ? "" : "s")
                        + " to Trash. Active, retained, unmarked, or unsafe "
                        + "items were left unchanged."
                    resultAlert.alertStyle = .informational
                case .noEligibleEntries:
                    resultAlert.messageText = "No Safe Cleanup Available"
                    resultAlert.informativeText =
                        "No temporary items could be proven safe to remove. "
                        + "Active, retained, unmarked, and unsafe items remain."
                    resultAlert.alertStyle = .informational
                case .retryRecommended:
                    resultAlert.messageText = "Cleanup Needs Attention"
                    let details = result.warnings
                        .prefix(3)
                        .map(\.message)
                        .joined(separator: "\n")
                    resultAlert.informativeText =
                        details.isEmpty
                        ? "Cleanup could not safely complete and can be retried."
                        : details
                    resultAlert.alertStyle = .warning
                case .cancelled:
                    return
                }
                resultAlert.addButton(withTitle: "OK")
                resultAlert.applyLungfishBranding()
                resultAlert.beginSheetModal(for: window) { _ in }
            }
        }
    }

    /// Presents a window-bound preview of all classified project storage.
    ///
    /// The originating controller is resolved from the sender/key window and
    /// never from the mutable global `mainWindowController` fallback.
    @objc func manageProjectStorage(_ sender: Any?) {
        guard let controller = projectStorageOriginController(sender: sender),
              let window = controller.window,
              let projectURL = successfullyOwnedProjectURL(
                  for: controller
              ),
              let identity = try? FileSystemObjectIdentity.noFollow(
                  ProjectSessionRegistry.canonicalProjectURL(projectURL)
              ) else {
            return
        }
        let windowID = ObjectIdentifier(window)
        guard projectStorageCoordinators[windowID] == nil else { return }
        let generation = projectStorageBindingGenerations[windowID, default: 0]
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: window,
            controller: controller,
            projectURL: projectURL,
            projectIdentity: identity,
            generation: generation,
            generationProvider: { [weak self, weak window] in
                guard let self, let window else { return .max }
                return self.projectStorageBindingGenerations[
                    ObjectIdentifier(window),
                    default: 0
                ]
            },
            completion: { [weak self, weak window] in
                guard let self, let window else { return }
                self.projectStorageCoordinators.removeValue(
                    forKey: ObjectIdentifier(window)
                )
            }
        )
        projectStorageCoordinators[windowID] = coordinator
        if !coordinator.present() {
            projectStorageCoordinators.removeValue(forKey: windowID)
        }
    }

    /// Formats a byte count for display: <1 MB shows KB, <1 GB shows MB, else GB.
    static func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1_024
        let mb = kb / 1_024
        let gb = mb / 1_024
        if mb < 1 {
            return String(format: "%.0f KB", kb)
        } else if gb < 1 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.2f GB", gb)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }

        let closedControllers = mainWindowControllers.filter { controller in
            controller.window === closedWindow
        }
        for controller in closedControllers {
            invalidateProjectStorage(for: controller)
        }
        projectStorageBindingGenerations.removeValue(
            forKey: ObjectIdentifier(closedWindow)
        )
        guard !isTerminating else { return }

        let affectedProjectURLs = Set(closedControllers.compactMap { $0.projectSession.projectURL })
        for controller in closedControllers {
            projectSessionRegistry.unregister(controller.projectSession)
        }

        // Remove closed main windows from our tracked list.
        mainWindowControllers.removeAll { controller in
            controller.window === closedWindow
        }

        if mainWindowController?.window === closedWindow {
            mainWindowController = mainWindowControllers.first(where: { $0.window?.isMainWindow == true }) ?? mainWindowControllers.last
        }
        for projectURL in affectedProjectURLs {
            if projectSessionRegistry
                .sessions(forProjectURL: projectURL)
                .isEmpty {
                stopAutomaticProjectStorageCleanup(for: projectURL)
            }
            refreshProjectWindowTitles(forProjectURL: projectURL)
        }
        saveApplicationState()
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let controller = window.windowController as? MainWindowController else {
            return
        }

        mainWindowController = controller
        if !mainWindowControllers.contains(where: { $0 === controller }) {
            mainWindowControllers.append(controller)
        }
        projectSessionRegistry.markFrontmost(controller.projectSession)
        DocumentManager.shared.mirrorProjectSession(controller.projectSession)
    }

    internal func saveApplicationState() {
        let snapshots = mainWindowControllers.enumerated().compactMap { index, controller -> ProjectWindowSnapshot? in
            let ordinal = projectSessionRegistry.windowNumber(for: controller.projectSession)
            return controller.captureProjectWindowSnapshot(windowOrdinal: ordinal, windowOrder: index)
        }

        do {
            try ProjectWindowStateStore().save(ProjectWindowStateEnvelope(windows: snapshots))
        } catch {
            appDelegateLogger.error("Failed to save project window state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreProjectWindowsFromSavedState() -> Bool {
        do {
            let envelope = try ProjectWindowStateStore().load()
            return try restoreProjectWindows(from: envelope)
        } catch {
            appDelegateLogger.error("Failed to restore project windows: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func restoreProjectWindows(from envelope: ProjectWindowStateEnvelope) throws -> Bool {
        let existingWindows = envelope.windows
            .filter { FileManager.default.fileExists(atPath: $0.projectURL.path) }
            .sorted { $0.windowOrder < $1.windowOrder }
        guard !existingWindows.isEmpty else { return false }

        var restoredAnyWindow = false
        for snapshot in existingWindows {
            let session = ProjectSession(id: snapshot.id)
            do {
                try session.openProject(at: snapshot.projectURL)
            } catch {
                appDelegateLogger.warning(
                    "Skipping saved project window for \(snapshot.projectURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            let controller = createAndShowMainWindow(projectSession: session)
            DocumentManager.shared.mirrorProjectSession(session)
            workingDirectoryURL = snapshot.projectURL
            controller.mainSplitViewController?.applyProjectSessionState(restoring: snapshot)
            updateProjectWindowTitle(controller)
            startProjectTempCleanupTimer(for: snapshot.projectURL)
            if let frame = snapshot.frame {
                controller.window?.setFrame(
                    NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                    display: true
                )
            }
            if snapshot.isFullScreen, controller.window?.styleMask.contains(.fullScreen) == false {
                controller.window?.toggleFullScreen(nil)
            }
            restoredAnyWindow = true
        }

        return restoredAnyWindow
    }

    var testingMainWindowControllers: [MainWindowController] {
        mainWindowControllers
    }

    func testingPrepareForManualHaplotypeTermination(
        in controllers: [MainWindowController]
    ) async -> Bool {
        await prepareForManualHaplotypeTermination(
            controllers: { controllers }
        )
    }

    func testingPrepareForManualHaplotypeTermination(
        controllers:
            @escaping @MainActor () -> [MainWindowController]
    ) async -> Bool {
        await prepareForManualHaplotypeTermination(
            controllers: controllers
        )
    }

    func testingSetMainWindowControllers(
        _ controllers: [MainWindowController]
    ) {
        mainWindowControllers = controllers
    }

    func testingWaitForManualHaplotypeTermination() async {
        while manualHaplotypeTerminationTask != nil {
            await Task.yield()
        }
    }

    func testingApplicationShouldTerminate(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        applicationShouldTerminate(reply: reply)
    }

    @discardableResult
    func testingRestoreProjectWindows(from envelope: ProjectWindowStateEnvelope) throws -> Bool {
        try restoreProjectWindows(from: envelope)
    }

    func testingOpenProject(_ projectURL: URL, in controller: MainWindowController) {
        openProject(projectURL, in: controller)
    }

    func testingRehydrateCopiedProvenance(from sourceURL: URL, to destinationURL: URL) {
        rehydrateCopiedProvenance(from: sourceURL, to: destinationURL)
    }

    private func canQueueDocumentOpen(at url: URL) -> DocumentType? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            debugLog("openDocument: refusing missing file \(url.path)")
            return nil
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            debugLog("openDocument: refusing unreadable file \(url.path)")
            return nil
        }

        guard let type = DocumentType.detect(from: url) else {
            debugLog("openDocument: refusing unsupported file \(url.path)")
            return nil
        }

        return type
    }

    @discardableResult
    private func ensureMainWindowForDocumentOpen() -> MainWindowController {
        if let controller = mainWindowController {
            controller.showWindow(nil)
            NSApp.activate()
            return controller
        }

        welcomeWindowController?.close()
        welcomeWindowController = nil

        let controller = createAndShowMainWindow()
        NSApp.activate()
        return controller
    }

    internal func openDocument(at url: URL) -> Bool {
        guard let type = canQueueDocumentOpen(at: url) else {
            return false
        }

        if type == .lungfishProject {
            let controller = ensureMainWindowForDocumentOpen()
            openProject(url, in: controller)
            return true
        }

        let controller = ensureMainWindowForDocumentOpen()
        let splitViewController = controller.mainSplitViewController
        let viewerController = splitViewController?.viewerController

        if type == .lungfishReferenceBundle || type == .lungfishMultipleSequenceAlignmentBundle || type == .lungfishPhylogeneticTreeBundle || type == .lungfishMHCReferenceBundle {
            Task {
                viewerController?.showProgress("Loading \(url.lastPathComponent)...")
                do {
                    switch type {
                    case .lungfishReferenceBundle:
                        try splitViewController?.displayReferenceBundleFromExternalOpen(at: url)
                    case .lungfishMultipleSequenceAlignmentBundle:
                        try await viewerController?.displayMultipleSequenceAlignmentBundle(at: url)
                    case .lungfishPhylogeneticTreeBundle:
                        try viewerController?.displayPhylogeneticTreeBundle(at: url)
                    case .lungfishMHCReferenceBundle:
                        splitViewController?.displayMHCReferenceBundleFromExternalOpen(at: url)
                    default:
                        break
                    }
                    viewerController?.hideProgress()
                } catch {
                    viewerController?.hideProgress()
                    let alert = NSAlert()
                    alert.messageText = "Failed to Open Bundle"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    if let window = self.mainWindowController?.window ?? NSApp.keyWindow {
                        await alert.beginSheetModal(for: window)
                    }
                }
            }
            return true
        }

        Task {
            // Show progress indicator
            viewerController?.showProgress("Loading \(url.lastPathComponent)...")

            do {
                let document = try await DocumentManager.shared.loadDocument(at: url)
                debugLog("Loaded document: \(document.name) with \(document.sequences.count) sequences")

                // Hide progress and display document
                viewerController?.hideProgress()
                viewerController?.displayDocument(document)
            } catch {
                // Hide progress and show error
                viewerController?.hideProgress()

                let alert = NSAlert()
                alert.messageText = "Failed to Open File"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                if let window = self.mainWindowController?.window ?? NSApp.keyWindow {
                    await alert.beginSheetModal(for: window)
                }
            }
        }
        return true
    }

    // MARK: - Menu Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Update Sidebar menu item title based on state (Apple HIG compliance)
        // Tag 1000 is for sidebar toggle
        if menuItem.tag == 1000 {
            if let isSidebarVisible = activeMainWindowController()?.mainSplitViewController?.isSidebarVisible {
                menuItem.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            }
            return true
        }

        // Update Inspector menu item title based on state
        if menuItem.tag == 1001 {
            if let isInspectorVisible = activeMainWindowController()?.mainSplitViewController?.isInspectorVisible {
                menuItem.title = isInspectorVisible ? "Hide Inspector" : "Show Inspector"
            }
            return true
        }

        // Update DNA/RNA mode menu item state
        if menuItem.tag == 1002 {
            if let isRNAMode = activeMainWindowController()?.mainSplitViewController?.viewerController?.isRNAMode {
                menuItem.state = isRNAMode ? .on : .off
            }
            return true
        }

        if menuItem.action == #selector(checkForUpdates(_:)) {
            return canCheckForUpdatesHandler?() ?? false
        }

        if menuItem.action == #selector(increaseContentTextSize(_:))
            || menuItem.action == #selector(decreaseContentTextSize(_:))
            || menuItem.action == #selector(resetContentTextSize(_:)) {
            return canPerformContentTextSizeAction(menuItem.action)
        }

        // "Import VCF Variants..." is always enabled (auto-ingest creates bundle if needed)
        if menuItem.action == #selector(importVCFToBundle(_:)) {
            return true
        }

        // "Import BAM/CRAM Alignments..." and sample metadata require a loaded bundle
        if menuItem.action == #selector(importBAMToBundle(_:))
            || menuItem.action == #selector(importSampleMetadataToBundle(_:)) {
            let hasBundle = activeMainWindowController()?.mainSplitViewController?.viewerController?.currentBundleURL != nil
            return hasBundle
        }

        if menuItem.action == #selector(showBAMVariantCalling(_:)) {
            let bundle = activeMainWindowController()?.mainSplitViewController?.viewerController?.currentReferenceBundle
            return canShowBAMVariantCalling(bundle: bundle)
        }

        if menuItem.action == #selector(showHaplotypeDefinitions(_:)) {
            let enabled = WorkflowFeatureAvailability.current().hasHaplotypeDefinitions
            menuItem.isHidden = !enabled
            return enabled
        }

        if menuItem.action == #selector(launchWorkflowFromMenu(_:))
            || menuItem.action == #selector(promptEnableWorkflowFromMenu(_:)) {
            return true
        }

        if menuItem.action == #selector(goToPosition(_:)) {
            let viewerController = activeMainWindowController()?
                .mainSplitViewController?
                .viewerController?
                .activeSequenceViewerController
            return canNavigateToPosition(viewerController: viewerController)
        }

        if menuItem.action == #selector(goToGene(_:)) {
            let viewerController = activeMainWindowController()?
                .mainSplitViewController?
                .viewerController?
                .activeSequenceViewerController
            return canNavigateToGene(viewerController: viewerController)
        }

        // Visible-region sequence operations require an active viewer.
        if menuItem.action == #selector(reverseComplement(_:))
            || menuItem.action == #selector(translate(_:))
            || menuItem.action == #selector(copySelectionFASTA(_:)) {
            guard let activeSequenceViewer = activeMainWindowController()?
                .mainSplitViewController?
                .viewerController?
                .activeSequenceViewerController else {
                return false
            }
            return activeSequenceViewer.viewerView.canRunSelectedSequenceFASTAOperation()
        }

        // Extract can bootstrap from the currently visible region.
        if menuItem.action == #selector(extractSelection(_:)) {
            let hasViewer = activeMainWindowController()?
                .mainSplitViewController?
                .viewerController?
                .activeSequenceViewerController
                .viewerView != nil
            return hasViewer
        }

        // "Cancel All Operations" needs running operations
        if menuItem.action == #selector(cancelAllOperations(_:)) {
            return OperationCenter.shared.items.contains { $0.isCancellable }
        }

        // "Clear Completed" needs finished items
        if menuItem.action == #selector(clearCompletedOperations(_:)) {
            return OperationCenter.shared.items.contains { !$0.state.isActive }
        }

        // Storage preview requires a project successfully owned by the exact
        // originating window/session (filesystem fallback roots do not count).
        if menuItem.action == #selector(manageProjectStorage(_:)) {
            guard let controller = projectStorageOriginController(
                sender: menuItem
            ) else {
                return false
            }
            return successfullyOwnedProjectURL(for: controller) != nil
        }

        if menuItem.action == #selector(showWindowSizeDialog(_:)) {
            return activeMainWindowController()?.window != nil || NSApp.keyWindow != nil || NSApp.mainWindow != nil
        }

        if menuItem.action == #selector(newWindowForCurrentProject(_:)) {
            let controller = activeMainWindowController()
            return controller?.projectSession.projectURL != nil
                || controller?.mainSplitViewController?.sidebarController?.currentProjectURL != nil
        }

        return true
    }

    private func projectStorageOriginController(
        sender: Any?
    ) -> MainWindowController? {
        if let view = sender as? NSView {
            return view.window?.windowController as? MainWindowController
        }
        if let window = sender as? NSWindow {
            return window.windowController as? MainWindowController
        }
        return (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
    }

    private func successfullyOwnedProjectURL(
        for controller: MainWindowController
    ) -> URL? {
        guard let sessionURL = controller.projectSession.projectURL,
              let sidebarURL = controller.mainSplitViewController?
                .sidebarController?
                .currentProjectURL,
              ProjectSessionRegistry.canonicalProjectURL(sessionURL)
                == ProjectSessionRegistry.canonicalProjectURL(sidebarURL) else {
            return nil
        }
        return sessionURL
    }

    private func invalidateProjectStorage(
        for controller: MainWindowController
    ) {
        guard let window = controller.window else { return }
        let windowID = ObjectIdentifier(window)
        projectStorageBindingGenerations[windowID, default: 0] &+= 1
        projectStorageCoordinators.removeValue(forKey: windowID)?.invalidate()
    }

    func canNavigateToPosition(viewerController: ViewerViewController?) -> Bool {
        viewerController?.referenceFrame != nil
    }

    func canNavigateToGene(viewerController: ViewerViewController?) -> Bool {
        canNavigateToPosition(viewerController: viewerController)
            && viewerController?.annotationSearchIndex != nil
    }

    @objc public func showWindowSizeDialog(_ sender: Any?) {
        guard let window = mainWindowController?.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            return
        }

        let controller = WindowSizeDialogController(parentWindow: window) { [weak self] in
            self?.windowSizeDialogController = nil
        }
        windowSizeDialogController = controller
        controller.beginSheet()
    }

}

@MainActor
internal struct AppUITestViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning {
    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        AppUITestConfiguration.current.appendEvent("viralrecon.cli.invoked \(arguments.joined(separator: " "))")
        outputHandler?(.standardOutput("deterministic Viral Recon completed"))
        return ViralReconWorkflowProcessResult(
            exitCode: 0,
            standardOutput: "deterministic Viral Recon completed",
            standardError: "",
            didStreamOutput: true
        )
    }

    func cancel() {
        AppUITestConfiguration.current.appendEvent("viralrecon.cli.cancelled")
    }
}

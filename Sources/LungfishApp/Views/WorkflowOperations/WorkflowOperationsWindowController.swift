import AppKit
import LungfishWorkflow
import LungfishKit
import SwiftUI

@MainActor
final class WorkflowOperationsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: WorkflowOperationsWindowController?

    private let state: WorkflowOperationDialogState
    private var routeContext: OperationRouteContext?
    private let serviceFactory: @MainActor () -> WorkflowOperationExecutionService
    private var configurationGeneration = UUID()
    private var originValidator: @MainActor () throws -> Void = {}
    private var writeValidator: @MainActor () throws -> Void = {}


    static func show(
        projectURL: URL?,
        routeContext: OperationRouteContext? = nil,
        selectedReadURLs: [URL] = [],
        sidebarInputSelection: WorkflowSidebarInputSelection? = nil,
        initialToolID: String? = nil
    ) {
        if shared == nil {
            shared = WorkflowOperationsWindowController(
                projectURL: projectURL,
                routeContext: routeContext,
                selectedReadURLs: selectedReadURLs,
                sidebarInputSelection: sidebarInputSelection,
                initialToolID: initialToolID
            )
        } else {
            shared?.configure(
                projectURL: projectURL,
                routeContext: routeContext,
                selectedReadURLs: selectedReadURLs,
                sidebarInputSelection: sidebarInputSelection,
                initialToolID: initialToolID
            )
        }
        shared?.showWindow(nil)
    }

    init(
        projectURL: URL?,
        routeContext: OperationRouteContext?,
        selectedReadURLs: [URL],
        sidebarInputSelection: WorkflowSidebarInputSelection?,
        initialToolID: String?,
        service: WorkflowOperationExecutionService? = nil,
        serviceFactory: (@MainActor () -> WorkflowOperationExecutionService)? = nil,
        providedState: WorkflowOperationDialogState? = nil,
        persistWindowFrame: Bool = true,
        appDelegate: AppDelegate? = NSApp.delegate as? AppDelegate
    ) {
        self.state = providedState ?? WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: selectedReadURLs,
            sidebarInputSelection: sidebarInputSelection,
            projectDiscoveryMode: .asynchronous,
            initialToolID: initialToolID
        )
        self.routeContext = routeContext
        self.serviceFactory = serviceFactory ?? { service ?? WorkflowOperationExecutionService() }
        self.originValidator = Self.captureReplayOrigin(routeContext: routeContext, appDelegate: appDelegate)
        self.writeValidator = Self.captureReplayOrigin(routeContext: routeContext, appDelegate: appDelegate, requireWritable: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workflow Operations"
        window.minSize = NSSize(width: 720, height: 460)
        if persistWindowFrame { window.setFrameAutosaveName("WorkflowOperationsWindow") }
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(WorkflowOperationsAccessibilityID.window)

        super.init(window: window)
        window.delegate = self

        window.contentView = NSHostingView(
            rootView: WorkflowOperationsDialog(
                state: state,
                onRun: { [weak self] request in
                    self?.run(request)
                },
                onCreateTwelveSReferenceBundle: { [weak self] configuration in
                    self?.createTwelveSReferenceBundle(configuration)
                },
                onOpenPreviousRun: { [weak self] in self?.presentPreviousRunChooser() },
                onCancel: { [weak self] in self?.close() }
            )
        )
        refreshAISpecialistPresetAvailability()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func configure(
        projectURL: URL?,
        routeContext: OperationRouteContext?,
        selectedReadURLs: [URL],
        sidebarInputSelection: WorkflowSidebarInputSelection?,
        initialToolID: String?
    ) {
        configurationGeneration = UUID()
        self.routeContext = routeContext
        originValidator = Self.captureReplayOrigin(routeContext: routeContext, appDelegate: NSApp.delegate as? AppDelegate)
        writeValidator = Self.captureReplayOrigin(routeContext: routeContext, appDelegate: NSApp.delegate as? AppDelegate, requireWritable: true)
        state.configureProject(
            projectURL: projectURL,
            selectedReadURLs: selectedReadURLs,
            sidebarInputSelection: sidebarInputSelection
        )
        if let initialToolID {
            state.selectTool(initialToolID)
        }
        refreshAISpecialistPresetAvailability()
    }

    func reopenPreviousRun(
        at url: URL,
        loader: @escaping @Sendable (URL) throws -> LocalWorkflowReplayConfiguration = LocalWorkflowReplayPreflight.load(from:)
    ) async throws {
        let generation = UUID()
        configurationGeneration = generation
        let validateOrigin = originValidator
        try validateOrigin()
        let worker = Task.detached(priority: .userInitiated) { try loader(url) }
        let configuration: LocalWorkflowReplayConfiguration
        do { configuration = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
        catch {
            guard configurationGeneration == generation else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard configurationGeneration == generation else { throw CancellationError() }
        try validateOrigin()
        try state.restoreReplayConfiguration(configuration, sourceBundleURL: url)
    }

    func choosePreviousRun(using chooser: @MainActor () async -> URL?) async throws {
        let generation = configurationGeneration
        let validateOrigin = originValidator
        try validateOrigin()
        guard let source = await chooser() else { return }
        guard configurationGeneration == generation else { throw CancellationError() }
        try validateOrigin()
        try await reopenPreviousRun(at: source)
    }

    static func captureReplayOrigin(
        routeContext: OperationRouteContext?, appDelegate: AppDelegate?, requireWritable: Bool = false
    ) -> @MainActor () throws -> Void {
        // A projectless configuration remains projectless; it never falls through to the frontmost window later.
        guard let routeContext else {
            return {
                if requireWritable {
                    throw LocalWorkflowReplayError.repairRequired("Open an intended project window, then reopen this run before starting a new attempt.")
                }
            }
        }
        guard let appDelegate, let owner = appDelegate.targetMainWindowController(routeContext: routeContext) else {
            return { throw LocalWorkflowReplayError.repairRequired("The originating window is unavailable. Open Previous Run from the intended window.") }
        }
        let generation = owner.projectSession.documentGeneration
        return { [weak appDelegate, weak owner] in
            guard let appDelegate, let owner,
                  appDelegate.targetMainWindowController(routeContext: routeContext) === owner,
                  owner.projectSession.documentGeneration == generation,
                  !owner.projectSession.isFilesystemUnavailable else {
                throw LocalWorkflowReplayError.repairRequired("The originating project was closed or replaced. Open Previous Run from the intended window.")
            }
            if requireWritable, appDelegate.isProjectWriteBlocked(projectURL: routeContext.projectURL,
                windowStateScope: owner.projectSession.windowStateScope) {
                throw LocalWorkflowReplayError.repairRequired("The originating project is read-only. Reopen it with write access before starting a new attempt.")
            }
        }
    }

    private func refreshAISpecialistPresetAvailability() {
        Task { @MainActor [weak self] in
            let available = await GenotypeAIHaplotypingExecutionService.hasConfiguredProvider()
            self?.state.setAISpecialistPresetsAvailable(available)
        }
    }

    private func invalidateConfiguration() {
        configurationGeneration = UUID()
        state.clearReplayConfiguration()
    }

    func windowWillClose(_ notification: Notification) { invalidateConfiguration() }

    override func close() {
        invalidateConfiguration()
        super.close()
    }

    @discardableResult
    func executeReplay(_ request: WorkflowOperationLaunchRequest) async throws -> [URL] {
        guard state.replayConfiguration != nil, state.isRunEnabled,
              try state.makeLaunchRequest() == request else {
            throw LocalWorkflowReplayError.repairRequired("Check the current retained configuration before starting.")
        }
        let generation = configurationGeneration
        let sessionID = state.replaySessionID
        let route = routeContext
        let validateOrigin = originValidator
        let validateWrite = writeValidator
        let service = serviceFactory() // Each production attempt owns its runner and cancellation handle.
        state.isSubmittingReplay = true
        defer { if configurationGeneration == generation { state.isSubmittingReplay = false } }
        return try await service.run(request, routeContext: route, beforeRegister: { [weak self] in
            guard let self, self.configurationGeneration == generation, self.state.replaySessionID == sessionID,
                  self.state.matchesReplayLaunchRequest(request) else { throw CancellationError() }
            try validateOrigin()
            try validateWrite()
            self.window?.orderOut(nil)
        })
    }

    private func run(_ request: WorkflowOperationLaunchRequest) {
        let generation = configurationGeneration
        let route = routeContext
        let replay = state.replayConfiguration != nil
        if !replay { window?.orderOut(nil) }
        Task { @MainActor [weak self] in
            guard let self, configurationGeneration == generation else { return }
            do {
                if replay { _ = try await executeReplay(request) }
                else { _ = try await serviceFactory().run(request, routeContext: route) }
            } catch {
                guard configurationGeneration == generation, !(error is CancellationError) else { return }
                showWindow(nil)
                state.errorMessage = error.localizedDescription
                state.showingError = true
            }
        }
    }

    private func presentPreviousRunChooser() {
        let generation = configurationGeneration
        Task { @MainActor [weak self] in
            guard let self, configurationGeneration == generation else { return }
            do {
                try await choosePreviousRun { [weak self] in
                    guard let self else { return nil }
                    let panel = NSOpenPanel()
                    panel.title = "Open Previous Local Run"
                    panel.message = "Choose a .lungfishrun folder. Its retained configuration will open for review."
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.treatsFilePackagesAsDirectories = true
                    panel.allowsMultipleSelection = false
                    return await withCheckedContinuation { continuation in
                        let completion: (NSApplication.ModalResponse) -> Void = { response in
                            continuation.resume(returning: response == .OK ? panel.url : nil)
                        }
                        if let window = self.window { panel.beginSheetModal(for: window, completionHandler: completion) }
                        else { panel.begin(completionHandler: completion) }
                    }
                }
            } catch {
                // Reopening starts a new generation; errors belong to this window unless it was reconfigured/closed.
                guard configurationGeneration == generation || !(error is CancellationError) else { return }
                state.errorMessage = error.localizedDescription
                state.showingError = true
            }
        }
    }

    static func replaySourceBundleURL(for item: OperationCenter.Item) -> URL? {
        guard !item.state.isActive, item.operationType == .workflow else { return nil }
        return ([item.targetBundleURL].compactMap { $0 } + item.bundleURLs)
            .first { $0.pathExtension.lowercased() == "lungfishrun" }
    }

    static func showPreviousRun(at source: URL, routeContext: OperationRouteContext?) {
        let capturedRoute = routeContext ?? (NSApp.delegate as? AppDelegate)?.currentOperationRouteContext()
        show(projectURL: capturedRoute?.projectURL, routeContext: capturedRoute)
        guard let controller = shared else { return }
        let generation = controller.configurationGeneration
        Task { @MainActor [weak controller] in
            guard let controller, controller.configurationGeneration == generation else { return }
            do { try await controller.reopenPreviousRun(at: source) }
            catch {
                guard !(error is CancellationError) else { return }
                controller.state.errorMessage = error.localizedDescription
                controller.state.showingError = true
            }
        }
    }

    private func createTwelveSReferenceBundle(_ configuration: TwelveSReferenceBundleBuildConfiguration) {
        let route = routeContext
        let service = serviceFactory()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await service.runTwelveSReferenceBundleBuild(configuration, routeContext: route)
                state.refreshProjectReferences(selecting: configuration.outputURL)
            } catch {
                state.errorMessage = error.localizedDescription
                state.showingError = true
            }
        }
    }
}

import AppKit
import Foundation
import LungfishIO
import LungfishWorkflow

@MainActor
final class ProjectStorageCoordinator {
    private enum RetryPhase {
        case revalidation
        case cleanup
    }

    struct CleanupInvocation: Sendable {
        let cleanupID: UUID
        let projectURL: URL
        let projectIdentity: FileSystemObjectIdentity
        let selectedEntries: [ProjectStorageEntry]
        let workflowName: String
        let workflowVersion: String
        let toolName: String
        let toolVersion: String
        let argv: [String]
        let durableReplayArgv: [String]?
        let options: ProvenanceOptions
        let runtimeIdentity: ProvenanceRuntimeIdentity
        let startedAt: Date
    }

    struct CleanupOutcome: Sendable {
        let cleanupID: UUID
        let summary: ProjectStorageCleanupExecutionSummary
        let summaryURL: URL
        let provenanceURL: URL
    }

    struct Operations: Sendable {
        var scan:
            @Sendable (
                URL,
                @escaping @Sendable (ProjectStorageScanProgress) -> Void
            ) async throws -> ProjectStorageScanResult
        var cleanup:
            @Sendable (CleanupInvocation) async throws -> CleanupOutcome
        var canonicalizeProjectURL: @Sendable (URL) -> URL
        var readProjectIdentity:
            @Sendable (URL) throws -> FileSystemObjectIdentity

        init(
            scan:
                @escaping @Sendable (
                    URL,
                    @escaping @Sendable (ProjectStorageScanProgress) -> Void
                ) async throws -> ProjectStorageScanResult = {
                    projectURL,
                    progress in
                    try await ProjectStorageCoordinator.runDetachedCancellable {
                        try ProjectStorageScanner().scan(
                            projectURL: projectURL,
                            progress: progress
                        )
                    }
                },
            cleanup:
                @escaping @Sendable (CleanupInvocation) async throws
                    -> CleanupOutcome = { invocation in
                        try await ProjectStorageCoordinator
                            .runDetachedCancellable {
                                try await performCleanup(invocation)
                            }
                    },
            canonicalizeProjectURL:
                @escaping @Sendable (URL) -> URL = {
                    $0.standardizedFileURL.resolvingSymlinksInPath()
                },
            readProjectIdentity:
                @escaping @Sendable (URL) throws
                    -> FileSystemObjectIdentity = {
                        try FileSystemObjectIdentity.noFollow($0)
                    }
        ) {
            self.scan = scan
            self.cleanup = cleanup
            self.canonicalizeProjectURL = canonicalizeProjectURL
            self.readProjectIdentity = readProjectIdentity
        }
    }

    @MainActor
    private final class Binding {
        weak var window: NSWindow?
        weak var controller: MainWindowController?
        let windowID: ObjectIdentifier
        let sessionID: UUID
        let windowStateScopeID: UUID
        let projectURL: URL
        let structuralProjectPath: String
        let projectIdentity: FileSystemObjectIdentity
        let generation: UInt64
        let generationProvider: @MainActor () -> UInt64

        init(
            window: NSWindow,
            controller: MainWindowController,
            projectURL: URL,
            projectIdentity: FileSystemObjectIdentity,
            generation: UInt64,
            generationProvider: @escaping @MainActor () -> UInt64
        ) {
            self.window = window
            self.controller = controller
            self.windowID = ObjectIdentifier(window)
            self.sessionID = controller.projectSession.id
            self.windowStateScopeID =
                controller.projectSession.windowStateScope.id
            self.projectURL = projectURL.standardizedFileURL
            self.structuralProjectPath =
                (controller.projectSession.projectURL ?? projectURL)
                    .standardizedFileURL.path
            self.projectIdentity = projectIdentity
            self.generation = generation
            self.generationProvider = generationProvider
        }

        func isStructurallyCurrent() -> Bool {
            guard let window,
                  let controller,
                  window.windowController === controller,
                  controller.projectSession.id == sessionID,
                  controller.projectSession.windowStateScope.id
                    == windowStateScopeID,
                  generationProvider() == generation,
                  let currentURL = controller.projectSession.projectURL,
                  currentURL.standardizedFileURL.path
                    == structuralProjectPath else {
                return false
            }
            return true
        }
    }

    private final class ProgressRelay: @unchecked Sendable {
        private let lock = NSLock()
        private let interval: TimeInterval
        private var lastDelivery: TimeInterval?
        private let deliver:
            @Sendable (ProjectStorageScanProgress) -> Void

        init(
            interval: TimeInterval,
            deliver:
                @escaping @Sendable (ProjectStorageScanProgress) -> Void
        ) {
            self.interval = interval
            self.deliver = deliver
        }

        func receive(_ progress: ProjectStorageScanProgress) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let shouldDeliver =
                lastDelivery.map { now - $0 >= interval } ?? true
            if shouldDeliver {
                lastDelivery = now
            }
            lock.unlock()
            if shouldDeliver {
                deliver(progress)
            }
        }
    }

    private final class SheetLifecycleDelegate: NSObject, NSWindowDelegate {
        weak var coordinator: ProjectStorageCoordinator?

        init(coordinator: ProjectStorageCoordinator) {
            self.coordinator = coordinator
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            coordinator?.sheetRequestedClose(sender)
            return false
        }

        func windowWillClose(_ notification: Notification) {
            guard let sheet = notification.object as? NSWindow else {
                return
            }
            coordinator?.sheetWillClose(sheet)
        }
    }

    private static var presentingWindowIDs: Set<ObjectIdentifier> = []

    private let binding: Binding
    private let operations: Operations
    private let completion: @MainActor () -> Void
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var canonicalAuthorityProjectURL: URL?
    private var sheetWindow: NSWindow?
    private var sheetViewController: ProjectStorageSheetViewController?
    private var sheetLifecycleDelegate: SheetLifecycleDelegate?
    private var isClosed = false
    private(set) lazy var viewModel = makeViewModel()
    var presentedSheetWindow: NSWindow? { sheetWindow }

    init(
        presentingWindow: NSWindow,
        controller: MainWindowController,
        projectURL: URL,
        projectIdentity: FileSystemObjectIdentity,
        generation: UInt64,
        generationProvider: @escaping @MainActor () -> UInt64,
        operations: Operations = .init(),
        completion: @escaping @MainActor () -> Void
    ) {
        self.binding = Binding(
            window: presentingWindow,
            controller: controller,
            projectURL: projectURL,
            projectIdentity: projectIdentity,
            generation: generation,
            generationProvider: generationProvider
        )
        self.operations = operations
        self.completion = completion
    }

    deinit {
        operationTask?.cancel()
    }

    @discardableResult
    func present() -> Bool {
        guard binding.isStructurallyCurrent(),
              let presentingWindow = binding.window,
              Self.claimPresentation(on: presentingWindow) else {
            return false
        }
        let controller = ProjectStorageSheetViewController(
            viewModel: viewModel
        )
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = viewModel.sheetTitle
        sheet.identifier = NSUserInterfaceItemIdentifier(
            ProjectStorageAccessibilityID.sheet
        )
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        let lifecycleDelegate = SheetLifecycleDelegate(coordinator: self)
        sheet.delegate = lifecycleDelegate
        sheetLifecycleDelegate = lifecycleDelegate
        sheetViewController = controller
        sheetWindow = sheet
        presentingWindow.beginSheet(sheet)
        startScan()
        return true
    }

    func invalidate() {
        operationTask?.cancel()
        _ = viewModel.revalidateBinding()
        close()
    }

    private func makeViewModel() -> ProjectStorageSheetViewModel {
        ProjectStorageSheetViewModel(
            projectURL: binding.projectURL,
            projectIdentity: binding.projectIdentity,
            bindingGeneration: binding.generation,
            allowsCleanup:
                binding.controller?.projectSession.isReadOnlyRecommended
                    != true,
            bindingIsCurrent: { [weak self] in
                self?.binding.isStructurallyCurrent() == true
            },
            requestCleanup: { [weak self] in
                self?.startCleanup()
            },
            requestClose: { [weak self] in
                self?.close()
            },
            requestCancellation: { [weak self] in
                self?.operationTask?.cancel()
            },
            requestRetryScan: { [weak self] in
                self?.startScan()
            },
            requestRetryFailed: { [weak self] entries in
                self?.retryFailed(entries)
            },
            requestReveal: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        )
    }

    private func startScan() {
        guard binding.isStructurallyCurrent() else {
            invalidate()
            return
        }
        viewModel.beginScanning()
        let attempt = beginOperationAttempt()
        let relay = ProgressRelay(interval: 0.1) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentAttempt(attempt) else {
                    return
                }
                self.viewModel.receiveScanProgress(progress)
            }
        }
        let scan = operations.scan
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let projectURL =
                    try await self.currentAuthorityProjectURL()
                guard self.isCurrentAttempt(attempt) else { return }
                guard let projectURL else {
                    self.invalidate()
                    return
                }
                let result = try await scan(projectURL) {
                    relay.receive($0)
                }
                try Task.checkCancellation()
                guard self.isCurrentAttempt(attempt) else { return }
                let authorityURL =
                    try await self.currentAuthorityProjectURL()
                guard self.isCurrentAttempt(attempt) else { return }
                guard authorityURL != nil else {
                    self.invalidate()
                    return
                }
                self.viewModel.receiveScanResult(result)
            } catch is CancellationError {
                if self.isCurrentAttempt(attempt) {
                    self.viewModel.receiveScanCancellation()
                }
            } catch {
                if self.isCurrentAttempt(attempt) {
                    self.viewModel.receiveScanFailure(error)
                }
            }
        }
    }

    private func startCleanup() {
        guard binding.isStructurallyCurrent() else {
            invalidate()
            return
        }
        let selected = viewModel.selectedEntries
        guard !selected.isEmpty else { return }
        runCleanup(for: selected)
    }

    private func runCleanup(for selected: [ProjectStorageEntry]) {
        let cleanup = operations.cleanup
        let attempt = beginOperationAttempt()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let projectURL =
                    try await self.currentAuthorityProjectURL()
                guard self.isCurrentAttempt(attempt) else { return }
                guard let projectURL else {
                    self.invalidate()
                    return
                }
                let invocation = Self.cleanupInvocation(
                    projectURL: projectURL,
                    projectIdentity: self.binding.projectIdentity,
                    selectedEntries: selected
                )
                let outcome = try await cleanup(invocation)
                guard self.isCurrentAttempt(attempt) else { return }
                guard outcome.cleanupID == invocation.cleanupID else {
                    self.invalidate()
                    return
                }
                self.viewModel.receiveCleanupResult(
                    summary: outcome.summary,
                    summaryURL: outcome.summaryURL,
                    provenanceURL: outcome.provenanceURL
                )
            } catch is CancellationError {
                if self.isCurrentAttempt(attempt) {
                    self.viewModel.receiveCleanupFailure(
                        ProjectStorageCoordinatorError
                            .cancelledBeforeDurablePartialReceipt
                    )
                }
            } catch {
                if self.isCurrentAttempt(attempt) {
                    self.viewModel.receiveCleanupFailure(error)
                }
            }
        }
    }

    private func retryFailed(_ priorEntries: [ProjectStorageEntry]) {
        guard binding.isStructurallyCurrent(), !priorEntries.isEmpty else {
            invalidate()
            return
        }
        var priorByPath: [String: ProjectStorageEntry] = [:]
        for entry in priorEntries {
            guard priorByPath.updateValue(
                entry,
                forKey: entry.relativePath
            ) == nil else {
                viewModel.receiveCleanupFailure(
                    ProjectStorageCoordinatorError
                        .duplicateCleanupSummaryItem
                )
                return
            }
        }
        let scan = operations.scan
        let cleanup = operations.cleanup
        let attempt = beginOperationAttempt()
        let relay = ProgressRelay(interval: 0.1) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentAttempt(attempt) else {
                    return
                }
                self.viewModel.receiveScanProgress(progress)
            }
        }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var phase = RetryPhase.revalidation
            do {
                let projectURL =
                    try await self.currentAuthorityProjectURL()
                guard self.isCurrentAttempt(attempt) else { return }
                guard let projectURL else {
                    self.invalidate()
                    return
                }
                let fresh = try await scan(projectURL) {
                    relay.receive($0)
                }
                try Task.checkCancellation()
                guard self.isCurrentAttempt(attempt) else { return }
                let authorityURL =
                    try await self.currentAuthorityProjectURL()
                try Task.checkCancellation()
                guard self.isCurrentAttempt(attempt) else { return }
                guard authorityURL != nil,
                      fresh.projectIdentity == self.binding.projectIdentity else {
                    self.invalidate()
                    return
                }
                let retryable = fresh.entries.filter { entry in
                    guard entry.classification.isRemovable,
                          let prior = priorByPath[entry.relativePath] else {
                        return false
                    }
                    return prior.identity == entry.identity
                }
                guard !retryable.isEmpty else {
                    self.viewModel.receiveScanResult(fresh)
                    return
                }
                self.viewModel.prepareRetry(with: retryable)
                phase = .cleanup
                let invocation = Self.cleanupInvocation(
                    projectURL: projectURL,
                    projectIdentity: fresh.projectIdentity,
                    selectedEntries: retryable
                )
                let outcome = try await cleanup(invocation)
                guard self.isCurrentAttempt(attempt) else { return }
                guard outcome.cleanupID == invocation.cleanupID else {
                    self.invalidate()
                    return
                }
                self.viewModel.receiveCleanupResult(
                    summary: outcome.summary,
                    summaryURL: outcome.summaryURL,
                    provenanceURL: outcome.provenanceURL
                )
            } catch is CancellationError {
                if self.isCurrentAttempt(attempt) {
                    switch phase {
                    case .revalidation:
                        self.viewModel.receiveRevalidationCancellation()
                    case .cleanup:
                        self.viewModel.receiveCleanupFailure(
                            ProjectStorageCoordinatorError
                                .cancelledBeforeDurablePartialReceipt
                        )
                    }
                }
            } catch {
                if self.isCurrentAttempt(attempt) {
                    switch phase {
                    case .revalidation:
                        self.viewModel.receiveRevalidationFailure(error)
                    case .cleanup:
                        self.viewModel.receiveCleanupFailure(error)
                    }
                }
            }
        }
    }

    private func beginOperationAttempt() -> UInt64 {
        operationTask?.cancel()
        operationGeneration += 1
        return operationGeneration
    }

    private func isCurrentAttempt(_ attempt: UInt64) -> Bool {
        !isClosed
            && attempt == operationGeneration
            && binding.isStructurallyCurrent()
    }

    private func currentAuthorityProjectURL() async throws -> URL? {
        let cachedURL = canonicalAuthorityProjectURL
        let readProjectIdentity = operations.readProjectIdentity
        let canonicalizeProjectURL = operations.canonicalizeProjectURL
        let projectURL = cachedURL ?? binding.projectURL
        let expectedIdentity = binding.projectIdentity
        let authority = try await Self.runDetachedCancellable {
            let canonicalURL =
                cachedURL ?? canonicalizeProjectURL(projectURL)
            return (
                canonicalURL,
                try readProjectIdentity(canonicalURL)
            )
        }
        guard authority.1 == expectedIdentity else { return nil }
        if canonicalAuthorityProjectURL == nil {
            canonicalAuthorityProjectURL = authority.0
            viewModel.bindAuthorityProjectURL(authority.0)
        }
        return authority.0
    }

    private func close() {
        close(sheetIsAlreadyClosing: false)
    }

    private func sheetRequestedClose(_ sheet: NSWindow) {
        guard sheet === sheetWindow else { return }
        close(sheetIsAlreadyClosing: false)
    }

    private func sheetWillClose(_ sheet: NSWindow) {
        guard sheet === sheetWindow else { return }
        close(sheetIsAlreadyClosing: true)
    }

    private func close(sheetIsAlreadyClosing: Bool) {
        guard !isClosed else { return }
        isClosed = true
        operationTask?.cancel()
        operationTask = nil
        operationGeneration += 1
        if let presentingWindow = binding.window,
           let sheetWindow,
           !sheetIsAlreadyClosing,
           sheetWindow.sheetParent === presentingWindow {
            presentingWindow.endSheet(sheetWindow)
        }
        Self.releasePresentation(windowID: binding.windowID)
        sheetWindow?.delegate = nil
        sheetLifecycleDelegate = nil
        sheetWindow = nil
        sheetViewController = nil
        completion()
    }

    static func cleanupInvocation(
        projectURL: URL,
        projectIdentity: FileSystemObjectIdentity,
        selectedEntries: [ProjectStorageEntry],
        appArgv: [String] = CommandLine.arguments,
        appVersion: String = WorkflowRun.currentAppVersion,
        cleanupID: UUID = UUID(),
        startedAt: Date = Date()
    ) -> CleanupInvocation {
        let selected = selectedEntries.sorted {
            $0.relativePath < $1.relativePath
        }
        let logical = saturatedTotal(selected, keyPath: \.logicalBytes)
        let allocated = saturatedTotal(selected, keyPath: \.allocatedBytes)
        let categories = Array(Set(selected.map(\.category.rawValue))).sorted()
        let explicit: [String: ParameterValue] = [
            "trigger": .string("user-requested"),
            "action": .string("move-to-trash"),
            "selectedRelativePaths": .array(
                selected.map { .string($0.relativePath) }
            ),
            "selectedCategories": .array(
                categories.map(ParameterValue.string)
            ),
            "estimatedLogicalBytes": .integer(
                Int(clamping: logical)
            ),
            "estimatedAllocatedBytes": .integer(
                Int(clamping: allocated)
            ),
        ]
        let defaults: [String: ParameterValue] = [
            "permanentDeleteFallback": .boolean(false),
            "requiresIdentityRevalidation": .boolean(true),
            "requiresRemovableClassification": .boolean(true),
            "trashIsRecoverable": .boolean(true),
        ]
        return .init(
            cleanupID: cleanupID,
            projectURL: projectURL.standardizedFileURL,
            projectIdentity: projectIdentity,
            selectedEntries: selected,
            workflowName: "Manage Project Storage",
            workflowVersion: appVersion,
            toolName: "Lungfish",
            toolVersion: appVersion,
            argv: appArgv,
            durableReplayArgv: nil,
            options: .init(
                explicit: explicit,
                defaults: defaults,
                resolvedDefaults: defaults
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: appVersion
            ),
            startedAt: startedAt
        )
    }

    static func testingRunDetached<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated) {
            body()
        }.value
    }

    static func testingLatestPublishedCleanupOutcome(
        operationDirectoryURL: URL,
        expectedOperationDirectoryIdentity:
            FileSystemObjectIdentity,
        cleanupID: UUID
    ) throws -> CleanupOutcome {
        try latestPublishedCleanupOutcome(
            operationDirectoryURL: operationDirectoryURL,
            expectedOperationDirectoryIdentity:
                expectedOperationDirectoryIdentity,
            cleanupID: cleanupID
        )
    }

    static func testingClaimPresentation(on window: NSWindow) -> Bool {
        claimPresentation(on: window)
    }

    static func testingReleasePresentation(on window: NSWindow) {
        releasePresentation(on: window)
    }

    private static func claimPresentation(on window: NSWindow) -> Bool {
        let id = ObjectIdentifier(window)
        guard presentingWindowIDs.insert(id).inserted else { return false }
        return true
    }

    private static func releasePresentation(on window: NSWindow) {
        releasePresentation(windowID: ObjectIdentifier(window))
    }

    private static func releasePresentation(windowID: ObjectIdentifier) {
        presentingWindowIDs.remove(windowID)
    }

    nonisolated private static func runDetachedCancellable<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) {
            try await operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func saturatedTotal(
        _ entries: [ProjectStorageEntry],
        keyPath: KeyPath<ProjectStorageEntry, UInt64> & Sendable
    ) -> UInt64 {
        entries.reduce(into: 0) { total, entry in
            let (next, overflow) = total.addingReportingOverflow(
                entry[keyPath: keyPath]
            )
            total = overflow ? .max : next
        }
    }
}

private enum ProjectStorageCoordinatorError: Error, LocalizedError {
    case cancelledBeforeDurablePartialReceipt
    case missingCancellationReceipt
    case mismatchedCancellationReceipt
    case duplicateCleanupSummaryItem

    var errorDescription: String? {
        switch self {
        case .cancelledBeforeDurablePartialReceipt:
            return "Cleanup stopped before a durable partial receipt was available."
        case .missingCancellationReceipt:
            return "Cleanup stopped without a paired summary and provenance receipt."
        case .mismatchedCancellationReceipt:
            return "The newest cleanup summary and provenance receipt do not match."
        case .duplicateCleanupSummaryItem:
            return "The cleanup receipt contains duplicate item identifiers."
        }
    }
}

private func performCleanup(
    _ invocation: ProjectStorageCoordinator.CleanupInvocation
) async throws -> ProjectStorageCoordinator.CleanupOutcome {
    let preparation = try ProjectStorageCleanupReceiptWriter()
        .prepareConfirmedCleanup(
            .init(
                cleanupID: invocation.cleanupID,
                projectURL: invocation.projectURL,
                projectIdentity: invocation.projectIdentity,
                selectedEntries: invocation.selectedEntries,
                workflowName: invocation.workflowName,
                workflowVersion: invocation.workflowVersion,
                toolName: invocation.toolName,
                toolVersion: invocation.toolVersion,
                argv: invocation.argv,
                durableReplayArgv: invocation.durableReplayArgv,
                options: invocation.options,
                runtimeIdentity: invocation.runtimeIdentity,
                startedAt: invocation.startedAt
            )
        )
    do {
        let execution = try await ProjectStorageCleanupExecutor().execute(
            .init(
                projectURL: invocation.projectURL,
                cleanupID: invocation.cleanupID,
                argv: invocation.argv,
                durableReplayArgv: invocation.durableReplayArgv,
                options: invocation.options,
                runtimeIdentity: invocation.runtimeIdentity,
                startedAt: invocation.startedAt
            )
        )
        return .init(
            cleanupID: invocation.cleanupID,
            summary: execution.summary,
            summaryURL: execution.summaryURL,
            provenanceURL: execution.provenanceURL
        )
    } catch is CancellationError {
        return try latestPublishedCleanupOutcome(
            preparation: preparation,
            cleanupID: invocation.cleanupID
        )
    }
}

private func latestPublishedCleanupOutcome(
    preparation: ProjectStorageCleanupPreparation,
    cleanupID: UUID
) throws -> ProjectStorageCoordinator.CleanupOutcome {
    try latestPublishedCleanupOutcome(
        operationDirectoryURL: preparation.operationDirectoryURL,
        expectedOperationDirectoryIdentity:
            preparation.operationDirectoryIdentity,
        cleanupID: cleanupID
    )
}

private func latestPublishedCleanupOutcome(
    operationDirectoryURL: URL,
    expectedOperationDirectoryIdentity:
        FileSystemObjectIdentity,
    cleanupID: UUID
) throws -> ProjectStorageCoordinator.CleanupOutcome {
    let execution: ProjectStorageCleanupExecutionResult
    do {
        execution = try ProjectStoragePublishedCleanupOutcomeReader()
            .readLatest(
                operationDirectoryURL: operationDirectoryURL,
                expectedOperationDirectoryIdentity:
                    expectedOperationDirectoryIdentity,
                cleanupID: cleanupID
            )
    } catch let error as ProjectStoragePublishedCleanupOutcomeError {
        switch error {
        case .missingCompleteReceipt:
            throw ProjectStorageCoordinatorError
                .missingCancellationReceipt
        case .unsafeAuthority, .mismatchedReceipt:
            throw ProjectStorageCoordinatorError
                .mismatchedCancellationReceipt
        }
    } catch {
        throw ProjectStorageCoordinatorError
            .mismatchedCancellationReceipt
    }
    return .init(
        cleanupID: cleanupID,
        summary: execution.summary,
        summaryURL: execution.summaryURL,
        provenanceURL: execution.provenanceURL
    )
}

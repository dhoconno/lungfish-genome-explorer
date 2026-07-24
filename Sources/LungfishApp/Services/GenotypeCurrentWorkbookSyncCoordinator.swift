import AppKit
import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Serializes `current.xlsx` publication independently for each genotype bundle.
@MainActor
final class GenotypeCurrentWorkbookSyncCoordinator {
    enum Phase: Equatable {
        case current
        case dirty
        case updating
        case dirtyWhileUpdating
        case failed(String)
    }

    struct Request: Sendable {
        let bundleURL: URL
        let displayedCalls: [GenotypeWorkbookHaplotypeCall]
        let effectiveCalls: [GenotypeWorkbookHaplotypeCall]
        let includedLoci: [String]
        let annotationSidecarURL: URL?
        let annotationOnly: Bool
        let fingerprint: GenotypeCurrentWorkbookInputFingerprint
        let routeContext: OperationRouteContext?

        var fingerprintInputs: GenotypeWorkbookFingerprintInputs {
            GenotypeWorkbookFingerprintInputs(
                calls: displayedCalls,
                includedLoci: includedLoci
            )
        }

        init(
            bundleURL: URL,
            displayedCalls: [GenotypeWorkbookHaplotypeCall],
            effectiveCalls: [GenotypeWorkbookHaplotypeCall],
            includedLoci: [String],
            annotationSidecarURL: URL?,
            annotationOnly: Bool,
            fingerprint: GenotypeCurrentWorkbookInputFingerprint,
            routeContext: OperationRouteContext?
        ) {
            self.bundleURL = bundleURL.standardizedFileURL
            self.displayedCalls = displayedCalls
            self.effectiveCalls = effectiveCalls
            self.includedLoci = includedLoci
            self.annotationSidecarURL = annotationSidecarURL?.standardizedFileURL
            self.annotationOnly = annotationOnly
            self.fingerprint = fingerprint
            self.routeContext = routeContext
        }
    }

    @MainActor
    protocol IdleCancellation: AnyObject {
        func cancel()
    }

    typealias RecordedFingerprintLoader =
        @MainActor (URL) async -> GenotypeCurrentWorkbookInputFingerprint?
    typealias CurrentWorkbookResolver = @MainActor (URL) async -> URL
    typealias UpdateRunner =
        @MainActor (Request, GenotypeCurrentWorkbookSyncIntent) async throws -> URL
    typealias WorkbookOpener = @MainActor (URL) -> Void
    typealias IdleScheduler =
        @MainActor (
            _ delayNanoseconds: UInt64,
            _ action: @escaping @MainActor @Sendable () async -> Void
        ) -> any IdleCancellation

    static let idleDelayNanoseconds: UInt64 = 90_000_000_000

    @MainActor
    final class Observation {
        private weak var coordinator: GenotypeCurrentWorkbookSyncCoordinator?
        private let id: UUID

        fileprivate init(
            coordinator: GenotypeCurrentWorkbookSyncCoordinator,
            id: UUID
        ) {
            self.coordinator = coordinator
            self.id = id
        }

        func cancel() {
            coordinator?.observers.removeValue(forKey: id)
            coordinator = nil
        }

    }

    private struct BundleState {
        var phase: Phase = .current
        var recordedFingerprintWasLoaded = false
        var recordedFingerprint: GenotypeCurrentWorkbookInputFingerprint?
        var fingerprintLoadTask: Task<GenotypeCurrentWorkbookInputFingerprint?, Never>?
        var publishedFingerprint: GenotypeCurrentWorkbookInputFingerprint?
        var latestRequest: Request?
        var generation: UInt64 = 0
        var pendingIntent: GenotypeCurrentWorkbookSyncIntent = .automaticIdle
        var operation: Task<URL, Error>?
        var openAfterSuccess = false
        var idleGeneration: UInt64 = 0
        var idleCancellation: (any IdleCancellation)?
    }

    private typealias Observer = @MainActor (URL, Phase) -> Bool

    private let recordedFingerprintLoader: RecordedFingerprintLoader
    private let currentWorkbookResolver: CurrentWorkbookResolver
    private let updateRunner: UpdateRunner
    private let workbookOpener: WorkbookOpener
    private let idleScheduler: IdleScheduler
    private var states: [String: BundleState] = [:]
    private var observers: [UUID: Observer] = [:]

    init(
        recordedFingerprintLoader: RecordedFingerprintLoader? = nil,
        currentWorkbookResolver: CurrentWorkbookResolver? = nil,
        updateRunner: UpdateRunner? = nil,
        workbookOpener: WorkbookOpener? = nil,
        idleScheduler: IdleScheduler? = nil
    ) {
        self.recordedFingerprintLoader = recordedFingerprintLoader ?? { bundleURL in
            await Task.detached {
                guard let manifest = try? ONTGenotypeResultBundle.loadManifest(from: bundleURL)
                else {
                    return nil
                }
                return try? GenotypeCurrentWorkbookInputFingerprint.recorded(
                    in: manifest,
                    bundleURL: bundleURL
                )
            }.value
        }
        self.currentWorkbookResolver = currentWorkbookResolver ?? { bundleURL in
            await Task.detached {
                if let resolved = try? ONTGenotypeResultBundle.currentWorkbookURL(
                    for: bundleURL
                ) {
                    return resolved.standardizedFileURL
                }
                return bundleURL
                    .appendingPathComponent("artifacts", isDirectory: true)
                    .appendingPathComponent("workbooks", isDirectory: true)
                    .appendingPathComponent("current.xlsx")
                    .standardizedFileURL
            }.value
        }
        self.updateRunner = updateRunner ?? { request, intent in
            try await GenotypeCurrentWorkbookUpdateExecutionService().run(
                bundleURL: request.bundleURL,
                calls: request.effectiveCalls,
                includedLoci: request.includedLoci,
                annotationSidecarURL: request.annotationSidecarURL,
                annotationOnly: request.annotationOnly,
                inputFingerprint: request.fingerprint,
                syncIntent: intent,
                routeContext: request.routeContext
            )
        }
        self.workbookOpener = workbookOpener ?? { url in
            NSWorkspace.shared.open(url)
        }
        self.idleScheduler = idleScheduler ?? { delayNanoseconds, action in
            TaskIdleCancellation(delayNanoseconds: delayNanoseconds, action: action)
        }
    }

    func phase(for bundleURL: URL) -> Phase {
        states[Self.bundleKey(for: bundleURL)]?.phase ?? .current
    }

    @discardableResult
    func observe<Owner: AnyObject>(
        _ owner: Owner,
        handler: @escaping @MainActor (Owner, URL, Phase) -> Void
    ) -> Observation {
        let id = UUID()
        observers[id] = { [weak owner] bundleURL, phase in
            guard let owner else {
                return false
            }
            handler(owner, bundleURL, phase)
            return true
        }
        return Observation(coordinator: self, id: id)
    }

    /// Records a semantic edit and resets the bundle's idle-update countdown.
    func markDirty(_ request: Request) {
        let key = Self.bundleKey(for: request.bundleURL)
        var state = states[key] ?? BundleState()
        let oldPhase = state.phase
        if state.publishedFingerprint == request.fingerprint
            || (state.recordedFingerprintWasLoaded
                && state.recordedFingerprint == request.fingerprint) {
            state.latestRequest = request
            state.idleCancellation?.cancel()
            state.idleCancellation = nil
            states[key] = state
            setPhase(.current, for: key, bundleURL: request.bundleURL)
            return
        }

        registerLatest(request, in: &state)
        if state.operation != nil {
            state.phase = .dirtyWhileUpdating
        } else {
            state.phase = .dirty
        }
        states[key] = state
        notifyPhaseIfChanged(
            from: oldPhase,
            to: state.phase,
            bundleURL: request.bundleURL
        )
        scheduleIdle(for: key, bundleURL: request.bundleURL)
    }

    /// Synchronizes the requested fingerprint and joins any update already running
    /// for the same standardized bundle path.
    @discardableResult
    func synchronize(
        _ request: Request,
        intent: GenotypeCurrentWorkbookSyncIntent
    ) async throws -> URL {
        let key = Self.bundleKey(for: request.bundleURL)
        cancelIdle(for: key)

        if var state = states[key], let operation = state.operation {
            let oldPhase = state.phase
            let changedGeneration = registerLatest(request, in: &state)
            state.pendingIntent = preferredIntent(state.pendingIntent, intent)
            if intent == .updateAndView {
                state.openAfterSuccess = true
            }
            if changedGeneration {
                state.phase = .dirtyWhileUpdating
            }
            states[key] = state
            notifyPhaseIfChanged(
                from: oldPhase,
                to: state.phase,
                bundleURL: request.bundleURL
            )
            return try await operation.value
        }

        let recorded = await recordedFingerprint(for: key, bundleURL: request.bundleURL)
        var state = states[key] ?? BundleState()
        if let operation = state.operation {
            let oldPhase = state.phase
            let changedGeneration = registerLatest(request, in: &state)
            state.pendingIntent = preferredIntent(state.pendingIntent, intent)
            if intent == .updateAndView {
                state.openAfterSuccess = true
            }
            if changedGeneration {
                state.phase = .dirtyWhileUpdating
            }
            states[key] = state
            notifyPhaseIfChanged(
                from: oldPhase,
                to: state.phase,
                bundleURL: request.bundleURL
            )
            return try await operation.value
        }
        if state.publishedFingerprint == request.fingerprint
            || recorded == request.fingerprint {
            state.latestRequest = request
            state.recordedFingerprintWasLoaded = true
            state.recordedFingerprint = recorded
            states[key] = state
            setPhase(.current, for: key, bundleURL: request.bundleURL)
            let workbookURL = await currentWorkbookResolver(request.bundleURL)
                .standardizedFileURL
            if intent == .updateAndView {
                workbookOpener(workbookURL)
            }
            return workbookURL
        }

        let oldPhase = state.phase
        registerLatest(request, in: &state)
        state.pendingIntent = intent
        state.openAfterSuccess = intent == .updateAndView
        state.phase = .dirty
        states[key] = state
        notifyPhaseIfChanged(
            from: oldPhase,
            to: .dirty,
            bundleURL: request.bundleURL
        )

        let operation = Task { @MainActor [weak self] () throws -> URL in
            guard let self else {
                throw CancellationError()
            }
            return try await self.runUpdateLoop(for: key)
        }
        states[key]?.operation = operation
        return try await operation.value
    }

    private func recordedFingerprint(
        for key: String,
        bundleURL: URL
    ) async -> GenotypeCurrentWorkbookInputFingerprint? {
        var state = states[key] ?? BundleState()
        if state.recordedFingerprintWasLoaded {
            return state.recordedFingerprint
        }
        let task: Task<GenotypeCurrentWorkbookInputFingerprint?, Never>
        if let existing = state.fingerprintLoadTask {
            task = existing
        } else {
            let loader = recordedFingerprintLoader
            task = Task { @MainActor in
                await loader(bundleURL)
            }
            state.fingerprintLoadTask = task
            states[key] = state
        }
        let fingerprint = await task.value
        state = states[key] ?? BundleState()
        state.recordedFingerprintWasLoaded = true
        state.recordedFingerprint = fingerprint
        state.fingerprintLoadTask = nil
        states[key] = state
        return fingerprint
    }

    private func runUpdateLoop(for key: String) async throws -> URL {
        while true {
            guard var state = states[key],
                  let request = state.latestRequest else {
                throw CancellationError()
            }
            let generation = state.generation
            let intent = state.pendingIntent
            let oldPhase = state.phase
            state.phase = .updating
            state.idleCancellation?.cancel()
            state.idleCancellation = nil
            states[key] = state
            notifyPhaseIfChanged(
                from: oldPhase,
                to: .updating,
                bundleURL: request.bundleURL
            )

            do {
                let workbookURL = try await updateRunner(request, intent)
                    .standardizedFileURL
                guard var completedState = states[key] else {
                    return workbookURL
                }
                completedState.publishedFingerprint = request.fingerprint
                if completedState.generation != generation {
                    let phaseBeforeFollowUp = completedState.phase
                    completedState.phase = .updating
                    completedState.idleCancellation?.cancel()
                    completedState.idleCancellation = nil
                    states[key] = completedState
                    notifyPhaseIfChanged(
                        from: phaseBeforeFollowUp,
                        to: .updating,
                        bundleURL: request.bundleURL
                    )
                    continue
                }

                let shouldOpen = completedState.openAfterSuccess
                let phaseBeforeCompletion = completedState.phase
                completedState.openAfterSuccess = false
                completedState.operation = nil
                completedState.phase = .current
                states[key] = completedState
                notifyPhaseIfChanged(
                    from: phaseBeforeCompletion,
                    to: .current,
                    bundleURL: request.bundleURL
                )
                if shouldOpen {
                    workbookOpener(workbookURL)
                }
                return workbookURL
            } catch {
                guard var failedState = states[key] else {
                    throw error
                }
                let oldFailedPhase = failedState.phase
                failedState.operation = nil
                failedState.openAfterSuccess = false
                failedState.idleCancellation?.cancel()
                failedState.idleCancellation = nil
                failedState.phase = .failed(Self.userFacingMessage(for: error))
                states[key] = failedState
                notifyPhaseIfChanged(
                    from: oldFailedPhase,
                    to: failedState.phase,
                    bundleURL: request.bundleURL
                )
                throw error
            }
        }
    }

    private func scheduleIdle(for key: String, bundleURL: URL) {
        guard var state = states[key] else {
            return
        }
        state.idleCancellation?.cancel()
        state.idleGeneration &+= 1
        let idleGeneration = state.idleGeneration
        state.idleCancellation = idleScheduler(Self.idleDelayNanoseconds) {
            [weak self] in
            guard let self else {
                return
            }
            await self.fireIdle(
                for: key,
                generation: idleGeneration,
                bundleURL: bundleURL
            )
        }
        states[key] = state
    }

    private func fireIdle(
        for key: String,
        generation: UInt64,
        bundleURL: URL
    ) async {
        guard var state = states[key],
              state.idleGeneration == generation,
              let request = state.latestRequest else {
            return
        }
        state.idleCancellation = nil
        states[key] = state
        do {
            _ = try await synchronize(request, intent: .automaticIdle)
        } catch {
            // `synchronize` records the retryable failed phase. Idle failures must
            // not create a new timer or retry loop.
        }
    }

    private func cancelIdle(for key: String) {
        guard var state = states[key] else {
            return
        }
        state.idleCancellation?.cancel()
        state.idleCancellation = nil
        state.idleGeneration &+= 1
        states[key] = state
    }

    @discardableResult
    private func registerLatest(
        _ request: Request,
        in state: inout BundleState
    ) -> Bool {
        let changed = state.latestRequest?.fingerprint != request.fingerprint
        state.latestRequest = request
        if changed {
            state.generation &+= 1
        }
        return changed
    }

    private func setPhase(_ phase: Phase, for key: String, bundleURL: URL) {
        var state = states[key] ?? BundleState()
        let oldPhase = state.phase
        state.phase = phase
        states[key] = state
        notifyPhaseIfChanged(from: oldPhase, to: phase, bundleURL: bundleURL)
    }

    private func notifyPhaseIfChanged(
        from oldPhase: Phase,
        to newPhase: Phase,
        bundleURL: URL
    ) {
        guard oldPhase != newPhase else {
            return
        }
        let expired = observers.compactMap { id, observer in
            observer(bundleURL, newPhase) ? nil : id
        }
        for id in expired {
            observers.removeValue(forKey: id)
        }
    }

    private func preferredIntent(
        _ lhs: GenotypeCurrentWorkbookSyncIntent,
        _ rhs: GenotypeCurrentWorkbookSyncIntent
    ) -> GenotypeCurrentWorkbookSyncIntent {
        func rank(_ intent: GenotypeCurrentWorkbookSyncIntent) -> Int {
            switch intent {
            case .automaticIdle: return 0
            case .bundleSwitch: return 1
            case .updateAndView: return 2
            }
        }
        return rank(rhs) > rank(lhs) ? rhs : lhs
    }

    private static func userFacingMessage(for error: Error) -> String {
        if error is CancellationError {
            return "The current workbook update was cancelled."
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let description = (error as NSError).localizedDescription
        return description.isEmpty
            ? "The current workbook update failed."
            : description
    }

    private static func bundleKey(for bundleURL: URL) -> String {
        bundleURL.standardizedFileURL.path
    }
}

@MainActor
private final class TaskIdleCancellation:
    GenotypeCurrentWorkbookSyncCoordinator.IdleCancellation {
    private var task: Task<Void, Never>?

    init(
        delayNanoseconds: UInt64,
        action: @escaping @MainActor @Sendable () async -> Void
    ) {
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

import Foundation
import Observation

/// The one serial chain the edits of a `GenotypeAnnotationStore` publish on (2.11 S35, plan S2).
///
/// An edit starts once the edit before it has adopted its result, so it changes the sidecar that
/// edit published and its stale check compares the file with it (R4), and the store adopts results
/// in the order the person made the edits. An edit that another edit of the same step calls runs
/// inside that step. The chain also counts the edits the UI started and has not seen end, which
/// hold the edit controls.
@Observable
@MainActor
final class GenotypeAnnotationPublicationChain {
    /// Whether an edit the UI started is still publishing.
    private(set) var isHoldingEdits = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var waitingSteps: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var editsInFlight = 0
    @ObservationIgnored private var editWaiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `step` after every step queued before it has ended.
    func run<T>(_ step: () async throws -> T) async throws -> T {
        if GenotypeAnnotationPublicationStepScope.isInside {
            return try await step()
        }
        if isRunning {
            await withCheckedContinuation { waitingSteps.append($0) }
        } else {
            isRunning = true
        }
        defer {
            if waitingSteps.isEmpty {
                isRunning = false
            } else {
                waitingSteps.removeFirst().resume()
            }
        }
        return try await GenotypeAnnotationPublicationStepScope.$isInside.withValue(true) {
            try await step()
        }
    }

    /// Starts `edit` in this event's turn and counts it until it ends.
    func beginEdit(
        _ edit: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        editsInFlight += 1
        isHoldingEdits = true
        Self.startEdit { [self] in
            do {
                try await edit()
            } catch {
                onFailure(error)
            }
            endEdit()
        }
    }

    /// Runs `edit`, which a UI edge awaits, as an edit the UI started, so the edit controls hold and
    /// `waitForEveryEdit` waits until it ends.
    func performEdit<T>(_ edit: () async throws -> T) async rethrows -> T {
        editsInFlight += 1
        isHoldingEdits = true
        Self.editsInFlightEverywhere += 1
        defer {
            endEdit()
            Self.endEditEverywhere()
        }
        return try await edit()
    }

    /// Returns once every edit the UI started has ended.
    func waitForEdits() async {
        while editsInFlight > 0 {
            await withCheckedContinuation { editWaiters.append($0) }
        }
    }

    private func endEdit() {
        editsInFlight -= 1
        guard editsInFlight == 0 else { return }
        isHoldingEdits = false
        let waiters = editWaiters
        editWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Every chain

    /// The edits the UI started on any chain, including a retry the matrix queue schedules, that
    /// have not ended yet.
    private static var editsInFlightEverywhere = 0
    /// The matrix retries that wait for a workbook publication lock to clear. No edit is running
    /// while a retry waits, so they are counted apart from `editsInFlightEverywhere`. Quit waits for
    /// both, and a test that holds the lock waits for the edits that run (GENOTYPE-QUIT-LOSES-WAITING-EDIT).
    private static var waitingRetriesEverywhere = 0
    private static var everyEditWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether an edit the UI started on any chain has not ended yet. A retry that waits for the
    /// lock is not an edit that is running, so it does not count here.
    static var hasEditsInFlightEverywhere: Bool { editsInFlightEverywhere > 0 }

    /// Whether a matrix retry waits for a workbook publication lock to clear on any chain.
    static var hasWaitingRetryEverywhere: Bool { waitingRetriesEverywhere > 0 }

    /// Starts `work` in this event's turn and counts it among the edits `waitForEveryEdit` waits on.
    static func startEdit(_ work: @escaping @MainActor () async -> Void) {
        editsInFlightEverywhere += 1
        Task.immediate { @MainActor in
            await work()
            endEditEverywhere()
        }
    }

    /// Counts a retry that waits for a publication lock as an edit that is not done, so Quit waits
    /// for it. Each call pairs with one `releaseWaitingRetry()`, which `GenotypeWaitingRetryHold`
    /// makes certain of.
    static func holdForWaitingRetry() {
        waitingRetriesEverywhere += 1
    }

    /// Gives back the count `holdForWaitingRetry()` took.
    static func releaseWaitingRetry() {
        waitingRetriesEverywhere -= 1
        guard waitingRetriesEverywhere == 0 else { return }
        resumeEveryEditWaiters()
    }

    private static func endEditEverywhere() {
        editsInFlightEverywhere -= 1
        guard editsInFlightEverywhere == 0 else { return }
        resumeEveryEditWaiters()
    }

    /// Wakes every waiter. Each one asks again whether its own condition holds and waits on if not.
    private static func resumeEveryEditWaiters() {
        let waiters = everyEditWaiters
        everyEditWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Returns once every edit the UI started on any store has ended, whichever store it
    /// publishes to. A test awaits it before it asserts on what an edit saved or removes the
    /// bundle an edit writes to. With `includingWaitingRetries` it also waits until no retry waits
    /// for a publication lock, which is what Quit needs.
    static func waitForEveryEdit(includingWaitingRetries: Bool = false) async {
        while editsInFlightEverywhere > 0 || (includingWaitingRetries && waitingRetriesEverywhere > 0) {
            await withCheckedContinuation { everyEditWaiters.append($0) }
        }
    }
}

/// One matrix retry that waits for a publication lock, counted until it fires or is dropped.
///
/// The retry's closure holds it. The closure releases it once the retry's edit has counted itself
/// (or when the controller has gone), and the release happens once however it ends. A scheduler that
/// drops the closure without firing it releases the hold when the closure goes, so a count can never
/// stay up and make every later Quit wait its whole deadline.
@MainActor
final class GenotypeWaitingRetryHold {
    private var isHeld = true

    init() {
        GenotypeAnnotationPublicationChain.holdForWaitingRetry()
    }

    func release() {
        guard isHeld else { return }
        isHeld = false
        GenotypeAnnotationPublicationChain.releaseWaitingRetry()
    }

    isolated deinit {
        release()
    }
}

/// Marks the task that runs a step of the chain, so an edit called inside a step runs in it.
enum GenotypeAnnotationPublicationStepScope {
    @TaskLocal static var isInside = false
}

// MARK: Quit

/// Lets the first of two events end a wait, once. The wait for the edits to end cannot be
/// cancelled, so a timer races it, and whichever ends first opens the gate.
@MainActor
private final class AnnotationSaveWaitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

extension GenotypeResultViewController {
    /// Whether an annotation edit is still saving or waiting for the workbook publication lock to
    /// clear. Quit waits for it (2.11 S35, GENOTYPE-QUIT-LOSES-WAITING-EDIT).
    public static var isSavingAnnotationEdits: Bool {
        GenotypeAnnotationPublicationChain.hasEditsInFlightEverywhere
            || GenotypeAnnotationPublicationChain.hasWaitingRetryEverywhere
    }

    /// Returns once every annotation edit has saved, or after `timeout`, so a stalled volume
    /// cannot block Quit. An edit renames `annotations.json` and then its record, and a process
    /// that ends between the two renames leaves a new file beside the record of the edit before.
    /// An edit that waits for the workbook publication lock counts as not saved, unless
    /// `includingWaitingRetries` is false, which a test that holds the lock uses to wait for the
    /// edits that are running.
    public static func waitForAnnotationEditsToSave(
        timeout: Duration = .seconds(15),
        includingWaitingRetries: Bool = true
    ) async {
        let isPending = GenotypeAnnotationPublicationChain.hasEditsInFlightEverywhere
            || (includingWaitingRetries && GenotypeAnnotationPublicationChain.hasWaitingRetryEverywhere)
        guard isPending else { return }
        let gate = AnnotationSaveWaitGate()
        Task { @MainActor in
            await GenotypeAnnotationPublicationChain.waitForEveryEdit(includingWaitingRetries: includingWaitingRetries)
            gate.open()
        }
        let deadline = Task { @MainActor in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            gate.open()
        }
        await gate.wait()
        deadline.cancel()
    }
}

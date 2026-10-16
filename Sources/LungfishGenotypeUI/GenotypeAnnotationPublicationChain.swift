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

    /// Whether no step runs, so a publication on the main actor reads what the store adopted.
    var isIdle: Bool { !isRunning }

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
    private static var everyEditWaiters: [CheckedContinuation<Void, Never>] = []

    /// Starts `work` in this event's turn and counts it among the edits `waitForEveryEdit` waits on.
    static func startEdit(_ work: @escaping @MainActor () async -> Void) {
        editsInFlightEverywhere += 1
        Task.immediate { @MainActor in
            await work()
            editsInFlightEverywhere -= 1
            guard editsInFlightEverywhere == 0 else { return }
            let waiters = everyEditWaiters
            everyEditWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    /// Returns once every edit the UI started on any store has ended, whichever store it
    /// publishes to. A test awaits it before it asserts on what an edit saved or removes the
    /// bundle an edit writes to.
    static func waitForEveryEdit() async {
        while editsInFlightEverywhere > 0 {
            await withCheckedContinuation { everyEditWaiters.append($0) }
        }
    }
}

/// Marks the task that runs a step of the chain, so an edit called inside a step runs in it.
enum GenotypeAnnotationPublicationStepScope {
    @TaskLocal static var isInside = false
}

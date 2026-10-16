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
        Task.immediate { @MainActor in
            do {
                try await edit()
            } catch {
                onFailure(error)
            }
            self.endEdit()
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
}

/// Marks the task that runs a step of the chain, so an edit called inside a step runs in it.
enum GenotypeAnnotationPublicationStepScope {
    @TaskLocal static var isInside = false
}

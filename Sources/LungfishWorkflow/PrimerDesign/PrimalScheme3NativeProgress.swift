import Foundation
import os

/// Turns PrimalScheme3 log lines into progress messages.
///
/// A combined panel is one native process that can run for hours. Without
/// this the operation shows one unchanging message for the whole design, which
/// is indistinguishable from a hang. The parser only reads the engine's own
/// log wording, so it reports progress and never affects the scientific result.
struct PrimalScheme3NativeProgress: Sendable {
    let inputCount: Int
    private(set) var digestedInputs = 0
    private(set) var addedAmplicons = 0

    init(inputCount: Int) {
        self.inputCount = max(inputCount, 1)
    }

    /// Consumes one native log line. Returns the fraction of this native run
    /// (0 to 1) and a message, or nil when the line reports nothing new.
    /// Candidate discovery runs serially per alignment and fills the first
    /// half. Panel construction has no known amplicon total, so it holds the
    /// fraction and counts amplicons in the message instead.
    mutating func consume(_ line: String) -> (fraction: Double, message: String)? {
        if line.contains("Digesting ") {
            digestedInputs = min(digestedInputs + 1, inputCount)
            return (0.5 * Double(digestedInputs - 1) / Double(inputCount),
                    "Finding primer candidates in alignment \(digestedInputs) of \(inputCount)")
        }
        if line.contains("Added amplicon (") {
            addedAmplicons += 1
            return (0.5, "Building the panel: \(addedAmplicons) amplicon\(addedAmplicons == 1 ? "" : "s") added")
        }
        if line.contains("Writing outputs") {
            return (0.9, "Writing PrimalScheme reports")
        }
        return nil
    }
}

extension PrimalScheme3NativeProgress {
    /// Runs native launch `index` of `runCount` inside its share of the
    /// operation's progress, from 0.2 to 0.9 overall. Native log lines become
    /// progress messages, and the caller's own observer still receives every line.
    static func observing<Result>(run index: Int, of runCount: Int, inputCount: Int,
                                  progress: (@Sendable (Double, String) -> Void)?,
                                  _ body: () async throws -> Result) async throws -> Result {
        let start = 0.2 + 0.7 * Double(index) / Double(runCount)
        let span = 0.7 / Double(runCount)
        let label = runCount == 1 ? "" : " (\(index + 1)/\(runCount))"
        progress?(start, "Running PrimalScheme" + label)
        let outer = NativeProcessObservation.onEvent
        let state = OSAllocatedUnfairLock(initialState: PrimalScheme3NativeProgress(inputCount: inputCount))
        let observer: @Sendable (NativeProcessEvent) -> Void = { event in
            outer?(event)
            guard let progress, case .output(_, let line) = event,
                  let update = state.withLock({ $0.consume(line) }) else { return }
            progress(start + span * update.fraction, update.message + label)
        }
        return try await NativeProcessObservation.$onEvent.withValue(observer) { try await body() }
    }
}

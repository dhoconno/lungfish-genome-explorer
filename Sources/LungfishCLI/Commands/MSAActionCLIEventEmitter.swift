import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Thin adapter over the shared `CLIEventEmitter` (LungfishWorkflow) matching
/// the call-site shape every MSA action subcommand already uses
/// (`emitStart(actionID:message:)`, `emitProgress`, `emitWarning`,
/// `emitComplete`, `emitFailed`). Replaces the private per-command
/// `msaActionStart`/`msaActionProgress`/… JSON schema with
/// the shared `CLIEvent` wire format. `actionID`/`warningCount` are accepted
/// for source compatibility but not part of the wire schema: no GUI caller
/// ever read them (`CLIMSAActionRunner`'s callers all discard its result).
final class MSAActionCLIEventEmitter: @unchecked Sendable {
    private let emitter: CLIEventEmitter

    init(
        enabled: Bool,
        operationID: String = UUID().uuidString,
        emit: @escaping (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }) {
        self.emitter = CLIEventEmitter(enabled: enabled, emit: emit)
    }

    func emitStart(actionID: String, message: String) {
        emitter.emitStart(message)
    }

    func emitProgress(actionID: String, progress: Double, message: String) {
        emitter.emitProgress(progress, message: message)
    }

    func emitWarning(actionID: String, message: String, warningCount: Int? = nil) {
        emitter.emitLog(.warning, message)
    }

    func emitComplete(actionID: String, output: String, warningCount: Int) {
        emitter.emitComplete(output: output)
    }

    func emitFailed(actionID: String, message: String) {
        emitter.emitFailed(message)
    }
}

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
/// the shared `CLIEvent` wire format. `actionID` is accepted for source
/// compatibility only. The complete event adds a `warningCount` key beside the
/// shared fields, which `CLIEventLineDecoder` ignores, so a script reading the
/// JSON sees how many warnings the run printed.
final class MSAActionCLIEventEmitter: @unchecked Sendable {
    private let emitter: CLIEventEmitter
    private let enabled: Bool
    private let emitLine: (String) -> Void

    init(
        enabled: Bool,
        operationID: String = UUID().uuidString,
        emit: @escaping (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }) {
        self.emitter = CLIEventEmitter(enabled: enabled, emit: emit)
        self.enabled = enabled
        self.emitLine = emit
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
        guard enabled else { return }
        guard let line = Self.completeLine(output: output, warningCount: warningCount) else {
            emitter.emitComplete(output: output)
            return
        }
        emitLine(line)
    }

    /// The shared complete event with `warningCount` added, keys sorted like
    /// every other `CLIEvent` line.
    static func completeLine(output: String, warningCount: Int) -> String? {
        guard let data = try? JSONEncoder().encode(CLIEvent.complete(outputs: [output], message: nil)),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["warningCount"] = warningCount
        guard let line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: line, encoding: .utf8)
    }

    func emitFailed(actionID: String, message: String) {
        emitter.emitFailed(message)
    }
}

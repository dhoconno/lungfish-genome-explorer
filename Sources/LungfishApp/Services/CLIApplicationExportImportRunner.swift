import Foundation
import LungfishCore
import LungfishWorkflow
import LungfishKit
import os.log

struct CLIApplicationExportImportResult: Sendable, Equatable {
    let collectionURL: URL
    let warningCount: Int
}

/// Runs `lungfish-cli import geneious` or `import application-export` and reports the collection it made.
///
/// The stream is read through `CLISubprocessTransport`, so a version 2 CLI and an older CLI, whose
/// private `applicationExport*` events `CLIEventLegacyNames` reads, give the same operation log, the
/// same label and the same imported collection (decision V13). The collection comes from `outputs`
/// only. The typed artifact that a version 2 CLI adds describes it and never stands in for it.
actor CLIApplicationExportImportRunner {
    enum RunError: Error, LocalizedError {
        case cliNotFound
        case launchFailed(String)
        case nonZeroExit(status: Int32, stderr: String)
        case missingCompletion
        case failedEvent(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The `lungfish-cli` binary could not be found in the app bundle or build products."
            case .launchFailed(let message):
                return "Failed to launch lungfish-cli: \(message)"
            case .nonZeroExit(let status, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "lungfish-cli exited with status \(status)"
                    : "lungfish-cli exited with status \(status): \(trimmed)"
            case .missingCompletion:
                return "lungfish-cli finished without reporting an imported collection."
            case .failedEvent(let message):
                return message
            }
        }
    }

    private let transport: CLISubprocessTransport

    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    static func buildApplicationExportArguments(
        sourceURL: URL,
        projectURL: URL,
        kind: ApplicationExportKind
    ) -> [String] {
        [
            "import", "application-export", kind.cliArgument, sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ]
    }

    static func buildGeneiousArguments(sourceURL: URL, projectURL: URL) -> [String] {
        [
            "import", "geneious", sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ]
    }

    func run(arguments: [String], operationID: UUID) async throws -> CLIApplicationExportImportResult {
        let opID = operationID
        let bridge = OperationCenterCLIBridge.onEvent(operationID: opID)
        let warnings = OSAllocatedUnfairLock(initialState: 0)

        await performCLIOperationCenterUpdate {
            _ = OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Launching lungfish-cli...")
        }

        do {
            let result = try await transport.run(
                arguments: arguments,
                isCancelled: { false },
                onEvent: { event in
                    switch event {
                    case let .start(message):
                        // The start line is a log line only, so the row shows "Launching lungfish-cli..."
                        // until the first progress line, as it did before the transport.
                        bridge(.log(level: .info, message: message))
                    case .log(.warning, _):
                        warnings.withLock { $0 += 1 }
                        bridge(event)
                    case let .failed(message, _):
                        // The failure stays in the operation log at error level, as it did before.
                        bridge(.log(level: .error, message: message))
                    case .progress, .log, .output, .complete:
                        bridge(event)
                    }
                }
            )
            guard let collectionPath = result.outputs.first,
                  !collectionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunError.missingCompletion
            }
            return CLIApplicationExportImportResult(
                collectionURL: URL(fileURLWithPath: collectionPath, isDirectory: true),
                warningCount: warnings.withLock { $0 }
            )
        } catch let error as CLISubprocessTransport.RunError {
            switch error {
            case .cliNotFound:
                await failOperation(opID, detail: RunError.cliNotFound.localizedDescription)
                throw RunError.cliNotFound
            case .launchFailed(let reason):
                await failOperation(opID, detail: reason)
                throw RunError.launchFailed(reason)
            case .nonZeroExit(let status, let stderr):
                throw RunError.nonZeroExit(status: status, stderr: stderr)
            case .missingCompletion:
                throw RunError.missingCompletion
            case .failedEvent:
                throw RunError.failedEvent(error.errorDescription ?? "Application export import failed")
            }
        }
    }

    nonisolated func cancel() {
        transport.cancel()
    }

    @MainActor
    private func failOperation(_ id: UUID, detail: String?) {
        let message = detail ?? "Application export import failed"
        _ = OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }
}

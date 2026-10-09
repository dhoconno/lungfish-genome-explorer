import Foundation
import LungfishCore
import LungfishWorkflow
import LungfishKit
import os.log

private let applicationExportImportLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "CLIApplicationExportImportRunner"
)

enum CLIApplicationExportImportEvent: Sendable, Equatable {
    case start(kind: String, source: String)
    case progress(progress: Double, message: String)
    case warning(message: String)
    case complete(collection: String, warningCount: Int)
    case failed(error: String)
}

struct CLIApplicationExportImportResult: Sendable, Equatable {
    let collectionURL: URL
    let warningCount: Int
}

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

    private let cliURLOverride: URL?
    private let cancellation = CLIRunCancellation()

    init(cliURLOverride: URL? = nil) {
        self.cliURLOverride = cliURLOverride
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

    static func parseEvent(from line: String) throws -> CLIApplicationExportImportEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        switch event {
        case "applicationExportImportStart":
            return .start(
                kind: dict["kind"] as? String ?? "",
                source: dict["source"] as? String ?? ""
            )
        case "applicationExportProgress":
            return .progress(
                progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
                message: dict["message"] as? String ?? "Importing application export..."
            )
        case "applicationExportWarning":
            return .warning(message: dict["message"] as? String ?? "Import warning")
        case "applicationExportImportComplete":
            return .complete(
                collection: dict["collection"] as? String ?? "",
                warningCount: dict["warningCount"] as? Int ?? 0
            )
        case "applicationExportImportFailed":
            return .failed(error: dict["error"] as? String ?? "Application export import failed")
        default:
            return nil
        }
    }

    func run(arguments: [String], operationID: UUID) async throws -> CLIApplicationExportImportResult {
        guard let binaryURL = cliURLOverride ?? CLIImportRunner.cliBinaryPath() else {
            await failOperation(operationID, detail: RunError.cliNotFound.localizedDescription)
            throw RunError.cliNotFound
        }

        applicationExportImportLogger.info("Launching application export import CLI")

        final class StreamState: @unchecked Sendable {
            var collectionPath: String?
            var warningCount = 0
            var failedMessage: String?
        }

        let state = OSAllocatedUnfairLock(initialState: StreamState())
        let opID = operationID

        @Sendable func handleLine(_ line: String) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            do {
                guard let event = try Self.parseEvent(from: line) else { return }
                switch event {
                case let .start(kind, _):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "Started \(kind) import via lungfish-cli"
                            )
                        }
                    }
                case let .progress(progress, message):
                    let clamped = max(0, min(1, progress))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.update(id: opID, progress: clamped, detail: message)
                        }
                    }
                case let .warning(message):
                    state.withLock { $0.warningCount += 1 }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .warning, message: message)
                        }
                    }
                case let .complete(collection, warningCount):
                    state.withLock {
                        $0.collectionPath = collection
                        $0.warningCount = max($0.warningCount, warningCount)
                    }
                case let .failed(error):
                    state.withLock { $0.failedMessage = error }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .error, message: error)
                        }
                    }
                }
            } catch {
                applicationExportImportLogger.warning("Failed to parse application export CLI event")
            }
        }

        await performCLIOperationCenterUpdate {
            _ = OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Launching lungfish-cli...")
        }

        let outcome = await CLIProcessLauncher.run(
            CLIProcessLauncher.spec(executableURL: binaryURL, arguments: arguments),
            cancellation: cancellation,
            onStdoutLine: handleLine
        )

        let exit: CLIProcessExit
        switch outcome {
        case .exited(let finished):
            exit = finished
        case .cancelled:
            throw CancellationError()
        case .launchFailed(let reason):
            await failOperation(opID, detail: reason)
            throw RunError.launchFailed(reason)
        }

        let snapshot = state.withLock { current in
            (
                collectionPath: current.collectionPath,
                warningCount: current.warningCount,
                failedMessage: current.failedMessage
            )
        }

        if let failedMessage = snapshot.failedMessage {
            throw RunError.failedEvent(failedMessage)
        }

        if !exit.succeeded {
            if let incomplete = exit.incompleteOutput {
                applicationExportImportLogger.error("\(incomplete, privacy: .public)")
            }
            throw RunError.nonZeroExit(status: exit.status, stderr: exit.failureDetail)
        }

        guard let collectionPath = snapshot.collectionPath,
              !collectionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunError.missingCompletion
        }

        return CLIApplicationExportImportResult(
            collectionURL: URL(fileURLWithPath: collectionPath, isDirectory: true),
            warningCount: snapshot.warningCount
        )
    }

    nonisolated func cancel() {
        cancellation.cancel()
    }

    @MainActor
    private func failOperation(_ id: UUID, detail: String?) {
        let message = detail ?? "Application export import failed"
        _ = OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }
}

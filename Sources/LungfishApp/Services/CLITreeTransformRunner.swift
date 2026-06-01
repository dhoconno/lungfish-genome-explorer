import Foundation
import LungfishCore
import LungfishKit
import os.log

private let treeTransformRunnerLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "CLITreeTransformRunner"
)

enum CLITreeTransformEvent: Sendable, Equatable {
    case start(progress: Double, message: String)
    case progress(progress: Double, message: String)
    case complete(output: String)
    case failed(error: String)
}

struct CLITreeTransformResult: Sendable, Equatable {
    let bundleURL: URL
}

actor CLITreeTransformRunner {
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
                return "lungfish-cli finished without reporting a tree bundle."
            case .failedEvent(let message):
                return message
            }
        }
    }

    private let cliURLOverride: URL?
    private var process: Process?

    init(cliURLOverride: URL? = nil) {
        self.cliURLOverride = cliURLOverride
    }

    static func parseEvent(from line: String) throws -> CLITreeTransformEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        switch event {
        case "treeTransformStart":
            return .start(
                progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
                message: dict["message"] as? String ?? "Starting tree transform..."
            )
        case "treeTransformProgress":
            return .progress(
                progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
                message: dict["message"] as? String ?? "Running tree transform..."
            )
        case "treeTransformComplete":
            return .complete(output: dict["output"] as? String ?? "")
        case "treeTransformFailed":
            return .failed(error: dict["error"] as? String ?? dict["message"] as? String ?? "Tree transform failed")
        default:
            return nil
        }
    }
}

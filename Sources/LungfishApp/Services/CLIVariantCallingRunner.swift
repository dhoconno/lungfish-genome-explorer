import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let variantCallingRunnerLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "CLIVariantCallingRunner"
)

enum CLIVariantCallingEvent: Sendable, Equatable {
    case runStart(message: String)
    case preflightStart(message: String)
    case preflightComplete(message: String)
    case stageStart(message: String)
    case stageProgress(progress: Double, message: String)
    case stageComplete(message: String)
    case importStart(message: String)
    case importComplete(message: String, importedVariantCount: Int?)
    case attachStart(message: String)
    case attachComplete(
        trackID: String?,
        trackName: String?,
        databasePath: String?,
        vcfPath: String?,
        tbiPath: String?
    )
    case runComplete(
        trackID: String,
        trackName: String,
        databasePath: String,
        vcfPath: String,
        tbiPath: String
    )
    case runFailed(message: String)
}

enum CLIVariantCallingRunnerError: Error, LocalizedError, Equatable {
    case cliBinaryNotFound
    case processLaunchFailed(String)
    case processExited(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .cliBinaryNotFound:
            return "lungfish-cli binary not found"
        case .processLaunchFailed(let detail):
            return "Failed to launch lungfish-cli: \(detail)"
        case .processExited(let status, let stderr):
            guard !stderr.isEmpty else {
                return "lungfish-cli exited with status \(status)"
            }
            return "lungfish-cli exited with status \(status): \(stderr)"
        }
    }
}

actor CLIVariantCallingRunner {
    private var process: Process?

    static func cliBinaryPath() -> URL? {
        CLIImportRunner.cliBinaryPath()
    }

    static func buildCLIArguments(request: BundleVariantCallingRequest) -> [String] {
        var arguments = [
            "variants",
            "call",
            "--bundle", request.bundleURL.path,
            "--alignment-track", request.alignmentTrackID,
            "--caller", request.caller.rawValue,
            "--name", request.outputTrackName,
            "--format", "json",
            "--threads", String(max(1, request.threads)),
            "--no-progress",
        ]

        if let minimumAlleleFrequency = request.minimumAlleleFrequency {
            arguments += ["--min-af", String(minimumAlleleFrequency)]
        }

        if let minimumDepth = request.minimumDepth {
            arguments += ["--min-depth", String(minimumDepth)]
        }

        if request.ivarPrimerTrimConfirmed {
            arguments.append("--ivar-primer-trimmed")
        }

        let medakaModel = request.medakaModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !medakaModel.isEmpty {
            arguments += ["--medaka-model", medakaModel]
        }

        if !request.advancedArguments.isEmpty {
            arguments += ["--advanced-options", AdvancedCommandLineOptions.join(request.advancedArguments)]
        }

        return arguments
    }

    static func parseEvent(from line: String) throws -> CLIVariantCallingEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        let message = dict["message"] as? String ?? ""
        let importedVariantCount = dict["importedVariantCount"] as? Int
        let variantTrackID = dict["variantTrackID"] as? String
        let variantTrackName = dict["variantTrackName"] as? String
        let databasePath = dict["databasePath"] as? String
        let vcfPath = dict["vcfPath"] as? String
        let tbiPath = dict["tbiPath"] as? String

        switch event {
        case "runStart":
            return .runStart(message: message)
        case "preflightStart":
            return .preflightStart(message: message)
        case "preflightComplete":
            return .preflightComplete(message: message)
        case "stageStart":
            return .stageStart(message: message)
        case "stageProgress":
            return .stageProgress(
                progress: dict["progress"] as? Double ?? 0,
                message: message
            )
        case "stageComplete":
            return .stageComplete(message: message)
        case "importStart":
            return .importStart(message: message)
        case "importComplete":
            return .importComplete(message: message, importedVariantCount: importedVariantCount)
        case "attachStart":
            return .attachStart(message: message)
        case "attachComplete":
            return .attachComplete(
                trackID: variantTrackID,
                trackName: variantTrackName,
                databasePath: databasePath,
                vcfPath: vcfPath,
                tbiPath: tbiPath
            )
        case "runComplete":
            guard let variantTrackID,
                  let variantTrackName,
                  let databasePath,
                  let vcfPath,
                  let tbiPath else {
                return nil
            }
            return .runComplete(
                trackID: variantTrackID,
                trackName: variantTrackName,
                databasePath: databasePath,
                vcfPath: vcfPath,
                tbiPath: tbiPath
            )
        case "runFailed":
            return .runFailed(message: message)
        default:
            variantCallingRunnerLogger.debug("Unknown CLI variant event type: \(event)")
            return nil
        }
    }

    func run(
        arguments: [String],
        onEvent: @escaping @Sendable (CLIVariantCallingEvent) -> Void
    ) async throws {
        guard let binaryURL = Self.cliBinaryPath() else {
            throw CLIVariantCallingRunnerError.cliBinaryNotFound
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process

        do {
            try process.run()
        } catch {
            self.process = nil
            throw CLIVariantCallingRunnerError.processLaunchFailed(error.localizedDescription)
        }

        final class StreamState: @unchecked Sendable {
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
        }
        let state = StreamState()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                state.stderrBuffer.append(chunk)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    stdoutHandle.readabilityHandler = nil
                    let alreadyResumed = resumed.withLock { value -> Bool in
                        if value { return true }
                        value = true
                        return false
                    }
                    if !alreadyResumed {
                        continuation.resume()
                    }
                    return
                }

                state.stdoutBuffer.append(chunk)

                while let newlineRange = state.stdoutBuffer.range(of: Data("\n".utf8)) {
                    let lineData = state.stdoutBuffer.subdata(in: state.stdoutBuffer.startIndex..<newlineRange.lowerBound)
                    state.stdoutBuffer.removeSubrange(state.stdoutBuffer.startIndex..<newlineRange.upperBound)

                    guard let line = String(data: lineData, encoding: .utf8),
                          !line.isEmpty else {
                        continue
                    }

                    do {
                        if let event = try Self.parseEvent(from: line) {
                            onEvent(event)
                        }
                    } catch {
                        variantCallingRunnerLogger.warning(
                            "Failed to parse variant-calling CLI event: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }

        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil
        self.process = nil

        if Task.isCancelled {
            throw CancellationError()
        }

        let status = process.terminationStatus
        guard status == 0 else {
            let stderr = String(data: state.stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIVariantCallingRunnerError.processExited(status: status, stderr: stderr)
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

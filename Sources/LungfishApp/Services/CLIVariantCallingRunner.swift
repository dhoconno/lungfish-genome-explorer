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

private final class CLIVariantCallingProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminateTree() {
        ProcessTreeTerminator.terminate(rootProcess: process)
    }
}

private final class CLIVariantCallingStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    func appendStdout(_ chunk: Data) -> [String] {
        lock.lock()
        stdoutBuffer.append(chunk)
        let lines = drainStdoutLines()
        lock.unlock()
        return lines
    }

    func finishStdout() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !stdoutBuffer.isEmpty else { return [] }
        let line = decode(stdoutBuffer)
        stdoutBuffer.removeAll(keepingCapacity: false)
        return line.isEmpty ? [] : [line]
    }

    func appendStderr(_ chunk: Data) {
        lock.lock()
        stderrBuffer.append(chunk)
        lock.unlock()
    }

    func stderrText() -> String {
        lock.lock()
        let data = stderrBuffer
        lock.unlock()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func drainStdoutLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = stdoutBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = stdoutBuffer[..<newlineIndex]
            let line = decode(Data(lineData))
            if !line.isEmpty {
                lines.append(line)
            }

            var removalEnd = stdoutBuffer.index(after: newlineIndex)
            if stdoutBuffer[newlineIndex] == 0x0D,
               removalEnd < stdoutBuffer.endIndex,
               stdoutBuffer[removalEnd] == 0x0A {
                removalEnd = stdoutBuffer.index(after: removalEnd)
            }
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<removalEnd)
        }
        return lines
    }

    private func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

private final class CLIVariantCallingVoidCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func complete() {
        let continuationToResume: CheckedContinuation<Void, Never>?
        lock.lock()
        if completed {
            continuationToResume = nil
        } else {
            completed = true
            continuationToResume = continuation
            continuation = nil
        }
        lock.unlock()
        continuationToResume?.resume()
    }
}

private final class CLIVariantCallingExitCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var exitStatus: Int32?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func complete(exitStatus: Int32) {
        let continuationToResume: CheckedContinuation<Int32, Never>?
        lock.lock()
        if self.exitStatus != nil {
            continuationToResume = nil
        } else {
            self.exitStatus = exitStatus
            continuationToResume = continuation
            continuation = nil
        }
        lock.unlock()
        continuationToResume?.resume(returning: exitStatus)
    }
}

actor CLIVariantCallingRunner {
    private var process: Process?
    private var cancellationRequested = false
    private let cliBinaryPathProvider: @Sendable () -> URL?

    init(cliBinaryPathProvider: @escaping @Sendable () -> URL? = CLIVariantCallingRunner.cliBinaryPath) {
        self.cliBinaryPathProvider = cliBinaryPathProvider
    }

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

        if request.caller == .ivar {
            arguments += ["--ivar-consensus-af", String(request.ivarConsensusAF)]
            arguments += ["--ivar-merge-af-threshold", String(request.ivarMergeAFThreshold)]
            arguments += ["--ivar-bad-quality-threshold", String(request.ivarBadQualityThreshold)]
            if !request.ivarIgnoreStrandBias {
                arguments.append("--ivar-no-ignore-strand-bias")
            }
        }

        let medakaModel = request.medakaModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !medakaModel.isEmpty {
            arguments += ["--medaka-model", medakaModel]
        }

        if !request.advancedArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(request.advancedArguments)]
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
        guard let binaryURL = cliBinaryPathProvider() else {
            throw CLIVariantCallingRunnerError.cliBinaryNotFound
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        let processBox = CLIVariantCallingProcessBox(process)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        cancellationRequested = false

        let state = CLIVariantCallingStreamState()
        let stdoutComplete = CLIVariantCallingVoidCompletion()
        let stderrComplete = CLIVariantCallingVoidCompletion()
        let exitComplete = CLIVariantCallingExitCompletion()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let emitStdoutLines: @Sendable ([String]) -> Void = { lines in
            for line in lines {
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

        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                stdoutHandle.readabilityHandler = nil
                emitStdoutLines(state.finishStdout())
                stdoutComplete.complete()
                return
            }
            emitStdoutLines(state.appendStdout(chunk))
        }

        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                stderrHandle.readabilityHandler = nil
                stderrComplete.complete()
                return
            }
            state.appendStderr(chunk)
        }

        process.terminationHandler = { terminatedProcess in
            exitComplete.complete(exitStatus: terminatedProcess.terminationStatus)
        }

        defer {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            process.terminationHandler = nil
            self.process = nil
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            throw CLIVariantCallingRunnerError.processLaunchFailed(error.localizedDescription)
        }

        let status = await withTaskCancellationHandler {
            async let exitStatus = exitComplete.wait()
            async let stdoutEOF: Void = stdoutComplete.wait()
            async let stderrEOF: Void = stderrComplete.wait()
            let status = await exitStatus
            _ = await (stdoutEOF, stderrEOF)
            return status
        } onCancel: {
            processBox.terminateTree()
        }

        if Task.isCancelled || cancellationRequested {
            throw CancellationError()
        }

        guard status == 0 else {
            let stderr = state.stderrText()
            throw CLIVariantCallingRunnerError.processExited(status: status, stderr: stderr)
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        cancellationRequested = true
        ProcessTreeTerminator.terminate(rootProcess: process)
    }
}

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let msaAlignmentRunnerLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "CLIMSAAlignmentRunner"
)

enum CLIMSAAlignmentEvent: Sendable, Equatable {
    case start(tool: String, sourceCount: Int)
    case progress(progress: Double, message: String)
    case warning(message: String)
    case complete(bundle: String, rowCount: Int, alignedLength: Int, warningCount: Int)
    case failed(error: String)
}

struct CLIMSAAlignmentResult: Sendable, Equatable {
    let bundleURL: URL
    let rowCount: Int
    let alignedLength: Int
    let warningCount: Int
}

actor CLIMSAAlignmentRunner {
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
                return "lungfish-cli finished without reporting an alignment bundle."
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

    static func buildArguments(
        inputURLs: [URL],
        projectURL: URL,
        outputURL: URL?,
        name: String?,
        strategy: String,
        outputOrder: String,
        threads: Int?,
        sequenceType: String = "auto",
        adjustDirection: String = "off",
        symbols: String = "strict",
        allowNondeterministicThreads: Bool = false,
        allowFASTQAssemblyInputs: Bool = false,
        extraArguments: [String]
    ) -> [String] {
        var args = ["align", "mafft"] + inputURLs.map(\.path)
        args += ["--project", projectURL.path]
        if let outputURL {
            args += ["--output", outputURL.path]
        }
        if let name {
            args += ["--name", name]
        }
        args += ["--strategy", strategy]
        args += ["--output-order", outputOrder]
        if sequenceType != "auto" {
            args += ["--sequence-type", sequenceType]
        }
        if adjustDirection != "off" {
            args += ["--adjust-direction", adjustDirection]
        }
        if symbols != "strict" {
            args += ["--symbols", symbols]
        }
        if allowNondeterministicThreads {
            args += ["--allow-nondeterministic-threads"]
        }
        if allowFASTQAssemblyInputs {
            args += ["--allow-fastq-assembly-inputs"]
        }
        if let threads {
            args += ["--threads", "\(threads)"]
        }
        if !extraArguments.isEmpty {
            args += ["--extra-mafft-options", AdvancedCommandLineOptions.join(extraArguments)]
        }
        args += ["--format", "json"]
        return args
    }

    static func parseEvent(from line: String) throws -> CLIMSAAlignmentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        switch event {
        case "msaAlignmentStart":
            return .start(
                tool: dict["tool"] as? String ?? "mafft",
                sourceCount: (dict["sourceCount"] as? NSNumber)?.intValue ?? 0
            )
        case "msaAlignmentProgress":
            return .progress(
                progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
                message: dict["message"] as? String ?? "Running MAFFT..."
            )
        case "msaAlignmentWarning":
            return .warning(message: dict["message"] as? String ?? "MAFFT warning")
        case "msaAlignmentComplete":
            return .complete(
                bundle: dict["bundle"] as? String ?? "",
                rowCount: (dict["rowCount"] as? NSNumber)?.intValue ?? 0,
                alignedLength: (dict["alignedLength"] as? NSNumber)?.intValue ?? 0,
                warningCount: (dict["warningCount"] as? NSNumber)?.intValue ?? 0
            )
        case "msaAlignmentFailed":
            return .failed(error: dict["message"] as? String ?? "MAFFT alignment failed")
        default:
            return nil
        }
    }

    func run(arguments: [String], operationID: UUID) async throws -> CLIMSAAlignmentResult {
        guard let binaryURL = cliURLOverride ?? CLIImportRunner.cliBinaryPath() else {
            await failOperation(operationID, detail: RunError.cliNotFound.localizedDescription)
            throw RunError.cliNotFound
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        process = proc

        final class StreamState: @unchecked Sendable {
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var bundlePath: String?
            var rowCount = 0
            var alignedLength = 0
            var warningCount = 0
            var failedMessage: String?
        }

        let state = OSAllocatedUnfairLock(initialState: StreamState())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let opID = operationID

        @Sendable func handleLine(_ data: Data) {
            guard let line = String(data: data, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            do {
                guard let event = try Self.parseEvent(from: line) else { return }
                switch event {
                case let .start(tool, sourceCount):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "Started \(tool) alignment for \(sourceCount) source file(s) via lungfish-cli"
                            )
                        }
                    }
                case let .progress(progress, message):
                    let clamped = max(0, min(1, progress))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(id: opID, progress: clamped, detail: message)
                        }
                    }
                case let .warning(message):
                    state.withLock { $0.warningCount += 1 }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .warning, message: message)
                        }
                    }
                case let .complete(bundle, rowCount, alignedLength, warningCount):
                    state.withLock {
                        $0.bundlePath = bundle
                        $0.rowCount = rowCount
                        $0.alignedLength = alignedLength
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
                msaAlignmentRunnerLogger.warning("Failed to parse MAFFT CLI event")
            }
        }

        @Sendable func consumeStdout(_ data: Data) {
            guard !data.isEmpty else { return }
            let lines = state.withLock { current -> [Data] in
                current.stdoutBuffer.append(data)
                var parsed: [Data] = []
                while let newlineIndex = current.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(current.stdoutBuffer.prefix(upTo: newlineIndex))
                    current.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleLine(line)
            }
        }

        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            consumeStdout(chunk)
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            state.withLock { $0.stderrBuffer.append(chunk) }
        }

        await MainActor.run {
            OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Launching lungfish-cli...")
        }

        do {
            try proc.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            process = nil
            await failOperation(opID, detail: error.localizedDescription)
            throw RunError.launchFailed(error.localizedDescription)
        }

        proc.waitUntilExit()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        consumeStdout(stdoutHandle.readDataToEndOfFile())
        if let trailing = state.withLock({ current -> Data? in
            guard !current.stdoutBuffer.isEmpty else { return nil }
            defer { current.stdoutBuffer.removeAll(keepingCapacity: false) }
            return current.stdoutBuffer
        }) {
            handleLine(trailing)
        }
        process = nil

        let snapshot = state.withLock { current in
            (
                stderr: String(data: current.stderrBuffer, encoding: .utf8) ?? "",
                bundlePath: current.bundlePath,
                rowCount: current.rowCount,
                alignedLength: current.alignedLength,
                warningCount: current.warningCount,
                failedMessage: current.failedMessage
            )
        }

        if let failedMessage = snapshot.failedMessage {
            throw RunError.failedEvent(failedMessage)
        }
        if proc.terminationStatus != 0 {
            throw RunError.nonZeroExit(status: proc.terminationStatus, stderr: snapshot.stderr)
        }
        guard let bundlePath = snapshot.bundlePath,
              !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunError.missingCompletion
        }

        return CLIMSAAlignmentResult(
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            rowCount: snapshot.rowCount,
            alignedLength: snapshot.alignedLength,
            warningCount: snapshot.warningCount
        )
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    @MainActor
    private func failOperation(_ id: UUID, detail: String?) {
        let message = detail ?? "MAFFT alignment failed"
        OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }
}

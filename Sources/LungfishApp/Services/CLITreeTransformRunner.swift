import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
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
    private let cancellationHandle = NativeProcessCancellationHandle()

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

    func run(arguments: [String], operationID: UUID) async throws -> CLITreeTransformResult {
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
        cancellationHandle.store(proc)

        final class StreamState: @unchecked Sendable {
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var outputPath: String?
            var failedMessage: String?
        }

        let state = OSAllocatedUnfairLock(initialState: StreamState())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutHandlerGroup = DispatchGroup()
        let stderrHandlerGroup = DispatchGroup()
        let opID = operationID

        @Sendable func handleLine(_ data: Data) {
            guard let line = String(data: data, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            do {
                guard let event = try Self.parseEvent(from: line) else { return }
                switch event {
                case let .start(progress, message):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .info, message: message)
                            _ = OperationCenter.shared.update(id: opID, progress: max(0, min(1, progress)), detail: message)
                        }
                    }
                case let .progress(progress, message):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.update(
                                id: opID,
                                progress: max(0, min(1, progress)),
                                detail: message
                            )
                        }
                    }
                case let .complete(output):
                    state.withLock { $0.outputPath = output }
                case let .failed(error):
                    state.withLock { $0.failedMessage = error }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .error, message: error)
                        }
                    }
                }
            } catch {
                treeTransformRunnerLogger.warning("Failed to parse tree transform CLI event")
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

        @Sendable func consumeStderr(_ data: Data) {
            guard !data.isEmpty else { return }
            state.withLock { $0.stderrBuffer.append(data) }
        }

        func drainStreamHandlers() {
            stdoutHandlerGroup.wait()
            stderrHandlerGroup.wait()
        }

        stdoutHandle.readabilityHandler = { handle in
            stdoutHandlerGroup.enter()
            defer { stdoutHandlerGroup.leave() }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            consumeStdout(chunk)
        }
        stderrHandle.readabilityHandler = { handle in
            stderrHandlerGroup.enter()
            defer { stderrHandlerGroup.leave() }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            consumeStderr(chunk)
        }

        await performCLIOperationCenterUpdate {
            _ = OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Launching lungfish-cli...")
        }

        do {
            try proc.run()
            cancellationHandle.terminateIfRequested()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            drainStreamHandlers()
            cancellationHandle.clear(proc)
            await failOperation(opID, detail: error.localizedDescription)
            throw RunError.launchFailed(error.localizedDescription)
        }

        proc.waitUntilExit()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        drainStreamHandlers()
        consumeStdout(stdoutHandle.readDataToEndOfFile())
        consumeStderr(stderrHandle.readDataToEndOfFile())
        drainStreamHandlers()
        if let trailing = state.withLock({ current -> Data? in
            guard !current.stdoutBuffer.isEmpty else { return nil }
            defer { current.stdoutBuffer.removeAll(keepingCapacity: false) }
            return current.stdoutBuffer
        }) {
            handleLine(trailing)
        }
        cancellationHandle.clear(proc)

        let snapshot = state.withLock { current in
            (
                stderr: String(data: current.stderrBuffer, encoding: .utf8) ?? "",
                outputPath: current.outputPath,
                failedMessage: current.failedMessage
            )
        }

        if await isOperationCancelled(opID) {
            throw CancellationError()
        }
        if let failedMessage = snapshot.failedMessage {
            await failOperation(opID, detail: failedMessage)
            throw RunError.failedEvent(failedMessage)
        }
        if proc.terminationStatus != 0 {
            let error = RunError.nonZeroExit(status: proc.terminationStatus, stderr: snapshot.stderr)
            await failOperation(opID, detail: error.localizedDescription)
            throw error
        }
        guard let outputPath = snapshot.outputPath,
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await failOperation(opID, detail: RunError.missingCompletion.localizedDescription)
            throw RunError.missingCompletion
        }

        let bundleURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        await performCLIOperationCenterUpdate {
            _ = OperationCenter.shared.complete(
                id: opID,
                detail: "Tree transform complete",
                bundleURLs: [bundleURL]
            )
        }

        return CLITreeTransformResult(bundleURL: bundleURL)
    }

    nonisolated func cancel() {
        cancellationHandle.terminateProcessTree(gracePeriod: 0)
    }

    @MainActor
    private func isOperationCancelled(_ id: UUID) -> Bool {
        OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled
    }

    @MainActor
    private func failOperation(_ id: UUID, detail: String?) {
        let message = detail ?? "Tree transform failed"
        guard OperationCenter.shared.items.first(where: { $0.id == id })?.state != .cancelled else {
            return
        }
        _ = OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }
}

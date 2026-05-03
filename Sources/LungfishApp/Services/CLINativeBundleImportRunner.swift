import Foundation
import LungfishCore
import os.log

private let nativeBundleImportLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "CLINativeBundleImportRunner"
)

enum CLINativeBundleImportEvent: Sendable, Equatable {
    case start(kind: String, source: String)
    case progress(progress: Double, message: String)
    case warning(message: String)
    case complete(bundle: String, warningCount: Int)
    case failed(error: String)
}

struct CLINativeBundleImportResult: Sendable, Equatable {
    let bundleURL: URL
    let warningCount: Int
}

actor CLINativeBundleImportRunner {
    enum BundleKind: String, Sendable {
        case msa
        case tree

        var operationTitle: String {
            switch self {
            case .msa: return "MSA Import"
            case .tree: return "Tree Import"
            }
        }
    }

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
                return "lungfish-cli finished without reporting an imported bundle."
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

    static func buildArguments(sourceURL: URL, projectURL: URL, kind: BundleKind) -> [String] {
        [
            "import", kind.rawValue, sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ]
    }

    static func parseEvent(from line: String) throws -> CLINativeBundleImportEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        switch event {
        case "nativeBundleImportStart":
            return .start(
                kind: dict["kind"] as? String ?? "",
                source: dict["source"] as? String ?? ""
            )
        case "nativeBundleImportProgress":
            return .progress(
                progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
                message: dict["message"] as? String ?? "Importing bundle..."
            )
        case "nativeBundleImportWarning":
            return .warning(message: dict["message"] as? String ?? "Import warning")
        case "nativeBundleImportComplete":
            return .complete(
                bundle: dict["bundle"] as? String ?? "",
                warningCount: dict["warningCount"] as? Int ?? 0
            )
        case "nativeBundleImportFailed":
            return .failed(error: dict["error"] as? String ?? "Native bundle import failed")
        default:
            return nil
        }
    }

    func run(arguments: [String], operationID: UUID) async throws -> CLINativeBundleImportResult {
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
                case let .start(kind, _):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(id: opID, level: .info, message: "Started \(kind) import via lungfish-cli")
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
                case let .complete(bundle, warningCount):
                    state.withLock {
                        $0.bundlePath = bundle
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
                nativeBundleImportLogger.warning("Failed to parse native bundle import CLI event")
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

        return CLINativeBundleImportResult(
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            warningCount: snapshot.warningCount
        )
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    @MainActor
    private func failOperation(_ id: UUID, detail: String?) {
        let message = detail ?? "Native bundle import failed"
        OperationCenter.shared.fail(id: id, detail: message, errorMessage: message)
    }
}

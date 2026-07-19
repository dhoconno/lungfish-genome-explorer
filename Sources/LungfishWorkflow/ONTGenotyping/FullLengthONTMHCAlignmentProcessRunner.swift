import Foundation

struct FullLengthONTMHCAlignmentProcessRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let inputs: [URL]
    let outputs: [URL]
    let stdoutURL: URL?
    let workingDirectoryURL: URL
    let logsDirectoryURL: URL
    let toolVersion: String?
    let temporaryRootURL: URL
}

struct FullLengthONTMHCAlignmentProcessRunner: @unchecked Sendable {
    static let maximumDiagnosticBytes = 65_536

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func execute(
        _ request: FullLengthONTMHCAlignmentProcessRequest
    ) async throws -> FullLengthONTMHCCohortAlignmentCommandRecord {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: request.logsDirectoryURL, withIntermediateDirectories: true)

        let identifier = UUID().uuidString
        let baseName = "\(request.executableURL.lastPathComponent)-\(identifier)"
        let stdoutLogURL = request.stdoutURL
            ?? request.logsDirectoryURL.appendingPathComponent("\(baseName).stdout.log")
        let stderrLogURL = request.logsDirectoryURL.appendingPathComponent("\(baseName).stderr.log")
        let inputDescriptors = try request.inputs.map {
            try Self.descriptor(
                for: $0,
                role: .commandInput,
                temporaryRootURL: request.temporaryRootURL
            )
        }
        let stdoutHandle = try Self.truncatingWriteHandle(at: stdoutLogURL, fileManager: fileManager)
        let stderrHandle = try Self.truncatingWriteHandle(at: stderrLogURL, fileManager: fileManager)
        let startedAt = Date()
        let state = CancellableProcessState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = request.executableURL
                process.arguments = request.arguments
                process.currentDirectoryURL = request.workingDirectoryURL
                process.environment = ProcessInfo.processInfo.environment
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                state.register(process)

                let finish: @Sendable (Int32, String?) -> Void = { status, launchError in
                    state.finishOnce {
                        try? stdoutHandle.close()
                        try? stderrHandle.close()
                        let completedAt = Date()
                        do {
                            let stdoutDescriptor = try FullLengthONTMHCArtifactDescriptor(
                                url: stdoutLogURL,
                                role: .commandStdoutLog,
                                phase: .diagnostic
                            )
                            let stderrDescriptor = try FullLengthONTMHCArtifactDescriptor(
                                url: stderrLogURL,
                                role: .commandStderrLog,
                                phase: .diagnostic
                            )
                            let outputDescriptors: [FullLengthONTMHCArtifactDescriptor] = try request.outputs.compactMap { url in
                                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                                return try Self.descriptor(
                                    for: url,
                                    role: .commandOutput,
                                    temporaryRootURL: request.temporaryRootURL
                                )
                            }
                            let stdoutText: String
                            let stderrText: String
                            if let launchError {
                                stdoutText = ""
                                stderrText = launchError
                            } else {
                                stdoutText = try Self.boundedTail(of: stdoutLogURL)
                                stderrText = try Self.boundedTail(of: stderrLogURL)
                            }
                            continuation.resume(returning: FullLengthONTMHCCohortAlignmentCommandRecord(
                                executableURL: request.executableURL,
                                toolVersion: request.toolVersion,
                                argv: [request.executableURL.path] + request.arguments,
                                arguments: request.arguments,
                                inputs: request.inputs,
                                outputs: request.outputs,
                                inputDescriptors: inputDescriptors,
                                outputDescriptors: outputDescriptors,
                                stdoutLogDescriptor: stdoutDescriptor,
                                stderrLogDescriptor: stderrDescriptor,
                                exitStatus: status,
                                stdout: stdoutText,
                                stderr: stderrText,
                                wasCancelled: state.isCancelled,
                                startedAt: startedAt,
                                completedAt: completedAt,
                                wallTime: completedAt.timeIntervalSince(startedAt)
                            ))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                process.terminationHandler = { terminatedProcess in
                    finish(terminatedProcess.terminationStatus, nil)
                }

                do {
                    if state.isCancelled { throw CancellationError() }
                    try process.run()
                    state.terminateIfCancelled()
                } catch {
                    finish(-1, error.localizedDescription)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func truncatingWriteHandle(
        at url: URL,
        fileManager: FileManager
    ) throws -> FileHandle {
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            throw FullLengthONTMHCAlignmentSafetyError("Could not create process log \(url.path).")
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func boundedTail(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maximumDiagnosticBytes) ? size - UInt64(maximumDiagnosticBytes) : 0
        try handle.seek(toOffset: start)
        let data = handle.readData(ofLength: maximumDiagnosticBytes)
        return String(decoding: data, as: UTF8.self)
    }

    private static func descriptor(
        for url: URL,
        role: FullLengthONTMHCArtifactRole,
        temporaryRootURL: URL
    ) throws -> FullLengthONTMHCArtifactDescriptor {
        let phase: FullLengthONTMHCArtifactPhase
        if url.path.contains("/.alignments-replacement-") {
            phase = .staging
        } else if contains(temporaryRootURL, url) {
            phase = .temporary
        } else {
            phase = .input
        }
        return try FullLengthONTMHCArtifactDescriptor(url: url, role: role, phase: phase)
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

private final class CancellableProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func register(_ process: Process) {
        lock.withLock { self.process = process }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return self.process
        }
        if process?.isRunning == true { process?.terminate() }
    }

    func terminateIfCancelled() {
        let process = lock.withLock { cancelled ? self.process : nil }
        if process?.isRunning == true { process?.terminate() }
    }

    func finishOnce(_ body: () -> Void) {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            process = nil
            return true
        }
        if shouldFinish { body() }
    }
}

import Darwin
import Foundation
import LungfishCore

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
    let pathIdentityValidator: (@Sendable () throws -> Void)?
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
        try request.pathIdentityValidator?()

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
        try Self.createEmptyLog(at: stdoutLogURL, fileManager: fileManager)
        try Self.createEmptyLog(at: stderrLogURL, fileManager: fileManager)
        let runClock = ProvenanceRunClock()
        let spec = ToolProcessSpec(
            executableURL: request.executableURL,
            arguments: request.arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            workingDirectory: request.workingDirectoryURL,
            stdout: .file(stdoutLogURL),
            stderr: .file(stderrLogURL),
            label: request.executableURL.lastPathComponent
        )

        let run: Result<ToolProcessResult, ToolProcessError>
        do {
            run = .success(try await ToolProcess.run(spec))
        } catch {
            run = .failure(error)
        }
        let status: Int32
        let launchError: String?
        var cancelled = false
        switch run {
        case .success(let result):
            // A descendant that outlived the tool may still have been writing
            // its output or logs, so the run cannot vouch for them.
            if let reason = result.incompleteOutputReason {
                throw FullLengthONTMHCAlignmentSafetyError(reason)
            }
            status = result.status
            launchError = nil
        case .failure(.cancelled(let results)):
            // A cancelled run still returns its record, so the caller can keep
            // the logs of what ran. Before launch there is no exit status.
            cancelled = true
            status = results.first?.status ?? -1
            launchError = results.isEmpty ? CancellationError().localizedDescription : nil
        case .failure(let error):
            status = -1
            launchError = error.localizedDescription
        }

        let completedAt = runClock.now
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
        var outputDescriptors: [FullLengthONTMHCArtifactDescriptor] = []
        var descriptorCaptureErrors: [FullLengthONTMHCArtifactDescriptorCaptureError] = []
        do {
            try request.pathIdentityValidator?()
            for url in request.outputs where Self.entryExistsNoFollow(url) {
                do {
                    outputDescriptors.append(try Self.descriptor(
                        for: url,
                        role: .commandOutput,
                        temporaryRootURL: request.temporaryRootURL
                    ))
                } catch {
                    descriptorCaptureErrors.append(.init(
                        path: url.standardizedFileURL.path,
                        role: .commandOutput,
                        message: (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    ))
                }
            }
        } catch {
            descriptorCaptureErrors.append(.init(
                path: request.temporaryRootURL.standardizedFileURL.path,
                role: .commandOutput,
                message: (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            ))
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
        return FullLengthONTMHCCohortAlignmentCommandRecord(
            executableURL: request.executableURL,
            toolVersion: request.toolVersion,
            argv: [request.executableURL.path] + request.arguments,
            arguments: request.arguments,
            inputs: request.inputs,
            outputs: request.outputs,
            inputDescriptors: inputDescriptors,
            outputDescriptors: outputDescriptors,
            descriptorCaptureErrors: descriptorCaptureErrors,
            stdoutLogDescriptor: stdoutDescriptor,
            stderrLogDescriptor: stderrDescriptor,
            exitStatus: status,
            stdout: stdoutText,
            stderr: stderrText,
            wasCancelled: cancelled || Task.isCancelled,
            startedAt: runClock.startedAt,
            completedAt: completedAt,
            wallTime: completedAt.timeIntervalSince(runClock.startedAt)
        )
    }

    /// Creates an empty log before launch, so a run that never launches
    /// still leaves both logs for its record.
    private static func createEmptyLog(at url: URL, fileManager: FileManager) throws {
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            throw FullLengthONTMHCAlignmentSafetyError("Could not create process log \(url.path).")
        }
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

    private static func entryExistsNoFollow(_ url: URL) -> Bool {
        var info = stat()
        return Darwin.lstat(url.path, &info) == 0
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

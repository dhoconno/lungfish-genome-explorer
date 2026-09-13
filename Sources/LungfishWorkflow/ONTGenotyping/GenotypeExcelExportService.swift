import Darwin
import Foundation
import LungfishCore
import LungfishIO

/// One-way Excel publication. Scientific inputs are supplied in memory; the
/// renderer never reloads a result bundle or searches for a source workbook.
public struct GenotypeExcelExportService: Sendable {
    public struct InputWitness: Codable, Sendable {
        public let path: String
        public let data: Data
        public let verifyCurrentFile: Bool
        public init(path: String, data: Data, verifyCurrentFile: Bool = true) {
            self.path = path; self.data = data; self.verifyCurrentFile = verifyCurrentFile
        }
    }

    public struct ProvenanceRequest: Codable, Sendable {
        public let workflowName: String
        public let toolVersion: String
        public let argv: [String]
        public let options: [String: String]
        public let defaults: [String: String]
        public let runtimeContext: [String: String]
        public let inputs: [InputWitness]
        public init(workflowName: String = "genotype.export.excel", toolVersion: String, argv: [String],
                    options: [String: String] = [:], defaults: [String: String] = [:],
                    runtimeContext: [String: String] = [:], inputs: [InputWitness] = []) {
            self.workflowName = workflowName; self.toolVersion = toolVersion; self.argv = argv
            self.options = options; self.defaults = defaults; self.runtimeContext = runtimeContext; self.inputs = inputs
        }
    }

    public struct ExportResult: Sendable {
        public let outputURL: URL
        public let receiptURL: URL
        public let snapshotURL: URL
        public let replayScriptURL: URL
        /// Exact durable files created by this export, excluding published report/receipt.
        public let artifactDirectoryURL: URL
        public let artifactURLs: [URL]
        public let artifactDirectoryIdentity: FileSystemObjectIdentity
        public let artifactIdentities: [String: FileSystemObjectIdentity]
    }

    public enum ExportError: Error, LocalizedError {
        case invalidInput(String)
        case rendererFailed(Int32, String)
        public var errorDescription: String? {
            switch self {
            case .invalidInput(let message): return "Excel export rejected: " + message
            case .rendererFailed(let status, let message): return "Excel renderer exited \(status): \(message)"
            }
        }
    }

    private let pythonExecutableURL: URL
    private let replayExecutableURL: URL?
    private let beforeOutputPublication: (@Sendable () throws -> Void)?
    public init(pythonExecutableURL: URL, replayExecutableURL: URL? = nil) {
        self.pythonExecutableURL = pythonExecutableURL.standardizedFileURL
        self.replayExecutableURL = replayExecutableURL?.standardizedFileURL
        beforeOutputPublication = nil
    }

    /// Test seam at the real publication ownership boundary. Production
    /// callers use the public initializer above.
    init(
        pythonExecutableURL: URL,
        replayExecutableURL: URL? = nil,
        beforeOutputPublication: @escaping @Sendable () throws -> Void
    ) {
        self.pythonExecutableURL = pythonExecutableURL.standardizedFileURL
        self.replayExecutableURL = replayExecutableURL?.standardizedFileURL
        self.beforeOutputPublication = beforeOutputPublication
    }

    public func export(snapshot: GenotypeWorkbookPresentation.Snapshot, outputURL: URL,
                       provenance: ProvenanceRequest, replacingExisting: Bool = true) async throws -> ExportResult {
        try Task.checkCancellation()
        try GenotypeExcelSnapshotBuilder.validate(snapshot)
        let fm = FileManager.default
        let output = outputURL.standardizedFileURL
        let receipt = output.appendingPathExtension("provenance.json")
        guard !provenance.toolVersion.isEmpty, !provenance.argv.isEmpty else {
            throw ExportError.invalidInput("tool version and invocation are required")
        }
        for input in provenance.inputs {
            guard URL(fileURLWithPath: input.path).standardizedFileURL != output,
                  URL(fileURLWithPath: input.path).standardizedFileURL != receipt else {
                throw ExportError.invalidInput("output would overwrite a scientific input")
            }
        }
        try verify(provenance.inputs)
        for (name, bytes) in snapshot.capturedScientificInputs ?? [:] {
            guard snapshot.sourceRevision[name] == GenotypeExcelSnapshotBuilder.digest(bytes) else {
                throw ExportError.invalidInput("captured scientific witness does not match \(name)")
            }
        }
        let parent = output.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let durable = parent.appendingPathComponent(output.lastPathComponent + ".export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: durable, withIntermediateDirectories: false)
        let directory = try NoFollowFileSystem.openDirectoryHierarchy(durable)
        var directoryInfo = stat()
        guard Darwin.fstat(directory, &directoryInfo) == 0 else {
            Darwin.close(directory)
            throw OwnedWorkDirectoryMarkerError.unsafePath(durable.path)
        }
        let directoryIdentity = FileSystemObjectIdentity(from: directoryInfo)
        var createdFiles: [DurableAtomicFileStore.OpenPublishedFile] = []
        var artifactIdentities: [String: FileSystemObjectIdentity] = [:]
        var retainArtifacts = false
        defer {
            if !retainArtifacts {
                let entry = GenotypingCleanupPlanEntry(path: durable.path,
                    intendedAction: .removeRetiredPublicationDirectory, identity: directoryIdentity)
                _ = GenotypingIdentityBoundCleanup.remove(entry) { detached in
                    let members = try fm.contentsOfDirectory(at: detached, includingPropertiesForKeys: nil)
                    for member in members {
                        if let expected = artifactIdentities[member.lastPathComponent] {
                            guard try FileSystemObjectIdentity.noFollow(member) == expected else {
                                throw OwnedWorkDirectoryMarkerError.identityMismatch(member.path)
                            }
                        } else if !["rendered.xlsx", "receipt.json"].contains(member.lastPathComponent) {
                            throw ExportError.invalidInput("unowned export-directory member retained")
                        }
                    }
                    try fm.removeItem(at: detached)
                }
            }
            createdFiles.forEach { $0.close() }
            Darwin.close(directory)
        }
        func writeArtifact(_ data: Data, to url: URL) throws -> DurableAtomicFileStore.OpenPublishedFile {
            let created = try DurableAtomicFileStore().createWitnessed(data,
                named: url.lastPathComponent, inOpenDirectory: directory, displayedAt: durable)
            createdFiles.append(created)
            artifactIdentities[url.lastPathComponent] = created.identity
            return created
        }
        let snapshotURL = durable.appendingPathComponent("snapshot.json")
        let scriptURL = durable.appendingPathComponent("renderer.py")
        let replayScriptURL = durable.appendingPathComponent("replay.sh")
        let requestURL = durable.appendingPathComponent("request.json")
        let stagedOutput = durable.appendingPathComponent("rendered.xlsx")
        let stagedReceipt = durable.appendingPathComponent("receipt.json")
        let stdoutURL = durable.appendingPathComponent("stdout.json")
        let stderrURL = durable.appendingPathComponent("stderr.txt")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let snapshotBytes = try encoder.encode(snapshot)
        _ = try writeArtifact(snapshotBytes, to: snapshotURL)
        _ = try writeArtifact(Data(Self.rendererScript.utf8), to: scriptURL)
        let requestBytes = try encoder.encode(provenance)
        _ = try writeArtifact(requestBytes, to: requestURL)
        let executable = replayExecutableURL?.path ?? Self.resolvedCLIExecutable()
        let replayPrefix = [executable, "genotype", "export-xlsx", "--snapshot", snapshotURL.path,
            "--provenance-request", requestURL.path, "--python", pythonExecutableURL.path]
        let replayArgv = replayPrefix + ["--output", output.path] + (replacingExisting ? ["--force"] : [])
        let replayScript = "#!/bin/sh\nreplay_default_output=" + Self.shellQuote(output.path)
            + "\nexec " + replayPrefix.map(Self.shellQuote).joined(separator: " ")
            + " --output \"${1:-$replay_default_output}\"" + (replacingExisting ? " --force" : "") + "\n"
        _ = try writeArtifact(Data(replayScript.utf8), to: replayScriptURL)
        var artifactURLs = [snapshotURL, scriptURL, replayScriptURL, requestURL, stdoutURL, stderrURL]
        var witnessedInputs: [[String: Any]] = []
        for (index, input) in provenance.inputs.enumerated() {
            let capturedURL = durable.appendingPathComponent("input-\(index).bin")
            _ = try writeArtifact(input.data, to: capturedURL)
            artifactURLs.append(capturedURL)
            witnessedInputs.append(["path": input.path, "capturedPath": capturedURL.path,
                "sha256": GenotypeExcelSnapshotBuilder.digest(input.data), "sizeBytes": input.data.count,
                "verifyCurrentFile": input.verifyCurrentFile])
        }
        let stdoutFile = try writeArtifact(Data(), to: stdoutURL)
        let stderrFile = try writeArtifact(Data(), to: stderrURL)
        let started = Date()
        let executedArgv = [pythonExecutableURL.path, scriptURL.path, snapshotURL.path, stagedOutput.path]
        let execution = try runPython(argv: Array(executedArgv.dropFirst()), stdoutFile: stdoutFile, stderrFile: stderrFile, directory: directory)
        try Task.checkCancellation()
        try verify(provenance.inputs)
        let bytes = try Data(contentsOf: stagedOutput)
        guard !bytes.isEmpty else { throw ExportError.invalidInput("renderer produced no workbook") }
        let runtime = try JSONSerialization.jsonObject(with: readCreatedFile(stdoutFile, directory: directory))
        let record: [String: Any] = [
            "schemaVersion": 1, "workflowName": provenance.workflowName, "toolName": "lungfish genotype Excel export",
            "toolVersion": provenance.toolVersion, "argv": provenance.argv, "executedArgv": executedArgv,
            "durableReplayArgv": replayArgv, "replayCommand": replayArgv.map(Self.shellQuote).joined(separator: " "),
            "options": provenance.options, "resolvedDefaults": provenance.defaults,
            "runtimeContext": provenance.runtimeContext, "runtime": runtime,
            "generatedAt": snapshot.generatedAt, "startedAt": ISO8601DateFormatter().string(from: started),
            "completedAt": ISO8601DateFormatter().string(from: Date()), "wallTimeSeconds": Date().timeIntervalSince(started),
            "exitStatus": execution.status, "stderr": execution.stderr,
            "inputs": witnessedInputs, "scientificInputWitnesses": snapshot.sourceRevision,
            "snapshot": descriptor(snapshotURL, bytes: snapshotBytes),
            "script": descriptor(scriptURL, bytes: Data(Self.rendererScript.utf8)),
            "request": descriptor(requestURL, bytes: requestBytes),
            "replayScript": descriptor(replayScriptURL, bytes: Data(replayScript.utf8)),
            "output": descriptor(output, bytes: bytes), "receiptPath": receipt.path, "replacingExisting": replacingExisting,
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: stagedReceipt, options: .atomic)
        let transaction = try ScientificFilePublicationTransaction(protectedURLs: [output, receipt], fileDestinations: [output, receipt])
        do {
            try Task.checkCancellation()
            try verify(provenance.inputs)
            try beforeOutputPublication?()
            try transaction.publish(stagedURL: stagedOutput, to: output, replacingExisting: replacingExisting)
            try transaction.publish(stagedURL: stagedReceipt, to: receipt)
            transaction.commit()
        } catch {
            do { try transaction.rollback(after: error) }
            catch let recovery as ScientificPublicationRecoveryRequired { retainArtifacts = true; throw recovery }
        }
        retainArtifacts = true
        return .init(outputURL: output, receiptURL: receipt, snapshotURL: snapshotURL, replayScriptURL: replayScriptURL,
            artifactDirectoryURL: durable, artifactURLs: artifactURLs,
            artifactDirectoryIdentity: directoryIdentity, artifactIdentities: artifactIdentities)
    }

    private func verify(_ inputs: [InputWitness]) throws {
        for input in inputs where input.verifyCurrentFile {
            guard (try? Data(contentsOf: URL(fileURLWithPath: input.path))) == input.data else {
                throw ExportError.invalidInput("scientific input changed: \(input.path)")
            }
        }
    }

    private func descriptor(_ url: URL, bytes: Data) -> [String: Any] {
        ["path": url.path, "sha256": GenotypeExcelSnapshotBuilder.digest(bytes), "sizeBytes": bytes.count]
    }

    private func runPython(
        argv: [String], stdoutFile: DurableAtomicFileStore.OpenPublishedFile,
        stderrFile: DurableAtomicFileStore.OpenPublishedFile, directory: Int32
    ) throws -> (status: Int32, stderr: String) {
        // Keep the writer-created handles through Process; reopening by path
        // would adopt a replacement even before the caller receives ownership.
        let stdout = FileHandle(fileDescriptor: stdoutFile.fileDescriptor, closeOnDealloc: false)
        let stderr = FileHandle(fileDescriptor: stderrFile.fileDescriptor, closeOnDealloc: false)
        let process = Process(); process.executableURL = pythonExecutableURL; process.arguments = argv
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        while process.isRunning {
            if Task.isCancelled { process.terminate(); process.waitUntilExit(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard Darwin.fsync(stdoutFile.fileDescriptor) == 0, Darwin.fsync(stderrFile.fileDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let message = String(data: try readCreatedFile(stderrFile, directory: directory), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw ExportError.rendererFailed(process.terminationStatus, message) }
        return (process.terminationStatus, message)
    }

    private func readCreatedFile(_ file: DurableAtomicFileStore.OpenPublishedFile, directory: Int32) throws -> Data {
        let descriptor = file.url.lastPathComponent.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw OwnedWorkDirectoryMarkerError.unsafePath(file.url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              FileSystemObjectIdentity(from: info) == file.identity else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(file.url.path)
        }
        return try handle.readToEnd() ?? Data()
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func resolvedCLIExecutable() -> String {
        if let path = Bundle.main.executableURL, path.lastPathComponent == CLICommandIdentity.executableName { return path.path }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(CLICommandIdentity.executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.standardizedFileURL.path }
        }
        return CLICommandIdentity.executableName
    }

    private static var rendererScript: String {
        GenotypeWorkbookPresentation.snapshotPythonScript + #"""

if __name__ == '__main__':
    import json, sys, platform, openpyxl
    with open(sys.argv[1], encoding='utf-8') as handle:
        snapshot = json.load(handle)
    summary = render_genotype_snapshot(snapshot, sys.argv[2])
    print(json.dumps(dict(pythonExecutable=sys.executable, pythonVersion=platform.python_version(),
        openpyxlVersion=openpyxl.__version__, platform=platform.platform(), renderer=summary)))
"""#
    }
}

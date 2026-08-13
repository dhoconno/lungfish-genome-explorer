// MetagenomicsDatabaseInstaller.swift - Recipe-aware Kraken2 database preparation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct MetagenomicsDatabaseToolResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitStatus: Int32
    public let argv: [String]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let toolVersion: String
    public let startedAt: Date
    public let completedAt: Date

    public init(stdout: String, stderr: String, exitStatus: Int32, argv: [String], runtimeIdentity: ProvenanceRuntimeIdentity, toolVersion: String, startedAt: Date, completedAt: Date) {
        self.stdout = stdout; self.stderr = stderr; self.exitStatus = exitStatus; self.argv = argv
        self.runtimeIdentity = runtimeIdentity; self.toolVersion = toolVersion
        self.startedAt = startedAt; self.completedAt = completedAt
    }
}

public protocol MetagenomicsDatabaseToolRunning: Sendable {
    func run(name: String, arguments: [String], environment: String, workingDirectory: URL, timeout: TimeInterval) async throws -> MetagenomicsDatabaseToolResult
    func executableDirectory(environment: String) async throws -> URL
    func executableDirectory(environment: String, executable: String) async throws -> URL
    func toolVersion(name: String, environment: String, workingDirectory: URL) async throws -> String
}

public extension MetagenomicsDatabaseToolRunning {
    /// Compatibility default for test doubles. Production runners must verify the
    /// named executable, rather than merely finding an environment's `bin` folder.
    func executableDirectory(environment: String, executable: String) async throws -> URL {
        try await executableDirectory(environment: environment)
    }
    func toolVersion(name: String, environment: String, workingDirectory: URL) async throws -> String { "unresolved" }
}

public protocol MetagenomicsDatabaseArchiveTransferring: Sendable {
    func download(from source: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
    func extractionToolVersion() async throws -> String
    func extract(archive: URL, destination: URL) async throws -> MetagenomicsDatabaseToolResult
}

public extension MetagenomicsDatabaseArchiveTransferring {
    func extractionToolVersion() async throws -> String { "unavailable" }
}

public protocol MetagenomicsDatabaseFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItemIfPresent(at url: URL) throws
}

public struct FoundationMetagenomicsDatabaseFileSystem: MetagenomicsDatabaseFileSystem, Sendable {
    public init() {}
    public func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func createDirectory(at url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    public func moveItem(at source: URL, to destination: URL) throws { try FileManager.default.moveItem(at: source, to: destination) }
    public func removeItemIfPresent(at url: URL) throws { if fileExists(at: url) { try FileManager.default.removeItem(at: url) } }
}

/// Records the actual managed micromamba invocation instead of a shell-dependent
/// approximation. `CondaManager` owns cancellation of the launched process tree.
public struct ManagedMetagenomicsDatabaseToolRunner: MetagenomicsDatabaseToolRunning, Sendable {
    private let condaManager: CondaManager
    private let now: @Sendable () -> Date
    private let versionResolver: @Sendable (CondaManager, String, String, URL) async throws -> String

    public init(
        condaManager: CondaManager = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        versionResolver: @escaping @Sendable (CondaManager, String, String, URL) async throws -> String = Self.resolveManagedToolVersion
    ) {
        self.condaManager = condaManager; self.now = now; self.versionResolver = versionResolver
    }

    public func executableDirectory(environment: String) async throws -> URL {
        let directory = await condaManager.environmentURL(named: environment).appendingPathComponent("bin", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw MetagenomicsDatabaseInstallerError.missingManagedTool(name: environment == "kraken2" ? "kraken2-build" : "bracken-build")
        }
        return directory
    }

    public func executableDirectory(environment: String, executable: String) async throws -> URL {
        let directory = try await executableDirectory(environment: environment)
        guard FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(executable).path) else {
            throw MetagenomicsDatabaseInstallerError.missingManagedTool(name: executable)
        }
        return directory
    }

    public func run(name: String, arguments: [String], environment: String, workingDirectory: URL, timeout: TimeInterval) async throws -> MetagenomicsDatabaseToolResult {
        let executableDirectory = try await executableDirectory(environment: environment, executable: name)
        let executable = executableDirectory.appendingPathComponent(name)
        let started = now()
        let version = try await versionResolver(condaManager, name, environment, workingDirectory)
        let result = try await condaManager.runTool(name: name, arguments: arguments, environment: environment, workingDirectory: workingDirectory, timeout: timeout)
        let completed = now()
        let argv = [await condaManager.micromambaPath.path, "run", "-n", environment, name] + arguments
        return MetagenomicsDatabaseToolResult(
            stdout: result.stdout, stderr: result.stderr, exitStatus: result.exitCode, argv: argv,
            runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: executable.path, condaEnvironment: environment, condaPrefix: await condaManager.environmentURL(named: environment).path, pluginPack: "Metagenomics"),
            toolVersion: version, startedAt: started, completedAt: completed
        )
    }

    public func toolVersion(name: String, environment: String, workingDirectory: URL) async throws -> String {
        _ = try await executableDirectory(environment: environment, executable: name)
        return try await versionResolver(condaManager, name, environment, workingDirectory)
    }

    public static func resolveManagedToolVersion(_ condaManager: CondaManager, _ name: String, _ environment: String, _ workingDirectory: URL) async throws -> String {
        let packageName: String
        switch name {
        case "kraken2-build": packageName = "kraken2"
        case "bracken-build": packageName = "bracken"
        default: packageName = name
        }
        guard let version = try await condaManager.listInstalled(in: environment).first(where: { $0.name == packageName })?.version,
              !version.isEmpty else {
            throw MetagenomicsDatabaseInstallerError.missingManagedTool(name: name)
        }
        return version
    }
}

public struct URLSessionTarDatabaseArchiveTransfer: MetagenomicsDatabaseArchiveTransferring, Sendable {
    private let tarVersion: @Sendable () async throws -> String

    public init(
        tarVersion: @escaping @Sendable () async throws -> String = URLSessionTarDatabaseArchiveTransfer.detectTarVersion
    ) {
        self.tarVersion = tarVersion
    }

    public static func validateHTTPResponse(_ response: HTTPURLResponse) throws {
        guard 200 ..< 300 ~= response.statusCode else {
            throw MetagenomicsDatabaseInstallerError.archiveTransferFailed(
                "HTTP \(response.statusCode) while downloading \(response.url?.absoluteString ?? "archive")"
            )
        }
    }

    public static func detectTarVersion() async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["--version"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            guard process.terminationStatus == 0 else {
                throw MetagenomicsDatabaseInstallerError.toolFailed(
                    tool: "tar",
                    exitStatus: process.terminationStatus,
                    stderr: String(text.prefix(16_384))
                )
            }
            let tokens = text.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count >= 2 else {
                throw MetagenomicsDatabaseInstallerError.invalidPayload(
                    reason: "/usr/bin/tar did not report a version"
                )
            }
            return tokens.prefix(2).joined(separator: " ")
        }.value
    }

    public func extractionToolVersion() async throws -> String {
        try Self.normalizedTarVersion(await tarVersion())
    }

    static func normalizedTarVersion(_ text: String) throws -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 2 else {
            throw MetagenomicsDatabaseInstallerError.invalidPayload(
                reason: "/usr/bin/tar did not report a version"
            )
        }
        return tokens.prefix(2).joined(separator: " ")
    }

    public func download(from source: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let taskBox = DownloadTaskCancellationBox()
        let temporary = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let delegate = InstallerDownloadDelegate(progress: progress) { result in
                    switch result {
                    case .success(let url): continuation.resume(returning: url)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: source)
                taskBox.store(task)
                task.resume()
            }
        } onCancel: { taskBox.cancel() }
        try Task.checkCancellation()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-database-\(UUID().uuidString).tar.gz")
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }

    public func extract(archive: URL, destination: URL) async throws -> MetagenomicsDatabaseToolResult {
        try Task.checkCancellation()
        let started = Date()
        let resolvedTarVersion = try await extractionToolVersion()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", archive.path, "-C", destination.path]
        let stdout = Pipe(); let stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let cancellation = TarProcessCancellationBox()
        let state = TarProcessResultState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminated in
                    state.waitForDrains {
                        guard state.finishOnce() else { return }
                        continuation.resume(returning: MetagenomicsDatabaseToolResult(stdout: state.stdout, stderr: state.stderr, exitStatus: terminated.terminationStatus, argv: ["/usr/bin/tar", "xzf", archive.path, "-C", destination.path], runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: "/usr/bin/tar"), toolVersion: resolvedTarVersion, startedAt: started, completedAt: Date()))
                    }
                }
                state.drain(stdout.fileHandleForReading, into: .stdout)
                state.drain(stderr.fileHandleForReading, into: .stderr)
                do {
                    try Task.checkCancellation()
                    guard try cancellation.launch(process) else { throw CancellationError() }
                } catch {
                    guard state.finishOnce() else { return }
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class InstallerDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void
    private let fired = InstallerLockedFlag()

    init(progress: @Sendable @escaping (Double) -> Void, completion: @Sendable @escaping (Result<URL, Error>) -> Void) {
        self.progress = progress; self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytesWritten
        guard total > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(total), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard fired.testAndSet() else { return }
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-database-\(UUID().uuidString).tar.gz")
        do {
            if let response = downloadTask.response as? HTTPURLResponse {
                try URLSessionTarDatabaseArchiveTransfer.validateHTTPResponse(response)
            }
            try FileManager.default.copyItem(at: location, to: stable)
            completion(.success(stable))
        }
        catch { completion(.failure(error)) }
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, fired.testAndSet() else { return }
        completion(.failure(error)); session.invalidateAndCancel()
    }
}

private final class InstallerLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func testAndSet() -> Bool { lock.lock(); defer { lock.unlock() }; guard !value else { return false }; value = true; return true }
}

private final class TarProcessCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// The check and launch share a lock with cancellation, so cancellation can
    /// either prevent launch or terminate an already-running tar process.
    func launch(_ process: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        try process.run()
        self.process = process
        return true
    }

    func cancel() {
        lock.lock(); cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
}

private final class TarProcessResultState: @unchecked Sendable {
    enum Stream { case stdout, stderr }
    private let lock = NSLock()
    private let drains = DispatchGroup()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var completed = false

    func drain(_ handle: FileHandle, into stream: Stream) {
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = handle.readDataToEndOfFile()
            self.lock.lock()
            switch stream {
            case .stdout:
                let remaining = max(0, 16_384 - self.stdoutData.count)
                self.stdoutData.append(data.prefix(remaining))
            case .stderr:
                let remaining = max(0, 16_384 - self.stderrData.count)
                self.stderrData.append(data.prefix(remaining))
            }
            self.lock.unlock()
            self.drains.leave()
        }
    }

    func waitForDrains(_ body: @escaping @Sendable () -> Void) { drains.notify(queue: .global(qos: .utility), execute: body) }
    func finishOnce() -> Bool { lock.lock(); defer { lock.unlock() }; guard !completed else { return false }; completed = true; return true }
    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(data: stdoutData, encoding: .utf8) ?? "" }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(data: stderrData, encoding: .utf8) ?? "" }
}

public struct MetagenomicsDatabaseInstallResult: Sendable {
    public let finalURL: URL
    public let version: String
    public let payloadDigest: String
    public let sizeOnDisk: Int64
    public init(finalURL: URL, version: String, payloadDigest: String, sizeOnDisk: Int64) { self.finalURL = finalURL; self.version = version; self.payloadDigest = payloadDigest; self.sizeOnDisk = sizeOnDisk }
}

public struct PreparedMetagenomicsDatabaseInstallation: Sendable {
    public let result: MetagenomicsDatabaseInstallResult
    fileprivate let stagingURL: URL
    fileprivate let backupURL: URL?
    fileprivate init(result: MetagenomicsDatabaseInstallResult, stagingURL: URL, backupURL: URL? = nil) { self.result = result; self.stagingURL = stagingURL; self.backupURL = backupURL }
}

public enum MetagenomicsDatabaseInstallerError: Error, Equatable, LocalizedError, Sendable {
    case missingRecipe
    case missingManagedTool(name: String)
    case toolFailed(tool: String, exitStatus: Int32, stderr: String)
    case invalidPayload(reason: String)
    case archiveTransferFailed(String)
    case failureReceiptDiagnostic(original: String, receipt: String)

    public var errorDescription: String? {
        switch self {
        case .missingRecipe: return "This database has no installation recipe."
        case .missingManagedTool(let name): return "Managed executable '\(name)' is unavailable. Install or repair the Metagenomics pack and try again."
        case .toolFailed(let tool, let status, let stderr): return "\(tool) failed with exit status \(status): \(stderr)"
        case .invalidPayload(let reason): return "Prepared database payload is invalid: \(reason)"
        case .archiveTransferFailed(let message): return message
        case .failureReceiptDiagnostic(let original, let receipt): return "\(original) (also could not write installation failure receipt: \(receipt))"
        }
    }
}

public struct MetagenomicsDatabaseInstaller: Sendable {
    private let toolRunner: any MetagenomicsDatabaseToolRunning
    private let archiveTransfer: any MetagenomicsDatabaseArchiveTransferring
    private let provenanceWriter: any MetagenomicsDatabaseInstallProvenanceWriting
    private let fileSystem: any MetagenomicsDatabaseFileSystem
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    public init(toolRunner: any MetagenomicsDatabaseToolRunning, archiveTransfer: any MetagenomicsDatabaseArchiveTransferring, provenanceWriter: any MetagenomicsDatabaseInstallProvenanceWriting, fileSystem: any MetagenomicsDatabaseFileSystem = FoundationMetagenomicsDatabaseFileSystem(), now: @escaping @Sendable () -> Date = Date.init, uuid: @escaping @Sendable () -> UUID = UUID.init) {
        self.toolRunner = toolRunner; self.archiveTransfer = archiveTransfer; self.provenanceWriter = provenanceWriter
        self.fileSystem = fileSystem; self.now = now; self.uuid = uuid
    }

    public func prepareInstallation(database: MetagenomicsDatabaseInfo, databasesBaseURL: URL, threads: Int, progress: @Sendable @escaping (Double, String) -> Void) async throws -> PreparedMetagenomicsDatabaseInstallation {
        let started = now()
        let finalURL = databasesBaseURL.standardizedFileURL.appendingPathComponent("kraken2", isDirectory: true).appendingPathComponent(Self.safePathComponent(database.catalogID ?? database.name), isDirectory: true)
        let staging = finalURL.deletingLastPathComponent().appendingPathComponent(".install-\(uuid().uuidString)", isDirectory: true)
        var steps: [MetagenomicsDatabaseInstallStepEvidence] = []
        var didPromoteStaging = false
        var didResolveRecipe = false
        let defaults: [String: ParameterValue] = ["threads": .integer(4), "kmerLength": .integer(35), "readLength": .integer(150)]
        let resolved: [String: ParameterValue] = ["threads": .integer(threads), "kmerLength": .integer(35), "readLength": .integer(150), "databaseRoot": .file(staging)]
        let recipeSource: String
        do {
            try Task.checkCancellation()
            try fileSystem.createDirectory(at: staging)
            guard let recipe = database.installationRecipe else { throw MetagenomicsDatabaseInstallerError.missingRecipe }
            didResolveRecipe = true
            switch recipe {
            case .archive(let source):
                recipeSource = source.absoluteString
                progress(0, "Downloading…")
                let archive = try await archiveTransfer.download(from: source) { fraction in progress(fraction * 0.4, "Downloading…") }
                try Task.checkCancellation()
                let descriptor = try ProvenanceFileDescriptor.file(url: archive, role: .input)
                progress(0.4, "Preparing…")
                let extractionVersion = try await archiveTransfer.extractionToolVersion()
                steps.append(plannedArchiveEvidence(
                    archive: archive,
                    destination: staging,
                    toolVersion: extractionVersion,
                    inputs: [descriptor],
                    options: resolved,
                    startedAt: now()
                ))
                let extraction = try await archiveTransfer.extract(archive: archive, destination: staging)
                steps[steps.count - 1] = evidence(from: extraction, toolName: "tar", inputs: [descriptor], options: resolved)
                try throwOnFailure(extraction, tool: "tar")
            case .kraken2Special(let type):
                recipeSource = type.rawValue
                progress(0, "Downloading…")
                try Task.checkCancellation()
                let krakenBin = try await executableDirectory(environment: "kraken2", executable: "kraken2-build")
                let brackenBin = try await executableDirectory(environment: "bracken", executable: "bracken-build")
                let krakenVersion = try await toolRunner.toolVersion(name: "kraken2-build", environment: "kraken2", workingDirectory: staging)
                let brackenVersion = try await toolRunner.toolVersion(name: "bracken-build", environment: "bracken", workingDirectory: staging)
                progress(0.35, "Preparing…")
                let specialArguments = ["--db", staging.path, "--special", type.rawValue]
                steps.append(plannedEvidence(
                    name: "kraken2-build", arguments: specialArguments, environment: "kraken2",
                    executableDirectory: krakenBin, toolVersion: krakenVersion, options: resolved, startedAt: now()
                ))
                let special = try await toolRunner.run(name: "kraken2-build", arguments: specialArguments, environment: "kraken2", workingDirectory: staging, timeout: 86_400)
                steps[steps.count - 1] = evidence(from: special, toolName: "kraken2-build", inputs: [], options: resolved)
                try throwOnFailure(special, tool: "kraken2-build")
                try Task.checkCancellation()
                let brackenArguments = ["-d", staging.path, "-t", String(threads), "-k", "35", "-l", "150", "-x", krakenBin.path, "-y", "kraken2"]
                steps.append(plannedEvidence(
                    name: "bracken-build", arguments: brackenArguments, environment: "bracken",
                    executableDirectory: brackenBin, toolVersion: brackenVersion, options: resolved, startedAt: now()
                ))
                let bracken = try await toolRunner.run(name: "bracken-build", arguments: brackenArguments, environment: "bracken", workingDirectory: staging, timeout: 86_400)
                steps[steps.count - 1] = evidence(from: bracken, toolName: "bracken-build", inputs: [], options: resolved)
                try throwOnFailure(bracken, tool: "bracken-build")
            }
            try Task.checkCancellation()
            progress(0.8, "Verifying…")
            try validatePayload(at: staging, requiresSpecialEvidence: isSpecial(database.installationRecipe))
            let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: staging)
            guard snapshot.totalSizeBytes > 0, !snapshot.aggregateSHA256.isEmpty else { throw MetagenomicsDatabaseInstallerError.invalidPayload(reason: "empty snapshot") }
            try Task.checkCancellation()
            // The preparation result has no registry visibility.  Canonical provenance
            // nevertheless must target the durable final path, so stage promotion occurs
            // before the success receipt and can be undone by rollback.
            try fileSystem.createDirectory(at: finalURL.deletingLastPathComponent())
            guard !fileSystem.fileExists(at: finalURL) else { throw MetagenomicsDatabaseInstallerError.invalidPayload(reason: "destination already exists") }
            try fileSystem.moveItem(at: staging, to: finalURL)
            didPromoteStaging = true
            let attempt = MetagenomicsDatabaseInstallAttempt(database: database, finalURL: finalURL, recipeSource: recipeSource, explicitOptions: ["threads": .integer(threads)], defaultOptions: defaults, resolvedOptions: resolved, steps: steps, startedAt: started, completedAt: now())
            let finalSnapshot = MetagenomicsDatabasePayloadSnapshot(rootURL: staging, files: snapshot.files, aggregateSHA256: snapshot.aggregateSHA256, totalSizeBytes: snapshot.totalSizeBytes)
            do { try provenanceWriter.writeSuccess(attempt, snapshot: finalSnapshot) } catch { try? fileSystem.removeItemIfPresent(at: finalURL); throw error }
            try Task.checkCancellation()
            progress(1, "Verifying…")
            let version = "built-\(Self.dayString(started))-\(snapshot.aggregateSHA256.prefix(12))"
            return PreparedMetagenomicsDatabaseInstallation(result: .init(finalURL: finalURL, version: version, payloadDigest: snapshot.aggregateSHA256, sizeOnDisk: Int64(clamping: snapshot.totalSizeBytes)), stagingURL: staging)
        } catch let originalError {
            try? fileSystem.removeItemIfPresent(at: staging)
            if didPromoteStaging {
                try? fileSystem.removeItemIfPresent(at: finalURL)
            }
            let failure = failureRecord(for: originalError)
            if didResolveRecipe {
                let attempt = MetagenomicsDatabaseInstallAttempt(database: database, finalURL: finalURL, recipeSource: database.installationRecipe.map(Self.recipeSource) ?? "unknown", explicitOptions: ["threads": .integer(threads)], defaultOptions: defaults, resolvedOptions: resolved, steps: steps, startedAt: started, completedAt: now())
                do { try provenanceWriter.writeFailure(attempt, error: failure, historyDirectory: databasesBaseURL.appendingPathComponent("installation-history", isDirectory: true)) }
                catch let receiptError { throw MetagenomicsDatabaseInstallerError.failureReceiptDiagnostic(original: originalError.localizedDescription, receipt: receiptError.localizedDescription) }
            }
            throw originalError
        }
    }

    public func finalize(_ prepared: PreparedMetagenomicsDatabaseInstallation) throws { _ = prepared }
    public func rollback(_ prepared: PreparedMetagenomicsDatabaseInstallation) throws { try fileSystem.removeItemIfPresent(at: prepared.result.finalURL); if let backup = prepared.backupURL { try fileSystem.moveItem(at: backup, to: prepared.result.finalURL) } }

    private func executableDirectory(environment: String, executable: String) async throws -> URL {
        do { return try await toolRunner.executableDirectory(environment: environment, executable: executable) }
        catch { throw MetagenomicsDatabaseInstallerError.missingManagedTool(name: executable) }
    }
    private func evidence(from result: MetagenomicsDatabaseToolResult, toolName: String, inputs: [ProvenanceFileDescriptor], options: [String: ParameterValue]) -> MetagenomicsDatabaseInstallStepEvidence {
        .init(toolName: toolName, toolVersion: result.toolVersion, argv: result.argv, durableReplayArgv: result.argv, resolvedOptions: options, runtimeIdentity: result.runtimeIdentity, inputs: inputs, outputs: [], exitStatus: result.exitStatus, startedAt: result.startedAt, completedAt: result.completedAt, stderr: Self.bounded(result.stderr))
    }
    private func plannedEvidence(name: String, arguments: [String], environment: String, executableDirectory: URL, toolVersion: String, options: [String: ParameterValue], startedAt: Date) -> MetagenomicsDatabaseInstallStepEvidence {
        let argv = [name] + arguments
        return .init(
            toolName: name, toolVersion: toolVersion, argv: argv, durableReplayArgv: argv,
            resolvedOptions: options,
            runtimeIdentity: .init(
                executablePath: executableDirectory.appendingPathComponent(name).path,
                condaEnvironment: environment,
                condaPrefix: executableDirectory.deletingLastPathComponent().path,
                pluginPack: "Metagenomics"
            ),
            inputs: [], outputs: [], exitStatus: 130, startedAt: startedAt, completedAt: startedAt,
            stderr: ""
        )
    }
    private func plannedArchiveEvidence(archive: URL, destination: URL, toolVersion: String, inputs: [ProvenanceFileDescriptor], options: [String: ParameterValue], startedAt: Date) -> MetagenomicsDatabaseInstallStepEvidence {
        let argv = ["/usr/bin/tar", "xzf", archive.path, "-C", destination.path]
        return .init(
            toolName: "tar", toolVersion: toolVersion, argv: argv, durableReplayArgv: argv,
            resolvedOptions: options,
            runtimeIdentity: .init(executablePath: "/usr/bin/tar"),
            inputs: inputs, outputs: [], exitStatus: 130,
            startedAt: startedAt, completedAt: startedAt, stderr: ""
        )
    }
    private func throwOnFailure(_ result: MetagenomicsDatabaseToolResult, tool: String) throws { if result.exitStatus != 0 { throw MetagenomicsDatabaseInstallerError.toolFailed(tool: tool, exitStatus: result.exitStatus, stderr: Self.bounded(result.stderr)) } }
    private func validatePayload(at root: URL, requiresSpecialEvidence: Bool) throws {
        for relative in ["hash.k2d", "opts.k2d", "taxo.k2d", "database150mers.kmer_distrib"] { try validateRegularNonempty(root.appendingPathComponent(relative)) }
        guard requiresSpecialEvidence else { return }
        try validateRegularNonempty(root.appendingPathComponent("taxonomy/nodes.dmp")); try validateRegularNonempty(root.appendingPathComponent("taxonomy/names.dmp"))
        let library = root.appendingPathComponent("library", isDirectory: true)
        let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: root)
        guard snapshot.files.contains(where: { $0.path.hasPrefix("library/") }) else { throw MetagenomicsDatabaseInstallerError.invalidPayload(reason: "missing regular library file") }
        guard FileManager.default.fileExists(atPath: library.path) else { throw MetagenomicsDatabaseInstallerError.invalidPayload(reason: "missing library") }
    }
    private func validateRegularNonempty(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else { throw MetagenomicsDatabaseInstallerError.invalidPayload(reason: "missing or empty \(url.lastPathComponent)") }
    }
    private func isSpecial(_ recipe: MetagenomicsDatabaseInstallationRecipe?) -> Bool { if case .kraken2Special = recipe { return true }; return false }
    private func failureRecord(for error: Error) -> MetagenomicsDatabaseInstallFailure { if error is CancellationError { return .cancelled(message: "Installation cancelled", stderr: "") }; if case .toolFailed(_, let status, let stderr) = error as? MetagenomicsDatabaseInstallerError { return .failed(exitStatus: status, message: error.localizedDescription, stderr: stderr) }; return .failed(exitStatus: 1, message: error.localizedDescription, stderr: "") }
    private static func bounded(_ text: String) -> String { String(text.prefix(16_384)) }
    private static func recipeSource(_ recipe: MetagenomicsDatabaseInstallationRecipe) -> String { switch recipe { case .archive(let url): return url.absoluteString; case .kraken2Special(let type): return type.rawValue } }
    private static func safePathComponent(_ source: String) -> String { let value = source.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }; return String(value).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
    private static func dayString(_ date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd"; return formatter.string(from: date) }
}

import Darwin
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

public struct GenotypeWorkbookUpdateAttemptReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let attemptID: String
    public let startedAt: Date
    public let completedAt: Date
    public let wallTimeSeconds: Double
    public let argv: [String]
    public let reproducibleCommand: String
    public let resolvedOptions: [String: String]
    public let runtimeIdentity: [String: String]
    public let attemptedInputPaths: [String]
    public let inputs: [ProvenanceFileDescriptor]
    public let outputs: [ProvenanceFileDescriptor]
    public let exitStatus: Int
    public let stderr: String?
    public let cleanupPendingWarning: String?
}

public enum GenotypeWorkbookUpdateAttemptRecorderError:
    Error,
    LocalizedError,
    Equatable
{
    case invalidBundle(String)
    case cannotCreateAttemptsDirectory(String, Int32)
    case cannotCreateExclusiveAttempt(String, Int32)
    case attemptAlreadyFinalized(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundle(let path):
            return "Workbook update attempt target is not a writable regular bundle directory: \(path)"
        case .cannotCreateAttemptsDirectory(let path, let code):
            return "Could not create workbook update attempt directory \(path) (errno \(code))."
        case .cannotCreateExclusiveAttempt(let path, let code):
            return "Could not create an exclusive workbook update attempt at \(path) (errno \(code))."
        case .attemptAlreadyFinalized(let identifier):
            return "Workbook update attempt \(identifier) was already finalized."
        }
    }
}

private struct GenotypeWorkbookUpdateAttemptRollbackError:
    Error,
    LocalizedError
{
    let path: String
    let code: Int32

    var errorDescription: String? {
        "Could not remove an incomplete workbook update attempt terminal publication at \(path) (errno \(code))."
    }
}

private struct GenotypeWorkbookUpdateAttemptMarker:
    Codable,
    Equatable
{
    static let fileName = ".lungfish-workbook-update-attempt.json"
    let schemaVersion: Int
    let attemptID: String
    let authorityToken: String
}

public struct GenotypeWorkbookUpdateAttemptRecorder: Sendable {
    private let dateProvider: @Sendable () -> Date
    private let uuidProvider: @Sendable () -> UUID
    private let atomicFileStore: DurableAtomicFileStore
    private let markerFileStore = DurableAtomicFileStore()

    public init(
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() },
        atomicFileStore: DurableAtomicFileStore = .init()
    ) {
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
        self.atomicFileStore = atomicFileStore
    }

    public func begin(
        bundleURL: URL,
        argv: [String],
        attemptedInputPaths: [String] = []
    ) throws -> GenotypeWorkbookUpdateAttemptHandle {
        let bundle = bundleURL.standardizedFileURL
        let publicationLock =
            try ONTGenotypeBundlePublicationLock.acquire(
                for: bundle,
                blocking: true
            )
        defer { publicationLock.release() }
        let bundleDescriptor = Darwin.open(
            bundle.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard bundleDescriptor >= 0 else {
            throw GenotypeWorkbookUpdateAttemptRecorderError.invalidBundle(
                bundle.path
            )
        }
        defer { Darwin.close(bundleDescriptor) }
        var bundleInfo = stat()
        guard Darwin.fstat(bundleDescriptor, &bundleInfo) == 0,
              bundleInfo.st_mode & S_IFMT == S_IFDIR,
              Darwin.faccessat(bundleDescriptor, ".", W_OK, 0) == 0 else {
            throw GenotypeWorkbookUpdateAttemptRecorderError.invalidBundle(
                bundle.path
            )
        }

        let relativeComponents = ["artifacts", "workbooks", "updates", "attempts"]
        var currentDescriptor = Darwin.dup(bundleDescriptor)
        guard currentDescriptor >= 0 else {
            throw GenotypeWorkbookUpdateAttemptRecorderError
                .cannotCreateAttemptsDirectory(bundle.path, errno)
        }
        defer { Darwin.close(currentDescriptor) }
        var currentURL = bundle
        for component in relativeComponents {
            currentURL.appendPathComponent(component, isDirectory: true)
            let next = try openOrCreateDirectory(
                component,
                parentDescriptor: currentDescriptor,
                displayedURL: currentURL
            )
            Darwin.close(currentDescriptor)
            currentDescriptor = next
        }

        var lastCollisionCode = EEXIST
        for _ in 0..<32 {
            let attemptID = uuidProvider().uuidString.lowercased()
            let status = attemptID.withCString {
                Darwin.mkdirat(currentDescriptor, $0, S_IRWXU)
            }
            if status == 0 {
                let attemptURL = currentURL.appendingPathComponent(
                    attemptID,
                    isDirectory: true
                )
                let attemptDescriptor = attemptID.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard attemptDescriptor >= 0 else {
                    let code = errno
                    _ = attemptID.withCString {
                        Darwin.unlinkat(
                            currentDescriptor,
                            $0,
                            AT_REMOVEDIR
                        )
                    }
                    throw GenotypeWorkbookUpdateAttemptRecorderError
                        .cannotCreateExclusiveAttempt(attemptURL.path, code)
                }
                let authorityToken = UUID().uuidString.lowercased()
                do {
                    let marker = GenotypeWorkbookUpdateAttemptMarker(
                        schemaVersion: 1,
                        attemptID: attemptID,
                        authorityToken: authorityToken
                    )
                    _ = try markerFileStore.create(
                        try ProvenanceJSON.encoder.encode(marker),
                        named:
                            GenotypeWorkbookUpdateAttemptMarker.fileName,
                        inOpenDirectory: attemptDescriptor,
                        displayedAt: attemptURL
                    )
                } catch {
                    cleanupFreshAttempt(
                        attemptID: attemptID,
                        attemptDescriptor: attemptDescriptor,
                        parentDescriptor: currentDescriptor
                    )
                    throw error
                }
                guard Darwin.fsync(currentDescriptor) == 0 else {
                    let code = errno
                    cleanupFreshAttempt(
                        attemptID: attemptID,
                        attemptDescriptor: attemptDescriptor,
                        parentDescriptor: currentDescriptor
                    )
                    throw GenotypeWorkbookUpdateAttemptRecorderError
                        .cannotCreateExclusiveAttempt(
                            currentURL.appendingPathComponent(attemptID).path,
                            code
                        )
                }
                Darwin.close(attemptDescriptor)
                return GenotypeWorkbookUpdateAttemptHandle(
                    attemptID: attemptID,
                    directoryURL: attemptURL,
                    bundleURL: bundle,
                    authorityToken: authorityToken,
                    startedAt: dateProvider(),
                    argv: argv,
                    attemptedInputPaths: attemptedInputPaths,
                    dateProvider: dateProvider,
                    atomicFileStore: atomicFileStore
                )
            }
            lastCollisionCode = errno
            guard lastCollisionCode == EEXIST else { break }
        }
        throw GenotypeWorkbookUpdateAttemptRecorderError
            .cannotCreateExclusiveAttempt(currentURL.path, lastCollisionCode)
    }

    private func cleanupFreshAttempt(
        attemptID: String,
        attemptDescriptor: Int32,
        parentDescriptor: Int32
    ) {
        _ = GenotypeWorkbookUpdateAttemptMarker.fileName.withCString {
            Darwin.unlinkat(attemptDescriptor, $0, 0)
        }
        Darwin.close(attemptDescriptor)
        _ = attemptID.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
    }

    private func openOrCreateDirectory(
        _ name: String,
        parentDescriptor: Int32,
        displayedURL: URL
    ) throws -> Int32 {
        var descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor >= 0 { return descriptor }
        guard errno == ENOENT else {
            throw GenotypeWorkbookUpdateAttemptRecorderError
                .cannotCreateAttemptsDirectory(displayedURL.path, errno)
        }
        let mkdirStatus = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        guard mkdirStatus == 0 || errno == EEXIST else {
            throw GenotypeWorkbookUpdateAttemptRecorderError
                .cannotCreateAttemptsDirectory(displayedURL.path, errno)
        }
        descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GenotypeWorkbookUpdateAttemptRecorderError
                .cannotCreateAttemptsDirectory(displayedURL.path, errno)
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw GenotypeWorkbookUpdateAttemptRecorderError
                .cannotCreateAttemptsDirectory(displayedURL.path, code)
        }
        return descriptor
    }
}

public final class GenotypeWorkbookUpdateAttemptHandle:
    @unchecked Sendable
{
    public let attemptID: String
    public let directoryURL: URL
    public var recordedArgv: [String] { argv }
    public var isFinalized: Bool {
        lock.withLock {
            if case .finalized = state { return true }
            return false
        }
    }
    public var hasPublicationFailure: Bool {
        lock.withLock { publicationFailureCount > 0 }
    }
    var testingTerminalOwnershipCount: Int {
        lock.withLock { terminalOwnershipCount }
    }

    private enum State {
        case recording
        case publishing
        case publicationFailed
        case finalized
    }

    private struct Snapshot {
        let completedAt: Date
        let attemptedInputPaths: [String]
        let resolvedOptions: [String: String]
        let runtimeIdentity: [String: String]
        let inputs: [ProvenanceFileDescriptor]
        let outputs: [ProvenanceFileDescriptor]
    }

    private struct PublishedFileWitness {
        let name: String
        let descriptor: Int32
        let identity: FileSystemObjectIdentity
    }

    private let lock = NSLock()
    private var state: State = .recording
    private var publicationFailureCount = 0
    private var terminalOwnershipCount = 0
    private let bundleURL: URL
    private let authorityToken: String
    private let startedAt: Date
    private let argv: [String]
    private var attemptedInputPaths: [String]
    private var resolvedOptions: [String: String] = [:]
    private var runtimeIdentity: [String: String]
    private var inputs: [ProvenanceFileDescriptor] = []
    private var outputs: [ProvenanceFileDescriptor] = []
    private let dateProvider: @Sendable () -> Date
    private let atomicFileStore: DurableAtomicFileStore

    fileprivate init(
        attemptID: String,
        directoryURL: URL,
        bundleURL: URL,
        authorityToken: String,
        startedAt: Date,
        argv: [String],
        attemptedInputPaths: [String],
        dateProvider: @escaping @Sendable () -> Date,
        atomicFileStore: DurableAtomicFileStore
    ) {
        self.attemptID = attemptID
        self.directoryURL = directoryURL
        self.bundleURL = bundleURL
        self.authorityToken = authorityToken
        self.startedAt = startedAt
        self.argv = argv
        self.attemptedInputPaths = attemptedInputPaths
        self.dateProvider = dateProvider
        self.atomicFileStore = atomicFileStore
        self.runtimeIdentity = Self.baseRuntimeIdentity()
    }

    public func recordResolvedOptions(
        _ values: [String: String]
    ) throws {
        try mutate {
            resolvedOptions.merge(values) { _, newValue in newValue }
        }
    }

    public func recordRuntimeIdentity(
        _ values: [String: String]
    ) throws {
        try mutate {
            runtimeIdentity.merge(values) { _, newValue in newValue }
            if let pythonExecutable = values["pythonExecutable"] {
                if runtimeIdentity["condaEnvironment"] == nil {
                    runtimeIdentity["condaEnvironment"] = "openpyxl"
                }
                if runtimeIdentity["condaPrefix"] == nil {
                    runtimeIdentity["condaPrefix"] = URL(
                        fileURLWithPath: pythonExecutable
                    )
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .path
                }
            }
        }
    }

    public func recordAttemptedInputPaths(_ paths: [String]) throws {
        try mutate {
            attemptedInputPaths.append(contentsOf: paths)
            attemptedInputPaths = Array(Set(attemptedInputPaths)).sorted()
        }
    }

    public func recordInput(
        _ descriptor: ProvenanceFileDescriptor
    ) throws {
        try mutate {
            inputs = Self.upserting(descriptor, into: inputs)
        }
    }

    public func recordOutput(
        _ descriptor: ProvenanceFileDescriptor
    ) throws {
        try mutate {
            outputs = Self.upserting(
                descriptor.withRole(.output),
                into: outputs
            )
        }
    }

    public func recordInputFile(
        at url: URL,
        format: FileFormat? = nil
    ) throws {
        try recordInput(
            ProvenanceFileDescriptor.file(
                url: url,
                format: format,
                role: .input
            )
        )
    }

    public func recordOutputFile(
        at url: URL,
        format: FileFormat? = nil
    ) throws {
        try recordOutput(
            ProvenanceFileDescriptor.file(
                url: url,
                format: format,
                role: .output
            )
        )
    }

    public func finalize(
        exitStatus: Int,
        stderr: String? = nil,
        cleanupPendingWarning: String? = nil,
        completedAt: Date? = nil
    ) throws {
        let snapshot: Snapshot = try lock.withLock {
            guard state == .recording else {
                throw GenotypeWorkbookUpdateAttemptRecorderError
                    .attemptAlreadyFinalized(attemptID)
            }
            state = .publishing
            terminalOwnershipCount += 1
            return Snapshot(
                completedAt: completedAt ?? dateProvider(),
                attemptedInputPaths: attemptedInputPaths,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: inputs.sorted { $0.path < $1.path },
                outputs: outputs.sorted { $0.path < $1.path }
            )
        }
        let publicationLock: ONTGenotypeBundlePublicationLock
        do {
            publicationLock =
                try ONTGenotypeBundlePublicationLock.acquire(
                    for: bundleURL,
                    blocking: true
                )
        } catch {
            recordTerminalPublicationFailure()
            throw error
        }
        defer { publicationLock.release() }
        let binding: (descriptor: Int32, displayedURL: URL)
        do {
            binding = try bindCurrentAttemptDirectory()
        } catch {
            recordTerminalPublicationFailure()
            throw error
        }
        defer { Darwin.close(binding.descriptor) }

        do {
            try publishTerminal(
                exitStatus: exitStatus,
                stderr: stderr,
                cleanupPendingWarning: cleanupPendingWarning,
                snapshot: snapshot,
                directoryDescriptor: binding.descriptor,
                displayedURL: binding.displayedURL
            )
            lock.withLock { state = .finalized }
        } catch let initialError {
            recordTerminalPublicationFailure(lockState: false)
            if initialError is GenotypeWorkbookUpdateAttemptRollbackError {
                lock.withLock { state = .publicationFailed }
                throw initialError
            }
            let failureText = [
                Self.normalized(stderr),
                "terminal provenance publication failed: \(Self.errorText(initialError))",
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            do {
                try publishTerminal(
                    exitStatus: 1,
                    stderr: failureText,
                    cleanupPendingWarning: nil,
                    snapshot: snapshot,
                    directoryDescriptor: binding.descriptor,
                    displayedURL: binding.displayedURL
                )
                lock.withLock { state = .finalized }
            } catch {
                lock.withLock { state = .publicationFailed }
                throw error
            }
            throw initialError
        }
    }

    private func publishTerminal(
        exitStatus: Int,
        stderr: String?,
        cleanupPendingWarning: String?,
        snapshot: Snapshot,
        directoryDescriptor: Int32,
        displayedURL: URL
    ) throws {
        let wallTime = max(
            0,
            snapshot.completedAt.timeIntervalSince(startedAt)
        )
        let command = argv.map(Self.shellEscape).joined(separator: " ")
        let receipt = GenotypeWorkbookUpdateAttemptReceipt(
            schemaVersion: 1,
            attemptID: attemptID,
            startedAt: startedAt,
            completedAt: snapshot.completedAt,
            wallTimeSeconds: wallTime,
            argv: argv,
            reproducibleCommand: command,
            resolvedOptions: snapshot.resolvedOptions,
            runtimeIdentity: snapshot.runtimeIdentity,
            attemptedInputPaths: snapshot.attemptedInputPaths,
            inputs: snapshot.inputs,
            outputs: snapshot.outputs,
            exitStatus: exitStatus,
            stderr: Self.normalized(stderr),
            cleanupPendingWarning: Self.normalized(cleanupPendingWarning)
        )
        var published: [PublishedFileWitness] = []
        defer {
            for witness in published {
                Darwin.close(witness.descriptor)
            }
        }
        do {
            let receiptData = try ProvenanceJSON.encoder.encode(receipt)
            _ = try atomicFileStore.create(
                receiptData,
                named: "receipt.json",
                inOpenDirectory: directoryDescriptor,
                displayedAt: displayedURL
            )
            published.append(
                try witness(
                    named: "receipt.json",
                    in: directoryDescriptor,
                    displayedAt: displayedURL
                )
            )
            let receiptDescriptor = ProvenanceFileDescriptor(
                path: displayedURL.appendingPathComponent(
                    "receipt.json"
                ).path,
                checksumSHA256: Self.sha256(receiptData),
                fileSize: UInt64(receiptData.count),
                format: .json,
                role: .output
            )
            let runtime = ProvenanceRuntimeIdentity(
                appVersion:
                    snapshot.runtimeIdentity["appVersion"]
                        ?? WorkflowRun.currentAppVersion,
                executablePath:
                    snapshot.runtimeIdentity["executablePath"]
                        ?? ProvenanceRuntimeIdentity.currentExecutablePath,
                operatingSystemVersion:
                    snapshot.runtimeIdentity["operatingSystem"]
                        ?? ProcessInfo.processInfo.operatingSystemVersionString,
                architecture:
                    snapshot.runtimeIdentity["architecture"]
                        ?? ProvenanceRuntimeIdentity.currentArchitecture,
                gitRevision: snapshot.runtimeIdentity["gitRevision"],
                condaEnvironment:
                    snapshot.runtimeIdentity["condaEnvironment"],
                condaPrefix: snapshot.runtimeIdentity["condaPrefix"]
            )
            let options = ProvenanceOptions(
                explicit: snapshot.resolvedOptions.mapValues {
                    ParameterValue.string($0)
                }
            )
            let envelope = ProvenanceEnvelope(
                id: UUID(uuidString: attemptID) ?? UUID(),
                createdAt: startedAt,
                workflowName: "update-current-workbook attempt",
                workflowVersion: WorkflowRun.currentAppVersion,
                toolName: "lungfish-cli fastq update-current-workbook",
                toolVersion: LungfishAppVersion.cliToolVersion,
                tool: ProvenanceToolIdentity(
                    name: "lungfish-cli fastq update-current-workbook",
                    version: LungfishAppVersion.cliToolVersion,
                    kind: "cli"
                ),
                argv: argv,
                durableReplayArgv: argv,
                reproducibleCommand: command,
                options: options,
                runtimeIdentity: runtime,
                files: snapshot.inputs,
                outputs: snapshot.outputs + [receiptDescriptor],
                wallTimeSeconds: wallTime,
                exitStatus: exitStatus,
                stderr: Self.normalized(stderr)
            )
            _ = try atomicFileStore.create(
                try ProvenanceJSON.encoder.encode(envelope),
                named: "provenance.json",
                inOpenDirectory: directoryDescriptor,
                displayedAt: displayedURL
            )
            published.append(
                try witness(
                    named: "provenance.json",
                    in: directoryDescriptor,
                    displayedAt: displayedURL
                )
            )
        } catch {
            let publicationError = error
            try rollbackTerminalFiles(
                published,
                directoryDescriptor: directoryDescriptor,
                displayedURL: displayedURL
            )
            throw publicationError
        }
    }

    private func rollbackTerminalFiles(
        _ witnesses: [PublishedFileWitness],
        directoryDescriptor: Int32,
        displayedURL: URL
    ) throws {
        guard !witnesses.isEmpty else { return }
        for witness in witnesses.reversed() {
            var openInformation = stat()
            var entryInformation = stat()
            guard Darwin.fstat(
                witness.descriptor,
                &openInformation
            ) == 0,
                  FileSystemObjectIdentity(
                    from: openInformation
                  ) == witness.identity,
                  witness.name.withCString({
                      Darwin.fstatat(
                          directoryDescriptor,
                          $0,
                          &entryInformation,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  FileSystemObjectIdentity(
                    from: entryInformation
                  ) == witness.identity else {
                throw GenotypeWorkbookUpdateAttemptRollbackError(
                    path: displayedURL
                        .appendingPathComponent(witness.name).path,
                    code: ESTALE
                )
            }
            let status = witness.name.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            guard status == 0 else {
                throw GenotypeWorkbookUpdateAttemptRollbackError(
                    path: displayedURL
                        .appendingPathComponent(witness.name).path,
                    code: errno
                )
            }
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw GenotypeWorkbookUpdateAttemptRollbackError(
                path: displayedURL.path,
                code: errno
            )
        }
    }

    private func bindCurrentAttemptDirectory() throws -> (
        descriptor: Int32,
        displayedURL: URL
    ) {
        let attemptsURL = bundleURL.appendingPathComponent(
            "artifacts/workbooks/updates/attempts",
            isDirectory: true
        )
        let attemptsDescriptor: Int32
        do {
            attemptsDescriptor =
                try NoFollowFileSystem.openDirectoryHierarchy(attemptsURL)
        } catch {
            throw GenotypeWorkbookUpdateAttemptRollbackError(
                path: attemptsURL.path,
                code: ESTALE
            )
        }
        defer { Darwin.close(attemptsDescriptor) }
        let displayedURL = attemptsURL.appendingPathComponent(
            attemptID,
            isDirectory: true
        )
        let descriptor = attemptID.withCString {
            Darwin.openat(
                attemptsDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GenotypeWorkbookUpdateAttemptRollbackError(
                path: displayedURL.path,
                code: errno
            )
        }
        do {
            let marker = try readMarker(
                directoryDescriptor: descriptor,
                displayedURL: displayedURL
            )
            guard marker == GenotypeWorkbookUpdateAttemptMarker(
                schemaVersion: 1,
                attemptID: attemptID,
                authorityToken: authorityToken
            ) else {
                throw GenotypeWorkbookUpdateAttemptRollbackError(
                    path: displayedURL.appendingPathComponent(
                        GenotypeWorkbookUpdateAttemptMarker.fileName
                    ).path,
                    code: ESTALE
                )
            }
            return (descriptor, displayedURL)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func readMarker(
        directoryDescriptor: Int32,
        displayedURL: URL
    ) throws -> GenotypeWorkbookUpdateAttemptMarker {
        let name = GenotypeWorkbookUpdateAttemptMarker.fileName
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GenotypeWorkbookUpdateAttemptRollbackError(
                path: displayedURL.appendingPathComponent(name).path,
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= 65_536 else {
            throw GenotypeWorkbookUpdateAttemptRollbackError(
                path: displayedURL.appendingPathComponent(name).path,
                code: ESTALE
            )
        }
        var data = Data(
            count: Int(information.st_size)
        )
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw GenotypeWorkbookUpdateAttemptRollbackError(
                        path: displayedURL
                            .appendingPathComponent(name).path,
                        code: count == 0 ? EIO : errno
                    )
                }
                offset += count
            }
        }
        return try ProvenanceJSON.decoder.decode(
            GenotypeWorkbookUpdateAttemptMarker.self,
            from: data
        )
    }

    private func witness(
        named name: String,
        in directoryDescriptor: Int32,
        displayedAt directoryURL: URL
    ) throws -> PublishedFileWitness {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GenotypeWorkbookUpdateAttemptRollbackError(
                path: directoryURL.appendingPathComponent(name).path,
                code: errno
            )
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            let code = errno == 0 ? ESTALE : errno
            Darwin.close(descriptor)
            throw GenotypeWorkbookUpdateAttemptRollbackError(
                path: directoryURL.appendingPathComponent(name).path,
                code: code
            )
        }
        return PublishedFileWitness(
            name: name,
            descriptor: descriptor,
            identity: FileSystemObjectIdentity(from: information)
        )
    }

    private func recordTerminalPublicationFailure(
        lockState: Bool = true
    ) {
        lock.withLock {
            publicationFailureCount += 1
            if lockState { state = .publicationFailed }
        }
    }

    private func mutate(_ mutation: () -> Void) throws {
        try lock.withLock {
            guard state == .recording else {
                throw GenotypeWorkbookUpdateAttemptRecorderError
                    .attemptAlreadyFinalized(attemptID)
            }
            mutation()
        }
    }

    private static func upserting(
        _ descriptor: ProvenanceFileDescriptor,
        into descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        descriptors.filter { $0.path != descriptor.path } + [descriptor]
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func errorText(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func shellEscape(_ argument: String) -> String {
        "'\(argument.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func baseRuntimeIdentity() -> [String: String] {
        var identity = [
            "appVersion": WorkflowRun.currentAppVersion,
            "cliVersion": LungfishAppVersion.cliToolVersion,
            "executablePath": ProvenanceRuntimeIdentity.currentExecutablePath,
            "operatingSystem":
                ProcessInfo.processInfo.operatingSystemVersionString,
            "kernel": Self.kernelIdentity(),
            "architecture": ProvenanceRuntimeIdentity.currentArchitecture,
            "processIdentifier":
                String(ProcessInfo.processInfo.processIdentifier),
        ]
        if let sourceRevision = Bundle.main.object(
            forInfoDictionaryKey: "LungfishGitRevision"
        ) as? String,
           !sourceRevision.isEmpty {
            identity["gitRevision"] = sourceRevision
        }
        return identity
    }

    private static func kernelIdentity() -> String {
        var value = utsname()
        guard uname(&value) == 0 else { return "unknown" }
        return withUnsafePointer(to: &value.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

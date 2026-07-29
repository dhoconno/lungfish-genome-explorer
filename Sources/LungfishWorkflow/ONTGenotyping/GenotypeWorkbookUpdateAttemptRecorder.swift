import Darwin
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

public struct GenotypeWorkbookUpdateAttemptRecorder: Sendable {
    private let dateProvider: @Sendable () -> Date
    private let uuidProvider: @Sendable () -> UUID
    private let atomicFileStore: DurableAtomicFileStore

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
                guard Darwin.fsync(currentDescriptor) == 0 else {
                    let code = errno
                    _ = attemptID.withCString {
                        Darwin.unlinkat(
                            currentDescriptor,
                            $0,
                            AT_REMOVEDIR
                        )
                    }
                    throw GenotypeWorkbookUpdateAttemptRecorderError
                        .cannotCreateExclusiveAttempt(
                            currentURL.appendingPathComponent(attemptID).path,
                            code
                        )
                }
                return GenotypeWorkbookUpdateAttemptHandle(
                    attemptID: attemptID,
                    directoryURL: currentURL.appendingPathComponent(
                        attemptID,
                        isDirectory: true
                    ),
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

    private enum State {
        case recording
        case finalized
    }

    private let lock = NSLock()
    private var state: State = .recording
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
        startedAt: Date,
        argv: [String],
        attemptedInputPaths: [String],
        dateProvider: @escaping @Sendable () -> Date,
        atomicFileStore: DurableAtomicFileStore
    ) {
        self.attemptID = attemptID
        self.directoryURL = directoryURL
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
        let snapshot: (
            completedAt: Date,
            attemptedInputPaths: [String],
            resolvedOptions: [String: String],
            runtimeIdentity: [String: String],
            inputs: [ProvenanceFileDescriptor],
            outputs: [ProvenanceFileDescriptor]
        ) = try lock.withLock {
            guard state == .recording else {
                throw GenotypeWorkbookUpdateAttemptRecorderError
                    .attemptAlreadyFinalized(attemptID)
            }
            state = .finalized
            return (
                completedAt ?? dateProvider(),
                attemptedInputPaths,
                resolvedOptions,
                runtimeIdentity,
                inputs.sorted { $0.path < $1.path },
                outputs.sorted { $0.path < $1.path }
            )
        }
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
        let receiptURL = try atomicFileStore.create(
            try ProvenanceJSON.encoder.encode(receipt),
            named: "receipt.json",
            in: directoryURL
        )
        let receiptDescriptor = try ProvenanceFileDescriptor.file(
            url: receiptURL,
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
            in: directoryURL
        )
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

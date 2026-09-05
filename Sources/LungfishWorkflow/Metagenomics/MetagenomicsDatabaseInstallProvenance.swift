import CryptoKit
import Darwin
import Foundation

public struct MetagenomicsDatabasePayloadSnapshot: Sendable, Equatable {
    public let rootURL: URL
    public let files: [ProvenanceFileDescriptor]
    public let aggregateSHA256: String
    public let totalSizeBytes: UInt64

    public init(
        rootURL: URL,
        files: [ProvenanceFileDescriptor],
        aggregateSHA256: String,
        totalSizeBytes: UInt64
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.files = files
        self.aggregateSHA256 = aggregateSHA256
        self.totalSizeBytes = totalSizeBytes
    }
}

public enum MetagenomicsDatabasePayloadDigestError: Error, Sendable, Equatable {
    case unsafePayload(path: String)
}

public enum MetagenomicsDatabaseInstallProvenanceError: Error, LocalizedError, Sendable, Equatable {
    case incompleteFileDescriptor(path: String)
    case expectedArchiveIdentityUnavailable(String)
    case archiveChecksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .incompleteFileDescriptor(let path): return "Incomplete provenance identity for \(path)."
        case .expectedArchiveIdentityUnavailable(let id): return "Pinned database '\(id)' has no received archive identity to verify."
        case .archiveChecksumMismatch(let expected, let actual): return "Database archive checksum mismatch: expected \(expected), received \(actual)."
        }
    }
}

public enum MetagenomicsDatabasePayloadDigester {
    public static func snapshot(at rootURL: URL) throws -> MetagenomicsDatabasePayloadSnapshot {
        try snapshot(at: rootURL, excludingTransactionArtifacts: [])
    }

    fileprivate static func snapshot(
        at rootURL: URL, excludingTransactionArtifacts excluded: Set<URL>
    ) throws -> MetagenomicsDatabasePayloadSnapshot {
        let root = rootURL.standardizedFileURL
        guard fileType(at: root) == .directory else {
            throw MetagenomicsDatabasePayloadDigestError.unsafePayload(path: root.path)
        }

        var entries: [(relativePath: String, url: URL)] = []
        try inspect(directory: root, root: root, excluded: excluded, entries: &entries)
        let files = try entries.sorted { $0.relativePath < $1.relativePath }.map { entry in
            ProvenanceFileDescriptor(
                path: entry.relativePath,
                checksumSHA256: try ProvenanceFileHasher.sha256(of: entry.url),
                fileSize: try ProvenanceFileHasher.fileSize(of: entry.url),
                role: .output
            )
        }
        let aggregateLines = files.map { file in
            [file.path, file.checksumSHA256 ?? "", String(file.fileSize ?? 0)]
                .joined(separator: "\t") + "\n"
        }.joined()
        let aggregate = SHA256.hash(data: Data(aggregateLines.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return MetagenomicsDatabasePayloadSnapshot(
            rootURL: root,
            files: files,
            aggregateSHA256: aggregate,
            totalSizeBytes: files.reduce(0) { $0 + ($1.fileSize ?? 0) }
        )
    }

    private static func inspect(
        directory: URL,
        root: URL,
        excluded: Set<URL>,
        entries: inout [(relativePath: String, url: URL)]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        for child in children {
            let standardized = child.standardizedFileURL
            guard isContained(standardized, in: root) else {
                throw MetagenomicsDatabasePayloadDigestError.unsafePayload(path: standardized.path)
            }
            guard let type = fileType(at: standardized), type != .symbolicLink else {
                throw MetagenomicsDatabasePayloadDigestError.unsafePayload(path: standardized.path)
            }
            guard !excluded.contains(standardized),
                  !isTransientOrProvenance(standardized.lastPathComponent) else { continue }
            if type == .directory {
                try inspect(directory: standardized, root: root, excluded: excluded, entries: &entries)
                continue
            }
            guard type == .regular else {
                throw MetagenomicsDatabasePayloadDigestError.unsafePayload(path: standardized.path)
            }
            entries.append((relativePath: relativePath(of: standardized, from: root), url: standardized))
        }
    }

    private enum EntryType { case directory, regular, symbolicLink, other }

    private static func fileType(at url: URL) -> EntryType? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
    }

    private static func isTransientOrProvenance(_ name: String) -> Bool {
        name == ProvenanceWriter.provenanceFilename || name.hasPrefix(".install-")
    }
}

public struct MetagenomicsDatabaseInstallStepEvidence: Sendable, Equatable {
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let durableReplayArgv: [String]
    public let resolvedOptions: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let inputs: [ProvenanceFileDescriptor]
    public let outputs: [ProvenanceFileDescriptor]
    public let exitStatus: Int32
    public let startedAt: Date
    public let completedAt: Date
    public let stderr: String

    public init(
        toolName: String,
        toolVersion: String,
        argv: [String],
        durableReplayArgv: [String],
        resolvedOptions: [String: ParameterValue],
        runtimeIdentity: ProvenanceRuntimeIdentity,
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        exitStatus: Int32,
        startedAt: Date,
        completedAt: Date,
        stderr: String
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.stderr = stderr
    }
}

public struct MetagenomicsDatabaseInstallAttempt: Sendable {
    public let database: MetagenomicsDatabaseInfo
    public let finalURL: URL
    public let recipeSource: String
    public let explicitOptions: [String: ParameterValue]
    public let defaultOptions: [String: ParameterValue]
    public let resolvedOptions: [String: ParameterValue]
    public let steps: [MetagenomicsDatabaseInstallStepEvidence]
    public let startedAt: Date
    public let completedAt: Date

    public init(
        database: MetagenomicsDatabaseInfo,
        finalURL: URL,
        recipeSource: String,
        explicitOptions: [String: ParameterValue],
        defaultOptions: [String: ParameterValue],
        resolvedOptions: [String: ParameterValue],
        steps: [MetagenomicsDatabaseInstallStepEvidence],
        startedAt: Date,
        completedAt: Date
    ) {
        self.database = database
        self.finalURL = finalURL.standardizedFileURL
        self.recipeSource = recipeSource
        self.explicitOptions = explicitOptions
        self.defaultOptions = defaultOptions
        self.resolvedOptions = resolvedOptions
        self.steps = steps
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum MetagenomicsDatabaseInstallFailure: Error, Sendable, Equatable {
    case failed(exitStatus: Int32, message: String, stderr: String)
    case cancelled(message: String, stderr: String)

    public var provenanceExitStatus: Int32 {
        switch self {
        case .failed(let status, _, _): return status == 0 ? 1 : status
        case .cancelled: return 130
        }
    }

    fileprivate var message: String {
        switch self {
        case .failed(_, let message, _), .cancelled(let message, _): return message
        }
    }

    fileprivate var stderr: String {
        switch self {
        case .failed(_, _, let stderr), .cancelled(_, let stderr): return stderr
        }
    }
}

public protocol MetagenomicsDatabaseInstallProvenanceWriting: Sendable {
    func writeSuccess(_ attempt: MetagenomicsDatabaseInstallAttempt, snapshot: MetagenomicsDatabasePayloadSnapshot) throws
    func writeFailure(_ attempt: MetagenomicsDatabaseInstallAttempt, error: MetagenomicsDatabaseInstallFailure, historyDirectory: URL) throws
}

public struct CanonicalMetagenomicsDatabaseInstallProvenanceWriter: MetagenomicsDatabaseInstallProvenanceWriting, Sendable {
    private let manifest: ManagedToolLock
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    public init(
        manifest: ManagedToolLock = .bundled,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.manifest = manifest
        self.now = now
        self.uuid = uuid
    }

    public func writeSuccess(
        _ attempt: MetagenomicsDatabaseInstallAttempt,
        snapshot: MetagenomicsDatabasePayloadSnapshot
    ) throws {
        try writeSuccess(attempt, snapshot: snapshot, to: attempt.finalURL)
    }

    /// Write physically into a prepared staging directory while every payload path
    /// in the envelope refers to the intended final destination.
    func writeSuccess(
        _ attempt: MetagenomicsDatabaseInstallAttempt,
        snapshot: MetagenomicsDatabasePayloadSnapshot,
        to publicationDirectory: URL
    ) throws {
        try validateSuccessDescriptors(attempt, snapshot: snapshot)
        let envelope = makeSuccessEnvelope(attempt, snapshot: snapshot)
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: publicationDirectory)
    }

    public func writeFailure(
        _ attempt: MetagenomicsDatabaseInstallAttempt,
        error: MetagenomicsDatabaseInstallFailure,
        historyDirectory: URL
    ) throws {
        let catalogDirectory = historyDirectory
            .standardizedFileURL
            .appendingPathComponent(safeCatalogSlug(for: attempt.database), isDirectory: true)
        let date = Self.historyDateString(now())
        let receiptID = uuid()
        let filename = "\(date)-\(receiptID.uuidString).lungfish-provenance.json"
        let destination = catalogDirectory.appendingPathComponent(filename)
        _ = try ProvenanceWriter(signingProvider: nil).writeNew(
            makeFailureEnvelope(attempt, error: error, id: receiptID),
            toSidecar: destination
        )
    }

    public func makeSuccessEnvelope(
        _ attempt: MetagenomicsDatabaseInstallAttempt,
        snapshot: MetagenomicsDatabasePayloadSnapshot
    ) -> ProvenanceEnvelope {
        let final = attempt.finalURL.standardizedFileURL
        let outputFiles = snapshot.files.map { descriptor in
            rehydrate(descriptor, stagingRoot: snapshot.rootURL, finalRoot: final).withRole(.output)
        }
        let inputFiles = deduplicated(
            attempt.steps.flatMap(\.inputs).map {
                rehydrate($0, stagingRoot: snapshot.rootURL, finalRoot: final)
            }
        )
        let canonicalFiles = deduplicated(inputFiles + outputFiles)
        let firstStep = attempt.steps.first
        let argv = rehydrate(firstStep?.argv ?? [], stagingRoot: snapshot.rootURL, finalRoot: final)
        let durable = rehydrate(firstStep?.durableReplayArgv ?? [], stagingRoot: snapshot.rootURL, finalRoot: final)
        var resolved = rehydrate(attempt.resolvedOptions, stagingRoot: snapshot.rootURL, finalRoot: final)
        resolved["recipeSource"] = .string(rehydrate(attempt.recipeSource, stagingRoot: snapshot.rootURL, finalRoot: final))
        resolved["intendedFinalPath"] = .string(final.path)
        resolved["payloadAggregateSHA256"] = .string(snapshot.aggregateSHA256)
        resolved["payloadTotalSizeBytes"] = .integer(Int(clamping: snapshot.totalSizeBytes))
        switch attempt.database.installationRecipe {
        case .archive(let source):
            let spec = attempt.database.catalogID.flatMap { manifest.database(id: $0) }
            // A stale or custom source must not inherit the current catalog's pin.
            let matchingSpec = spec?.url == source.absoluteString ? spec : nil
            let policy = matchingSpec?.effectiveSourcePolicy ?? .unpinnedArchive
            resolved["databaseSourcePolicy"] = .string(policy.rawValue)
            resolved["requestedSourceURL"] = .string(source.absoluteString)
            resolved["requestedCatalogVersion"] = .string(attempt.database.version ?? "unspecified")
            resolved["retrievedAt"] = .string(ISO8601DateFormatter().string(from: attempt.completedAt))
            resolved["retrievalTimeBasis"] = .string("workflow-completion upper bound")
            resolved["exactRemoteReconstruction"] = .boolean(policy == .pinnedArchive)
            resolved["retainedPayloadPath"] = .string(final.path)
            if let archive = attempt.steps.flatMap(\.inputs).first {
                resolved["receivedArchiveSHA256"] = archive.checksumSHA256.map(ParameterValue.string)
                resolved["receivedArchiveSizeBytes"] = archive.fileSize.map { .integer(Int(clamping: $0)) }
                resolved["archiveIdentityStatus"] = .string("received")
            } else {
                resolved["archiveIdentityStatus"] = .string("unavailable")
            }
        case .kraken2Special:
            resolved["databaseSourcePolicy"] = .string(DatabaseSourcePolicy.localBuild.rawValue)
            resolved["retainedPayloadPath"] = .string(final.path)
        case nil:
            resolved["databaseSourcePolicy"] = .string("userProvided")
        }
        return ProvenanceEnvelope(
            id: uuid(),
            createdAt: now(),
            workflowName: "metagenomics.database.install",
            workflowVersion: attempt.database.version ?? "unknown",
            toolName: firstStep?.toolName ?? attempt.database.tool,
            toolVersion: firstStep?.toolVersion ?? "unknown",
            argv: argv,
            durableReplayArgv: durable,
            options: ProvenanceOptions(
                explicit: rehydrate(attempt.explicitOptions, stagingRoot: snapshot.rootURL, finalRoot: final),
                defaults: rehydrate(attempt.defaultOptions, stagingRoot: snapshot.rootURL, finalRoot: final),
                resolvedDefaults: resolved
            ),
            runtimeIdentity: firstStep?.runtimeIdentity ?? ProvenanceRuntimeIdentity(),
            files: canonicalFiles,
            output: outputFiles.first,
            outputs: outputFiles,
            steps: attempt.steps.map { successStep($0, stagingRoot: snapshot.rootURL, finalRoot: final) },
            wallTimeSeconds: max(0, attempt.completedAt.timeIntervalSince(attempt.startedAt)),
            exitStatus: 0,
            stderr: ProvenanceStderr.normalized(firstStep?.stderr)
        )
    }

    public func makeFailureEnvelope(
        _ attempt: MetagenomicsDatabaseInstallAttempt,
        error: MetagenomicsDatabaseInstallFailure
    ) -> ProvenanceEnvelope {
        makeFailureEnvelope(attempt, error: error, id: uuid())
    }

    private func makeFailureEnvelope(
        _ attempt: MetagenomicsDatabaseInstallAttempt,
        error: MetagenomicsDatabaseInstallFailure,
        id: UUID
    ) -> ProvenanceEnvelope {
        let final = attempt.finalURL.standardizedFileURL
        let firstStep = attempt.steps.first
        var resolved = attempt.resolvedOptions
        resolved["recipeSource"] = .string(attempt.recipeSource)
        resolved["intendedFinalPath"] = .string(final.path)
        resolved["failureMessage"] = .string(error.message)
        return ProvenanceEnvelope(
            id: id,
            createdAt: now(),
            workflowName: "metagenomics.database.install",
            workflowVersion: attempt.database.version ?? "unknown",
            toolName: firstStep?.toolName ?? attempt.database.tool,
            toolVersion: firstStep?.toolVersion ?? "unknown",
            argv: firstStep?.argv ?? [],
            durableReplayArgv: firstStep?.durableReplayArgv ?? [],
            options: ProvenanceOptions(
                explicit: attempt.explicitOptions,
                defaults: attempt.defaultOptions,
                resolvedDefaults: resolved
            ),
            runtimeIdentity: firstStep?.runtimeIdentity ?? ProvenanceRuntimeIdentity(),
            files: deduplicated(attempt.steps.flatMap(\.inputs).map(failureInputDescriptor)),
            output: nil,
            outputs: [],
            steps: attempt.steps.map(failureStep),
            wallTimeSeconds: max(0, attempt.completedAt.timeIntervalSince(attempt.startedAt)),
            exitStatus: Int(error.provenanceExitStatus),
            stderr: ProvenanceStderr.normalized(error.stderr)
        )
    }

    private func successStep(
        _ evidence: MetagenomicsDatabaseInstallStepEvidence,
        stagingRoot: URL,
        finalRoot: URL
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: evidence.toolName,
            toolVersion: evidence.toolVersion,
            argv: rehydrate(evidence.argv, stagingRoot: stagingRoot, finalRoot: finalRoot),
            durableReplayArgv: rehydrate(evidence.durableReplayArgv, stagingRoot: stagingRoot, finalRoot: finalRoot),
            resolvedOptions: rehydrate(evidence.resolvedOptions, stagingRoot: stagingRoot, finalRoot: finalRoot),
            runtimeIdentity: evidence.runtimeIdentity,
            inputs: evidence.inputs.map { rehydrate($0, stagingRoot: stagingRoot, finalRoot: finalRoot) },
            outputs: evidence.outputs.map { rehydrate($0, stagingRoot: stagingRoot, finalRoot: finalRoot).withRole(.output) },
            exitStatus: Int(evidence.exitStatus),
            wallTimeSeconds: max(0, evidence.completedAt.timeIntervalSince(evidence.startedAt)),
            stderr: ProvenanceStderr.normalized(evidence.stderr),
            startedAt: evidence.startedAt,
            completedAt: evidence.completedAt
        )
    }

    private func failureStep(_ evidence: MetagenomicsDatabaseInstallStepEvidence) -> ProvenanceStep {
        ProvenanceStep(
            toolName: evidence.toolName,
            toolVersion: evidence.toolVersion,
            argv: evidence.argv,
            durableReplayArgv: evidence.durableReplayArgv,
            resolvedOptions: evidence.resolvedOptions,
            runtimeIdentity: evidence.runtimeIdentity,
            inputs: evidence.inputs.map(failureInputDescriptor),
            outputs: [],
            exitStatus: Int(evidence.exitStatus),
            wallTimeSeconds: max(0, evidence.completedAt.timeIntervalSince(evidence.startedAt)),
            stderr: ProvenanceStderr.normalized(evidence.stderr),
            startedAt: evidence.startedAt,
            completedAt: evidence.completedAt
        )
    }

    private func rehydrate(
        _ argv: [String],
        stagingRoot: URL?,
        finalRoot: URL
    ) -> [String] {
        argv.map { rehydrate($0, stagingRoot: stagingRoot, finalRoot: finalRoot) }
    }

    private func validateSuccessDescriptors(
        _ attempt: MetagenomicsDatabaseInstallAttempt,
        snapshot: MetagenomicsDatabasePayloadSnapshot
    ) throws {
        if case .archive(let source)? = attempt.database.installationRecipe,
           let catalogID = attempt.database.catalogID, let spec = manifest.database(id: catalogID),
           spec.url == source.absoluteString {
            try spec.validateSourceIdentity()
            if spec.sha256 != nil || spec.md5 != nil {
                guard let archive = attempt.steps.flatMap(\.inputs).first else {
                    throw MetagenomicsDatabaseInstallProvenanceError.expectedArchiveIdentityUnavailable(catalogID)
                }
                let expected = spec.sha256 ?? spec.md5!
                let actual: String
                if spec.sha256 != nil {
                    actual = archive.checksumSHA256 ?? ""
                } else {
                    actual = try MetagenomicsDatabaseRegistry.fileChecksum(URL(fileURLWithPath: archive.path), .md5)
                }
                guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
                    throw MetagenomicsDatabaseInstallProvenanceError.archiveChecksumMismatch(expected: expected, actual: actual)
                }
            }
        }
        let descriptors = snapshot.files + attempt.steps.flatMap { $0.inputs + $0.outputs }
        for descriptor in descriptors {
            guard descriptor.checksumSHA256?.isEmpty == false, descriptor.fileSize != nil else {
                throw MetagenomicsDatabaseInstallProvenanceError.incompleteFileDescriptor(path: descriptor.path)
            }
        }
    }

    private func failureInputDescriptor(
        _ descriptor: ProvenanceFileDescriptor
    ) -> ProvenanceFileDescriptor {
        descriptor.role == .output ? descriptor.withRole(.input) : descriptor
    }

    private func deduplicated(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var keys = Set<String>()
        return descriptors.filter { descriptor in
            keys.insert("\(descriptor.role.rawValue)\u{0}\(descriptor.path)").inserted
        }
    }

    private func rehydrate(
        _ value: String,
        stagingRoot: URL?,
        finalRoot: URL
    ) -> String {
        guard let stagingRoot else { return value }
        return value.replacingOccurrences(of: stagingRoot.standardizedFileURL.path, with: finalRoot.path)
    }

    private func rehydrate(
        _ values: [String: ParameterValue],
        stagingRoot: URL?,
        finalRoot: URL
    ) -> [String: ParameterValue] {
        values.mapValues { rehydrate($0, stagingRoot: stagingRoot, finalRoot: finalRoot) }
    }

    private func rehydrate(
        _ value: ParameterValue,
        stagingRoot: URL?,
        finalRoot: URL
    ) -> ParameterValue {
        switch value {
        case .string(let string): return .string(rehydrate(string, stagingRoot: stagingRoot, finalRoot: finalRoot))
        case .file(let url):
            return .file(URL(fileURLWithPath: rehydrate(url.path, stagingRoot: stagingRoot, finalRoot: finalRoot)))
        case .array(let values): return .array(values.map { rehydrate($0, stagingRoot: stagingRoot, finalRoot: finalRoot) })
        case .dictionary(let values): return .dictionary(rehydrate(values, stagingRoot: stagingRoot, finalRoot: finalRoot))
        default: return value
        }
    }

    private func rehydrate(
        _ descriptor: ProvenanceFileDescriptor,
        stagingRoot: URL?,
        finalRoot: URL
    ) -> ProvenanceFileDescriptor {
        let path: String
        if descriptor.path.hasPrefix("/"), let stagingRoot {
            path = rehydrate(descriptor.path, stagingRoot: stagingRoot, finalRoot: finalRoot)
        } else {
            path = finalRoot.appendingPathComponent(descriptor.path).path
        }
        return ProvenanceFileDescriptor(
            path: path,
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath.map { rehydrate($0, stagingRoot: stagingRoot, finalRoot: finalRoot) },
            sourceProvenancePath: descriptor.sourceProvenancePath.map { rehydrate($0, stagingRoot: stagingRoot, finalRoot: finalRoot) }
        )
    }

    private func safeCatalogSlug(for database: MetagenomicsDatabaseInfo) -> String {
        let source = database.catalogID ?? database.name
        let slug = source.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        let normalized = String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "database-install" : normalized
    }

    private static func historyDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}


public enum MetagenomicsDatabaseIdentityError: Error, LocalizedError, Sendable {
    case unbound(String)
    case changed(String)

    public var errorDescription: String? {
        switch self {
        case .unbound(let name):
            return "Database '\(name)' has no bound canonical receipt and payload identity; reinstall or update it before conformance."
        case .changed(let name):
            return "Database '\(name)' receipt or retained payload differs from its recorded identity."
        }
    }
}

/// Compact evidence for the exact database snapshot used by a conformance run.
/// Verification is explicit and may hash a large payload; it is never a UI refresh.
public struct MetagenomicsDatabaseConformanceIdentity: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let databaseName: String
    public let catalogID: String?
    public let catalogVersion: String?
    public let installedVersion: String?
    public let path: String
    public let canonicalReceiptSHA256: String
    public let payloadAggregateSHA256: String
    public let sourcePolicy: String
    public let requestedSourceURL: String?
    public let receivedArchiveSHA256: String?
    public let retrievedAt: String?

    public static func verify(_ database: MetagenomicsDatabaseInfo) throws -> Self {
        try verify(database, readingPayloadAt: nil)
    }

    /// A relocation validates bytes at the new physical location against the
    /// original row and original receipt paths before any metadata is rewritten.
    static func verify(
        _ database: MetagenomicsDatabaseInfo, readingPayloadAt physicalRoot: URL?,
        publication: ScientificFilePublicationTransaction? = nil
    ) throws -> Self {
        guard database.status == .ready, let path = database.path?.standardizedFileURL,
              let expectedReceipt = database.canonicalReceiptSHA256,
              let expectedPayload = database.payloadDigest else {
            throw MetagenomicsDatabaseIdentityError.unbound(database.name)
        }
        let payloadRoot = physicalRoot?.standardizedFileURL ?? path
        let sidecar = payloadRoot.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let receiptBytes = try Data(contentsOf: sidecar)
        let receiptDigest = SHA256.hash(data: receiptBytes).map { String(format: "%02x", $0) }.joined()
        guard receiptDigest == expectedReceipt else { throw MetagenomicsDatabaseIdentityError.changed(database.name) }
        let receipt = try ProvenanceEnvelopeReader.decodeCanonical(receiptBytes)
        let options = receipt.options.resolvedDefaults
        guard receipt.workflowName == "metagenomics.database.install", receipt.exitStatus == 0,
              options["payloadAggregateSHA256"]?.stringValue == expectedPayload,
              options["intendedFinalPath"]?.stringValue == path.path,
              let policy = options["databaseSourcePolicy"]?.stringValue else {
            throw MetagenomicsDatabaseIdentityError.changed(database.name)
        }
        let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: payloadRoot,
            excludingTransactionArtifacts: Set(publication?.displacedArtifactURLs.map(\.standardizedFileURL) ?? []))
        guard snapshot.aggregateSHA256 == expectedPayload,
              receipt.outputs.count == snapshot.files.count else {
            throw MetagenomicsDatabaseIdentityError.changed(database.name)
        }
        var recordedOutputs: [String: ProvenanceFileDescriptor] = [:]
        for output in receipt.outputs {
            guard recordedOutputs.updateValue(output, forKey: output.path) == nil else {
                throw MetagenomicsDatabaseIdentityError.changed(database.name)
            }
        }
        for file in snapshot.files {
            let finalPath = path.appendingPathComponent(file.path).path
            guard let output = recordedOutputs[finalPath], output.checksumSHA256 == file.checksumSHA256,
                  output.fileSize == file.fileSize else {
                throw MetagenomicsDatabaseIdentityError.changed(database.name)
            }
        }
        return Self(schemaVersion: 1, databaseName: database.name, catalogID: database.catalogID,
            catalogVersion: options["requestedCatalogVersion"]?.stringValue ?? receipt.workflowVersion,
            installedVersion: database.version, path: path.path, canonicalReceiptSHA256: receiptDigest,
            payloadAggregateSHA256: snapshot.aggregateSHA256, sourcePolicy: policy,
            requestedSourceURL: options["requestedSourceURL"]?.stringValue,
            receivedArchiveSHA256: options["receivedArchiveSHA256"]?.stringValue,
            retrievedAt: options["retrievedAt"]?.stringValue)
    }

    public func evidenceJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}


extension CanonicalMetagenomicsDatabaseInstallProvenanceWriter {
    /// Preserve the original installation history and append the metadata
    /// relocation actually performed by the registry.
    static func appendingRelocation(
        to envelope: ProvenanceEnvelope, databaseName: String, from source: URL, to destination: URL,
        previousReceipt: ProvenanceFileDescriptor, startedAt: Date
    ) -> ProvenanceEnvelope {
        let completedAt = Date()
        let step = ProvenanceStep(
            toolName: "Lungfish database relocation", toolVersion: WorkflowRun.currentAppVersion,
            argv: ["MetagenomicsDatabaseRegistry.relocateDatabase(name:to:)", databaseName, destination.path],
            resolvedOptions: ["invocationKind": .string("swift-api"), "relocatedFrom": .file(source),
                "relocatedTo": .file(destination), "previousCanonicalReceiptSHA256": .string(previousReceipt.checksumSHA256 ?? "")],
            runtimeIdentity: .init(), inputs: [previousReceipt], outputs: envelope.outputs,
            exitStatus: 0, wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt, completedAt: completedAt
        )
        return ProvenanceEnvelope(schemaVersion: envelope.schemaVersion, id: envelope.id, createdAt: envelope.createdAt,
            workflowName: envelope.workflowName, workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName, toolVersion: envelope.toolVersion, githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool, argv: envelope.argv, durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand, options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity, files: envelope.files + [previousReceipt],
            output: envelope.output, outputs: envelope.outputs, steps: envelope.steps + [step],
            wallTimeSeconds: (envelope.wallTimeSeconds ?? 0) + completedAt.timeIntervalSince(startedAt),
            exitStatus: envelope.exitStatus, stderr: envelope.stderr, signatures: [], legacyWorkflowRun: nil)
    }
}

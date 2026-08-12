import Darwin
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3

private let mappingViewerSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MappingViewerBundlePublicationError: Error, LocalizedError {
    case missingCanonicalProvenance(URL)
    case missingViewerBundle(URL)
    case invalidViewerPayloadPath(String)
    case missingViewerPayload(URL)
    case invalidCandidateLocation(URL, URL)
    case unsafePublicationRoot(String)
    case atomicPublicationFailed(URL, URL, String)
    case concurrentSidecarChanges([String])
    case publicationOwnershipConflict(String, String?)
    case rollbackFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .missingCanonicalProvenance(let url):
            return "Canonical mapping provenance is missing at \(url.path)."
        case .missingViewerBundle(let url):
            return "The prepared mapping viewer bundle is missing at \(url.path)."
        case .invalidViewerPayloadPath(let path):
            return "The mapping viewer bundle declares an unsafe payload path: \(path)."
        case .missingViewerPayload(let url):
            return "The mapping viewer bundle payload is missing at \(url.path)."
        case .invalidCandidateLocation(let candidate, let final):
            return "The mapping viewer candidate \(candidate.path) must be adjacent to its final bundle \(final.path)."
        case .unsafePublicationRoot(let path):
            return "The mapping viewer publication root is not a no-follow directory: \(path)."
        case .atomicPublicationFailed(let candidate, let final, let detail):
            return "Could not atomically publish \(candidate.lastPathComponent) as \(final.lastPathComponent): \(detail)"
        case .concurrentSidecarChanges(let paths):
            return "Mapping viewer rollback preserved newer sidecar generations at: \(paths.joined(separator: ", "))."
        case .publicationOwnershipConflict(let path, let preservedPath):
            let suffix = preservedPath.map { " The displaced original was preserved at \($0)." } ?? ""
            return "The published mapping viewer root was replaced by another filesystem generation at \(path).\(suffix)"
        case .rollbackFailed(let url, let detail):
            return "Could not restore \(url.lastPathComponent) after mapping viewer publication failed: \(detail)"
        }
    }
}

struct MappingViewerBundlePublicationPlan {
    let finalBundleURL: URL
    fileprivate let bundleRoot: MappingViewerSecureBundleRoot
    fileprivate let payloads: [MappingViewerPlannedPayload]
    fileprivate let includesManifest: Bool

    fileprivate func matchesPublishedRoot() -> Bool {
        bundleRoot.matchesNamedRoot(at: finalBundleURL)
    }

    fileprivate func validatedViewerOutputDescriptors() throws -> [ProvenanceFileDescriptor] {
        guard matchesPublishedRoot() else {
            throw MappingViewerBundlePublicationError.publicationOwnershipConflict(finalBundleURL.path, nil)
        }
        guard includesManifest else { return [] }
        return [ProvenanceFileDescriptor(path: finalBundleURL.path, role: .output)]
            + (try payloads.map { try $0.validatedDescriptor(from: bundleRoot) })
    }
}

private struct MappingViewerBundleFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

private struct MappingViewerBundleStableFileState: Equatable {
    let identity: MappingViewerBundleFileIdentity
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
}

private final class MappingViewerPlannedPayload {
    let relativePath: String
    let publishedPath: String
    let format: FileFormat?
    let role: FileRole
    let originPath: String?
    let sourceProvenancePath: String?
    private let descriptor: Int32
    private let identity: MappingViewerBundleFileIdentity

    init(
        relativePath: String,
        publishedPath: String,
        format: FileFormat?,
        role: FileRole,
        originPath: String? = nil,
        sourceProvenancePath: String? = nil,
        bundleRoot: MappingViewerSecureBundleRoot
    ) throws {
        self.relativePath = relativePath
        self.publishedPath = publishedPath
        self.format = format
        self.role = role
        self.originPath = originPath
        self.sourceProvenancePath = sourceProvenancePath
        descriptor = try bundleRoot.openRegularFile(relativePath: relativePath, flags: O_RDONLY)
        identity = try MappingViewerSecureBundleRoot.fileIdentity(descriptor: descriptor)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func validatedDescriptor(
        from bundleRoot: MappingViewerSecureBundleRoot
    ) throws -> ProvenanceFileDescriptor {
        let currentDescriptor = try bundleRoot.openRegularFile(relativePath: relativePath, flags: O_RDONLY)
        defer { Darwin.close(currentDescriptor) }
        guard try MappingViewerSecureBundleRoot.fileIdentity(descriptor: currentDescriptor) == identity else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        let captured = try MappingViewerSecureBundleRoot.stableDigest(descriptor: descriptor)
        return ProvenanceFileDescriptor(
            path: publishedPath,
            checksumSHA256: captured.checksum,
            fileSize: captured.size,
            format: format,
            role: role,
            originPath: originPath,
            sourceProvenancePath: sourceProvenancePath
        )
    }
}

private final class MappingViewerSecureBundleRoot {
    let originalURL: URL
    let descriptor: Int32
    let identity: MappingViewerBundleFileIdentity

    init(url: URL) throws {
        originalURL = url.standardizedFileURL
        descriptor = Darwin.open(originalURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MappingViewerBundlePublicationError.unsafePublicationRoot(originalURL.path)
        }
        do {
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0,
                  information.st_mode & S_IFMT == S_IFDIR else {
                throw MappingViewerBundlePublicationError.unsafePublicationRoot(originalURL.path)
            }
            identity = Self.identity(information)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func matchesNamedRoot(at url: URL) -> Bool {
        var information = stat()
        return url.path.withCString { Darwin.lstat($0, &information) } == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && Self.identity(information) == identity
    }

    func entryExists(relativePath: String) -> Bool {
        guard let components = try? validatedComponents(relativePath), components.count == 1 else {
            return false
        }
        var information = stat()
        return components[0].withCString {
            Darwin.fstatat(descriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        } == 0
    }

    func openRegularFile(relativePath: String, flags: Int32) throws -> Int32 {
        let (parent, name) = try openParent(relativePath: relativePath)
        defer { Darwin.close(parent) }
        let opened = name.withCString {
            Darwin.openat(parent, $0, flags | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        var information = stat()
        guard Darwin.fstat(opened, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(opened)
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        return opened
    }

    func openDirectory(relativePath: String) throws -> Int32 {
        let components = try validatedComponents(relativePath)
        var current = Darwin.dup(descriptor)
        guard current >= 0 else { throw posixFailure(relativePath) }
        do {
            for component in components {
                let next = component.withCString {
                    Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw posixFailure(relativePath) }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    func readData(relativePath: String) throws -> Data {
        let opened = try openRegularFile(relativePath: relativePath, flags: O_RDONLY)
        defer { Darwin.close(opened) }
        return try Self.readAll(descriptor: opened)
    }

    func listNames(in relativeDirectory: String) throws -> [String] {
        let directory = try openDirectory(relativePath: relativeDirectory)
        guard let stream = fdopendir(directory) else {
            Darwin.close(directory)
            throw posixFailure(relativeDirectory)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != "..", !name.hasPrefix(".") {
                names.append(name)
            }
        }
        return names.sorted()
    }

    func replaceFile(relativePath: String, data: Data, namedRootURL: URL) throws {
        guard matchesNamedRoot(at: namedRootURL) else {
            throw MappingViewerBundlePublicationError.publicationOwnershipConflict(namedRootURL.path, nil)
        }
        let (parent, name) = try openParent(relativePath: relativePath)
        defer { Darwin.close(parent) }
        let temporaryName = ".lungfish-rehydrate-\(UUID().uuidString)"
        let temporary = temporaryName.withCString {
            Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard temporary >= 0 else { throw posixFailure(relativePath) }
        var removeTemporary = true
        defer {
            Darwin.close(temporary)
            if removeTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(parent, $0, 0) }
            }
        }
        try Self.writeAll(data, descriptor: temporary)
        guard Darwin.fsync(temporary) == 0,
              matchesNamedRoot(at: namedRootURL) else {
            throw MappingViewerBundlePublicationError.publicationOwnershipConflict(namedRootURL.path, nil)
        }
        let status = temporaryName.withCString { temporaryPath in
            name.withCString { destinationPath in
                Darwin.renameat(parent, temporaryPath, parent, destinationPath)
            }
        }
        guard status == 0 else { throw posixFailure(relativePath) }
        removeTemporary = false
        guard matchesNamedRoot(at: namedRootURL) else {
            throw MappingViewerBundlePublicationError.publicationOwnershipConflict(namedRootURL.path, nil)
        }
    }

    fileprivate static func fileIdentity(descriptor: Int32) throws -> MappingViewerBundleFileIdentity {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return identity(information)
    }

    fileprivate static func stableDigest(descriptor: Int32) throws -> (checksum: String, size: UInt64) {
        let before = try stableState(descriptor: descriptor)
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard count > 0 else { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        let after = try stableState(descriptor: descriptor)
        guard before == after else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath("payload changed while hashing")
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            after.size
        )
    }

    private func openParent(relativePath: String) throws -> (Int32, String) {
        var components = try validatedComponents(relativePath)
        let name = components.removeLast()
        var current = Darwin.dup(descriptor)
        guard current >= 0 else { throw posixFailure(relativePath) }
        do {
            for component in components {
                let next = component.withCString {
                    Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw posixFailure(relativePath) }
                Darwin.close(current)
                current = next
            }
            return (current, name)
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func validatedComponents(_ relativePath: String) throws -> [String] {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        return components
    }

    private static func identity(_ information: stat) -> MappingViewerBundleFileIdentity {
        MappingViewerBundleFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private static func stableState(descriptor: Int32) throws -> MappingViewerBundleStableFileState {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return MappingViewerBundleStableFileState(
            identity: identity(information),
            size: UInt64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(information.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private static func readAll(descriptor: Int32) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard count > 0 else { return result }
            result.append(contentsOf: buffer[0..<count])
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func posixFailure(_ path: String) -> Error {
        MappingViewerBundlePublicationError.invalidViewerPayloadPath(path)
    }
}

enum MappingViewerBundlePublicationService {
    private static let mappingResultFilename = "mapping-result.json"

    static func publishCandidate(
        candidateBundleURL: URL,
        finalBundleURL: URL,
        fileManager: FileManager = .default,
        finalize: (URL) throws -> Void
    ) throws {
        try publishCandidate(
            candidateBundleURL: candidateBundleURL,
            finalBundleURL: finalBundleURL,
            fileManager: fileManager
        ) { publishedURL, _ in
            try finalize(publishedURL)
        }
    }

    static func publishCandidate(
        candidateBundleURL: URL,
        finalBundleURL: URL,
        fileManager: FileManager = .default,
        beforeCandidateRehydration: (() throws -> Void)? = nil,
        finalize: (URL, MappingViewerBundlePublicationPlan) throws -> Void
    ) throws {
        let candidate = candidateBundleURL.standardizedFileURL
        let final = finalBundleURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == final.deletingLastPathComponent(),
              candidate != final else {
            throw MappingViewerBundlePublicationError.invalidCandidateLocation(candidate, final)
        }

        guard try validatePublicationRoot(
            candidate,
            allowMissing: false
        ) else {
            throw MappingViewerBundlePublicationError.missingViewerBundle(candidate)
        }
        let replacingExisting = try validatePublicationRoot(
            final,
            allowMissing: true
        )
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let resolvedFinal = final.resolvingSymlinksInPath()
        guard resolvedCandidate.deletingLastPathComponent()
                == resolvedFinal.deletingLastPathComponent() else {
            throw MappingViewerBundlePublicationError.invalidCandidateLocation(candidate, final)
        }
        let plan = try preparePublicationPlan(
            candidateBundleURL: candidate,
            finalBundleURL: final,
            fileManager: fileManager,
            beforeCandidateRehydration: beforeCandidateRehydration
        )
        guard plan.bundleRoot.matchesNamedRoot(at: candidate) else {
            throw MappingViewerBundlePublicationError.publicationOwnershipConflict(candidate.path, nil)
        }
        try atomicRename(
            candidate,
            final,
            flags: UInt32(replacingExisting ? RENAME_SWAP : RENAME_EXCL)
        )

        do {
            try finalize(final, plan)
            guard plan.matchesPublishedRoot() else {
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(final.path, nil)
            }
            if replacingExisting {
                // Finalization has committed the result sidecars. A cleanup
                // failure must not swap the old viewer back underneath them;
                // retaining the hidden displaced bundle is consistent and the
                // caller's deferred cleanup gets another safe attempt.
                try? fileManager.removeItem(at: candidate)
            }
        } catch {
            let originalError = error
            guard plan.matchesPublishedRoot() else {
                let preservedOriginal = replacingExisting
                    ? try? preserveDisplacedOriginal(at: candidate)
                    : nil
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(
                    final.path,
                    preservedOriginal?.path
                )
            }
            do {
                if replacingExisting {
                    try atomicRename(candidate, final, flags: UInt32(RENAME_SWAP))
                    // The old viewer is restored atomically. Failure to remove
                    // the now-hidden failed candidate does not invalidate that
                    // rollback and must not replace the original error.
                    try? fileManager.removeItem(at: candidate)
                } else if fileManager.fileExists(atPath: final.path) {
                    try fileManager.removeItem(at: final)
                }
            } catch let rollbackError {
                throw MappingViewerBundlePublicationError.rollbackFailed(
                    final,
                    "\(rollbackError.localizedDescription); original error: \(originalError.localizedDescription)"
                )
            }
            throw originalError
        }
    }

    static func publish(
        result: MappingResult,
        resultDirectoryURL: URL,
        sourceReferenceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager = .default,
        beforeRollback: (() throws -> Void)? = nil,
        afterCanonicalRewrite: (() throws -> Void)? = nil,
        viewerPublicationPlan: MappingViewerBundlePublicationPlan? = nil,
        beforePublishedRootRecheck: (() throws -> Void)? = nil
    ) throws {
        let resultDirectory = resultDirectoryURL.standardizedFileURL
        let sourceBundle = sourceReferenceBundleURL.standardizedFileURL
        let viewerBundle = viewerBundleURL.standardizedFileURL
        if let viewerPublicationPlan {
            guard viewerPublicationPlan.finalBundleURL.standardizedFileURL == viewerBundle,
                  viewerPublicationPlan.matchesPublishedRoot() else {
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(viewerBundle.path, nil)
            }
        }
        let mappingResultURL = resultDirectory.appendingPathComponent(mappingResultFilename)
        let mappingProvenanceURL = resultDirectory.appendingPathComponent(MappingProvenance.filename)
        let snapshot = try ProvenancePublicationSnapshot(
            urls: deduplicatedURLs(
                [mappingResultURL, mappingProvenanceURL]
                    + ProvenancePublicationArtifacts.bundleRootArtifacts(for: resultDirectory)
            ),
            backupNamePrefix: "lungfish-mapping-viewer-publication",
            fileManager: fileManager
        )
        defer { snapshot.discard() }
        let tracker = try MappingViewerRollbackWitnessTracker(snapshot: snapshot)
        let stagingDirectory = resultDirectory.appendingPathComponent(
            ".mapping-viewer-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        var displacedURLs: [URL] = []
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            for displacedURL in displacedURLs {
                try? fileManager.removeItem(at: displacedURL)
            }
        }

        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            try result.save(to: stagingDirectory)
            let mappingResultPublication = try snapshot.publishReplacement(
                from: stagingDirectory.appendingPathComponent(mappingResultFilename),
                to: mappingResultURL,
                replacingExisting: fileManager.fileExists(atPath: mappingResultURL.path),
                witness: tracker.currentWitness
            )
            tracker.replaceWitness(mappingResultPublication.witness)
            if let displacedURL = mappingResultPublication.displacedURL {
                displacedURLs.append(displacedURL)
            }
            if let provenance = MappingProvenance.load(from: resultDirectory) {
                try provenance
                    .withViewerBundleURL(viewerBundle)
                    .withSourceReferenceBundleURL(sourceBundle)
                    .save(to: stagingDirectory)
                let mappingProvenancePublication = try snapshot.publishReplacement(
                    from: stagingDirectory.appendingPathComponent(MappingProvenance.filename),
                    to: mappingProvenanceURL,
                    replacingExisting: true,
                    witness: tracker.currentWitness
                )
                tracker.replaceWitness(mappingProvenancePublication.witness)
                if let displacedURL = mappingProvenancePublication.displacedURL {
                    displacedURLs.append(displacedURL)
                }
            }
            try rewriteCanonicalProvenance(
                result: result,
                resultDirectoryURL: resultDirectory,
                sourceReferenceBundleURL: sourceBundle,
                viewerBundleURL: viewerBundle,
                fileManager: fileManager,
                viewerPublicationPlan: viewerPublicationPlan,
                writer: ProvenanceWriter(
                    publicationMutationDidOccur: tracker.observe,
                    signingProvider: nil
                )
            )
            try afterCanonicalRewrite?()
            try beforePublishedRootRecheck?()
            if let viewerPublicationPlan,
               !viewerPublicationPlan.matchesPublishedRoot() {
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(viewerBundle.path, nil)
            }
        } catch {
            do {
                try beforeRollback?()
                let preserved = try snapshot.restore(ifCurrentMatches: tracker.currentWitness)
                guard preserved.isEmpty else {
                    throw MappingViewerBundlePublicationError.concurrentSidecarChanges(
                        preserved.map(\.path)
                    )
                }
            } catch let rollbackError {
                if let concurrencyError = rollbackError as? MappingViewerBundlePublicationError,
                   case .concurrentSidecarChanges = concurrencyError {
                    throw concurrencyError
                }
                throw MappingViewerBundlePublicationError.rollbackFailed(
                    resultDirectory,
                    rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private static func rewriteCanonicalProvenance(
        result: MappingResult,
        resultDirectoryURL: URL,
        sourceReferenceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager,
        viewerPublicationPlan: MappingViewerBundlePublicationPlan?,
        writer: ProvenanceWriter
    ) throws {
        let publicationStartedAt = Date()
        let canonicalURL = resultDirectoryURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        guard let envelope = try ProvenanceEnvelopeReader.load(from: resultDirectoryURL) else {
            throw MappingViewerBundlePublicationError.missingCanonicalProvenance(canonicalURL)
        }
        if viewerPublicationPlan == nil {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: viewerBundleURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MappingViewerBundlePublicationError.missingViewerBundle(viewerBundleURL)
            }
        }

        let mappingResultURL = resultDirectoryURL.appendingPathComponent(mappingResultFilename)
        let mappingResultDescriptor = try ProvenanceFileDescriptor.file(
            url: mappingResultURL,
            format: .json,
            role: .output
        )
        let mappingProvenanceURL = resultDirectoryURL.appendingPathComponent(MappingProvenance.filename)
        let mappingProvenanceDescriptor = fileManager.fileExists(atPath: mappingProvenanceURL.path)
            ? try ProvenanceFileDescriptor.file(
                url: mappingProvenanceURL,
                format: .json,
                role: .output
            )
            : nil
        let refreshedFiles = try envelope.files
            .filter { $0.path != canonicalURL.path }
            .map {
                try refreshedPublicationSidecarDescriptor(
                    $0,
                    mappingResultURL: mappingResultURL,
                    mappingProvenanceURL: mappingProvenanceURL
                )
            }
        let refreshedOutputs = try envelope.outputs
            .filter { $0.path != canonicalURL.path }
            .map {
                try refreshedPublicationSidecarDescriptor(
                    $0,
                    mappingResultURL: mappingResultURL,
                    mappingProvenanceURL: mappingProvenanceURL
                )
            }
        let refreshedPrimaryOutput: ProvenanceFileDescriptor? = try envelope.output.flatMap { descriptor in
            guard descriptor.path != canonicalURL.path else { return nil }
            return try refreshedPublicationSidecarDescriptor(
                descriptor,
                mappingResultURL: mappingResultURL,
                mappingProvenanceURL: mappingProvenanceURL
            )
        }
        let refreshedSteps = try envelope.steps.map { step in
            ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: step.argv,
                durableReplayArgv: step.durableReplayArgv,
                reproducibleCommand: step.reproducibleCommand,
                resolvedOptions: step.resolvedOptions,
                runtimeIdentity: step.runtimeIdentity,
                inputs: step.inputs,
                outputs: try step.outputs
                    .filter { $0.path != canonicalURL.path }
                    .map {
                        try refreshedPublicationSidecarDescriptor(
                            $0,
                            mappingResultURL: mappingResultURL,
                            mappingProvenanceURL: mappingProvenanceURL
                        )
                },
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }

        let argv = [
            "Lungfish.app",
            "prepare-mapping-viewer-bundle",
            "--mapping-result", resultDirectoryURL.path,
            "--source-reference-bundle", sourceReferenceBundleURL.path,
            "--viewer-bundle", viewerBundleURL.path,
        ]
        let inputs = try sourceInputDescriptors(
            sourceBundleURL: sourceReferenceBundleURL,
            fileManager: fileManager
        ) + [
            try ProvenanceFileDescriptor.file(url: result.bamURL, format: .bam, role: .input),
            try ProvenanceFileDescriptor.file(url: result.baiURL, format: .unknown, role: .index),
        ]
        let viewerDescriptors = try viewerPublicationPlan?.validatedViewerOutputDescriptors()
            ?? viewerOutputDescriptors(
                viewerBundleURL: viewerBundleURL,
                fileManager: fileManager
            )
        let publicationOutputs = deduplicated(
            [mappingResultDescriptor] + [mappingProvenanceDescriptor].compactMap { $0 } + viewerDescriptors
        )
        let publicationCompletedAt = Date()
        let publicationStep = ProvenanceStep(
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            resolvedOptions: [
                "mappingResult": .file(resultDirectoryURL),
                "sourceReferenceBundle": .file(sourceReferenceBundleURL),
                "viewerBundle": .file(viewerBundleURL),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: inputs,
            outputs: publicationOutputs,
            exitStatus: 0,
            wallTimeSeconds: publicationCompletedAt.timeIntervalSince(publicationStartedAt),
            dependsOn: refreshedSteps.last.map { [$0.id] } ?? [],
            startedAt: publicationStartedAt,
            completedAt: publicationCompletedAt
        )
        let updatedOptions = ProvenanceOptions(
            explicit: envelope.options.explicit,
            defaults: envelope.options.defaults,
            resolvedDefaults: envelope.options.resolvedDefaults.merging([
                "sourceReferenceBundle": .file(sourceReferenceBundleURL),
                "viewerBundle": .file(viewerBundleURL),
            ]) { _, finalValue in finalValue }
        )
        let updatedEnvelope = ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: updatedOptions,
            runtimeIdentity: envelope.runtimeIdentity,
            files: deduplicated(refreshedFiles + inputs + publicationOutputs),
            output: refreshedPrimaryOutput,
            outputs: deduplicated(refreshedOutputs + publicationOutputs),
            steps: refreshedSteps + [publicationStep],
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )

        try writer.write(updatedEnvelope, to: resultDirectoryURL)
    }

    private static func validatePublicationRoot(
        _ url: URL,
        allowMissing: Bool
    ) throws -> Bool {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status != 0 {
            if errno == ENOENT, allowMissing {
                return false
            }
            if errno == ENOENT {
                return false
            }
            throw MappingViewerBundlePublicationError.atomicPublicationFailed(
                url,
                url,
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw MappingViewerBundlePublicationError.unsafePublicationRoot(url.path)
        }
        let resolvedRoot = url.resolvingSymlinksInPath()
        let expectedRoot = url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)
        guard resolvedRoot == expectedRoot else {
            throw MappingViewerBundlePublicationError.unsafePublicationRoot(url.path)
        }
        return true
    }

    private static func preparePublicationPlan(
        candidateBundleURL: URL,
        finalBundleURL: URL,
        fileManager: FileManager,
        beforeCandidateRehydration: (() throws -> Void)?
    ) throws -> MappingViewerBundlePublicationPlan {
        let bundleRoot = try MappingViewerSecureBundleRoot(url: candidateBundleURL)
        try beforeCandidateRehydration?()
        guard bundleRoot.matchesNamedRoot(at: candidateBundleURL) else {
            throw MappingViewerBundlePublicationError.publicationOwnershipConflict(candidateBundleURL.path, nil)
        }
        try rehydrateImportedBAMProvenance(
            in: bundleRoot,
            replacingRoot: candidateBundleURL,
            with: finalBundleURL,
            namedRootURL: candidateBundleURL
        )
        let includesManifest: Bool
        let payloads: [MappingViewerPlannedPayload]
        if bundleRoot.entryExists(relativePath: BundleManifest.filename) {
            let manifestData = try bundleRoot.readData(relativePath: BundleManifest.filename)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(BundleManifest.self, from: manifestData)
            includesManifest = true
            payloads = try plannedPayloads(
                manifest: manifest,
                bundleRoot: bundleRoot,
                finalBundleURL: finalBundleURL
            )
        } else {
            includesManifest = false
            payloads = []
        }
        return MappingViewerBundlePublicationPlan(
            finalBundleURL: finalBundleURL,
            bundleRoot: bundleRoot,
            payloads: payloads,
            includesManifest: includesManifest
        )
    }

    private static func plannedPayloads(
        manifest: BundleManifest,
        bundleRoot: MappingViewerSecureBundleRoot,
        finalBundleURL: URL
    ) throws -> [MappingViewerPlannedPayload] {
        var specifications: [(String, FileFormat?, FileRole)] = [
            (BundleManifest.filename, .json, .output)
        ]
        if let genome = manifest.genome {
            specifications.append((genome.path, .fasta, .output))
            if !genome.indexPath.isEmpty { specifications.append((genome.indexPath, .unknown, .index)) }
            if let path = genome.gzipIndexPath, !path.isEmpty { specifications.append((path, .unknown, .index)) }
        }
        for annotation in manifest.annotations {
            specifications.append((annotation.path, .bigBed, .output))
            if let path = annotation.databasePath, !path.isEmpty { specifications.append((path, .sqlite, .output)) }
        }
        for variant in manifest.variants {
            specifications.append((variant.path, variantFormat(for: variant.path), .output))
            if !variant.indexPath.isEmpty { specifications.append((variant.indexPath, .unknown, .index)) }
            if let path = variant.databasePath, !path.isEmpty { specifications.append((path, .sqlite, .output)) }
        }
        for track in manifest.tracks { specifications.append((track.path, .bigWig, .output)) }
        for track in manifest.alignments {
            specifications.append((track.sourcePath, track.format == .cram ? .cram : .bam, .output))
            if !track.indexPath.isEmpty { specifications.append((track.indexPath, .unknown, .index)) }
            if let path = track.metadataDBPath, !path.isEmpty { specifications.append((path, .sqlite, .output)) }
        }
        if let names = try? bundleRoot.listNames(in: "alignments") {
            specifications.append(contentsOf: names
                .filter { $0.hasSuffix(".import.lungfish-provenance.json") }
                .map { ("alignments/\($0)", FileFormat.json, FileRole.output) })
        }
        var seen: Set<String> = []
        return try specifications.filter { seen.insert($0.0).inserted }.map { path, format, role in
            try MappingViewerPlannedPayload(
                relativePath: path,
                publishedPath: finalBundleURL.appendingPathComponent(path).path,
                format: format,
                role: role,
                bundleRoot: bundleRoot
            )
        }
    }

    private static func preserveDisplacedOriginal(at candidateURL: URL) throws -> URL {
        let preservedURL = candidateURL.deletingLastPathComponent().appendingPathComponent(
            ".\(candidateURL.lastPathComponent).ownership-conflict-\(UUID().uuidString)",
            isDirectory: true
        )
        try atomicRename(candidateURL, preservedURL, flags: UInt32(RENAME_EXCL))
        return preservedURL
    }

    private static func atomicRename(
        _ source: URL,
        _ destination: URL,
        flags: UInt32
    ) throws {
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
        guard status == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw MappingViewerBundlePublicationError.atomicPublicationFailed(
                source,
                destination,
                POSIXError(code).localizedDescription
            )
        }
    }

    private static func rehydrateImportedBAMProvenance(
        in bundleRoot: MappingViewerSecureBundleRoot,
        replacingRoot candidateBundleURL: URL,
        with finalBundleURL: URL,
        namedRootURL: URL
    ) throws {
        let names: [String]
        do {
            names = try bundleRoot.listNames(in: "alignments")
        } catch {
            // Viewer-less synthetic publication tests intentionally omit the
            // conventional bundle layout. A present-but-unsafe directory is
            // rejected because the root-relative open cannot distinguish it
            // from any other invalid path.
            if bundleRoot.entryExists(relativePath: "alignments") { throw error }
            return
        }

        for name in names where name.hasSuffix(".stats.db") {
            try rehydrateAlignmentMetadataDatabase(
                relativePath: "alignments/\(name)",
                bundleRoot: bundleRoot,
                replacingRoot: candidateBundleURL,
                with: finalBundleURL,
                namedRootURL: namedRootURL
            )
        }

        for name in names where name.hasSuffix(".import.lungfish-provenance.json") {
            let relativePath = "alignments/\(name)"
            let envelope = try ProvenanceJSON.decoder.decode(
                ProvenanceEnvelope.self,
                from: bundleRoot.readData(relativePath: relativePath)
            )
            let rehydrated = try remappedEnvelope(
                envelope,
                replacingRoot: candidateBundleURL,
                with: finalBundleURL,
                bundleRoot: bundleRoot
            )
            let encoded = try ProvenanceJSON.encoder.encode(rehydrated)
            try bundleRoot.replaceFile(
                relativePath: relativePath,
                data: encoded,
                namedRootURL: namedRootURL
            )
        }
    }

    private static func rehydrateAlignmentMetadataDatabase(
        relativePath: String,
        bundleRoot: MappingViewerSecureBundleRoot,
        replacingRoot candidateBundleURL: URL,
        with finalBundleURL: URL,
        namedRootURL: URL
    ) throws {
        guard bundleRoot.matchesNamedRoot(at: namedRootURL) else {
            throw MappingViewerBundlePublicationError.publicationOwnershipConflict(namedRootURL.path, nil)
        }
        let databaseDescriptor = try bundleRoot.openRegularFile(relativePath: relativePath, flags: O_RDWR)
        defer { Darwin.close(databaseDescriptor) }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            "/dev/fd/\(databaseDescriptor)",
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(database)
            throw MappingViewerBundlePublicationError.atomicPublicationFailed(
                candidateBundleURL,
                finalBundleURL,
                "Could not open imported BAM metadata for path rehydration: \(detail)"
            )
        }
        defer { sqlite3_close_v2(database) }

        guard sqlite3_exec(database, "PRAGMA journal_mode=MEMORY", nil, nil, nil) == SQLITE_OK else {
            throw sqliteRehydrationError(
                database: database,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
        }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw sqliteRehydrationError(
                database: database,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
        }
        do {
            try executePathReplacement(
                """
                UPDATE file_info
                SET value = replace(value, ?1, ?2)
                WHERE instr(value, ?1) > 0
                """,
                database: database,
                candidatePath: candidateBundleURL.standardizedFileURL.path,
                finalPath: finalBundleURL.standardizedFileURL.path,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
            try executePathReplacement(
                """
                UPDATE provenance
                SET command = replace(command, ?1, ?2),
                    input_file = replace(input_file, ?1, ?2),
                    output_file = replace(output_file, ?1, ?2)
                WHERE instr(command, ?1) > 0
                   OR instr(COALESCE(input_file, ''), ?1) > 0
                   OR instr(COALESCE(output_file, ''), ?1) > 0
                """,
                database: database,
                candidatePath: candidateBundleURL.standardizedFileURL.path,
                finalPath: finalBundleURL.standardizedFileURL.path,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw sqliteRehydrationError(
                    database: database,
                    candidateBundleURL: candidateBundleURL,
                    finalBundleURL: finalBundleURL
                )
            }
            guard bundleRoot.matchesNamedRoot(at: namedRootURL) else {
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(namedRootURL.path, nil)
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func executePathReplacement(
        _ sql: String,
        database: OpaquePointer,
        candidatePath: String,
        finalPath: String,
        candidateBundleURL: URL,
        finalBundleURL: URL
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteRehydrationError(
                database: database,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, candidatePath, -1, mappingViewerSQLiteTransient)
        sqlite3_bind_text(statement, 2, finalPath, -1, mappingViewerSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteRehydrationError(
                database: database,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
        }
    }

    private static func sqliteRehydrationError(
        database: OpaquePointer,
        candidateBundleURL: URL,
        finalBundleURL: URL
    ) -> MappingViewerBundlePublicationError {
        .atomicPublicationFailed(
            candidateBundleURL,
            finalBundleURL,
            "Could not rehydrate imported BAM metadata paths: \(String(cString: sqlite3_errmsg(database)))"
        )
    }

    private static func remappedEnvelope(
        _ envelope: ProvenanceEnvelope,
        replacingRoot candidateBundleURL: URL,
        with finalBundleURL: URL,
        bundleRoot: MappingViewerSecureBundleRoot
    ) throws -> ProvenanceEnvelope {
        let remapString: (String) -> String = { value in
            value.replacingOccurrences(
                of: candidateBundleURL.standardizedFileURL.path,
                with: finalBundleURL.standardizedFileURL.path
            )
        }
        let remapDescriptor: (ProvenanceFileDescriptor) throws -> ProvenanceFileDescriptor = { descriptor in
            let remappedPath = remapString(descriptor.path)
            guard remappedPath != descriptor.path else { return descriptor }
            let prefix = candidateBundleURL.standardizedFileURL.path + "/"
            guard descriptor.path.hasPrefix(prefix) else {
                throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(descriptor.path)
            }
            let relativePath = String(descriptor.path.dropFirst(prefix.count))
            let opened = try bundleRoot.openRegularFile(relativePath: relativePath, flags: O_RDONLY)
            defer { Darwin.close(opened) }
            let captured = try MappingViewerSecureBundleRoot.stableDigest(descriptor: opened)
            return ProvenanceFileDescriptor(
                path: remappedPath,
                checksumSHA256: captured.checksum,
                fileSize: captured.size,
                format: descriptor.format,
                role: descriptor.role,
                originPath: descriptor.originPath.map(remapString),
                sourceProvenancePath: descriptor.sourceProvenancePath.map(remapString)
            )
        }
        let remapValue: (ParameterValue) -> ParameterValue = { value in
            remappedParameterValue(value, remapString: remapString)
        }
        let remapOptions: ([String: ParameterValue]) -> [String: ParameterValue] = { options in
            options.mapValues(remapValue)
        }
        let argv = envelope.argv.map(remapString)
        let steps = try envelope.steps.map { step in
            let stepArgv = step.argv.map(remapString)
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: stepArgv,
                durableReplayArgv: step.durableReplayArgv?.map(remapString),
                reproducibleCommand: stepArgv.map(shellQuote).joined(separator: " "),
                resolvedOptions: remapOptions(step.resolvedOptions),
                runtimeIdentity: step.runtimeIdentity,
                inputs: try step.inputs.map(remapDescriptor),
                outputs: try step.outputs.map(remapDescriptor),
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: argv,
            durableReplayArgv: envelope.durableReplayArgv?.map(remapString),
            reproducibleCommand: argv.map(shellQuote).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: remapOptions(envelope.options.explicit),
                defaults: remapOptions(envelope.options.defaults),
                resolvedDefaults: remapOptions(envelope.options.resolvedDefaults)
            ),
            runtimeIdentity: envelope.runtimeIdentity,
            files: try envelope.files.map(remapDescriptor),
            output: try envelope.output.map(remapDescriptor),
            outputs: try envelope.outputs.map(remapDescriptor),
            steps: steps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private static func remappedParameterValue(
        _ value: ParameterValue,
        remapString: (String) -> String
    ) -> ParameterValue {
        switch value {
        case .string(let string):
            return .string(remapString(string))
        case .file(let url):
            let remappedPath = remapString(url.path)
            guard remappedPath != url.path else { return value }
            return .file(URL(fileURLWithPath: remappedPath))
        case .array(let values):
            return .array(values.map { remappedParameterValue($0, remapString: remapString) })
        case .dictionary(let values):
            return .dictionary(values.mapValues { remappedParameterValue($0, remapString: remapString) })
        case .integer, .number, .boolean, .null:
            return value
        }
    }

    private static func shellQuote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@%+=:,./-"))
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func sourceInputDescriptors(
        sourceBundleURL: URL,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        let manifestURL = sourceBundleURL.appendingPathComponent(BundleManifest.filename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(manifestURL)
        }
        try validateRegularPayloadNoFollow(manifestURL)
        let manifest = try BundleManifest.load(from: sourceBundleURL)
        var descriptors = [
            ProvenanceFileDescriptor(path: sourceBundleURL.path, role: .reference),
            try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .reference),
        ]
        if let genome = manifest.genome {
            descriptors.append(try descriptor(
                relativePath: genome.path,
                format: .fasta,
                role: .reference,
                bundleURL: sourceBundleURL,
                fileManager: fileManager
            ))
            if !genome.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: genome.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: sourceBundleURL,
                    fileManager: fileManager
                ))
            }
            if let gzipIndexPath = genome.gzipIndexPath, !gzipIndexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: gzipIndexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: sourceBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        descriptors.append(contentsOf: try nonAlignmentPayloadDescriptors(
            manifest: manifest,
            bundleURL: sourceBundleURL,
            payloadRole: .reference,
            fileManager: fileManager
        ))
        return deduplicated(descriptors)
    }

    private static func viewerOutputDescriptors(
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        let manifestURL = viewerBundleURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(manifestURL)
        }
        try validateRegularPayloadNoFollow(manifestURL)
        let manifest = try BundleManifest.load(from: viewerBundleURL)
        var descriptors = [
            ProvenanceFileDescriptor(path: viewerBundleURL.path, role: .output),
            try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output),
        ]
        if let genome = manifest.genome {
            descriptors.append(try descriptor(
                relativePath: genome.path,
                format: .fasta,
                role: .output,
                bundleURL: viewerBundleURL,
                fileManager: fileManager
            ))
            if !genome.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: genome.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
            if let gzipIndexPath = genome.gzipIndexPath, !gzipIndexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: gzipIndexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        descriptors.append(contentsOf: try nonAlignmentPayloadDescriptors(
            manifest: manifest,
            bundleURL: viewerBundleURL,
            payloadRole: .output,
            fileManager: fileManager
        ))
        for track in manifest.alignments {
            descriptors.append(try descriptor(
                relativePath: track.sourcePath,
                format: track.format == .cram ? .cram : .bam,
                role: .output,
                bundleURL: viewerBundleURL,
                fileManager: fileManager
            ))
            if !track.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: track.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
            if let metadataPath = track.metadataDBPath {
                descriptors.append(try descriptor(
                    relativePath: metadataPath,
                    format: .sqlite,
                    role: .output,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        let alignmentsURL = viewerBundleURL.appendingPathComponent("alignments", isDirectory: true)
        if fileManager.fileExists(atPath: alignmentsURL.path) {
            let importProvenanceSidecars = try fileManager.contentsOfDirectory(
                at: alignmentsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasSuffix(".import.lungfish-provenance.json") }
            descriptors.append(contentsOf: try importProvenanceSidecars.map {
                try validateRegularPayloadNoFollow($0)
                return try ProvenanceFileDescriptor.file(url: $0, format: .json, role: .output)
            })
        }
        return deduplicated(descriptors)
    }

    private static func nonAlignmentPayloadDescriptors(
        manifest: BundleManifest,
        bundleURL: URL,
        payloadRole: FileRole,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        var descriptors: [ProvenanceFileDescriptor] = []
        for annotation in manifest.annotations {
            descriptors.append(try descriptor(
                relativePath: annotation.path,
                format: .bigBed,
                role: payloadRole,
                bundleURL: bundleURL,
                fileManager: fileManager
            ))
            if let databasePath = annotation.databasePath, !databasePath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: databasePath,
                    format: .sqlite,
                    role: payloadRole,
                    bundleURL: bundleURL,
                    fileManager: fileManager
                ))
            }
        }
        for variant in manifest.variants {
            descriptors.append(try descriptor(
                relativePath: variant.path,
                format: variantFormat(for: variant.path),
                role: payloadRole,
                bundleURL: bundleURL,
                fileManager: fileManager
            ))
            if !variant.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: variant.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: bundleURL,
                    fileManager: fileManager
                ))
            }
            if let databasePath = variant.databasePath, !databasePath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: databasePath,
                    format: .sqlite,
                    role: payloadRole,
                    bundleURL: bundleURL,
                    fileManager: fileManager
                ))
            }
        }
        for track in manifest.tracks {
            descriptors.append(try descriptor(
                relativePath: track.path,
                format: .bigWig,
                role: payloadRole,
                bundleURL: bundleURL,
                fileManager: fileManager
            ))
        }
        return descriptors
    }

    private static func variantFormat(for path: String) -> FileFormat {
        path.lowercased().hasSuffix(".bcf") ? .bcf : .vcf
    }

    private static func descriptor(
        relativePath: String,
        format: FileFormat,
        role: FileRole,
        bundleURL: URL,
        fileManager: FileManager
    ) throws -> ProvenanceFileDescriptor {
        let root = bundleURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.pathComponents.count > root.pathComponents.count,
              candidate.pathComponents.starts(with: root.pathComponents) else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(candidate)
        }
        try validateRegularPayloadNoFollow(candidate)
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.pathComponents.count > resolvedRoot.pathComponents.count,
              resolvedCandidate.pathComponents.starts(with: resolvedRoot.pathComponents) else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        return try ProvenanceFileDescriptor.file(url: candidate, format: format, role: role)
    }

    private static func validateRegularPayloadNoFollow(_ url: URL) throws {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(url)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(url.path)
        }
    }

    private static func refreshedPublicationSidecarDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        mappingResultURL: URL,
        mappingProvenanceURL: URL
    ) throws -> ProvenanceFileDescriptor {
        let descriptorURL = URL(fileURLWithPath: descriptor.path).standardizedFileURL
        let refreshedURL: URL
        if descriptorURL == mappingResultURL.standardizedFileURL {
            refreshedURL = mappingResultURL
        } else if descriptorURL == mappingProvenanceURL.standardizedFileURL {
            refreshedURL = mappingProvenanceURL
        } else {
            return descriptor
        }
        return try ProvenanceFileDescriptor.file(
            url: refreshedURL,
            format: descriptor.format ?? .json,
            role: descriptor.role,
            originPath: descriptor.originPath,
            sourceProvenancePath: descriptor.sourceProvenancePath
        )
    }

    private static func deduplicated(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen: Set<String> = []
        return descriptors.filter { seen.insert($0.path).inserted }
    }

    private static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

}

private final class MappingViewerRollbackWitnessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProvenancePublicationSnapshot
    private var witness: ProvenancePublicationRollbackWitness

    init(snapshot: ProvenancePublicationSnapshot) throws {
        self.snapshot = snapshot
        self.witness = try snapshot.captureRollbackWitness()
    }

    var currentWitness: ProvenancePublicationRollbackWitness {
        lock.withLock { witness }
    }

    func replaceWitness(_ witness: ProvenancePublicationRollbackWitness) {
        lock.withLock { self.witness = witness }
    }

    func observe(_ mutation: ProvenanceWriterMutation) throws {
        try lock.withLock {
            witness = try snapshot.refreshingRollbackWitness(witness, after: mutation)
        }
    }
}

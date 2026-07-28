// ProvenanceWriter.swift - Canonical provenance sidecar writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishIO

public enum ProvenanceWriterError: Error, LocalizedError, Sendable, Equatable {
    case unstableSignatureArtifact(
        provider: String,
        expectedSignaturePath: String,
        actualSignaturePath: String,
        expectedPublicKeyPath: String,
        actualPublicKeyPath: String
    )
    case unsafeStagedSignatureArtifact(provider: String, path: String)
    case unsafeStagedArtifact(path: String, reason: String)
    case exclusivePublicationFailed(path: String, code: Int32)
    case exclusivePublicationIdentityMismatch(path: String)
    case exclusivePublicationCleanupFailed(
        path: String,
        quarantinePath: String?,
        reason: String
    )
    case exclusivePublicationRollbackFailed(
        originalError: String,
        cleanupErrors: [String],
        preservedQuarantinePaths: [String]
    )
    case directoryPreparationFailed(path: String, code: Int32)
    case transactionalSigningRequired(provider: String)
    case durabilitySyncFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unstableSignatureArtifact(
            let provider,
            let expectedSignaturePath,
            let actualSignaturePath,
            let expectedPublicKeyPath,
            let actualPublicKeyPath
        ):
            return """
            Provenance signing provider '\(provider)' changed signature artifact URLs for the same provenance URL; expected signature \(expectedSignaturePath) and public key \(expectedPublicKeyPath), got signature \(actualSignaturePath) and public key \(actualPublicKeyPath).
            """
        case .unsafeStagedSignatureArtifact(let provider, let path):
            return "Provenance signing provider '\(provider)' produced an artifact outside the staging directory: \(path)."
        case .unsafeStagedArtifact(let path, let reason):
            return "Unsafe staged provenance artifact at \(path): \(reason)."
        case .exclusivePublicationFailed(let path, let code):
            return "Could not publish a new provenance artifact without replacement at \(path): \(POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription)"
        case .exclusivePublicationIdentityMismatch(let path):
            return "Exclusive provenance publication renamed a different filesystem object than the validated staged regular file at \(path)."
        case .exclusivePublicationCleanupFailed(
            let path,
            let quarantinePath,
            let reason
        ):
            let quarantineDescription = quarantinePath.map {
                " The filesystem object was preserved at \($0)."
            } ?? ""
            return "Could not safely clean provenance artifact at \(path): \(reason).\(quarantineDescription)"
        case .exclusivePublicationRollbackFailed(
            let originalError,
            let cleanupErrors,
            let preservedQuarantinePaths
        ):
            let preservedDescription = preservedQuarantinePaths.isEmpty
                ? ""
                : " Preserved filesystem objects: \(preservedQuarantinePaths.joined(separator: ", "))."
            return "Provenance publication failed (\(originalError)), and rollback was incomplete: \(cleanupErrors.joined(separator: "; ")).\(preservedDescription)"
        case .directoryPreparationFailed(let path, let code):
            return "Could not prepare provenance directory at \(path): "
                + POSIXError(
                    .init(rawValue: code) ?? .EIO
                ).localizedDescription
        case .transactionalSigningRequired(let provider):
            return "Provenance signing provider '\(provider)' does not support operation-derived publication receipts."
        case .durabilitySyncFailed(let path, let code):
            return "Could not durably synchronize provenance artifact \(path): \(POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription)"
        }
    }
}

/// A filesystem mutation boundary reached while provenance is published.
///
/// Observers can use these boundaries to refresh a compare-and-swap rollback
/// witness before allowing publication to continue. A signing-provider event
/// is emitted after the provider returns or throws because providers may
/// create signature artifacts before reporting a failure.
public struct ProvenanceWriterMutation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case directoryPrepared
        case provenanceDocumentWritten
        case signingArtifactsMayHaveChanged
        case artifactRemoved
    }

    public let kind: Kind
    public let affectedURLs: [URL]
    let requiredPriorStates:
        [String: ProvenancePublicationArtifactState]
    let resultingStates:
        [String: ProvenancePublicationArtifactState]

    init(
        kind: Kind,
        affectedURLs: [URL],
        requiredPriorStates:
            [String: ProvenancePublicationArtifactState] = [:],
        resultingStates:
            [String: ProvenancePublicationArtifactState] = [:]
    ) {
        self.kind = kind
        self.affectedURLs = affectedURLs
        self.requiredPriorStates = requiredPriorStates
        self.resultingStates = resultingStates
    }

    public var url: URL {
        affectedURLs[0]
    }
}

/// Signals that a mutation receipt was accepted before a downstream observer
/// requested publication to stop. The writer must not undo the accepted
/// mutation; the enclosing transaction owns rollback from this point.
public struct ProvenanceWriterMutationAcceptedError:
    Error, LocalizedError, Sendable
{
    public let underlyingDescription: String

    public init(_ error: Error) {
        underlyingDescription = String(reflecting: error)
    }

    public var errorDescription: String? {
        underlyingDescription
    }
}

public struct ProvenanceWriter: Sendable {
    public static let provenanceFilename = ProvenanceRecorder.provenanceFilename
    public static let bundleProvenanceDirectoryName = "provenance"
    public static let bundleRollupFilename = "bundle.lungfish-provenance.json"
    public static let maximumBundleOutputSidecars = 100

    private let signingProvider: (any ProvenanceSigningProvider)?
    private let exclusivePublicationPreRenameHook:
        (@Sendable (URL, URL) throws -> Void)?
    private let exclusivePublicationPreMismatchCleanupHook:
        (@Sendable (URL) throws -> Void)?
    private let exclusivePublicationPreRollbackCleanupHook:
        (@Sendable (URL) throws -> Void)?
    private let exclusivePublicationPreQuarantineRestoreHook:
        (@Sendable (URL, URL) throws -> Void)?
    private let publicationMutationDidOccur:
        (@Sendable (ProvenanceWriterMutation) throws -> Void)?
    private let durableAtomicFileStore: DurableAtomicFileStore

    public init(
        signingProvider: (any ProvenanceSigningProvider)? =
            ProvenanceSigningConfiguration.defaultProvider()
    ) {
        self.signingProvider = signingProvider
        durableAtomicFileStore = DurableAtomicFileStore()
        publicationMutationDidOccur = nil
        exclusivePublicationPreRenameHook = nil
        exclusivePublicationPreMismatchCleanupHook = nil
        exclusivePublicationPreRollbackCleanupHook = nil
        exclusivePublicationPreQuarantineRestoreHook = nil
    }

    public init(
        publicationMutationDidOccur:
            @escaping @Sendable (ProvenanceWriterMutation) throws -> Void,
        signingProvider: (any ProvenanceSigningProvider)? =
            ProvenanceSigningConfiguration.defaultProvider()
    ) {
        self.signingProvider = signingProvider
        durableAtomicFileStore = DurableAtomicFileStore()
        self.publicationMutationDidOccur = publicationMutationDidOccur
        exclusivePublicationPreRenameHook = nil
        exclusivePublicationPreMismatchCleanupHook = nil
        exclusivePublicationPreRollbackCleanupHook = nil
        exclusivePublicationPreQuarantineRestoreHook = nil
    }

    init(
        signingProvider: (any ProvenanceSigningProvider)?,
        durableAtomicFileStore: DurableAtomicFileStore
    ) {
        self.signingProvider = signingProvider
        self.durableAtomicFileStore = durableAtomicFileStore
        publicationMutationDidOccur = nil
        exclusivePublicationPreRenameHook = nil
        exclusivePublicationPreMismatchCleanupHook = nil
        exclusivePublicationPreRollbackCleanupHook = nil
        exclusivePublicationPreQuarantineRestoreHook = nil
    }

    init(
        signingProvider: (any ProvenanceSigningProvider)?,
        exclusivePublicationPreRenameHook:
            @escaping @Sendable (URL, URL) throws -> Void,
        exclusivePublicationPreMismatchCleanupHook:
            (@Sendable (URL) throws -> Void)? = nil,
        exclusivePublicationPreRollbackCleanupHook:
            (@Sendable (URL) throws -> Void)? = nil,
        exclusivePublicationPreQuarantineRestoreHook:
            (@Sendable (URL, URL) throws -> Void)? = nil,
        publicationMutationDidOccur:
            (@Sendable (ProvenanceWriterMutation) throws -> Void)? = nil
    ) {
        self.signingProvider = signingProvider
        durableAtomicFileStore = DurableAtomicFileStore()
        self.publicationMutationDidOccur = publicationMutationDidOccur
        self.exclusivePublicationPreRenameHook =
            exclusivePublicationPreRenameHook
        self.exclusivePublicationPreMismatchCleanupHook =
            exclusivePublicationPreMismatchCleanupHook
        self.exclusivePublicationPreRollbackCleanupHook =
            exclusivePublicationPreRollbackCleanupHook
        self.exclusivePublicationPreQuarantineRestoreHook =
            exclusivePublicationPreQuarantineRestoreHook
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL {
        try write(envelope, to: directory, bundleLayoutRoot: directory)
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, to directory: URL, bundleLayoutRoot: URL) throws -> URL {
        try prepareDirectory(directory, withIntermediateDirectories: true)
        let provenanceURL = directory.appendingPathComponent(Self.provenanceFilename)
        let writtenURL = try write(envelope, toSidecar: provenanceURL)
        if Self.isBundleDirectory(bundleLayoutRoot) {
            _ = try writeBundleProvenanceLayout(
                envelope,
                toBundleRoot: directory,
                descriptorBundleRoot: bundleLayoutRoot
            )
        }
        return writtenURL
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, toSidecar provenanceURL: URL) throws -> URL {
        let directory = provenanceURL.deletingLastPathComponent()
        try prepareDirectory(directory, withIntermediateDirectories: true)

        try writeUnsigned(envelope, toSidecar: provenanceURL)

        guard let signingProvider else {
            if envelope.signatures.isEmpty {
                try removeSigningArtifacts(for: provenanceURL)
            }
            return provenanceURL
        }

        let initialArtifact = try sign(
            with: signingProvider,
            provenanceURL: provenanceURL
        )
        let placeholderReference = signatureReference(
            provider: signingProvider.providerIdentifier,
            artifact: initialArtifact,
            provenanceSHA256: "",
            relativeTo: directory
        )
        let envelopeWithSignaturePaths = envelope.upsertingSignatureReference(placeholderReference)
        try writeUnsigned(envelopeWithSignaturePaths, toSidecar: provenanceURL)

        let signaturePathArtifact = try sign(
            with: signingProvider,
            provenanceURL: provenanceURL
        )
        try validateStableArtifact(
            signaturePathArtifact,
            matches: initialArtifact,
            provider: signingProvider.providerIdentifier
        )
        let finalDigest = try ProvenanceSigningPayload.sha256Hex(
            ofProvenanceAt: provenanceURL,
            provider: signingProvider.providerIdentifier,
            signatureURL: initialArtifact.signatureURL
        )
        let finalReference = signatureReference(
            provider: signingProvider.providerIdentifier,
            artifact: initialArtifact,
            provenanceSHA256: finalDigest,
            relativeTo: directory
        )
        let signedEnvelope = envelope.upsertingSignatureReference(finalReference)
        try writeUnsigned(signedEnvelope, toSidecar: provenanceURL)
        let finalArtifact = try sign(
            with: signingProvider,
            provenanceURL: provenanceURL
        )
        try validateStableArtifact(
            finalArtifact,
            matches: initialArtifact,
            provider: signingProvider.providerIdentifier
        )
        if signingProvider.providerIdentifier == ProvenanceSigningConfiguration.localProviderID {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        }

        return provenanceURL
    }

    /// Writes and signs a complete provenance transaction on the destination
    /// filesystem, then publishes every artifact without replacing any path.
    ///
    /// Signature and public-key artifacts are published first. The provenance
    /// document is the commit marker and is published last.
    @discardableResult
    public func writeNew(
        _ envelope: ProvenanceEnvelope,
        toSidecar provenanceURL: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let destinationDirectory = provenanceURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let stagingDirectory = destinationDirectory.appendingPathComponent(
            ".\(provenanceURL.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }

        let stagedProvenanceURL = stagingDirectory.appendingPathComponent(
            provenanceURL.lastPathComponent
        )
        try write(envelope, toSidecar: stagedProvenanceURL)

        var artifacts: [(staged: URL, destination: URL)] = []
        if let signingProvider {
            guard let stagedEnvelope = try ProvenanceEnvelopeReader.load(
                fromSidecar: stagedProvenanceURL
            ),
            let reference = stagedEnvelope.signatures.last(where: {
                $0.provider == signingProvider.providerIdentifier
            }) else {
                throw ProvenanceWriterError.unsafeStagedSignatureArtifact(
                    provider: signingProvider.providerIdentifier,
                    path: stagedProvenanceURL.path
                )
            }
            artifacts.append(
                try exclusivePublicationArtifact(
                    storedPath: reference.signaturePath,
                    provider: signingProvider.providerIdentifier,
                    stagingDirectory: stagingDirectory,
                    destinationDirectory: destinationDirectory
                )
            )
            if let publicKeyPath = reference.publicKeyPath {
                artifacts.append(
                    try exclusivePublicationArtifact(
                        storedPath: publicKeyPath,
                        provider: signingProvider.providerIdentifier,
                        stagingDirectory: stagingDirectory,
                        destinationDirectory: destinationDirectory
                    )
                )
            }
        }
        artifacts.append((stagedProvenanceURL, provenanceURL))

        var validatedArtifacts: [ValidatedPublicationArtifact] = []
        defer {
            for artifact in validatedArtifacts {
                Darwin.close(artifact.descriptor)
            }
        }
        for artifact in artifacts {
            validatedArtifacts.append(
                try validateStagedRegularFile(
                    at: artifact.staged,
                    destination: artifact.destination
                )
            )
        }
        try synchronizeDirectory(at: stagingDirectory)

        var published: [
            (url: URL, identity: FileSystemObjectIdentity)
        ] = []
        do {
            for artifact in validatedArtifacts {
                guard try fileIdentity(at: artifact.staged)
                        == artifact.identity else {
                    throw ProvenanceWriterError.unsafeStagedArtifact(
                        path: artifact.staged.path,
                        reason:
                            "the path no longer identifies the validated regular file"
                    )
                }
                try exclusivePublicationPreRenameHook?(
                    artifact.staged,
                    artifact.destination
                )
                let result = artifact.staged.path.withCString { sourcePath in
                    artifact.destination.path.withCString { destinationPath in
                        PortableExclusiveRename.renameatxNP(
                            AT_FDCWD,
                            sourcePath,
                            AT_FDCWD,
                            destinationPath,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard result == 0 else {
                    throw ProvenanceWriterError.exclusivePublicationFailed(
                        path: artifact.destination.path,
                        code: errno
                    )
                }
                let renamedIdentity: FileSystemObjectIdentity
                do {
                    renamedIdentity = try fileSystemObjectIdentity(
                        at: artifact.destination
                    )
                } catch {
                    try exclusivePublicationPreMismatchCleanupHook?(
                        artifact.destination
                    )
                    _ = try quarantineAndRemoveIfIdentityMatches(
                        at: artifact.destination,
                        expectedIdentity: FileSystemObjectIdentity(
                            fileIdentity: artifact.identity,
                            fileType: mode_t(S_IFREG)
                        )
                    )
                    throw ProvenanceWriterError
                        .exclusivePublicationIdentityMismatch(
                            path: artifact.destination.path
                        )
                }
                guard renamedIdentity.isRegularFile,
                      renamedIdentity.fileIdentity
                        == artifact.identity else {
                    try exclusivePublicationPreMismatchCleanupHook?(
                        artifact.destination
                    )
                    _ = try quarantineAndRemoveIfIdentityMatches(
                        at: artifact.destination,
                        expectedIdentity: renamedIdentity
                    )
                    throw ProvenanceWriterError
                        .exclusivePublicationIdentityMismatch(
                            path: artifact.destination.path
                        )
                }
                published.append(
                    (artifact.destination, renamedIdentity)
                )
            }
            try synchronizeDirectory(at: destinationDirectory)
        } catch {
            let originalError = error
            var cleanupErrors: [String] = []
            var preservedQuarantinePaths: [String] = []
            for artifact in published.reversed() {
                do {
                    try exclusivePublicationPreRollbackCleanupHook?(
                        artifact.url
                    )
                    _ = try quarantineAndRemoveIfIdentityMatches(
                        at: artifact.url,
                        expectedIdentity: artifact.identity
                    )
                } catch {
                    cleanupErrors.append(error.localizedDescription)
                    if case let ProvenanceWriterError
                        .exclusivePublicationCleanupFailed(
                            _,
                            quarantinePath?,
                            _
                        ) = error {
                        preservedQuarantinePaths.append(quarantinePath)
                    }
                }
            }
            do {
                try synchronizeDirectory(at: destinationDirectory)
            } catch {
                cleanupErrors.append(error.localizedDescription)
            }
            guard cleanupErrors.isEmpty else {
                throw ProvenanceWriterError
                    .exclusivePublicationRollbackFailed(
                        originalError: originalError.localizedDescription,
                        cleanupErrors: cleanupErrors,
                        preservedQuarantinePaths:
                            preservedQuarantinePaths
                    )
            }
            throw originalError
        }

        return provenanceURL
    }

    @discardableResult
    public func writeBundleProvenanceLayout(
        _ envelope: ProvenanceEnvelope,
        toBundleRoot bundleURL: URL
    ) throws -> [URL] {
        try writeBundleProvenanceLayout(
            envelope,
            toBundleRoot: bundleURL,
            descriptorBundleRoot: bundleURL
        )
    }

    @discardableResult
    public func writeBundleProvenanceLayout(
        _ envelope: ProvenanceEnvelope,
        toBundleRoot bundleURL: URL,
        descriptorBundleRoot: URL
    ) throws -> [URL] {
        let provenanceDirectory = bundleURL.appendingPathComponent(
            Self.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        try prepareDirectory(
            provenanceDirectory,
            withIntermediateDirectories: true
        )

        let outputEntries = bundleOutputEntries(from: envelope, relativeTo: descriptorBundleRoot)
        let rollupEnvelope = outputEntries.isEmpty
            ? envelope.replacingSignatures([])
            : envelope.projectedToBundleOutputs(outputEntries.map(\.descriptor))
        let rollupURL = provenanceDirectory.appendingPathComponent(Self.bundleRollupFilename)
        var writtenURLs = [try write(rollupEnvelope, toSidecar: rollupURL)]

        let expectedFocusedSidecars: Set<URL> = outputEntries.count <= Self.maximumBundleOutputSidecars
            ? Set(outputEntries.map { entry in
                Self.bundleOutputSidecarURL(
                    forRelativeOutputPath: entry.relativePath,
                    inProvenanceDirectory: provenanceDirectory
                ).standardizedFileURL
            })
            : []
        try pruneStaleBundleOutputSidecars(
            in: provenanceDirectory,
            descriptorBundleRoot: descriptorBundleRoot,
            keeping: expectedFocusedSidecars
        )

        if outputEntries.count <= Self.maximumBundleOutputSidecars {
            for entry in outputEntries {
                let sidecarURL = Self.bundleOutputSidecarURL(
                    forRelativeOutputPath: entry.relativePath,
                    inProvenanceDirectory: provenanceDirectory
                )
                let focusedEnvelope = envelope
                    .focusedOnOutput(entry.descriptor)
                    .replacingSignatures([])
                writtenURLs.append(try write(focusedEnvelope, toSidecar: sidecarURL))
            }
        }

        return writtenURLs
    }

    private func pruneStaleBundleOutputSidecars(
        in provenanceDirectory: URL,
        descriptorBundleRoot: URL,
        keeping expectedSidecars: Set<URL>
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: provenanceDirectory.path) else { return }
        guard let enumerator = fileManager.enumerator(
            at: provenanceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let expectedPaths = Set(expectedSidecars.map { $0.standardizedFileURL.path })
        for case let candidateURL as URL in enumerator {
            let standardizedCandidate = candidateURL.standardizedFileURL
            guard !expectedPaths.contains(standardizedCandidate.path),
                  isWriterManagedBundleOutputSidecar(
                    standardizedCandidate,
                    provenanceDirectory: provenanceDirectory,
                    descriptorBundleRoot: descriptorBundleRoot
                  ) else {
                continue
            }
            try removeSigningArtifacts(for: standardizedCandidate)
            try removeArtifact(
                at: standardizedCandidate,
                mutationKind: .artifactRemoved
            )
        }
    }

    private func isWriterManagedBundleOutputSidecar(
        _ sidecarURL: URL,
        provenanceDirectory: URL,
        descriptorBundleRoot: URL
    ) -> Bool {
        guard sidecarURL.lastPathComponent != Self.bundleRollupFilename,
              sidecarURL.lastPathComponent.hasSuffix(".lungfish-provenance.json") else {
            return false
        }
        guard let relativeSidecarPath = Self.bundleRelativePath(
            for: sidecarURL.path,
            relativeTo: provenanceDirectory
        ) else {
            return false
        }
        guard let expectedOutputRelativePath = outputRelativePath(forBundleOutputSidecarRelativePath: relativeSidecarPath) else {
            return false
        }
        guard let envelope = try? ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL),
              envelope.outputs.count == 1,
              let output = envelope.outputs.first,
              Self.bundleRelativePath(for: output.path, relativeTo: descriptorBundleRoot) == expectedOutputRelativePath else {
            return false
        }
        return true
    }

    private func outputRelativePath(forBundleOutputSidecarRelativePath sidecarRelativePath: String) -> String? {
        let suffix = ".lungfish-provenance.json"
        guard sidecarRelativePath.hasSuffix(suffix) else { return nil }
        let outputRelativePath = String(sidecarRelativePath.dropLast(suffix.count))
        return outputRelativePath.isEmpty ? nil : outputRelativePath
    }

    public static func isBundleDirectory(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.hasPrefix("lungfish") && !ext.isEmpty
    }

    public static func bundleOutputSidecarURL(for outputURL: URL, inBundle bundleURL: URL) -> URL? {
        guard let relativePath = bundleRelativePath(for: outputURL.path, relativeTo: bundleURL) else {
            return nil
        }
        let provenanceDirectory = bundleURL.appendingPathComponent(
            Self.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        return bundleOutputSidecarURL(
            forRelativeOutputPath: relativePath,
            inProvenanceDirectory: provenanceDirectory
        )
    }

    private func writeUnsigned(_ envelope: ProvenanceEnvelope, toSidecar provenanceURL: URL) throws {
        let data = try ProvenanceJSON.encoder.encode(envelope)
        if signingProvider == nil,
           publicationMutationDidOccur == nil,
           !FileManager.default.fileExists(atPath: provenanceURL.path) {
            try durableAtomicFileStore.create(
                data,
                named: provenanceURL.lastPathComponent,
                in: provenanceURL.deletingLastPathComponent()
            )
            return
        }
        let temporaryURL = provenanceURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(provenanceURL.lastPathComponent)"
                    + ".provenance-write-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .atomic)
        try publishStagedArtifact(
            at: temporaryURL,
            to: provenanceURL,
            kind: .provenanceDocumentWritten,
            replacingExisting: true
        )
    }

    private func removeSigningArtifacts(for provenanceURL: URL) throws {
        for artifactURL in [
            ProvenanceSigningConfiguration.signatureURL(for: provenanceURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL),
        ] {
            try removeArtifact(
                at: artifactURL,
                mutationKind: .artifactRemoved
            )
        }
    }

    private func prepareDirectory(
        _ directory: URL,
        withIntermediateDirectories: Bool
    ) throws {
        let standardized = directory.standardizedFileURL
        if !withIntermediateDirectories {
            try createDirectoryComponentIfNeeded(standardized)
            return
        }

        var missingComponents: [URL] = []
        var cursor = standardized
        while !Self.isDirectoryFollowingSymbolicLinks(cursor) {
            var information = stat()
            let status = cursor.path.withCString {
                Darwin.lstat($0, &information)
            }
            if status == 0 {
                throw ProvenanceWriterError.directoryPreparationFailed(
                    path: cursor.path,
                    code: ENOTDIR
                )
            }
            let code = errno
            guard code == ENOENT else {
                throw ProvenanceWriterError.directoryPreparationFailed(
                    path: cursor.path,
                    code: code
                )
            }
            missingComponents.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw ProvenanceWriterError.directoryPreparationFailed(
                    path: cursor.path,
                    code: ENOENT
                )
            }
            cursor = parent
        }
        for component in missingComponents.reversed() {
            try createDirectoryComponentIfNeeded(component)
        }
    }

    private func sign(
        with provider: any ProvenanceSigningProvider,
        provenanceURL: URL
    ) throws -> ProvenanceSignatureArtifact {
        let plannedArtifact = provider.artifactLocations(
            for: provenanceURL
        )
        guard publicationMutationDidOccur != nil else {
            let artifact = try provider.sign(
                provenanceURL: provenanceURL
            )
            try validateStableArtifact(
                artifact,
                matches: plannedArtifact,
                provider: provider.providerIdentifier
            )
            return artifact
        }
        guard let transactionalProvider =
                provider as? any TransactionalProvenanceSigningProvider else {
            throw ProvenanceWriterError.transactionalSigningRequired(
                provider: provider.providerIdentifier
            )
        }
        let allowedPaths = Set([
            plannedArtifact.signatureURL.standardizedFileURL.path,
            plannedArtifact.publicKeyURL.standardizedFileURL.path,
        ])
        let artifact = try transactionalProvider.sign(
            provenanceURL: provenanceURL
        ) { data, destinationURL in
            let destination = destinationURL.standardizedFileURL
            guard allowedPaths.contains(destination.path) else {
                throw ProvenanceWriterError.unstableSignatureArtifact(
                    provider: provider.providerIdentifier,
                    expectedSignaturePath:
                        plannedArtifact.signatureURL.path,
                    actualSignaturePath: destination.path,
                    expectedPublicKeyPath:
                        plannedArtifact.publicKeyURL.path,
                    actualPublicKeyPath: destination.path
                )
            }
            try publishDataArtifact(
                data,
                to: destination,
                kind: .signingArtifactsMayHaveChanged
            )
        }
        try validateStableArtifact(
            artifact,
            matches: plannedArtifact,
            provider: provider.providerIdentifier
        )
        return artifact
    }

    private func publishDataArtifact(
        _ data: Data,
        to destinationURL: URL,
        kind: ProvenanceWriterMutation.Kind
    ) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent)"
                    + ".provenance-artifact-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .atomic)
        try publishStagedArtifact(
            at: temporaryURL,
            to: destinationURL,
            kind: kind,
            replacingExisting: true
        )
    }

    private func createDirectoryComponentIfNeeded(
        _ directory: URL
    ) throws {
        if Self.isDirectoryFollowingSymbolicLinks(directory) {
            return
        }
        let temporaryDirectory = directory.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(directory.lastPathComponent)"
                    + ".provenance-directory-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let creationResult = temporaryDirectory.path.withCString {
            Darwin.mkdir($0, mode_t(0o777))
        }
        guard creationResult == 0 else {
            let code = errno
            throw ProvenanceWriterError.directoryPreparationFailed(
                path: temporaryDirectory.path,
                code: code
            )
        }
        do {
            try publishStagedArtifact(
                at: temporaryDirectory,
                to: directory,
                kind: .directoryPrepared,
                replacingExisting: false
            )
            return
        } catch let error as ProvenanceWriterError {
            if case .exclusivePublicationFailed(_, let code) = error,
               code == EEXIST,
               Self.isDirectoryFollowingSymbolicLinks(directory) {
                return
            }
            throw error
        }
    }

    private func removeArtifact(
        at artifactURL: URL,
        mutationKind: ProvenanceWriterMutation.Kind
    ) throws {
        let detachedURL = artifactURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(artifactURL.lastPathComponent)"
                    + ".provenance-remove-\(UUID().uuidString)"
            )
        let detached = try Self.renameExclusivelyIfPresent(
            from: artifactURL,
            to: detachedURL
        )
        guard detached else { return }
        let priorState: ProvenancePublicationArtifactState
        do {
            priorState = try ProvenancePublicationSnapshot.artifactState(
                at: detachedURL,
                fileManager: .default
            )
        } catch {
            try Self.restoreDetachedAfterFailure(
                detachedURL,
                to: artifactURL,
                originalError: error
            )
        }
        let mutation = ProvenanceWriterMutation(
            kind: mutationKind,
            affectedURLs: [artifactURL],
            requiredPriorStates: [artifactURL.standardizedFileURL.path: priorState],
            resultingStates: [artifactURL.standardizedFileURL.path: .missing]
        )
        do {
            try reportMutation(mutation)
        } catch {
            if error is ProvenanceWriterMutationAcceptedError {
                throw error
            }
            try Self.restoreDetachedArtifact(
                detachedURL,
                to: artifactURL
            )
            throw error
        }
        do {
            try FileManager.default.removeItem(at: detachedURL)
        } catch {
            throw ProvenanceWriterError.exclusivePublicationCleanupFailed(
                path: artifactURL.path,
                quarantinePath: detachedURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func publishStagedArtifact(
        at stagedURL: URL,
        to destinationURL: URL,
        kind: ProvenanceWriterMutation.Kind,
        replacingExisting: Bool
    ) throws {
        let standardizedDestination =
            destinationURL.standardizedFileURL
        let stagedState = try ProvenancePublicationSnapshot.artifactState(
            at: stagedURL,
            fileManager: .default
        )
        guard stagedState != .missing else {
            throw ProvenanceWriterError.unsafeStagedArtifact(
                path: stagedURL.path,
                reason: "the staged artifact is missing"
            )
        }

        let displacedURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent)"
                    + ".provenance-displaced-\(UUID().uuidString)"
            )
        var priorState: ProvenancePublicationArtifactState = .missing
        var displaced = false
        if replacingExisting {
            displaced = try Self.renameExclusivelyIfPresent(
                from: destinationURL,
                to: displacedURL
            )
            if displaced {
                do {
                    priorState =
                        try ProvenancePublicationSnapshot.artifactState(
                            at: displacedURL,
                            fileManager: .default
                        )
                } catch {
                    try Self.restoreDetachedAfterFailure(
                        displacedURL,
                        to: destinationURL,
                        originalError: error
                    )
                }
            }
        }

        do {
            try Self.renameExclusively(
                from: stagedURL,
                to: destinationURL
            )
        } catch {
            if displaced {
                do {
                    try Self.restoreDetachedArtifact(
                        displacedURL,
                        to: destinationURL
                    )
                } catch let cleanupError {
                    throw ProvenanceWriterError
                        .exclusivePublicationRollbackFailed(
                            originalError: error.localizedDescription,
                            cleanupErrors: [
                                cleanupError.localizedDescription,
                            ],
                            preservedQuarantinePaths: [
                                displacedURL.path,
                            ]
                        )
                }
            }
            throw error
        }

        let mutation = ProvenanceWriterMutation(
            kind: kind,
            affectedURLs: [standardizedDestination],
            requiredPriorStates: [
                standardizedDestination.path: priorState,
            ],
            resultingStates: [
                standardizedDestination.path: stagedState,
            ]
        )
        do {
            try reportMutation(mutation)
        } catch {
            if error is ProvenanceWriterMutationAcceptedError {
                throw error
            }
            let observationError = error
            try rollbackUnacceptedReplacement(
                at: destinationURL,
                expectedPublishedState: stagedState,
                displacedURL: displaced ? displacedURL : nil
            )
            throw observationError
        }

        if displaced {
            do {
                try FileManager.default.removeItem(at: displacedURL)
            } catch {
                throw ProvenanceWriterError
                    .exclusivePublicationCleanupFailed(
                        path: destinationURL.path,
                        quarantinePath: displacedURL.path,
                        reason: error.localizedDescription
                    )
            }
        }
    }

    private func rollbackUnacceptedReplacement(
        at destinationURL: URL,
        expectedPublishedState:
            ProvenancePublicationArtifactState,
        displacedURL: URL?
    ) throws {
        let rejectedURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent)"
                    + ".provenance-rejected-\(UUID().uuidString)"
            )
        let detached = try Self.renameExclusivelyIfPresent(
            from: destinationURL,
            to: rejectedURL
        )
        if detached {
            let detachedState =
                try ProvenancePublicationSnapshot.artifactState(
                    at: rejectedURL,
                    fileManager: .default
                )
            guard ProvenancePublicationSnapshot.statesMatch(
                detachedState,
                expectedPublishedState
            ) else {
                try Self.restoreDetachedArtifact(
                    rejectedURL,
                    to: destinationURL
                )
                throw ProvenanceWriterError
                    .exclusivePublicationCleanupFailed(
                        path: destinationURL.path,
                        quarantinePath: displacedURL?.path,
                        reason:
                            "a later writer replaced the rejected transaction artifact"
                    )
            }
            try FileManager.default.removeItem(at: rejectedURL)
        }
        if let displacedURL {
            try Self.restoreDetachedArtifact(
                displacedURL,
                to: destinationURL
            )
        }
    }

    private static func renameExclusively(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                PortableExclusiveRename.renameatxNP(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw ProvenanceWriterError.exclusivePublicationFailed(
                path: destinationURL.path,
                code: errno
            )
        }
    }

    private static func renameExclusivelyIfPresent(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> Bool {
        var sourceInfo = stat()
        if sourceURL.path.withCString({
            Darwin.lstat($0, &sourceInfo)
        }) != 0 {
            let code = errno
            if code == ENOENT {
                return false
            }
            throw ProvenanceWriterError.exclusivePublicationFailed(
                path: sourceURL.path,
                code: code
            )
        }
        do {
            try renameExclusively(
                from: sourceURL,
                to: destinationURL
            )
            return true
        } catch let error as ProvenanceWriterError {
            if case .exclusivePublicationFailed(_, let code) = error,
               code == ENOENT {
                return false
            }
            throw error
        }
    }

    private static func restoreDetachedArtifact(
        _ detachedURL: URL,
        to destinationURL: URL
    ) throws {
        do {
            try renameExclusively(
                from: detachedURL,
                to: destinationURL
            )
        } catch {
            throw ProvenanceWriterError
                .exclusivePublicationCleanupFailed(
                    path: destinationURL.path,
                    quarantinePath: detachedURL.path,
                    reason: error.localizedDescription
                )
        }
    }

    private static func restoreDetachedAfterFailure(
        _ detachedURL: URL,
        to destinationURL: URL,
        originalError: Error
    ) throws -> Never {
        do {
            try restoreDetachedArtifact(
                detachedURL,
                to: destinationURL
            )
        } catch {
            throw ProvenanceWriterError
                .exclusivePublicationRollbackFailed(
                    originalError:
                        originalError.localizedDescription,
                    cleanupErrors: [error.localizedDescription],
                    preservedQuarantinePaths: [
                        detachedURL.path,
                    ]
                )
        }
        throw originalError
    }

    private static func isDirectoryFollowingSymbolicLinks(
        _ url: URL
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func reportMutation(
        _ mutation: ProvenanceWriterMutation
    ) throws {
        try publicationMutationDidOccur?(mutation)
    }

    private func validateStableArtifact(
        _ artifact: ProvenanceSignatureArtifact,
        matches expected: ProvenanceSignatureArtifact,
        provider: String
    ) throws {
        let actualSignatureURL = artifact.signatureURL.standardizedFileURL
        let expectedSignatureURL = expected.signatureURL.standardizedFileURL
        let actualPublicKeyURL = artifact.publicKeyURL.standardizedFileURL
        let expectedPublicKeyURL = expected.publicKeyURL.standardizedFileURL
        guard actualSignatureURL == expectedSignatureURL,
              actualPublicKeyURL == expectedPublicKeyURL else {
            throw ProvenanceWriterError.unstableSignatureArtifact(
                provider: provider,
                expectedSignaturePath: expectedSignatureURL.path,
                actualSignaturePath: actualSignatureURL.path,
                expectedPublicKeyPath: expectedPublicKeyURL.path,
                actualPublicKeyPath: actualPublicKeyURL.path
            )
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct FileSystemObjectIdentity: Equatable {
        let fileIdentity: FileIdentity
        let fileType: mode_t

        var isRegularFile: Bool {
            fileType == mode_t(S_IFREG)
        }

        var isDirectory: Bool {
            fileType == mode_t(S_IFDIR)
        }
    }

    private struct ValidatedPublicationArtifact {
        let staged: URL
        let destination: URL
        let identity: FileIdentity
        let descriptor: Int32
    }

    private func exclusivePublicationArtifact(
        storedPath: String,
        provider: String,
        stagingDirectory: URL,
        destinationDirectory: URL
    ) throws -> (staged: URL, destination: URL) {
        guard !storedPath.hasPrefix("/") else {
            throw ProvenanceWriterError.unsafeStagedSignatureArtifact(
                provider: provider,
                path: storedPath
            )
        }
        let stagedURL = stagingDirectory.appendingPathComponent(storedPath)
            .standardizedFileURL
        guard stagedURL.deletingLastPathComponent()
                == stagingDirectory.standardizedFileURL,
              stagedURL.lastPathComponent != "." else {
            throw ProvenanceWriterError.unsafeStagedSignatureArtifact(
                provider: provider,
                path: storedPath
            )
        }
        return (
            stagedURL,
            destinationDirectory.appendingPathComponent(
                stagedURL.lastPathComponent
            )
        )
    }

    private func fileIdentity(at url: URL) throws -> FileIdentity {
        try fileSystemObjectIdentity(at: url).fileIdentity
    }

    private func fileSystemObjectIdentity(
        at url: URL
    ) throws -> FileSystemObjectIdentity {
        var metadata = stat()
        guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return FileSystemObjectIdentity(
            fileIdentity: FileIdentity(
                device: metadata.st_dev,
                inode: metadata.st_ino
            ),
            fileType: metadata.st_mode & mode_t(S_IFMT)
        )
    }

    private enum QuarantineCleanupResult {
        case removedExpectedIdentity
        case restoredUnexpectedIdentity
        case destinationAlreadyAbsent
    }

    private func quarantineAndRemoveIfIdentityMatches(
        at url: URL,
        expectedIdentity: FileSystemObjectIdentity
    ) throws -> QuarantineCleanupResult {
        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).cleanup-quarantine-\(UUID().uuidString)"
            )
        let quarantineResult = url.path.withCString { sourcePath in
            quarantineURL.path.withCString { quarantinePath in
                PortableExclusiveRename.renameatxNP(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    quarantinePath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard quarantineResult == 0 else {
            let code = errno
            if code == ENOENT {
                return .destinationAlreadyAbsent
            }
            throw ProvenanceWriterError
                .exclusivePublicationCleanupFailed(
                    path: url.path,
                    quarantinePath: nil,
                    reason:
                        "could not atomically move it to quarantine: \(String(cString: Darwin.strerror(code)))"
                )
        }

        let quarantinedIdentity: FileSystemObjectIdentity
        do {
            quarantinedIdentity = try fileSystemObjectIdentity(
                at: quarantineURL
            )
        } catch {
            let restoreResult = quarantineURL.path.withCString {
                quarantinePath in
                url.path.withCString { originalPath in
                    PortableExclusiveRename.renameatxNP(
                        AT_FDCWD,
                        quarantinePath,
                        AT_FDCWD,
                        originalPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            throw ProvenanceWriterError
                .exclusivePublicationCleanupFailed(
                    path: url.path,
                    quarantinePath:
                        restoreResult == 0 ? nil : quarantineURL.path,
                    reason:
                        "could not inspect the quarantined filesystem object"
                )
        }

        guard quarantinedIdentity == expectedIdentity else {
            do {
                try exclusivePublicationPreQuarantineRestoreHook?(
                    url,
                    quarantineURL
                )
            } catch {
                throw ProvenanceWriterError
                    .exclusivePublicationCleanupFailed(
                        path: url.path,
                        quarantinePath: quarantineURL.path,
                        reason:
                            "the pre-restore operation failed: \(error.localizedDescription)"
                    )
            }
            let restoreResult = quarantineURL.path.withCString {
                quarantinePath in
                url.path.withCString { originalPath in
                    PortableExclusiveRename.renameatxNP(
                        AT_FDCWD,
                        quarantinePath,
                        AT_FDCWD,
                        originalPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard restoreResult == 0 else {
                let code = errno
                throw ProvenanceWriterError
                    .exclusivePublicationCleanupFailed(
                        path: url.path,
                        quarantinePath: quarantineURL.path,
                        reason:
                            "the quarantined replacement could not be restored exclusively: \(String(cString: Darwin.strerror(code)))"
                    )
            }
            return .restoredUnexpectedIdentity
        }

        do {
            try FileManager.default.removeItem(at: quarantineURL)
        } catch {
            throw ProvenanceWriterError
                .exclusivePublicationCleanupFailed(
                    path: url.path,
                    quarantinePath: quarantineURL.path,
                    reason:
                        "could not remove the identity-matched quarantined object: \(error.localizedDescription)"
                )
        }
        return .removedExpectedIdentity
    }

    private func validateStagedRegularFile(
        at url: URL,
        destination: URL
    ) throws -> ValidatedPublicationArtifact {
        var pathMetadata = stat()
        guard url.path.withCString({
            Darwin.lstat($0, &pathMetadata)
        }) == 0 else {
            throw ProvenanceWriterError.unsafeStagedArtifact(
                path: url.path,
                reason: String(cString: Darwin.strerror(errno))
            )
        }
        guard (pathMetadata.st_mode & mode_t(S_IFMT))
                == mode_t(S_IFREG) else {
            throw ProvenanceWriterError.unsafeStagedArtifact(
                path: url.path,
                reason: "expected a regular file"
            )
        }
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            throw ProvenanceWriterError.unsafeStagedArtifact(
                path: url.path,
                reason:
                    "could not open without following links: \(String(cString: Darwin.strerror(errno)))"
            )
        }
        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }
        var descriptorMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0 else {
            throw ProvenanceWriterError.unsafeStagedArtifact(
                path: url.path,
                reason:
                    "could not inspect the opened descriptor: \(String(cString: Darwin.strerror(errno)))"
            )
        }
        guard (descriptorMetadata.st_mode & mode_t(S_IFMT))
                == mode_t(S_IFREG) else {
            throw ProvenanceWriterError.unsafeStagedArtifact(
                path: url.path,
                reason: "the opened descriptor is not a regular file"
            )
        }
        let pathIdentity = FileIdentity(
            device: pathMetadata.st_dev,
            inode: pathMetadata.st_ino
        )
        let descriptorIdentity = FileIdentity(
            device: descriptorMetadata.st_dev,
            inode: descriptorMetadata.st_ino
        )
        guard pathIdentity == descriptorIdentity else {
            throw ProvenanceWriterError.unsafeStagedArtifact(
                path: url.path,
                reason:
                    "the path and opened descriptor identify different files"
            )
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProvenanceWriterError.durabilitySyncFailed(
                path: url.path,
                code: errno
            )
        }
        shouldClose = false
        return ValidatedPublicationArtifact(
            staged: url,
            destination: destination,
            identity: descriptorIdentity,
            descriptor: descriptor
        )
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw ProvenanceWriterError.durabilitySyncFailed(
                path: url.path,
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProvenanceWriterError.durabilitySyncFailed(
                path: url.path,
                code: errno
            )
        }
    }

    private func signatureReference(
        provider: String,
        artifact: ProvenanceSignatureArtifact,
        provenanceSHA256: String,
        relativeTo directory: URL
    ) -> ProvenanceSignatureReference {
        ProvenanceSignatureReference(
            provider: provider,
            provenanceSHA256: provenanceSHA256,
            signaturePath: storedPath(for: artifact.signatureURL, relativeTo: directory),
            publicKeyPath: storedPath(for: artifact.publicKeyURL, relativeTo: directory)
        )
    }

    private func storedPath(for url: URL, relativeTo directory: URL) -> String {
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        if standardizedURL.deletingLastPathComponent() == standardizedDirectory {
            return standardizedURL.lastPathComponent
        }
        return standardizedURL.path
    }

    private struct BundleOutputEntry {
        let descriptor: ProvenanceFileDescriptor
        let relativePath: String
    }

    private func bundleOutputEntries(
        from envelope: ProvenanceEnvelope,
        relativeTo bundleURL: URL
    ) -> [BundleOutputEntry] {
        let descriptors = envelope.steps.flatMap(\.outputs)
            + (envelope.output.map { [$0] } ?? [])
            + envelope.outputs
        var orderedKeys: [String] = []
        var entriesByKey: [String: BundleOutputEntry] = [:]
        var entries: [BundleOutputEntry] = []
        for descriptor in descriptors {
            guard let relativePath = Self.bundleRelativePath(for: descriptor.path, relativeTo: bundleURL),
                  !isDirectoryOutput(descriptor, relativePath: relativePath, bundleURL: bundleURL) else {
                continue
            }
            if entriesByKey[relativePath] == nil {
                orderedKeys.append(relativePath)
            }
            entriesByKey[relativePath] = BundleOutputEntry(descriptor: descriptor, relativePath: relativePath)
        }
        for key in orderedKeys {
            if let entry = entriesByKey[key] {
                entries.append(entry)
            }
        }
        return entries
    }

    private func isDirectoryOutput(
        _ descriptor: ProvenanceFileDescriptor,
        relativePath: String,
        bundleURL: URL
    ) -> Bool {
        let outputURL = descriptor.path.hasPrefix("/")
            ? URL(fileURLWithPath: descriptor.path)
            : bundleURL.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func bundleRelativePath(for path: String, relativeTo bundleURL: URL) -> String? {
        if path.hasPrefix("/") {
            let bundleComponents = bundleURL.standardizedFileURL.pathComponents
            let outputComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard outputComponents.starts(with: bundleComponents),
                  outputComponents.count > bundleComponents.count else {
                return nil
            }
            let relativeComponents = outputComponents.dropFirst(bundleComponents.count)
            guard relativeComponents.first != Self.bundleProvenanceDirectoryName else {
                return nil
            }
            return relativeComponents.joined(separator: "/")
        }

        let components = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty,
              !components.contains(".."),
              components.first != Self.bundleProvenanceDirectoryName else {
            return nil
        }
        return components.joined(separator: "/")
    }

    static func bundleOutputSidecarURL(
        forRelativeOutputPath relativePath: String,
        inProvenanceDirectory provenanceDirectory: URL
    ) -> URL {
        var components = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        let filename = (components.popLast() ?? "output") + ".lungfish-provenance.json"
        var directory = provenanceDirectory
        for component in components {
            directory = directory.appendingPathComponent(component, isDirectory: true)
        }
        return directory.appendingPathComponent(filename)
    }
}

extension ProvenanceEnvelope {
    public func focusedOnOutput(_ output: ProvenanceFileDescriptor) -> ProvenanceEnvelope {
        let retainedOutputByPath = [output.path: output]
        let focusedSteps = steps.compactMap { step -> ProvenanceStep? in
            let focusedOutputs = step.outputs.compactMap { retainedOutputByPath[$0.path] }
            guard !focusedOutputs.isEmpty || step.outputs.isEmpty else {
                return nil
            }
            return step.replacingOutputs(focusedOutputs)
        }
        let retainedInputPaths = Set(focusedSteps.flatMap { $0.inputs.map(\.path) })
        return ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            tool: tool,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files.compactMap { descriptor in
                if descriptor.role == .output {
                    return retainedOutputByPath[descriptor.path]
                }
                guard !focusedSteps.isEmpty else {
                    return descriptor
                }
                return retainedInputPaths.contains(descriptor.path) ? descriptor : nil
            },
            output: output,
            outputs: [output],
            steps: focusedSteps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: signatures,
            legacyWorkflowRun: nil
        )
    }

    func projectedToBundleOutputs(_ retainedOutputs: [ProvenanceFileDescriptor]) -> ProvenanceEnvelope {
        let retainedOutputByPath = Dictionary(
            retainedOutputs.map { ($0.path, $0) },
            uniquingKeysWith: { _, final in final }
        )
        let retainedPaths = Set(retainedOutputByPath.keys)
        let retainedFiles = files.filter { descriptor in
            descriptor.role != .output || retainedPaths.contains(descriptor.path)
        }.map { descriptor in
            descriptor.role == .output ? retainedOutputByPath[descriptor.path] ?? descriptor : descriptor
        }
        let projectedSteps = steps.map { step in
            ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                durableReplayArgv: step.durableReplayArgv,
                reproducibleCommand: step.reproducibleCommand,
                inputs: step.inputs,
                outputs: step.outputs.compactMap { retainedOutputByPath[$0.path] },
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
        let primaryOutput = output.flatMap { retainedOutputByPath[$0.path] }
            ?? retainedOutputs.first
        return ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            tool: tool,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: retainedFiles,
            output: primaryOutput,
            outputs: retainedOutputs,
            steps: projectedSteps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    func upsertingSignatureReference(_ reference: ProvenanceSignatureReference) -> ProvenanceEnvelope {
        let filtered = signatures.filter { $0.provider != reference.provider }
        return replacingSignatures(filtered + [reference])
    }

    func replacingSignatures(_ signatures: [ProvenanceSignatureReference]) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            tool: tool,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files,
            output: output,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: signatures,
            legacyWorkflowRun: legacyRun
        )
    }
}

private extension ProvenanceStep {
    func replacingOutputs(_ outputs: [ProvenanceFileDescriptor]) -> ProvenanceStep {
        ProvenanceStep(
            id: id,
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            inputs: inputs,
            outputs: outputs,
            exitStatus: exitStatus,
            wallTimeSeconds: wallTimeSeconds,
            peakMemoryBytes: peakMemoryBytes,
            stderr: stderr,
            dependsOn: dependsOn,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}

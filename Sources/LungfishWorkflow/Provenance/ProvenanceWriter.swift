// ProvenanceWriter.swift - Canonical provenance sidecar writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

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
        case .durabilitySyncFailed(let path, let code):
            return "Could not durably synchronize provenance artifact \(path): \(POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription)"
        }
    }
}

public struct ProvenanceWriter: Sendable {
    public static let provenanceFilename = ProvenanceRecorder.provenanceFilename
    public static let bundleProvenanceDirectoryName = "provenance"
    public static let bundleRollupFilename = "bundle.lungfish-provenance.json"
    public static let maximumBundleOutputSidecars = 100

    private let signingProvider: (any ProvenanceSigningProvider)?

    public init(signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider()) {
        self.signingProvider = signingProvider
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL {
        try write(envelope, to: directory, bundleLayoutRoot: directory)
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, to directory: URL, bundleLayoutRoot: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try writeUnsigned(envelope, toSidecar: provenanceURL)

        guard let signingProvider else {
            if envelope.signatures.isEmpty {
                try removeSigningArtifacts(for: provenanceURL)
            }
            return provenanceURL
        }

        let initialArtifact = try signingProvider.sign(provenanceURL: provenanceURL)
        let placeholderReference = signatureReference(
            provider: signingProvider.providerIdentifier,
            artifact: initialArtifact,
            provenanceSHA256: "",
            relativeTo: directory
        )
        let envelopeWithSignaturePaths = envelope.upsertingSignatureReference(placeholderReference)
        try writeUnsigned(envelopeWithSignaturePaths, toSidecar: provenanceURL)

        let signaturePathArtifact = try signingProvider.sign(provenanceURL: provenanceURL)
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
        let finalArtifact = try signingProvider.sign(provenanceURL: provenanceURL)
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

        var published: [(url: URL, identity: FileIdentity)] = []
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
                let result = artifact.staged.path.withCString { sourcePath in
                    artifact.destination.path.withCString { destinationPath in
                        Darwin.renameatx_np(
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
                published.append(
                    (artifact.destination, artifact.identity)
                )
            }
            try synchronizeDirectory(at: destinationDirectory)
        } catch {
            for artifact in published.reversed()
            where (try? fileIdentity(at: artifact.url)) == artifact.identity {
                _ = artifact.url.path.withCString { Darwin.unlink($0) }
            }
            try? synchronizeDirectory(at: destinationDirectory)
            throw error
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
        try FileManager.default.createDirectory(at: provenanceDirectory, withIntermediateDirectories: true)

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
            try fileManager.removeItem(at: standardizedCandidate)
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
        try data.write(to: provenanceURL, options: .atomic)
    }

    private func removeSigningArtifacts(for provenanceURL: URL) throws {
        let fileManager = FileManager.default
        for artifactURL in [
            ProvenanceSigningConfiguration.signatureURL(for: provenanceURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL),
        ] where fileManager.fileExists(atPath: artifactURL.path) {
            try fileManager.removeItem(at: artifactURL)
        }
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
        var metadata = stat()
        guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
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

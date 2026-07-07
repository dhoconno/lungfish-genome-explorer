// ProvenanceWriter.swift - Canonical provenance sidecar writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceWriterError: Error, LocalizedError, Sendable, Equatable {
    case unstableSignatureArtifact(
        provider: String,
        expectedSignaturePath: String,
        actualSignaturePath: String,
        expectedPublicKeyPath: String,
        actualPublicKeyPath: String
    )

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

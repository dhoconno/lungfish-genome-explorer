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

    private let signingProvider: (any ProvenanceSigningProvider)?

    public init(signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider()) {
        self.signingProvider = signingProvider
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provenanceURL = directory.appendingPathComponent(Self.provenanceFilename)
        let writtenURL = try write(envelope, toSidecar: provenanceURL)
        if Self.isBundleDirectory(directory) {
            _ = try writeBundleProvenanceLayout(envelope, toBundleRoot: directory)
        }
        return writtenURL
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, toSidecar provenanceURL: URL) throws -> URL {
        let directory = provenanceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try writeUnsigned(envelope, toSidecar: provenanceURL)

        guard let signingProvider else {
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
        let provenanceDirectory = bundleURL.appendingPathComponent(
            Self.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: provenanceDirectory, withIntermediateDirectories: true)

        let outputEntries = bundleOutputEntries(from: envelope, relativeTo: bundleURL)
        let rollupEnvelope = outputEntries.isEmpty
            ? envelope.replacingSignatures([])
            : envelope.projectedToBundleOutputs(outputEntries.map(\.descriptor))
        let rollupURL = provenanceDirectory.appendingPathComponent(Self.bundleRollupFilename)
        var writtenURLs = [try write(rollupEnvelope, toSidecar: rollupURL)]

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

        return writtenURLs
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
        let outputByPath = [output.path: output]
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
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files.map { descriptor in
                descriptor.role == .output ? outputByPath[descriptor.path] ?? descriptor : descriptor
            },
            output: output,
            outputs: [output],
            steps: steps.map { step in
                step.replacingOutputDescriptors(outputByPath)
            },
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
    func replacingOutputDescriptors(_ replacementsByPath: [String: ProvenanceFileDescriptor]) -> ProvenanceStep {
        ProvenanceStep(
            id: id,
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            inputs: inputs,
            outputs: outputs.map { replacementsByPath[$0.path] ?? $0 },
            exitStatus: exitStatus,
            wallTimeSeconds: wallTimeSeconds,
            stderr: stderr,
            dependsOn: dependsOn,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}

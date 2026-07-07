// FASTQAutoBundleWorkflow.swift - Provenanced wrapping of naked project FASTQ files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

struct FASTQAutoBundleResult: Sendable {
    let bundleURL: URL
    let payloadURL: URL
    let provenanceURL: URL
}

enum FASTQAutoBundleError: Error, LocalizedError, Sendable, Equatable {
    case sourceIsNotFASTQ(String)
    case sourceAlreadyInsideBundle(String)
    case destinationExists(String)
    case destinationParentUnavailable(String)
    case sourceProvenanceDoesNotDescribeSource(String)

    var errorDescription: String? {
        switch self {
        case .sourceIsNotFASTQ(let path):
            return "Source is not a FASTQ file: \(path)"
        case .sourceAlreadyInsideBundle(let path):
            return "FASTQ file is already inside a .\(FASTQBundle.directoryExtension) bundle: \(path)"
        case .destinationExists(let path):
            return "FASTQ bundle already exists: \(path)"
        case .destinationParentUnavailable(let path):
            return "Could not create FASTQ bundle parent directory: \(path)"
        case .sourceProvenanceDoesNotDescribeSource(let path):
            return "Source provenance does not describe the FASTQ being wrapped: \(path)"
        }
    }
}

enum FASTQAutoBundleWorkflow {
    private static let workflowName = "FASTQ Auto-Bundle"
    private static let toolName = "lungfish-app"

    static func wrapNakedFASTQ(
        sourceURL rawSourceURL: URL,
        bundleURL rawBundleURL: URL,
        runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
        fileManager: FileManager = .default,
        provenanceWriter: ProvenanceWriter = ProvenanceWriter(signingProvider: nil)
    ) throws -> FASTQAutoBundleResult {
        let sourceURL = rawSourceURL.standardizedFileURL
        let bundleURL = rawBundleURL.standardizedFileURL
        guard FASTQBundle.isFASTQFileURL(sourceURL) else {
            throw FASTQAutoBundleError.sourceIsNotFASTQ(sourceURL.path)
        }
        guard !FASTQBundle.isBundleURL(sourceURL.deletingLastPathComponent()) else {
            throw FASTQAutoBundleError.sourceAlreadyInsideBundle(sourceURL.path)
        }
        guard !fileManager.fileExists(atPath: bundleURL.path) else {
            throw FASTQAutoBundleError.destinationExists(bundleURL.path)
        }

        let parentURL = bundleURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            throw FASTQAutoBundleError.destinationParentUnavailable(parentURL.path)
        }

        let sourceMetadataURL = FASTQMetadataStore.metadataURL(for: sourceURL)
        let finalPayloadURL = bundleURL.appendingPathComponent(sourceURL.lastPathComponent)
        let finalMetadataURL = bundleURL.appendingPathComponent(sourceMetadataURL.lastPathComponent)
        let stagingBundleURL = stagingBundleURL(for: bundleURL)
        let stagingPayloadURL = stagingBundleURL.appendingPathComponent(sourceURL.lastPathComponent)
        let stagingMetadataURL = stagingBundleURL.appendingPathComponent(sourceMetadataURL.lastPathComponent)
        let startedAt = Date()
        let sourceDescriptor = try ProvenanceFileDescriptor.file(url: sourceURL, format: .fastq, role: .input)
        let sourceEnvelope = try loadSourceProvenanceEnvelope(for: sourceURL)
        let sourceHadMetadata = fileManager.fileExists(atPath: sourceMetadataURL.path)

        do {
            try fileManager.createDirectory(at: stagingBundleURL, withIntermediateDirectories: true)
            try fileManager.moveItem(at: sourceURL, to: stagingPayloadURL)
            if sourceHadMetadata {
                try fileManager.moveItem(at: sourceMetadataURL, to: stagingMetadataURL)
            }
            try fileManager.moveItem(at: stagingBundleURL, to: bundleURL)

            let completedAt = Date()
            let envelope = try provenanceEnvelope(
                sourceEnvelope: sourceEnvelope,
                sourceDescriptor: sourceDescriptor,
                sourceURL: sourceURL,
                bundleURL: bundleURL,
                payloadURL: finalPayloadURL,
                metadataURL: sourceHadMetadata ? finalMetadataURL : nil,
                startedAt: startedAt,
                completedAt: completedAt,
                runtimeIdentity: runtimeIdentity
            )
            try provenanceWriter.write(envelope, to: bundleURL)
            removeObsoleteSourceSidecar(for: sourceURL, fileManager: fileManager)
            return FASTQAutoBundleResult(
                bundleURL: bundleURL,
                payloadURL: finalPayloadURL,
                provenanceURL: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            )
        } catch {
            rollback(
                sourceURL: sourceURL,
                sourceMetadataURL: sourceMetadataURL,
                stagingBundleURL: stagingBundleURL,
                stagingPayloadURL: stagingPayloadURL,
                stagingMetadataURL: stagingMetadataURL,
                finalBundleURL: bundleURL,
                finalPayloadURL: finalPayloadURL,
                finalMetadataURL: finalMetadataURL,
                fileManager: fileManager
            )
            throw error
        }
    }

    private static func provenanceEnvelope(
        sourceEnvelope: ProvenanceEnvelope?,
        sourceDescriptor: ProvenanceFileDescriptor,
        sourceURL: URL,
        bundleURL: URL,
        payloadURL: URL,
        metadataURL: URL?,
        startedAt: Date,
        completedAt: Date,
        runtimeIdentity: ProvenanceRuntimeIdentity
    ) throws -> ProvenanceEnvelope {
        let bundleDescriptor = ProvenanceFileDescriptor(
            path: bundleURL.path,
            format: .unknown,
            role: .output,
            originPath: sourceURL.path
        )
        let payloadDescriptor = try ProvenanceFileDescriptor.file(
            url: payloadURL,
            format: .fastq,
            role: .output,
            originPath: sourceURL.path
        )
        let metadataDescriptor = try metadataURL.map {
            try ProvenanceFileDescriptor.file(url: $0, format: .json, role: .output)
        }
        let outputs = [bundleDescriptor, payloadDescriptor] + (metadataDescriptor.map { [$0] } ?? [])
        let argv = [
            toolName,
            "fastq",
            "auto-bundle",
            "--input",
            sourceURL.path,
            "--output",
            bundleURL.path
        ]
        let durableArgv = [
            toolName,
            "fastq",
            "auto-bundle",
            "--input",
            payloadURL.path,
            "--output",
            bundleURL.path
        ]
        let step = ProvenanceStep(
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: durableArgv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: [sourceDescriptor],
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )

        let rewrittenSourceEnvelope = try sourceEnvelope.map {
            let rewritten = try GUIImportedProvenanceRehydrator.rewriteOutputDescriptors(
                in: $0,
                pathMap: [sourceURL.path: payloadURL.path]
            )
            try validateRewrittenSourceEnvelope(rewritten, sourceURL: sourceURL)
            return rewritten
        }
        let sourceFiles = rewrittenSourceEnvelope?.files ?? []
        let sourceSteps = rewrittenSourceEnvelope?.steps ?? []
        let files = deduplicated(sourceFiles + [sourceDescriptor] + outputs + sourceSteps.flatMap { $0.inputs + $0.outputs })
        let explicitOptions: [String: ParameterValue] = [
            "sourceFASTQ": .file(sourceURL),
            "outputBundle": .file(bundleURL),
            "outputFASTQ": .file(payloadURL),
            "moveMode": .string("in-place-auto-bundle")
        ]
        let defaultOptions: [String: ParameterValue] = [
            "preserveFASTQMetadataSidecar": .boolean(true),
            "writeBundleProvenance": .boolean(true)
        ]
        return ProvenanceEnvelope(
            id: UUID(),
            createdAt: startedAt,
            workflowName: workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(name: toolName, version: WorkflowRun.currentAppVersion, kind: "app"),
            argv: argv,
            durableReplayArgv: durableArgv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: explicitOptions,
                defaults: defaultOptions,
                resolvedDefaults: defaultOptions.merging(explicitOptions) { _, explicit in explicit }
            ),
            runtimeIdentity: runtimeIdentity,
            files: files,
            output: bundleDescriptor,
            outputs: outputs,
            steps: sourceSteps + [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
    }

    private static func loadSourceProvenanceEnvelope(for sourceURL: URL) throws -> ProvenanceEnvelope? {
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: sourceURL)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return nil
        }
        return try ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL)
    }

    private static func validateRewrittenSourceEnvelope(
        _ envelope: ProvenanceEnvelope,
        sourceURL: URL
    ) throws {
        let sourcePath = sourceURL.standardizedFileURL.path
        let outputPaths = ([envelope.output].compactMap { $0 } + envelope.outputs + envelope.steps.flatMap(\.outputs))
            .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        if outputPaths.contains(sourcePath) {
            throw FASTQAutoBundleError.sourceProvenanceDoesNotDescribeSource(sourceURL.path)
        }
    }

    private static func stagingBundleURL(for bundleURL: URL) -> URL {
        let parentURL = bundleURL.deletingLastPathComponent()
        let name = bundleURL.deletingPathExtension().lastPathComponent
        return parentURL.appendingPathComponent(
            ".\(name).\(UUID().uuidString).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
    }

    private static func rollback(
        sourceURL: URL,
        sourceMetadataURL: URL,
        stagingBundleURL: URL,
        stagingPayloadURL: URL,
        stagingMetadataURL: URL,
        finalBundleURL: URL,
        finalPayloadURL: URL,
        finalMetadataURL: URL,
        fileManager: FileManager
    ) {
        if fileManager.fileExists(atPath: finalPayloadURL.path),
           !fileManager.fileExists(atPath: sourceURL.path) {
            try? fileManager.moveItem(at: finalPayloadURL, to: sourceURL)
        } else if fileManager.fileExists(atPath: stagingPayloadURL.path),
                  !fileManager.fileExists(atPath: sourceURL.path) {
            try? fileManager.moveItem(at: stagingPayloadURL, to: sourceURL)
        }

        if fileManager.fileExists(atPath: finalMetadataURL.path),
           !fileManager.fileExists(atPath: sourceMetadataURL.path) {
            try? fileManager.moveItem(at: finalMetadataURL, to: sourceMetadataURL)
        } else if fileManager.fileExists(atPath: stagingMetadataURL.path),
                  !fileManager.fileExists(atPath: sourceMetadataURL.path) {
            try? fileManager.moveItem(at: stagingMetadataURL, to: sourceMetadataURL)
        }

        try? fileManager.removeItem(at: finalBundleURL)
        try? fileManager.removeItem(at: stagingBundleURL)
    }

    private static func removeObsoleteSourceSidecar(for sourceURL: URL, fileManager: FileManager) {
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: sourceURL)
        if fileManager.fileExists(atPath: sidecarURL.path) {
            try? fileManager.removeItem(at: sidecarURL)
        }
    }

    private static func deduplicated(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result
    }

    private static func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-:=,+"))
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

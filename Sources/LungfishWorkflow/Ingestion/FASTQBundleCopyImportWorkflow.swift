// FASTQBundleCopyImportWorkflow.swift - Atomic import/copy for existing FASTQ bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct FASTQBundleCopyImportResult: Sendable {
    public let sourceBundleURL: URL
    public let bundleURL: URL
    public let copiedFileCount: Int
    public let totalCopiedBytes: UInt64
    public let provenanceURL: URL
    public let wallClockSeconds: TimeInterval
}

public enum FASTQBundleCopyImportError: Error, LocalizedError, Sendable, Equatable {
    case sourceIsNotFASTQBundle(String)
    case sourceProvenanceMissing(String)
    case destinationExists(String)
    case cannotCreateDestinationParent(String)
    case unsupportedSymlinkPayload(String)

    public var errorDescription: String? {
        switch self {
        case .sourceIsNotFASTQBundle(let path):
            return "Source is not a .lungfishfastq bundle: \(path)"
        case .sourceProvenanceMissing(let path):
            return "Source FASTQ bundle is missing readable provenance: \(path)"
        case .destinationExists(let path):
            return "Destination FASTQ bundle already exists: \(path)"
        case .cannotCreateDestinationParent(let path):
            return "Could not create destination directory: \(path)"
        case .unsupportedSymlinkPayload(let path):
            return "FASTQ bundle symlink payload must resolve to a regular file: \(path)"
        }
    }
}

public final class FASTQBundleCopyImportWorkflow: @unchecked Sendable {
    public struct CommandContext: Sendable {
        public let workflowName: String
        public let workflowVersion: String
        public let toolName: String
        public let toolVersion: String
        public let argv: [String]
        public let durableReplayArgv: [String]?
        public let reproducibleCommand: String
        public let explicitOptions: [String: ParameterValue]
        public let defaultOptions: [String: ParameterValue]
        public let resolvedOptions: [String: ParameterValue]
        public let runtimeIdentity: ProvenanceRuntimeIdentity
        public let stderr: String?

        public init(
            workflowName: String,
            workflowVersion: String = WorkflowRun.currentAppVersion,
            toolName: String,
            toolVersion: String = WorkflowRun.currentAppVersion,
            argv: [String],
            durableReplayArgv: [String]? = nil,
            reproducibleCommand: String? = nil,
            explicitOptions: [String: ParameterValue] = [:],
            defaultOptions: [String: ParameterValue] = [:],
            resolvedOptions: [String: ParameterValue] = [:],
            runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
            stderr: String? = nil
        ) {
            self.workflowName = workflowName
            self.workflowVersion = workflowVersion
            self.toolName = toolName
            self.toolVersion = toolVersion
            self.argv = argv
            self.durableReplayArgv = durableReplayArgv
            self.reproducibleCommand = reproducibleCommand ?? argv.map(shellEscape).joined(separator: " ")
            self.explicitOptions = explicitOptions
            self.defaultOptions = defaultOptions
            self.resolvedOptions = resolvedOptions
            self.runtimeIdentity = runtimeIdentity
            self.stderr = stderr
        }
    }

    private let fileManager: FileManager
    private let provenanceWriter: ProvenanceWriter

    public init(
        fileManager: FileManager = .default,
        provenanceWriter: ProvenanceWriter = ProvenanceWriter(signingProvider: nil)
    ) {
        self.fileManager = fileManager
        self.provenanceWriter = provenanceWriter
    }

    public func importBundle(
        sourceBundleURL: URL,
        outputURL: URL,
        context: CommandContext
    ) throws -> FASTQBundleCopyImportResult {
        let sourceBundleURL = sourceBundleURL.standardizedFileURL
        guard FASTQBundle.isBundleURL(sourceBundleURL) else {
            throw FASTQBundleCopyImportError.sourceIsNotFASTQBundle(sourceBundleURL.path)
        }

        let destinationBundleURL = resolvedDestinationBundleURL(
            outputURL: outputURL.standardizedFileURL,
            sourceBundleURL: sourceBundleURL
        )
        guard !fileManager.fileExists(atPath: destinationBundleURL.path) else {
            throw FASTQBundleCopyImportError.destinationExists(destinationBundleURL.path)
        }

        let parentURL = destinationBundleURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            throw FASTQBundleCopyImportError.cannotCreateDestinationParent(parentURL.path)
        }

        let startedAt = Date()
        let stagingBundleURL = stagingBundleURL(for: destinationBundleURL)
        var didPublishBundle = false
        do {
            let sourceProvenanceURL = try requiredSourceProvenanceURL(in: sourceBundleURL)
            try fileManager.copyItem(at: sourceBundleURL, to: stagingBundleURL)
            try removeProvenanceArtifacts(in: stagingBundleURL)
            try materializeSymlinkFiles(in: stagingBundleURL)
            let sourceFiles = try concreteFiles(in: sourceBundleURL)
            let copiedFiles = try concreteFiles(in: stagingBundleURL)
            let completedAt = Date()
            let sourceToStagingPathMap = sourceToTargetPathMap(
                sourceBundleURL: sourceBundleURL,
                targetBundleURL: stagingBundleURL,
                sourceFiles: sourceFiles
            )
            let sourceToDestinationPathMap = sourceToTargetPathMap(
                sourceBundleURL: sourceBundleURL,
                targetBundleURL: destinationBundleURL,
                sourceFiles: sourceFiles
            )
            let rehydratedSourceEnvelope: ProvenanceEnvelope
            do {
                let stagingSourceEnvelope = try ProvenanceRehydrator.rehydrateSelectedOutputs(
                    sourceDirectory: sourceBundleURL,
                    finalDirectory: stagingBundleURL,
                    pathMap: sourceToStagingPathMap,
                    argumentPathMap: sourceToDestinationPathMap
                )
                rehydratedSourceEnvelope = rewriteEnvelopePaths(
                    stagingSourceEnvelope,
                    pathMap: stagingToDestinationPathMap(
                        stagingBundleURL: stagingBundleURL,
                        destinationBundleURL: destinationBundleURL,
                        copiedFiles: copiedFiles
                    )
                )
            } catch ProvenanceRehydrationError.missingSourceProvenance {
                throw FASTQBundleCopyImportError.sourceProvenanceMissing(sourceBundleURL.path)
            }
            try removeProvenanceArtifacts(in: stagingBundleURL)
            let copyEnvelope = try provenanceEnvelope(
                context: context,
                sourceBundleURL: sourceBundleURL,
                destinationBundleURL: destinationBundleURL,
                copiedFilesRootURL: stagingBundleURL,
                sourceFiles: sourceFiles,
                copiedFiles: copiedFiles,
                sourceProvenancePath: sourceProvenanceURL.path,
                startedAt: startedAt,
                completedAt: completedAt
            )
            let envelope = mergedCopyImportEnvelope(
                sourceEnvelope: rehydratedSourceEnvelope,
                copyEnvelope: copyEnvelope
            )
            let totalCopiedBytes = copiedFiles.reduce(UInt64(0)) {
                $0 + ((try? ProvenanceFileHasher.fileSize(of: $1)) ?? 0)
            }
            try fileManager.moveItem(at: stagingBundleURL, to: destinationBundleURL)
            didPublishBundle = true
            try provenanceWriter.write(envelope, to: destinationBundleURL)
            return FASTQBundleCopyImportResult(
                sourceBundleURL: sourceBundleURL,
                bundleURL: destinationBundleURL,
                copiedFileCount: copiedFiles.count,
                totalCopiedBytes: totalCopiedBytes,
                provenanceURL: destinationBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename),
                wallClockSeconds: completedAt.timeIntervalSince(startedAt)
            )
        } catch {
            try? fileManager.removeItem(at: stagingBundleURL)
            if didPublishBundle {
                try? fileManager.removeItem(at: destinationBundleURL)
            }
            throw error
        }
    }

    public static func resolvedDestinationBundleURL(outputURL: URL, sourceBundleURL: URL) -> URL {
        let standardizedOutput = outputURL.standardizedFileURL
        if standardizedOutput.pathExtension.lowercased() == FASTQBundle.directoryExtension {
            return standardizedOutput
        }
        return standardizedOutput.appendingPathComponent(sourceBundleURL.lastPathComponent, isDirectory: true)
    }

    private func provenanceEnvelope(
        context: CommandContext,
        sourceBundleURL: URL,
        destinationBundleURL: URL,
        copiedFilesRootURL: URL,
        sourceFiles: [URL],
        copiedFiles: [URL],
        sourceProvenancePath: String?,
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let inputDescriptors = try sourceFiles.map {
            try ProvenanceFileDescriptor.file(
                url: $0,
                format: provenanceFormat(for: $0),
                role: .input,
                sourceProvenancePath: sourceProvenancePath
            )
        }
        let destinationDirectoryDescriptor = ProvenanceFileDescriptor(
            path: destinationBundleURL.path,
            format: .unknown,
            role: .output,
            originPath: sourceBundleURL.path,
            sourceProvenancePath: sourceProvenancePath
        )
        let outputDescriptors = try copiedFiles.map { copiedURL in
            let relativePath = relativePath(from: copiedFilesRootURL, to: copiedURL)
            let sourceURL = sourceBundleURL.appendingPathComponent(relativePath)
            let finalCopiedURL = destinationBundleURL.appendingPathComponent(relativePath)
            return ProvenanceFileDescriptor(
                path: finalCopiedURL.path,
                checksumSHA256: try ProvenanceFileHasher.sha256(of: copiedURL),
                fileSize: try ProvenanceFileHasher.fileSize(of: copiedURL),
                format: provenanceFormat(for: finalCopiedURL),
                role: .output,
                originPath: sourceURL.path,
                sourceProvenancePath: sourceProvenancePath
            )
        }
        let outputs = [destinationDirectoryDescriptor] + outputDescriptors
        let wallTime = completedAt.timeIntervalSince(startedAt)
        let step = ProvenanceStep(
            toolName: context.toolName,
            toolVersion: context.toolVersion,
            argv: context.argv,
            durableReplayArgv: context.durableReplayArgv,
            reproducibleCommand: context.reproducibleCommand,
            inputs: inputDescriptors,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: wallTime,
            stderr: context.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return ProvenanceEnvelope(
            id: UUID(),
            createdAt: startedAt,
            workflowName: context.workflowName,
            workflowVersion: context.workflowVersion,
            toolName: context.toolName,
            toolVersion: context.toolVersion,
            tool: ProvenanceToolIdentity(name: context.toolName, version: context.toolVersion, kind: "cli"),
            argv: context.argv,
            durableReplayArgv: context.durableReplayArgv,
            reproducibleCommand: context.reproducibleCommand,
            options: ProvenanceOptions(
                explicit: context.explicitOptions,
                defaults: context.defaultOptions,
                resolvedDefaults: context.resolvedOptions
            ),
            runtimeIdentity: context.runtimeIdentity,
            files: deduplicated(inputDescriptors + outputs),
            output: destinationDirectoryDescriptor,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: wallTime,
            exitStatus: 0,
            stderr: context.stderr
        )
    }

    private func mergedCopyImportEnvelope(
        sourceEnvelope: ProvenanceEnvelope,
        copyEnvelope: ProvenanceEnvelope
    ) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            schemaVersion: copyEnvelope.schemaVersion,
            id: copyEnvelope.id,
            createdAt: copyEnvelope.createdAt,
            workflowName: copyEnvelope.workflowName,
            workflowVersion: copyEnvelope.workflowVersion,
            toolName: copyEnvelope.toolName,
            toolVersion: copyEnvelope.toolVersion,
            githubReleaseVersion: copyEnvelope.githubReleaseVersion,
            tool: copyEnvelope.tool,
            argv: copyEnvelope.argv,
            durableReplayArgv: copyEnvelope.durableReplayArgv,
            reproducibleCommand: copyEnvelope.reproducibleCommand,
            options: copyEnvelope.options,
            runtimeIdentity: copyEnvelope.runtimeIdentity,
            files: deduplicated(sourceEnvelope.files + copyEnvelope.files),
            output: copyEnvelope.output,
            outputs: copyEnvelope.outputs,
            steps: sourceEnvelope.steps + copyEnvelope.steps,
            wallTimeSeconds: copyEnvelope.wallTimeSeconds,
            exitStatus: copyEnvelope.exitStatus,
            stderr: copyEnvelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private func resolvedDestinationBundleURL(outputURL: URL, sourceBundleURL: URL) -> URL {
        Self.resolvedDestinationBundleURL(outputURL: outputURL, sourceBundleURL: sourceBundleURL)
    }

    private func stagingBundleURL(for destinationBundleURL: URL) -> URL {
        let parentURL = destinationBundleURL.deletingLastPathComponent()
        let name = destinationBundleURL.deletingPathExtension().lastPathComponent
        let ext = destinationBundleURL.pathExtension
        return parentURL.appendingPathComponent(
            ".\(name).\(UUID().uuidString).\(ext)",
            isDirectory: true
        )
    }

    private func concreteFiles(in rootURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ProvenanceWriter.bundleProvenanceDirectoryName {
                enumerator.skipDescendants()
                continue
            }
            if isProvenanceArtifact(url) {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true || symlinkResolvesToRegularFile(url, values: values) {
                urls.append(url.standardizedFileURL)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func symlinkResolvesToRegularFile(_ url: URL, values: URLResourceValues) -> Bool {
        guard values.isSymbolicLink == true,
              let targetPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let targetURL = resolvedSymlinkTarget(targetPath, from: url)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func materializeSymlinkFiles(in rootURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == ProvenanceWriter.bundleProvenanceDirectoryName {
                enumerator.skipDescendants()
                continue
            }
            if isProvenanceArtifact(url) {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }

            let targetPath = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            let targetURL = resolvedSymlinkTarget(targetPath, from: url)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw FASTQBundleCopyImportError.unsupportedSymlinkPayload(url.path)
            }

            let materializedURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).materialized")
            try fileManager.copyItem(at: targetURL, to: materializedURL)
            try fileManager.removeItem(at: url)
            try fileManager.moveItem(at: materializedURL, to: url)
        }
    }

    private func resolvedSymlinkTarget(_ targetPath: String, from symlinkURL: URL) -> URL {
        let targetURL = targetPath.hasPrefix("/")
            ? URL(fileURLWithPath: targetPath)
            : symlinkURL.deletingLastPathComponent().appendingPathComponent(targetPath)
        return targetURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func requiredSourceProvenanceURL(in sourceBundleURL: URL) throws -> URL {
        guard let sourceProvenanceURL = sourceProvenanceURL(in: sourceBundleURL),
              (try ProvenanceEnvelopeReader.load(fromSidecar: sourceProvenanceURL)) != nil else {
            throw FASTQBundleCopyImportError.sourceProvenanceMissing(sourceBundleURL.path)
        }
        return sourceProvenanceURL
    }

    private func sourceProvenanceURL(in sourceBundleURL: URL) -> URL? {
        let sidecar = sourceBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        if fileManager.fileExists(atPath: sidecar.path) {
            return sidecar.standardizedFileURL
        }
        let rollup = sourceBundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        if fileManager.fileExists(atPath: rollup.path) {
            return rollup.standardizedFileURL
        }
        return nil
    }

    private func sourceToTargetPathMap(
        sourceBundleURL: URL,
        targetBundleURL: URL,
        sourceFiles: [URL]
    ) -> [String: String] {
        var pathMap = [
            sourceBundleURL.path: targetBundleURL.path
        ]
        for sourceFile in sourceFiles {
            let relativePath = relativePath(from: sourceBundleURL, to: sourceFile)
            pathMap[sourceFile.path] = targetBundleURL.appendingPathComponent(relativePath).path
        }
        return pathMap
    }

    private func stagingToDestinationPathMap(
        stagingBundleURL: URL,
        destinationBundleURL: URL,
        copiedFiles: [URL]
    ) -> [String: String] {
        var pathMap = [
            stagingBundleURL.path: destinationBundleURL.path
        ]
        for copiedFile in copiedFiles {
            let relativePath = relativePath(from: stagingBundleURL, to: copiedFile)
            pathMap[copiedFile.path] = destinationBundleURL.appendingPathComponent(relativePath).path
        }
        return pathMap
    }

    private func rewriteEnvelopePaths(
        _ envelope: ProvenanceEnvelope,
        pathMap: [String: String]
    ) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
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
            options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: envelope.files.map { rewriteDescriptor($0, pathMap: pathMap) },
            output: envelope.output.map { rewriteDescriptor($0, pathMap: pathMap) },
            outputs: envelope.outputs.map { rewriteDescriptor($0, pathMap: pathMap) },
            steps: envelope.steps.map { rewriteStep($0, pathMap: pathMap) },
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private func rewriteStep(_ step: ProvenanceStep, pathMap: [String: String]) -> ProvenanceStep {
        ProvenanceStep(
            id: step.id,
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            githubReleaseVersion: step.githubReleaseVersion,
            argv: step.argv,
            durableReplayArgv: step.durableReplayArgv,
            reproducibleCommand: step.reproducibleCommand,
            inputs: step.inputs.map { rewriteDescriptor($0, pathMap: pathMap) },
            outputs: step.outputs.map { rewriteDescriptor($0, pathMap: pathMap) },
            exitStatus: step.exitStatus,
            wallTimeSeconds: step.wallTimeSeconds,
            stderr: step.stderr,
            dependsOn: step.dependsOn,
            startedAt: step.startedAt,
            completedAt: step.completedAt
        )
    }

    private func rewriteDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        pathMap: [String: String]
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: rewritePath(descriptor.path, pathMap: pathMap),
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath.map { rewritePath($0, pathMap: pathMap) },
            sourceProvenancePath: descriptor.sourceProvenancePath.map { rewritePath($0, pathMap: pathMap) }
        )
    }

    private func rewritePath(_ path: String, pathMap: [String: String]) -> String {
        pathMap.reduce(path) { rewritten, entry in
            rewritten.replacingOccurrences(of: entry.key, with: entry.value)
        }
    }

    private func removeProvenanceArtifacts(in bundleURL: URL) throws {
        let rootSidecarURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        if fileManager.fileExists(atPath: rootSidecarURL.path) {
            try fileManager.removeItem(at: rootSidecarURL)
        }

        let provenanceDirectoryURL = bundleURL.appendingPathComponent(
            ProvenanceWriter.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: provenanceDirectoryURL.path) {
            try fileManager.removeItem(at: provenanceDirectoryURL)
        }

        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let url as URL in enumerator where isProvenanceArtifact(url) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func isProvenanceArtifact(_ url: URL) -> Bool {
        url.lastPathComponent == ProvenanceWriter.provenanceFilename
            || url.lastPathComponent.hasSuffix(".lungfish-provenance.json")
    }

    private func relativePath(from rootURL: URL, to childURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let childPath = childURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard childPath.hasPrefix(prefix) else {
            return childURL.lastPathComponent
        }
        return String(childPath.dropFirst(prefix.count))
    }

    private func provenanceFormat(for url: URL) -> FileFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".fastq") || name.hasSuffix(".fq")
            || name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq.gz") {
            return .fastq
        }
        if name.hasSuffix(".json") {
            return .json
        }
        if name.hasSuffix(".txt") || name.hasSuffix(".tsv") || name.hasSuffix(".csv") {
            return .text
        }
        return .unknown
    }

    private func deduplicated(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
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
}

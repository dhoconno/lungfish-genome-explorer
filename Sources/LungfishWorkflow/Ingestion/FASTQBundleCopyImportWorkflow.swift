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
    case sourceDestinationAlias(String)
    case cannotCreateDestinationParent(String)
    case unsupportedSymlinkPayload(String)
    /// A copied FASTQ file differs in size or digest from what the source bundle's record states for it. The
    /// path is the file in the source bundle.
    case payloadDoesNotMatchRecord(String)

    public var errorDescription: String? {
        switch self {
        case .payloadDoesNotMatchRecord(let path):
            return "\(URL(fileURLWithPath: path).lastPathComponent) does not match its provenance record and may be incomplete. Copy it again and retry."
        case .sourceIsNotFASTQBundle(let path):
            return "Source is not a .lungfishfastq bundle: \(path)"
        case .sourceProvenanceMissing(let path):
            return "Source FASTQ bundle is missing readable provenance: \(path)"
        case .sourceDestinationAlias(let path):
            return "Source and destination bundles must be separate locations: \(path)"
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
        provenanceWriter: ProvenanceWriter = ProvenanceWriter()
    ) {
        self.fileManager = fileManager
        self.provenanceWriter = provenanceWriter
    }

    public func importBundle(
        sourceBundleURL: URL,
        outputURL: URL,
        context: CommandContext,
        replaceExisting: Bool = false,
        checkCancellation: () throws -> Void = {}
    ) throws -> FASTQBundleCopyImportResult {
        let sourceBundleURL = sourceBundleURL.standardizedFileURL
        guard FASTQBundle.isBundleURL(sourceBundleURL) else {
            throw FASTQBundleCopyImportError.sourceIsNotFASTQBundle(sourceBundleURL.path)
        }

        let destinationBundleURL = resolvedDestinationBundleURL(
            outputURL: outputURL.standardizedFileURL,
            sourceBundleURL: sourceBundleURL
        )
        let sourcePath = sourceBundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destinationBundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourcePath != destinationPath,
              !destinationPath.hasPrefix(sourcePath + "/"),
              !sourcePath.hasPrefix(destinationPath + "/") else {
            throw FASTQBundleCopyImportError.sourceDestinationAlias(destinationBundleURL.path)
        }
        guard replaceExisting || !fileManager.fileExists(atPath: destinationBundleURL.path) else {
            throw FASTQBundleCopyImportError.destinationExists(destinationBundleURL.path)
        }

        let parentURL = destinationBundleURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            throw FASTQBundleCopyImportError.cannotCreateDestinationParent(parentURL.path)
        }

        let runClock = ProvenanceRunClock()
        let stagingBundleURL = stagingBundleURL(for: destinationBundleURL)
        let publication = try ScientificFilePublicationTransaction(protectedURLs: [destinationBundleURL], fileDestinations: [])
        do {
            let sourceProvenanceURL = try requiredSourceProvenanceURL(in: sourceBundleURL)
            try checkCancellation()
            try fileManager.copyItem(at: sourceBundleURL, to: stagingBundleURL)
            try removeProvenanceArtifacts(in: stagingBundleURL)
            try materializeSymlinkFiles(in: stagingBundleURL)
            let sourceFiles = try concreteFiles(in: sourceBundleURL)
            let copiedFiles = try concreteFiles(in: stagingBundleURL)
            let completedAt = runClock.now
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
                    argumentPathMap: sourceToDestinationPathMap,
                    cancellationCheck: checkCancellation
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
                startedAt: runClock.startedAt,
                completedAt: completedAt,
                checkCancellation: checkCancellation
            )
            // The record that is about to certify these files is checked against the source bundle's own record,
            // so a transfer cut short is refused here and the catch below discards the staged copy.
            try requireCopiedFASTQMatchesSourceRecord(
                copyEnvelope.outputs,
                sourceProvenanceURL: sourceProvenanceURL,
                sourceBundleURL: sourceBundleURL,
                destinationBundleURL: destinationBundleURL
            )
            let envelope = mergedCopyImportEnvelope(
                sourceEnvelope: rehydratedSourceEnvelope,
                copyEnvelope: copyEnvelope
            )
            let totalCopiedBytes = copiedFiles.reduce(UInt64(0)) {
                $0 + ((try? ProvenanceFileHasher.fileSize(of: $1)) ?? 0)
            }
            try publication.publish(stagedURL: stagingBundleURL, to: destinationBundleURL, replacingExisting: replaceExisting)
            try provenanceWriter.observingPublications { try publication.observe($0) }
                .write(envelope, to: destinationBundleURL)
            publication.commit()
            return FASTQBundleCopyImportResult(
                sourceBundleURL: sourceBundleURL,
                bundleURL: destinationBundleURL,
                copiedFileCount: copiedFiles.count,
                totalCopiedBytes: totalCopiedBytes,
                provenanceURL: destinationBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename),
                wallClockSeconds: completedAt.timeIntervalSince(runClock.startedAt)
            )
        } catch {
            try? fileManager.removeItem(at: stagingBundleURL)
            try publication.rollback(after: error)
        }
    }

    /// Refuses a copy whose FASTQ files differ from what the source bundle's record states for them, before
    /// anything is published. `copiedOutputs` are the outputs the copy step just described, with the digest and
    /// size it computed, so no payload is read again. A transfer cut short leaves a file whose size and digest
    /// differ from the record's, and the new record would otherwise certify the short file.
    ///
    /// Only the top-level outputs of the record count, by their path relative to the bundle, and only those that
    /// state a digest. The reads are the one part of the bundle that nothing rewrites after the record is
    /// written. `lungfish fastq platform` and the metadata editors rewrite the metadata files that the import's
    /// record also lists, so those files, and a file the record names without a digest, keep today's behaviour.
    private func requireCopiedFASTQMatchesSourceRecord(
        _ copiedOutputs: [ProvenanceFileDescriptor],
        sourceProvenanceURL: URL,
        sourceBundleURL: URL,
        destinationBundleURL: URL
    ) throws {
        guard let sourceRecord = try ProvenanceEnvelopeReader.load(fromSidecar: sourceProvenanceURL) else { return }
        var recorded: [String: ProvenanceFileDescriptor] = [:]
        for descriptor in (sourceRecord.output.map { [$0] } ?? []) + sourceRecord.outputs
        where descriptor.checksumSHA256 != nil {
            if let recordedPath = ProvenanceWriter.bundleRelativePath(for: descriptor.path, relativeTo: sourceBundleURL) {
                recorded[recordedPath] = descriptor
            }
        }
        for copied in copiedOutputs {
            let relativePath = relativePath(from: destinationBundleURL, to: URL(fileURLWithPath: copied.path))
            guard provenanceFormat(for: URL(fileURLWithPath: relativePath)) == .fastq,
                  let expected = recorded[relativePath] else { continue }
            let digestDiffers = expected.checksumSHA256?.lowercased() != copied.checksumSHA256?.lowercased()
            let sizeDiffers = expected.fileSize != nil && expected.fileSize != copied.fileSize
            if digestDiffers || sizeDiffers {
                throw FASTQBundleCopyImportError.payloadDoesNotMatchRecord(
                    sourceBundleURL.appendingPathComponent(relativePath).path
                )
            }
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
        completedAt: Date,
        checkCancellation: () throws -> Void
    ) throws -> ProvenanceEnvelope {
        let inputDescriptors = try sourceFiles.map {
            ProvenanceFileDescriptor(
                path: $0.path,
                checksumSHA256: try ProvenanceFileHasher.sha256(of: $0, cancellationCheck: checkCancellation),
                fileSize: try ProvenanceFileHasher.fileSize(of: $0),
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
                checksumSHA256: try ProvenanceFileHasher.sha256(of: copiedURL, cancellationCheck: checkCancellation),
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
        copyEnvelope.with {
            $0.files = deduplicated(sourceEnvelope.files + copyEnvelope.files)
            $0.steps = sourceEnvelope.steps + copyEnvelope.steps
            // The copy step succeeded, but a bundle copied from a cancelled or failed run is still that
            // run's partial result, so the copy keeps the status of the run it copies.
            if sourceEnvelope.status == .cancelled || sourceEnvelope.status == .failed {
                $0.status = sourceEnvelope.status
                $0.exitStatus = sourceEnvelope.exitStatus
            }
        }
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
        envelope.with { copy in
            copy.files = envelope.files.map { rewriteDescriptor($0, pathMap: pathMap) }
            copy.output = envelope.output.map { rewriteDescriptor($0, pathMap: pathMap) }
            copy.outputs = envelope.outputs.map { rewriteDescriptor($0, pathMap: pathMap) }
            copy.steps = envelope.steps.map { rewriteStep($0, pathMap: pathMap) }
        }
    }

    private func rewriteStep(_ step: ProvenanceStep, pathMap: [String: String]) -> ProvenanceStep {
        step.with { copy in
            copy.inputs = step.inputs.map { rewriteDescriptor($0, pathMap: pathMap) }
            copy.outputs = step.outputs.map { rewriteDescriptor($0, pathMap: pathMap) }
            // The rehydration rewrote the options with the replay command, so they name the destination.
        }
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

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
    case destinationExists(String)
    case cannotCreateDestinationParent(String)

    public var errorDescription: String? {
        switch self {
        case .sourceIsNotFASTQBundle(let path):
            return "Source is not a .lungfishfastq bundle: \(path)"
        case .destinationExists(let path):
            return "Destination FASTQ bundle already exists: \(path)"
        case .cannotCreateDestinationParent(let path):
            return "Could not create destination directory: \(path)"
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
        do {
            try fileManager.copyItem(at: sourceBundleURL, to: destinationBundleURL)
            let copiedFiles = try concreteFiles(in: destinationBundleURL)
            let sourceFiles = try concreteFiles(in: sourceBundleURL)
            let completedAt = Date()
            let sourceProvenancePath = sourceProvenanceURL(in: sourceBundleURL)?.path
            let envelope = try provenanceEnvelope(
                context: context,
                sourceBundleURL: sourceBundleURL,
                destinationBundleURL: destinationBundleURL,
                sourceFiles: sourceFiles,
                copiedFiles: copiedFiles,
                sourceProvenancePath: sourceProvenancePath,
                startedAt: startedAt,
                completedAt: completedAt
            )
            try provenanceWriter.write(envelope, to: destinationBundleURL)
            return FASTQBundleCopyImportResult(
                sourceBundleURL: sourceBundleURL,
                bundleURL: destinationBundleURL,
                copiedFileCount: copiedFiles.count,
                totalCopiedBytes: copiedFiles.reduce(UInt64(0)) {
                    $0 + ((try? ProvenanceFileHasher.fileSize(of: $1)) ?? 0)
                },
                provenanceURL: destinationBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename),
                wallClockSeconds: completedAt.timeIntervalSince(startedAt)
            )
        } catch {
            try? fileManager.removeItem(at: destinationBundleURL)
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
            let relativePath = relativePath(from: destinationBundleURL, to: copiedURL)
            let sourceURL = sourceBundleURL.appendingPathComponent(relativePath)
            return try ProvenanceFileDescriptor.file(
                url: copiedURL,
                format: provenanceFormat(for: copiedURL),
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

    private func resolvedDestinationBundleURL(outputURL: URL, sourceBundleURL: URL) -> URL {
        Self.resolvedDestinationBundleURL(outputURL: outputURL, sourceBundleURL: sourceBundleURL)
    }

    private func concreteFiles(in rootURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
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
            if url.lastPathComponent == ProvenanceWriter.provenanceFilename {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                urls.append(url.standardizedFileURL.resolvingSymlinksInPath())
            }
        }
        return urls.sorted { $0.path < $1.path }
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

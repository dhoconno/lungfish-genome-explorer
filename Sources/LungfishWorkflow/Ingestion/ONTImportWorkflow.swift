// ONTImportWorkflow.swift - Workflow-layer ONT import with canonical provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct ONTImportWorkflow: Sendable {
    public enum CallerKind: String, Sendable {
        case cli
        case gui
    }

    public enum ImportError: Error, LocalizedError, Sendable, Equatable {
        case outputAlreadyExists([String])

        public var errorDescription: String? {
            switch self {
            case .outputAlreadyExists(let paths):
                return "ONT import output already exists: \(paths.joined(separator: ", "))"
            }
        }
    }

    public struct CommandContext: Sendable {
        public let caller: CallerKind
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
            caller: CallerKind,
            workflowName: String,
            workflowVersion: String,
            toolName: String,
            toolVersion: String,
            argv: [String],
            durableReplayArgv: [String]? = nil,
            reproducibleCommand: String,
            explicitOptions: [String: ParameterValue],
            defaultOptions: [String: ParameterValue],
            resolvedOptions: [String: ParameterValue],
            runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
            stderr: String? = nil
        ) {
            self.caller = caller
            self.workflowName = workflowName
            self.workflowVersion = workflowVersion
            self.toolName = toolName
            self.toolVersion = toolVersion
            self.argv = argv
            self.durableReplayArgv = durableReplayArgv
            self.reproducibleCommand = reproducibleCommand
            self.explicitOptions = explicitOptions
            self.defaultOptions = defaultOptions
            self.resolvedOptions = resolvedOptions
            self.runtimeIdentity = runtimeIdentity
            self.stderr = stderr
        }
    }

    public struct Result: Sendable {
        public let importResult: ONTImportResult
        public let provenanceEnvelope: ProvenanceEnvelope
        public let provenanceURLs: [URL]

        public init(
            importResult: ONTImportResult,
            provenanceEnvelope: ProvenanceEnvelope,
            provenanceURLs: [URL]
        ) {
            self.importResult = importResult
            self.provenanceEnvelope = provenanceEnvelope
            self.provenanceURLs = provenanceURLs
        }
    }

    public typealias ProvenanceWriterClosure = @Sendable (ProvenanceEnvelope, URL) throws -> URL

    private let importer: ONTDirectoryImporter
    private let provenanceWriter: ProvenanceWriterClosure

    private struct RollbackPlan {
        let outputDirectory: URL
        let outputDirectoryExisted: Bool
        let bundleURLs: [URL]
        let preexistingOutputPaths: Set<String>
        let manifestURL: URL
        let provenanceURL: URL
    }

    public init(
        importer: ONTDirectoryImporter = ONTDirectoryImporter(),
        provenanceWriter: @escaping ProvenanceWriterClosure = { envelope, directory in
            try ProvenanceWriter().write(envelope, to: directory)
        }
    ) {
        self.importer = importer
        self.provenanceWriter = provenanceWriter
    }

    public func importDirectory(
        config: ONTImportConfig,
        context: CommandContext,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Result {
        let startedAt = Date()
        let layout = try importer.detectLayout(at: config.sourceDirectory)
        let importedBarcodeDirectories = layout.barcodeDirectories.filter {
            config.includeUnclassified || !$0.isUnclassified
        }
        let inputChunkURLs = importedBarcodeDirectories
            .flatMap(\.chunkFiles)
            .map(canonicalURL)
            .sorted { $0.path < $1.path }
        let plannedBundleURLs = expectedBundleURLs(
            outputDirectory: config.outputDirectory,
            barcodeDirectories: importedBarcodeDirectories
        )
        let rollbackPlan = makeRollbackPlan(
            outputDirectory: config.outputDirectory,
            plannedBundleURLs: plannedBundleURLs
        )
        try preflightOutputs(rollbackPlan)

        let importResult: ONTImportResult
        do {
            importResult = try await importer.importDirectory(config: config, progress: progress)
        } catch {
            rollback(rollbackPlan)
            throw error
        }
        let completedAt = Date()

        do {
            let outputURLs = try concreteOutputURLs(
                outputDirectory: config.outputDirectory,
                bundleURLs: importResult.bundleURLs
            )
            let inputDescriptors = try inputChunkURLs.map {
                try ProvenanceFileDescriptor.file(url: $0, format: .fastq, role: .input)
            }
            let outputDescriptors = try outputURLs.map {
                try ProvenanceFileDescriptor.file(
                    url: $0,
                    format: provenanceFormat(for: $0),
                    role: .output
                )
            }
            let envelope = try provenanceEnvelope(
                context: context,
                config: config,
                layout: layout,
                importedBarcodeCount: importedBarcodeDirectories.count,
                inputDescriptors: inputDescriptors,
                outputDescriptors: outputDescriptors,
                startedAt: startedAt,
                completedAt: completedAt
            )

            var provenanceURLs: [URL] = []
            provenanceURLs.append(try provenanceWriter(envelope, canonicalURL(config.outputDirectory)))
            for bundleURL in importResult.bundleURLs {
                provenanceURLs.append(try provenanceWriter(envelope, canonicalURL(bundleURL)))
            }

            return Result(
                importResult: importResult,
                provenanceEnvelope: envelope,
                provenanceURLs: provenanceURLs
            )
        } catch {
            rollback(rollbackPlan, additionalBundleURLs: importResult.bundleURLs)
            throw error
        }
    }

    private func provenanceEnvelope(
        context: CommandContext,
        config: ONTImportConfig,
        layout: ONTDirectoryLayout,
        importedBarcodeCount: Int,
        inputDescriptors: [ProvenanceFileDescriptor],
        outputDescriptors: [ProvenanceFileDescriptor],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        var defaults: [String: ParameterValue] = [
            "includeUnclassified": .boolean(false),
            "concurrency": .integer(4),
            "useVirtualConcatenation": .boolean(true),
        ]
        defaults.merge(context.defaultOptions) { _, contextValue in contextValue }

        var resolved = context.resolvedOptions
        resolved["input"] = .file(config.sourceDirectory)
        resolved["output"] = .file(config.outputDirectory)
        resolved["includeUnclassified"] = .boolean(config.includeUnclassified)
        resolved["concurrency"] = .integer(config.maxConcurrentBarcodes)
        resolved["useVirtualConcatenation"] = .boolean(config.useVirtualConcatenation)
        resolved["caller"] = .string(context.caller.rawValue)
        resolved["barcodeDirectoryCount"] = .integer(layout.barcodeDirectories.count)
        resolved["importedBarcodeDirectoryCount"] = .integer(importedBarcodeCount)
        resolved["chunkCount"] = .integer(inputDescriptors.count)

        let step = ProvenanceStep(
            toolName: context.toolName,
            toolVersion: context.toolVersion,
            argv: context.argv,
            durableReplayArgv: context.durableReplayArgv,
            reproducibleCommand: context.reproducibleCommand,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: context.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )

        return try ProvenanceRunBuilder(
            workflowName: context.workflowName,
            workflowVersion: context.workflowVersion,
            toolName: context.toolName,
            toolVersion: context.toolVersion
        )
        .argv(context.argv)
        .durableReplayArgv(context.durableReplayArgv)
        .reproducibleCommand(context.reproducibleCommand)
        .options(
            explicit: context.explicitOptions,
            defaults: defaults,
            resolved: resolved
        )
        .runtime(context.runtimeIdentity)
        .step(step)
        .complete(
            exitStatus: 0,
            stderr: context.stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )
    }

    private func concreteOutputURLs(outputDirectory: URL, bundleURLs: [URL]) throws -> [URL] {
        var urls = [
            canonicalURL(outputDirectory.appendingPathComponent(DemultiplexManifest.filename)),
        ]
        for bundleURL in bundleURLs {
            urls.append(contentsOf: try concreteFiles(in: bundleURL))
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func expectedBundleURLs(
        outputDirectory: URL,
        barcodeDirectories: [ONTBarcodeDirectory]
    ) -> [URL] {
        barcodeDirectories.map { barcodeDirectory in
            outputDirectory.appendingPathComponent(
                "\(barcodeDirectory.barcodeName).\(FASTQBundle.directoryExtension)",
                isDirectory: true
            )
        }
    }

    private func concreteFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
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
                urls.append(canonicalURL(url))
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
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
        return .unknown
    }

    private func makeRollbackPlan(outputDirectory: URL, plannedBundleURLs: [URL]) -> RollbackPlan {
        let fm = FileManager.default
        let manifestURL = outputDirectory.appendingPathComponent(DemultiplexManifest.filename)
        let provenanceURL = outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let outputDirectoryExisted = fm.fileExists(atPath: outputDirectory.path)
        var preexistingOutputPaths = Set<String>()
        for url in plannedBundleURLs + [manifestURL, provenanceURL] where fm.fileExists(atPath: url.path) {
            preexistingOutputPaths.insert(outputPathKey(url))
        }

        return RollbackPlan(
            outputDirectory: outputDirectory,
            outputDirectoryExisted: outputDirectoryExisted,
            bundleURLs: plannedBundleURLs,
            preexistingOutputPaths: preexistingOutputPaths,
            manifestURL: manifestURL,
            provenanceURL: provenanceURL
        )
    }

    private func preflightOutputs(_ plan: RollbackPlan) throws {
        let conflicts = (plan.bundleURLs + [plan.manifestURL, plan.provenanceURL])
            .filter { plan.preexistingOutputPaths.contains(outputPathKey($0)) }
            .map { $0.path }
            .sorted()
        guard conflicts.isEmpty else {
            throw ImportError.outputAlreadyExists(conflicts)
        }
    }

    private func rollback(
        _ plan: RollbackPlan,
        additionalBundleURLs: [URL] = []
    ) {
        let fm = FileManager.default
        let bundleURLs = (plan.bundleURLs + additionalBundleURLs).reduce(into: [String: URL]()) { result, url in
            result[outputPathKey(url)] = url
        }

        for (path, bundleURL) in bundleURLs where !plan.preexistingOutputPaths.contains(path) {
            try? fm.removeItem(at: bundleURL)
        }
        for url in [plan.manifestURL, plan.provenanceURL] where !plan.preexistingOutputPaths.contains(outputPathKey(url)) {
            try? fm.removeItem(at: url)
        }

        if !plan.outputDirectoryExisted,
           let contents = try? fm.contentsOfDirectory(atPath: plan.outputDirectory.path),
           contents.isEmpty {
            try? fm.removeItem(at: plan.outputDirectory)
        }
    }

    private func outputPathKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

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
        case optimizationRequiresFlattenedStorage
        case missingFlattenedPayload(String)

        public var errorDescription: String? {
            switch self {
            case .outputAlreadyExists(let paths):
                return "ONT import output already exists: \(paths.joined(separator: ", "))"
            case .optimizationRequiresFlattenedStorage:
                return "ONT import storage optimization requires flattened storage mode."
            case .missingFlattenedPayload(let path):
                return "ONT import could not find a flattened FASTQ payload in \(path)."
            }
        }
    }

    public struct OptimizationConfig: Sendable {
        public let optimizeStorage: Bool
        public let qualityBinning: QualityBinningScheme
        public let threads: Int

        public static let disabled = OptimizationConfig(optimizeStorage: false)

        public init(
            optimizeStorage: Bool,
            qualityBinning: QualityBinningScheme = .none,
            threads: Int = 4
        ) {
            self.optimizeStorage = optimizeStorage
            self.qualityBinning = qualityBinning
            self.threads = threads
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
    public typealias OptimizationRunnerClosure = @Sendable (
        URL,
        OptimizationConfig,
        @escaping @Sendable (Double, String) -> Void
    ) async throws -> [ProvenanceStep]

    private let importer: ONTDirectoryImporter
    private let provenanceWriter: ProvenanceWriterClosure
    private let optimizationRunner: OptimizationRunnerClosure

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
        },
        optimizationRunner: OptimizationRunnerClosure? = nil
    ) {
        self.importer = importer
        self.provenanceWriter = provenanceWriter
        self.optimizationRunner = optimizationRunner ?? ONTImportWorkflow.defaultOptimizationRunner
    }

    public func importDirectory(
        config: ONTImportConfig,
        context: CommandContext,
        optimization: OptimizationConfig = .disabled,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Result {
        if optimization.optimizeStorage && config.storageMode != .flattened {
            throw ImportError.optimizationRequiresFlattenedStorage
        }

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
        let importedOutputDescriptorsByBundle: [String: [ProvenanceFileDescriptor]]
        let optimizationStepsByBundle: [String: [ProvenanceStep]]
        do {
            importResult = try await importer.importDirectory(config: config, progress: progress)
            importedOutputDescriptorsByBundle = try concreteOutputDescriptorsByBundle(
                importResult.bundleURLs
            )
            optimizationStepsByBundle = try await optimizeImportedBundlesIfNeeded(
                bundleURLs: importResult.bundleURLs,
                config: config,
                optimization: optimization,
                progress: progress
            )
        } catch {
            rollback(rollbackPlan)
            throw error
        }
        let completedAt = Date()

        do {
            let inputDescriptors = try inputChunkURLs.map {
                try ProvenanceFileDescriptor.file(url: $0, format: .fastq, role: .input)
            }
            let parentOutputDescriptors = try parentOutputDescriptors(
                outputDirectory: config.outputDirectory,
                bundleURLs: importResult.bundleURLs
            )
            let parentEnvelope = try provenanceEnvelope(
                context: context,
                config: config,
                optimization: optimization,
                layout: layout,
                importedBarcodeCount: importedBarcodeDirectories.count,
                inputDescriptors: inputDescriptors,
                outputDescriptors: parentOutputDescriptors,
                startedAt: startedAt,
                completedAt: completedAt
            )

            var provenanceURLs: [URL] = []
            for bundleURL in importResult.bundleURLs {
                let barcodeDirectory = try barcodeDirectory(
                    forBundleURL: bundleURL,
                    in: importedBarcodeDirectories
                )
                let childInputDescriptors = try barcodeDirectory.chunkFiles
                    .map(canonicalURL)
                    .sorted { $0.path < $1.path }
                    .map {
                        try ProvenanceFileDescriptor.file(url: $0, format: .fastq, role: .input)
                    }
                let bundleKey = canonicalURL(bundleURL).path
                let childOutputDescriptors: [ProvenanceFileDescriptor]
                if let importedDescriptors = importedOutputDescriptorsByBundle[bundleKey] {
                    childOutputDescriptors = importedDescriptors
                } else {
                    childOutputDescriptors = try concreteFiles(in: bundleURL).map {
                        try ProvenanceFileDescriptor.file(
                            url: $0,
                            format: provenanceFormat(for: $0),
                            role: .output
                        )
                    }
                }
                let childEnvelope = try provenanceEnvelope(
                    context: context,
                    config: config,
                    optimization: optimization,
                    layout: layout,
                    importedBarcodeCount: 1,
                    inputDescriptors: childInputDescriptors,
                    outputDescriptors: childOutputDescriptors,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    barcodeName: barcodeDirectory.barcodeName,
                    bundleURL: bundleURL,
                    extraSteps: optimizationStepsByBundle[bundleKey] ?? []
                )
                provenanceURLs.append(try provenanceWriter(childEnvelope, canonicalURL(bundleURL)))
            }
            provenanceURLs.append(try provenanceWriter(parentEnvelope, canonicalURL(config.outputDirectory)))

            return Result(
                importResult: importResult,
                provenanceEnvelope: parentEnvelope,
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
        optimization: OptimizationConfig,
        layout: ONTDirectoryLayout,
        importedBarcodeCount: Int,
        inputDescriptors: [ProvenanceFileDescriptor],
        outputDescriptors: [ProvenanceFileDescriptor],
        startedAt: Date,
        completedAt: Date,
        barcodeName: String? = nil,
        bundleURL: URL? = nil,
        extraSteps: [ProvenanceStep] = []
    ) throws -> ProvenanceEnvelope {
        var defaults: [String: ParameterValue] = [
            "includeUnclassified": .boolean(false),
            "concurrency": .integer(4),
            "storageMode": .string(ONTImportStorageMode.chunked.rawValue),
            "optimizeStorage": .boolean(false),
            "qualityBinning": .string(QualityBinningScheme.none.rawValue),
            "useVirtualConcatenation": .boolean(true),
        ]
        defaults.merge(context.defaultOptions) { _, contextValue in contextValue }

        var resolved = context.resolvedOptions
        resolved["input"] = .file(config.sourceDirectory)
        resolved["output"] = .file(config.outputDirectory)
        resolved["includeUnclassified"] = .boolean(config.includeUnclassified)
        resolved["concurrency"] = .integer(config.maxConcurrentBarcodes)
        resolved["storageMode"] = .string(config.storageMode.rawValue)
        resolved["optimizeStorage"] = .boolean(optimization.optimizeStorage)
        resolved["qualityBinning"] = .string(optimization.qualityBinning.rawValue)
        resolved["useVirtualConcatenation"] = .boolean(config.useVirtualConcatenation)
        resolved["caller"] = .string(context.caller.rawValue)
        resolved["barcodeDirectoryCount"] = .integer(layout.barcodeDirectories.count)
        resolved["importedBarcodeDirectoryCount"] = .integer(importedBarcodeCount)
        resolved["chunkCount"] = .integer(inputDescriptors.count)
        if let barcodeName {
            resolved["barcode"] = .string(barcodeName)
        }
        if let bundleURL {
            resolved["bundle"] = .file(bundleURL)
        }

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

        var builder = ProvenanceRunBuilder(
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

        for extraStep in extraSteps {
            builder = builder.step(extraStep)
        }

        return try builder
        .complete(
            exitStatus: 0,
            stderr: context.stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )
    }

    private func parentOutputDescriptors(outputDirectory: URL, bundleURLs: [URL]) throws -> [ProvenanceFileDescriptor] {
        var descriptors = [
            try ProvenanceFileDescriptor.file(
                url: canonicalURL(outputDirectory.appendingPathComponent(DemultiplexManifest.filename)),
                format: .json,
                role: .output
            ),
        ]
        descriptors.append(contentsOf: bundleURLs.map { bundleURL in
            let canonicalBundleURL = canonicalURL(bundleURL)
            let childProvenanceURL = canonicalBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            return ProvenanceFileDescriptor(
                path: canonicalBundleURL.path,
                format: .unknown,
                role: .output,
                sourceProvenancePath: childProvenanceURL.path
            )
        })
        return descriptors.sorted { $0.path < $1.path }
    }

    private func concreteOutputDescriptorsByBundle(
        _ bundleURLs: [URL]
    ) throws -> [String: [ProvenanceFileDescriptor]] {
        var descriptorsByBundle: [String: [ProvenanceFileDescriptor]] = [:]
        for bundleURL in bundleURLs {
            descriptorsByBundle[canonicalURL(bundleURL).path] = try concreteFiles(in: bundleURL).map {
                try ProvenanceFileDescriptor.file(
                    url: $0,
                    format: provenanceFormat(for: $0),
                    role: .output
                )
            }
        }
        return descriptorsByBundle
    }

    private func optimizeImportedBundlesIfNeeded(
        bundleURLs: [URL],
        config: ONTImportConfig,
        optimization: OptimizationConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [String: [ProvenanceStep]] {
        guard optimization.optimizeStorage else { return [:] }
        guard config.storageMode == .flattened else {
            throw ImportError.optimizationRequiresFlattenedStorage
        }

        var stepsByBundle: [String: [ProvenanceStep]] = [:]

        for (index, bundleURL) in bundleURLs.enumerated() {
            let bundleKey = canonicalURL(bundleURL).path
            guard FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) != nil else {
                throw ImportError.missingFlattenedPayload(bundleURL.path)
            }

            stepsByBundle[bundleKey] = try await optimizationRunner(
                bundleURL,
                optimization,
                { fraction, message in
                    let bundleProgress = (Double(index) + fraction) / Double(max(1, bundleURLs.count))
                    progress(bundleProgress, "\(bundleURL.deletingPathExtension().lastPathComponent): \(message)")
                }
            )
        }

        return stepsByBundle
    }

    private static func defaultOptimizationRunner(
        bundleURL: URL,
        optimization: OptimizationConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [ProvenanceStep] {
        guard let payloadURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) else {
            throw ImportError.missingFlattenedPayload(bundleURL.path)
        }

        let pipeline = FASTQIngestionPipeline()
        let result = try await pipeline.run(
            config: FASTQIngestionConfig(
                inputFiles: [payloadURL],
                pairingMode: .singleEnd,
                outputDirectory: bundleURL,
                threads: max(1, optimization.threads),
                deleteOriginals: true,
                qualityBinning: optimization.qualityBinning,
                skipClumpify: false
            ),
            progress: progress
        )
        updateMetadataAfterOptimization(result: result, bundleURL: bundleURL)
        return result.provenanceSteps.map(ProvenanceStep.init(stepExecution:))
    }

    private static func updateMetadataAfterOptimization(
        result: FASTQIngestionResult,
        bundleURL: URL
    ) {
        var metadata = FASTQMetadataStore.load(for: bundleURL) ?? PersistedFASTQMetadata()
        metadata.ingestion = IngestionMetadata(
            isClumpified: result.wasClumpified,
            isCompressed: result.outputFile.pathExtension.lowercased() == "gz",
            pairingMode: .singleEnd,
            qualityBinning: result.qualityBinning.rawValue,
            originalFilenames: result.originalFilenames,
            ingestionDate: Date(),
            originalSizeBytes: result.originalSizeBytes
        )
        FASTQMetadataStore.save(metadata, for: bundleURL)
    }

    private func barcodeDirectory(
        forBundleURL bundleURL: URL,
        in barcodeDirectories: [ONTBarcodeDirectory]
    ) throws -> ONTBarcodeDirectory {
        let barcodeName = bundleURL.deletingPathExtension().lastPathComponent
        if let barcodeDirectory = barcodeDirectories.first(where: { $0.barcodeName == barcodeName }) {
            return barcodeDirectory
        }
        throw ONTImportError.notONTDirectory(bundleURL)
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

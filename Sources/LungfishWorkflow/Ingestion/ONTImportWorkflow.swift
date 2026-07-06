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
    /// Writes to a physical directory while using the third URL as the bundle root
    /// for relative provenance sidecars. Staged imports use this to record final paths.
    public typealias LayoutAwareProvenanceWriterClosure = @Sendable (ProvenanceEnvelope, URL, URL) throws -> URL
    public typealias OptimizationRunnerClosure = @Sendable (
        URL,
        OptimizationConfig,
        @escaping @Sendable (Double, String) -> Void
    ) async throws -> [ProvenanceStep]

    private let importer: ONTDirectoryImporter
    private let provenanceWriter: LayoutAwareProvenanceWriterClosure
    private let optimizationRunner: OptimizationRunnerClosure

    private struct RollbackPlan {
        let outputDirectory: URL
        let stagingOutputDirectory: URL
        let outputDirectoryExisted: Bool
        let bundleURLs: [URL]
        let metadataURLs: [URL]
        let preexistingOutputPaths: Set<String>
        let manifestURL: URL
        let provenanceURL: URL
    }

    public init(
        importer: ONTDirectoryImporter = ONTDirectoryImporter(),
        optimizationRunner: OptimizationRunnerClosure? = nil
    ) {
        self.init(
            importer: importer,
            layoutAwareProvenanceWriter: { envelope, directory, bundleLayoutRoot in
                try ProvenanceWriter().write(envelope, to: directory, bundleLayoutRoot: bundleLayoutRoot)
            },
            optimizationRunner: optimizationRunner
        )
    }

    public init(
        importer: ONTDirectoryImporter = ONTDirectoryImporter(),
        provenanceWriter: @escaping ProvenanceWriterClosure,
        optimizationRunner: OptimizationRunnerClosure? = nil
    ) {
        self.init(
            importer: importer,
            layoutAwareProvenanceWriter: { envelope, directory, _ in
                try provenanceWriter(envelope, directory)
            },
            optimizationRunner: optimizationRunner
        )
    }

    public init(
        importer: ONTDirectoryImporter = ONTDirectoryImporter(),
        layoutAwareProvenanceWriter: @escaping LayoutAwareProvenanceWriterClosure,
        optimizationRunner: OptimizationRunnerClosure? = nil
    ) {
        self.importer = importer
        self.provenanceWriter = layoutAwareProvenanceWriter
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

        let stagingConfig = stagedConfig(from: config, outputDirectory: rollbackPlan.stagingOutputDirectory)
        let stagedImportResult: ONTImportResult
        let stagedOptimizationStepsByBundle: [String: [ProvenanceStep]]
        do {
            stagedImportResult = try await importer.importDirectory(config: stagingConfig, progress: progress)
            stagedOptimizationStepsByBundle = try await optimizeImportedBundlesIfNeeded(
                bundleURLs: stagedImportResult.bundleURLs,
                config: stagingConfig,
                optimization: optimization,
                progress: progress
            )
        } catch {
            rollback(rollbackPlan)
            throw error
        }
        let completedAt = Date()

        do {
            _ = try writeImportProvenance(
                config: stagingConfig,
                context: context,
                optimization: optimization,
                layout: layout,
                importedBarcodeDirectories: importedBarcodeDirectories,
                inputChunkURLs: inputChunkURLs,
                importResult: stagedImportResult,
                optimizationStepsByBundle: stagedOptimizationStepsByBundle,
                startedAt: startedAt,
                completedAt: completedAt
            )

            try publishStagedOutputs(rollbackPlan)

            let finalImportResult = finalImportResult(
                from: stagedImportResult,
                outputDirectory: config.outputDirectory
            )
            let finalOptimizationStepsByBundle = remapOptimizationStepsByBundle(
                stagedOptimizationStepsByBundle,
                from: stagedImportResult.bundleURLs,
                to: finalImportResult.bundleURLs
            )
            let finalProvenance = try writeImportProvenance(
                config: config,
                context: context,
                optimization: optimization,
                layout: layout,
                importedBarcodeDirectories: importedBarcodeDirectories,
                inputChunkURLs: inputChunkURLs,
                importResult: finalImportResult,
                optimizationStepsByBundle: finalOptimizationStepsByBundle,
                startedAt: startedAt,
                completedAt: completedAt
            )

            return Result(
                importResult: finalImportResult,
                provenanceEnvelope: finalProvenance.envelope,
                provenanceURLs: finalProvenance.urls
            )
        } catch {
            rollback(rollbackPlan)
            throw error
        }
    }

    private func writeImportProvenance(
        config: ONTImportConfig,
        context: CommandContext,
        optimization: OptimizationConfig,
        layout: ONTDirectoryLayout,
        importedBarcodeDirectories: [ONTBarcodeDirectory],
        inputChunkURLs: [URL],
        importResult: ONTImportResult,
        optimizationStepsByBundle: [String: [ProvenanceStep]],
        startedAt: Date,
        completedAt: Date
    ) throws -> (envelope: ProvenanceEnvelope, urls: [URL]) {
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

        let importedOutputDescriptorsByBundle = try concreteOutputDescriptorsByBundle(importResult.bundleURLs)
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
            let childOutputDescriptors = importedOutputDescriptorsByBundle[bundleKey] ?? []
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
            provenanceURLs.append(try provenanceWriter(
                childEnvelope,
                canonicalURL(bundleURL),
                canonicalURL(bundleURL)
            ))
        }
        provenanceURLs.append(try provenanceWriter(
            parentEnvelope,
            canonicalURL(config.outputDirectory),
            canonicalURL(config.outputDirectory)
        ))

        return (parentEnvelope, provenanceURLs)
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

    private func stagedConfig(from config: ONTImportConfig, outputDirectory: URL) -> ONTImportConfig {
        ONTImportConfig(
            sourceDirectory: config.sourceDirectory,
            outputDirectory: outputDirectory,
            maxConcurrentBarcodes: config.maxConcurrentBarcodes,
            includeUnclassified: config.includeUnclassified,
            storageMode: config.storageMode
        )
    }

    private func finalImportResult(
        from stagedResult: ONTImportResult,
        outputDirectory: URL
    ) -> ONTImportResult {
        ONTImportResult(
            manifest: stagedResult.manifest,
            bundleURLs: stagedResult.bundleURLs.map {
                outputDirectory.appendingPathComponent($0.lastPathComponent, isDirectory: true)
            },
            flowCellID: stagedResult.flowCellID,
            sampleID: stagedResult.sampleID,
            basecallModel: stagedResult.basecallModel,
            totalReadCount: stagedResult.totalReadCount,
            wallClockSeconds: stagedResult.wallClockSeconds
        )
    }

    private func publishStagedOutputs(_ plan: RollbackPlan) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plan.outputDirectory, withIntermediateDirectories: true)
        let stagedArtifacts = try fm.contentsOfDirectory(
            at: plan.stagingOutputDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )

        for stagedURL in stagedArtifacts {
            let finalURL = plan.outputDirectory.appendingPathComponent(stagedURL.lastPathComponent)
            if fm.fileExists(atPath: finalURL.path) {
                throw ImportError.outputAlreadyExists([finalURL.path])
            }
            try fm.moveItem(at: stagedURL, to: finalURL)
        }

        try? fm.removeItem(at: plan.stagingOutputDirectory)
    }

    private func remapOptimizationStepsByBundle(
        _ stepsByStagedBundle: [String: [ProvenanceStep]],
        from stagedBundleURLs: [URL],
        to finalBundleURLs: [URL]
    ) -> [String: [ProvenanceStep]] {
        var remapped: [String: [ProvenanceStep]] = [:]
        for (stagedBundleURL, finalBundleURL) in zip(stagedBundleURLs, finalBundleURLs) {
            let stagedKey = canonicalURL(stagedBundleURL).path
            let finalKey = canonicalURL(finalBundleURL).path
            remapped[finalKey] = (stepsByStagedBundle[stagedKey] ?? []).map {
                remapOptimizationStep($0, from: stagedBundleURL, to: finalBundleURL)
            }
        }
        return remapped
    }

    private func remapOptimizationStep(
        _ step: ProvenanceStep,
        from stagedBundleURL: URL,
        to finalBundleURL: URL
    ) -> ProvenanceStep {
        ProvenanceStep(
            id: step.id,
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            githubReleaseVersion: step.githubReleaseVersion,
            argv: step.argv.map { remapPathString($0, from: stagedBundleURL, to: finalBundleURL) },
            durableReplayArgv: step.durableReplayArgv?.map {
                remapPathString($0, from: stagedBundleURL, to: finalBundleURL)
            },
            reproducibleCommand: remapPathString(step.reproducibleCommand, from: stagedBundleURL, to: finalBundleURL),
            inputs: step.inputs.map { remapDescriptor($0, from: stagedBundleURL, to: finalBundleURL) },
            outputs: step.outputs.map { remapDescriptor($0, from: stagedBundleURL, to: finalBundleURL) },
            exitStatus: step.exitStatus,
            wallTimeSeconds: step.wallTimeSeconds,
            stderr: step.stderr,
            dependsOn: step.dependsOn,
            startedAt: step.startedAt,
            completedAt: step.completedAt
        )
    }

    private func remapDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        from stagedBundleURL: URL,
        to finalBundleURL: URL
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: remapPathString(descriptor.path, from: stagedBundleURL, to: finalBundleURL),
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath.map {
                remapPathString($0, from: stagedBundleURL, to: finalBundleURL)
            },
            sourceProvenancePath: descriptor.sourceProvenancePath.map {
                remapPathString($0, from: stagedBundleURL, to: finalBundleURL)
            }
        )
    }

    private func remapPathString(_ value: String, from stagedBundleURL: URL, to finalBundleURL: URL) -> String {
        value.replacingOccurrences(
            of: canonicalURL(stagedBundleURL).path,
            with: canonicalURL(finalBundleURL).path
        )
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
        let stagingOutputDirectory = stagingOutputDirectory(for: outputDirectory)
        let manifestURL = outputDirectory.appendingPathComponent(DemultiplexManifest.filename)
        let provenanceURL = outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let metadataURLs = plannedBundleURLs.map(FASTQMetadataStore.metadataURL(for:))
        let outputDirectoryExisted = fm.fileExists(atPath: outputDirectory.path)
        var preexistingOutputPaths = Set<String>()
        for url in plannedBundleURLs + metadataURLs + [manifestURL, provenanceURL]
            where fm.fileExists(atPath: url.path) {
            preexistingOutputPaths.insert(outputPathKey(url))
        }

        return RollbackPlan(
            outputDirectory: outputDirectory,
            stagingOutputDirectory: stagingOutputDirectory,
            outputDirectoryExisted: outputDirectoryExisted,
            bundleURLs: plannedBundleURLs,
            metadataURLs: metadataURLs,
            preexistingOutputPaths: preexistingOutputPaths,
            manifestURL: manifestURL,
            provenanceURL: provenanceURL
        )
    }

    private func stagingOutputDirectory(for outputDirectory: URL) -> URL {
        outputDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputDirectory.lastPathComponent).ont-import-staging-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func preflightOutputs(_ plan: RollbackPlan) throws {
        let conflicts = (plan.bundleURLs + plan.metadataURLs + [plan.manifestURL, plan.provenanceURL])
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
        for url in plan.metadataURLs + [plan.manifestURL, plan.provenanceURL]
            where !plan.preexistingOutputPaths.contains(outputPathKey(url)) {
            try? fm.removeItem(at: url)
        }
        try? fm.removeItem(at: plan.stagingOutputDirectory)

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

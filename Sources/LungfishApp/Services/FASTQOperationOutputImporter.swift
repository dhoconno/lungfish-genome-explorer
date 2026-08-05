import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct IdentityFASTQOperationImporter: FASTQOperationDirectImporting {
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL] {
        _ = request
        _ = originalRequest
        _ = outputDirectory
        return outputURLs
    }
}

private struct AppReferenceBundleWrapper: ReferenceBundleWrapping {
    func importReferenceBundle(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String?
    ) async throws -> URL {
        let result = try await ReferenceBundleImportHelperLauncher.importAsReferenceBundleViaAppHelper(
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            preferredBundleName: preferredBundleName
        )
        return result.bundleURL
    }
}

struct AppFASTQOutputIngestor: FASTQOutputIngesting {
    func ingest(
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult {
        try await FASTQIngestionPipeline().run(config: config, progress: progress)
    }
}

struct AppFASTQOutputBundleWriter: FASTQOutputBundleWriting {
    let ingestor: any FASTQOutputIngesting

    init(ingestor: any FASTQOutputIngesting = AppFASTQOutputIngestor()) {
        self.ingestor = ingestor
    }

    func importFASTQOutput(
        sourceURL: URL,
        bundleURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?
    ) async throws -> URL {
        let fileManager = FileManager.default
        let finalBundleURL = bundleURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: finalBundleURL.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: finalBundleURL.path])
        }

        let stagingBundleURL = stagingBundleURL(for: finalBundleURL)
        var publishedFinalBundle = false
        do {
            try fileManager.createDirectory(
                at: finalBundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(at: stagingBundleURL, withIntermediateDirectories: true)

            let pairingMode = pairingMode(for: sourceInputURL)
            let stats = try await computeStatistics(from: sourceURL)

            let result = try await ingestor.ingest(
                config: FASTQIngestionConfig(
                    inputFiles: [sourceURL],
                    pairingMode: ingestionPipelinePairingMode(for: pairingMode),
                    outputDirectory: stagingBundleURL,
                    threads: max(1, ProcessInfo.processInfo.activeProcessorCount),
                    deleteOriginals: true,
                    qualityBinning: .illumina4,
                    skipClumpify: false
                ),
                progress: { _, _ in }
            )
            let finalOutputURL = finalBundleURL.appendingPathComponent(result.outputFile.lastPathComponent)

            var metadata = FASTQMetadataStore.load(for: result.outputFile) ?? PersistedFASTQMetadata()
            metadata.ingestion = IngestionMetadata(
                isClumpified: result.wasClumpified,
                isCompressed: result.outputFile.pathExtension.lowercased() == "gz",
                pairingMode: ingestionMetadataPairingMode(for: result.pairingMode),
                qualityBinning: result.qualityBinning.rawValue,
                originalFilenames: result.originalFilenames,
                ingestionDate: Date(),
                originalSizeBytes: result.originalSizeBytes,
                storageInputSizeBytes: result.originalSizeBytes,
                storageOutputSizeBytes: result.finalSizeBytes
            )
            FASTQMetadataStore.save(metadata, for: result.outputFile)

            let operation = try writeDerivedManifest(
                for: result.outputFile,
                in: stagingBundleURL,
                manifestBundleURL: finalBundleURL,
                sourceURL: sourceURL,
                recordedOutputURL: finalOutputURL,
                originalRequest: originalRequest,
                sourceInputURL: sourceInputURL,
                stats: stats,
                pairingMode: metadata.ingestion?.pairingMode
            )
            try await writeOperationProvenance(
                for: result.outputFile,
                in: stagingBundleURL,
                sourceURL: sourceURL,
                recordedOutputURL: result.outputFile,
                originalRequest: originalRequest,
                sourceInputURL: sourceInputURL,
                operation: operation
            )

            try fileManager.moveItem(at: stagingBundleURL, to: finalBundleURL)
            publishedFinalBundle = true
            do {
                try await writeOperationProvenance(
                    for: finalOutputURL,
                    in: finalBundleURL,
                    sourceURL: sourceURL,
                    recordedOutputURL: finalOutputURL,
                    originalRequest: originalRequest,
                    sourceInputURL: sourceInputURL,
                    operation: operation
                )
            } catch {
                try? fileManager.removeItem(at: finalBundleURL)
                throw error
            }

            return finalBundleURL
        } catch {
            try? fileManager.removeItem(at: stagingBundleURL)
            if publishedFinalBundle {
                try? fileManager.removeItem(at: finalBundleURL)
            }
            throw error
        }
    }

    private func stagingBundleURL(for finalBundleURL: URL) -> URL {
        finalBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(finalBundleURL.lastPathComponent).staging-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func computeStatistics(from sourceURL: URL) async throws -> FASTQDatasetStatistics {
        let reader = FASTQReader(validateSequence: false)
        return try await reader.computeStatistics(from: sourceURL, sampleLimit: 0).0
    }

    private func pairingMode(for sourceInputURL: URL?) -> IngestionMetadata.PairingMode {
        guard let sourceInputURL else { return .singleEnd }

        if FASTQBundle.isBundleURL(sourceInputURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: sourceInputURL),
           let pairingMode = manifest.pairingMode {
            return pairingMode
        }

        if let bundleURL = enclosingFASTQBundleURL(for: sourceInputURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL),
           let pairingMode = manifest.pairingMode {
            return pairingMode
        }

        let fastqURL: URL?
        if FASTQBundle.isFASTQFileURL(sourceInputURL) {
            fastqURL = sourceInputURL
        } else if let bundleURL = enclosingFASTQBundleURL(for: sourceInputURL) {
            fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)
        } else {
            fastqURL = nil
        }

        return fastqURL
            .flatMap { FASTQMetadataStore.load(for: $0)?.ingestion?.pairingMode }
            ?? .singleEnd
    }

    private func ingestionPipelinePairingMode(
        for pairingMode: IngestionMetadata.PairingMode
    ) -> FASTQIngestionConfig.PairingMode {
        switch pairingMode {
        case .singleEnd:
            return .singleEnd
        case .pairedEnd, .interleaved:
            return .interleaved
        }
    }

    private func ingestionMetadataPairingMode(
        for pairingMode: FASTQIngestionConfig.PairingMode
    ) -> IngestionMetadata.PairingMode {
        switch pairingMode {
        case .singleEnd:
            return .singleEnd
        case .pairedEnd:
            return .pairedEnd
        case .interleaved:
            return .interleaved
        }
    }

    private func writeDerivedManifest(
        for outputFASTQ: URL,
        in storageBundleURL: URL,
        manifestBundleURL: URL,
        sourceURL: URL,
        recordedOutputURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?,
        stats: FASTQDatasetStatistics,
        pairingMode: IngestionMetadata.PairingMode?
    ) throws -> FASTQDerivativeOperation {
        let operation = derivativeOperation(
            for: originalRequest,
            sourceURL: sourceURL,
            outputURL: recordedOutputURL
        )
        let parentBundleURL = sourceInputURL.flatMap(enclosingFASTQBundleURL(for:))
        let sourceManifest = parentBundleURL.flatMap { FASTQBundle.loadDerivedManifest(in: $0) }
        let baseLineage = sourceManifest?.lineage ?? []
        let checksum = try PayloadChecksum.sha256Hex(fileAt: outputFASTQ)

        let parentRelativePath = parentBundleURL.map {
            FASTQBundle.projectRelativePath(for: $0, from: manifestBundleURL)
                ?? FASTQOperationPlanner.relativePath(from: manifestBundleURL, to: $0)
                ?? "."
        } ?? "."

        let manifest = FASTQDerivedBundleManifest(
            name: manifestBundleURL.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: parentRelativePath,
            rootBundleRelativePath: ".",
            rootFASTQFilename: outputFASTQ.lastPathComponent,
            payload: .full(fastqFilename: outputFASTQ.lastPathComponent),
            lineage: baseLineage + [operation],
            operation: operation,
            cachedStatistics: stats,
            pairingMode: pairingMode,
            sequenceFormat: .fastq,
            payloadChecksums: PayloadChecksum(checksums: [
                outputFASTQ.lastPathComponent: checksum,
            ]),
            materializationState: .materialized(checksum: checksum)
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: storageBundleURL)
        return operation
    }

    private func writeOperationProvenance(
        for outputFASTQ: URL,
        in bundleURL: URL,
        sourceURL: URL,
        recordedOutputURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?,
        operation: FASTQDerivativeOperation
    ) async throws {
        _ = originalRequest
        _ = operation
        try FASTQOperationProvenanceRehydrator().rehydrateOperationOutput(
            sourceURL: sourceURL,
            finalDirectory: bundleURL,
            finalOutputURL: recordedOutputURL,
            sourceInputURL: sourceInputURL
        )
    }

    private func derivativeOperation(
        for request: FASTQOperationLaunchRequest,
        sourceURL: URL,
        outputURL: URL
    ) -> FASTQDerivativeOperation {
        guard case .derivative(let derivativeRequest, _, _) = request else {
            return FASTQDerivativeOperation(
                kind: .deduplicate,
                toolUsed: "lungfish",
                toolCommand: "lungfish \(sourceURL.path) -o \(outputURL.path)"
            )
        }

        let kind = FASTQDerivativeOperationKind(rawValue: derivativeRequest.operationKindString) ?? .deduplicate
        switch derivativeRequest {
        case .ribosomalRNAFilter(let retention, let ensure):
            let outputRetention = riboDetectorRetention(for: outputURL, fallback: retention)
            return FASTQDerivativeOperation(
                kind: .ribosomalRNAFilter,
                riboDetectorRetention: outputRetention,
                riboDetectorEnsure: ensure,
                toolUsed: "deacon",
                toolCommand: derivativeRequest.cliCommand(inputPath: sourceURL.path, outputPath: outputURL.path)
            )

        default:
            return FASTQDerivativeOperation(
                kind: kind,
                toolUsed: CLICommandIdentity.executableName,
                toolCommand: derivativeRequest.cliCommand(inputPath: sourceURL.path, outputPath: outputURL.path)
            )
        }
    }

    private func riboDetectorRetention(
        for outputURL: URL,
        fallback: FASTQRiboDetectorRetention
    ) -> FASTQRiboDetectorRetention {
        let filename = outputURL.lastPathComponent.lowercased()
        if filename.contains(".norrna.") || filename.contains("-norrna") || filename.contains("_norrna") {
            return .nonRRNA
        }
        if filename.contains(".rrna.") || filename.contains("-rrna") || filename.contains("_rrna") {
            return .rRNA
        }
        return fallback
    }

    private func enclosingFASTQBundleURL(for url: URL) -> URL? {
        if FASTQBundle.isBundleURL(url) {
            return url
        }
        return SequenceInputResolver.enclosingFASTQBundleURL(for: url)
    }
}

struct BundleFASTQOperationImporter: FASTQOperationDirectImporting {
    let destinationDirectory: URL
    let referenceBundleWrapper: any ReferenceBundleWrapping
    let fastqBundleWriter: any FASTQOutputBundleWriting

    init(
        destinationDirectory: URL,
        referenceBundleWrapper: any ReferenceBundleWrapping = AppReferenceBundleWrapper(),
        fastqBundleWriter: any FASTQOutputBundleWriting = AppFASTQOutputBundleWriter()
    ) {
        self.destinationDirectory = destinationDirectory
        self.referenceBundleWrapper = referenceBundleWrapper
        self.fastqBundleWriter = fastqBundleWriter
    }

    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL] {
        switch originalRequest {
        case .refreshQCSummary(let inputURLs):
            guard let reportURL = outputURLs.first else { return inputURLs }
            let mutations = try applyQCSummaryReport(from: reportURL, to: inputURLs)
            let provenanceSnapshot = try ProvenancePublicationSnapshot(
                urls: qCSummaryProvenanceArtifacts(for: mutations),
                backupNamePrefix: "lungfish-fastq-qc-summary-refresh"
            )
            do {
                try writeQCSummaryRefreshProvenance(
                    reportURL: reportURL,
                    mutations: mutations,
                    resolvedRequest: request,
                    originalRequest: originalRequest
                )
                provenanceSnapshot.discard()
            } catch {
                try throwAfterProvenancePublicationFailure(error) {
                    try restoreQCSummaryMutations(mutations)
                    try provenanceSnapshot.restore()
                }
            }
            return inputURLs.map(selectableSourceURL(for:))

        case .derivative(.demultiplex, _, _):
            return [outputDirectory]

        case .ontFluidigmSampleSplit, .ontPacBioBarcodeDemux:
            return try rehydrateONTFluidigmSampleBundles(
                outputURLs,
                originalRequest: originalRequest,
                outputDirectory: outputDirectory
            )

        case .derivative:
            return try await importSequenceOutputs(outputURLs, originalRequest: originalRequest)

        case .pbaa:
            return outputURLs

        case .savont:
            try validateSavontOutputsHaveCanonicalProvenance(outputURLs)
            return outputURLs

        default:
            return outputURLs
        }
    }

    private func validateSavontOutputsHaveCanonicalProvenance(_ outputURLs: [URL]) throws {
        for outputURL in outputURLs {
            let standardizedOutputURL = outputURL.standardizedFileURL
            let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: standardizedOutputURL)
            let resourceValues = try? standardizedOutputURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true,
                  FileManager.default.fileExists(atPath: sidecarURL.path) else {
                throw ProvenanceRehydrationError.missingSourceProvenance(
                    "Savont output is missing its canonical provenance sidecar: \(standardizedOutputURL.path)"
                )
            }

            let envelope: ProvenanceEnvelope
            do {
                envelope = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: sidecarURL))
            } catch {
                throw ProvenanceRehydrationError.missingSourceProvenance(
                    "Savont output has invalid canonical provenance: \(sidecarURL.path)"
                )
            }

            guard envelope.workflowName == "lungfish fastq savont-cluster",
                  envelope.toolName == "savont",
                  envelope.exitStatus == 0,
                  let durableArgv = envelope.durableReplayArgv,
                  durableArgv.count >= 3,
                  URL(fileURLWithPath: durableArgv[0]).lastPathComponent == CLICommandIdentity.executableName,
                  Array(durableArgv[1...2]) == ["fastq", "savont-cluster"],
                  let outputArgumentIndex = durableArgv.firstIndex(of: "--output"),
                  durableArgv.indices.contains(outputArgumentIndex + 1),
                  URL(fileURLWithPath: durableArgv[outputArgumentIndex + 1]).standardizedFileURL
                    == standardizedOutputURL,
                  let descriptor = envelope.output,
                  descriptor.role == .output,
                  descriptor.format == .fasta,
                  URL(fileURLWithPath: descriptor.path).standardizedFileURL == standardizedOutputURL,
                  let expectedChecksum = descriptor.checksumSHA256,
                  let expectedFileSize = descriptor.fileSize else {
                throw ProvenanceRehydrationError.missingSourceProvenance(
                    "Savont provenance does not describe a successful canonical clustering output: \(standardizedOutputURL.path)"
                )
            }

            do {
                let actualChecksum = try ProvenanceFileHasher.sha256(of: standardizedOutputURL)
                let actualFileSize = try ProvenanceFileHasher.fileSize(of: standardizedOutputURL)
                guard expectedChecksum.lowercased() == actualChecksum,
                      expectedFileSize == actualFileSize else {
                    throw ProvenanceRehydrationError.missingSourceProvenance(
                        "Savont output does not match its canonical provenance integrity record: \(standardizedOutputURL.path)"
                    )
                }
            } catch let error as ProvenanceRehydrationError {
                throw error
            } catch {
                throw ProvenanceRehydrationError.missingSourceProvenance(
                    "Savont output integrity could not be verified: \(standardizedOutputURL.path)"
                )
            }
        }
    }

    private func rehydrateONTFluidigmSampleBundles(
        _ outputURLs: [URL],
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) throws -> [URL] {
        _ = originalRequest
        let bundleURLs = outputURLs
            .filter { FASTQBundle.isBundleURL($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !bundleURLs.isEmpty else { return [] }

        for bundleURL in bundleURLs {
            guard let payloadURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) else {
                throw ProvenanceRehydrationError.missingSourceProvenance(
                    "ONT Fluidigm sample bundle has no primary FASTQ payload: \(bundleURL.path)"
                )
            }
            var pathMap = [payloadURL.path: payloadURL.standardizedFileURL.path]
            pathMap[payloadURL.standardizedFileURL.path] = payloadURL.standardizedFileURL.path
            try ProvenanceRehydrator.rehydrateSelectedOutputs(
                sourceDirectory: outputDirectory,
                finalDirectory: bundleURL,
                pathMap: pathMap
            )
        }

        return bundleURLs
    }

    private func importSequenceOutputs(
        _ outputURLs: [URL],
        originalRequest: FASTQOperationLaunchRequest
    ) async throws -> [URL] {
        guard !outputURLs.isEmpty else { return [] }

        var importedBundleURLs: [URL] = []
        for (index, outputURL) in outputURLs.enumerated() {
            let bundleBaseName = bundleNameStem(
                for: originalRequest,
                outputURL: outputURL,
                index: index
            )

            if SequenceFormat.from(url: outputURL) == .fasta {
                let referenceBundleURL = try await referenceBundleWrapper.importReferenceBundle(
                    sourceURL: outputURL,
                    outputDirectory: destinationDirectory,
                    preferredBundleName: bundleBaseName
                )
                try FASTQOperationProvenanceRehydrator().rehydrateReferenceBundleProvenance(
                    sourceURL: outputURL,
                    referenceBundleURL: referenceBundleURL
                )
                importedBundleURLs.append(referenceBundleURL)
                continue
            }

            guard FASTQBundle.isFASTQFileURL(outputURL) else {
                importedBundleURLs.append(outputURL)
                continue
            }

            let bundleURL = uniqueBundleURL(named: bundleBaseName)
            let sourceInputURL = sourceInputURL(forOutputAt: index, request: originalRequest)
            let importedURL = try await fastqBundleWriter.importFASTQOutput(
                sourceURL: outputURL,
                bundleURL: bundleURL,
                originalRequest: originalRequest,
                sourceInputURL: sourceInputURL
            )
            importedBundleURLs.append(importedURL)
        }

        return importedBundleURLs
    }

    private func bundleNameStem(
        for request: FASTQOperationLaunchRequest,
        outputURL: URL,
        index: Int
    ) -> String {
        let inputStem = sourceInputURL(forOutputAt: index, request: request)
            .map(FASTQOperationPlanner.sanitizedStem(for:))
            ?? FASTQOperationPlanner.sanitizedStem(for: outputURL)
        let operationStem = operationStem(for: request, outputURL: outputURL)
        return "\(inputStem)-\(operationStem)"
    }

    private func sourceInputURL(
        forOutputAt index: Int,
        request: FASTQOperationLaunchRequest
    ) -> URL? {
        if request.inputURLs.count == 1 {
            return request.inputURLs.first
        }
        return request.inputURLs[safe: index]
    }

    private func operationStem(
        for request: FASTQOperationLaunchRequest,
        outputURL: URL
    ) -> String {
        guard case .derivative(let derivativeRequest, _, _) = request,
              case .ribosomalRNAFilter = derivativeRequest else {
            return request.outputNameStem
        }

        let filename = outputURL.lastPathComponent.lowercased()
        if filename.contains(".norrna.") || filename.contains("-norrna") || filename.contains("_norrna") {
            return "deacon-ribo-norrna"
        }
        if filename.contains(".rrna.") || filename.contains("-rrna") || filename.contains("_rrna") {
            return "deacon-ribo-rrna"
        }
        return request.outputNameStem
    }

    private func uniqueBundleURL(named baseName: String) -> URL {
        let ext = FASTQBundle.directoryExtension
        let initialURL = destinationDirectory.appendingPathComponent("\(baseName).\(ext)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: initialURL.path) else {
            var counter = 2
            var candidate = destinationDirectory.appendingPathComponent("\(baseName)-\(counter).\(ext)", isDirectory: true)
            while FileManager.default.fileExists(atPath: candidate.path) {
                counter += 1
                candidate = destinationDirectory.appendingPathComponent("\(baseName)-\(counter).\(ext)", isDirectory: true)
            }
            return candidate
        }

        return initialURL
    }

    private struct QCSummaryMutation {
        let bundleURL: URL
        let targetURL: URL
        let originalData: Data?
    }

    private func applyQCSummaryReport(from reportURL: URL, to inputURLs: [URL]) throws -> [QCSummaryMutation] {
        let data = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(FASTQQCSummaryReport.self, from: data)
        var mutations: [QCSummaryMutation] = []

        for (entry, inputURL) in zip(report.inputs, inputURLs) {
            if FASTQBundle.isDerivedBundle(inputURL),
               let manifest = FASTQBundle.loadDerivedManifest(in: inputURL) {
                let manifestURL = FASTQBundle.derivedManifestURL(in: inputURL)
                let originalData = try? Data(contentsOf: manifestURL)
                let updatedManifest = FASTQDerivedBundleManifest(
                    id: manifest.id,
                    name: manifest.name,
                    createdAt: manifest.createdAt,
                    parentBundleRelativePath: manifest.parentBundleRelativePath,
                    rootBundleRelativePath: manifest.rootBundleRelativePath,
                    rootFASTQFilename: manifest.rootFASTQFilename,
                    payload: manifest.payload,
                    lineage: manifest.lineage,
                    operation: manifest.operation,
                    cachedStatistics: entry.statistics,
                    pairingMode: manifest.pairingMode,
                    readClassification: manifest.readClassification,
                    batchOperationID: manifest.batchOperationID,
                    sequenceFormat: manifest.sequenceFormat,
                    provenance: manifest.provenance,
                    payloadChecksums: manifest.payloadChecksums
                )
                try FASTQBundle.saveDerivedManifest(updatedManifest, in: inputURL)
                mutations.append(QCSummaryMutation(
                    bundleURL: inputURL,
                    targetURL: manifestURL,
                    originalData: originalData
                ))
                continue
            }

            guard let fastqURL = writableFASTQURL(for: inputURL) else { continue }
            let metadataURL = FASTQMetadataStore.metadataURL(for: fastqURL)
            let originalData = try? Data(contentsOf: metadataURL)
            var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
            metadata.computedStatistics = entry.statistics
            FASTQMetadataStore.save(metadata, for: fastqURL)
            mutations.append(QCSummaryMutation(
                bundleURL: enclosingFASTQBundleURL(for: inputURL) ?? fastqURL.deletingLastPathComponent(),
                targetURL: metadataURL,
                originalData: originalData
            ))
        }

        return mutations
    }

    private func writeQCSummaryRefreshProvenance(
        reportURL: URL,
        mutations: [QCSummaryMutation],
        resolvedRequest: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest
    ) throws {
        let sourceEnvelope = try ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: reportURL)
        )
        let startedAt = Date()
        let completedAt = startedAt
        let groupedMutations = Dictionary(grouping: mutations, by: { $0.bundleURL.standardizedFileURL })

        for (bundleURL, bundleMutations) in groupedMutations {
            let outputDescriptors = try bundleMutations.map {
                try ProvenanceFileDescriptor.file(url: $0.targetURL, format: .json, role: .output)
            }
            let reportInput = try ProvenanceFileDescriptor.file(url: reportURL, format: .json, role: .input)
            let argv = qCSummaryRefreshArgv(
                reportURL: reportURL,
                bundleURL: bundleURL,
                mutations: bundleMutations
            )
            let step = ProvenanceStep(
                toolName: "lungfish-app-action:fastq-refresh-qc-summary-import",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                inputs: [reportInput],
                outputs: outputDescriptors,
                exitStatus: 0,
                wallTimeSeconds: 0,
                startedAt: startedAt,
                completedAt: completedAt
            )

            var builder = ProvenanceRunBuilder(
                workflowName: "lungfish fastq refresh-qc-summary import",
                workflowVersion: WorkflowRun.currentAppVersion,
                toolName: "lungfish-app-action:fastq-refresh-qc-summary-import",
                toolVersion: WorkflowRun.currentAppVersion
            )
            .argv(argv)
            .options(
                explicit: [
                    "report": .string(reportURL.path),
                    "bundle": .string(bundleURL.path),
                    "targets": .array(bundleMutations.map { .string($0.targetURL.path) }),
                ],
                defaults: [:],
                resolved: [
                    "originalRequest": .string(String(describing: originalRequest)),
                    "resolvedRequest": .string(String(describing: resolvedRequest)),
                ]
            )
            .runtime(ProvenanceRuntimeIdentity())

            if let sourceEnvelope {
                for sourceStep in sourceEnvelope.steps {
                    builder = builder.step(sourceStep)
                }
            }
            builder = builder.step(step)
            for mutation in bundleMutations {
                builder = try builder.output(mutation.targetURL, format: .json, role: .output)
            }

            let envelope = try builder.complete(
                exitStatus: 0,
                startedAt: startedAt,
                endedAt: completedAt
            )
            try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
        }
    }

    private func qCSummaryRefreshArgv(
        reportURL: URL,
        bundleURL: URL,
        mutations: [QCSummaryMutation]
    ) -> [String] {
        [
            "lungfish-app-action:fastq-refresh-qc-summary-import",
            "--report",
            reportURL.path,
            "--bundle",
            bundleURL.path,
        ] + mutations.flatMap { ["--target", $0.targetURL.path] }
    }

    private func qCSummaryProvenanceArtifacts(for mutations: [QCSummaryMutation]) -> [URL] {
        let bundleURLs = Set(mutations.map { $0.bundleURL.standardizedFileURL })
        return bundleURLs.flatMap { ProvenancePublicationArtifacts.bundleRootArtifacts(for: $0) }
    }

    private func restoreQCSummaryMutations(_ mutations: [QCSummaryMutation]) throws {
        for mutation in mutations.reversed() {
            if let originalData = mutation.originalData {
                try FileManager.default.createDirectory(
                    at: mutation.targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try originalData.write(to: mutation.targetURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: mutation.targetURL.path) {
                try FileManager.default.removeItem(at: mutation.targetURL)
            }
        }
    }

    private func enclosingFASTQBundleURL(for url: URL) -> URL? {
        if FASTQBundle.isBundleURL(url) {
            return url
        }
        return SequenceInputResolver.enclosingFASTQBundleURL(for: url)
    }

    private func writableFASTQURL(for inputURL: URL) -> URL? {
        if FASTQBundle.isFASTQFileURL(inputURL) {
            return inputURL
        }
        if FASTQBundle.isBundleURL(inputURL) {
            return FASTQBundle.resolvePrimaryFASTQURL(for: inputURL)
        }
        let parentBundleURL = inputURL.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parentBundleURL) {
            return FASTQBundle.resolvePrimaryFASTQURL(for: parentBundleURL)
        }
        return nil
    }

    private func selectableSourceURL(for inputURL: URL) -> URL {
        if let fastqBundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) {
            return fastqBundleURL
        }
        if let referenceBundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: inputURL) {
            return referenceBundleURL
        }
        return inputURL
    }
}

private struct FASTQQCSummaryReport: Decodable {
    let inputs: [Entry]

    struct Entry: Decodable {
        let input: String
        let statistics: FASTQDatasetStatistics
    }
}

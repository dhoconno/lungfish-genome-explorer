import Foundation
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
        let pairingMode = pairingMode(for: sourceInputURL)
        let stats = try await computeStatistics(from: sourceURL)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = try await ingestor.ingest(
            config: FASTQIngestionConfig(
                inputFiles: [sourceURL],
                pairingMode: ingestionPipelinePairingMode(for: pairingMode),
                outputDirectory: bundleURL,
                threads: max(1, ProcessInfo.processInfo.activeProcessorCount),
                deleteOriginals: true,
                qualityBinning: .illumina4,
                skipClumpify: false
            ),
            progress: { _, _ in }
        )

        var metadata = FASTQMetadataStore.load(for: result.outputFile) ?? PersistedFASTQMetadata()
        metadata.ingestion = IngestionMetadata(
            isClumpified: result.wasClumpified,
            isCompressed: result.outputFile.pathExtension.lowercased() == "gz",
            pairingMode: ingestionMetadataPairingMode(for: result.pairingMode),
            qualityBinning: result.qualityBinning.rawValue,
            originalFilenames: result.originalFilenames,
            ingestionDate: Date(),
            originalSizeBytes: result.originalSizeBytes
        )
        FASTQMetadataStore.save(metadata, for: result.outputFile)

        let operation = try writeDerivedManifest(
            for: result.outputFile,
            in: bundleURL,
            sourceURL: sourceURL,
            originalRequest: originalRequest,
            sourceInputURL: sourceInputURL,
            stats: stats,
            pairingMode: metadata.ingestion?.pairingMode
        )
        try await writeOperationProvenance(
            for: result.outputFile,
            in: bundleURL,
            sourceURL: sourceURL,
            originalRequest: originalRequest,
            sourceInputURL: sourceInputURL,
            operation: operation
        )

        return bundleURL
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
        in bundleURL: URL,
        sourceURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?,
        stats: FASTQDatasetStatistics,
        pairingMode: IngestionMetadata.PairingMode?
    ) throws -> FASTQDerivativeOperation {
        let operation = derivativeOperation(
            for: originalRequest,
            sourceURL: sourceURL,
            outputURL: outputFASTQ
        )
        let parentBundleURL = sourceInputURL.flatMap(enclosingFASTQBundleURL(for:))
        let sourceManifest = parentBundleURL.flatMap { FASTQBundle.loadDerivedManifest(in: $0) }
        let rootBundleURL = sourceManifest
            .map { FASTQBundle.resolveBundle(relativePath: $0.rootBundleRelativePath, from: parentBundleURL ?? bundleURL) }
            ?? parentBundleURL
            ?? bundleURL
        let rootFASTQFilename = sourceManifest?.rootFASTQFilename
            ?? parentBundleURL.flatMap { FASTQBundle.resolvePrimarySequenceURL(for: $0)?.lastPathComponent }
            ?? outputFASTQ.lastPathComponent
        let baseLineage = sourceManifest?.lineage ?? []
        let checksum = try PayloadChecksum.sha256Hex(fileAt: outputFASTQ)

        let parentRelativePath = parentBundleURL.map {
            FASTQBundle.projectRelativePath(for: $0, from: bundleURL)
                ?? FASTQOperationPlanner.relativePath(from: bundleURL, to: $0)
                ?? "."
        } ?? "."
        let rootRelativePath = FASTQBundle.projectRelativePath(for: rootBundleURL, from: bundleURL)
            ?? FASTQOperationPlanner.relativePath(from: bundleURL, to: rootBundleURL)
            ?? "."

        let manifest = FASTQDerivedBundleManifest(
            name: bundleURL.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: parentRelativePath,
            rootBundleRelativePath: rootRelativePath,
            rootFASTQFilename: rootFASTQFilename,
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
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return operation
    }

    private func writeOperationProvenance(
        for outputFASTQ: URL,
        in bundleURL: URL,
        sourceURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?,
        operation: FASTQDerivativeOperation
    ) async throws {
        _ = originalRequest
        _ = operation
        try FASTQOperationProvenanceRehydrator().rehydrateOperationOutput(
            sourceURL: sourceURL,
            finalDirectory: bundleURL,
            finalOutputURL: outputFASTQ,
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
                toolUsed: "lungfish-cli",
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
        _ = request

        switch originalRequest {
        case .refreshQCSummary(let inputURLs):
            guard let reportURL = outputURLs.first else { return inputURLs }
            try applyQCSummaryReport(from: reportURL, to: inputURLs)
            return inputURLs.map(selectableSourceURL(for:))

        case .derivative(.demultiplex, _, _):
            return [outputDirectory]

        case .derivative:
            return try await importSequenceOutputs(outputURLs, originalRequest: originalRequest)

        default:
            return outputURLs
        }
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

    private func applyQCSummaryReport(from reportURL: URL, to inputURLs: [URL]) throws {
        let data = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(FASTQQCSummaryReport.self, from: data)

        for (entry, inputURL) in zip(report.inputs, inputURLs) {
            if FASTQBundle.isDerivedBundle(inputURL),
               let manifest = FASTQBundle.loadDerivedManifest(in: inputURL) {
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
                continue
            }

            guard let fastqURL = writableFASTQURL(for: inputURL) else { continue }
            var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
            metadata.computedStatistics = entry.statistics
            FASTQMetadataStore.save(metadata, for: fastqURL)
        }
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

import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func resolveMHCReferenceFASTA(_ sourceURL: URL) throws -> URL {
        if MHCAmpliconReferenceBundle.isBundleURL(sourceURL),
           let fastaURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: sourceURL) {
            return fastaURL.standardizedFileURL
        }
        guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
              (SequenceInputResolver.inputSequenceFormat(for: sourceURL) ?? SequenceFormat.from(url: fastaURL)) == .fasta else {
            throw FullLengthONTMHCGenotypingError.invalidReference(sourceURL.path)
        }
        return fastaURL.standardizedFileURL
    }

    func mhcReferenceRecords(
        sourceURL: URL,
        fastaURL: URL,
        cdnaThreshold: Int
    ) throws -> [MHCReferenceRecord] {
        if sourceURL.pathExtension.lowercased() == "lungfishref" {
            return try MHCReferenceRecordCatalog.load(
                from: sourceURL,
                cdnaThreshold: cdnaThreshold
            ).records
        }
        return try FullLengthONTMHCClusterGenotyper.readFASTARecords(from: fastaURL).map { record in
            let sequenceID = record.name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                ?? record.name
            let alleleName = sequenceID
            let locus = alleleName.split(separator: "*", maxSplits: 1).first.map(String.init)
                ?? alleleName
            return MHCReferenceRecord(
                sequenceID: sequenceID,
                alleleName: alleleName,
                locus: locus,
                moleculeClass: record.sequence.count < cdnaThreshold ? .cDNA : .genomicDNA,
                classEvidence: .lengthThresholdFallback,
                sequenceLength: record.sequence.count
            )
        }
    }

    func mhcReferenceCatalogInputURLs(
        sourceURL: URL,
        fastaURL: URL
    ) throws -> [URL] {
        try mhcReferenceCatalogInputs(sourceURL: sourceURL, fastaURL: fastaURL).allURLs
    }

    internal func mhcReferenceVisualizationInputURLs(
        sourceURL: URL,
        fastaURL: URL
    ) throws -> [URL] {
        var urls = try mhcReferenceCatalogInputURLs(sourceURL: sourceURL, fastaURL: fastaURL)
        let manifest = try BundleManifest.load(from: sourceURL)
        func appendBundleMember(_ path: String, field: String) throws {
            let url = try BundleManifest.validatedBundleMemberURL(
                for: path,
                in: sourceURL,
                field: field
            ).standardizedFileURL
            if !urls.contains(where: { $0.standardizedFileURL == url }) {
                urls.append(url)
            }
        }
        if let genome = manifest.genome {
            try appendBundleMember(genome.indexPath, field: "genome.index_path")
            if let gzipIndexPath = genome.gzipIndexPath {
                try appendBundleMember(gzipIndexPath, field: "genome.gzip_index_path")
            }
        }
        for annotation in manifest.annotations {
            if let databasePath = annotation.databasePath, !databasePath.isEmpty {
                try appendBundleMember(
                    databasePath,
                    field: "annotations[\(annotation.id)].database_path"
                )
            }
        }
        return urls
    }

    internal func mhcReferenceCatalogInputs(
        sourceURL: URL,
        fastaURL: URL
    ) throws -> FullLengthONTMHCReferenceCatalogInputs {
        let source = sourceURL.standardizedFileURL
        let fasta = fastaURL.standardizedFileURL
        if source.pathExtension.lowercased() == "lungfishref" {
            let manifestURL = source.appendingPathComponent("manifest.json").standardizedFileURL
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(FullLengthONTMHCReferenceInputManifest.self, from: data)
            var recordStoreURL: URL?
            if let databasePath = manifest.recordStore?.databasePath,
               !databasePath.isEmpty {
                recordStoreURL = try BundleManifest.validatedBundleMemberURL(
                    for: databasePath,
                    in: source,
                    field: "record_store.database_path"
                ).standardizedFileURL
            }
            return FullLengthONTMHCReferenceCatalogInputs(
                fastaURL: fasta,
                manifestURL: manifestURL,
                recordStoreURL: recordStoreURL
            )
        }
        if MHCAmpliconReferenceBundle.isBundleURL(source) {
            return FullLengthONTMHCReferenceCatalogInputs(
                fastaURL: fasta,
                manifestURL: MHCAmpliconReferenceBundle.manifestURL(in: source).standardizedFileURL,
                recordStoreURL: nil
            )
        }
        return FullLengthONTMHCReferenceCatalogInputs(
            fastaURL: fasta,
            manifestURL: nil,
            recordStoreURL: nil
        )
    }

    internal func materializeMHCReferenceCatalog(
        sourceURL: URL,
        fastaURL: URL,
        cdnaThreshold: Int,
        outputURL: URL
    ) throws -> (records: [MHCReferenceRecord], step: FullLengthONTMHCProvenanceStep) {
        let inputs = try mhcReferenceCatalogInputs(sourceURL: sourceURL, fastaURL: fastaURL)
        var argv = [
            "lungfish-in-process", "import-mhc-reference-catalog",
            "--reference-fasta", inputs.fastaURL.path,
        ]
        if let manifestURL = inputs.manifestURL {
            argv += ["--reference-bundle-manifest", manifestURL.path]
        }
        if let recordStoreURL = inputs.recordStoreURL {
            argv += ["--record-store", recordStoreURL.path]
        }
        argv += [
            "--cdna-threshold", String(cdnaThreshold),
            "--output", outputURL.path,
        ]

        let startedAt = Date()
        do {
            let records = try mhcReferenceRecords(
                sourceURL: sourceURL,
                fastaURL: fastaURL,
                cdnaThreshold: cdnaThreshold
            )
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(FullLengthONTMHCReferenceCatalogProjection(
                cdnaThreshold: cdnaThreshold,
                records: records
            )).write(to: outputURL, options: .atomic)
            let projection = try JSONDecoder().decode(
                FullLengthONTMHCReferenceCatalogProjection.self,
                from: Data(contentsOf: outputURL)
            )
            let completedAt = Date()
            return (
                projection.records,
                FullLengthONTMHCProvenanceStep(
                    toolName: "lungfish-in-process:import-mhc-reference-catalog",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    resolvedOptions: [
                        "recordCount": .integer(projection.records.count),
                        "cdnaThreshold": .integer(cdnaThreshold),
                        "moleculeClassSource": .string("reference-metadata-with-length-fallback"),
                    ],
                    inputs: inputs.allURLs,
                    outputs: [outputURL],
                    exitStatus: 0,
                    stderr: nil,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )
        } catch {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "MHC reference catalog import failed after \(Date().timeIntervalSince(startedAt)) seconds: \(error.localizedDescription)"
            )
        }
    }

    internal func publishMHCReferenceVisualizations(
        referenceBundleURL: URL,
        referenceFASTAURL: URL,
        referenceRecords: [MHCReferenceRecord],
        exactCallRows: [FullLengthONTMHCClusterGenotypeRow],
        exactCallInputURL: URL,
        candidateDocument: ONTMHCCandidateAllelesDocument,
        candidateJSONURL: URL,
        unnameableDocument: ONTMHCUnnameableClustersDocument,
        unnameableJSONURL: URL,
        outputDirectoryURL: URL,
        finalOutputDirectoryURL: URL,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws -> FullLengthONTMHCReferenceVisualizationPublication? {
        guard referenceBundleURL.pathExtension.lowercased() == "lungfishref",
              fullLengthONTMHCPathIsDirectory(referenceBundleURL) else {
            return nil
        }

        let rawReferenceIDs = Set(referenceRecords.map(\.sequenceID))
        let exactKnownRawReferenceIDs = exactCallRows.reduce(into: Set<String>()) { ids, row in
            if let referenceSequenceID = row.referenceSequenceID,
               rawReferenceIDs.contains(referenceSequenceID) {
                ids.insert(referenceSequenceID)
            } else if rawReferenceIDs.contains(row.allele) {
                ids.insert(row.allele)
            }
        }

        let referenceDirectoryURL = outputDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("reference", isDirectory: true)
        let recordsJSONURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-visualizations.json")
        let genBankURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-records.gb")
        let fastaURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-records.fasta")
        let finalReferenceDirectoryURL = finalOutputDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("reference", isDirectory: true)
        let finalOutputURLs = [
            finalReferenceDirectoryURL.appendingPathComponent("mhc-reference-visualizations.json"),
            finalReferenceDirectoryURL.appendingPathComponent("mhc-reference-records.gb"),
            finalReferenceDirectoryURL.appendingPathComponent("mhc-reference-records.fasta"),
        ]
        let startedAt = Date()
        let sourceReferenceURLs = try mhcReferenceVisualizationInputURLs(
            sourceURL: referenceBundleURL,
            fastaURL: referenceFASTAURL
        )
        let inputs = (sourceReferenceURLs + [candidateJSONURL, unnameableJSONURL, exactCallInputURL]).reduce(
            into: [URL]()
        ) { unique, url in
            guard !unique.contains(where: {
                $0.standardizedFileURL == url.standardizedFileURL
            }) else { return }
            unique.append(url.standardizedFileURL)
        }
        let outputURLs = [recordsJSONURL, genBankURL, fastaURL]
        func extractionArgv(
            candidateJSONURL: URL?,
            unnameableJSONURL: URL?,
            exactCallInputURL: URL?,
            outputURLs: [URL]
        ) -> [String] {
            var values = [
                "lungfish-in-process", "extract-mhc-reference-visualizations",
                "--reference-bundle", referenceBundleURL.path,
            ]
            if let candidateJSONURL {
                values += ["--candidate-json", candidateJSONURL.path]
            }
            if let unnameableJSONURL {
                values += ["--unnameable-json", unnameableJSONURL.path]
            }
            if let exactCallInputURL {
                values += ["--exact-call-input", exactCallInputURL.path]
            }
            for rawReferenceID in exactKnownRawReferenceIDs.sorted() {
                values += ["--exact-known-reference-id", rawReferenceID]
            }
            values += [
                "--records-json", outputURLs[0].path,
                "--genbank", outputURLs[1].path,
                "--fasta", outputURLs[2].path,
            ]
            return values
        }
        let argv = extractionArgv(
            candidateJSONURL: candidateJSONURL,
            unnameableJSONURL: unnameableJSONURL,
            exactCallInputURL: exactCallInputURL,
            outputURLs: outputURLs
        )
        func resolvedOptions(recordCount: Int?) -> [String: ParameterValue] {
            var values: [String: ParameterValue] = [
                "schemaVersion": .integer(1),
                "exactKnownRawReferenceIDs": .array(
                    exactKnownRawReferenceIDs.sorted().map(ParameterValue.string)
                ),
                "includeCandidateClosestReferences": .boolean(true),
                "includeUnnameableClosestReferences": .boolean(true),
                "candidateCount": .integer(candidateDocument.candidates.count),
                "unnameableCount": .integer(unnameableDocument.clusters.count),
                "jsonEncoding": .string("pretty-printed-sorted-keys-without-escaped-slashes"),
                "companionOrdering": .string("source-ordinal-then-raw-reference-id"),
            ]
            if let recordCount {
                values["recordCount"] = .integer(recordCount)
            }
            return values
        }
        func provenanceStep(
            recordCount: Int?,
            outputs: [URL],
            exitStatus: Int32,
            stderr: String?,
            completedAt: Date
        ) -> FullLengthONTMHCProvenanceStep {
            return FullLengthONTMHCProvenanceStep(
                toolName: "lungfish-in-process:extract-mhc-reference-visualizations",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                resolvedOptions: resolvedOptions(recordCount: recordCount),
                inputs: inputs,
                outputs: outputs,
                exitStatus: exitStatus,
                stderr: stderr,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }

        do {
            let output = try MHCReferenceVisualizationArtifactBuilder().build(.init(
                referenceBundleURL: referenceBundleURL,
                exactKnownRawReferenceIDs: exactKnownRawReferenceIDs,
                candidates: candidateDocument,
                unnameable: unnameableDocument
            ))
            try FileManager.default.createDirectory(
                at: referenceDirectoryURL,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(output.document).write(to: recordsJSONURL, options: .atomic)
            try Data(output.genBankText.utf8).write(to: genBankURL, options: .atomic)
            try Data(output.fastaText.utf8).write(to: fastaURL, options: .atomic)

            func artifactReference(_ url: URL) throws -> ONTMHCArtifactReference {
                ONTMHCArtifactReference(
                    path: relativePath(from: outputDirectoryURL, to: url),
                    sha256: try ProvenanceFileHasher.sha256(of: url) {
                        try Task.checkCancellation()
                    },
                    sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
                )
            }
            let publication = try FullLengthONTMHCReferenceVisualizationPublication(
                descriptor: ONTMHCReferenceVisualizationArtifacts(
                    schemaVersion: 1,
                    recordCount: output.document.records.count,
                    recordsJSON: artifactReference(recordsJSONURL),
                    genBank: artifactReference(genBankURL),
                    fasta: artifactReference(fastaURL)
                ),
                recordsJSONURL: recordsJSONURL,
                genBankURL: genBankURL,
                fastaURL: fastaURL
            )
            steps.append(provenanceStep(
                recordCount: output.document.records.count,
                outputs: publication.outputURLs,
                exitStatus: 0,
                stderr: nil,
                completedAt: Date()
            ))
            return publication
        } catch {
            let completedAt = Date()
            let visualizationFailure = error
            let failureInputDirectoryURL = URL(
                fileURLWithPath: finalOutputDirectoryURL.standardizedFileURL.path
                    + ".failed.lungfish-provenance.json.inputs",
                isDirectory: true
            )
            let preparedFailureInputDirectory: Bool = {
                do {
                    let safety = FullLengthONTMHCAlignmentSafety()
                    if try safety.requireOptionalDirectoryEntryNoFollow(
                        failureInputDirectoryURL,
                        role: "MHC visualization failure input directory"
                    ) {
                        try safety.requireSafeDirectoryTree(
                            failureInputDirectoryURL,
                            role: "MHC visualization failure input directory"
                        )
                        try FileManager.default.removeItem(at: failureInputDirectoryURL)
                    }
                    try FileManager.default.createDirectory(
                        at: failureInputDirectoryURL,
                        withIntermediateDirectories: false
                    )
                    return true
                } catch {
                    return false
                }
            }()
            func retainFailureInput(_ sourceURL: URL, name: String) -> URL? {
                guard preparedFailureInputDirectory else { return nil }
                let retainedURL = failureInputDirectoryURL.appendingPathComponent(name)
                do {
                    try Data(contentsOf: sourceURL).write(to: retainedURL, options: .atomic)
                    return retainedURL
                } catch {
                    return nil
                }
            }
            let retainedCandidateJSONURL = retainFailureInput(
                candidateJSONURL,
                name: "candidate-alleles.json"
            )
            let retainedUnnameableJSONURL = retainFailureInput(
                unnameableJSONURL,
                name: "unnameable-unmatched-clusters.json"
            )
            let retainedExactCallInputURL = retainFailureInput(
                exactCallInputURL,
                name: "exact-calls.csv"
            )
            let failedArgv = extractionArgv(
                candidateJSONURL: retainedCandidateJSONURL,
                unnameableJSONURL: retainedUnnameableJSONURL,
                exactCallInputURL: retainedExactCallInputURL,
                outputURLs: finalOutputURLs
            )
            var seenInputPaths = Set<String>()
            var failedInputs: [ProvenanceFileDescriptor] = []
            for url in sourceReferenceURLs + [
                retainedCandidateJSONURL,
                retainedUnnameableJSONURL,
                retainedExactCallInputURL,
            ].compactMap({ $0 }) {
                let path = url.standardizedFileURL.path
                guard seenInputPaths.insert(path).inserted else { continue }
                do {
                    failedInputs.append(try ProvenanceFileDescriptor.file(
                        url: url,
                        format: failureFileFormat(url),
                        role: .input
                    ))
                } catch {
                    throw FullLengthFailureProvenancePreparationError(
                        inputURL: url,
                        operation: "describing a reference-visualization scientific input",
                        underlyingError: error,
                        initiatingError: visualizationFailure
                    )
                }
            }
            let failedStep = ProvenanceStep(
                toolName: "lungfish-in-process:extract-mhc-reference-visualizations",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: failedArgv,
                durableReplayArgv: failedArgv,
                reproducibleCommand: failedArgv.map(shellEscape).joined(separator: " "),
                resolvedOptions: resolvedOptions(recordCount: nil),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: failedInputs,
                outputs: [],
                exitStatus: (error is CancellationError || Task.isCancelled) ? 130 : 1,
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                stderr: error.localizedDescription,
                startedAt: startedAt,
                completedAt: completedAt
            )
            throw FullLengthONTMHCReferenceVisualizationPublicationError(
                step: failedStep,
                underlyingLocalizedDescription: error.localizedDescription
            )
        }
    }
}

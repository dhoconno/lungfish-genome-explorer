import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func writeFASTARecords(
        _ records: [FullLengthONTMHCClusterFASTARecord],
        to url: URL
    ) throws {
        var text = ""
        for record in records {
            text += ">\(record.name)\n"
            var sequence = record.sequence
            while !sequence.isEmpty {
                let chunk = String(sequence.prefix(80))
                text += chunk + "\n"
                sequence.removeFirst(chunk.count)
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    internal func sampleClusterKey(sample: String, cluster: String) -> String {
        "\(sample)\u{0}\(cluster)"
    }

    internal func writeClusterGenotypeTSV(
        _ rows: [FullLengthONTMHCClusterGenotypeRow],
        to url: URL
    ) throws {
        var lines = ["sample\tcluster\tcluster_reads\tallele\tallele_length\taligned_bases\tscore"]
        lines += rows.map {
            [
                $0.sample,
                $0.cluster,
                String($0.clusterReads),
                $0.allele,
                String($0.alleleLength),
                String($0.alignedBases),
                String($0.score),
            ].joined(separator: "\t")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    internal func writeReportCSV(
        _ rows: [FullLengthONTMHCReportRow],
        to url: URL
    ) throws {
        var lines = [
            [
                "sample",
                "genotype",
                "passed_alignments",
                "passed_unique_reads",
                "sample_total_reads",
                "sample_unique_retained_reads",
                "sample_unique_retained_percent",
                "overall_input_reads",
                "overall_unique_retained_reads",
                "overall_unique_retained_percent",
            ].joined(separator: ","),
        ]
        lines += rows.map {
            [
                csvEscape($0.sample),
                csvEscape($0.genotype),
                String($0.passedAlignments),
                String($0.passedUniqueReads),
                optionalString($0.sampleTotalReads),
                String($0.sampleUniqueRetainedReads),
                optionalString($0.sampleUniqueRetainedPercent),
                String($0.overallInputReads),
                String($0.overallUniqueRetainedReads),
                optionalString($0.overallUniqueRetainedPercent),
            ].joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    internal func writeSampleSummaryCSV(
        _ rows: [FullLengthONTMHCSampleSummary],
        to url: URL
    ) throws {
        let header = [
            "sample",
            "passed_alignments",
            "passed_unique_reads",
            "sample_total_reads",
            "sample_unique_retained_reads",
            "sample_unique_retained_percent",
            "cluster_count",
            "clustered_reads",
            "unmatched_clusters",
            "cdna_clusters",
            "savont_preset",
            "savont_status",
            "savont_fallback_reason",
        ].joined(separator: ",")
        var lines = [header]
        lines += rows.sorted { $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }.map { row in
            let percent = row.totalInputReads > 0
                ? Double(row.assignedReads) / Double(row.totalInputReads) * 100.0
                : nil
            return [
                csvEscape(row.sample),
                String(row.assignedReads),
                String(row.assignedReads),
                String(row.totalInputReads),
                String(row.assignedReads),
                optionalString(percent),
                String(row.clusterCount),
                String(row.clusteredReads),
                String(row.unmatchedClusters),
                String(row.cdnaClusters),
                csvEscape(row.savontPreset),
                csvEscape(row.savontStatus.rawValue),
                csvEscape(row.savontFallbackReason ?? ""),
            ].joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    internal func writeStatsJSON(
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        genotypeRows: [FullLengthONTMHCClusterGenotypeRow],
        to url: URL
    ) throws {
        let totalInput = sampleSummaries.reduce(0) { $0 + $1.totalInputReads }
        let assigned = Dictionary(
            genotypeRows.map { ("\($0.sample)\0\($0.cluster)", $0.clusterReads) },
            uniquingKeysWith: max
        ).values.reduce(0, +)
        let clustered = sampleSummaries.reduce(0) { $0 + $1.clusteredReads }
        let object: [String: Any] = [
            "totalInputReads": totalInput,
            "totalAlignments": assigned,
            "passedAlignments": assigned,
            "retainedUniqueReads": assigned,
            "retainedUniquePercentOfTotalReads": totalInput > 0 ? Double(assigned) / Double(totalInput) * 100.0 : 0.0,
            "assignedUniqueRetainedReads": assigned,
            "unassignedUniqueRetainedReads": max(0, clustered - assigned),
            "clusteredReads": clustered,
            "clusterCount": sampleSummaries.reduce(0) { $0 + $1.clusterCount },
            "unmatchedClusters": sampleSummaries.reduce(0) { $0 + $1.unmatchedClusters },
            "cdnaClusters": sampleSummaries.reduce(0) { $0 + $1.cdnaClusters },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    internal func workbookSheets(
        reportRows: [FullLengthONTMHCReportRow],
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        projection: FullLengthONTMHCWorkbookProjection,
        normalizedUnmatchedRows: [FullLengthONTMHCNormalizedUnmatchedRow],
        knownAlleleDisplayNames: [String: String]
    ) -> [FullLengthONTMHCXLSXPackageWriter.Sheet] {
        [
            .init(
                name: "Unified Genotype Pivot",
                cells: FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildWorkbookCells(
                    reportRows: reportRows,
                    projection: projection,
                    samples: sampleSummaries.map {
                        let retainedPercent = $0.totalInputReads > 0
                            ? Double($0.assignedReads) / Double($0.totalInputReads) * 100.0
                            : nil
                        return FullLengthONTMHCPivotSample(
                            sample: $0.sample,
                            mappedReadCount: $0.assignedReads,
                            totalReadCount: $0.totalInputReads,
                            retainedPercent: retainedPercent
                        )
                    },
                    haplotypeAnalysis: haplotypeAnalysis,
                    knownAlleleDisplayNames: knownAlleleDisplayNames
                )
            ),
            .init(
                name: "Unmatched Alleles",
                cells: FullLengthONTMHCUnmatchedWorksheetBuilder.buildCells(
                    rows: normalizedUnmatchedRows,
                    sampleOrder: sampleSummaries.map(\.sample)
                )
            ),
        ]
    }

    internal func interpretationWorkbookRows(
        request: FullLengthONTMHCGenotypingRunRequest,
        sampleSummaries: [FullLengthONTMHCSampleSummary],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[String]] {
        [
            ["Field", "Interpretation"],
            ["Workflow", "Full-length ONT MHC genotyping"],
            ["Read preparation", "Input reads are materialized as plain FASTQ, optionally oriented and primer-trimmed, length-filtered, then clustered into Savont ASVs."],
            ["Savont settings", "quality_value_cutoff=\(request.savontQualityValueCutoff); min_cluster_size=\(request.savontMinimumClusterSize); min_length=\(request.minimumLength); max_length=\(request.maximumLength)"],
            ["Sample presets", sampleSummaries.map { "\($0.sample): \($0.savontPreset) (\($0.savontStatus.rawValue))" }.joined(separator: "; ")],
            ["Genotype call rule", "Known genotype calls require zero SNP differences. Indel-only genomic-reference alignments remain calls to the existing allele; true genomic extensions of cDNA references are classified separately with the _ext suffix."],
            ["Score formula", "score = aligned_bases - (100 * snp_differences) - (10 * indel_bases)"],
            ["Score interpretation", "Higher scores are better. Alignments without SNPs or indels have score equal to aligned_bases; each SNP subtracts 100 and each indel base subtracts 10."],
            ["Unmatched closest match", "For unmatched clusters, closest-match fields describe the best non-exact mapped reference hit when one exists."],
            ["Unmatched normalization", "Unmatched cluster sequences are trimmed to their best minimap2 target interval and reverse-complemented when the best hit maps to the reverse strand before unmatched_sequence_id assignment."],
            ["Blank closest-match fields", "Blank closest-match fields mean the unmatched cluster had no mapped SAM hit."],
            ["MHC-like unmatched rescue", "Blank unmatched clusters are compared to the resolved MHC reference FASTA with local blastn; accepted rescue hits use match_source=local-blast-rescue."],
            ["MHC-like rescue thresholds", "query_coverage>=\(oneDecimalString(FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage))%; aligned_bases>=\(FullLengthONTMHCBlastRescueMatch.minimumAlignedBases); percent_identity>=\(oneDecimalString(FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity))%; evalue<=\(FullLengthONTMHCBlastRescueMatch.maximumEValue)"],
            ["Unmatched sequence ID", "A deterministic UUID derived from the normalized unmatched sequence links detail rows to the shared pivot."],
            ["Haplotype assay", haplotypeAnalysis?.assayID ?? request.haplotypeAssayID ?? ""],
            ["Haplotype definition", haplotypeAnalysis?.definitionSetID ?? request.haplotypeDefinitionSetID ?? ""],
            ["Haplotype filtering scope", "Haplotype thresholds affect haplotype assignment only; genotype and unmatched worksheets retain observed cluster evidence."],
            ["", ""],
            ["Samples worksheet", "One row per sample with input reads, retained/assigned read summaries, unmatched counts, cDNA counts, and Savont status."],
            ["Genotypes worksheet", "Cluster-level known genotype evidence. Each row is one sample cluster assigned to one existing reference allele."],
            ["Genotyping pivot worksheet", "Sample-by-genotype pivot formatted for review of full-length genotyping calls and haplotype summaries."],
            ["Unmatched Clusters worksheet", "One row per unmatched cluster with sequence, read support, deterministic unmatched_sequence_id, and closest-match metadata when available."],
            ["Unmatched Shared Pivot worksheet", "One row per unique unmatched sequence with occurrence count, total supporting reads, closest-match summary, and per-sample read counts."],
            ["MHC-like Unmatched Clusters worksheet", "One row per unmatched cluster with either genotyping SAM closest-match evidence or accepted local BLAST rescue evidence."],
            ["MHC-like Unmatched Pivot worksheet", "One row per unique MHC-like unmatched sequence with occurrence count, total supporting reads, best evidence summary, and per-sample read counts."],
            ["Unified Genotype Pivot worksheet", "One sample-by-call pivot combining known reference genotype calls with every classified _nov and _ext candidate. Stable cluster IDs keep distinct sequences on separate rows even when provisional names collide."],
            ["Candidate Alleles worksheet", "One machine-readable row per classified candidate. Every singleton/shared _nov and _ext candidate is retained; color is limited to the provisional-name cell and classification/support columns remain authoritative."],
            ["Un-nameable Clusters worksheet", "One machine-readable row per unmatched cluster that cannot receive a provisional allele name, including the reason, support, FASTA identity, evidence locator, and per-sample reads."],
        ]
    }

    internal func writeHaplotypeAnalysisIfRequested(
        request: FullLengthONTMHCGenotypingRunRequest,
        supportDirectory: URL,
        generatedAt: Date
    ) throws -> GenotypeHaplotypeAnalysis? {
        guard let definitionSetID = request.haplotypeDefinitionSetID else {
            return nil
        }
        guard let definitionSet = try resolveHaplotypeDefinitionSet(for: request) else {
            throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        try writeHaplotypeDefinitionSnapshot(definitionSet, supportDirectory: supportDirectory)

        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
            outputName: request.outputName,
            analysisName: request.outputName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            haplotypeDefinitionSetID: definitionSetID,
            haplotypeAssayID: definitionSet.assayID
        )
        let result = try ONTGenotypeResultBundle.loadResult(from: request.outputDirectory, manifest: manifest)
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: result.calls,
            definitionSet: definitionSet,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            dropoutFilter: request.haplotypeDropoutEvaluator
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(analysis).write(to: request.haplotypeAnalysisURL, options: .atomic)
        return analysis
    }

    internal func resolveHaplotypeDefinitionSet(
        for request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        guard let definitionSetID = request.haplotypeDefinitionSetID else {
            return nil
        }
        if let bundledDefinition = try bundledHaplotypeDefinitionSet(
            for: request,
            definitionSetID: definitionSetID
        ) {
            return bundledDefinition
        }
        if request.haplotypeSpeciesCode != nil || request.haplotypeDefinitionScope != nil {
            let matchingRecords = haplotypeDefinitionLibrary(for: request)
                .activeRecords(
                    assayID: request.haplotypeAssayID,
                    speciesCode: request.haplotypeSpeciesCode,
                    scope: request.haplotypeDefinitionScope
                )
                .filter { $0.definitionSet.id == definitionSetID }
            if matchingRecords.count == 1 {
                return matchingRecords[0].definitionSet
            }
            if matchingRecords.isEmpty {
                throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
            }
            throw FullLengthONTMHCGenotypingError.ambiguousHaplotypeDefinition(definitionID: definitionSetID)
        }
        let registry = haplotypeDefinitionRegistry(for: request)
        if let assayID = request.haplotypeAssayID {
            guard registry.assay(id: assayID) != nil else {
                throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinitionForAssay(
                    definitionID: definitionSetID,
                    assayID: assayID
                )
            }
            guard let definitionSet = registry.definitionSet(id: definitionSetID, assayID: assayID) else {
                if registry.definitionSet(id: definitionSetID) == nil {
                    throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
                }
                throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinitionForAssay(
                    definitionID: definitionSetID,
                    assayID: assayID
                )
            }
            return definitionSet
        }

        let matchingSets = registry.definitionSets(id: definitionSetID)
        if matchingSets.count == 1 {
            return matchingSets[0]
        }
        if matchingSets.isEmpty {
            throw FullLengthONTMHCGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        throw FullLengthONTMHCGenotypingError.ambiguousHaplotypeDefinition(definitionID: definitionSetID)
    }

    internal func bundledHaplotypeDefinitionSet(
        for request: FullLengthONTMHCGenotypingRunRequest,
        definitionSetID: String
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        guard MHCAmpliconReferenceBundle.isBundleURL(request.referenceSourceURL) else {
            return nil
        }
        return try MHCAmpliconReferenceBundle.haplotypeDefinition(
            id: definitionSetID,
            assayID: request.haplotypeAssayID,
            speciesCode: request.haplotypeSpeciesCode,
            in: request.referenceSourceURL
        )
    }

    internal func haplotypeDefinitionRegistry(
        for request: FullLengthONTMHCGenotypingRunRequest
    ) -> GenotypeHaplotypeDefinitionRegistry {
        haplotypeDefinitionLibrary(for: request).mergedRegistry()
    }

    internal func haplotypeDefinitionLibrary(
        for request: FullLengthONTMHCGenotypingRunRequest
    ) -> HaplotypeDefinitionLibrary {
        HaplotypeDefinitionLibrary(projectRoot: request.projectURL)
    }

    @discardableResult
    internal func writeHaplotypeDefinitionSnapshot(
        _ definitionSet: GenotypeHaplotypeDefinitionSet,
        supportDirectory: URL
    ) throws -> URL {
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
        let url = inputsDirectory.appendingPathComponent("haplotype-definition.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definitionSet).write(to: url, options: .atomic)
        return url
    }

    internal func createInitialCurrentWorkbookCopy(
        for request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> FullLengthONTMHCWorkbookCopyResult {
        let startedAt = Date()
        let destinationURL = request.currentWorkbookURL
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: request.workbookURL, to: destinationURL)
        let completedAt = Date()
        let revision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: relativePath(from: request.outputDirectory, to: destinationURL),
            label: "Initial editable workbook",
            sourceFilename: request.workbookURL.lastPathComponent,
            createdAt: ISO8601DateFormatter().string(from: completedAt),
            user: NSUserName(),
            predecessorPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            sha256: try ProvenanceFileHasher.sha256(of: destinationURL) {
                try Task.checkCancellation()
            },
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: destinationURL)),
            provenancePath: nil
        )
        let step = FullLengthONTMHCProvenanceStep(
            toolName: "lungfish genotype workbook initial-current-copy",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: request.argv + ["--create-current-workbook", destinationURL.path],
            inputs: [request.workbookURL],
            outputs: [destinationURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return FullLengthONTMHCWorkbookCopyResult(revision: revision, step: step)
    }

    internal func publishReviewableRowCatalogIfNeeded(
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceRecords: [MHCReferenceRecord],
        referenceCatalogProjectionURL: URL,
        reportRows: [FullLengthONTMHCReportRow],
        sampleNames: [String],
        candidateDocument: ONTMHCCandidateAllelesDocument,
        candidateJSONURL: URL,
        unnameableDocument: ONTMHCUnnameableClustersDocument,
        unnameableJSONURL: URL,
        genotypingEvidenceBAMURL: URL,
        genotypingEvidenceBAIURL: URL
    ) throws -> GenotypeReviewableRowCatalogPublication? {
        guard request.haplotypeDefinitionSetID == nil else { return nil }
        let csvAuthority = try GenotypeReviewCSVSemanticAuthority.capture(
            sampleSummaryURL: request.sampleSummaryCSVURL,
            reportURL: request.reportCSVURL
        )
        let expectedCalls = reportRows.map {
            ONTGenotypeCall(
                sample: $0.sample,
                genotype: $0.genotype,
                passedAlignments: $0.passedAlignments,
                passedUniqueReads: $0.passedUniqueReads,
                sampleTotalReads: $0.sampleTotalReads,
                sampleUniqueRetainedReads: $0.sampleUniqueRetainedReads,
                sampleUniqueRetainedPercent: $0.sampleUniqueRetainedPercent,
                overallInputReads: $0.overallInputReads,
                overallUniqueRetainedReads: $0.overallUniqueRetainedReads,
                overallUniqueRetainedPercent: $0.overallUniqueRetainedPercent
            )
        }
        try csvAuthority.requireMatches(
            expectedRoster: sampleNames,
            expectedCalls: expectedCalls
        )
        let reviewAuthority = try Self.reviewableCatalogAuthority(
            expectedReferenceRecords: referenceRecords,
            referenceCatalogURL: referenceCatalogProjectionURL,
            expectedCandidateDocument: candidateDocument,
            candidateURL: candidateJSONURL,
            expectedUnnameableDocument: unnameableDocument,
            unnameableURL: unnameableJSONURL
        )
        let exactReferenceRecords = reviewAuthority.referenceRecords
        let exactCandidateDocument = reviewAuthority.candidateDocument
        let sharedCalls = try Self.reviewableSharedCalls(
            csvAuthority.calls,
            referenceRecords: exactReferenceRecords
        )
        let outputURL = request.outputDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent("genotype-reviewable-rows.json")
        let argv = [
            "lungfish-internal", "publish-genotype-reviewable-rows",
            "--reference-catalog", referenceCatalogProjectionURL.path,
            "--sample-roster", request.sampleSummaryCSVURL.path,
            "--calls", request.reportCSVURL.path,
            "--candidate-json", candidateJSONURL.path,
            "--unnameable-json", unnameableJSONURL.path,
            "--genotyping-bam", genotypingEvidenceBAMURL.path,
            "--genotyping-bai", genotypingEvidenceBAIURL.path,
            "--output", outputURL.path,
            "--support-metric", "passed-unique-reads",
        ]
        let bamSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            genotypingEvidenceBAMURL,
            retainingData: false
        )
        let baiSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            genotypingEvidenceBAIURL,
            retainingData: false
        )
        let descriptors = [
            reviewAuthority.snapshots[0].descriptor(format: .json, role: .reference),
            csvAuthority.sampleSnapshot.descriptor(format: .text, role: .input),
            csvAuthority.reportSnapshot.descriptor(format: .text, role: .input),
            reviewAuthority.snapshots[1].descriptor(format: .json, role: .input),
            reviewAuthority.snapshots[2].descriptor(format: .json, role: .input),
            bamSnapshot.descriptor(format: .bam, role: .input),
            baiSnapshot.descriptor(format: nil, role: .index),
        ]
        let publication = try reviewableRowCatalogPublisher(
            GenotypeReviewableRowCatalogInputs(
                referenceRecords: exactReferenceRecords,
                authoritativeSamples: csvAuthority.roster,
                calls: sharedCalls,
                candidates:
                    GenotypeReviewableRowCandidate.fullLengthCandidates(
                        from: exactCandidateDocument
                    ) + GenotypeReviewableRowCandidate.fullLengthIncompleteCandidates(
                        from: reviewAuthority.unnameableDocument ?? unnameableDocument
                    ),
                inputDescriptors: descriptors,
                workflowName: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
                workflowVersion: "1",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                userVisibleOptions: [
                    "workflowMode": .string(GenotypeResultWorkflowMode.genotypeOnly.rawValue),
                    "candidateDesignation": .string("full-length-candidate-or-incomplete-reference-span-review"),
                ],
                resolvedDefaults: [
                    "supportMetric": .string("passed-unique-reads"),
                    "referenceRowScope": .string("all-exact-run-reference-records"),
                ],
                runtimeIdentity: ProvenanceRuntimeIdentity(
                    appVersion: WorkflowRun.currentAppVersion,
                    executablePath: CommandLine.arguments.first
                        ?? ProvenanceRuntimeIdentity.currentExecutablePath,
                    operatingSystemVersion: WorkflowRun.currentHostOS,
                    user: NSUserName(),
                    condaEnvironment: "lungfish-managed-tools",
                    condaPrefix: condaManager.rootPrefix.path
                )
            ),
            request.outputDirectory,
            {
                try reviewAuthority.requireUnchanged()
                try csvAuthority.requireUnchanged()
                try bamSnapshot.requireMetadataUnchanged()
                try baiSnapshot.requireMetadataUnchanged()
            }
        )
        return publication
    }

    static func reviewableSharedCalls(
        _ calls: [ONTGenotypeCall],
        referenceRecords: [MHCReferenceRecord]
    ) throws -> [ONTGenotypeSharedCall] {
        let recordsBySequenceID = Dictionary(
            uniqueKeysWithValues: referenceRecords.map {
                ($0.sequenceID, $0)
            }
        )
        let recordsByAllele = Dictionary(
            grouping: referenceRecords,
            by: \.alleleName
        )
        var rowsByCall:
            [FullLengthONTMHCReviewCallKey: [ONTGenotypeCall]] = [:]
        for row in calls {
            let reference: MHCReferenceRecord
            if let exact = recordsBySequenceID[row.genotype] {
                reference = exact
            } else if let matches = recordsByAllele[row.genotype],
                      let first = matches.first,
                      Set(matches.map(\.locus)).count == 1 {
                reference = first
            } else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Authoritative workbook review-row call \(row.genotype) does not resolve to exactly one exact-run reference record."
                )
            }
            let key = FullLengthONTMHCReviewCallKey(
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(
                    reference.locus
                ),
                genotype: row.genotype
            )
            rowsByCall[key, default: []].append(row)
        }
        return try rowsByCall.map { key, rows in
            let support = try Dictionary(grouping: rows, by: \.sample)
                .map { sample, sampleRows in
                    ONTGenotypeSampleSupport(
                        sample: sample,
                        passedAlignments: try checkedReviewSupportSum(
                            sampleRows.map(\.passedAlignments),
                            sample: sample
                        ),
                        passedUniqueReads: try checkedReviewSupportSum(
                            sampleRows.map(\.passedUniqueReads),
                            sample: sample
                        )
                    )
                }
            return ONTGenotypeSharedCall(
                locus: key.locus,
                genotype: key.genotype,
                sampleSupport: support
            )
        }
    }

    internal static func checkedReviewSupportSum(
        _ values: [Int],
        sample: String
    ) throws -> Int {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .invalidSupport(sample: sample, value: value)
            }
            result = addition.partialValue
        }
        return result
    }

    internal func genotypeWorkbookRows(_ rows: [FullLengthONTMHCClusterGenotypeRow]) -> [[String]] {
        var result = [[
            "sample",
            "genotype",
            "cluster",
            "cluster_reads",
            "allele_length",
            "aligned_bases",
            "score",
            "reference_sequence_id",
            "mapping_quality",
            "cigar",
            "evidence_bam_path",
            "evidence_query_name",
            "evidence_reference_name",
            "evidence_read_group_id",
            "evidence_reference_start",
            "evidence_cigar",
        ]]
        result += rows.map {
            [
                $0.sample,
                $0.allele,
                $0.cluster,
                String($0.clusterReads),
                String($0.alleleLength),
                String($0.alignedBases),
                String($0.score),
                $0.referenceSequenceID ?? "",
                $0.mappingQuality.map(String.init) ?? "",
                $0.cigar ?? "",
                $0.evidence?.bamPath ?? "",
                $0.evidence?.queryName ?? "",
                $0.evidence?.referenceName ?? "",
                $0.evidence?.readGroupID ?? "",
                $0.evidence.map { String($0.referenceStart) } ?? "",
                $0.evidence?.cigar ?? "",
            ]
        }
        return result
    }

    internal func sampleWorkbookRows(_ rows: [FullLengthONTMHCSampleSummary]) -> [[String]] {
        let overallInputReads = rows.reduce(0) { $0 + $1.totalInputReads }
        let overallRetainedReads = rows.reduce(0) { $0 + $1.assignedReads }
        let overallRetainedPercent = overallInputReads > 0
            ? Double(overallRetainedReads) / Double(overallInputReads) * 100.0
            : nil
        var result = [[
            "sample",
            "total_input_reads",
            "cluster_count",
            "clustered_reads",
            "sample_unique_retained_reads",
            "sample_unique_retained_percent",
            "overall_input_reads",
            "overall_unique_retained_reads",
            "overall_unique_retained_percent",
            "unmatched_clusters",
            "cdna_clusters",
            "savont_preset",
            "savont_status",
            "savont_fallback_reason",
        ]]
        result += rows.map {
            let samplePercent = $0.totalInputReads > 0
                ? Double($0.assignedReads) / Double($0.totalInputReads) * 100.0
                : nil
            return [
                $0.sample,
                String($0.totalInputReads),
                String($0.clusterCount),
                String($0.clusteredReads),
                String($0.assignedReads),
                oneDecimalString(samplePercent),
                String(overallInputReads),
                String(overallRetainedReads),
                oneDecimalString(overallRetainedPercent),
                String($0.unmatchedClusters),
                String($0.cdnaClusters),
                $0.savontPreset,
                $0.savontStatus.rawValue,
                $0.savontFallbackReason ?? "",
            ]
        }
        return result
    }
}

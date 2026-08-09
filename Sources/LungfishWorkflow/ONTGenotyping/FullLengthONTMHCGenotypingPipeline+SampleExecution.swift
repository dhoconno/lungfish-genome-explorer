import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func materializeFASTQ(
        inputURL: URL,
        sample: String,
        sampleDirectory: URL,
        logicalFinalOutputURL: URL
    ) throws -> FullLengthONTMHCFASTQMaterializationResult {
        let outputURL = sampleDirectory.appendingPathComponent("00-input.fastq")
        return try FullLengthONTMHCFASTQMaterializer.materializePlainFASTQ(
            inputURL: inputURL,
            outputURL: outputURL,
            logicalOutputURL: logicalFinalOutputURL
                .appendingPathComponent("workflow", isDirectory: true)
                .appendingPathComponent(sample, isDirectory: true)
                .appendingPathComponent("00-input.fastq")
        )
    }

    internal func stageSamples(
        request: FullLengthONTMHCGenotypingRunRequest,
        workDirectory: URL,
        logicalFinalOutputURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) throws -> [FullLengthONTMHCScheduledSample] {
        var sampleNameCounts: [String: Int] = [:]
        var stagedSamples: [FullLengthONTMHCScheduledSample] = []
        let totalCount = request.inputFASTQURLs.count
        for (index, inputURL) in request.inputFASTQURLs.enumerated() {
            let sampleBaseName = sampleName(for: inputURL, fallbackIndex: index)
            let sampleOccurrence = (sampleNameCounts[sampleBaseName] ?? 0) + 1
            sampleNameCounts[sampleBaseName] = sampleOccurrence
            let sample = sampleOccurrence == 1 ? sampleBaseName : "\(sampleBaseName)-\(sampleOccurrence)"
            progressHandler?(
                FullLengthONTMHCSampleScheduler.stagingProgress(
                    stagedSampleCount: index,
                    totalSampleCount: totalCount
                ),
                "Staging FASTQ \(index + 1)/\(totalCount): \(sample)."
            )
            let sampleDirectory = workDirectory.appendingPathComponent(sample, isDirectory: true)
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
            let materialization = try materializeFASTQ(
                inputURL: inputURL,
                sample: sample,
                sampleDirectory: sampleDirectory,
                logicalFinalOutputURL: logicalFinalOutputURL
            )
            let materializedFASTQ = materialization.outputURL
            let readCount = fastqReadCount(materializedFASTQ)
            stagedSamples.append(FullLengthONTMHCScheduledSample(
                originalIndex: index,
                inputURL: inputURL,
                sample: sample,
                sampleDirectory: sampleDirectory,
                materializedFASTQURL: materializedFASTQ,
                readCount: readCount,
                materializationStep: materialization.step
            ))
            progressHandler?(
                FullLengthONTMHCSampleScheduler.stagingProgress(
                    stagedSampleCount: index + 1,
                    totalSampleCount: totalCount
                ),
                "Staged \(index + 1)/\(totalCount): \(sample) (\(formattedReadCount(readCount)) reads)."
            )
        }
        return stagedSamples
    }

    internal func processSample(
        _ scheduled: FullLengthONTMHCScheduledSample,
        processingRank: Int,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> FullLengthONTMHCSampleResult {
        var steps: [FullLengthONTMHCProvenanceStep] = []
        let preparedFASTQ = try await prepareReadsForSavont(
            inputFASTQ: scheduled.materializedFASTQURL,
            sample: scheduled.sample,
            sampleDirectory: scheduled.sampleDirectory,
            request: request,
            execution: execution,
            steps: &steps
        )
        if request.reuseCompatibleCheckpoints,
           let checkpoint = try loadCompatibleSampleCheckpoint(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
           ) {
            progressHandler?(
                progressFraction,
                "Reused compatible full-length ONT MHC checkpoint for \(scheduled.sample)."
            )
            return checkpoint.result.rehydrated(
                originalIndex: scheduled.originalIndex,
                processingRank: processingRank,
                readCount: scheduled.readCount,
                prepSteps: steps,
                reuseStep: sampleCheckpointReuseStep(
                    checkpointURL: checkpoint.url,
                    result: checkpoint.result
                )
            )
        }
        let selectedClustering = try await selectSavontClusters(
            scheduled: scheduled,
            preparedFASTQ: preparedFASTQ,
            request: request,
            execution: execution,
            progressFraction: progressFraction,
            progressHandler: progressHandler,
            steps: &steps
        )
        let clustersFASTAURL = selectedClustering.clustersFASTAURL
        let clusterRecords = try FullLengthONTMHCClusterGenotyper.readFASTARecords(
            from: clustersFASTAURL
        )
        guard !clusterRecords.isEmpty else {
            let sampleSummary = FullLengthONTMHCSampleSummary(
                sample: scheduled.sample,
                totalInputReads: scheduled.readCount,
                clusterCount: 0,
                clusteredReads: 0,
                assignedReads: 0,
                unmatchedClusters: 0,
                cdnaClusters: 0,
                savontPreset: selectedClustering.preset.label,
                savontStatus: selectedClustering.handledSavontFailure
                    ? .handledSavontFailure
                    : .noCall,
                savontFallbackReason: selectedClustering.fallbackReason
            )
            let result = FullLengthONTMHCSampleResult(
                originalIndex: scheduled.originalIndex,
                processingRank: processingRank,
                sample: scheduled.sample,
                readCount: scheduled.readCount,
                clustersFASTAURL: clustersFASTAURL,
                clusterRecords: clusterRecords,
                genotypeRows: [],
                sampleSummary: sampleSummary,
                unmatchedClusters: [],
                cdnaMatchedClusters: [],
                closestMatches: [],
                steps: steps
            )
            return try saveSampleCheckpoint(
                result: result,
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
            )
        }

        let sampleSummary = FullLengthONTMHCSampleSummary(
            sample: scheduled.sample,
            totalInputReads: scheduled.readCount,
            clusterCount: clusterRecords.count,
            clusteredReads: clusterRecords.reduce(0) { $0 + $1.readCount },
            assignedReads: 0,
            unmatchedClusters: 0,
            cdnaClusters: 0,
            savontPreset: selectedClustering.preset.label,
            savontStatus: .noCall,
            savontFallbackReason: selectedClustering.fallbackReason
        )
        let result = FullLengthONTMHCSampleResult(
            originalIndex: scheduled.originalIndex,
            processingRank: processingRank,
            sample: scheduled.sample,
            readCount: scheduled.readCount,
            clustersFASTAURL: clustersFASTAURL,
            clusterRecords: clusterRecords,
            genotypeRows: [],
            sampleSummary: sampleSummary,
            unmatchedClusters: [],
            cdnaMatchedClusters: [],
            closestMatches: [],
            steps: steps
        )
        return try saveSampleCheckpoint(
            result: result,
            scheduled: scheduled,
            preparedFASTQ: preparedFASTQ,
            request: request,
            referenceFASTAURL: referenceFASTAURL,
            execution: execution
        )
    }

    internal func genotypeSummariesFromFinalCohortBAM(
        orderedResults: [FullLengthONTMHCSampleResult],
        samURL: URL,
        cohortAlignmentResult: FullLengthONTMHCCohortAlignmentResult,
        referenceFASTAURL: URL,
        referenceRecords: [MHCReferenceRecord],
        request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> [String: FullLengthONTMHCClusterGenotypingSummary] {
        let readGroupBySample = Dictionary(
            uniqueKeysWithValues: cohortAlignmentResult.sampleMappings.map {
                ($0.sampleID, $0.readGroupID)
            }
        )
        return try FullLengthONTMHCFinalBAMParser().genotypeSummaries(
            samURL: samURL,
            referenceFASTAURL: referenceFASTAURL,
            referenceRecords: referenceRecords,
            samples: orderedResults.map { result in
                FullLengthONTMHCFinalBAMSampleContext(
                    sampleID: result.sample,
                    readGroupID: readGroupBySample[result.sample],
                    clusterRecords: result.clusterRecords
                )
            },
            cdnaThreshold: request.cdnaThreshold,
            minUnmatchedReads: request.minUnmatchedReads
        )
    }

    internal func reciprocalKnownGenotypeRows(
        from result: FullLengthONTMHCCandidateArtifactResult
    ) -> [FullLengthONTMHCClusterGenotypeRow] {
        return zip(result.classifiedClusters, result.classifications).flatMap {
            (cluster, classification) -> [FullLengthONTMHCClusterGenotypeRow] in
            guard case .known(let calls) = classification else { return [] }
            return calls.flatMap { call in
                cluster.observations.flatMap { observation in
                    observation.sourceClusterIDs.compactMap { sourceClusterID in
                        guard let reads = observation.sourceClusterReadCounts[sourceClusterID] else { return nil }
                        return FullLengthONTMHCClusterGenotypeRow(
                            sample: observation.sampleID,
                            cluster: sourceClusterID,
                            clusterReads: reads,
                            allele: call.reference.alleleName,
                            alleleLength: call.reference.sequenceLength,
                            alignedBases: call.comparableBases,
                            score: call.alignmentScore,
                            referenceSequenceID: call.reference.sequenceID,
                            mappingQuality: call.mappingQuality,
                            cigar: call.cigar,
                            evidence: call.evidence
                        )
                    }
                }
            }
        }.sorted {
            if $0.sample != $1.sample {
                return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
            }
            if $0.allele != $1.allele {
                return $0.allele.localizedStandardCompare($1.allele) == .orderedAscending
            }
            if $0.cluster != $1.cluster {
                return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending
            }
            if $0.referenceSequenceID != $1.referenceSequenceID {
                return ($0.referenceSequenceID ?? "").localizedStandardCompare(
                    $1.referenceSequenceID ?? ""
                ) == .orderedAscending
            }
            return ($0.cigar ?? "").localizedStandardCompare($1.cigar ?? "") == .orderedAscending
        }
    }

    internal func runNativeTool(
        _ tool: NativeTool,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        workingDirectory: URL,
        provenanceOutputs: [URL]? = nil,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws {
        let startedAt = Date()
        let result = try await nativeToolRunner.run(
            tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: 3_600
        )
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: tool.executableName,
            toolVersion: await nativeToolRunner.getToolVersion(tool) ?? "unknown",
            argv: result.arguments.isEmpty ? [tool.executableName] + arguments : result.arguments,
            inputs: inputs,
            outputs: provenanceOutputs ?? outputs,
            exitStatus: result.exitCode,
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        guard result.isSuccess else {
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: tool.executableName,
                status: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    internal func prepareBlastRescueReference(
        _ referenceFASTAURL: URL,
        rescueDirectory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: rescueDirectory, withIntermediateDirectories: true)
        let outputURL = rescueDirectory.appendingPathComponent("reference.fa")
        let records = try FullLengthONTMHCClusterGenotyper.readFASTARecords(from: referenceFASTAURL)
        try writeFASTARecords(records, to: outputURL)
        return outputURL
    }

    internal func rescueUnmatchedMHCMatches(
        sample: String,
        records: [FullLengthONTMHCClusterFASTARecord],
        referenceFASTAURL: URL,
        sampleDirectory: URL,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> [FullLengthONTMHCBlastRescueMatch] {
        guard !records.isEmpty else { return [] }
        let rescueDirectory = sampleDirectory.appendingPathComponent("blast-rescue", isDirectory: true)
        try FileManager.default.createDirectory(at: rescueDirectory, withIntermediateDirectories: true)
        let queryURL = rescueDirectory.appendingPathComponent("\(sample).unmatched-no-closest.fasta")
        let tsvURL = blastRescueTSVURL(
            sample: sample,
            sampleDirectory: sampleDirectory
        )
        try writeFASTARecords(records, to: queryURL)
        let outfmt = [
            "6",
            "qseqid",
            "sseqid",
            "pident",
            "length",
            "mismatch",
            "gapopen",
            "qstart",
            "qend",
            "sstart",
            "send",
            "evalue",
            "bitscore",
            "qlen",
            "slen",
        ].joined(separator: " ")
        let arguments = [
            "-query", queryURL.path,
            "-subject", referenceFASTAURL.path,
            "-task", "blastn",
            "-dust", "no",
            "-evalue", String(FullLengthONTMHCBlastRescueMatch.maximumEValue),
            "-outfmt", outfmt,
        ]
        let startedAt = Date()
        let result = try await nativeToolRunner.run(
            .blastn,
            arguments: arguments,
            workingDirectory: rescueDirectory,
            timeout: 3_600
        )
        try result.stdout.write(to: tsvURL, atomically: true, encoding: .utf8)
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "blastn",
            toolVersion: await nativeToolRunner.getToolVersion(.blastn) ?? "unknown",
            argv: result.arguments.isEmpty ? ["blastn"] + arguments : result.arguments,
            inputs: [queryURL, referenceFASTAURL],
            outputs: [tsvURL],
            exitStatus: result.exitCode,
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        guard result.exitCode == 0 else {
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: "blastn",
                status: result.exitCode,
                stderr: result.stderr
            )
        }
        let tsv = try String(contentsOf: tsvURL, encoding: .utf8)
        return try FullLengthONTMHCBlastRescueParser.acceptedMatches(
            sample: sample,
            recordsByCluster: Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) }),
            tsv: tsv
        )
    }

    internal func blastRescueTSVURL(sample: String, sampleDirectory: URL) -> URL {
        sampleDirectory
            .appendingPathComponent("blast-rescue", isDirectory: true)
            .appendingPathComponent("\(sample).unmatched-blast-rescue.tsv")
    }
}

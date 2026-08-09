import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func writeProvenance(
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        executionPlan: FullLengthONTMHCSampleExecutionPlan,
        stagedSamples: [FullLengthONTMHCScheduledSample],
        processingOrder: [FullLengthONTMHCScheduledSample],
        steps: [FullLengthONTMHCProvenanceStep],
        cohortAlignmentResult: FullLengthONTMHCCohortAlignmentResult,
        bamViewRecord: FullLengthONTMHCCohortAlignmentCommandRecord,
        candidateArtifactResult: FullLengthONTMHCCandidateArtifactResult,
        referenceVisualizationPublication: FullLengthONTMHCReferenceVisualizationPublication?,
        manifestPublicationPlan: FullLengthONTMHCSuccessManifestPublicationPlan,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let defaults: [String: ParameterValue] = [
            "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            "minimumLength": .integer(2_000),
            "maximumLength": .integer(4_000),
            "savontQualityValueCutoff": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize),
            "hiddenSavontNoCallFallback": .string("qv90-min1"),
            "savontCondaEnvironment": .string(FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment),
            "savontPackageSpec": .string(FullLengthONTMHCGenotypingRunRequest.savontPackageSpec),
            "savontToolVersion": .string(FullLengthONTMHCGenotypingRunRequest.savontToolVersion),
            "minUnmatchedReads": .integer(5),
            "cdnaThreshold": .integer(2_000),
            "mhcLikeBlastRescue": .string("enabled"),
            "mhcLikeBlastRescueMinimumQueryCoverage": .number(FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage),
            "mhcLikeBlastRescueMinimumAlignedBases": .integer(FullLengthONTMHCBlastRescueMatch.minimumAlignedBases),
            "mhcLikeBlastRescueMinimumPercentIdentity": .number(FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity),
            "mhcLikeBlastRescueMaximumEValue": .number(FullLengthONTMHCBlastRescueMatch.maximumEValue),
            "sampleJobs": .string("auto"),
            "savontThreadsPerSample": .string("auto"),
            "haplotypeDropoutSampleFraction": .string("disabled"),
            "haplotypeDropoutLocusFraction": .string("disabled"),
            "haplotypeDropoutLocusFractionOverrides": .dictionary([:]),
            "haplotypeDefinition": .string("disabled"),
            "keepIntermediates": .boolean(false),
            "reuseCompatibleCheckpoints": .boolean(false),
            "mhcMappingPreset": .string("splice"),
            "mhcCandidateReciprocalMappingPreset": .string("asm20"),
            "mhcCandidateReciprocalMaximumSecondaryAlignments": .integer(100),
            "mhcCandidateReciprocalSecondaryAlignments": .boolean(true),
            "mhcCandidateReciprocalEQX": .boolean(true),
            "mhcCandidateReciprocalCS": .string("long"),
            "mhcCandidateMinimumAlignedBases": .integer(ONTMHCCandidateThresholds.defaults.minimumAlignedBases),
            "mhcCandidateMinimumIdentity": .number(ONTMHCCandidateThresholds.defaults.minimumIdentity),
            "mhcCandidateMinimumShorterCoverage": .number(ONTMHCCandidateThresholds.defaults.minimumShorterCoverage),
            "mhcCandidateMinimumIntronGapBases": .integer(ONTMHCCandidateThresholds.defaults.minimumIntronGapBases),
            "mhcCandidateNovelDistanceMetric": .string("SNP-substitutions-only"),
            "mhcCandidateZeroSNPIndelClassification": .string("known-existing-allele"),
            "mhcRawUnmatchedConsensusesPath": .string("artifacts/internal/raw-unmatched-consensuses.fasta"),
            "mhcRawUnmatchedDecisionPath": .string("artifacts/internal/raw-unmatched-consensus-decisions.json"),
            "mhcCanonicalUnmatchedClustersPath": .string("deduplicated_unmatched_clusters.fasta"),
            "mhcCanonicalUnmatchedPublicationRule": .string("writer-only-root-publication"),
            "mhcReferenceVisualizationSchemaVersion": .integer(1),
            "mhcReferenceVisualizationRecordsPath": .string("artifacts/reference/mhc-reference-visualizations.json"),
            "mhcReferenceVisualizationGenBankPath": .string("artifacts/reference/mhc-reference-records.gb"),
            "mhcReferenceVisualizationFASTAPath": .string("artifacts/reference/mhc-reference-records.fasta"),
            "mhcResultBundleAtomicPublication": .string("adjacent-directory-renameatx_np"),
            "minimap2CondaEnvironment": .string("minimap2"),
            "samtoolsCondaEnvironment": .string("samtools"),
            "mhcWorkbookSharedNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedNovel),
            "mhcWorkbookSingletonNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonNovel),
            "mhcWorkbookSharedExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedExtension),
            "mhcWorkbookSingletonExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonExtension),
        ]
        let resolved: [String: ParameterValue] = [
            "threads": .integer(request.threads),
            "minimumLength": .integer(request.minimumLength),
            "maximumLength": .integer(request.maximumLength),
            "savontQualityValueCutoff": .integer(request.savontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(request.savontMinimumClusterSize),
            "hiddenSavontNoCallFallback": shouldRunHiddenSavontNoCallFallback(for: request)
                ? .string(FullLengthONTMHCSavontPreset.hiddenNoCallFallback.label)
                : .string("disabled"),
            "savontCondaEnvironment": .string(FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment),
            "savontPackageSpec": .string(FullLengthONTMHCGenotypingRunRequest.savontPackageSpec),
            "savontToolVersion": .string(FullLengthONTMHCGenotypingRunRequest.savontToolVersion),
            "minUnmatchedReads": .integer(request.minUnmatchedReads),
            "cdnaThreshold": .integer(request.cdnaThreshold),
            "mhcLikeBlastRescue": .string("enabled"),
            "mhcLikeBlastRescueMinimumQueryCoverage": .number(FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage),
            "mhcLikeBlastRescueMinimumAlignedBases": .integer(FullLengthONTMHCBlastRescueMatch.minimumAlignedBases),
            "mhcLikeBlastRescueMinimumPercentIdentity": .number(FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity),
            "mhcLikeBlastRescueMaximumEValue": .number(FullLengthONTMHCBlastRescueMatch.maximumEValue),
            "sampleJobs": .integer(executionPlan.sampleJobs),
            "savontThreadsPerSample": .integer(executionPlan.savontThreadsPerSample),
            "workerThreadsPerSample": .integer(executionPlan.workerThreadsPerSample),
            "haplotypeDropoutSampleFraction": request.haplotypeDropoutSampleFraction
                .map(ParameterValue.number) ?? .string("disabled"),
            "haplotypeDropoutLocusFraction": request.haplotypeDropoutLocusFraction
                .map(ParameterValue.number) ?? .string("disabled"),
            "haplotypeDropoutLocusFractionOverrides": .dictionary(
                request.haplotypeDropoutLocusFractionOverrides.mapValues(ParameterValue.number)
            ),
            "haplotypeDefinition": request.haplotypeDefinitionSetID
                .map(ParameterValue.string) ?? .string("disabled"),
            "keepIntermediates": .boolean(request.keepIntermediates),
            "reuseCompatibleCheckpoints": .boolean(request.reuseCompatibleCheckpoints),
            "mhcMappingPreset": .string("splice"),
            "mhcCohortAlignmentThreads": .integer(request.threads),
            "mhcCandidateReciprocalMappingPreset": .string("asm20"),
            "mhcCandidateReciprocalMaximumSecondaryAlignments": .integer(100),
            "mhcCandidateReciprocalSecondaryAlignments": .boolean(true),
            "mhcCandidateReciprocalEQX": .boolean(true),
            "mhcCandidateReciprocalCS": .string("long"),
            "mhcCandidateMinimumAlignedBases": .integer(ONTMHCCandidateThresholds.defaults.minimumAlignedBases),
            "mhcCandidateMinimumIdentity": .number(ONTMHCCandidateThresholds.defaults.minimumIdentity),
            "mhcCandidateMinimumShorterCoverage": .number(ONTMHCCandidateThresholds.defaults.minimumShorterCoverage),
            "mhcCandidateMinimumIntronGapBases": .integer(ONTMHCCandidateThresholds.defaults.minimumIntronGapBases),
            "mhcCandidateNovelDistanceMetric": .string("SNP-substitutions-only"),
            "mhcCandidateZeroSNPIndelClassification": .string("known-existing-allele"),
            "mhcRawUnmatchedConsensusesPath": .string("artifacts/internal/raw-unmatched-consensuses.fasta"),
            "mhcRawUnmatchedDecisionPath": .string("artifacts/internal/raw-unmatched-consensus-decisions.json"),
            "mhcCanonicalUnmatchedClustersPath": .string("deduplicated_unmatched_clusters.fasta"),
            "mhcCanonicalUnmatchedPublicationRule": .string("writer-only-root-publication"),
            "mhcReferenceVisualizationSchemaVersion": .integer(1),
            "mhcReferenceVisualizationRecordsPath": .string("artifacts/reference/mhc-reference-visualizations.json"),
            "mhcReferenceVisualizationGenBankPath": .string("artifacts/reference/mhc-reference-records.gb"),
            "mhcReferenceVisualizationFASTAPath": .string("artifacts/reference/mhc-reference-records.fasta"),
            "mhcResultBundleAtomicPublication": .string("adjacent-directory-renameatx_np"),
            "minimap2CondaEnvironment": .string("minimap2"),
            "samtoolsCondaEnvironment": .string("samtools"),
            "mhcWorkbookSharedNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedNovel),
            "mhcWorkbookSingletonNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonNovel),
            "mhcWorkbookSharedExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedExtension),
            "mhcWorkbookSingletonExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonExtension),
        ]
        var explicit = resolved
        explicit["requestedSampleJobs"] = request.sampleJobs.map(ParameterValue.integer) ?? .string("auto")
        explicit["requestedSavontThreadsPerSample"] = request.savontThreadsPerSample.map(ParameterValue.integer) ?? .string("auto")
        explicit["inputFASTQs"] = .array(request.inputFASTQURLs.map(ParameterValue.file))
        explicit["reference"] = .file(request.referenceSourceURL)
        explicit["resolvedReferenceFASTA"] = .file(referenceFASTAURL)
        explicit["outputDirectory"] = .file(request.outputDirectory)
        explicit["outputName"] = .string(request.outputName)
        explicit["currentWorkbook"] = .file(request.currentWorkbookURL)
        explicit["genotypingEvidenceBAM"] = .file(cohortAlignmentResult.bamURL)
        explicit["genotypingEvidenceBAI"] = .file(cohortAlignmentResult.baiURL)
        explicit["mhcCohortSampleMergeOrder"] = .array(
            cohortAlignmentResult.sampleMappings.map { .string($0.sampleID) }
        )
        explicit["mhcInProcessTransformationResolvedOptions"] = .array(
            (cohortAlignmentResult.transformationRecords + candidateArtifactResult.transformationRecords).map { transformation in
                .dictionary(transformation.resolvedOptions.mapValues(ParameterValue.string))
            }
        )
        explicit["mhcRawUnmatchedConsensusesFASTA"] = .file(request.rawUnmatchedConsensusesFASTAURL)
        explicit["mhcRawUnmatchedDecisionPayload"] = .file(
            request.rawUnmatchedConsensusDecisionsJSONURL
        )
        explicit["mhcCandidateStableUnmatchedFASTA"] = .file(candidateArtifactResult.stableUnmatchedFASTAURL)
        explicit["mhcCandidateReciprocalBAM"] = .file(candidateArtifactResult.reciprocalBAMURL)
        explicit["mhcCandidateReciprocalBAI"] = .file(candidateArtifactResult.reciprocalBAIURL)
        explicit["mhcCandidateJSON"] = .file(candidateArtifactResult.candidateJSONURL)
        explicit["mhcCandidateFASTA"] = .file(candidateArtifactResult.candidateFASTAURL)
        explicit["mhcCandidateGenBank"] = .file(candidateArtifactResult.candidateGenBankURL)
        explicit["mhcCandidateEMBL"] = .file(candidateArtifactResult.candidateEMBLURL)
        explicit["mhcUnnameableJSON"] = .file(candidateArtifactResult.unnameableJSONURL)
        explicit["mhcUnnameableFASTA"] = .file(candidateArtifactResult.unnameableFASTAURL)
        explicit["mhcUnnameableGenBank"] = .file(candidateArtifactResult.unnameableGenBankURL)
        explicit["mhcUnnameableEMBL"] = .file(candidateArtifactResult.unnameableEMBLURL)
        if let referenceVisualizationPublication {
            explicit["mhcReferenceVisualizationRecords"] = .file(
                referenceVisualizationPublication.recordsJSONURL
            )
            explicit["mhcReferenceVisualizationGenBank"] = .file(
                referenceVisualizationPublication.genBankURL
            )
            explicit["mhcReferenceVisualizationFASTA"] = .file(
                referenceVisualizationPublication.fastaURL
            )
        }
        if let minimap2ExecutableURL = cohortAlignmentResult.toolVersions.first(where: { $0.toolName == "minimap2" })?
            .discoveryCommand.executableURL {
            explicit["resolvedMinimap2Executable"] = .file(minimap2ExecutableURL)
            explicit["minimap2CondaPrefix"] = .file(
                minimap2ExecutableURL.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        if let samtoolsExecutableURL = cohortAlignmentResult.toolVersions.first(where: { $0.toolName == "samtools" })?
            .discoveryCommand.executableURL {
            explicit["resolvedSamtoolsExecutable"] = .file(samtoolsExecutableURL)
            explicit["samtoolsCondaPrefix"] = .file(
                samtoolsExecutableURL.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        explicit["sampleReadCounts"] = .dictionary(Dictionary(uniqueKeysWithValues: stagedSamples.map {
            ($0.sample, ParameterValue.integer($0.readCount))
        }))
        explicit["sampleProcessingOrder"] = .array(processingOrder.map { .string($0.sample) })
        if let haplotypeAssayID = request.haplotypeAssayID {
            explicit["haplotypeAssay"] = .string(haplotypeAssayID)
        }
        if let haplotypeSpeciesCode = request.haplotypeSpeciesCode {
            explicit["haplotypeSpecies"] = .string(haplotypeSpeciesCode)
        }
        if let haplotypeDefinitionScope = request.haplotypeDefinitionScope {
            explicit["haplotypeDefinitionScope"] = .string(haplotypeDefinitionScope.rawValue)
        }
        if request.haplotypeDefinitionSetID != nil {
            explicit["haplotypeAnalysis"] = .file(request.haplotypeAnalysisURL)
        }
        if let orientReferenceURL = request.orientReferenceURL {
            explicit["orientReference"] = .file(orientReferenceURL)
        }
        if let forwardPrimerURL = request.forwardPrimerURL {
            explicit["forwardPrimer"] = .file(forwardPrimerURL)
        }
        if let reversePrimerURL = request.reversePrimerURL {
            explicit["reversePrimer"] = .file(reversePrimerURL)
        }
        if let projectURL = request.projectURL {
            explicit["project"] = .file(projectURL)
        }

        var builder = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(request.argv)
        .durableReplayArgv(request.argv)
        .reproducibleCommand(request.argv.map(shellEscape).joined(separator: " "))
        .options(explicit: explicit, defaults: defaults, resolved: resolved)
        .runtime(cohortAlignmentResult.runtimeIdentity)
        .input(referenceFASTAURL, format: .fasta, role: .reference)
        .output(request.reportCSVURL, format: .text, role: .report)
        .output(request.sampleSummaryCSVURL, format: .text, role: .report)
        .output(request.statsJSONURL, format: .json, role: .report)
        .output(request.workbookURL, format: .unknown, role: .report)
        .output(request.currentWorkbookURL, format: .unknown, role: .report)
        .relocatedOutput(manifestPublicationPlan.finalDescriptor)
        .output(request.unmatchedClustersFASTAURL, format: .fasta, role: .output)
        .output(request.rawUnmatchedConsensusDecisionsJSONURL, format: .json, role: .output)
        .output(request.rawUnmatchedConsensusesFASTAURL, format: .fasta, role: .output)
        .output(request.deduplicatedUnmatchedClustersFASTAURL, format: .fasta, role: .output)
        .output(request.cdnaClustersFASTAURL, format: .fasta, role: .output)
        .output(cohortAlignmentResult.bamURL, format: .bam, role: .output)
        .output(cohortAlignmentResult.baiURL, format: .unknown, role: .index)
        .output(candidateArtifactResult.reciprocalBAMURL, format: .bam, role: .output)
        .output(candidateArtifactResult.reciprocalBAIURL, format: .unknown, role: .index)
        .output(candidateArtifactResult.candidateJSONURL, format: .json, role: .output)
        .output(candidateArtifactResult.candidateFASTAURL, format: .fasta, role: .output)
        .output(candidateArtifactResult.candidateGenBankURL, format: .genBank, role: .output)
        .output(candidateArtifactResult.candidateEMBLURL, format: .text, role: .output)
        .output(candidateArtifactResult.unnameableJSONURL, format: .json, role: .output)
        .output(candidateArtifactResult.unnameableFASTAURL, format: .fasta, role: .output)
        .output(candidateArtifactResult.unnameableGenBankURL, format: .genBank, role: .output)
        .output(candidateArtifactResult.unnameableEMBLURL, format: .text, role: .output)

        if let referenceVisualizationPublication {
            for outputURL in referenceVisualizationPublication.outputURLs {
                builder = try builder.output(
                    outputURL,
                    format: outputURL.pathExtension.lowercased() == "json" ? .json :
                        (outputURL.pathExtension.lowercased() == "fasta" ? .fasta : .text),
                    role: .output
                )
            }
        }

        if request.haplotypeDefinitionSetID != nil {
            builder = try builder.output(request.haplotypeAnalysisURL, format: .json, role: .report)
        }

        for input in request.inputFASTQURLs where !fullLengthONTMHCPathIsDirectory(input) {
            builder = try builder.input(input, format: .fastq, role: .input)
        }
        for primer in [request.orientReferenceURL, request.forwardPrimerURL, request.reversePrimerURL].compactMap({ $0 }) {
            builder = try builder.input(primer, format: .fasta, role: .reference)
        }
        var allProvenanceSteps = stagedSamples.compactMap(\.materializationStep)
        allProvenanceSteps += try steps.map { try $0.provenanceStep() }
        allProvenanceSteps += try cohortAlignmentProvenanceSteps(
            cohortAlignmentResult,
            bamViewRecord: bamViewRecord
        )
        allProvenanceSteps += try (
            candidateArtifactResult.toolVersionDiscoveryRecords + candidateArtifactResult.commandRecords
        ).map {
            try provenanceStep(for: $0)
        }
        allProvenanceSteps += candidateArtifactResult.transformationRecords.map {
            $0.provenanceStep()
        }
        allProvenanceSteps.sort {
            ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        }
        for step in allProvenanceSteps {
            builder = builder.step(step)
        }

        let builtEnvelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: completedAt
        )
        let durableOutputs = builtEnvelope.outputs.filter { descriptor in
            !descriptor.path.contains(".cohort-alignment-work")
                && !descriptor.path.contains(".candidate-artifact-work")
                && !descriptor.path.contains("/.alignments-replacement-")
                && !descriptor.path.contains("/workflow/")
        }
        let envelope = ProvenanceEnvelope(
            schemaVersion: builtEnvelope.schemaVersion,
            id: builtEnvelope.id,
            createdAt: builtEnvelope.createdAt,
            workflowName: builtEnvelope.workflowName,
            workflowVersion: builtEnvelope.workflowVersion,
            toolName: builtEnvelope.toolName,
            toolVersion: builtEnvelope.toolVersion,
            githubReleaseVersion: builtEnvelope.githubReleaseVersion,
            tool: builtEnvelope.tool,
            argv: builtEnvelope.argv,
            durableReplayArgv: builtEnvelope.durableReplayArgv,
            reproducibleCommand: builtEnvelope.reproducibleCommand,
            options: builtEnvelope.options,
            runtimeIdentity: builtEnvelope.runtimeIdentity,
            files: builtEnvelope.files,
            output: durableOutputs.first,
            outputs: durableOutputs,
            steps: builtEnvelope.steps,
            wallTimeSeconds: builtEnvelope.wallTimeSeconds,
            exitStatus: builtEnvelope.exitStatus,
            stderr: builtEnvelope.stderr,
            signatures: builtEnvelope.signatures,
            legacyWorkflowRun: builtEnvelope.legacyRun
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: request.provenanceURL)
    }

    internal func loadPartialFailureEnvelope(
        stagedOutputURL: URL,
        finalOutputURL: URL,
        finalExistedBeforeRun: Bool
    ) -> ProvenanceEnvelope? {
        let stagedURL = stagedOutputURL.appendingPathComponent(
            "full-length-ont-mhc-genotyping-provenance.json"
        )
        if let envelope = try? ProvenanceEnvelopeReader.load(fromSidecar: stagedURL) {
            return envelope
        }
        guard !finalExistedBeforeRun else { return nil }
        let finalURL = finalOutputURL.appendingPathComponent(
            "full-length-ont-mhc-genotyping-provenance.json"
        )
        return try? ProvenanceEnvelopeReader.load(fromSidecar: finalURL)
    }

    internal func writeFailureProvenance(
        request: FullLengthONTMHCGenotypingRunRequest,
        stagedOutputURL: URL,
        startedAt: Date,
        error: Error,
        partialEnvelope: ProvenanceEnvelope?,
        failedPublicationRecord: FullLengthONTMHCResultBundlePublicationRecord?,
        successfulPublicationRecord: FullLengthONTMHCResultBundlePublicationRecord?,
        rollbackStep: ProvenanceStep?,
        rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery?,
        additionalDiagnosticRoots: [URL] = []
    ) throws {
        let completedAt = Date()
        let cancelled = isCancellation(error)
        let exitStatus = cancelled ? 130 : 1
        let stderrText = cancelled
            ? "Full-length ONT MHC genotyping was cancelled: \(error.localizedDescription)"
            : error.localizedDescription
        let inputs = try failureInputDescriptors(request)
        let outputs = try failureDiagnosticDescriptors(
            stagedOutputURL: stagedOutputURL,
            additionalRoots: additionalDiagnosticRoots
        )
        let options = failureProvenanceOptions(
            request: request,
            outcome: cancelled ? "cancelled" : "failed",
            retainedDiagnosticCount: outputs.count,
            rollbackFailureRecovery: rollbackFailureRecovery
        )
        var steps = partialEnvelope?.steps ?? []
        func appendIfMissing(_ candidate: ProvenanceStep) {
            let exists = steps.contains {
                $0.toolName == candidate.toolName
                    && $0.argv == candidate.argv
                    && $0.exitStatus == candidate.exitStatus
                    && $0.startedAt == candidate.startedAt
            }
            if !exists {
                steps.append(candidate)
            }
        }
        if let cohortError = error as? FullLengthONTMHCCohortAlignmentBuildError {
            for record in cohortError.toolVersionDiscoveryRecords + cohortError.commandRecords {
                do {
                    steps.append(try provenanceStep(for: record))
                } catch {
                    let sourceURL = record.inputs.first ?? record.executableURL
                    throw FullLengthFailureProvenancePreparationError(
                        inputURL: sourceURL,
                        operation: "rehydrating a failed cohort command provenance step",
                        underlyingError: error
                    )
                }
            }
            steps.append(contentsOf: cohortError.transformationRecords.map { $0.provenanceStep() })
        }
        if let visualizationError = error as? FullLengthONTMHCReferenceVisualizationPublicationError {
            appendIfMissing(visualizationError.step)
        }
        if let catalogError =
            error as? GenotypeReviewableRowCatalogPublicationFailure,
           let failedStep = catalogError.provenance.steps.last {
            appendIfMissing(failedStep)
        }
        if let successfulPublicationRecord {
            appendIfMissing(successfulPublicationRecord.provenanceStep)
        }
        if let failedPublicationRecord {
            appendIfMissing(failedPublicationRecord.provenanceStep)
        }
        if let rollbackStep {
            appendIfMissing(rollbackStep)
        }
        let receiptArgv = request.argv + [
            "--failure-provenance", request.failureProvenanceURL.path,
        ]
        steps.append(ProvenanceStep(
            toolName: "lungfish-internal record-full-length-mhc-failed-run",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: receiptArgv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: options.resolvedDefaults,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: inputs,
            outputs: outputs,
            exitStatus: exitStatus,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderrText,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        steps.sort { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        var seenFiles = Set<String>()
        let files = (inputs + outputs + steps.flatMap { $0.inputs + $0.outputs }).filter {
            seenFiles.insert("\($0.role.rawValue)\u{0}\($0.path)").inserted
        }
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: CLICommandIdentity.executableName,
                version: WorkflowRun.currentAppVersion,
                kind: "cli"
            ),
            argv: request.argv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            options: options,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: files,
            output: outputs.first,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: exitStatus,
            stderr: stderrText
        )
        if FileManager.default.fileExists(atPath: request.failureProvenanceURL.path) {
            try FileManager.default.removeItem(at: request.failureProvenanceURL)
        }
        try ProvenanceWriter(signingProvider: nil).write(
            envelope,
            toSidecar: request.failureProvenanceURL
        )
    }

    internal func failureInputDescriptors(
        _ request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> [ProvenanceFileDescriptor] {
        var descriptors: [ProvenanceFileDescriptor] = []
        for inputURL in request.inputFASTQURLs {
            do {
                let sourceDescriptors = try FullLengthONTMHCFASTQMaterializer
                    .provenanceSourceDescriptors(for: inputURL)
                descriptors.append(contentsOf: sourceDescriptors)
            } catch {
                throw FullLengthFailureProvenancePreparationError(
                    inputURL: inputURL,
                    operation: "describing a FASTQ scientific source",
                    underlyingError: error
                )
            }
        }
        let referenceFASTA: URL
        do {
            referenceFASTA = try resolveMHCReferenceFASTA(request.referenceSourceURL)
        } catch {
            throw FullLengthFailureProvenancePreparationError(
                inputURL: request.referenceSourceURL,
                operation: "resolving the MHC reference source",
                underlyingError: error
            )
        }
        let catalogInputs: FullLengthONTMHCReferenceCatalogInputs
        do {
            catalogInputs = try mhcReferenceCatalogInputs(
                sourceURL: request.referenceSourceURL,
                fastaURL: referenceFASTA
            )
        } catch {
            throw FullLengthFailureProvenancePreparationError(
                inputURL: request.referenceSourceURL,
                operation: "resolving MHC reference catalog inputs",
                underlyingError: error
            )
        }
        let referencePaths = Set(catalogInputs.allURLs.map {
            $0.standardizedFileURL.path
        })
        let supplementalURLs: [URL] = catalogInputs.allURLs + [
            request.orientReferenceURL,
            request.forwardPrimerURL,
            request.reversePrimerURL,
        ].compactMap { $0 }
        var seen = Set<String>()
        for url in supplementalURLs.map(\.standardizedFileURL) where seen.insert(url.path).inserted {
            do {
                descriptors.append(try ProvenanceFileDescriptor.file(
                    url: url,
                    format: failureFileFormat(url),
                    role: referencePaths.contains(url.path) ? .reference : .input
                ))
            } catch {
                throw FullLengthFailureProvenancePreparationError(
                    inputURL: url,
                    operation: referencePaths.contains(url.path)
                        ? "describing an MHC reference or catalog source"
                        : "describing a configured scientific input",
                    underlyingError: error
                )
            }
        }
        var seenDescriptors = Set<String>()
        return descriptors.filter {
            seenDescriptors.insert("\($0.role.rawValue)\u{0}\($0.path)").inserted
        }
    }

    internal func failureProvenancePreparationReceiptData(
        request: FullLengthONTMHCGenotypingRunRequest,
        runID: UUID,
        startedAt: Date,
        originalError: Error,
        preparationError: FullLengthFailureProvenancePreparationError,
        rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery?
    ) throws -> Data {
        let completedAt = Date()
        let exitStatus = isCancellation(originalError) ? 130 : 1
        let stderr = [
            originalError.localizedDescription,
            preparationError.localizedDescription,
        ].joined(separator: "\n")
        let receipt = FullLengthFailureProvenancePreparationReceipt(
            schemaVersion: 1,
            kind: "incomplete-failure-provenance-preparation",
            runID: runID,
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: request.argv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            options: failureProvenanceOptions(
                request: request,
                outcome: isCancellation(originalError)
                    ? "cancelled-provenance-incomplete"
                    : "failed-provenance-incomplete",
                retainedDiagnosticCount: 0,
                rollbackFailureRecovery: rollbackFailureRecovery
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputPath: preparationError.inputPath,
            preparationError: preparationError.localizedDescription,
            originalError: originalError.localizedDescription,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: exitStatus,
            stderr: stderr
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }

    internal func failureDiagnosticDescriptors(
        stagedOutputURL: URL,
        additionalRoots: [URL] = []
    ) throws -> [ProvenanceFileDescriptor] {
        let parentURL = stagedOutputURL.deletingLastPathComponent()
        let runToken = stagedOutputURL.lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        var seenRoots = Set<String>()
        let roots = (contents.filter {
            $0.lastPathComponent.contains(runToken)
                && $0.standardizedFileURL != stagedOutputURL.standardizedFileURL
                && !$0.lastPathComponent.contains("candidate-artifact-work")
                && !$0.lastPathComponent.contains("cohort-alignment-work")
        } + additionalRoots)
            .map(\.standardizedFileURL)
            .filter {
                !$0.path.contains("candidate-artifact-work")
                    && !$0.path.contains("cohort-alignment-work")
            }
            .filter { seenRoots.insert($0.path).inserted }
        var fileURLs: [URL] = []
        let safety = FullLengthONTMHCAlignmentSafety()
        for root in roots.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                try safety.requireSafeDirectoryTree(root, role: "retained failed-run diagnostics")
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else { continue }
                for case let entry as URL in enumerator {
                    var entryIsDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory),
                       !entryIsDirectory.boolValue,
                       entry.lastPathComponent != OwnedWorkDirectoryMarker.fileName {
                        fileURLs.append(entry.standardizedFileURL)
                    }
                }
            } else {
                try safety.requireRegularFileNoFollow(root, role: "retained failed-run diagnostic")
                fileURLs.append(root.standardizedFileURL)
            }
        }
        return try fileURLs.sorted { $0.path < $1.path }.map { url in
            try ProvenanceFileDescriptor.file(
                url: url,
                format: failureFileFormat(url),
                role: url.path.contains("/logs/") || url.pathExtension == "log" ? .log : .output
            )
        }
    }

    internal func failureProvenanceOptions(
        request: FullLengthONTMHCGenotypingRunRequest,
        outcome: String,
        retainedDiagnosticCount: Int,
        rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery? = nil
    ) -> ProvenanceOptions {
        let defaults: [String: ParameterValue] = [
            "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            "minimumLength": .integer(2_000),
            "maximumLength": .integer(4_000),
            "savontQualityValueCutoff": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize),
            "minUnmatchedReads": .integer(5),
            "cdnaThreshold": .integer(2_000),
            "sampleJobs": .string("auto"),
            "savontThreadsPerSample": .string("auto"),
            "keepIntermediates": .boolean(false),
            "reuseCompatibleCheckpoints": .boolean(false),
        ]
        var resolved: [String: ParameterValue] = [
            "threads": .integer(request.threads),
            "minimumLength": .integer(request.minimumLength),
            "maximumLength": .integer(request.maximumLength),
            "savontQualityValueCutoff": .integer(request.savontQualityValueCutoff),
            "savontMinimumClusterSize": .integer(request.savontMinimumClusterSize),
            "minUnmatchedReads": .integer(request.minUnmatchedReads),
            "cdnaThreshold": .integer(request.cdnaThreshold),
            "sampleJobs": request.sampleJobs.map(ParameterValue.integer) ?? .string("auto"),
            "savontThreadsPerSample": request.savontThreadsPerSample.map(ParameterValue.integer) ?? .string("auto"),
            "keepIntermediates": .boolean(request.keepIntermediates),
            "reuseCompatibleCheckpoints": .boolean(request.reuseCompatibleCheckpoints),
            "outcome": .string(outcome),
            "retainedDiagnosticCount": .integer(retainedDiagnosticCount),
        ]
        resolved["haplotypeDropoutSampleFraction"] = request.haplotypeDropoutSampleFraction
            .map(ParameterValue.number) ?? .string("disabled")
        resolved["haplotypeDropoutLocusFraction"] = request.haplotypeDropoutLocusFraction
            .map(ParameterValue.number) ?? .string("disabled")
        resolved["haplotypeDropoutLocusFractionOverrides"] = .dictionary(
            request.haplotypeDropoutLocusFractionOverrides.mapValues(ParameterValue.number)
        )
        resolved["haplotypeDefinition"] = request.haplotypeDefinitionSetID
            .map(ParameterValue.string) ?? .string("disabled")
        if let path = rollbackFailureRecovery?.retainedPriorGenerationURL?.path {
            resolved["retainedPriorGenerationPath"] = .file(URL(fileURLWithPath: path))
        }
        if let path = rollbackFailureRecovery?.retainedFailedPublishedGenerationURL?.path {
            resolved["retainedFailedPublishedGenerationPath"] = .file(URL(fileURLWithPath: path))
        }
        var explicit = resolved
        explicit["inputFASTQs"] = .array(request.inputFASTQURLs.map(ParameterValue.file))
        explicit["reference"] = .file(request.referenceSourceURL)
        explicit["outputDirectory"] = .file(request.outputDirectory)
        explicit["outputName"] = .string(request.outputName)
        explicit["failureProvenance"] = .file(request.failureProvenanceURL)
        if let value = request.orientReferenceURL { explicit["orientReference"] = .file(value) }
        if let value = request.forwardPrimerURL { explicit["forwardPrimer"] = .file(value) }
        if let value = request.reversePrimerURL { explicit["reversePrimer"] = .file(value) }
        if let value = request.projectURL { explicit["project"] = .file(value) }
        return ProvenanceOptions(explicit: explicit, defaults: defaults, resolvedDefaults: resolved)
    }

    internal func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? FullLengthONTMHCCohortAlignmentBuildError)?.wasCancelled == true
            || Task.isCancelled
    }

    internal func failureFileFormat(_ url: URL) -> FileFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".fastq") || name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq") || name.hasSuffix(".fq.gz") { return .fastq }
        if name.hasSuffix(".fasta") || name.hasSuffix(".fasta.gz") || name.hasSuffix(".fa") || name.hasSuffix(".fa.gz") { return .fasta }
        if name.hasSuffix(".bam") { return .bam }
        if name.hasSuffix(".sam") { return .sam }
        if name.hasSuffix(".json") { return .json }
        if name.hasSuffix(".sqlite") || name.hasSuffix(".db") { return .sqlite }
        if name.hasSuffix(".csv") || name.hasSuffix(".tsv") || name.hasSuffix(".log") { return .text }
        return .unknown
    }

    internal func cohortAlignmentProvenanceSteps(
        _ result: FullLengthONTMHCCohortAlignmentResult,
        bamViewRecord: FullLengthONTMHCCohortAlignmentCommandRecord
    ) throws -> [ProvenanceStep] {
        var steps: [ProvenanceStep] = []
        for record in result.toolVersionDiscoveryRecords + result.commandRecords + [bamViewRecord] {
            steps.append(try provenanceStep(for: record))
        }
        for transformation in result.transformationRecords {
            steps.append(transformation.provenanceStep())
        }
        guard let publication = result.publicationRecord else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Cohort alignment publication completed without its actual atomic publication record."
            )
        }
        steps.append(ProvenanceStep(
            toolName: publication.toolName,
            toolVersion: publication.toolVersion,
            argv: publication.argv,
            durableReplayArgv: publication.argv,
            reproducibleCommand: publication.argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: [
                "atomicMechanism": .string(publication.atomicMechanism),
                "publicationScope": .string("cohort-alignment-artifacts"),
            ],
            runtimeIdentity: result.runtimeIdentity,
            inputs: result.publicationMappings.map {
                provenanceDescriptor($0.stagedDescriptor, forcedRole: .input)
            },
            outputs: result.publicationMappings.map {
                provenanceDescriptor(
                    $0.finalDescriptor,
                    forcedRole: $0.finalDescriptor.role == .evidenceBAI ? .index : .output
                )
            },
            exitStatus: Int(publication.exitStatus),
            wallTimeSeconds: publication.wallTime,
            stderr: publication.errorMessage,
            startedAt: publication.startedAt,
            completedAt: publication.completedAt
        ))
        return steps
    }

    internal func provenanceStep(
        for record: FullLengthONTMHCCohortAlignmentCommandRecord
    ) throws -> ProvenanceStep {
        guard record.descriptorCaptureErrors.isEmpty else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not rehydrate cohort command provenance: \(record.descriptorCaptureErrors.map(\.message).joined(separator: "; "))."
            )
        }
        var outputDescriptors = record.outputDescriptors
        outputDescriptors.append(record.stdoutLogDescriptor)
        outputDescriptors.append(record.stderrLogDescriptor)
        var seenOutputs = Set<String>()
        let uniqueOutputs = outputDescriptors.filter {
            seenOutputs.insert("\($0.path)\u{0}\($0.role.rawValue)").inserted
        }
        return ProvenanceStep(
            toolName: record.executableURL.lastPathComponent,
            toolVersion: record.toolVersion ?? "unknown",
            argv: record.argv,
            durableReplayArgv: record.argv,
            reproducibleCommand: record.argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: [
                "executionMode": .string("external-command"),
                "capturedArgv": .boolean(true),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: record.inputDescriptors.map {
                provenanceDescriptor($0, forcedRole: .input)
            },
            outputs: uniqueOutputs.map {
                provenanceDescriptor(
                    $0,
                    forcedRole: $0.role == .commandStdoutLog || $0.role == .commandStderrLog ? .log : .output
                )
            },
            exitStatus: Int(record.exitStatus),
            wallTimeSeconds: record.wallTime,
            stderr: record.stderr,
            startedAt: record.startedAt,
            completedAt: record.completedAt
        )
    }

    internal func provenanceDescriptor(
        _ descriptor: FullLengthONTMHCArtifactDescriptor,
        forcedRole: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: descriptor.path,
            checksumSHA256: descriptor.sha256,
            fileSize: descriptor.byteSize,
            format: provenanceFormat(for: descriptor),
            role: forcedRole
        )
    }

    internal func provenanceFormat(
        for descriptor: FullLengthONTMHCArtifactDescriptor
    ) -> FileFormat {
        switch descriptor.role {
        case .referenceFASTA, .sourceClusterFASTA, .snapshotClusterFASTA, .namespacedClusterFASTA:
            return .fasta
        case .evidenceBAM:
            return .bam
        case .commandStdoutLog, .commandStderrLog:
            return descriptor.path.hasSuffix(".sam") ? .sam : .text
        case .evidenceBAI:
            return .unknown
        case .commandInput, .commandOutput:
            let path = descriptor.path.lowercased()
            if path.hasSuffix(".bam") { return .bam }
            if path.hasSuffix(".sam") { return .sam }
            if path.hasSuffix(".fa") || path.hasSuffix(".fasta") { return .fasta }
            return .unknown
        }
    }

    internal func cleanupWarning(
        _ diagnostic: FullLengthONTMHCCleanupDiagnostic
    ) -> FullLengthONTMHCGenotypingCleanupWarning {
        let kind: FullLengthONTMHCGenotypingCleanupWarningKind
        switch diagnostic.kind {
        case .retiredPublicationDirectory:
            kind = .retiredCohortPublicationDirectory
        case .temporaryWorkDirectory:
            kind = .cohortAlignmentTemporaryWorkDirectory
        }
        return FullLengthONTMHCGenotypingCleanupWarning(
            kind: kind,
            path: diagnostic.retainedDirectoryURL.standardizedFileURL.path,
            error: diagnostic.message,
            publishedArtifactsRemainValid: diagnostic.publishedArtifactsRemainValid
        )
    }

    internal func cleanupErrorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

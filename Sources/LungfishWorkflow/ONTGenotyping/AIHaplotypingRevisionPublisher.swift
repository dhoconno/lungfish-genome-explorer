import Foundation
import CryptoKit
import LungfishCore
import LungfishIO

public struct AIHaplotypingRevisionPublishContext {
    public let toolName: String
    public let toolKind: String
    public let argv: [String]
    public let durableReplayArgv: [String]
    public let explicitOptions: [String: ParameterValue]
    public let defaultOptions: [String: ParameterValue]
    public let resolvedOptions: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let startedAt: Date
    public let stderr: String?

    public init(
        toolName: String,
        toolKind: String,
        argv: [String],
        durableReplayArgv: [String]? = nil,
        explicitOptions: [String: ParameterValue] = [:],
        defaultOptions: [String: ParameterValue] = [:],
        resolvedOptions: [String: ParameterValue] = [:],
        runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
        startedAt: Date = Date(),
        stderr: String? = nil
    ) {
        self.toolName = toolName
        self.toolKind = toolKind
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv ?? argv
        self.explicitOptions = explicitOptions
        self.defaultOptions = defaultOptions
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.startedAt = startedAt
        self.stderr = stderr
    }
}

public struct AIHaplotypingRevisionPublishRequest {
    public let bundleURL: URL
    public let result: ONTGenotypeResultBundleData
    public let sidecarURL: URL?
    public let sidecar: GenotypeAnnotationSidecar?
    public let runnerOutput: AIHaplotypingRunnerOutput
    public let context: AIHaplotypingRevisionPublishContext

    public init(
        bundleURL: URL,
        result: ONTGenotypeResultBundleData,
        sidecarURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar? = nil,
        runnerOutput: AIHaplotypingRunnerOutput,
        context: AIHaplotypingRevisionPublishContext
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.result = result
        self.sidecarURL = sidecarURL?.standardizedFileURL
        self.sidecar = sidecar
        self.runnerOutput = runnerOutput
        self.context = context
    }
}

public struct AIHaplotypingRevisionPublishResult {
    public let revision: ONTGenotypeHaplotypeAnalysisRevision
    public let manifest: ONTGenotypeResultBundleManifest
    public let analysis: GenotypeHaplotypeAnalysis
    public let sidecar: GenotypeAnnotationSidecar?
    public let revisionDirectoryURL: URL
    public let provenanceURL: URL
}

public enum AIHaplotypingRevisionPublisherError: Error, LocalizedError, Sendable {
    case noAcceptedValidationReports
    case invalidSlot(String)
    case pendingProvenancePath(String)
    case rollbackFailed(originalError: String, rollbackError: String, orphanDirectory: String)

    public var errorDescription: String? {
        switch self {
        case .noAcceptedValidationReports:
            return "AI haplotyping output cannot be published because it has no accepted validation reports."
        case .invalidSlot(let slot):
            return "AI haplotyping output contains an invalid haplotype slot: \(slot)"
        case .pendingProvenancePath(let path):
            return "AI haplotyping output still points at a non-final provenance path: \(path)"
        case .rollbackFailed(let originalError, let rollbackError, let orphanDirectory):
            return "AI haplotyping publish failed (\(originalError)) and rollback could not remove \(orphanDirectory): \(rollbackError)"
        }
    }
}

public typealias AIHaplotypingProvenanceWriter = (ProvenanceEnvelope, URL) throws -> Void

public struct AIHaplotypingRevisionPublisher {
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let revisionIDProvider: () -> String
    private let provenanceWriter: AIHaplotypingProvenanceWriter

    public init(
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init,
        revisionIDProvider: @escaping () -> String = { "haprev-ai-\(UUID().uuidString)" },
        provenanceWriter: @escaping AIHaplotypingProvenanceWriter = {
            try ProvenanceWriter(signingProvider: nil).write($0, toSidecar: $1)
        }
    ) {
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.revisionIDProvider = revisionIDProvider
        self.provenanceWriter = provenanceWriter
    }

    public func publish(
        _ request: AIHaplotypingRevisionPublishRequest
    ) throws -> AIHaplotypingRevisionPublishResult {
        guard request.runnerOutput.validationReports.contains(where: \.accepted) else {
            throw AIHaplotypingRevisionPublisherError.noAcceptedValidationReports
        }

        let bundleURL = request.bundleURL.standardizedFileURL
        let originalManifest = try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: bundleURL))
        let sidecarSnapshot = try request.sidecarURL.map { url -> (url: URL, data: Data?, existed: Bool) in
            let existed = fileManager.fileExists(atPath: url.path)
            return (url, existed ? try Data(contentsOf: url) : nil, existed)
        }
        let revisionID = revisionIDProvider()
        let revisionDirectory = bundleURL
            .appendingPathComponent("artifacts/ai-haplotyping/revisions", isDirectory: true)
            .appendingPathComponent(revisionID, isDirectory: true)
        let paths = RevisionPaths(bundleURL: bundleURL, revisionDirectory: revisionDirectory)
        let provenancePath = relativePath(from: bundleURL, to: paths.provenanceURL)

        do {
            try fileManager.createDirectory(at: revisionDirectory, withIntermediateDirectories: true)
            _ = try copySpecialistPromptSnapshotIfNeeded(request: request, paths: paths)

            let calls = try remappedCalls(request.runnerOutput.normalizedCalls, provenancePath: provenancePath)
            let analysis = try makeAnalysis(
                revisionID: revisionID,
                generatedAt: isoString(dateProvider()),
                result: request.result,
                output: request.runnerOutput,
                calls: calls
            )
            try writeJSON(analysis, to: paths.analysisURL)
            try writeJSON(request.runnerOutput.registry, to: paths.evidenceURL)
            try writeJSON(request.runnerOutput.validationReports, to: paths.validationURL)
            try writeJSON(calls, to: paths.callsURL)
            try writeJSON(request.runnerOutput.validatedDefinitions, to: paths.definitionsURL)

            let updatedSidecar = try writeSidecarReviewIfNeeded(
                request: request,
                revisionID: revisionID,
                createdAt: analysis.generatedAt ?? isoString(dateProvider()),
                calls: calls,
                paths: paths,
                provenancePath: provenancePath
            )

            let revision = try makeRevision(
                revisionID: revisionID,
                request: request,
                analysisURL: paths.analysisURL,
                analysisPath: relativePath(from: bundleURL, to: paths.analysisURL),
                evidencePath: relativePath(from: bundleURL, to: paths.evidenceURL),
                validationPath: relativePath(from: bundleURL, to: paths.validationURL),
                promptSnapshotPath: specialistPromptSnapshotIfPresent(paths: paths)
                    .map { relativePath(from: bundleURL, to: $0) },
                provenancePath: provenancePath
            )
            let manifest = manifestByAppendingRevision(
                request.result.manifest,
                revision: revision
            )
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

            let envelope = try makeProvenanceEnvelope(
                request: request,
                revisionDirectory: revisionDirectory,
                paths: paths,
                originalManifest: originalManifest,
                sidecarSnapshot: sidecarSnapshot,
                sidecarURL: request.sidecarURL,
                startedAt: request.context.startedAt,
                completedAt: dateProvider()
            )
            try provenanceWriter(envelope, paths.provenanceURL)
            try assertFinalProvenancePaths(
                analysisURL: paths.analysisURL,
                callsURL: paths.callsURL,
                manifest: manifest,
                sidecar: updatedSidecar,
                provenancePath: provenancePath
            )
            return AIHaplotypingRevisionPublishResult(
                revision: revision,
                manifest: manifest,
                analysis: analysis,
                sidecar: updatedSidecar,
                revisionDirectoryURL: revisionDirectory,
                provenanceURL: paths.provenanceURL
            )
        } catch {
            try rollback(
                originalManifest: originalManifest,
                sidecarSnapshot: sidecarSnapshot,
                bundleURL: bundleURL,
                revisionDirectory: revisionDirectory,
                originalError: error
            )
            throw error
        }
    }

    private func makeRevision(
        revisionID: String,
        request: AIHaplotypingRevisionPublishRequest,
        analysisURL: URL,
        analysisPath: String,
        evidencePath: String,
        validationPath: String,
        promptSnapshotPath: String?,
        provenancePath: String
    ) throws -> ONTGenotypeHaplotypeAnalysisRevision {
        let prompt = request.runnerOutput.chunkOutputs.first?.promptMetadata
        let attempt = request.runnerOutput.providerAttempts.first
        return ONTGenotypeHaplotypeAnalysisRevision(
            id: revisionID,
            method: request.runnerOutput.mode == .aiRefinement ? .aiRefinement : .aiDiscovery,
            path: analysisPath,
            predecessorID: request.runnerOutput.mode == .aiRefinement
                ? request.result.manifest.activeHaplotypeAnalysisRevisionID
                    ?? request.result.haplotypeAnalysis?.analysisRevisionID
                : nil,
            predecessorPath: request.runnerOutput.mode == .aiRefinement
                ? request.result.manifest.haplotypeAnalysisPath
                : nil,
            createdAt: isoString(dateProvider()),
            reviewState: .needsReview,
            sha256: try ProvenanceFileHasher.sha256(of: analysisURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: analysisURL)),
            provenancePath: provenancePath,
            provider: attempt?.provider ?? request.runnerOutput.validationReports.compactMap(\.run?.provider).first,
            model: attempt?.model ?? request.runnerOutput.validationReports.compactMap(\.run?.model).first,
            promptTemplateID: prompt?.promptTemplateID,
            promptTemplateVersion: prompt?.promptTemplateVersion,
            promptHash: prompt?.promptHash,
            promptSnapshotPath: promptSnapshotPath,
            evidenceSnapshotPath: evidencePath,
            validationReportPath: validationPath
        )
    }

    private func manifestByAppendingRevision(
        _ manifest: ONTGenotypeResultBundleManifest,
        revision: ONTGenotypeHaplotypeAnalysisRevision
    ) -> ONTGenotypeResultBundleManifest {
        ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            workflowKind: manifest.workflowKind,
            workflowMode: .haplotyped,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: manifest.deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: revision.path,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            presetID: manifest.presetID,
            presetVersion: manifest.presetVersion,
            createdAt: manifest.createdAt,
            activeHaplotypeAnalysisRevisionID: revision.id,
            haplotypeAnalysisRevisions: (manifest.haplotypeAnalysisRevisions ?? []) + [revision],
            mhcCandidateArtifacts: manifest.mhcCandidateArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore,
            alignmentArtifacts: manifest.alignmentArtifacts,
            provisionalExon2Artifacts: manifest.provisionalExon2Artifacts
        )
    }

    private func remappedCalls(
        _ calls: [AIHaplotypingValidatedCall],
        provenancePath: String
    ) throws -> [AIHaplotypingValidatedCall] {
        try calls.map { call in
            let metadata = metadata(call.aiMetadata, provenancePath: provenancePath)
            guard metadata.provenancePath == provenancePath,
                  !metadata.provenancePath.contains("provenance.pending") else {
                throw AIHaplotypingRevisionPublisherError.pendingProvenancePath(metadata.provenancePath)
            }
            return AIHaplotypingValidatedCall(
                patchOpID: call.patchOpID,
                sample: call.sample,
                locus: call.locus,
                slot: call.slot,
                status: call.status,
                primaryHaplotypeLabel: call.primaryHaplotypeLabel,
                proposedHaplotypeLabel: call.proposedHaplotypeLabel,
                aiMetadata: metadata,
                supportEvidenceRefs: call.supportEvidenceRefs,
                counterevidenceRefs: call.counterevidenceRefs
            )
        }
    }

    private func metadata(
        _ metadata: GenotypeHaplotypeAICallMetadata,
        provenancePath: String
    ) -> GenotypeHaplotypeAICallMetadata {
        GenotypeHaplotypeAICallMetadata(
            patchOpID: metadata.patchOpID,
            source: metadata.source,
            sourceState: metadata.sourceState,
            reviewState: metadata.reviewState,
            callState: metadata.callState,
            confidenceTier: metadata.confidenceTier,
            proposedHaplotypeLabel: metadata.proposedHaplotypeLabel,
            supportEvidenceRefs: metadata.supportEvidenceRefs,
            counterevidenceRefs: metadata.counterevidenceRefs,
            alternates: metadata.alternates,
            rationaleCode: metadata.rationaleCode,
            rationale: metadata.rationale,
            provenancePath: provenancePath
        )
    }

    private func makeAnalysis(
        revisionID: String,
        generatedAt: String,
        result: ONTGenotypeResultBundleData,
        output: AIHaplotypingRunnerOutput,
        calls: [AIHaplotypingValidatedCall]
    ) throws -> GenotypeHaplotypeAnalysis {
        let predecessor = output.mode == .aiRefinement ? result.haplotypeAnalysis : nil
        var callsBySample: [String: [String: GenotypeHaplotypeLocusCall]] = [:]
        var sampleOrder: [String] = []
        var lociBySampleOrder: [String: [String]] = [:]

        if let predecessor {
            for sample in predecessor.samples {
                appendUnique(sample.sample, to: &sampleOrder)
                for call in sample.calls {
                    callsBySample[sample.sample, default: [:]][call.locus] = call
                    appendUnique(call.locus, to: &lociBySampleOrder[sample.sample, default: []])
                }
            }
        }

        for sample in output.registry.samples.map(\.sample) {
            appendUnique(sample, to: &sampleOrder)
            for locus in output.registry.loci.map(\.locus)
                where GenotypeHaplotypeLocusResolver.isReportableHaplotypeLocus(locus) {
                appendUnique(locus, to: &lociBySampleOrder[sample, default: []])
                if callsBySample[sample]?[locus] == nil {
                    callsBySample[sample, default: [:]][locus] = placeholderCall(
                        sample: sample,
                        locus: locus,
                        registry: output.registry
                    )
                }
            }
        }

        let callsByTarget = Dictionary(grouping: calls) {
            SampleLocus(sample: $0.sample, locus: $0.locus)
        }
        for (target, targetCalls) in callsByTarget {
            guard GenotypeHaplotypeLocusResolver.isReportableHaplotypeLocus(target.locus) else {
                continue
            }
            let existing = callsBySample[target.sample]?[target.locus]
                ?? placeholderCall(sample: target.sample, locus: target.locus, registry: output.registry)
            callsBySample[target.sample, default: [:]][target.locus] = try applying(
                targetCalls,
                to: existing
            )
            appendUnique(target.sample, to: &sampleOrder)
            appendUnique(target.locus, to: &lociBySampleOrder[target.sample, default: []])
        }

        let samples = sampleOrder.map { sample in
            GenotypeHaplotypeSampleAnalysis(
                sample: sample,
                calls: (lociBySampleOrder[sample] ?? [])
                    .compactMap { callsBySample[sample]?[$0] }
            )
        }

        return GenotypeHaplotypeAnalysis(
            schemaVersion: 2,
            assayID: predecessor?.assayID ?? result.manifest.haplotypeAssayID ?? "ai-haplotyping",
            definitionSetID: "ai-provisional:\(revisionID)",
            definitionSetName: "AI provisional haplotype calls",
            speciesName: predecessor?.speciesName ?? "Unknown",
            generatedAt: generatedAt,
            analysisRevisionID: revisionID,
            source: .ai,
            samples: samples
        )
    }

    private func applying(
        _ calls: [AIHaplotypingValidatedCall],
        to existing: GenotypeHaplotypeLocusCall
    ) throws -> GenotypeHaplotypeLocusCall {
        var haplotype1 = existing.haplotype1
        var haplotype2 = existing.haplotype2
        var statuses: [GenotypeHaplotypeCallStatus] = []
        var slotMetadata: [GenotypeHaplotypeAISlotMetadata] = []
        for call in calls.sorted(by: slotSort) {
            guard let slot = HaplotypeSlot(rawValue: call.slot) else {
                throw AIHaplotypingRevisionPublisherError.invalidSlot(call.slot)
            }
            if call.aiMetadata.callState != .retainCurrent {
                let value = call.primaryHaplotypeLabel ?? "-"
                switch slot {
                case .h1: haplotype1 = value
                case .h2: haplotype2 = value
                }
            }
            statuses.append(call.status)
            slotMetadata.append(GenotypeHaplotypeAISlotMetadata(slot: slot, metadata: call.aiMetadata))
        }
        let status = aggregateStatus(statuses, fallback: existing.status)
        let notes = existing.notes.isEmpty
            ? "AI review required"
            : "\(existing.notes) AI review required"
        return GenotypeHaplotypeLocusCall(
            locus: existing.locus,
            sourceLocus: existing.sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: status,
            matchedHaplotypes: existing.matchedHaplotypes,
            observedGenotypeCount: existing.observedGenotypeCount,
            observedGenotypes: existing.observedGenotypes,
            notes: notes,
            aiMetadata: slotMetadata.first?.metadata,
            aiSlotMetadata: slotMetadata
        )
    }

    private func aggregateStatus(
        _ statuses: [GenotypeHaplotypeCallStatus],
        fallback: GenotypeHaplotypeCallStatus
    ) -> GenotypeHaplotypeCallStatus {
        guard !statuses.isEmpty else { return fallback }
        if statuses.contains(.specialCase) { return .specialCase }
        if statuses.allSatisfy({ $0 == .notAssayed }) { return .notAssayed }
        if statuses.contains(.noHaplotype) { return .noHaplotype }
        if statuses.allSatisfy({ $0 == .called }) { return .called }
        return fallback
    }

    private func placeholderCall(
        sample: String,
        locus: String,
        registry: AIHaplotypingEvidenceRegistry
    ) -> GenotypeHaplotypeLocusCall {
        let observations = observationsFor(sample: sample, locus: locus, registry: registry)
        return GenotypeHaplotypeLocusCall(
            locus: locus,
            sourceLocus: locus,
            haplotype1: "-",
            haplotype2: "-",
            status: observations.isEmpty ? .notAssayed : .noHaplotype,
            matchedHaplotypes: [],
            observedGenotypeCount: observations.count,
            observedGenotypes: observations.map(\.genotype)
        )
    }

    private func observationsFor(
        sample: String,
        locus: String,
        registry: AIHaplotypingEvidenceRegistry
    ) -> [ObservationEvidence] {
        let samplesByID = Dictionary(uniqueKeysWithValues: registry.samples.map { ($0.id, $0.sample) })
        let lociByID = Dictionary(uniqueKeysWithValues: registry.loci.map { ($0.id, $0.locus) })
        return registry.observations.filter {
            samplesByID[$0.sampleID] == sample && lociByID[$0.locusID] == locus
        }
    }

    private func writeSidecarReviewIfNeeded(
        request: AIHaplotypingRevisionPublishRequest,
        revisionID: String,
        createdAt: String,
        calls: [AIHaplotypingValidatedCall],
        paths: RevisionPaths,
        provenancePath: String
    ) throws -> GenotypeAnnotationSidecar? {
        guard let sidecarURL = request.sidecarURL, var sidecar = request.sidecar else {
            return nil
        }
        let callReviews = try calls.map { call -> GenotypeAnnotationSidecar.AIHaplotypeCallReview in
            guard let slot = HaplotypeSlot(rawValue: call.slot) else {
                throw AIHaplotypingRevisionPublisherError.invalidSlot(call.slot)
            }
            return GenotypeAnnotationSidecar.AIHaplotypeCallReview(
                sample: call.sample,
                locus: call.locus,
                slot: slot,
                callState: call.aiMetadata.callState,
                confidenceTier: call.aiMetadata.confidenceTier,
                supportEvidenceRefs: call.supportEvidenceRefs,
                counterevidenceRefs: call.counterevidenceRefs,
                reviewerDecision: .needsReview,
                reviewer: nil,
                reviewedAt: nil,
                provenancePath: provenancePath
            )
        }
        let review = GenotypeAnnotationSidecar.AIHaplotypeReviewEntry(
            id: "airev-\(revisionID)",
            analysisRevisionID: revisionID,
            createdAt: createdAt,
            source: .ai,
            reviewState: .needsReview,
            callReviews: callReviews,
            evidenceSnapshotPath: relativePath(from: request.bundleURL, to: paths.evidenceURL),
            callsPath: relativePath(from: request.bundleURL, to: paths.callsURL),
            validationReportPath: relativePath(from: request.bundleURL, to: paths.validationURL),
            provenancePath: provenancePath
        )
        sidecar.aiHaplotypeReviews.append(review)
        sidecar.activeAIHaplotypeReviewID = review.id
        sidecar.lastEditedAt = createdAt
        sidecar.lastEditor = request.context.toolName
        try sidecar.encoded().write(to: sidecarURL, options: .atomic)
        return sidecar
    }

    private func copySpecialistPromptSnapshotIfNeeded(
        request: AIHaplotypingRevisionPublishRequest,
        paths: RevisionPaths
    ) throws -> URL? {
        guard let sourceURL = try specialistPromptSourceURL(for: request.runnerOutput) else {
            return nil
        }
        try fileManager.createDirectory(
            at: paths.promptSnapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: paths.promptSnapshotURL.path) {
            try fileManager.removeItem(at: paths.promptSnapshotURL)
        }
        try fileManager.copyItem(at: sourceURL, to: paths.promptSnapshotURL)
        return paths.promptSnapshotURL
    }

    private func specialistPromptSourceURL(
        for output: AIHaplotypingRunnerOutput
    ) throws -> URL? {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let specialistPromptIDs: Set<String> = [
            preset.aiDiscoveryPromptTemplateID,
            preset.aiRefinementPromptTemplateID,
        ]
        let templateIDs = output.chunkOutputs.map(\.promptMetadata.promptTemplateID)
            + output.validationReports.compactMap(\.run?.promptTemplateID)
        guard templateIDs.contains(where: specialistPromptIDs.contains) else {
            return nil
        }
        return try preset.bundledSpecialistPromptURL()
    }

    private func specialistPromptSnapshotIfPresent(paths: RevisionPaths) -> URL? {
        fileManager.fileExists(atPath: paths.promptSnapshotURL.path) ? paths.promptSnapshotURL : nil
    }

    private func specialistPromptSnapshotStep(
        request: AIHaplotypingRevisionPublishRequest,
        paths: RevisionPaths,
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceStep? {
        guard let sourceURL = try specialistPromptSourceURL(for: request.runnerOutput),
              let outputURL = specialistPromptSnapshotIfPresent(paths: paths) else {
            return nil
        }
        let source = try ProvenanceFileDescriptor.file(url: sourceURL, format: .text, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: outputURL, format: .text, role: .output)
        return ProvenanceStep(
            toolName: "MCM specialist prompt snapshot",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: ["copy", source.path, output.path],
            inputs: [source],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 0,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func makeProvenanceEnvelope(
        request: AIHaplotypingRevisionPublishRequest,
        revisionDirectory: URL,
        paths: RevisionPaths,
        originalManifest: Data,
        sidecarSnapshot: (url: URL, data: Data?, existed: Bool)?,
        sidecarURL: URL?,
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        var inputs = [
            provenanceDescriptor(
                url: ONTGenotypeResultBundle.manifestURL(in: request.bundleURL),
                data: originalManifest,
                format: .json,
                role: .input
            )
        ]
        if let sidecarSnapshot, sidecarSnapshot.existed, let data = sidecarSnapshot.data {
            inputs.append(provenanceDescriptor(
                url: sidecarSnapshot.url,
                data: data,
                format: .json,
                role: .input
            ))
        }
        inputs += try [
            request.result.artifacts.longSummaryCSVURL,
            request.result.artifacts.sampleSummaryCSVURL,
            request.result.artifacts.statsJSONURL,
            request.result.artifacts.haplotypeAnalysisURL,
        ].compactMap { $0 }.filter { fileManager.fileExists(atPath: $0.path) }
            .map { try ProvenanceFileDescriptor.file(url: $0, format: format(for: $0), role: .input) }
        if let specialistPromptSourceURL = try specialistPromptSourceURL(for: request.runnerOutput) {
            inputs.append(try ProvenanceFileDescriptor.file(
                url: specialistPromptSourceURL,
                format: .text,
                role: .input
            ))
        }
        let outputs = try [
            paths.analysisURL,
            paths.evidenceURL,
            paths.validationURL,
            paths.callsURL,
            paths.definitionsURL,
            specialistPromptSnapshotIfPresent(paths: paths),
            ONTGenotypeResultBundle.manifestURL(in: request.bundleURL),
            sidecarURL,
        ].compactMap { $0 }.filter { fileManager.fileExists(atPath: $0.path) }
            .map { try ProvenanceFileDescriptor.file(url: $0, format: format(for: $0), role: .output) }
        let provenanceOptions = provenanceOptions(
            request: request,
            revisionDirectory: revisionDirectory,
            paths: paths
        )
        let promptStep = try specialistPromptSnapshotStep(
            request: request,
            paths: paths,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let step = ProvenanceStep(
            toolName: "\(request.context.toolName) publish AI haplotypes",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: request.context.argv,
            durableReplayArgv: request.context.durableReplayArgv,
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: sanitizedStderr(request.context.stderr),
            startedAt: startedAt,
            completedAt: completedAt
        )
        var builder = ProvenanceRunBuilder(
            workflowName: "AI Haplotype Revision",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: request.context.toolName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(request.context.argv)
        .durableReplayArgv(request.context.durableReplayArgv)
        .options(
            explicit: provenanceOptions.explicit,
            defaults: provenanceOptions.defaults,
            resolved: provenanceOptions.resolved
        )
        .runtime(request.context.runtimeIdentity)
        if let promptStep {
            builder = builder.step(promptStep)
        }
        return try builder
        .step(step)
        .complete(
            exitStatus: 0,
            stderr: sanitizedStderr(request.context.stderr),
            startedAt: startedAt,
            endedAt: completedAt
        )
        .includingOutputDescriptors(outputs)
    }

    private func provenanceDescriptor(
        url: URL,
        data: Data,
        format: FileFormat?,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ProvenanceFileDescriptor(
            path: url.standardizedFileURL.path,
            checksumSHA256: digest,
            fileSize: UInt64(data.count),
            format: format,
            role: role
        )
    }

    private func provenanceOptions(
        request: AIHaplotypingRevisionPublishRequest,
        revisionDirectory: URL,
        paths: RevisionPaths
    ) -> (
        explicit: [String: ParameterValue],
        defaults: [String: ParameterValue],
        resolved: [String: ParameterValue]
    ) {
        let firstRun = request.runnerOutput.validationReports.compactMap(\.run).first
        let firstAttempt = request.runnerOutput.providerAttempts.first
        var explicit = request.context.explicitOptions
        explicit["bundle"] = .file(request.bundleURL)
        explicit["mode"] = .string(request.runnerOutput.mode.rawValue)
        if let credentialSource = firstAttempt?.credentialSource {
            explicit["credentialSource"] = .string(sanitizedMetadataString(credentialSource))
        }
        var resolved = request.context.resolvedOptions
        resolved["revisionDirectory"] = .file(revisionDirectory)
        resolved["analysisPath"] = .file(paths.analysisURL)
        resolved["provider"] = .string(sanitizedMetadataString(firstRun?.provider ?? firstAttempt?.provider ?? "unknown"))
        resolved["model"] = .string(sanitizedMetadataString(firstRun?.model ?? firstAttempt?.model ?? "unknown"))
        resolved["promptTemplateID"] = .string(firstRun?.promptTemplateID ?? "unknown")
        resolved["promptTemplateVersion"] = .string(firstRun?.promptTemplateVersion ?? "unknown")
        resolved["promptHash"] = .string(firstRun?.promptHash ?? "unknown")
        if let promptURL = specialistPromptSnapshotIfPresent(paths: paths) {
            resolved["specialistPromptPath"] = .string(relativePath(from: request.bundleURL, to: promptURL))
            resolved["specialistPromptSHA256"] = .string((try? ProvenanceFileHasher.sha256(of: promptURL)) ?? "unknown")
        } else {
            resolved["specialistPromptPath"] = .null
            resolved["specialistPromptSHA256"] = .null
        }
        if let promptMetadata = request.runnerOutput.chunkOutputs.first?.promptMetadata {
            if let knowledgePackID = promptMetadata.knowledgePackID {
                resolved["knowledgePackID"] = .string(knowledgePackID)
            }
            if let knowledgePackVersion = promptMetadata.knowledgePackVersion {
                resolved["knowledgePackVersion"] = .string(knowledgePackVersion)
            }
            if let knowledgePackDigest = promptMetadata.knowledgePackDigest {
                resolved["knowledgePackDigest"] = .string(knowledgePackDigest)
            }
        }
        resolved["registryDigest"] = .string(request.runnerOutput.registry.digest)
        resolved["inputSnapshotDigest"] = .string(request.runnerOutput.registry.inputSnapshotDigest)
        resolved["generationParameters"] = .dictionary(
            (firstRun?.generationParameters ?? [:]).mapValues { .string($0) }
        )
        resolved["providerAttempts"] = .array(request.runnerOutput.providerAttempts.map { attempt in
            .dictionary([
                "attemptIndex": .integer(attempt.attemptIndex),
                "fallbackIndex": .integer(attempt.fallbackIndex),
                "provider": .string(sanitizedMetadataString(attempt.provider)),
                "model": .string(sanitizedMetadataString(attempt.model)),
                "endpoint": .string(sanitizedMetadataString(attempt.endpoint)),
                "credentialSource": .string(sanitizedMetadataString(attempt.credentialSource ?? "")),
                "statusCode": attempt.statusCode.map(ParameterValue.integer) ?? .null,
                "stopReason": .string(sanitizedMetadataString(attempt.stopReason ?? "")),
                "inputTokens": attempt.inputTokens.map(ParameterValue.integer) ?? .null,
                "outputTokens": attempt.outputTokens.map(ParameterValue.integer) ?? .null,
                "sanitizedErrorCategory": .string(sanitizedMetadataString(attempt.sanitizedErrorCategory ?? "")),
            ])
        })
        return (explicit, request.context.defaultOptions, resolved)
    }

    private func assertFinalProvenancePaths(
        analysisURL: URL,
        callsURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        sidecar: GenotypeAnnotationSidecar?,
        provenancePath: String
    ) throws {
        guard !provenancePath.contains("provenance.pending") else {
            throw AIHaplotypingRevisionPublisherError.pendingProvenancePath(provenancePath)
        }
        let analysis = try JSONDecoder().decode(GenotypeHaplotypeAnalysis.self, from: Data(contentsOf: analysisURL))
        for sample in analysis.samples {
            for call in sample.calls {
                for metadata in call.aiSlotMetadata where metadata.metadata.provenancePath != provenancePath {
                    throw AIHaplotypingRevisionPublisherError.pendingProvenancePath(metadata.metadata.provenancePath)
                }
            }
        }
        let calls = try JSONDecoder().decode([AIHaplotypingValidatedCall].self, from: Data(contentsOf: callsURL))
        for call in calls where call.aiMetadata.provenancePath != provenancePath {
            throw AIHaplotypingRevisionPublisherError.pendingProvenancePath(call.aiMetadata.provenancePath)
        }
        for revision in manifest.haplotypeAnalysisRevisions ?? []
            where revision.provenancePath.contains("provenance.pending") {
            throw AIHaplotypingRevisionPublisherError.pendingProvenancePath(revision.provenancePath)
        }
        for review in sidecar?.aiHaplotypeReviews ?? [] where review.provenancePath.contains("provenance.pending") {
            throw AIHaplotypingRevisionPublisherError.pendingProvenancePath(review.provenancePath)
        }
    }

    private func rollback(
        originalManifest: Data,
        sidecarSnapshot: (url: URL, data: Data?, existed: Bool)?,
        bundleURL: URL,
        revisionDirectory: URL,
        originalError: Error
    ) throws {
        do {
            try originalManifest.write(to: ONTGenotypeResultBundle.manifestURL(in: bundleURL), options: .atomic)
            if let sidecarSnapshot {
                if sidecarSnapshot.existed, let data = sidecarSnapshot.data {
                    try data.write(to: sidecarSnapshot.url, options: .atomic)
                } else if fileManager.fileExists(atPath: sidecarSnapshot.url.path) {
                    try fileManager.removeItem(at: sidecarSnapshot.url)
                }
            }
            if fileManager.fileExists(atPath: revisionDirectory.path) {
                try fileManager.removeItem(at: revisionDirectory)
            }
        } catch {
            throw AIHaplotypingRevisionPublisherError.rollbackFailed(
                originalError: String(describing: originalError),
                rollbackError: String(describing: error),
                orphanDirectory: revisionDirectory.path
            )
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func appendUnique<T: Equatable>(_ value: T, to values: inout [T]) {
        if !values.contains(value) {
            values.append(value)
        }
    }

    private func slotSort(_ lhs: AIHaplotypingValidatedCall, _ rhs: AIHaplotypingValidatedCall) -> Bool {
        lhs.slot < rhs.slot
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return filePath
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func format(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "json": return .json
        case "md", "markdown": return .text
        default: return .unknown
        }
    }

    private func sanitizedStderr(_ stderr: String?) -> String? {
        guard let stderr else { return nil }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "[redacted]"
    }

    private func sanitizedMetadataString(_ value: String) -> String {
        let filtered = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "-"
                || scalar == "_"
                || scalar == ":"
                || scalar == "/" {
                return Character(scalar)
            }
            return "_"
        }
        return String(filtered).prefix(160).description
    }
}

private struct RevisionPaths {
    let analysisURL: URL
    let evidenceURL: URL
    let validationURL: URL
    let callsURL: URL
    let definitionsURL: URL
    let promptSnapshotURL: URL
    let provenanceURL: URL

    init(bundleURL: URL, revisionDirectory: URL) {
        self.analysisURL = revisionDirectory.appendingPathComponent("haplotype-analysis.json")
        self.evidenceURL = revisionDirectory.appendingPathComponent("evidence-registry.json")
        self.validationURL = revisionDirectory.appendingPathComponent("validation-report.json")
        self.callsURL = revisionDirectory.appendingPathComponent("calls.json")
        self.definitionsURL = revisionDirectory.appendingPathComponent("discovered-definitions.json")
        self.promptSnapshotURL = revisionDirectory.appendingPathComponent("mcm-mhc-haplotyping-specialist-prompt.md")
        self.provenanceURL = revisionDirectory.appendingPathComponent("ai-haplotyping.lungfish-provenance.json")
    }
}

private struct SampleLocus: Hashable {
    let sample: String
    let locus: String
}

private extension ProvenanceEnvelope {
    func includingOutputDescriptors(_ descriptors: [ProvenanceFileDescriptor]) -> ProvenanceEnvelope {
        let mergedOutputs = descriptors.reduce(outputs) { partial, descriptor in
            partial.contains(where: { $0.path == descriptor.path && $0.role == descriptor.role })
                ? partial
                : partial + [descriptor]
        }
        let mergedFiles = descriptors.reduce(files) { partial, descriptor in
            partial.contains(where: { $0.path == descriptor.path && $0.role == descriptor.role })
                ? partial
                : partial + [descriptor]
        }
        return ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            tool: tool,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: mergedFiles,
            output: output,
            outputs: mergedOutputs,
            steps: steps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: signatures,
            legacyWorkflowRun: legacyRun
        )
    }
}

import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct FullLengthONTMHCCandidateSequenceObservation: Sendable, Equatable {
    public let sampleID: String
    public let readGroupID: String
    public let sourceClusterID: String
    public let clusterReadCount: Int
    public let sequence: String
    public let genotypingEvidence: [ONTMHCEvidenceLocator]

    public init(
        sampleID: String,
        readGroupID: String,
        sourceClusterID: String,
        clusterReadCount: Int,
        sequence: String,
        genotypingEvidence: [ONTMHCEvidenceLocator]
    ) {
        self.sampleID = sampleID
        self.readGroupID = readGroupID
        self.sourceClusterID = sourceClusterID
        self.clusterReadCount = clusterReadCount
        self.sequence = sequence
        self.genotypingEvidence = genotypingEvidence
    }
}

public struct FullLengthONTMHCCandidateArtifactWriteRequest: Sendable, Equatable {
    public let observations: [FullLengthONTMHCCandidateSequenceObservation]
    public let referenceAlleleFASTAURL: URL
    public let referenceRecords: [MHCReferenceRecord]
    public let genotypingEvidence: ONTMHCBAMArtifactPair?
    public let threads: Int
    public let outputDirectoryURL: URL
    public let workDirectoryURL: URL
    public let thresholds: ONTMHCCandidateThresholds

    public init(
        observations: [FullLengthONTMHCCandidateSequenceObservation],
        referenceAlleleFASTAURL: URL,
        referenceRecords: [MHCReferenceRecord],
        genotypingEvidence: ONTMHCBAMArtifactPair?,
        threads: Int,
        outputDirectoryURL: URL,
        workDirectoryURL: URL,
        thresholds: ONTMHCCandidateThresholds = .defaults
    ) {
        self.observations = observations
        self.referenceAlleleFASTAURL = referenceAlleleFASTAURL.standardizedFileURL
        self.referenceRecords = referenceRecords
        self.genotypingEvidence = genotypingEvidence
        self.threads = max(1, threads)
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.workDirectoryURL = workDirectoryURL.standardizedFileURL
        self.thresholds = thresholds
    }
}

public struct FullLengthONTMHCCandidateArtifactResult: Sendable, Equatable {
    public let stableUnmatchedFASTAURL: URL
    public let reciprocalBAMURL: URL
    public let reciprocalBAIURL: URL
    public let candidateFASTAURL: URL
    public let candidateJSONURL: URL
    public let unnameableFASTAURL: URL
    public let unnameableJSONURL: URL
    public let manifest: ONTMHCCandidateArtifactManifest
    public let classifiedClusters: [FullLengthONTMHCCandidateCluster]
    public let classifications: [FullLengthONTMHCCandidateClassificationResult]
    public let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let toolVersions: [FullLengthONTMHCToolVersionRecord]
    public let toolVersionDiscoveryRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let transformationRecords: [FullLengthONTMHCInProcessTransformationRecord]
    public let runtimeIdentity: ProvenanceRuntimeIdentity

    public var allArtifactReferences: [ONTMHCArtifactReference] {
        [
            manifest.reciprocalEvidence?.bam,
            manifest.reciprocalEvidence?.bai,
            manifest.candidateJSON,
            manifest.candidateFASTA,
            manifest.unnameableJSON,
            manifest.unnameableFASTA,
        ].compactMap { $0 }
    }
}

public struct FullLengthONTMHCCandidateArtifactWriterError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

public struct FullLengthONTMHCCandidateArtifactWriter: @unchecked Sendable {
    private let executableDirectoryURL: URL?
    private let minimap2ExecutableURL: URL?
    private let samtoolsExecutableURL: URL?
    private let fileManager: FileManager

    public init(executableDirectoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.executableDirectoryURL = executableDirectoryURL?.standardizedFileURL
        minimap2ExecutableURL = nil
        samtoolsExecutableURL = nil
        self.fileManager = fileManager
    }

    public init(
        minimap2ExecutableURL: URL,
        samtoolsExecutableURL: URL,
        fileManager: FileManager = .default
    ) {
        executableDirectoryURL = nil
        self.minimap2ExecutableURL = minimap2ExecutableURL.standardizedFileURL
        self.samtoolsExecutableURL = samtoolsExecutableURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func stableClusterID(for sequence: String) -> String {
        let normalized = normalizedSequence(sequence)
        var bytes = Array(SHA256.hash(data: Data(normalized.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    public func write(
        _ request: FullLengthONTMHCCandidateArtifactWriteRequest
    ) async throws -> FullLengthONTMHCCandidateArtifactResult {
        try Task.checkCancellation()
        let safety = FullLengthONTMHCAlignmentSafety(fileManager: fileManager)
        try safety.requireRegularFileNoFollow(request.referenceAlleleFASTAURL, role: "reference allele FASTA")
        try fileManager.createDirectory(at: request.outputDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: request.workDirectoryURL, withIntermediateDirectories: true)
        let pathContext = try safety.prepareDirectories(
            outputDirectoryURL: request.outputDirectoryURL,
            workDirectoryURL: request.workDirectoryURL
        )

        let generationURL = request.workDirectoryURL.appendingPathComponent(
            "full-length-ont-mhc-candidates-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: generationURL, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: generationURL) }
        let logsURL = generationURL.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: false)
        let stagedRootURL = generationURL.appendingPathComponent("publication", isDirectory: true)
        let stagedAlignmentsURL = stagedRootURL.appendingPathComponent("artifacts/alignments", isDirectory: true)
        try fileManager.createDirectory(at: stagedAlignmentsURL, withIntermediateDirectories: true)
        try copyExistingAlignmentArtifacts(
            from: request.outputDirectoryURL.appendingPathComponent("artifacts/alignments", isDirectory: true),
            to: stagedAlignmentsURL
        )

        var transformations: [FullLengthONTMHCInProcessTransformationRecord] = []
        let referenceDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: request.referenceAlleleFASTAURL,
            role: .referenceFASTA,
            phase: .input
        )
        let referenceImportStartedAt = Date()
        let referenceImportCompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:import-mhc-reference-catalog",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "import-mhc-reference-catalog",
                "--record-count", String(request.referenceRecords.count),
                request.referenceAlleleFASTAURL.path,
            ],
            resolvedOptions: [
                "recordCount": String(request.referenceRecords.count),
                "moleculeClassSource": "reference-metadata-with-length-fallback",
            ],
            inputs: [referenceDescriptor],
            outputs: [],
            exitStatus: 0,
            startedAt: referenceImportStartedAt,
            completedAt: referenceImportCompletedAt,
            wallTime: referenceImportCompletedAt.timeIntervalSince(referenceImportStartedAt)
        ))
        let stagedStableFASTAURL = stagedRootURL.appendingPathComponent("deduplicated_unmatched_clusters.fasta")
        let stableFASTAStartedAt = Date()
        let grouped = try groupedClusters(request.observations)
        try writeFASTA(grouped.map { ($0.id, $0.sequence) }, to: stagedStableFASTAURL)
        let stagedStableDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: stagedStableFASTAURL,
            role: .sourceClusterFASTA,
            phase: .staging
        )
        let stableFASTACompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:construct-stable-unmatched-cluster-fasta",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "construct-stable-unmatched-cluster-fasta",
                "--stable-id", "sha256-uuid-v5-compatible",
                "--line-width", "80",
                stagedStableFASTAURL.path,
            ],
            resolvedOptions: [
                "stableID": "first-128-bits-SHA256-with-UUID-version-and-variant-bits",
                "sequenceNormalization": "remove-whitespace-and-uppercase",
                "sequenceGrouping": "exact-normalized-sequence",
                "lineWidth": "80",
            ],
            inputs: [],
            outputs: [stagedStableDescriptor],
            exitStatus: 0,
            startedAt: stableFASTAStartedAt,
            completedAt: stableFASTACompletedAt,
            wallTime: stableFASTACompletedAt.timeIntervalSince(stableFASTAStartedAt)
        ))

        let minimap2URL = try executable(named: "minimap2")
        let samtoolsURL = try executable(named: "samtools")
        let minimapVersion = try await discoverVersion(
            toolName: "minimap2", executableURL: minimap2URL,
            generationURL: generationURL, logsURL: logsURL
        )
        let samtoolsVersion = try await discoverVersion(
            toolName: "samtools", executableURL: samtoolsURL,
            generationURL: generationURL, logsURL: logsURL
        )
        let toolVersions = [minimapVersion, samtoolsVersion]
        var commands: [FullLengthONTMHCCohortAlignmentCommandRecord] = []
        let reciprocalSAMURL = generationURL.appendingPathComponent("reciprocal.sam")
        let reciprocalUnsortedBAMURL = generationURL.appendingPathComponent("reciprocal.unsorted.bam")
        let stagedBAMURL = stagedAlignmentsURL.appendingPathComponent("unmatched-to-reference.bam")
        let stagedBAIURL = stagedAlignmentsURL.appendingPathComponent("unmatched-to-reference.bam.bai")

        try await run(
            minimap2URL,
            arguments: [
                "-a", "--eqx", "--cs=long", "-x", "asm20", "-t", String(request.threads),
                "-N", "100", "--secondary=yes", request.referenceAlleleFASTAURL.path,
                stagedStableFASTAURL.path,
            ],
            inputs: [request.referenceAlleleFASTAURL, stagedStableFASTAURL],
            outputs: [reciprocalSAMURL],
            stdoutURL: reciprocalSAMURL,
            toolVersion: minimapVersion.version,
            generationURL: generationURL,
            logsURL: logsURL,
            records: &commands
        )
        try await run(
            samtoolsURL,
            arguments: ["view", "-b", "-o", reciprocalUnsortedBAMURL.path, reciprocalSAMURL.path],
            inputs: [reciprocalSAMURL], outputs: [reciprocalUnsortedBAMURL],
            toolVersion: samtoolsVersion.version,
            generationURL: generationURL, logsURL: logsURL, records: &commands
        )
        try await run(
            samtoolsURL,
            arguments: ["sort", "-o", stagedBAMURL.path, reciprocalUnsortedBAMURL.path],
            inputs: [reciprocalUnsortedBAMURL], outputs: [stagedBAMURL],
            toolVersion: samtoolsVersion.version,
            generationURL: generationURL, logsURL: logsURL, records: &commands
        )
        try await run(
            samtoolsURL,
            arguments: ["index", stagedBAMURL.path, stagedBAIURL.path],
            inputs: [stagedBAMURL], outputs: [stagedBAIURL],
            toolVersion: samtoolsVersion.version,
            generationURL: generationURL, logsURL: logsURL, records: &commands
        )
        try await run(
            samtoolsURL,
            arguments: ["quickcheck", stagedBAMURL.path],
            inputs: [stagedBAMURL, stagedBAIURL], outputs: [],
            toolVersion: samtoolsVersion.version,
            generationURL: generationURL, logsURL: logsURL, records: &commands
        )
        try await run(
            samtoolsURL,
            arguments: ["idxstats", stagedBAMURL.path],
            inputs: [stagedBAMURL, stagedBAIURL], outputs: [],
            toolVersion: samtoolsVersion.version,
            generationURL: generationURL, logsURL: logsURL, records: &commands
        )
        let reciprocalViewURL = generationURL.appendingPathComponent("reciprocal-view.sam")
        try await run(
            samtoolsURL,
            arguments: ["view", "-h", stagedBAMURL.path],
            inputs: [stagedBAMURL, stagedBAIURL], outputs: [reciprocalViewURL],
            stdoutURL: reciprocalViewURL,
            toolVersion: samtoolsVersion.version,
            generationURL: generationURL, logsURL: logsURL, records: &commands
        )

        let reciprocalBAMRelativePath = "artifacts/alignments/unmatched-to-reference.bam"
        let finalBAMURL = request.outputDirectoryURL.appendingPathComponent(reciprocalBAMRelativePath)
        let finalBAIURL = request.outputDirectoryURL.appendingPathComponent("artifacts/alignments/unmatched-to-reference.bam.bai")
        let classificationStartedAt = Date()
        let alignments = try parseReciprocalSAM(
            reciprocalViewURL,
            clusterIDs: Set(grouped.map(\.id)),
            references: request.referenceRecords,
            finalBAMPath: reciprocalBAMRelativePath
        )
        let clusters = grouped.map { group in
            FullLengthONTMHCCandidateCluster(
                stableClusterID: group.id,
                fastaRecordID: group.id,
                sequenceSHA256: Self.sha256(Data(group.sequence.utf8)),
                sequenceLength: group.sequence.count,
                observations: group.observations,
                alignments: alignments[group.id] ?? []
            )
        }
        let classifications = try FullLengthONTMHCCandidateClassifier(thresholds: request.thresholds).classify(clusters)
        let reciprocalViewDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: reciprocalViewURL,
            role: .commandOutput,
            phase: .temporary
        )
        let classificationCompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:parse-and-classify-reciprocal-mhc-alignments",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "parse-and-classify-reciprocal-mhc-alignments",
                "--minimum-aligned-bases", String(request.thresholds.minimumAlignedBases),
                "--minimum-identity", String(request.thresholds.minimumIdentity),
                "--minimum-shorter-coverage", String(request.thresholds.minimumShorterCoverage),
                "--minimum-intron-gap-bases", String(request.thresholds.minimumIntronGapBases),
                "--novel-distance", "snp-substitutions-only",
                reciprocalViewURL.path,
            ],
            resolvedOptions: Self.candidateResolvedOptions(request.thresholds),
            inputs: [referenceDescriptor, stagedStableDescriptor, reciprocalViewDescriptor],
            outputs: [],
            exitStatus: 0,
            startedAt: classificationStartedAt,
            completedAt: classificationCompletedAt,
            wallTime: classificationCompletedAt.timeIntervalSince(classificationStartedAt)
        ))
        let candidates = classifications.compactMap { result -> ONTMHCCandidateRecord? in
            guard case .candidate(let record) = result else { return nil }
            return record
        }.sorted { $0.stableClusterID.localizedStandardCompare($1.stableClusterID) == .orderedAscending }
        let unnameable = classifications.compactMap { result -> ONTMHCUnnameableRecord? in
            guard case .unnameable(let record) = result else { return nil }
            return record
        }.sorted { $0.stableClusterID.localizedStandardCompare($1.stableClusterID) == .orderedAscending }
        let sequenceByID = Dictionary(uniqueKeysWithValues: grouped.map { ($0.id, $0.sequence) })
        let candidateFASTAURL = stagedRootURL.appendingPathComponent("candidate_alleles.fasta")
        let unnameableFASTAURL = stagedRootURL.appendingPathComponent("unnameable_unmatched_clusters.fasta")
        let candidateFASTAStartedAt = Date()
        try writeFASTA(candidates.map { ($0.stableClusterID, sequenceByID[$0.stableClusterID]!) }, to: candidateFASTAURL)
        let candidateFASTADescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: candidateFASTAURL, role: .sourceClusterFASTA, phase: .staging
        )
        let candidateFASTACompletedAt = Date()
        transformations.append(Self.renderTransformation(
            name: "render-mhc-candidate-fasta",
            source: stagedStableDescriptor,
            output: candidateFASTADescriptor,
            recordCount: candidates.count,
            startedAt: candidateFASTAStartedAt,
            completedAt: candidateFASTACompletedAt
        ))
        let unnameableFASTAStartedAt = Date()
        try writeFASTA(unnameable.map { ($0.stableClusterID, sequenceByID[$0.stableClusterID]!) }, to: unnameableFASTAURL)
        let unnameableFASTADescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: unnameableFASTAURL, role: .sourceClusterFASTA, phase: .staging
        )
        let unnameableFASTACompletedAt = Date()
        transformations.append(Self.renderTransformation(
            name: "render-mhc-unnameable-fasta",
            source: stagedStableDescriptor,
            output: unnameableFASTADescriptor,
            recordCount: unnameable.count,
            startedAt: unnameableFASTAStartedAt,
            completedAt: unnameableFASTACompletedAt
        ))

        let reciprocalBAMReference = try artifactReference(stagedBAMURL, finalRelativePath: "artifacts/alignments/unmatched-to-reference.bam")
        let reciprocalBAIReference = try artifactReference(stagedBAIURL, finalRelativePath: "artifacts/alignments/unmatched-to-reference.bam.bai")
        let candidateFASTAReference = try artifactReference(candidateFASTAURL, finalRelativePath: "candidate_alleles.fasta")
        let unnameableFASTAReference = try artifactReference(unnameableFASTAURL, finalRelativePath: "unnameable_unmatched_clusters.fasta")
        let referenceInput = try artifactReference(request.referenceAlleleFASTAURL, finalRelativePath: request.referenceAlleleFASTAURL.path)
        let stableUnmatchedInput = try artifactReference(
            stagedStableFASTAURL,
            finalRelativePath: "deduplicated_unmatched_clusters.fasta"
        )
        let allObservations = grouped.flatMap(\.observations).sorted(by: Self.observationLessThan)
        let createdAt = Self.iso8601(Date())
        let evidence = [reciprocalBAMReference, reciprocalBAIReference]
            + (request.genotypingEvidence.map { [$0.bam, $0.bai] } ?? [])
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: createdAt,
            thresholds: request.thresholds,
            inputs: [referenceInput, stableUnmatchedInput],
            evidence: evidence,
            sequenceFASTA: candidateFASTAReference,
            candidates: candidates,
            observations: allObservations.filter { Set(candidates.map(\.stableClusterID)).contains($0.stableClusterID) }
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: createdAt,
            thresholds: request.thresholds,
            inputs: [referenceInput, stableUnmatchedInput],
            evidence: evidence,
            sequenceFASTA: unnameableFASTAReference,
            clusters: unnameable,
            observations: allObservations.filter { Set(unnameable.map(\.stableClusterID)).contains($0.stableClusterID) }
        )
        let candidateJSONURL = stagedRootURL.appendingPathComponent("candidate-alleles.json")
        let unnameableJSONURL = stagedRootURL.appendingPathComponent("unnameable-unmatched-clusters.json")
        let candidateJSONStartedAt = Date()
        try writeCanonicalJSON(candidateDocument, to: candidateJSONURL)
        let candidateJSONDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: candidateJSONURL, role: .commandOutput, phase: .staging
        )
        let candidateJSONCompletedAt = Date()
        transformations.append(Self.renderTransformation(
            name: "render-mhc-candidate-json",
            inputs: [referenceDescriptor, stagedStableDescriptor, candidateFASTADescriptor],
            output: candidateJSONDescriptor,
            recordCount: candidates.count,
            startedAt: candidateJSONStartedAt,
            completedAt: candidateJSONCompletedAt
        ))
        let unnameableJSONStartedAt = Date()
        try writeCanonicalJSON(unnameableDocument, to: unnameableJSONURL)
        let unnameableJSONDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: unnameableJSONURL, role: .commandOutput, phase: .staging
        )
        let unnameableJSONCompletedAt = Date()
        transformations.append(Self.renderTransformation(
            name: "render-mhc-unnameable-json",
            inputs: [referenceDescriptor, stagedStableDescriptor, unnameableFASTADescriptor],
            output: unnameableJSONDescriptor,
            recordCount: unnameable.count,
            startedAt: unnameableJSONStartedAt,
            completedAt: unnameableJSONCompletedAt
        ))
        let candidateJSONReference = try artifactReference(candidateJSONURL, finalRelativePath: "candidate-alleles.json")
        let unnameableJSONReference = try artifactReference(unnameableJSONURL, finalRelativePath: "unnameable-unmatched-clusters.json")

        try Task.checkCancellation()
        try safety.revalidatePathContext(pathContext)
        let stagedPublicationDescriptors = [
            try FullLengthONTMHCArtifactDescriptor(url: stagedBAMURL, role: .evidenceBAM, phase: .staging),
            try FullLengthONTMHCArtifactDescriptor(url: stagedBAIURL, role: .evidenceBAI, phase: .staging),
            stagedStableDescriptor,
            candidateFASTADescriptor,
            candidateJSONDescriptor,
            unnameableFASTADescriptor,
            unnameableJSONDescriptor,
        ]
        let publicationStartedAt = Date()
        try publishTransaction(
            stagedRootURL: stagedRootURL,
            outputDirectoryURL: request.outputDirectoryURL,
            relativePaths: [
                "artifacts/alignments", "deduplicated_unmatched_clusters.fasta",
                "candidate_alleles.fasta", "candidate-alleles.json",
                "unnameable_unmatched_clusters.fasta", "unnameable-unmatched-clusters.json",
            ]
        )
        let publicationCompletedAt = Date()
        let finalPublicationURLs: [(URL, FullLengthONTMHCArtifactRole)] = [
            (finalBAMURL, .evidenceBAM),
            (finalBAIURL, .evidenceBAI),
            (request.outputDirectoryURL.appendingPathComponent("deduplicated_unmatched_clusters.fasta"), .sourceClusterFASTA),
            (request.outputDirectoryURL.appendingPathComponent("candidate_alleles.fasta"), .sourceClusterFASTA),
            (request.outputDirectoryURL.appendingPathComponent("candidate-alleles.json"), .commandOutput),
            (request.outputDirectoryURL.appendingPathComponent("unnameable_unmatched_clusters.fasta"), .sourceClusterFASTA),
            (request.outputDirectoryURL.appendingPathComponent("unnameable-unmatched-clusters.json"), .commandOutput),
        ]
        let finalPublicationDescriptors = try finalPublicationURLs.map {
            try FullLengthONTMHCArtifactDescriptor(url: $0.0, role: $0.1, phase: .final)
        }
        transformations.append(.init(
            workflowName: "lungfish-internal:publish-mhc-candidate-artifacts",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-internal", "publish-mhc-candidate-artifacts",
                "--atomic-mechanism", "renameatx_np",
                stagedRootURL.path,
                request.outputDirectoryURL.path,
            ],
            resolvedOptions: [
                "atomicMechanism": "renameatx_np",
                "replaceMode": "RENAME_SWAP",
                "createMode": "RENAME_EXCL",
                "rollbackOnFailure": "true",
            ],
            inputs: stagedPublicationDescriptors,
            outputs: finalPublicationDescriptors,
            exitStatus: 0,
            startedAt: publicationStartedAt,
            completedAt: publicationCompletedAt,
            wallTime: publicationCompletedAt.timeIntervalSince(publicationStartedAt)
        ))
        let checksumStartedAt = Date()
        let checksumCompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:capture-mhc-candidate-artifact-checksums",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: ["lungfish-in-process", "capture-mhc-candidate-artifact-checksums", "--algorithm", "sha256"],
            resolvedOptions: ["algorithm": "SHA-256", "artifactCount": String(finalPublicationDescriptors.count)],
            inputs: finalPublicationDescriptors,
            outputs: [],
            exitStatus: 0,
            startedAt: checksumStartedAt,
            completedAt: checksumCompletedAt,
            wallTime: checksumCompletedAt.timeIntervalSince(checksumStartedAt)
        ))
        let manifest = ONTMHCCandidateArtifactManifest(
            schemaVersion: 1,
            genotypingEvidence: request.genotypingEvidence,
            reciprocalEvidence: .init(bam: reciprocalBAMReference, bai: reciprocalBAIReference),
            candidateJSON: candidateJSONReference,
            candidateFASTA: candidateFASTAReference,
            unnameableJSON: unnameableJSONReference,
            unnameableFASTA: unnameableFASTAReference
        )
        return FullLengthONTMHCCandidateArtifactResult(
            stableUnmatchedFASTAURL: request.outputDirectoryURL.appendingPathComponent("deduplicated_unmatched_clusters.fasta"),
            reciprocalBAMURL: finalBAMURL,
            reciprocalBAIURL: finalBAIURL,
            candidateFASTAURL: request.outputDirectoryURL.appendingPathComponent("candidate_alleles.fasta"),
            candidateJSONURL: request.outputDirectoryURL.appendingPathComponent("candidate-alleles.json"),
            unnameableFASTAURL: request.outputDirectoryURL.appendingPathComponent("unnameable_unmatched_clusters.fasta"),
            unnameableJSONURL: request.outputDirectoryURL.appendingPathComponent("unnameable-unmatched-clusters.json"),
            manifest: manifest,
            classifiedClusters: clusters,
            classifications: classifications,
            commandRecords: commands,
            toolVersions: toolVersions,
            toolVersionDiscoveryRecords: toolVersions.map(\.discoveryCommand),
            transformationRecords: transformations,
            runtimeIdentity: ProvenanceRuntimeIdentity()
        )
    }
}

private extension FullLengthONTMHCCandidateArtifactWriter {
    struct Group {
        let id: String
        let sequence: String
        let observations: [ONTMHCCandidateObservation]
    }

    static func normalizedSequence(_ sequence: String) -> String {
        sequence.filter { !$0.isWhitespace }.uppercased()
    }

    static func candidateResolvedOptions(
        _ thresholds: ONTMHCCandidateThresholds
    ) -> [String: String] {
        [
            "minimumAlignedBases": String(thresholds.minimumAlignedBases),
            "minimumIdentity": String(thresholds.minimumIdentity),
            "minimumShorterCoverage": String(thresholds.minimumShorterCoverage),
            "minimumIntronGapBases": String(thresholds.minimumIntronGapBases),
            "novelDistanceMetric": "SNP-substitutions-only",
            "zeroSNPIndelClassification": "known-existing-allele",
            "extensionRule": "identical-except-long-intron-gaps",
        ]
    }

    static func renderTransformation(
        name: String,
        source: FullLengthONTMHCArtifactDescriptor,
        output: FullLengthONTMHCArtifactDescriptor,
        recordCount: Int,
        startedAt: Date,
        completedAt: Date
    ) -> FullLengthONTMHCInProcessTransformationRecord {
        renderTransformation(
            name: name,
            inputs: [source],
            output: output,
            recordCount: recordCount,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    static func renderTransformation(
        name: String,
        inputs: [FullLengthONTMHCArtifactDescriptor],
        output: FullLengthONTMHCArtifactDescriptor,
        recordCount: Int,
        startedAt: Date,
        completedAt: Date
    ) -> FullLengthONTMHCInProcessTransformationRecord {
        FullLengthONTMHCInProcessTransformationRecord(
            workflowName: "lungfish-in-process:\(name)",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", name,
                "--canonical-order", "stable-cluster-id",
                "--record-count", String(recordCount),
                output.path,
            ],
            resolvedOptions: [
                "canonicalOrder": "stable-cluster-id",
                "recordCount": String(recordCount),
                "newline": "LF",
            ],
            inputs: inputs,
            outputs: [output],
            exitStatus: 0,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTime: completedAt.timeIntervalSince(startedAt)
        )
    }

    func groupedClusters(_ inputs: [FullLengthONTMHCCandidateSequenceObservation]) throws -> [Group] {
        struct RawKey: Hashable { let sequence: String; let sampleID: String; let readGroupID: String }
        var buckets: [RawKey: [FullLengthONTMHCCandidateSequenceObservation]] = [:]
        for input in inputs {
            let sequence = Self.normalizedSequence(input.sequence)
            guard !sequence.isEmpty, sequence.allSatisfy({ "ACGTRYSWKMBDHVN".contains($0) }) else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Unmatched cluster '\(input.sourceClusterID)' has an invalid nucleotide sequence.")
            }
            guard !input.sampleID.isEmpty, !input.readGroupID.isEmpty, !input.sourceClusterID.isEmpty, input.clusterReadCount > 0 else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Unmatched cluster observation fields and read counts must be nonempty and positive.")
            }
            buckets[RawKey(sequence: sequence, sampleID: input.sampleID, readGroupID: input.readGroupID), default: []].append(input)
        }
        let bySequence = Dictionary(grouping: buckets.keys, by: \.sequence)
        return bySequence.map { sequence, keys in
            let id = Self.stableClusterID(for: sequence)
            let observations = keys.map { key -> ONTMHCCandidateObservation in
                let values = buckets[key]!.sorted { $0.sourceClusterID.localizedStandardCompare($1.sourceClusterID) == .orderedAscending }
                var counts: [String: Int] = [:]
                var evidence: [ONTMHCEvidenceLocator] = []
                for value in values {
                    counts[value.sourceClusterID, default: 0] += value.clusterReadCount
                    evidence.append(contentsOf: value.genotypingEvidence)
                }
                let sources = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                return ONTMHCCandidateObservation(
                    stableClusterID: id,
                    sampleID: key.sampleID,
                    readGroupID: key.readGroupID,
                    sourceClusterIDs: sources,
                    sourceClusterReadCounts: counts,
                    aggregatedSampleReadCount: counts.values.reduce(0, +),
                    evidence: evidence.sorted(by: Self.evidenceLessThan)
                )
            }.sorted(by: Self.observationLessThan)
            return Group(id: id, sequence: sequence, observations: observations)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func parseReciprocalSAM(
        _ url: URL,
        clusterIDs: Set<String>,
        references: [MHCReferenceRecord],
        finalBAMPath: String
    ) throws -> [String: [FullLengthONTMHCCandidateAlignment]] {
        let referencesByID = Dictionary(uniqueKeysWithValues: references.map { ($0.sequenceID, $0) })
        let data = try String(contentsOf: url, encoding: .utf8)
        var result: [String: [FullLengthONTMHCCandidateAlignment]] = [:]
        for (lineIndex, line) in data.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            try Task.checkCancellation()
            if line.first == "@" { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 11,
                  clusterIDs.contains(fields[0]),
                  let flag = Int(fields[1]), flag >= 0 else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Malformed reciprocal SAM alignment at line \(lineIndex + 1).")
            }
            if flag & 0x4 != 0 { continue }
            guard
                  let position = Int(fields[3]), position > 0,
                  let mapq = Int(fields[4]), (0...255).contains(mapq),
                  fields[5] != "*" else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Malformed reciprocal SAM alignment at line \(lineIndex + 1).")
            }
            guard let reference = referencesByID[fields[2]] else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Reciprocal SAM names unknown reference '\(fields[2])'.")
            }
            var nm: Int?
            var score: Int?
            for tag in fields.dropFirst(11) {
                if tag.hasPrefix("NM:i:") { nm = Int(tag.dropFirst(5)) }
                if tag.hasPrefix("AS:i:") { score = Int(tag.dropFirst(5)) }
            }
            guard let score else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Reciprocal SAM alignment at line \(lineIndex + 1) lacks AS:i.")
            }
            let locator = ONTMHCEvidenceLocator(
                bamPath: finalBAMPath,
                queryName: fields[0],
                referenceName: fields[2],
                readGroupID: nil,
                referenceStart: position,
                cigar: fields[5]
            )
            result[fields[0], default: []].append(.init(
                reference: .resolved(reference), cigar: fields[5], nm: nm,
                mappingQuality: mapq, alignmentScore: score, evidence: locator
            ))
        }
        return result
    }

    func run(
        _ executableURL: URL,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        stdoutURL: URL? = nil,
        toolVersion: String,
        generationURL: URL,
        logsURL: URL,
        records: inout [FullLengthONTMHCCohortAlignmentCommandRecord]
    ) async throws {
        let record = try await FullLengthONTMHCAlignmentProcessRunner(fileManager: fileManager).execute(.init(
            executableURL: executableURL,
            arguments: arguments,
            inputs: inputs,
            outputs: outputs,
            stdoutURL: stdoutURL,
            workingDirectoryURL: generationURL,
            logsDirectoryURL: logsURL,
            toolVersion: toolVersion,
            temporaryRootURL: generationURL,
            pathIdentityValidator: nil
        ))
        records.append(record)
        if record.wasCancelled { throw CancellationError() }
        guard record.exitStatus == 0 else {
            throw FullLengthONTMHCCandidateArtifactWriterError("\(executableURL.lastPathComponent) failed with exit status \(record.exitStatus): \(record.stderr)")
        }
        guard record.descriptorCaptureErrors.isEmpty else {
            throw FullLengthONTMHCCandidateArtifactWriterError("Could not validate reciprocal command outputs: \(record.descriptorCaptureErrors.map(\.message).joined(separator: "; "))")
        }
        for output in outputs {
            try FullLengthONTMHCAlignmentSafety(fileManager: fileManager).requireRegularFileNoFollow(output, role: "reciprocal command output")
        }
    }

    func discoverVersion(
        toolName: String,
        executableURL: URL,
        generationURL: URL,
        logsURL: URL
    ) async throws -> FullLengthONTMHCToolVersionRecord {
        let raw = try await FullLengthONTMHCAlignmentProcessRunner(fileManager: fileManager).execute(.init(
            executableURL: executableURL,
            arguments: ["--version"],
            inputs: [],
            outputs: [],
            stdoutURL: nil,
            workingDirectoryURL: generationURL,
            logsDirectoryURL: logsURL,
            toolVersion: nil,
            temporaryRootURL: generationURL,
            pathIdentityValidator: nil
        ))
        if raw.wasCancelled { throw CancellationError() }
        guard raw.exitStatus == 0,
              let version = raw.stdout.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw FullLengthONTMHCCandidateArtifactWriterError(
                "Could not discover \(toolName) version: \(raw.stderr)"
            )
        }
        return FullLengthONTMHCToolVersionRecord(
            toolName: toolName,
            version: version,
            discoveryCommand: raw.replacingToolVersion(with: version)
        )
    }

    func executable(named name: String) throws -> URL {
        if let explicit = name == "minimap2" ? minimap2ExecutableURL : samtoolsExecutableURL {
            guard fileManager.isExecutableFile(atPath: explicit.path) else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Executable '\(name)' is missing at \(explicit.path).")
            }
            return explicit
        }
        if let executableDirectoryURL {
            let url = executableDirectoryURL.appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Executable '\(name)' is missing at \(url.path).")
            }
            return url
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        throw FullLengthONTMHCCandidateArtifactWriterError("Executable '\(name)' was not found on PATH.")
    }

    func copyExistingAlignmentArtifacts(from source: URL, to destination: URL) throws {
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0 else { return }
        guard (sourceInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw FullLengthONTMHCCandidateArtifactWriterError("Existing alignments path is not a regular directory.")
        }
        for name in try fileManager.contentsOfDirectory(atPath: source.path).sorted() {
            let input = source.appendingPathComponent(name)
            var info = stat()
            guard lstat(input.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw FullLengthONTMHCCandidateArtifactWriterError("Existing alignment artifact '\(name)' is not a regular file.")
            }
            if name == "unmatched-to-reference.bam" || name == "unmatched-to-reference.bam.bai" { continue }
            try fileManager.copyItem(at: input, to: destination.appendingPathComponent(name))
        }
    }

    func publishTransaction(stagedRootURL: URL, outputDirectoryURL: URL, relativePaths: [String]) throws {
        struct Applied { let staged: URL; let final: URL; let replaced: Bool }
        var applied: [Applied] = []
        do {
            for relative in relativePaths {
                try Task.checkCancellation()
                let staged = stagedRootURL.appendingPathComponent(relative)
                let final = outputDirectoryURL.appendingPathComponent(relative)
                try fileManager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                let replaced = fileManager.fileExists(atPath: final.path)
                let flags = UInt32(replaced ? RENAME_SWAP : RENAME_EXCL)
                let status = staged.path.withCString { source in
                    final.path.withCString { destination in
                        renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, flags)
                    }
                }
                guard status == 0 else {
                    throw FullLengthONTMHCCandidateArtifactWriterError("Could not publish candidate artifact '\(relative)': \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)")
                }
                applied.append(.init(staged: staged, final: final, replaced: replaced))
            }
        } catch {
            for operation in applied.reversed() {
                if operation.replaced {
                    _ = operation.staged.path.withCString { source in
                        operation.final.path.withCString { destination in
                            renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_SWAP))
                        }
                    }
                } else {
                    try? fileManager.removeItem(at: operation.final)
                }
            }
            throw error
        }
    }

    func writeFASTA(_ records: [(String, String)], to url: URL) throws {
        var text = ""
        for (id, sequence) in records.sorted(by: { $0.0.localizedStandardCompare($1.0) == .orderedAscending }) {
            text += ">\(id)\n"
            var index = sequence.startIndex
            while index < sequence.endIndex {
                let end = sequence.index(index, offsetBy: 80, limitedBy: sequence.endIndex) ?? sequence.endIndex
                text += sequence[index..<end] + "\n"
                index = end
            }
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func writeCanonicalJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    func artifactReference(_ url: URL, finalRelativePath: String) throws -> ONTMHCArtifactReference {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return ONTMHCArtifactReference(
            path: finalRelativePath,
            sha256: Self.sha256(try Data(contentsOf: url, options: .mappedIfSafe)),
            sizeBytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func observationLessThan(_ lhs: ONTMHCCandidateObservation, _ rhs: ONTMHCCandidateObservation) -> Bool {
        if lhs.stableClusterID != rhs.stableClusterID {
            return lhs.stableClusterID.localizedStandardCompare(rhs.stableClusterID) == .orderedAscending
        }
        if lhs.sampleID != rhs.sampleID {
            return lhs.sampleID.localizedStandardCompare(rhs.sampleID) == .orderedAscending
        }
        return lhs.readGroupID.localizedStandardCompare(rhs.readGroupID) == .orderedAscending
    }

    static func evidenceLessThan(_ lhs: ONTMHCEvidenceLocator, _ rhs: ONTMHCEvidenceLocator) -> Bool {
        let left = [lhs.bamPath, lhs.queryName, lhs.referenceName, lhs.readGroupID ?? "", String(lhs.referenceStart), lhs.cigar]
        let right = [rhs.bamPath, rhs.queryName, rhs.referenceName, rhs.readGroupID ?? "", String(rhs.referenceStart), rhs.cigar]
        return left.lexicographicallyPrecedes(right)
    }
}

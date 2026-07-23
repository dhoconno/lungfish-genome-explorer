import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCCandidateSequenceObservation: Sendable, Equatable {
    let sampleID: String
    let readGroupID: String
    let sourceClusterID: String
    let clusterReadCount: Int
    let sequence: String
    let genotypingHitSummaries: [ONTMHCGenotypingTargetHitSummary]

    init(
        sampleID: String,
        readGroupID: String,
        sourceClusterID: String,
        clusterReadCount: Int,
        sequence: String,
        genotypingHitSummaries: [ONTMHCGenotypingTargetHitSummary]
    ) {
        self.sampleID = sampleID
        self.readGroupID = readGroupID
        self.sourceClusterID = sourceClusterID
        self.clusterReadCount = clusterReadCount
        self.sequence = sequence
        self.genotypingHitSummaries = genotypingHitSummaries
    }
}

struct FullLengthONTMHCCandidateArtifactWriteRequest: Sendable, Equatable {
    let observations: [FullLengthONTMHCCandidateSequenceObservation]
    let referenceAlleleFASTAURL: URL
    let rawUnmatchedConsensusesFASTAURL: URL
    let referenceBundleURL: URL?
    let referenceAnnotationInputURLs: [URL]
    let referenceRecords: [MHCReferenceRecord]
    let genotypingEvidence: ONTMHCBAMArtifactPair?
    let threads: Int
    let outputDirectoryURL: URL
    let finalOutputDirectoryURL: URL
    let workDirectoryURL: URL
    let thresholds: ONTMHCCandidateThresholds
    let analysisName: String
    let projectBundleName: String?

    init(
        observations: [FullLengthONTMHCCandidateSequenceObservation],
        referenceAlleleFASTAURL: URL,
        rawUnmatchedConsensusesFASTAURL: URL? = nil,
        referenceBundleURL: URL? = nil,
        referenceAnnotationInputURLs: [URL] = [],
        referenceRecords: [MHCReferenceRecord],
        genotypingEvidence: ONTMHCBAMArtifactPair?,
        threads: Int,
        outputDirectoryURL: URL,
        finalOutputDirectoryURL: URL? = nil,
        workDirectoryURL: URL,
        thresholds: ONTMHCCandidateThresholds = .defaults,
        analysisName: String = "full-length-ont-mhc-genotype",
        projectBundleName: String? = nil
    ) {
        self.observations = observations
        self.referenceAlleleFASTAURL = referenceAlleleFASTAURL.standardizedFileURL
        self.rawUnmatchedConsensusesFASTAURL = (
            rawUnmatchedConsensusesFASTAURL
                ?? outputDirectoryURL.appendingPathComponent(
                    "artifacts/internal/raw-unmatched-consensuses.fasta"
                )
        ).standardizedFileURL
        self.referenceBundleURL = referenceBundleURL?.standardizedFileURL
        self.referenceAnnotationInputURLs = referenceAnnotationInputURLs.map(\.standardizedFileURL)
        self.referenceRecords = referenceRecords
        self.genotypingEvidence = genotypingEvidence
        self.threads = max(1, threads)
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.finalOutputDirectoryURL = (finalOutputDirectoryURL ?? outputDirectoryURL).standardizedFileURL
        self.workDirectoryURL = workDirectoryURL.standardizedFileURL
        self.thresholds = thresholds
        self.analysisName = analysisName
        self.projectBundleName = projectBundleName
    }
}

struct FullLengthONTMHCCandidateArtifactResult: Sendable, Equatable {
    let stableUnmatchedFASTAURL: URL
    let reciprocalBAMURL: URL
    let reciprocalBAIURL: URL
    let candidateFASTAURL: URL
    let candidateJSONURL: URL
    let candidateGenBankURL: URL
    let unnameableFASTAURL: URL
    let unnameableJSONURL: URL
    let unnameableGenBankURL: URL
    let manifest: ONTMHCCandidateArtifactManifest
    let classifiedClusters: [FullLengthONTMHCCandidateCluster]
    let classifications: [FullLengthONTMHCCandidateClassificationResult]
    let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    let toolVersions: [FullLengthONTMHCToolVersionRecord]
    let toolVersionDiscoveryRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    let transformationRecords: [FullLengthONTMHCInProcessTransformationRecord]
    let runtimeIdentity: ProvenanceRuntimeIdentity

    var allArtifactReferences: [ONTMHCArtifactReference] {
        [
            manifest.reciprocalEvidence?.bam,
            manifest.reciprocalEvidence?.bai,
            manifest.candidateJSON,
            manifest.candidateFASTA,
            manifest.candidateGenBank,
            manifest.unnameableJSON,
            manifest.unnameableFASTA,
            manifest.unnameableGenBank,
            manifest.rawUnmatchedFASTA,
            manifest.sourceIdentityMap,
        ].compactMap { $0 }
    }
}

struct FullLengthONTMHCCandidateArtifactWriterError: Error, LocalizedError, Sendable, Equatable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct FullLengthONTMHCReciprocalSAMParser: Sendable {
    static let maximumLineBytes = 1_048_576
    static let maximumFields = 4_096
    static let maximumAlignmentsPerCluster = 1_024

    func parse(
        _ url: URL,
        clusterIDs: Set<String>,
        references: [MHCReferenceRecord],
        finalBAMPath: String
    ) throws -> [String: [FullLengthONTMHCCandidateAlignment]] {
        let referencesByID = Dictionary(uniqueKeysWithValues: references.map { ($0.sequenceID, $0) })
        var result: [String: [FullLengthONTMHCCandidateAlignment]] = [:]
        var lineNumber = 0
        try url.forEachLineAutoDecompressing { line in
            try Task.checkCancellation()
            lineNumber += 1
            guard line.utf8.count <= Self.maximumLineBytes else {
                throw error("line exceeds \(Self.maximumLineBytes) bytes", line: lineNumber)
            }
            guard !line.isEmpty, !line.hasPrefix("@") else { return }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 11, fields.count <= Self.maximumFields,
                  clusterIDs.contains(fields[0]),
                  let flag = Int(fields[1]), flag >= 0 else {
                throw error("malformed mandatory fields", line: lineNumber)
            }
            if flag & 0x4 != 0 { return }
            guard let position = Int(fields[3]), position > 0,
                  let mapq = Int(fields[4]), (0...255).contains(mapq),
                  fields[5] != "*" else {
                throw error("malformed mapped alignment", line: lineNumber)
            }
            guard let reference = referencesByID[fields[2]] else {
                throw error("unknown reference '\(fields[2])'", line: lineNumber)
            }
            let nm = try uniqueIntegerTag("NM", in: fields.dropFirst(11), required: false, line: lineNumber)
            let score = try uniqueIntegerTag("AS", in: fields.dropFirst(11), required: true, line: lineNumber)!
            guard nm.map({ $0 >= 0 }) ?? true else {
                throw error("NM must be nonnegative", line: lineNumber)
            }
            let locator = ONTMHCEvidenceLocator(
                bamPath: finalBAMPath,
                queryName: fields[0],
                referenceName: fields[2],
                readGroupID: nil,
                referenceStart: position,
                cigar: fields[5]
            )
            var alignments = result[fields[0], default: []]
            guard alignments.count < Self.maximumAlignmentsPerCluster else {
                throw error("too many alignments for cluster '\(fields[0])'", line: lineNumber)
            }
            alignments.append(.init(
                reference: .resolved(reference),
                cigar: fields[5],
                nm: nm,
                mappingQuality: mapq,
                alignmentScore: score,
                evidence: locator,
                isReverse: flag & 0x10 != 0
            ))
            result[fields[0]] = alignments
        }
        return result.mapValues { values in
            var unique: [FullLengthONTMHCCandidateAlignment] = []
            for value in values.sorted(by: Self.alignmentLessThan) where unique.last != value {
                unique.append(value)
            }
            return unique
        }
    }

    private func uniqueIntegerTag(
        _ name: String,
        in tags: ArraySlice<String>,
        required: Bool,
        line: Int
    ) throws -> Int? {
        let matches = tags.filter { tag in
            tag.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first == Substring(name)
        }
        guard matches.count <= 1 else {
            throw error("duplicate \(name) tag", line: line)
        }
        guard let tag = matches.first else {
            if required { throw error("missing \(name):i tag", line: line) }
            return nil
        }
        let pieces = tag.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == Substring(name), pieces[1] == "i",
              let value = Int(pieces[2]) else {
            throw error("malformed \(name):i tag", line: line)
        }
        return value
    }

    private func error(_ detail: String, line: Int) -> FullLengthONTMHCCandidateArtifactWriterError {
        FullLengthONTMHCCandidateArtifactWriterError(
            "Malformed reciprocal SAM alignment at line \(line): \(detail)."
        )
    }

    private static func alignmentLessThan(
        _ lhs: FullLengthONTMHCCandidateAlignment,
        _ rhs: FullLengthONTMHCCandidateAlignment
    ) -> Bool {
        let left = [
            lhs.reference.referenceName, String(lhs.evidence.referenceStart), lhs.cigar,
            String(lhs.nm ?? -1), String(lhs.alignmentScore), String(lhs.mappingQuality),
            lhs.evidence.bamPath, lhs.evidence.queryName,
        ]
        let right = [
            rhs.reference.referenceName, String(rhs.evidence.referenceStart), rhs.cigar,
            String(rhs.nm ?? -1), String(rhs.alignmentScore), String(rhs.mappingQuality),
            rhs.evidence.bamPath, rhs.evidence.queryName,
        ]
        return left.lexicographicallyPrecedes(right)
    }
}

struct FullLengthONTMHCCandidateArtifactWriter: @unchecked Sendable {
    typealias CanonicalizationProvider = @Sendable (
        FullLengthONTMHCCandidateGenBankArtifactBuilder.Input
    ) throws -> FullLengthONTMHCCandidateCanonicalization

    private let executableDirectoryURL: URL?
    private let minimap2ExecutableURL: URL?
    private let samtoolsExecutableURL: URL?
    private let fileManager: FileManager
    private let canonicalizationProvider: CanonicalizationProvider
    private let artifactDescriptorProvider: any FullLengthONTMHCArtifactDescriptorProviding

    init(
        executableDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        canonicalizationProvider: CanonicalizationProvider? = nil,
        artifactDescriptorProvider: any FullLengthONTMHCArtifactDescriptorProviding =
            DefaultFullLengthONTMHCArtifactDescriptorProvider()
    ) {
        self.executableDirectoryURL = executableDirectoryURL?.standardizedFileURL
        minimap2ExecutableURL = nil
        samtoolsExecutableURL = nil
        self.fileManager = fileManager
        self.canonicalizationProvider = canonicalizationProvider ?? {
            try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: $0)
        }
        self.artifactDescriptorProvider = artifactDescriptorProvider
    }

    init(
        minimap2ExecutableURL: URL,
        samtoolsExecutableURL: URL,
        fileManager: FileManager = .default,
        canonicalizationProvider: CanonicalizationProvider? = nil,
        artifactDescriptorProvider: any FullLengthONTMHCArtifactDescriptorProviding =
            DefaultFullLengthONTMHCArtifactDescriptorProvider()
    ) {
        executableDirectoryURL = nil
        self.minimap2ExecutableURL = minimap2ExecutableURL.standardizedFileURL
        self.samtoolsExecutableURL = samtoolsExecutableURL.standardizedFileURL
        self.fileManager = fileManager
        self.canonicalizationProvider = canonicalizationProvider ?? {
            try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: $0)
        }
        self.artifactDescriptorProvider = artifactDescriptorProvider
    }

    static func stableClusterID(for sequence: String) -> String {
        let normalized = normalizedSequence(sequence)
        var bytes = Array(SHA256.hash(data: Data(normalized.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    func stage(
        _ request: FullLengthONTMHCCandidateArtifactWriteRequest
    ) async throws -> FullLengthONTMHCCandidateArtifactResult {
        try Task.checkCancellation()
        let safety = FullLengthONTMHCAlignmentSafety(fileManager: fileManager)
        try safety.requireRegularFileNoFollow(request.referenceAlleleFASTAURL, role: "reference allele FASTA")
        try fileManager.createDirectory(at: request.outputDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: request.workDirectoryURL, withIntermediateDirectories: true)
        let canonicalUnmatchedFASTAURL = request.outputDirectoryURL.appendingPathComponent(
            "deduplicated_unmatched_clusters.fasta"
        )
        try safety.requireRegularFileNoFollow(
            request.rawUnmatchedConsensusesFASTAURL,
            role: "caller-staged raw unmatched consensus FASTA"
        )
        try requireFreshStagingTargets(in: request.outputDirectoryURL)
        let pathContext = try safety.prepareDirectories(
            outputDirectoryURL: request.outputDirectoryURL,
            workDirectoryURL: request.workDirectoryURL
        )
        let observationGroups = try groupedClusters(request.observations)
        let canonicalRecords = try canonicalUnmatchedRecords(
            request.rawUnmatchedConsensusesFASTAURL
        )
        let grouped = try bindCanonicalRecords(
            canonicalRecords,
            to: observationGroups
        )
        let capturedCanonicalDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: request.rawUnmatchedConsensusesFASTAURL,
            role: .sourceClusterFASTA,
            phase: .input
        )
        let canonicalDescriptor = capturedCanonicalDescriptor.relocated(
            to: request.finalOutputDirectoryURL.appendingPathComponent(
                "artifacts/internal/raw-unmatched-consensuses.fasta"
            ),
            role: .sourceClusterFASTA,
            phase: .final
        )

        let generationURL = request.workDirectoryURL.appendingPathComponent(
            "full-length-ont-mhc-candidates-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: generationURL, withIntermediateDirectories: false)
        let logsURL = generationURL.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: false)
        let stagedRootURL = generationURL.appendingPathComponent("publication", isDirectory: true)
        let stagedAlignmentsURL = stagedRootURL.appendingPathComponent("artifacts/alignments", isDirectory: true)
        try fileManager.createDirectory(at: stagedAlignmentsURL, withIntermediateDirectories: true)

        var transformations: [FullLengthONTMHCInProcessTransformationRecord] = []
        let referenceDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: request.referenceAlleleFASTAURL,
            role: .referenceFASTA,
            phase: .input
        )
        let annotationInputDescriptors = try request.referenceAnnotationInputURLs.map {
            try FullLengthONTMHCArtifactDescriptor(url: $0, role: .commandInput, phase: .input)
        }
        let stagedStableFASTAURL = stagedRootURL.appendingPathComponent("deduplicated_unmatched_clusters.fasta")
        let stableFASTAStartedAt = Date()
        try writeFASTA(grouped.map { ($0.id, $0.sequence) }, to: stagedStableFASTAURL)
        let stagedStableDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: stagedStableFASTAURL, role: .sourceClusterFASTA, phase: .temporary
        )
        let stableFASTACompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:construct-stable-unmatched-cluster-fasta",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "construct-stable-unmatched-cluster-fasta",
                "--stable-id", "sha256-uuid-v5-compatible",
                "--line-width", "80",
                "--input", request.rawUnmatchedConsensusesFASTAURL.path,
                "--output", stagedStableFASTAURL.path,
            ],
            resolvedOptions: [
                "stableID": "first-128-bits-SHA256-with-UUID-version-and-variant-bits",
                "sequenceNormalization": "remove-whitespace-and-uppercase",
                "sequenceGrouping": "exact-normalized-sequence",
                "canonicalValidation": "exact-stable-id-and-normalized-sequence-bijection",
                "querySequenceSource": "validated-raw-full-consensus-internal-copy",
                "lineWidth": "80",
            ],
            inputs: [canonicalDescriptor],
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
        let reciprocalSecondaryAlignmentLimit = max(1, request.referenceRecords.count)

        try await run(
            minimap2URL,
            arguments: [
                "-a", "--eqx", "--cs=long", "-x", "asm20", "-t", String(request.threads),
                "-N", String(reciprocalSecondaryAlignmentLimit), "--secondary=yes",
                request.referenceAlleleFASTAURL.path,
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
        let alignments = try FullLengthONTMHCReciprocalSAMParser().parse(
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
        let classifications = try FullLengthONTMHCCandidateClassifier(
            thresholds: request.thresholds,
            reciprocalBAMPath: reciprocalBAMRelativePath
        ).classify(clusters)
        let reciprocalViewDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: reciprocalViewURL,
            role: .commandOutput,
            phase: .temporary
        )
        let reciprocalBAMDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: stagedBAMURL,
            role: .evidenceBAM,
            phase: .staging
        )
        let reciprocalBAIDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: stagedBAIURL,
            role: .evidenceBAI,
            phase: .staging
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
            resolvedOptions: Self.candidateResolvedOptions(request.thresholds).merging([
                "provenanceOutputException": "typed in-memory classification result is consumed by the candidate and unnameable render steps",
                "documentSchemaVersion": "4",
                "reciprocalSecondaryAlignmentLimit": String(reciprocalSecondaryAlignmentLimit),
                "reciprocalSecondaryAlignmentLimitRule": "reference-record-count;at-least-one",
                "reciprocalBAMPath": reciprocalBAMRelativePath,
                "reciprocalLocatorIdentity": "bam-path,query-name,reference-name,read-group-id,reference-start,cigar",
                "reciprocalAlignmentCountRule": "unique-locator-count-equals-sum-of-target-alignment-counts",
                "reciprocalExactRelationshipRule": "eligible-zero-SNP",
                "reciprocalClosestRelationshipRule": "all-targets-tied-at-classifier-biological-rank-before-lexical-tiebreak",
                "selectedEvidenceRule": "classifier-selected-target-must-occur-in-closest-match-target-names",
                "unnameableBulkEvidence": "omitted",
            ]) { current, _ in current },
            inputs: [
                referenceDescriptor, stagedStableDescriptor, reciprocalViewDescriptor,
                reciprocalBAMDescriptor, reciprocalBAIDescriptor,
            ],
            outputs: [],
            exitStatus: 0,
            startedAt: classificationStartedAt,
            completedAt: classificationCompletedAt,
            wallTime: classificationCompletedAt.timeIntervalSince(classificationStartedAt)
        ))
        let rawCandidates = classifications.compactMap { result -> ONTMHCCandidateRecord? in
            guard case .candidate(let record) = result else { return nil }
            return record
        }.sorted { $0.stableClusterID.localizedStandardCompare($1.stableClusterID) == .orderedAscending }
        let rawUnnameable = classifications.compactMap { result -> ONTMHCUnnameableRecord? in
            guard case .unnameable(let record) = result else { return nil }
            return record
        }.sorted { $0.stableClusterID.localizedStandardCompare($1.stableClusterID) == .orderedAscending }
        let sequenceByID = Dictionary(uniqueKeysWithValues: grouped.map { ($0.id, $0.sequence) })
        let observationsByRawID = Dictionary(uniqueKeysWithValues: grouped.map {
            ($0.id, $0.observations)
        })
        let rawSequenceReference = try artifactReference(
            request.rawUnmatchedConsensusesFASTAURL,
            finalRelativePath: "artifacts/internal/raw-unmatched-consensuses.fasta"
        )
        let rawCreatedAt = Self.iso8601(Date())
        let rawCandidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 3,
            createdAt: rawCreatedAt,
            thresholds: request.thresholds,
            inputs: [],
            evidence: [],
            sequenceFASTA: rawSequenceReference,
            candidates: rawCandidates,
            observations: grouped.flatMap(\.observations).filter {
                Set(rawCandidates.map(\.stableClusterID)).contains($0.stableClusterID)
            }
        )
        let rawUnnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 3,
            createdAt: rawCreatedAt,
            thresholds: request.thresholds,
            inputs: [],
            evidence: [],
            sequenceFASTA: rawSequenceReference,
            clusters: rawUnnameable,
            observations: grouped.flatMap(\.observations).filter {
                Set(rawUnnameable.map(\.stableClusterID)).contains($0.stableClusterID)
            }
        )
        let referenceVisualization: ONTMHCReferenceVisualizationArtifact?
        if let referenceBundleURL = request.referenceBundleURL,
           referenceBundleURL.pathExtension.lowercased() == "lungfishref",
           fileManager.fileExists(atPath: referenceBundleURL.path) {
            referenceVisualization = try MHCReferenceVisualizationArtifactBuilder().build(.init(
                referenceBundleURL: referenceBundleURL,
                exactKnownRawReferenceIDs: [],
                candidates: rawCandidateDocument,
                unnameable: rawUnnameableDocument
            )).document
        } else {
            referenceVisualization = nil
        }
        let canonicalizationStartedAt = Date()
        let preparedCandidates = try rawCandidates.map { candidate in
            let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
                subject: .candidate(candidate),
                sequence: sequenceByID[candidate.stableClusterID]!,
                selectedAlignmentIsReverse: candidate.selectedAlignmentIsReverse,
                closestReference: referenceVisualization?.recordsByRawReferenceID[
                    candidate.selectedEvidence.referenceName
                ],
                analysisName: request.analysisName,
                projectBundleName: request.projectBundleName,
                minimumIntronGapBases: request.thresholds.minimumIntronGapBases
            )
            return FullLengthONTMHCCandidateCanonicalizer.Input(
                record: candidate,
                observations: observationsByRawID[candidate.stableClusterID] ?? [],
                canonicalization: try canonicalizationProvider(input)
            )
        }
        let canonicalCandidates = try FullLengthONTMHCCandidateCanonicalizer()
            .aggregate(preparedCandidates)
        let candidates = canonicalCandidates.map(\.record)
        let canonicalSequenceByID = Dictionary(uniqueKeysWithValues: canonicalCandidates.map {
            ($0.record.stableClusterID, $0.sequence)
        })

        let preparedUnnameable = try rawUnnameable.map { cluster -> (
            record: ONTMHCUnnameableRecord,
            canonicalization: FullLengthONTMHCCandidateCanonicalization
        ) in
            let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
                subject: .unnameable(cluster),
                sequence: sequenceByID[cluster.stableClusterID]!,
                selectedAlignmentIsReverse: cluster.selectedAlignmentIsReverse,
                closestReference: cluster.selectedEvidence.flatMap {
                    referenceVisualization?.recordsByRawReferenceID[$0.referenceName]
                },
                analysisName: request.analysisName,
                projectBundleName: request.projectBundleName,
                minimumIntronGapBases: request.thresholds.minimumIntronGapBases
            )
            return (cluster, try canonicalizationProvider(input))
        }
        let unnameable = preparedUnnameable.map { prepared -> ONTMHCUnnameableRecord in
            guard let sequence = prepared.canonicalization.externalSequence,
                  prepared.canonicalization.referenceReadiness == .referenceReady else {
                return ONTMHCUnnameableRecord(
                    stableClusterID: prepared.record.stableClusterID,
                    reason: prepared.record.reason,
                    failedMetrics: prepared.record.failedMetrics,
                    supportClass: prepared.record.supportClass,
                    independentSampleCount: prepared.record.independentSampleCount,
                    occurrenceCount: prepared.record.occurrenceCount,
                    totalClusterReads: prepared.record.totalClusterReads,
                    supportingSampleIDs: prepared.record.supportingSampleIDs,
                    fastaRecordID: nil,
                    sequenceSHA256: nil,
                    reciprocalHitSummary: prepared.record.reciprocalHitSummary,
                    selectedEvidence: prepared.record.selectedEvidence,
                    selectedAlignmentIsReverse: prepared.record.selectedAlignmentIsReverse
                )
            }
            let external = Self.normalizedSequence(sequence)
            return ONTMHCUnnameableRecord(
                stableClusterID: prepared.record.stableClusterID,
                reason: prepared.record.reason,
                failedMetrics: prepared.record.failedMetrics,
                supportClass: prepared.record.supportClass,
                independentSampleCount: prepared.record.independentSampleCount,
                occurrenceCount: prepared.record.occurrenceCount,
                totalClusterReads: prepared.record.totalClusterReads,
                supportingSampleIDs: prepared.record.supportingSampleIDs,
                fastaRecordID: Self.stableClusterID(for: external),
                sequenceSHA256: Self.sha256(Data(external.utf8)),
                reciprocalHitSummary: prepared.record.reciprocalHitSummary,
                selectedEvidence: prepared.record.selectedEvidence,
                selectedAlignmentIsReverse: prepared.record.selectedAlignmentIsReverse
            )
        }
        let duplicateUnnameableExternalIDs = Dictionary(
            grouping: unnameable.compactMap(\.fastaRecordID),
            by: { $0 }
        ).filter { $0.value.count > 1 }.keys.sorted()
        guard duplicateUnnameableExternalIDs.isEmpty else {
            throw FullLengthONTMHCCandidateArtifactWriterError(
                "Multiple un-nameable MHC clusters resolve to the same external UTR-trimmed sequence: "
                    + duplicateUnnameableExternalIDs.joined(separator: ", ")
                    + ". Publication is blocked until their raw-source ownership can be represented without conflation."
            )
        }
        let unnameableExternalSequences = Dictionary(uniqueKeysWithValues: zip(
            unnameable,
            preparedUnnameable
        ).compactMap { record, prepared -> (String, String)? in
            guard let id = record.fastaRecordID,
                  let sequence = prepared.canonicalization.externalSequence else { return nil }
            return (id, Self.normalizedSequence(sequence))
        })
        let canonicalizationInputDescriptors = [
            canonicalDescriptor, referenceDescriptor, reciprocalViewDescriptor,
            reciprocalBAMDescriptor, reciprocalBAIDescriptor,
        ] + annotationInputDescriptors
        let canonicalizationCompletedAt = Date()
        let canonicalizationResolvedOptions = Self.canonicalizationResolvedOptions(
            thresholds: request.thresholds,
            rawCandidateCount: rawCandidates.count,
            canonicalCandidateCount: candidates.count,
            rawUnnameableCount: rawUnnameable.count,
            externalUnnameableCount: unnameableExternalSequences.count
        )
        transformations.append(.init(
            workflowName: "lungfish-in-process:canonicalize-and-aggregate-mhc-candidates",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "canonicalize-and-aggregate-mhc-candidates",
                "--observation-merge-key", "canonical-stable-cluster-id,sample-id,read-group-id",
            ] + canonicalizationInputDescriptors.flatMap { ["--input", $0.path] },
            resolvedOptions: canonicalizationResolvedOptions.merging([
                "provenanceOutputException": "typed in-memory canonical candidates and external-ready unnameable records are consumed by artifact render steps",
            ]) { _, value in value },
            inputs: canonicalizationInputDescriptors,
            outputs: [],
            exitStatus: 0,
            startedAt: canonicalizationStartedAt,
            completedAt: canonicalizationCompletedAt,
            wallTime: canonicalizationCompletedAt.timeIntervalSince(canonicalizationStartedAt)
        ))
        let candidateFASTAURL = stagedRootURL.appendingPathComponent("candidate_alleles.fasta")
        let unnameableFASTAURL = stagedRootURL.appendingPathComponent("unnameable_unmatched_clusters.fasta")
        let candidateFASTAStartedAt = Date()
        try writeFASTA(candidates.map {
            ($0.stableClusterID, canonicalSequenceByID[$0.stableClusterID]!)
        }, to: candidateFASTAURL)
        let candidateFASTADescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: candidateFASTAURL, role: .sourceClusterFASTA, phase: .staging
        )
        let candidateFASTACompletedAt = Date()
        transformations.append(Self.renderTransformation(
            name: "render-mhc-candidate-fasta",
            inputs: canonicalizationInputDescriptors,
            output: candidateFASTADescriptor,
            recordCount: candidates.count,
            additionalResolvedOptions: canonicalizationResolvedOptions,
            startedAt: candidateFASTAStartedAt,
            completedAt: candidateFASTACompletedAt
        ))
        let unnameableFASTAStartedAt = Date()
        let unnameableFASTARecords = unnameable.compactMap { record -> (String, String)? in
            guard let id = record.fastaRecordID,
                  let sequence = unnameableExternalSequences[id] else { return nil }
            return (id, sequence)
        }
        try writeFASTA(unnameableFASTARecords, to: unnameableFASTAURL)
        let unnameableFASTADescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: unnameableFASTAURL, role: .sourceClusterFASTA, phase: .staging
        )
        let unnameableFASTACompletedAt = Date()
        transformations.append(Self.renderTransformation(
            name: "render-mhc-unnameable-fasta",
            inputs: canonicalizationInputDescriptors,
            output: unnameableFASTADescriptor,
            recordCount: unnameableFASTARecords.count,
            additionalResolvedOptions: canonicalizationResolvedOptions,
            startedAt: unnameableFASTAStartedAt,
            completedAt: unnameableFASTACompletedAt
        ))

        let internalDirectoryURL = stagedRootURL.appendingPathComponent(
            "artifacts/internal",
            isDirectory: true
        )
        try fileManager.createDirectory(at: internalDirectoryURL, withIntermediateDirectories: true)
        let sourceMapURL = internalDirectoryURL.appendingPathComponent(
            "mhc-candidate-source-map.json"
        )
        let sourceIdentityStartedAt = Date()
        let rawInternalFASTAReference = try artifactReference(
            request.rawUnmatchedConsensusesFASTAURL,
            finalRelativePath: "artifacts/internal/raw-unmatched-consensuses.fasta"
        )
        let canonicalCandidateByRawID = Dictionary(uniqueKeysWithValues: canonicalCandidates.flatMap {
            output in output.rawInputs.map { ($0.record.stableClusterID, output) }
        })
        let classificationByRawID = Dictionary(uniqueKeysWithValues: zip(
            clusters,
            classifications
        ).map { cluster, result -> (String, String) in
            let classification: String
            switch result {
            case .known:
                classification = "known"
            case .candidate(let record):
                classification = record.classification.rawValue
            case .unnameable:
                classification = "unnameable"
            }
            return (cluster.stableClusterID, classification)
        })
        let unnameablePreparedByRawID = Dictionary(uniqueKeysWithValues: zip(
            unnameable,
            preparedUnnameable
        ).map { ($0.stableClusterID, ($0, $1.canonicalization)) })
        let sourceIdentityRecords = grouped.map { group -> ONTMHCCandidateSourceIdentityRecord in
            if let candidate = canonicalCandidateByRawID[group.id],
               let rawInput = candidate.rawInputs.first(where: {
                   $0.record.stableClusterID == group.id
               }) {
                return .init(
                    rawStableClusterID: group.id,
                    rawSequenceSHA256: Self.sha256(Data(group.sequence.utf8)),
                    rawSequenceLength: group.sequence.count,
                    canonicalStableClusterID: candidate.record.stableClusterID,
                    canonicalSequenceSHA256: candidate.record.sequenceSHA256,
                    trimStart: rawInput.canonicalization.trimRange?.lowerBound,
                    trimEnd: rawInput.canonicalization.trimRange?.upperBound,
                    referenceReadiness: rawInput.canonicalization.referenceReadiness.rawValue,
                    classification: classificationByRawID[group.id] ?? "unavailable",
                    sampleIDs: Set(group.observations.map(\.sampleID)).sorted(),
                    isRepresentative:
                        candidate.record.representativeSourceSequenceClusterID == group.id
                )
            }
            let prepared = unnameablePreparedByRawID[group.id]
            return .init(
                rawStableClusterID: group.id,
                rawSequenceSHA256: Self.sha256(Data(group.sequence.utf8)),
                rawSequenceLength: group.sequence.count,
                canonicalStableClusterID: prepared?.0.fastaRecordID,
                canonicalSequenceSHA256: prepared?.0.sequenceSHA256,
                trimStart: prepared?.1.trimRange?.lowerBound,
                trimEnd: prepared?.1.trimRange?.upperBound,
                referenceReadiness: prepared?.1.referenceReadiness.rawValue
                    ?? FullLengthONTMHCReferenceReadiness.unavailable.rawValue,
                classification: classificationByRawID[group.id] ?? "unavailable",
                sampleIDs: Set(group.observations.map(\.sampleID)).sorted(),
                isRepresentative: prepared != nil
            )
        }.sorted { $0.rawStableClusterID < $1.rawStableClusterID }
        let sourceIdentityDocument = ONTMHCCandidateSourceIdentityDocument(
            schemaVersion: 2,
            createdAt: rawCreatedAt,
            rawSequenceFASTA: rawInternalFASTAReference,
            records: sourceIdentityRecords
        )
        try writeCanonicalJSON(sourceIdentityDocument, to: sourceMapURL)
        let sourceMapDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: sourceMapURL,
            role: .commandOutput,
            phase: .staging
        )
        let sourceIdentityCompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:render-mhc-candidate-source-identity",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "render-mhc-candidate-source-identity",
                "--raw-fasta", request.rawUnmatchedConsensusesFASTAURL.path,
                "--source-map", sourceMapURL.path,
            ] + canonicalizationInputDescriptors.flatMap { ["--input", $0.path] },
            resolvedOptions: canonicalizationResolvedOptions.merging([
                "rawRecordCount": String(grouped.count),
            ]) { _, value in value },
            inputs: canonicalizationInputDescriptors,
            outputs: [sourceMapDescriptor],
            exitStatus: 0,
            startedAt: sourceIdentityStartedAt,
            completedAt: sourceIdentityCompletedAt,
            wallTime: sourceIdentityCompletedAt.timeIntervalSince(sourceIdentityStartedAt)
        ))

        let reciprocalBAMReference = try artifactReference(stagedBAMURL, finalRelativePath: "artifacts/alignments/unmatched-to-reference.bam")
        let reciprocalBAIReference = try artifactReference(stagedBAIURL, finalRelativePath: "artifacts/alignments/unmatched-to-reference.bam.bai")
        let candidateFASTAReference = try artifactReference(candidateFASTAURL, finalRelativePath: "candidate_alleles.fasta")
        let unnameableFASTAReference = try artifactReference(unnameableFASTAURL, finalRelativePath: "unnameable_unmatched_clusters.fasta")
        let referenceInput = try artifactReference(request.referenceAlleleFASTAURL, finalRelativePath: request.referenceAlleleFASTAURL.path)
        let stableUnmatchedInput = rawInternalFASTAReference
        let candidateObservations = canonicalCandidates.flatMap(\.observations)
            .sorted(by: Self.observationLessThan)
        let unnameableStableIDs = Set(unnameable.lazy.map(\.stableClusterID))
        let unnameableObservations = grouped.flatMap(\.observations)
            .filter { unnameableStableIDs.contains($0.stableClusterID) }
            .map {
                ONTMHCCandidateObservation(
                    stableClusterID: $0.stableClusterID,
                    sourceSequenceClusterID: $0.stableClusterID,
                    sampleID: $0.sampleID,
                    readGroupID: $0.readGroupID,
                    sourceClusterIDs: $0.sourceClusterIDs,
                    sourceClusterReadCounts: $0.sourceClusterReadCounts,
                    aggregatedSampleReadCount: $0.aggregatedSampleReadCount,
                    genotypingHitSummaries: $0.genotypingHitSummaries
                )
            }
            .sorted(by: Self.observationLessThan)
        let createdAt = Self.iso8601(Date())
        let evidence = [reciprocalBAMReference, reciprocalBAIReference]
            + (request.genotypingEvidence.map { [$0.bam, $0.bai] } ?? [])
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 4,
            createdAt: createdAt,
            thresholds: request.thresholds,
            inputs: [referenceInput, stableUnmatchedInput],
            evidence: evidence,
            sequenceFASTA: candidateFASTAReference,
            candidates: candidates,
            observations: candidateObservations
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 4,
            createdAt: createdAt,
            thresholds: request.thresholds,
            inputs: [referenceInput, stableUnmatchedInput],
            evidence: evidence,
            sequenceFASTA: unnameableFASTAReference,
            clusters: unnameable,
            observations: unnameableObservations
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
            inputs: canonicalizationInputDescriptors + [candidateFASTADescriptor],
            output: candidateJSONDescriptor,
            recordCount: candidates.count,
            additionalResolvedOptions: canonicalizationResolvedOptions.merging(
                Self.compactHitShapeResolvedOptions(
                evidence: evidence,
                reciprocalBAMPath: reciprocalBAMRelativePath
                )
            ) { _, value in value },
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
            inputs: canonicalizationInputDescriptors + [unnameableFASTADescriptor],
            output: unnameableJSONDescriptor,
            recordCount: unnameable.count,
            additionalResolvedOptions: canonicalizationResolvedOptions.merging(
                Self.compactHitShapeResolvedOptions(
                evidence: evidence,
                reciprocalBAMPath: reciprocalBAMRelativePath
                )
            ) { _, value in value },
            startedAt: unnameableJSONStartedAt,
            completedAt: unnameableJSONCompletedAt
        ))
        let candidateJSONReference = try artifactReference(candidateJSONURL, finalRelativePath: "candidate-alleles.json")
        let unnameableJSONReference = try artifactReference(unnameableJSONURL, finalRelativePath: "unnameable-unmatched-clusters.json")

        let candidateGenBankURL = stagedRootURL.appendingPathComponent("candidate_alleles.gb")
        let candidateGenBankStartedAt = Date()
        let candidateGenBankRecords = try canonicalCandidates.map {
            try canonicalGenBankRecord(
                $0.representativeCanonicalization.record,
                externalID: $0.record.stableClusterID,
                externalSequence: $0.sequence,
                rawSourceIDs: $0.record.sourceSequenceClusterIDs,
                canonicalCandidate: $0.record
            )
        }
        try GenBankWriter(url: candidateGenBankURL).write(candidateGenBankRecords)
        let candidateGenBankDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: candidateGenBankURL, role: .commandOutput, phase: .staging
        )
        let candidateGenBankCompletedAt = Date()

        let unnameableGenBankURL = stagedRootURL.appendingPathComponent("unnameable_unmatched_clusters.gb")
        let unnameableGenBankStartedAt = Date()
        let unnameableGenBankRecords = try zip(unnameable, preparedUnnameable).compactMap {
            record, prepared -> GenBankRecord? in
            guard let externalID = record.fastaRecordID,
                  let externalSequence = prepared.canonicalization.externalSequence else {
                return nil
            }
            return try canonicalGenBankRecord(
                prepared.canonicalization.record,
                externalID: externalID,
                externalSequence: externalSequence,
                rawSourceIDs: [record.stableClusterID]
            )
        }
        try GenBankWriter(url: unnameableGenBankURL).write(unnameableGenBankRecords)
        let unnameableGenBankDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: unnameableGenBankURL, role: .commandOutput, phase: .staging
        )
        let unnameableGenBankCompletedAt = Date()
        let commonGenBankResolvedOptions: [String: String] = [
            "analysisName": request.analysisName,
            "projectBundleName": request.projectBundleName ?? "unavailable",
            "recordIdentity": "external-or-canonical-FASTA-record-id;raw-stable-cluster-id-retained-in-source-metadata",
            "externalRecordGate": "emit-only-typed-externalSequence-with-reference-readiness=reference-ready;non-ready-omitted;no-untrimmed-external-fallback",
            "outerCDSTrimRule": "reference-ready-candidates+reference-ready-unnameables:crop-to-outer-lifted-CDS-span+rebase-annotations;retain-intervening-introns",
            "referenceCoordinateConvention": "zero-based-half-open",
            "reciprocalCIGARCoordinateSource": "one-based-reference-start-plus-SAM-CIGAR",
            "reverseAlignmentRule": "project-oriented-query-then-convert-to-stored-candidate-coordinates",
            "minimumIntronGapBases": String(request.thresholds.minimumIntronGapBases),
            "supportMetadata": "all-supporting-samples-independent-count-occurrence-count-total-cluster-reads",
        ]
        let candidateGenBankResolvedOptions = commonGenBankResolvedOptions.merging([
            "translationRule": "recomputed-from-lifted-candidate-CDS;translation-table-1-only;unsupported-omitted+unresolved;terminal-stop-removed;internal-stops-retained-and-counted",
            "consequenceChangeSource": "selected-closest-reference-sequence+one-based-reference-start+reciprocal-CIGAR+candidate-sequence;no-BAM-reread",
            "consequenceCoordinateConvention": "one-based-reference+stored-candidate-ORIGIN+CDS+codon+exon+intron+amino-acid;outside-crop-reference-only",
            "codingConsequenceRule": "transcript-strand+codon-start+translation-table;group-same-codon-substitutions;scope-unresolved-to-intersecting-exon-summary;group-touching-replacement-indels-by-reference-span;ordinary-indels-frame-delta",
            "cDNAIntronFillRule": "internal-query-insertion-at-least-minimum-intron-gap;excluded-from-cDNA-lifted-CDS+CDS-indels;genomic-long-insertions-retained;source-CDS-complete-assessment-includes-deletions",
            "consequenceAmbiguityRule": "partial+unsupported+ambiguous+unassessed-CDS=unresolved-never-coerced",
            "candidateUTRTrimRule": "reference-ready-only:crop-to-outer-lifted-CDS-span-in-stored-orientation;retain-intervening-introns;rebase-annotations+consequence-candidate-coordinates;non-ready-omitted",
        ]) { _, candidate in candidate }
        let unnameableGenBankResolvedOptions = commonGenBankResolvedOptions.merging([
            "translationRule": "unnameable-only:recomputed-from-lifted-CDS-when-five-prime-boundary-is-aligned;source-translation-table-not-gated;terminal-stop-removed;internal-stops-retained-and-counted;status-uses-boundary-coverage",
            "unnameableSequenceRule": "reference-ready+paired-external-FASTA-id+sequence-SHA-256-only:crop-to-outer-lifted-CDS-span-in-stored-orientation;retain-intervening-introns;rebase-annotations;otherwise-omit",
            "unnameableFeatureLiftoverRule": "project-gene+mRNA+transcript+exon+CDS+UTR;omit-reference-introns;exclude-query-insertions-at-least-minimum-intron-gap-from-lifted-features",
            "unnameableConsequenceRule": "do-not-render-candidate-nucleotide-or-protein-consequence-COMMENT-summaries",
        ]) { _, unnameable in unnameable }
        transformations.append(Self.renderTransformation(
            name: "render-mhc-candidate-genbank",
            inputs: [candidateJSONDescriptor, candidateFASTADescriptor] + annotationInputDescriptors,
            output: candidateGenBankDescriptor,
            recordCount: candidateGenBankRecords.count,
            additionalResolvedOptions: candidateGenBankResolvedOptions,
            startedAt: candidateGenBankStartedAt,
            completedAt: candidateGenBankCompletedAt
        ))
        transformations.append(Self.renderTransformation(
            name: "render-mhc-unnameable-genbank",
            inputs: [unnameableJSONDescriptor, unnameableFASTADescriptor] + annotationInputDescriptors,
            output: unnameableGenBankDescriptor,
            recordCount: unnameableGenBankRecords.count,
            additionalResolvedOptions: unnameableGenBankResolvedOptions,
            startedAt: unnameableGenBankStartedAt,
            completedAt: unnameableGenBankCompletedAt
        ))
        let candidateGenBankReference = try artifactReference(
            candidateGenBankURL,
            finalRelativePath: "candidate_alleles.gb"
        )
        let unnameableGenBankReference = try artifactReference(
            unnameableGenBankURL,
            finalRelativePath: "unnameable_unmatched_clusters.gb"
        )

        try Task.checkCancellation()
        try safety.revalidatePathContext(pathContext)
        var stagedPublicationDescriptors = [
            try FullLengthONTMHCArtifactDescriptor(url: stagedBAMURL, role: .evidenceBAM, phase: .staging),
            try FullLengthONTMHCArtifactDescriptor(url: stagedBAIURL, role: .evidenceBAI, phase: .staging),
            candidateFASTADescriptor,
            candidateJSONDescriptor,
            candidateGenBankDescriptor,
            unnameableFASTADescriptor,
            unnameableJSONDescriptor,
            unnameableGenBankDescriptor,
            sourceMapDescriptor,
        ]
        let canonicalDedupStartedAt = Date()
        try Data(contentsOf: candidateFASTAURL).write(
            to: stagedStableFASTAURL,
            options: .atomic
        )
        let canonicalDedupDescriptor = try FullLengthONTMHCArtifactDescriptor(
            url: stagedStableFASTAURL,
            role: .sourceClusterFASTA,
            phase: .staging
        )
        let canonicalDedupCompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:publish-canonical-deduplicated-unmatched-fasta",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "publish-canonical-deduplicated-unmatched-fasta",
                "--input", candidateFASTAURL.path,
                "--output", stagedStableFASTAURL.path,
            ],
            resolvedOptions: [
                "sequenceBoundary": "UTR-trimmed-reference-ready-candidates-only",
                "recordIdentity": "exact-trimmed-sequence-SHA256-derived-stable-id",
                "replacementScope": "private-staging-generation-before-fresh-publication",
            ],
            inputs: [candidateFASTADescriptor],
            outputs: [canonicalDedupDescriptor],
            exitStatus: 0,
            startedAt: canonicalDedupStartedAt,
            completedAt: canonicalDedupCompletedAt,
            wallTime: canonicalDedupCompletedAt.timeIntervalSince(canonicalDedupStartedAt)
        ))
        stagedPublicationDescriptors.append(canonicalDedupDescriptor)
        let materializationStartedAt = Date()
        try materializeStagingGeneration(
            stagedRootURL: stagedRootURL,
            outputDirectoryURL: request.outputDirectoryURL,
            relativePaths: [
                "artifacts/alignments/unmatched-to-reference.bam",
                "artifacts/alignments/unmatched-to-reference.bam.bai",
                "deduplicated_unmatched_clusters.fasta",
                "candidate_alleles.fasta", "candidate-alleles.json",
                "candidate_alleles.gb",
                "unnameable_unmatched_clusters.fasta", "unnameable-unmatched-clusters.json",
                "unnameable_unmatched_clusters.gb",
                "artifacts/internal/mhc-candidate-source-map.json",
            ]
        )
        let materializationCompletedAt = Date()
        let finalPublicationURLs: [(URL, FullLengthONTMHCArtifactRole)] = [
            (finalBAMURL, .evidenceBAM),
            (finalBAIURL, .evidenceBAI),
            (canonicalUnmatchedFASTAURL, .sourceClusterFASTA),
            (request.outputDirectoryURL.appendingPathComponent("candidate_alleles.fasta"), .sourceClusterFASTA),
            (request.outputDirectoryURL.appendingPathComponent("candidate-alleles.json"), .commandOutput),
            (request.outputDirectoryURL.appendingPathComponent("candidate_alleles.gb"), .commandOutput),
            (request.outputDirectoryURL.appendingPathComponent("unnameable_unmatched_clusters.fasta"), .sourceClusterFASTA),
            (request.outputDirectoryURL.appendingPathComponent("unnameable-unmatched-clusters.json"), .commandOutput),
            (request.outputDirectoryURL.appendingPathComponent("unnameable_unmatched_clusters.gb"), .commandOutput),
            (request.outputDirectoryURL.appendingPathComponent("artifacts/internal/mhc-candidate-source-map.json"), .commandOutput),
        ]
        let checksumStartedAt = Date()
        let finalPublicationDescriptors = try finalPublicationURLs.map {
            try artifactDescriptorProvider.descriptor(for: $0.0, role: $0.1, phase: .staging)
        }
        let checksumCompletedAt = Date()
        transformations.append(.init(
            workflowName: "lungfish-in-process:materialize-mhc-candidate-staging-generation",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "materialize-mhc-candidate-staging-generation",
                stagedRootURL.path,
                request.outputDirectoryURL.path,
            ],
            resolvedOptions: [
                "destinationState": "fresh-caller-owned-unpublished-staging-directory",
                "replacementAllowed": "false",
                "preflightRule": "validate-all-destinations-before-moving-any-file",
            ],
            inputs: stagedPublicationDescriptors,
            outputs: finalPublicationDescriptors,
            exitStatus: 0,
            startedAt: materializationStartedAt,
            completedAt: materializationCompletedAt,
            wallTime: materializationCompletedAt.timeIntervalSince(materializationStartedAt)
        ))
        transformations.append(.init(
            workflowName: "lungfish-in-process:capture-mhc-candidate-artifact-checksums",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: ["lungfish-in-process", "capture-mhc-candidate-artifact-checksums", "--algorithm", "sha256"],
            resolvedOptions: [
                "algorithm": "SHA-256",
                "artifactCount": String(finalPublicationDescriptors.count),
                "provenanceOutputException": "checksums are embedded in the candidate artifact manifest consumed by result-bundle publication",
            ],
            inputs: finalPublicationDescriptors,
            outputs: [],
            exitStatus: 0,
            startedAt: checksumStartedAt,
            completedAt: checksumCompletedAt,
            wallTime: checksumCompletedAt.timeIntervalSince(checksumStartedAt)
        ))
        let manifest = ONTMHCCandidateArtifactManifest(
            schemaVersion: 2,
            genotypingEvidence: request.genotypingEvidence,
            reciprocalEvidence: .init(bam: reciprocalBAMReference, bai: reciprocalBAIReference),
            candidateJSON: candidateJSONReference,
            candidateFASTA: candidateFASTAReference,
            candidateGenBank: candidateGenBankReference,
            unnameableJSON: unnameableJSONReference,
            unnameableFASTA: unnameableFASTAReference,
            unnameableGenBank: unnameableGenBankReference,
            rawUnmatchedFASTA: rawInternalFASTAReference,
            sourceIdentityMap: try artifactReference(
                request.outputDirectoryURL.appendingPathComponent(
                    "artifacts/internal/mhc-candidate-source-map.json"
                ),
                finalRelativePath: "artifacts/internal/mhc-candidate-source-map.json"
            )
        )
        return FullLengthONTMHCCandidateArtifactResult(
            stableUnmatchedFASTAURL: canonicalUnmatchedFASTAURL,
            reciprocalBAMURL: finalBAMURL,
            reciprocalBAIURL: finalBAIURL,
            candidateFASTAURL: request.outputDirectoryURL.appendingPathComponent("candidate_alleles.fasta"),
            candidateJSONURL: request.outputDirectoryURL.appendingPathComponent("candidate-alleles.json"),
            candidateGenBankURL: request.outputDirectoryURL.appendingPathComponent("candidate_alleles.gb"),
            unnameableFASTAURL: request.outputDirectoryURL.appendingPathComponent("unnameable_unmatched_clusters.fasta"),
            unnameableJSONURL: request.outputDirectoryURL.appendingPathComponent("unnameable-unmatched-clusters.json"),
            unnameableGenBankURL: request.outputDirectoryURL.appendingPathComponent("unnameable_unmatched_clusters.gb"),
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

    struct CanonicalUnmatchedRecord {
        let stableID: String
        let sequence: String
    }

    static let maximumCanonicalFASTALineBytes = 1_048_576
    static let maximumCanonicalSequenceBases = 100_000_000
    static let maximumCanonicalRecordCount = 1_000_000

    static func normalizedSequence(_ sequence: String) -> String {
        sequence.filter { !$0.isWhitespace }.uppercased()
    }

    func canonicalGenBankRecord(
        _ record: GenBankRecord,
        externalID: String,
        externalSequence: String,
        rawSourceIDs: [String],
        canonicalCandidate: ONTMHCCandidateRecord? = nil
    ) throws -> GenBankRecord {
        var annotations = record.annotations
        let sequence = Self.normalizedSequence(externalSequence)
        let sequenceSHA256 = Self.sha256(Data(sequence.utf8))
        if let sourceIndex = annotations.firstIndex(where: { $0.type == .source }) {
            annotations[sourceIndex].qualifiers["stable_cluster_id"] = .init(
                canonicalCandidate?.stableClusterID ?? rawSourceIDs.first ?? externalID
            )
            annotations[sourceIndex].qualifiers["fasta_record_id"] = .init(externalID)
            annotations[sourceIndex].qualifiers["source_sequence_cluster_ids"] = .init(
                rawSourceIDs.sorted()
            )
            annotations[sourceIndex].qualifiers["sequence_sha256"] = .init(sequenceSHA256)
            annotations[sourceIndex].qualifiers["genbank_sequence_sha256"] = .init(
                sequenceSHA256
            )
            if let candidate = canonicalCandidate {
                annotations[sourceIndex].qualifiers[
                    "representative_source_sequence_cluster_id"
                ] = .init(candidate.representativeSourceSequenceClusterID)
                annotations[sourceIndex].qualifiers["support_class"] = .init(
                    candidate.supportClass.rawValue
                )
                annotations[sourceIndex].qualifiers["independent_sample_count"] = .init(
                    String(candidate.independentSampleCount)
                )
                annotations[sourceIndex].qualifiers["occurrence_count"] = .init(
                    String(candidate.occurrenceCount)
                )
                annotations[sourceIndex].qualifiers["total_cluster_reads"] = .init(
                    String(candidate.totalClusterReads)
                )
                annotations[sourceIndex].qualifiers["supporting_sample_ids"] = .init(
                    candidate.supportingSampleIDs.sorted()
                )
                annotations[sourceIndex].qualifiers["provisional_name"] = .init(
                    candidate.provisionalName
                )
                annotations[sourceIndex].qualifiers["classification"] = .init(
                    candidate.classification.rawValue
                )
                annotations[sourceIndex].qualifiers["original_sequence_length"] = .init(
                    String(sequence.count)
                )
                annotations[sourceIndex].qualifiers["trim_start"] = .init("1")
                annotations[sourceIndex].qualifiers["trim_end"] = .init(
                    String(sequence.count)
                )
            }
        }
        var recordFields = record.recordFields
        if let candidate = canonicalCandidate {
            let canonicalCommentPrefixes = [
                "Lungfish stable cluster ID:",
                "Lungfish sequence SHA-256:",
                "Lungfish support:",
                "Lungfish supporting samples:",
                "Lungfish source sequence cluster IDs:",
                "Lungfish representative source sequence cluster ID:",
                "Lungfish candidate sequence trim:",
                "Lungfish GenBank sequence SHA-256:",
            ]
            recordFields.removeAll { field in
                field.key == "COMMENT"
                    && canonicalCommentPrefixes.contains { field.value.hasPrefix($0) }
            }
            let canonicalComments = [
                "Lungfish stable cluster ID: \(candidate.stableClusterID)",
                "Lungfish sequence SHA-256: \(sequenceSHA256)",
                "Lungfish support: \(candidate.supportClass.rawValue); independent samples=\(candidate.independentSampleCount); occurrences=\(candidate.occurrenceCount); reads=\(candidate.totalClusterReads)",
                "Lungfish supporting samples: \(candidate.supportingSampleIDs.sorted().joined(separator: ", "))",
                "Lungfish source sequence cluster IDs: \(candidate.sourceSequenceClusterIDs.sorted().joined(separator: ", "))",
                "Lungfish representative source sequence cluster ID: \(candidate.representativeSourceSequenceClusterID)",
                "Lungfish candidate sequence trim: canonical UTR-trimmed genomic sequence; original length=\(sequence.count); trim start=1; trim end=\(sequence.count); retained length=\(sequence.count)",
                "Lungfish GenBank sequence SHA-256: \(sequenceSHA256)",
            ]
            let nextOrdinal = (recordFields.map(\.ordinal).max() ?? -1) + 1
            recordFields.append(contentsOf: canonicalComments.enumerated().map {
                GenBankRecordField(
                    key: "COMMENT",
                    value: $0.element,
                    ordinal: nextOrdinal + $0.offset
                )
            })
        }
        return GenBankRecord(
            sequence: try Sequence(
                name: externalID,
                description: record.sequence.description,
                alphabet: .dna,
                bases: sequence
            ),
            annotations: annotations,
            locus: LocusInfo(
                name: externalID,
                length: sequence.count,
                moleculeType: .dna,
                topology: .linear
            ),
            definition: record.definition,
            accession: externalID,
            version: nil,
            recordFields: recordFields
        )
    }

    func canonicalUnmatchedRecords(_ url: URL) throws -> [CanonicalUnmatchedRecord] {
        var records: [CanonicalUnmatchedRecord] = []
        var stableIDs = Set<String>()
        var currentHeader: String?
        var currentSequence = ""
        var lineNumber = 0

        func finishRecord() throws {
            guard let header = currentHeader else { return }
            let sequence = Self.normalizedSequence(currentSequence)
            guard !sequence.isEmpty,
                  sequence.allSatisfy({ "ACGTRYSWKMBDHVN".contains($0) }) else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA record '\(header)' has an invalid nucleotide sequence."
                )
            }
            let firstToken = header.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let claimedStableID = firstToken.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            let derivedStableID = Self.stableClusterID(for: sequence)
            guard claimedStableID == derivedStableID else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA header stable ID does not match normalized sequence: \(claimedStableID)."
                )
            }
            guard stableIDs.insert(derivedStableID).inserted else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA contains duplicate stable cluster '\(derivedStableID)'."
                )
            }
            guard records.count < Self.maximumCanonicalRecordCount else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA exceeds \(Self.maximumCanonicalRecordCount) records."
                )
            }
            records.append(.init(stableID: derivedStableID, sequence: sequence))
            currentHeader = nil
            currentSequence = ""
        }

        try url.forEachLineAutoDecompressing { line in
            try Task.checkCancellation()
            lineNumber += 1
            guard line.utf8.count <= Self.maximumCanonicalFASTALineBytes else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA line \(lineNumber) exceeds \(Self.maximumCanonicalFASTALineBytes) bytes."
                )
            }
            if line.hasPrefix(">") {
                try finishRecord()
                let header = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !header.isEmpty else {
                    throw FullLengthONTMHCCandidateArtifactWriterError(
                        "Canonical deduplicated unmatched FASTA has an empty header at line \(lineNumber)."
                    )
                }
                currentHeader = header
                return
            }
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard currentHeader != nil else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA has sequence before its first header at line \(lineNumber)."
                )
            }
            guard currentSequence.utf8.count <= Self.maximumCanonicalSequenceBases - line.utf8.count else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA sequence exceeds \(Self.maximumCanonicalSequenceBases) bases."
                )
            }
            currentSequence += line
        }
        try finishRecord()
        return records
    }

    func bindCanonicalRecords(
        _ canonicalRecords: [CanonicalUnmatchedRecord],
        to observationGroups: [Group]
    ) throws -> [Group] {
        let observationsByID = Dictionary(uniqueKeysWithValues: observationGroups.map { ($0.id, $0) })
        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalRecords.map { ($0.stableID, $0) })
        let observationIDs = Set(observationsByID.keys)
        let canonicalIDs = Set(canonicalByID.keys)
        if let missing = observationIDs.subtracting(canonicalIDs).sorted().first {
            throw FullLengthONTMHCCandidateArtifactWriterError(
                "Canonical deduplicated unmatched FASTA is missing stable cluster '\(missing)' from consolidated observations."
            )
        }
        if let extra = canonicalIDs.subtracting(observationIDs).sorted().first {
            throw FullLengthONTMHCCandidateArtifactWriterError(
                "Canonical deduplicated unmatched FASTA contains extra stable cluster '\(extra)' absent from consolidated observations."
            )
        }
        return try canonicalRecords.map { canonical in
            guard let observed = observationsByID[canonical.stableID],
                  observed.sequence == canonical.sequence else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Canonical deduplicated unmatched FASTA sequence differs from consolidated observations for stable cluster '\(canonical.stableID)'."
                )
            }
            return Group(
                id: canonical.stableID,
                sequence: canonical.sequence,
                observations: observed.observations
            )
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
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
            "zeroSNPClassificationOrder": "1:eligible-genomic-zero-snp=known;2:eligible-cdna-zero-snp-structural-extension=extension;3:eligible-cdna-zero-snp-end-to-end=known;4:otherwise=candidate",
            "extensionRule": "cdna-coverage>=0.95;each-cdna-deficit<20;no-hard-clip;cluster-flank-or-structural-segment>=20",
            "knownCDNARule": "extension-eligibility;cluster-coverage>=0.95;each-cluster-structural-segment<20",
            "cDNACoverageNumerator": "comparable-query-reference-bases-excluding-cdna-deficit-operations",
            "minimumCDNAReferenceCoverage": "0.95",
            "minimumCDNAClusterCoverage": "0.95",
            "meaningfulCDNAStructuralSegmentBases": "20-per-side-or-cigar-operation",
            "cDNAHardClipPolicy": "ineligible",
            "cohortCDNAOrientation": "query=reference-cdna,target=cluster;cluster-structure=target-flanks+D+N;cdna-deficit=I+S+H",
            "reciprocalCDNAOrientation": "query=cluster,target=reference-cdna;cluster-structure=I+S;cdna-deficit=reference-flanks+D+N+H",
            "allCompatibleReferenceRule": "secondary=yes;-N=reference-record-count;no-fixed-secondary-cap",
        ]
    }

    static func canonicalizationResolvedOptions(
        thresholds: ONTMHCCandidateThresholds,
        rawCandidateCount: Int,
        canonicalCandidateCount: Int,
        rawUnnameableCount: Int,
        externalUnnameableCount: Int
    ) -> [String: String] {
        candidateResolvedOptions(thresholds).merging([
            "rawIdentity": "exact-normalized-full-consensus-sequence",
            "canonicalIdentity": "exact-normalized-UTR-trimmed-genomic-sequence",
            "canonicalStableID": "first-128-bits-SHA256-with-UUID-version-and-variant-bits",
            "outerCDSTrimRule": "reference-ready-only:outer-lifted-CDS-span;retain-intervening-introns",
            "referenceReadinessRule": "external-artifacts-require-reference-ready-canonicalization",
            "candidateMergeFields": "classification,locus,provisional-name,closest-reference-name,closest-reference-raw-id,closest-reference-class,extension-of,provisional-naming-ambiguous",
            "representativeRule": "highest-total-cluster-reads;then-lexical-raw-stable-id",
            "observationMergeKey": "canonical-stable-cluster-id,sample-id,read-group-id",
            "observationAggregationRule": "sum-read-counts;union-source-cluster-ids-and-counts;deduplicate-compact-hit-shapes",
            "rawCandidateCount": String(rawCandidateCount),
            "canonicalCandidateCount": String(canonicalCandidateCount),
            "rawUnnameableCount": String(rawUnnameableCount),
            "externalUnnameableCount": String(externalUnnameableCount),
        ]) { _, value in value }
    }

    static func compactHitShapeResolvedOptions(
        evidence: [ONTMHCArtifactReference],
        reciprocalBAMPath: String
    ) -> [String: String] {
        let evidenceArtifacts = evidence.map {
            "\($0.path)|sha256=\($0.sha256)|size-bytes=\($0.sizeBytes)"
        }.sorted().joined(separator: ";")
        return [
            "documentSchemaVersion": "4",
            "evidenceArtifacts": evidenceArtifacts,
            "reciprocalBAMPath": reciprocalBAMPath,
            "reciprocalLocatorIdentity": "bam-path,query-name,reference-name,read-group-id,reference-start,cigar",
            "reciprocalAlignmentCountRule": "unique-locator-count-equals-sum-of-target-alignment-counts",
            "reciprocalExactRelationshipRule": "eligible-zero-SNP",
            "reciprocalClosestRelationshipRule": "all-targets-tied-at-classifier-biological-rank-before-lexical-tiebreak",
            "selectedEvidenceRule": "classifier-selected-target-must-occur-in-closest-match-target-names",
            "perAlignmentLocatorArrays": "omitted",
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
        additionalResolvedOptions: [String: String] = [:],
        startedAt: Date,
        completedAt: Date
    ) -> FullLengthONTMHCInProcessTransformationRecord {
        let inputArguments = inputs.flatMap { ["--input", $0.path] }
        return FullLengthONTMHCInProcessTransformationRecord(
            workflowName: "lungfish-in-process:\(name)",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", name,
                "--canonical-order", "stable-cluster-id",
                "--record-count", String(recordCount),
            ] + inputArguments + ["--output", output.path],
            resolvedOptions: [
                "canonicalOrder": "stable-cluster-id",
                "recordCount": String(recordCount),
                "newline": "LF",
            ].merging(additionalResolvedOptions) { _, additional in additional },
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
        return try bySequence.map { sequence, keys in
            let id = Self.stableClusterID(for: sequence)
            let observations = try keys.map { key -> ONTMHCCandidateObservation in
                let values = buckets[key]!.sorted { $0.sourceClusterID.localizedStandardCompare($1.sourceClusterID) == .orderedAscending }
                var counts: [String: Int] = [:]
                var summaries: [ONTMHCGenotypingTargetHitSummary] = []
                for value in values {
                    counts[value.sourceClusterID, default: 0] += value.clusterReadCount
                    summaries.append(contentsOf: value.genotypingHitSummaries)
                }
                let sources = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let sortedSummaries = summaries.sorted {
                    if $0.targetName != $1.targetName {
                        return $0.targetName.localizedStandardCompare($1.targetName) == .orderedAscending
                    }
                    return $0.bamPath.localizedStandardCompare($1.bamPath) == .orderedAscending
                }
                let uniqueSummaries = sortedSummaries.enumerated().compactMap { index, summary in
                    index == 0 || sortedSummaries[index - 1] != summary ? summary : nil
                }
                guard Set(uniqueSummaries.map(\.targetName)).count == uniqueSummaries.count else {
                    throw FullLengthONTMHCCandidateArtifactWriterError(
                        "Grouped unmatched observation for sample '\(key.sampleID)' contains duplicate genotyping target summaries."
                    )
                }
                let expectedTargets = Set(sources.map { "\(key.sampleID)|\($0)" })
                guard Set(uniqueSummaries.map(\.targetName)).isSubset(of: expectedTargets) else {
                    throw FullLengthONTMHCCandidateArtifactWriterError(
                        "Grouped unmatched observation for sample '\(key.sampleID)' contains a genotyping target outside its source clusters."
                    )
                }
                return ONTMHCCandidateObservation(
                    stableClusterID: id,
                    sampleID: key.sampleID,
                    readGroupID: key.readGroupID,
                    sourceClusterIDs: sources,
                    sourceClusterReadCounts: counts,
                    aggregatedSampleReadCount: counts.values.reduce(0, +),
                    genotypingHitSummaries: uniqueSummaries
                )
            }.sorted(by: Self.observationLessThan)
            return Group(id: id, sequence: sequence, observations: observations)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
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

    var stagedRelativePaths: [String] {
        [
            "artifacts/alignments/unmatched-to-reference.bam",
            "artifacts/alignments/unmatched-to-reference.bam.bai",
            "artifacts/internal/mhc-candidate-source-map.json",
            "deduplicated_unmatched_clusters.fasta",
            "candidate_alleles.fasta",
            "candidate-alleles.json",
            "candidate_alleles.gb",
            "unnameable_unmatched_clusters.fasta",
            "unnameable-unmatched-clusters.json",
            "unnameable_unmatched_clusters.gb",
        ]
    }

    func requireFreshStagingTargets(in outputDirectoryURL: URL) throws {
        let existing = stagedRelativePaths.filter { relative in
            fileManager.fileExists(atPath: outputDirectoryURL.appendingPathComponent(relative).path)
        }
        guard existing.isEmpty else {
            throw FullLengthONTMHCCandidateArtifactWriterError(
                "Candidate artifacts require a fresh caller-owned staging directory; existing targets: \(existing.joined(separator: ", "))."
            )
        }
    }

    func materializeStagingGeneration(
        stagedRootURL: URL,
        outputDirectoryURL: URL,
        relativePaths: [String]
    ) throws {
        for relative in relativePaths {
            try Task.checkCancellation()
            let destination = outputDirectoryURL.appendingPathComponent(relative)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw FullLengthONTMHCCandidateArtifactWriterError(
                    "Candidate artifacts require a fresh caller-owned staging directory; target appeared during generation: \(relative)."
                )
            }
        }
        for relative in relativePaths {
            try Task.checkCancellation()
            let staged = stagedRootURL.appendingPathComponent(relative)
            let destination = outputDirectoryURL.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: staged, to: destination)
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
        return ONTMHCArtifactReference(
            path: finalRelativePath,
            sha256: try ProvenanceFileHasher.sha256(of: url) {
                try Task.checkCancellation()
            },
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
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

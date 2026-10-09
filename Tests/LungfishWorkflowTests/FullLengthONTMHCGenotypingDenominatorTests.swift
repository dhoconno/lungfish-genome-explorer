import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Note N7 of the Phase 2.3 bioinformatics review (lane N7). The full-length
/// ONT pipeline infers its own haplotype analysis from a result it loads
/// through a manifest that names no candidate artifacts, so its locus
/// denominators held known alleles only. Every re-inference of the published
/// bundle, the GUI's live analysis and the CLI exports alike, loads the whole
/// bundle and divides by known alleles plus candidate clusters at the locus,
/// as GenotypeLocusDenominator documents. Wherever a candidate cluster sat at
/// a haplotyped locus, an allele near the locus percent threshold was kept by
/// the run and dropped by re-inference. The owner ruled on 2026-10-09 that new
/// runs use the documented denominator and that existing bundles keep their
/// workbooks.
///
/// The fixture writes the candidate artifacts the way the candidate artifact
/// writer publishes them, candidate schema 5 and manifest schema 2 with both
/// evidence pairs, and the analysis step decodes the written files the way
/// `run` does.
final class FullLengthONTMHCGenotypingDenominatorTests: XCTestCase {
    /// One sample carries 150 reads of A_marker, 2 of B_marker and 3 of
    /// C_marker at MHC-A. M-A needs A_marker and C_marker, M-B needs B_marker.
    /// At the same locus sit a 25-read candidate cluster and a 30-read
    /// un-nameable cluster whose incomplete reference span was interpreted, and
    /// the sample also has a 100-read un-nameable cluster that aligned nowhere
    /// and carries no interpretation. The documented denominator is the 155
    /// known reads plus the 25 and the 30, so 210. Against the 155 known reads
    /// alone B_marker is 1.29 percent and survives the run's 1 percent
    /// threshold, which calls M-A and M-B. Against 210 it is 0.95 percent and
    /// drops while C_marker stays at 1.43 percent, so the sample is M-A alone.
    /// Had the uninterpreted cluster counted too, C_marker would be 0.97
    /// percent of 310 and M-A would lose its second diagnostic allele. The
    /// run's own analysis must say what the GUI and the CLI say about the
    /// published bundle.
    func testPipelineAnalysisCountsCandidateReadsAtTheLocusAsEveryReinferenceDoes() throws {
        let fixture = try makeFixture(clusterLocus: "MHC-A")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let run = try runAnalysisStep(fixture)
        try publishBundle(fixture)
        let published = try ONTGenotypeResultBundle.loadResult(from: fixture.request.outputDirectory)

        // The published bundle loads the documents the run decoded, so its
        // denominator is the documented one. The known-only denominator is
        // what the pipeline divided by before the fix. The uninterpreted
        // cluster counts on neither path.
        XCTAssertTrue(published.integrityWarnings.isEmpty, "\(published.integrityWarnings)")
        XCTAssertEqual(published.mhcCandidates, run.candidateDocument)
        XCTAssertEqual(published.mhcUnnameableClusters, run.unnameableDocument)
        XCTAssertEqual(run.unnameableDocument.clusters.count, 2)
        XCTAssertEqual(run.unnameableDocument.clusters.compactMap(\.candidateInterpretation).count, 1)
        XCTAssertEqual(GenotypeLocusDenominator(calls: published.calls).total(sample: "sample", sourceLocus: "MHC-A"), 155)
        XCTAssertEqual(GenotypeLocusDenominator(result: published).total(sample: "sample", sourceLocus: "MHC-A"), 210)
        XCTAssertEqual(
            GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: published),
            GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: 0.01)
        )

        // The CLI exports resolve the active analysis, the GUI's live analysis
        // runs the analyzer with the run evaluator and the bundle denominator.
        let cli = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: published, sidecar: nil))
        let gui = GenotypeHaplotypeAnalyzer.analyze(
            calls: published.calls, definitionSet: definition(), generatedAt: nil,
            dropoutFilter: GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: published),
            matrixReviews: [], locusDenominator: GenotypeLocusDenominator(result: published)
        )
        let reinferred = try XCTUnwrap(cli.samples.first?.calls.first)
        XCTAssertEqual([reinferred.haplotype1, reinferred.haplotype2], ["M-A", "-"])
        XCTAssertEqual(reinferred.status, .called)
        XCTAssertEqual(gui.samples, cli.samples)

        // The run's own analysis, the one its workbook and its persisted
        // haplotype-analysis.json carry, agrees with both re-inferences.
        XCTAssertEqual(published.haplotypeAnalysis, run.analysis)
        XCTAssertEqual(
            run.analysis.samples, cli.samples,
            "the run's own analysis must divide by known alleles plus candidate clusters at the locus"
        )
    }

    /// The same sample with the three clusters at MHC-B instead. The MHC-A
    /// denominator stays at the 155 known reads on every path, B_marker stays
    /// above the threshold and the run and both re-inferences call M-A and
    /// M-B. MHC-B gathers the candidate and the interpreted cluster and not the
    /// uninterpreted one. A run with no cluster at a haplotyped locus keeps its
    /// calls.
    func testClustersAtAnotherLocusLeaveTheRunCallsUnchanged() throws {
        let fixture = try makeFixture(clusterLocus: "MHC-B")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let run = try runAnalysisStep(fixture)
        try publishBundle(fixture)
        let published = try ONTGenotypeResultBundle.loadResult(from: fixture.request.outputDirectory)
        XCTAssertTrue(published.integrityWarnings.isEmpty, "\(published.integrityWarnings)")
        XCTAssertEqual(published.mhcCandidates, run.candidateDocument)
        XCTAssertEqual(published.mhcUnnameableClusters, run.unnameableDocument)
        XCTAssertEqual(GenotypeLocusDenominator(result: published).total(sample: "sample", sourceLocus: "MHC-A"), 155)
        XCTAssertEqual(GenotypeLocusDenominator(result: published).total(sample: "sample", sourceLocus: "MHC-B"), 55)

        let cli = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: published, sidecar: nil))
        let gui = GenotypeHaplotypeAnalyzer.analyze(
            calls: published.calls, definitionSet: definition(), generatedAt: nil,
            dropoutFilter: GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: published),
            matrixReviews: [], locusDenominator: GenotypeLocusDenominator(result: published)
        )
        let reinferred = try XCTUnwrap(cli.samples.first?.calls.first)
        XCTAssertEqual([reinferred.haplotype1, reinferred.haplotype2], ["M-A", "M-B"])
        XCTAssertEqual(gui.samples, cli.samples)
        XCTAssertEqual(run.analysis.samples, cli.samples)
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let request: FullLengthONTMHCGenotypingRunRequest
        /// What `candidateArtifactResult` gives `run`, the written documents
        /// and the manifest that declares them.
        let candidateJSONURL: URL
        let unnameableJSONURL: URL
        let candidateArtifacts: ONTMHCCandidateArtifactManifest
    }

    private struct RunAnalysis {
        let analysis: GenotypeHaplotypeAnalysis
        let candidateDocument: ONTMHCCandidateAllelesDocument
        let unnameableDocument: ONTMHCUnnameableClustersDocument
    }

    private static let sample = "sample"
    private static let candidateClusterID = "novel-cluster"
    private static let incompleteClusterID = "incomplete-cluster"
    private static let unalignedClusterID = "unaligned-cluster"
    private static let candidateSequence = String(repeating: "ACGTTGCA", count: 8)
    private static let incompleteSequence = String(repeating: "GGCCAATT", count: 8)
    private static let unalignedSequence = String(repeating: "TTGACCAG", count: 8)
    private static let reciprocalBAMPath = "artifacts/alignments/unmatched-to-reference.bam"
    private static let genotypingBAMPath = "artifacts/alignments/cohort-to-reference.bam"

    /// The pipeline's own analysis step as `run` reaches it. The candidate
    /// artifacts are on disk and `run` decodes the two documents from the
    /// written files with a plain JSONDecoder before it calls the step.
    private func runAnalysisStep(_ fixture: Fixture) throws -> RunAnalysis {
        let candidateDocument = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: fixture.candidateJSONURL)
        )
        let unnameableDocument = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: fixture.unnameableJSONURL)
        )
        let analysis = try XCTUnwrap(FullLengthONTMHCGenotypingPipeline().writeHaplotypeAnalysisIfRequested(
            request: fixture.request,
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            supportDirectory: fixture.request.outputDirectory.appendingPathComponent(".full-length-ont-mhc", isDirectory: true),
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        ))
        return RunAnalysis(analysis: analysis, candidateDocument: candidateDocument, unnameableDocument: unnameableDocument)
    }

    private func definition() -> GenotypeHaplotypeDefinitionSet {
        .init(id: "n7-defs", assayID: "n7-assay", displayName: "N7 definitions", speciesName: "Test species",
              speciesCode: "TST", prefix: "Test", locusDefinitions: [
                .init(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [
                    .init(name: "M-A", diagnosticAlleles: ["A_marker", "C_marker"]),
                    .init(name: "M-B", diagnosticAlleles: ["B_marker"]),
                ]),
              ])
    }

    /// A run's output directory as the pipeline leaves it before the analysis
    /// step. The reference bundle resolves the definition set, the calls and
    /// stats are on disk, the stats record the run's 1 percent locus
    /// threshold, and the candidate artifacts are written and declared with
    /// the digests the published-bundle loader verifies. The candidate cluster
    /// and the interpreted un-nameable cluster sit at `clusterLocus`.
    private func makeFixture(clusterLocus: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullLengthDenominator-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Analyses/Run/cohort.lungfishgenotype", isDirectory: true)
        let reference = project.appendingPathComponent("Reference allele databases/cohort.lungfishmhcref", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: bundle.appendingPathComponent("artifacts/alignments", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: reference.appendingPathComponent("haplotypes", isDirectory: true), withIntermediateDirectories: true)

        try JSONEncoder().encode(definition()).write(to: reference.appendingPathComponent("haplotypes/definition.json"))
        let referenceManifest = MHCAmpliconReferenceBundleManifest(
            name: "N7 reference", referenceFastaPath: "reference.fasta",
            haplotypeDefinitionPaths: ["haplotypes/definition.json"], defaultHaplotypeDefinitionID: "n7-defs",
            metrics: .init(referenceCount: 3, haplotypeDefinitionCount: 1), createdAt: "2026-10-09T00:00:00Z"
        )
        try JSONEncoder().encode(referenceManifest).write(to: MHCAmpliconReferenceBundle.manifestURL(in: reference))

        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [project.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq")],
            referenceSourceURL: reference,
            outputDirectory: bundle,
            outputName: "cohort",
            projectURL: project,
            haplotypeDropoutLocusFraction: 0.01,
            haplotypeAssayID: "n7-assay",
            haplotypeDefinitionSetID: "n7-defs"
        )

        let rows = [("A_marker", 150), ("B_marker", 2), ("C_marker", 3)].map {
            "\(Self.sample),\($0.0)|source_loci=MHC-A|haplotype_groups=MHC-A,\($0.1),\($0.1)"
        }
        try (["sample,genotype,passed_alignments,passed_unique_reads"] + rows).joined(separator: "\n")
            .appending("\n")
            .write(to: request.reportCSVURL, atomically: true, encoding: .utf8)
        try "sample,passed_alignments,passed_unique_reads\n"
            .write(to: request.sampleSummaryCSVURL, atomically: true, encoding: .utf8)
        try FullLengthONTMHCGenotypingPipeline().writeStatsJSON(request: request, sampleSummaries: [], genotypeRows: [])

        // The evidence BAM pairs and the two FASTA files, at the paths the
        // candidate artifact writer publishes, with the digests it declares.
        func artifactReference(_ relativePath: String) throws -> ONTMHCArtifactReference {
            let url = bundle.appendingPathComponent(relativePath)
            return ONTMHCArtifactReference(
                path: relativePath,
                sha256: try ProvenanceFileHasher.sha256(of: url),
                sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
            )
        }
        for (path, content) in [
            (Self.genotypingBAMPath, "cohort alignments"),
            (Self.genotypingBAMPath + ".bai", "cohort index"),
            (Self.reciprocalBAMPath, "reciprocal alignments"),
            (Self.reciprocalBAMPath + ".bai", "reciprocal index"),
            ("candidate_alleles.fasta", ">\(Self.candidateClusterID)\n\(Self.candidateSequence)\n"),
            (
                "unnameable_unmatched_clusters.fasta",
                ">\(Self.incompleteClusterID)\n\(Self.incompleteSequence)\n>\(Self.unalignedClusterID)\n\(Self.unalignedSequence)\n"
            ),
        ] {
            try Data(content.utf8).write(to: bundle.appendingPathComponent(path))
        }
        let genotypingEvidence = ONTMHCBAMArtifactPair(
            bam: try artifactReference(Self.genotypingBAMPath),
            bai: try artifactReference(Self.genotypingBAMPath + ".bai")
        )
        let reciprocalEvidence = ONTMHCBAMArtifactPair(
            bam: try artifactReference(Self.reciprocalBAMPath),
            bai: try artifactReference(Self.reciprocalBAMPath + ".bai")
        )
        let evidence = [reciprocalEvidence.bam, reciprocalEvidence.bai, genotypingEvidence.bam, genotypingEvidence.bai]
        let candidateFASTA = try artifactReference("candidate_alleles.fasta")
        let unnameableFASTA = try artifactReference("unnameable_unmatched_clusters.fasta")

        // Candidate schema 5. One novel allele at clusterLocus with 25 reads
        // of the sample.
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 5,
            createdAt: "2026-10-09T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: evidence,
            sequenceFASTA: candidateFASTA,
            candidates: [
                try candidateRecord(
                    clusterID: Self.candidateClusterID, locus: clusterLocus, reads: 25,
                    sequence: Self.candidateSequence, shorterCoverage: 1
                ),
            ],
            observations: [observation(clusterID: Self.candidateClusterID, reads: 25)]
        )
        // Two un-nameable clusters of the sample. The incomplete reference
        // span was aligned and interpreted at clusterLocus with 30 reads, so
        // it counts there. The unaligned cluster has 100 reads and no
        // interpretation, so it counts nowhere.
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 5,
            createdAt: "2026-10-09T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: evidence,
            sequenceFASTA: unnameableFASTA,
            clusters: [
                ONTMHCUnnameableRecord(
                    stableClusterID: Self.incompleteClusterID,
                    reason: .incompleteReferenceSpan,
                    failedMetrics: ["shorter_coverage": 0.62],
                    supportClass: .singleton,
                    independentSampleCount: 1,
                    occurrenceCount: 1,
                    totalClusterReads: 30,
                    supportingSampleIDs: [Self.sample],
                    fastaRecordID: Self.incompleteClusterID,
                    sequenceSHA256: Self.sha256(Self.incompleteSequence),
                    reciprocalHitSummary: try alignedReciprocalHit(clusterID: Self.incompleteClusterID),
                    selectedEvidence: reciprocalLocator(clusterID: Self.incompleteClusterID, sequence: Self.incompleteSequence),
                    candidateInterpretation: .init(candidate: try candidateRecord(
                        clusterID: Self.incompleteClusterID, locus: clusterLocus, reads: 30,
                        sequence: Self.incompleteSequence, shorterCoverage: 0.62
                    ))
                ),
                ONTMHCUnnameableRecord(
                    stableClusterID: Self.unalignedClusterID,
                    reason: .noAlignment,
                    failedMetrics: [:],
                    supportClass: .singleton,
                    independentSampleCount: 1,
                    occurrenceCount: 1,
                    totalClusterReads: 100,
                    supportingSampleIDs: [Self.sample],
                    fastaRecordID: Self.unalignedClusterID,
                    sequenceSHA256: Self.sha256(Self.unalignedSequence),
                    reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                        bamPath: Self.reciprocalBAMPath, queryName: Self.unalignedClusterID, alignmentCount: 0,
                        targetAlignmentCounts: [:], exactMatchTargetNames: [], closestMatchTargetNames: []
                    ),
                    selectedEvidence: nil
                ),
            ],
            observations: [
                observation(clusterID: Self.incompleteClusterID, reads: 30),
                observation(clusterID: Self.unalignedClusterID, reads: 100),
            ]
        )
        let documentEncoder = JSONEncoder()
        documentEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let candidateJSONURL = bundle.appendingPathComponent("candidate-alleles.json")
        let unnameableJSONURL = bundle.appendingPathComponent("unnameable-unmatched-clusters.json")
        try documentEncoder.encode(candidateDocument).write(to: candidateJSONURL)
        try documentEncoder.encode(unnameableDocument).write(to: unnameableJSONURL)
        let candidateArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: 2,
            genotypingEvidence: genotypingEvidence,
            reciprocalEvidence: reciprocalEvidence,
            candidateJSON: try artifactReference("candidate-alleles.json"),
            candidateFASTA: candidateFASTA,
            unnameableJSON: try artifactReference("unnameable-unmatched-clusters.json"),
            unnameableFASTA: unnameableFASTA
        )

        // The provenance envelope the run writes, with the run's argv.
        let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(request.argv)
        .durableReplayArgv(request.argv)
        .runtime(ProvenanceRuntimeIdentity())
        .output(request.statsJSONURL, format: .json, role: .report)
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60))
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: request.provenanceURL)

        return Fixture(
            root: root,
            request: request,
            candidateJSONURL: candidateJSONURL,
            unnameableJSONURL: unnameableJSONURL,
            candidateArtifacts: candidateArtifacts
        )
    }

    /// A schema 5 record of a cluster aligned to A_marker in the reciprocal
    /// BAM, as the writer publishes a novel allele. With `shorterCoverage`
    /// below the threshold it is also the interpretation an incomplete
    /// reference span keeps.
    private func candidateRecord(
        clusterID: String, locus: String, reads: Int, sequence: String, shorterCoverage: Double
    ) throws -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: clusterID,
            provisionalName: "Test-\(locus)*900:01_nov",
            locus: locus,
            classification: .novel,
            supportClass: .singleton,
            closestReferenceName: "A_marker",
            closestReferenceClass: .genomicDNA,
            snpCount: 3,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: 0,
            comparableBases: sequence.count,
            shorterCoverage: shorterCoverage,
            identity: 0.95,
            mappingQuality: 60,
            alignmentScore: sequence.count,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: reads,
            supportingSampleIDs: [Self.sample],
            fastaRecordID: clusterID,
            sequenceSHA256: Self.sha256(sequence),
            reciprocalHitSummary: try alignedReciprocalHit(clusterID: clusterID),
            selectedEvidence: reciprocalLocator(clusterID: clusterID, sequence: sequence)
        )
    }

    private func alignedReciprocalHit(clusterID: String) throws -> ONTMHCReciprocalQueryHitSummary {
        try ONTMHCReciprocalQueryHitSummary(
            bamPath: Self.reciprocalBAMPath,
            queryName: clusterID,
            alignmentCount: 1,
            targetAlignmentCounts: ["A_marker": 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: ["A_marker"]
        )
    }

    private func reciprocalLocator(clusterID: String, sequence: String) -> ONTMHCEvidenceLocator {
        ONTMHCEvidenceLocator(
            bamPath: Self.reciprocalBAMPath,
            queryName: clusterID,
            referenceName: "A_marker",
            readGroupID: nil,
            referenceStart: 1,
            cigar: "\(sequence.count)M"
        )
    }

    /// The sample's compact observation of one cluster, as schema 5 records it.
    private func observation(clusterID: String, reads: Int) -> ONTMHCCandidateObservation {
        ONTMHCCandidateObservation(
            stableClusterID: clusterID,
            sampleID: Self.sample,
            readGroupID: Self.sample,
            sourceClusterIDs: ["source-\(clusterID)"],
            sourceClusterReadCounts: ["source-\(clusterID)": reads],
            aggregatedSampleReadCount: reads,
            genotypingHitSummaries: []
        )
    }

    private static func sha256(_ sequence: String) -> String {
        SHA256.hash(data: Data(sequence.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The success manifest the pipeline publishes last, naming the analysis
    /// the run wrote and the candidate artifacts, so the GUI and the CLI load
    /// the bundle with its candidate and un-nameable clusters.
    private func publishBundle(_ fixture: Fixture) throws {
        let request = fixture.request
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
            outputName: request.outputName,
            analysisName: request.outputName,
            primaryWorkbookPath: request.workbookURL.lastPathComponent,
            longSummaryCSVPath: request.reportCSVURL.lastPathComponent,
            sampleSummaryCSVPath: request.sampleSummaryCSVURL.lastPathComponent,
            statsJSONPath: request.statsJSONURL.lastPathComponent,
            provenancePath: request.provenanceURL.lastPathComponent,
            haplotypeAnalysisPath: request.haplotypeAnalysisURL.lastPathComponent,
            haplotypeDefinitionSetID: request.haplotypeDefinitionSetID,
            haplotypeAssayID: request.haplotypeAssayID,
            mhcCandidateArtifacts: fixture.candidateArtifacts
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: request.outputDirectory)
    }
}

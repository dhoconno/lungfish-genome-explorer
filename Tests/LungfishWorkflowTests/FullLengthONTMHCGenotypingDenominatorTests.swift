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
final class FullLengthONTMHCGenotypingDenominatorTests: XCTestCase {
    /// One sample carries 148 reads of A_marker and 2 reads of B_marker at
    /// MHC-A, and a 60-read candidate cluster at the same locus. Against known
    /// reads alone B_marker is 1.33 percent of the locus and survives the run's
    /// 1 percent threshold. Against the documented denominator it is 0.95
    /// percent and drops, so the sample is M-A alone. The run's own analysis
    /// must say what the GUI and the CLI say about the published bundle.
    func testPipelineAnalysisCountsCandidateReadsAtTheLocusAsEveryReinferenceDoes() throws {
        let fixture = try makeFixture(candidateLocus: "MHC-A")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pipelineAnalysis = try runAnalysisStep(fixture)
        try publishBundle(fixture)
        let published = try ONTGenotypeResultBundle.loadResult(from: fixture.request.outputDirectory)

        // The published bundle carries the candidate cluster, so its
        // denominator is the documented one. The known-only denominator is
        // what the pipeline divided by before the fix.
        XCTAssertNotNil(published.mhcCandidates)
        XCTAssertTrue(published.integrityWarnings.isEmpty, "\(published.integrityWarnings)")
        XCTAssertEqual(GenotypeLocusDenominator(calls: published.calls).total(sample: "sample", sourceLocus: "MHC-A"), 150)
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
        XCTAssertEqual(gui.samples, cli.samples)

        // The run's own analysis, the one its workbook and its persisted
        // haplotype-analysis.json carry, agrees with both re-inferences.
        XCTAssertEqual(published.haplotypeAnalysis, pipelineAnalysis)
        XCTAssertEqual(
            pipelineAnalysis.samples, cli.samples,
            "the run's own analysis must divide by known alleles plus candidate clusters at the locus"
        )
    }

    /// The same sample with the candidate cluster at MHC-B instead. The MHC-A
    /// denominator stays at the 150 known reads on every path, B_marker stays
    /// above the threshold and the run and both re-inferences call M-A and M-B.
    /// A run with no candidate cluster at a haplotyped locus keeps its calls.
    func testACandidateClusterAtAnotherLocusLeavesTheRunCallsUnchanged() throws {
        let fixture = try makeFixture(candidateLocus: "MHC-B")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pipelineAnalysis = try runAnalysisStep(fixture)
        try publishBundle(fixture)
        let published = try ONTGenotypeResultBundle.loadResult(from: fixture.request.outputDirectory)
        XCTAssertNotNil(published.mhcCandidates)
        XCTAssertEqual(GenotypeLocusDenominator(result: published).total(sample: "sample", sourceLocus: "MHC-A"), 150)
        XCTAssertEqual(GenotypeLocusDenominator(result: published).total(sample: "sample", sourceLocus: "MHC-B"), 60)

        let cli = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: published, sidecar: nil))
        let gui = GenotypeHaplotypeAnalyzer.analyze(
            calls: published.calls, definitionSet: definition(), generatedAt: nil,
            dropoutFilter: GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: published),
            matrixReviews: [], locusDenominator: GenotypeLocusDenominator(result: published)
        )
        let reinferred = try XCTUnwrap(cli.samples.first?.calls.first)
        XCTAssertEqual([reinferred.haplotype1, reinferred.haplotype2], ["M-A", "M-B"])
        XCTAssertEqual(gui.samples, cli.samples)
        XCTAssertEqual(pipelineAnalysis.samples, cli.samples)
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let request: FullLengthONTMHCGenotypingRunRequest
        let candidateDocument: ONTMHCCandidateAllelesDocument
        let unnameableDocument: ONTMHCUnnameableClustersDocument
        let candidateArtifacts: ONTMHCCandidateArtifactManifest
    }

    /// The pipeline's own analysis step, as `run` calls it once the candidate
    /// artifacts are written and their documents decoded.
    private func runAnalysisStep(_ fixture: Fixture) throws -> GenotypeHaplotypeAnalysis {
        try XCTUnwrap(FullLengthONTMHCGenotypingPipeline().writeHaplotypeAnalysisIfRequested(
            request: fixture.request,
            candidateDocument: fixture.candidateDocument,
            unnameableDocument: fixture.unnameableDocument,
            supportDirectory: fixture.request.outputDirectory.appendingPathComponent(".full-length-ont-mhc", isDirectory: true),
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        ))
    }

    private func definition() -> GenotypeHaplotypeDefinitionSet {
        .init(id: "n7-defs", assayID: "n7-assay", displayName: "N7 definitions", speciesName: "Test species",
              speciesCode: "TST", prefix: "Test", locusDefinitions: [
                .init(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [
                    .init(name: "M-A", diagnosticAlleles: ["A_marker"]),
                    .init(name: "M-B", diagnosticAlleles: ["B_marker"]),
                ]),
              ])
    }

    /// A run's output directory as the pipeline leaves it before the analysis
    /// step. The reference bundle resolves the definition set, the calls and
    /// stats are on disk, the stats record the run's 1 percent locus
    /// threshold, and the candidate artifacts are written and declared with
    /// the digests the published-bundle loader verifies.
    private func makeFixture(candidateLocus: String) throws -> Fixture {
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
            metrics: .init(referenceCount: 2, haplotypeDefinitionCount: 1), createdAt: "2026-10-09T00:00:00Z"
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

        let rows = [("A_marker", 148), ("B_marker", 2)].map {
            "sample,\($0.0)|source_loci=MHC-A|haplotype_groups=MHC-A,\($0.1),\($0.1)"
        }
        try (["sample,genotype,passed_alignments,passed_unique_reads"] + rows).joined(separator: "\n")
            .appending("\n")
            .write(to: request.reportCSVURL, atomically: true, encoding: .utf8)
        try "sample,passed_alignments,passed_unique_reads\n"
            .write(to: request.sampleSummaryCSVURL, atomically: true, encoding: .utf8)
        try FullLengthONTMHCGenotypingPipeline().writeStatsJSON(request: request, sampleSummaries: [], genotypeRows: [])

        // The candidate artifacts, at the paths the candidate artifact writer
        // publishes, with one 60-read cluster of this sample at candidateLocus.
        func artifactReference(_ relativePath: String) throws -> ONTMHCArtifactReference {
            let url = bundle.appendingPathComponent(relativePath)
            return ONTMHCArtifactReference(
                path: relativePath,
                sha256: try ProvenanceFileHasher.sha256(of: url),
                sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
            )
        }
        let clusterID = "novel-cluster"
        let sequence = String(repeating: "ACGTTGCA", count: 8)
        try ">\(clusterID)\n\(sequence)\n".write(to: bundle.appendingPathComponent("candidate_alleles.fasta"), atomically: true, encoding: .utf8)
        try Data("reciprocal alignments".utf8).write(to: bundle.appendingPathComponent("artifacts/alignments/unmatched-to-reference.bam"))
        try Data("reciprocal index".utf8).write(to: bundle.appendingPathComponent("artifacts/alignments/unmatched-to-reference.bam.bai"))
        let fastaReference = try artifactReference("candidate_alleles.fasta")
        let reciprocalBAM = try artifactReference("artifacts/alignments/unmatched-to-reference.bam")
        let reciprocalBAI = try artifactReference("artifacts/alignments/unmatched-to-reference.bam.bai")
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: "2026-10-09T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [reciprocalBAM, reciprocalBAI],
            sequenceFASTA: fastaReference,
            candidates: [
                ONTMHCCandidateRecord(
                    stableClusterID: clusterID,
                    provisionalName: "Test-\(candidateLocus)*900:01_nov",
                    locus: candidateLocus,
                    classification: .novel,
                    supportClass: .singleton,
                    closestReferenceName: "A_marker",
                    closestReferenceClass: .genomicDNA,
                    snpCount: 3,
                    insertedBases: 0,
                    deletedBases: 0,
                    longGapBases: 0,
                    comparableBases: sequence.count,
                    shorterCoverage: 1,
                    identity: 0.95,
                    mappingQuality: 60,
                    alignmentScore: sequence.count,
                    independentSampleCount: 1,
                    occurrenceCount: 1,
                    totalClusterReads: 60,
                    supportingSampleIDs: ["sample"],
                    fastaRecordID: clusterID,
                    sequenceSHA256: SHA256.hash(data: Data(sequence.utf8)).map { String(format: "%02x", $0) }.joined(),
                    selectedEvidence: ONTMHCEvidenceLocator(
                        bamPath: reciprocalBAM.path,
                        queryName: clusterID,
                        referenceName: "A_marker",
                        readGroupID: nil,
                        referenceStart: 1,
                        cigar: "\(sequence.count)M"
                    )
                ),
            ],
            observations: [
                ONTMHCCandidateObservation(
                    stableClusterID: clusterID,
                    sampleID: "sample",
                    readGroupID: "sample",
                    sourceClusterIDs: ["source-\(clusterID)"],
                    sourceClusterReadCounts: ["source-\(clusterID)": 60],
                    aggregatedSampleReadCount: 60,
                    evidence: []
                ),
            ]
        )
        let documentEncoder = JSONEncoder()
        documentEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try documentEncoder.encode(candidateDocument).write(to: bundle.appendingPathComponent("candidate-alleles.json"))
        let candidateArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: 1,
            genotypingEvidence: nil,
            reciprocalEvidence: ONTMHCBAMArtifactPair(bam: reciprocalBAM, bai: reciprocalBAI),
            candidateJSON: try artifactReference("candidate-alleles.json"),
            candidateFASTA: fastaReference,
            unnameableJSON: nil,
            unnameableFASTA: nil
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: "2026-10-09T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: fastaReference,
            clusters: [],
            observations: []
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
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            candidateArtifacts: candidateArtifacts
        )
    }

    /// The success manifest the pipeline publishes last, naming the analysis
    /// the run wrote and the candidate artifacts, so the GUI and the CLI load
    /// the bundle with its candidate clusters.
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

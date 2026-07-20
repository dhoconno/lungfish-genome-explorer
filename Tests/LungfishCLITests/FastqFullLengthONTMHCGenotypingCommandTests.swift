import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqFullLengthONTMHCGenotypingCommandTests: XCTestCase {
    func testFullLengthONTMHCPayloadIncludesFinalCohortEvidencePaths() throws {
        let payload = FastqFullLengthONTMHCGenotypingPayload(
            outputDirectory: "/tmp/result.lungfishgenotype",
            reportCSVPath: "/tmp/report.csv",
            sampleSummaryCSVPath: "/tmp/samples.csv",
            statsJSONPath: "/tmp/stats.json",
            workbookPath: "/tmp/current.xlsx",
            primaryWorkbookPath: "/tmp/primary.xlsx",
            haplotypeAnalysisPath: nil,
            unmatchedClustersFASTAPath: "/tmp/unmatched.fasta",
            deduplicatedUnmatchedClustersFASTAPath: "/tmp/result.lungfishgenotype/deduplicated_unmatched_clusters.fasta",
            cdnaClustersFASTAPath: "/tmp/cdna.fasta",
            provenancePath: "/tmp/provenance.json",
            manifestPath: "/tmp/result.lungfishgenotype/genotype-result.json",
            referenceFASTAPath: "/tmp/reference.fasta",
            genotypingEvidenceBAMPath: "/tmp/result.lungfishgenotype/artifacts/alignments/genotyping-evidence.bam",
            genotypingEvidenceBAIPath: "/tmp/result.lungfishgenotype/artifacts/alignments/genotyping-evidence.bam.bai",
            reciprocalEvidenceBAMPath: "/tmp/result.lungfishgenotype/artifacts/alignments/unmatched-to-reference.bam",
            reciprocalEvidenceBAIPath: "/tmp/result.lungfishgenotype/artifacts/alignments/unmatched-to-reference.bam.bai",
            candidateAllelesJSONPath: "/tmp/result.lungfishgenotype/candidate-alleles.json",
            candidateAllelesFASTAPath: "/tmp/result.lungfishgenotype/candidate_alleles.fasta",
            unnameableClustersJSONPath: "/tmp/result.lungfishgenotype/unnameable-unmatched-clusters.json",
            unnameableClustersFASTAPath: "/tmp/result.lungfishgenotype/unnameable_unmatched_clusters.fasta",
            cleanupWarnings: [
                FullLengthONTMHCGenotypingCleanupWarning(
                    kind: .workflowIntermediates,
                    path: "/tmp/result.lungfishgenotype/workflow",
                    error: "injected cleanup failure",
                    publishedArtifactsRemainValid: true
                )
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )

        XCTAssertEqual(
            object["genotypingEvidenceBAMPath"] as? String,
            "/tmp/result.lungfishgenotype/artifacts/alignments/genotyping-evidence.bam"
        )
        XCTAssertEqual(
            object["genotypingEvidenceBAIPath"] as? String,
            "/tmp/result.lungfishgenotype/artifacts/alignments/genotyping-evidence.bam.bai"
        )
        let expectedPublishedPaths: [String: String] = [
            "deduplicatedUnmatchedClustersFASTAPath": "/tmp/result.lungfishgenotype/deduplicated_unmatched_clusters.fasta",
            "manifestPath": "/tmp/result.lungfishgenotype/genotype-result.json",
            "reciprocalEvidenceBAMPath": "/tmp/result.lungfishgenotype/artifacts/alignments/unmatched-to-reference.bam",
            "reciprocalEvidenceBAIPath": "/tmp/result.lungfishgenotype/artifacts/alignments/unmatched-to-reference.bam.bai",
            "candidateAllelesJSONPath": "/tmp/result.lungfishgenotype/candidate-alleles.json",
            "candidateAllelesFASTAPath": "/tmp/result.lungfishgenotype/candidate_alleles.fasta",
            "unnameableClustersJSONPath": "/tmp/result.lungfishgenotype/unnameable-unmatched-clusters.json",
            "unnameableClustersFASTAPath": "/tmp/result.lungfishgenotype/unnameable_unmatched_clusters.fasta",
        ]
        for (key, path) in expectedPublishedPaths {
            XCTAssertEqual(object[key] as? String, path, "Missing final published CLI path for \(key)")
            XCTAssertTrue(payload.textOutput.contains(path), "Missing final published text path for \(key)")
        }
        let warnings = try XCTUnwrap(object["cleanupWarnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings[0]["kind"] as? String, "workflowIntermediates")
        XCTAssertEqual(warnings[0]["path"] as? String, "/tmp/result.lungfishgenotype/workflow")
        XCTAssertEqual(warnings[0]["error"] as? String, "injected cleanup failure")
        XCTAssertEqual(warnings[0]["publishedArtifactsRemainValid"] as? Bool, true)
    }

    func testFullLengthONTMHCCommandDoesNotRequireGuideSequences() throws {
        let command = try FastqFullLengthONTMHCGenotypingSubcommand.parse([
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
        ])

        XCTAssertEqual(command.reference, "/tmp/ref.lungfishref")
    }

    func testFullLengthONTMHCCommandParsesThreads() throws {
        let command = try FastqFullLengthONTMHCGenotypingSubcommand.parse([
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--threads", "4",
        ])

        XCTAssertEqual(command.threads, 4)
    }

    func testFullLengthONTMHCCommandParsesThreadsThroughTopLevelCLI() throws {
        let parsed = try LungfishCLI.parseAsRoot([
            "fastq",
            "full-length-ont-mhc-genotype",
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--threads", "4",
        ])
        let command = try XCTUnwrap(parsed as? FastqFullLengthONTMHCGenotypingSubcommand)

        XCTAssertEqual(command.threads, 4)
    }

    func testFullLengthONTMHCCommandParsesCheckpointFlags() throws {
        let command = try FastqFullLengthONTMHCGenotypingSubcommand.parse([
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--keep-intermediates",
            "--reuse-compatible-checkpoints",
        ])

        XCTAssertTrue(command.keepIntermediates)
        XCTAssertTrue(command.reuseCompatibleCheckpoints)
    }

    func testFullLengthONTMHCRunRequestArgvUsesSavontAndOmitsGuideAndPBAAOptions() {
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq", isDirectory: true)],
            referenceSourceURL: URL(fileURLWithPath: "/tmp/ref.lungfishref", isDirectory: true),
            outputDirectory: URL(fileURLWithPath: "/tmp/out.lungfishgenotype", isDirectory: true)
        )

        XCTAssertFalse(request.argv.contains("--guide"))
        XCTAssertFalse(request.argv.contains { $0.contains("pbaa") || $0.contains("pbAA") })
        XCTAssertEqual(value(after: "--savont-quality-value-cutoff", in: request.argv), "90")
        XCTAssertEqual(value(after: "--savont-min-cluster-size", in: request.argv), "3")
    }

    func testFullLengthONTMHCRunRequestArgvIncludesCheckpointFlagsWhenEnabled() {
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq", isDirectory: true)],
            referenceSourceURL: URL(fileURLWithPath: "/tmp/ref.lungfishref", isDirectory: true),
            outputDirectory: URL(fileURLWithPath: "/tmp/out.lungfishgenotype", isDirectory: true),
            keepIntermediates: true,
            reuseCompatibleCheckpoints: true
        )

        XCTAssertTrue(request.argv.contains("--keep-intermediates"))
        XCTAssertTrue(request.argv.contains("--reuse-compatible-checkpoints"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

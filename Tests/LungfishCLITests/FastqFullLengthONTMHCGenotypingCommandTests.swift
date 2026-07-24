import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqFullLengthONTMHCGenotypingCommandTests: XCTestCase {
    func testFullLengthONTMHCCommandRoutesTextOutputDirectly() throws {
        let command = try makeCommand(format: .text)
        let payload = makePayload()

        let output = try XCTUnwrap(command.outputData(for: payload))

        XCTAssertEqual(String(decoding: output, as: UTF8.self), payload.textOutput)
    }

    func testFullLengthONTMHCCommandRoutesJSONOutputDirectly() throws {
        let command = try makeCommand(format: .json)
        let payload = makePayload()

        let output = try XCTUnwrap(command.outputData(for: payload))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )

        XCTAssertEqual(object["outputDirectory"] as? String, "/tmp/result.lungfishgenotype")
        XCTAssertEqual(object["candidateAllelesJSONPath"] as? String, "/tmp/result.lungfishgenotype/candidate-alleles.json")
        XCTAssertTrue(String(decoding: output, as: UTF8.self).hasSuffix("\n"))
    }

    func testFullLengthONTMHCCommandRoutesOneEscapedTSVRowWithStableHeader() throws {
        let command = try makeCommand(format: .tsv)
        let payload = makePayload(outputDirectory: "/tmp/result\t\"quoted\".lungfishgenotype")

        let output = String(decoding: try XCTUnwrap(command.outputData(for: payload)), as: UTF8.self)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.count, 3, "Expected one header, one data row, and a trailing newline")
        XCTAssertEqual(
            lines[0],
            [
                "outputDirectory", "reportCSVPath", "sampleSummaryCSVPath", "statsJSONPath",
                "workbookPath", "primaryWorkbookPath", "haplotypeAnalysisPath",
                "unmatchedClustersFASTAPath", "deduplicatedUnmatchedClustersFASTAPath",
                "cdnaClustersFASTAPath", "provenancePath", "manifestPath", "referenceFASTAPath",
                "genotypingEvidenceBAMPath", "genotypingEvidenceBAIPath", "reciprocalEvidenceBAMPath",
                "reciprocalEvidenceBAIPath", "candidateAllelesJSONPath", "candidateAllelesFASTAPath",
                "candidateAllelesGenBankPath", "unnameableClustersJSONPath", "unnameableClustersFASTAPath",
                "unnameableClustersGenBankPath", "referenceCatalogJSONPath",
                "workbookProjectionInputJSONPath", "cleanupWarnings",
            ].joined(separator: "\t")
        )
        XCTAssertTrue(
            lines[1].hasPrefix("\"/tmp/result\t\"\"quoted\"\".lungfishgenotype\"\t/tmp/report.csv\t"),
            lines[1]
        )
        XCTAssertTrue(lines[1].contains("\t\t/tmp/unmatched.fasta\t"), "Nil fields must remain empty TSV cells")
        XCTAssertTrue(lines[1].contains("\"\"error\"\":\"\"injected cleanup failure\"\""), lines[1])
    }

    func testFullLengthONTMHCCommandQuietSuppressesEveryOutputFormat() throws {
        let payload = makePayload()

        for format in OutputFormat.allCases {
            let command = try makeCommand(format: format, quiet: true)
            XCTAssertNil(try command.outputData(for: payload), "Quiet did not suppress \(format.rawValue)")
        }
    }

    func testFullLengthONTMHCPayloadIncludesFinalCohortEvidencePaths() throws {
        let payload = makePayload()

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
            "candidateAllelesGenBankPath": "/tmp/result.lungfishgenotype/candidate_alleles.gb",
            "unnameableClustersJSONPath": "/tmp/result.lungfishgenotype/unnameable-unmatched-clusters.json",
            "unnameableClustersFASTAPath": "/tmp/result.lungfishgenotype/unnameable_unmatched_clusters.fasta",
            "unnameableClustersGenBankPath": "/tmp/result.lungfishgenotype/unnameable_unmatched_clusters.gb",
            "referenceCatalogJSONPath": "/tmp/result.lungfishgenotype/artifacts/reference/mhc-reference-catalog.json",
            "workbookProjectionInputJSONPath": "/tmp/result.lungfishgenotype/artifacts/projections/mhc-workbook-projection-input.json",
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

    private func makeCommand(
        format: OutputFormat,
        quiet: Bool = false
    ) throws -> FastqFullLengthONTMHCGenotypingSubcommand {
        var arguments = [
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--format", format.rawValue,
        ]
        if quiet {
            arguments.append("--quiet")
        }
        return try FastqFullLengthONTMHCGenotypingSubcommand.parse(arguments)
    }

    private func makePayload(
        outputDirectory: String = "/tmp/result.lungfishgenotype"
    ) -> FastqFullLengthONTMHCGenotypingPayload {
        FastqFullLengthONTMHCGenotypingPayload(
            outputDirectory: outputDirectory,
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
            candidateAllelesGenBankPath: "/tmp/result.lungfishgenotype/candidate_alleles.gb",
            unnameableClustersJSONPath: "/tmp/result.lungfishgenotype/unnameable-unmatched-clusters.json",
            unnameableClustersFASTAPath: "/tmp/result.lungfishgenotype/unnameable_unmatched_clusters.fasta",
            unnameableClustersGenBankPath: "/tmp/result.lungfishgenotype/unnameable_unmatched_clusters.gb",
            referenceCatalogJSONPath: "/tmp/result.lungfishgenotype/artifacts/reference/mhc-reference-catalog.json",
            workbookProjectionInputJSONPath: "/tmp/result.lungfishgenotype/artifacts/projections/mhc-workbook-projection-input.json",
            cleanupWarnings: [
                FullLengthONTMHCGenotypingCleanupWarning(
                    kind: .workflowIntermediates,
                    path: "/tmp/result.lungfishgenotype/workflow",
                    error: "injected cleanup failure",
                    publishedArtifactsRemainValid: true
                )
            ]
        )
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

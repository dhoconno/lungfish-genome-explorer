import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FetchNCBIGFF3Tests: XCTestCase {
    private let annotatedGFF3 = """
    ##gff-version 3
    ##sequence-region MN908947.3 1 29903
    MN908947.3\tRefSeq\tregion\t1\t29903\t.\t+\t.\tID=MN908947.3:1..29903;Dbxref=taxon:2697049
    MN908947.3\tRefSeq\tgene\t28274\t29533\t.\t+\t.\tID=gene-GU280_gp10;Name=N;gbkey=Gene;gene=N
    """

    func testFetchGFF3SidecarRecordsFormatChecksumAndResolvedURL() throws {
        let tempDir = try temporaryDirectory(named: "FetchNCBIGFF3Sidecar")
        let outputURL = tempDir.appendingPathComponent("MN908947.3.gff3")
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "gff3",
            "--save-to", outputURL.path,
            "--format", "json"
        ])

        try command.writeNCBIFetchOutputWithProvenance(
            content: annotatedGFF3,
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let run = try decodeProvenance(for: outputURL)
        let step = try XCTUnwrap(run.steps.first)
        XCTAssertEqual(run.parameters["fetchFormat"]?.stringValue, "gff3")
        XCTAssertEqual(run.parameters["resolvedFetchFormat"]?.stringValue, "gff3")
        XCTAssertEqual(step.inputs.first?.path, "ncbi://nucleotide/MN908947.3?rettype=gff3")
        XCTAssertEqual(step.outputs.first?.path, outputURL.path)
        XCTAssertEqual(step.outputs.first?.format, .gff3)
        XCTAssertNotNil(step.outputs.first?.sha256)
        XCTAssertGreaterThan(step.outputs.first?.sizeBytes ?? 0, 0)
    }

    func testFetchGFFAliasRecordsResolvedGFF3URLAndFormat() throws {
        let tempDir = try temporaryDirectory(named: "FetchNCBIGFFAlias")
        let outputURL = tempDir.appendingPathComponent("MN908947.3.gff3")
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "gff",
            "--save-to", outputURL.path
        ])

        try command.writeNCBIFetchOutputWithProvenance(
            content: annotatedGFF3,
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let run = try decodeProvenance(for: outputURL)
        let step = try XCTUnwrap(run.steps.first)
        XCTAssertEqual(run.parameters["fetchFormat"]?.stringValue, "gff")
        XCTAssertEqual(run.parameters["resolvedFetchFormat"]?.stringValue, "gff3")
        XCTAssertEqual(step.inputs.first?.path, "ncbi://nucleotide/MN908947.3?rettype=gff3")
        XCTAssertEqual(step.outputs.first?.format, .gff3)
    }

    func testFixtureRegeneratorFetchesGFF3AndCreatesAnnotatedBundle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("docs/user-manual/fixtures/sarscov2-srr36291587/regenerate.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("--fetch-format gff3 --save-to \"$OUT/MN908947.3.gff3\""))
        XCTAssertTrue(script.contains("--annotation \"$OUT/MN908947.3.gff3\""))
    }

    func testGFF3FeatureCounterTreatsHeaderOnlyResponseAsEmpty() {
        let headerOnly = """
        ##gff-version 3
        ##sequence-region TEST 1 100
        # No annotated features
        """

        XCTAssertEqual(NCBISubcommand.gff3FeatureCount(in: annotatedGFF3), 2)
        XCTAssertEqual(NCBISubcommand.gff3FeatureCount(in: headerOnly), 0)
    }

    func testEmptyGFF3ResponseNormalizesToValidHeaderOnlyDocument() {
        let normalized = NCBISubcommand.normalizedGFF3Content("", accession: "NO_ANNOTATIONS.1")

        XCTAssertEqual(normalized, "##gff-version 3\n")
        XCTAssertEqual(NCBISubcommand.gff3FeatureCount(in: normalized), 0)
    }

    func testMultiAccessionGFF3OutputSeparatesRecordsWithComments() {
        let combined = NCBISubcommand.combinedContent(
            for: [
                (accession: "MN908947.3", content: "##gff-version 3\nMN908947.3\tRefSeq\tgene\t1\t3\t.\t+\t.\tID=a\n"),
                (accession: "NC_045512.2", content: "##gff-version 3\nNC_045512.2\tRefSeq\tgene\t1\t3\t.\t+\t.\tID=b")
            ],
            format: .gff3
        )

        XCTAssertTrue(combined.contains("# lungfish fetch ncbi accession: MN908947.3"))
        XCTAssertTrue(combined.contains("###\n# lungfish fetch ncbi accession: NC_045512.2"))
        XCTAssertTrue(combined.hasSuffix("\n"))
    }

    private func temporaryDirectory(named prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }
        return tempDir
    }

    private func decodeProvenance(for outputURL: URL) throws -> WorkflowRun {
        let provenanceURL = NCBISubcommand.provenanceSidecarURL(for: outputURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))
    }
}

import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FetchNCBIProvenanceTests: XCTestCase {
    func testSaveToWritesOutputAndFileSpecificWorkflowProvenance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchNCBIProvenanceOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let outputURL = tempDir.appendingPathComponent("MN908947.3.fasta")
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "fasta",
            "--save-to", outputURL.path,
            "--format", "json"
        ])

        try command.writeNCBIFetchOutputWithProvenance(
            content: ">MN908947.3\nACGT\n",
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), ">MN908947.3\nACGT\n")
        let provenanceURL = NCBISubcommand.provenanceSidecarURL(for: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))
        XCTAssertEqual(run.steps.first?.outputs.first?.path, outputURL.path)
        XCTAssertNotNil(run.steps.first?.outputs.first?.sha256)
        XCTAssertEqual(run.steps.first?.outputs.first?.sizeBytes, 17)
    }

    func testSaveToWritesFileSpecificWorkflowProvenance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchNCBIProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let outputURL = tempDir.appendingPathComponent("MN908947.3.fasta")
        try ">MN908947.3\nACGT\n".write(to: outputURL, atomically: true, encoding: .utf8)
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "fasta",
            "--save-to", outputURL.path,
            "--format", "json"
        ])

        try command.writeNCBIFetchProvenance(
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let provenanceURL = NCBISubcommand.provenanceSidecarURL(for: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))

        XCTAssertEqual(run.name, "ncbi-sequence-fetch")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.parameters["database"]?.stringValue, "nucleotide")
        XCTAssertEqual(run.parameters["fetchFormat"]?.stringValue, "fasta")
        XCTAssertEqual(run.parameters["saveTo"]?.stringValue, outputURL.path)
        XCTAssertEqual(run.parameters["endpoint"]?.stringValue, "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")
        XCTAssertEqual(run.steps.count, 1)

        let step = try XCTUnwrap(run.steps.first)
        XCTAssertEqual(step.toolName, "ncbi-efetch")
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertEqual(step.wallTime, 2)
        XCTAssertTrue(step.command.contains("--save-to"))
        XCTAssertTrue(step.command.contains(outputURL.path))
        XCTAssertEqual(step.inputs.first?.path, "ncbi://nucleotide/MN908947.3?rettype=fasta")
        XCTAssertEqual(step.outputs.first?.path, outputURL.path)
        XCTAssertEqual(step.outputs.first?.format, .fasta)
        XCTAssertNotNil(step.outputs.first?.sha256)
        XCTAssertEqual(step.outputs.first?.sizeBytes, 17)
    }
}

import XCTest
import LungfishWorkflow
@testable import LungfishCLI

final class FastqQCSummaryCommandTests: XCTestCase {
    func testQCSummaryParsesInputAndOutput() throws {
        let command = try FastqQCSummarySubcommand.parse([
            "reads.fastq",
            "--output", "/tmp/qc-summary.json",
        ])

        XCTAssertEqual(command.inputs, ["reads.fastq"])
        XCTAssertEqual(command.output.output, "/tmp/qc-summary.json")
    }

    func testQCSummaryRunWritesJsonSummary() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("fastq-qc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("reads.fastq")
        let outputURL = tempDir.appendingPathComponent("qc-summary.json")
        let fastq = """
        @read1
        ACGT
        +
        !!!!
        @read2
        GGTT
        +
        !!!!
        """
        guard let fastqData = fastq.data(using: .utf8) else {
            return XCTFail("Failed to encode FASTQ fixture")
        }
        try fastqData.write(to: inputURL)

        let command = try FastqQCSummarySubcommand.parse([
            inputURL.path,
            "--output", outputURL.path,
        ])

        try await command.run()

        let data = try Data(contentsOf: outputURL)
        let decoded = try JSONDecoder().decode(QCSummaryReport.self, from: data)

        XCTAssertEqual(decoded.inputs.count, 1)
        XCTAssertEqual(decoded.inputs[0].input, inputURL.path)
        XCTAssertEqual(decoded.inputs[0].statistics.readCount, 2)
        XCTAssertEqual(decoded.inputs[0].statistics.baseCount, 8)
        XCTAssertEqual(decoded.inputs[0].statistics.minReadLength, 4)
        XCTAssertEqual(decoded.inputs[0].statistics.maxReadLength, 4)
        XCTAssertEqual(decoded.inputs[0].statistics.meanQuality, 0.0, accuracy: 0.0001)

        let directoryEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: tempDir))
        XCTAssertEqual(directoryEnvelope.workflowName, "lungfish fastq qc-summary")
        XCTAssertEqual(directoryEnvelope.toolName, "lungfish fastq qc-summary")
        XCTAssertEqual(directoryEnvelope.argv, [
            "lungfish", "fastq", "qc-summary", inputURL.path, "--output", outputURL.path
        ])
        XCTAssertEqual(directoryEnvelope.durableReplayArgv, directoryEnvelope.argv)
        XCTAssertEqual(directoryEnvelope.exitStatus, 0)
        XCTAssertEqual(directoryEnvelope.output?.path, outputURL.path)
        XCTAssertEqual(directoryEnvelope.output?.format, .json)
        XCTAssertNotNil(directoryEnvelope.output?.checksumSHA256)
        XCTAssertTrue(directoryEnvelope.files.contains { descriptor in
            descriptor.path == inputURL.path
                && descriptor.role == .input
                && descriptor.format == .fastq
                && descriptor.checksumSHA256 != nil
        })
        XCTAssertEqual(directoryEnvelope.options.explicit["output"]?.fileValue?.path, outputURL.path)
        XCTAssertEqual(
            directoryEnvelope.options.explicit["inputs"]?.arrayValue?.compactMap { $0.fileValue?.path },
            [inputURL.path]
        )
        XCTAssertEqual(directoryEnvelope.options.defaults["force"]?.booleanValue, false)
        XCTAssertEqual(directoryEnvelope.options.defaults["compress"]?.booleanValue, false)
        XCTAssertEqual(directoryEnvelope.options.resolvedDefaults["force"]?.booleanValue, false)
        XCTAssertEqual(directoryEnvelope.options.resolvedDefaults["compress"]?.booleanValue, false)
        XCTAssertEqual(directoryEnvelope.steps.count, 1)
        XCTAssertEqual(directoryEnvelope.steps.first?.toolName, "lungfish fastq qc-summary")
        XCTAssertEqual(directoryEnvelope.steps.first?.outputs.first?.path, outputURL.path)

        let fileEnvelope = try loadFileSidecarEnvelope(for: outputURL)
        XCTAssertEqual(fileEnvelope.workflowName, "lungfish fastq qc-summary")
        XCTAssertEqual(fileEnvelope.output?.path, outputURL.path)
        XCTAssertEqual(fileEnvelope.outputs.map(\.path), [outputURL.path])
        XCTAssertNotNil(ProvenanceRecorder.findProvenance(forFile: outputURL))
    }

    func testFastqCommandRegistersQCSummarySubcommand() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("qc-summary"))
    }
}

private func loadFileSidecarEnvelope(for outputURL: URL) throws -> ProvenanceEnvelope {
    let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
    XCTAssertTrue(
        FileManager.default.fileExists(atPath: sidecarURL.path),
        "Missing file-specific provenance sidecar at \(sidecarURL.path)"
    )
    return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecarURL))
}

private struct QCSummaryReport: Decodable {
    struct Entry: Decodable {
        let input: String
        let statistics: Statistics
    }

    struct Statistics: Decodable {
        let readCount: Int
        let baseCount: Int64
        let minReadLength: Int
        let maxReadLength: Int
        let meanQuality: Double
    }

    let inputs: [Entry]
}

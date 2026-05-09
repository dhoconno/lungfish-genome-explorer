import XCTest
@testable import LungfishWorkflow

final class BAMPrimerTrimProvenanceTests: XCTestCase {
    func testProvenanceEncodesToJSONAndRoundTrips() throws {
        let sourceRecord = FileRecord(
            path: "/bundle/alignments/source.bam",
            sha256: "source-sha",
            sizeBytes: 12_345,
            format: .bam,
            role: .input
        )
        let outputRecord = FileRecord(
            path: "/bundle/alignments/trimmed.bam",
            sha256: "trimmed-sha",
            sizeBytes: 23_456,
            format: .bam,
            role: .output
        )
        let step = StepExecution(
            toolName: "ivar",
            toolVersion: "1.4.4 (managed conda environment ivar; executable ivar; package ivar)",
            command: ["/tools/ivar", "trim", "-b", "/bundle/primers.bed"],
            inputs: [sourceRecord],
            outputs: [outputRecord],
            exitCode: 0,
            wallTime: 0.25,
            stderr: "ivar stderr",
            startTime: Date(timeIntervalSince1970: 1_714_000_000),
            endTime: Date(timeIntervalSince1970: 1_714_000_001)
        )
        let provenance = BAMPrimerTrimProvenance(
            operation: "primer-trim",
            primerScheme: .init(
                bundleName: "QIASeqDIRECT-SARS2",
                bundleSource: "built-in",
                bundleVersion: "1.0",
                canonicalAccession: "MN908947.3"
            ),
            sourceBAMRelativePath: "derivatives/alignment.bam",
            ivarVersion: "1.4.2",
            ivarTrimArgs: ["-q", "20", "-m", "30"],
            timestamp: Date(timeIntervalSince1970: 1714000000),
            schemaVersion: 2,
            workflowName: "lungfish bam primer-trim",
            workflowVersion: "Lungfish test (1)",
            command: ["lungfish-cli", "bam", "primer-trim", "--ivar-min-quality", "20"],
            resolvedOptions: [
                "ivar_min_quality": "20",
                "ivar_min_length": "30",
                "ivar_sliding_window": "4",
                "ivar_primer_offset": "0"
            ],
            inputFiles: [sourceRecord],
            outputFiles: [outputRecord],
            runtimeIdentity: [
                "ivar": "managed conda environment ivar; executable ivar; package ivar"
            ],
            steps: [step],
            wallTimeSeconds: 1.0,
            exitStatus: 0,
            stderr: "ivar stderr"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(provenance)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BAMPrimerTrimProvenance.self, from: data)

        XCTAssertEqual(decoded, provenance)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.workflowName, "lungfish bam primer-trim")
        XCTAssertEqual(decoded.command.first, "lungfish-cli")
        XCTAssertEqual(decoded.resolvedOptions["ivar_min_quality"], "20")
        XCTAssertEqual(decoded.inputFiles.first?.sha256, "source-sha")
        XCTAssertEqual(decoded.outputFiles.first?.sizeBytes, 23_456)
        XCTAssertEqual(decoded.runtimeIdentity["ivar"], "managed conda environment ivar; executable ivar; package ivar")
        XCTAssertEqual(decoded.steps.first?.command.last, "/bundle/primers.bed")
        XCTAssertEqual(decoded.steps.first?.exitCode, 0)
    }

    func testRelocatingFinalOutputsPreservesMetadataWhenFinalFilesAreNotPresent() throws {
        let provenance = BAMPrimerTrimProvenance(
            operation: "primer-trim",
            primerScheme: .init(
                bundleName: "QIASeqDIRECT-SARS2",
                bundleSource: "built-in",
                bundleVersion: "1",
                canonicalAccession: "MN908947.3"
            ),
            sourceBAMRelativePath: "alignments/source.bam",
            ivarVersion: "1.4.2",
            ivarTrimArgs: ["trim"],
            timestamp: Date(timeIntervalSince1970: 1_714_000_000),
            outputFiles: [
                FileRecord(path: "/tmp/staged.bam", sha256: "bam-sha", sizeBytes: 10, format: .bam, role: .output),
                FileRecord(path: "/tmp/staged.bam.bai", sha256: "bai-sha", sizeBytes: 20, format: nil, role: .index)
            ]
        )

        let relocated = provenance.relocatingFinalOutputs(
            outputBAMURL: URL(fileURLWithPath: "/bundle/alignments/final.bam"),
            outputBAMIndexURL: URL(fileURLWithPath: "/bundle/alignments/final.bam.bai")
        )

        XCTAssertEqual(relocated.outputFiles[0].path, "/bundle/alignments/final.bam")
        XCTAssertEqual(relocated.outputFiles[0].sha256, "bam-sha")
        XCTAssertEqual(relocated.outputFiles[0].sizeBytes, 10)
        XCTAssertEqual(relocated.outputFiles[1].path, "/bundle/alignments/final.bam.bai")
        XCTAssertEqual(relocated.outputFiles[1].sha256, "bai-sha")
        XCTAssertEqual(relocated.outputFiles[1].sizeBytes, 20)
    }
}

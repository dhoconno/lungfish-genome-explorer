import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqMergeProvenanceTests: XCTestCase {
    func testCompressedMergeRecordsGzipAsSeparateStep() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("fastq-merge-provenance-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("interleaved.fastq")
        let mergedURL = tempDir.appendingPathComponent("merged.fastq")
        let unmergedURL = tempDir.appendingPathComponent("unmerged.fastq")
        let concatenatedURL = tempDir.appendingPathComponent("merged-and-unmerged.fastq")
        let outputURL = tempDir.appendingPathComponent("merged.fastq.gz")

        try "@r1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: mergedURL, atomically: true, encoding: .utf8)
        try Data().write(to: unmergedURL)
        try "@r1\nACGT\n+\nIIII\n".write(to: concatenatedURL, atomically: true, encoding: .utf8)
        try Data([0x1f, 0x8b, 0x08]).write(to: outputURL)

        let bbmergeArguments = [
            "in=\(inputURL.path)",
            "out=\(mergedURL.path)",
            "outu=\(unmergedURL.path)",
            "minoverlap=12",
        ]
        let bbmergeResult = NativeToolResult(
            exitCode: 0,
            stdout: "",
            stderr: "bbmerge summary",
            arguments: ["/tools/bbmerge.sh"] + bbmergeArguments
        )
        let gzipResult = FASTQGzipProvenanceResult(
            command: ["/usr/bin/gzip", "-c", concatenatedURL.path],
            inputURL: concatenatedURL,
            outputURL: outputURL,
            exitCode: 0,
            wallTime: 0.25,
            stderr: ""
        )

        let envelope = try await recordFASTQMergeProvenance(
            cliArguments: ["merge", inputURL.path, "--output", outputURL.path, "--compress"],
            nativeArguments: bbmergeArguments,
            bbmergeResult: bbmergeResult,
            gzipResult: gzipResult,
            inputURL: inputURL,
            bbmergeOutputURLs: [mergedURL, unmergedURL],
            finalOutputURL: outputURL,
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "compress": .boolean(true),
            ],
            defaults: ["compress": .boolean(false)],
            startedAt: Date().addingTimeInterval(-1)
        )

        XCTAssertEqual(envelope.workflowName, "lungfish fastq merge")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertTrue(envelope.outputs.contains { $0.path == outputURL.path })
        XCTAssertEqual(envelope.steps.count, 3)

        let bbmergeStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bbmerge" })
        XCTAssertEqual(bbmergeStep.outputs.map(\.path), [mergedURL.path, unmergedURL.path])
        XCTAssertFalse(bbmergeStep.outputs.contains { $0.path == outputURL.path })
        XCTAssertEqual(bbmergeStep.stderr, "bbmerge summary")

        let concatenateStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "lungfish fastq merge concatenate" })
        XCTAssertEqual(concatenateStep.inputs.map(\.path), [mergedURL.path, unmergedURL.path])
        XCTAssertEqual(concatenateStep.outputs.map(\.path), [concatenatedURL.path])
        XCTAssertEqual(concatenateStep.exitStatus, 0)

        let gzipStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "/usr/bin/gzip" })
        XCTAssertEqual(gzipStep.argv, ["/usr/bin/gzip", "-c", concatenatedURL.path])
        XCTAssertEqual(gzipStep.inputs.map(\.path), [concatenatedURL.path])
        XCTAssertEqual(gzipStep.outputs.map(\.path), [outputURL.path])
        XCTAssertEqual(gzipStep.exitStatus, 0)
        XCTAssertEqual(gzipStep.wallTimeSeconds, 0.25)

        let directoryEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: tempDir))
        XCTAssertEqual(directoryEnvelope.steps.map(\.toolName), [
            "bbmerge",
            "lungfish fastq merge concatenate",
            "/usr/bin/gzip",
        ])
        XCTAssertEqual(directoryEnvelope.output?.path, outputURL.path)

        let fileEnvelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(fileEnvelope.steps.map(\.toolName), ["/usr/bin/gzip"])
        XCTAssertEqual(fileEnvelope.output?.path, outputURL.path)
    }
}

// AffectedResultsS1SweepRecordTests.swift - The kind of the records the CLI's two merge writers make
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Lane AFFECTED-S1 m2, row MERGE-COUNTED-INVENTED-Q (BIO-MERGE item 8 and Q3). `AffectedResults.kind(of:)` reads a
/// record's root name and its steps, so the kind is pinned against the records the CLI's writers make, with no tool run.
/// Every app merge up to Preview 2026.11.16 (14223) passed `--count-duplicates`, and `recordFASTQCountedMergeProvenance`
/// wrote its record. A merge without the flag, the app's merge since MERGE-UNCOUNTED, is written by
/// `recordFASTQMergeProvenance` and is no kind. The fixtures are those of `FastqMergeProvenanceTests`.
final class AffectedResultsS1SweepRecordTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-s1-sweep-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func url(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    private func bbmerge() -> (arguments: [String], result: NativeToolResult) {
        let arguments = [
            "in=\(url("interleaved.fastq").path)",
            "out=\(url("merged.fastq").path)",
            "outu=\(url("unmerged.fastq").path)",
            "minoverlap=12",
        ]
        let result = NativeToolResult(
            exitCode: 0, stdout: "", stderr: "bbmerge summary", arguments: ["/tools/bbmerge.sh"] + arguments
        )
        return (arguments, result)
    }

    private func writeReads() throws {
        try "@r1\nACGT\n+\nIIII\n".write(to: url("interleaved.fastq"), atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: url("merged.fastq"), atomically: true, encoding: .utf8)
        try "@r2\nTTTT\n+\nIIII\n".write(to: url("unmerged.fastq"), atomically: true, encoding: .utf8)
    }

    func testTheRecordOfACountedMergeIsTheCountedMergeKind() async throws {
        try writeReads()
        let countedRaw = url(".counted.fastq")
        let output = url("counted.fastq")
        try "@u000001;size=2\nACGT\n+\nIIII\n".write(to: countedRaw, atomically: true, encoding: .utf8)
        try "@u000001;size=2\nACGT\n+\nIIII\n".write(to: output, atomically: true, encoding: .utf8)
        let countedResult = CountedFASTQMaterializationResult(
            outputURL: output, inputRecordCount: 2, totalReadCount: 2, uniqueSequenceCount: 1, uniqueBaseCount: 4,
            weightedBaseCount: 8,
            materializedOutput: ProvenanceRecorder.fileRecord(url: countedRaw, format: .fastq, role: .output),
            compression: nil
        )
        let tool = bbmerge()
        let record = try await recordFASTQCountedMergeProvenance(
            cliArguments: ["merge", url("interleaved.fastq").path, "--count-duplicates", "--output", output.path],
            nativeArguments: tool.arguments,
            bbmergeResult: tool.result,
            inputURL: url("interleaved.fastq"),
            bbmergeOutputURLs: [url("merged.fastq"), url("unmerged.fastq")],
            countedResult: countedResult,
            finalOutputURL: output,
            parameters: ["input": .file(url("interleaved.fastq")), "output": .file(output),
                         "countDuplicatesAfterMerge": .boolean(true)],
            defaults: ["countDuplicatesAfterMerge": .boolean(false)],
            runClock: ProvenanceRunClock()
        )
        XCTAssertEqual(record.workflowName, "lungfish fastq merge")
        XCTAssertEqual(AffectedResults.kind(of: record)?.rawValue, "fastqCountedMerge")
    }

    /// Guard: the merge the app runs since MERGE-UNCOUNTED counts nothing and is no kind.
    func testTheRecordOfAnUncountedMergeIsNoKind() async throws {
        try writeReads()
        let concatenated = url("merged-and-unmerged.fastq")
        let output = url("merged.fastq.gz")
        try "@r1\nACGT\n+\nIIII\n@r2\nTTTT\n+\nIIII\n".write(to: concatenated, atomically: true, encoding: .utf8)
        try Data([0x1f, 0x8b, 0x08]).write(to: output)
        let tool = bbmerge()
        let record = try await recordFASTQMergeProvenance(
            cliArguments: ["merge", url("interleaved.fastq").path, "--output", output.path, "--compress"],
            nativeArguments: tool.arguments,
            bbmergeResult: tool.result,
            gzipResult: FASTQGzipProvenanceResult(
                command: ["/usr/bin/gzip", "-c", concatenated.path], inputURL: concatenated, outputURL: output,
                exitCode: 0, wallTime: 0.25, stderr: ""
            ),
            inputURL: url("interleaved.fastq"),
            bbmergeOutputURLs: [url("merged.fastq"), url("unmerged.fastq")],
            finalOutputURL: output,
            parameters: ["input": .file(url("interleaved.fastq")), "output": .file(output), "compress": .boolean(true)],
            defaults: ["compress": .boolean(false)],
            runClock: ProvenanceRunClock()
        )
        XCTAssertEqual(record.workflowName, "lungfish fastq merge")
        XCTAssertEqual(AffectedResults.kind(of: record)?.rawValue, nil)
    }
}

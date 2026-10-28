// ImportBAMPlainReadCountsLiveConformanceTests.swift - the plain route of import bam counts reads, with the real samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI
@testable import LungfishCore

/// Row IMPORT-BAM-PLAIN-IDXSTATS-AS-READS (review of lane MAPPED, N1). `lungfish import bam` into a plain folder summed the
/// idxstats rows into "Total reads", "Mapped reads" and "Unmapped reads" and wrote the same sums into its provenance record.
/// idxstats counts alignment records, so the supplementary fixture (13 records for 11 reads, 12 records mapped for 10 reads)
/// printed 12 of 13 (92.31%) where the reads are 10 of 11 (90.91%). This runs the command in this process with the real
/// samtools of the managed tool root, and `ImportBAMPlainStatisticsTests` is its stand-in. Its name keeps it out of the unit
/// tier. It skips on a Mac without samtools and fails there under `LUNGFISH_REQUIRE_TOOLS=1`.
final class ImportBAMPlainReadCountsLiveConformanceTests: XCTestCase {
    func testPlainImportPrintsAndRecordsTheReadsOfTheSupplementaryFixture() async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            try ToolAvailability.skipOrFail("samtools is not installed in the managed conda root: \(error)")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-bam-plain-read-counts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let fixtureBAM = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mapping/supplementary-one-contig/fixture.sorted.bam")

        let command = try ImportCommand.BAMSubcommand.parse([fixtureBAM.path, "--output-dir", folder.path, "--no-color"])
        let output = try await Self.captureStandardOutput { try await command.run() }

        XCTAssertEqual(Self.value(of: "Total reads", in: output), "11", "11 reads, not the 13 alignment records: \(output)")
        XCTAssertEqual(Self.value(of: "Mapped reads", in: output), "10 (90.91%)", "10 of 11 reads, not 12 of 13 records: \(output)")
        XCTAssertEqual(Self.value(of: "Unmapped reads", in: output), "1", output)

        let sidecar = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar), "the run writes its record")
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved["totalReads"]?.integerValue, 11, "the record holds the number the Summary printed")
        XCTAssertEqual(resolved["mappedReads"]?.integerValue, 10)
        XCTAssertEqual(resolved["unmappedReads"]?.integerValue, 1)
    }

    /// The words after a label in the Summary table, without the padding and the colon that the table puts after a label.
    private static func value(of label: String, in output: String) -> String? {
        let skipped = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":"))
        return output.split(separator: "\n")
            .first { $0.contains(label) }
            .flatMap { $0.components(separatedBy: label).last?.trimmingCharacters(in: skipped) }
    }

    private static func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        // Flush what earlier tests left in the buffer before the redirect, so it does not reach this pipe first.
        fflush(stdout)
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

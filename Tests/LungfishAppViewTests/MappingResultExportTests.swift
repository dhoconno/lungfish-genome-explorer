// MappingResultExportTests.swift - The mapping table export writes the stored rows and records the counts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// The export writes the rows a result holds and never filters them, so a
/// schema-1 result that lists references without alignments exports those
/// rows unchanged (BIO ruling Q-S3, BIO 1).
@MainActor
final class MappingResultExportTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping_result_export_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testExportWritesStoredRowsAndRecordsCounts() throws {
        let schemaOne = makeResult(
            in: "schema-one",
            contigs: [
                row("alpha", length: 100, reads: 42),
                row("beta", length: 200, reads: 0),
                row("gamma", length: 300, reads: 0),
            ]
        )

        let (content, resolved) = try export(schemaOne, to: "schema-one.csv")

        XCTAssertEqual(
            content,
            """
            Contig,Length,Mapped Reads,% Mapped,Mean Depth,Coverage Breadth,Median MAPQ,Mean Identity
            alpha,100,42,21.0000,2.4000,0.8000,60.0000,0.9900
            beta,200,0,0.0000,0.0000,0.0000,0.0000,0.0000
            gamma,300,0,0.0000,0.0000,0.0000,0.0000,0.0000

            """
        )
        XCTAssertEqual(content.split(separator: "\n").count, 1 + schemaOne.contigs.count)
        XCTAssertEqual(resolved["contigCount"]?.integerValue, 3)
        XCTAssertNil(resolved["referenceCount"], "a schema-1 result records no reference count")
        XCTAssertNil(resolved["unalignedReferenceCount"], "a schema-1 result records no unaligned count")

        let schemaTwo = makeResult(
            in: "schema-two",
            contigs: [row("alpha", length: 100, reads: 42), row("supplementary-only", length: 200, reads: 0)],
            referenceCount: 905_628,
            unalignedReferenceCount: 905_626
        )

        let (schemaTwoContent, schemaTwoResolved) = try export(schemaTwo, to: "schema-two.csv")

        let lines = schemaTwoContent.split(separator: "\n").map(String.init)
        XCTAssertEqual(
            lines.first,
            "Contig,Length,Mapped Reads,% Mapped,Mean Depth,Coverage Breadth,Median MAPQ,Mean Identity"
        )
        XCTAssertEqual(lines.count, 1 + schemaTwo.contigs.count, "the export writes the stored rows and no others")
        XCTAssertEqual(schemaTwoResolved["contigCount"]?.integerValue, 2)
        XCTAssertEqual(schemaTwoResolved["referenceCount"]?.integerValue, 905_628)
        XCTAssertEqual(schemaTwoResolved["unalignedReferenceCount"]?.integerValue, 905_626)
    }

    // MARK: - Helpers

    private func row(_ name: String, length: Int, reads: Int) -> MappingContigSummary {
        MappingContigSummary(
            contigName: name,
            contigLength: length,
            mappedReads: reads,
            mappedReadPercent: reads > 0 ? 21 : 0,
            meanDepth: reads > 0 ? 2.4 : 0,
            coverageBreadth: reads > 0 ? 0.8 : 0,
            medianMAPQ: reads > 0 ? 60 : 0,
            meanIdentity: reads > 0 ? 0.99 : 0
        )
    }

    private func makeResult(
        in folder: String,
        contigs: [MappingContigSummary],
        referenceCount: Int? = nil,
        unalignedReferenceCount: Int? = nil
    ) -> MappingResult {
        let directory = tempDir.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            bamURL: directory.appendingPathComponent("example.sorted.bam"),
            baiURL: directory.appendingPathComponent("example.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 42,
            unmappedReads: 158,
            wallClockSeconds: 1.5,
            contigs: contigs,
            referenceCount: referenceCount,
            unalignedReferenceCount: unalignedReferenceCount
        )
        try? Data("bam".utf8).write(to: result.bamURL)
        try? Data("bai".utf8).write(to: result.baiURL)
        return result
    }

    /// Exports `result` as CSV from a mapping viewport and returns the file's
    /// text and the export record's resolved values.
    private func export(
        _ result: MappingResult,
        to name: String
    ) throws -> (content: String, resolved: [String: ParameterValue]) {
        let vc = MappingResultViewController()
        _ = vc.view
        let resultDirectory = result.bamURL.deletingLastPathComponent()
        try result.save(to: resultDirectory)
        vc.configureForTesting(result: result, resultDirectoryURL: resultDirectory)

        let outputURL = tempDir.appendingPathComponent(name)
        try vc.exportResults(to: outputURL, format: .csv)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        return (try String(contentsOf: outputURL, encoding: .utf8), envelope.options.resolvedDefaults)
    }
}

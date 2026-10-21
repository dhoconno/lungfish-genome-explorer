// SequenceExportRouteTests.swift - The pieces of the sequence export route that need no lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3. `SequenceExportRoute` builds the `convert` arguments the row records and the run
// executes, decides which files `convert` reads, and removes the stage files a stopped command leaves. Since
// Phase 2.12 lane 12.13 a file that `convert` does not read is staged first (`SequenceExportStagingDurabilityTests`).
// `SequenceExportPinConformanceTests` runs the route against the built command.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class SequenceExportRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sequence-export-route")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testArgumentsCarryEveryInputTheCompressorAndTheAnnotationRule() {
        let first = URL(fileURLWithPath: "/tmp/in/first.fa")
        let bundle = URL(fileURLWithPath: "/tmp/in/Alpha.lungfishref", isDirectory: true)
        let output = URL(fileURLWithPath: "/tmp/out/both.gb.gz")

        XCTAssertEqual(
            SequenceExportRoute.arguments(inputs: [first, bundle], outputURL: output, format: .genbank, compression: .gzip),
            ["convert", first.path, bundle.path, "--to", output.path, "--to-format", "genbank",
             "--include-annotations", "--compress", "gzip", "--force", "--format", "json", "--quiet"]
        )
        // A FASTA export of plain files carries no annotation flag, a bundle always does.
        XCTAssertFalse(
            SequenceExportRoute.arguments(inputs: [first], outputURL: output, format: .fasta, compression: .none)
                .contains("--include-annotations")
        )
        XCTAssertTrue(
            SequenceExportRoute.arguments(inputs: [bundle], outputURL: output, format: .fasta, compression: .zstd)
                .contains("--include-annotations")
        )
    }

    func testConvertReadsTheExtensionsItDetectsAfterAGzSuffix() {
        for name in ["a.fa", "a.FASTA", "a.fna", "a.gb", "a.gbff", "a.fastq.gz", "A.lungfishref", "a.fa.gz"] {
            XCTAssertTrue(SequenceExportRoute.convertReads(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.seq", "a.txt", "a", "a.gff3", "a.bam"] {
            XCTAssertFalse(SequenceExportRoute.convertReads(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        let output = URL(fileURLWithPath: "/tmp/out.fa")
        XCTAssertNil(AppDelegate.sequenceExportCLICommand(
            inputURLs: [URL(fileURLWithPath: "/tmp/a.fa"), URL(fileURLWithPath: "/tmp/a.seq")],
            outputURL: output, format: .fasta, compression: .none
        ), "a file convert cannot read is staged before the row, so no command names it")
    }

    /// The error of a refused export names the file the person chose, not the copy staging made of it (MD59).
    func testTheErrorNamesTheChosenFileNotTheStagedCopy() throws {
        let chosen = root.appendingPathComponent("my reads.seq")
        let plain = root.appendingPathComponent("11-empty.seq.fa")
        let folder = root.appendingPathComponent("sequence-export-a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent("1-empty.seq.fa")
        let metadata = [chosen, plain].map { url in
            SequenceExportSourceResolver.Metadata(
                kind: .filesystem, url: url, documentID: nil, nativeSequenceID: nil, projectURL: nil
            )
        }
        try JSONEncoder().encode(metadata)
            .write(to: folder.appendingPathComponent(SequenceExportStaging.selectionFileName))
        let output = root.appendingPathComponent("out.fa")
        let arguments = SequenceExportRoute.arguments(
            inputs: [staged, plain], outputURL: output, format: .fasta, compression: .none
        )
        XCTAssertEqual(
            SequenceExportRoute.namingChosenFiles(
                in: "Error: Conversion failed: No sequences found in 1-empty.seq.fa.", arguments: arguments
            ),
            "Error: Conversion failed: No sequences found in my reads.seq."
        )
        XCTAssertEqual(
            SequenceExportRoute.namingChosenFiles(in: "Error: Input file not found: \(staged.path)", arguments: arguments),
            "Error: Input file not found: \(chosen.path)"
        )
        // A file the person chose keeps its own name, even when a staged name lies inside it.
        XCTAssertEqual(
            SequenceExportRoute.namingChosenFiles(in: "No sequences found in 11-empty.seq.fa.", arguments: arguments),
            "No sequences found in 11-empty.seq.fa."
        )
        // A run that staged nothing keeps its text.
        let unstaged = SequenceExportRoute.arguments(inputs: [plain], outputURL: output, format: .fasta, compression: .none)
        XCTAssertEqual(
            SequenceExportRoute.namingChosenFiles(in: "No sequences found in 1-empty.seq.fa.", arguments: unstaged),
            "No sequences found in 1-empty.seq.fa."
        )
    }

    func testRemoveStagesRemovesOnlyTheHiddenConvertStagesOfThatOutput() throws {
        let output = root.appendingPathComponent("out.fa.gz")
        let stages = [
            ".out.fa.gz.AAAA.convert.tmp",
            "..out.fa.gz.AAAA.convert.tmp.lungfish-stage-BBBB",
        ]
        let keep = [".other.fa.gz.AAAA.convert.tmp", "out.fa.gz", ".out.fa.gz.note", "notes.txt"]
        for name in stages + keep {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".out.fa.gz.CCCC.convert.d"), withIntermediateDirectories: true
        )

        SequenceExportRoute.removeStages(beside: output)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(remaining, keep.sorted())
    }
}

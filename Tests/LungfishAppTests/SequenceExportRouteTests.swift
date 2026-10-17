// SequenceExportRouteTests.swift - The pieces of the sequence export route that need no lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3. `SequenceExportRoute` builds the `convert` arguments the row records and the run
// executes, decides which files `convert` reads, and removes the stage files a stopped command leaves. A file
// that `convert` does not read stays on the app's own writer, which compresses on `SequenceExportCompressor`.
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
        ), "one file that convert cannot read leaves the row with no command")
        XCTAssertNil(AppDelegate.sequenceExportCLICommand(
            inputURLs: [], outputURL: output, format: .fasta, compression: .none
        ), "a captured snapshot has no file")
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

    func testAFileConvertDoesNotReadStaysOnTheAppWriterAndCompressesWithGzip() async throws {
        let input = root.appendingPathComponent("reads.seq")
        try ">one\nACGT\n>two\nTTGGCC\n".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out.fa.gz")

        let count = try await makeAppDelegateWithTemporaryState().performSequenceExport(
            sources: [.init(
                metadata: .init(kind: .filesystem, url: input, documentID: nil, nativeSequenceID: nil, projectURL: nil),
                document: nil
            )],
            outputURL: output, format: .fasta, compression: .gzip
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(try Data(contentsOf: output).prefix(2)), [0x1f, 0x8b], "a gzip container")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(text, ">one\nACGT\n>two\nTTGGCC\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
    }
}

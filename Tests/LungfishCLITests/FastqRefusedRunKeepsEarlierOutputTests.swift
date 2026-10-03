// FastqRefusedRunKeepsEarlierOutputTests.swift - A refused fastq run leaves the earlier output in place
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli fastq demultiplex --replace` deleted its output folder
// before it checked the input. Lane 1x moved the input check and the bundle
// materialization into `FASTQSubcommandInput`, which ran after the output
// step, so a mistyped input path or a virtual bundle whose root had moved
// refused the run after the earlier barcode bundles were gone. A mistyped
// kit did the same before lane 1x. The command now checks its output without
// touching it, resolves the input and the arguments, and deletes the earlier
// results only once every refusal has passed (R3, final review B2).
//
// Every other single-input `fastq` subcommand that resolves its input
// through `FASTQSubcommandInput` refuses a missing input before it writes or
// deletes anything in its output, and the table below holds each one to it.
// No case runs a tool.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FastqRefusedRunKeepsEarlierOutputTests: XCTestCase {
    private var root: URL!
    private var kitCSV: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-refused-run-output")
        kitCSV = root.appendingPathComponent("kit.csv")
        try "id,sequence\nBC01,ACGTACGTACGT\n".write(to: kitCSV, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private var missingInput: String {
        root.appendingPathComponent("typo-missing.fastq").path
    }

    /// An earlier demultiplex output folder with one barcode bundle and a manifest.
    private func writeEarlierDemultiplexOutput() throws -> (folder: URL, files: [URL: Data]) {
        let folder = root.appendingPathComponent("demux-out", isDirectory: true)
        let bundle = folder.appendingPathComponent("BC01.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        let manifest = folder.appendingPathComponent(DemultiplexManifest.filename)
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try "{}".write(to: manifest, atomically: true, encoding: .utf8)
        return (folder, [reads: try Data(contentsOf: reads), manifest: try Data(contentsOf: manifest)])
    }

    private func assertUnchanged(_ files: [URL: Data], file: StaticString = #filePath, line: UInt = #line) {
        for (url, data) in files {
            XCTAssertEqual(
                FileManager.default.contents(atPath: url.path), data,
                "the refused run kept \(url.lastPathComponent)", file: file, line: line
            )
        }
    }

    private func runDemultiplex(_ arguments: [String]) async throws {
        var command = try FastqDemultiplexSubcommand.parse(arguments)
        try await command.run()
    }

    // MARK: - demultiplex --replace

    func testDemultiplexReplaceWithAMissingInputKeepsTheEarlierOutput() async throws {
        let earlier = try writeEarlierDemultiplexOutput()
        do {
            try await runDemultiplex([missingInput, "--kit", kitCSV.path, "--output", earlier.folder.path, "--replace"])
            XCTFail("a missing input must refuse the run")
        } catch CLIError.inputFileNotFound(let path) {
            XCTAssertEqual(path, missingInput)
        }
        assertUnchanged(earlier.files)
    }

    /// A virtual bundle whose root has moved cannot be materialized.
    func testDemultiplexReplaceWithAnUnreadableVirtualBundleKeepsTheEarlierOutput() async throws {
        let earlier = try writeEarlierDemultiplexOutput()
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let subset = imports.appendingPathComponent("moved-root-subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: subset, withIntermediateDirectories: true)
        try "r1\n".write(to: subset.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: subset.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "r")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "moved-root-subset",
                parentBundleRelativePath: "@/Imports/moved-away.lungfishfastq",
                rootBundleRelativePath: "@/Imports/moved-away.lungfishfastq",
                rootFASTQFilename: "moved-away-reads.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: subset
        )
        do {
            try await runDemultiplex([subset.path, "--kit", kitCSV.path, "--output", earlier.folder.path, "--replace"])
            XCTFail("a virtual bundle whose root is gone must refuse the run")
        } catch FASTQCLIMaterializerError.rootBundleMissing {
        }
        assertUnchanged(earlier.files)
    }

    /// A mistyped kit refused the run after the output was deleted, before
    /// lane 1x as well.
    func testDemultiplexReplaceWithAnUnknownKitKeepsTheEarlierOutput() async throws {
        let earlier = try writeEarlierDemultiplexOutput()
        let input = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        do {
            try await runDemultiplex([input.path, "--kit", "no-such-kit", "--output", earlier.folder.path, "--replace"])
            XCTFail("an unknown kit must refuse the run")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("no-such-kit"), error.message)
        }
        assertUnchanged(earlier.files)
    }

    // MARK: - Every subcommand with the FASTQSubcommandInput prologue

    /// One subcommand, its arguments around a missing input, and the earlier
    /// output it is given, with the flag that lets it overwrite that output.
    private struct Case {
        let name: String
        let arguments: [String]
        let earlierFiles: [URL]
    }

    /// An earlier output file at `name` in the scratch folder.
    private func earlierFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "earlier result of \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func cases() throws -> [Case] {
        let input = missingInput
        /// A subcommand that takes `OutputOptions`, run with `--force`.
        func forced(_ subcommand: String, _ extra: [String] = []) throws -> Case {
            let output = try earlierFile("\(subcommand)/earlier.fastq")
            return Case(
                name: subcommand,
                arguments: ["fastq", subcommand, input] + extra + ["-o", output.path, "--force"],
                earlierFiles: [output]
            )
        }
        /// A subcommand that writes into an output folder.
        func intoFolder(_ subcommand: String, _ extra: [String] = []) throws -> Case {
            let earlier = try earlierFile("\(subcommand)/out/earlier.fastq")
            return Case(
                name: subcommand,
                arguments: ["fastq", subcommand, input] + extra + ["-o", earlier.deletingLastPathComponent().path],
                earlierFiles: [earlier]
            )
        }
        let demultiplexEarlier = try earlierFile("demultiplex/out/BC01.lungfishfastq/reads.fastq")
        let scoutEarlier = try earlierFile("scout/scout-result.json")
        let out1 = try earlierFile("deinterleave/R1.fastq")
        let out2 = try earlierFile("deinterleave/R2.fastq")
        // `orient` checks its reference before its input, so the reference exists.
        let reference = root.appendingPathComponent("reference.fasta")
        try ">ref\nACGTACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        return [
            try forced("subsample", ["--proportion", "0.5"]),
            try forced("length-filter", ["--min", "10"]),
            try forced("trim"),
            try forced("quality-trim"),
            try forced("adapter-trim"),
            try forced("fixed-trim", ["--front", "2"]),
            try forced("contaminant-filter"),
            try forced("entropy-filter"),
            try forced("primer-remove", ["--literal", "ACGTACGT"]),
            try forced("error-correct"),
            try forced("merge"),
            try forced("repair"),
            try forced("deduplicate"),
            try forced("search-text", ["--query", "r1"]),
            try forced("search-motif", ["--pattern", "ACGT"]),
            try forced("orient", ["--reference", reference.path]),
            try forced("scrub-human", ["--database-id", "human-scrubber"]),
            try forced("sequence-filter", ["--sequence", "ACGTACGT"]),
            try forced("reverse-complement"),
            try forced("translate"),
            Case(
                name: "demultiplex",
                arguments: [
                    "fastq", "demultiplex", input, "--kit", kitCSV.path,
                    "-o", demultiplexEarlier.deletingLastPathComponent().deletingLastPathComponent().path, "--replace",
                ],
                earlierFiles: [demultiplexEarlier]
            ),
            Case(
                name: "scout",
                arguments: ["fastq", "scout", input, "--kit", kitCSV.path, "-o", scoutEarlier.path],
                earlierFiles: [scoutEarlier]
            ),
            Case(
                name: "deinterleave",
                arguments: ["fastq", "deinterleave", input, "--out1", out1.path, "--out2", out2.path],
                earlierFiles: [out1, out2]
            ),
            try intoFolder("ribodetector"),
            try intoFolder("deacon-ribo"),
        ]
    }

    func testEverySubcommandRefusesAMissingInputBeforeItTouchesItsOutput() async throws {
        let table = try cases()
        XCTAssertEqual(table.count, 25, "every fastq subcommand that resolves its input through FASTQSubcommandInput")
        for testCase in table {
            let earlier = try Dictionary(uniqueKeysWithValues: testCase.earlierFiles.map { ($0, try Data(contentsOf: $0)) })
            let parsed = try LungfishCLI.parseAsRoot(testCase.arguments)
            guard var command = parsed as? any AsyncParsableCommand else {
                XCTFail("\(testCase.name) parsed to \(type(of: parsed))")
                continue
            }
            do {
                try await command.run()
                XCTFail("\(testCase.name) ran with a missing input")
            } catch CLIError.inputFileNotFound(let path) {
                XCTAssertEqual(path, missingInput, testCase.name)
            } catch {
                XCTFail("\(testCase.name) refused for another reason first: \(error)")
            }
            for (url, data) in earlier {
                XCTAssertEqual(
                    FileManager.default.contents(atPath: url.path), data,
                    "\(testCase.name) kept the earlier \(url.lastPathComponent)"
                )
            }
        }
    }
}

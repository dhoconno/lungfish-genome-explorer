// EsVirituStagingNamesProbeTests.swift - Each EsViritu input is staged as its own file, whatever its name holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session probe PROBES-B, row ESV-STAGING-SYMBOL-NAMES, fixed by lane FIX-ESV. When a path holds a space,
// `EsVirituPipeline.detect` links each input into `_input_links` and gives EsViritu the links. Whatever the names hold, each
// link must resolve to its own input. The cases are two inputs of one name in different folders (the F1 class), two names that
// differ only by a space and an underscore, a symbol in a name (the W-1 class) and links left by a run that failed. The
// stand-in EsViritu below writes down each file after `-r`, as the tool is given it, with the first line of the file it
// resolves to. No EsViritu runs, and what the real tool does with a `#`, `'` or `&` in a path it is given is not measured here.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

private struct StagingStandIn {
    let root: URL
    let condaManager: CondaManager
    let database: URL
    /// While this file exists the stand-in EsViritu exits 1 before it logs anything, as a run that fails does.
    let failFlag: URL

    init() throws {
        let fm = FileManager.default
        root = try TestTempDirectory.make(prefix: "esviritu-staging")
        database = root.appendingPathComponent("esviritu-db", isDirectory: true)
        failFlag = root.appendingPathComponent("fail.flag")
        try fm.createDirectory(at: database, withIntermediateDirectories: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        // The conda manager installs a copy of the bundled micromamba, so the script names its files by absolute path.
        let log = root.appendingPathComponent("staging.log").path
        try Self.script
            .replacingOccurrences(of: "__LOG__", with: log)
            .replacingOccurrences(of: "__FAIL__", with: failFlag.path)
            .write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func remove() {
        TestTempDirectory.cleanup(root)
    }

    /// A file of `folder` named `name` whose one line says which file it is.
    func input(folder: String, name: String, line: String) throws -> URL {
        let directory = root.appendingPathComponent("inputs/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try "\(line)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func config(inputs: [URL], paired: Bool, sample: String = "sample") -> EsVirituConfig {
        EsVirituConfig(
            inputFiles: inputs, isPairedEnd: paired, sampleName: sample,
            outputDirectory: root.appendingPathComponent("Analyses/esviritu/\(sample)", isDirectory: true),
            databasePath: database, threads: 2, readFormat: paired ? .paired : .unpaired
        )
    }

    /// The staged path each `-r` file was given as, with the first line of what it resolved to, in the order given.
    func given() throws -> [(path: String, line: String)] {
        let log = root.appendingPathComponent("staging.log")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { row in
            let parts = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }
    }

    private static let script = #"""
        #!/bin/sh
        LOG='__LOG__'
        if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
        [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
        shift
        if [ "$1" = "-n" ]; then shift; shift; fi
        tool="$1"; shift
        [ "$tool" = "EsViritu" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
        if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then echo "EsViritu 1.3.3"; exit 0; fi
        if [ -e '__FAIL__' ]; then echo "EsViritu stand-in failed on request" >&2; exit 1; fi
        sample=""; output=""; collecting=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -r) collecting=1 ;;
            -s) collecting=0; shift; sample="$1" ;;
            -o) collecting=0; shift; output="$1" ;;
            -*) collecting=0 ;;
            *) if [ "$collecting" = "1" ]; then printf '%s\t%s\n' "$1" "$(head -n 1 "$1")" >> "$LOG"; fi ;;
          esac
          shift
        done
        mkdir -p "$output"
        printf 'sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample\n' > "$output/$sample.detected_virus.info.tsv"
        echo "EsViritu stand-in finished" >&2
        exit 0
        """#
}

final class EsVirituStagingNamesProbeTests: XCTestCase {
    private func detect(_ config: EsVirituConfig, with standIn: StagingStandIn) async throws {
        _ = try await EsVirituPipeline(condaManager: standIn.condaManager).detect(config: config)
    }

    /// A pair whose mates share a name in two folders, with a space in the path so the run stages its inputs.
    func testTwoMatesOfOneNameInTwoFoldersAreStagedAsTwoFiles() async throws {
        let standIn = try StagingStandIn()
        defer { standIn.remove() }
        let mate1 = try standIn.input(folder: "Run A", name: "reads.fastq.gz", line: "mate-1-from-run-A")
        let mate2 = try standIn.input(folder: "Run B", name: "reads.fastq.gz", line: "mate-2-from-run-B")
        try await detect(standIn.config(inputs: [mate1, mate2], paired: true), with: standIn)
        let given = try standIn.given()
        // Measured red at af54540c8 before the fix: the second link replaced the first at the same path, so both mates
        // resolved to run B's file and the pair was read as mate 2 twice (S1, BACKLOG ESV-STAGING-SYMBOL-NAMES).
        XCTAssertEqual(given.map(\.line), ["mate-1-from-run-A", "mate-2-from-run-B"], "given \(given)")
        XCTAssertEqual(Set(given.map(\.path)).count, 2, "each mate is staged at a path of its own: \(given)")
    }

    /// Two names that differ only by a space and an underscore, in one folder, are two files for the tool.
    func testTwoNamesThatDifferOnlyBySpaceAndUnderscoreAreStagedAsTwoFiles() async throws {
        let standIn = try StagingStandIn()
        defer { standIn.remove() }
        let withSpace = try standIn.input(folder: "Run A", name: "reads 1.fastq.gz", line: "reads-named-with-a-space")
        let withUnderscore = try standIn.input(folder: "Run A", name: "reads_1.fastq.gz", line: "reads-named-with-an-underscore")
        try await detect(standIn.config(inputs: [withSpace, withUnderscore], paired: false), with: standIn)
        let given = try standIn.given()
        XCTAssertEqual(given.map(\.line), ["reads-named-with-a-space", "reads-named-with-an-underscore"], "given \(given)")
    }

    /// A run that fails leaves its links in the output folder, and the next run into that folder links the same inputs
    /// again, each at the path its earlier link has, so a link that is there must not stop the run.
    func testLinksLeftByAFailedRunDoNotStopTheNextRunIntoTheSameFolder() async throws {
        let standIn = try StagingStandIn()
        defer { standIn.remove() }
        let mate1 = try standIn.input(folder: "Run A", name: "reads.fastq.gz", line: "mate-1-from-run-A")
        let mate2 = try standIn.input(folder: "Run B", name: "reads.fastq.gz", line: "mate-2-from-run-B")
        let config = standIn.config(inputs: [mate1, mate2], paired: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: standIn.failFlag.path, contents: Data()))
        do {
            try await detect(config, with: standIn)
            XCTFail("the stand-in EsViritu was set to fail")
        } catch is EsVirituPipelineError {
            // The failed first run.
        }
        let links = config.outputDirectory.appendingPathComponent("_input_links", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: links.path), "a failed run leaves its links, the premise of this test")
        try FileManager.default.removeItem(at: standIn.failFlag)
        try await detect(config, with: standIn)
        let given = try standIn.given()
        XCTAssertEqual(given.map(\.line), ["mate-1-from-run-A", "mate-2-from-run-B"], "given \(given)")
    }

    /// Two samples, each with a `reads.fastq.gz` of its own folder, run as the batch does, one config and one output a sample.
    func testTwoSamplesOfOneFileNameEachStageTheirOwnFile() async throws {
        let first = try StagingStandIn()
        defer { first.remove() }
        let second = try StagingStandIn()
        defer { second.remove() }
        let readsOfS1 = try first.input(folder: "Run A", name: "reads.fastq.gz", line: "reads-of-S1")
        let readsOfS2 = try second.input(folder: "Run B", name: "reads.fastq.gz", line: "reads-of-S2")
        try await detect(first.config(inputs: [readsOfS1], paired: false, sample: "S1"), with: first)
        try await detect(second.config(inputs: [readsOfS2], paired: false, sample: "S2"), with: second)
        XCTAssertEqual(try first.given().map(\.line), ["reads-of-S1"])
        XCTAssertEqual(try second.given().map(\.line), ["reads-of-S2"])
    }

    /// A name with a space, `#`, `'` and `&` keeps its symbols, loses its spaces and reaches the tool as one argument.
    func testNamesHoldingASymbolReachTheToolIntactAndResolveToTheirOwnFile() async throws {
        let standIn = try StagingStandIn()
        defer { standIn.remove() }
        let name = "it's #1 & co.fastq.gz"
        let reads = try standIn.input(folder: "Run A", name: name, line: "reads-with-symbols")
        try await detect(standIn.config(inputs: [reads], paired: false), with: standIn)
        let given = try standIn.given()
        XCTAssertEqual(given.map(\.line), ["reads-with-symbols"], "given \(given)")
        let stagedName = try XCTUnwrap(given.first.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertFalse(stagedName.contains(" "), "a staged name holds no space: \(stagedName)")
        XCTAssertTrue(stagedName.hasSuffix("it's_#1_&_co.fastq.gz"), "the symbols and the ending of the name stay: \(stagedName)")
    }
}

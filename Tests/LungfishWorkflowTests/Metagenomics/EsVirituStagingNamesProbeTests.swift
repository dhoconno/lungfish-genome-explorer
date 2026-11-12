// EsVirituStagingNamesProbeTests.swift - Each EsViritu input is staged as its own file, whatever its name holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session probe PROBES-B, row ESV-STAGING-SYMBOL-NAMES. `EsVirituPipeline.detect` links each input into
// `_input_links` under its last path component with only spaces replaced, when a path holds a space, so two inputs of one
// name in different folders (the F1 class) or a symbol in a name (the W-1 class) may hit it. The stand-in EsViritu below
// writes down each file after `-r`, as the tool is given it, with the first line of the file it resolves to. No EsViritu
// runs, and what the real tool does with a `#`, `'` or `&` in a path it is given is not measured here.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

private struct StagingStandIn {
    let root: URL
    let condaManager: CondaManager
    let database: URL

    init() throws {
        let fm = FileManager.default
        root = try TestTempDirectory.make(prefix: "esviritu-staging")
        database = root.appendingPathComponent("esviritu-db", isDirectory: true)
        try fm.createDirectory(at: database, withIntermediateDirectories: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        // The conda manager installs a copy of the bundled micromamba, so the script names its log by absolute path.
        let log = root.appendingPathComponent("staging.log").path
        try Self.script.replacingOccurrences(of: "__LOG__", with: log).write(to: micromamba, atomically: true, encoding: .utf8)
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
        // Measured at af54540c8, red at this line without the expectation: the second link replaces the first at the same
        // path, so both mates resolve to run B's file and the pair is read as mate 2 twice. The fix lane removes this
        // expectation (S1, BACKLOG ESV-STAGING-SYMBOL-NAMES).
        XCTExpectFailure("ESV-STAGING-SYMBOL-NAMES: both mates are staged as the second file") {
            XCTAssertEqual(given.map(\.line), ["mate-1-from-run-A", "mate-2-from-run-B"], "given \(given)")
        }
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
        XCTAssertEqual(given.first.map { URL(fileURLWithPath: $0.path).lastPathComponent }, "it's_#1_&_co.fastq.gz")
    }
}

// NvdSamtoolsSpawnPinTests.swift - The two samtools spawns of the NVD import that lane 13.10 moves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Pins of `metagenomicsExternalToolVersion` (the `--version` probe that gives every samtools step its `toolVersion`)
/// and `nvdCountReadsWithTelemetry` (the `view -c` that fills `unique_reads`), both private to
/// `MetagenomicsImportService`, through `importNvd` with a stand-in samtools (Phase 2.13 lane 13.10, M2 (3)).
/// They pass on the `Process` spawns of the base and unchanged on `ToolProcess`.
final class NvdSamtoolsSpawnPinTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-samtools-spawn-pins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
    }

    private static let csv = """
    experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank
    EXP001,blastn,S1,contig-1,120,gb|NC_001|,Example virus species,S,118,99.2,1e-20,250.5,Example virus,12345,nt-2026,run-001,42,100000,stat-1,12345,unchanged,Example virus,species

    """

    private func makeNvdRun() throws -> URL {
        let run = workspace.appendingPathComponent("nvd-run", isDirectory: true)
        let labkey = run.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        let results = run.appendingPathComponent("02_human_viruses/03_human_virus_results", isDirectory: true)
        let mapped = results.appendingPathComponent("mapped_reads", isDirectory: true)
        try FileManager.default.createDirectory(at: labkey, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mapped, withIntermediateDirectories: true)
        try Self.csv.write(to: labkey.appendingPathComponent("sample_blast_concatenated.csv"),
                           atomically: true, encoding: .utf8)
        try "synthetic bam payload\n".write(to: mapped.appendingPathComponent("S1.filtered.bam"),
                                            atomically: true, encoding: .utf8)
        try "synthetic bai payload\n".write(to: mapped.appendingPathComponent("S1.filtered.bam.bai"),
                                            atomically: true, encoding: .utf8)
        try ">contig-1\nACGTACGT\n".write(to: results.appendingPathComponent("S1.human_virus.fasta"),
                                         atomically: true, encoding: .utf8)
        return run
    }

    /// A samtools that logs its `--version` and `view -c` calls, one append each, and answers by the two shell
    /// fragments. The rest is the stand-in of `MetagenomicsImportServiceTests`.
    private func makeSamtools(versionCode: String, countCode: String) throws -> URL {
        let url = workspace.appendingPathComponent("fake-samtools")
        let script = #"""
        #!/bin/sh
        set -eu
        dir="$(cd "$(dirname "$0")" && pwd -P)"
        command="${1:-}"
        if [ "$command" = "--version" ]; then
          printf '[--version]\n' >> "$dir/calls.log"
        \#(versionCode)
          exit 0
        fi
        case "$command" in
          view)
            if [ "${2:-}" = "-H" ]; then exit 0; fi
            if [ "${2:-}" = "-c" ]; then
              args=""
              for a in "$@"; do args="${args}[${a}]"; done
              printf '%s\n' "$args" >> "$dir/calls.log"
              if [ "${4:-}" = "1028" ]; then
        \#(countCode)
              else
                echo 7
              fi
            fi
            exit 0 ;;
          sort|fixmate)
            cat >/dev/null || true
            echo "fake-bam-stream"
            exit 0 ;;
          markdup)
            output=""
            for arg in "$@"; do output="$arg"; done
            cat >/dev/null || true
            printf 'fake markdup bam\n' > "$output"
            exit 0 ;;
          index)
            printf 'fake index\n' > "$2.bai"
            exit 0 ;;
          *)
            echo "unsupported fake samtools command: $command" >&2
            exit 2 ;;
        esac
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private struct Imported {
        let result: NvdImportResult
        let samtools: URL
        let steps: [ProvenanceStep]
        let calls: [String]
    }

    private func runImport(versionCode: String, countCode: String) async throws -> Imported {
        let samtools = try makeSamtools(versionCode: versionCode, countCode: countCode)
        let result = try await MetagenomicsImportService.importNvd(
            inputURL: try makeNvdRun(),
            outputDirectory: workspace.appendingPathComponent("imports", isDirectory: true),
            samtoolsPath: samtools.path)
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: result.resultDirectory))
        let log = (try? String(contentsOf: workspace.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return Imported(result: result, samtools: samtools,
                        steps: envelope.steps.filter { $0.toolName == "samtools" },
                        calls: log.split(separator: "\n").map(String.init))
    }

    private func countStep(_ imported: Imported) throws -> ProvenanceStep {
        // The markdup replay step is `/bin/sh -c ...`, so the `view` and `-c` pair picks the count alone.
        try XCTUnwrap(imported.steps.first { $0.argv.count > 2 && $0.argv[1] == "view" && $0.argv[2] == "-c" })
    }

    func testTheCountStepRecordsItsArgvStatusAndParsedCountAndTheProbeRunsOnce() async throws {
        let imported = try await runImport(versionCode: "  echo 'samtools fake 1.0'", countCode: "      echo 7")
        XCTAssertEqual(imported.result.uniqueReadRowsUpdated, 1)
        let step = try countStep(imported)
        XCTAssertEqual(step.argv.count, 7)
        XCTAssertEqual(step.argv.first, imported.samtools.path)
        XCTAssertEqual(Array(step.argv[1...4]), ["view", "-c", "-F", "1028"])
        XCTAssertEqual(URL(fileURLWithPath: step.argv[5]).lastPathComponent, "S1.bam")
        XCTAssertEqual(step.argv.last, "gb|NC_001|")
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertEqual(step.toolVersion, "samtools fake 1.0")
        XCTAssertTrue(step.outputs.contains { $0.path.hasSuffix("hits.sqlite") })
        XCTAssertEqual(imported.calls.filter { $0 == "[--version]" }.count, 1)
        let counts = imported.calls.filter { $0.hasPrefix("[view][-c][-F][1028][") }
        XCTAssertEqual(counts.count, 1)
        XCTAssertTrue(counts.first?.hasSuffix("/S1.bam][gb|NC_001|]") == true, "\(counts)")
    }

    func testTheVersionIsTheFirstNonEmptyLineOfStdoutThenStderr() async throws {
        let imported = try await runImport(
            versionCode: "  printf '\\n\\nsamtools fake 3.0\\nUsing htslib 9\\n'\n  echo 'a warning' >&2",
            countCode: "      echo 7")
        XCTAssertFalse(imported.steps.isEmpty)
        XCTAssertTrue(imported.steps.allSatisfy { $0.toolVersion == "samtools fake 3.0" },
                      "\(imported.steps.map(\.toolVersion))")
    }

    func testAVersionPrintedOnlyOnStderrIsStillTheVersion() async throws {
        let imported = try await runImport(
            versionCode: "  printf '  samtools fake 2.0 (stderr)  \\nUsing htslib 9\\n' >&2",
            countCode: "      echo 7")
        XCTAssertFalse(imported.steps.isEmpty)
        XCTAssertTrue(imported.steps.allSatisfy { $0.toolVersion == "samtools fake 2.0 (stderr)" },
                      "\(imported.steps.map(\.toolVersion))")
    }

    func testAToolThatPrintsNoVersionIsRecordedAsUnknown() async throws {
        let imported = try await runImport(versionCode: "  :", countCode: "      echo 7")
        XCTAssertFalse(imported.steps.isEmpty)
        XCTAssertTrue(imported.steps.allSatisfy { $0.toolVersion == "unknown" },
                      "\(imported.steps.map(\.toolVersion))")
    }

    func testAFailingCountRecordsItsStatusAndTrimmedStderrAndFillsNoRow() async throws {
        let imported = try await runImport(
            versionCode: "  echo 'samtools fake 1.0'",
            countCode: "      printf 'count exploded  \\n\\n' >&2\n      exit 3")
        XCTAssertEqual(imported.result.uniqueReadRowsUpdated, 0)
        let step = try countStep(imported)
        XCTAssertEqual(step.exitStatus, 3)
        XCTAssertEqual(step.stderr, "count exploded")
        XCTAssertTrue(step.outputs.isEmpty)
    }

    func testANonNumericCountExitsCleanButFillsNoRow() async throws {
        let imported = try await runImport(versionCode: "  echo 'samtools fake 1.0'", countCode: "      echo many")
        XCTAssertEqual(imported.result.uniqueReadRowsUpdated, 0)
        let step = try countStep(imported)
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertNil(step.stderr)
        XCTAssertTrue(step.outputs.isEmpty)
    }
}

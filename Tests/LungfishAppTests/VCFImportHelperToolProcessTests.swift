// VCFImportHelperToolProcessTests.swift - The per-chromosome VCF helper never deadlocks on a full pipe
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import os
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishApp

/// The per-chromosome VCF import runs bcftools and a child helper import.
/// Each of those used to wait for the process to exit before reading either
/// pipe, so a run that wrote more than 64 KB to stdout or stderr blocked on a
/// full pipe forever (Phase 2.2 lane 3B1, finding R7).
///
/// The tests reach the spawns through the seams the helper already has. The
/// managed bcftools resolves through `LUNGFISH_CONDA_ROOT`, and the child
/// helper is whatever executable argv[0] names, so the subprocess tests launch
/// the built `Lungfish` executable with argv[0] pointing at a fake helper.
final class VCFImportHelperToolProcessTests: VCFImportHelperSubprocessTestCase {
    // MARK: - bcftools runs

    /// Every bcftools run writes well over 64 KB to both streams. The helper
    /// must drain them while bcftools runs, finish the per-chromosome pass
    /// (the shard reports no records) and fall back to a single-pass import.
    func testBcftoolsWritingOver64KBToBothStreamsDoesNotDeadlock() throws {
        let condaRoot = try makeFakeBcftools(body: """
        case "$1 $2" in
          "index --nrecords") echo 0 ;;
        esac
        \(Self.noiseLoop)
        exit 0
        """)
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")

        let exitCode = try withEnvironment("LUNGFISH_CONDA_ROOT", condaRoot.path) {
            try runHelperInProcess(arguments: [
                "Lungfish", "--vcf-import-helper",
                "--vcf-path", input.path,
                "--output-db-path", output.path,
                "--import-profile", "ultra-low-memory",
            ])
        }

        XCTAssertEqual(exitCode, 0)
        // The helper defers the index build to the app, so the database is
        // still marked as indexing and only its rows can be read.
        XCTAssertEqual(try Self.rows(output, "SELECT COUNT(*) FROM variants", quoted: false), ["9"])
        let bcftoolsRuns = try String(contentsOf: pidFile, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(bcftoolsRuns, 4, "index source, view, index shard and index --nrecords")
    }

    func testFailingBcftoolsWithOver64KBOfOutputFailsTheImport() throws {
        let condaRoot = try makeFakeBcftools(body: """
        \(Self.noiseLoop)
        echo "bcftools: index exploded" >&2
        exit 3
        """)
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")
        let exitCode = try withEnvironment("LUNGFISH_CONDA_ROOT", condaRoot.path) {
            try runHelperInProcess(arguments: [
                "Lungfish", "--vcf-import-helper",
                "--vcf-path", input.path, "--output-db-path", output.path,
                "--import-profile", "ultra-low-memory",
            ])
        }
        XCTAssertEqual(exitCode, 1)
    }

    // MARK: - Child helper import

    /// The child helper writes over 64 KB of progress events and stderr. The
    /// parent must read both while the child runs, then apply its events.
    func testChildHelperWritingOver64KBToBothStreamsDoesNotDeadlock() throws {
        let lungfish = try builtLungfishExecutable()
        let condaRoot = try makeFakeBcftools(body: """
        case "$1 $2" in
          "index --nrecords") echo 9 ;;
          "view --regions") cp "$7" "$6" ;;
        esac
        exit 0
        """)
        let helper = tempDirectory.appendingPathComponent("fake-helper")
        try writeExecutable(helper, """
        #!/bin/sh
        echo $$ >> "\(pidFile.path)"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--output-db-path" ]; then out="$2"; fi
          shift
        done
        /usr/bin/sqlite3 "$out" "CREATE TABLE db_metadata (key TEXT PRIMARY KEY, value TEXT);"
        i=0
        while [ $i -lt \(Self.noiseLines) ]; do
          echo '{"event":"progress","progress":0.5,"message":"child progress line padded to make the stream long enough"}'
          echo "child stderr line $i padded to make the stream long enough to fill a pipe" >&2
          i=$((i+1))
        done
        echo '{"event":"done","progress":1.0,"variantCount":9}'
        exit 0
        """)
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")

        let result = try runHelperSubprocess(
            lungfish: lungfish, argv0: helper.path, condaRoot: condaRoot,
            arguments: ["--vcf-path", input.path, "--output-db-path", output.path, "--import-profile", "ultra-low-memory"]
        )

        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("\"variantCount\":9"), result.stdout)
        XCTAssertEqual(try metadataValue(output, key: "import_partition_mode"), "helper-subprocess-per-chromosome")
    }
}

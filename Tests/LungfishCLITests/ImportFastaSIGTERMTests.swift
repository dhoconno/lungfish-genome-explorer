// ImportFastaSIGTERMTests.swift - A SIGTERM cancels import fasta mid-build and publishes nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A48 M3, ruling A48 F2 pin P6 (SWIFT SC4). The app's Cancel sends SIGTERM to the
// leaf and gives it `operationGrace`. The leaf turns the signal into a cancel of the reference
// build, exits 125 and leaves nothing in Reference Sequences, no bundle, no `.building-` folder and
// no `.processing` file, and no process behind. It writes no cancelled record, because the helper
// route it replaces wrote none (ruling A48 F2, L5). The built lungfish-cli runs against a stand-in
// bgzip that writes its process ID and then sleeps, so the leaf is known to be building when the
// signal arrives, and no real tool and no network are needed. A `.zst` input runs a stand-in zstd the
// same way, which the leaf finds as a managed tool in the same stub conda root (13.17 M3). The cancel
// after the build, with `--annotations`, needs the real tools and is
// `ImportFastaAnnotatedSIGTERMConformanceTests`.

import Foundation
import XCTest
import LungfishTestSupport

final class ImportFastaSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-fasta-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testAReferenceImportTurnsSIGTERMMidBuildIntoACancelAndLeavesNothing() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("ref.fa")
        try ">chr1\nACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let pidFile = root.appendingPathComponent("bgzip.pid")
        let condaRoot = try Self.stubCondaRoot(in: root, pidFile: pidFile)

        let run = try CLISIGTERMHarness.launchCLI(
            ["import", "fasta", source.path, "--output-dir", project.path, "--name", "Mid build", "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let bgzipPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertNotNil(bgzipPID, "the leaf never reached bgzip. Standard output: \(stop.standardOutput)")

        XCTAssertEqual(try Self.leftovers(in: project), [], "a cancelled import leaves nothing in Reference Sequences or .tmp")
        try Self.assertCancelledEvents(stop.standardOutput, importing: "ref.fa")
    }

    /// A SIGTERM while the leaf waits for the decompressor of a compressed input is acted on as well
    /// (A48 M3 review, Fix 1). The stand-in zstd writes its process ID and sleeps, so the leaf is
    /// known to be decompressing when the signal arrives. The leaf finds zstd as a managed tool since
    /// lane 13.17 M3, so the stand-in is staged in a stub conda root, as the first test stages its bgzip.
    /// The leaf must end the decompressor, remove its temporary folder and the marker, and exit 125
    /// inside the grace, where it stayed blocked until the harness killed it before.
    func testAReferenceImportTurnsSIGTERMDuringDecompressionIntoACancelAndLeavesNothing() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("ref.fa.zst")
        try Data().write(to: source)
        let pidFile = root.appendingPathComponent("zstd.pid")
        let condaRoot = try Self.stubCondaRoot(in: root, pidFile: pidFile)

        let run = try CLISIGTERMHarness.launchCLI(
            ["import", "fasta", source.path, "--output-dir", project.path, "--name", "Mid decompression", "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let zstdPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        let held = try Self.leftovers(in: project).filter { $0.hasPrefix(".tmp/") }
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertNotNil(zstdPID, "the leaf never reached zstd. Standard output: \(stop.standardOutput)")
        XCTAssertEqual(held.count, 1, "the leaf holds its temporary folder while it decompresses, so the check below is not vacuous. \(held)")

        XCTAssertEqual(try Self.leftovers(in: project), [], "a cancelled import leaves nothing in Reference Sequences or .tmp")
        try Self.assertCancelledEvents(stop.standardOutput, importing: "ref.fa.zst")
    }

    // MARK: - Shared with the annotated case

    /// The row's first words and the failed event a cancelled import ends with.
    static func assertCancelledEvents(_ output: String, importing name: String) throws {
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.first?.contains("Importing \(name)") == true, "the row's first words. \(lines)")
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any], "\(lines)"
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last line is the failed event. \(lines)")
        XCTAssertEqual(last["error"] as? String, "Import cancelled. Nothing was published.")
    }

    /// The entries a cancelled import must not leave, a bundle, a `.building-` folder or a `.processing`
    /// file in the project's Reference Sequences folder, and a `ref-import-` folder in its `.tmp`
    /// (listed as `.tmp/<name>`).
    static func leftovers(in project: URL) throws -> [String] {
        var found: [String] = []
        let folder = project.appendingPathComponent("Reference Sequences", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            found += try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { name in
                name.hasSuffix(".lungfishref") || name.hasPrefix(".building-") || name.contains(".processing")
            }
        }
        let scratch = project.appendingPathComponent(".tmp", isDirectory: true)
        if FileManager.default.fileExists(atPath: scratch.path) {
            found += try FileManager.default.contentsOfDirectory(atPath: scratch.path)
                .filter { $0.hasPrefix("ref-import-") }
                .map { ".tmp/\($0)" }
        }
        return found.sorted()
    }

    /// A conda root whose bgzip, samtools and zstd answer a version probe, and whose bgzip and zstd sleep on
    /// any other call, after they wrote `$$`. A reference build reaches bgzip and a compressed input reaches
    /// zstd, so one process ID file serves both tests. The CLI reads the root from `LUNGFISH_CONDA_ROOT`, so
    /// the stand-ins win over any real tool whatever app identity the built CLI has. Since lane 13.17 M3 the
    /// leaf finds zstd as a managed tool, in `envs/zstd/bin`, and runs it with an empty environment, so its
    /// stand-in sleeps through the absolute `/bin/sleep`, which needs no PATH.
    private static func stubCondaRoot(in root: URL, pidFile: URL) throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        echo $$ > '\(pidFile.path)'
        exec sleep 120
        """
        let zstd = """
        #!/bin/sh
        case "$1" in
          --version) echo "*** Zstandard CLI (64-bit) v1.5.7, by Yann Collet ***"; exit 0 ;;
        esac
        echo $$ > '\(pidFile.path)'
        exec /bin/sleep 120
        """
        let samtools = """
        #!/bin/sh
        echo "samtools 1.20"
        exit 0
        """
        let stubs = [
            ("envs/htslib/bin/bgzip", bgzip), ("envs/samtools/bin/samtools", samtools), ("envs/zstd/bin/zstd", zstd),
        ]
        for (path, script) in stubs {
            let binary = condaRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return condaRoot
    }
}

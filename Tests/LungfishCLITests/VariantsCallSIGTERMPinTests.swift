// VariantsCallSIGTERMPinTests.swift - Pins what a SIGTERM does to `variants call` at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M1. The app's Cancel sends SIGTERM to `lungfish-cli`. At the base `variants call`
// names no `SIGTERMCancellation`, so the signal reaches only the handler of `CLITerminationSignals`, which
// stops the tools of the run and ends the CLI by the signal. The built CLI runs
// against stand-in tools under a conda root of its own. The stand-in samtools writes its process ID and
// sleeps, which holds the preflight's `samtools view -H` open, so the CLI is known to be at work when the
// signal arrives. This pins the exit (a signal, not 125), the record (none) and what stays running (nothing,
// since the handler stops the tool). M2 makes `variants call` convert SIGTERM and flips these assertions to
// exit 125 and a cancelled record.

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest

final class VariantsCallSIGTERMPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variants-call-sigterm-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A conda root whose five tools answer a version probe and sleep on any other call, after they wrote
    /// `$$` to `<tool>.pid` in the test folder. The CLI reads the root from `LUNGFISH_CONDA_ROOT`.
    private func stubCondaRoot() throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let tools = [("samtools", "samtools"), ("bcftools", "bcftools"), ("htslib", "bgzip"), ("htslib", "tabix"), ("lofreq", "lofreq")]
        for (environment, name) in tools {
            let binary = condaRoot.appendingPathComponent("envs/\(environment)/bin/\(name)")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            case "$*" in
              *version*) echo "\(name) 1.20"; exit 0 ;;
            esac
            echo $$ > '\(root.appendingPathComponent("\(name).pid").path)'
            exec sleep 120
            """
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return condaRoot
    }

    /// A reference bundle with one alignment track whose files the preflight finds. The BAM holds no reads,
    /// since only the stand-in samtools ever looks at it.
    private func makeBundle() throws -> URL {
        let bundle = root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        for folder in ["genome", "alignments"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(">chr1\nACGTACGTACGT\n".utf8).write(to: bundle.appendingPathComponent("genome/reference.fa"))
        try Data("chr1\t12\t6\t12\t13\n".utf8).write(to: bundle.appendingPathComponent("genome/reference.fa.fai"))
        try Data("bam-bytes".utf8).write(to: bundle.appendingPathComponent("alignments/sample.bam"))
        try Data("bai-bytes".utf8).write(to: bundle.appendingPathComponent("alignments/sample.bam.bai"))
        let manifest = BundleManifest(
            name: "Sample",
            identifier: "sample-bundle",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: 12,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 12, offset: 6, lineBases: 12, lineWidth: 13)]
            ),
            alignments: [
                AlignmentTrackInfo(id: "aln-1", name: "Sample BAM", sourcePath: "alignments/sample.bam", indexPath: "alignments/sample.bam.bai"),
            ]
        )
        try manifest.save(to: bundle)
        return bundle
    }

    /// Every regular file under `bundle` by its path in the bundle.
    private func regularFiles(in bundle: URL) throws -> [String: Data] {
        let resolved = bundle.resolvingSymlinksInPath()
        let base = resolved.path + "/"
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files[String(url.path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return files
    }

    func testSIGTERMEndsVariantsCallBySignalLeavingItsToolRunningAndNoRecord() async throws {
        let bundle = try makeBundle()
        let condaRoot = try stubCondaRoot()
        let samtoolsPIDFile = root.appendingPathComponent("samtools.pid")
        let before = try regularFiles(in: bundle)
        let cli = try CLISIGTERMHarness.launchCLI(
            ["variants", "call", "--bundle", bundle.path, "--alignment-track", "aln-1", "--caller", "lofreq", "--format", "json", "--quiet"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard let samtoolsPID = await CLISIGTERMHarness.waitForProcessID(in: samtoolsPIDFile) else {
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("The CLI never reached samtools.\(stop.diagnostics) Standard output: \(stop.standardOutput)")
        }
        addTeardownBlock { kill(samtoolsPID, SIGKILL) }

        // The tool never exits on its own, so a 5 second wait for it to leave ends the pin's question.
        let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))

        XCTAssertNotNil(stop.termination, "the CLI exited after the SIGTERM.\(stop.diagnostics)")
        XCTAssertNil(stop.exitStatus, "the default action ended the CLI by the signal, and it exited with no status.\(stop.diagnostics)")
        // `CLITerminationSignals`, which the CLI's main installs, stops the tools of the run before the CLI ends.
        XCTAssertEqual(stop.left, [], "no tool of the run stays running, out of \(stop.tree)")
        XCTAssertFalse(stop.tree.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent("provenance/cancelled").path),
            "the CLI leaves no cancelled record"
        )
        XCTAssertEqual(try regularFiles(in: bundle), before, "the bundle is as it was, with no record of the cancel in it")
    }
}

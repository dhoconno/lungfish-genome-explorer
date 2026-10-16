// BundleMergeSIGTERMTests.swift - A SIGTERM cancels bundle merge before it publishes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M2 (SWIFT SC4, SC5). The app's Cancel sends SIGTERM to the leaf and gives it
// `operationGrace`. The leaf turns the signal into a cancel of the merge, publishes nothing, removes its
// stage from the project's `.tmp` folder, records the run as cancelled beside the bundle it would have
// published, exits 125 and leaves no process behind. The built lungfish-cli runs against a stand-in bgzip
// that writes its process ID and then sleeps, so the leaf is known to be at work when the signal arrives.
// The source bundles hold a plain FASTA each, so no real tool and no network are needed.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class BundleMergeSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bundle-merge-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testAMergeTurnsSIGTERMIntoACancelAndPublishesNothing() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let first = try makeSource("Alpha", sequence: "chrA", in: project)
        let second = try makeSource("Beta", sequence: "chrB", in: project)
        let pidFile = root.appendingPathComponent("bgzip.pid")
        let condaRoot = try stubCondaRoot(pidFile: pidFile)

        let run = try CLISIGTERMHarness.launchCLI(
            ["bundle", "merge", first.path, second.path, "--name=Merged", "--output-dir", project.path, "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let bgzipPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: {
            ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue
        })
        XCTAssertNotNil(bgzipPID, "the leaf never reached bgzip. Standard output: \(stop.standardOutput)")

        let entries = try FileManager.default.contentsOfDirectory(atPath: project.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix("Merged") }, "a cancelled merge publishes no bundle. \(entries)")
        let temp = project.appendingPathComponent(".tmp", isDirectory: true)
        let stages = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
            .filter { $0.hasPrefix("reference-merge-") }
        XCTAssertEqual(stages, [], "the stage is removed")
        let lines = stop.standardOutput.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.first?.contains("Merging 2 reference bundles") == true, "the row's first words. \(lines)")
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any], "\(lines)"
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last line is the failed event. \(lines)")
        XCTAssertEqual(
            (last["error"] ?? last["message"]) as? String, "Merge cancelled. Nothing was published."
        )
    }

    // MARK: - Fixture

    /// A reference bundle folder that holds one plain FASTA of one sequence, so reading it needs no tool.
    private func makeSource(_ name: String, sequence: String, in project: URL) throws -> URL {
        let bundle = project.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try ">\(sequence)\nACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT\n"
            .write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// A conda root whose bgzip and samtools answer a version probe, and whose bgzip sleeps on any
    /// other call, after it wrote `$$`. The CLI reads the root from `LUNGFISH_CONDA_ROOT`, so the
    /// stand-ins win over any real tool whatever app identity the built CLI has.
    private func stubCondaRoot(pidFile: URL) throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        echo $$ > '\(pidFile.path)'
        exec sleep 120
        """
        let samtools = """
        #!/bin/sh
        echo "samtools 1.20"
        exit 0
        """
        for (path, script) in [("envs/htslib/bin/bgzip", bgzip), ("envs/samtools/bin/samtools", samtools)] {
            let binary = condaRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return condaRoot
    }
}

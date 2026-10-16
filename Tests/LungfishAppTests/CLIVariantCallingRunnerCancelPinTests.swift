// CLIVariantCallingRunnerCancelPinTests.swift - Pins what a cancel through the runner does at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50. M1 pinned the base, where `CLIVariantCallingRunner` passed no `operationGrace`, so the
// transport gave the CLI no time between SIGTERM and SIGKILL, ended its whole tree at once and left no
// record (commit e9963271d). M2 (decision S7) moves the runner to `operationGrace` and `operationDrain`. The
// first test runs the built CLI through the runner against stand-in tools (the stand-in samtools holds the
// preflight open) and asserts that the CLI records the cancel inside the grace and nothing keeps running.
// The second runs a stand-in CLI that ignores SIGTERM and asserts that the cancel waits the grace for it.

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class CLIVariantCallingRunnerCancelPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variant-runner-cancel-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func stubCondaRoot() throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let tools = [("samtools", "samtools"), ("bcftools", "bcftools"), ("htslib", "bgzip"), ("htslib", "tabix"), ("lofreq", "lofreq")]
        for (environment, name) in tools {
            try writeExecutable(
                """
                #!/bin/sh
                case "$*" in
                  *version*) echo "\(name) 1.20"; exit 0 ;;
                esac
                echo $$ > '\(root.appendingPathComponent("\(name).pid").path)'
                exec sleep 120
                """,
                to: condaRoot.appendingPathComponent("envs/\(environment)/bin/\(name)")
            )
        }
        return condaRoot
    }

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

    private func regularFiles(in bundle: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for subpath in try FileManager.default.subpathsOfDirectory(atPath: bundle.path) {
            let url = bundle.appendingPathComponent(subpath)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files[subpath] = try Data(contentsOf: url)
        }
        return files
    }

    func testCancelThroughTheRunnerLetsTheCLIRecordTheCancelAndStopsItsTool() async throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let bundle = try makeBundle()
        let condaRoot = try stubCondaRoot()
        // The runner gives the CLI no environment, so a wrapper points the built CLI at the stand-in tools.
        // `exec` keeps the process, so the transport's signals reach the CLI itself.
        let wrapper = root.appendingPathComponent("lungfish-cli-with-stand-ins")
        try writeExecutable("#!/bin/sh\nexport LUNGFISH_CONDA_ROOT='\(condaRoot.path)'\nexec '\(cli.path)' \"$@\"\n", to: wrapper)
        let before = try regularFiles(in: bundle)
        let arguments = CLIVariantCallingRunner.buildCLIArguments(
            request: BundleVariantCallingRequest(
                bundleURL: bundle, alignmentTrackID: "aln-1", caller: .lofreq, outputTrackName: "Sample BAM \u{2022} LoFreq"
            )
        )
        let runner = CLIVariantCallingRunner(cliURLOverride: wrapper)
        let task = Task { try await runner.run(arguments: arguments) }

        guard let samtoolsPID = await CLISIGTERMHarness.waitForProcessID(in: root.appendingPathComponent("samtools.pid")) else {
            runner.cancel()
            return XCTFail("The CLI never reached samtools.")
        }
        addTeardownBlock { kill(samtoolsPID, SIGKILL) }
        let cancelledAt = ContinuousClock.now
        runner.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run throws CancellationError")
        } catch is CancellationError {
            // expected
        }
        let elapsed = ContinuousClock.now - cancelledAt

        XCTAssertLessThan(elapsed, .seconds(6), "the CLI cancels inside the grace the runner gives it")
        await CLISIGTERMHarness.assertNoProcessLeft([samtoolsPID])
        let records = (try? FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("provenance/cancelled").path)) ?? []
        XCTAssertEqual(records.count, 1, "the CLI wrote its cancelled record before the transport ended it: \(records)")
        let after = try regularFiles(in: bundle).filter { !$0.key.hasPrefix("provenance/cancelled/") }
        XCTAssertEqual(after, before, "every other file of the bundle is as it was")
    }

    func testCancelWaitsTheGraceForACLIThatIgnoresSIGTERM() async throws {
        let pidFile = root.appendingPathComponent("stand-in-cli.pid")
        let standInCLI = root.appendingPathComponent("lungfish-cli")
        try writeExecutable(
            "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nwhile true; do sleep 1; done\n",
            to: standInCLI
        )
        let runner = CLIVariantCallingRunner(cliURLOverride: standInCLI)
        let task = Task { try await runner.run(arguments: []) }
        guard let pid = await CLISIGTERMHarness.waitForProcessID(in: pidFile) else {
            runner.cancel()
            return XCTFail("The stand-in CLI never started.")
        }
        addTeardownBlock { kill(pid, SIGKILL) }
        let cancelledAt = ContinuousClock.now
        runner.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run throws CancellationError")
        } catch is CancellationError {
            // expected
        }

        let waited = ContinuousClock.now - cancelledAt
        XCTAssertGreaterThanOrEqual(waited, .seconds(5), "the runner passes operationGrace, so SIGKILL waits for the command to answer")
        XCTAssertLessThan(waited, .seconds(15))
        await CLISIGTERMHarness.assertNoProcessLeft([pid])
    }
}

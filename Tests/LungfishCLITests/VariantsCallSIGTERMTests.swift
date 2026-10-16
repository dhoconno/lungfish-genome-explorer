// VariantsCallSIGTERMTests.swift - SIGTERM cancels `variants call` for every caller
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M2 (plan decisions C5 and P2 of Phase 2.10, S7 of Phase 2.11). The app's Cancel sends
// SIGTERM to `lungfish-cli` and gives it `operationGrace`. M1 pinned the base, where the signal ended the CLI
// by the signal with no record (`VariantsCallSIGTERMPinTests` at e9963271d). `variants call` now turns the signal
// into a cancel for every caller, records the run as cancelled under the bundle's `provenance/cancelled`,
// exits 125 and leaves no process of its tree. The built CLI runs against stand-in tools in a conda root of
// its own. The stand-in samtools holds the preflight of the iVar-free callers open, and the stand-in
// micromamba holds the GATK command open. Each writes its process ID first, so the CLI is known to be at work.

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class VariantsCallSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variants-call-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A conda root whose five tools answer a version probe and sleep on any other call, after they wrote
    /// `$$` to `<tool>.pid` in the test folder. The CLI reads the root from `LUNGFISH_CONDA_ROOT`.
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

    /// A storage root whose micromamba answers the version probes and then sleeps on the GATK command, with
    /// a child that stands in for the JVM. The files hold what the stand-in saw.
    private func stubMicromambaEnvironment() throws -> [String: String] {
        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let condaRoot = storageRoot.appendingPathComponent("conda", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let lockVersion = ManagedToolLock.bundled.bootstrap?.micromamba.version ?? "2.9.0-0"
        let version = lockVersion.split(separator: "-").first.map(String.init) ?? lockVersion
        try writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "\(version)"; exit 0; fi
            case "$*" in
              *"gatk --version"*) echo "4.6.1.0"; exit 0 ;;
            esac
            echo "$@" >> '\(root.appendingPathComponent("micromamba-calls.txt").path)'
            echo $$ > '\(root.appendingPathComponent("micromamba.pid").path)'
            /bin/sh -c 'echo $$ > "\(root.appendingPathComponent("worker.pid").path)"; exec /bin/sleep 300' &
            wait
            """,
            to: condaRoot.appendingPathComponent("bin/micromamba")
        )
        try writeExecutable("#!/bin/sh\nexit 0\n", to: condaRoot.appendingPathComponent("envs/gatk-core/bin/gatk"))
        return [
            "LUNGFISH_STORAGE_ROOT": storageRoot.path,
            "LUNGFISH_CONDA_ROOT": condaRoot.path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "CFFIXED_USER_HOME": home.path,
        ]
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

    /// The status of the one record under `bundle/provenance/cancelled`, or nil when there is none.
    private func cancelledRecordStatus(in bundle: URL) throws -> String? {
        let folder = bundle.appendingPathComponent("provenance/cancelled", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".lungfish-provenance.json") }
        XCTAssertEqual(names.count, 1, "one cancelled record, found \(names)")
        return try names.first.flatMap { try ProvenanceEnvelopeReader.load(fromSidecar: folder.appendingPathComponent($0))?.status.rawValue }
    }

    /// Everything the bundle held before, nothing else changed, and the one record of the cancel beside it.
    private func assertOnlyTheRecordWasAdded(_ bundle: URL, before: [String: Data], file: StaticString = #filePath, line: UInt = #line) throws {
        var after = try regularFiles(in: bundle)
        let added = after.keys.filter { before[$0] == nil }
        XCTAssertEqual(added.count, 1, "the cancel adds one file, its record: \(added)", file: file, line: line)
        XCTAssertTrue(added.allSatisfy { $0.hasPrefix("provenance/cancelled/") }, "\(added)", file: file, line: line)
        added.forEach { after.removeValue(forKey: $0) }
        XCTAssertEqual(after, before, "every file the bundle held is as it was", file: file, line: line)
    }

    func testSIGTERMCancelsALoFreqCallAndRecordsTheCancel() async throws {
        let bundle = try makeBundle()
        let condaRoot = try stubCondaRoot()
        let before = try regularFiles(in: bundle)
        let cli = try CLISIGTERMHarness.launchCLI(
            ["variants", "call", "--bundle", bundle.path, "--alignment-track", "aln-1", "--caller", "lofreq", "--format", "json", "--quiet"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard let samtoolsPID = await CLISIGTERMHarness.waitForProcessID(in: root.appendingPathComponent("samtools.pid")) else {
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("The CLI never reached samtools.\(stop.diagnostics) Standard output: \(stop.standardOutput)")
        }
        addTeardownBlock { kill(samtoolsPID, SIGKILL) }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli, record: { try self.cancelledRecordStatus(in: bundle) })

        XCTAssertTrue(stop.tree.contains(samtoolsPID), "samtools belongs to the CLI's tree \(stop.tree)")
        XCTAssertFalse(stop.standardOutput.contains("runFailed"), "a cancel reports no failed event: \(stop.standardOutput)")
        try assertOnlyTheRecordWasAdded(bundle, before: before)
    }

    func testSIGTERMCancelsAGATKCallStopsGATKAndLeavesOnlyTheRecord() async throws {
        let bundle = try makeBundle()
        let environment = try stubMicromambaEnvironment()
        let before = try regularFiles(in: bundle)
        let cli = try CLISIGTERMHarness.launchCLI(
            ["variants", "call", "--bundle", bundle.path, "--alignment-track", "aln-1", "--caller", "gatk", "--format", "json", "--quiet"],
            environment: environment,
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard let toolPID = await CLISIGTERMHarness.waitForProcessID(in: root.appendingPathComponent("micromamba.pid")),
              let workerPID = await CLISIGTERMHarness.waitForProcessID(in: root.appendingPathComponent("worker.pid")) else {
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("The CLI never ran the GATK command.\(stop.diagnostics) Standard output: \(stop.standardOutput)")
        }
        addTeardownBlock {
            kill(toolPID, SIGKILL)
            kill(workerPID, SIGKILL)
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli, record: { try self.cancelledRecordStatus(in: bundle) })

        XCTAssertTrue(stop.tree.contains(toolPID) && stop.tree.contains(workerPID), "GATK and its worker belong to the CLI's tree \(stop.tree)")
        XCTAssertFalse(stop.standardOutput.contains("runFailed"), "a cancel reports no failed event: \(stop.standardOutput)")
        try assertOnlyTheRecordWasAdded(bundle, before: before)
        let partial = try FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("variants/gatk").path)
        XCTAssertEqual(partial.filter { !$0.hasPrefix(".") }, [], "GATK's partial output is gone: \(partial)")
    }
}

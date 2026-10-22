// FastqIngestOutOfMemoryTests.swift - A clumpify that runs out of memory fails the import at once (CHTC lane C2-EOOM)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The managed clumpify is a stand-in script in a conda root of this test's own. It logs the argv it was started with
// and ends the way a JVM started with `-eoom` ends when its heap is full: a line on standard error and status 3. The
// test forks the built `lungfish-cli fastq ingest` leaf, which deletes the original once an import succeeds, so an
// original that is still there afterwards shows the failure kept it. The heap is pinned by the debug-only variable
// that `ManagedJavaHeapPolicy` reads, so the sentence names a heap the test knows. It needs no real tool.

import Foundation
import XCTest
import LungfishTestSupport

final class FastqIngestOutOfMemoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-ingest-oom")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A stand-in for the managed `clumpify.sh` that runs out of memory the way `-eoom` ends a JVM.
    private func installStandInClumpify(in condaRoot: URL) throws {
        let script = condaRoot.appendingPathComponent("envs/bbtools/bin/clumpify.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo "$*" >> "$CLUMPIFY_ARGV_LOG"
        echo "Terminating due to java.lang.OutOfMemoryError: Java heap space" >&2
        exit 3
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func testAClumpifyThatRunsOutOfMemoryFailsTheImportAtOnceAndKeepsTheOriginal() throws {
        let binary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            ),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        try installStandInClumpify(in: condaRoot)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        for directory in [home, systemTemp, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try "@read1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n@read2\nTTGGCCAATTGG\n+\nIIIIIIIIIIII\n"
            .write(to: input, atomically: true, encoding: .utf8)
        let originalBytes = try Data(contentsOf: input)
        let argvLog = root.appendingPathComponent("clumpify-argv.txt")
        let outputFile = root.appendingPathComponent("cli-output.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputFile.path, contents: nil))
        let handle = try FileHandle(forWritingTo: outputFile)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["fastq", "ingest", input.path, "--delete-originals"]
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TMPDIR": systemTemp.path,
            "LUNGFISH_CONDA_ROOT": condaRoot.path,
            "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "LUNGFISH_MANAGED_JAVA_HEAP_PIN_GB": "4",
            "CFFIXED_USER_HOME": home.path,
            "CLUMPIFY_ARGV_LOG": argvLog.path,
        ]) { _, new in new }
        process.standardOutput = handle
        process.standardError = handle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let timedOut = exited.wait(timeout: .now() + 120) == .timedOut
        if timedOut { process.terminate(); _ = exited.wait(timeout: .now() + 10) }
        let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""

        XCTAssertFalse(timedOut, "the import must stop when the tool reports it ran out of memory: \(output)")
        XCTAssertEqual(process.terminationStatus == 0, false, "the import must fail: \(output)")
        XCTAssertTrue(output.contains("ran out of memory"), output)
        XCTAssertTrue(output.contains("4 GB heap"), "the sentence names the heap that ran: \(output)")
        XCTAssertTrue(output.contains("--clumpify-heap-gb"), "the sentence names the option that raises it: \(output)")
        XCTAssertFalse(output.contains("Clumpify failed"), "the plain sentence is not wrapped in the generic one: \(output)")

        // The stand-in saw `-eoom` and the pinned heap on its storage launch.
        let launches = try String(contentsOf: argvLog, encoding: .utf8).split(separator: "\n").filter { $0.contains("in=") }
        XCTAssertFalse(launches.isEmpty, "the import never started the stand-in clumpify: \(output)")
        for launch in launches {
            XCTAssertTrue(launch.contains("-eoom"), "\(launch)")
            XCTAssertTrue(launch.contains("-Xmx4g"), "\(launch)")
        }

        // The original is as it was and nothing was published beside it or left in the staging folder.
        XCTAssertEqual(try Data(contentsOf: input), originalBytes, "the original is as it was")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".fastq.gz") || $0.hasSuffix(".lungfishfastq") }, "\(names)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: systemTemp.path), [], "no staging folder is left")
    }
}

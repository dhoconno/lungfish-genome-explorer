// VariantsImportSampleMetadataSIGTERMTests.swift - SIGTERM cancels `variants import-sample-metadata` and leaves the bundle as it was
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A43 M2, plan decision C5, on the pattern of SequenceAttachTrackSIGTERMTests. The
// app's Cancel sends SIGTERM to `lungfish-cli`. `variants import-sample-metadata` edits the
// bundle's variant databases in place, so it turns the signal into a cancel, exits 125 and leaves
// every database, file and record as it was. A cancelled import writes no run record, so the test
// reads the bundle where `CLISIGTERMHarness.assertSIGTERMCancels` would read a record's status.
//
// What holds the command. The attach test holds its command on a FIFO, and this import cannot be
// held that way: the service describes its copy of the metadata file with
// `ProvenanceFileDescriptor.file`, which opens the copy twice, once to hash it and once for its
// size, and a FIFO that no writer holds never opens a second time. The metadata file is a sparse
// file of 3 GiB instead. The service copies it (a clone on APFS, so the copy is instant and takes
// no space) and hashes the copy, about a second of work that no cancel interrupts. The copy
// appears in the bundle's `.mutation-inputs` folder just before the hash starts, so a SIGTERM
// sent when it appears lands while the import runs. The service takes the cancel at its next ask,
// before it imports anything (`VariantEditInvocationTests` covers every ask), and rolls back.

import Darwin
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class VariantsImportSampleMetadataSIGTERMTests: XCTestCase {
    func testSIGTERMCancelsTheImportAndLeavesTheBundleAsItWas() async throws {
        let root = try TestTempDirectory.make(prefix: "variants-import-sigterm")
        defer { TestTempDirectory.cleanup(root) }
        let volume = try root.resourceValues(forKeys: [.volumeSupportsSparseFilesKey, .volumeSupportsFileCloningKey])
        guard volume.volumeSupportsSparseFiles == true, volume.volumeSupportsFileCloning == true else {
            throw XCTSkip("The test volume has no sparse files or no file cloning, so a 3 GiB file would take space and time")
        }
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let metadata = root.appendingPathComponent("long.tsv")
        XCTAssertTrue(FileManager.default.createFile(atPath: metadata.path, contents: nil))
        let handle = try FileHandle(forWritingTo: metadata)
        try handle.truncate(atOffset: 3 << 30)
        try handle.close()
        let standardError = root.appendingPathComponent("stderr.txt")
        let before = try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL])

        guard let cliURL = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        // The shell puts the command's standard error in a file, and `exec` keeps the process ID,
        // so the SIGTERM reaches the command itself.
        let cli = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "exec \"$0\" \"$@\" 2>\"$IMPORT_STDERR\"",
                cliURL.path, "variants", "import-sample-metadata", fixture.bundleURL.path, metadata.path,
                "--metadata-format", "tsv", "--quiet",
            ],
            environment: CLISIGTERMHarness.childEnvironment(overriding: ["IMPORT_STDERR": standardError.path])
        )
        defer { cli.stop() }

        // The copy of the metadata file appears when the import holds the bundle and starts to hash.
        guard await Self.waitForRetainedCopy(in: fixture.bundleURL) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The import never copied the metadata file.\(stop.diagnostics) \(Self.text(of: standardError))")
        }
        let stop = await CLISIGTERMHarness.cancel(cli)
        let errors = Self.text(of: standardError)

        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(errors.contains("Cancelling the import"), "Its standard error file holds: \(errors)")
        XCTAssertTrue(errors.contains("Import cancelled"), "Its standard error file holds: \(errors)")
        XCTAssertEqual(
            try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL]), before,
            "a cancelled import leaves every database, file and record of the bundle as it was"
        )
    }

    /// Waits up to the harness's process wait until a copy of the metadata file stands in the
    /// bundle's `.mutation-inputs` folder, checking every 10 ms.
    private static func waitForRetainedCopy(in bundle: URL) async -> Bool {
        let inputs = bundle.appendingPathComponent(".mutation-inputs", isDirectory: true)
        let deadline = ContinuousClock.now + CLISIGTERMHarness.processWait
        while ContinuousClock.now < deadline {
            let enumerator = FileManager.default.enumerator(atPath: inputs.path)
            while let name = enumerator?.nextObject() as? String {
                if (name as NSString).lastPathComponent.hasPrefix("metadata-") { return true }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// What `file` holds, or nothing when it cannot be read.
    private static func text(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }
}

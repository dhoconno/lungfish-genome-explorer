// SequenceAttachTrackSIGTERMTests.swift - SIGTERM cancels `sequence attach-track` and leaves the bundle as it was
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A42 M3 and its review's Fix 5, plan decision C5. The app's Cancel sends SIGTERM to
// `lungfish-cli`. `sequence attach-track` edits a reference bundle in place, so it turns the signal
// into a cancel, exits 125 and leaves every file of the bundle as it was. The attach writes no run
// record, so the test reads the bundle where `CLISIGTERMHarness.assertSIGTERMCancels` would read a
// record's status. The GFF3 it attaches is a FIFO. The attach opens it inside the service and
// cannot end its parse until the FIFO closes, so a writer that can open the FIFO knows the command
// is at work, and the cancel lands while the attach runs. The command's standard error goes to a
// file, which the test reads while the command runs, and the FIFO closes once the command reports
// there that its cancel reached the attach.

import Darwin
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class SequenceAttachTrackSIGTERMTests: XCTestCase {
    func testSIGTERMCancelsTheAttachAndLeavesTheBundleAsItWas() async throws {
        let root = try TestTempDirectory.make(prefix: "attach-track-sigterm")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try SequenceEditFixture.referenceBundle(in: root)
        let source = root.appendingPathComponent("held.gff3")
        XCTAssertEqual(mkfifo(source.path, 0o600), 0, "the held GFF3 is a FIFO")
        let standardError = root.appendingPathComponent("stderr.txt")
        let before = try Self.regularFiles(in: bundle)

        guard let cliURL = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        // The shell puts the command's standard error in a file, and `exec` keeps the process ID,
        // so the SIGTERM reaches the command itself.
        let cli = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "exec \"$0\" \"$@\" 2>\"$ATTACH_STDERR\"",
                cliURL.path, "sequence", "attach-track", bundle.path, source.path, "--quiet",
            ],
            environment: CLISIGTERMHarness.childEnvironment(overriding: ["ATTACH_STDERR": standardError.path])
        )
        defer { cli.stop() }

        // A writer opens the FIFO once the attach holds it open to read, inside the service, after
        // the command started turning SIGTERM into a cancel.
        guard let writer = await Self.openWriter(of: source) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The attach never opened the GFF3.\(stop.diagnostics) \(Self.text(of: standardError))")
        }
        let feature = "##gff-version 3\nchr1\ttest\tgene\t3\t9\t.\t+\t.\tID=gene1;Name=held\n"
        _ = feature.withCString { write(writer, $0, strlen($0)) }
        // The parse cannot end while the FIFO stays open, so the attach is at work when the SIGTERM
        // comes. The FIFO closes once the command reports that its cancel reached the attach.
        let closer = Task.detached { () -> Bool in
            let reported = await Self.waitForText("Cancelling the attach", in: standardError)
            close(writer)
            return reported
        }
        let stop = await CLISIGTERMHarness.cancel(cli)
        let reported = await closer.value
        let errors = Self.text(of: standardError)

        XCTAssertTrue(reported, "The command never reported that its cancel reached the attach.\(stop.diagnostics) \(errors)")
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(errors.contains("Attach cancelled"), "Its standard error file holds: \(errors)")
        XCTAssertEqual(
            try Self.regularFiles(in: bundle), before,
            "a cancelled attach leaves every file of the bundle as it was, its manifest and records included"
        )
    }

    /// Opens the FIFO at `url` for writing once a reader holds it, waiting up to the harness's
    /// process wait. A write after the reader left fails instead of raising SIGPIPE.
    private static func openWriter(of url: URL) async -> Int32? {
        let deadline = ContinuousClock.now + CLISIGTERMHarness.processWait
        while ContinuousClock.now < deadline {
            let descriptor = open(url.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
                _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                return descriptor
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Waits up to the harness's process wait until `file` holds `text`, reading it every 10 ms.
    private static func waitForText(_ text: String, in file: URL) async -> Bool {
        let deadline = ContinuousClock.now + CLISIGTERMHarness.processWait
        while ContinuousClock.now < deadline {
            if Self.text(of: file).contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// What `file` holds, or nothing when it cannot be read.
    private static func text(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Every regular file under `bundle`, hidden ones included, by its path in the bundle.
    private static func regularFiles(in bundle: URL) throws -> [String: Data] {
        let base = bundle.resolvingSymlinksInPath().path + "/"
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return files
    }
}

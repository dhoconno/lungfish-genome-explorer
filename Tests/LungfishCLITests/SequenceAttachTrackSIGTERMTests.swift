// SequenceAttachTrackSIGTERMTests.swift - SIGTERM cancels `sequence attach-track` and leaves the bundle as it was
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A42 M3, plan decision C5. The app's Cancel sends SIGTERM to `lungfish-cli`.
// `sequence attach-track` edits a reference bundle in place, so it turns the signal into a cancel,
// exits 125 and leaves every file of the bundle as it was. The attach writes no run record, so the
// test reads the bundle where `CLISIGTERMHarness.assertSIGTERMCancels` would read a record's status.
// The GFF3 it attaches is a FIFO. The attach opens it inside the service and cannot end its parse
// until the FIFO closes, so a writer that can open the FIFO knows the command is at work, and the
// cancel lands while the attach runs.

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
        let before = try Self.regularFiles(in: bundle)

        let cli = try CLISIGTERMHarness.launchCLI(
            ["sequence", "attach-track", bundle.path, source.path, "--quiet"],
            testClass: Self.self
        )
        defer { cli.stop() }

        // A writer opens the FIFO once the attach holds it open to read, inside the service, after
        // the command started turning SIGTERM into a cancel.
        guard let writer = await Self.openWriter(of: source) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The attach never opened the GFF3.\(stop.diagnostics)")
        }
        let feature = "##gff-version 3\nchr1\ttest\tgene\t3\t9\t.\t+\t.\tID=gene1;Name=held\n"
        _ = feature.withCString { write(writer, $0, strlen($0)) }
        // The parse cannot end while the FIFO stays open, so the attach is at work when the SIGTERM
        // comes. The FIFO closes two seconds later, which gives the signal's cancel time to reach
        // the attach. The pause cannot hide a defect, as the command cannot move before it ends.
        let closer = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            close(writer)
        }
        let stop = await CLISIGTERMHarness.cancel(cli)
        await closer.value

        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(stop.standardError.contains("Attach cancelled"), stop.diagnostics)
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

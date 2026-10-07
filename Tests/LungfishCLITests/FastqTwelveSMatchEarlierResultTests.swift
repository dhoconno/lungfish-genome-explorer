// FastqTwelveSMatchEarlierResultTests.swift - What `fastq 12s-match --force` prints when the earlier result cannot come back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow
import XCTest

/// Re-review 2, N6. When a forced `lungfish-cli fastq 12s-match` fails while it
/// writes its new bundle, and the earlier result cannot be moved back either,
/// the error the CLI prints says in one line where the earlier result waits,
/// as `fastq demultiplex` says it of its earlier output.
final class FastqTwelveSMatchEarlierResultTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqTwelveSMatchEarlierResultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAFailedRestoreIsPrintedWithWhereTheEarlierResultWaits() async throws {
        let reference = root.appendingPathComponent("reference.fa")
        try ">human (Homo sapiens)|locus=12S|len=8\nACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        let reads = root.appendingPathComponent("sampleA.fastq")
        try "@read1\nTTACGTACGTGG\n+\nIIIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let outputDirectory = root.appendingPathComponent("results", isDirectory: true)
        let arguments = [
            reads.path,
            "--reference", reference.path,
            "--output-dir", outputDirectory.path,
            "--output-name", "sampleA-12s",
            "--min-soft-clip", "2",
            "--threads", "1",
            "--no-chimera-review",
        ]
        try await FastqTwelveSMatchSubcommand.parse(arguments).run()
        let locked = outputDirectory.appendingPathComponent("sampleA-12s.lungfish12s/locked", isDirectory: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        // The command's own configuration, run as `run()` runs it, with a
        // progress handler that fails the write and the restore.
        let command = try FastqTwelveSMatchSubcommand.parse(arguments + ["--force"])
        var printed = ""
        do {
            _ = try await TwelveSAmpliconMatchingWorkflow().run(try command.configurationForTesting()) { _, message in
                guard message == "Writing 12S result bundle tables." else { return }
                try? FileManager.default.removeItem(at: reference)
                try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
                try? Data("held\n".utf8).write(to: locked.appendingPathComponent("held.txt"))
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            }
            XCTFail("a bundle that cannot be written must fail the run")
        } catch {
            // What `lungfish-cli` prints to stderr for an error it exits with.
            printed = LungfishCLI.fullMessage(for: error)
        }

        let aside = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
                .first { $0.hasPrefix(".sampleA-12s.lungfish12s.replaced-") }
        )
        let asidePath = outputDirectory.standardizedFileURL.appendingPathComponent(aside, isDirectory: true).path
        XCTAssertTrue(printed.hasPrefix("Error: "), printed)
        XCTAssertEqual(
            printed.components(separatedBy: "\n").last,
            "The earlier 12S result could not be moved back to sampleA-12s.lungfish12s, and it waits at \(asidePath).",
            printed
        )
        XCTAssertNoThrow(try TwelveSAmpliconResultBundle.loadResult(from: URL(fileURLWithPath: asidePath)))
    }
}

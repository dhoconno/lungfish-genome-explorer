// MSAFailedRowWordsTests.swift - a refused MSA action's `failed` event holds the refusal's own words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A69, fixes F6 to F8 of the A69 review (carry-in row SW11). The `msa` action commands
// ended their stream with `emitter.emitFailed(actionID:message: error.localizedDescription)`, and
// ArgumentParser's `ValidationError` has no localized text, so the Operations row of a refused `msa`
// command read "The operation couldn't be completed". Each test makes a command refuse from inside its
// `do` block, before any bundle loads, and reads the `failed` line the command wrote.

import ArgumentParser
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class MSAFailedRowWordsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "msa-failed-row-words")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A bundle path that does not exist. Every refusal below comes before the bundle loads.
    private var missingBundle: URL {
        root.appendingPathComponent("no-such.lungfishmsa", isDirectory: true)
    }

    /// `msa annotate add` checks the strand first in its `do` block.
    func testMSAAnnotateAddFailedEventCarriesTheStrandRefusal() throws {
        let refusal = "Unsupported annotation strand 'x'. Supported values: +, -, ."
        let command = try MSACommand.AddSubcommand.parse([
            missingBundle.path,
            "--row", "seq1",
            "--columns", "1-3",
            "--name", "site",
            "--type", "motif",
            "--strand", "x",
            "--format", "json",
        ])
        var lines: [String] = []
        do {
            try command.executeForTesting { lines.append($0) }
            XCTFail("an unsupported strand must end the run")
        } catch let error as ValidationError {
            XCTAssertEqual(error.message, refusal)
        }

        let message = try Self.failedMessage(in: lines)
        XCTAssertEqual(message, refusal)
        XCTAssertFalse(message.contains("be completed"), message)
    }

    /// `msa distance` checks the model first in its `do` block.
    func testMSADistanceFailedEventCarriesAnUnsupportedModelRefusal() throws {
        let prefix = "Unsupported MSA distance model 'nope'. Supported values: "
        let command = try MSACommand.DistanceSubcommand.parse([
            missingBundle.path,
            "--model", "nope",
            "--output", root.appendingPathComponent("matrix.tsv").path,
            "--format", "json",
        ])
        var lines: [String] = []
        do {
            try command.executeForTesting { lines.append($0) }
            XCTFail("an unsupported model must end the run")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.hasPrefix(prefix), error.message)
        }

        let message = try Self.failedMessage(in: lines)
        XCTAssertTrue(message.hasPrefix(prefix), message)
        XCTAssertFalse(message.contains("be completed"), message)
    }

    /// `msa export` refuses an output file that exists before it loads the bundle, so the test needs
    /// no bundle. The refusal is the one the review names.
    func testMSAExportFailedEventCarriesTheOutputExistsRefusal() throws {
        let output = root.appendingPathComponent("selected.fa")
        try ">seq1\nACGT\n".write(to: output, atomically: true, encoding: .utf8)
        let command = try MSACommand.ExportSubcommand.parse([
            missingBundle.path,
            "--output-format", "aligned-fasta",
            "--output", output.path,
            "--format", "json",
        ])
        var lines: [String] = []
        do {
            try command.executeForTesting { lines.append($0) }
            XCTFail("an output file that exists must refuse the export without --force")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.hasPrefix("Output file already exists: "), error.message)
        }

        let message = try Self.failedMessage(in: lines)
        XCTAssertTrue(message.hasPrefix("Output file already exists: "), message)
        XCTAssertTrue(message.hasSuffix("Use --force to overwrite."), message)
        XCTAssertTrue(message.contains("selected.fa"), message)
        XCTAssertFalse(message.contains("be completed"), message)
    }

    /// The `error` text of the last `failed` event among the lines.
    private static func failedMessage(in lines: [String]) throws -> String {
        let events = try lines.filter { $0.hasPrefix("{") }.map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], $0)
        }
        let failed = try XCTUnwrap(events.last { $0["event"] as? String == "failed" }, "no failed event in \(lines)")
        return try XCTUnwrap(failed["error"] as? String, "\(failed)")
    }
}

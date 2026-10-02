// SequenceAnnotationOperationRunnerArgvTests.swift - Find ORFs argv parses with the real lungfish-cli parser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Find ORFs runs `lungfish-cli sequence annotate-orfs` with the argv that
// SequenceAnnotationOperationRunner builds, and records the same argv as its
// Operations panel command (R3, R4). ArgumentParser reads a separate value
// that starts with "-" as an option name, so a reverse-frame list such as
// `-1,-2,-3` used to fail with "Missing value for '--frames <frames>'". The
// runner now passes such values as `--option=value`. These tests hand the
// runner's argv to `LungfishCLI.parseAsRoot`, the parser the shipped binary
// runs, so any selection the dialog can make must parse.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishWorkflow

final class SequenceAnnotationOperationRunnerArgvTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1k1/Sample.lungfishref", isDirectory: true)

    private func request(
        frames: [String],
        sequenceName: String = "chr 1",
        trackID: String? = "orfs_chr_1",
        trackName: String = "chr 1 ORFs"
    ) -> SequenceAnnotationOperationRequest {
        SequenceAnnotationOperationRequest(
            operation: .orf,
            bundleURL: bundleURL,
            sequenceName: sequenceName,
            start: 100,
            end: 2_500,
            frames: frames,
            codonTableID: 11,
            trackID: trackID,
            trackName: trackName,
            minimumORFLength: 150,
            includePartialORFs: true,
            allowAlternativeStarts: false
        )
    }

    /// Parses `arguments` the way `LungfishCLIMain.main` does.
    private func parse(_ arguments: [String]) throws -> SequenceCommand.AnnotateORFs {
        let parsed = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(arguments))
        return try XCTUnwrap(parsed as? SequenceCommand.AnnotateORFs, "parsed \(type(of: parsed))")
    }

    func testReverseFramesOnlyParseAsTheRunAndTheRecordedCommand() throws {
        let reverseOnly = request(frames: ["-1", "-2", "-3"])

        let run = try parse(SequenceAnnotationOperationRunner.commandArguments(for: reverseOnly))
        XCTAssertEqual(run.frames, "-1,-2,-3")
        XCTAssertEqual(run.bundle, bundleURL.path)
        XCTAssertEqual(run.start, 100)
        XCTAssertEqual(run.end, 2_500)
        XCTAssertEqual(run.table, 11)
        XCTAssertEqual(run.minLength, 150)
        XCTAssertTrue(run.includePartial)
        XCTAssertFalse(run.allowAlternativeStarts)
        XCTAssertTrue(run.globalOptions.quiet)

        let recorded = try RecordedCLICommand.parse(
            SequenceAnnotationOperationRunner.displayCommand(for: reverseOnly),
            as: SequenceCommand.AnnotateORFs.self
        )
        XCTAssertEqual(recorded.frames, "-1,-2,-3")
    }

    /// The dialog lists the selected frames in `ReadingFrame.allCases` order,
    /// so every one of the 63 selections it can make is checked.
    func testEveryFrameSelectionTheDialogCanMakeParses() throws {
        let allFrames = ReadingFrame.allCases.map(\.rawValue)
        for mask in 1..<(1 << allFrames.count) {
            let frames = allFrames.enumerated()
                .filter { mask & (1 << $0.offset) != 0 }
                .map(\.element)
            let command = try parse(SequenceAnnotationOperationRunner.commandArguments(for: request(frames: frames)))
            XCTAssertEqual(command.frames, frames.joined(separator: ","), "selection \(frames)")
        }
    }

    /// The sequence name comes from the bundle and the track ID and name from
    /// the dialog, which allows a leading hyphen in both.
    func testTextValuesThatStartWithAHyphenParse() throws {
        let hyphenated = request(
            frames: ["+1", "-1"],
            sequenceName: "-chrM",
            trackID: "-orfs",
            trackName: "-chrM ORFs"
        )

        let run = try parse(SequenceAnnotationOperationRunner.commandArguments(for: hyphenated))
        XCTAssertEqual(run.sequence, "-chrM")
        XCTAssertEqual(run.trackID, "-orfs")
        XCTAssertEqual(run.trackName, "-chrM ORFs")
        XCTAssertEqual(run.frames, "+1,-1")

        let recorded = try RecordedCLICommand.parse(
            SequenceAnnotationOperationRunner.displayCommand(for: hyphenated),
            as: SequenceCommand.AnnotateORFs.self
        )
        XCTAssertEqual(recorded.sequence, "-chrM")
        XCTAssertEqual(recorded.trackID, "-orfs")
        XCTAssertEqual(recorded.trackName, "-chrM ORFs")
    }
}

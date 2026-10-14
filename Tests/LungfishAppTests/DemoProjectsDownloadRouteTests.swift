// DemoProjectsDownloadRouteTests.swift - The child's arguments and the bar of the window's download through demo fetch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

/// Phase 2.10 lane A45 M4, panel decisions C4 and C9. The pure parts of the Demo Projects window's download through
/// `lungfish-cli demo fetch`. The class that runs the built CLI is `DemoProjectsCLIRoutePinReplayTests`. The hidden
/// key that chose between this route and the in-process install went with the flip (C4).
@MainActor
final class DemoProjectsDownloadRouteTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/Users/me/Documents/LGE Demo Projects")

    private static let phases: [DemoProjectInstallPhase] = {
        let total: Int64 = 388_000_000
        return [
            .downloading(bytesReceived: 0, totalBytes: total),
            .downloading(bytesReceived: 1, totalBytes: total),
            .downloading(bytesReceived: 123_456_789, totalBytes: total),
            .downloading(bytesReceived: total - 1, totalBytes: total),
            .downloading(bytesReceived: total, totalBytes: total),
            .verifying, .extracting, .installing,
        ]
    }()

    /// The child gets the command the row records, with `--format json`, and the shipped parser reads it as the
    /// project, the folder and the replace choice the window has.
    func testTheChildGetsTheRowsCommandWithTheFormat() throws {
        for replace in [false, true] {
            let fetch = DemoProjectCLIFetch(projectID: "demo-fixture", directory: directory, replaceExisting: replace, totalBytes: 10)
            let project = DemoProject(
                id: "demo-fixture", title: "Demo Fixture", summary: "", chapters: [], projectFolderName: "Demo Fixture.lungfish",
                archive: .init(url: URL(string: "https://example.invalid/demo.zip")!, sha256: String(repeating: "a", count: 64), bytes: 10),
                version: "2026.9.44")
            let recorded = DemoProjectsViewModel.cliCommand(for: project, directory: directory, replaceExisting: replace)
            XCTAssertEqual(fetch.arguments, try RecordedCLICommand.arguments(of: recorded) + ["--format", "json"])
            let parsed = try XCTUnwrap(try DemoCommand.parseAsRoot(Array(fetch.arguments.dropFirst())) as? DemoCommand.FetchSubcommand)
            XCTAssertEqual(parsed.id, "demo-fixture")
            XCTAssertEqual(parsed.location.destination, directory.path)
            XCTAssertEqual(parsed.force, replace)
            XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
            XCTAssertNil(parsed.location.manifestPath, "the window names no list of its own")
        }
    }

    /// A `progress` line of the command reads back into the phase that wrote it, the bytes exactly, after the
    /// fraction has travelled as JSON.
    func testAProgressLineReadsBackIntoThePhaseThatWroteIt() throws {
        let total: Int64 = 388_000_000
        for phase in Self.phases {
            let line = DemoFetchReporter.line(for: phase)
            var written: [String] = []
            CLIEventEmitter(enabled: true) { written.append($0) }.emitProgress(line.fraction, message: line.message)
            let event = try XCTUnwrap(try CLIEventLineDecoder().decode(line: XCTUnwrap(written.first)))
            guard case let .progress(fraction, message) = event else { return XCTFail("\(event)") }
            XCTAssertEqual(message, line.message)
            XCTAssertEqual(DemoProjectCLIProgress.phase(forFraction: fraction, totalBytes: total), phase, "\(phase)")
        }
    }

    /// The `progress` line carries the words the window shows, and the two copies of the bar's numbers agree.
    func testTheCommandsWordsAndNumbersAreTheWindowsOwn() {
        for phase in Self.phases {
            XCTAssertEqual(DemoFetchReporter.detail(for: phase), DemoProjectsViewModel.detailText(for: phase), "\(phase)")
        }
        XCTAssertEqual(DemoProjectCLIProgress.downloadShare, DemoFetchReporter.downloadShare)
        XCTAssertEqual(DemoProjectCLIProgress.verifyingFraction, DemoFetchReporter.verifyingFraction)
        XCTAssertEqual(DemoProjectCLIProgress.extractingFraction, DemoFetchReporter.extractingFraction)
        XCTAssertEqual(DemoProjectCLIProgress.installingFraction, DemoFetchReporter.installingFraction)
    }
}

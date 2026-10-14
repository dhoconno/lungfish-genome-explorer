// DemoFetchEventTranscriptReplayTests.swift - The events and transcripts of lungfish-cli demo fetch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

/// Runs the built `lungfish-cli demo fetch --format json` on a project archive served by the loopback
/// stand-in and checks the lines it prints (Phase 2.10 lane A45 M4, panel decision C9). A run is one `start`
/// line, `progress` lines, and one `complete` line that names the installed project folder, or one `failed`
/// line. The progress is the download from 0 to 0.9 as the share of the bytes received, then verifying at
/// 0.91, unpacking at 0.93 and installing at 0.98, each with the words the Demo Projects window shows
/// (`DemoProjectsViewModel.detailText`). Standard output holds nothing but event lines.
///
/// The transcripts in `Tests/Fixtures/cli-events/commands/demo-fetch` are `complete` (a fresh install),
/// `complete-installed` (a copy that was already there) and `failed` (a project the list does not hold, whose
/// words hold no digest and no port). With `LUNGFISH_RECAPTURE_CLI_EVENTS=1` the tests write the transcripts.
/// Otherwise they check that each run starts and ends as its transcript does, because the number of progress
/// lines follows the transfer. The scratch folder is rewritten to `/work`.
///
/// It launches the built CLI, so its name ends in ReplayTests, which sends it to the integration tier.
final class DemoFetchEventTranscriptReplayTests: XCTestCase {
    private struct Scratch {
        let root: URL
        let work: URL
        let cli: URL
    }

    private func scratch() throws -> Scratch {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "demo-fetch-events")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return Scratch(root: root, work: root.appendingPathComponent("work", isDirectory: true), cli: cli)
    }

    private func fetch(
        _ id: String, in scratch: Scratch, standIn: DemoArchiveStandIn, extra: [String] = []
    ) async -> RouteParityHarness.CLIRun {
        await RouteParityHarness.runCLI(
            scratch.cli,
            arguments: ["demo", "fetch", id, "--dest", scratch.work.path, "--manifest", standIn.manifestURL.path]
                + extra + ["--format", "json"],
            timeout: .seconds(120),
            environment: standIn.environment)
    }

    /// A copy of the project that an earlier install left, with its record, so a run that finds it downloads nothing.
    private func writeInstalledCopy(in work: URL) throws {
        let folder = work.appendingPathComponent(DemoArchiveStandIn.projectFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DemoProjectInstallRecord(id: DemoArchiveStandIn.projectID, version: "2026.9.44", sha256: "x", installedAt: Date()))
            .write(to: folder.appendingPathComponent(".lgedemo.json"))
    }

    /// The events of `stdout`. A line that is not an event line fails the test, because standard output of
    /// a run with events on holds nothing else.
    private func eventLines(of stdout: String, file: StaticString = #filePath, line: UInt = #line) throws -> [CLIEvent] {
        let decoder = CLIEventLineDecoder()
        return try stdout.split(separator: "\n").map { text in
            let envelope = try XCTUnwrap(
                try decoder.decodeLine(String(text)), "stdout holds a line that is not an event: \(text)", file: file, line: line)
            return try XCTUnwrap(envelope.event, "stdout holds an event this reader ignores: \(text)", file: file, line: line)
        }
    }

    private func checkTranscript(_ name: String, stdout: String, work: URL) throws {
        let lines = stdout.split(separator: "\n").map { FetchGenomeEventTranscriptReplayTests.normalized(String($0), work: work) }
        let url = CLIEventTranscriptLocation.url(leaf: "demo fetch", name: name)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, expected.first, "The run starts as \(name).ndjson does")
        XCTAssertEqual(lines.last, expected.last, "The run ends as \(name).ndjson does")
    }

    private func leftovers(in work: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).sorted()
    }

    // MARK: - Runs

    func testAFreshInstallStartsReportsItsStagesAndCompletes() async throws {
        let scratch = try scratch()
        let standIn = try DemoArchiveStandIn.start(in: scratch.root)
        defer { standIn.stop() }

        let run = await fetch(DemoArchiveStandIn.projectID, in: scratch, standIn: standIn)
        XCTAssertEqual(run.status, 0, run.detail)
        let events = try eventLines(of: run.stdout)
        XCTAssertEqual(
            events.first, CLIEvent.start(message: "Started download of demo project demo-fixture via lungfish-cli"))
        let project = scratch.work.appendingPathComponent(DemoArchiveStandIn.projectFolderName, isDirectory: true)
        guard case let .complete(outputs, message)? = events.last else {
            return XCTFail("The run does not end in complete: \(events.last.map(String.init(describing:)) ?? "nothing")")
        }
        XCTAssertEqual(outputs.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, [project.resolvingSymlinksInPath().path])
        XCTAssertEqual(message, "Installed Demo Fixture")

        let progress = events.compactMap { event -> (fraction: Double, message: String)? in
            if case let .progress(fraction, message) = event { return (fraction, message) }
            return nil
        }
        XCTAssertEqual(progress.first?.fraction, 0, "the first line is the start of the transfer")
        XCTAssertEqual(progress.map { $0.fraction }, progress.map { $0.fraction }.sorted(), "the bar never steps back")
        let downloads = progress.filter { $0.message.hasPrefix("Downloading ") }
        XCTAssertGreaterThanOrEqual(downloads.count, 2, "\(progress)")
        XCTAssertTrue(downloads.allSatisfy { $0.fraction <= 0.9 }, "the download takes the first nine tenths: \(downloads)")
        XCTAssertEqual(downloads.last?.fraction, 0.9, "the transfer ends at its share")
        XCTAssertEqual(
            progress.suffix(3).map { $0.message }, ["Verifying size and SHA-256…", "Unpacking…", "Installing…"],
            "the stages carry the words of the window's detail text")
        XCTAssertEqual(progress.suffix(3).map { $0.fraction }, [0.91, 0.93, 0.98])
        XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: project)?.id, DemoArchiveStandIn.projectID)
        XCTAssertEqual(leftovers(in: scratch.work), [DemoArchiveStandIn.projectFolderName], "no staging folder is left")
        try checkTranscript("complete", stdout: run.stdout, work: scratch.work)
    }

    func testACopyThatIsAlreadyInstalledStartsAndCompletesWithNoProgress() async throws {
        let scratch = try scratch()
        let standIn = try DemoArchiveStandIn.start(in: scratch.root)
        defer { standIn.stop() }
        try writeInstalledCopy(in: scratch.work)
        let requestsBefore = standIn.server.requests.count

        let run = await fetch(DemoArchiveStandIn.projectID, in: scratch, standIn: standIn)
        XCTAssertEqual(run.status, 0, run.detail)
        let events = try eventLines(of: run.stdout)
        XCTAssertEqual(events.count, 2, "start and complete only: \(events)")
        guard case let .complete(outputs, message)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(
            outputs.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [scratch.work.appendingPathComponent(DemoArchiveStandIn.projectFolderName).resolvingSymlinksInPath().path])
        XCTAssertEqual(message, "Demo Fixture is already installed. Pass --force to replace it with a fresh copy.")
        XCTAssertEqual(standIn.server.requests.count, requestsBefore, "an installed copy downloads nothing")
        try checkTranscript("complete-installed", stdout: run.stdout, work: scratch.work)
    }

    func testAChecksumFailureEndsFailedAndLeavesNothing() async throws {
        let scratch = try scratch()
        let standIn = try DemoArchiveStandIn.start(in: scratch.root, declaredSHA256: String(repeating: "ab", count: 32))
        defer { standIn.stop() }

        let run = await fetch(DemoArchiveStandIn.projectID, in: scratch, standIn: standIn)
        XCTAssertEqual(run.status, 1, run.detail)
        let events = try eventLines(of: run.stdout)
        XCTAssertEqual(events.filter { if case .failed = $0 { return true } else { return false } }.count, 1)
        guard case let .failed(message, _)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(message.contains("SHA-256"), message)
        XCTAssertEqual(leftovers(in: scratch.work), [], "a failed run leaves no staging folder and no project")
    }

    func testAnUnknownProjectEndsFailedWithTheListsWords() async throws {
        let scratch = try scratch()
        let standIn = try DemoArchiveStandIn.start(in: scratch.root)
        defer { standIn.stop() }

        let run = await fetch("no-such-demo", in: scratch, standIn: standIn)
        XCTAssertEqual(run.status, 1, run.detail)
        let events = try eventLines(of: run.stdout)
        guard case let .start(startMessage)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(startMessage, "Started download of demo project no-such-demo via lungfish-cli")
        guard case let .failed(message, _)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(message.contains("There is no demo project called"), message)
        try checkTranscript("failed", stdout: run.stdout, work: scratch.work)
    }
}

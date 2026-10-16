// ReferenceBundleMergeOperationTests.swift - The sidebar's reference bundle merge row, run as bundle merge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `ReferenceBundleMergeRoute.merge` takes its reporter and its launch as parameters (R4), so these tests
// watch the row without touching `OperationCenter.shared` and without starting a command. Phase 2.11 lane
// A49 M2 closed the parity gap `reference-bundle-merge`. The row records the `bundle merge` command it runs.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ReferenceBundleMergeOperationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = try TestTempDirectory.make(prefix: "reference-merge-operation")
    }

    override func tearDown() {
        if let tempDirectory {
            TestTempDirectory.cleanup(tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    private struct CommandFailure: LocalizedError {
        var errorDescription: String? { "Reference bundle merge needs every sequence name to be unique." }
    }

    private func sources() -> [URL] {
        ["A", "B"].map { tempDirectory.appendingPathComponent("\($0).lungfishref", isDirectory: true) }
    }

    func testTheRowRecordsTheBundleMergeCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let merged = tempDirectory.appendingPathComponent("Merged.lungfishref", isDirectory: true)
        var launched: [String] = []

        let url = try await ReferenceBundleMergeRoute.merge(
            sourceBundleURLs: sources(),
            outputDirectory: tempDirectory,
            bundleName: "Merged",
            reporter: reporter
        ) { arguments, _ in
            launched = arguments
            return ReferenceBundleMergeRoute.Run(outputs: [merged.path], message: "Merged 2 reference bundles")
        }

        XCTAssertEqual(url.path, merged.path)
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.title, "Merge Reference Bundles")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.logs.first?.message, "Merging 2 reference bundles into \"Merged\".")
        // The row records the command it ran. It parses back to the options the route gave it.
        let command = try XCTUnwrap(item.cliCommand)
        let parsed = try RecordedCLICommand.parse(command, as: BundleMergeSubcommand.self)
        XCTAssertEqual(parsed.bundles, sources().map(\.path))
        XCTAssertEqual(parsed.name, "Merged")
        XCTAssertEqual(parsed.outputDirectory, tempDirectory.path)
        XCTAssertEqual(Array(launched.prefix(2)), ["bundle", "merge"])
        XCTAssertEqual(Array(launched.suffix(2)), ["--format", "json"])
    }

    func testAFailedCommandFailsTheRowWithItsWords() async throws {
        let reporter = RecordingOperationReporter()
        do {
            _ = try await ReferenceBundleMergeRoute.merge(
                sourceBundleURLs: sources(), outputDirectory: tempDirectory, bundleName: "Merged", reporter: reporter
            ) { _, _ in throw CommandFailure() }
            XCTFail("a failed command must fail the merge")
        } catch is CommandFailure {
            // Expected. The route rethrows the command's error.
        }
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.failure?.errorMessage, "Reference bundle merge needs every sequence name to be unique.")
    }

    func testARefusedMergeThrowsAndLaunchesNothing() async throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false
        do {
            _ = try await ReferenceBundleMergeRoute.merge(
                sourceBundleURLs: sources(), outputDirectory: tempDirectory, bundleName: "Merged", reporter: reporter
            ) { _, _ in
                launched = true
                return ReferenceBundleMergeRoute.Run(outputs: [], message: nil)
            }
            XCTFail("a refused begin must stop the merge")
        } catch let error as OperationRefusedError {
            XCTAssertEqual(error.refusal.blockingOperationTitle, "Importing BAM")
        }
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        XCTAssertTrue(reporter.items[0].logs.isEmpty, "a refused merge reports nothing further")
        XCTAssertFalse(launched, "a refused merge launches no command")
    }

    func testTheArgumentsKeepANameThatStartsWithAHyphenAsOneWord() {
        let arguments = ReferenceBundleMergeRoute.arguments(
            sourceBundleURLs: sources(), outputDirectory: tempDirectory, bundleName: "-lab set, 2"
        )
        XCTAssertTrue(arguments.contains("--name=-lab set, 2"))
        XCTAssertEqual(Array(arguments.prefix(2)), ["bundle", "merge"])
    }
}

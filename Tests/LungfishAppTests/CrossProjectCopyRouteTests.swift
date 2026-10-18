// CrossProjectCopyRouteTests.swift - Each value of the hidden key CrossProjectCopyRoute
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 (BIO ruling on `caller`, answer 5, U-R1). The key is new, hidden and defaults to
// `cli`. On `cli` the sidebar's drop runs `lungfish-cli project copy-item` and the app copies nothing
// itself. On `legacy` the copier runs in the app and no command runs. A test for each value, as FX53 did.
// Lane 13.03 deletes the key, its `legacy` code and these tests' `legacy` cases.

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport

@MainActor
final class CrossProjectCopyRouteTests: XCTestCase {
    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "cross-project-copy-route")
        sourceProject = root.appendingPathComponent("S.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("T.lungfish", isDirectory: true)
        for project in [sourceProject!, targetProject!] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testUnsetKeyTakesTheCLIRoute() {
        let suite = makeTestDefaultsSuite(prefix: "cross-project-copy-route")
        XCTAssertEqual(CrossProjectCopyRouteSettings.defaultsKey, "CrossProjectCopyRoute")
        XCTAssertEqual(CrossProjectCopyRouteSettings(defaults: suite.defaults).route, .cli)
    }

    func testEachValueOfTheKeyNamesItsRoute() {
        let suite = makeTestDefaultsSuite(prefix: "cross-project-copy-route")
        let values: [(Any, CrossProjectCopyRoute)] = [
            ("cli", .cli), ("legacy", .legacy), ("LEGACY", .legacy), (true, .cli), (false, .legacy), ("in-app", .cli),
        ]
        for (value, route) in values {
            suite.defaults.set(value, forKey: CrossProjectCopyRouteSettings.defaultsKey)
            XCTAssertEqual(CrossProjectCopyRouteSettings(defaults: suite.defaults).route, route, "\(value)")
        }
    }

    func testCLIRouteRunsTheCommandAndCopiesNothingInTheApp() async throws {
        let item = try makeReferenceBundle()
        let landedPath = targetProject.appendingPathComponent("Reference Sequences/NC_045512.lungfishref").path
        var launched: [[String]] = []

        let result = await MainSplitViewController.copyDroppedProjectItem(
            item, intoProject: targetProject, requestedFolder: nil, route: .cli, operationID: UUID()
        ) { arguments, _ in
            launched.append(arguments)
            return CrossProjectCopyRoute.Run(outputs: [landedPath], message: "Copied NC_045512.lungfishref")
        }

        XCTAssertEqual(launched, [[
            "project", "copy-item", "Reference Sequences/NC_045512.lungfishref",
            "--source-project", sourceProject.standardizedFileURL.path,
            "--project", targetProject.standardizedFileURL.path, "--format", "json",
        ]])
        XCTAssertEqual(try result.get().destinationURL.path, landedPath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: targetProject.path), [], "the app copied nothing")
    }

    func testCLIRouteCancelReturnsTheCancelSoTheDropShowsNoAlert() async throws {
        let item = try makeReferenceBundle()

        let result = await MainSplitViewController.copyDroppedProjectItem(
            item, intoProject: targetProject, requestedFolder: nil, route: .cli, operationID: UUID()
        ) { _, _ in
            throw CancellationError()
        }

        guard case .failure(let error) = result else { return XCTFail("a cancelled run landed") }
        XCTAssertTrue(error is CancellationError, "\(error)")
    }

    func testLegacyRouteCopiesInTheAppAndRunsNoCommand() async throws {
        let item = try makeReferenceBundle()

        let result = await MainSplitViewController.copyDroppedProjectItem(
            item, intoProject: targetProject, requestedFolder: nil, route: .legacy, operationID: UUID()
        ) { arguments, _ in
            XCTFail("legacy ran \(arguments)")
            throw CancellationError()
        }

        let landed = try result.get()
        XCTAssertEqual(landed.destinationURL.lastPathComponent, "NC_045512.lungfishref")
        let sequence = landed.destinationURL.appendingPathComponent("sequence.fasta")
        XCTAssertEqual(try String(contentsOf: sequence, encoding: .utf8), ">NC_045512\nACGTACGT\n")
        XCTAssertNotNil(landed.record, "the in-process copy writes its record")
    }

    private func makeReferenceBundle() throws -> URL {
        let bundle = sourceProject.appendingPathComponent("Reference Sequences/NC_045512.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ">NC_045512\nACGTACGT\n".write(to: bundle.appendingPathComponent("sequence.fasta"), atomically: true, encoding: .utf8)
        return bundle
    }
}

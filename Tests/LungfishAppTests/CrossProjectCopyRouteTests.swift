// CrossProjectCopyRouteTests.swift - The sidebar's copy runs lungfish-cli project copy-item
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 (BIO ruling on `caller`, answer 5, U-R1). A project item dropped from another project
// runs `lungfish-cli project copy-item`, and the app copies nothing itself. The hidden key `CrossProjectCopyRoute`
// and its `legacy` route, which copied in the app and ran no command, went in Phase 2.13, so these tests give
// the drop helper a launch closure and check the command it runs and the cancel it returns.

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

    func testTheDropRunsTheCommandAndCopiesNothingInTheApp() async throws {
        let item = try makeReferenceBundle()
        let landedPath = targetProject.appendingPathComponent("Reference Sequences/NC_045512.lungfishref").path
        var launched: [[String]] = []

        let result = await MainSplitViewController.copyDroppedProjectItem(
            item, intoProject: targetProject, requestedFolder: nil, operationID: UUID()
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

    func testTheCancelIsReturnedSoTheDropShowsNoAlert() async throws {
        let item = try makeReferenceBundle()

        let result = await MainSplitViewController.copyDroppedProjectItem(
            item, intoProject: targetProject, requestedFolder: nil, operationID: UUID()
        ) { _, _ in
            throw CancellationError()
        }

        guard case .failure(let error) = result else { return XCTFail("a cancelled run landed") }
        XCTAssertTrue(error is CancellationError, "\(error)")
    }

    private func makeReferenceBundle() throws -> URL {
        let bundle = sourceProject.appendingPathComponent("Reference Sequences/NC_045512.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ">NC_045512\nACGTACGT\n".write(to: bundle.appendingPathComponent("sequence.fasta"), atomically: true, encoding: .utf8)
        return bundle
    }
}

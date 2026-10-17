// MappingRoutePrivateProjectReplayTests.swift - Map Reads onto a reference bundle in a project spelled under /private
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A62 M1 (K11). A Map Reads onto a `.lungfishref` ends with
// `MappingViewerBundlePublicationService.publishCandidate`, which renames the hidden candidate bundle to the final
// one. It compared the two bundles' parent folders after `standardizedFileURL`, which drops a leading `/private` from
// a path that exists (the candidate) and keeps it on a path that does not exist yet (the final bundle). A project
// whose paths are spelled under `/private` (the resolved form of a folder under `/var/folders`) then failed the
// publication on the in-process route and on the CLI route alike. The fixture helpers keep the spelling of the root
// they are given, so these cases hand them the root in its `/private` form.
//
// minimap2 and samtools are the storage root's own, stated with ToolAvailability, and the CLI case launches the
// built lungfish-cli, so the name ends in ReplayTests, which sends the class to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class MappingRoutePrivateProjectReplayTests: XCTestCase {
    private typealias Fixture = MappingViewerBundlePublicationSigningReplayTests

    private var scratch: URL!
    private var cliBinary: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "mapping-private-project")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cliBinary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so the CLI route cannot run"
        )
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    /// The in-process route, `runSingleManagedMappingAwaitingCompletion`, in a project spelled under `/private`.
    func testAMapReadsOntoAReferenceBundleInAPrivateProjectPublishesOnTheInProcessRoute() async throws {
        let request = try await privateProjectRequest()
        let (_, item) = try await ReadsRouteParity.record(title: Fixture.title) {
            Task { @MainActor in
                await AppDelegate().runSingleManagedMappingAwaitingCompletion(
                    request: request, warning: nil, routeContext: nil,
                    preassignedAnalysisDirectory: request.outputDirectory, registerCancel: { _ in }
                )
            }
        }
        let outcome = ReadsRouteParity.outcome(of: item)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)
        Self.assertViewerPublished(in: request.outputDirectory)
    }

    /// The CLI route, `runSingleManagedMappingThroughCLI` on the built `lungfish-cli map`, in the same project.
    func testAMapReadsOntoAReferenceBundleInAPrivateProjectPublishesOnTheCLIRoute() async throws {
        let request = try await privateProjectRequest()
        let runner = CLIReadsRunner(cliURLOverride: cliBinary)
        let (_, item) = try await ReadsRouteParity.record(title: Fixture.title) {
            Task { @MainActor in
                await AppDelegate().runSingleManagedMappingThroughCLI(
                    request: request, warning: nil, routeContext: nil,
                    preassignedAnalysisDirectory: request.outputDirectory, runner: runner,
                    cancelBatch: {}, registerCancel: { _ in }
                )
            }
        }
        let outcome = ReadsRouteParity.outcome(of: item, recordsCommand: true)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)
        Self.assertViewerPublished(in: request.outputDirectory)
    }

    // MARK: - The project and the checks

    /// The Map Reads window's request for the golden's reads onto a `.lungfishref` of a project that is spelled
    /// under `/private`, with every path of the request in that spelling.
    private func privateProjectRequest() async throws -> MappingRunRequest {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let root = try Self.privateSpelling(of: scratch).appendingPathComponent("root", isDirectory: true)
        try Fixture.writeFixture(root, onReferenceBundle: true)
        let request = try Fixture.request(in: root, onReferenceBundle: true)
        XCTAssertTrue(
            request.outputDirectory.path.hasPrefix("/private/") && request.projectURL?.path.hasPrefix("/private/") == true,
            "the project is not spelled under /private: \(request.outputDirectory.path)"
        )
        return request
    }

    /// `folder` in the spelling `realpath` gives, which is `/private/var/folders/...` for a folder under `/var/folders`.
    /// Foundation's `resolvingSymlinksInPath` and `standardizedFileURL` give the other spelling back.
    nonisolated static func privateSpelling(of folder: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = try XCTUnwrap(realpath(folder.path, &buffer), "realpath could not resolve \(folder.path)")
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// The analysis folder holds one published viewer bundle and no candidate, the result names that bundle, and
    /// the imported BAM's own record names the final bundle and not the candidate that was renamed to it.
    nonisolated static func assertViewerPublished(
        in folder: URL, file: StaticString = #filePath, line: UInt = #line
    ) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(
            names.filter { $0.hasSuffix(".lungfishref") && !$0.hasPrefix(".") }.count, 1,
            "no viewer bundle is published in \(folder.path): \(names)", file: file, line: line
        )
        XCTAssertEqual(
            names.filter { $0.hasPrefix(".") && $0.contains(".candidate-") }, [],
            "a candidate bundle is left in \(folder.path)", file: file, line: line
        )
        guard let mapping = try? MappingResult.load(from: folder),
              let viewer = mapping.viewerBundleURL,
              FileManager.default.fileExists(atPath: viewer.path) else {
            XCTFail("the result in \(folder.path) names no viewer bundle that exists", file: file, line: line)
            return
        }
        let alignments = viewer.appendingPathComponent("alignments", isDirectory: true)
        let records = ((try? FileManager.default.contentsOfDirectory(atPath: alignments.path)) ?? [])
            .filter { $0.hasSuffix(".import.lungfish-provenance.json") }
        XCTAssertFalse(records.isEmpty, "the viewer bundle holds no import record in \(alignments.path)", file: file, line: line)
        for name in records {
            let text = (try? String(contentsOf: alignments.appendingPathComponent(name), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains(".candidate-"), "\(name) still names the candidate bundle", file: file, line: line)
            XCTAssertFalse(text.contains("/private/private"), "\(name) doubles /private in a path", file: file, line: line)
        }
        // The stats database of the imported BAM holds the same paths, and replacing the stripped candidate path
        // inside a path that keeps /private would double it. (One run of ".candidate-" bytes stays in the database
        // file of a project spelled without /private too, so only the doubled /private is checked.)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: alignments.path)) ?? []) where name.hasSuffix(".stats.db") {
            let bytes = (try? Data(contentsOf: alignments.appendingPathComponent(name))) ?? Data()
            XCTAssertNil(bytes.range(of: Data("/private/private".utf8)), "\(name) doubles /private in a path", file: file, line: line)
        }
    }
}

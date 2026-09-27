// MapCommandLayoutParityTests.swift - `lungfish-cli map` leaves the window's layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// The Map Reads window publishes its result through
/// `MappingResultLayoutService.publishViewerBundle` and records it through
/// `MappingResultLayoutService.recordAnalysisManifest`
/// (`AppDelegate.prepareMappingViewerBundleIfPossible`). `lungfish-cli map`
/// runs `MapCommand.publishLayout`, which must produce the identical
/// project layout from the same mapping result.
final class MapCommandLayoutParityTests: XCTestCase {
    private var scaffolds: [MappingResultLayoutScaffold] = []

    override func tearDown() {
        scaffolds.forEach { $0.cleanUp() }
        scaffolds = []
        super.tearDown()
    }

    func testCLIPublishLayoutMatchesTheWindowLayout() async throws {
        try await skipUnlessSamtoolsIsInstalled()
        let windowRun = try makeScaffold()
        let cliRun = try makeScaffold()

        // The window's path.
        let windowPublishedOrNil = try await MappingResultLayoutService.publishViewerBundle(
            result: windowRun.result,
            request: windowRun.request
        )
        let windowPublication = try XCTUnwrap(windowPublishedOrNil)
        try MappingResultLayoutService.recordAnalysisManifest(
            originalInputURLs: windowRun.request.inputFASTQURLs,
            resolvedRequest: windowRun.request,
            result: windowPublication.result,
            projectURL: windowRun.projectRootURL
        )

        // The CLI's path.
        let cliResult = try await MapCommand.publishLayout(
            result: cliRun.result,
            request: cliRun.request,
            originalInputURLs: cliRun.request.inputFASTQURLs,
            skipViewerBundle: false
        )

        XCTAssertEqual(
            try MappingResultLayoutScaffold.normalizedLayout(of: cliRun.analysisDirectoryURL, tool: .minimap2),
            try MappingResultLayoutScaffold.normalizedLayout(of: windowRun.analysisDirectoryURL, tool: .minimap2)
        )
        XCTAssertEqual(
            try MappingResultLayoutScaffold.normalizedLayout(of: cliRun.projectRootURL, tool: .minimap2),
            try MappingResultLayoutScaffold.normalizedLayout(of: windowRun.projectRootURL, tool: .minimap2)
        )

        let cliManifest = try BundleManifest.load(from: try XCTUnwrap(cliResult.viewerBundleURL))
        let windowManifest = try BundleManifest.load(from: windowPublication.viewerBundleURL)
        XCTAssertEqual(cliManifest.alignments.map(\.name), ["minimap2 Mapping"])
        XCTAssertEqual(cliManifest.alignments.map(\.name), windowManifest.alignments.map(\.name))
        XCTAssertEqual(cliManifest.originBundlePath, windowManifest.originBundlePath)
        XCTAssertEqual(cliManifest.alignments.map(\.format), windowManifest.alignments.map(\.format))
        XCTAssertEqual(
            cliManifest.alignments.map { MappingResultLayoutScaffold.normalize($0.sourcePath, tool: .minimap2) },
            windowManifest.alignments.map { MappingResultLayoutScaffold.normalize($0.sourcePath, tool: .minimap2) }
        )

        let cliSidecar = try MappingResult.load(from: cliRun.analysisDirectoryURL)
        XCTAssertEqual(cliSidecar.viewerBundleURL?.lastPathComponent, "src.lungfishref")
        XCTAssertEqual(cliSidecar, cliResult)

        for run in [windowRun, cliRun] {
            let history = AnalysisManifestStore.load(bundleURL: run.fastqBundleURL, projectURL: run.projectRootURL)
            XCTAssertEqual(history.analyses.map(\.displayName), ["minimap2 Mapping"], run.projectRootURL.path)
            XCTAssertEqual(history.analyses.first?.summary, "1/1 reads mapped")
        }
    }

    func testCLIHonoursTrackNameAndSkipFlag() async throws {
        try await skipUnlessSamtoolsIsInstalled()
        let named = try makeScaffold(outputTrackName: "HG002 minimap2")
        let namedResult = try await MapCommand.publishLayout(
            result: named.result,
            request: named.request,
            originalInputURLs: named.request.inputFASTQURLs,
            skipViewerBundle: false
        )
        XCTAssertEqual(
            try BundleManifest.load(from: try XCTUnwrap(namedResult.viewerBundleURL)).alignments.map(\.name),
            ["HG002 minimap2"]
        )

        let skipped = try makeScaffold()
        let skippedResult = try await MapCommand.publishLayout(
            result: skipped.result,
            request: skipped.request,
            originalInputURLs: skipped.request.inputFASTQURLs,
            skipViewerBundle: true
        )
        XCTAssertNil(skippedResult.viewerBundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: skipped.analysisDirectoryURL.appendingPathComponent("src.lungfishref").path
        ))
    }

    /// The window's copied command names the project and any changed track
    /// name, so `lungfish-cli map` reproduces the window's layout; the
    /// command parses them back into the same request fields.
    func testMapCommandParsesProjectAndTrackNameFromTheWindowCommand() throws {
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.rawValue,
            inputFASTQURLs: [URL(fileURLWithPath: "/proj/Imports/s.lungfishfastq")],
            referenceFASTAURL: URL(fileURLWithPath: "/proj/Reference Sequences/r.lungfishref/genome/sequence.fa"),
            projectURL: URL(fileURLWithPath: "/proj"),
            outputDirectory: URL(fileURLWithPath: "/proj/Analyses/minimap2-2026-09-27T10-00-00"),
            sampleName: "s",
            threads: 4,
            outputTrackName: "HG002 minimap2"
        )
        let arguments = MappingCLIInvocationBuilder.arguments(for: request)
        XCTAssertTrue(arguments.contains("--project"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--project")! + 1], "/proj")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--track-name")! + 1], "HG002 minimap2")

        let command = try MapCommand.parse(arguments)
        XCTAssertEqual(command.project, "/proj")
        XCTAssertEqual(command.trackName, "HG002 minimap2")
        XCTAssertEqual(command.outputDir, "/proj/Analyses/minimap2-2026-09-27T10-00-00")
        XCTAssertFalse(command.noViewerBundle)

        // The default track name is left implicit on both sides.
        let defaultArguments = MappingCLIInvocationBuilder.arguments(for: request.withOutputTrackName(nil))
        XCTAssertFalse(defaultArguments.contains("--track-name"))
        XCTAssertNil(try MapCommand.parse(defaultArguments).trackName)
        XCTAssertTrue(try MapCommand.parse(defaultArguments + ["--no-viewer-bundle"]).noViewerBundle)
    }

    // MARK: - Helpers

    private func makeScaffold(outputTrackName: String? = nil) throws -> MappingResultLayoutScaffold {
        let fixtureBAM = packageRoot().appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        guard FileManager.default.fileExists(atPath: fixtureBAM.path) else {
            throw XCTSkip("sarscov2 BAM fixture missing at \(fixtureBAM.path)")
        }
        let scaffold = try MappingResultLayoutScaffold.make(fixtureBAMURL: fixtureBAM, outputTrackName: outputTrackName)
        scaffolds.append(scaffold)
        return scaffold
    }

    private func skipUnlessSamtoolsIsInstalled() async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            throw XCTSkip("samtools is not installed in the managed conda root: \(error.localizedDescription)")
        }
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

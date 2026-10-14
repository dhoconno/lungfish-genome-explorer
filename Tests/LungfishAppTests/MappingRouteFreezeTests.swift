// MappingRouteFreezeTests.swift - The Map Reads row and its batch folders before the route moves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M1 (census row p19, decision C4). The Map Reads window runs
// ManagedMappingPipeline in the app, and its row records `lungfish-cli map` from
// MappingCLIInvocationBuilder. The CLI route behind the mapping key runs that same argv, so this
// class pins, at the base, the row's title, first detail and type, the recorded argv with the read
// layout left in auto, and a batch's folders: one `<mapper>-batch-<timestamp>` root holding a folder
// per sample, named in request order, each recorded as that sample's `--output-dir`. The UI-test
// backend's result is pinned by AppUITestMappingBackendTests. No tool runs.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class MappingRouteFreezeTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var reference: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mapping-route-freeze")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        reference = project.appendingPathComponent("genome.fasta")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testOneBundleRowRecordsTheMapArgvWithTheLayoutLeftInAuto() throws {
        let bundle = project.appendingPathComponent("Imports/sampleA.lungfishfastq", isDirectory: true)
        let analysis = try AnalysesFolder.createAnalysisDirectory(tool: MappingTool.minimap2.rawValue, in: project)
        let request = try XCTUnwrap(plan(bundles: [bundle], output: analysis).requests.first).withOutputDirectory(analysis)

        let reporter = RecordingOperationReporter()
        var launched: UUID?
        AppDelegate.beginManagedMappingOperation(request: request, routeContext: nil, reporter: reporter) { launched = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launched, item.id)
        XCTAssertEqual(item.title, "Map Reads (minimap2): sampleA")
        XCTAssertEqual(item.initialDetail, "Mapping 1 file(s) to genome.fasta")
        XCTAssertEqual(item.operationType, .mapping)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), [
            "map", bundle.path,
            "--reference", reference.path,
            "--mapper", "minimap2",
            "--preset", "sr",
            "--project", project.path,
            "--output-dir", analysis.path,
            "--sample-name", "sampleA",
            "--rg-id", "sampleA", "--rg-sm", "sampleA", "--rg-lb", "sampleA", "--rg-pl", "ILLUMINA", "--rg-pu", "sampleA",
            "--threads", "2",
        ])
        let parsed = try RecordedCLICommand.parse(item.cliCommand, as: MapCommand.self)
        XCTAssertEqual(parsed.readLayout, .auto, "a bundle's layout is left to the command's auto")
        XCTAssertFalse(parsed.pairedEnd)
    }

    func testABatchRecordsEachSampleFolderUnderOneBatchRootInRequestOrder() throws {
        let bundles = ["sampleB", "sampleA"].map {
            project.appendingPathComponent("Imports/\($0).lungfishfastq", isDirectory: true)
        }
        let requests = plan(bundles: bundles, output: project.appendingPathComponent("unused", isDirectory: true)).requests
        XCTAssertEqual(requests.map(\.sampleName), ["sampleB", "sampleA"])

        let folders = try XCTUnwrap(AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: project))
        XCTAssertEqual(folders.map(\.lastPathComponent), ["sampleB", "sampleA"])
        let batchRoots = Set(folders.map { $0.deletingLastPathComponent().standardizedFileURL })
        XCTAssertEqual(batchRoots.count, 1)
        let batchRoot = try XCTUnwrap(batchRoots.first)
        XCTAssertTrue(batchRoot.lastPathComponent.hasPrefix("minimap2-batch-"), batchRoot.lastPathComponent)
        XCTAssertEqual(batchRoot.deletingLastPathComponent().lastPathComponent, "Analyses")

        let reporter = RecordingOperationReporter()
        for (request, folder) in zip(requests, folders) {
            AppDelegate.beginManagedMappingOperation(
                request: request.withOutputDirectory(folder),
                routeContext: nil,
                reporter: reporter
            ) { _ in }
        }
        XCTAssertEqual(reporter.items.map(\.title), ["Map Reads (minimap2): sampleB", "Map Reads (minimap2): sampleA"])
        for (item, folder) in zip(reporter.items, folders) {
            let parsed = try RecordedCLICommand.parse(item.cliCommand, as: MapCommand.self)
            XCTAssertEqual(parsed.outputDir, folder.path)
            XCTAssertEqual(parsed.project, project.path)
            XCTAssertEqual(parsed.sampleName, folder.lastPathComponent)
            XCTAssertEqual(parsed.readGroupID, folder.lastPathComponent)
        }
    }

    /// The plan the Map Reads dialog builds for `bundles`, one request per bundle.
    private func plan(bundles: [URL], output: URL) -> MappingRunPlan {
        MappingWizardSheet.buildRunPlan(
            bundleURLs: bundles,
            mode: .perBundle,
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: reference,
            sourceReferenceBundleURL: nil,
            projectURL: project,
            outputDirectory: output,
            runToken: "freeze",
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 2,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
    }
}

// ClassifierLayoutReaderPinTests.swift - Readers of every classifier result layout, pinned before the 2.7 executor writes new ones
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A2, risk R11 of the plan ("Executor migration changes classifier result
// layout for existing projects") and decisions E1, E2 and E5. The analysis run executor
// writes Kraken2 and EsViritu results through `--project` and `--output-dir`. The readers
// that decide what the sidebar lists and which viewer opens never ask a writer. They look
// at the shape of the folder (AnalysesFolder, SidebarProjectScanner, ClassifierDatabaseRouter,
// MainSplitViewController). This suite builds each shape LGE has written, and each shape the
// executor will write, with ClassifierLayoutFixtures, and pins what the readers do with it.
//
// Three kinds of pin cover each layout.
//   - The sidebar row, in the snapshot Tests/Fixtures/sidebar-scan/classifier-layouts.txt.
//   - The route. A layout with an index opens a viewer, and the rows for those are in
//     RoutingSafetyNetTable+BundleAndClassifierRows.swift. A layout with no index routes to the
//     database build placeholder, whose first act is to launch `lungfish-cli build-db`, so this
//     suite pins the decision at the router (a nil database) and never selects it.
//   - A run that failed, was cancelled or is still going stays out of every listing and is
//     offered for review in the Operations Panel.
//
// The fixtures are literal files, so a writer cannot move a pin. One test runs the import
// writer and compares its folder with the fixture, which keeps the claim "as an import
// writes it" true.
//
// An executor lane that changes a row on purpose edits the line here or rewrites the snapshot:
//
//     LUNGFISH_UPDATE_SIDEBAR_SNAPSHOTS=1 swift test --skip-update \
//         --filter LungfishAppTests.ClassifierLayoutReaderPinTests/testSidebarSnapshot
//
// and names the changed row in its commit message.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ClassifierLayoutReaderPinTests: XCTestCase {
    private typealias Layouts = ClassifierLayoutFixtures
    private typealias Name = ClassifierLayoutFixtures.Name

    // MARK: - Fixture

    private struct Built {
        let root: URL
        let project: URL
        let paths: SafetyNetPathRenderer
        var analyses: URL { project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true) }
        var imports: URL { project.appendingPathComponent("Imports", isDirectory: true) }
    }

    private func buildProject() async throws -> Built {
        let root = try TestTempDirectory.make(prefix: "ClassifierLayoutPins")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = try await SidebarScanSafetyNetProjects.classifierLayoutProject.build(root)
        return Built(root: root, project: project, paths: SafetyNetPathRenderer(root: project))
    }

    // MARK: - Sidebar

    /// The whole scan of the layout project against its committed snapshot. Every visible
    /// layout is a row, and the failed, cancelled and running runs and the claimed folder
    /// outside Analyses are absent.
    func testSidebarSnapshot() async throws {
        let built = try await buildProject()
        let layouts = SidebarScanSafetyNetProjects.classifierLayoutProject
        let rendered = SidebarScanSnapshot.render(
            SidebarProjectScanner.scanRootNodes(from: built.project),
            projectURL: built.project,
            summary: layouts.summary
        )
        let snapshotURL = SafetyNetPaths.fixture("sidebar-scan/\(layouts.name).txt")

        if ProcessInfo.processInfo.environment[SidebarScanSafetyNetTests.updateEnvironmentKey] == "1" {
            try SafetyNetFiles.write(rendered, to: snapshotURL)
            return
        }
        guard let committed = try? String(contentsOf: snapshotURL, encoding: .utf8) else {
            XCTFail("No committed snapshot at \(snapshotURL.path). Run with \(SidebarScanSafetyNetTests.updateEnvironmentKey)=1 to write it.")
            return
        }
        XCTAssertEqual(
            rendered,
            committed,
            "The sidebar scan of the classifier layouts changed. Diff against \(snapshotURL.lastPathComponent):\n\(SidebarScanSnapshot.difference(rendered, committed))"
        )
    }

    // MARK: - Identification and routing

    /// What `AnalysesFolder.analysisInfo` and `ClassifierDatabaseRouter.route` make of each layout.
    /// A database of `no` is the lazy index build, and `nil` is a selection that ends silently.
    private let expectedLayouts: [(name: String, info: String, route: String)] = [
        // Writers of today.
        (Name.cliKraken2, "kraken2 batch=false", "kraken2 database=no result=Analyses/kraken2-golden sample=-"),
        (Name.windowKraken2Single, "kraken2 batch=false", "kraken2 database=no result=Analyses/kraken2-2026-02-09T09-00-00 sample=-"),
        (Name.windowKraken2Batch, "kraken2 batch=true", "kraken2 database=yes result=Analyses/kraken2-batch-2026-02-09T10-00-00 sample=-"),
        (Name.windowKraken2BatchWithoutIndex, "kraken2 batch=true", "kraken2 database=no result=Analyses/kraken2-batch-2026-02-09T11-00-00 sample=-"),
        (Name.cliEsViritu, "esviritu batch=false", "esviritu database=no result=Analyses/esviritu-golden sample=-"),
        (Name.cliEsVirituFreeName, "esviritu batch=false", "nil"),
        (Name.importedEsViritu, "esviritu batch=false", "esviritu database=no result=Analyses/esviritu-HG002_import sample=-"),
        (Name.windowEsVirituBatchOfOne, "esviritu batch=true", "esviritu database=yes result=Analyses/esviritu-batch-2026-02-09T12-00-00 sample=-"),
        (Name.windowEsVirituBatchOfOneWithoutIndex, "esviritu batch=true", "esviritu database=no result=Analyses/esviritu-batch-2026-02-09T12-10-00 sample=-"),
        (Name.probeOnlyKraken2, "kraken2 batch=false", "nil"),
        // The executor.
        (Name.executorKraken2Single, "kraken2 batch=false", "kraken2 database=yes result=Analyses/kraken2-2026-02-11T09-00-00 sample=-"),
        (Name.executorKraken2Batch, "kraken2 batch=true", "kraken2 database=yes result=Analyses/kraken2-batch-2026-02-11T10-00-00 sample=-"),
        (Name.executorEsVirituBatch, "esviritu batch=true", "esviritu database=yes result=Analyses/esviritu-batch-2026-02-11T11-00-00 sample=-"),
        (Name.claimedKraken2, "kraken2 batch=false", "kraken2 database=no result=Analyses/Sample A kraken2 sample=-"),
    ]

    func testAnalysesFolderIdentifiesEveryLayout() async throws {
        let built = try await buildProject()
        for layout in expectedLayouts {
            let folder = built.analyses.appendingPathComponent(layout.name, isDirectory: true)
            let info = AnalysesFolder.analysisInfo(for: folder)
            XCTAssertEqual(
                info.map { "\($0.tool) batch=\($0.isBatch)" },
                layout.info,
                "\(layout.name) is identified differently"
            )
        }
    }

    func testRouterPlacesEveryLayout() async throws {
        let built = try await buildProject()
        for layout in expectedLayouts {
            let folder = built.analyses.appendingPathComponent(layout.name, isDirectory: true)
            XCTAssertEqual(
                describe(ClassifierDatabaseRouter.route(for: folder), paths: built.paths),
                layout.route,
                "\(layout.name) routes differently"
            )
        }
    }

    /// A sample folder of a batch routes to the batch with the sample set, for both tools and for
    /// the window's layout and the executor's.
    func testRouterNarrowsASampleFolderToItsBatch() async throws {
        let built = try await buildProject()
        let cases: [(batch: String, sample: String, expected: String)] = [
            (Name.windowKraken2Batch, Layouts.secondSample, "kraken2 database=yes result=Analyses/kraken2-batch-2026-02-09T10-00-00 sample=MMU-17"),
            (Name.windowKraken2BatchWithoutIndex, Layouts.sample, "kraken2 database=no result=Analyses/kraken2-batch-2026-02-09T11-00-00 sample=HG002"),
            (Name.windowEsVirituBatchOfOne, Layouts.sample, "esviritu database=yes result=Analyses/esviritu-batch-2026-02-09T12-00-00 sample=HG002"),
            (Name.windowEsVirituBatchOfOneWithoutIndex, Layouts.sample, "esviritu database=no result=Analyses/esviritu-batch-2026-02-09T12-10-00 sample=HG002"),
            (Name.executorKraken2Batch, Layouts.secondSample, "kraken2 database=yes result=Analyses/kraken2-batch-2026-02-11T10-00-00 sample=MMU-17"),
            (Name.executorEsVirituBatch, Layouts.sample, "esviritu database=yes result=Analyses/esviritu-batch-2026-02-11T11-00-00 sample=HG002"),
        ]
        for item in cases {
            let sample = built.analyses
                .appendingPathComponent(item.batch, isDirectory: true)
                .appendingPathComponent(item.sample, isDirectory: true)
            XCTAssertEqual(
                describe(ClassifierDatabaseRouter.route(for: sample), paths: built.paths),
                item.expected,
                "\(item.batch)/\(item.sample) routes differently"
            )
        }
    }

    // MARK: - Hidden inputs

    /// The executor keeps materialized reads in a hidden folder at the batch root (decision E3).
    /// Without a manifest the scanner counts a classifier batch by the sample folders that hold the
    /// tool's sidecar, and that hidden folder has neither the name nor the sidecar of a sample.
    func testHiddenInputsFolderDoesNotChangeTheBatchSampleCount() async throws {
        let built = try await buildProject()
        let kraken = built.analyses.appendingPathComponent(Name.executorKraken2Batch, isDirectory: true)
        let esviritu = built.analyses.appendingPathComponent(Name.executorEsVirituBatch, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kraken.appendingPathComponent(".lungfish-classify-inputs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: esviritu.appendingPathComponent(".lungfish-esviritu-inputs").path))
        try FileManager.default.removeItem(at: kraken.appendingPathComponent(ClassificationBatchResultManifest.filename))
        try FileManager.default.removeItem(at: esviritu.appendingPathComponent(EsVirituBatchResultManifest.filename))

        let subtitles = Dictionary(uniqueKeysWithValues: analysisNodes(of: built).map { ($0.title, $0.subtitle ?? "-") })
        XCTAssertEqual(subtitles[Name.executorKraken2Batch], "2 samples · 2026-02-11T10-00-00")
        XCTAssertEqual(subtitles[Name.executorEsVirituBatch], "1 samples · 2026-02-11T11-00-00")
    }

    // MARK: - Failed, cancelled and running runs (decision E5)

    func testEndedAndRunningRunsStayOutOfEveryListing() async throws {
        let built = try await buildProject()
        let hidden = [Name.failedKraken2, Name.cancelledEsVirituBatch, Name.runningKraken2]

        XCTAssertTrue(Set(hidden).isDisjoint(with: analysisNodes(of: built).map(\.title)), "the sidebar lists a run that did not complete")
        let listed = try AnalysesFolder.listAnalyses(in: built.project).map(\.url.lastPathComponent)
        XCTAssertTrue(Set(hidden).isDisjoint(with: listed), "the analyses listing includes a run that did not complete")
        for name in hidden {
            let folder = built.analyses.appendingPathComponent(name, isDirectory: true)
            XCTAssertTrue(AnalysesFolder.isAnalysisIncomplete(folder), "\(name) lost its run record")
            XCTAssertNotNil(AnalysesFolder.analysisInfo(for: folder), "\(name) keeps its metadata, so only the run record hides it")
        }
    }

    func testEndedRunsKeepTheirOutcomeAndAreOfferedForReview() async throws {
        let built = try await buildProject()
        let kraken2Command = Layouts.recordedCommand(for: "kraken2")
        let esVirituCommand = Layouts.recordedCommand(for: "esviritu")
        let runs = AnalysesFolder.incompleteAnalysisRuns(in: built.project)
        XCTAssertEqual(
            runs.map { "\(built.paths.render($0.directory) ?? "-") outcome=\($0.record?.outcome?.rawValue ?? "none") command=\($0.record?.command ?? "-")" },
            [
                "Analyses/\(Name.cancelledEsVirituBatch) outcome=cancelled command=\(esVirituCommand)",
                "Analyses/\(Name.failedKraken2) outcome=failed command=\(kraken2Command)",
                "Analyses/\(Name.runningKraken2) outcome=none command=\(kraken2Command)",
            ],
            "the listing is sorted by path"
        )

        let center = OperationCenter()
        let ids = await InterruptedAnalysisRunDiscovery.registerInterruptedRuns(
            in: built.project,
            center: center,
            processProbe: { _ in .notRunning }
        )
        let rows = ids.compactMap { id in center.items.first { $0.id == id } }
        XCTAssertEqual(
            rows.map { "\($0.title) | \($0.detail.components(separatedBy: " started").first ?? "-") | \($0.state) | \($0.cliCommand ?? "-")" }.sorted(),
            [
                "EsViritu: \(Name.cancelledEsVirituBatch) | Cancelled run | interrupted | \(esVirituCommand)",
                "Kraken2: \(Name.failedKraken2) | Failed run | interrupted | \(kraken2Command)",
                "Kraken2: \(Name.runningKraken2) | Interrupted run | interrupted | \(kraken2Command)",
            ]
        )
        for name in [Name.failedKraken2, Name.cancelledEsVirituBatch, Name.runningKraken2] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: built.analyses.appendingPathComponent(name).path),
                "discovery never deletes \(name)"
            )
        }
    }

    // MARK: - Claimed folders (risk R11)

    /// The command line writes no metadata. A `--output-dir` outside Analyses is therefore an
    /// ordinary folder of files today. The executor claims it with metadata, and the generic
    /// scan hides every folder that carries metadata, so the claimed folder leaves the sidebar.
    func testMetadataOfAClaimedFolderOutsideAnalysesHidesIt() async throws {
        let built = try await buildProject()
        let imports = try XCTUnwrap(SidebarProjectScanner.scanRootNodes(from: built.project).first { $0.title == "Imports" })
        XCTAssertEqual(imports.children.map(\.title), [Name.outsideCLIOutput])
        XCTAssertEqual(
            imports.children.first?.children.map(\.title),
            ["classification.kreport"],
            "the sidecar and the hidden files of the command line output stay out of the folder row"
        )
        XCTAssertNotNil(AnalysesFolder.readAnalysisMetadata(from: built.imports.appendingPathComponent(Name.outsideClaimedOutput)))
        XCTAssertNil(AnalysesFolder.readAnalysisMetadata(from: built.imports.appendingPathComponent(Name.outsideCLIOutput)))
    }

    // MARK: - Writer parity

    /// "As an import writes it" is a claim about `MetagenomicsImportService.importEsViritu`, so
    /// this runs the writer on a detection table and compares its folder with the fixture. Every
    /// file name and the sidebar row must agree. A writer that changes its layout fails here, and
    /// its owner decides whether the fixture or the readers follow.
    func testImportedEsVirituFixtureIsWhatTheImportWriterLeaves() throws {
        let root = try TestTempDirectory.make(prefix: "ClassifierLayoutImport")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("input", isDirectory: true)
        try Layouts.writeEsVirituDetectionTable(sample: Layouts.sample, into: input, virusCount: 3)

        let written = try MetagenomicsImportService.importEsViritu(
            inputURL: input,
            outputDirectory: root.appendingPathComponent("written.lungfish/Analyses", isDirectory: true),
            preferredName: "HG002_import"
        ).resultDirectory
        let fixture = try Layouts.importedEsViritu(
            named: Name.importedEsViritu,
            timestamp: "2026-02-09T12-30-00",
            in: root.appendingPathComponent("fixture.lungfish/Analyses", isDirectory: true)
        )

        XCTAssertEqual(written.lastPathComponent, Name.importedEsViritu)
        XCTAssertEqual(
            try FileManager.default.subpathsOfDirectory(atPath: written.path).sorted(),
            try FileManager.default.subpathsOfDirectory(atPath: fixture.path).sorted(),
            "the import writer leaves a different set of files than the fixture"
        )
        func row(of project: String) -> String {
            let url = root.appendingPathComponent(project, isDirectory: true)
            return SidebarScanSnapshot.render(SidebarProjectScanner.scanRootNodes(from: url), projectURL: url, summary: "")
        }
        XCTAssertEqual(row(of: "written.lungfish"), row(of: "fixture.lungfish"))
    }

    // MARK: - Helpers

    private func analysisNodes(of built: Built) -> [SidebarScanNode] {
        SidebarProjectScanner.scanRootNodes(from: built.project).first { $0.title == "Analyses" }?.children ?? []
    }

    private func describe(_ route: ClassifierDatabaseRouter.Route?, paths: SafetyNetPathRenderer) -> String {
        guard let route else { return "nil" }
        return "\(route.tool) database=\(route.databaseURL == nil ? "no" : "yes") result=\(paths.render(route.resultURL) ?? "-") sample=\(route.sampleId ?? "-")"
    }
}

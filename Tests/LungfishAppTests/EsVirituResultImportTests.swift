// EsVirituResultImportTests.swift - Where an imported classifier result lists in the sidebar, and whether it opens
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane ROW20 (row 20, V10). The Import Center sent a NAO-MGS result to the project's Analyses folder and an
// EsViritu, Kraken2 or TaxTriage result to its Imports folder, and the Tools menu sent an NVD result to Imports. The
// sidebar lists a NAO-MGS or NVD bundle from any folder and the other kinds only from Analyses, so an imported
// EsViritu result never showed (SidebarProjectScanner.swift:297-300 and :920). These cases drive a real sidebar over a
// project folder and run the route's argv in process as the vehicle of the import, as
// ClassifierResultImportRecordTests does.
//
// The first two cases are pins that pass at the base and keep passing. They record what an older result under Imports
// does today, for each kind, so the move of the new imports to Analyses leaves that layout as it is (UX 6).

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class EsVirituResultImportTests: XCTestCase {
    private var root: URL!
    private var split: MainSplitViewController?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "esviritu-result-import")
    }

    override func tearDown() async throws {
        split?.sidebarController.closeProject()
        split = nil
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Pins that pass at the base

    /// A NAO-MGS or NVD bundle that an earlier version put under Imports is a row of the real sidebar, of its own
    /// kind, and the row can be selected. The route tests open both bundles from Imports in the viewer (the rows
    /// "NAO-MGS result bundle" and "NVD result bundle" of RoutingSafetyNetTable+BundleAndClassifierRows.swift).
    func testOlderNaoMgsAndNvdResultsUnderImportsStillListAndSelect() async throws {
        let project = try makeProject()
        let imports = try makeFolder("Imports", in: project)
        let naoMgs = try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-older-import", in: imports).bundle
        let nvd = try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-older-import", in: imports).bundle
        let expected: [(URL, SidebarItemType)] = [(naoMgs, .naoMgsResult), (nvd, .nvdResult)]

        let sidebar = openSidebar(on: project)
        for (bundle, type) in expected {
            let row = try XCTUnwrap(self.row(for: bundle, in: sidebar), "\(bundle.lastPathComponent) under Imports is not a row")
            XCTAssertEqual(row.type, type, bundle.lastPathComponent)
            XCTAssertTrue(sidebar.selectItem(forURL: bundle), "\(bundle.lastPathComponent) cannot be selected")
            XCTAssertEqual(
                sidebar.selectedFileURLs().map { $0.resolvingSymlinksInPath().path },
                [bundle.resolvingSymlinksInPath().path]
            )
        }
    }

    /// The record for the kinds that the sidebar lists only from Analyses. An EsViritu, Kraken2 or TaxTriage result that
    /// an earlier version imported into Imports is no row of the sidebar and its folder cannot be selected, so it does
    /// not open. The 2.14 notes carry that as a Known limit, and nothing under Imports is moved or rewritten.
    func testOlderEsVirituKraken2AndTaxTriageResultsUnderImportsDoNotList() async throws {
        let project = try makeProject()
        let imports = try makeFolder("Imports", in: project)
        let older: [(MetagenomicsImportKind, URL)] = [
            (.kraken2, try ClassifierImportAppFixtures.kraken2Report(in: root)),
            (.esviritu, try ClassifierImportAppFixtures.esVirituResult(in: root)),
            (.taxtriage, try ClassifierImportAppFixtures.taxTriageResult(in: root)),
        ]
        var folders: [(MetagenomicsImportKind, URL)] = []
        for (kind, input) in older {
            folders.append((kind, try await importResult(kind, input: input, into: imports)))
        }

        let sidebar = openSidebar(on: project)
        for (kind, folder) in folders {
            let row = self.row(for: folder, in: sidebar)
            XCTAssertNil(row, "the \(kind.rawValue) result \(folder.lastPathComponent) under Imports lists as \(String(describing: row?.type))")
            XCTAssertFalse(sidebar.selectItem(forURL: folder), "the \(kind.rawValue) result under Imports can be selected")
        }
    }

    // MARK: - Row 20, the fix

    /// An EsViritu result imported through the route lists in the sidebar and opens with the source folder's
    /// detections. The route's argv runs in process into the folder that the one destination function gives. The
    /// sidebar lists the result as an EsViritu row, the router places the row's folder as an EsViritu result, and
    /// opening it builds the result's index as the viewer does (`lungfish-cli build-db esviritu <result>`). The opened
    /// result's detection count and read counts equal those of the source folder (BIO). It failed at the base, where
    /// the result went to Imports and never listed.
    func testImportedCLIResultIsListedAndOpens() async throws {
        let project = try makeProject()
        let input = try ClassifierImportAppFixtures.esVirituResult(in: root)
        let destination = try ClassifierResultImportCLIRoute.destination(projectURL: project)
        let imported = try await importResult(.esviritu, input: input, into: destination)

        let sidebar = openSidebar(on: project)
        let row = try XCTUnwrap(
            self.row(for: imported, in: sidebar),
            "the imported EsViritu result \(imported.path) is not a row of the sidebar"
        )
        XCTAssertEqual(row.type, .esvirituResult)
        XCTAssertTrue(sidebar.selectItem(forURL: imported), "the imported result cannot be selected")

        let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: imported), "the row's folder routes to no classifier")
        XCTAssertEqual(route.analysisID, .esviritu)
        XCTAssertEqual(route.resultURL.resolvingSymlinksInPath().path, imported.resolvingSymlinksInPath().path)
        XCTAssertNil(route.databaseURL, "an import leaves no index, so opening the row builds it")
        let build = try await ClassifierImportAppFixtures.runCLI(["build-db", route.tool, route.resultURL.path], in: root)
        XCTAssertNil(build.failure, build.lines.joined(separator: "\n"))

        let database = try EsVirituDatabase(at: route.resultURL.appendingPathComponent("esviritu.sqlite"))
        let samples = try database.fetchSamples()
        let rows = try database.fetchRows(samples: samples.map(\.sample))
        let table = input.appendingPathComponent("\(ClassifierImportAppFixtures.sampleID).detected_virus.info.tsv")
        let source = try EsVirituDetectionParser.parse(url: table)
        XCTAssertFalse(source.isEmpty, "the source folder holds detections")
        XCTAssertEqual(samples.map(\.detectionCount), [source.count], "detections of the opened result and the source folder")
        XCTAssertEqual(rows.count, source.count)
        XCTAssertEqual(rows.map(\.accession).sorted(), source.map(\.accession).sorted())
        XCTAssertEqual(
            rows.map(\.readCount).sorted(), source.map(\.readCount).sorted(),
            "read counts of the opened result and the source folder"
        )
    }

    /// The Kraken2, TaxTriage and NVD imports move with the EsViritu import (ARCH 4, the changed route). Each result the
    /// route's argv imports into the destination is a row of its own kind in the sidebar, as a run's result is.
    func testKraken2TaxTriageAndNvdImportsListFromAnalysesToo() async throws {
        let project = try makeProject()
        let destination = try ClassifierResultImportCLIRoute.destination(projectURL: project)
        let imported: [(MetagenomicsImportKind, URL, SidebarItemType)] = [
            (.kraken2, try await importResult(.kraken2, input: ClassifierImportAppFixtures.kraken2Report(in: root), into: destination), .classificationResult),
            (.taxtriage, try await importResult(.taxtriage, input: ClassifierImportAppFixtures.taxTriageResult(in: root), into: destination), .taxTriageResult),
            (.nvd, try await importResult(.nvd, input: NaoMgsNvdAppFixtures.nvdRun(in: root), into: destination), .nvdResult),
        ]

        let sidebar = openSidebar(on: project)
        for (kind, folder, type) in imported {
            let row = try XCTUnwrap(self.row(for: folder, in: sidebar), "the imported \(kind.rawValue) result is not a row")
            XCTAssertEqual(row.type, type, kind.rawValue)
        }
    }

    /// Every kind is told to write into `<project>/Analyses`, which the destination makes when the project has none, and
    /// the row's Copy CLI Command names it (the prediction row of the report, `--output-dir <project>/Imports` before).
    func testTheDestinationIsTheProjectsAnalysesFolderForEveryKind() throws {
        let project = try makeProject()
        let destination = try ClassifierResultImportCLIRoute.destination(projectURL: project)

        XCTAssertEqual(
            destination.resolvingSymlinksInPath().path,
            project.appendingPathComponent(AnalysesFolder.directoryName).resolvingSymlinksInPath().path
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let input = root.appendingPathComponent("incoming", isDirectory: true)
        for kind in MetagenomicsImportKind.allCases {
            let command = ClassifierResultImportCLIRoute.rowCommand(
                kind: kind, inputURL: input, outputDirectory: destination, preferredName: nil
            )
            XCTAssertTrue(command.contains("--output-dir \(destination.path) "), "\(kind.rawValue): \(command)")
            XCTAssertFalse(command.contains("/Imports"), "\(kind.rawValue): \(command)")
        }
        XCTAssertEqual(try listing(of: project), [AnalysesFolder.directoryName])
    }

    /// An Analyses folder that resolves outside the project is refused before anything is written (SWIFT 6).
    func testAnAnalysesFolderThatLeavesTheProjectIsRefusedBeforeAnythingIsWritten() throws {
        let project = try makeProject()
        let outside = try makeFolder("Elsewhere", in: root)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(AnalysesFolder.directoryName), withDestinationURL: outside
        )

        XCTAssertThrowsError(try ClassifierResultImportCLIRoute.destination(projectURL: project)) { error in
            XCTAssertEqual(
                error as? ClassifierResultImportCLIRoute.DestinationError,
                .outsideProject(outside.resolvingSymlinksInPath())
            )
        }
        XCTAssertEqual(try listing(of: outside), [], "nothing was written outside the project")
    }

    /// A name that tries to leave the folder is kept to one folder inside Analyses by the leaf's sanitizer, which the
    /// destination relies on (ARCH 4, SWIFT 6). The command runs with `--name ../../Escape`.
    func testAHostileResultNameStaysInsideAnalyses() async throws {
        let project = try makeProject()
        let input = try ClassifierImportAppFixtures.esVirituResult(in: root)
        let destination = try ClassifierResultImportCLIRoute.destination(projectURL: project)
        let argv = ClassifierResultImportCLIRoute.arguments(
            kind: .esviritu, inputURL: input, outputDirectory: destination, preferredName: "../../Escape"
        )

        let run = try await ClassifierImportAppFixtures.runCLI(argv, in: root)

        XCTAssertNil(run.failure, run.lines.joined(separator: "\n"))
        XCTAssertEqual(try listing(of: destination), ["esviritu-Escape"])
        XCTAssertEqual(try listing(of: project), [AnalysesFolder.directoryName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Escape").path))
    }

    /// A source folder that is already named for the kind keeps one prefix. The 2.13 walk imported a folder named
    /// `esviritu-one-folder` and the leaf made `esviritu-esviritu-one-folder`. The destination holds one folder named
    /// `esviritu-one-folder` and the sidebar lists it as an EsViritu row (the ROW20-UX review, section R6).
    func testASourceFolderAlreadyNamedForTheKindKeepsOneEsvirituPrefix() async throws {
        let project = try makeProject()
        let input = root.appendingPathComponent("esviritu-one-folder", isDirectory: true)
        try FileManager.default.moveItem(at: ClassifierImportAppFixtures.esVirituResult(in: root), to: input)
        let destination = try ClassifierResultImportCLIRoute.destination(projectURL: project)

        let imported = try await importResult(.esviritu, input: input, into: destination)

        XCTAssertEqual(try listing(of: destination), ["esviritu-one-folder"])
        XCTAssertEqual(imported.lastPathComponent, "esviritu-one-folder")
        let sidebar = openSidebar(on: project)
        let row = try XCTUnwrap(
            self.row(for: imported, in: sidebar),
            "the imported EsViritu result \(imported.path) is not a row of the sidebar"
        )
        XCTAssertEqual(row.type, .esvirituResult)
    }

    // MARK: - Helpers

    private func makeProject() throws -> URL {
        try makeFolder("Pins.lungfish", in: root)
    }

    private func makeFolder(_ name: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A real sidebar over `project`, loaded from the file system as the app loads it, with its watcher dropped.
    private func openSidebar(on project: URL) -> SidebarViewController {
        _ = NSApplication.shared
        let controller = MainSplitViewController()
        _ = controller.view
        split = controller
        let sidebar: SidebarViewController = controller.sidebarController
        sidebar.openProject(at: project)
        sidebar.detachFilesystemWatcherForTesting()
        sidebar.reloadFromFilesystem()
        return sidebar
    }

    private func rows(of sidebar: SidebarViewController) -> [SidebarItem] {
        var found: [SidebarItem] = []
        func walk(_ items: [SidebarItem]) {
            for item in items {
                found.append(item)
                walk(item.children)
            }
        }
        walk(sidebar.rootItems)
        return found
    }

    private func row(for folder: URL, in sidebar: SidebarViewController) -> SidebarItem? {
        let path = folder.resolvingSymlinksInPath().path
        return rows(of: sidebar).first { $0.url?.resolvingSymlinksInPath().path == path }
    }

    private func listing(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
    }

    /// Imports `input` with the route's argv run in process into `destination`, and returns the one result folder the
    /// command made there.
    private func importResult(_ kind: MetagenomicsImportKind, input: URL, into destination: URL) async throws -> URL {
        let before = Set(try listing(of: destination))
        let argv = ClassifierResultImportCLIRoute.arguments(
            kind: kind, inputURL: input, outputDirectory: destination, preferredName: nil
        )
        let run = try await ClassifierImportAppFixtures.runCLI(argv, in: root)
        XCTAssertNil(run.failure, run.lines.joined(separator: "\n"))
        let made = Set(try listing(of: destination)).subtracting(before)
        XCTAssertEqual(made.count, 1, "\(made)")
        return destination.appendingPathComponent(try XCTUnwrap(made.first), isDirectory: true)
    }
}

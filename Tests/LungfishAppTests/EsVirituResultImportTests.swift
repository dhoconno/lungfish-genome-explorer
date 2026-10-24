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

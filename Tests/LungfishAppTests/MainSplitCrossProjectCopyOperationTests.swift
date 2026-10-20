// MainSplitCrossProjectCopyOperationTests.swift - begin() site in MainSplitViewController+CrossProjectCopy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A Lungfish item dropped into an open project is copied one row per item
// (R4). The row records `lungfish-cli project copy-item`, which these tests
// parse with the shipped parser (Phase 2.12 lane 12.18, gap id
// `cross-project-copy` closed). The hidden key `CrossProjectCopyRoute` and its
// `legacy` route, whose row recorded no command, went in Phase 2.13. The row
// locks no bundle, so a reporter that refuses every begin stands in for a
// refusal.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class MainSplitCrossProjectCopyOperationTests: XCTestCase {
    private let itemURL = URL(
        fileURLWithPath: "/tmp/lane 1k2/Other.lungfish/Imports/Sample 1.lungfishfastq",
        isDirectory: true
    )
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1k2/Project.lungfish", isDirectory: true)
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1k2/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    func testCopyRowRecordsTheCopyItemCommandThatParses() throws {
        let reporter = RecordingOperationReporter()

        let result = MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: itemURL,
            projectURL: projectURL,
            requestedFolder: nil,
            routeContext: routeContext,
            reporter: reporter
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(item.title, "Copy Sample 1.lungfishfastq")
        XCTAssertEqual(item.initialDetail, "Copying into Project...")
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        let parsed = try RecordedCLICommand.parse(item.cliCommand, as: ProjectCopyItemSubcommand.self)
        XCTAssertEqual(parsed.item, "Imports/Sample 1.lungfishfastq", "the item by its path inside its project")
        XCTAssertEqual(parsed.sourceProject, "/tmp/lane 1k2/Other.lungfish")
        XCTAssertEqual(parsed.project, "/tmp/lane 1k2/Project.lungfish")
        XCTAssertNil(parsed.folder)
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json, "the row reads the command's events")
    }

    func testCopyRowRecordsTheFolderTheItemWasDroppedOnInsideTheProject() throws {
        let reporter = RecordingOperationReporter()
        let cases: [(folder: URL, recorded: String)] = [
            (projectURL.appendingPathComponent("Imports/Reviewed", isDirectory: true), "Imports/Reviewed"),
            (projectURL, "."),
        ]

        for (folder, recorded) in cases {
            MainSplitViewController.beginCrossProjectCopyOperation(
                itemURL: itemURL,
                projectURL: projectURL,
                requestedFolder: folder,
                routeContext: nil,
                reporter: reporter
            )
            let parsed = try RecordedCLICommand.parse(reporter.items.last?.cliCommand, as: ProjectCopyItemSubcommand.self)
            XCTAssertEqual(parsed.folder, recorded, folder.path)
        }
    }

    func testFinderItemInNoProjectIsRecordedByItsAbsolutePath() throws {
        let reporter = RecordingOperationReporter()
        let finderItem = URL(fileURLWithPath: "/tmp/lane 1k2/Loose/NC_045512.lungfishref", isDirectory: true)

        MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: finderItem,
            projectURL: projectURL,
            requestedFolder: nil,
            routeContext: nil,
            reporter: reporter
        )

        let parsed = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: ProjectCopyItemSubcommand.self)
        XCTAssertEqual(parsed.item, finderItem.path)
        XCTAssertNil(parsed.sourceProject)
    }

    func testRefusedCopyReturnsTheRefusalSoTheItemIsSkipped() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let result = MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: itemURL,
            projectURL: projectURL,
            requestedFolder: nil,
            routeContext: nil,
            reporter: reporter
        )

        XCTAssertNil(result.startedID)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}

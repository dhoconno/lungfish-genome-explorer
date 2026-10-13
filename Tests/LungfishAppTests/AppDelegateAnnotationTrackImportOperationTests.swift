// AppDelegateAnnotationTrackImportOperationTests.swift - The begin() site of the annotation track attach
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Import Center and a file dropped on the sidebar attach an annotation
// file to a reference bundle through one begin helper,
// `AppDelegate.beginAnnotationTrackImportOperation` (2.10 A42). Its row keeps
// the words, type and lock the two inline sites registered before. Since M3
// both sites launch `lungfish-cli sequence attach-track` with the argv the
// helper hands them, and the row records that argv, so these parse tests
// replace the two gap pins. AnnotationTrackAttachCLIGUIParityReplayTests
// replays the command.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class AppDelegateAnnotationTrackImportOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Sample.lungfishref", isDirectory: true)
    private let annotationURL = URL(fileURLWithPath: "/tmp/lane 1a2/genes v2.gff3")

    func testAHeldBundleLockRefusesTheRowAndLaunchesNothing() async throws {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Find ORFs",
            detail: "Running",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli sequence annotate-orfs"
        ).startedID)
        var launched = false

        let result = await AppDelegate.beginAnnotationTrackImportOperation(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: center
        ) { _, _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a refused begin must not start the attach")
        }
        XCTAssertFalse(launched, "a refused row must write nothing to the bundle")
        XCTAssertEqual(refusal.blockingOperationTitle, "Find ORFs")
    }

    func testTheRowLocksTheBundleAndRecordsTheSequenceAttachTrackItLaunches() async throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
            windowStateScopeID: UUID()
        )
        var launched: (id: UUID, arguments: [String])?

        // The Import Center's sheet names the track. A hyphen-leading name replays as a value.
        await AppDelegate.beginAnnotationTrackImportOperation(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            trackID: "genes_v2",
            trackName: "-genes v2",
            routeContext: routeContext,
            reporter: reporter
        ) { launched = ($0, $1) }

        let item = try XCTUnwrap(reporter.items.first)
        let arguments = try XCTUnwrap(launched?.arguments)
        XCTAssertEqual(launched?.id, item.id)
        XCTAssertEqual(item.title, "Annotation Import")
        XCTAssertEqual(item.initialDetail, "Importing genes v2.gff3...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(subcommand: "sequence attach-track", args: Array(arguments.dropFirst(2))),
            "the row records the argv the launch runs"
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.AttachTrack.self)
        XCTAssertEqual(command.bundle, bundleURL.path)
        XCTAssertEqual(command.annotationFile, annotationURL.path)
        XCTAssertEqual(command.trackID, "genes_v2")
        XCTAssertEqual(command.trackName, "-genes v2")
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the command's events")
    }

    func testARowWithNoChosenTrackRecordsNoTrackOptions() async throws {
        // A sidebar drop whose sheet keeps the defaults, and each file of a multi-file import.
        let reporter = RecordingOperationReporter()
        await AppDelegate.beginAnnotationTrackImportOperation(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: reporter
        ) { _, _ in }

        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: SequenceCommand.AttachTrack.self)
        XCTAssertEqual([command.bundle, command.annotationFile], [bundleURL.path, annotationURL.path])
        XCTAssertNil(command.trackID)
        XCTAssertNil(command.trackName)
    }
}

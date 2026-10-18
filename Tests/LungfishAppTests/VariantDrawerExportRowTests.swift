// VariantDrawerExportRowTests.swift - The Operations rows of the variant drawer's bookmark and template exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, ARCH ruling 1.5 rule 3. `AnnotationTableDrawerView.beginBookmarkedVariantsExportOperation`
// and `AnnotationTableDrawerView.beginVariantSampleTemplateExportOperation` begin an export row with no lock and a
// cancel callback, record the `variants export bookmarked` and `variants export sample-template` commands the runner
// runs, and launch nothing when the row is refused. VariantExportCLIGUIParityReplayTests runs the commands.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class VariantExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class VariantDrawerExportRowTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = try TestTempDirectory.make(prefix: "variant-drawer-export-row")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
    }

    private let bookmarkedInvocation = BookmarkedVariantExport.invocation(
        databaseURLs: [
            URL(fileURLWithPath: "/tmp/lane 12.39/Ref.lungfishref/first.db"),
            URL(fileURLWithPath: "/tmp/lane 12.39/Ref.lungfishref/first.db"),
            URL(fileURLWithPath: "/tmp/lane 12.39/Ref.lungfishref/second.db"),
        ],
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.39/bookmarks, all.tsv"),
        force: true
    )

    private func templateInvocation() -> ViewerExportInvocation {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.sampleMetadataFields = ["collection_date", "country"]
        return drawer.variantSampleTemplateExportInvocation(
            bundleURL: URL(fileURLWithPath: "/tmp/lane 12.39/Ref.lungfishref", isDirectory: true),
            outputURL: URL(fileURLWithPath: "/tmp/lane 12.39/template, all.csv")
        )
    }

    /// A drawer over the fixture bundle's one variant track, as the viewer gives it its search index.
    private func drawer(over fixture: VariantEditFixture) async throws -> AnnotationTableDrawerView {
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: try await ReferenceBundle(url: fixture.bundleURL), chromosomes: [])
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = index
        return drawer
    }

    func testTheBookmarkedRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AnnotationTableDrawerView.beginBookmarkedVariantsExportOperation(
            invocation: bookmarkedInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Bookmarked Variants")
        XCTAssertEqual(item.initialDetail, "Writing bookmarks, all.tsv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: VariantsCommand.ExportBookmarkedSubcommand.self)
        XCTAssertEqual(command.invocation(), bookmarkedInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.databasePaths, [
            "/tmp/lane 12.39/Ref.lungfishref/first.db", "/tmp/lane 12.39/Ref.lungfishref/first.db",
            "/tmp/lane 12.39/Ref.lungfishref/second.db",
        ], "one path for each track, in track order, never deduplicated")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.39/bookmarks, all.tsv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testTheSampleTemplateRowRecordsTheLeafCommandItRuns() async throws {
        let invocation = templateInvocation()
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AnnotationTableDrawerView.beginVariantSampleTemplateExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Sample Metadata Template")
        XCTAssertEqual(item.initialDetail, "Writing template, all.csv")

        let command = try RecordedCLICommand.parse(
            item.cliCommand, as: VariantsCommand.ExportSampleTemplateSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), invocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.39/Ref.lungfishref")
        XCTAssertEqual(command.format.format, .csv, "a .csv name asks for CSV, as the drawer's closure read it")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.39/template, all.csv")
        XCTAssertFalse(command.output.force, "no file was there, so the leaf is not told to replace one")
        XCTAssertEqual(try command.invocation().state.metadataColumns, ["collection_date", "country"])
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    /// The drawer says "No Bookmarks" before its save panel and begins no row when no track holds a bookmark, and
    /// passes one database path for each track once one does.
    func testNoBookmarkBeginsNoRow() async throws {
        let fixture = try VariantEditFixture.make(in: folder, withTrackManifest: true)
        let drawer = try await drawer(over: fixture)
        XCTAssertNil(drawer.bookmarkedVariantsExportDatabaseURLs())
        let rowsBefore = OperationCenter.shared.items.count
        drawer.exportBookmarkedVariants(nil)
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore, "no row began and no leaf ran")

        let handle = try XCTUnwrap(drawer.searchIndex?.variantDatabaseHandles.first)
        XCTAssertTrue(handle.db.toggleBookmark(variantId: try XCTUnwrap(fixture.variantIDs().first)))
        let urls = try XCTUnwrap(drawer.bookmarkedVariantsExportDatabaseURLs())
        XCTAssertEqual(urls.map(\.standardizedFileURL.path), [fixture.databaseURL.standardizedFileURL.path])
    }

    func testARefusedRowLaunchesNothing() throws {
        let invocations: [(ViewerExportInvocation, Bool)] = [(bookmarkedInvocation, true), (templateInvocation(), false)]
        for (invocation, bookmarked) in invocations {
            let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
            let onFailure: @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void = { _ in
                XCTFail("a refused row runs nothing, so nothing fails")
            }
            let runner = CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false"))
            let begun = bookmarked
                ? AnnotationTableDrawerView.beginBookmarkedVariantsExportOperation(
                    invocation: invocation, runner: runner, reporter: reporter, onFailure: onFailure
                )
                : AnnotationTableDrawerView.beginVariantSampleTemplateExportOperation(
                    invocation: invocation, runner: runner, reporter: reporter, onFailure: onFailure
                )

            XCTAssertNil(begun)
            XCTAssertEqual(reporter.items.map(\.state), [.refused])
            if bookmarked {
                let command = try RecordedCLICommand.parse(
                    reporter.items.first?.cliCommand, as: VariantsCommand.ExportBookmarkedSubcommand.self
                )
                XCTAssertEqual(command.invocation(), invocation)
            } else {
                let command = try RecordedCLICommand.parse(
                    reporter.items.first?.cliCommand, as: VariantsCommand.ExportSampleTemplateSubcommand.self
                )
                XCTAssertEqual(try command.invocation(), invocation)
            }
        }
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once, which the drawer shows under
    /// "Bookmark Export Failed" or "Template Export Failed" (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        for bookmarked in [true, false] {
            let calls = VariantExportFailureCalls()
            let runner = CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false"))
            let onFailure: @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void = { failure in
                calls.messages.append(failure.message)
            }
            let begun = try XCTUnwrap(bookmarked
                ? AnnotationTableDrawerView.beginBookmarkedVariantsExportOperation(
                    invocation: bookmarkedInvocation, runner: runner, reporter: RecordingOperationReporter(),
                    onFailure: onFailure
                )
                : AnnotationTableDrawerView.beginVariantSampleTemplateExportOperation(
                    invocation: templateInvocation(), runner: runner, reporter: RecordingOperationReporter(),
                    onFailure: onFailure
                ))
            let outcome = await begun.task.value
            guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertEqual(calls.messages, [failure.message])
        }
    }
}

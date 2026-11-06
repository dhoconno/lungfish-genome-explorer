// AssemblyResultSurfaceRouteTests.swift - The assembly viewer on the surface host, its five tools and every way out (Phase 3.2 lane ASM)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Five tool kinds share one viewer, so these tests read what a slip would change: which kind opens, the tool's name on the
// viewer, the numbers and the contig table, and where a BLAST search reports. The leaf that a search reaches here is a
// stand-in script found through `LUNGFISH_CLI_PATH`, and each test that sends checks that before it sends, so nothing
// reaches NCBI.

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishAssemblyUI
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

/// What a contigs file that does not read says. A real load throws this kind of error, not a `SurfaceError`.
private struct DamagedContigsFile: LocalizedError {
    var errorDescription: String? { "contigs.fasta ends in the middle of a record" }
}

/// A surface whose load fails on the file, so the assembly's show never installs.
@MainActor
private final class RefusingAssemblySurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .analysis(.spades) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw DamagedContigsFile()
    }
}

@MainActor
final class AssemblyResultSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    private let chromeVisible = AlignmentChrome(ruler: false, viewer: false, header: false, status: false)
    private let chromeCovered = AlignmentChrome(ruler: true, viewer: true, header: true, status: true)
    private let nextStep = "Select the item again. If it still does not open, check that the assembly's folder is complete or run the assembly again."

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "AssemblySurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        BlastConsentSheet.presenterForTesting = nil
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The surface, one for each tool

    /// A tool that joins `AnalysisToolRegistry.swift` and reaches this viewer's route fails here until it has a surface.
    func testEveryAssemblyToolHasARegisteredSurface() {
        let viewer = ViewerViewController()
        _ = viewer.view

        let assemblers = AnalysisToolRegistry.all.map(\.id).filter {
            AnalysisResultDisplayRoute.route(forToolID: $0.rawValue) == .assembly
        }

        XCTAssertEqual(
            Set(assemblers.map(\.rawValue)), Set(AssemblyTool.allCases.map(\.rawValue)),
            "the registry's assemblers and the assembler list differ"
        )
        for id in assemblers {
            do {
                let surface = try viewer.surfaceHost.registry.make(.analysis(id))
                XCTAssertEqual(surface.surfaceKind, .analysis(id))
            } catch {
                XCTFail("\(id.rawValue) has no registered surface: \(error)")
            }
        }
    }

    func testEachToolOpensThroughTheRouteInAFreshWindowWithItsOwnName() async throws {
        for tool in AssemblyTool.allCases {
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            let viewer = harness.split.viewerController!

            harness.select(try makeResult(of: tool).item)

            await assertShows(tool, in: viewer)
            // The numbers of the contigs `makeResult` writes (20 and 12 bases), read for every tool and not only the seed's.
            await assertSummary("assembly-result-summary-contigs", reads: "2", in: viewer)
            await assertSummary("assembly-result-summary-total-bp", reads: "32", in: viewer)
            await assertSummary("assembly-result-summary-n50", reads: "20 bp", in: viewer)
            await assertSummary("assembly-result-summary-longest", reads: "20 bp", in: viewer)
            let filled = await waitUntil(budget: .lookup) {
                viewer.assemblyResultController?.testContigTableView.displayedRows.map(\.lengthBP) == [20, 12]
            }
            XCTAssertTrue(
                filled, "\(tool.displayName)'s table reads \(String(describing: viewer.assemblyResultController?.testContigTableView.displayedRows.map(\.lengthBP)))"
            )
            XCTAssertEqual(AlignmentChrome(viewer), chromeCovered, "the genomics chrome shows under \(tool.displayName)")
            XCTAssertEqual(viewer.contentMode, .assembly)
        }
    }

    /// Each tool after a kind that is not an assembly, then after another tool, so that no name stays from the last one.
    func testEachToolKeepsItsOwnNameAfterAnotherKindAndAfterAnotherTool() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rest = try await buildRow(of: "Status only", under: root)

        for tool in AssemblyTool.allCases {
            let row = try makeResult(of: tool).item
            harness.select(rest)
            let rested = await settle(harness, on: "Status only")
            XCTAssertTrue(rested, "the status row never opened before \(tool.displayName)")
            harness.select(row)
            await assertShows(tool, in: viewer)
        }
        for tool in AssemblyTool.allCases.reversed() {
            harness.select(try makeResult(of: tool).item)
            await assertShows(tool, in: viewer)
        }
    }

    /// `hideAssemblyView` names every tool's kind.
    func testTheShimTakesEachToolsSurfaceAway() throws {
        let viewer = ViewerViewController()
        _ = viewer.view

        for tool in AssemblyTool.allCases {
            try viewer.displayAssemblyResult(try makeResult(of: tool).result)
            XCTAssertEqual(viewer.installedSurface?.surfaceKind, .analysis(AnalysisToolID(rawValue: tool.rawValue)))
            viewer.clearSurface(ifShowing: .analysis(.spades), .analysis(.megahit), .analysis(.skesa), .analysis(.flye), .analysis(.hifiasm))
            XCTAssertNil(viewer.assemblyResultController, "\(tool.displayName) stayed after its hide")
            XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "\(tool.displayName) left the chrome hidden")
        }
    }

    /// The numbers and the contig table of the committed seed's contigs. A slip in the host could change no reading here,
    /// and the same assertions pass at the base.
    func testTheNumbersAndTheContigTableOfTheFixtureDoNotChange() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let analyses = root.appendingPathComponent("Seed/Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let result = try RoutingSafetyNetFixtures.assemblyAnalysis(in: analyses).result

        harness.select(item(result))

        await assertSummary("assembly-result-summary-assembler", reads: "SPAdes", in: viewer)
        await assertSummary("assembly-result-summary-contigs", reads: "2", in: viewer)
        await assertSummary("assembly-result-summary-total-bp", reads: "183", in: viewer)
        await assertSummary("assembly-result-summary-n50", reads: "122 bp", in: viewer)
        await assertSummary("assembly-result-summary-longest", reads: "122 bp", in: viewer)
        let loaded = await waitUntil(budget: .lookup) { viewer.assemblyResultController?.testContigTableView.displayedRows.count == 2 }
        XCTAssertTrue(loaded, "the contig table never filled")
        let rows = viewer.assemblyResultController?.testContigTableView.displayedRows ?? []
        // The file's own lengths, as read at the base. The names in its headers say 500 and 300 and are only names.
        XCTAssertEqual(rows.map(\.name), ["NODE_1_length_500_cov_25.4", "NODE_2_length_300_cov_15.1"])
        XCTAssertEqual(rows.map(\.lengthBP), [122, 61], "the contig table's lengths changed")
        XCTAssertEqual(rows.map(\.rank), [1, 2], "the contig table's order changed")
    }

    /// The controller's first row sits at the top of its own view (`AssemblyResultViewController.layoutSubviews`), so the
    /// surface asks for the safe area, as the old display did.
    func testAssemblyContentStartsBelowTheToolbar() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!

        harness.select(try makeResult(of: .megahit).item)
        await assertShows(.megahit, in: viewer)
        harness.window.contentView?.layoutSubtreeIfNeeded()

        let inset = viewer.view.safeAreaInsets.top
        XCTAssertGreaterThan(inset, 0, "the window has no toolbar inset, so this test cannot tell the two pins apart")
        let assembly = try XCTUnwrap(viewer.assemblyResultController).view
        let top = assembly.convert(assembly.bounds, to: nil).maxY
        let safeTop = viewer.view.convert(viewer.view.safeAreaRect, to: nil).maxY
        XCTAssertLessThanOrEqual(top, safeTop + 0.5, "the viewer starts \(top - safeTop) points above the safe area")
    }

    // MARK: - A result that does not open

    func testAnAssemblyResultThatDoesNotOpenSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let split = harness.split
        let viewer = split.viewerController!
        split.displayContent(for: try makeResult(of: .megahit).item)
        await assertShows(.megahit, in: viewer)
        viewer.surfaceHost.registry.register(.analysis(.spades)) { RefusingAssemblySurface() }

        harness.select(try makeResult(of: .spades).item)

        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Unable to open the assembly. "), "the status line never said the assembly did not open: \(words)")
        XCTAssertTrue(words.contains("contigs.fasta ends in the middle of a record."), "the status line left out the file's own words: \(words)")
        XCTAssertTrue(words.hasSuffix(nextStep), "the status line gave no next step: \(words)")
        XCTAssertFalse(words.contains("analysis:"), "the words name an internal kind id: \(words)")
        assertNothingShows(after: "a refused assembly", in: harness)
    }

    /// The base said `Unable to load assembly result.`, with no reason and no next step, and left the Inspector as it was.
    func testAnAssemblyWhoseRecordIsGoneSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try makeResult(of: .flye).item)
        await assertShows(.flye, in: viewer)
        let gone = try makeResult(of: .megahit)
        try FileManager.default.removeItem(at: gone.folder.appendingPathComponent("assembly-result.json"))

        harness.select(gone.item)

        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Unable to open the assembly. "), "the status line never said the assembly did not open: \(words)")
        XCTAssertTrue(words.contains("assembly-result.json"), "the words do not say which file: \(words)")
        XCTAssertTrue(words.hasSuffix(nextStep), "the status line gave no next step: \(words)")
        assertNothingShows(after: "an assembly with no record", in: harness)
    }

    func testAnAssemblyWhoseRecordDoesNotReadSaysWhatToTry() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let damaged = try makeResult(of: .skesa)
        try "{".write(to: damaged.folder.appendingPathComponent("assembly-result.json"), atomically: true, encoding: .utf8)

        harness.select(damaged.item)

        let words = harness.split.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Unable to open the assembly. "), "the status line never said the assembly did not open: \(words)")
        XCTAssertTrue(words.hasSuffix(nextStep), "the status line gave no next step: \(words)")
        assertNothingShows(after: "an assembly whose record does not read", in: harness)
    }

    /// The base opened the viewer with the record's numbers over an empty table, and an alert.
    func testAnAssemblyWhoseContigsFileIsGoneSaysWhatToTry() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let gone = try makeResult(of: .hifiasm)
        try FileManager.default.removeItem(at: gone.result.contigsPath)

        selectHoldingAnyAlert(gone.item, in: harness)

        let words = harness.split.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Unable to open the assembly. "), "the status line never said the assembly did not open: \(words)")
        XCTAssertTrue(words.contains("contigs.fasta is no longer in this assembly's folder."), "the words do not say what happened: \(words)")
        XCTAssertTrue(words.contains("then select it again."), "the words do not say what to try: \(words)")
        assertNothingShows(after: "an assembly whose contigs file is gone", in: harness)
    }

    func testAnAssemblyWhoseContigsFileIsLockedSaysWhatToTry() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let locked = try makeResult(of: .flye)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.result.contigsPath.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.result.contigsPath.path) }

        selectHoldingAnyAlert(locked.item, in: harness)

        let words = harness.split.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Unable to open the assembly. "), "the status line never said the assembly did not open: \(words)")
        XCTAssertTrue(words.contains("does not allow contigs.fasta to be read."), "the words do not say what happened: \(words)")
        XCTAssertTrue(words.contains("permissions"), "the words do not say what to try: \(words)")
        assertNothingShows(after: "an assembly whose contigs file is locked", in: harness)
    }

    /// A run that made no contigs has no file to read, so nothing is checked and it says so itself.
    func testAResultWithNoContigsHasNoFileToCheckAndStillOpens() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let empty = try makeResult(of: .skesa, outcome: .completedWithNoContigs)
        try FileManager.default.removeItem(at: empty.result.contigsPath)

        harness.select(empty.item)

        let said = await waitUntil(budget: .lookup) {
            viewer.assemblyResultController?.testEmptyStateMessage == "Assembly completed, but no contigs were generated."
        }
        XCTAssertTrue(said, "a result with no contigs did not say so")
        XCTAssertEqual(viewer.contentMode, .assembly)
    }

    /// A catalog load that fails after the person left raises no alert over what replaced it. The base raised one.
    func testALoadThatFailsAfterTheAssemblyHasGoneSaysNothingOverWhatReplacedIt() async throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        try viewer.displayAssemblyResult(try makeResult(of: .spades).result)
        let assembly = try XCTUnwrap(viewer.assemblyResultController)
        var reports: [FailureReport] = []
        assembly.failurePresenter = { reports.append($0) }
        let (held, release) = AsyncStream<Void>.makeStream()
        assembly.catalogLoader = { _ in
            for await _ in held { break }
            throw DamagedContigsFile()
        }

        viewer.clearSurface(ifShowing: .analysis(.spades), .analysis(.megahit), .analysis(.skesa), .analysis(.flye), .analysis(.hifiasm))
        release.yield()
        await assembly.loadTask?.value

        XCTAssertTrue(reports.isEmpty, "a load that failed after the assembly left raised: \(reports.map(\.whatHappened))")
    }

    // MARK: - BLAST

    /// The display's own closure, consent answered, on a stand-in leaf. The search goes on its row and this viewer's drawer,
    /// the person moves to another kind and then to another tool's result, and its answer comes back with the row completed,
    /// on its own drawer and on no other.
    func testBlastFromAContigKeepsItsRowAndComesBackWhileAnotherKindShows() async throws {
        let leaf = try makeStandInLeaf()
        guard useStandIn(leaf.url) else { return }
        defer { unsetenv("LUNGFISH_CLI_PATH") }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rest = try await buildRow(of: "Status only", under: root)
        harness.select(try makeResult(of: .spades).item)
        await assertShows(.spades, in: viewer)
        let assembly = try XCTUnwrap(viewer.assemblyResultController)
        BlastConsentSheet.presenterForTesting = { _, send in send() }

        assembly.onBlastVerification?(BlastRequest(taxId: nil, sequences: [Self.contig], readCount: 1, sourceLabel: "contig contig_1"))

        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "BLAST contig contig_1" }, "the search began no row")
        defer { OperationCenter.shared.clearItem(id: row.id) }
        XCTAssertEqual(row.operationType, .blastVerification)
        XCTAssertEqual(state(of: row.id), .running)
        XCTAssertTrue(assembly.ensureBlastDrawer().showsASearchInProgress, "this viewer's drawer does not show the search")
        let started = await waitUntil(budget: .lookup) { FileManager.default.fileExists(atPath: leaf.started.path) }
        XCTAssertTrue(started, "the stand-in leaf never ran")

        harness.select(rest)
        let left = await waitUntil(budget: .lookup) { viewer.assemblyResultController == nil }
        XCTAssertTrue(left, "the status row left the assembly on screen")
        XCTAssertEqual(state(of: row.id), .running, "moving to another kind ended the search")

        harness.select(try makeResult(of: .megahit).item)
        await assertShows(.megahit, in: viewer)
        let second = try XCTUnwrap(viewer.assemblyResultController)
        XCTAssertEqual(state(of: row.id), .running, "another assembly ended the search")

        try Data().write(to: leaf.release)

        let completed = await waitUntil(budget: .lookup) { self.state(of: row.id) == .completed }
        XCTAssertTrue(completed, "the row never completed: \(String(describing: state(of: row.id)))")
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == row.id }?.detail, "Results ready for 1 contig")
        let landed = await waitUntil(budget: .lookup) { assembly.ensureBlastDrawer().currentResult?.rid == "STANDIN-ASM" }
        XCTAssertTrue(landed, "the answer did not reach the drawer of the viewer that sent it")
        XCTAssertNil(second.blastDrawerContainer, "the answer reached the assembly now showing")
        XCTAssertFalse(viewer.children.contains { $0 === assembly }, "the answer brought the old viewer back")
    }

    /// The consent sheet and the read of the contigs come before the search starts, so the person can be on another
    /// assembly when the answer is given. The search still reports to the assembly that sent it: its row, its drawer and
    /// its answer. The assembly now showing gets no drawer and no verdict of the other's contigs.
    func testASearchSentJustBeforeMovingToAnotherAssemblyReportsToTheAssemblyThatSentIt() async throws {
        let leaf = try makeStandInLeaf()
        guard useStandIn(leaf.url) else { return }
        defer { unsetenv("LUNGFISH_CLI_PATH") }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try makeResult(of: .spades).item)
        await assertShows(.spades, in: viewer)
        let first = try XCTUnwrap(viewer.assemblyResultController)

        var held: (@MainActor () -> Void)?
        BlastConsentSheet.presenterForTesting = { _, send in held = send }
        first.onBlastVerification?(BlastRequest(taxId: nil, sequences: [Self.contig], readCount: 1, sourceLabel: "contig contig_1"))
        XCTAssertNil(OperationCenter.shared.items.first { $0.title == "BLAST contig contig_1" }, "the search began before the person answered")
        let answer = try XCTUnwrap(held, "the consent sheet was never asked")

        harness.select(try makeResult(of: .megahit).item)
        await assertShows(.megahit, in: viewer)
        let second = try XCTUnwrap(viewer.assemblyResultController)
        XCTAssertFalse(first === second)

        answer()

        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "BLAST contig contig_1" }, "the search began no row")
        defer { OperationCenter.shared.clearItem(id: row.id) }
        XCTAssertEqual(state(of: row.id), .running)
        XCTAssertNotNil(first.blastDrawerContainer, "the search did not open the drawer of the assembly that sent it")
        XCTAssertTrue(first.ensureBlastDrawer().showsASearchInProgress, "the drawer of the assembly that sent it does not show the search")
        XCTAssertNil(second.blastDrawerContainer, "the search reached the assembly now showing")

        try Data().write(to: leaf.release)
        let landed = await waitUntil(budget: .lookup) { first.ensureBlastDrawer().currentResult?.rid == "STANDIN-ASM" }
        XCTAssertTrue(landed, "the answer did not reach the drawer of the assembly that sent it")
        XCTAssertNil(second.blastDrawerContainer, "the answer reached the assembly now showing")
    }

    /// Only NCBI's answer or the person ends a search. The person's Cancel from the Operations panel still does, with
    /// another kind showing.
    func testAPersonsCancelEndsASearchLeftRunning() async throws {
        let leaf = try makeStandInLeaf()
        guard useStandIn(leaf.url) else { return }
        defer { unsetenv("LUNGFISH_CLI_PATH") }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rest = try await buildRow(of: "Status only", under: root)
        harness.select(try makeResult(of: .flye).item)
        await assertShows(.flye, in: viewer)
        let assembly = try XCTUnwrap(viewer.assemblyResultController)
        BlastConsentSheet.presenterForTesting = { _, send in send() }

        assembly.onBlastVerification?(BlastRequest(taxId: nil, sequences: [Self.contig], readCount: 1, sourceLabel: "contig cancelled"))

        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "BLAST contig cancelled" }, "the search began no row")
        defer { OperationCenter.shared.clearItem(id: row.id) }
        let started = await waitUntil(budget: .lookup) { FileManager.default.fileExists(atPath: leaf.started.path) }
        XCTAssertTrue(started, "the stand-in leaf never ran")
        harness.select(rest)
        let left = await waitUntil(budget: .lookup) { viewer.assemblyResultController == nil }
        XCTAssertTrue(left, "the status row left the assembly on screen")
        XCTAssertEqual(state(of: row.id), .running, "moving to another kind ended the search")

        OperationCenter.shared.cancel(id: row.id)

        let cancelled = await waitUntil(budget: .lookup) { self.state(of: row.id) == .cancelled }
        XCTAssertTrue(cancelled, "the person's Cancel did not end the search: \(String(describing: state(of: row.id)))")
    }

    /// A search that cannot start says so on this viewer's drawer. No process starts, as the plan refuses it.
    func testASearchThatCannotBePlannedSaysSoOnThisViewersDrawer() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try makeResult(of: .megahit).item)
        await assertShows(.megahit, in: viewer)
        let assembly = try XCTUnwrap(viewer.assemblyResultController)
        BlastConsentSheet.presenterForTesting = { _, send in send() }

        assembly.onBlastVerification?(BlastRequest(taxId: nil, sequences: [], readCount: 0, sourceLabel: "contig unplanned"))

        XCTAssertNotNil(assembly.blastDrawerContainer, "the refusal did not reach this viewer's drawer")
        XCTAssertTrue(assembly.isBlastDrawerOpen, "the refusal's drawer did not open")
        XCTAssertFalse(OperationCenter.shared.items.contains { $0.title == "BLAST contig unplanned" }, "a search with no plan began a row")
    }

    // MARK: - Every way out

    /// Each kind is shown from the status row twice, once straight and once with the assembly and an open BLAST drawer in
    /// between. The viewer is released, and the chrome is what the kind shows alone.
    func testEveryKindOfTheMatrixTakesTheAssemblyAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rest = try await buildRow(of: "Status only", under: root)
        let assemblyRow = try makeResult(of: .spades).item

        for kind in ViewSwitchKinds.all where kind.name != "Status only" && kind.name != "Assembly" {
            let row = try await buildRow(of: kind.name, under: root)
            harness.select(rest)
            let restedAlone = await settle(harness, on: "Status only")
            XCTAssertTrue(restedAlone, "the status row never opened before \(kind.name)")
            harness.select(row)
            let alone = await settle(harness, on: kind.name)
            XCTAssertTrue(alone, "\(kind.name) never opened from the status row")
            let chromeAlone = AlignmentChrome(viewer)

            harness.select(rest)
            let rested = await settle(harness, on: "Status only")
            XCTAssertTrue(rested, "the status row never opened before the assembly and \(kind.name)")
            harness.select(assemblyRow)
            await assertShows(.spades, in: viewer)
            weak var left = viewer.assemblyResultController
            left?.showBlastFailure("a drawer left open")

            harness.select(row)

            let gone = await waitUntil(budget: .lookup) { viewer.assemblyResultController == nil }
            XCTAssertTrue(gone, "\(kind.name) left the assembly on screen")
            let after = await settle(harness, on: kind.name)
            XCTAssertTrue(after, "\(kind.name) never opened after the assembly")
            XCTAssertFalse(viewer.children.contains { $0 is AssemblyResultViewController }, "\(kind.name) kept the assembly as a child")
            XCTAssertEqual(AlignmentChrome(viewer), chromeAlone, "\(kind.name) shows other chrome after the assembly than alone")
            let released = await waitUntil(budget: .lookup) { left == nil }
            XCTAssertTrue(released, "the assembly outlived \(kind.name), with no search holding it")
        }
    }

    func testASecondAssemblyOfAnotherToolTakesNothingOfTheFirst() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let firstResult = try makeResult(of: .spades)
        harness.select(firstResult.item)
        await assertShows(.spades, in: viewer)
        let first = try XCTUnwrap(viewer.assemblyResultController)
        let filled = await waitUntil(budget: .lookup) { first.testContigTableView.displayedRows.count == 2 }
        XCTAssertTrue(filled, "the first assembly's table never filled")
        try await first.testSelectContig(named: "contig_1")
        first.showBlastFailure("a drawer left open")
        XCTAssertFalse(first.selectedContigNames.isEmpty, "the first assembly holds no selection, so this test proves nothing")

        harness.select(try makeResult(of: .hifiasm).item)

        await assertShows(.hifiasm, in: viewer)
        let second = try XCTUnwrap(viewer.assemblyResultController)
        XCTAssertFalse(first === second, "the first viewer was kept")
        XCTAssertNil(first.view.window, "the first viewer stayed in the window")
        XCTAssertTrue(second.selectedContigNames.isEmpty, "the second assembly took the first one's selection")
        XCTAssertNil(second.blastDrawerContainer, "the second assembly took the first one's drawer")
        XCTAssertEqual(viewer.children.filter { $0 is AssemblyResultViewController }.count, 1)
    }

    func testAProjectSwitchTakesTheAssemblyAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try makeResult(of: .skesa).item)
        await assertShows(.skesa, in: viewer)

        harness.split.resetWindowForProjectChange()

        XCTAssertNil(viewer.assemblyResultController, "a project switch left the assembly on screen")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "a project switch left chrome hidden")
    }

    func testClosingTheWindowLeavesNoAssemblyBehind() async throws {
        let row = try makeResult(of: .flye).item
        weak var weakSplit: MainSplitViewController?
        weak var weakAssembly: AssemblyResultViewController?
        do {
            let harness = try ViewSwitchWindowHarness()
            harness.select(row)
            await assertShows(.flye, in: harness.split.viewerController)
            weakSplit = harness.split
            weakAssembly = harness.split.viewerController.assemblyResultController
            XCTAssertNotNil(weakAssembly)
            // Not `harness.close()`: it clears the viewport through the host, which would remove the assembly even if the
            // window's own close left it behind.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the window's split controller outlived the close")
        let released = await waitUntil(budget: .lookup) { weakAssembly == nil }
        XCTAssertTrue(released, "the assembly outlived the window")
    }

    // MARK: - Support

    private static let contig = ">contig_1 first\nACGTACGTACGTACGTACGT\n"

    /// A result of `tool` saved by the pipeline's own writer, under the name the sidebar's route reads, with a project
    /// around it, so a BLAST plan finds where to save.
    private func makeResult(
        of tool: AssemblyTool, outcome: AssemblyOutcome? = nil
    ) throws -> (folder: URL, result: AssemblyResult, item: SidebarItem) {
        let folder = root.appendingPathComponent("\(UUID().uuidString).lungfish/Analyses/\(tool.rawValue)-2026-01-15T13-30-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contigs = folder.appendingPathComponent("contigs.fasta")
        try ">contig_1 first\nACGTACGTACGTACGTACGT\n>contig_2 second\nGGATCCGGATCC\n".write(to: contigs, atomically: true, encoding: .utf8)
        try FASTAIndexBuilder.buildAndWrite(for: contigs)
        let statistics = outcome == .completedWithNoContigs
            ? AssemblyStatisticsCalculator.computeFromLengths([])
            : try AssemblyStatisticsCalculator.compute(from: contigs)
        let result = AssemblyResult(
            tool: tool, readType: .illuminaShortReads, outcome: outcome ?? .completed, contigsPath: contigs, graphPath: nil, logPath: nil,
            assemblerVersion: "1", commandLine: "\(tool.rawValue) -o \(folder.path)", outputDirectory: folder,
            statistics: statistics, wallTimeSeconds: 1
        )
        try result.save(to: folder)
        return (folder, result, item(folder))
    }

    private func item(_ url: URL) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: .analysisResult, url: url)
    }

    /// Selects `item`, and answers any alert the load raises, since a test has nobody to press its button.
    private func selectHoldingAnyAlert(_ item: SidebarItem, in harness: ViewSwitchWindowHarness) {
        harness.select(item)
        harness.split.viewerController.assemblyResultController?.failurePresenter = { _ in }
    }

    private func assertNothingShows(
        after what: String, in harness: ViewSwitchWindowHarness, file: StaticString = #filePath, line: UInt = #line
    ) {
        let viewer = harness.split.viewerController!
        XCTAssertNil(viewer.assemblyResultController, "\(what) is on screen", file: file, line: line)
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "\(what) left the chrome hidden", file: file, line: line)
        XCTAssertEqual(viewer.contentMode, .empty, "\(what) left the mode", file: file, line: line)
        XCTAssertNil(
            harness.split.inspectorController.viewModel.documentSectionViewModel.assemblyDocument,
            "the Inspector shows an assembly under \(what)", file: file, line: line
        )
    }

    /// Waits until `tool`'s result shows, on its own surface, with its own name on the viewer.
    private func assertShows(
        _ tool: AssemblyTool, in viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line
    ) async {
        await assertSummary("assembly-result-summary-assembler", reads: tool.displayName, in: viewer, file: file, line: line)
        XCTAssertEqual(
            viewer.installedSurface?.surfaceKind, .analysis(AnalysisToolID(rawValue: tool.rawValue)),
            "\(tool.displayName) is not on the surface host", file: file, line: line
        )
    }

    private func assertSummary(
        _ identifier: String, reads expected: String, in viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let read = await waitUntil(budget: .lookup) { self.summary(identifier, in: viewer) == expected }
        XCTAssertTrue(read, "\(identifier) reads \(String(describing: summary(identifier, in: viewer))), not \(expected)", file: file, line: line)
    }

    private func summary(_ identifier: String, in viewer: ViewerViewController) -> String? {
        guard let assembly = viewer.assemblyResultController else { return nil }
        assembly.view.layoutSubtreeIfNeeded()
        return (descendant(in: assembly.testSummaryStrip, identifier) as? NSTextField)?.stringValue
    }

    private func descendant(in root: NSView, _ identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        return root.subviews.lazy.compactMap { self.descendant(in: $0, identifier) }.first
    }

    private func state(of id: UUID) -> OperationCenter.Item.State? {
        OperationCenter.shared.items.first { $0.id == id }?.state
    }

    /// Names the stand-in as the CLI, and says whether the locator now finds it. A test that sends goes on only then, so a
    /// real `blast submit` can never start.
    private func useStandIn(_ url: URL) -> Bool {
        setenv("LUNGFISH_CLI_PATH", url.path, 1)
        let found = CLIBinaryLocator.cliBinaryPath()?.standardizedFileURL.path == url.standardizedFileURL.path
        XCTAssertTrue(found, "the locator does not find the stand-in, so this test sends nothing")
        return found
    }

    /// A shell script in place of `lungfish-cli`. It says it started, holds until the test releases it, then fills the digest
    /// of the query it is handed into a saved record and names the record in its `complete` event.
    private func makeStandInLeaf() throws -> (url: URL, started: URL, release: URL) {
        let folder = root.appendingPathComponent("leaf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = folder.appendingPathComponent("started")
        let release = folder.appendingPathComponent("release")
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let read = try JSONDecoder().decode(BlastReadResult.self, from: Data(
            #"{"hasLCADisagreement":false,"id":"contig_1","matchesQueriedTaxon":false,"querySequence":"ACGT","topHits":[],"verdict":"verified"}"#.utf8
        ))
        let record = BlastSubmissionRecord(
            savedAt: moment,
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: "DIGESTPLACEHOLDER", sequenceCount: 1),
            lineage: .init(),
            search: .init(BlastVerificationRequest(
                taxonName: "contig contig_1", taxId: 0, sequences: [(id: "contig_1", sequence: "ACGTACGTACGTACGTACGT")], database: "core_nt"
            )),
            result: BlastVerificationResult(
                taxonName: "contig contig_1", taxId: 0, totalReads: 1, verifiedCount: 1, ambiguousCount: 0,
                unverifiedCount: 0, errorCount: 0, readResults: [read], submittedAt: moment,
                completedAt: moment, rid: "STANDIN-ASM", blastProgram: "blastn", database: "core_nt"
            )
        )
        let template = folder.appendingPathComponent("record-template.json")
        try BlastSubmissionRecord.encoder.encode(record).write(to: template)
        let output = folder.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        let complete = #"{"event":"complete","message":"rid=STANDIN-ASM","output":"\#(output.path)","outputs":["\#(output.path)"],"progress":1,"schemaVersion":2}"#
        let script = """
        #!/bin/sh
        for argument in "$@"; do
          case "$argument" in */\(BlastSubmissionRecord.queryFileName)) query="$argument" ;; esac
        done
        /usr/bin/touch '\(started.path)'
        while [ ! -f '\(release.path)' ]; do /bin/sleep 0.05; done
        digest=$(/usr/bin/shasum -a 256 "$query" | /usr/bin/cut -d ' ' -f 1)
        /usr/bin/sed "s/DIGESTPLACEHOLDER/$digest/" '\(template.path)' > '\(output.path)'
        /bin/echo '\(complete)'

        """
        let url = folder.appendingPathComponent("lungfish-cli-standin")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, started, release)
    }

    /// Waits until the window shows `name`'s kind: what is installed, whatever mode it sits in.
    private func settle(_ harness: ViewSwitchWindowHarness, on name: String) async -> Bool {
        guard let kind = ViewSwitchKinds.all.first(where: { $0.name == name }),
              let shown = kind.outcome.components(separatedBy: " in ").first else { return false }
        let paths = SafetyNetPathRenderer(root: root)
        return await waitUntil(budget: .lookup) {
            ViewSwitchKinds.outcome(of: RoutingObserver.observe(harness.split, paths: paths, loaded: [])).hasPrefix(shown + " in ")
        }
    }
}

// MSADiscriminatingSitesInspectorTests.swift - Inspector model, viewport highlight, and CLI parity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

private final class DiscriminatingNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[AnyHashable: Any]?] = []

    func record(_ userInfo: [AnyHashable: Any]?) {
        lock.lock(); defer { lock.unlock() }
        storage.append(userInfo)
    }

    var all: [[AnyHashable: Any]?] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private final class DiscriminatingSitesPasteboard: PasteboardWriting {
    private(set) var strings: [String] = []
    func setString(_ string: String) { strings.append(string) }
}

/// Covers the MSA Inspector's Discriminating Sites section: the model that turns
/// row roles and settings into the CLI's request, the notifications that drive the
/// viewport, the viewport's highlight and focus, and a real run on the Primer
/// Design demo project when it is present.
@MainActor
final class MSADiscriminatingSitesInspectorTests: XCTestCase {
    /// One scratch folder per test instance under the repository's test-scratch area.
    private lazy var scratchRoot: URL = {
        let url = repositoryRoot()
            .appendingPathComponent(".build/test-scratch/msa-discriminating-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Model

    private func makeModel(rows: [(String, String)] = [("row-1", "t1"), ("row-2", "t2"), ("row-3", "x1"), ("row-4", "x2")]) -> MSADiscriminatingSitesInspectorModel {
        MSADiscriminatingSitesInspectorModel(
            bundleURL: URL(fileURLWithPath: "/project/panel.lungfishmsa"),
            rows: rows.map { .init(id: $0.0, name: $0.1) },
            projectExclusionOptions: []
        )
    }

    func testEveryRowStartsAsATargetAndRowsModeNeedsAnExclusion() {
        let model = makeModel()
        XCTAssertEqual(model.rows.map(model.role(of:)), [.target, .target, .target, .target])
        XCTAssertEqual(model.validationMessage, "Mark at least one row as an exclusion, or choose exclusion sequences from a file.")
        XCTAssertFalse(model.canRun)

        model.setRole(.exclusion, for: model.rows[2])
        model.setRole(.exclusion, for: model.rows[3])
        XCTAssertNil(model.validationMessage)
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.targetRows.map(\.name), ["t1", "t2"])
        XCTAssertEqual(model.exclusionRows.map(\.name), ["x1", "x2"])
    }

    func testRowsModeRequestOmitsTargetsUntilARowIsSkipped() throws {
        let model = makeModel()
        model.setRole(.exclusion, for: model.rows[2])
        model.setRole(.exclusion, for: model.rows[3])

        var request = try model.makeRequest()
        XCTAssertEqual(request, MSADiscriminatingSitesRequest(
            bundleURL: model.bundleURL, targets: nil, exclusions: "x1,x2",
            targetMismatchTolerance: 0, minimumExclusionDifferences: nil, windowLength: 25))

        model.setRole(.skip, for: model.rows[1])
        model.templateRowID = "row-1"
        model.targetMismatchToleranceText = "0"
        model.windowLengthText = "150"
        model.minimumExclusionDifferencesText = "1"
        request = try model.makeRequest()
        XCTAssertEqual(request.targets, "t1")
        XCTAssertEqual(request.exclusions, "x1,x2")
        XCTAssertNil(request.template, "the first target is the CLI default and is not passed")
        XCTAssertEqual(request.windowLength, 150)
        XCTAssertEqual(request.minimumExclusionDifferences, 1)
    }

    func testTemplateIsPassedOnlyWhenItIsNotTheFirstTarget() throws {
        let model = makeModel()
        model.setRole(.exclusion, for: model.rows[3])
        model.templateRowID = "row-2"
        XCTAssertEqual(try model.makeRequest().template, "t2")

        // Marking the template row as an exclusion drops it back to the default.
        model.setRole(.exclusion, for: model.rows[1])
        XCTAssertNil(model.templateRowID)
        XCTAssertNil(try model.makeRequest().template)
    }

    func testFileModeUsesTheChosenSequencesAndOnlyTargetOrSkipRoles() throws {
        let model = makeModel()
        model.exclusionSource = .file
        XCTAssertEqual(model.validationMessage, "Choose the FASTA file or reference bundle holding the exclusion sequences.")

        let exclusions = URL(fileURLWithPath: "/project/Reference Sequences/exclusion.lungfishref")
        model.exclusionFileURL = exclusions
        model.setRole(.skip, for: model.rows[3])
        let request = try model.makeRequest()
        XCTAssertEqual(request.exclusionSequencesURL, exclusions)
        XCTAssertNil(request.exclusions)
        XCTAssertEqual(request.targets, "t1,t2,x1")

        let argv = CLIMSAActionCommandBuilder.buildDiscriminatingSitesArguments(
            request: request, outputURL: URL(fileURLWithPath: "/out/sites.tsv"))
        XCTAssertEqual(Array(argv.prefix(5)), [
            "msa", "discriminating-sites", model.bundleURL.path, "--targets", "t1,t2,x1",
        ])
        XCTAssertTrue(argv.contains("--exclusion-sequences"))
        XCTAssertFalse(argv.contains("--exclusions"))

        // A row still carrying the Exclusion role from the rows mode is left out of
        // the targets too, so the CLI default cannot sweep it back in.
        let carried = makeModel()
        carried.setRole(.exclusion, for: carried.rows[3])
        carried.exclusionSource = .file
        carried.exclusionFileURL = exclusions
        XCTAssertEqual(try carried.makeRequest().targets, "t1,t2,x1")
        carried.setRole(.target, for: carried.rows[3])
        XCTAssertNil(try carried.makeRequest().targets)
    }

    func testValidationRejectsBadNumbersWithTheControlName() {
        let model = makeModel()
        model.setRole(.exclusion, for: model.rows[3])
        model.targetMismatchToleranceText = "3"
        XCTAssertEqual(model.validationMessage, "Target mismatch tolerance must be smaller than the number of target rows (3).")
        model.targetMismatchToleranceText = "x"
        XCTAssertEqual(model.validationMessage, "Target mismatch tolerance must be a whole number of at least 0.")
        model.targetMismatchToleranceText = "0"
        model.windowLengthText = "0"
        XCTAssertEqual(model.validationMessage, "Window length must be a whole number of at least 1.")
        model.windowLengthText = "25"
        model.minimumExclusionDifferencesText = "0"
        XCTAssertEqual(model.validationMessage, "Exclusions that must differ must be a whole number of at least 1.")
        model.minimumExclusionDifferencesText = " "
        XCTAssertNil(model.validationMessage)
    }

    func testAmbiguousOrCommaBearingNamesFallBackToRowIDs() throws {
        let model = makeModel(rows: [("row-1", "dup"), ("row-2", "dup"), ("row-3", "a,b"), ("row-4", "plain")])
        model.setRole(.exclusion, for: model.rows[2])
        model.setRole(.exclusion, for: model.rows[3])
        model.setRole(.skip, for: model.rows[1])
        let request = try model.makeRequest()
        XCTAssertEqual(request.targets, "row-1")
        XCTAssertEqual(request.exclusions, "row-3,plain")
    }

    func testApplyingAReportFillsSortedTablesHighlightAndCopiesTheCLITSV() throws {
        let model = makeModel()
        model.setRole(.exclusion, for: model.rows[2])
        model.setRole(.exclusion, for: model.rows[3])
        let pasteboard = DiscriminatingSitesPasteboard()
        model.pasteboard = pasteboard
        var highlights: [MSADiscriminatingSitesHighlight?] = []
        model.onHighlightChanged = { highlights.append($0.highlight) }

        let report = try DiscriminatingSitesAnalysis.analyze(
            targets: [.init(name: "t1", sequence: "ACGTACGT"), .init(name: "t2", sequence: "ACGTACGT")],
            exclusions: [.init(name: "x1", sequence: "GCGTGCGT"), .init(name: "x2", sequence: "GCGTGCGT")],
            options: .init(windowLength: 8))
        model.apply(report: report, outputURL: URL(fileURLWithPath: "/out/sites.tsv"))

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.sites.map(\.column), [1, 5])
        XCTAssertEqual(model.sites.map(\.templatePosition), [1, 5])
        XCTAssertEqual(model.sites.map(\.targetBase), ["A", "A"])
        XCTAssertEqual(model.sites.map(\.exclusionDifferenceCount), [2, 2])
        XCTAssertEqual(model.sites.first?.exclusionNames, "x1:G; x2:G")
        XCTAssertEqual(model.windows.map(\.spanText), ["1-5"])
        XCTAssertEqual(model.windows.first?.siteCount, 2)
        XCTAssertEqual(model.summaryLines.first, "Targets: 2 (template t1)")

        model.siteSortOrder = [KeyPathComparator(\.column, order: .reverse)]
        XCTAssertEqual(model.sortedSites.map(\.column), [5, 1])

        XCTAssertTrue(model.copyTSV())
        XCTAssertEqual(pasteboard.strings, [DiscriminatingSitesReportFormatter.siteTSV(for: report)])

        let highlight = try XCTUnwrap(highlights.last ?? nil)
        XCTAssertEqual(highlight.columns, [1, 5])
        XCTAssertEqual(highlight.rowRolesByID, ["row-1": .target, "row-2": .target, "row-3": .exclusion, "row-4": .exclusion])
        XCTAssertEqual(highlight.targetCount, 2)
        XCTAssertEqual(highlight.exclusionCount, 2)
        XCTAssertNil(highlight.exclusionSourceName)
        XCTAssertEqual(highlight.legendText, "Discriminating sites: 2 columns · Target rows 2 · Exclusion rows 2")

        model.highlightsEnabled = false
        XCTAssertNil(model.highlight)
        XCTAssertEqual(highlights.count, 2)
        XCTAssertNil(highlights.last ?? nil)

        // Changing a role invalidates the result and clears the highlight.
        model.highlightsEnabled = true
        model.setRole(.skip, for: model.rows[0])
        XCTAssertEqual(model.status, .idle)
        XCTAssertTrue(model.sites.isEmpty)
        XCTAssertNil(model.report)
        XCTAssertNil(highlights.last ?? nil)
    }

    func testFileExclusionsAreNamedInTheLegendNotAsRows() throws {
        let model = makeModel()
        model.exclusionSource = .file
        model.exclusionFileURL = URL(fileURLWithPath: "/project/Reference Sequences/mamu-class-i-exclusion.lungfishref")
        let report = try DiscriminatingSitesAnalysis.analyze(
            targets: [.init(name: "t1", sequence: "ACGT")],
            exclusions: [.init(name: "e1", sequence: "GCGT"), .init(name: "e2", sequence: "GCGT"), .init(name: "e3", sequence: "GCGT")])
        model.apply(report: report, outputURL: nil)
        let highlight = try XCTUnwrap(model.highlight)
        XCTAssertEqual(highlight.rowRolesByID.values.filter { $0 == .exclusion }.count, 0)
        XCTAssertEqual(highlight.exclusionSourceName, "mamu-class-i-exclusion")
        XCTAssertEqual(highlight.legendText, "Discriminating sites: 1 column · Target rows 1 · Exclusion sequences 3 from mamu-class-i-exclusion")
    }

    func testSelectingASiteRowAsksForAJumpAndReselectingRecentres() {
        let model = makeModel()
        var jumps: [Int] = []
        model.onJumpRequested = { jumps.append($0) }
        model.selectedSiteColumn = 12
        model.jump(toColumn: 12)
        model.jump(toColumn: 40)
        XCTAssertEqual(jumps, [12, 12, 40])
    }

    func testLoadingTheCLIJSONReportMatchesApplyingItDirectly() throws {
        let report = try DiscriminatingSitesAnalysis.analyze(
            targets: [.init(name: "t1", sequence: "ACGTACGT")],
            exclusions: [.init(name: "x1", sequence: "GCGTGCGT")])
        let jsonURL = scratchRoot.appendingPathComponent("sites.json")
        try DiscriminatingSitesReportFormatter.json(for: report).write(to: jsonURL)
        let model = makeModel()
        try model.loadReport(jsonURL: jsonURL, outputURL: scratchRoot.appendingPathComponent("sites.tsv"))
        XCTAssertEqual(model.report, report)
        XCTAssertEqual(model.lastOutputURL?.lastPathComponent, "sites.tsv")
    }

    func testProjectReferenceBundlesAreOfferedAsExclusionSources() throws {
        let project = scratchRoot.appendingPathComponent("Demo.lungfish", isDirectory: true)
        let references = project.appendingPathComponent("Reference Sequences", isDirectory: true)
        try FileManager.default.createDirectory(at: references.appendingPathComponent("zeta.lungfishref"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: references.appendingPathComponent("alpha.lungfishref"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: references.appendingPathComponent("notes.txt.d"), withIntermediateDirectories: true)
        let bundleURL = project.appendingPathComponent("Analyses/Multiple Sequence Alignments/a.lungfishmsa")
        XCTAssertEqual(
            MSADiscriminatingSitesInspectorModel.projectExclusionOptions(near: bundleURL).map(\.name),
            ["alpha", "zeta"])
        XCTAssertTrue(MSADiscriminatingSitesInspectorModel.projectExclusionOptions(near: scratchRoot).isEmpty)
    }

    // MARK: - Inspector wiring and notifications

    func testInspectorBuildsTheModelFromBundleRowsAndBroadcastsHighlightAndFocus() throws {
        let bundleURL = try makeBundle(named: "panel", contents: """
        >t1
        ACGTACGT
        >t2
        ACGTACGT
        >x1
        GCGTGCGT
        """)
        let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        let highlightCapture = DiscriminatingNotificationCapture()
        let focusCapture = DiscriminatingNotificationCapture()
        let highlightObserver = NotificationCenter.default.addObserver(
            forName: .msaDiscriminatingSitesHighlightChanged, object: inspector, queue: nil
        ) { highlightCapture.record($0.userInfo) }
        let focusObserver = NotificationCenter.default.addObserver(
            forName: .msaFocusAlignmentColumnRequested, object: inspector, queue: nil
        ) { focusCapture.record($0.userInfo) }
        defer {
            NotificationCenter.default.removeObserver(highlightObserver)
            NotificationCenter.default.removeObserver(focusObserver)
        }

        inspector.updateMultipleSequenceAlignmentDocument(bundle)
        let model = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.msaDiscriminatingSites)
        XCTAssertEqual(model.bundleURL, bundle.url)
        XCTAssertEqual(model.rows.map(\.name), ["t1", "t2", "x1"])
        XCTAssertEqual(model.rows.map(\.id), bundle.rows.map(\.id))
        XCTAssertNotNil(model.onRunRequested)
        XCTAssertNotNil(model.onExportRequested)
        XCTAssertNotNil(model.onChooseExclusionFileRequested)

        inspector.updateMultipleSequenceAlignmentDocument(bundle)
        XCTAssertTrue(
            inspector.viewModel.documentSectionViewModel.msaDiscriminatingSites === model,
            "refreshing the same bundle keeps the marked roles")

        model.setRole(.exclusion, for: model.rows[2])
        let report = try DiscriminatingSitesAnalysis.analyze(
            targets: [.init(name: "t1", sequence: "ACGTACGT"), .init(name: "t2", sequence: "ACGTACGT")],
            exclusions: [.init(name: "x1", sequence: "GCGTGCGT")])
        model.apply(report: report, outputURL: nil)
        let posted = try XCTUnwrap(highlightCapture.all.last ?? nil)
        let highlight = try XCTUnwrap(posted[NotificationUserInfoKey.msaDiscriminatingSitesHighlight] as? MSADiscriminatingSitesHighlight)
        XCTAssertEqual(highlight.columns, [1, 5])

        model.highlightsEnabled = false
        let cleared = try XCTUnwrap(highlightCapture.all.last ?? nil)
        XCTAssertNil(cleared[NotificationUserInfoKey.msaDiscriminatingSitesHighlight])

        model.jump(toColumn: 5)
        let focus = try XCTUnwrap(focusCapture.all.last ?? nil)
        XCTAssertEqual(focus[NotificationUserInfoKey.msaAlignmentColumn] as? Int, 5)

        inspector.viewModel.documentSectionViewModel.updateMultipleSequenceAlignmentDocument(nil)
        XCTAssertNil(inspector.viewModel.documentSectionViewModel.msaDiscriminatingSites)
    }

    // MARK: - Viewport

    func testViewportTintsColumnsNamesRowRolesAndFocusesAColumn() async throws {
        let bundleURL = try makeBundle(named: "viewport", contents: """
        >t1
        ACGTACGT
        >t2
        ACGTACGT
        >x1
        GCGTGCGT
        """)
        let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        _ = try await controller.displayBundle(at: bundleURL)
        XCTAssertEqual(controller.testingDiscriminatingHighlightedColumns, [])
        XCTAssertNil(controller.testingDiscriminatingLegendText)

        let highlight = MSADiscriminatingSitesHighlight(
            columns: [1, 5],
            rowRolesByID: [bundle.rows[0].id: .target, bundle.rows[1].id: .target, bundle.rows[2].id: .exclusion],
            targetCount: 2, exclusionCount: 1, exclusionSourceName: nil)
        controller.applyDiscriminatingSitesHighlight(highlight)
        XCTAssertEqual(controller.testingDiscriminatingHighlightedColumns, [1, 5])
        XCTAssertEqual(controller.testingDiscriminatingLegendText, highlight.legendText)
        XCTAssertEqual(controller.testingRowRoleLabels, ["Target · t1", "Target · t2", "Exclusion · x1"])

        // A column hidden by the variable-sites filter is shown again when focused.
        controller.testingSetVariableSitesOnly(true)
        XCTAssertEqual(controller.testingDisplayedAlignmentColumnCount, 2)
        controller.focusAlignmentColumn(oneBased: 3)
        XCTAssertEqual(controller.testingDisplayedAlignmentColumnCount, 8)
        // The testing accessors report 1-based columns, as the CLI tables do.
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 3)
        XCTAssertEqual(controller.testingSelectedAlignmentColumnRange, 3...3)
        controller.focusAlignmentColumn(oneBased: 99)
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 3, "an out-of-range column is ignored")

        controller.applyDiscriminatingSitesHighlight(nil)
        XCTAssertEqual(controller.testingDiscriminatingHighlightedColumns, [])
        XCTAssertNil(controller.testingDiscriminatingLegendText)
        XCTAssertEqual(controller.testingRowRoleLabels, ["t1", "t2", "x1"])
    }

    func testViewerForwardsTheInspectorNotificationsToTheAlignmentViewport() async throws {
        let bundleURL = try makeBundle(named: "forwarding", contents: """
        >t1
        ACGTACGT
        >x1
        GCGTGCGT
        """)
        let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        let scope = WindowStateScope()
        viewer.windowStateScope = scope
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        _ = try await controller.displayBundle(at: bundleURL)
        viewer.multipleSequenceAlignmentViewController = controller

        let highlight = MSADiscriminatingSitesHighlight(
            columns: [5], rowRolesByID: [bundle.rows[1].id: .exclusion],
            targetCount: 1, exclusionCount: 1, exclusionSourceName: nil)
        NotificationCenter.default.post(
            name: .msaDiscriminatingSitesHighlightChanged, object: nil,
            userInfo: [
                NotificationUserInfoKey.msaDiscriminatingSitesHighlight: highlight,
                NotificationUserInfoKey.windowStateScope: scope,
            ])
        XCTAssertEqual(controller.testingDiscriminatingHighlightedColumns, [5])

        NotificationCenter.default.post(
            name: .msaFocusAlignmentColumnRequested, object: nil,
            userInfo: [
                NotificationUserInfoKey.msaAlignmentColumn: 5,
                NotificationUserInfoKey.windowStateScope: scope,
            ])
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 5)

        NotificationCenter.default.post(
            name: .msaDiscriminatingSitesHighlightChanged, object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: scope])
        XCTAssertEqual(controller.testingDiscriminatingHighlightedColumns, [])
    }

    // MARK: - Layout

    // Expanding the section in a 1572x900 window with the Inspector showing
    // used to widen the whole Inspector scroll content past its column, so the
    // section's leading text and row names were clipped and its trailing
    // controls ran off the right edge (Preview 2026.9.66).
    func testExpandedSectionFitsTheInspectorColumnAtDefaultAndMinimumWidths() throws {
        let longNames = [
            "LR699574.1_Mamu-A1_001_01_01_01_Macaca_mulatta_genomic_DNA",
            "LR699575.1_Mamu-A1_001_01_02_01_Macaca_mulatta_genomic_DNA",
            "LR699576.1_Mamu-A1_001_02_01_01_Macaca_mulatta_genomic_DNA",
            "LR699577.1_Mamu-A1_001_03_01_01_Macaca_mulatta_genomic_DNA",
        ]
        let exclusionURL = URL(fileURLWithPath: "/project/Reference Sequences/mamu-class-i-exclusion.lungfishref")
        // The Inspector pads its scroll content by 16pt on each side, so the
        // section is offered the column width less 32pt.
        for inspectorWidth in [CGFloat(260), 340] {
            for (source, withResult) in [(MSADiscriminatingSitesInspectorModel.ExclusionSource.rows, false),
                                         (.file, false), (.file, true)] {
                let model = MSADiscriminatingSitesInspectorModel(
                    bundleURL: URL(fileURLWithPath: "/project/mamu-a1-001-lineage.lungfishmsa"),
                    rows: longNames.enumerated().map { .init(id: "row-\($0.offset)", name: $0.element) },
                    projectExclusionOptions: [.init(name: "mamu-class-i-exclusion", url: exclusionURL)]
                )
                model.exclusionSource = source
                if source == .file { model.exclusionFileURL = exclusionURL }
                model.templateRowID = "row-0"
                if withResult {
                    let report = try DiscriminatingSitesAnalysis.analyze(
                        targets: longNames.map { .init(name: $0, sequence: "ACGTACGTACGT") },
                        exclusions: [.init(name: "Mamu-B_exclusion_panel_sequence_01", sequence: "GCGTGCGTGCGT")])
                    model.apply(report: report, outputURL: URL(fileURLWithPath:
                        "/Users/example/Documents/Primer Design.lungfish/Analyses/Discriminating Sites/mamu-a1-001-lineage-discriminating-sites.tsv"))
                }

                let offered = inspectorWidth - 32
                let controller = NSHostingController(rootView: MSADiscriminatingSitesSection(
                    model: model, isExpanded: .constant(true)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: offered, height: 900),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentViewController = controller
                controller.view.layoutSubtreeIfNeeded()

                let fitted = controller.sizeThatFits(in: CGSize(width: offered, height: 10_000))
                XCTAssertLessThanOrEqual(
                    fitted.width, offered + 0.5,
                    "Discriminating Sites (\(source.rawValue), result \(withResult)) must fit a \(Int(inspectorWidth))pt Inspector")
            }
        }
    }

    // MARK: - Real run on the demo project

    /// Reproduces the manual's eleven columns by running the CLI in-process with the
    /// exact argv the Inspector builds for the demo lineage alignment and its
    /// exclusion reference bundle. Skipped when the demo project or the managed
    /// MAFFT is not on this machine.
    func testDemoProjectRunThroughTheInspectorArgvFindsElevenColumns() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectURL = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_DESIGN_DEMO_PROJECT"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Desktop/lge-docs/Primer Design.lungfish", isDirectory: true)
        let bundleURL = projectURL
            .appendingPathComponent("Analyses/Multiple Sequence Alignments/mamu-a1-001-lineage.lungfishmsa", isDirectory: true)
        let exclusionsURL = projectURL
            .appendingPathComponent("Reference Sequences/mamu-class-i-exclusion.lungfishref", isDirectory: true)
        let mafft = home.appendingPathComponent(".lungfish/conda/envs/mafft/bin/mafft")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundleURL.path), "Primer Design demo project not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: exclusionsURL.path), "exclusion reference bundle not present")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: mafft.path), "managed MAFFT not installed")

        let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let model = MSADiscriminatingSitesInspectorModel(
            bundleURL: bundle.url,
            rows: bundle.rows.map { .init(id: $0.id, name: $0.displayName) })
        XCTAssertEqual(model.projectExclusionOptions.map(\.name).sorted(), ["mamu-a1-001-lineage", "mamu-a1-panel", "mamu-class-i-exclusion"])
        model.exclusionSource = .file
        model.exclusionFileURL = try XCTUnwrap(model.projectExclusionOptions.first { $0.name == "mamu-class-i-exclusion" }).url

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lge-discriminating-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mamu-a1-001-lineage-discriminating-sites.tsv")
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let argv = CLIMSAActionCommandBuilder.buildDiscriminatingSitesArguments(
            request: try model.makeRequest(), outputURL: outputURL)
        XCTAssertEqual(argv, [
            "msa", "discriminating-sites", bundle.url.path,
            "--exclusion-sequences", exclusionsURL.standardizedFileURL.path,
            "--target-mismatch-tolerance", "0",
            "--window-length", "25",
            "--output", outputURL.path,
            "--force", "--format", "json",
        ])

        let command = try MSACommand.DiscriminatingSitesSubcommand.parse(Array(argv.dropFirst(2)))
        var lines: [String] = []
        try command.executeForTesting { lines.append($0) }
        XCTAssertTrue(lines.contains { $0.contains("\"complete\"") || $0.contains("complete") }, lines.joined(separator: "\n"))

        try model.loadReport(
            jsonURL: MSADiscriminatingSitesRequest.defaultJSONOutputURL(for: outputURL), outputURL: outputURL)
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.sites.count, 11)
        XCTAssertEqual(
            model.sites.map(\.templatePosition),
            [220, 679, 911, 990, 1008, 1057, 1851, 1860, 1907, 2633, 2876])
        XCTAssertEqual(model.sites.map(\.targetBase).joined(), "AACAAAAATTG")
        XCTAssertEqual(model.report?.targetNames.count, 4)
        XCTAssertEqual(model.report?.exclusionNames.count, 18)
        XCTAssertEqual(model.windows.map(\.spanText), ["990-1008", "1851-1860"])
        XCTAssertEqual(model.highlight?.columns.count, 11)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.appendingPathExtension("lungfish-provenance.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MSADiscriminatingSitesRequest.defaultWindowsOutputURL(for: outputURL).path))
    }

    // MARK: - Bundle tab (lane D, 2026-10-05)

    // The section lives on the Bundle tab. Opening an alignment auto-selects its
    // first cell, and jumping to a site selects that column, and both used to
    // flip the Inspector to Selected Item, so the section was never on screen
    // when the alignment opened and its tables vanished the moment a row was
    // clicked. A real click in the alignment still switches tabs.

    func testOpeningAnAlignmentKeepsTheBundleTabButAUserSelectionStillSwitches() async throws {
        let (bundle, viewport, inspector) = try await makeWiredInspector(named: "open-tab")
        // The order MainSplitViewController.displayMultipleSequenceAlignmentBundleFromSidebar uses.
        inspector.updateMultipleSequenceAlignmentDocument(bundle)
        viewport.onSelectionStateChanged = { inspector.updateMultipleSequenceAlignmentSelection($0) }
        viewport.notifySelectionStateIfAvailable()
        XCTAssertEqual(inspector.viewModel.selectedTab, .bundle, "the automatic first-cell selection keeps the Bundle tab")

        viewport.notifySelectionStateIfAvailable()
        XCTAssertEqual(inspector.viewModel.selectedTab, .selectedItem, "a later selection change still shows Selected Item")
    }

    func testJumpingToASiteKeepsTheBundleTab() async throws {
        let (bundle, viewport, inspector) = try await makeWiredInspector(named: "jump-tab")
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        let scope = WindowStateScope()
        viewer.windowStateScope = scope
        inspector.windowStateScope = scope
        viewer.multipleSequenceAlignmentViewController = viewport
        inspector.updateMultipleSequenceAlignmentDocument(bundle)
        viewport.onSelectionStateChanged = { inspector.updateMultipleSequenceAlignmentSelection($0) }
        viewport.notifySelectionStateIfAvailable()
        inspector.viewModel.selectedTab = .bundle
        let model = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.msaDiscriminatingSites)

        model.jump(toColumn: 5)
        XCTAssertEqual(viewport.testingSelectedAlignmentColumn, 5, "the jump reached the viewport")
        XCTAssertEqual(inspector.viewModel.selectedTab, .bundle, "a site jump keeps the section on screen")

        model.jump(toColumn: 99)
        viewport.notifySelectionStateIfAvailable()
        XCTAssertEqual(inspector.viewModel.selectedTab, .selectedItem, "an ignored jump leaves no hold behind")
    }

    func testSectionStaysExpandedAcrossATabSwitch() async throws {
        let (bundle, _, inspector) = try await makeWiredInspector(named: "expanded-tab")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 1400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = inspector.view
        inspector.updateMultipleSequenceAlignmentDocument(bundle)
        inspector.viewModel.selectedTab = .bundle
        let model = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.msaDiscriminatingSites)
        XCTAssertFalse(model.isExpanded)
        model.isExpanded = true
        let expanded = await showsRoleMenus(bundle.rows.count, in: inspector.view)
        XCTAssertTrue(expanded, "the expanded section shows one role menu per row")

        inspector.viewModel.selectedTab = .selectedItem
        let hidden = await showsRoleMenus(0, in: inspector.view)
        XCTAssertTrue(hidden, "the Selected Item tab removes the section")
        inspector.viewModel.selectedTab = .bundle
        let restored = await showsRoleMenus(bundle.rows.count, in: inspector.view)
        XCTAssertTrue(restored, "returning to Bundle finds the section still open")
    }

    private func makeWiredInspector(
        named name: String
    ) async throws -> (MultipleSequenceAlignmentBundle, MultipleSequenceAlignmentViewController, InspectorViewController) {
        let bundleURL = try makeBundle(named: name, contents: """
        >t1
        ACGTACGT
        >t2
        ACGTACGT
        >x1
        GCGTGCGT
        """)
        let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let viewport = MultipleSequenceAlignmentViewController()
        _ = viewport.view
        _ = try await viewport.displayBundle(at: bundleURL)
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        return (bundle, viewport, inspector)
    }

    /// Waits until the rendered Inspector shows exactly `count` per-row role menus.
    private func showsRoleMenus(_ count: Int, in view: NSView) async -> Bool {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return await waitUntil(timeout: .seconds(5)) {
            view.layoutSubtreeIfNeeded()
            return all(view).compactMap { $0 as? NSPopUpButton }
                .filter { $0.itemTitles == ["Target", "Exclusion", "Skip"] }
                .count == count
        }
    }

    // MARK: - Helpers

    private func makeBundle(named name: String, contents: String) throws -> URL {
        let sourceURL = scratchRoot.appendingPathComponent("\(name).fasta")
        try contents.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = scratchRoot.appendingPathComponent("\(name).lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL, options: .init(name: name))
        return bundleURL
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

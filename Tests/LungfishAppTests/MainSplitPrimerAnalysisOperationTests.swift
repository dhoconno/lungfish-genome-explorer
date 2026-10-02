// MainSplitPrimerAnalysisOperationTests.swift - begin() sites in MainSplitViewController+PrimerAnalysis
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The saved primer analysis viewport registers two export rows through static
// begin helpers (R4). Both lock the new export folder, so a held lock must
// refuse the row and launch nothing. The primer order export has a
// lungfish-cli equivalent, `primers analysis export-order`, and its recorded
// command must parse with the run's values. The primer FASTA and reference
// amplicon exports have none yet, and a PrimalScheme order from a filtered
// view has none either. Their tests pin the missing command and fail when one
// is added. The provenance argv of every export is the row's command as words,
// or for an export with no command an argv that names the app (R3, R8).

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class MainSplitPrimerAnalysisOperationTests: XCTestCase {
    private let analysisURL = URL(
        fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Analyses/Saved design.lungfishprimeranalysis",
        isDirectory: true
    )
    private let destinationURL = URL(
        fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Analyses/Primer order-1A2B3C4D",
        isDirectory: true
    )
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    /// A fresh center whose lock on the export folder is already held, as when
    /// another operation is running on the project's Analyses folder.
    private func centerHoldingDestinationLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Mapping reads",
            detail: "Running",
            operationType: .mapping,
            targetBundleURL: destinationURL,
            cliCommand: "lungfish-cli map"
        ).startedID)
        return center
    }

    private func makeDraft(
        selectedAssayIDs: [String]? = nil,
        includesAllReportedAssays: Bool? = nil,
        primer3CandidatePairs: Bool? = nil,
        settings: PrimerAnalysisDisplaySettings = .init()
    ) -> PrimerOrderDraft {
        let artifact = PrimerAnalysisArtifact(
            relativePath: "provenance.json",
            role: "provenance",
            format: "json",
            sha256: String(repeating: "0", count: 64),
            byteSize: 0
        )
        let manifest = PrimerAnalysisManifest(
            analysisID: UUID(),
            runID: UUID(),
            inputs: [],
            results: [],
            artifacts: [],
            provenance: artifact,
            grouping: .independent,
            publishedRootPath: analysisURL.path
        )
        let selection = PrimerOrderSelection(
            capturedAt: Date(timeIntervalSince1970: 100),
            analysisURL: analysisURL,
            manifest: manifest,
            settings: settings,
            compatibilityReady: false,
            compatibilitySummaries: [:],
            selectedPrimerIDs: [],
            selectedAssayIDs: selectedAssayIDs,
            includesAllReportedAssays: includesAllReportedAssays,
            primer3CandidatePairs: primer3CandidatePairs
        )
        return PrimerOrderDraft(selection: selection, oligos: [], defaultName: "Saved design order")
    }

    private func orderMetadata() -> PrimerOrderMetadata {
        PrimerOrderMetadata(
            name: "Spring panel order",
            requestedBy: "Pat Lee",
            project: "Panel 7",
            orderReference: "PO 1234",
            notes: "Rush it, it's for Monday"
        )
    }

    /// Registers the order row on a recording reporter and returns what it recorded.
    private func recordedOrder(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata? = nil
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?
        MainSplitViewController.beginPrimerOrderExportOperation(
            title: "Export Displayed Primer Order",
            detail: "Verifying 12 displayed oligos…",
            draft: draft,
            metadata: metadata ?? orderMetadata(),
            destinationURL: destinationURL,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Export Displayed Primer Order")
        XCTAssertEqual(item.initialDetail, "Verifying 12 displayed oligos…")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, destinationURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        return item
    }

    // MARK: - Primer order export

    func testPrimerOrderExportRefusedByAHeldLockLaunchesNothing() throws {
        let center = try centerHoldingDestinationLock()
        var launched = false

        let result = MainSplitViewController.beginPrimerOrderExportOperation(
            title: "Export Displayed Primer Order",
            detail: "Verifying 12 displayed oligos…",
            draft: makeDraft(),
            metadata: orderMetadata(),
            destinationURL: destinationURL,
            routeContext: routeContext,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held lock on the export folder must refuse the order row")
        }
        XCTAssertFalse(launched, "a refused row must start no export")
        XCTAssertEqual(refusal.blockingOperationTitle, "Mapping reads")
    }

    func testPrimer3OrderRecordsACommandNamingTheCandidatePairs() throws {
        let firstPair = UUID().uuidString
        let secondPair = UUID().uuidString
        let item = try recordedOrder(draft: makeDraft(
            selectedAssayIDs: [firstPair, secondPair],
            primer3CandidatePairs: true
        ))

        let command = try RecordedCLICommand.parse(item.cliCommand, as: PrimerAnalysisExportOrderCommand.self)
        XCTAssertEqual(command.bundlePath, analysisURL.path)
        XCTAssertEqual(command.outputPath, destinationURL.path)
        XCTAssertEqual(command.scope, .candidatePairs)
        XCTAssertEqual(command.candidatePairIDs, [firstPair, secondPair])
        XCTAssertEqual(command.name, "Spring panel order")
        XCTAssertEqual(command.requestedBy, "Pat Lee")
        XCTAssertEqual(command.project, "Panel 7")
        XCTAssertEqual(command.orderReference, "PO 1234")
        XCTAssertEqual(command.notes, "Rush it, it's for Monday")
    }

    func testOlivarOrExactVarVAMPOrdersRecordTheirAssayScope() throws {
        let assays = [UUID().uuidString.lowercased()]

        let selected = try recordedOrder(draft: makeDraft(selectedAssayIDs: assays, includesAllReportedAssays: false))
        let selectedCommand = try RecordedCLICommand.parse(selected.cliCommand, as: PrimerAnalysisExportOrderCommand.self)
        XCTAssertEqual(selectedCommand.scope, .selectedAssays)
        XCTAssertEqual(selectedCommand.candidatePairIDs, [])

        let reported = try recordedOrder(draft: makeDraft(selectedAssayIDs: assays, includesAllReportedAssays: true))
        let reportedCommand = try RecordedCLICommand.parse(reported.cliCommand, as: PrimerAnalysisExportOrderCommand.self)
        XCTAssertEqual(reportedCommand.scope, .allReportedAssays)
        XCTAssertEqual(reportedCommand.candidatePairIDs, [])
    }

    func testPrimalSchemeOrderFromTheDefaultViewRecordsTheDisplayedScopeAndOmitsEmptyFields() throws {
        let item = try recordedOrder(
            draft: makeDraft(),
            metadata: PrimerOrderMetadata(name: "Spring panel order")
        )

        let command = try RecordedCLICommand.parse(item.cliCommand, as: PrimerAnalysisExportOrderCommand.self)
        XCTAssertEqual(command.scope, .displayed)
        XCTAssertEqual(command.name, "Spring panel order")
        XCTAssertEqual(command.requestedBy, "")
        XCTAssertEqual(command.project, "")
        XCTAssertEqual(command.orderReference, "")
        XCTAssertEqual(command.notes, "")
        XCTAssertFalse(try XCTUnwrap(item.cliCommand).contains("--requested-by"), "empty fields are left to the CLI defaults")
    }

    func testPrimalSchemeOrderFromAFilteredViewRecordsNoCommandAsAParityGap() throws {
        let filteredViews: [PrimerAnalysisDisplaySettings] = [
            PrimerAnalysisDisplaySettings(hiddenPrimerIDs: ["primer-3"]),
            PrimerAnalysisDisplaySettings(hiddenPoolIDs: ["result::pool::2"]),
            PrimerAnalysisDisplaySettings(showForward: false),
            PrimerAnalysisDisplaySettings(showReverse: false),
            PrimerAnalysisDisplaySettings(filterByCompatibility: true, minimumCompatibilityPercent: 90),
        ]
        for settings in filteredViews {
            let item = try recordedOrder(draft: makeDraft(settings: settings))
            // CLI parity gap. `primers analysis export-order --scope displayed`
            // captures the default view and has no option for these filters,
            // so no command reproduces the order. When the CLI can express a
            // filtered view, record the command and replace this pin with a
            // parse test.
            XCTAssertNil(item.cliCommand)
            XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
        }
    }

    func testAssayAndCandidateOrdersRecordTheCommandWhateverTheViewSettings() throws {
        let hidden = PrimerAnalysisDisplaySettings(hiddenPrimerIDs: ["primer-3"], showForward: false)

        let primer3 = try recordedOrder(draft: makeDraft(
            selectedAssayIDs: [UUID().uuidString],
            primer3CandidatePairs: true,
            settings: hidden
        ))
        XCTAssertNotNil(primer3.cliCommand, "view filters never change which candidate pairs an order names")

        let assays = try recordedOrder(draft: makeDraft(
            selectedAssayIDs: [UUID().uuidString.lowercased()],
            includesAllReportedAssays: false,
            settings: hidden
        ))
        XCTAssertNotNil(assays.cliCommand, "view filters never change which assays an order names")
    }

    // MARK: - Primer FASTA and reference amplicon exports, CLI parity gaps

    func testPrimerSelectionExportRefusedByAHeldLockLaunchesNothing() throws {
        let center = try centerHoldingDestinationLock()
        var launched = false

        let result = MainSplitViewController.beginPrimerAnalysisSelectionExportOperation(
            title: "Save Primer FASTA Bundle",
            destinationURL: destinationURL,
            routeContext: routeContext,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held lock on the export folder must refuse the selection export row")
        }
        XCTAssertFalse(launched, "a refused row must start no export")
        XCTAssertEqual(refusal.blockingOperationTitle, "Mapping reads")
    }

    func testPrimerSelectionExportsRecordTheirTypeAndLockAndNoCommandAsAParityGap() throws {
        for title in ["Save Primer FASTA Bundle", "Extract Reference Amplicon"] {
            let reporter = RecordingOperationReporter()
            var launchedID: UUID?

            MainSplitViewController.beginPrimerAnalysisSelectionExportOperation(
                title: title,
                destinationURL: destinationURL,
                routeContext: routeContext,
                reporter: reporter
            ) { launchedID = $0 }

            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertEqual(launchedID, item.id)
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.initialDetail, "Verifying saved primer analysis…")
            XCTAssertEqual(item.operationType, .workflow)
            XCTAssertEqual(item.targetBundleURL, destinationURL)
            XCTAssertEqual(item.additionalLockedBundleURLs, [])
            XCTAssertEqual(item.routeContext, routeContext)
            // CLI parity gap. No lungfish-cli command exports a primer FASTA
            // bundle or a reference amplicon for a selected primer, amplicon
            // or pool. The closest is `primers analysis annotated-reference`,
            // which covers a whole Primer3 result. When a selection export
            // command exists, record it and replace this pin with a parse test.
            XCTAssertNil(item.cliCommand)
            XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
        }
    }

    // MARK: - Provenance argv (R3, R8)

    func testOrderProvenanceArgvIsTheExportOrderCommandTheRowRecords() throws {
        // The export used to record the app process's own launch arguments.
        let drafts = [
            makeDraft(selectedAssayIDs: [UUID().uuidString, UUID().uuidString], primer3CandidatePairs: true),
            makeDraft(selectedAssayIDs: [UUID().uuidString.lowercased()], includesAllReportedAssays: false),
            makeDraft(selectedAssayIDs: [UUID().uuidString.lowercased()], includesAllReportedAssays: true),
            makeDraft(),
        ]
        for draft in drafts {
            let item = try recordedOrder(draft: draft)
            let argv = MainSplitViewController.primerOrderExportProvenanceArgv(
                draft: draft, metadata: orderMetadata(), destinationURL: destinationURL
            )
            XCTAssertEqual(argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: item.cliCommand)))
            XCTAssertEqual(Array(argv.prefix(4)), [CLICommandIdentity.executableName, "primers", "analysis", "export-order"])
        }
    }

    func testFilteredPrimalSchemeOrderProvenanceArgvNamesTheAppAndTheFilteredView() throws {
        let draft = makeDraft(settings: PrimerAnalysisDisplaySettings(hiddenPrimerIDs: ["primer-3"]))

        let argv = MainSplitViewController.primerOrderExportProvenanceArgv(
            draft: draft, metadata: orderMetadata(), destinationURL: destinationURL
        )

        XCTAssertEqual(argv, [
            "Lungfish.app", "export-primer-order", analysisURL.path, "--output", destinationURL.path,
            "--scope", "displayed", "--view", "filtered", "--name", "Spring panel order",
            "--requested-by", "Pat Lee", "--project", "Panel 7", "--order-reference", "PO 1234",
            "--notes", "Rush it, it's for Monday",
        ])
        XCTAssertThrowsError(
            try RecordedCLICommand.parse(argv.map(shellEscape).joined(separator: " ")),
            "no lungfish-cli command reproduces a filtered view, so the argv names the app"
        )
    }

    func testSelectionExportProvenanceArgvNamesTheAppTheKindAndTheSelection() throws {
        let cases: [(PrimerAnalysisExportSelection, PrimerAnalysisExportKind, [String])] = [
            (.primer(targetID: "target-1", primerID: "primer-3"), .primerFASTA,
             ["--target-id", "target-1", "--primer-id", "primer-3"]),
            (.amplicon(targetID: "target-1", ampliconID: "amplicon-2"), .referenceAmplicon,
             ["--target-id", "target-1", "--amplicon-id", "amplicon-2"]),
            (.pool(sourceResultID: "result-1", pool: 2), .primerFASTA,
             ["--source-result-id", "result-1", "--pool", "2"]),
            (.nativePool(sourceResultID: "result-1", pool: "B"), .primerFASTA,
             ["--source-result-id", "result-1", "--native-pool", "B"]),
        ]
        for (selection, kind, selectionArguments) in cases {
            let argv = MainSplitViewController.primerSelectionExportProvenanceArgv(
                analysisURL: analysisURL, selection: selection, kind: kind, destinationURL: destinationURL
            )
            XCTAssertEqual(
                argv,
                ["Lungfish.app", "export-primer-selection", analysisURL.path, "--kind", kind.rawValue]
                    + selectionArguments + ["--output", destinationURL.path]
            )
        }
    }
}

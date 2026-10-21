// PrimerOrderExportProvenanceParityTests.swift - A GUI primer order records the export-order command it runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The primer analysis viewport exports an order through PrimerOrderExportService
// and records `lungfish-cli primers analysis export-order` in the Operations
// panel. Its provenance used to record the app process's own launch arguments
// (R3, R8). These tests run the GUI path and the recorded command on one saved
// Primer3 analysis and compare the orders and the provenance argv.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class PrimerOrderExportProvenanceParityTests: XCTestCase {
    func testGUIOrderRecordsTheRowCommandAsArgvAndTheCommandWritesTheSameOrder() async throws {
        let fixture = try makePrimer3Fixture(pairCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let pairIDs = snapshot.designReview.filter { $0.presentation == .primer3Template }.map(\.id)
        let selection = try PrimerOrderExportService.captureSelection(
            snapshot: snapshot,
            scope: .primer3CandidatePairs(includedPairIDs: [try XCTUnwrap(pairIDs.last)])
        )
        let draft = PrimerOrderDraft(
            selection: selection,
            oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
            defaultName: "fixture candidate pairs order"
        )
        let metadata = PrimerOrderMetadata(name: "Pair order", requestedBy: "Bench", notes: "Rush")

        // The GUI path, with the argv the viewport now passes.
        let guiDestination = fixture.root.appendingPathComponent("GUI order")
        let guiArgv = MainSplitViewController.primerOrderExportProvenanceArgv(
            draft: draft, metadata: metadata, destinationURL: guiDestination
        )
        // The app builds the row and the argv before the export, while the folder does not exist. A standardized path
        // drops a leading `/private` only for a path that exists, so the row is built before the export here too.
        let guiRow = try XCTUnwrap(MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: guiDestination
        ))
        let guiOutput = try await PrimerOrderExportService().export(
            selection: draft.selection, metadata: metadata, destinationURL: guiDestination, invocationArgv: guiArgv
        )
        let gui = try PrimerOrderExportService.loadSnapshot(from: guiOutput)
        XCTAssertEqual(
            gui.provenance.argv,
            [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: guiRow)),
            "the provenance names the export-order command the Operations row records"
        )
        XCTAssertNotEqual(gui.provenance.argv, CommandLine.arguments)

        // The same command, recorded for a second folder, run through the real CLI.
        let cliDestination = fixture.root.appendingPathComponent("CLI order")
        let cliRow = try XCTUnwrap(MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: cliDestination
        ))
        let command = try RecordedCLICommand.parse(cliRow, as: PrimerAnalysisExportOrderCommand.self)
        try await command.run()
        let cli = try PrimerOrderExportService.loadSnapshot(from: cliDestination)

        XCTAssertEqual(cli.document.oligos, gui.document.oligos)
        XCTAssertEqual(cli.document.metadata, gui.document.metadata)
        XCTAssertEqual(cli.document.selection.selectedAssayIDs, gui.document.selection.selectedAssayIDs)
        XCTAssertEqual(
            cli.provenance.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: cliRow)),
            "the row, the record and the leaf print one argv")
        XCTAssertEqual(cli.provenance.workflowName, gui.provenance.workflowName)
    }

    /// Fix 4 of the 13.43-M3 review (UX 4, ARCH 2, BIO 3). Before M3 the app wrote the order in its own process, so an
    /// order name or note that starts with a hyphen, such as `-80 C freezer`, worked. The row now runs these words, and
    /// ArgumentParser refuses a next token that reads as an option, so every free-text field joins its option with `=`.
    /// The order's invocation, the app's row for the same draft and the leaf that runs that row read the five fields
    /// back as typed, and the leaf records them.
    func testAnOrderFieldThatStartsWithAHyphenReadsBackFromTheRecordedCommand() async throws {
        let fixture = try makePrimer3Fixture(pairCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let pairID = try XCTUnwrap(
            snapshot.designReview.filter { $0.presentation == .primer3Template }.map(\.id).last)
        let selection = try PrimerOrderExportService.captureSelection(
            snapshot: snapshot, scope: .primer3CandidatePairs(includedPairIDs: [pairID]))
        let draft = PrimerOrderDraft(
            selection: selection,
            oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
            defaultName: "fixture candidate pairs order")
        let metadata = PrimerOrderMetadata(
            name: "-Pair order", requestedBy: "-Bench", project: "-Study", orderReference: "-PO 7",
            notes: "-80 C freezer")

        // The invocation, and the row the begin helper records for it, one field at a time so a failure names the
        // field. At the base all six values fail to parse from the recorded command. The parser reads a token that
        // starts with a hyphen as an option and reports a missing value, and a short option letter such as the t of
        // -t makes -Study an unknown composite option. The = form makes each one a value.
        let fields: [(option: String, metadata: PrimerOrderMetadata, read: (PrimerAnalysisExportOrderCommand) -> String?)] = [
            ("--name", PrimerOrderMetadata(name: "-Pair order"), { $0.name }),
            ("--requested-by", PrimerOrderMetadata(requestedBy: "-Bench"), { $0.requestedBy }),
            ("--project", PrimerOrderMetadata(project: "-Study"), { $0.project }),
            ("--order-reference", PrimerOrderMetadata(orderReference: "-PO 7"), { $0.orderReference }),
            ("--notes", PrimerOrderMetadata(notes: "-80 C freezer"), { $0.notes }),
            ("--notes", PrimerOrderMetadata(notes: "-80 C freezer, tube 2"), { $0.notes }),
        ]
        for field in fields {
            let invocation = PrimerOrderExport.invocation(
                analysisURL: fixture.bundle, selection: selection, metadata: field.metadata,
                outputURL: fixture.root.appendingPathComponent("Invocation order"))
            let invocationRow = OperationCenter.buildCLICommand(
                subcommand: "primers analysis export-order", args: Array(invocation.arguments().dropFirst(3)))
            let expected = [
                field.metadata.name, field.metadata.requestedBy, field.metadata.project,
                field.metadata.orderReference, field.metadata.notes,
            ].first { $0.hasPrefix("-") }
            do {
                let parsed = try RecordedCLICommand.parse(invocationRow, as: PrimerAnalysisExportOrderCommand.self)
                XCTAssertEqual(field.read(parsed), expected, "\(field.option) reads back as typed")
            } catch {
                XCTFail("\(field.option) \(expected ?? "") does not parse from the recorded command: \(error)")
            }
        }

        // The app's row for the draft, then the leaf runs that row and records the same words.
        let destination = fixture.root.appendingPathComponent("Hyphen order")
        let appRow = MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: destination)
        let command = try RecordedCLICommand.parse(appRow, as: PrimerAnalysisExportOrderCommand.self)
        XCTAssertEqual(command.name, "-Pair order")
        XCTAssertEqual(command.notes, "-80 C freezer")
        try await command.run()
        let written = try PrimerOrderExportService.loadSnapshot(from: destination)
        XCTAssertEqual(written.document.metadata, metadata, "the leaf recorded the five fields as typed")
        XCTAssertEqual(
            written.provenance.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: appRow)),
            "the row, the record and the leaf print one argv")
    }

    /// Fix 4 of the 13.43-fix review (QA 1 and 2). Masks M-1 to M-4 had run only on the synthetic text of
    /// `RouteParityHarnessTests`, and a parity class run falls inside one second, so no capture time differed in it.
    /// Two exports of one order, run a second apart, hold different capture times in `order.json`, in the workbook cell
    /// and in the zip entries, and they compare equal under the standard masks. With the order masks taken out, the same
    /// two folders differ, which shows that the masks have something to hide.
    func testTwoOrdersASecondApartCompareEqualUnderTheStandardMasks() async throws {
        let fixture = try makePrimer3Fixture(pairCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let pairID = try XCTUnwrap(
            snapshot.designReview.filter { $0.presentation == .primer3Template }.map(\.id).last)
        let selection = try PrimerOrderExportService.captureSelection(
            snapshot: snapshot, scope: .primer3CandidatePairs(includedPairIDs: [pairID]))
        let draft = PrimerOrderDraft(
            selection: selection,
            oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
            defaultName: "fixture candidate pairs order")
        let metadata = PrimerOrderMetadata(name: "Pair order", requestedBy: "Bench", notes: "Rush")

        // The app's row for two folders. The first leaf runs, more than a second passes, then the second leaf runs.
        let first = fixture.root.appendingPathComponent("first")
        let second = fixture.root.appendingPathComponent("second")
        let firstRow = MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: first)
        let secondRow = MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: second)
        try await RecordedCLICommand.parse(firstRow, as: PrimerAnalysisExportOrderCommand.self).run()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await RecordedCLICommand.parse(secondRow, as: PrimerAnalysisExportOrderCommand.self).run()

        let firstOrder = try PrimerOrderExportService.loadSnapshot(from: first)
        let secondOrder = try PrimerOrderExportService.loadSnapshot(from: second)
        XCTAssertGreaterThanOrEqual(
            secondOrder.document.selection.capturedAt.timeIntervalSince(firstOrder.document.selection.capturedAt), 1,
            "the second export captured its selection a second after the first")

        XCTAssertEqual(
            try OutputEquivalence.compare(first, second, kind: .bundle, masks: .standard).differences, [],
            "M-1 to M-4 hide the clock of the two exports and nothing else")

        let orderMasks: Set<String> = ["primerOrderCaptureClocks", "primerOrderRecordDigests"]
        var withoutOrderMasks = OutputEquivalence.MaskPolicy.standard
        withoutOrderMasks.records.removeAll { orderMasks.contains($0.name) }
        withoutOrderMasks.provenance.removeAll { orderMasks.contains($0.name) }
        withoutOrderMasks.payloads.removeAll { orderMasks.contains($0.name) }
        let unmasked = try OutputEquivalence.compare(first, second, kind: .bundle, masks: withoutOrderMasks).differences
        for file in ["order.json", "workbook-parts/", ".lungfish-provenance.json"] {
            XCTAssertTrue(
                unmasked.contains { $0.hasPrefix("differs: \(file)") },
                "without M-1, M-2 and M-4 the two exports differ in \(file)")
        }
    }

    /// Pins at the base of lane 13.43 (QA 1), before PRIMER-EXPORT-RUN changes the route. The order export as it is
    /// today: the row the begin helper registers with its recorded command, the files the in-process writer and the
    /// leaf write, and the record each leaves (its tool, its argv and the keys of its resolved options). The
    /// continuation compares its converted route with these facts, and a difference there is a prediction row.
    func testTheOrderExportAsItIsTodayRowFilesAndRecord() async throws {
        let fixture = try makePrimer3Fixture(pairCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let pairID = try XCTUnwrap(
            snapshot.designReview.filter { $0.presentation == .primer3Template }.map(\.id).last)
        let selection = try PrimerOrderExportService.captureSelection(
            snapshot: snapshot, scope: .primer3CandidatePairs(includedPairIDs: [pairID]))
        let draft = PrimerOrderDraft(
            selection: selection,
            oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
            defaultName: "fixture candidate pairs order")
        let metadata = PrimerOrderMetadata(name: "Pair order", requestedBy: "Bench", notes: "Rush")
        let appFolder = fixture.root.appendingPathComponent("App order")

        // The row. The title and the detail are words of the private caller, so the helper's own parts are pinned.
        let reporter = RecordingOperationReporter()
        let route = OperationRouteContext(projectURL: fixture.root, windowStateScopeID: UUID())
        let begun = try XCTUnwrap(MainSplitViewController.beginPrimerOrderExportOperation(
            title: "Export Candidate Pairs", detail: "Verifying 2 candidate oligos…",
            invocation: MainSplitViewController.primerOrderExportInvocation(
                draft: draft, metadata: metadata, destinationURL: appFolder),
            routeContext: route, runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter) {})
        _ = await begun.task.value
        let row = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(row.title, "Export Candidate Pairs")
        XCTAssertEqual(row.initialDetail, "Verifying 2 candidate oligos…")
        XCTAssertEqual(row.operationType, .workflow)
        XCTAssertEqual(row.targetBundleURL?.path, appFolder.standardizedFileURL.path)
        XCTAssertEqual(row.additionalLockedBundleURLs, [])
        let words = try RecordedCLICommand.arguments(of: row.cliCommand)
        // The command is built by ViewerExportInvocation (lane 13.43 M3), so `--output` comes after the leaf's own words
        // and `--format json` ends it, with standardized absolute paths.
        XCTAssertEqual(words, [
            "primers", "analysis", "export-order", fixture.bundle.standardizedFileURL.path, "--scope",
            "candidate-pairs", "--candidate-pair-id", pairID, "--name=Pair order", "--requested-by=Bench",
            "--notes=Rush", "--output", appFolder.standardizedFileURL.path, "--format", "json",
        ])
        let appArgv = MainSplitViewController.primerOrderExportProvenanceArgv(
            draft: draft, metadata: metadata, destinationURL: appFolder)
        XCTAssertEqual(appArgv, [CLICommandIdentity.executableName] + words)

        // The files and the record of the in-process writer and of the leaf the recorded command names.
        _ = try await PrimerOrderExportService().export(
            selection: draft.selection, metadata: metadata, destinationURL: appFolder, invocationArgv: appArgv)
        let leafFolder = fixture.root.appendingPathComponent("Leaf order")
        let leafRow = MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: leafFolder)
        try await RecordedCLICommand.parse(leafRow, as: PrimerAnalysisExportOrderCommand.self).run()
        let facts = try ["app": appFolder, "leaf": leafFolder].mapValues { folder -> [String: String] in
            let loaded = try PrimerOrderExportService.loadSnapshot(from: folder)
            let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let csv = try String(contentsOf: folder.appendingPathComponent("ordering.csv"), encoding: .utf8)
            return [
                "entries": entries.joined(separator: ","),
                "csvHeader": csv.components(separatedBy: "\n").first ?? "",
                "csvRows": String(csv.split(whereSeparator: \.isNewline).count),
                "workflowName": loaded.provenance.workflowName,
                "tool": "\(loaded.provenance.tool.name)|\(loaded.provenance.tool.kind ?? "none")",
                "resolvedKeys": loaded.provenance.options.resolvedDefaults.keys.sorted().joined(separator: ","),
            ]
        }
        XCTAssertEqual(facts["app"], facts["leaf"], "the leaf writes what the in-process writer writes")
        let columns = [
            "Pool name", "Oligo name", "Sequence (5′–3′)", "Length (nt)", "Scheme", "Pool number", "Primer ID", "Target ID",
            "Source result ID", "Reference ID", "Amplicon IDs (JSON)", "Start (1-based inclusive)",
            "End (1-based inclusive)", "Strand", "Compatible rows", "Assessable rows", "Unassessed rows",
            "Total alignment rows", "Observed MSA compatibility (%)", "Order name", "Requested by", "Project",
            "Order reference", "Order notes", "Source oligo ID", "Oligo role", "Candidate status", "Assay IDs (JSON)",
            "Native pool", "Synthesis scale", "Purification", "Modifications",
        ]
        XCTAssertEqual(facts["app"], [
            "workflowName": "Export Primer3 candidate pairs",
            "tool": "LGE primer ordering|cli",
            "csvHeader": columns.map { "\"\($0)\"" }.joined(separator: ",") + "\r",
            "csvRows": "3",
            "entries": ".lungfish-provenance.json,analysis-metadata.json,order.json,ordering.csv,primer-order.xlsx,"
                + "source-analysis,template-parts,template.xlsx,workbook-parts",
            "resolvedKeys": "candidatePairsAreAlternatives,compatibilityReady,deduplicate,displaySettingsJSON,"
                + "idtOPoolsWorkbook,orderMetadataJSON,publication,scope,selectedCandidatePairIDs,selectedCount,"
                + "selectedPrimerIDs,selectionDocument,sequenceOrientation,sourceAnalysisID,sourceManifestSHA256,"
                + "sourceNormalizedResult,sourceRunID,templateSHA256",
        ], "the facts of today's order export")
        let appRecord = try PrimerOrderExportService.loadSnapshot(from: appFolder).provenance
        XCTAssertEqual(appRecord.argv, appArgv)
        let leafRecord = try PrimerOrderExportService.loadSnapshot(from: leafFolder).provenance
        XCTAssertEqual(
            leafRecord.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: leafRow)),
            "the leaf records the canonical argv of the command it ran, which is the row's")
    }

    /// A saved Primer3 analysis with `pairCount` candidate pairs, the fixture
    /// PrimerAnalysisExportOrderCommandTests writes.
    private func makePrimer3Fixture(pairCount: Int) throws -> (root: URL, bundle: URL) {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
        let template = "ACGTACGT"
        let input = root.appendingPathComponent("input.fasta")
        try Data(">\(inputID.uuidString)\n\(template)\n".utf8).write(to: input)
        let native = root.appendingPathComponent("native.txt")
        try Data("Synthetic Primer3 fixture, not an engine execution.\n".utf8).write(to: native)
        func oligo(start: Int, end: Int, orientation: String, sequence: String) -> [String: Any] {
            ["id": UUID().uuidString, "start": start, "end": end, "orientation": orientation,
             "sequence": sequence, "meltingTemperature": 60.0, "gcPercent": 50.0]
        }
        let pairs: [[String: Any]] = (0..<pairCount).map { index in
            ["id": UUID().uuidString, "productSize": 8 - index,
             "left": oligo(start: 0, end: 2, orientation: "forward", sequence: "AC"),
             "right": oligo(start: 6 - index, end: 8 - index, orientation: "reverse", sequence: index == 0 ? "AC" : "GT")]
        }
        let result: [String: Any] = [
            "resultID": resultID.uuidString, "inputID": inputID.uuidString,
            "title": "Synthetic display fixture", "sourceKind": "fasta",
            "sourceIndex": 0, "sourceRecordID": "synthetic-display-fixture",
            "templateSequence": template, "excludedRegions": [], "pairs": pairs,
            "explanation": "Synthetic candidate fixture.",
        ]
        let document: [String: Any] = ["schemaVersion": 1, "analysisID": analysisID.uuidString,
            "runID": runID.uuidString, "results": [result]]
        let normalized = root.appendingPathComponent("normalized.json")
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: normalized)
        let path = "results/primer3-normalized-v1.json"
        let artifacts: [PrimerAnalysisSourceArtifact] = [
            .init(sourceURL: input, relativePath: "inputs/\(inputID.uuidString).fasta", role: "input", format: "fasta"),
            .init(sourceURL: native, relativePath: "native/output.txt", role: "nativeOutput", format: "text"),
            .init(sourceURL: normalized, relativePath: path, role: "normalized", format: "json"),
        ]
        let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
            analysisID: analysisID, runID: runID, grouping: .independent,
            inputs: [.init(id: inputID, label: "Fixture", artifactPaths: ["inputs/\(inputID.uuidString).fasta"])],
            results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])],
            artifacts: artifacts, destinationURL: root.appendingPathComponent("fixture.lungfishprimeranalysis"),
            invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        let physicalBundle = try XCTUnwrap(realpath(bundle.url.path, nil))
        defer { free(physicalBundle) }
        return (root, URL(fileURLWithPath: String(cString: physicalBundle)))
    }
}

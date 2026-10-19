// AnnotationTableExportCLIGUIParityReplayTests.swift - The annotation table export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39 (B2), ARCH ruling on the export shape 1.7, ARCH ruling on 12.39 R1, R3 and R4, on lane Q30's
// harness. Each case runs one tab in one format on three sides that start as copies of one root holding a reference
// bundle with an annotation database of a gene and a transcript and a variant database of three variants and two
// samples (`VariantEditFixture`).
//
// - Every side first collects the rows as the drawer's `collect` closure does, with the drawer's All Matching
//   queries (`AnnotationTableAnnotationQueryRequest`, `AnnotationTableVariantQueryRequest`) and the drawer's genotype
//   and sample rows, and names the inputs with `AnnotationTableExportSources`.
// - Side A is `AnnotationTableExportService.export` and the retained-selection helper it called, frozen in this
//   file as it stood at 9d5378e3e (the retained folder, the payload, one `writeAtomically` with the `/bin/cp`
//   replay), since the lane deletes them.
// - Side C is `AnnotationTableDrawerView.annotationTableExportInvocation` and `beginAnnotationTableExportOperation`,
//   which write the selection file, begin the row and run the built `lungfish-cli bundle export-annotation-table` on
//   `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with the selection file copied into its
//   root.
//
// A against C compares the payload and its digest and size, the record's inputs with their digests outside the
// retained folder, `defaults` and every `resolved` key the leaf writes. The identity fields, the old argv's
// `explicit` keys, `replayScope`, `replaysUpstreamAnalysis` and the retained inputs are prediction rows of the lane
// report (BIO 7), pinned by `assertPredictedRecordChanges`. Nothing is declared, so the old writer goes with no key
// (R-A1, C4).
//
// R4. An XLSX archive stores the entry times of the moment it was written under a fresh temporary name, so for xlsx
// the output's digest and size are replaced by `assertXLSXEntriesEqual` (every entry name and every entry's bytes),
// and `xlsxArchiveArgv` is a masked run-varying key in both compares. `testXLSXArchiveArgvIsTheOnlyRunVaryingKey`
// shows it is the only one.
//
// Every case root sits four folders below the scratch folder, so no record's sidecar lookup lists the user temporary
// folder (12.31 M4). The cancel runs through the real transport, as the GFF3 class runs it (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class AnnotationTableExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class AnnotationTableExportCLIGUIParityReplayTests: XCTestCase {
    struct Case: Hashable, Sendable, CustomStringConvertible {
        let tab: AnnotationTableExport.Tab
        let format: ScientificTableFormat
        /// Runs the case on the second bundle (`makeDerivedFixture`), which holds a genome, coding features and an
        /// iVar track.
        var derived = false
        /// With `derived`, the plain track is not hidden, so its rows are exported with the iVar track's.
        var showsPlainTrack = false
        var description: String {
            "\(tab.rawValue)-\(format.rawValue)" + (derived ? "-derived" : "") + (showsPlainTrack ? "-both" : "")
        }
    }

    /// The rows the drawer collected and the state it froze at the click.
    struct Collected {
        let snapshot: AnnotationTableExportSnapshot
        let table: AnnotationTableExportSelection
        var editedValues: [String: [String: String]] = [:]
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let bundleName = "fixture.lungfishref"
    static let trackID = VariantEditFixture.trackID

    var scratch: URL!
    var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "annotation-table-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// A case root four folders below the scratch folder (12.31 M4).
    func deepRoot(_ name: String) -> URL {
        scratch.appendingPathComponent("levels/deep/run/\(name)", isDirectory: true)
    }

    func testAnnotationsTabMatchesInEveryFormat() async throws {
        for format in ScientificTableFormat.allCases {
            try await assertParity(Case(tab: .annotations, format: format))
        }
    }

    func testVariantsTabMatchesInEveryFormat() async throws {
        for format in ScientificTableFormat.allCases {
            try await assertParity(Case(tab: .variants, format: format))
        }
    }

    func testGenotypesTabMatchesInEveryFormat() async throws {
        for format in ScientificTableFormat.allCases {
            try await assertParity(Case(tab: .genotypes, format: format))
        }
    }

    func testSamplesTabMatchesInEveryFormat() async throws {
        let runs = try await assertParity(Case(tab: .samples, format: .tsv))
        let text = try String(contentsOf: Self.outputURL(in: runs.c.root, .tsv), encoding: .utf8)
        XCTAssertTrue(text.contains("Animal A"), "the display name travels in editedValues\n\(text)")
        for format in ScientificTableFormat.allCases where format != .tsv {
            try await assertParity(Case(tab: .samples, format: format))
        }
    }

    /// The review of 12.39 B2, Fix 4 (BIO 1 and BIO 7). The second bundle (`makeDerivedFixture`) holds a genome of 120
    /// bases, a forward CDS of two blocks, a reverse CDS and two variant tracks, `ivar` with its FORMAT overlay VCF and
    /// `plain`. Side A shows the coding feature, consequence and amino-acid change columns and the projected INFO
    /// columns from coding bases that `explicitCodingContext` reads from the genome and from the overlay that
    /// `VariantFormatOverlaySource.iVarSources` loads, so A shares neither with the leaf's `codingContext(for:)`. The
    /// plain track is hidden in the first variants case, so the variants and genotypes records name only the tracks
    /// their rows came from, and the samples record names both.
    func testDerivedColumnsAndOverlayMatch() async throws {
        let ivarOnly = try await assertParity(Case(tab: .variants, format: .csv, derived: true))
        let both = try await assertParity(Case(tab: .variants, format: .csv, derived: true, showsPlainTrack: true))
        try await assertParity(Case(tab: .genotypes, format: .csv, derived: true))
        try await assertParity(Case(tab: .annotations, format: .tsv, derived: true))
        try await assertParity(Case(tab: .samples, format: .tsv, derived: true))

        typealias Table = (text: String, rows: [[String]])
        func cells(_ runs: RouteParityRuns) throws -> Table {
            let text = try String(contentsOf: Self.outputURL(in: runs.c.root, .csv), encoding: .utf8)
            XCTAssertFalse(text.contains("Zoom in"), "no cell holds the drawer's placeholder\n\(text)")
            return (text, text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) })
        }
        // Columns: ID, Chrom, Position, Ref, Alt, Quality, Filter, Samples, AF, DP, ALT_FREQ, ALT_QUAL, Track,
        // Caller Settings, then the three derived columns last.
        func fields(_ ref: String, _ alt: String, _ table: Table) throws -> [String] {
            try XCTUnwrap(
                table.rows.first { $0.count > 16 && $0[3] == ref && $0[4] == alt },
                "the row \(ref)>\(alt) is in the table\n\(table.text)"
            )
        }
        func derived(_ row: [String]) -> [String] { Array(row.suffix(3)) }

        let table = try cells(ivarOnly)
        let missense = try fields("G", "C", table)
        XCTAssertTrue(derived(missense)[0].contains("cdsF"), "\(missense)")
        XCTAssertTrue(derived(missense)[1].hasSuffix(": missense_variant W12S"), "\(missense)")
        XCTAssertEqual(derived(missense)[2], "W12S", "a missense change in the second block of the forward CDS")
        let synonymous = try fields("T", "C", table)
        XCTAssertTrue(derived(synonymous)[1].hasSuffix(": synonymous_variant G7G"), "\(synonymous)")
        XCTAssertEqual(derived(synonymous)[2], "G7G", "a synonymous change in the first block")
        let reverse = try fields("C", "T", table)
        XCTAssertTrue(derived(reverse)[0].contains("cdsR"), "\(reverse)")
        XCTAssertTrue(derived(reverse)[1].hasSuffix(": missense_variant G3D"), "\(reverse)")
        XCTAssertEqual(derived(reverse)[2], "G3D", "a missense change in the reverse CDS")
        let indel = try fields("AA", "A", table)
        XCTAssertTrue(derived(indel)[1].hasSuffix(": frameshift_variant"), "\(indel)")
        XCTAssertEqual(derived(indel)[2], "", "an indel has no amino-acid change")
        XCTAssertEqual(derived(try fields("C", "G", table)), ["", "", ""], "a variant inside no CDS has empty derived cells")
        XCTAssertEqual([missense[9], synonymous[9], reverse[9], indel[9]], ["120", "200", "80", "50"], "the projected DP")
        for row in [missense, synonymous, reverse, indel] {
            XCTAssertFalse(row[8].isEmpty || row[10].isEmpty || row[11].isEmpty, "the projected AF, ALT_FREQ and ALT_QUAL, \(row)")
        }
        XCTAssertNil(table.rows.first { $0.count > 4 && $0[3] == "T" && $0[4] == "A" }, "the hidden plain track's row is not exported")

        let plain = try fields("T", "A", try cells(both))
        XCTAssertEqual(derived(plain), ["", "", ""], "the plain track's row lies in no CDS")
        XCTAssertEqual(plain[8], "", "the iVar overlay does not reach the plain track's row")
        XCTAssertEqual(plain[9], "9", "the plain track's own INFO DP")
    }

    /// R3. `--output-format json --format json` writes the JSON bytes of the drawer's builder and the row reads the
    /// leaf's events, so the two flags stay independent.
    func testAnnotationTableLeafWritesJSONWithEventsOn() async throws {
        let root = deepRoot("json-events")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root, .json)
        let collected = try Self.collect(.annotations, in: root)
        let run = try await runC(root, collected, format: .json, output: output)
        XCTAssertTrue(run.completed, "the runner read the leaf's events to the end, it ended \(run.detail)")
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(run.command))
        XCTAssertEqual(Array(arguments.suffix(2)), ["--format", "json"])
        let flag = try XCTUnwrap(arguments.firstIndex(of: "--output-format"))
        XCTAssertEqual(arguments[flag + 1], "json")
        let reference = root.appendingPathComponent("reference.json")
        _ = try ScientificTableWriter.writeWithReport(collected.snapshot.table, format: .json, to: reference, shouldCancel: { false })
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: reference))
    }

    /// R4 item 3. Two runs of side C to two outputs differ in no `resolved` key but `xlsxArchiveArgv`, and the two
    /// argvs differ only at index 3, the archive path.
    func testXLSXArchiveArgvIsTheOnlyRunVaryingKey() async throws {
        let root = deepRoot("xlsx-twice")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        var resolved: [[String: ParameterValue]] = []
        for name in ["first.xlsx", "second.xlsx"] {
            let output = root.appendingPathComponent(name)
            let run = try await runC(root, try Self.collect(.variants, in: root), format: .xlsx, output: output)
            XCTAssertTrue(run.completed, run.detail)
            resolved.append(try Self.envelope(of: output).options.resolvedDefaults)
        }
        XCTAssertEqual(resolved[0].filter { $0.key != "xlsxArchiveArgv" }, resolved[1].filter { $0.key != "xlsxArchiveArgv" })
        guard case .array(let first)? = resolved[0]["xlsxArchiveArgv"], case .array(let second)? = resolved[1]["xlsxArchiveArgv"] else {
            return XCTFail("an xlsx record names its archive argv")
        }
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(zip(first, second).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset), [3])
    }

    /// ARCH ruling on 12.39 R1 item 6 (the review of 12.39 B2, Fix 2). A selection whose feature count differs from
    /// the coding features the bundle gives is a failure, and the leaf says so in the ruling's words and writes
    /// nothing. The selection is written directly, since `annotationTableExportInvocation` replaces its `query` with
    /// the snapshot's description. The class fixture holds no coding feature, so the selection's count of 1 differs.
    func testADifferingCodingFeatureCountFailsWithTheRulingsWords() async throws {
        let root = deepRoot("feature-count")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root, .csv)
        let collected = try Self.collect(.variants, in: root)
        var table = collected.table
        table.codingFeatureRegion = AnnotationTableFeatureRegion(chromosome: "", start: 0, end: 0, trackIDs: [])
        table.query = ["derivedVariantFeatureCount": "1"]
        let selection = try ViewerExportSelection(identities: collected.snapshot.rowIdentities, annotationTable: table)
            .write(besideOutput: output)
        let invocation = AnnotationTableExport.invocation(
            bundleURL: Self.bundleURL(in: root), tab: .variants, format: .csv,
            selectionURL: selection, outputURL: output, force: true
        )
        let run = await RouteParityHarness.runCLI(harness.cliBinary, arguments: invocation.arguments(), timeout: .seconds(60))
        XCTAssertEqual(run.status, 64, "a failure exits 64, \(run.detail)")
        XCTAssertTrue(
            (run.stdout + run.stderr).contains("The coding features read from the bundle do not match the ones the table showed."),
            "the ruling's words, \(run.stdout) \(run.stderr)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused export leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), "and no record")
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record. The case root sits five folders below the temporary folder.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = scratch.appendingPathComponent("cancel/case/run/root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root, .tsv)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let collected = try Self.collect(.annotations, in: root)
        let invocation = try AnnotationTableDrawerView.annotationTableExportInvocation(
            snapshot: collected.snapshot, bundleURL: Self.bundleURL(in: root), tableSelection: collected.table,
            editedValues: collected.editedValues, format: .tsv, outputURL: output
        )

        let failures = AnnotationTableExportFailureCalls()
        let begun = try XCTUnwrap(AnnotationTableDrawerView.beginAnnotationTableExportOperation(
            invocation: invocation,
            rowCount: collected.snapshot.table.rows.count,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}

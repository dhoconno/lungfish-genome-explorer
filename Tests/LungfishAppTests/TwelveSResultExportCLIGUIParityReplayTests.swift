// TwelveSResultExportCLIGUIParityReplayTests.swift - The 12S viewer's result export before and after its row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B3, ARCH ruling on the export shape 1.7, on lane Q30's harness. Each case runs on three
// sides that start as copies of one `.lungfish12s` bundle, written once outside the case folder and copied in.
//
// - Side A is the export the view ran before its row, `TwelveSAmpliconResultExportService.export` after the side A
//   fix (`--force` only on Replace, ARCH 1.2), frozen in this file since the lane deletes it. It ran the same leaf
//   through `LungfishCLIRunner` with no row.
// - Side C is the view's run helper, `runResultExport`, given the same frozen filters. It begins the row and runs the
//   built `lungfish-cli fastq 12s-export` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares the report byte for byte and every fact of the record but its times, with each side's root
// read as one token: tool, workflow, argv, every file with its role and digest, and every option. Both sides run one
// leaf, so no record field moves, nothing is declared, and the old path goes in the lane with no key (R-A1, C4).
//
// Each case root sits five folders below the temporary folder, since a record's sidecar search lists each input's
// folder and four above it (SCR/lanes/12.31/12.31-cancel.md).
//
// The cancel runs through the real transport. The leaf holds before it writes on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`,
// the row's Cancel stops it, and neither the report nor its record is left (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishTwelveSUI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class TwelveSExportParityFailureCalls {
    var messages: [String] = []
}

@MainActor
final class TwelveSResultExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case csvWithEveryFilter
        case tsvUnfiltered
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let bundleRelativePath = "Project/Analyses/hilo.lungfish12s"

    private var scratch: URL!
    private var fixtureBundle: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "twelve-s-export-parity")
        fixtureBundle = scratch.appendingPathComponent("fixture/hilo.lungfish12s", isDirectory: true)
        try Self.writeBundle(at: fixtureBundle)
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

    /// Every filter the view holds, which keeps the dog row and drops the human row. The Excel-only filters are
    /// recorded as the view held them.
    func testCSVWithEveryFilterMatches() async throws {
        let runs = try await assertParity(.csvWithEveryFilter)
        let report = try String(contentsOf: Self.outputURL(in: runs.c.root, case: .csvWithEveryFilter), encoding: .utf8)
        XCTAssertTrue(report.contains("Canis lupus familiaris"), report)
        XCTAssertFalse(report.contains("Homo sapiens"), report)
    }

    /// The view as it opens, with no filter, so both rows are written.
    func testTSVUnfilteredMatches() async throws {
        let runs = try await assertParity(.tsvUnfiltered)
        let report = try String(contentsOf: Self.outputURL(in: runs.c.root, case: .tsvUnfiltered), encoding: .utf8)
        XCTAssertTrue(report.contains("Homo sapiens") && report.contains("Canis lupus familiaris"), report)
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf before it writes, the row reads Cancelled with no
    /// alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the report or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = Self.caseFolder(in: scratch).appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFixture(root)
        let output = Self.outputURL(in: root, case: .csvWithEveryFilter)
        let sidecar = Self.sidecarURL(for: output)
        let hold = root.appendingPathComponent("held")

        let failures = TwelveSExportParityFailureCalls()
        let begun = try XCTUnwrap(TwelveSAmpliconResultViewController.runResultExport(
            snapshot: Self.snapshot(.csvWithEveryFilter, in: root),
            format: .csv,
            outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its hold")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no report")
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no report")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}

// MARK: - The fixture

extension TwelveSResultExportCLIGUIParityReplayTests {
    /// The folder the case roots sit in, five folders below the temporary folder.
    static func caseFolder(in scratch: URL) -> URL {
        scratch.appendingPathComponent("cases/of/the/twelve-s", isDirectory: true)
    }

    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent(bundleRelativePath, isDirectory: true)
    }

    static func format(of parityCase: Case) -> TwelveSAmpliconResultExportFormat {
        parityCase == .csvWithEveryFilter ? .csv : .tsv
    }

    /// The report each side writes, in its root.
    static func outputURL(in root: URL, case parityCase: Case) -> URL {
        root.appendingPathComponent("hilo-12s.\(format(of: parityCase).fileExtension)")
    }

    static func sidecarURL(for output: URL) -> URL {
        output.appendingPathExtension("lungfish-provenance.json")
    }

    static func envelope(for output: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL(for: output)))
    }

    /// The filters the view froze when the export began, as `exportSnapshot` holds them.
    static func snapshot(_ parityCase: Case, in root: URL) -> TwelveSAmpliconResultExportSnapshot {
        let filters = parityCase == .tsvUnfiltered ? TwelveSResultDisplayState() : TwelveSResultDisplayState(
            minimumExactReads: 4,
            filterText: " canis ",
            includedTaxonGroups: ["Mammal"],
            excludedTaxonGroups: ["Bird"],
            excludeHuman: true,
            requireAlternateMatches: true,
            minimumUnresolvedReads: 5,
            chimeraFilter: .candidate
        )
        return TwelveSAmpliconResultExportSnapshot(
            bundleURL: bundleURL(in: root),
            analysisName: "hilo",
            sampleNames: ["SampleA"],
            filters: filters,
            rows: [],
            unresolvedRows: []
        )
    }

    /// The bundle written once in setUp, copied into the root.
    func makeFixture(_ root: URL) throws {
        let bundle = Self.bundleURL(in: root)
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureBundle, to: bundle)
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A two-target, one-sample 12S result, the bundle of `TwelveSResultExportWorkflowTests.makeBundle`.
    static func writeBundle(at bundleURL: URL) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try TwelveSAmpliconResultBundle.writeManifest(TwelveSAmpliconResultBundleManifest(
            outputName: "hilo",
            analysisName: "hilo",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            alternateMatchesTablePath: "target-alternate-matches.tsv",
            unresolvedTablePath: "unresolved-sequences.tsv",
            unresolvedFastaPath: "unresolved-sequences.fasta",
            provenancePath: ".lungfish-provenance.json"
        ), to: bundleURL)
        let mammal = "Mammal\troot; Eukaryota; Mammalia"
        let files = [
            "reference.fa": ">ref\nACGT\n",
            ".lungfish-provenance.json": "{}",
            "targets.tsv": """
            target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header
            human\thuman (Homo sapiens)\tHomo sapiens\thuman\t9606\t\(mammal)\tncbi_common\t12S\t107\t2\t1\t12S_vert\thuman (Homo sapiens)
            dog\tdog (Canis lupus familiaris)\tCanis lupus familiaris\tdog\t9615\t\(mammal)\tncbi_common\t12S\t101\t4\t1\t12S_vert\tdog (Canis lupus familiaris)
            """,
            "target-alternate-matches.tsv": """
            target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason
            dog\twolf (Canis lupus)\tCanis lupus\twolf\t9612\t\(mammal)\tncbi_common\tshared_exact_amplicon
            """,
            "sample-target-counts.tsv": "target_id\tSampleA\nhuman\t3\ndog\t5",
            "samples.tsv": """
            sample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent
            SampleA\tSample A\t30\t8\t22\t0\t8\t26.666667\t73.333333
            """,
            "read-fate.json": """
            {"totalReads":30,"exactMatchReads":8,"unresolvedReads":22,"ambiguousExactReads":0,"chimeraCandidateReads":8}
            """,
            "unresolved-sequences.tsv": """
            sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote
            unresolved_1\tACGTACGT\t12\tSampleA:12\tnot_detected\t
            unresolved_2\tTTTTCCCC\t8\tSampleA:8\tcandidate\t
            """,
            "unresolved-sequences.fasta": ">unresolved_1\nACGTACGT\n",
        ]
        for (name, text) in files {
            try text.write(to: bundleURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - The sides

extension TwelveSResultExportCLIGUIParityReplayTests {
    /// Side A. The export the view's Export 12S Results ran before its row, frozen below.
    private func sideA(_ root: URL, case parityCase: Case) async -> RouteParitySideOutcome {
        do {
            try await Self.frozenServiceExport(
                snapshot: Self.snapshot(parityCase, in: root),
                format: Self.format(of: parityCase),
                to: Self.outputURL(in: root, case: parityCase),
                cli: harness.cliBinary
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported the 12S report")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `TwelveSAmpliconResultExportService.export` as the view ran it after the side A fix, with `LungfishCLIRunner`
    /// given the built CLI where the app found the one beside itself, and its record check.
    private static func frozenServiceExport(
        snapshot: TwelveSAmpliconResultExportSnapshot,
        format: TwelveSAmpliconResultExportFormat,
        to outputURL: URL,
        cli: URL
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let standardizedOutputURL = outputURL.standardizedFileURL
        let provenanceURL = standardizedOutputURL.appendingPathExtension("lungfish-provenance.json")
        var arguments = [
            "fastq", "12s-export",
            "--bundle", snapshot.bundleURL.path,
            "--export-format", format.cliValue,
            "--output", standardizedOutputURL.path,
        ]
        let filters = snapshot.filters
        if filters.minimumExactReads > 0 {
            arguments += ["--min-exact-reads", String(filters.minimumExactReads)]
        }
        if !filters.normalizedFilterText.isEmpty {
            arguments += ["--filter", filters.normalizedFilterText]
        }
        for group in filters.includedTaxonGroups.sorted() {
            arguments += ["--taxon-group", group]
        }
        for group in filters.excludedTaxonGroups.sorted() {
            arguments += ["--exclude-taxon-group", group]
        }
        if filters.excludeHuman {
            arguments.append("--exclude-human")
        }
        if filters.requireAlternateMatches {
            arguments.append("--require-alternate-matches")
        }
        if filters.minimumUnresolvedReads > 0 {
            arguments += ["--min-unresolved-reads", String(filters.minimumUnresolvedReads)]
        }
        if filters.chimeraFilter != .all {
            arguments += ["--chimera-status", filters.chimeraFilter.rawValue]
        }
        if fileManager.fileExists(atPath: standardizedOutputURL.path) {
            arguments.append("--force")
        }
        do {
            _ = try await LungfishCLIRunner.run(arguments: arguments, executableURL: cli)
            guard fileManager.fileExists(atPath: standardizedOutputURL.path),
                  let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL),
                  envelope.toolName == CLICommandIdentity.executableName,
                  envelope.workflowName == "lungfish fastq 12s-export",
                  envelope.exitStatus == 0,
                  !envelope.argv.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch {
            try? fileManager.removeItem(at: standardizedOutputURL)
            try? fileManager.removeItem(at: provenanceURL)
            throw error
        }
    }

    /// Side C. The view's run helper, which runs the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, case parityCase: Case) async -> RouteParitySideOutcome {
        let failures = TwelveSExportParityFailureCalls()
        guard let begun = TwelveSAmpliconResultViewController.runResultExport(
            snapshot: Self.snapshot(parityCase, in: root),
            format: Self.format(of: parityCase),
            outputURL: Self.outputURL(in: root, case: parityCase),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(failures.messages, [])
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }
}

// MARK: - The comparison

extension TwelveSResultExportCLIGUIParityReplayTests {
    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on every fact but the record's times,
    /// and the record's argv is the row's command.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: Self.caseFolder(in: scratch).appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try self.makeFixture(root) },
            sideA: { root in await self.sideA(root, case: parityCase) },
            sideC: { root in await self.sideC(root, case: parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "side \(side) names no other side's root")
        }
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "C against C' declares nothing")
        try assertAEqualsC(runs, case: parityCase)
        try assertTheRecordNamesTheRowsCommand(runs, case: parityCase)
        return runs
    }

    /// A against C with each path read relative to its side root. No file but the record differs, and the record
    /// is equal on everything but its times, since both sides ran one leaf.
    private func assertAEqualsC(_ runs: RouteParityRuns, case parityCase: Case) throws {
        let outputA = Self.outputURL(in: runs.a.root, case: parityCase)
        let outputC = Self.outputURL(in: runs.c.root, case: parityCase)
        let sidecarName = Self.sidecarURL(for: outputA).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: outputA)
        XCTAssertEqual(payloadA, try Data(contentsOf: outputC), "the report byte for byte")
        let a = try Self.envelope(for: outputA)
        let c = try Self.envelope(for: outputC)
        XCTAssertEqual(a.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(a.toolName, c.toolName, "the tool")
        XCTAssertEqual(a.tool.kind, c.tool.kind, "the tool kind")
        XCTAssertEqual(a.workflowName, "lungfish fastq 12s-export")
        XCTAssertEqual(a.workflowName, c.workflowName, "the workflow")
        XCTAssertEqual(Self.relative(a.argv, under: runs.a.root), Self.relative(c.argv, under: runs.c.root), "the argv")
        XCTAssertEqual(
            Self.relative(try XCTUnwrap(a.durableReplayArgv), under: runs.a.root),
            Self.relative(try XCTUnwrap(c.durableReplayArgv), under: runs.c.root),
            "the durable replay argv"
        )
        let outA = try XCTUnwrap(a.output)
        let outC = try XCTUnwrap(c.output)
        XCTAssertNotNil(outA.checksumSHA256)
        XCTAssertEqual(outA.checksumSHA256, outC.checksumSHA256, "the output digest")
        XCTAssertEqual(outA.fileSize, UInt64(payloadA.count))
        XCTAssertEqual(outA.fileSize, outC.fileSize, "the output size")
        XCTAssertEqual(outA.format, outC.format, "the output format")
        let filesA = Self.files(of: a, under: runs.a.root)
        for name in ["targets.tsv", "sample-target-counts.tsv", "samples.tsv", "read-fate.json"] {
            XCTAssertTrue(filesA.keys.contains { $0.hasSuffix("/\(Self.bundleRelativePath)/\(name)") }, "\(name) in \(filesA.keys.sorted())")
        }
        XCTAssertEqual(filesA, Self.files(of: c, under: runs.c.root), "every file with its role and digest")
        XCTAssertEqual(a.options.resolvedDefaults, c.options.resolvedDefaults, "the resolved values")
        XCTAssertEqual(a.options.defaults, c.options.defaults, "the defaults")
        XCTAssertEqual(a.options.explicit.keys.sorted(), c.options.explicit.keys.sorted(), "the explicit keys")
        for key in a.options.explicit.keys.sorted() {
            if case .file(let fileA)? = a.options.explicit[key], case .file(let fileC)? = c.options.explicit[key] {
                XCTAssertEqual(
                    Self.relativePath(fileA.path, under: runs.a.root), Self.relativePath(fileC.path, under: runs.c.root),
                    "explicit \(key)"
                )
            } else {
                XCTAssertEqual(a.options.explicit[key], c.options.explicit[key], "explicit \(key)")
            }
        }
    }

    /// The record names the row's command (ARCH 2). The side A fix is the one record change, `forceOverwrite` false
    /// for a new file, a prediction row of the lane report (BIO 7).
    private func assertTheRecordNamesTheRowsCommand(_ runs: RouteParityRuns, case parityCase: Case) throws {
        let c = try Self.envelope(for: Self.outputURL(in: runs.c.root, case: parityCase))
        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(Array(rowArguments.prefix(2)), TwelveSAmpliconResultViewController.resultExportCommandPath)
        XCTAssertFalse(rowArguments.contains("--force"), "a new file is not replaced")
        XCTAssertEqual(c.options.explicit["forceOverwrite"], ParameterValue.boolean(false))
    }

    /// Each file of the record below `root`, keyed by its role and path, with its digest.
    private static func files(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        var files: [String: String] = [:]
        for file in envelope.files {
            files["\(file.role) \(relativePath(file.path, under: root))"] = file.checksumSHA256 ?? "no digest"
        }
        return files
    }

    private static func relative(_ argv: [String], under root: URL) -> [String] {
        argv.map { relativePath($0, under: root) }
    }

    private static func relativePath(_ path: String, under root: URL) -> String {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        let rootPath = rootPaths.first { path.hasPrefix($0 + "/") }
        return rootPath.map { "<ROOT>" + String(path.dropFirst($0.count)) } ?? path
    }
}

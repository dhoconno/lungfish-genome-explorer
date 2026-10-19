// AnnotationExportCLIGUIParityReplayTests.swift - The GFF3 annotation export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39 (B5), ARCH ruling on the export shape 1.7, ARCH ruling on 12.39 R2, manager decision R5, on
// lane Q30's harness. Each case runs on three sides that start as copies of one root holding a reference bundle with
// one annotation database of a one-line gene and a two-block transcript.
//
// - Side A is `AnnotationExportService.export` as it stood at c998d3ce1 (the retained folder, the payload, one
//   `writeAtomically` with the `/bin/cp` replay), frozen in this file since the lane deletes it, given the
//   annotations the app gave it. For a sidebar bundle those come from `AnnotationGFF3Export.loadBundleAnnotations`,
//   as the app's `loadAnnotationsForExport` loads them.
// - Side C is `AppDelegate.annotationGFF3ExportInvocation` and `beginAnnotationGFF3ExportOperation`, which begin the
//   row and run the built `lungfish-cli bundle export-gff3` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded. An open document's command names the
//   selection file side C wrote, which the record names as its input, so side C copies that file into root C'.
//
// A against C compares the payload, the record's inputs with their digests outside the retained folder, the output's
// size, `annotationCount` and `defaults`, and for an open document the output's digest and the selection's
// annotations. The identity fields, the old argv's `explicit` keys, `replayScope`, `replaysUpstreamAnalysis` and the
// retained inputs are prediction rows of the lane report (BIO 7), pinned by `assertPredictedRecordChanges`. Nothing
// is declared, so the old writer goes with no key (R-A1, C4).
//
// R5. Every load of a database gives its records new UUIDs, which the writer prints as `ID=`, so a sidebar bundle's
// payload is compared under `AnnotationGFF3RelationalIDMask` (A against C and C against C'), and its output digest,
// which follows the IDs, is left out of both compares. The open document keeps its UUIDs in the selection and is
// compared unmasked, digest included.
//
// The cancel runs through the real transport, as the EsViritu class runs it (ARCH ruling 1.6, X14).
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
private final class AnnotationExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class AnnotationExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case sidebarBundle
        case openDocument
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let bundleName = "fixture.lungfishref"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "annotation-export-parity")
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

    /// ARCH ruling on 12.39 R2 item 1. A sidebar bundle exports with no selection, and the leaf reads the manifest and
    /// the database side A's record names since commit 0abf67494.
    func testSidebarBundleMatches() async throws {
        let runs = try await assertParity(.sidebarBundle)
        let text = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
        let features = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(features.count, 3, "the gene and the transcript's two blocks\n\(text)")
        let masked = AnnotationGFF3RelationalIDMask.masked(text)
        XCTAssertEqual(masked.components(separatedBy: "ID=<ID-2>").count - 1, 2, "the transcript's two lines share one ID\n\(masked)")
        let record = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(record.options.resolvedDefaults["annotationCount"]?.integerValue, 2)
        XCTAssertEqual(record.argv.dropFirst().prefix(2), ["bundle", "export-gff3"])
        XCTAssertTrue(record.argv.count > 3 && record.argv[3].hasSuffix("/\(Self.bundleName)"), "\(record.argv)")
    }

    /// ARCH ruling on 12.39 R2 item 2 and R5 item 5. An open document's annotations, unsaved edits included, travel
    /// in the selection file with their UUIDs, so the payload and its digest match with no mask.
    func testOpenDocumentMatchesWithNoMask() async throws {
        let runs = try await assertParity(.openDocument)
        let payload = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
        XCTAssertTrue(payload.contains("Name=unsaved edit"), payload)
        let record = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(record.argv.dropFirst().prefix(3), ["bundle", "export-gff3", "--selection"])
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let invocation = try AppDelegate.annotationGFF3ExportInvocation(
            annotations: [], source: Self.sidebarSource(root), outputURL: output
        )

        let failures = AnnotationExportFailureCalls()
        let begun = try XCTUnwrap(AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: invocation,
            sourceName: "fixture",
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

// MARK: - The fixture and the sides

extension AnnotationExportCLIGUIParityReplayTests {
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("annotations.gff3")
    }

    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent(bundleName, isDirectory: true)
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    static func sidebarSource(_ root: URL) -> AnnotationExportService.Source {
        .init(kind: .sidebarBundle, urls: [bundleURL(in: root)], name: "fixture")
    }

    /// The open document's file, outside every side root. It is never read, and its path is in side A's argv and in
    /// the selection side C copies into root C'.
    var documentSource: AnnotationExportService.Source {
        .init(kind: .openDocument, urls: [scratch.appendingPathComponent("documents/Edited document.gb")], name: "Edited document")
    }

    /// A reference bundle with one annotation database of a one-line gene and a two-block transcript.
    static func makeFixture(_ root: URL) throws {
        let bundle = bundleURL(in: root)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("annotations"), withIntermediateDirectories: true)
        let bed = root.appendingPathComponent("genes.bed")
        try ("chr1\t10\t60\tgene-a\t0\t+\t10\t60\t0,0,0\t1\t50\t0\tgene\tgene_id=gene-a\n"
            + "chr1\t100\t200\ttx-b\t0\t+\t100\t200\t0,0,0\t2\t20,30\t0,70\tmRNA\tgene=gene-a\n")
            .write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db"))
        try FileManager.default.removeItem(at: bed)
        try BundleManifest(
            name: "Annotation Export Fixture",
            identifier: "org.lungfish.annotation-export-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: nil,
            annotations: [AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db")],
            recordStore: nil
        ).save(to: bundle)
    }

    /// An open document's annotations, an unsaved edit among them, built once for both sides of a case.
    static func documentAnnotations() -> [SequenceAnnotation] {
        [
            SequenceAnnotation(
                type: .gene, name: "unsaved edit", chromosome: "chr1", start: 10, end: 60, strand: .forward,
                note: "edited, not saved"
            ),
            SequenceAnnotation(
                type: .mRNA, name: "tx-b", chromosome: "chr1",
                intervals: [AnnotationInterval(start: 100, end: 120), AnnotationInterval(start: 170, end: 200)],
                strand: .forward, qualifiers: ["gene": AnnotationQualifier("unsaved edit")]
            ),
        ]
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The source and annotations the app gives the export. A sidebar bundle's come from the shared loader, as the
    /// app's `loadAnnotationsForExport` loads them before the save panel.
    private func appInput(_ root: URL, _ parityCase: Case, document: [SequenceAnnotation]) throws
        -> (source: AnnotationExportService.Source, annotations: [SequenceAnnotation]) {
        switch parityCase {
        case .sidebarBundle:
            return (Self.sidebarSource(root), try AnnotationGFF3Export.loadBundleAnnotations(bundleURL: Self.bundleURL(in: root)).annotations)
        case .openDocument:
            return (documentSource, document)
        }
    }

    /// Side A. The in-app writer the panel ran before the leaf, frozen below.
    private func sideA(_ root: URL, _ parityCase: Case, document: [SequenceAnnotation]) async throws -> RouteParitySideOutcome {
        let input = try appInput(root, parityCase, document: document)
        do {
            try await Self.frozenExport(source: input.source, annotations: input.annotations, outputURL: Self.outputURL(in: root))
            return RouteParitySideOutcome(end: .completed, detail: "Exported annotations.gff3")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// The base's selection.json, `AnnotationExportService.Selection` at c998d3ce1.
    struct FrozenSelection: Codable {
        var replayScope = "retained-selection snapshot byte replay"
        var source: AnnotationExportService.Source
        var annotations: [SequenceAnnotation]
    }

    /// `AnnotationExportService.export` with its retained-selection helper inlined, as it stood at c998d3ce1.
    static func frozenExport(source: AnnotationExportService.Source, annotations: [SequenceAnnotation], outputURL: URL) async throws {
        let runClock = ProvenanceRunClock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let directory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".lungfish-export-inputs/\(UUID())", isDirectory: true)
        let payloadURL = directory.appendingPathComponent("selected." + outputURL.pathExtension)
        let selectionURL = directory.appendingPathComponent("selection.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(FrozenSelection(source: source, annotations: annotations)).write(to: selectionURL, options: .atomic)
            try await GFF3Writer.write(annotations, to: payloadURL, source: "Lungfish")
            var argv = ["Lungfish.app", "export-gff3", "--source-kind", source.kind.rawValue]
            for url in source.urls { argv += ["--source", url.path] }
            argv += ["--output", outputURL.path]
            let readURLs = source.kind == .sidebarBundle
                ? source.urls.flatMap { (try? AnnotationGFF3Export.bundleInputURLs(bundleURL: $0)) ?? [] }
                : []
            var seen = Set<String>()
            let sourceURLs = (readURLs + [payloadURL, selectionURL]).filter { seen.insert($0.standardizedFileURL.path).inserted }
            try ScientificFileExportProvenance.writeAtomically(.init(
                workflowName: "lungfish app annotation export", sourceURLs: sourceURLs,
                outputURL: outputURL, outputFormat: .gff3, argv: argv,
                durableReplayArgv: ["/bin/cp", payloadURL.path, outputURL.path],
                explicitOptions: ["sourceKind": .string(source.kind.rawValue),
                    "sourceName": .string(source.name),
                    "sourcePaths": .array(source.urls.map { .file($0) }),
                    "outputPath": .file(outputURL)],
                defaults: ["outputFormat": .string("gff3"), "featureSource": .string("Lungfish")],
                resolved: ["annotationCount": .integer(annotations.count),
                    "replayScope": .string("retained-selection snapshot byte replay"),
                    "replaysUpstreamAnalysis": .boolean(false)],
                runClock: runClock
            )) { stagedURL in
                try FileManager.default.copyItem(at: payloadURL, to: stagedURL)
            }
        } catch {
            if !(error is ScientificPublicationRecoveryRequired) {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    /// Side C. The panel's invocation and begin helper, which run the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, _ parityCase: Case, document: [SequenceAnnotation]) async throws -> RouteParitySideOutcome {
        let input = try appInput(root, parityCase, document: document)
        let invocation = try AppDelegate.annotationGFF3ExportInvocation(
            annotations: input.annotations, source: input.source, outputURL: Self.outputURL(in: root)
        )
        if let selection = invocation.selection {
            // Side C' replays a command naming this file below its own root, and the record names it as the input.
            try Self.copy(URL(fileURLWithPath: selection), from: root, to: RouteParityHarness.root(of: .cPrime, in: root.deletingLastPathComponent()))
        }
        let failures = AnnotationExportFailureCalls()
        guard let begun = AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: invocation,
            sourceName: input.source.name,
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

    private static func copy(_ file: URL, from root: URL, to otherRoot: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        XCTAssertTrue(path.hasPrefix(rootPath + "/"), "\(path) is below \(rootPath)")
        let target = otherRoot.appendingPathComponent(String(path.dropFirst(rootPath.count + 1)))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: target)
    }

    /// Runs the case on its three sides and checks it as 1.7 reads it, with R5's mask for a sidebar bundle.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let document = Self.documentAnnotations()
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: Self.makeFixture,
            sideA: { root in try await self.sideA(root, parityCase, document: document) },
            sideC: { root in try await self.sideC(root, parityCase, document: document) }
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
        let cAgainstCPrime = (found[.cAgainstCPrime] ?? []).filter { !Self.followsTheIDs($0, parityCase) }
        XCTAssertEqual(cAgainstCPrime.map(\.description), [], "C against C' differs in nothing outside R5's mask")
        try assertSameOutput(runs.c, runs.cPrime, parityCase, "C against C'")
        XCTAssertEqual(
            Self.inputs(of: try Self.envelope(in: runs.c.root), under: runs.c.root),
            Self.inputs(of: try Self.envelope(in: runs.cPrime.root), under: runs.cPrime.root),
            "C against C', the inputs and their digests"
        )
        try assertAEqualsC(runs, parityCase)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// R5. The differences a sidebar bundle's export shows because each load gives new UUIDs, a payload line whose
    /// `ID=` differs and the record's digest of the payload. The payload is compared under the mask instead, and the
    /// record's input digests on their own.
    private static func followsTheIDs(_ difference: RouteParityDifference, _ parityCase: Case) -> Bool {
        guard parityCase == .sidebarBundle else { return false }
        let output = outputURL(in: URL(fileURLWithPath: "/"))
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: output).lastPathComponent
        if difference.id.contains(sidecarName) {
            return difference.id.hasSuffix("checksumSHA256")
        }
        return difference.id.contains(output.lastPathComponent)
    }

    /// The payload and the record's output facts of two sides. A sidebar bundle's payload is equal under R5's mask
    /// and in size, and an open document's byte for byte with its digest.
    private func assertSameOutput(_ first: RouteParitySideRun, _ second: RouteParitySideRun, _ parityCase: Case, _ label: String) throws {
        let payloadFirst = try Data(contentsOf: Self.outputURL(in: first.root))
        let payloadSecond = try Data(contentsOf: Self.outputURL(in: second.root))
        let outputFirst = try XCTUnwrap(try Self.envelope(in: first.root).output)
        let outputSecond = try XCTUnwrap(try Self.envelope(in: second.root).output)
        XCTAssertEqual(outputFirst.fileSize, UInt64(payloadFirst.count), label)
        XCTAssertEqual(outputFirst.fileSize, outputSecond.fileSize, "\(label), the output size")
        XCTAssertNotNil(outputFirst.checksumSHA256)
        switch parityCase {
        case .sidebarBundle:
            XCTAssertEqual(
                AnnotationGFF3RelationalIDMask.masked(String(decoding: payloadFirst, as: UTF8.self)),
                AnnotationGFF3RelationalIDMask.masked(String(decoding: payloadSecond, as: UTF8.self)),
                "\(label), the payload under R5's mask"
            )
        case .openDocument:
            XCTAssertEqual(payloadFirst, payloadSecond, "\(label), the payload byte for byte")
            XCTAssertEqual(outputFirst.checksumSHA256, outputSecond.checksumSHA256, "\(label), the output digest")
        }
    }

    /// A against C on the facts of 1.7, each record path read relative to its side root. No file but the record, the
    /// retained folder and, for a sidebar bundle, the IDs differs.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && !$0.id.contains(".lungfish-export-inputs") && !Self.followsTheIDs($0, parityCase)
        }
        XCTAssertEqual(others.map(\.description), [], "only the record and the retained folder may differ between A and C")
        try assertSameOutput(runs.a, runs.c, parityCase, "A against C")

        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let inputsA = Self.inputs(of: a, under: runs.a.root).filter { !$0.key.contains("/.lungfish-export-inputs/") }
        let inputsC = Self.inputs(of: c, under: runs.c.root)
        switch parityCase {
        case .sidebarBundle:
            XCTAssertEqual(inputsA, inputsC, "the manifest and the database with their digests")
            XCTAssertEqual(inputsC.keys.sorted(), ["/fixture.lungfishref/annotations/genes.db", "/fixture.lungfishref/manifest.json"])
        case .openDocument:
            XCTAssertEqual(inputsA, [:], "side A names no file outside its retained folder")
            XCTAssertEqual(inputsC.count, 1)
            XCTAssertTrue(inputsC.keys.allSatisfy { $0.hasPrefix("/.lungfish-export-inputs/") && $0.hasSuffix("/selection.json") }, "\(inputsC)")
            try assertTheSelectionsCarryOneDocument(a, c)
        }
        XCTAssertEqual(a.options.resolvedDefaults["annotationCount"], c.options.resolvedDefaults["annotationCount"])
        XCTAssertEqual(a.options.defaults, c.options.defaults, "defaults")
    }

    /// The base's selection.json and the leaf's selection file hold one document, its annotations with their UUIDs.
    private func assertTheSelectionsCarryOneDocument(_ a: ProvenanceEnvelope, _ c: ProvenanceEnvelope) throws {
        let fileA = try XCTUnwrap(a.files.first { $0.role == .input && $0.path.hasSuffix("/selection.json") })
        let fileC = try XCTUnwrap(c.files.first { $0.role == .input && $0.path.hasSuffix("/selection.json") })
        let base = try JSONDecoder().decode(FrozenSelection.self, from: Data(contentsOf: URL(fileURLWithPath: fileA.path)))
        let selection = try ViewerExportSelection.read(from: URL(fileURLWithPath: fileC.path))
        XCTAssertEqual(selection.documentAnnotations, AnnotationExportDocumentSelection(
            sourceName: base.source.name, sourcePath: base.source.urls.first?.path, annotations: base.annotations
        ), "the selection carries the annotations side A retained, with their UUIDs")
    }

    /// The prediction rows of the lane report (BIO 7). The identity fields, the old argv's `explicit` keys, the
    /// `/bin/cp` replay's `resolved` keys and the retained inputs go, and the record's argv is the row's command.
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let outputA = Self.outputURL(in: runs.a.root)
        let sourceA = try parityCase == .sidebarBundle ? Self.bundleURL(in: runs.a.root) : XCTUnwrap(documentSource.urls.first)
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, [
            "Lungfish.app", "export-gff3", "--source-kind", parityCase == .sidebarBundle ? "sidebarBundle" : "openDocument",
            "--source", sourceA.path, "--output", outputA.path,
        ])
        XCTAssertEqual(a.durableReplayArgv?.first, "/bin/cp")
        XCTAssertEqual(a.durableReplayArgv?.last, outputA.path)
        XCTAssertEqual(a.workflowName, "lungfish app annotation export")
        XCTAssertEqual(Set(a.options.resolvedDefaults.keys), ["annotationCount", "replayScope", "replaysUpstreamAnalysis"])
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["outputPath", "sourceKind", "sourceName", "sourcePaths"])
        let retained = Self.inputs(of: a, under: runs.a.root).keys.filter { $0.contains("/.lungfish-export-inputs/") }
        XCTAssertEqual(retained.map { ($0 as NSString).lastPathComponent }.sorted(), ["selected.gff3", "selection.json"])

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, AnnotationGFF3Export.workflowName)
        XCTAssertEqual(Set(c.options.resolvedDefaults.keys), ["annotationCount"])
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["force", "outputPath"])
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}

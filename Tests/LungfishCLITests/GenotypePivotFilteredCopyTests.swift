import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class GenotypePivotFilteredCopyTests: XCTestCase {
    private static var managedPythonURL: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"]
            .map { root.appendingPathComponent("\($0)/conda/envs/openpyxl/bin/python") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func testEveryOrdinaryXlsxRouteUsesTheReviewedSnapshotContract() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-common-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: root, includeCalls: true)

        let pivot = root.appendingPathComponent("pivot.xlsx")
        try await GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", bundle.path,
            "--output", pivot.path,
            "--min-percent", "50",
            "--percent-basis", "sample-retained",
        ]).run(managedPythonResolver: { python })

        let legacyName = root.appendingPathComponent("export-xlsx.xlsx")
        try await GenotypeExportXlsxSubcommand.parse([
            "--bundle", bundle.path,
            "--output", legacyName.path,
        ]).run(managedPythonResolver: { python })

        let unified = root.appendingPathComponent("unified.xlsx")
        _ = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "xlsx",
            "--output", unified.path,
            "--min-reads", "10",
        ]).runReturningResolvedColumns(managedPythonResolver: { python })

        for output in [pivot, legacyName, unified] {
            let inspection = try await inspect(output, python: python, root: root)
            XCTAssertEqual(
                inspection["sheets"] as? [String],
                [
                    "Haplotype Calls",
                    "Genotype Matrix - All",
                    "Genotype Matrix - Filtered",
                    "Export Metadata",
                ]
            )
            XCTAssertEqual(inspection["call"] as? String, "Exact H1")
            XCTAssertFalse((inspection["all"] as? [String] ?? []).isEmpty)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: output.appendingPathExtension("provenance.json").path
                )
            )
        }

        let pivotInspection = try await inspect(pivot, python: python, root: root)
        XCTAssertTrue((pivotInspection["all"] as? [String] ?? []).contains("03_Mamu-B_Background"))
        XCTAssertFalse((pivotInspection["filtered"] as? [String] ?? []).contains("03_Mamu-B_Background"))
        XCTAssertEqual(
            pivotInspection["filteredPolicy"] as? String,
            GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy
        )
    }

    func testGenotypeTokensDoNotInventHaplotypeCalls() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-no-fake-calls-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: root, includeCalls: false)
        let output = root.appendingPathComponent("report.xlsx")

        try await GenotypeExportXlsxSubcommand.parse([
            "--bundle", bundle.path,
            "--output", output.path,
        ]).run(managedPythonResolver: { python })

        let inspection = try await inspect(output, python: python, root: root)
        XCTAssertEqual(
            inspection["sheets"] as? [String],
            ["Genotype Matrix - All", "Genotype Matrix - Filtered", "Export Metadata"]
        )
    }

    func testReceiptRecordsFinalOutputAndDurableReplay() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: root, includeCalls: true)
        let output = root.appendingPathComponent("report.xlsx")
        try await GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", bundle.path,
            "--output", output.path,
        ]).run(managedPythonResolver: { python })

        let receiptURL = output.appendingPathExtension("provenance.json")
        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
                as? [String: Any]
        )
        XCTAssertEqual((receipt["output"] as? [String: Any])?["path"] as? String, output.path)
        XCTAssertEqual(receipt["receiptPath"] as? String, receiptURL.path)
        XCTAssertEqual(receipt["exitStatus"] as? Int, 0)
        XCTAssertEqual(receipt["workflowName"] as? String, "genotype.export.pivot-xlsx")
        XCTAssertFalse((receipt["durableReplayArgv"] as? [String] ?? []).isEmpty)
        XCTAssertFalse((receipt["inputs"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testExactStableReviewCommentAndPaletteSurviveOrdinaryCommand() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-stable-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: root, includeCalls: true)
        let output = root.appendingPathComponent("reviewed.xlsx")

        try await GenotypeExportXlsxSubcommand.parse([
            "--bundle", bundle.path,
            "--output", output.path,
        ]).run(managedPythonResolver: { python })

        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: output.appendingPathExtension("provenance.json"))
            ) as? [String: Any]
        )
        let snapshotPath = try XCTUnwrap(
            (receipt["snapshot"] as? [String: Any])?["path"] as? String
        )
        let snapshot = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        )
        let exact = try XCTUnwrap(
            snapshot.allMatrix.rows.first {
                $0.target.stableClusterID == "stable-candidate-A"
            }
        )
        XCTAssertEqual(
            snapshot.allMatrix.rows.filter { $0.displayName == "Duplicate candidate" }.count,
            2
        )
        XCTAssertEqual(exact.target.genotype, "Duplicate candidate")
        XCTAssertEqual(exact.cells.first?.rawSupport, 12)
        XCTAssertEqual(exact.cells.first?.review, "false-positive")
        XCTAssertEqual(exact.cells.first?.comment, "exact stable note")
        XCTAssertEqual(exact.style?.fillHex?.uppercased(), "#ABCDEF")
        XCTAssertEqual(exact.cells.first?.style?.textHex?.uppercased(), "#FFFFFF")

        let expectedHaplotypeFill = try XCTUnwrap(
            snapshot.colors.first { $0.locus == "MHC-A" && $0.call == "Exact H1" }
        ).fillHex.replacingOccurrences(of: "#", with: "").uppercased()
        let inspection = try await inspectExactRow(
            output,
            rowID: exact.id,
            python: python,
            root: root
        )
        XCTAssertEqual(inspection["rowLabel"] as? String, "Duplicate candidate")
        XCTAssertEqual(inspection["rowValue"] as? Int, 12)
        XCTAssertTrue((inspection["cellNote"] as? String ?? "").contains("exact stable note"))
        XCTAssertTrue((inspection["cellNote"] as? String ?? "").contains("false-positive"))
        XCTAssertEqual(inspection["haplotypeFill"] as? String, expectedHaplotypeFill)
    }

    func testDecodedSnapshotReplayKeepsLiteralValuesAfterBundleRemoval() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-snapshot-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: root, includeCalls: true)
        let original = root.appendingPathComponent("original.xlsx")
        try await GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", bundle.path,
            "--output", original.path,
            "--min-reads", "10",
        ]).run(managedPythonResolver: { python })
        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: original.appendingPathExtension("provenance.json"))
            ) as? [String: Any]
        )
        let snapshotPath = try XCTUnwrap(
            (receipt["snapshot"] as? [String: Any])?["path"] as? String
        )
        let snapshotURL = URL(fileURLWithPath: snapshotPath)
        let requestURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("request.json")

        // The decoded-snapshot branch must be completely independent of the
        // original mutable bundle after capture.
        try FileManager.default.removeItem(at: bundle)
        let replayed = root.appendingPathComponent("replayed.xlsx")
        try await GenotypeExportXlsxSubcommand.parse([
            "--snapshot", snapshotURL.path,
            "--provenance-request", requestURL.path,
            "--python", python.path,
            "--output", replayed.path,
        ]).run(managedPythonResolver: {
            XCTFail("snapshot replay uses its explicit --python")
            throw CocoaError(.fileNoSuchFile)
        })

        let originalInspection = try await inspect(original, python: python, root: root)
        let replayInspection = try await inspect(replayed, python: python, root: root)
        XCTAssertEqual(
            originalInspection["sheets"] as? [String],
            replayInspection["sheets"] as? [String]
        )
        XCTAssertEqual(
            originalInspection["all"] as? [String],
            replayInspection["all"] as? [String]
        )
        XCTAssertEqual(
            originalInspection["filtered"] as? [String],
            replayInspection["filtered"] as? [String]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: replayed.appendingPathExtension("provenance.json").path
            )
        )
    }

    func testPivotProjectionPreservesLowerAuthoritativeOccurrenceAndAttestedZero() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-projected-occurrences-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: root, includeCalls: true)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        S1,01_M1A_A1_063,16,16,100,20,20.0,1000,20,2.0
        S1,01_M1A_A1_063,4,4,100,20,20.0,1000,20,2.0
        S2,01_M1A_A1_063,0,0,80,0,0.0,1000,20,2.0
        """.write(
            to: bundle.appendingPathComponent("calls.csv"),
            atomically: true,
            encoding: .utf8
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1", "S2"],
                rows: [
                    .init(
                        label: "Captured allele",
                        rawGenotype: "01_M1A_A1_063",
                        cells: ["4", "0"]
                    ),
                ]
            )
        ).write(to: projectionURL)
        let output = root.appendingPathComponent("report.xlsx")

        try await GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", bundle.path,
            "--output", output.path,
            "--view-projection", projectionURL.path,
        ]).run(managedPythonResolver: { python })

        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: output.appendingPathExtension("provenance.json"))
            ) as? [String: Any]
        )
        let snapshotPath = try XCTUnwrap(
            (receipt["snapshot"] as? [String: Any])?["path"] as? String
        )
        let snapshot = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        )
        let row = try XCTUnwrap(snapshot.filteredMatrix.rows.first)
        XCTAssertEqual(row.displayName, "Captured allele")
        XCTAssertEqual(row.cells.map(\.displayValue), [4, 0])
    }

    func testPivotRejectsIncoherentProjectionBeforeForcedDestinationReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-incoherent-projection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: root, includeCalls: true)
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1"],
                rows: [
                    .init(
                        label: "Unsupported count",
                        rawGenotype: "01_M1A_A1_063",
                        cells: ["999"]
                    ),
                ]
            )
        ).write(to: projectionURL)
        let output = root.appendingPathComponent("existing.xlsx")
        let receipt = output.appendingPathExtension("provenance.json")
        let priorOutput = Data("existing output owner".utf8)
        let priorReceipt = Data("existing receipt owner".utf8)
        try priorOutput.write(to: output)
        try priorReceipt.write(to: receipt)

        do {
            try await GenotypeExportPivotXlsxSubcommand.parse([
                "--bundle", bundle.path,
                "--output", output.path,
                "--view-projection", projectionURL.path,
                "--force",
            ]).run(managedPythonResolver: {
                XCTFail("incoherent projection must fail before runtime resolution")
                throw CocoaError(.fileNoSuchFile)
            })
            XCTFail("incoherent projection was accepted")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "projected value does not match authoritative evidence"
                ),
                String(describing: error)
            )
        }
        XCTAssertEqual(try Data(contentsOf: output), priorOutput)
        XCTAssertEqual(try Data(contentsOf: receipt), priorReceipt)
    }

    private func makeBundle(in root: URL, includeCalls: Bool) throws -> URL {
        let bundle = root.appendingPathComponent(
            includeCalls ? "called.lungfishgenotype" : "uncalled.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let workbook = bundle.appendingPathComponent("source.xlsx")
        let calls = bundle.appendingPathComponent("calls.csv")
        let samples = bundle.appendingPathComponent("samples.csv")
        let stats = bundle.appendingPathComponent("stats.json")
        let provenance = bundle.appendingPathComponent("provenance.json")
        let analysis = bundle.appendingPathComponent("haplotypes.json")
        let catalog = bundle.appendingPathComponent("reviewable-row-catalog.json")
        try Data("this is deliberately not an xlsx workbook".utf8).write(to: workbook)
        try Data("{}".utf8).write(to: provenance)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        S1,01_M1A_A1_063,42,39,100,46,46.0,1000,60,6.0
        S1,03_Mamu-B_Background,4,4,100,46,46.0,1000,60,6.0
        """.write(to: calls, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        S1,46,46,100,46.0,1000,6.0
        """.write(to: samples, atomically: true, encoding: .utf8)
        try """
        {"totalInputReads":1000,"totalAlignments":46,"passedAlignments":46,"retainedUniqueReads":46,"retainedUniquePercentOfTotalReads":4.6,"assignedUniqueRetainedReads":43,"unassignedUniqueRetainedReads":3}
        """.write(to: stats, atomically: true, encoding: .utf8)

        if includeCalls {
            let value = GenotypeHaplotypeAnalysis(
                assayID: "fixture-assay",
                definitionSetID: "fixture-definition",
                definitionSetName: "Fixture",
                speciesName: "Fixture",
                generatedAt: "2026-09-12T00:00:00Z",
                analysisRevisionID: "fixture-revision",
                source: .manual,
                samples: [
                    .init(sample: "S1", calls: [
                        .init(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "Exact H1",
                            haplotype2: "Exact H2",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1A_A1_063"]
                        ),
                    ]),
                ]
            )
            try JSONEncoder().encode(value).write(to: analysis)
        }
        let rowCatalog = try GenotypeReviewableRowCatalog(
            samples: ["S1"],
            rows: [
                .init(
                    kind: .candidate,
                    callID: "candidate:MHC-A:stable-candidate-A",
                    displayName: "Duplicate candidate",
                    locus: "MHC-A",
                    stableID: "stable-candidate-A",
                    section: "candidate",
                    sortKey: "A",
                    supportBySample: ["S1": 12]
                ),
                .init(
                    kind: .candidate,
                    callID: "candidate:MHC-A:stable-candidate-B",
                    displayName: "Duplicate candidate",
                    locus: "MHC-A",
                    stableID: "stable-candidate-B",
                    section: "candidate",
                    sortKey: "B",
                    supportBySample: ["S1": 0]
                ),
            ]
        ).validated()
        try rowCatalog.encoded().write(to: catalog)
        let catalogReference = ONTMHCArtifactReference(
            path: catalog.lastPathComponent,
            sha256: try ProvenanceFileHasher.sha256(of: catalog),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: catalog))
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbook.lastPathComponent,
            longSummaryCSVPath: calls.lastPathComponent,
            sampleSummaryCSVPath: samples.lastPathComponent,
            statsJSONPath: stats.lastPathComponent,
            provenancePath: provenance.lastPathComponent,
            haplotypeAnalysisPath: includeCalls ? analysis.lastPathComponent : nil,
            createdAt: "2026-09-12T00:00:00Z",
            reviewableRowCatalog: catalogReference
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-09-12T00:00:00Z"
        )
        let exactCell = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Duplicate candidate",
            sample: "S1",
            stableClusterID: "stable-candidate-A"
        )
        sidecar.matrixReviews = [
            .init(
                target: exactCell,
                disposition: .falsePositive,
                author: "Reviewer",
                timestamp: "2026-09-12T00:00:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: exactCell,
                body: "exact stable note",
                author: "Reviewer",
                timestamp: "2026-09-12T00:00:00Z"
            ),
        ]
        sidecar.matrixStyles = [
            .init(
                target: .row(
                    locus: "MHC-A",
                    genotype: "Duplicate candidate",
                    stableClusterID: "stable-candidate-A"
                ),
                style: .init(fillColor: "#ABCDEF", isBold: true),
                author: "Reviewer",
                timestamp: "2026-09-12T00:00:00Z"
            ),
            .init(
                target: exactCell,
                style: .init(textColor: "#FFFFFF", isItalic: true),
                author: "Reviewer",
                timestamp: "2026-09-12T00:00:00Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundle)
        return bundle
    }

    private func inspect(_ workbook: URL, python: URL, root: URL) async throws -> [String: Any] {
        let script = root.appendingPathComponent("inspect-\(UUID().uuidString).py")
        try Data(#"""
import json, sys
from openpyxl import load_workbook
w = load_workbook(sys.argv[1], data_only=False)
o = {'sheets': w.sheetnames}
if 'Haplotype Calls' in w.sheetnames:
    o['call'] = w['Haplotype Calls']['D2'].value
for key, name in [('all', 'Genotype Matrix - All'), ('filtered', 'Genotype Matrix - Filtered')]:
    if name in w.sheetnames:
        s = w[name]
        o[key] = [s.cell(r, 3).value for r in range(2, s.max_row + 1) if s.cell(r, 3).value]
if 'Export Metadata' in w.sheetnames:
    m = w['Export Metadata']
    for r in range(1, m.max_row + 1):
        if m.cell(r, 1).value == 'Filtered evidence row policy':
            o['filteredPolicy'] = m.cell(r, 2).value
print(json.dumps(o))
"""#.utf8).write(to: script)
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, workbook.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: stdout.fileHandleForReading.readDataToEndOfFile()
            ) as? [String: Any]
        )
    }

    private func inspectExactRow(
        _ workbook: URL,
        rowID: String,
        python: URL,
        root: URL
    ) async throws -> [String: Any] {
        let script = root.appendingPathComponent("inspect-exact-\(UUID().uuidString).py")
        try Data(#"""
import json, sys
from openpyxl import load_workbook
w = load_workbook(sys.argv[1], data_only=False)
s = w['Genotype Matrix - All']
row = next(r for r in range(1, s.max_row + 1) if s.cell(r, 1).value == sys.argv[2])
fill = w['Haplotype Calls']['D2'].fill.fgColor.rgb or ''
print(json.dumps({
  'rowLabel': s.cell(row, 3).value,
  'rowValue': s.cell(row, 4).value,
  'cellNote': s.cell(row, 4).comment.text if s.cell(row, 4).comment else '',
  'haplotypeFill': fill[-6:].upper(),
}))
"""#.utf8).write(to: script)
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, workbook.path, rowID]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let error = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: stdout.fileHandleForReading.readDataToEndOfFile()
            ) as? [String: Any]
        )
    }
}

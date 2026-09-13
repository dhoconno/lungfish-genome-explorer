import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeExactZeroWorkbookAcceptanceTests: XCTestCase {
    func testAttestedReferenceZeroSurvivesNativeReviewExportReopenAndClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LGE-Zero-Acceptance-" + UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Exact-zero QA retained fixture: \(root.path)")
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = workspace.appendingPathComponent(".build/debug/lungfish-cli")
        let raw = Data("sample,genotype,passed_alignments,passed_unique_reads\nScientific-S,01_Mafa_A1_Zero,0,0\n".utf8)
        try raw.write(to: root.appendingPathComponent("calls.csv"))
        try Data("sample,passed_alignments,passed_unique_reads\nScientific-S,0,0\n".utf8).write(to: root.appendingPathComponent("samples.csv"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("provenance.json"))
        try JSONEncoder().encode(ONTGenotypeRunStats(totalInputReads: 0, retainedUniqueReads: 0)).write(to: root.appendingPathComponent("stats.json"))
        let catalog = try GenotypeReviewableRowCatalog(samples: ["Scientific-S"], rows: [
            .init(kind: .reference, callID: "01_Mafa_A1_Zero", displayName: "01_Mafa_A1_Zero", locus: "MHC-A", stableID: nil, section: "reference", sortKey: "0", supportBySample: ["Scientific-S": 0])
        ]).validated()
        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(catalog).write(to: catalogURL)
        let descriptor = ONTMHCArtifactReference(path: "catalog.json", sha256: try ProvenanceFileHasher.sha256(of: catalogURL), sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: catalogURL)))
        let manifest = ONTGenotypeResultBundleManifest(kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype, workflowMode: .genotypeOnly, outputName: "zero", analysisName: "Exact zero",
            primaryWorkbookPath: "report.xlsx", longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv", statsJSONPath: "stats.json", provenancePath: "provenance.json", reviewableRowCatalog: descriptor)
        try ONTGenotypeResultBundle.writeManifest(manifest, to: root)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(.empty(generatedAt: "2026-09-12T00:00:00Z"), forBundleAt: root)
        let result = try ONTGenotypeResultBundle.loadResult(from: root)
        let controller = GenotypeResultViewController(); _ = controller.view; controller.configure(result: result)
        controller.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 0))

        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-A", genotype: "01_Mafa_A1_Zero", sample: "Scientific-S")
        for phase in ["set", "clear"] {
            controller.applyMatrixReview(.init(targets: [target], intent: phase == "set" ? .set(.falseNegative) : .clear))
            let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: root)
            XCTAssertEqual(sidecar.matrixReviews.count, phase == "set" ? 1 : 0)
            let reopened = GenotypeResultViewController(); _ = reopened.view
            reopened.configure(result: try ONTGenotypeResultBundle.loadResult(from: root))
            reopened.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 0))
            let snapshot = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
                from: XCTUnwrap(reopened.captureExcelExportSnapshot().excelSnapshotData))
            let zero = try XCTUnwrap(snapshot.allMatrix.rows.first { $0.target.genotype == "01_Mafa_A1_Zero" }?.cells.first)
            XCTAssertEqual(zero.rawSupport, 0)
            XCTAssertEqual(zero.displayValue, 0)
            XCTAssertEqual(zero.review, phase == "set" ? "false-negative" : nil)
            XCTAssertFalse(snapshot.filteredMatrix.rows.contains { $0.target.genotype == "01_Mafa_A1_Zero" })
            let output = root.appendingPathComponent("report-\(phase).xlsx")
            let exported = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot,
                outputURL: output, provenance: .init(workflowName: "exact-zero-native-review", toolVersion: "test",
                    argv: [cli.path, "genotype", "export"], options: ["phase": phase], defaults: [:], runtimeContext: [:], inputs: []))
            XCTAssertTrue(FileManager.default.fileExists(atPath: exported.receiptURL.path))
            try runPython(python, code: #"""
import sys
from openpyxl import load_workbook
w=load_workbook(sys.argv[1],data_only=False)
assert w.sheetnames==['Genotype Matrix - All','Genotype Matrix - Filtered','Export Metadata']
assert not any(c.data_type=='f' for s in w for row in s for c in row)
assert any(c.value==0 and c.data_type=='n' for row in w['Genotype Matrix - All'] for c in row)
"""#, arguments: [output.path])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("calls.csv")), raw)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/workbooks/current.xlsx").path))
    }

    private func runPython(_ python: URL, code: String, arguments: [String]) throws {
        let p = Process(); p.executableURL = python; p.arguments = ["-c", code] + arguments
        let errors = Pipe(); p.standardError = errors
        try p.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self)
            print("Exact-zero acceptance failure: \(detail)")
            throw NSError(domain: "ExactZeroQA", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}

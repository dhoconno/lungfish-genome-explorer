import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishGenotypeUI

/// Cross-workflow acceptance for the immutable, one-way genotype workbook.
/// Expected scientific values are literal test data, never reconstructed with
/// the production snapshot builder or workbook adapter.
@MainActor
final class GenotypeUnifiedExcelAcceptanceTests: XCTestCase {
    private let timestamp = "2026-09-12T00:00:00Z"

    func testNativeFilteredViewportMatchesWorkbookUnderCombinedVisibilityControls() async throws {
        let root = retainedDirectory("native-filtered")
        let output = root.appendingPathComponent("native-filtered-three-sheet.xlsx")
        let samples = ["Visible-A", "Visible-B", "Hidden-C", "Visible-ManualHidden"]
        let calls = [
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*001", reads: 9),
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*002", reads: 4),
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*003", reads: 8),
            GenotypeTestFixtures.makeCall(sample: samples[1], genotype: "Mafa-A*003", reads: 0),
            GenotypeTestFixtures.makeCall(sample: samples[2], genotype: "Mafa-A*004", reads: 12),
            GenotypeTestFixtures.makeCall(sample: samples[3], genotype: "Mafa-A*007", reads: 10),
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*005", reads: 0),
        ]
        let catalog = try GenotypeReviewableRowCatalog(samples: [], rows: [
            .init(kind: .reference, callID: "Mafa-A*006", displayName: "Mafa-A*006", locus: "MHC-A",
                  stableID: nil, section: "reference", sortKey: "006", supportBySample: [:]),
        ]).validated()
        let result = GenotypeTestFixtures.makeResult(
            bundleURL: root,
            calls: calls,
            reviewableRowCatalog: catalog
        )
        let positive = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: "Mafa-A*001", sample: samples[0])
        let zero = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: "Mafa-A*003", sample: samples[1])
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.matrixReviews = [
            .init(target: positive, disposition: .falsePositive, author: "QA", timestamp: timestamp),
            .init(target: zero, disposition: .falseNegative, author: "QA", timestamp: timestamp),
        ]
        sidecar.matrixComments = [
            .init(target: positive, body: "native FP note", author: "QA", timestamp: timestamp),
            .init(target: zero, body: "native FN note", author: "QA", timestamp: timestamp),
        ]
        sidecar.matrixStyles = [
            .init(target: positive,
                  style: .init(fillColor: "#1A2B3C", isBold: true),
                  author: "QA", timestamp: timestamp),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: root)

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingApplyDisplayState(.init(
            summaryViewMode: .matrix,
            matrixMinimumReads: 5,
            matrixSampleFilterText: "Visible"
        ))
        controller.testingComparisonMatrix.testingHideSamples(Set([samples[3]]))
        let witness = try GenotypeFilteredViewportAcceptanceOracle.capture(
            matrix: controller.testingComparisonMatrix,
            sidecar: sidecar,
            minimumReads: 5
        )
        XCTAssertEqual(witness.samples.map(\.id), Array(samples.prefix(2)))
        XCTAssertEqual(witness.rows.map(\.genotype), ["Mafa-A*001", "Mafa-A*003"])
        let witnessURL = root.appendingPathComponent("native-filtered-witness.json")
        try GenotypeFilteredViewportAcceptanceOracle.write(witness, to: witnessURL)

        let snapshot = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(controller.captureExcelExportSnapshot().excelSnapshotData)
        )
        let exported = try await export(snapshot, to: output, replay: cliURL())
        try verifyNativeFilteredArtifact(
            exported.outputURL,
            snapshotURL: exported.snapshotURL,
            witnessURL: witnessURL
        )
    }

    func testMiSeqAllAndCombinedFilteredViewMatchIndependentEvidenceAndCalls() async throws {
        let root = retainedDirectory("miseq")
        let output = root.appendingPathComponent("miseq-four-sheet.xlsx")
        let samples = ["Visible-A", "Visible-B", "Hidden-C"]
        let calls = [
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*001", reads: 9),
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*002", reads: 4),
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*003", reads: 8),
            GenotypeTestFixtures.makeCall(sample: samples[1], genotype: "Mafa-A*003", reads: 0),
            GenotypeTestFixtures.makeCall(sample: samples[2], genotype: "Mafa-A*004", reads: 12),
            GenotypeTestFixtures.makeCall(sample: samples[0], genotype: "Mafa-A*005", reads: 0),
        ]
        // An empty catalog roster is a literal attestation that the sixth row
        // exists while providing no per-sample evidence: every output cell is
        // unknown, not zero.
        let catalog = try GenotypeReviewableRowCatalog(samples: [], rows: [
            .init(kind: .reference, callID: "Mafa-A*006", displayName: "Mafa-A*006", locus: "MHC-A", stableID: nil,
                  section: "reference", sortKey: "006", supportBySample: [:]),
        ]).validated()
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq", definitionSetID: "literal-fixture", definitionSetName: "Literal fixture",
            speciesName: "Fixture", generatedAt: timestamp, samples: [
                .init(sample: samples[0], calls: [.init(locus: "MHC-A", sourceLocus: "MHC-A",
                    haplotype1: "M1A", haplotype2: "-", status: .called, matchedHaplotypes: [],
                    observedGenotypeCount: 3, observedGenotypes: ["Mafa-A*001", "Mafa-A*002", "Mafa-A*003"])]),
                .init(sample: samples[1], calls: [.init(locus: "MHC-A", sourceLocus: "MHC-A",
                    haplotype1: "", haplotype2: "", status: .noHaplotype, matchedHaplotypes: [],
                    observedGenotypeCount: 0, observedGenotypes: [])]),
                .init(sample: samples[2], calls: [.init(locus: "MHC-A", sourceLocus: "MHC-A",
                    haplotype1: "M2A", haplotype2: "M3A", status: .called, matchedHaplotypes: [],
                    observedGenotypeCount: 1, observedGenotypes: ["Mafa-A*004"])]),
            ])
        let result = GenotypeTestFixtures.makeResult(calls: calls,
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            haplotypeAnalysis: analysis, haplotypeDefinitionSetID: analysis.definitionSetID,
            reviewableRowCatalog: catalog)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        let positive = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: "Mafa-A*001", sample: samples[0])
        let zero = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: "Mafa-A*003", sample: samples[1])
        sidecar.matrixReviews = [
            .init(target: positive, disposition: .falsePositive, author: "QA", timestamp: timestamp),
            .init(target: zero, disposition: .falseNegative, author: "QA", timestamp: timestamp),
        ]
        sidecar.matrixComments = [
            .init(target: positive, body: "positive FP note", author: "QA", timestamp: timestamp),
            .init(target: zero, body: "attested zero FN note", author: "QA", timestamp: timestamp),
        ]
        let filtered = GenotypeViewProjection(lens: "genotype", sampleColumns: Array(samples.prefix(2)), rows: [
            .init(label: "Mafa-A*001", rawGenotype: "Mafa-A*001", locus: "MHC-A", cells: ["9", ""]),
            .init(label: "Mafa-A*003", rawGenotype: "Mafa-A*003", locus: "MHC-A", cells: ["8", "0"]),
        ], haplotypeLocusScope: ["MHC-A"], filterContext: [
            "matrixMinimumReads": "5", "matrixSampleFilterText": "Visible", "combinedVisibility": "sample+reads",
        ])
        let colors: [GenotypeWorkbookPresentation.Color] = [
            .init(locus: "MHC-A", call: "M1A", fillHex: "#008000", fontHex: "#FFFFFF"),
            .init(locus: "MHC-A", call: "M2A", fillHex: "#0000FF", fontHex: "#FFFFFF"),
            .init(locus: "MHC-A", call: "M3A", fillHex: "#C65911", fontHex: "#FFFFFF"),
        ]
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: filtered, generatedAt: timestamp,
            authority: .init(analysis: analysis, colors: colors), filter: .init(matrixMinimumReads: 5))

        XCTAssertEqual(snapshot.allMatrix.samples.map(\.name), samples)
        XCTAssertEqual(snapshot.allMatrix.rows.count, 6)
        XCTAssertEqual(Set(snapshot.filteredMatrix.rows.map(\.displayName)), Set(["Mafa-A*001", "Mafa-A*003"]))
        XCTAssertEqual(snapshot.filteredMatrix.samples.map(\.name), Array(samples.prefix(2)))
        let mixed = try XCTUnwrap(snapshot.filteredMatrix.rows.first { $0.target.genotype == "Mafa-A*003" })
        XCTAssertEqual(mixed.cells.map(\.displayValue), [8, 0])
        XCTAssertEqual(mixed.cells[1].review, "false-negative")
        XCTAssertEqual(mixed.cells[1].comment, "attested zero FN note")
        XCTAssertFalse(snapshot.filteredMatrix.rows.contains { ["Mafa-A*002", "Mafa-A*004", "Mafa-A*005", "Mafa-A*006"].contains($0.target.genotype) })
        XCTAssertEqual(snapshot.calls.first { $0.sampleID == samples[0] }?.h2.effective, "M1A")
        XCTAssertEqual(snapshot.calls.first { $0.sampleID == samples[1] }?.h1.status, "noHaplotype")

        let exported = try await export(snapshot, to: output, replay: cliURL())
        try verifyMiSeqArtifact(exported.outputURL, snapshotURL: exported.snapshotURL)
        try verifyReceipt(exported.receiptURL, output: exported.outputURL, expectedMinimumReads: "5")
        print("TASK6_FOUR_SHEET=\(output.path)")
        print("TASK6_FOUR_RANGES=Haplotype Calls!A1:L4;Genotype Matrix - All!A1:F12;Genotype Matrix - Filtered!A1:E7;Export Metadata!A1:B30")
    }

    func testGenotypeOnlyExportHasThreeSheetsAndReplaysWithoutSourcePaths() async throws {
        let root = retainedDirectory("genotype-only")
        let output = root.appendingPathComponent("genotype-only-three-sheet.xlsx")
        let source = root.appendingPathComponent("temporary-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let result = GenotypeTestFixtures.makeResult(bundleURL: source, calls: [
            GenotypeTestFixtures.makeCall(sample: "Only-Sample", genotype: "Mafa-B*001", reads: 11),
        ])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result,
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil,
            generatedAt: timestamp, authority: .init(analysis: nil), filter: .init(matrixMinimumReads: 5))
        XCTAssertFalse(snapshot.hasHaplotypeContent)
        XCTAssertTrue(snapshot.calls.isEmpty)
        XCTAssertTrue(snapshot.allMatrix.loci.isEmpty)
        let exported = try await export(snapshot, to: output, replay: cliURL())
        try FileManager.default.removeItem(at: source)
        let replayed = root.appendingPathComponent("replayed-after-source-removal.xlsx")
        XCTAssertEqual(try run(["/bin/sh", exported.replayScriptURL.path, replayed.path]), 0)
        XCTAssertGreaterThan(try Data(contentsOf: replayed).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try verifyReceipt(replayed.appendingPathExtension("provenance.json"), output: replayed, expectedMinimumReads: "5")
        try runPython(#"""
import sys
from openpyxl import load_workbook
books=[load_workbook(path,data_only=False) for path in sys.argv[1:]]
for w in books:
    assert w.sheetnames==['Genotype Matrix - All','Genotype Matrix - Filtered','Export Metadata']
    assert not any(c.data_type=='f' for s in w for row in s for c in row)
    assert w['Genotype Matrix - All'].cell(2,4).value==11
    assert w['Genotype Matrix - Filtered'].cell(2,4).value==11
for left,right in zip(books[0],books[1]):
    assert (left.max_row,left.max_column)==(right.max_row,right.max_column)
    for lrow,rrow in zip(left.iter_rows(),right.iter_rows()):
        for lcell,rcell in zip(lrow,rrow):
            assert (lcell.value,lcell.data_type)==(rcell.value,rcell.data_type)
            assert (lcell.comment.text if lcell.comment else None)==(rcell.comment.text if rcell.comment else None)
            assert lcell.fill.fgColor.rgb==rcell.fill.fgColor.rgb
"""#, [output.path, replayed.path])
        print("TASK6_THREE_SHEET=\(output.path)")
        print("TASK6_THREE_RANGES=Genotype Matrix - All!A1:D2;Genotype Matrix - Filtered!A1:D2;Export Metadata!A1:B30")
    }

    func testFullLengthManualAndAnalyzedUnresolvedAreActualCallContent() async throws {
        let root = retainedDirectory("full-length")
        let output = root.appendingPathComponent("full-length-manual.xlsx")
        let analysis = GenotypeHaplotypeAnalysis(assayID: "legacy", definitionSetID: "legacy",
            definitionSetName: "Legacy", speciesName: "Fixture", generatedAt: timestamp,
            samples: [.init(sample: "ONT-S", calls: [.init(locus: "MHC-A", sourceLocus: "MHC-A",
                haplotype1: "Pipeline-A", haplotype2: "", status: .noHaplotype,
                matchedHaplotypes: [], observedGenotypeCount: 1, observedGenotypes: ["Mafa-A*100"])])])
        let result = GenotypeTestFixtures.makeResult(calls: [
            GenotypeTestFixtures.makeCall(sample: "ONT-S", genotype: "Mafa-A*100", reads: 10),
        ], kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue, haplotypeAnalysis: analysis)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.manualHaplotypeAssignments = [
            .init(sample: "ONT-S", locus: "MHC-A", slot: .h1, label: "Manual-A", colorTokenIndex: 1,
                  diagnosticAlleles: [], notes: "manual acceptance"),
            .init(sample: "ONT-S", locus: "MHC-A", slot: .h2, label: "-", colorTokenIndex: 2,
                  diagnosticAlleles: [], notes: "explicit absence"),
        ]
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp,
            authority: .init(analysis: analysis))
        let call = try XCTUnwrap(snapshot.calls.first)
        XCTAssertEqual(call.h1.effective, "Manual-A")
        XCTAssertEqual(call.h1.source, "analystOverride")
        XCTAssertEqual(call.h2.effective, "-")
        XCTAssertEqual(call.h2.status, "noHaplotype")
        XCTAssertTrue(snapshot.hasHaplotypeContent)
        _ = try await export(snapshot, to: output, replay: cliURL())
        try runPython(#"""
import sys
from openpyxl import load_workbook
w=load_workbook(sys.argv[1],data_only=False)
assert w.sheetnames==['Haplotype Calls','Genotype Matrix - All','Genotype Matrix - Filtered','Export Metadata']
assert w['Haplotype Calls']['D2'].value=='Manual-A'
assert w['Haplotype Calls']['E2'].value=='-'
assert w['Haplotype Calls']['F2'].value=='called'
assert w['Haplotype Calls']['G2'].value=='noHaplotype'
"""#, [output.path])
        print("TASK6_FULL_LENGTH=\(output.path)")
    }

    func testDefaultBandsUseOnlyNativeCallOrderNotRawEvidenceOrder() throws {
        let nativeCallOrder = ["MHC-A", "MHC-B", "MHC-DR", "MHC-DQ", "MHC-DP"]
        let rawEvidenceOrder = ["MHC-F", "MHC-B", "MHC-A1", "MHC-DRB", "MHC-DQA", "MHC-DPB"]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq", definitionSetID: "literal-band-order",
            definitionSetName: "Literal band order", speciesName: "Fixture", generatedAt: timestamp,
            samples: [.init(sample: "S1", calls: nativeCallOrder.enumerated().map { index, locus in
                .init(locus: locus, sourceLocus: locus, haplotype1: "M\(index + 1)", haplotype2: "-",
                    status: .called, matchedHaplotypes: [], observedGenotypeCount: 0, observedGenotypes: [])
            })]
        )
        let result = GenotypeTestFixtures.makeResult(calls: [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-F*001", reads: 9),
        ], kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            haplotypeAnalysis: analysis, haplotypeDefinitionSetID: analysis.definitionSetID)

        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result,
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil,
            generatedAt: timestamp,
            authority: .init(analysis: analysis, locusDisplayOrder: rawEvidenceOrder))

        XCTAssertEqual(snapshot.allMatrix.loci, nativeCallOrder)
        XCTAssertEqual(snapshot.filteredMatrix.loci, nativeCallOrder)
        XCTAssertEqual(snapshot.allMatrix.rows.map(\.target.genotype), ["Mafa-F*001"])
    }

    func testConfiguredDisposableCohortRunsAgainstRawEvidence() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["LUNGFISH_EXCEL_QA_PROJECT"] == nil,
           environment["LUNGFISH_EXCEL_QA_BUNDLE"] == nil {
            throw XCTSkip("Private cohort acceptance requires both disposable QA paths")
        }
        let project = try XCTUnwrap(environment["LUNGFISH_EXCEL_QA_PROJECT"],
            "Configured private cohort acceptance requires LUNGFISH_EXCEL_QA_PROJECT")
        let bundle = try XCTUnwrap(environment["LUNGFISH_EXCEL_QA_BUNDLE"],
            "Configured private cohort acceptance requires LUNGFISH_EXCEL_QA_BUNDLE")
        try await GenotypeThreeSheetCohortAcceptance.run(
            projectURL: URL(fileURLWithPath: project), bundleURL: URL(fileURLWithPath: bundle))
    }

    private func export(_ snapshot: GenotypeWorkbookPresentation.Snapshot, to output: URL, replay: URL) async throws -> GenotypeExcelExportService.ExportResult {
        try await GenotypeExcelExportService(pythonExecutableURL: pythonURL(), replayExecutableURL: replay).export(
            snapshot: snapshot, outputURL: output,
            provenance: .init(workflowName: "task6.synthetic.acceptance", toolVersion: "task6-test",
                argv: [replay.path, "genotype", "export-xlsx"],
                options: ["matrixMinimumReads": snapshot.metadata.first { $0.first == "Minimum reads" }?[1] ?? ""],
                defaults: ["filteredEvidenceRowPolicy": GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy],
                runtimeContext: ["environment": "managed-openpyxl"]))
    }

    private func verifyMiSeqArtifact(_ workbook: URL, snapshotURL: URL) throws {
        try runPython(GenotypeFullCurrentEvidenceOracle.pythonScript + "\n" + #"""
import json,sys
from openpyxl import load_workbook
snapshot=json.load(open(sys.argv[2])); w=load_workbook(sys.argv[1],data_only=False)
oracle={'samples':['Visible-A','Visible-B','Hidden-C'],'rows':[
 {'locus':'MHC-A','genotype':'Mafa-A*001','support':{'Visible-A':9}},
 {'locus':'MHC-A','genotype':'Mafa-A*002','support':{'Visible-A':4}},
 {'locus':'MHC-A','genotype':'Mafa-A*003','support':{'Visible-A':8,'Visible-B':0}},
 {'locus':'MHC-A','genotype':'Mafa-A*004','support':{'Hidden-C':12}},
 {'locus':'MHC-A','genotype':'Mafa-A*005','support':{'Visible-A':0}},
 {'locus':'MHC-A','genotype':'Mafa-A*006','support':{}}]}
summary=verify_full_current_evidence(oracle,snapshot,w)
assert summary=={'rows':6,'samples':3,'evidenceCells':18,'knownCells':6,'unknownCells':12},summary
assert w.sheetnames==['Haplotype Calls','Genotype Matrix - All','Genotype Matrix - Filtered','Export Metadata']
assert [s['name'] for s in snapshot['filteredMatrix']['samples']]==['Visible-A','Visible-B']
assert {(r['target']['genotype'],r['target'].get('stableClusterID')) for r in snapshot['filteredMatrix']['rows']}=={
 ('Mafa-A*001',None),('Mafa-A*003',None)}
mixed=next(r for r in snapshot['filteredMatrix']['rows'] if r['target']['genotype']=='Mafa-A*003')
assert mixed['cells'][1]['displayValue']==0 and mixed['cells'][1]['rawSupport']==0
assert mixed['cells'][1]['review']=='false-negative' and mixed['cells'][1]['comment']=='attested zero FN note'
positive=next(r for r in snapshot['filteredMatrix']['rows'] if r['target']['genotype']=='Mafa-A*001')['cells'][0]
assert positive['review']=='false-positive' and positive['comment']=='positive FP note'
filtered=w['Genotype Matrix - Filtered']
assert (filtered.max_row,filtered.max_column)==(6,5)
assert [filtered.cell(4,column).value for column in range(4,6)]==['Visible-A','Visible-B']
assert [[filtered.cell(row,column).value for column in range(1,4)] for row in [5,6]]==[
 [_filtered_stable_id({'locus':'MHC-A','genotype':'Mafa-A*001'}),'MHC-A','Mafa-A*001'],
 [_filtered_stable_id({'locus':'MHC-A','genotype':'Mafa-A*003'}),'MHC-A','Mafa-A*003']]
fp=filtered.cell(5,4); fn=filtered.cell(6,5)
assert fp.value==9 and type(fp.value) is int and fp.number_format=='"["0"]"'
assert fp.font.italic and fp.font.color.rgb[-6:]=='767676'
assert fp.comment.text=='Evidence: display=9, raw support=9\nCurrent comment: "positive FP note"\nCurrent review: "false-positive"'
assert fn.value==0 and type(fn.value) is int and fn.number_format=='0;-0;"FN"'
assert fn.font.bold and fn.fill.fgColor.rgb[-6:]=='FFF2CC'
assert all(side.style=='mediumDashed' and side.color.rgb[-6:]=='C65911'
           for side in [fn.border.left,fn.border.right,fn.border.top,fn.border.bottom])
assert fn.comment.text=='Evidence: display=0, raw support=0\nCurrent comment: "attested zero FN note"\nCurrent review: "false-negative"'
assert not any(c.data_type=='f' for s in w for row in s for c in row)
for matrix in ['Genotype Matrix - All','Genotype Matrix - Filtered']:
    sheet=w[matrix]
    assert sheet.cell(2,4).value=='M1A' and sheet.cell(3,4).value=='M1A'
"""#, [workbook.path, snapshotURL.path])
    }

    private func verifyNativeFilteredArtifact(
        _ workbook: URL,
        snapshotURL: URL,
        witnessURL: URL
    ) throws {
        try runPython(GenotypeFullCurrentEvidenceOracle.pythonScript + "\n" + #"""
import json,sys
from openpyxl import load_workbook
snapshot=json.load(open(sys.argv[2])); native=json.load(open(sys.argv[3]))
oracle={'samples':['Visible-A','Visible-B','Hidden-C','Visible-ManualHidden'],'rows':[
 {'locus':'MHC-A','genotype':'Mafa-A*001','support':{'Visible-A':9}},
 {'locus':'MHC-A','genotype':'Mafa-A*002','support':{'Visible-A':4}},
 {'locus':'MHC-A','genotype':'Mafa-A*003','support':{'Visible-A':8,'Visible-B':0}},
 {'locus':'MHC-A','genotype':'Mafa-A*004','support':{'Hidden-C':12}},
 {'locus':'MHC-A','genotype':'Mafa-A*005','support':{'Visible-A':0}},
 {'locus':'MHC-A','genotype':'Mafa-A*006','support':{}},
 {'locus':'MHC-A','genotype':'Mafa-A*007','support':{'Visible-ManualHidden':10}}]}
summary=verify_filtered_current_view(oracle,native,snapshot,load_workbook(sys.argv[1],data_only=False))
assert summary=={'rows':2,'samples':2,'cells':4},summary
assert native['rows'][0]['cells'][0]['displayText']=='[9]'
assert native['rows'][1]['cells'][1]['displayText']=='—'
"""#, [workbook.path, snapshotURL.path, witnessURL.path])
    }

    private func verifyReceipt(_ receipt: URL, output: URL, expectedMinimumReads: String?) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertEqual(object["exitStatus"] as? Int, 0)
        XCTAssertNotNil(object["wallTimeSeconds"] as? Double)
        XCTAssertNotNil(object["executedArgv"] as? [String])
        XCTAssertNotNil(object["durableReplayArgv"] as? [String])
        XCTAssertNotNil(object["runtime"] as? [String: Any])
        if let expectedMinimumReads {
            let options = try XCTUnwrap(object["options"] as? [String: String])
            let requestPath: String
            if let directMinimum = options["matrixMinimumReads"] {
                XCTAssertEqual(directMinimum, expectedMinimumReads)
                XCTAssertEqual((object["resolvedDefaults"] as? [String: String])?["filteredEvidenceRowPolicy"],
                    GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy)
                requestPath = try XCTUnwrap((object["request"] as? [String: Any])?["path"] as? String,
                    "Direct receipt must bind its captured provenance request")
            } else {
                XCTAssertEqual((object["resolvedDefaults"] as? [String: String])?["force"], "false")
                requestPath = try XCTUnwrap(options["provenanceRequest"],
                    "Replay receipt must retain the captured provenance-request path")
            }
            let request = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: requestPath))) as? [String: Any])
            XCTAssertEqual((request["options"] as? [String: String])?["matrixMinimumReads"], expectedMinimumReads)
            XCTAssertEqual((request["defaults"] as? [String: String])?["filteredEvidenceRowPolicy"],
                GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy)
        }
        XCTAssertEqual((object["output"] as? [String: Any])?["sha256"] as? String, try ProvenanceFileHasher.sha256(of: output))
        XCTAssertEqual((object["output"] as? [String: Any])?["sizeBytes"] as? Int, try Data(contentsOf: output).count)
    }

    private func retainedDirectory(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LGE-Task6-\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pythonURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3")
    }

    private func cliURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/lungfish-cli")
    }

    private func runPython(_ script: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = pythonURL(); process.arguments = ["-c", script] + arguments
        let error = Pipe(); process.standardError = error
        try process.run(); let stderr = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stderr, as: UTF8.self))
    }

    private func run(_ arguments: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: arguments[0]); process.arguments = Array(arguments.dropFirst())
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus != 0 { print(String(decoding: bytes, as: UTF8.self)) }
        return process.terminationStatus
    }
}

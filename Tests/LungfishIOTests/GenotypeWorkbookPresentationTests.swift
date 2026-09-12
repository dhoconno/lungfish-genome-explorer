import Foundation
import XCTest
@testable import LungfishIO

final class GenotypeWorkbookPresentationTests: XCTestCase {
    func testPresentationAllowsNativeSelectionAndShowsAdjacentColoredCallsAndReviews() throws {
        for role in ["editable-current", "filtered-snapshot"] {
            let result = try render(role: role, mutation: "acceptance-styles")
            XCTAssertTrue(result.selectionAllowed)
            XCTAssertTrue(result.adjacentCalls)
            XCTAssertTrue(result.callColorParity)
            XCTAssertTrue(result.displayLabelParity)
            XCTAssertTrue(result.readableLayout)
            XCTAssertTrue(result.singleScope)
            XCTAssertTrue(result.reviewStyles)
            XCTAssertTrue(result.analystStyles)
            XCTAssertTrue(result.nativeDifferentialFill)
        }
    }
    func testRendererCreatesThreeSheetEditableWorkbookWithTrustedManifestAndCaches() throws {
        let result = try render(role: "editable-current")
        XCTAssertEqual(result.sheetNames, ["Genotype Matrix", "Haplotype Calls", "Export Metadata"])
        XCTAssertEqual(result.cachedDRSlots, ["M4DR", "M4DR"])
        XCTAssertEqual(result.matrixEvidence, [nil, 5])
        XCTAssertEqual(result.zeroRawSupport, 0)
        XCTAssertNil(result.unknownRawSupport)
        XCTAssertEqual(result.formulaDRSlots, ["=IF('Haplotype Calls'!D2=\"\",\"\",'Haplotype Calls'!D2)", "=IF('Haplotype Calls'!E2=\"\",\"\",'Haplotype Calls'!E2)"])
        XCTAssertEqual(result.manifestRole, "editable-current")
        XCTAssertEqual(result.manifestSheetOrder, result.sheetNames)
        XCTAssertEqual(result.noteGrammar, 2)
        XCTAssertEqual(result.callTargetCount, 10)
        XCTAssertEqual(result.noteBlockCount, 3)
        XCTAssertTrue(result.noExtraSheets)
        XCTAssertTrue(result.fullCalculation)
        XCTAssertTrue(result.matrixFrozenAndFiltered)
        XCTAssertTrue(result.customColorApplied)
        XCTAssertTrue(result.allColorRulesApplied)
        XCTAssertTrue(result.callsEditable)
        XCTAssertTrue(result.snapshotFieldsLocked)
        XCTAssertTrue(result.specialTextLiteral)
    }

    func testFilteredRoleHasParityButLocksEditing() throws {
        let editable = try render(role: "editable-current")
        let filtered = try render(role: "filtered-snapshot")
        XCTAssertEqual(filtered.sheetNames, editable.sheetNames)
        XCTAssertEqual(filtered.callTargetCount, editable.callTargetCount)
        XCTAssertFalse(filtered.callsEditable)
        XCTAssertEqual(filtered.manifestRole, "filtered-snapshot")
        XCTAssertTrue(filtered.roleGuidance)
        XCTAssertTrue(filtered.metadataFits)
    }

    func testSparseCallsAndEvidenceOnlyLocusRemainValid() throws {
        let result = try render(role: "editable-current", mutation: "sparse-valid")
        XCTAssertEqual(result.callTargetCount, 9)
        XCTAssertEqual(result.sheetNames, ["Genotype Matrix", "Haplotype Calls", "Export Metadata"])
        XCTAssertEqual(result.clusterIdentity, "cluster-F")
        XCTAssertTrue(result.hasUnannotatedRowTarget)
        XCTAssertTrue(result.hasUnannotatedSampleTarget)
        XCTAssertNil(result.sparseCachedSlot)
    }

    func testBaselineUnavailableCallSlotsStayLocked() throws {
        let result = try render(role: "editable-current", mutation: "baseline-unavailable")
        XCTAssertFalse(result.callsEditable)
    }

    func testCurrentWithoutCallEditingKeepsCurrentNoteGuidance() throws {
        let result = try render(role: "editable-current", mutation: "unsupported-calls")
        XCTAssertFalse(result.callsEditable)
        XCTAssertTrue(result.roleGuidance)
    }

    func testFormulaCachesAndPayloadTextRemainLiteral() throws {
        let result = try render(role: "editable-current", mutation: "literal-edge-values")
        XCTAssertEqual(result.cachedDQSlots, ["Slash\\1<&\"", nil])
        XCTAssertTrue(result.explicitEmptyFormulaCache)
        XCTAssertTrue(result.literalPayloadHeadings)
        XCTAssertTrue(result.literalMetadata)
    }

    func testRendererRejectsInvalidRostersAndTargets() throws {
        for mutation in ["duplicate-sample", "duplicate-row-id", "duplicate-call-id", "duplicate-call-target", "duplicate-cell", "missing-cell", "unknown-call-sample", "negative-support", "inconsistent-baseline"] {
            XCTAssertThrowsError(try render(role: "editable-current", mutation: mutation), mutation)
        }
    }

    private struct Result: Decodable {
        let sheetNames: [String]
        let cachedDRSlots: [String?]
        let matrixEvidence: [Int?]
        let zeroRawSupport: Int?
        let unknownRawSupport: Int?
        let formulaDRSlots: [String]
        let manifestRole: String
        let manifestSheetOrder: [String]
        let noteGrammar: Int
        let callTargetCount: Int
        let noteBlockCount: Int
        let noExtraSheets: Bool
        let fullCalculation: Bool
        let matrixFrozenAndFiltered: Bool
        let customColorApplied: Bool
        let allColorRulesApplied: Bool
        let callsEditable: Bool
        let snapshotFieldsLocked: Bool
        let specialTextLiteral: Bool
        let clusterIdentity: String?
        let hasUnannotatedRowTarget: Bool
        let hasUnannotatedSampleTarget: Bool
        let sparseCachedSlot: String?
        let cachedDQSlots: [String?]
        let explicitEmptyFormulaCache: Bool
        let literalPayloadHeadings: Bool
        let literalMetadata: Bool
        let selectionAllowed: Bool
        let adjacentCalls: Bool
        let callColorParity: Bool
        let displayLabelParity: Bool
        let readableLayout: Bool
        let singleScope: Bool
        let reviewStyles: Bool
        let analystStyles: Bool
        let nativeDifferentialFill: Bool
        let roleGuidance: Bool
        let metadataFits: Bool
    }

    private func render(role: String, mutation: String? = nil) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = fixture(role: role, mutation: mutation)
        let payloadData = try JSONEncoder().encode(payload)
        let payloadURL = directory.appendingPathComponent("payload.json")
        let workbookURL = directory.appendingPathComponent("workbook.xlsx")
        let resultURL = directory.appendingPathComponent("result.json")
        try payloadData.write(to: payloadURL)
        let runner = #"""
import json, sys
from openpyxl import load_workbook
"""# + "\n" + GenotypeWorkbookPresentation.pythonScript + "\n" + #"""
p=json.load(open(sys.argv[1])); out=sys.argv[2]
if sys.argv[4]=='acceptance-styles':
    p['rows'][0]['style']={'fillHex':'#123456','textHex':'#ABCDEF','borderHex':'#654321','isBold':True,'isItalic':True}
    p['rows'][0]['cells'][0]['style']={'fillHex':None,'textHex':'#112233','borderHex':'#223344','isBold':False,'isItalic':False}
    p['rows'][1]['cells'][0]['review']='false-positive'
    p['rows'][2]['cells'][0]['displayValue']=0
    p['rows'][2]['cells'][0]['review']='false-negative'
m=render_three_sheet_workbook(p,out); notes=list(m['noteTargets'].values())
with zipfile.ZipFile(out) as z: sheet_xml=z.read('xl/worksheets/sheet1.xml').decode('utf-8')
wf=load_workbook(out,data_only=False); wc=load_workbook(out,data_only=True)
gmf=wf['Genotype Matrix']; gmc=wc['Genotype Matrix']; calls=wf['Haplotype Calls']
target=m['callTargets']['call-S1-DR']; h1=calls[target['h1']['valueCell']]; h2=calls[target['h2']['valueCell']]
fp=gmf[next(x['cell'] for x in notes if x['target'].get('rowID')=='row-DQ' and x['target'].get('sampleID')=='S1')]
fn=gmf[next(x['cell'] for x in notes if x['target'].get('rowID')=='row-A' and x['target'].get('sampleID')=='S1')]
styled=gmf['D13']; label=gmf['C13']
def rgb(color): return color.rgb[-6:] if color and color.type=='rgb' else None
result={'sheetNames':wf.sheetnames,'cachedDRSlots':[wc['Genotype Matrix']['D2'].value,wc['Genotype Matrix']['D3'].value],
'matrixEvidence':[gmc['D17'].value,gmc['E17'].value], 'zeroRawSupport':next(x['rawSupport'] for x in notes if x['target'].get('rowID')=='row-A' and x['target'].get('sampleID')=='S1'),
'unknownRawSupport':next(x['rawSupport'] for x in notes if x['target'].get('rowID')=='row-C' and x['target'].get('sampleID')=='S1'), 'formulaDRSlots':[gmf['D2'].value,gmf['D3'].value],
'manifestRole':m['role'],'manifestSheetOrder':m['sheetOrder'],'noteGrammar':m['allowedNoteGrammarVersion'],
'callTargetCount':len(m['callTargets']),'noteBlockCount':sum(1 for x in m['noteTargets'].values() if '[LGE Edit v2]' in x['generatedText']),
'noExtraSheets':len(wf.worksheets)==3,'fullCalculation':wf.calculation.fullCalcOnLoad and wf.calculation.forceFullCalc,
'matrixFrozenAndFiltered':gmf.freeze_panes=='D12' and gmf.auto_filter.ref=='B12:E17',
'customColorApplied':gmf['D2'].fill.fgColor.rgb.endswith('123456'),
'allColorRulesApplied':sum(len(x) for x in gmf.conditional_formatting._cf_rules.values())>=24 and 'OtherDR' in str(gmf.conditional_formatting._cf_rules) and 'AND(' in str(gmf.conditional_formatting._cf_rules),
'callsEditable':not calls['D2'].protection.locked,'snapshotFieldsLocked':calls['H2'].protection.locked,
'specialTextLiteral':calls['N2'].data_type=='s' and calls['N2'].value.startswith('=literal'),
'clusterIdentity':next((x['target'].get('stableClusterID') for x in notes if x['target'].get('rowID')=='row-F' and x['target'].get('sampleID')=='S1'),None),
'hasUnannotatedRowTarget':'row:row-C' in m['noteTargets'],'hasUnannotatedSampleTarget':'sample:S2' in m['noteTargets'],
'sparseCachedSlot':wc['Genotype Matrix']['E10'].value,'cachedDQSlots':[wc['Genotype Matrix']['E4'].value,wc['Genotype Matrix']['E5'].value],
'explicitEmptyFormulaCache':re.search(r'<c r="E5"[^>]*t="str"><f>.*?</f><v></v></c>',sheet_xml) is not None,
'literalPayloadHeadings':gmf['E1'].data_type=='s' and gmf['E12'].data_type=='s',
'literalMetadata':all(c.data_type=='s' for row in wf['Export Metadata'] for c in row if isinstance(c.value,str)),
'selectionAllowed':all(not ws.protection.selectLockedCells and not ws.protection.selectUnlockedCells and not ws.protection.autoFilter for ws in [gmf,calls]),
'adjacentCalls':h2.column==h1.column+1,
'callColorParity':rgb(h1.fill.fgColor)==rgb(gmf['D2'].fill.fgColor)=='123456' and rgb(h2.font.color)=='FFFFFF' and len(calls.conditional_formatting)>0,
'displayLabelParity':calls['B2'].value==gmf['D1'].value,
'readableLayout':gmf.column_dimensions['C'].width>=60 and gmf.column_dimensions['D'].width>=18 and gmf['C13'].alignment.wrap_text and calls['D1'].alignment.wrap_text and gmf.row_dimensions[13].height<=30,
'singleScope':sum(row[0].value=='Scope' for row in wf['Export Metadata'])==1,
'roleGuidance':('Filtered snapshot' not in dict(wf['Export Metadata'].values)['Editing'] and 'Apply edits' in dict(wf['Export Metadata'].values)) if p['role']=='editable-current' else not any('[LGE Edit v2]' in str(c.value) or 'Save the workbook' in str(c.value) for row in wf['Export Metadata'] for c in row),
'metadataFits':wf['Export Metadata'].row_dimensions[2].height>=16*((len(str(wf['Export Metadata']['B2'].value))+89)//90),
'nativeDifferentialFill':all(rule.dxf.fill.fgColor.rgb==rule.dxf.fill.bgColor.rgb and rule.dxf.fill.fgColor.rgb.startswith('FF') for ws in [gmf,calls] for rules in ws.conditional_formatting._cf_rules.values() for rule in rules),
'reviewStyles':fp.value==1 and fp.data_type=='n' and fp.number_format=='"["0"]"' and fp.font.italic and rgb(fp.font.color)=='767676' and fn.value==0 and fn.data_type=='n' and '"FN"' in fn.number_format and fn.font.bold and rgb(fn.fill.fgColor)=='FFF2CC' and rgb(fn.font.color)=='7F6000' and all(getattr(fn.border,s).style=='mediumDashed' and rgb(getattr(fn.border,s).color)=='C65911' for s in ['left','right','top','bottom']),
'analystStyles':rgb(label.fill.fgColor)=='123456' and label.font.bold and label.font.italic and rgb(label.font.color)=='ABCDEF' and rgb(label.border.left.color)=='654321' and styled.fill.patternType is None and not styled.font.bold and not styled.font.italic and rgb(styled.font.color)=='112233' and rgb(styled.border.left.color)=='223344'}
json.dump(result,open(sys.argv[3],'w'))
"""#
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let process = Process(); process.executableURL = python
        process.arguments = ["-c", runner, payloadURL.path, workbookURL.path, resultURL.path, mutation ?? ""]
        let errorPipe = Pipe(); process.standardError = errorPipe
        try process.run(); process.waitUntilExit()
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw NSError(domain: "renderer", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: error]) }
        return try JSONDecoder().decode(Result.self, from: Data(contentsOf: resultURL))
    }

    private func fixture(role: String, mutation: String?) -> GenotypeWorkbookPresentation.Payload {
        var samples = [
            GenotypeWorkbookPresentation.Sample(id: "S1", name: "Alpha", comment: "=sample"),
            GenotypeWorkbookPresentation.Sample(id: "S2", name: "Beta", comment: nil)
        ]
        let loci = ["DR", "DQ", "A", "B", "C"]
        var rows = loci.map { locus in
            GenotypeWorkbookPresentation.Row(id: "row-\(locus)", target: .init(kind: "row", locus: locus, genotype: "G-\(locus)", stableClusterID: nil), displayName: "G-\(locus)", comment: locus == "DR" ? "row note" : nil, fillHex: nil, cells: [
                .init(sampleID: "S1", displayValue: locus == "C" ? nil : 1, rawSupport: locus == "A" ? 0 : (locus == "C" ? nil : 1), reviewEligible: true, fillHex: nil, comment: locus == "A" ? "cell comment" : nil, review: nil),
                .init(sampleID: "S2", displayValue: locus == "C" ? 5 : 2, rawSupport: locus == "C" ? 5 : 2, reviewEligible: true, fillHex: nil, comment: nil, review: nil)
            ])
        }
        var calls = [
            ("DR", "M4DR", "M4DR"), ("DQ", "M2DQ", "M1DQ"), ("A", "M1A", ""), ("B", "M1B", "M2B"), ("C", "M1C", "M2C")
        ].flatMap { locus, h1, h2 in samples.map { sample in
            GenotypeWorkbookPresentation.Call(id: "call-\(sample.id)-\(locus)", sampleID: sample.id, locus: locus,
                h1: .init(effective: h1, pipeline: h1, baselineAvailable: true, status: "ok", source: "pipeline"),
                h2: .init(effective: h2, pipeline: h2, baselineAvailable: true, status: h2.isEmpty ? "unresolved" : "ok", source: locus == "DQ" ? "manual" : "pipeline"),
                comment: sample.id == "S1" && locus == "DR" ? "=literal <&> \"quoted\"" : nil)
        }}
        switch mutation {
        case "duplicate-sample": samples.append(samples[0])
        case "duplicate-row-id": rows.append(rows[0])
        case "duplicate-call-id": calls.append(calls[0])
        case "duplicate-call-target": calls.append(.init(id: "other-id", sampleID: calls[0].sampleID, locus: calls[0].locus, h1: calls[0].h1, h2: calls[0].h2, comment: nil))
        case "duplicate-cell": rows[0].cells.append(rows[0].cells[0])
        case "missing-cell": rows[0].cells.removeLast()
        case "unknown-call-sample": calls[0] = .init(id: calls[0].id, sampleID: "missing", locus: calls[0].locus, h1: calls[0].h1, h2: calls[0].h2, comment: calls[0].comment)
        case "negative-support": rows[0].cells[0] = .init(sampleID: "S1", displayValue: 1, rawSupport: -1, reviewEligible: true, fillHex: nil, comment: nil, review: nil)
        case "inconsistent-baseline": calls[0] = .init(id: calls[0].id, sampleID: calls[0].sampleID, locus: calls[0].locus, h1: .init(effective: "M4DR", pipeline: nil, baselineAvailable: true, status: "ok", source: "pipeline"), h2: calls[0].h2, comment: calls[0].comment)
        case "sparse-valid":
            rows.append(.init(id: "row-F", target: .init(kind: "row", locus: "MHC-F", genotype: "G-F", stableClusterID: "cluster-F"), displayName: "G-F", comment: nil, fillHex: nil, cells: [
                .init(sampleID: "S1", displayValue: 3, rawSupport: 3, reviewEligible: true, fillHex: nil, comment: nil, review: nil),
                .init(sampleID: "S2", displayValue: nil, rawSupport: nil, reviewEligible: false, fillHex: nil, comment: nil, review: nil)
            ]))
            calls.removeAll { $0.sampleID == "S2" && $0.locus == "C" }
        case "baseline-unavailable":
            calls[0] = .init(id: calls[0].id, sampleID: calls[0].sampleID, locus: calls[0].locus,
                h1: .init(effective: "legacy", pipeline: nil, baselineAvailable: false, status: "legacy", source: "manual"),
                h2: calls[0].h2, comment: calls[0].comment)
        case "literal-edge-values":
            samples[1] = .init(id: "S2", name: "=1+1", comment: nil)
            if let index = calls.firstIndex(where: { $0.sampleID == "S2" && $0.locus == "DQ" }) {
                calls[index] = .init(id: calls[index].id, sampleID: "S2", locus: "DQ",
                    h1: .init(effective: "Slash\\1<&\"", pipeline: "Slash\\1<&\"", baselineAvailable: true, status: "ok", source: "pipeline"),
                    h2: .init(effective: "", pipeline: "", baselineAvailable: true, status: "unresolved", source: "pipeline"), comment: nil)
            }
        default: break
        }
        return .init(schemaVersion: 2, role: role, sourceRevision: ["sha256": "abc"], samples: samples, loci: loci, rows: rows, calls: calls,
            colors: [
                .init(locus: "DR", call: "M4DR", fillHex: "#123456", fontHex: "#FFFFFF"),
                .init(locus: "DR", call: "OtherDR", fillHex: "#654321", fontHex: "#FFFFFF"),
                .init(locus: "A", call: "M1A", fillHex: "#112233", fontHex: "#FFFFFF"),
                .init(locus: "A", call: "OtherA", fillHex: "#332211", fontHex: "#FFFFFF")
            ], metadata: [["Scope", "=All evidence"]], callEditingSupported: role == "editable-current" && mutation != "unsupported-calls")
    }
}

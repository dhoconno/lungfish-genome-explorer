import Foundation
import XCTest
@testable import LungfishIO

final class GenotypeWorkbookSnapshotTests: XCTestCase {
    func testRendererWritesLiteralAllAndFilteredEvidenceFromOneSnapshot() throws {
        let result = try render(snapshot: fixture())

        XCTAssertEqual(result.sheetNames, [
            "Haplotype Calls",
            "Genotype Matrix - All",
            "Genotype Matrix - Filtered",
            "Export Metadata",
        ])
        XCTAssertEqual(result.allEvidence, [1, 5])
        XCTAssertEqual(result.filteredEvidence, [nil, 5])
        XCTAssertEqual(result.allCalls, ["M4A", "M4A", "M1A", "M3A"])
        XCTAssertEqual(result.filteredCalls, result.allCalls)
        XCTAssertEqual(result.callValues, result.allCalls)
        XCTAssertEqual(result.m4aFills, ["112233", "112233", "112233"])
        XCTAssertFalse(result.hasFormulaCells)
        XCTAssertFalse(result.hasFormulaXML)
        XCTAssertFalse(result.hasDataValidations)
        XCTAssertFalse(result.hasImportColumns)
        XCTAssertEqual(result.summarySchemaVersion, 3)
        XCTAssertEqual(result.summarySheets, [
            "Haplotype Calls",
            "Genotype Matrix - All",
            "Genotype Matrix - Filtered",
            "Export Metadata",
        ])
        XCTAssertEqual(result.summaryKeys, ["schemaVersion", "sheets"])
        XCTAssertEqual(result.summarySheetKeys, ["cellCount", "name", "rowCount"])
        XCTAssertTrue(result.readableLayout)
    }

    func testHaplotypeCapabilityControlsSheetsAndBandsRatherThanPlaceholderCount() throws {
        let absent = try render(snapshot: fixture(), mutation: "absent-content")
        XCTAssertEqual(absent.sheetNames, [
            "Genotype Matrix - All",
            "Genotype Matrix - Filtered",
            "Export Metadata",
        ])
        XCTAssertEqual(absent.firstAllHeader, "S1")
        XCTAssertEqual(absent.firstAllEvidence, 1)

        let unresolved = try render(snapshot: fixture(), mutation: "analyzed-unresolved")
        XCTAssertEqual(unresolved.sheetNames.count, 4)
        XCTAssertEqual(unresolved.callStatuses, ["unresolved", "error"])

        let manual = try render(snapshot: fixture(), mutation: "manual-only")
        XCTAssertEqual(manual.sheetNames.count, 4)
        XCTAssertEqual(manual.callValues.prefix(2), ["Manual-A1", "Manual-A2"])
    }

    func testSparseAndEmptyFilteredAxesStaySparse() throws {
        let sparse = try render(snapshot: fixture(), mutation: "sparse-filtered")
        XCTAssertEqual(sparse.sparseFilteredValues, ["S2", "M4A", "5"])

        let empty = try render(snapshot: fixture(), mutation: "empty-filtered")
        XCTAssertEqual(empty.filteredShape, [1, 3])
        XCTAssertEqual(empty.filteredHeaderValues, ["Stable ID", "Locus", "Allele"])
    }

    func testRendererPreservesAnnotationsStableIdentitiesStylesAndLiteralText() throws {
        let result = try render(snapshot: fixture(), mutation: "annotations-and-literals")

        XCTAssertTrue(result.reviewStyles)
        XCTAssertTrue(result.invalidReviewsWithheld)
        XCTAssertTrue(result.explicitStyleClearing)
        XCTAssertTrue(result.literalText)
        XCTAssertTrue(result.generatedComments)
        XCTAssertTrue(result.readOnlyComments)
        XCTAssertEqual(result.stableRowIDs, ["row-M4A", "row-zero", "candidate-alt-id"])
        XCTAssertEqual(result.duplicateLabels, ["M4A", "M4A"])
    }

    func testRendererRejectsInvalidSnapshotsBeforeSaving() throws {
        let mutations = [
            "duplicate-sample", "duplicate-locus", "duplicate-row", "duplicate-cell", "missing-cell",
            "unknown-filtered-sample", "unknown-filtered-row", "inconsistent-filtered-row", "inconsistent-filtered-raw",
            "duplicate-call-id", "duplicate-call-target", "unknown-call-sample", "unknown-call-locus",
            "negative-raw", "negative-display", "inconsistent-baseline", "invalid-slot-types",
            "invalid-style-types", "invalid-metadata", "invalid-source-revision", "invalid-generated-at",
        ]
        for mutation in mutations {
            let failure = try validationFailure(snapshot: fixture(), mutation: mutation)
            XCTAssertNotNil(failure.error, mutation)
            XCTAssertTrue(failure.error?.contains("invalid snapshot") == true, "\(mutation): \(failure.error ?? "missing error")")
            XCTAssertFalse(failure.outputExists, mutation)
        }
    }

    private struct RenderResult: Decodable {
        let sheetNames: [String]
        let allEvidence: [Int?]
        let filteredEvidence: [Int?]
        let allCalls: [String]
        let filteredCalls: [String]
        let callValues: [String]
        let m4aFills: [String?]
        let hasFormulaCells: Bool
        let hasFormulaXML: Bool
        let hasDataValidations: Bool
        let hasImportColumns: Bool
        let summarySchemaVersion: Int
        let summarySheets: [String]
        let summaryKeys: [String]
        let summarySheetKeys: [String]
        let readableLayout: Bool
        let firstAllHeader: String?
        let firstAllEvidence: Int?
        let callStatuses: [String]
        let sparseFilteredValues: [String]
        let filteredShape: [Int]
        let filteredHeaderValues: [String]
        let reviewStyles: Bool
        let invalidReviewsWithheld: Bool
        let explicitStyleClearing: Bool
        let literalText: Bool
        let generatedComments: Bool
        let readOnlyComments: Bool
        let stableRowIDs: [String]
        let duplicateLabels: [String]
    }

    private struct ValidationFailure: Decodable {
        let error: String?
        let outputExists: Bool
    }

    private func render(snapshot: GenotypeWorkbookPresentation.Snapshot, mutation: String = "") throws -> RenderResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payloadURL = directory.appendingPathComponent("payload.json")
        let workbookURL = directory.appendingPathComponent("workbook.xlsx")
        let resultURL = directory.appendingPathComponent("result.json")
        try JSONEncoder().encode(snapshot).write(to: payloadURL)

        let runner = #"""
import json, sys, zipfile
from openpyxl import load_workbook
"""# + "\n" + mutationPython + "\n" + GenotypeWorkbookPresentation.snapshotPythonScript + "\n" + #"""
p=json.load(open(sys.argv[1])); out=sys.argv[2]
mutate(p,sys.argv[4])
summary=render_genotype_snapshot(p,out)
wb=load_workbook(out,data_only=False)
all_ws=wb['Genotype Matrix - All']; filtered_ws=wb['Genotype Matrix - Filtered']; calls=wb['Haplotype Calls'] if 'Haplotype Calls' in wb.sheetnames else None
metadata=wb['Export Metadata']
filtered_shape=[filtered_ws.max_row,filtered_ws.max_column]
def fill_rgb(cell):
    color=cell.fill.fgColor
    return color.rgb[-6:] if color and color.type=='rgb' and color.rgb else None
def font_rgb(cell):
    color=cell.font.color
    return color.rgb[-6:] if color and color.type=='rgb' and color.rgb else None
def border_rgb(cell):
    color=cell.border.left.color
    return color.rgb[-6:] if color and color.type=='rgb' and color.rgb else None
def note(cell):
    return cell.comment.text if cell.comment else ''
with zipfile.ZipFile(out) as archive:
    formula_xml=any(b'<f' in archive.read(name) for name in archive.namelist() if name.startswith('xl/worksheets/sheet'))
headers=[cell.value for cell in calls[1]] if calls else []
annotation_case=sys.argv[4]=='annotations-and-literals'
if annotation_case:
    fp=all_ws['D5']; invalid_positive=all_ws['E5']; fn=all_ws['D6']; invalid_unknown=all_ws['E6']; invalid_name=all_ws['D7']
    review_styles=(fp.number_format=='"["0"]"' and fp.font.italic and font_rgb(fp)=='767676' and
        'FN' in fn.number_format and fn.font.bold and fill_rgb(fn)=='FFF2CC' and border_rgb(fn)=='C65911')
    invalid_reviews_withheld=(invalid_positive.number_format=='General' and invalid_unknown.number_format=='General' and
        invalid_name.number_format=='General' and 'Current review' not in note(invalid_positive) and
        'Current review' not in note(invalid_unknown) and 'Current review' not in note(invalid_name))
    explicit_style_clearing=(fill_rgb(all_ws['C5'])=='123456' and all_ws['C5'].font.bold and
        all_ws['D7'].fill.patternType is None and not all_ws['D7'].font.bold and not all_ws['D7'].font.italic and
        all_ws['D7'].font.color.type=='rgb' and all_ws['D7'].font.color.rgb.endswith('112233'))
    literal_text=(all_ws['D1'].value=='=sample formula-like' and all_ws['D1'].data_type=='s' and
        all_ws['D2'].value=='=call formula-like' and all_ws['D2'].data_type=='s' and
        calls['D2'].value=='=call formula-like' and calls['D2'].data_type=='s' and calls['L2'].data_type=='s')
    generated_comments=(note(all_ws['D1']).startswith('Sample comment: "=sample comment"') and
        'Evidence: display=1, raw support=1' in note(fp) and 'Current comment: "=cell comment"' in note(fp) and
        'Current review: "false-positive"' in note(fp) and '[LGE Edit' not in note(fp))
else:
    review_styles=invalid_reviews_withheld=explicit_style_clearing=literal_text=generated_comments=False
result={
    'sheetNames':wb.sheetnames,
    'allEvidence':[all_ws['D5'].value,all_ws['E5'].value],
    'filteredEvidence':[filtered_ws['D5'].value,filtered_ws['E5'].value],
    'allCalls':[all_ws['D2'].value,all_ws['D3'].value,all_ws['E2'].value,all_ws['E3'].value] if p['hasHaplotypeContent'] and p['allMatrix']['loci'] and sys.argv[4]!='analyzed-unresolved' else [],
    'filteredCalls':[filtered_ws['D2'].value,filtered_ws['D3'].value,filtered_ws['E2'].value,filtered_ws['E3'].value] if p['hasHaplotypeContent'] and p['filteredMatrix']['loci'] and sys.argv[4]!='analyzed-unresolved' else [],
    'callValues':[calls['D2'].value,calls['E2'].value,calls['D3'].value,calls['E3'].value] if calls and sys.argv[4]!='analyzed-unresolved' else [],
    'm4aFills':[fill_rgb(calls['D2']),fill_rgb(all_ws['D2']),fill_rgb(filtered_ws['D2'])] if calls else [],
    'hasFormulaCells':any(c.data_type=='f' for ws in wb for row in ws for c in row),
    'hasFormulaXML':formula_xml,
    'hasDataValidations':any(ws.data_validations.count for ws in wb),
    'hasImportColumns':any('action' in str(x).lower() or 'import' in str(x).lower() for x in headers),
    'summarySchemaVersion':summary['schemaVersion'],
    'summarySheets':[x['name'] for x in summary['sheets']],
    'summaryKeys':sorted(summary.keys()),
    'summarySheetKeys':sorted(summary['sheets'][0].keys()),
    'readableLayout':bool(all_ws.column_dimensions['C'].width>=60 and all_ws.column_dimensions['D'].width>=18 and
        all_ws['C5'].alignment.wrap_text and calls is not None and calls['D1'].alignment.wrap_text and
        all_ws.row_dimensions[5].height is not None and all_ws.row_dimensions[5].height<=30 and
        metadata.column_dimensions['B'].width>=90),
    'firstAllHeader':all_ws['D1'].value,
    'firstAllEvidence':all_ws['D2'].value if sys.argv[4]=='absent-content' else None,
    'callStatuses':[calls['F2'].value,calls['G2'].value] if calls else [],
    'sparseFilteredValues':[str(filtered_ws['D1'].value),str(filtered_ws['C2'].value),str(filtered_ws['D2'].value)] if sys.argv[4]=='sparse-filtered' else [],
    'filteredShape':filtered_shape,
    'filteredHeaderValues':[filtered_ws.cell(1,c).value for c in range(1,4)] if sys.argv[4]=='empty-filtered' else [],
    'reviewStyles':review_styles,
    'invalidReviewsWithheld':invalid_reviews_withheld,
    'explicitStyleClearing':explicit_style_clearing,
    'literalText':literal_text,
    'generatedComments':generated_comments,
    'readOnlyComments':annotation_case and all_ws.protection.sheet and all_ws.protection.objects,
    'stableRowIDs':[all_ws.cell(r,1).value for r in range(5,8)] if annotation_case else [],
    'duplicateLabels':[all_ws['C5'].value,all_ws['C7'].value] if annotation_case else [],
}
json.dump(result,open(sys.argv[3],'w'))
"""#
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", runner, payloadURL.path, workbookURL.path, resultURL.path, mutation]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "snapshot-renderer", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: error])
        }
        return try JSONDecoder().decode(RenderResult.self, from: Data(contentsOf: resultURL))
    }

    private func validationFailure(snapshot: GenotypeWorkbookPresentation.Snapshot, mutation: String) throws -> ValidationFailure {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloadURL = directory.appendingPathComponent("payload.json")
        let workbookURL = directory.appendingPathComponent("invalid.xlsx")
        let resultURL = directory.appendingPathComponent("result.json")
        try JSONEncoder().encode(snapshot).write(to: payloadURL)
        let runner = #"""
import json, os, sys
"""# + "\n" + mutationPython + "\n" + GenotypeWorkbookPresentation.snapshotPythonScript + "\n" + #"""
p=json.load(open(sys.argv[1])); mutate(p,sys.argv[4])
error=None
try:
    render_genotype_snapshot(p,sys.argv[2])
except Exception as exc:
    error=str(exc)
json.dump({'error':error,'outputExists':os.path.exists(sys.argv[2])},open(sys.argv[3],'w'))
"""#
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", runner, payloadURL.path, workbookURL.path, resultURL.path, mutation]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "snapshot-validation", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }
        return try JSONDecoder().decode(ValidationFailure.self, from: Data(contentsOf: resultURL))
    }

    private var mutationPython: String {
        #"""
def mutate(p,name):
    if name=='absent-content':
        p['hasHaplotypeContent']=False
    elif name=='analyzed-unresolved':
        p['calls'][0]['h1'].update(effective='',status='unresolved')
        p['calls'][0]['h2'].update(effective='',status='error')
    elif name=='manual-only':
        for index,slot in enumerate(('h1','h2'),1):
            p['calls'][0][slot].update(effective='Manual-A'+str(index),pipeline=None,baselineAvailable=False,status='ok',source='manual')
    elif name=='sparse-filtered':
        p['filteredMatrix']={'samples':[p['allMatrix']['samples'][1]],'loci':[], 'rows':[dict(p['allMatrix']['rows'][0],cells=[p['allMatrix']['rows'][0]['cells'][1]])]}
    elif name=='empty-filtered':
        p['filteredMatrix']={'samples':[],'loci':[],'rows':[]}
    elif name=='annotations-and-literals':
        p['allMatrix']['samples'][0].update(name='=sample formula-like',comment='=sample comment')
        p['filteredMatrix']['samples'][0].update(name='=sample formula-like',comment='=sample comment')
        for key in ('allMatrix','filteredMatrix'):
            row=p[key]['rows'][0]
            row.update(comment='=row comment',style={'fillHex':'#123456','textHex':'#FFFFFF','borderHex':None,'isBold':True,'isItalic':False})
            row['cells'][0].update(comment='=cell comment',review='false-positive')
            row['cells'][1].update(review='false-negative')
            zero={'style':None,'id':'row-zero','target':{'kind':'candidate','locus':'A','genotype':'ZeroA','stableClusterID':'candidate-zero'},'displayName':'ZeroA','comment':None,'fillHex':None,'cells':[
                {'style':None,'sampleID':'S1','displayValue':0,'rawSupport':0,'reviewEligible':True,'fillHex':None,'comment':None,'review':'false-negative'},
                {'style':None,'sampleID':'S2','displayValue':None,'rawSupport':None,'reviewEligible':True,'fillHex':None,'comment':None,'review':'false-negative'}]}
            duplicate={'style':None,'id':'candidate-alt-id','target':{'kind':'candidate','locus':'DQA','genotype':'M4A','stableClusterID':'candidate-alt'},'displayName':'M4A','comment':None,'fillHex':None,'cells':[
                {'style':{'fillHex':None,'textHex':'#112233','borderHex':None,'isBold':False,'isItalic':False},'sampleID':'S1','displayValue':2,'rawSupport':2,'reviewEligible':True,'fillHex':'#ABCDEF','comment':None,'review':'unknown-review'},
                {'style':None,'sampleID':'S2','displayValue':3,'rawSupport':3,'reviewEligible':True,'fillHex':None,'comment':None,'review':None}]}
            p[key]['rows'].extend([zero,duplicate])
        p['calls'][0]['h1']['effective']='=call formula-like'
        p['calls'][0]['comment']='=call comment'
    elif name=='duplicate-sample': p['allMatrix']['samples'].append(p['allMatrix']['samples'][0])
    elif name=='duplicate-locus': p['allMatrix']['loci'].append('A')
    elif name=='duplicate-row': p['allMatrix']['rows'].append(p['allMatrix']['rows'][0])
    elif name=='duplicate-cell': p['allMatrix']['rows'][0]['cells'].append(p['allMatrix']['rows'][0]['cells'][0])
    elif name=='missing-cell': p['allMatrix']['rows'][0]['cells'].pop()
    elif name=='unknown-filtered-sample': p['filteredMatrix']['samples'][0]['id']='missing'
    elif name=='unknown-filtered-row': p['filteredMatrix']['rows'][0]['id']='missing'
    elif name=='inconsistent-filtered-row': p['filteredMatrix']['rows'][0]['target']['stableClusterID']='changed'
    elif name=='inconsistent-filtered-raw': p['filteredMatrix']['rows'][0]['cells'][0]['rawSupport']=99
    elif name=='duplicate-call-id': p['calls'].append(dict(p['calls'][0],sampleID='S2'))
    elif name=='duplicate-call-target': p['calls'].append(dict(p['calls'][0],id='another-call'))
    elif name=='unknown-call-sample': p['calls'][0]['sampleID']='missing'
    elif name=='unknown-call-locus': p['calls'][0]['locus']='missing'
    elif name=='negative-raw': p['allMatrix']['rows'][0]['cells'][0]['rawSupport']=-1
    elif name=='negative-display': p['allMatrix']['rows'][0]['cells'][0]['displayValue']=-1
    elif name=='inconsistent-baseline': p['calls'][0]['h1']['pipeline']=None
    elif name=='invalid-slot-types': p['calls'][0]['h1']['status']=3
    elif name=='invalid-style-types': p['allMatrix']['rows'][0]['style']={'fillHex':None,'textHex':None,'borderHex':None,'isBold':'yes','isItalic':False}
    elif name=='invalid-metadata': p['metadata']=[['Scope',3]]
    elif name=='invalid-source-revision': p['sourceRevision']={'sha256':3}
    elif name=='invalid-generated-at': p['generatedAt']=3
"""#
    }

    private func fixture() -> GenotypeWorkbookPresentation.Snapshot {
        let samples = [
            GenotypeWorkbookPresentation.Sample(id: "S1", name: "S1", comment: nil),
            GenotypeWorkbookPresentation.Sample(id: "S2", name: "S2", comment: nil),
        ]
        let target = GenotypeWorkbookPresentation.Target(kind: "candidate", locus: "A", genotype: "M4A", stableClusterID: "candidate-4")
        let allRow = GenotypeWorkbookPresentation.Row(
            id: "row-M4A", target: target, displayName: "M4A", comment: nil, fillHex: nil,
            cells: [
                .init(sampleID: "S1", displayValue: 1, rawSupport: 1, reviewEligible: true, fillHex: nil, comment: nil, review: nil),
                .init(sampleID: "S2", displayValue: 5, rawSupport: 5, reviewEligible: true, fillHex: nil, comment: nil, review: nil),
            ]
        )
        let filteredRow = GenotypeWorkbookPresentation.Row(
            id: "row-M4A", target: target, displayName: "M4A", comment: nil, fillHex: nil,
            cells: [
                .init(sampleID: "S1", displayValue: nil, rawSupport: 1, reviewEligible: true, fillHex: nil, comment: nil, review: nil),
                .init(sampleID: "S2", displayValue: 5, rawSupport: 5, reviewEligible: true, fillHex: nil, comment: nil, review: nil),
            ]
        )
        let calls = [
            GenotypeWorkbookPresentation.Call(
                id: "call-S1-A", sampleID: "S1", locus: "A",
                h1: .init(effective: "M4A", pipeline: "M4A", baselineAvailable: true, status: "ok", source: "pipeline"),
                h2: .init(effective: "M4A", pipeline: "M4A", baselineAvailable: true, status: "ok", source: "pipeline"),
                comment: nil
            ),
            GenotypeWorkbookPresentation.Call(
                id: "call-S2-A", sampleID: "S2", locus: "A",
                h1: .init(effective: "M1A", pipeline: "M1A", baselineAvailable: true, status: "ok", source: "pipeline"),
                h2: .init(effective: "M3A", pipeline: "M3A", baselineAvailable: true, status: "ok", source: "pipeline"),
                comment: nil
            ),
        ]
        return .init(
            generatedAt: "2026-09-12T18:00:00Z",
            sourceRevision: ["sha256": "abc123", "source": "/input/project.lungfishproj"],
            allMatrix: .init(samples: samples, loci: ["A"], rows: [allRow]),
            filteredMatrix: .init(samples: samples, loci: ["A"], rows: [filteredRow]),
            calls: calls,
            colors: [
                .init(locus: "A", call: "M4A", fillHex: "#112233", fontHex: "#FFFFFF"),
                .init(locus: "A", call: "M1A", fillHex: "#445566", fontHex: "#FFFFFF"),
                .init(locus: "A", call: "M3A", fillHex: "#778899", fontHex: "#000000"),
            ],
            hasHaplotypeContent: true,
            metadata: [["Scope", "All authoritative evidence plus captured filtered viewport"]]
        )
    }
}

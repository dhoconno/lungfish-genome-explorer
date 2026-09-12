import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishGenotypeUI

/// Whole-project acceptance; every loader and writer operates on an additional
/// disposable clone. External QA inputs are never passed to recovery loaders.
@MainActor
enum GenotypeThreeSheetCohortAcceptance {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LUNGFISH_EXCEL_QA_BUNDLE"], let project = env["LUNGFISH_EXCEL_QA_PROJECT"] else {
            throw XCTSkip("Set disposable whole-project LUNGFISH_EXCEL_QA_PROJECT and LUNGFISH_EXCEL_QA_BUNDLE")
        }
        let source = URL(fileURLWithPath: project).standardizedFileURL
        let input = URL(fileURLWithPath: path).standardizedFileURL
        let before = try witness(source)
        defer { XCTAssertEqual(try? witness(source), before) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LGE-ThreeSheet-Acceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent("working.lungfish")
        XCTAssertTrue(input.path.hasPrefix(source.path + "/"))
        try FileManager.default.copyItem(at: source, to: copy)
        let bundle = copy.appendingPathComponent(String(input.path.dropFirst(source.path.count + 1)))
        let python = URL(fileURLWithPath: env["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = workspace.appendingPathComponent(".build/debug/lungfish-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path))
        let version = try LungfishCLIRunner.run(arguments: ["--version"], executableURL: cli)
        XCTAssertEqual(version.status, 0)
        XCTAssertFalse(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try JSONSerialization.data(withJSONObject: ["executable": cli.path, "version": version.stdout, "sha256": ProvenanceFileHasher.sha256(of: cli)], options: [.sortedKeys]).write(to: root.appendingPathComponent("cli-witness.json"))
        print("Excel QA retained artifacts: \(root.path)")
        let exporter = GenotypeViewportExportService(runner: WorkspaceExportRunner(cli: cli))
        let execution = GenotypeCurrentWorkbookUpdateExecutionService(processRunner: ProcessLocalWorkflowCLIProcessRunner(executableURL: cli))
        let result = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let rawCalls = result.calls
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
        var requests: [GenotypeCurrentWorkbookUIRequest] = []
        controller.onCurrentWorkbookSyncRequested = { requests.append($0) }
        controller.testingRequestCurrentWorkbookUpdate()
        let initial = try XCTUnwrap(requests.last)
        XCTAssertFalse(initial.snapshot.presentationColors.isEmpty)
        _ = try await generate(initial, execution: execution)
        try compare(controller, bundle: bundle, root: root, label: "initial", python: python, exporter: exporter)
        print("Cohort initial comparison and export provenance passed")
        let original = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        let service = GenotypeEditableWorkbookService(pythonExecutableURL: python)
        for phase in ["set", "clear"] {
            print("Cohort edit phase: \(phase)")
            let current = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundle)
            do {
                _ = try runPython(python, script: editScript, arguments: [bundle.path, current.path, root.appendingPathComponent("edit-targets.json").path, phase])
            } catch {
                print("Cohort edit failure: \(error.localizedDescription)")
                throw error
            }
            let inspection = try service.inspect(bundleURL: bundle)
            XCTAssertEqual(inspection.changes.count, 4, phase)
            XCTAssertEqual(inspection.changes.filter { $0.kind == .call }.count, 1)
            XCTAssertEqual(inspection.changes.filter { $0.kind == .review }.count, 1)
            XCTAssertEqual(inspection.changes.filter { $0.kind == .comment }.count, 2)
            if phase == "set" {
                XCTAssertEqual(Set(inspection.changes.filter { $0.kind == .review }.compactMap(\.value)), ["false-positive"])
            } else {
                XCTAssertTrue(inspection.changes.allSatisfy { $0.value == nil })
            }
            let requestCount = requests.count
            try controller.acceptEditableWorkbook(inspection, using: service)
            XCTAssertEqual(requests.count, requestCount + 1)
            let accepted = try XCTUnwrap(requests.last)
            XCTAssertFalse(accepted.snapshot.annotationOnly)
            XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls(), accepted.snapshot.calls)
            let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
            XCTAssertTrue(original.matrixReviews.allSatisfy { saved.matrixReviews.contains($0) })
            if phase == "set" {
                XCTAssertEqual(saved.matrixReviews.count, original.matrixReviews.count + 1)
                XCTAssertTrue(saved.matrixComments.contains { $0.body == "QA row comment" })
                XCTAssertTrue(saved.matrixComments.contains { $0.body == "QA cell comment" })
            } else {
                XCTAssertEqual(saved.matrixReviews, original.matrixReviews)
                XCTAssertEqual(saved.matrixComments, original.matrixComments)
            }
            let immediate = try XCTUnwrap(controller.testingCurrentExportSnapshot())
            let immediateCalls = controller.testingCurrentWorkbookHaplotypeCalls()
            _ = try await generate(accepted, execution: execution)
            XCTAssertTrue(try service.inspect(bundleURL: bundle).changes.isEmpty)
            try compare(controller, bundle: bundle, root: root, label: phase, python: python, exporter: exporter)
            let reopened = GenotypeResultViewController()
            _ = reopened.view
            reopened.configure(result: try ONTGenotypeResultBundle.loadResult(from: bundle))
            reopened.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
            XCTAssertEqual(reopened.testingCurrentWorkbookHaplotypeCalls(), immediateCalls)
            let reopenedProjection = GenotypeViewProjectionSerializer.makeProjection(from: try XCTUnwrap(reopened.testingCurrentExportSnapshot()))
            let immediateProjection = GenotypeViewProjectionSerializer.makeProjection(from: immediate)
            XCTAssertEqual(reopenedProjection.rows, immediateProjection.rows)
            XCTAssertEqual(reopenedProjection.haplotypeCalls, immediateProjection.haplotypeCalls)
            XCTAssertEqual(try ONTGenotypeResultBundle.loadResult(from: bundle).calls, rawCalls)
            do {
                print(try runPython(python, script: provenanceScript, arguments: [bundle.path, cli.path]))
            } catch {
                print("Cohort retained provenance failure (\(phase)): \(error.localizedDescription)")
                throw error
            }
        }
        XCTAssertEqual(try witness(source), before)
        print("Excel QA final artifacts ready: \(root.path)")
    }

    private static func generate(_ request: GenotypeCurrentWorkbookUIRequest, execution: GenotypeCurrentWorkbookUpdateExecutionService) async throws -> URL {
        let s = request.snapshot
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(calls: s.calls, includedLoci: s.includedLoci,
            annotationSidecar: s.annotationSidecar, candidateArtifacts: s.candidateArtifacts, reviewableRowCatalog: s.reviewableRowCatalog,
            reviewableRowCatalogSchemaVersion: s.reviewableRowCatalogSchemaVersion, haplotypeProjectionMode: s.haplotypeProjectionMode, presentationColors: s.presentationColors)
        return try await execution.run(bundleURL: s.bundleURL, calls: s.calls, includedLoci: s.includedLoci,
            annotationSidecarURL: s.annotationSidecarURL, annotationSidecarData: s.annotationSidecarData, annotationOnly: s.annotationOnly,
            haplotypeProjectionMode: s.haplotypeProjectionMode, presentationColors: s.presentationColors, inputFingerprint: fingerprint,
            syncIntent: .updateAndView)
    }

    private static func compare(_ controller: GenotypeResultViewController, bundle: URL, root: URL, label: String, python: URL, exporter: GenotypeViewportExportService) throws {
        let state = controller.testingDisplayState
        controller.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 0))
        let unfiltered = GenotypeViewProjectionSerializer.makeProjection(from: try XCTUnwrap(controller.testingCurrentExportSnapshot()))
        controller.testingApplyDisplayState(state)
        try JSONEncoder().encode(unfiltered).write(to: root.appendingPathComponent("unfiltered-display.json"))
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        let definition = try XCTUnwrap(snapshot.filters["activeHaplotypeDefinitionPath"])
        XCTAssertTrue(definition.hasPrefix(root.path + "/"))
        XCTAssertFalse(snapshot.rows.isEmpty)
        let output = root.appendingPathComponent("filtered-\(label).xlsx")
        _ = try exporter.export(snapshot: snapshot, format: .pivotExcel, to: output)
        let current = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundle)
        try FileManager.default.copyItem(at: current, to: root.appendingPathComponent("current-\(label).xlsx"))
        let expected = root.appendingPathComponent("calls-\(label).json")
        try JSONEncoder().encode(controller.testingCurrentWorkbookHaplotypeCalls()).write(to: expected)
        print(try runPython(python, script: parityScript, arguments: [output.path, bundle.path, current.path, expected.path, root.appendingPathComponent("dump-\(label).json").path]))
        print("Cohort checking export provenance")
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertTrue(provenance.argv.contains("--view-projection"))
        XCTAssertEqual(provenance.options.resolvedDefaults["minReads"], .integer(5))
        let records = provenance.files + provenance.steps.flatMap(\.inputs) + provenance.steps.flatMap(\.outputs)
        for url in [output, output.appendingPathExtension("view-projection.json"), output.appendingPathExtension("annotations.json")] {
            let record = try XCTUnwrap(records.first { $0.path == url.path })
            XCTAssertEqual(record.checksumSHA256, try ProvenanceFileHasher.sha256(of: url))
            XCTAssertNotNil(record.fileSize)
        }
    }

    private struct WorkspaceExportRunner: GenotypeViewportExportRunning {
        let cli: URL
        func run(arguments: [String]) throws -> LungfishCLIRunner.Output {
            try LungfishCLIRunner.run(arguments: arguments, executableURL: cli)
        }
    }

    private static func witness(_ root: URL) throws -> [String: String] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: String] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try ProvenanceFileHasher.sha256(of: url)
        }
        return result
    }

    private static func runPython(_ python: URL, script: String, arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = python; process.arguments = ["-c", script] + arguments
        let output = Pipe(); let error = Pipe(); process.standardOutput = output; process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errors = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "ThreeSheetCohortQA", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)]) }
        return String(decoding: data, as: UTF8.self)
    }

    private static let editScript = #"""
import json,sys,os,base64
from openpyxl import load_workbook
from openpyxl.comments import Comment
bundle,path,targets_path,phase=sys.argv[1:]
b=json.load(open(os.path.join(bundle,'artifacts/workbooks/editable-baseline.json')))
m=json.loads(base64.b64decode(b['trustedManifest']))
w=load_workbook(path)
if phase=='set':
    notes=m['noteTargets']
    row=next(k for k,n in notes.items() if n['target']['kind']=='row' and n.get('currentComment') is None)
    fp=next(k for k,n in notes.items() if n['target']['kind']=='cell' and n['reviewEligible'] and n['rawSupport']>5 and n.get('currentReview') is None and n.get('currentComment') is None)
    assert not any(n['target']['kind']=='cell' and n['reviewEligible'] and n['rawSupport']==0 for n in notes.values()), 'Cohort unexpectedly contains attested zero; revise QA expectations explicitly'
    call=next(k for k,t in m['callTargets'].items() if t['h1']['baselineAvailable'] and t['h2']['effective'] and t['h2']['effective']!=t['h1']['effective'])
    ids=dict(row=row,fp=fp,call=call)
    json.dump(ids,open(targets_path,'w'))
else: ids=json.load(open(targets_path))
for kind in ['row','fp']:
    n=m['noteTargets'][ids[kind]]; c=w[n['sheet']][n['cell']]
    generated=n['generatedText'].split('[LGE Edit v2]')[0].rstrip('\n')
    review_op=phase if kind in ['fp','fn'] else 'keep'
    review_value=({'fp':'false-positive','fn':'false-negative'}[kind] if phase=='set' and kind!='row' else '')
    comment_op=phase if kind in ['row','fp'] else 'keep'
    comment_value=({'row':'QA row comment','fp':'QA cell comment'}[kind] if phase=='set' and kind!='fn' else '')
    block='[LGE Edit v2]\nReview operation: '+review_op+'\nReview value: '+json.dumps(review_value)+'\nComment operation: '+comment_op+'\nComment value: '+json.dumps(comment_value)+'\n[/LGE Edit v2]'
    c.comment=Comment(generated+('\n' if generated else '')+block,'LGE')
t=m['callTargets'][ids['call']]
if phase=='set': w['Haplotype Calls'][t['h1']['valueCell']]=t['h2']['effective']
else: w['Haplotype Calls'][t['h1']['actionCell']]='Use pipeline call'
w.save(path)
"""#

    private static let parityScript = #"""
import json,sys,os,base64,glob,hashlib
from openpyxl import load_workbook
filtered,bundle,current,calls_path,dump_path=sys.argv[1:]
projection=json.load(open(filtered+'.view-projection.json'))
b=json.load(open(os.path.join(bundle,'artifacts/workbooks/editable-baseline.json')))
m=json.loads(base64.b64decode(b['trustedManifest']))
payload=json.load(open(os.path.join(bundle,next(x['path'] for x in b['inputs'] if x['path'].endswith('/presentation-payload.json')))))
unfiltered=json.load(open(os.path.join(os.path.dirname(filtered),'unfiltered-display.json')))
labels={(r['locus'],r['rawGenotype'],r.get('stableClusterID')):r['label'] for r in unfiltered['rows']}
for r in payload['rows']:
    key=(r['target']['locus'],r['target']['genotype'],r['target'].get('stableClusterID'))
    assert r['displayName']==labels[key], (r['displayName'],labels.get(key))
fp=json.load(open(glob.glob(filtered+'.inputs-*/presentation-payload.json')[0]))
assert [s['id'] for s in fp['samples']]==projection['sampleColumns']
assert [r['displayName'] for r in fp['rows']]==[r['label'] for r in projection['rows']]
for row,expected in zip(fp['rows'],projection['rows']):
    assert row['target']['genotype']==expected['rawGenotype']
    assert row['target'].get('stableClusterID')==expected.get('stableClusterID')
    assert [c.get('displayValue') for c in row['cells']]==[int(x) if x else None for x in expected['cells']]
    assert [c.get('style') for c in row['cells']]==expected.get('cellStyles')
want={(x['sample'],x['locus']):(x['haplotype1'],x['haplotype2']) for x in json.load(open(calls_path))}
assert {(x['sampleID'],x['locus']):(x['h1']['effective'],x['h2']['effective']) for x in payload['calls']}==want
assert {(x['sampleID'],x['locus']):(x['h1']['effective'],x['h2']['effective']) for x in fp['calls']}=={(x['sample'],x['locus']):(x['haplotype1'],x['haplotype2']) for x in projection['haplotypeCalls']}
def rgb(c): return c.rgb[-6:].upper() if c is not None and c.type=='rgb' else None
def check(path,p):
    wf=load_workbook(path,data_only=False); wc=load_workbook(path,data_only=True)
    assert wf.sheetnames==['Genotype Matrix','Haplotype Calls','Export Metadata']
    g=wf['Genotype Matrix']; cached=wc['Genotype Matrix']; c=wf['Haplotype Calls']
    assert [x.value for x in g[1]][3:]==[s['name'] for s in p['samples']]
    assert g.max_row==2+len(p['loci'])*2+len(p['rows'])
    assert g.max_column==3+len(p['samples'])
    palette={(x['locus'],x['call']):x for x in p['colors']}
    callrows={(x['sampleID'],x['locus']):(i+2,x) for i,x in enumerate(p['calls'])}
    for (sample,locus),(r,call) in callrows.items():
        assert c.cell(r,2).value==next(x['name'] for x in p['samples'] if x['id']==sample)
        for slot,column in [('h1',4),('h2',5)]:
            value=call[slot]['effective']; cell=c.cell(r,column)
            assert (cell.value or '')==value
            color=palette.get((locus,value))
            if color: assert rgb(cell.fill.fgColor)==color['fillHex'].lstrip('#')[-6:].upper()
    slots=0
    for li,locus in enumerate(p['loci']):
        for offset,slot in enumerate(['h1','h2']):
            for col,sample in enumerate(p['samples'],4):
                r=2+li*2+offset; present=callrows.get((sample['id'],locus))
                want=present[1][slot]['effective'] if present else ''
                assert (cached.cell(r,col).value or '')==want,(path,r,col,want,cached.cell(r,col).value)
                if present:
                    assert g.cell(r,col).data_type=='f'
                    callcell=c.cell(present[0],4+offset)
                    assert rgb(g.cell(r,col).fill.fgColor)==rgb(callcell.fill.fgColor)
                    assert rgb(g.cell(r,col).font.color)==rgb(callcell.font.color)
                slots+=1
    count=0
    for r,row in enumerate(p['rows'],3+2*len(p['loci'])):
        assert g.cell(r,3).value==row['displayName']
        for col,expected in enumerate(row['cells'],4):
            cell=g.cell(r,col)
            assert cell.value==expected.get('displayValue')
            assert cell.data_type!='f'
            style=expected.get('style') or {}
            fill=style.get('fillHex') if 'style' in expected else expected.get('fillHex')
            if fill: assert rgb(cell.fill.fgColor)==fill.lstrip('#')[-6:].upper()
            if expected.get('comment') is not None: assert expected['comment'] in cell.comment.text
            review=expected.get('review')
            if review=='false-positive': assert cell.font.italic and rgb(cell.font.color)=='767676' and '[' in cell.number_format
            elif review=='false-negative': assert cell.font.bold and 'FN' in cell.number_format and cell.border.left.style=='mediumDashed'
            else:
                assert bool(cell.font.bold)==style.get('isBold',False)
                assert bool(cell.font.italic)==style.get('isItalic',False)
                if style.get('textHex'): assert rgb(cell.font.color)==style['textHex'].lstrip('#')[-6:].upper()
                if style.get('borderHex'): assert rgb(cell.border.left.color)==style['borderHex'].lstrip('#')[-6:].upper()
            count+=1
    return dict(rows=len(p['rows']),samples=len(p['samples']),slots=slots,evidenceCells=count)
result=dict(filtered=check(filtered,fp),current=check(current,payload))
json.dump(result,open(dump_path,'w'),indent=2)
print(json.dumps(result))
"""#

    private static let provenanceScript = #"""
import json,os,sys,hashlib,base64
bundle=sys.argv[1]
b=json.load(open(os.path.join(bundle,'artifacts/workbooks/editable-baseline.json')))
assert b['schemaVersion']==2
inputs=b['inputs']; required=['presentation-payload.json','presentation-layout.json']
for name in required: assert any(x['path'].endswith('/'+name) for x in inputs),name
for item in inputs+[b['workbook']]:
    path=os.path.join(bundle,item['path']); data=open(path,'rb').read()
    assert len(data)==item['size'] and hashlib.sha256(data).hexdigest()==item['sha256'],path
manifest=json.load(open(os.path.join(bundle,'genotype-result.json')))
revision=json.load(open(os.path.join(bundle,manifest['workbookRevisions'][-1]['provenancePath'])))
assert revision['argv'][0]==sys.argv[2],revision['argv'][0]
assert revision['toolVersion'] and revision['runtimeIdentity'] and revision['options']
assert revision['exitStatus']==0 and revision['wallTimeSeconds']>=0
records=revision['files']+[x for step in revision['steps'] for x in step.get('inputs',[])+step.get('outputs',[])]
for name in ['presentation-payload.json','presentation-layout.json','apply-current-workbook-overrides.py','openpyxl-runtime.json']:
    item=next((x for x in records if x['path'].endswith('/'+name)),None)
    assert item is not None,('revision descriptor missing',name)
    data=open(item['path'],'rb').read()
    assert len(data)==item['fileSize'],('revision fileSize',item['path'],item['fileSize'],len(data))
    assert hashlib.sha256(data).hexdigest()==item['checksumSHA256'],('revision checksumSHA256',item['path'])
p=json.load(open(os.path.join(bundle,'annotations.json.lungfish-provenance.json')))
e=p['options']['explicit']['acceptedEditableWorkbook']['evidenceDirectory']
assert os.path.isdir(e)
for name in ['input.xlsx','baseline.json','provenance.json']: assert os.path.isfile(os.path.join(e,name))
receipt=json.load(open(os.path.join(e,'provenance.json')))
assert receipt['argv'] and receipt['options'] and receipt['runtimeIdentity']
assert receipt['exitStatus']==0 and receipt['wallTimeSeconds']>=0
for item in receipt['inputs']+receipt['outputs']:
    data=open(item['path'],'rb').read()
    assert len(data)==item['sizeBytes'] and hashlib.sha256(data).hexdigest()==item['sha256']
assert os.path.isfile(receipt['argv'][0]) and os.path.isfile(receipt['argv'][1])
print('Retained baseline, payload, layout, renderer, runtime and reviewed bytes verified')
"""#
}

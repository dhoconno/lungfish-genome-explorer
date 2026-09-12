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
    func testAttestedReferenceZeroSurvivesReviewRegenerationReopenAndClear() async throws {
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
        let payload = GenotypeWorkbookPresentation.Payload(schemaVersion: 2, role: "editable-current", sourceRevision: [:],
            samples: [.init(id: "Scientific-S", name: "Display sample", comment: nil)], loci: [], rows: [], calls: [], colors: [], metadata: [], callEditingSupported: false)
        try JSONEncoder().encode(payload).write(to: root.appendingPathComponent("seed.json"))
        try runPython(python, code: GenotypeWorkbookPresentation.pythonScript + "\nimport sys,json\nrender_three_sheet_workbook(json.load(open(sys.argv[1])),sys.argv[2])", arguments: [root.appendingPathComponent("seed.json").path, root.appendingPathComponent("source.xlsx").path])
        let initialCurrent = root.appendingPathComponent("artifacts/workbooks/current.xlsx")
        try FileManager.default.createDirectory(at: initialCurrent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("source.xlsx"), to: initialCurrent)
        let revision = ONTGenotypeWorkbookRevision(id: "initial-current-copy", role: .initialCurrentCopy, path: "artifacts/workbooks/current.xlsx", label: "Initial editable workbook", sourceFilename: "source.xlsx", createdAt: "2026-09-12T00:00:00Z", user: "QA", predecessorPath: "source.xlsx", sha256: try ProvenanceFileHasher.sha256(of: initialCurrent), sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: initialCurrent)), provenancePath: nil)
        let manifest = ONTGenotypeResultBundleManifest(kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype, workflowMode: .genotypeOnly, outputName: "zero", analysisName: "Exact zero",
            primaryWorkbookPath: "source.xlsx", currentWorkbookPath: "artifacts/workbooks/current.xlsx", workbookRevisions: [revision], longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv", statsJSONPath: "stats.json", provenancePath: "provenance.json", reviewableRowCatalog: descriptor)
        try ONTGenotypeResultBundle.writeManifest(manifest, to: root)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(.empty(generatedAt: "2026-09-12T00:00:00Z"), forBundleAt: root)
        let result = try ONTGenotypeResultBundle.loadResult(from: root)
        let controller = GenotypeResultViewController(); _ = controller.view; controller.configure(result: result)
        controller.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 0))
        var requests: [GenotypeCurrentWorkbookUIRequest] = []
        controller.onCurrentWorkbookSyncRequested = { requests.append($0) }
        controller.testingRequestCurrentWorkbookUpdate()
        let execution = GenotypeCurrentWorkbookUpdateExecutionService(processRunner: LoggedExactZeroProcessRunner(cli: cli))
        func generate(_ request: GenotypeCurrentWorkbookUIRequest) async throws {
            let s = request.snapshot
            do {
                _ = try await execution.run(bundleURL: root, calls: s.calls, includedLoci: s.includedLoci, annotationSidecarURL: s.annotationSidecarURL,
                    annotationSidecarData: s.annotationSidecarData, annotationOnly: s.annotationOnly, haplotypeProjectionMode: s.haplotypeProjectionMode,
                    presentationColors: s.presentationColors)
            } catch {
                print("Exact-zero generation primary failure: \(error.localizedDescription)")
                throw error
            }
        }
        try await generate(XCTUnwrap(requests.last))
        let service = GenotypeEditableWorkbookService(pythonExecutableURL: python)
        for phase in ["set", "clear"] {
            let current = try ONTGenotypeResultBundle.currentWorkbookURL(for: root)
            try runPython(python, code: #"""
import sys,json,base64
from openpyxl import load_workbook
from openpyxl.comments import Comment
p,b,phase=sys.argv[1:]; w=load_workbook(p)
m=json.loads(base64.b64decode(json.load(open(b))['trustedManifest']))
n=next(n for n in m['noteTargets'].values() if n['target'].get('kind')=='cell' and n['target'].get('genotype')=='01_Mafa_A1_Zero')
assert n['rawSupport']==0 and n['reviewEligible']
c=w[n['sheet']][n['cell']]; evidence=n['generatedText'].split('[LGE Edit v2]')[0].rstrip('\n')
c.comment=Comment(evidence+'\n[LGE Edit v2]\nReview operation: '+phase+'\nReview value: '+json.dumps('false-negative' if phase=='set' else '')+'\nComment operation: keep\nComment value: ""\n[/LGE Edit v2]','LGE')
w.save(p)
"""#, arguments: [current.path, root.appendingPathComponent(GenotypeEditableWorkbookService.baselinePath).path, phase])
            let inspection = try service.inspect(bundleURL: root)
            XCTAssertEqual(inspection.changes.count, 1)
            XCTAssertEqual(inspection.changes[0].target?.genotype, "01_Mafa_A1_Zero")
            XCTAssertNil(inspection.changes[0].target?.stableClusterID)
            XCTAssertEqual(inspection.changes[0].passedUniqueReads, 0)
            try controller.acceptEditableWorkbook(inspection, using: service)
            let accepted = try XCTUnwrap(requests.last)
            let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: root)
            XCTAssertEqual(sidecar.matrixReviews.count, phase == "set" ? 1 : 0)
            if phase == "set" {
                XCTAssertEqual(sidecar.matrixReviews.first?.target.genotype, "01_Mafa_A1_Zero")
                XCTAssertEqual(sidecar.matrixReviews.first?.disposition, .falseNegative)
            }
            try await generate(accepted)
            let reopened = GenotypeResultViewController(); _ = reopened.view
            reopened.configure(result: try ONTGenotypeResultBundle.loadResult(from: root))
            reopened.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 0))
            let snapshot = try XCTUnwrap(reopened.testingCurrentExportSnapshot())
            let output = root.appendingPathComponent("filtered-\(phase).xlsx")
            _ = try GenotypeViewportExportService(runner: ExactZeroExportRunner(cli: cli)).export(snapshot: snapshot, format: .pivotExcel, to: output)
            try runPython(python, code: #"""
import sys,json,base64,glob,os,hashlib
from openpyxl import load_workbook
bundle,filtered,phase=sys.argv[1:]
b=json.load(open(os.path.join(bundle,'artifacts/workbooks/editable-baseline.json')))
m=json.loads(base64.b64decode(b['trustedManifest']))
w=load_workbook(os.path.join(bundle,b['workbook']['path']))
n=next(n for n in m['noteTargets'].values() if n['target'].get('kind')=='cell' and n['target'].get('genotype')=='01_Mafa_A1_Zero')
c=w[n['sheet']][n['cell']]
assert c.value==0 and c.data_type=='n'
assert n.get('currentReview')==('false-negative' if phase=='set' else None)
if phase=='set': assert 'FN' in c.number_format and c.font.bold
else: assert 'FN' not in c.number_format
p=json.load(open(glob.glob(filtered+'.inputs-*/presentation-payload.json')[0]))
f=load_workbook(filtered)
assert f.sheetnames==w.sheetnames==['Genotype Matrix','Haplotype Calls','Export Metadata']
if phase=='set':
    row=next(r for r in p['rows'] if r['target'].get('genotype')=='01_Mafa_A1_Zero')
    assert row['cells'][0]['rawSupport']==0 and row['cells'][0]['review']=='false-negative'
    emitted=next(r for r in f['Genotype Matrix'] if r[0].value==row['id'])[3]
    assert emitted.value==0 and emitted.data_type=='n' and 'FN' in emitted.number_format and emitted.font.bold
else:
    assert not any(c.get('review') for r in p['rows'] if r['target'].get('genotype')=='01_Mafa_A1_Zero' for c in r['cells'])
    assert not any('FN' in c.number_format for r in f['Genotype Matrix'] for c in r)
for x in b['inputs']+[b['workbook']]:
    data=open(os.path.join(bundle,x['path']),'rb').read()
    assert len(data)==x['size'] and hashlib.sha256(data).hexdigest()==x['sha256']
receipt=json.load(open(os.path.join(bundle,'annotations.json.lungfish-provenance.json')))
e=receipt['options']['explicit']['acceptedEditableWorkbook']['evidenceDirectory']
r=json.load(open(os.path.join(e,'provenance.json')))
assert r['runtimeIdentity'] and r['argv'] and r['exitStatus']==0 and r['wallTimeSeconds']>=0
for x in r['inputs']+r['outputs']:
    data=open(x['path'],'rb').read()
    assert len(data)==x['sizeBytes'] and hashlib.sha256(data).hexdigest()==x['sha256']
"""#, arguments: [root.path, output.path, phase])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("calls.csv")), raw)
            XCTAssertTrue(try service.inspect(bundleURL: root).changes.isEmpty)
        }
    }

    private struct ExactZeroExportRunner: GenotypeViewportExportRunning {
        let cli: URL
        func run(arguments: [String]) throws -> LungfishCLIRunner.Output { try LungfishCLIRunner.run(arguments: arguments, executableURL: cli) }
    }

    private struct LoggedExactZeroProcessRunner: LocalWorkflowCLIProcessRunning {
        let cli: URL
        func runLungfishCLI(arguments: [String], workingDirectory: URL, outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?) async throws -> LocalWorkflowCLIProcessResult {
            let result = try await ProcessLocalWorkflowCLIProcessRunner(executableURL: cli).runLungfishCLI(arguments: arguments, workingDirectory: workingDirectory, outputHandler: outputHandler)
            if result.exitCode != 0 { print("Exact-zero CLI stderr: \(result.standardError)") }
            return result
        }
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

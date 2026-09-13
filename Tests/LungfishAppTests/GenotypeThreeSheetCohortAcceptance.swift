import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishGenotypeUI

/// Opt-in, whole-project acceptance: only disposable clones reach loaders and writers.
@MainActor
enum GenotypeThreeSheetCohortAcceptance {
    private struct NativeSlotWitness: Codable {
        let value: String
        let status: String
        let source: String
    }

    private struct NativeCallWitness: Codable {
        let sample: String
        let locus: String
        let h1: NativeSlotWitness
        let h2: NativeSlotWitness
    }

    private struct NativeColorWitness: Codable {
        let locus: String
        let call: String
        let fillHex: String
    }

    private struct NativeWitness: Codable {
        let calls: [NativeCallWitness]
        let colors: [NativeColorWitness]
    }
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LUNGFISH_EXCEL_QA_BUNDLE"], let project = env["LUNGFISH_EXCEL_QA_PROJECT"] else {
            throw XCTSkip("Set disposable whole-project LUNGFISH_EXCEL_QA_PROJECT and LUNGFISH_EXCEL_QA_BUNDLE")
        }
        try await run(projectURL: URL(fileURLWithPath: project), bundleURL: URL(fileURLWithPath: path))
    }

    static func run(projectURL: URL, bundleURL: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let source = projectURL.standardizedFileURL
        let input = bundleURL.standardizedFileURL
        guard input.path.hasPrefix(source.path + "/") else { throw NSError(domain: "QA input outside project", code: 1) }
        let before = try witness(source)
        defer { XCTAssertEqual(try? witness(source), before) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LGE-OneWay-Acceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent("working.lungfish")
        try FileManager.default.copyItem(at: source, to: copy)
        let bundle = copy.appendingPathComponent(String(input.path.dropFirst(source.path.count + 1)))
        let python = URL(fileURLWithPath: env["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = workspace.appendingPathComponent(".build/debug/lungfish-cli")
        let version = try LungfishCLIRunner.run(arguments: ["--version"], executableURL: cli)
        XCTAssertEqual(version.status, 0)
        try JSONSerialization.data(withJSONObject: ["executable": cli.path, "version": version.stdout,
            "sha256": ProvenanceFileHasher.sha256(of: cli)], options: [.sortedKeys]).write(to: root.appendingPathComponent("cli-witness.json"))
        let oracleURL = root.appendingPathComponent("raw-evidence-oracle.json")
        _ = try runPython(python, script: rawOracleScript, arguments: [bundle.path, oracleURL.path])
        let result = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let rawCalls = result.calls
        let controller = GenotypeResultViewController(); _ = controller.view
        controller.configure(result: result)
        controller.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
        let original = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        let reviewedTargets = Set(original.matrixReviews.map(\.target))
        let commentedTargets = Set(original.matrixComments.map(\.target))
        let targetCall = try XCTUnwrap(rawCalls.first { call in
            let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: call.locusGroup, genotype: call.genotype, sample: call.sample)
            return call.passedUniqueReads > 0 && !reviewedTargets.contains(target) && !commentedTargets.contains(target)
        })
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: targetCall.locusGroup, genotype: targetCall.genotype, sample: targetCall.sample)
        let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: oracleURL)) as? [String: Any])
        let rawSamples = try XCTUnwrap(rawObject["samples"] as? [String])
        let callLoci = ["MHC-A", "MHC-B", "MHC-DR", "MHC-DQ", "MHC-DP"]
        var finalExport: GenotypeExcelExportService.ExportResult?
        for phase in ["initial", "set", "clear"] {
            if phase != "initial" {
                controller.applyMatrixReview(.init(targets: [target], intent: phase == "set" ? .set(.falsePositive) : .clear))
                controller.editMatrixComment(.init(targets: [target], intent: phase == "set" ? .upsert(body: "QA native cell comment") : .remove))
            }
            let nativeWitness = try captureNativeWitness(controller, samples: rawSamples, loci: callLoci)
            let nativeWitnessURL = root.appendingPathComponent("\(phase)-native-witness.json")
            try canonicalJSON(nativeWitness).write(to: nativeWitnessURL)
            let snapshot = try capture(controller)
            let phaseSidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
                forBundleAt: bundle
            )
            let phaseReviews = phaseSidecar.matrixReviews.filter { $0.target == target }
            let phaseComments = phaseSidecar.matrixComments.filter { $0.target == target }
            let targetRow = try XCTUnwrap(snapshot.allMatrix.rows.first {
                $0.target.locus == targetCall.locusGroup
                    && $0.target.genotype == targetCall.genotype
                    && $0.target.stableClusterID == nil
            })
            let targetCell = try XCTUnwrap(targetRow.cells.first {
                $0.sampleID == targetCall.sample
            })
            if phase == "set" {
                XCTAssertEqual(phaseReviews.map(\.disposition), [.falsePositive])
                XCTAssertEqual(phaseComments.map(\.body), ["QA native cell comment"])
                XCTAssertEqual(targetCell.review, "false-positive")
                XCTAssertEqual(targetCell.comment, "QA native cell comment")
            } else {
                XCTAssertTrue(phaseReviews.isEmpty)
                XCTAssertTrue(phaseComments.isEmpty)
                XCTAssertNil(targetCell.review)
                XCTAssertNil(targetCell.comment)
            }
            let exported = try await GenotypeExcelExportService(pythonExecutableURL: python, replayExecutableURL: cli).export(
                snapshot: snapshot, outputURL: root.appendingPathComponent(phase + ".xlsx"),
                provenance: .init(workflowName: "cohort-one-way-acceptance", toolVersion: version.stdout,
                    argv: [cli.path, "genotype", "export"], options: ["phase": phase]))
            if phase == "clear" { finalExport = exported }
            print("Task6 cohort verifying phase \(phase)")
            do {
                print(try runPython(python, script: GenotypeFullCurrentEvidenceOracle.pythonScript + "\n" + #"""
import json,sys,hashlib
from openpyxl import load_workbook
oracle=json.load(open(sys.argv[1])); snapshot=json.load(open(sys.argv[2]))
w=load_workbook(sys.argv[3],data_only=False)
summary=verify_full_current_evidence(oracle,snapshot,w)
assert summary=={'rows':169,'samples':26,'evidenceCells':4394,'knownCells':1909,'unknownCells':2485},summary
assert w.sheetnames==(['Haplotype Calls'] if snapshot['hasHaplotypeContent'] else [])+['Genotype Matrix - All','Genotype Matrix - Filtered','Export Metadata']
def identity(row): return (row['locus'],row['genotype'],row.get('stableClusterID'))
source={identity(row):row for row in oracle['rows']}
expected_filtered={key for key,row in source.items() if any(value>=5 for value in row['support'].values())}
actual_filtered={identity(row['target']) for row in snapshot['filteredMatrix']['rows']}
assert len(expected_filtered)==160 and actual_filtered==expected_filtered,(len(expected_filtered),len(actual_filtered))
assert [s['id'] for s in snapshot['filteredMatrix']['samples']]==oracle['samples']
for row in snapshot['filteredMatrix']['rows']:
    evidence=source[identity(row['target'])]['support']
    for cell in row['cells']:
        raw=evidence.get(cell['sampleID'])
        want=raw if raw is not None and raw>=5 else None
        assert cell.get('rawSupport')==raw and cell.get('displayValue')==want,(identity(row['target']),cell['sampleID'],raw,want,cell)

sidecar=oracle['annotations']; native=json.load(open(sys.argv[4]))
expected_calls={(call['sample'],call['locus']):call for call in native['calls']}
actual_calls={(call['sampleID'],call['locus']):call for call in snapshot['calls']}
expected_keys={(sample,locus) for sample in oracle['samples'] for locus in ['MHC-A','MHC-B','MHC-DR','MHC-DQ','MHC-DP']}
assert set(expected_calls)==set(actual_calls)==expected_keys and len(actual_calls)==130
for key,want in expected_calls.items():
    for slot in ['h1','h2']:
        got=actual_calls[key][slot]; expected=want[slot]
        assert (got['effective'],got['status'],got['source'])==(
            expected['value'],expected['status'],expected['source']),(
                slot,key,expected,got)
        assert got['baselineAvailable'] is True and isinstance(got['pipeline'],str),(
            'native baseline transport shape',slot,key,got)

# Verify literal call/status/source/color transport into the Calls worksheet and
# both matrix bands against the pre-export native display witness. Exact pipeline
# baseline values remain covered by the fixed synthetic fixtures because the
# native cohort display APIs deliberately do not expose live baselines.
call_rows={(row[1].value,row[2].value):row for row in w['Haplotype Calls'].iter_rows(min_row=2)}
assert set(call_rows)==set(actual_calls)
native_colors={(c['locus'],c['call']):c for c in native['colors']}
assert len(native_colors)==len(native['colors'])
snapshot_colors={(c['locus'],c['call']):c for c in snapshot['colors']}
assert len(snapshot_colors)==len(snapshot['colors'])
def fill(cell):
    value=cell.fill.fgColor.rgb
    return value[-6:].upper() if isinstance(value,str) else None
for key,call in actual_calls.items():
    row=call_rows[key]
    assert [row[3].value,row[4].value,row[5].value,row[6].value,row[7].value,row[8].value]==[
        call['h1']['effective'],call['h2']['effective'],call['h1']['status'],call['h2']['status'],call['h1']['source'],call['h2']['source']]
    for column,slot in [(3,'h1'),(4,'h2')]:
        value=call[slot]['effective']
        if value.strip() and value not in ['-','?'] and not value.startswith('ERR:'):
            color=native_colors[(key[1],value)]
            assert snapshot_colors[(key[1],value)]['fillHex'].upper()==color['fillHex'].upper()
            assert fill(row[column])==color['fillHex'].lstrip('#').upper()
for sheet_name,matrix in [('Genotype Matrix - All',snapshot['allMatrix']),('Genotype Matrix - Filtered',snapshot['filteredMatrix'])]:
    sheet=w[sheet_name]
    assert matrix['loci']==['MHC-A','MHC-B','MHC-DR','MHC-DQ','MHC-DP'],(sheet_name,matrix['loci'])
    for locus_index,locus_name in enumerate(matrix['loci']):
        for offset,slot in enumerate(['h1','h2']):
            row_number=2+locus_index*2+offset
            for column,sample in enumerate(matrix['samples'],4):
                call=actual_calls.get((sample['id'],locus_name))
                if not call: continue
                value=call[slot]['effective']; cell=sheet.cell(row_number,column)
                assert cell.value==value,(sheet_name,sample['id'],locus_name,slot,value,cell.value)
                if value.strip() and value not in ['-','?'] and not value.startswith('ERR:'):
                    color=native_colors[(locus_name,value)]
                    assert fill(cell)==color['fillHex'].lstrip('#').upper()

# The native annotation surface must preserve the raw sidecar review exactly;
# the temporary QA annotation is checked separately by the Swift phase loop.
raw_reviews={}
for review in sidecar.get('matrixReviews',[]):
    target=review['target']; raw_reviews[(target['locus'],target['genotype'],target['sample'],target.get('stableClusterID'))]=review['disposition']
snapshot_reviews={}
for row in snapshot['allMatrix']['rows']:
    for cell in row['cells']:
        if cell.get('review'):
            snapshot_reviews[(row['target']['locus'],row['target']['genotype'],cell['sampleID'],row['target'].get('stableClusterID'))]=cell['review'].replace('-','').lower()
assert {k:v.lower() for k,v in raw_reviews.items()}.items() <= snapshot_reviews.items()

# Confirm the native set/clear edit is visible in the actual workbook cell,
# not merely present in an in-memory snapshot or final sidecar.
phase,target_locus,target_genotype,target_sample=sys.argv[5:9]
all_matrix=snapshot['allMatrix']; sheet=w['Genotype Matrix - All']
header=2+2*len(all_matrix['loci'])
row_index=next(index for index,row in enumerate(all_matrix['rows'],header+1)
               if row['target']['locus']==target_locus
               and row['target']['genotype']==target_genotype
               and row['target'].get('stableClusterID') is None)
column_index=next(index for index,sample in enumerate(all_matrix['samples'],4)
                  if sample['id']==target_sample)
annotation=sheet.cell(row_index,column_index).comment.text
if phase=='set':
    assert 'Current comment: "QA native cell comment"' in annotation,annotation
    assert 'Current review: "false-positive"' in annotation,annotation
else:
    assert 'Current comment:' not in annotation and 'Current review:' not in annotation,annotation
assert not any(c.data_type=='f' for s in w for row in s for c in row)
receipt=json.load(open(sys.argv[3]+'.provenance.json'))
for name in ['output','snapshot','script','request','replayScript']:
    d=receipt[name]; data=open(d['path'],'rb').read()
    assert len(data)==d['sizeBytes'] and hashlib.sha256(data).hexdigest()==d['sha256']
assert receipt['executedArgv'] and receipt['durableReplayArgv'] and receipt['exitStatus']==0
print({'rawEvidence':summary,'filteredRows':len(actual_filtered),'calls':len(actual_calls),'sourceReviews':len(raw_reviews)})
"""#, arguments: [oracleURL.path, exported.snapshotURL.path, exported.outputURL.path,
                    nativeWitnessURL.path, phase, targetCall.locusGroup,
                    targetCall.genotype, targetCall.sample]))
            } catch {
                let nsError = error as NSError
                print("Task6 cohort verifier error domain=\(nsError.domain) code=\(nsError.code) info=\(nsError.userInfo)")
                throw error
            }
            print("Task6 cohort reopening phase \(phase)")
            let reopened = GenotypeResultViewController(); _ = reopened.view
            reopened.configure(result: try ONTGenotypeResultBundle.loadResult(from: bundle))
            reopened.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
            let recaptured = try capture(reopened)
            XCTAssertEqual(try canonicalJSON(recaptured.calls), try canonicalJSON(snapshot.calls))
            XCTAssertEqual(try canonicalJSON(recaptured.allMatrix), try canonicalJSON(snapshot.allMatrix))
            XCTAssertEqual(try ONTGenotypeResultBundle.loadResult(from: bundle).calls, rawCalls)
            print("Task6 cohort completed phase \(phase)")
        }
        let final = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        XCTAssertEqual(final.matrixReviews, original.matrixReviews)
        XCTAssertEqual(final.matrixComments, original.matrixComments)
        let sourceIndependent = try XCTUnwrap(finalExport)
        try FileManager.default.removeItem(at: copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let replayed = root.appendingPathComponent("replayed-after-working-copy-removal.xlsx")
        XCTAssertEqual(try runProcess("/bin/sh", [sourceIndependent.replayScriptURL.path, replayed.path]), 0)
        print(try runPython(python, script: #"""
import hashlib,json,sys
from openpyxl import load_workbook
left,right=[load_workbook(path,data_only=False) for path in sys.argv[1:3]]
assert left.sheetnames==right.sheetnames==['Haplotype Calls','Genotype Matrix - All','Genotype Matrix - Filtered','Export Metadata']
for left_sheet,right_sheet in zip(left,right):
    assert (left_sheet.max_row,left_sheet.max_column)==(right_sheet.max_row,right_sheet.max_column)
    for left_row,right_row in zip(left_sheet.iter_rows(),right_sheet.iter_rows()):
        for left_cell,right_cell in zip(left_row,right_row):
            assert (left_cell.value,left_cell.data_type)==(right_cell.value,right_cell.data_type)
            assert (left_cell.comment.text if left_cell.comment else None)==(right_cell.comment.text if right_cell.comment else None)
            assert left_cell.fill.fgColor.rgb==right_cell.fill.fgColor.rgb
receipt=json.load(open(sys.argv[2]+'.provenance.json'))
for name in ['output','snapshot','script','request','replayScript']:
    descriptor=receipt[name]; data=open(descriptor['path'],'rb').read()
    assert len(data)==descriptor['sizeBytes'] and hashlib.sha256(data).hexdigest()==descriptor['sha256']
assert receipt['exitStatus']==0 and receipt['executedArgv'] and receipt['durableReplayArgv']
print({'semanticReplaySheets':left.sheetnames,'outputSize':receipt['output']['sizeBytes'],'outputSHA256':receipt['output']['sha256']})
"""#, arguments: [sourceIndependent.outputURL.path, replayed.path]))
        print("One-way cohort QA retained artifacts: \(root.path)")
    }

    /// Builds the scientific oracle directly from manifest-selected CSV/JSON
    /// bytes. It deliberately does not import or call any Lungfish parser,
    /// snapshot builder, projection, adapter, or workbook implementation.
    private static let rawOracleScript = #"""
import csv,json,os,sys
bundle,out=sys.argv[1:]
manifest=json.load(open(os.path.join(bundle,'genotype-result.json')))
def selected(name):
    path=manifest[name]
    return path if os.path.isabs(path) else os.path.join(bundle,path)
def canonical(raw):
    token=raw.strip().upper()
    if token.startswith('MHC-'): token=token[4:]
    if token.startswith('AG'): return 'MHC-AG'
    if token=='A' or (token.startswith('A') and token[1:2].isdigit()): return 'MHC-A'
    if token=='B' or (token.startswith('B') and token[1:2].isdigit()): return 'MHC-B'
    if token.startswith('DRB'): return 'MHC-DRB'
    for prefix in ['DQA','DQB','DPA','DPB']:
        if token.startswith(prefix) and token[len(prefix):len(prefix)+1].isdigit():
            digits=''.join(c for c in token[len(prefix):] if c.isdigit())
            return 'MHC-'+prefix+digits
    if token in ['F','G','E','70']: return 'MHC-'+token
    return 'Unknown' if token in ['', 'UNKNOWN'] else 'MHC-'+token
def locus(genotype):
    fields={}
    for field in genotype.split('|')[1:]:
        if '=' in field:
            key,value=field.split('=',1); fields.setdefault(key,value)
    raw=[]
    for item in fields.get('source_loci','').split(','):
        item=item.strip()
        if item and item not in raw: raw.append(item)
    groups={canonical(item) for item in raw}
    return next(iter(groups)) if len(groups)==1 else 'Unknown'
with open(selected('sampleSummaryCSVPath'),newline='') as stream:
    samples=[]
    for record in csv.DictReader(stream):
        sample=record.get('sample','').strip()
        if sample and sample.lower()!='unassigned' and sample not in samples: samples.append(sample)
values={}
with open(selected('longSummaryCSVPath'),newline='') as stream:
    for record in csv.DictReader(stream):
        sample=record['sample'].strip(); genotype=record['genotype'].strip()
        if not sample or not genotype or sample.lower()=='unassigned': continue
        key=(locus(genotype),genotype)
        count=int(float(record['passed_unique_reads'].replace(',','')))
        values.setdefault(key,{})[sample]=max(count,values.setdefault(key,{}).get(sample,count))
rows=[{'locus':key[0],'genotype':key[1],'stableClusterID':None,'support':support}
      for key,support in sorted(values.items())]
recorded_analysis=selected('haplotypeAnalysisPath')
current_analysis=os.path.join(bundle,manifest['outputName']+'.current-haplotype-analysis.json')
analysis_path=current_analysis if os.path.exists(current_analysis) else recorded_analysis
analysis=json.load(open(analysis_path))
annotation_path=os.path.join(bundle,'annotations.json')
annotations=json.load(open(annotation_path)) if os.path.exists(annotation_path) else {}
oracle={'samples':samples,'rows':rows,'analysis':analysis,'annotations':annotations,
        'selectedPaths':{'longSummaryCSVPath':manifest['longSummaryCSVPath'],
                         'sampleSummaryCSVPath':manifest['sampleSummaryCSVPath'],
                         'haplotypeAnalysisPath':os.path.relpath(analysis_path,bundle)}}
json.dump(oracle,open(out,'w'),sort_keys=True,separators=(',',':'))
print({'samples':len(samples),'rows':len(rows),'observations':sum(len(r['support']) for r in rows),
       'calls':sum(len(s['calls']) for s in analysis['samples']),'overrides':len(annotations.get('callOverrides',[]))})
"""#

    private static func capture(_ controller: GenotypeResultViewController) throws -> GenotypeWorkbookPresentation.Snapshot {
        try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(controller.captureExcelExportSnapshot().excelSnapshotData))
    }

    /// Captures already-held native viewer authority before export. This is
    /// intentionally separate from the export snapshot/builder: sample detail,
    /// outline semantics, the native matrix band, and the cached active
    /// definition must all agree before they can be transport expectations.
    private static func captureNativeWitness(
        _ controller: GenotypeResultViewController,
        samples: [String],
        loci: [String]
    ) throws -> NativeWitness {
        func sourceName(_ source: GenotypeEffectiveHaplotypeValue.Source) -> String {
            switch source {
            case .pipeline: return "pipeline"
            case .analystOverride: return "analystOverride"
            case .staleOverride: return "staleOverride"
            }
        }
        let definition = try XCTUnwrap(controller.testingActiveHaplotypeDefinitionSet)
        var nativeColors: [String: NativeColorWitness] = [:]
        for locus in definition.locusDefinitions {
            for haplotype in locus.haplotypes {
                let color = haplotype.effectiveFillColor
                let key = locus.locus + "\u{0}" + haplotype.name
                let witness = NativeColorWitness(
                    locus: locus.locus,
                    call: haplotype.name,
                    fillHex: color.hexString
                )
                if let existing = nativeColors[key] {
                    XCTAssertEqual(existing.fillHex, witness.fillHex, "native definition palette conflict for \(key)")
                } else {
                    nativeColors[key] = witness
                }
            }
        }

        let matrix = controller.testingComparisonMatrix
        var calls: [NativeCallWitness] = []
        var requiredColors = Set<String>()
        for sample in samples {
            let detailRows = controller.testingSampleDetailRows(sample: sample)
                .filter { loci.contains($0.locus) }
            var details: [String: GenotypeSampleDetailSheet.CallRow] = [:]
            for row in detailRows {
                let key = row.locus + "\u{0}" + row.slot.rawValue
                XCTAssertNil(details.updateValue(row, forKey: key), "duplicate native detail slot \(sample) \(key)")
            }
            XCTAssertEqual(details.count, loci.count * HaplotypeSlot.allCases.count)

            let outlineSlots = controller.testingOutlineSlots(sample: sample)
            var outlines: [String: GenotypeHaplotypeTapeView.Slot] = [:]
            for row in outlineSlots where loci.contains(row.locus) {
                XCTAssertNil(outlines.updateValue(row, forKey: row.locus), "duplicate native outline locus \(sample) \(row.locus)")
            }
            XCTAssertEqual(Set(outlines.keys), Set(loci))

            func slotWitness(locus: String, slot: HaplotypeSlot) throws -> NativeSlotWitness {
                let detail = try XCTUnwrap(details[locus + "\u{0}" + slot.rawValue])
                let outline = try XCTUnwrap(outlines[locus])
                let semantics = try XCTUnwrap(slot == .h1 ? outline.h1Semantics : outline.h2Semantics)
                let band = try XCTUnwrap(matrix.testingHaplotypeBandValue(
                    sample: sample,
                    locus: locus,
                    slot: slot
                ))
                XCTAssertEqual(detail.callName, semantics.value)
                XCTAssertEqual(detail.status, semantics.status)
                XCTAssertEqual(detail.source, semantics.source)
                XCTAssertEqual(detail.callName, band.value)
                XCTAssertEqual(detail.status, band.status)
                XCTAssertEqual(detail.source, band.source)
                let value = detail.callName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && value != "-" && value != "?" && !value.hasPrefix("ERR:") {
                    requiredColors.insert(locus + "\u{0}" + value)
                }
                return NativeSlotWitness(
                    value: detail.callName,
                    status: detail.status.rawValue,
                    source: sourceName(detail.source)
                )
            }

            for locus in loci {
                calls.append(NativeCallWitness(
                    sample: sample,
                    locus: locus,
                    h1: try slotWitness(locus: locus, slot: .h1),
                    h2: try slotWitness(locus: locus, slot: .h2)
                ))
            }
        }
        XCTAssertEqual(calls.count, samples.count * loci.count)
        for key in requiredColors {
            _ = try XCTUnwrap(nativeColors[key], "native definition palette lacks effective call \(key)")
        }
        return NativeWitness(
            calls: calls,
            colors: nativeColors.values.sorted {
                ($0.locus, $0.call) < ($1.locus, $1.call)
            }
        )
    }

    private static func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
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

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { print(String(decoding: bytes, as: UTF8.self)) }
        return process.terminationStatus
    }

}

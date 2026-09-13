import Foundation
import XCTest
import LungfishIO

/// Independent acceptance oracle, never constructed from a presentation payload,
/// generated manifest, filtered projection, or source workbook.
enum GenotypeFullCurrentEvidenceOracle {
    struct Evidence: Encodable {
        let samples: [String]
        let rows: [Row]
    }

    struct Identity: Hashable, Encodable {
        let locus: String
        let genotype: String
        let stableClusterID: String?
    }

    struct Row: Encodable {
        let locus: String
        let genotype: String
        let stableClusterID: String?
        let support: [String: Int]
    }

    /// Capture once, before current generation or accepted annotation changes.
    /// This reads the loader's validated scientific model, not exporter helpers.
    static func capture(_ result: ONTGenotypeResultBundleData) -> Evidence {
        if let catalog = result.reviewableRowCatalog {
            return Evidence(samples: catalog.samples, rows: catalog.rows.map {
                Row(locus: $0.locus, genotype: $0.callID, stableClusterID: $0.stableID, support: $0.supportBySample)
            })
        }
        var values: [Identity: [String: Int]] = [:]
        var samples = Set(result.samples.map(\.sample))
        for call in result.calls {
            let key = Identity(locus: call.locusGroup, genotype: call.genotype, stableClusterID: nil)
            let prior = values[key]?[call.sample]
            values[key, default: [:]][call.sample] = max(prior ?? call.passedUniqueReads, call.passedUniqueReads)
            samples.insert(call.sample)
        }
        if let document = result.mhcCandidates {
            for candidate in document.candidates {
                let key = Identity(locus: candidate.locus, genotype: candidate.provisionalName, stableClusterID: candidate.stableClusterID)
                values[key] = [:]
                for observation in document.observations where observation.stableClusterID == candidate.stableClusterID {
                    values[key, default: [:]][observation.sampleID, default: 0] += observation.aggregatedSampleReadCount
                    samples.insert(observation.sampleID)
                }
            }
        }
        if let document = result.mhcUnnameableClusters {
            for cluster in document.clusters {
                let key = Identity(locus: cluster.candidateInterpretation?.locus ?? "", genotype: cluster.candidateInterpretation?.provisionalName ?? cluster.stableClusterID, stableClusterID: cluster.stableClusterID)
                values[key] = [:]
                for observation in document.observations where observation.stableClusterID == cluster.stableClusterID {
                    values[key, default: [:]][observation.sampleID, default: 0] += observation.aggregatedSampleReadCount
                    samples.insert(observation.sampleID)
                }
            }
        }
        let rows = values.map { Row(locus: $0.key.locus, genotype: $0.key.genotype, stableClusterID: $0.key.stableClusterID, support: $0.value) }
            .sorted { ($0.locus, $0.genotype, $0.stableClusterID ?? "") < ($1.locus, $1.genotype, $1.stableClusterID ?? "") }
        return Evidence(samples: samples.sorted(), rows: rows)
    }

    static let pythonScript = #"""
def verify_full_current_evidence(oracle, snapshot, workbook):
    payload=snapshot['allMatrix']
    def identity(row): return (row['locus'],row['genotype'],row.get('stableClusterID'))
    def unique(items, label):
        result=set(items)
        assert len(result)==len(items), label+' duplicates'
        return result
    samples=unique(oracle['samples'],'source samples')
    rows={identity(r):r for r in oracle['rows']}
    assert len(rows)==len(oracle['rows']), 'source row duplicates'
    assert unique([s['id'] for s in payload['samples']],'payload samples')==samples, 'payload sample roster differs from raw authority'
    assert unique([identity(r['target']) for r in payload['rows']],'payload rows')==set(rows), 'payload row roster differs from raw authority'
    expected={(key+(sample,)):row['support'].get(sample) for key,row in rows.items() for sample in samples}
    for row in payload['rows']:
        key=identity(row['target'])
        assert unique([c['sampleID'] for c in row['cells']],'payload row samples')==samples, ('payload row sample roster',key)
        for cell in row['cells']:
            target=key+(cell['sampleID'],); want=expected[target]
            for field in ['rawSupport','displayValue']:
                value=cell.get(field)
                assert value==want and (value is None or type(value) is int), (field,target,want,value)
    sheet=workbook['Genotype Matrix - All']
    header=2+2*len(payload['loci']) if snapshot['hasHaplotypeContent'] and payload['loci'] else 1
    actual_samples=[sheet.cell(header,c).value for c in range(4,4+len(payload['samples']))]
    assert actual_samples==[s['name'] for s in payload['samples']], 'XLSX sample roster'
    for ri,row in enumerate(payload['rows'],header+1):
        assert sheet.cell(ri,1).value==row['id'], 'XLSX row identity'
        key=identity(row['target'])
        by_sample={c['sampleID']:c for c in row['cells']}
        for ci,sample in enumerate(payload['samples'],4):
            want=expected[key+(sample['id'],)]
            cell=sheet.cell(ri,ci)
            assert cell.value==want and (want is None or type(cell.value) is int), ('XLSX evidence',key,sample['id'],want,cell.value)
            assert cell.data_type!='f'
    return dict(rows=len(rows),samples=len(samples),evidenceCells=len(expected),knownCells=sum(v is not None for v in expected.values()),unknownCells=sum(v is None for v in expected.values()))
"""#
}

final class GenotypeFullCurrentEvidenceOracleTests: XCTestCase {
    /// A renderer dropping a row/sample or coherently changing payload + XLSX
    /// evidence must fail even though all remaining output agrees internally.
    func testIndependentOracleRejectsCoherentRenderedMutations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LGE-Oracle-Mutations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let process = Process(); process.executableURL = python
        process.arguments = ["-c", GenotypeWorkbookPresentation.snapshotPythonScript + "\n" + GenotypeFullCurrentEvidenceOracle.pythonScript + "\n" + Self.mutations, root.path]
        let stdout = Pipe(); let stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        print(String(decoding: output, as: UTF8.self))
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error, as: UTF8.self))
    }

    private static let mutations = #"""
import copy, json, os, sys
from openpyxl import load_workbook
# Literal raw authority: explicit zero, sparse unknowns, colliding candidate
# display names with distinct stable IDs, and an extra call-only sample.
oracle={'samples':['S1','S2','CallOnly'], 'rows':[
    {'locus':'MHC-A','genotype':'Reference','support':{'S1':0}},
    {'locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-a','support':{'S1':7}},
    {'locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-b','support':{'S2':9}}]}
baseline={'schemaVersion':2,'role':'editable-current','sourceRevision':{},
    'samples':[{'id':s,'name':s} for s in ['S1','S2','CallOnly']],
    'loci':[],'calls':[],'colors':[],'metadata':[],'callEditingSupported':False,'rows':[
    {'id':'reference','target':{'kind':'row','locus':'MHC-A','genotype':'Reference'},'displayName':'Reference',
     'cells':[{'sampleID':'S1','rawSupport':0,'displayValue':0,'reviewEligible':True},
              {'sampleID':'S2','reviewEligible':False},{'sampleID':'CallOnly','reviewEligible':False}]},
    {'id':'a','target':{'kind':'row','locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-a'},'displayName':'Candidate',
     'cells':[{'sampleID':'S1','rawSupport':7,'displayValue':7,'reviewEligible':True},
              {'sampleID':'S2','reviewEligible':False},{'sampleID':'CallOnly','reviewEligible':False}]},
    {'id':'b','target':{'kind':'row','locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-b'},'displayName':'Candidate',
     'cells':[{'sampleID':'S1','reviewEligible':False},
              {'sampleID':'S2','rawSupport':9,'displayValue':9,'reviewEligible':True},{'sampleID':'CallOnly','reviewEligible':False}]}]}
accepted=[]
for mutation in ['baseline','drop-row','drop-sample','coherent-count','unknown-to-zero','retarget-stable-id']:
    p=copy.deepcopy(baseline)
    if mutation=='drop-row': p['rows'].pop()
    if mutation=='drop-sample':
        p['samples'].pop()
        for row in p['rows']: row['cells'].pop()
    if mutation=='coherent-count': p['rows'][1]['cells'][0].update(rawSupport=700,displayValue=700)
    if mutation=='unknown-to-zero': p['rows'][0]['cells'][2].update(rawSupport=0,displayValue=0,reviewEligible=True)
    if mutation=='retarget-stable-id': p['rows'][1]['target']['stableClusterID']='wrong-cluster'
    path=os.path.join(sys.argv[1],mutation+'.xlsx')
    snapshot={'schemaVersion':3,'generatedAt':'test','sourceRevision':{'result':'literal'},'hasHaplotypeContent':False,
        'calls':[],'colors':[],'metadata':[], 'allMatrix':{'samples':p['samples'],'rows':p['rows'],'loci':[]},
        'filteredMatrix':{'samples':p['samples'],'rows':[r for r in p['rows'] if any((c.get('displayValue') or 0)>0 for c in r['cells'])],'loci':[]}}
    m=render_genotype_snapshot(snapshot,path)
    json.dump(p,open(path+'.payload.json','w')); json.dump(m,open(path+'.manifest.json','w'))
    w=load_workbook(path,data_only=False)
    # Confirm the malformed artifact really agrees with its own payload before
    # applying the independent oracle. All XLSX authoring is shipping renderer.
    for ri,row in enumerate(p['rows'],2):
        for ci,cell in enumerate(row['cells'],4):
            assert w['Genotype Matrix - All'].cell(ri,ci).value==cell.get('displayValue')
    try:
        verify_full_current_evidence(oracle,snapshot,w)
    except AssertionError as error:
        assert mutation!='baseline', str(error)
        print('REJECTED '+mutation+': '+str(error))
    else:
        accepted.append(mutation)
assert accepted==['baseline'], ('independent oracle accepted coherent corruption',accepted)
print('Accepted exact zero/sparse/call-only baseline; rejected all five coherent mutations')
"""#
}

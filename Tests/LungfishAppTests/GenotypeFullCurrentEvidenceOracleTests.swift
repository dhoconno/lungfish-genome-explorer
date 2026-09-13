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
import hashlib,json
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
    if 'calls' in oracle:
        def call_key(call): return (call['sampleID'],call['locus'])
        actual_calls={call_key(call):call for call in snapshot['calls']}
        expected_calls={call_key(call):call for call in oracle['calls']}
        assert len(actual_calls)==len(snapshot['calls']), 'payload call duplicates'
        assert set(actual_calls)==set(expected_calls), 'payload call targets'
        for key,want in expected_calls.items():
            got=actual_calls[key]
            for slot in ['h1','h2']:
                assert got[slot]==want[slot], ('payload call slot',key,slot,want[slot],got[slot])
        def color_key(color): return (color['locus'],color['call'])
        actual_colors={color_key(color):color for color in snapshot['colors']}
        expected_colors={color_key(color):color for color in oracle['colors']}
        assert actual_colors==expected_colors, ('payload palette',expected_colors,actual_colors)
        names={sample['id']:sample['name'] for sample in payload['samples']}
        call_rows={(row[1].value,row[2].value):row for row in workbook['Haplotype Calls'].iter_rows(min_row=2)}
        assert set(call_rows)=={(names[sample],locus) for sample,locus in expected_calls}, 'XLSX call targets'
        def fill(cell):
            value=cell.fill.fgColor.rgb
            return value[-6:].upper() if isinstance(value,str) else None
        expected_fill={(color['locus'],color['call']):color['fillHex'].lstrip('#').upper() for color in oracle['colors']}
        for (sample,locus),want in expected_calls.items():
            row=call_rows[(names[sample],locus)]
            for column,slot in [(3,'h1'),(4,'h2')]:
                value=want[slot]['effective']
                assert row[column].value==value, ('XLSX call value',sample,locus,slot,value,row[column].value)
                if (locus,value) in expected_fill:
                    assert fill(row[column])==expected_fill[(locus,value)], ('XLSX call color',sample,locus,slot)
        for matrix_name,matrix in [('Genotype Matrix - All',snapshot['allMatrix']),('Genotype Matrix - Filtered',snapshot['filteredMatrix'])]:
            if not matrix['loci']: continue
            sheet=workbook[matrix_name]
            for locus_index,locus in enumerate(matrix['loci']):
                for slot_offset,slot in enumerate(['h1','h2']):
                    row_number=2+locus_index*2+slot_offset
                    for column,sample in enumerate(matrix['samples'],4):
                        want=expected_calls.get((sample['id'],locus))
                        if want is None: continue
                        value=want[slot]['effective']; cell=sheet.cell(row_number,column)
                        assert cell.value==value, ('XLSX band value',matrix_name,sample['id'],locus,slot,value,cell.value)
                        if (locus,value) in expected_fill:
                            assert fill(cell)==expected_fill[(locus,value)], ('XLSX band color',matrix_name,sample['id'],locus,slot)
    return dict(rows=len(rows),samples=len(samples),evidenceCells=len(expected),knownCells=sum(v is not None for v in expected.values()),unknownCells=sum(v is None for v in expected.values()))

def _filtered_identity(row):
    return (row['locus'],row['genotype'],row.get('stableClusterID'))

def _filtered_stable_id(row):
    raw=json.dumps([row['locus'],row['genotype'],row.get('stableClusterID') or ''],
                   ensure_ascii=False,separators=(',',':')).encode('utf-8')
    return hashlib.sha256(raw).hexdigest()

def verify_filtered_current_view(oracle, native, snapshot, workbook):
    """Compare Filtered XLSX to pre-export native viewport and raw evidence."""
    raw_rows={_filtered_identity(row):row for row in oracle['rows']}
    assert len(raw_rows)==len(oracle['rows']), 'raw Filtered row identities are not unique'
    native_samples=native['samples']
    sample_ids=[sample['id'] for sample in native_samples]
    assert len(set(sample_ids))==len(sample_ids), 'native Filtered sample identities are not unique'
    assert all(sample['id']==sample['name'] for sample in native_samples), 'native sample display/identity mismatch'
    assert set(sample_ids)<=set(oracle['samples']), 'native Filtered samples outside raw authority'
    minimum=native['minimumReads']
    independently_eligible={
        key for key,row in raw_rows.items()
        if any((row['support'].get(sample) is not None
                and row['support'][sample]>=minimum
                and row['support'][sample]>0) for sample in sample_ids)
    }
    native_rows=native['rows']
    native_keys=[_filtered_identity(row) for row in native_rows]
    assert len(set(native_keys))==len(native_keys), 'native Filtered row identities are not unique'
    assert set(native_keys)==independently_eligible, (
        'native Filtered eligibility differs from raw evidence', independently_eligible, set(native_keys))

    native_by_key=dict(zip(native_keys,native_rows))
    def same_native_color(actual,want):
        if actual is None or want is None: return actual is want
        a=actual.lstrip('#'); w=want.lstrip('#')
        return len(a)==len(w)==6 and all(abs(int(a[i:i+2],16)-int(w[i:i+2],16))<=1 for i in [0,2,4])
    for key,row in native_by_key.items():
        cells=row['cells']
        assert [cell['sampleID'] for cell in cells]==sample_ids, ('native Filtered cell order',key)
        for cell in cells:
            raw=raw_rows[key]['support'].get(cell['sampleID'])
            expected=raw if raw is not None and raw>=minimum else None
            assert cell.get('displayValue')==expected, (
                'native Filtered mask differs from raw evidence',key,cell['sampleID'],raw,expected,cell.get('displayValue'))
            review=cell.get('review')
            assert review in [None,'false-positive','false-negative'], ('native Filtered review',key,cell)
            if review=='false-positive': assert raw is not None and raw>0
            if review=='false-negative': assert raw==0

    matrix=snapshot['filteredMatrix']
    assert [(sample['id'],sample['name']) for sample in matrix['samples']]==[
        (sample['id'],sample['name']) for sample in native_samples], 'snapshot Filtered sample order'
    assert [_filtered_identity(row['target']) for row in matrix['rows']]==native_keys, 'snapshot Filtered row order'
    for captured,native_row in zip(matrix['rows'],native_rows):
        key=_filtered_identity(native_row)
        assert captured['id']==_filtered_stable_id(native_row), ('snapshot Filtered stable ID',key,captured['id'])
        assert captured['displayName']==native_row['displayName'], ('snapshot Filtered display value',key)
        assert [cell['sampleID'] for cell in captured['cells']]==sample_ids, ('snapshot Filtered cell order',key)
        for cell,native_cell in zip(captured['cells'],native_row['cells']):
            raw=raw_rows[key]['support'].get(cell['sampleID'])
            for field,want in [('rawSupport',raw),('displayValue',native_cell.get('displayValue')),
                               ('review',native_cell.get('review')),('comment',native_cell.get('comment'))]:
                assert cell.get(field)==want, ('snapshot Filtered '+field,key,cell['sampleID'],want,cell.get(field))
            style=cell.get('style') or {}
            native_style=native_cell['style']
            for field in ['fillHex']:
                assert same_native_color(style.get(field),native_style.get(field)), (
                    'snapshot Filtered style '+field,key,cell['sampleID'],native_style.get(field),style.get(field))
            for field in ['isBold','isItalic']:
                assert bool(style.get(field))==bool(native_style.get(field)), ('snapshot Filtered style '+field,key,cell['sampleID'])

    sheet=workbook['Genotype Matrix - Filtered']
    header=2+2*len(matrix['loci']) if snapshot['hasHaplotypeContent'] and matrix['loci'] else 1
    assert (sheet.max_row,sheet.max_column)==(header+len(native_rows),3+len(native_samples)), (
        'XLSX Filtered dimensions',(sheet.max_row,sheet.max_column),(header+len(native_rows),3+len(native_samples)))
    assert [sheet.cell(header,column).value for column in range(4,4+len(native_samples))]==[
        sample['name'] for sample in native_samples], 'XLSX Filtered sample order'

    def rgb(value):
        return value[-6:].upper() if isinstance(value,str) else None
    def fill(cell):
        return rgb(cell.fill.fgColor.rgb) if cell.fill.patternType=='solid' else None
    def border(cell):
        return [(side.style if side else None,rgb(side.color.rgb) if side and side.color and side.color.type=='rgb' else None)
                for side in [cell.border.left,cell.border.right,cell.border.top,cell.border.bottom]]
    def expected_comment(display,raw,comment,review):
        value='Evidence: display='+json.dumps(display)+', raw support='+json.dumps(raw)
        if comment is not None: value+='\nCurrent comment: '+json.dumps(comment,ensure_ascii=False)
        if review is not None: value+='\nCurrent review: '+json.dumps(review,ensure_ascii=False)
        return value

    for row_number,native_row in enumerate(native_rows,header+1):
        key=_filtered_identity(native_row)
        assert [sheet.cell(row_number,column).value for column in [1,2,3]]==[
            _filtered_stable_id(native_row),native_row['locus'],native_row['displayName']], (
                'XLSX Filtered row identity/order',row_number,key)
        for column,native_cell in enumerate(native_row['cells'],4):
            raw=raw_rows[key]['support'].get(native_cell['sampleID'])
            display=native_cell.get('displayValue')
            review=native_cell.get('review')
            cell=sheet.cell(row_number,column)
            assert cell.value==display and (display is None or type(cell.value) is int), (
                'XLSX Filtered literal evidence',key,native_cell['sampleID'],display,cell.value,type(cell.value).__name__)
            assert cell.data_type!='f', ('XLSX Filtered formula',key,native_cell['sampleID'])
            annotation=cell.comment.text if cell.comment else None
            assert annotation==expected_comment(display,raw,native_cell.get('comment'),review), (
                'XLSX Filtered annotation',key,native_cell['sampleID'],annotation)
            style=native_cell['style']
            wanted_fill=rgb(style.get('fillHex'))
            if review=='false-negative' and wanted_fill is None: wanted_fill='FFF2CC'
            assert same_native_color(fill(cell),wanted_fill), (
                'XLSX Filtered fill',key,native_cell['sampleID'],wanted_fill,fill(cell))
            if review=='false-negative':
                assert border(cell)==[('mediumDashed','C65911')]*4, ('XLSX Filtered FN border',key,native_cell['sampleID'])
            assert bool(cell.font.bold)==(bool(style.get('isBold')) or review=='false-negative'), (
                'XLSX Filtered bold',key,native_cell['sampleID'])
            assert bool(cell.font.italic)==(bool(style.get('isItalic')) or review=='false-positive'), (
                'XLSX Filtered italic',key,native_cell['sampleID'])
            if review=='false-positive':
                assert cell.number_format=='"["0"]"' and rgb(cell.font.color.rgb)=='767676', (
                    'XLSX Filtered FP style',key,native_cell['sampleID'])
            elif review=='false-negative':
                assert cell.number_format=='0;-0;"FN"', ('XLSX Filtered FN format',key,native_cell['sampleID'])
            else:
                assert cell.number_format=='General', ('XLSX Filtered unexpected number format',key,native_cell['sampleID'])
    return dict(rows=len(native_rows),samples=len(native_samples),cells=len(native_rows)*len(native_samples))
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
import copy as copy_module, json, os, sys
from openpyxl import load_workbook
# Literal raw authority: explicit zero, sparse unknowns, colliding candidate
# display names with distinct stable IDs, and an extra call-only sample.
oracle={'samples':['S1','S2','CallOnly'], 'rows':[
    {'locus':'MHC-A','genotype':'Reference','support':{'S1':0}},
    {'locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-a','support':{'S1':7,'S2':0}},
    {'locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-b','support':{'S2':9}}],
    'calls':[{'sampleID':'S1','locus':'MHC-A','h1':{'effective':'H1','pipeline':'H1','status':'called','source':'pipeline','baselineAvailable':True},
              'h2':{'effective':'H2','pipeline':'H2','status':'called','source':'pipeline','baselineAvailable':True}}],
    'colors':[{'locus':'MHC-A','call':'H1','fillHex':'#008000','fontHex':'#FFFFFF'},
              {'locus':'MHC-A','call':'H2','fillHex':'#0000FF','fontHex':'#FFFFFF'}]}
baseline={'schemaVersion':2,'role':'editable-current','sourceRevision':{},
    'samples':[{'id':s,'name':s} for s in ['S1','S2','CallOnly']],
    'loci':[],'calls':[],'colors':[],'metadata':[],'callEditingSupported':False,'rows':[
    {'id':_filtered_stable_id({'locus':'MHC-A','genotype':'Reference'}),'target':{'kind':'row','locus':'MHC-A','genotype':'Reference'},'displayName':'Reference',
     'cells':[{'sampleID':'S1','rawSupport':0,'displayValue':0,'reviewEligible':True},
              {'sampleID':'S2','reviewEligible':False},{'sampleID':'CallOnly','reviewEligible':False}]},
    {'id':_filtered_stable_id({'locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-a'}),'target':{'kind':'row','locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-a'},'displayName':'Candidate',
     'cells':[{'sampleID':'S1','rawSupport':7,'displayValue':7,'reviewEligible':True,
               'review':'false-positive','comment':'literal FP note'},
              {'sampleID':'S2','rawSupport':0,'displayValue':0,'reviewEligible':True,
               'review':'false-negative','comment':'literal FN note'},
              {'sampleID':'CallOnly','reviewEligible':False}]},
    {'id':_filtered_stable_id({'locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-b'}),'target':{'kind':'row','locus':'MHC-A','genotype':'Candidate','stableClusterID':'cluster-b'},'displayName':'Candidate',
     'cells':[{'sampleID':'S1','reviewEligible':False},
              {'sampleID':'S2','rawSupport':9,'displayValue':9,'reviewEligible':True},{'sampleID':'CallOnly','reviewEligible':False}]}]}
accepted=[]
for mutation in ['baseline','drop-row','drop-sample','coherent-count','unknown-to-zero','retarget-stable-id','diverge-h2','diverge-palette',
                 'filtered-value','filtered-order','filtered-annotation']:
    p=copy_module.deepcopy(baseline)
    if mutation=='drop-row': p['rows'].pop()
    if mutation=='drop-sample':
        p['samples'].pop()
        for row in p['rows']: row['cells'].pop()
    if mutation=='coherent-count': p['rows'][1]['cells'][0].update(rawSupport=700,displayValue=700)
    if mutation=='unknown-to-zero': p['rows'][0]['cells'][2].update(rawSupport=0,displayValue=0,reviewEligible=True)
    if mutation=='retarget-stable-id': p['rows'][1]['target']['stableClusterID']='wrong-cluster'
    path=os.path.join(sys.argv[1],mutation+'.xlsx')
    filtered_rows=copy_module.deepcopy([r for r in p['rows'] if any(
        (c.get('rawSupport') is not None and c['rawSupport']>=5 and c['rawSupport']>0) for c in r['cells'])])
    for row in filtered_rows:
        for cell in row['cells']:
            if cell.get('rawSupport') is None or cell['rawSupport']<5:
                cell['displayValue']=None
    snapshot={'schemaVersion':3,'generatedAt':'test','sourceRevision':{'result':'literal'},'hasHaplotypeContent':True,
        'calls':copy_module.deepcopy(oracle['calls']),'colors':copy_module.deepcopy(oracle['colors']),'metadata':[],
        'allMatrix':{'samples':p['samples'],'rows':p['rows'],'loci':['MHC-A']},
        'filteredMatrix':{'samples':p['samples'],'rows':filtered_rows,'loci':['MHC-A']}}
    for index,call in enumerate(snapshot['calls']): call['id']='call-'+str(index)
    if mutation=='diverge-h2': snapshot['calls'][0]['h2']['effective']='WRONG-H2'
    if mutation=='diverge-palette': snapshot['colors'][1]['fillHex']='#FF0000'
    m=render_genotype_snapshot(snapshot,path)
    json.dump(p,open(path+'.payload.json','w')); json.dump(m,open(path+'.manifest.json','w'))
    w=load_workbook(path,data_only=False)
    filtered=w['Genotype Matrix - Filtered']
    if mutation=='filtered-value': filtered.cell(5,4).value=700
    if mutation=='filtered-order':
        for column in range(1,filtered.max_column+1):
            filtered.cell(5,column).value,filtered.cell(6,column).value=filtered.cell(6,column).value,filtered.cell(5,column).value
    if mutation=='filtered-annotation': filtered.cell(5,4).comment=None
    # Confirm the malformed artifact really agrees with its own payload before
    # applying the independent oracle. All XLSX authoring is shipping renderer.
    for ri,row in enumerate(p['rows'],5):
        for ci,cell in enumerate(row['cells'],4):
            assert w['Genotype Matrix - All'].cell(ri,ci).value==cell.get('displayValue')
    native={'minimumReads':5,'samples':copy_module.deepcopy(p['samples']),'rows':[]}
    for row in filtered_rows:
        native_row={'locus':row['target']['locus'],'genotype':row['target']['genotype'],
                    'stableClusterID':row['target'].get('stableClusterID'),'displayName':row['displayName'],'cells':[]}
        for cell in row['cells']:
            native_row['cells'].append({'sampleID':cell['sampleID'],'displayValue':cell.get('displayValue'),
                'review':cell.get('review'),'comment':cell.get('comment'),
                'style':{'fillHex':None,'isBold':False,'isItalic':False}})
        native['rows'].append(native_row)
    try:
        verify_full_current_evidence(oracle,snapshot,w)
        verify_filtered_current_view(oracle,native,snapshot,w)
    except AssertionError as error:
        assert mutation!='baseline', str(error)
        print('REJECTED '+mutation+': '+str(error))
    else:
        accepted.append(mutation)
assert accepted==['baseline'], ('independent oracle accepted coherent corruption',accepted)
print('Accepted exact zero/sparse/call-only baseline; rejected all ten coherent mutations')
"""#
}

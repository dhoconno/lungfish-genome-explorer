import Foundation

extension GenotypeWorkbookPresentation {
    public static let pythonScript = #"""
import json, re, zipfile, tempfile, os
from xml.sax.saxutils import escape as xml_escape
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Font, PatternFill, Protection
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.utils import get_column_letter

_NOTE_BLOCK = '[LGE Edit v2]\nReview operation: keep\nReview value: ""\nComment operation: keep\nComment value: ""\n[/LGE Edit v2]'

def _unique(values, label):
    if len(values) != len(set(values)): raise ValueError('duplicate '+label)

def _note(generated):
    return generated + ('\n' if generated else '') + _NOTE_BLOCK

def _literal(cell, value):
    cell.value = value
    if isinstance(value, str): cell.data_type = 's'

def _validate(p):
    if p.get('schemaVersion') != 2: raise ValueError('unsupported schema')
    if p.get('role') not in ('editable-current','filtered-snapshot'): raise ValueError('invalid role')
    sample_ids=[x['id'] for x in p['samples']]; _unique(sample_ids,'sample id'); _unique(p['loci'],'locus')
    _unique([x['id'] for x in p['rows']],'row id'); _unique([x['id'] for x in p['calls']],'call id')
    roster=set(sample_ids); loci=set(p['loci']); call_targets=[]
    for row in p['rows']:
        ids=[x['sampleID'] for x in row['cells']]
        if len(ids)!=len(sample_ids) or set(ids)!=roster or len(ids)!=len(set(ids)): raise ValueError('invalid cell roster')
        for cell in row['cells']:
            raw=cell.get('rawSupport')
            if raw is not None and (not isinstance(raw,int) or isinstance(raw,bool) or raw<0): raise ValueError('invalid raw support')
    for call in p['calls']:
        if call['sampleID'] not in roster or call['locus'] not in loci: raise ValueError('unknown call target')
        target=(call['sampleID'],call['locus'])
        if target in call_targets: raise ValueError('duplicate call target')
        call_targets.append(target)
        for slot in ('h1','h2'):
            s=call[slot]
            if s['baselineAvailable'] != (s.get('pipeline') is not None): raise ValueError('inconsistent baseline availability')

def _inject_formula_caches(path, caches):
    source=zipfile.ZipFile(path,'r'); fd,tmp=tempfile.mkstemp(suffix='.xlsx',dir=os.path.dirname(os.path.abspath(path))); os.close(fd)
    try:
        with source, zipfile.ZipFile(tmp,'w') as dest:
            for item in source.infolist():
                data=source.read(item.filename)
                if item.filename=='xl/worksheets/sheet1.xml':
                    text=data.decode('utf-8')
                    for address,value in caches.items():
                        pattern=r'(<c[^>]*\br="'+re.escape(address)+r'"[^>]*)(>)(.*?</c>)'
                        def replacement(match, value=value):
                            prefix=re.sub(r'\s+t="[^"]*"','',match.group(1))+' t="str"'
                            body=match.group(3)
                            cached='<v>'+xml_escape(value)+'</v>'
                            if re.search(r'<v(?:\s[^>]*)?>.*?</v>',body,flags=re.S): body=re.sub(r'<v(?:\s[^>]*)?>.*?</v>',lambda _:cached,body,count=1,flags=re.S)
                            elif re.search(r'<v(?:\s[^>]*)?\s*/>',body): body=re.sub(r'<v(?:\s[^>]*)?\s*/>',lambda _:cached,body,count=1)
                            else: body=body.replace('</c>',cached+'</c>')
                            return prefix+match.group(2)+body
                        text,n=re.subn(pattern,replacement,text,count=1,flags=re.S)
                        if n != 1: raise ValueError('formula cache target missing: '+address)
                    data=text.encode('utf-8')
                dest.writestr(item,data)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def render_three_sheet_workbook(payload, output_path):
    _validate(payload)
    wb=Workbook(); matrix=wb.active; matrix.title='Genotype Matrix'; calls=wb.create_sheet('Haplotype Calls'); metadata=wb.create_sheet('Export Metadata')
    call_lookup={(c['sampleID'],c['locus']):(i+2,c) for i,c in enumerate(payload['calls'])}
    colors={(c['locus'],c['call']):(c['fillHex'].lstrip('#').upper(),c['fontHex'].lstrip('#').upper()) for c in payload['colors']}
    manifest={'schemaVersion':2,'role':payload['role'],'sourceRevision':payload['sourceRevision'],'callEditingSupported':payload.get('callEditingSupported',False),'sheetOrder':['Genotype Matrix','Haplotype Calls','Export Metadata'],'callTargets':{},'noteTargets':{},'immutableCells':{},'expectedFormulas':{},'identityCells':{},'allowedNoteGrammarVersion':2}
    headers=['Stable ID','Sample','Locus','Effective H1','H1 import action','H1 status','H1 source','Pipeline H1','Effective H2','H2 import action','H2 status','H2 source','Pipeline H2','Comment']
    calls.append(headers); calls.freeze_panes='B2'; calls.auto_filter.ref='B1:N'+str(len(payload['calls'])+1); calls.column_dimensions['A'].hidden=True
    editable=payload['role']=='editable-current' and payload.get('callEditingSupported',False)
    action_validation=DataValidation(type='list',formula1='"Use entered call,Use pipeline call"'); calls.add_data_validation(action_validation)
    for r,call in enumerate(payload['calls'],2):
        vals=[call['id'],call['sampleID'],call['locus'],call['h1']['effective'],'Use entered call',call['h1']['status'],call['h1']['source'],call['h1'].get('pipeline'),call['h2']['effective'],'Use entered call',call['h2']['status'],call['h2']['source'],call['h2'].get('pipeline'),call.get('comment')]
        for col,val in enumerate(vals,1): _literal(calls.cell(r,col),val)
        action_validation.add(calls.cell(r,5)); action_validation.add(calls.cell(r,10))
        for slot,prefix,vcol,acol in [('h1','H1',4,5),('h2','H2',9,10)]:
            s=call[slot]; slot_editable=editable and s['baselineAvailable']
            calls.cell(r,vcol).protection=Protection(locked=not slot_editable); calls.cell(r,acol).protection=Protection(locked=not slot_editable)
            target=manifest['callTargets'].setdefault(call['id'],{'sampleID':call['sampleID'],'locus':call['locus']})
            target[slot]={'valueCell':calls.cell(r,vcol).coordinate,'actionCell':calls.cell(r,acol).coordinate,'baselineAvailable':s['baselineAvailable'],'pipeline':s.get('pipeline'),'effective':s['effective']}
        manifest['identityCells']['call:'+call['id']]={'sheet':'Haplotype Calls','cell':'A'+str(r),'value':call['id']}
    calls.protection.sheet=True; calls.protection.selectLockedCells=False; calls.protection.selectUnlockedCells=True
    for cell in calls[1]: cell.font=Font(bold=True)
    matrix['A1']='Stable ID'; matrix['B1']='Locus'; matrix['C1']='Slot / allele'; matrix.column_dimensions['A'].hidden=True
    for c,sample in enumerate(payload['samples'],4):
        _literal(matrix.cell(1,c),sample['name']); manifest['identityCells']['sample:'+sample['id']]={'sheet':'Genotype Matrix','cell':matrix.cell(1,c).coordinate,'value':sample['name']}
        generated='Sample comment: '+json.dumps(sample['comment'],ensure_ascii=False) if sample.get('comment') is not None else ''
        if generated: matrix.cell(1,c).comment=Comment(_note(generated),'LGE')
        manifest['noteTargets']['sample:'+sample['id']]={'sheet':'Genotype Matrix','cell':matrix.cell(1,c).coordinate,'target':{'kind':'sample','sampleID':sample['id']},'rawSupport':None,'reviewEligible':False,'currentComment':sample.get('comment'),'currentReview':None,'generatedText':_note(generated) if generated else ''}
    formula_caches={}
    for li,locus in enumerate(payload['loci']):
        for offset,slot in enumerate(('h1','h2')):
            r=2+li*2+offset; _literal(matrix.cell(r,2),locus); matrix.cell(r,3).value=slot.upper()
            for c,sample in enumerate(payload['samples'],4):
                present=call_lookup.get((sample['id'],locus)); addr=matrix.cell(r,c).coordinate
                if present is None:
                    matrix.cell(r,c).value=None
                    continue
                callrow,call=present; source_col='D' if slot=='h1' else 'I'
                formula="=IF('Haplotype Calls'!%s%d=\"\",\"\",'Haplotype Calls'!%s%d)"%(source_col,callrow,source_col,callrow)
                matrix.cell(r,c).value=formula; manifest['expectedFormulas'].setdefault('Genotype Matrix',{})[addr]=formula; formula_caches[addr]=call[slot]['effective']
                if (locus,call[slot]['effective']) in colors:
                    fill,font=colors[(locus,call[slot]['effective'])]; matrix.cell(r,c).fill=PatternFill('solid',fgColor=fill); matrix.cell(r,c).font=Font(color=font)
                definitions=[]
                for (defined_locus,defined_call),(fill,font) in colors.items():
                    if defined_locus != locus: continue
                    definitions.append(defined_call)
                    matrix.conditional_formatting.add(addr,FormulaRule(formula=['%s="%s"'%(addr,defined_call.replace('"','""'))],fill=PatternFill('solid',fgColor=fill),font=Font(color=font),stopIfTrue=True))
                if definitions:
                    comparisons=','.join('%s<>"%s"'%(addr,x.replace('"','""')) for x in definitions)
                    matrix.conditional_formatting.add(addr,FormulaRule(formula=['AND('+comparisons+')'],fill=PatternFill('solid',fgColor='FFFFFF'),font=Font(color='000000'),stopIfTrue=True))
    header=2+2*len(payload['loci']); matrix.cell(header,1).value='Stable ID'; matrix.cell(header,2).value='Locus'; matrix.cell(header,3).value='Allele'
    for c,sample in enumerate(payload['samples'],4): _literal(matrix.cell(header,c),sample['name'])
    for rr,row in enumerate(payload['rows'],header+1):
        _literal(matrix.cell(rr,1),row['id']); _literal(matrix.cell(rr,2),row['target']['locus']); _literal(matrix.cell(rr,3),row['displayName'])
        manifest['identityCells']['row:'+row['id']]={'sheet':'Genotype Matrix','cell':'A'+str(rr),'value':row['id']}
        if row.get('fillHex'): matrix.cell(rr,3).fill=PatternFill('solid',fgColor=row['fillHex'].lstrip('#'))
        generated='Row comment: '+json.dumps(row['comment'],ensure_ascii=False) if row.get('comment') is not None else ''
        if generated: matrix.cell(rr,3).comment=Comment(_note(generated),'LGE')
        manifest['noteTargets']['row:'+row['id']]={'sheet':'Genotype Matrix','cell':'C'+str(rr),'target':row['target'],'rawSupport':None,'reviewEligible':False,'currentComment':row.get('comment'),'currentReview':None,'generatedText':_note(generated) if generated else ''}
        by_sample={x['sampleID']:x for x in row['cells']}
        for c,sample in enumerate(payload['samples'],4):
            cell=by_sample[sample['id']]; out=matrix.cell(rr,c); out.value=cell.get('displayValue')
            if cell.get('fillHex'): out.fill=PatternFill('solid',fgColor=cell['fillHex'].lstrip('#'))
            target={'kind':'cell','rowID':row['id'],'sampleID':sample['id'],'locus':row['target']['locus'],'genotype':row['target']['genotype']}
            if row['target'].get('stableClusterID') is not None: target['stableClusterID']=row['target']['stableClusterID']
            raw=cell.get('rawSupport'); display=cell.get('displayValue')
            target_id='cell:'+row['id']+':'+sample['id']
            generated='Evidence: display='+json.dumps(display)+', raw support='+json.dumps(raw)
            if cell.get('comment') is not None: generated+='\nCurrent comment: '+json.dumps(cell['comment'],ensure_ascii=False)
            if cell.get('review') is not None: generated+='\nCurrent review: '+json.dumps(cell['review'],ensure_ascii=False)
            text=_note(generated) if cell['reviewEligible'] and (cell.get('comment') is not None or cell.get('review') is not None) else generated
            if text: out.comment=Comment(text,'LGE')
            manifest['noteTargets'][target_id]={'sheet':'Genotype Matrix','cell':out.coordinate,'target':target,'rawSupport':raw,'reviewEligible':cell['reviewEligible'],'currentComment':cell.get('comment'),'currentReview':cell.get('review'),'generatedText':text}
    matrix.freeze_panes='D'+str(header); matrix.auto_filter.ref='B%d:%s%d'%(header,get_column_letter(3+len(payload['samples'])),header+len(payload['rows']))
    matrix.protection.sheet=True; matrix.protection.selectLockedCells=True; matrix.protection.selectUnlockedCells=True
    for c in range(1,matrix.max_column+1): matrix.cell(header,c).font=Font(bold=True)
    instructions=[['Workbook role',payload['role']],['Source revision',json.dumps(payload['sourceRevision'],sort_keys=True)],['Scope','All evidence' if payload['role']=='editable-current' else 'Captured filtered evidence'],['Editing','Edit current H1/H2 and explicit import action only; legacy slots without baselines stay locked.'],['Notes','Traditional Excel Notes contain immutable generated evidence plus an editable LGE block. Threaded Comments are not imported.'],['Clear semantics','Deleting or blanking a Note never clears data. Use explicit clear in the block and review in LGE.'],['Eligible Note template',_NOTE_BLOCK]]+payload.get('metadata',[])
    for r,row in enumerate(instructions,1):
        for c,value in enumerate(row,1): _literal(metadata.cell(r,c),value)
    metadata.freeze_panes='A2'; metadata.column_dimensions['A'].width=24; metadata.column_dimensions['B'].width=100; metadata['A1'].font=Font(bold=True)
    for ws in wb.worksheets:
        for row in ws.iter_rows():
            for cell in row:
                if cell.value is not None and cell.protection.locked:
                    manifest['immutableCells'][ws.title+'!'+cell.coordinate]={'type':cell.data_type,'value':cell.value,'hyperlink':cell.hyperlink.target if cell.hyperlink else None}
    wb.calculation.fullCalcOnLoad=True; wb.calculation.forceFullCalc=True; wb.calculation.calcMode='auto'
    wb.save(output_path)
    _inject_formula_caches(output_path,formula_caches)
    return manifest
"""#
}

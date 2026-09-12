import Foundation

extension GenotypeWorkbookPresentation {
    public static let pythonScript = #"""
import json, re, zipfile, tempfile, os
from xml.sax.saxutils import escape as xml_escape
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Font, PatternFill, Protection, Alignment, Border, Side
from copy import copy
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

def _apply_style(cell, style, legacy_fill=None):
    # A captured record, including nil fill/false traits, is authoritative.
    style = style if style is not None else {'fillHex':legacy_fill}
    fill=style.get('fillHex'); text=style.get('textHex'); border=style.get('borderHex')
    cell.fill=PatternFill('solid',fgColor=fill.lstrip('#')) if fill else PatternFill()
    cell.font=Font(color=text.lstrip('#') if text else None,bold=style.get('isBold',False),italic=style.get('isItalic',False))
    if border:
        side=Side(style='thin',color=border.lstrip('#')); cell.border=Border(left=side,right=side,top=side,bottom=side)

def _opaque_fill(rgb):
    rgb=rgb.lstrip('#')[-6:]
    return PatternFill('solid',fgColor='FF'+rgb,bgColor='FF'+rgb)

def _call_color(sheet, cell, locus, value, colors):
    if (locus,value) in colors:
        fill,font=colors[(locus,value)]; cell.fill=PatternFill('solid',fgColor=fill); cell.font=Font(color=font)
    definitions=[]; addr=cell.coordinate
    for (defined_locus,defined_call),(fill,font) in colors.items():
        if defined_locus != locus: continue
        definitions.append(defined_call)
        sheet.conditional_formatting.add(addr,FormulaRule(formula=['%s="%s"'%(addr,defined_call.replace('"','""'))],fill=_opaque_fill(fill),font=Font(color=font),stopIfTrue=True))
    if definitions:
        comparisons=','.join('%s<>"%s"'%(addr,x.replace('"','""')) for x in definitions)
        sheet.conditional_formatting.add(addr,FormulaRule(formula=['AND('+comparisons+')'],fill=_opaque_fill('FFFFFF'),font=Font(color='000000'),stopIfTrue=True))

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
    headers=['Stable ID','Sample','Locus','Effective H1','Effective H2','H1 import action','H2 import action','H1 status','H2 status','H1 source','H2 source','Pipeline H1','Pipeline H2','Comment']
    calls.append(headers); calls.freeze_panes='B2'; calls.auto_filter.ref='B1:N'+str(len(payload['calls'])+1); calls.column_dimensions['A'].hidden=True
    editable=payload['role']=='editable-current' and payload.get('callEditingSupported',False)
    action_validation=DataValidation(type='list',formula1='"Use entered call,Use pipeline call"'); calls.add_data_validation(action_validation)
    for r,call in enumerate(payload['calls'],2):
        sample_name=next(s['name'] for s in payload['samples'] if s['id']==call['sampleID'])
        vals=[call['id'],sample_name,call['locus'],call['h1']['effective'],call['h2']['effective'],'Use entered call','Use entered call',call['h1']['status'],call['h2']['status'],call['h1']['source'],call['h2']['source'],call['h1'].get('pipeline'),call['h2'].get('pipeline'),call.get('comment')]
        for col,val in enumerate(vals,1): _literal(calls.cell(r,col),val)
        action_validation.add(calls.cell(r,6)); action_validation.add(calls.cell(r,7))
        for slot,prefix,vcol,acol in [('h1','H1',4,6),('h2','H2',5,7)]:
            s=call[slot]; slot_editable=editable and s['baselineAvailable']
            calls.cell(r,vcol).protection=Protection(locked=not slot_editable); calls.cell(r,acol).protection=Protection(locked=not slot_editable)
            target=manifest['callTargets'].setdefault(call['id'],{'sampleID':call['sampleID'],'locus':call['locus']})
            target[slot]={'valueCell':calls.cell(r,vcol).coordinate,'actionCell':calls.cell(r,acol).coordinate,'baselineAvailable':s['baselineAvailable'],'pipeline':s.get('pipeline'),'effective':s['effective']}
            _call_color(calls,calls.cell(r,vcol),call['locus'],s['effective'],colors)
        manifest['identityCells']['call:'+call['id']]={'sheet':'Haplotype Calls','cell':'A'+str(r),'value':call['id']}
    calls.protection.sheet=True; calls.protection.selectLockedCells=False; calls.protection.selectUnlockedCells=False; calls.protection.autoFilter=False
    for cell in calls[1]: cell.font=Font(bold=True)
    for col in range(2,15): calls.column_dimensions[get_column_letter(col)].width=24 if col in (6,7) else (40 if col==14 else 18)
    for row in calls:
        for cell in row: cell.alignment=Alignment(vertical='center',wrap_text=True)
    calls.row_dimensions[1].height=32
    for r in range(2,calls.max_row+1): calls.row_dimensions[r].height=30
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
                callrow,call=present; source_col='D' if slot=='h1' else 'E'
                formula="=IF('Haplotype Calls'!%s%d=\"\",\"\",'Haplotype Calls'!%s%d)"%(source_col,callrow,source_col,callrow)
                matrix.cell(r,c).value=formula; manifest['expectedFormulas'].setdefault('Genotype Matrix',{})[addr]=formula; formula_caches[addr]=call[slot]['effective']
                _call_color(matrix,matrix.cell(r,c),locus,call[slot]['effective'],colors)
    header=2+2*len(payload['loci']); matrix.cell(header,1).value='Stable ID'; matrix.cell(header,2).value='Locus'; matrix.cell(header,3).value='Allele'
    for c,sample in enumerate(payload['samples'],4): _literal(matrix.cell(header,c),sample['name'])
    for rr,row in enumerate(payload['rows'],header+1):
        _literal(matrix.cell(rr,1),row['id']); _literal(matrix.cell(rr,2),row['target']['locus']); _literal(matrix.cell(rr,3),row['displayName'])
        manifest['identityCells']['row:'+row['id']]={'sheet':'Genotype Matrix','cell':'A'+str(rr),'value':row['id']}
        _apply_style(matrix.cell(rr,3),row.get('style'),row.get('fillHex'))
        generated='Row comment: '+json.dumps(row['comment'],ensure_ascii=False) if row.get('comment') is not None else ''
        if generated: matrix.cell(rr,3).comment=Comment(_note(generated),'LGE')
        manifest['noteTargets']['row:'+row['id']]={'sheet':'Genotype Matrix','cell':'C'+str(rr),'target':row['target'],'rawSupport':None,'reviewEligible':False,'currentComment':row.get('comment'),'currentReview':None,'generatedText':_note(generated) if generated else ''}
        by_sample={x['sampleID']:x for x in row['cells']}
        for c,sample in enumerate(payload['samples'],4):
            cell=by_sample[sample['id']]; out=matrix.cell(rr,c); out.value=cell.get('displayValue')
            _apply_style(out,cell.get('style'),cell.get('fillHex'))
            if cell.get('review')=='false-positive':
                out.number_format='"["0"]"'; font=copy(out.font); font.italic=True; font.color='767676'; out.font=font
            elif cell.get('review')=='false-negative':
                out.number_format='0;-0;"FN"'
                side=Side(style='mediumDashed',color='C65911'); out.border=Border(left=side,right=side,top=side,bottom=side)
                if out.fill.patternType is None: out.fill=PatternFill('solid',fgColor='FFF2CC')
                font=copy(out.font); font.bold=True
                if font.color is None: font.color='7F6000'
                out.font=font
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
    matrix.protection.sheet=True; matrix.protection.selectLockedCells=False; matrix.protection.selectUnlockedCells=False; matrix.protection.autoFilter=False
    # Notes attach to locked evidence; allow editing drawing objects (traditional
    # Notes) while importer validation still protects generated text and counts.
    matrix.protection.objects=False
    matrix.column_dimensions['B'].width=18; matrix.column_dimensions['C'].width=64
    for c in range(4,matrix.max_column+1): matrix.column_dimensions[get_column_letter(c)].width=18
    for row in matrix:
        for cell in row: cell.alignment=Alignment(vertical='center',wrap_text=True)
    for r in range(1,matrix.max_row+1): matrix.row_dimensions[r].height=30 if r>header or r in (1,header) else 22
    for c in range(1,matrix.max_column+1): matrix.cell(header,c).font=Font(bold=True)
    extra=payload.get('metadata',[])
    scope=next((r[1] for r in extra if r[0]=='Scope'),'All evidence' if payload['role']=='editable-current' else 'Captured filtered evidence')
    editing='Filtered snapshot for viewing. Edit calls and annotations in LGE or current.xlsx.'
    if payload['role']=='editable-current':
        editing='Edit H1/H2 in Haplotype Calls; choose Use pipeline call to queue a reset for LGE review. Slots without baselines stay locked.' if editable else 'Current workbook. Haplotype calls are read-only here; edit them in LGE. Eligible matrix Notes can be reviewed and imported using the instructions below.'
    instructions=[['Workbook role',payload['role']],['Source revision',json.dumps(payload['sourceRevision'],sort_keys=True)],['Scope',scope],['Editing',editing],['Notes','Edit the existing LGE block in a traditional Excel Note, or append one after the evidence if absent. Never add a second block. Keep generated evidence unchanged.'],['Note operations','Use keep, set, or clear. Values must be quoted JSON strings. Set review to "false-positive" (positive reads) or "false-negative" (exact zero). Set comment to your text.'],['Apply edits','Save the workbook, return to LGE, then choose Review Excel changes and accept the proposed edits.'],['JSON values','Use quoted JSON strings; for a line break enter \\n inside the quotes (for example "first\\nsecond").'],['Clear semantics','Deleting a Note never clears data. Set the relevant operation to clear and its value to ""; review changes in LGE.'],['Eligible Note template',_NOTE_BLOCK],['Comment example','[LGE Edit v2]\nReview operation: keep\nReview value: ""\nComment operation: set\nComment value: "Check this allele"\n[/LGE Edit v2]']]+[r for r in extra if r[0]!='Scope']
    if payload['role']=='filtered-snapshot':
        edit_keys={'Notes','Note operations','Apply edits','JSON values','Clear semantics','Eligible Note template','Comment example'}
        instructions=[r for r in instructions if r[0] not in edit_keys]
    for r,row in enumerate(instructions,1):
        for c,value in enumerate(row,1): _literal(metadata.cell(r,c),value)
    metadata.freeze_panes='A2'; metadata.column_dimensions['A'].width=24; metadata.column_dimensions['B'].width=100; metadata['A1'].font=Font(bold=True)
    for row in metadata:
        for cell in row: cell.alignment=Alignment(vertical='top',wrap_text=True)
        metadata.row_dimensions[row[0].row].height=max(30,8+16*sum(max(1,(len(line)+89)//90) for line in str(row[1].value).split('\n')))
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

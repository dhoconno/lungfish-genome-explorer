import Foundation

extension GenotypeEditableWorkbookService {
    static let readerScript = #"""
import sys, json, platform, openpyxl
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path, data_only=False, keep_links=True)
# SEED
sheets = {}
evidence = {}
evidence['__workbook__'] = {'defined_names': json.dumps({k: v.attr_text for k, v in wb.defined_names.items()}, sort_keys=True), 'epoch': str(wb.epoch), 'external_links': str([str(getattr(getattr(link, 'file_link', None), 'Target', '')) for link in wb._external_links])}
for ws in wb.worksheets:
    if ws.title in ('Edit Calls', 'Edit Matrix'):
        rows = []
        for row in ws.iter_rows():
            if any(c.data_type == 'f' for c in row):
                raise ValueError('Formulas are not allowed in editing tables')
            rows.append(['' if c.value is None else str(c.value) for c in row])
        while rows and not any(rows[-1]):
            rows.pop()
        sheets[ws.title] = rows
    else:
        sheets[ws.title] = []
        cells = {}
        for row in ws.iter_rows():
            for c in row:
                if c.value is not None or c.comment or c.hyperlink:
                    cells[c.coordinate] = json.dumps([c.data_type, c.value, c.comment.text if c.comment else None, c.hyperlink.target if c.hyperlink else None], sort_keys=True, default=str)
        cells['__merged__'] = str(sorted(str(r) for r in ws.merged_cells.ranges))
        evidence[ws.title] = cells
with open(sys.argv[2], 'w') as f:
    json.dump({'document': {'sheets': sheets, 'evidence': evidence}, 'runtime': {'executable': sys.executable, 'python': platform.python_version(), 'openpyxl': openpyxl.__version__, 'platform': platform.platform()}}, f, sort_keys=True)
"""#

    static let seedScript = #"""
def seed_editable_tables(workbook, calls, annotations, catalog, call_editing_supported=True):
    import hashlib, json
    from openpyxl.styles import Protection, Font
    from openpyxl.worksheet.datavalidation import DataValidation
    def identity(value):
        return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    def table(name, headers, records, mutable):
        if name in workbook.sheetnames:
            del workbook[name]
        ws = workbook.create_sheet(name)
        ws.append(headers)
        for record in records:
            ws.append(record)
            # Values are scientific/annotation text, never executable Excel formulas.
            for cell in ws[ws.max_row]:
                if isinstance(cell.value, str):
                    cell.data_type = 's'
        ws.freeze_panes = 'A2'
        ws.auto_filter.ref = ws.dimensions
        ws.protection.sheet = True
        for column, header in enumerate(headers, 1):
            ws.cell(1, column).font = Font(bold=True)
            ws.column_dimensions[ws.cell(1, column).column_letter].width = 24
            if header in mutable:
                for row in range(2, ws.max_row + 1):
                    ws.cell(row, column).protection = Protection(locked=False)
            if header.endswith('operation') or header == 'Operation':
                validation = DataValidation(type='list', formula1='"keep,set,clear"')
                validation.errorTitle = 'Explicit operation required'
                validation.error = 'Use keep, set, or clear. Blank cells never delete an annotation.'
                validation.showErrorMessage = True
                ws.add_data_validation(validation)
                if ws.max_row > 1:
                    validation.add(f'{ws.cell(2,column).coordinate}:{ws.cell(ws.max_row,column).coordinate}')
        return ws
    if not calls and 'Edit Calls' in workbook.sheetnames:
        previous = workbook['Edit Calls']
        headers = [c.value for c in previous[1]]
        preserved = {}
        for values in previous.iter_rows(min_row=2, values_only=True):
            record = dict(zip(headers, values))
            sample, locus, slot = record['Sample'], record['Locus'], record['Slot']
            call = preserved.setdefault((sample, locus), {'sample': sample, 'locus': locus, 'haplotype1': '', 'haplotype2': ''})
            key = 'haplotype1' if slot == 'h1' else 'haplotype2'
            call[key] = record.get('Effective call') or ''
            if record.get('Baseline available') == 'yes':
                call['baselineHaplotype1' if slot == 'h1' else 'baselineHaplotype2'] = record.get('Baseline call') or ''
        calls = list(preserved.values())
    call_records = []
    # Preserve the established exact-locus last-wins generation contract. IDs
    # in the resulting editable table are unique and import rejects duplicates.
    exact_calls = {(c['sample'], c['locus']): c for c in calls}
    for call in exact_calls.values():
        for slot, key, baseline_key in [('h1', 'haplotype1', 'baselineHaplotype1'), ('h2', 'haplotype2', 'baselineHaplotype2')]:
            sample, locus = call['sample'], call['locus']
            row_id = identity([sample, locus, slot])
            effective = call[key]
            # A normalized effective H2 is never a substitute for raw evidence.
            baseline = call.get(baseline_key)
            available = baseline is not None
            call_records.append([row_id, sample, locus, slot, effective, baseline if available else '', 'keep', '', 'yes' if available else 'no'])
    call_sheet = table('Edit Calls', ['ID', 'Sample', 'Locus', 'Slot', 'Effective call', 'Baseline call', 'Operation', 'Value', 'Baseline available'], call_records, {'Operation', 'Value'} if call_editing_supported else set())
    for row in range(2, call_sheet.max_row + 1):
        if call_sheet.cell(row, 9).value != 'yes':
            for column in (7, 8):
                call_sheet.cell(row, column).protection = Protection(locked=True)
    targets = {}
    roster = catalog.get('samples') or sorted(set(c['sample'] for c in calls))
    for sample in roster:
        t = {'kind': 'column', 'sample': sample}
        targets[identity(t)] = (t, '')
    for row in catalog.get('rows', []):
        base = {'locus': row['locus'], 'genotype': row['display_name']}
        if row.get('stable_id') is not None:
            base['stableClusterID'] = row['stable_id']
        row_target = dict(base, kind='row')
        targets[identity(row_target)] = (row_target, '')
        support = {r['sample']: r['support'] for r in row['support_by_sample']}
        if set(support) != set(roster):
            raise ValueError('Reviewable row evidence roster is incomplete')
        for sample in roster:
            t = dict(base, kind='cell', sample=sample)
            if identity(t) in targets:
                raise ValueError('Ambiguous matrix identity')
            targets[identity(t)] = (t, support[sample])
    for record in annotations.get('matrixComments', []) + annotations.get('matrixReviews', []):
        t = record['target']
        if identity(t) not in targets:
            targets[identity(t)] = (t, '')
    from datetime import datetime
    resolved_comments = {}
    for comment in annotations.get('matrixComments', []):
        key = identity(comment['target'])
        prior = resolved_comments.get(key)
        if prior:
            try:
                if datetime.fromisoformat(comment['timestamp'].replace('Z', '+00:00')) < datetime.fromisoformat(prior['timestamp'].replace('Z', '+00:00')):
                    continue
            except (ValueError, KeyError):
                pass
        resolved_comments[key] = comment
    comments = {key: comment['body'] for key, comment in resolved_comments.items()}
    reviews = {identity(c['target']): c['disposition'] for c in annotations.get('matrixReviews', [])}
    def target_label(t):
        raw = t.get('genotype', '')
        alleles = next((part[8:] for part in raw.split('|')[1:] if part.startswith('alleles=')), '')
        label = ' / '.join(alleles.split(',')) if alleles else raw
        context = ' | '.join(str(t[key]) for key in ('kind', 'sample', 'locus') if t.get(key))
        if t.get('stableClusterID'):
            context += ' | ' + t['stableClusterID']
        return context + ('\n' + label if label else '')
    matrix_records = [[i, json.dumps(t, sort_keys=True), reads, reviews.get(i, ''), comments.get(i, ''), 'keep', '', 'keep', '', target_label(t)] for i, (t, reads) in sorted(targets.items())]
    matrix_sheet = table('Edit Matrix', ['ID', 'Target', 'Reads', 'Current review', 'Current comment', 'Review operation', 'Review value', 'Comment operation', 'Comment value', 'Target label'], matrix_records, {'Review operation', 'Review value', 'Comment operation', 'Comment value'})
    from openpyxl.styles import Alignment
    matrix_sheet.column_dimensions['A'].hidden = True
    matrix_sheet.column_dimensions['B'].hidden = True
    for col, width in [('C',9), ('D',16), ('E',22), ('F',13), ('G',17), ('H',13), ('I',22), ('J',68)]:
        matrix_sheet.column_dimensions[col].width = width
    matrix_sheet.row_dimensions[1].height = 30
    for row in matrix_sheet:
        for cell in row:
            cell.alignment = Alignment(wrap_text=True, vertical='center')
        if row[0].row > 1:
            matrix_sheet.row_dimensions[row[0].row].height = max(32, 16 * (1 + (len(str(row[9].value)) + 59) // 60))
    if 'Editing Guide' in workbook.sheetnames:
        del workbook['Editing Guide']
    guide = workbook.create_sheet('Editing Guide')
    guide.append(['Editing rule', 'Instructions'])
    guide.append(['H1/H2', 'Set or clear overrides only where a raw baseline is available.' if call_editing_supported else 'Legacy manual assignments: H1/H2 calls are read-only. Use the LGE assignment editor.'])
    guide.append(['Operations', 'Use keep, set, or clear. Blank cells or missing rows never delete annotations.'])
    guide.append(['Review values', 'false-positive requires positive raw support; false-negative requires authoritative zero support.'])
    guide.append(['Scientific sheets', 'Read-only evidence. Edit only the unlocked operation and value cells in Edit Calls and Edit Matrix.'])
    guide.append(['Annotation revision', identity(annotations)])
    guide.column_dimensions['A'].width = 25
    guide.column_dimensions['B'].width = 110
    for ws in workbook.worksheets:
        if ws.title not in ('Edit Calls', 'Edit Matrix'):
            ws.protection.sheet = True
"""#
}

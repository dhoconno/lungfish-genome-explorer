import Foundation

extension GenotypeWorkbookPresentation {
    public static let snapshotPythonScript = #"""
import json, re
from copy import copy
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Protection, Side
from openpyxl.utils import get_column_letter

def _literal(cell, value):
    cell.value = value
    if isinstance(value, str):
        cell.data_type = 's'

def _invalid(message):
    raise ValueError('invalid snapshot: ' + message)

def _string(value, label, allow_none=False):
    if value is None and allow_none:
        return
    if not isinstance(value, str):
        _invalid(label + ' must be a string')

def _identity(value, label):
    _string(value, label)
    if not value:
        _invalid(label + ' must not be empty')

def _unique(values, label):
    if len(values) != len(set(values)):
        _invalid('duplicate ' + label)

def _count(value, label):
    if value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 0):
        _invalid(label + ' must be a nonnegative integer or null')

def _hex(value, label, allow_none=True):
    if value is None and allow_none:
        return
    _string(value, label)
    if re.fullmatch(r'#?[0-9A-Fa-f]{6}', value) is None:
        _invalid(label + ' must be a six-digit RGB color')

def _style(style, label, legacy_fill=None):
    _hex(legacy_fill, label + '.fillHex')
    if style is None:
        return
    if not isinstance(style, dict):
        _invalid(label + ' must be an object or null')
    for key in ('fillHex', 'textHex', 'borderHex'):
        _hex(style.get(key), label + '.' + key)
    for key in ('isBold', 'isItalic'):
        if not isinstance(style.get(key, False), bool):
            _invalid(label + '.' + key + ' must be boolean')

def _validate_matrix(matrix, label):
    if not isinstance(matrix, dict):
        _invalid(label + ' must be an object')
    for key in ('samples', 'loci', 'rows'):
        if not isinstance(matrix.get(key), list):
            _invalid(label + '.' + key + ' must be an array')
    sample_ids = []
    for sample_index, sample in enumerate(matrix['samples']):
        if not isinstance(sample, dict):
            _invalid(label + ' sample must be an object')
        _identity(sample.get('id'), label + ' sample id')
        _string(sample.get('name'), label + ' sample name')
        _string(sample.get('comment'), label + ' sample comment', allow_none=True)
        sample_ids.append(sample['id'])
    _unique(sample_ids, label + ' sample id')
    for locus in matrix['loci']:
        _identity(locus, label + ' locus')
    _unique(matrix['loci'], label + ' locus')
    row_ids = []
    roster = set(sample_ids)
    for row_index, row in enumerate(matrix['rows']):
        if not isinstance(row, dict):
            _invalid(label + ' row must be an object')
        _identity(row.get('id'), label + ' row id')
        row_ids.append(row['id'])
        target = row.get('target')
        if not isinstance(target, dict):
            _invalid(label + ' row target must be an object')
        for key in ('kind', 'locus', 'genotype'):
            _string(target.get(key), label + ' target ' + key)
        _string(target.get('stableClusterID'), label + ' target stableClusterID', allow_none=True)
        _string(row.get('displayName'), label + ' row displayName')
        _string(row.get('comment'), label + ' row comment', allow_none=True)
        _style(row.get('style'), label + ' row style', row.get('fillHex'))
        cells = row.get('cells')
        if not isinstance(cells, list):
            _invalid(label + ' row cells must be an array')
        cell_ids = []
        for cell in cells:
            if not isinstance(cell, dict):
                _invalid(label + ' cell must be an object')
            _identity(cell.get('sampleID'), label + ' cell sample id')
            cell_ids.append(cell['sampleID'])
            _count(cell.get('displayValue'), label + ' display value')
            _count(cell.get('rawSupport'), label + ' raw support')
            if not isinstance(cell.get('reviewEligible'), bool):
                _invalid(label + ' reviewEligible must be boolean')
            _string(cell.get('comment'), label + ' cell comment', allow_none=True)
            _string(cell.get('review'), label + ' cell review', allow_none=True)
            _style(cell.get('style'), label + ' cell style', cell.get('fillHex'))
        if len(cell_ids) != len(sample_ids) or set(cell_ids) != roster or len(cell_ids) != len(set(cell_ids)):
            _invalid(label + ' row has invalid cell roster')
    _unique(row_ids, label + ' row id')
    return {
        'samples': {sample['id']: sample for sample in matrix['samples']},
        'rows': {row['id']: row for row in matrix['rows']},
    }

def _validate_filtered_consistency(all_matrix, filtered_matrix, all_index, filtered_index):
    for sample_id, sample in filtered_index['samples'].items():
        if sample_id not in all_index['samples']:
            _invalid('unknown filtered sample')
        if sample != all_index['samples'][sample_id]:
            _invalid('inconsistent filtered sample identity')
    all_loci = set(all_matrix['loci'])
    if any(locus not in all_loci for locus in filtered_matrix['loci']):
        _invalid('unknown filtered locus')
    for row_id, row in filtered_index['rows'].items():
        source = all_index['rows'].get(row_id)
        if source is None:
            _invalid('unknown filtered row')
        # Each view can abbreviate its label; stable target identity and
        # scientific annotations still have to agree.
        for key in ('target', 'comment'):
            if row.get(key) != source.get(key):
                _invalid('inconsistent filtered row identity')
        source_cells = {cell['sampleID']: cell for cell in source['cells']}
        for cell in row['cells']:
            source_cell = source_cells[cell['sampleID']]
            for key in ('rawSupport', 'reviewEligible', 'comment', 'review'):
                if cell.get(key) != source_cell.get(key):
                    _invalid('inconsistent filtered cell evidence')

def _validate_snapshot(payload):
    if not isinstance(payload, dict) or payload.get('schemaVersion') != 3:
        _invalid('unsupported schema version')
    _string(payload.get('generatedAt'), 'generatedAt')
    if not payload['generatedAt']:
        _invalid('generatedAt must not be empty')
    source_revision = payload.get('sourceRevision')
    if not isinstance(source_revision, dict) or not source_revision:
        _invalid('sourceRevision must be a nonempty string map')
    for key, value in source_revision.items():
        _identity(key, 'sourceRevision key')
        _string(value, 'sourceRevision value')
    if not isinstance(payload.get('hasHaplotypeContent'), bool):
        _invalid('hasHaplotypeContent must be boolean')
    all_matrix = payload.get('allMatrix')
    filtered_matrix = payload.get('filteredMatrix')
    all_index = _validate_matrix(all_matrix, 'all matrix')
    filtered_index = _validate_matrix(filtered_matrix, 'filtered matrix')
    _validate_filtered_consistency(all_matrix, filtered_matrix, all_index, filtered_index)

    calls = payload.get('calls')
    if not isinstance(calls, list):
        _invalid('calls must be an array')
    call_ids = []
    call_targets = []
    all_samples = set(all_index['samples'])
    call_loci = set(all_matrix['loci'])
    for call in calls:
        if not isinstance(call, dict):
            _invalid('call must be an object')
        _identity(call.get('id'), 'call id')
        _identity(call.get('sampleID'), 'call sample id')
        _identity(call.get('locus'), 'call locus')
        call_ids.append(call['id'])
        if call['sampleID'] not in all_samples or call['locus'] not in call_loci:
            _invalid('unknown call target')
        call_targets.append((call['sampleID'], call['locus']))
        _string(call.get('comment'), 'call comment', allow_none=True)
        for slot_name in ('h1', 'h2'):
            slot = call.get(slot_name)
            if not isinstance(slot, dict):
                _invalid('call slot must be an object')
            _string(slot.get('effective'), 'call effective value')
            _string(slot.get('pipeline'), 'call pipeline value', allow_none=True)
            _string(slot.get('status'), 'call status')
            _string(slot.get('source'), 'call source')
            if not isinstance(slot.get('baselineAvailable'), bool):
                _invalid('call baselineAvailable must be boolean')
            if slot['baselineAvailable'] != (slot.get('pipeline') is not None):
                _invalid('inconsistent call baseline availability')
    _unique(call_ids, 'call id')
    _unique(call_targets, 'call target')

    colors = payload.get('colors')
    if not isinstance(colors, list):
        _invalid('colors must be an array')
    color_targets = []
    for color in colors:
        if not isinstance(color, dict):
            _invalid('color must be an object')
        _string(color.get('locus'), 'color locus')
        _string(color.get('call'), 'color call')
        _hex(color.get('fillHex'), 'color fillHex', allow_none=False)
        _hex(color.get('fontHex'), 'color fontHex', allow_none=False)
        color_targets.append((color['locus'], color['call']))
    _unique(color_targets, 'color target')

    metadata = payload.get('metadata')
    if not isinstance(metadata, list):
        _invalid('metadata must be an array')
    for row in metadata:
        if not isinstance(row, list) or any(not isinstance(value, str) for value in row):
            _invalid('metadata rows must contain strings')

def _color_lookup(payload):
    return {
        (item['locus'], item['call']): (
            item['fillHex'].lstrip('#').upper(),
            item['fontHex'].lstrip('#').upper(),
        )
        for item in payload['colors']
    }

def _apply_call_color(cell, locus, value, colors):
    color = colors.get((locus, value))
    if color is None:
        return
    fill, font = color
    cell.fill = PatternFill('solid', fgColor=fill)
    cell.font = Font(color=font)

def _apply_style(cell, style, legacy_fill=None):
    resolved = style if style is not None else {'fillHex': legacy_fill}
    fill = resolved.get('fillHex')
    text = resolved.get('textHex')
    border = resolved.get('borderHex')
    cell.fill = PatternFill('solid', fgColor=fill.lstrip('#')) if fill else PatternFill()
    cell.font = Font(
        color=text.lstrip('#') if text else None,
        bold=resolved.get('isBold', False),
        italic=resolved.get('isItalic', False),
    )
    if border:
        side = Side(style='thin', color=border.lstrip('#'))
        cell.border = Border(left=side, right=side, top=side, bottom=side)
    else:
        cell.border = Border()

def _valid_review(cell):
    if not cell['reviewEligible']:
        return None
    review = cell.get('review')
    raw = cell.get('rawSupport')
    if review == 'false-positive' and isinstance(raw, int) and not isinstance(raw, bool) and raw > 0:
        return review
    if review == 'false-negative' and isinstance(raw, int) and not isinstance(raw, bool) and raw == 0:
        return review
    return None

def _apply_review(cell, review):
    if review == 'false-positive':
        cell.number_format = '"["0"]"'
        font = copy(cell.font)
        font.italic = True
        font.color = '767676'
        cell.font = font
    elif review == 'false-negative':
        cell.number_format = '0;-0;"FN"'
        side = Side(style='mediumDashed', color='C65911')
        cell.border = Border(left=side, right=side, top=side, bottom=side)
        if cell.fill.patternType is None:
            cell.fill = PatternFill('solid', fgColor='FFF2CC')
        font = copy(cell.font)
        font.bold = True
        if font.color is None:
            font.color = '7F6000'
        cell.font = font

def _sample_comment(sample):
    if sample.get('comment') is None:
        return None
    return 'Sample comment: ' + json.dumps(sample['comment'], ensure_ascii=False)

def _row_comment(row):
    if row.get('comment') is None:
        return None
    return 'Row comment: ' + json.dumps(row['comment'], ensure_ascii=False)

def _cell_comment(cell, review):
    generated = 'Evidence: display=' + json.dumps(cell.get('displayValue')) + ', raw support=' + json.dumps(cell.get('rawSupport'))
    if cell.get('comment') is not None:
        generated += '\nCurrent comment: ' + json.dumps(cell['comment'], ensure_ascii=False)
    if review is not None:
        generated += '\nCurrent review: ' + json.dumps(review, ensure_ascii=False)
    return generated

def _slot_comment(slot_name, slot):
    return 'Haplotype slot: ' + slot_name.upper() + '\nStatus: ' + slot['status'] + '\nSource: ' + slot['source']

def _finish_sheet(sheet, header_rows):
    for row_number in header_rows:
        for cell in sheet[row_number]:
            cell.font = Font(bold=True)
    for row in sheet.iter_rows():
        for cell in row:
            cell.alignment = Alignment(vertical='center', wrap_text=True)
            cell.protection = Protection(locked=True)
    sheet.protection.sheet = True
    sheet.protection.selectLockedCells = False
    sheet.protection.selectUnlockedCells = False
    sheet.protection.autoFilter = False
    sheet.protection.objects = True

def _render_calls(workbook, payload, colors):
    sheet = workbook.create_sheet('Haplotype Calls')
    headers = [
        'Stable ID', 'Sample', 'Locus', 'Effective H1', 'Effective H2',
        'H1 status', 'H2 status', 'H1 source', 'H2 source',
        'Pipeline H1', 'Pipeline H2', 'Comment',
    ]
    sheet.append(headers)
    names = {sample['id']: sample['name'] for sample in payload['allMatrix']['samples']}
    for row_number, call in enumerate(payload['calls'], 2):
        values = [
            call['id'], names[call['sampleID']], call['locus'],
            call['h1']['effective'], call['h2']['effective'],
            call['h1']['status'], call['h2']['status'],
            call['h1']['source'], call['h2']['source'],
            call['h1'].get('pipeline'), call['h2'].get('pipeline'),
            call.get('comment'),
        ]
        for column, value in enumerate(values, 1):
            _literal(sheet.cell(row_number, column), value)
        _apply_call_color(sheet.cell(row_number, 4), call['locus'], call['h1']['effective'], colors)
        _apply_call_color(sheet.cell(row_number, 5), call['locus'], call['h2']['effective'], colors)
    sheet.freeze_panes = 'B2'
    sheet.auto_filter.ref = 'B1:L' + str(max(1, len(payload['calls']) + 1))
    sheet.column_dimensions['A'].hidden = True
    for column in range(2, 13):
        sheet.column_dimensions[get_column_letter(column)].width = 40 if column == 12 else 18
    sheet.row_dimensions[1].height = 32
    for row_number in range(2, sheet.max_row + 1):
        sheet.row_dimensions[row_number].height = 30
    _finish_sheet(sheet, [1])

def _render_matrix(workbook, title, matrix, payload, colors):
    sheet = workbook.create_sheet(title)
    calls = {(call['sampleID'], call['locus']): call for call in payload['calls']}
    has_bands = payload['hasHaplotypeContent'] and bool(matrix['loci'])

    if has_bands:
        _literal(sheet['A1'], 'Stable ID')
        _literal(sheet['B1'], 'Locus')
        _literal(sheet['C1'], 'Slot / allele')
        for column, sample in enumerate(matrix['samples'], 4):
            _literal(sheet.cell(1, column), sample['name'])
            generated = _sample_comment(sample)
            if generated:
                sheet.cell(1, column).comment = Comment(generated, 'LGE')
        for locus_index, locus in enumerate(matrix['loci']):
            for slot_offset, slot in enumerate(('h1', 'h2')):
                row_number = 2 + locus_index * 2 + slot_offset
                _literal(sheet.cell(row_number, 2), locus)
                _literal(sheet.cell(row_number, 3), slot.upper())
                for column, sample in enumerate(matrix['samples'], 4):
                    call = calls.get((sample['id'], locus))
                    if call is None:
                        continue
                    value = call[slot]['effective']
                    cell = sheet.cell(row_number, column)
                    _literal(cell, value)
                    _apply_call_color(cell, locus, value, colors)
                    cell.comment = Comment(_slot_comment(slot, call[slot]), 'LGE')
        header_row = 2 + 2 * len(matrix['loci'])
    else:
        header_row = 1

    _literal(sheet.cell(header_row, 1), 'Stable ID')
    _literal(sheet.cell(header_row, 2), 'Locus')
    _literal(sheet.cell(header_row, 3), 'Allele')
    for column, sample in enumerate(matrix['samples'], 4):
        _literal(sheet.cell(header_row, column), sample['name'])
        generated = _sample_comment(sample)
        if generated and not has_bands:
            sheet.cell(header_row, column).comment = Comment(generated, 'LGE')
    for row_number, row in enumerate(matrix['rows'], header_row + 1):
        _literal(sheet.cell(row_number, 1), row['id'])
        _literal(sheet.cell(row_number, 2), row['target']['locus'])
        _literal(sheet.cell(row_number, 3), row['displayName'])
        _apply_style(sheet.cell(row_number, 3), row.get('style'), row.get('fillHex'))
        generated = _row_comment(row)
        if generated:
            sheet.cell(row_number, 3).comment = Comment(generated, 'LGE')
        by_sample = {cell['sampleID']: cell for cell in row['cells']}
        for column, sample in enumerate(matrix['samples'], 4):
            captured = by_sample[sample['id']]
            cell = sheet.cell(row_number, column)
            _literal(cell, captured.get('displayValue'))
            _apply_style(cell, captured.get('style'), captured.get('fillHex'))
            review = _valid_review(captured)
            _apply_review(cell, review)
            cell.comment = Comment(_cell_comment(captured, review), 'LGE')

    sheet.column_dimensions['A'].hidden = True
    sheet.column_dimensions['B'].width = 18
    sheet.column_dimensions['C'].width = 64
    for column in range(4, 4 + len(matrix['samples'])):
        sheet.column_dimensions[get_column_letter(column)].width = 18
    sheet.freeze_panes = 'D' + str(header_row)
    sheet.auto_filter.ref = 'B%d:%s%d' % (
        header_row,
        get_column_letter(max(3, 3 + len(matrix['samples']))),
        header_row + len(matrix['rows']),
    )
    for row_number in range(1, sheet.max_row + 1):
        sheet.row_dimensions[row_number].height = 30 if row_number > header_row or row_number in (1, header_row) else 22
    _finish_sheet(sheet, sorted(set(([1] if has_bands else []) + [header_row])))

def _render_metadata(workbook, payload):
    sheet = workbook.create_sheet('Export Metadata')
    rows = [
        ['Snapshot schema', '3'],
        ['Generated at', payload['generatedAt']],
        ['Source revision', json.dumps(payload['sourceRevision'], sort_keys=True)],
        ['Workbook', 'Static point-in-time report. Make edits in LGE and export again.'],
    ] + payload.get('metadata', [])
    for row_number, row in enumerate(rows, 1):
        for column, value in enumerate(row, 1):
            _literal(sheet.cell(row_number, column), value)
    sheet.freeze_panes = 'A2'
    sheet.column_dimensions['A'].width = 24
    sheet.column_dimensions['B'].width = 100
    for row_number in range(1, sheet.max_row + 1):
        value = str(sheet.cell(row_number, 2).value or '')
        lines = sum(max(1, (len(line) + 89) // 90) for line in value.split('\n'))
        sheet.row_dimensions[row_number].height = max(30, 8 + 16 * lines)
    _finish_sheet(sheet, [1])

def _summary(workbook):
    return {
        'schemaVersion': 3,
        'sheets': [
            {
                'name': sheet.title,
                'rowCount': sheet.max_row,
                'cellCount': sum(1 for row in sheet.iter_rows() for cell in row if cell.value is not None),
            }
            for sheet in workbook.worksheets
        ],
    }

def render_genotype_snapshot(payload, output_path):
    _validate_snapshot(payload)
    workbook = Workbook()
    workbook.remove(workbook.active)
    colors = _color_lookup(payload)
    if payload['hasHaplotypeContent']:
        _render_calls(workbook, payload, colors)
    _render_matrix(workbook, 'Genotype Matrix - All', payload['allMatrix'], payload, colors)
    _render_matrix(workbook, 'Genotype Matrix - Filtered', payload['filteredMatrix'], payload, colors)
    _render_metadata(workbook, payload)
    result = _summary(workbook)
    workbook.save(output_path)
    return result
"""#
}

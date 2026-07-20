import Foundation

extension GenotypeWorkbookRevisionService {
    var workbookOverrideScript: String {
        #"""
import json
import re
import sys
import platform
import openpyxl
from copy import copy
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

input_path = sys.argv[1]
output_path = sys.argv[2]
calls_path = sys.argv[3]
sidecar_path = sys.argv[4] if len(sys.argv) > 4 else ""
configuration_path = sys.argv[5] if len(sys.argv) > 5 else ""

with open(calls_path) as handle:
    call_rows = json.load(handle)

sidecar = {}
if sidecar_path:
    try:
        with open(sidecar_path) as handle:
            sidecar = json.load(handle)
    except FileNotFoundError:
        sidecar = {}

candidate_configuration = {}
if configuration_path:
    with open(configuration_path) as handle:
        candidate_configuration = json.load(handle)


def load_json_path(key, collection):
    path = candidate_configuration.get(key)
    if not path:
        return {collection: [], "observations": []}
    with open(path) as handle:
        document = json.load(handle)
    if int(document.get("schema_version", 0)) != 1:
        raise ValueError(f"Unsupported candidate workbook JSON schema in {path}")
    if not isinstance(document.get(collection), list) or not isinstance(document.get("observations"), list):
        raise ValueError(f"Malformed candidate workbook JSON in {path}")
    return document


candidate_document = load_json_path("candidate_json_path", "candidates")
unnameable_document = load_json_path("unnameable_json_path", "clusters")
candidate_records = sorted(candidate_document.get("candidates", []), key=lambda item: str(item.get("stable_cluster_id") or ""))
unnameable_records = sorted(unnameable_document.get("clusters", []), key=lambda item: str(item.get("stable_cluster_id") or ""))
candidate_observations = candidate_document.get("observations", [])
unnameable_observations = unnameable_document.get("observations", [])

wb = load_workbook(input_path)

MCM_FAMILIES = ["M1", "M2", "M3", "M4", "M5", "M6", "M7"]
MCM_STYLES = {
    "M1": {"font": "000000"},
    "M2": {"font": "FF0000"},
    "M3": {"font": "0432FF"},
    "M4": {"font": "00B050"},
    "M5": {"font": "FFC000"},
    "M6": {"font": "595959"},
    "M7": {"font": "7030A0"},
}
SUMMARY_LOCI = [
    ("MHC-A", "MHC-A"),
    ("MHC-B", "MHC-B"),
    ("MHC-DQ", "MHC-DQA/B"),
    ("MHC-DP", "MHC-DPA/B"),
]
FULL_LOCI = ["MHC-A", "MHC-B", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
WRITABLE_LOCI = {"MHC-A", "MHC-B", "MHC-DQ", "MHC-DP"}


def clean(value):
    if value is None:
        return ""
    return str(value).strip()


def family(value):
    text = clean(value)
    if not text or text == "-" or text.startswith("ERR"):
        return None
    match = re.search(r"\b(M[1-7])", text)
    return match.group(1) if match else None


def display_family(value):
    return family(value) or clean(value) or "?"


def canonical_locus(locus):
    text = clean(locus)
    if text in ("MHC-DQA", "MHC-DQB"):
        return "MHC-DQ"
    if text in ("MHC-DPA", "MHC-DPB"):
        return "MHC-DP"
    return text


calls_by_sample_locus = {}
for call in call_rows:
    sample = clean(call.get("sample"))
    locus = canonical_locus(call.get("locus"))
    if not sample or not locus:
        continue
    if locus not in WRITABLE_LOCI:
        continue
    calls_by_sample_locus.setdefault(sample, {})[locus] = {
        "haplotype1": clean(call.get("haplotype1")),
        "haplotype2": clean(call.get("haplotype2")),
        "status": clean(call.get("status")),
        "notes": clean(call.get("notes")),
    }

call_overrides = sidecar.get("callOverrides") or []
audit_entries = sidecar.get("auditLog") or []
matrix_styles = sidecar.get("matrixStyles") or []
matrix_comments = sidecar.get("matrixComments") or []


def call_for(sample, locus):
    return calls_by_sample_locus.get(sample, {}).get(canonical_locus(locus), {})


def call_value(sample, locus, index):
    call = call_for(sample, locus)
    key = "haplotype1" if index == 1 else "haplotype2"
    value = call.get(key, "")
    if index == 2 and (not value or value == "-"):
        inferred = inferred_homozygous_family(sample)
        first = call.get("haplotype1", "")
        if inferred and family(first) == inferred:
            return first
    return value or "-"


def inferred_homozygous_family(sample):
    families = []
    for locus in [item[0] for item in SUMMARY_LOCI]:
        call = call_for(sample, locus)
        if not call:
            continue
        first = call.get("haplotype1", "")
        second = call.get("haplotype2", "")
        first_family = family(first)
        second_family = family(second)
        if first_family:
            families.append(first_family)
            if not second_family:
                continue
        if second_family:
            families.append(second_family)
    unique = []
    for item in families:
        if item not in unique:
            unique.append(item)
    return unique[0] if len(unique) == 1 else None


def whole_animal(sample, index):
    families = []
    for locus, _label in SUMMARY_LOCI:
        value = call_value(sample, locus, index)
        item = family(value)
        if item and item not in families:
            families.append(item)
    if not families:
        return "?"
    if len(families) == 1:
        return families[0]
    return "rec" + "".join(families)


def comments(sample):
    values = []
    for locus in sorted(calls_by_sample_locus.get(sample, {})):
        call = call_for(sample, locus)
        status = call.get("status", "")
        note = call.get("notes", "")
        h1 = call.get("haplotype1", "")
        h2 = call.get("haplotype2", "")
        if h1.startswith("ERR") or h2.startswith("ERR"):
            values.append(f"{locus}: {h1}/{h2}".strip("/"))
        elif status and status != "called":
            values.append(f"{locus}: {status}")
        if note:
            values.append(f"{locus}: {note}")
    return "; ".join(values) or None


def header_map(ws):
    values = {}
    for col in range(1, ws.max_column + 1):
        value = ws.cell(1, col).value
        if value is not None:
            values[str(value)] = col
    return values


def sample_row(ws, sample):
    for row in range(1, ws.max_row + 1):
        if clean(ws.cell(row, 1).value) == sample:
            return row
    return None


def sample_col(ws, sample):
    for col in range(1, ws.max_column + 1):
        for row in range(1, min(ws.max_row, 4) + 1):
            if clean(ws.cell(row, col).value) == sample:
                return col
    return None


def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if clean(ws.cell(row, 1).value) == label:
            return row
    return None


def clear_fill(cell):
    cell.fill = PatternFill(fill_type=None)


def style_haplotype(cell, value):
    clear_fill(cell)
    item = family(value)
    if item:
        cell.font = Font(name="Calibri", size=11, color=MCM_STYLES[item]["font"], bold=True)
        cell.alignment = Alignment(horizontal="center", vertical="center")
    elif clean(value).startswith("ERR"):
        cell.font = Font(name="Calibri", size=11, color="9C0006", bold=True)
        cell.alignment = Alignment(horizontal="center", vertical="center")
    else:
        cell.font = Font(name="Calibri", size=11)


def set_cell(cell, value):
    cell.value = value
    style_haplotype(cell, value)


def patch_summary_sheet(sheet_name):
    if sheet_name not in wb.sheetnames:
        return
    ws = wb[sheet_name]
    headers = header_map(ws)
    for sample in calls_by_sample_locus:
        row = sample_row(ws, sample)
        if row is None:
            continue
        if "Haplotype 1" in headers:
            set_cell(ws.cell(row, headers["Haplotype 1"]), whole_animal(sample, 1))
        if "Haplotype 2" in headers:
            set_cell(ws.cell(row, headers["Haplotype 2"]), whole_animal(sample, 2))
        for locus, label in SUMMARY_LOCI:
            h1_header = f"{label} Haplotype 1"
            h2_header = f"{label} Haplotype 2"
            if h1_header in headers:
                set_cell(ws.cell(row, headers[h1_header]), call_value(sample, locus, 1))
            if h2_header in headers:
                set_cell(ws.cell(row, headers[h2_header]), call_value(sample, locus, 2))
        if "Comments" in headers:
            ws.cell(row, headers["Comments"]).value = comments(sample)


def patch_full_sheet():
    if "Full Sequencing Results 1" not in wb.sheetnames:
        return
    ws = wb["Full Sequencing Results 1"]
    for sample in calls_by_sample_locus:
        col = sample_col(ws, sample)
        if col is None:
            continue
        for locus in FULL_LOCI:
            for index in (1, 2):
                row = row_for(ws, f"{locus} Haplotype {index}")
                if row is not None:
                    set_cell(ws.cell(row, col), call_value(sample, locus, index))
        comment_row = row_for(ws, "Comments")
        if comment_row is not None:
            ws.cell(comment_row, col).value = comments(sample)


def upsert_guide_row(label, value):
    if "Interpretation Guide" not in wb.sheetnames:
        ws = wb.create_sheet("Interpretation Guide", 0)
        ws.append(["Field", "Interpretation"])
    ws = wb["Interpretation Guide"]
    target = row_for(ws, label)
    if target is None:
        target = ws.max_row + 1
    ws.cell(target, 1).value = label
    ws.cell(target, 2).value = value
    ws.cell(target, 1).font = Font(name="Calibri", size=11, bold=True)
    ws.cell(target, 2).font = Font(name="Calibri", size=11)


def replace_sheet(name):
    if name in wb.sheetnames:
        del wb[name]
    return wb.create_sheet(name)


def style_table_header(ws):
    fill = PatternFill(fill_type="solid", fgColor="D9EAF7")
    for cell in ws[1]:
        cell.font = Font(name="Calibri", size=11, bold=True)
        cell.fill = fill
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)


def style_table_body(ws):
    for row in ws.iter_rows(min_row=2):
        for cell in row:
            cell.font = Font(name="Calibri", size=11)
            cell.alignment = Alignment(vertical="top", wrap_text=True)


def autosize_columns(ws, max_width=64):
    for column_cells in ws.columns:
        width = 10
        for cell in column_cells:
            value = clean(cell.value)
            if value:
                width = max(width, min(max_width, len(value) + 2))
        ws.column_dimensions[column_cells[0].column_letter].width = width


def write_table_sheet(name, headers, rows):
    ws = replace_sheet(name)
    ws.append(headers)
    for row in rows:
        ws.append(row)
    style_table_header(ws)
    style_table_body(ws)
    autosize_columns(ws)
    ws.freeze_panes = "A2"


def write_override_sheets():
    override_headers = [
        "Sample",
        "Locus",
        "Slot",
        "Original Call",
        "Override Call",
        "Reason",
        "Rationale",
        "Author",
        "Timestamp",
    ]
    override_rows = []
    for entry in call_overrides:
        override_rows.append([
            clean(entry.get("sample")),
            clean(entry.get("locus")),
            clean(entry.get("slot")),
            clean(entry.get("originalCall")),
            clean(entry.get("overrideCall")),
            clean(entry.get("reasonTag")),
            clean(entry.get("rationale")),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
        ])
    write_table_sheet("Overrides", override_headers, override_rows)

    audit_headers = [
        "Action",
        "Sample",
        "Locus",
        "Slot",
        "Before",
        "After",
        "Reason",
        "Rationale",
        "Author",
        "Timestamp",
    ]
    audit_rows = []
    for entry in audit_entries:
        audit_rows.append([
            clean(entry.get("action")),
            clean(entry.get("sample")),
            clean(entry.get("locus")),
            clean(entry.get("slot")),
            clean(entry.get("before")),
            clean(entry.get("after")),
            clean(entry.get("reason")),
            clean(entry.get("rationale")),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
        ])
    write_table_sheet("Audit Log", audit_headers, audit_rows)


def matrix_target_parts(target):
    target = target or {}
    return (
        clean(target.get("kind")),
        clean(target.get("locus")),
        clean(target.get("genotype")),
        clean(target.get("sample")),
    )


def write_matrix_annotation_sheet():
    rows = []
    for entry in matrix_styles:
        target = entry.get("target") or {}
        kind, locus, genotype, sample = matrix_target_parts(target)
        style = entry.get("style") or {}
        rows.append([
            "style",
            kind,
            locus,
            genotype,
            sample,
            clean(style.get("fillColor")),
            clean(style.get("textColor")),
            clean(style.get("borderColor")),
            display_bool(style.get("isBold"), style.get("boldOverride")),
            display_bool(style.get("isItalic"), style.get("italicOverride")),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            "",
        ])
    for entry in matrix_comments:
        target = entry.get("target") or {}
        kind, locus, genotype, sample = matrix_target_parts(target)
        rows.append([
            "comment",
            kind,
            locus,
            genotype,
            sample,
            "",
            "",
            "",
            "",
            "",
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            clean(entry.get("body")),
        ])
    if not rows:
        return
    write_table_sheet(
        "Matrix Annotations",
        [
            "Entry Type",
            "Target Kind",
            "Locus",
            "Genotype",
            "Sample",
            "Fill Color",
            "Text Color",
            "Border Color",
            "Bold",
            "Italic",
            "Author",
            "Timestamp",
            "Comment",
        ],
        rows,
    )


def display_bool(value, override):
    if override is not None:
        return str(bool(override)).lower()
    if value is None:
        return ""
    return str(bool(value)).lower()


def normalize_hex(value):
    text = clean(value).lstrip("#")
    if len(text) == 6 and all(char in "0123456789abcdefABCDEF" for char in text):
        return "FF" + text.upper()
    if len(text) == 8 and all(char in "0123456789abcdefABCDEF" for char in text):
        return text.upper()
    return None


def apply_matrix_style(cell, style):
    if not style:
        return
    font = copy(cell.font)
    text_color = normalize_hex(style.get("textColor"))
    if text_color:
        font.color = text_color
    if style.get("boldOverride") is not None:
        font.bold = bool(style.get("boldOverride"))
    elif style.get("isBold"):
        font.bold = True
    if style.get("italicOverride") is not None:
        font.italic = bool(style.get("italicOverride"))
    elif style.get("isItalic"):
        font.italic = True
    cell.font = font

    fill_color = normalize_hex(style.get("fillColor"))
    if fill_color:
        cell.fill = PatternFill(fill_type="solid", fgColor=fill_color)

    border_color = normalize_hex(style.get("borderColor"))
    if border_color:
        side = Side(style="thin", color=border_color)
        cell.border = Border(left=side, right=side, top=side, bottom=side)


def collect_matrix_style_maps():
    row_styles = {}
    column_styles = {}
    cell_styles = {}
    for entry in matrix_styles:
        target = entry.get("target") or {}
        style = entry.get("style") or {}
        kind, locus, genotype, sample = matrix_target_parts(target)
        if kind == "row" and genotype:
            row_styles[(locus, genotype)] = style
        elif kind == "column" and sample:
            column_styles[sample] = style
        elif kind == "cell" and genotype and sample:
            cell_styles[(locus, genotype, sample)] = style
    return row_styles, column_styles, cell_styles


def collect_matrix_comment_maps():
    row_comments = {}
    column_comments = {}
    cell_comments = {}
    for entry in matrix_comments:
        target = entry.get("target") or {}
        body = clean(entry.get("body"))
        if not body:
            continue
        author = clean(entry.get("author")) or "Lungfish"
        timestamp = clean(entry.get("timestamp"))
        line = f"{body} ({author}{', ' + timestamp if timestamp else ''})"
        kind, locus, genotype, sample = matrix_target_parts(target)
        if kind == "row" and genotype:
            row_comments.setdefault((locus, genotype), []).append(line)
        elif kind == "column" and sample:
            column_comments.setdefault(sample, []).append(line)
        elif kind == "cell" and genotype and sample:
            cell_comments.setdefault((locus, genotype, sample), []).append(line)
    return row_comments, column_comments, cell_comments


def known_matrix_samples():
    names = set(calls_by_sample_locus.keys())
    for entry in matrix_styles + matrix_comments:
        _kind, _locus, _genotype, sample = matrix_target_parts(entry.get("target") or {})
        if sample:
            names.add(sample)
    return names


def sample_columns_for_matrix(ws, sample_names):
    columns = {}
    if sample_names:
        for row in range(1, min(ws.max_row, 25) + 1):
            for col in range(1, ws.max_column + 1):
                value = clean(ws.cell(row, col).value)
                if value in sample_names and value not in columns:
                    columns[value] = (col, row)
        return columns

    for row in range(1, min(ws.max_row, 25) + 1):
        row_label = clean(ws.cell(row, 1).value).lower()
        if row_label not in {"animal id", "gs id", "genotype"}:
            continue
        for col in range(4, ws.max_column + 1):
            value = clean(ws.cell(row, col).value)
            if value and value not in columns:
                columns[value] = (col, row)
    return columns


def genotype_rows_for_matrix(ws):
    rows = {}
    for row in range(1, ws.max_row + 1):
        value = clean(ws.cell(row, 1).value)
        if value:
            rows.setdefault(value, []).append(row)
    return rows


def style_for_matrix_cell(genotype, sample, row_styles, column_styles, cell_styles):
    styles = []
    for (_locus, style_genotype), style in row_styles.items():
        if style_genotype == genotype:
            styles.append(style)
    if sample in column_styles:
        styles.append(column_styles[sample])
    for (_locus, style_genotype, style_sample), style in cell_styles.items():
        if style_genotype == genotype and style_sample == sample:
            styles.append(style)
    return styles


def append_lge_comment(pending, cell, lines):
    if lines:
        pending.setdefault(cell.coordinate, (cell, []))[1].extend(lines)


def set_lge_comments(comment_targets):
    marker = "[LGE Matrix Comments]"
    for cell, lines in comment_targets.values():
        unique = []
        for line in lines:
            if line and line not in unique:
                unique.append(line)
        existing = cell.comment.text if cell.comment else ""
        base = existing.split(marker, 1)[0].rstrip()
        lge_text = marker + "\n" + "\n".join(unique) if unique else ""
        combined = "\n\n".join(part for part in [base, lge_text] if part)
        cell.comment = Comment(combined, "Lungfish") if combined else None


def apply_matrix_annotations_to_workbook():
    if not matrix_styles and not matrix_comments:
        return
    row_styles, column_styles, cell_styles = collect_matrix_style_maps()
    row_comments, column_comments, cell_comments = collect_matrix_comment_maps()
    sample_names = known_matrix_samples()
    for ws in wb.worksheets:
        if ws.title in {"Matrix Annotations", "Overrides", "Audit Log"}:
            continue
        sample_columns = sample_columns_for_matrix(ws, sample_names)
        genotype_rows = genotype_rows_for_matrix(ws)
        if not sample_columns or not genotype_rows:
            continue

        pending_comments = {}
        for sample, (col, header_row) in sample_columns.items():
            append_lge_comment(pending_comments, ws.cell(header_row, col), column_comments.get(sample, []))

        target_genotypes = {
            genotype
            for _locus, genotype in list(row_styles.keys()) + list(row_comments.keys())
            if genotype
        }
        target_genotypes.update(
            genotype
            for _locus, genotype, _sample in list(cell_styles.keys()) + list(cell_comments.keys())
            if genotype
        )
        for genotype in target_genotypes:
            for row in genotype_rows.get(genotype, []):
                label_cell = ws.cell(row, 1)
                for (locus, row_genotype), lines in row_comments.items():
                    if row_genotype == genotype:
                        append_lge_comment(pending_comments, label_cell, lines)
                for sample, (col, _header_row) in sample_columns.items():
                    cell = ws.cell(row, col)
                    for style in style_for_matrix_cell(genotype, sample, row_styles, column_styles, cell_styles):
                        apply_matrix_style(cell, style)
                    for (locus, cell_genotype, cell_sample), lines in cell_comments.items():
                        if cell_genotype == genotype and cell_sample == sample:
                            append_lge_comment(pending_comments, cell, lines)

        set_lge_comments(pending_comments)


# Candidate display visibility is deliberately ignored here: workbooks are durable
# scientific exports and retain every singleton/shared _nov/_ext row.  Only the
# current four RGBA tints are display settings consumed by this explicit update.
def candidate_tint_category(record):
    classification = clean(record.get("classification"))
    support = clean(record.get("support_class"))
    mapping = {
        ("novel", "shared"): "sharedNovel",
        ("novel", "singleton"): "singletonNovel",
        ("extension", "shared"): "sharedExtension",
        ("extension", "singleton"): "singletonExtension",
    }
    category = mapping.get((classification, support))
    if not category:
        raise ValueError(f"Unsupported candidate classification/support: {classification}/{support}")
    return category


def byte_from_unit(value):
    number = float(value)
    if number < 0 or number > 1:
        raise ValueError(f"RGBA component outside [0, 1]: {number}")
    return max(0, min(255, int(number * 255.0 + 0.5)))


def candidate_argb(record):
    category = candidate_tint_category(record)
    tint = (candidate_configuration.get("tints") or {}).get(category)
    if not tint:
        raise ValueError(f"Missing candidate tint: {category}")
    # OOXML/openpyxl stores colors as ARGB. The leading byte is alpha:
    # 00 is transparent and FF is opaque; the UI RGBA values are rounded to bytes.
    return "".join(f"{byte_from_unit(tint[key]):02X}" for key in ("alpha", "red", "green", "blue"))


def observations_by_id():
    grouped = {}
    for observation in candidate_observations + unnameable_observations:
        stable_id = clean(observation.get("stable_cluster_id"))
        grouped.setdefault(stable_id, []).append(observation)
    return grouped


OBSERVATIONS_BY_ID = observations_by_id()


def sample_read_counts(stable_id):
    counts = {}
    for observation in OBSERVATIONS_BY_ID.get(stable_id, []):
        sample = clean(observation.get("sample_id"))
        if sample:
            counts[sample] = counts.get(sample, 0) + int(observation.get("aggregated_sample_read_count") or 0)
    return counts


def candidate_samples():
    return sorted({
        clean(observation.get("sample_id"))
        for observation in candidate_observations + unnameable_observations
        if clean(observation.get("sample_id"))
    })


def evidence_values(locator):
    locator = locator or {}
    return [
        clean(locator.get("bam_path")),
        clean(locator.get("query_name")),
        clean(locator.get("reference_name")),
        clean(locator.get("read_group_id")),
        locator.get("reference_start"),
        clean(locator.get("cigar")),
    ]


CANDIDATE_HEADERS = [
    "Stable Cluster ID", "Provisional Name", "Locus", "Classification", "Support Class",
    "Independent Sample Count", "Occurrence Count", "Total Cluster Reads", "Supporting Sample IDs",
    "FASTA Record ID", "Sequence SHA-256", "BAM Path", "Query Name", "Reference Name",
    "Read Group ID", "Reference Start", "CIGAR", "Closest Reference Name", "Closest Reference Class",
    "SNP Count", "Inserted Bases", "Deleted Bases", "Long Gap Bases", "Comparable Bases",
    "Shorter Coverage", "Identity", "Mapping Quality", "Alignment Score",
]


def candidate_row(record, samples):
    stable_id = clean(record.get("stable_cluster_id"))
    reads = sample_read_counts(stable_id)
    return [
        stable_id,
        clean(record.get("provisional_name")),
        clean(record.get("locus")),
        clean(record.get("classification")),
        clean(record.get("support_class")),
        record.get("independent_sample_count"),
        record.get("occurrence_count"),
        record.get("total_cluster_reads"),
        ";".join(record.get("supporting_sample_ids") or []),
        clean(record.get("fasta_record_id")),
        clean(record.get("sequence_sha256")),
    ] + evidence_values(record.get("selected_evidence")) + [
        clean(record.get("closest_reference_name")),
        clean(record.get("closest_reference_class")),
        record.get("snp_count"),
        record.get("inserted_bases"),
        record.get("deleted_bases"),
        record.get("long_gap_bases"),
        record.get("comparable_bases"),
        record.get("shorter_coverage"),
        record.get("identity"),
        record.get("mapping_quality"),
        record.get("alignment_score"),
    ] + [reads.get(sample) for sample in samples]


def failed_metrics_text(record):
    metrics = record.get("failed_metrics") or {}
    return ";".join(f"{key}={metrics[key]}" for key in sorted(metrics))


def unnameable_rows(record, samples):
    stable_id = clean(record.get("stable_cluster_id"))
    reads = sample_read_counts(stable_id)
    evidence = sorted(record.get("evidence") or [], key=lambda item: (
        clean(item.get("bam_path")), clean(item.get("query_name")), clean(item.get("reference_name")),
        clean(item.get("read_group_id")), int(item.get("reference_start") or 0), clean(item.get("cigar")),
    ))
    evidence = evidence or [None]
    rows = []
    for index, locator in enumerate(evidence, start=1):
        rows.append([
            stable_id,
            clean(record.get("reason")),
            clean(record.get("support_class")),
            record.get("independent_sample_count"),
            record.get("occurrence_count"),
            record.get("total_cluster_reads"),
            ";".join(record.get("supporting_sample_ids") or []),
            clean(record.get("fasta_record_id")),
            clean(record.get("sequence_sha256")),
            failed_metrics_text(record),
            index if locator else None,
            len(record.get("evidence") or []),
        ] + evidence_values(locator) + [reads.get(sample) for sample in samples])
    return rows


def write_candidate_artifact_sheets():
    samples = candidate_samples()
    candidate_ws = replace_sheet("Candidate Alleles")
    candidate_ws.append(CANDIDATE_HEADERS + [f"Sample Reads: {sample}" for sample in samples])
    for record in candidate_records:
        candidate_ws.append(candidate_row(record, samples))
        # This is the only tinted cell on this machine-readable sheet.
        candidate_ws.cell(candidate_ws.max_row, 2).fill = PatternFill(
            fill_type="solid", fgColor=candidate_argb(record)
        )
    style_table_header(candidate_ws)
    style_table_body(candidate_ws)
    autosize_columns(candidate_ws)
    candidate_ws.freeze_panes = "A2"

    unnameable_ws = replace_sheet("Un-nameable Clusters")
    unnameable_ws.append([
        "Stable Cluster ID", "Reason", "Support Class", "Independent Sample Count", "Occurrence Count",
        "Total Cluster Reads", "Supporting Sample IDs", "FASTA Record ID", "Sequence SHA-256", "Failed Metrics",
        "Evidence Ordinal", "Evidence Count", "Evidence BAM Path", "Evidence Query Name", "Evidence Reference Name",
        "Evidence Read Group ID", "Evidence Reference Start", "Evidence CIGAR",
    ] + [f"Sample Reads: {sample}" for sample in samples])
    for record in unnameable_records:
        for row in unnameable_rows(record, samples):
            unnameable_ws.append(row)
    style_table_header(unnameable_ws)
    style_table_body(unnameable_ws)
    autosize_columns(unnameable_ws)
    unnameable_ws.freeze_panes = "A2"


def write_candidates_to_editable_view():
    if not candidate_records:
        return
    samples = candidate_samples()
    if "Full Sequencing Results 1" in wb.sheetnames:
        ws = wb["Full Sequencing Results 1"]
        # Replace only the prior managed candidate block, preserving known/user rows.
        marker_row = row_for(ws, "LGE MHC Candidate Alleles")
        if marker_row is not None:
            ws.delete_rows(marker_row, ws.max_row - marker_row + 1)
        ws.append([])
        ws.append(["LGE MHC Candidate Alleles"])
        ws.append(["Provisional Name", "Stable Cluster ID", "Locus", "Classification", "Support Class"] + samples)
        for record in candidate_records:
            reads = sample_read_counts(clean(record.get("stable_cluster_id")))
            ws.append([
                clean(record.get("provisional_name")), clean(record.get("stable_cluster_id")),
                clean(record.get("locus")), clean(record.get("classification")), clean(record.get("support_class")),
            ] + [reads.get(sample) for sample in samples])
            # The provisional-name cell alone receives the category tint.
            ws.cell(ws.max_row, 1).fill = PatternFill(fill_type="solid", fgColor=candidate_argb(record))
        return

    if "Unified Genotype Pivot" in wb.sheetnames:
        ws = wb["Unified Genotype Pivot"]
    else:
        ws = wb.create_sheet("Unified Genotype Pivot")
        ws.append([
            "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
            "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
            "total_cluster_reads",
        ] + samples)
    headers = [clean(cell.value) for cell in ws[1]]
    call_type_col = headers.index("call_type") + 1 if "call_type" in headers else 1
    for row in range(ws.max_row, 1, -1):
        if clean(ws.cell(row, call_type_col).value).startswith("candidate-"):
            ws.delete_rows(row, 1)
    sample_headers = headers[12:] if len(headers) > 12 else samples
    for record in candidate_records:
        reads = sample_read_counts(clean(record.get("stable_cluster_id")))
        ws.append([
            f"candidate-{clean(record.get('classification'))}",
            clean(record.get("stable_cluster_id")),
            clean(record.get("provisional_name")),
            clean(record.get("stable_cluster_id")),
            clean(record.get("locus")),
            clean(record.get("classification")),
            clean(record.get("support_class")),
            clean(record.get("closest_reference_name")),
            clean(record.get("classification")),
            record.get("occurrence_count"),
            record.get("independent_sample_count"),
            record.get("total_cluster_reads"),
        ] + [reads.get(sample) for sample in sample_headers])
        # Unified pivot provisional/display name is column 3.
        ws.cell(ws.max_row, 3).fill = PatternFill(fill_type="solid", fgColor=candidate_argb(record))


def enrich_legacy_unmatched_sheets():
    candidates = {clean(record.get("stable_cluster_id")): record for record in candidate_records}
    unnameable = {clean(record.get("stable_cluster_id")): record for record in unnameable_records}
    metadata_headers = [
        "provisional_name", "candidate_locus", "candidate_classification", "candidate_support_class",
        "candidate_snp_count", "candidate_inserted_bases", "candidate_deleted_bases",
        "candidate_long_gap_bases", "candidate_closest_reference", "un_nameable_reason",
    ]
    for name in ["Unmatched Clusters", "Unmatched Shared Pivot", "MHC-like Unmatched Clusters", "MHC-like Unmatched Pivot"]:
        if name not in wb.sheetnames:
            continue
        ws = wb[name]
        headers = [clean(cell.value) for cell in ws[1]]
        for header in metadata_headers:
            if header not in headers:
                ws.cell(1, ws.max_column + 1).value = header
                headers.append(header)
        for row in range(2, ws.max_row + 1):
            stable_id = clean(ws.cell(row, 1).value)
            candidate = candidates.get(stable_id)
            unresolved = unnameable.get(stable_id)
            if not candidate and not unresolved:
                # Normalize only legacy display labels; raw stable identifiers stay untouched.
                for field in ["closest_match_id", "closest_reference", "closest_reference_name"]:
                    if field in headers:
                        column = headers.index(field) + 1
                        value = clean(ws.cell(row, column).value).replace("_extension", "_ext")
                        value = re.sub(r"_0SNP", "", value)
                        value = re.sub(r"_([1-9][0-9]*)SNP", lambda match: f"_{match.group(1)}nt_nov", value)
                        ws.cell(row, column).value = value
                continue
            values = {
                "provisional_name": clean(candidate.get("provisional_name")) if candidate else "",
                "candidate_locus": clean(candidate.get("locus")) if candidate else "",
                "candidate_classification": clean(candidate.get("classification")) if candidate else "un-nameable",
                "candidate_support_class": clean((candidate or unresolved).get("support_class")),
                "candidate_snp_count": candidate.get("snp_count") if candidate else "",
                "candidate_inserted_bases": candidate.get("inserted_bases") if candidate else "",
                "candidate_deleted_bases": candidate.get("deleted_bases") if candidate else "",
                "candidate_long_gap_bases": candidate.get("long_gap_bases") if candidate else "",
                "candidate_closest_reference": clean(candidate.get("closest_reference_name")) if candidate else "",
                "un_nameable_reason": clean(unresolved.get("reason")) if unresolved else "",
            }
            for header, value in values.items():
                ws.cell(row, headers.index(header) + 1).value = value
            if candidate:
                authoritative = {
                    "match_source": "reciprocal-minimap2",
                    "closest_match_id": clean(candidate.get("provisional_name")),
                    "closest_reference": clean(candidate.get("closest_reference_name")),
                    "closest_reference_name": clean(candidate.get("closest_reference_name")),
                    "match_class": clean(candidate.get("classification")),
                    "nucleotides_different": candidate.get("snp_count"),
                    "snp_differences": candidate.get("snp_count"),
                    "indel_bases": int(candidate.get("inserted_bases") or 0) + int(candidate.get("deleted_bases") or 0),
                    "aligned_bases": candidate.get("comparable_bases"),
                    "score": candidate.get("alignment_score"),
                    "percent_identity": f"{float(candidate.get('identity') or 0) * 100:.12g}",
                    "query_coverage": f"{float(candidate.get('shorter_coverage') or 0) * 100:.12g}",
                    "inserted_bases": candidate.get("inserted_bases"),
                    "deleted_bases": candidate.get("deleted_bases"),
                    "long_gap_bases": candidate.get("long_gap_bases"),
                    "evalue": "",
                    "bitscore": "",
                }
                for header, value in authoritative.items():
                    if header in headers:
                        ws.cell(row, headers.index(header) + 1).value = value
            else:
                authoritative = {
                    "match_source": "reciprocal-unnameable",
                    "match_class": "un-nameable",
                    "closest_match_id": "",
                    "closest_reference": "",
                    "closest_reference_name": "",
                    "nucleotides_different": "",
                    "snp_differences": "",
                    "indel_bases": "",
                    "inserted_bases": "",
                    "deleted_bases": "",
                    "long_gap_bases": "",
                    "aligned_bases": "",
                    "score": "",
                    "percent_identity": "",
                    "query_coverage": "",
                    "evalue": "",
                    "bitscore": "",
                }
                for header, value in authoritative.items():
                    if header in headers:
                        ws.cell(row, headers.index(header) + 1).value = value


patch_summary_sheet("Abbreviated Haplotypes")
patch_summary_sheet("Custom Sort")
patch_full_sheet()
write_override_sheets()
write_matrix_annotation_sheet()
apply_matrix_annotations_to_workbook()
if candidate_configuration.get("candidate_json_path") or candidate_configuration.get("unnameable_json_path"):
    write_candidate_artifact_sheets()
    write_candidates_to_editable_view()
    enrich_legacy_unmatched_sheets()
upsert_guide_row("Workbook update source", "Lungfish.app Review viewport")
upsert_guide_row("Workbook update note", "current.xlsx reflects sidecar haplotype overrides at the time this workbook revision was created.")
upsert_guide_row("Workbook updated haplotype calls", str(sum(len(calls) for calls in calls_by_sample_locus.values())))
upsert_guide_row("Workbook update overrides", str(len(call_overrides)))
upsert_guide_row("Workbook update matrix styles", str(len(matrix_styles)))
upsert_guide_row("Workbook update matrix comments", str(len(matrix_comments)))
upsert_guide_row("Workbook update audit entries", str(len(audit_entries)))
upsert_guide_row("Workbook update audit source", "annotations.json")
upsert_guide_row("Workbook update MHC candidates", str(len(candidate_records)))
upsert_guide_row("Workbook update un-nameable clusters", str(len(unnameable_records)))
upsert_guide_row("Workbook candidate tint encoding", candidate_configuration.get("ooxml_alpha_semantics", ""))

wb.save(output_path)
print(json.dumps({
    "python_version": platform.python_version(),
    "python_executable": sys.executable,
    "openpyxl_version": openpyxl.__version__,
    "candidate_count": len(candidate_records),
    "unnameable_count": len(unnameable_records),
}, sort_keys=True))
"""#
    }

}

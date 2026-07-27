import Foundation

extension GenotypeWorkbookRevisionService {
    var workbookOverrideScript: String {
        #"""
import json
import hashlib
import re
import shutil
import sys
import platform
import zipfile
import openpyxl
from copy import copy
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter, range_boundaries

input_path = sys.argv[1]
output_path = sys.argv[2]
calls_path = sys.argv[3]
sidecar_path = sys.argv[4] if len(sys.argv) > 4 else ""
configuration_path = sys.argv[5] if len(sys.argv) > 5 else ""
reviewable_row_catalog_path = sys.argv[6] if len(sys.argv) > 6 else ""

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

uses_two_sheet_mhc_contract = bool(candidate_configuration.get("uses_two_sheet_mhc_contract"))
preserve_existing_workbook_projection = bool(
    candidate_configuration.get("preserve_existing_workbook_projection")
)
normalized_unmatched_rows = candidate_configuration.get("normalized_unmatched_rows") or []
known_allele_display_names = candidate_configuration.get("known_allele_display_names") or {}
workbook_samples = candidate_configuration.get("samples") or []
workbook_known_calls = candidate_configuration.get("known_calls") or []
expected_managed_state_authority = str(
    candidate_configuration.get("expected_managed_state_authority") or ""
).strip()
new_managed_state_authority = str(
    candidate_configuration.get("new_managed_state_authority") or ""
).strip()
if not new_managed_state_authority:
    raise ValueError("Managed workbook state authority is missing")

reviewable_row_catalog = {}
if reviewable_row_catalog_path:
    with open(reviewable_row_catalog_path) as handle:
        reviewable_row_catalog = json.load(handle)


def load_json_path(key, collection):
    path = candidate_configuration.get(key)
    if not path:
        return {"schema_version": 1, collection: [], "observations": []}
    with open(path) as handle:
        document = json.load(handle)
    if int(document.get("schema_version", 0)) not in (1, 2, 3, 4):
        raise ValueError(f"Unsupported candidate workbook JSON schema in {path}")
    if not isinstance(document.get(collection), list) or not isinstance(document.get("observations"), list):
        raise ValueError(f"Malformed candidate workbook JSON in {path}")
    return document


candidate_document = ({"schema_version": 2, "candidates": [], "observations": []}
    if uses_two_sheet_mhc_contract else load_json_path("candidate_json_path", "candidates"))
unnameable_document = ({"schema_version": 2, "clusters": [], "observations": []}
    if uses_two_sheet_mhc_contract else load_json_path("unnameable_json_path", "clusters"))
candidate_records = sorted(candidate_document.get("candidates", []), key=lambda item: str(item.get("stable_cluster_id") or ""))
unnameable_records = sorted(unnameable_document.get("clusters", []), key=lambda item: str(item.get("stable_cluster_id") or ""))
candidate_observations = candidate_document.get("observations", [])
unnameable_observations = unnameable_document.get("observations", [])
candidate_schema_version = int(candidate_document.get("schema_version", 1))
unnameable_schema_version = int(unnameable_document.get("schema_version", 1))

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


def natural_sort_key(value):
    # Keep this ASCII token contract in lockstep with MHCAlleleDisplayOrder.
    text = "" if value is None else str(value)
    tokens = []
    start = 0
    while start < len(text):
        is_digits = "0" <= text[start] <= "9"
        end = start + 1
        while end < len(text) and ("0" <= text[end] <= "9") == is_digits:
            end += 1
        chunk = text[start:end]
        if is_digits:
            normalized = chunk.lstrip("0")
            tokens.append((0, len(normalized), normalized))
        else:
            lowered = "".join(
                chr(ord(character) + 32) if "A" <= character <= "Z" else character
                for character in chunk
            )
            tokens.append((1, lowered))
        start = end
    return tuple(tokens)


def numbered_locus(locus, prefix, allows_letter_suffix):
    if not locus.startswith(prefix):
        return False
    remainder = locus[len(prefix):]
    digit_count = 0
    while digit_count < len(remainder) and "0" <= remainder[digit_count] <= "9":
        digit_count += 1
    if digit_count == 0:
        return False
    suffix = remainder[digit_count:]
    return not suffix or (allows_letter_suffix and all(
        "A" <= character <= "Z" or "a" <= character <= "z"
        for character in suffix
    ))


def locus_group_rank(locus):
    if numbered_locus(locus, "A", False):
        return 0
    if locus == "B":
        return 1
    if numbered_locus(locus, "B", True):
        return 2
    return {
        "I": 3,
        "F": 4,
        "G": 5,
        "AG": 6,
        "J": 7,
        "K": 8,
    }.get(locus, 9)


def allele_display_parts(value):
    complete_name = "" if value is None else str(value)
    if not complete_name.strip():
        return 10, "", "", "", ""

    star = complete_name.find("*")
    separator = complete_name.rfind("-", 0, star) if star >= 0 else -1
    if star < 0 or separator < 0:
        return 9, complete_name, "", "", complete_name

    species_prefix = complete_name[:separator]
    locus = complete_name[separator + 1:star]
    allele = complete_name[star + 1:]
    if not species_prefix or not locus or not allele:
        return 9, complete_name, "", "", complete_name
    return locus_group_rank(locus), locus, allele, species_prefix, complete_name


def allele_display_sort_key(display_name, stable_id):
    group, locus, allele, species, complete_name = allele_display_parts(display_name)
    exact_stable_id = "" if stable_id is None else str(stable_id)
    return (
        group,
        natural_sort_key(locus),
        natural_sort_key(allele),
        natural_sort_key(species),
        natural_sort_key(complete_name),
        natural_sort_key(exact_stable_id),
        complete_name,
        exact_stable_id,
    )


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
matrix_reviews = sidecar.get("matrixReviews") or []


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


def write_override_sheets(matrix_review_results):
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
        "Target Kind",
        "Genotype",
        "Stable Cluster ID",
        "Disposition",
        "Validation Status",
        "Validation Reason",
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
            "",
            "",
            "",
            "",
            "",
            "",
        ])
    for result in matrix_review_results:
        entry = result["entry"]
        target = entry.get("target") or {}
        kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
        disposition = clean(entry.get("disposition"))
        audit_rows.append([
            "validateMatrixReview",
            sample,
            locus,
            "",
            "",
            disposition,
            "matrix-review-validation",
            semantic_target_description(target),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            kind,
            genotype,
            stable_id,
            disposition,
            result["status"],
            result["reason"],
        ])
    write_table_sheet("Audit Log", audit_headers, audit_rows)


def matrix_target_parts(target):
    target = target or {}
    return (
        clean(target.get("kind")),
        clean(target.get("locus")),
        clean(target.get("genotype")),
        clean(target.get("sample")),
        clean(target.get("stableClusterID")),
    )


def matrix_target_key(target):
    return matrix_target_parts(target)


def structured_matrix_target(target):
    kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
    return {
        "kind": kind,
        "locus": locus,
        "genotype": genotype,
        "sample": sample,
        "stableClusterID": stable_id or None,
    }


def semantic_target_description(target):
    kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
    identity = " ".join(part for part in [locus, genotype, sample] if part)
    if stable_id:
        identity += f" [{stable_id}]"
    return f"{kind} {identity}".strip()


def timestamp_value(value):
    text = clean(value)
    if not text:
        return None
    try:
        from datetime import datetime, timezone
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except ValueError:
        return None


def resolve_current_annotations(entries):
    resolved = {}
    for entry in entries:
        key = matrix_target_key(entry.get("target") or {})
        existing = resolved.get(key)
        if existing is None:
            resolved[key] = entry
            continue
        existing_date = timestamp_value(existing.get("timestamp"))
        candidate_date = timestamp_value(entry.get("timestamp"))
        if existing_date is None or candidate_date is None or candidate_date >= existing_date:
            resolved[key] = entry
    return list(resolved.values())


resolved_matrix_styles = resolve_current_annotations(matrix_styles)
resolved_matrix_comments = resolve_current_annotations(matrix_comments)
MANAGED_REVIEW_STATE_SHEET = "_LGE Matrix Review State"
MANAGED_REVIEW_STATE_SCHEMA_ID = "org.lungfish.matrix-review-state"
MANAGED_REVIEW_STATE_SCHEMA_VERSION = 4
LEGACY_MANAGED_REVIEW_STATE_HEADERS = [
    "Sheet", "Target Kind", "Locus", "Genotype", "Sample",
    "Stable Cluster ID", "Coordinate", "Disposition", "Original Value",
    "Original Font", "Original Border",
]
UNVERSIONED_MANAGED_REVIEW_STATE_HEADERS = [
    "Sheet", "Target Kind", "Locus", "Genotype", "Sample",
    "Stable Cluster ID", "Coordinate", "Disposition", "Original Value",
    "Original Font", "Original Fill", "Original Border",
    "Expected Managed Value", "Expected Managed Font",
    "Expected Managed Fill", "Expected Managed Border", "Synthetic Row",
    "Adapter", "Synthetic Row Index", "Expected Synthetic Row",
    "Marker Row Index", "Expected Marker Row",
]
VERSIONED_MANAGED_REVIEW_STATE_PREFIX = (
    UNVERSIONED_MANAGED_REVIEW_STATE_HEADERS
    + [MANAGED_REVIEW_STATE_SCHEMA_ID, MANAGED_REVIEW_STATE_SCHEMA_VERSION]
)
VERSION_3_MANAGED_REVIEW_STATE_PREFIX = (
    UNVERSIONED_MANAGED_REVIEW_STATE_HEADERS
    + [MANAGED_REVIEW_STATE_SCHEMA_ID, 3]
)
managed_state_created_for_current_run = False
ANNOTATION_ONLY_BLOCK_CALL_TYPE = "analyst-annotation-only-block"
ANNOTATION_ONLY_CALL_TYPE = "analyst-annotation-only"
ANNOTATION_ONLY_BLOCK_LABEL = "Analyst annotation-only rows"
RETAINED_ANNOTATION_ONLY_BLOCK_CALL_TYPE = (
    "analyst-annotation-only-block-retained"
)
RETAINED_ANNOTATION_ONLY_BLOCK_LABEL = (
    "Analyst annotation-only rows (contains retained analyst edits)"
)
managed_cleanup_warnings = {}


def write_matrix_annotation_sheet(matrix_review_results):
    rows = []
    for entry in resolved_matrix_styles:
        target = entry.get("target") or {}
        kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
        style = entry.get("style") or {}
        rows.append([
            "style",
            kind,
            locus,
            genotype,
            sample,
            stable_id,
            "",
            "not-applicable",
            "",
            clean(style.get("fillColor")),
            clean(style.get("textColor")),
            clean(style.get("borderColor")),
            display_bool(style.get("isBold"), style.get("boldOverride")),
            display_bool(style.get("isItalic"), style.get("italicOverride")),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            "",
        ])
    for entry in resolved_matrix_comments:
        target = entry.get("target") or {}
        kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
        rows.append([
            "comment",
            kind,
            locus,
            genotype,
            sample,
            stable_id,
            "",
            "not-applicable",
            "",
            "",
            "",
            "",
            "",
            "",
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            clean(entry.get("body")),
        ])
    for result in matrix_review_results:
        entry = result["entry"]
        target = entry.get("target") or {}
        kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
        rows.append([
            "review",
            kind,
            locus,
            genotype,
            sample,
            stable_id,
            clean(entry.get("disposition")),
            result["status"],
            result["reason"],
            "",
            "",
            "",
            "",
            "",
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            "",
        ])
    if "Matrix Annotations" in wb.sheetnames:
        del wb["Matrix Annotations"]
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
            "Stable Cluster ID",
            "Disposition",
            "Validation Status",
            "Validation Reason",
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
    for entry in resolved_matrix_styles:
        target = entry.get("target") or {}
        style = entry.get("style") or {}
        kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
        if kind == "row" and genotype:
            row_styles[(locus, genotype, stable_id)] = style
        elif kind == "column" and sample:
            column_styles[sample] = style
        elif kind == "cell" and genotype and sample:
            cell_styles[(locus, genotype, sample, stable_id)] = style
    return row_styles, column_styles, cell_styles


def known_matrix_samples():
    names = set(calls_by_sample_locus.keys())
    for entry in resolved_matrix_styles + resolved_matrix_comments + matrix_reviews:
        _kind, _locus, _genotype, sample, _stable_id = matrix_target_parts(entry.get("target") or {})
        if sample:
            names.add(sample)
    return names


def authoritative_matrix_samples():
    names = known_matrix_samples()
    if reviewable_row_catalog:
        roster = reviewable_row_catalog.get("samples") or []
        names.update(clean(sample) for sample in roster if clean(sample))
    return names


def validation_matrix_samples():
    names = authoritative_matrix_samples()
    if MANAGED_REVIEW_STATE_SHEET in wb.sheetnames:
        managed_review_state_schema()
        state = wb[MANAGED_REVIEW_STATE_SHEET]
        for row in range(2, state.max_row + 1):
            sample = clean(state.cell(row, 5).value)
            if sample:
                names.add(sample)
    return names


def validate_matrix_sample_header_ambiguity():
    sample_names = validation_matrix_samples()
    if not sample_names:
        return
    for ws in wb.worksheets:
        if ws.title in {
            "Matrix Annotations", "Overrides", "Audit Log", MANAGED_REVIEW_STATE_SHEET
        }:
            continue
        for row in range(1, min(ws.max_row, 60) + 1):
            columns = header_columns(ws, row)
            is_unified = "call_type" in columns
            is_generic = any(
                alias in columns for alias in GENOTYPE_HEADER_ALIASES
            )
            if not is_unified and not is_generic:
                continue
            for sample in sample_names:
                exact = [
                    col for col in range(1, ws.max_column + 1)
                    if clean(ws.cell(row, col).value) == sample
                ]
                if len(exact) > 1:
                    raise ValueError(
                        f"Ambiguous workbook layout repeats sample column "
                        f"'{sample}'; workbook was not modified"
                    )


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


def normalized_header(value):
    return re.sub(r"[^a-z0-9]+", "_", clean(value).lower()).strip("_")


UNIFIED_REQUIRED_HEADERS = {
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus",
    "classification", "support_class", "closest_reference", "match_class",
    "occurrence_count", "sample_count", "total_cluster_reads",
}
GENOTYPE_HEADER_ALIASES = (
    "genotype", "display_name", "provisional_allele_name", "provisional_name"
)
TOTAL_HEADER_ALIASES = ("total",)
OBSERVED_HEADER_ALIASES = ("obs", "observed", "observations", "sample_count")
synthetic_rows_for_current_run = {}
WORKBOOK_MATRIX_ADAPTER_VERSION = "lge-workbook-matrix-adapter-v1"
workbook_adapter_decisions = []
managed_review_restoration_decisions = []
false_negative_synthesis_decisions = []
false_negative_target_cell_decisions = []


def header_columns(ws, row):
    values = {}
    for col in range(1, ws.max_column + 1):
        header = normalized_header(ws.cell(row, col).value)
        if header:
            values.setdefault(header, []).append(col)
    return values


def unique_alias_column(columns, aliases, label, required):
    matches = [
        (alias, col)
        for alias in aliases
        for col in columns.get(alias, [])
    ]
    if len(matches) > 1:
        raise ValueError(
            f"Ambiguous workbook layout exposes duplicate {label} aliases; workbook was not modified"
        )
    if not matches:
        if required:
            return None
        return None
    return matches[0][1]


def matrix_layout_adapter(ws, sample_names, requires_synthesis=False):
    candidates = []
    for row in range(1, min(ws.max_row, 60) + 1):
        columns = header_columns(ws, row)
        if "call_type" in columns:
            if len(columns["call_type"]) != 1:
                raise ValueError(
                    "Ambiguous unified workbook layout exposes duplicate call_type headers; "
                    "workbook was not modified"
                )
            duplicate_required = sorted(
                name for name in UNIFIED_REQUIRED_HEADERS
                if len(columns.get(name, [])) > 1
            )
            if duplicate_required:
                raise ValueError(
                    "Ambiguous unified workbook layout exposes duplicate headers: "
                    + ", ".join(duplicate_required)
                )
            missing = sorted(
                name for name in UNIFIED_REQUIRED_HEADERS
                if len(columns.get(name, [])) != 1
            )
            if missing:
                if requires_synthesis:
                    raise ValueError(
                        "Unsupported unified workbook layout is missing required headers: "
                        + ", ".join(missing)
                    )
                continue
            headers = {name: columns[name][0] for name in columns if len(columns[name]) == 1}
            sample_columns = {}
            for sample in sample_names:
                exact = [
                    col for col in columns.get(normalized_header(sample), [])
                    if clean(ws.cell(row, col).value) == sample
                ]
                if len(exact) > 1:
                    raise ValueError(
                        f"Ambiguous unified workbook layout repeats sample column "
                        f"'{sample}'; workbook was not modified"
                    )
                if exact:
                    sample_columns[sample] = exact[0]
            candidates.append({
                "kind": "unified",
                "ws": ws,
                "header_row": row,
                "headers": headers,
                "genotype_col": headers["display_name"],
                "locus_col": headers["locus"],
                "stable_col": headers["stable_cluster_id"],
                "total_col": headers["total_cluster_reads"],
                "observed_col": headers["sample_count"],
                "sample_columns": sample_columns,
            })
            continue

        genotype_col = unique_alias_column(
            columns, GENOTYPE_HEADER_ALIASES, "genotype", False
        )
        if genotype_col is None:
            continue
        total_col = unique_alias_column(columns, TOTAL_HEADER_ALIASES, "Total", False)
        observed_col = unique_alias_column(
            columns, OBSERVED_HEADER_ALIASES, "# Obs.", False
        )
        if requires_synthesis and (total_col is None or observed_col is None):
            continue
        locus_col = unique_alias_column(columns, ("locus",), "locus", False)
        stable_col = unique_alias_column(
            columns, ("stable_cluster_id", "stable_id"), "stable ID", False
        )
        sample_columns = {}
        for sample in sample_names:
            exact = [
                col for col in range(1, ws.max_column + 1)
                if clean(ws.cell(row, col).value) == sample
            ]
            if len(exact) > 1:
                raise ValueError(
                    f"Ambiguous generic workbook layout repeats sample column '{sample}'; "
                    "workbook was not modified"
                )
            if exact:
                sample_columns[sample] = exact[0]
        candidates.append({
            "kind": "generic",
            "ws": ws,
            "header_row": row,
            "headers": {},
            "genotype_col": genotype_col,
            "locus_col": locus_col,
            "stable_col": stable_col,
            "total_col": total_col,
            "observed_col": observed_col,
            "sample_columns": sample_columns,
        })

    if len(candidates) > 1:
        raise ValueError(
            f"Ambiguous workbook layout in '{ws.title}' exposes multiple matrix headers; "
            "workbook was not modified"
        )
    return candidates[0] if candidates else None


def adapter_owned_table(adapter):
    ws = adapter["ws"]
    header_row = adapter["header_row"]
    matches = []
    for table in ws.tables.values():
        min_col, min_row, max_col, max_row = range_boundaries(table.ref)
        if min_row == header_row and min_col <= adapter["genotype_col"] <= max_col:
            matches.append((table, min_col, min_row, max_col, max_row))
    if len(matches) > 1:
        raise ValueError(
            f"Ambiguous workbook layout in '{ws.title}' exposes multiple matrix tables; "
            "workbook was not modified"
        )
    return matches[0] if matches else None


def adapter_owned_column_bounds(adapter):
    owned_table = adapter_owned_table(adapter)
    if owned_table is not None:
        _table, min_col, _min_row, max_col, _max_row = owned_table
        return min_col, max_col
    columns = [
        adapter.get("genotype_col"),
        adapter.get("locus_col"),
        adapter.get("stable_col"),
        adapter.get("total_col"),
        adapter.get("observed_col"),
        *adapter.get("sample_columns", {}).values(),
    ]
    columns = [column for column in columns if isinstance(column, int)]
    if not columns:
        raise ValueError(
            f"Workbook layout in '{adapter['ws'].title}' has no owned matrix columns; "
            "workbook was not modified"
        )
    return min(columns), max(columns)


def adapter_matrix_end(adapter):
    if isinstance(adapter.get("managed_end"), int):
        return adapter["managed_end"]
    owned_table = adapter_owned_table(adapter)
    if owned_table is not None:
        return owned_table[4]
    ws = adapter["ws"]
    header_row = adapter["header_row"]
    descriptor_rows = [
        item["row"] for item in matrix_row_descriptors(ws)
        if item["row"] > header_row
    ]
    return max(descriptor_rows, default=header_row)


def set_adapter_range_end(adapter, end_row):
    ws = adapter["ws"]
    header_row = adapter["header_row"]
    owned_table = adapter_owned_table(adapter)
    if owned_table is not None:
        table, min_col, min_row, max_col, _max_row = owned_table
        updated_ref = (
            f"{get_column_letter(min_col)}{min_row}:"
            f"{get_column_letter(max_col)}{end_row}"
        )
        table.ref = updated_ref
        if table.autoFilter is not None:
            table.autoFilter.ref = updated_ref
    if ws.auto_filter.ref:
        min_col, min_row, max_col, _max_row = range_boundaries(ws.auto_filter.ref)
        if min_row == header_row and min_col <= adapter["genotype_col"] <= max_col:
            ws.auto_filter.ref = (
                f"{get_column_letter(min_col)}{min_row}:"
                f"{get_column_letter(max_col)}{end_row}"
            )


def ensure_adapter_owned_row_is_vacant(adapter, row):
    ws = adapter["ws"]
    min_col, max_col = adapter_owned_column_bounds(adapter)
    for merged_range in ws.merged_cells.ranges:
        if (
            merged_range.min_row <= row <= merged_range.max_row
            and merged_range.min_col <= max_col
            and merged_range.max_col >= min_col
        ):
            raise ValueError(
                f"The next matrix-owned row in '{ws.title}' intersects merged cells; "
                "workbook was not modified"
            )
    for col in range(min_col, max_col + 1):
        cell = ws.cell(row, col)
        if (
            cell.value is not None
            or cell.comment is not None
            or cell.hyperlink is not None
            or cell.has_style
        ):
            raise ValueError(
                f"The next matrix-owned row in '{ws.title}' contains workbook content; "
                "workbook was not modified"
            )


def style_adapter_owned_row(adapter, row):
    ws = adapter["ws"]
    min_col, max_col = adapter_owned_column_bounds(adapter)
    for col in range(min_col, max_col + 1):
        cell = ws.cell(row, col)
        cell.font = Font(name="Calibri", size=11)
        cell.fill = PatternFill(fill_type=None)
        cell.border = Border()
        cell.alignment = Alignment(vertical="center")
        cell.number_format = "General"


def catalog_support(row):
    values = row.get("support_by_sample")
    if not isinstance(values, list):
        raise ValueError("Malformed reviewable-row catalog evidence")
    support = {}
    for item in values:
        if not isinstance(item, dict):
            raise ValueError("Malformed reviewable-row catalog evidence")
        sample = clean(item.get("sample"))
        if not sample or sample in support:
            raise ValueError("Malformed reviewable-row catalog evidence roster")
        value = item.get("support")
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError("Malformed reviewable-row catalog evidence value")
        support[sample] = value
    return support


def authoritative_catalog_row(target, requires_cohort_zero):
    if not reviewable_row_catalog:
        return None, "No authoritative reviewable-row catalog was supplied."
    if (
        clean(reviewable_row_catalog.get("schema_id"))
        != "org.lungfish.genotype.reviewable-row-catalog"
        or int(reviewable_row_catalog.get("schema_version") or 0) != 1
    ):
        raise ValueError("Unsupported reviewable-row catalog schema")
    kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
    if kind != "cell":
        return None, "False-negative reviews require an exact cell target."
    roster = reviewable_row_catalog.get("samples") or []
    if sample not in roster:
        return None, "The selected sample is outside the authoritative roster."
    matches = []
    for row in reviewable_row_catalog.get("rows") or []:
        row_kind = clean(row.get("kind"))
        if clean(row.get("locus")) != locus or clean(row.get("display_name")) != genotype:
            continue
        if stable_id:
            if row_kind == "reference" or clean(row.get("stable_id")) != stable_id:
                continue
        elif row_kind != "reference" or row.get("stable_id") is not None:
            continue
        matches.append(row)
    if not matches:
        return None, "No reviewable-row catalog record exactly matches the target."
    if len(matches) != 1:
        raise ValueError(
            "Ambiguous reviewable-row catalog identity; workbook was not modified"
        )
    row = matches[0]
    support = catalog_support(row)
    if set(support) != set(roster):
        raise ValueError("Reviewable-row catalog evidence does not match its roster")
    if support.get(sample) != 0:
        return None, "False-negative reviews require authoritative sample support of zero."
    if requires_cohort_zero and any(value != 0 for value in support.values()):
        return None, "An annotation-only row requires zero support across the cohort."
    return row, ""


def catalog_identity(row):
    return (
        clean(row.get("kind")),
        clean(row.get("locus")),
        clean(row.get("call_id")),
        clean(row.get("stable_id")),
    )


def append_annotation_only_row(adapter, catalog_row):
    ws = adapter["ws"]
    row = adapter_matrix_end(adapter) + 1
    ensure_adapter_owned_row_is_vacant(adapter, row)
    style_adapter_owned_row(adapter, row)
    if adapter["kind"] == "unified":
        values = {
            "call_type": ANNOTATION_ONLY_CALL_TYPE,
            "call_id": clean(catalog_row.get("call_id")),
            "display_name": clean(catalog_row.get("display_name")),
            "stable_cluster_id": clean(catalog_row.get("stable_id")) or None,
            "locus": clean(catalog_row.get("locus")),
            "classification": ANNOTATION_ONLY_CALL_TYPE,
            "support_class": "zero-support",
            "closest_reference": None,
            "match_class": ANNOTATION_ONLY_CALL_TYPE,
            "occurrence_count": 0,
            "sample_count": 0,
            "total_cluster_reads": 0,
        }
        for header, col in adapter["headers"].items():
            ws.cell(row, col).value = values.get(header)
    else:
        ws.cell(row, adapter["genotype_col"]).value = clean(
            catalog_row.get("display_name")
        )
        if adapter["locus_col"]:
            ws.cell(row, adapter["locus_col"]).value = clean(catalog_row.get("locus"))
        if adapter["stable_col"]:
            ws.cell(row, adapter["stable_col"]).value = (
                clean(catalog_row.get("stable_id")) or None
            )
        ws.cell(row, adapter["total_col"]).value = 0
        ws.cell(row, adapter["observed_col"]).value = 0
    for col in adapter["sample_columns"].values():
        ws.cell(row, col).value = None
    if adapter.get("extend_owned_range"):
        set_adapter_range_end(adapter, row)
    adapter["managed_end"] = row
    return row


def append_annotation_only_marker(adapter):
    ws = adapter["ws"]
    marker_rows = []
    retained_marker_rows = []
    if adapter["kind"] == "unified":
        marker_col = adapter["headers"]["call_type"]
        marker_rows = [
            row for row in range(adapter["header_row"] + 1, ws.max_row + 1)
            if clean(ws.cell(row, marker_col).value) == ANNOTATION_ONLY_BLOCK_CALL_TYPE
        ]
        retained_marker_rows = [
            row for row in range(adapter["header_row"] + 1, ws.max_row + 1)
            if clean(ws.cell(row, marker_col).value)
                == RETAINED_ANNOTATION_ONLY_BLOCK_CALL_TYPE
        ]
    else:
        marker_col = adapter["genotype_col"]
        marker_rows = [
            row for row in range(adapter["header_row"] + 1, ws.max_row + 1)
            if clean(ws.cell(row, marker_col).value) == ANNOTATION_ONLY_BLOCK_LABEL
        ]
        retained_marker_rows = [
            row for row in range(adapter["header_row"] + 1, ws.max_row + 1)
            if clean(ws.cell(row, marker_col).value)
                == RETAINED_ANNOTATION_ONLY_BLOCK_LABEL
        ]
    if marker_rows or retained_marker_rows:
        raise ValueError(
            "An unmanaged analyst annotation-only block already exists; "
            "workbook was not modified"
        )
    matrix_end = adapter_matrix_end(adapter)
    row = matrix_end + 1
    ensure_adapter_owned_row_is_vacant(adapter, row)
    adapter["extend_owned_range"] = True
    style_adapter_owned_row(adapter, row)
    if adapter["kind"] == "unified":
        ws.cell(row, adapter["headers"]["call_type"]).value = (
            ANNOTATION_ONLY_BLOCK_CALL_TYPE
        )
        ws.cell(row, adapter["headers"]["display_name"]).value = (
            ANNOTATION_ONLY_BLOCK_LABEL
        )
    else:
        ws.cell(row, adapter["genotype_col"]).value = ANNOTATION_ONLY_BLOCK_LABEL
    font = copy(ws.cell(row, marker_col).font)
    font.bold = True
    ws.cell(row, marker_col).font = font
    if adapter["extend_owned_range"]:
        set_adapter_range_end(adapter, row)
    adapter["managed_end"] = row
    return row


def prepare_missing_false_negative_rows():
    current_reviews = resolve_current_annotations(matrix_reviews)
    counts = {}
    for entry in matrix_reviews:
        key = matrix_target_key(entry.get("target") or {})
        counts[key] = counts.get(key, 0) + 1
    false_negatives = [
        entry for entry in current_reviews
        if clean(entry.get("disposition")) == "falseNegative"
        and counts.get(matrix_target_key(entry.get("target") or {}), 0) == 1
    ]
    if not false_negatives:
        return
    sample_names = authoritative_matrix_samples()
    adapters = []
    for ws in wb.worksheets:
        if ws.title in {
            "Matrix Annotations", "Overrides", "Audit Log", MANAGED_REVIEW_STATE_SHEET
        }:
            continue
        adapter = matrix_layout_adapter(ws, sample_names, requires_synthesis=True)
        if adapter is not None and adapter["sample_columns"]:
            adapters.append(adapter)
            workbook_adapter_decisions.append({
                "worksheet": ws.title,
                "adapter": adapter["kind"],
                "header_row": adapter["header_row"],
                "sample_count": len(adapter["sample_columns"]),
            })

    required_by_adapter = {}
    unresolved_eligible_target = False
    for entry in false_negatives:
        target = entry.get("target") or {}
        _kind, _locus, _genotype, sample, stable_id = matrix_target_parts(target)
        catalog_row, _catalog_error = authoritative_catalog_row(
            target, requires_cohort_zero=True
        )
        if catalog_row is None:
            continue
        resolved_somewhere = False
        for adapter in adapters:
            if sample not in adapter["sample_columns"]:
                continue
            descriptors = matrix_row_descriptors(adapter["ws"])
            matches, match_error = matching_matrix_rows(descriptors, target)
            if matches:
                resolved_somewhere = True
                continue
            if match_error and not matrix_match_error_is_legitimate_absence(
                match_error
            ):
                raise ValueError(f"{match_error} Workbook was not modified.")
            if stable_id and adapter["stable_col"] is None:
                continue
            if adapter["locus_col"] is None:
                aliases = [
                    row for row in reviewable_row_catalog.get("rows") or []
                    if clean(row.get("display_name")) == clean(catalog_row.get("display_name"))
                ]
                if len(aliases) != 1:
                    raise ValueError(
                        "Generic workbook layout cannot disambiguate duplicate genotype aliases; "
                        "workbook was not modified"
                    )
            required_by_adapter.setdefault(id(adapter), {
                "adapter": adapter,
                "rows": {},
            })["rows"][catalog_identity(catalog_row)] = catalog_row
            resolved_somewhere = True
        if not resolved_somewhere:
            unresolved_eligible_target = True

    if unresolved_eligible_target:
        raise ValueError(
            "Unsupported workbook matrix layout cannot materialize the authoritative "
            "annotation-only row; workbook was not modified"
        )

    for required in required_by_adapter.values():
        adapter = required["adapter"]
        marker_row = append_annotation_only_marker(adapter)
        for catalog_row in sorted(
            required["rows"].values(),
            key=lambda row: (
                clean(row.get("sort_key")),
                clean(row.get("locus")),
                clean(row.get("display_name")),
                clean(row.get("stable_id")),
                clean(row.get("call_id")),
            ),
        ):
            row = append_annotation_only_row(adapter, catalog_row)
            synthetic_rows_for_current_run[(adapter["ws"].title, row)] = {
                "adapter": adapter["kind"],
                "marker_row": marker_row,
            }
            false_negative_synthesis_decisions.append({
                "worksheet": adapter["ws"].title,
                "adapter": adapter["kind"],
                "row": row,
                "marker_row": marker_row,
                "identity": {
                    "kind": clean(catalog_row.get("kind")),
                    "callID": clean(catalog_row.get("call_id")),
                    "displayName": clean(catalog_row.get("display_name")),
                    "locus": clean(catalog_row.get("locus")),
                    "stableID": clean(catalog_row.get("stable_id")) or None,
                },
                "cells": [
                    adapter["ws"].cell(row, col).coordinate
                    for _sample, col in sorted(adapter["sample_columns"].items())
                ],
            })
        invalidate_matrix_descriptor_cache(adapter["ws"])


matrix_descriptor_cache = {}
matrix_descriptor_scan_count = 0


def invalidate_matrix_descriptor_cache(ws):
    matrix_descriptor_cache.pop(id(ws), None)


def compute_matrix_row_descriptors(ws):
    genotype_aliases = ("genotype", "display_name", "provisional_allele_name", "provisional_name")
    stable_aliases = ("stable_cluster_id", "stable_id")
    layout = None
    for row in range(1, min(ws.max_row, 60) + 1):
        headers = {}
        for col in range(1, ws.max_column + 1):
            header = normalized_header(ws.cell(row, col).value)
            if header and header not in headers:
                headers[header] = col
        genotype_col = next((headers[name] for name in genotype_aliases if name in headers), None)
        if genotype_col is None:
            continue
        stable_col = next((headers[name] for name in stable_aliases if name in headers), None)
        locus_col = headers.get("locus")
        layout = (row, genotype_col, locus_col, stable_col)
        if locus_col is not None or stable_col is not None:
            break

    descriptors = []
    if layout is not None:
        header_row, genotype_col, locus_col, stable_col = layout
        for row in range(header_row + 1, ws.max_row + 1):
            genotype = clean(ws.cell(row, genotype_col).value)
            if not genotype:
                continue
            descriptors.append({
                "row": row,
                "label_col": genotype_col,
                "genotype": genotype,
                "locus": clean(ws.cell(row, locus_col).value) if locus_col else "",
                "stable_id": clean(ws.cell(row, stable_col).value) if stable_col else "",
            })
        return descriptors

    for row in range(1, ws.max_row + 1):
        genotype = clean(ws.cell(row, 1).value)
        if genotype:
            descriptors.append({
                "row": row,
                "label_col": 1,
                "genotype": genotype,
                "locus": "",
                "stable_id": "",
            })
    return descriptors


def matrix_row_descriptors(ws):
    global matrix_descriptor_scan_count
    key = id(ws)
    if key not in matrix_descriptor_cache:
        matrix_descriptor_cache[key] = compute_matrix_row_descriptors(ws)
        matrix_descriptor_scan_count += 1
    return matrix_descriptor_cache[key]


def matching_matrix_rows(descriptors, target):
    _kind, locus, genotype, _sample, stable_id = matrix_target_parts(target)
    matches = [item for item in descriptors if item["genotype"] == genotype]
    if not matches:
        return [], "No workbook row matches the exact genotype."

    workbook_loci = {item["locus"] for item in matches if item["locus"]}
    if workbook_loci:
        matches = [item for item in matches if item["locus"] == locus]
        if not matches:
            return [], "No workbook row matches the exact locus and genotype."

    workbook_stable_ids = {item["stable_id"] for item in matches if item["stable_id"]}
    if stable_id:
        if workbook_stable_ids:
            matches = [item for item in matches if item["stable_id"] == stable_id]
            if not matches:
                return [], "No workbook row matches the exact stable cluster ID."
        else:
            return [], "The workbook row does not expose the requested stable cluster ID."
    elif workbook_stable_ids:
        return [], "The target omits a stable cluster ID required to disambiguate workbook rows."

    if len(matches) > 1:
        return [], "The workbook target is ambiguous at the available semantic identity."
    return matches, ""


def matrix_match_error_is_legitimate_absence(error):
    return error in {
        "No workbook row matches the exact genotype.",
        "No workbook row matches the exact locus and genotype.",
        "No workbook row matches the exact stable cluster ID.",
    }


def numeric_review_evidence(value):
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = clean(value)
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1].strip()
    text = text.replace(",", "")
    try:
        return float(text)
    except ValueError:
        return None


def review_display_value(value, number):
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    text = clean(value)
    if text.startswith("[") and text.endswith("]"):
        return text[1:-1].strip()
    return text if text else str(int(number) if number.is_integer() else number)


def validate_matrix_reviews():
    review_count_by_target = {}
    for entry in matrix_reviews:
        key = matrix_target_key(entry.get("target") or {})
        review_count_by_target[key] = review_count_by_target.get(key, 0) + 1
    current_ids = {id(entry) for entry in resolve_current_annotations(matrix_reviews)}
    sample_names = known_matrix_samples()
    worksheets = [
        ws for ws in wb.worksheets
        if ws.title not in {
            "Matrix Annotations", "Overrides", "Audit Log", MANAGED_REVIEW_STATE_SHEET
        }
    ]
    results = []
    for entry in matrix_reviews:
        target = entry.get("target") or {}
        kind, _locus, genotype, sample, _stable_id = matrix_target_parts(target)
        result = {"entry": entry, "status": "invalid", "reason": "", "destinations": []}
        if review_count_by_target.get(matrix_target_key(target), 0) > 1:
            result["reason"] = (
                "Conflicting duplicate review records target the same projection cell."
            )
            results.append(result)
            continue
        if id(entry) not in current_ids:
            result["reason"] = "Superseded by the current review for this exact target."
            results.append(result)
            continue
        if kind != "cell" or not genotype or not sample:
            result["reason"] = "Matrix reviews require an exact cell target."
            results.append(result)
            continue
        disposition = clean(entry.get("disposition"))
        if disposition == "falseNegative":
            _catalog_row, catalog_error = authoritative_catalog_row(
                target, requires_cohort_zero=False
            )
            if _catalog_row is None:
                result["reason"] = catalog_error
                results.append(result)
                continue

        target_destinations = []
        target_errors = []
        for ws in worksheets:
            sample_columns = sample_columns_for_matrix(ws, sample_names)
            if sample not in sample_columns:
                continue
            descriptors = matrix_row_descriptors(ws)
            matches, match_error = matching_matrix_rows(descriptors, target)
            if not matches:
                if any(item["genotype"] == genotype for item in descriptors):
                    target_errors.append(match_error)
                continue
            col, _header_row = sample_columns[sample]
            target_destinations.extend((ws, item, ws.cell(item["row"], col)) for item in matches)

        if not target_destinations:
            result["reason"] = (
                target_errors[0]
                if target_errors
                else "No workbook cell matches the exact review target."
            )
            results.append(result)
            continue

        evidence = [numeric_review_evidence(cell.value) for _ws, _item, cell in target_destinations]
        if disposition == "falsePositive":
            supported_destinations = [
                destination for destination, number in zip(target_destinations, evidence)
                if number is not None and number > 0
            ]
            if not supported_destinations:
                result["reason"] = "False-positive reviews require passedUniqueReads > 0."
                results.append(result)
                continue
            target_destinations = supported_destinations
        elif disposition == "falseNegative":
            if not all(cell.value is None or (number is not None and number <= 0)
                       for (_ws, _item, cell), number in zip(target_destinations, evidence)):
                result["reason"] = "False-negative reviews require passedUniqueReads <= 0 or absent."
                results.append(result)
                continue
        else:
            result["reason"] = f"Unsupported matrix review disposition '{disposition}'."
            results.append(result)
            continue

        result["status"] = "valid"
        result["reason"] = managed_cleanup_warnings.get(
            matrix_target_key(target), ""
        )
        result["destinations"] = target_destinations
        results.append(result)
    return results


def comment_section(label, entry):
    return "\n".join([
        label,
        f"Body: {clean(entry.get('body'))}",
        f"Author: {clean(entry.get('author')) or 'Lungfish'}",
        f"Timestamp: {clean(entry.get('timestamp'))}",
    ])


def strip_lge_comment(cell):
    marker = "[LGE Matrix Comments]"
    if cell.comment is None:
        return "", "Lungfish"
    base = cell.comment.text.split(marker, 1)[0].rstrip()
    return base, cell.comment.author or "Lungfish"


def set_lge_comment(cell, sections):
    base, existing_author = strip_lge_comment(cell)
    marker = "[LGE Matrix Comments]"
    lge_text = marker + "\n" + "\n\n".join(sections) if sections else ""
    combined = "\n\n".join(part for part in [base, lge_text] if part)
    cell.comment = Comment(combined, existing_author if base else "Lungfish") if combined else None


def managed_review_state_sheet():
    global managed_state_created_for_current_run
    if MANAGED_REVIEW_STATE_SHEET in wb.sheetnames:
        if not managed_state_created_for_current_run:
            managed_review_state_schema()
        return wb[MANAGED_REVIEW_STATE_SHEET]
    ws = wb.create_sheet(MANAGED_REVIEW_STATE_SHEET)
    ws.append(
        VERSIONED_MANAGED_REVIEW_STATE_PREFIX
        + [new_managed_state_authority, ""]
    )
    ws.sheet_state = "veryHidden"
    managed_state_created_for_current_run = True
    return ws


def managed_state_payload_digest(
    state,
    authority,
    schema_version=MANAGED_REVIEW_STATE_SCHEMA_VERSION,
):
    def color_payload(color):
        if color is None:
            return None
        color_type = clean(color.type)
        if color_type == "rgb":
            value = clean(color.rgb).upper()
        elif color_type == "indexed":
            value = color.indexed
        elif color_type == "theme":
            value = color.theme
        elif color_type == "auto":
            value = bool(color.auto)
        else:
            value = None
        return {"type": color_type, "value": value}

    def font_payload(font):
        payload = {
            "italic": bool(font.i),
            "color": color_payload(font.color),
        }
        if schema_version >= 4:
            payload["bold"] = bool(font.b)
        return payload

    def fill_payload(fill):
        if schema_version < 4:
            return {
                "type": clean(fill.fill_type),
                "foreground": color_payload(fill.fgColor),
                "background": color_payload(fill.bgColor),
            }
        payload = {
            "class": type(fill).__name__,
            "type": clean(fill.fill_type),
        }
        if hasattr(fill, "fgColor"):
            payload["foreground"] = color_payload(fill.fgColor)
        if hasattr(fill, "bgColor"):
            payload["background"] = color_payload(fill.bgColor)
        for attribute in ("degree", "left", "right", "top", "bottom"):
            if hasattr(fill, attribute):
                payload[attribute] = getattr(fill, attribute)
        if hasattr(fill, "stop"):
            payload["stops"] = [
                {
                    "position": stop.position,
                    "color": color_payload(stop.color),
                }
                for stop in fill.stop
            ]
        return payload

    def side_payload(side):
        if side is None:
            return None
        return {
            "style": clean(side.style),
            "color": color_payload(side.color),
        }

    def border_payload(border):
        return {
            side: side_payload(getattr(border, side))
            for side in ("left", "right", "top", "bottom", "diagonal")
        }

    rows = []
    for row in range(2, state.max_row + 1):
        cells = []
        for col in range(1, len(UNVERSIONED_MANAGED_REVIEW_STATE_HEADERS) + 1):
            cell = state.cell(row, col)
            payload = {
                "value": serialize_managed_value(cell.value),
            }
            if col in (10, 14):
                payload["font"] = font_payload(cell.font)
            elif col in (11, 15):
                payload["fill"] = fill_payload(cell.fill)
            elif col in (12, 16):
                payload["border"] = border_payload(cell.border)
            cells.append(payload)
        rows.append(cells)
    payload = json.dumps(
        {"authority": authority, "rows": rows},
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def validate_legacy_managed_state(state):
    for row in range(2, state.max_row + 1):
        destination = state_destination(state, row)
        coordinate = clean(state.cell(row, 7).value).upper()
        if destination is None or destination.coordinate.upper() != coordinate:
            raise ValueError(
                "Legacy managed review-state coordinate does not match its "
                "recorded matrix target; workbook was not modified"
            )
        disposition = clean(state.cell(row, 8).value)
        if disposition == "falsePositive":
            value = destination.value
            original_value = state.cell(row, 9).value
            original_number = numeric_review_evidence(original_value)
            expected_value = (
                f"[{review_display_value(original_value, original_number)}]"
                if original_number is not None
                else None
            )
            valid = (
                isinstance(value, str)
                and value == expected_value
                and bool(destination.font.italic)
                and color_has_rgb_suffix(destination.font.color, "767676")
            )
        else:
            valid = all(
                clean(getattr(destination.border, side_name).style) == "thick"
                and color_has_rgb_suffix(
                    getattr(destination.border, side_name).color,
                    "000000",
                )
                for side_name in ("left", "right", "top", "bottom")
            )
        if not valid:
            raise ValueError(
                "Legacy managed review-state presentation is inconsistent "
                "with the recorded annotation; workbook was not modified"
            )


def managed_review_state_schema():
    if MANAGED_REVIEW_STATE_SHEET not in wb.sheetnames:
        return None
    state = wb[MANAGED_REVIEW_STATE_SHEET]
    if state.sheet_state != "veryHidden":
        raise ValueError(
            "Reserved managed review-state sheet is not Lungfish-owned; "
            "workbook was not modified"
        )
    headers = [
        clean(state.cell(1, col).value)
        for col in range(1, state.max_column + 1)
    ]
    while headers and not headers[-1]:
        headers.pop()
    versioned_prefix = [
        clean(value) for value in VERSIONED_MANAGED_REVIEW_STATE_PREFIX
    ]
    version_3_prefix = [
        clean(value) for value in VERSION_3_MANAGED_REVIEW_STATE_PREFIX
    ]
    if (
        len(headers) == len(versioned_prefix) + 2
        and headers[:len(versioned_prefix)] == versioned_prefix
    ):
        schema = "versioned-current"
    elif (
        len(headers) == len(version_3_prefix) + 2
        and headers[:len(version_3_prefix)] == version_3_prefix
    ):
        schema = "versioned-3"
    elif headers == LEGACY_MANAGED_REVIEW_STATE_HEADERS:
        schema = "legacy"
    else:
        raise ValueError(
            "Reserved managed review-state sheet has an unknown schema; "
            "workbook was not modified"
        )
    if state.max_row < 2:
        raise ValueError(
            "Reserved managed review-state sheet is empty; workbook was not modified"
        )
    for row in range(2, state.max_row + 1):
        if (
            not clean(state.cell(row, 1).value)
            or clean(state.cell(row, 2).value) != "cell"
            or not clean(state.cell(row, 4).value)
            or not clean(state.cell(row, 5).value)
            or not clean(state.cell(row, 7).value)
            or clean(state.cell(row, 8).value)
                not in {"falsePositive", "falseNegative"}
        ):
            raise ValueError(
                "Reserved managed review-state sheet contains malformed records; "
                "workbook was not modified"
            )
    if schema in {"versioned-current", "versioned-3"}:
        authority = headers[-2]
        recorded_digest = headers[-1].lower()
        calculated_digest = managed_state_payload_digest(
            state,
            authority,
            schema_version=(
                MANAGED_REVIEW_STATE_SCHEMA_VERSION
                if schema == "versioned-current"
                else 3
            ),
        )
        if (
            not expected_managed_state_authority
            or authority != expected_managed_state_authority
            or not re.fullmatch(r"[0-9a-f]{64}", recorded_digest)
            or calculated_digest != recorded_digest
        ):
            raise ValueError(
                "Reserved managed review-state authority or payload binding "
                "does not match the current workbook revision; "
                "workbook was not modified"
            )
    elif schema == "legacy":
        validate_legacy_managed_state(state)
    return schema


def serialize_managed_value(value):
    if value is None:
        payload = {"type": "none", "value": None}
    elif isinstance(value, bool):
        payload = {"type": "bool", "value": value}
    elif isinstance(value, int):
        payload = {"type": "int", "value": value}
    elif isinstance(value, float):
        payload = {"type": "float", "value": value}
    else:
        payload = {"type": "string", "value": str(value)}
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def deserialize_managed_value(value):
    payload = json.loads(clean(value))
    if payload.get("type") == "none":
        return None
    return payload.get("value")


def style_array(cell):
    return list(cell._style) if cell.has_style else []


def row_signature(ws, row):
    dimension = ws.row_dimensions[row]
    cells = []
    for col in range(1, ws.max_column + 1):
        cell = ws.cell(row, col)
        cells.append({
            "coordinate": cell.coordinate,
            "value": serialize_managed_value(cell.value),
            "data_type": clean(cell.data_type),
            "style": style_array(cell),
            "number_format": clean(cell.number_format),
            "comment": None if cell.comment is None else {
                "text": cell.comment.text,
                "author": cell.comment.author,
            },
            "hyperlink": None if cell.hyperlink is None else clean(cell.hyperlink.target),
        })
    return json.dumps({
        "cells": cells,
        "height": dimension.height,
        "hidden": bool(dimension.hidden),
        "outline_level": int(dimension.outlineLevel or 0),
    }, sort_keys=True, separators=(",", ":"))


matrix_row_signature_count = 0


def cached_row_signature(cache, ws, row):
    global matrix_row_signature_count
    key = (id(ws), row)
    if key not in cache:
        cache[key] = row_signature(ws, row)
        matrix_row_signature_count += 1
    return cache[key]


def record_managed_review_state(ws, cell, target, disposition):
    state = managed_review_state_sheet()
    kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
    row = state.max_row + 1
    synthetic = synthetic_rows_for_current_run.get((ws.title, cell.row))
    values = [
        ws.title,
        kind,
        locus,
        genotype,
        sample,
        stable_id,
        cell.coordinate,
        disposition,
        serialize_managed_value(cell.value),
    ]
    for col, value in enumerate(values, start=1):
        state.cell(row, col).value = value
    state.cell(row, 10).font = copy(cell.font)
    state.cell(row, 11).fill = copy(cell.fill)
    state.cell(row, 12).border = copy(cell.border)
    state.cell(row, 17).value = "true" if synthetic else "false"
    state.cell(row, 18).value = synthetic["adapter"] if synthetic else ""
    state.cell(row, 19).value = cell.row if synthetic else None
    state.cell(row, 21).value = synthetic["marker_row"] if synthetic else None
    return row


def record_expected_managed_review_state(state_row, cell):
    state = managed_review_state_sheet()
    state.cell(state_row, 13).value = serialize_managed_value(cell.value)
    state.cell(state_row, 14).font = copy(cell.font)
    state.cell(state_row, 15).fill = copy(cell.fill)
    state.cell(state_row, 16).border = copy(cell.border)


def finalize_managed_synthetic_state():
    if MANAGED_REVIEW_STATE_SHEET not in wb.sheetnames:
        return
    state = wb[MANAGED_REVIEW_STATE_SHEET]
    signature_cache = {}
    for row in range(2, state.max_row + 1):
        if clean(state.cell(row, 17).value) != "true":
            continue
        sheet_name = clean(state.cell(row, 1).value)
        synthetic_row = state.cell(row, 19).value
        marker_row = state.cell(row, 21).value
        if (
            sheet_name not in wb.sheetnames
            or not isinstance(synthetic_row, int)
            or not isinstance(marker_row, int)
        ):
            raise ValueError("Malformed managed synthetic-row state")
        ws = wb[sheet_name]
        state.cell(row, 20).value = cached_row_signature(
            signature_cache, ws, synthetic_row
        )
        state.cell(row, 22).value = cached_row_signature(
            signature_cache, ws, marker_row
        )
    state.cell(1, 25).value = new_managed_state_authority
    state.cell(1, 26).value = managed_state_payload_digest(
        state, new_managed_state_authority
    )


def state_destination(state, row):
    sheet_name = clean(state.cell(row, 1).value)
    if not sheet_name or sheet_name not in wb.sheetnames:
        return None
    ws = wb[sheet_name]
    target = {
        "kind": clean(state.cell(row, 2).value),
        "locus": clean(state.cell(row, 3).value),
        "genotype": clean(state.cell(row, 4).value),
        "sample": clean(state.cell(row, 5).value),
    }
    stable_id = clean(state.cell(row, 6).value)
    if stable_id:
        target["stableClusterID"] = stable_id
    sample = target["sample"]
    sample_columns = sample_columns_for_matrix(ws, {sample})
    if sample not in sample_columns:
        return None
    matches, _error = matching_matrix_rows(matrix_row_descriptors(ws), target)
    if len(matches) != 1:
        return None
    col, _header_row = sample_columns[sample]
    return ws.cell(matches[0]["row"], col)


def color_has_rgb_suffix(color, suffix):
    return clean(getattr(color, "rgb", None)).upper().endswith(suffix)


def style_matches(left, right):
    return copy(left) == copy(right)


def delete_managed_adapter_row(adapter, row):
    ws = adapter["ws"]
    min_col, max_col = adapter_owned_column_bounds(adapter)
    matrix_end = adapter_matrix_end(adapter)
    if not isinstance(row, int) or not (adapter["header_row"] < row <= matrix_end):
        raise ValueError(
            "Managed annotation-only row is outside its exact matrix ownership; "
            "workbook was not modified"
        )
    for merged_range in ws.merged_cells.ranges:
        if (
            merged_range.min_row <= matrix_end
            and merged_range.max_row >= row
            and merged_range.min_col <= max_col
            and merged_range.max_col >= min_col
        ):
            raise ValueError(
                "Managed annotation-only row compaction intersects merged cells; "
                "workbook was not modified"
            )
    for source_row in range(row + 1, matrix_end + 1):
        for col in range(min_col, max_col + 1):
            source = ws.cell(source_row, col)
            destination = ws.cell(source_row - 1, col)
            destination._value = source._value
            destination.data_type = source.data_type
            destination._style = (
                copy(source._style) if source.has_style else None
            )
            destination.comment = (
                copy(source.comment) if source.comment is not None else None
            )
            destination._hyperlink = (
                copy(source.hyperlink) if source.hyperlink is not None else None
            )
    for col in range(min_col, max_col + 1):
        cell = ws.cell(matrix_end, col)
        cell.value = None
        cell.comment = None
        cell._hyperlink = None
        cell._style = None
    updated_end = matrix_end - 1
    set_adapter_range_end(adapter, updated_end)
    adapter["managed_end"] = updated_end
    invalidate_matrix_descriptor_cache(ws)


def mark_annotation_only_marker_retained(ws, row):
    replacements = 0
    for cell in ws[row]:
        value = clean(cell.value)
        if value == ANNOTATION_ONLY_BLOCK_CALL_TYPE:
            cell.value = RETAINED_ANNOTATION_ONLY_BLOCK_CALL_TYPE
            replacements += 1
        elif value == ANNOTATION_ONLY_BLOCK_LABEL:
            cell.value = RETAINED_ANNOTATION_ONLY_BLOCK_LABEL
            replacements += 1
    if replacements == 0:
        raise ValueError("Malformed managed annotation-only block marker")
    invalidate_matrix_descriptor_cache(ws)


def restore_prior_managed_matrix_annotations():
    for ws in wb.worksheets:
        if ws.title == MANAGED_REVIEW_STATE_SHEET:
            continue
        for row in ws.iter_rows():
            for cell in row:
                if cell.comment and "[LGE Matrix Comments]" in cell.comment.text:
                    set_lge_comment(cell, [])

    if MANAGED_REVIEW_STATE_SHEET not in wb.sheetnames:
        managed_review_restoration_decisions.append({
            "action": "none",
            "reason": "no-managed-review-state",
        })
        return
    state = wb[MANAGED_REVIEW_STATE_SHEET]
    state_schema = managed_review_state_schema()
    legacy_state = state_schema == "legacy"
    version_3_state = state_schema == "versioned-3"
    signature_cache = {}
    synthetic_safety = {}
    marker_safety = {}
    marker_members = {}
    for row in range(2, state.max_row + 1):
        if clean(state.cell(row, 17).value) != "true":
            continue
        sheet_name = clean(state.cell(row, 1).value)
        synthetic_row = state.cell(row, 19).value
        marker_row = state.cell(row, 21).value
        key = (sheet_name, synthetic_row)
        marker_key = (sheet_name, marker_row)
        marker_members.setdefault(marker_key, set()).add(key)
        if (
            sheet_name not in wb.sheetnames
            or not isinstance(synthetic_row, int)
            or not isinstance(marker_row, int)
        ):
            synthetic_safety[key] = False
            marker_safety[marker_key] = False
            continue
        ws = wb[sheet_name]
        expected_row = clean(state.cell(row, 20).value)
        expected_marker = clean(state.cell(row, 22).value)
        row_safe = (
            bool(expected_row)
            and cached_row_signature(signature_cache, ws, synthetic_row) == expected_row
        )
        marker_safe = (
            bool(expected_marker)
            and cached_row_signature(signature_cache, ws, marker_row) == expected_marker
        )
        synthetic_safety[key] = synthetic_safety.get(key, True) and row_safe
        marker_safety[marker_key] = marker_safety.get(marker_key, True) and marker_safe
        if not row_safe:
            target = {
                "kind": clean(state.cell(row, 2).value),
                "locus": clean(state.cell(row, 3).value),
                "genotype": clean(state.cell(row, 4).value),
                "sample": clean(state.cell(row, 5).value),
            }
            stable_id = clean(state.cell(row, 6).value)
            if stable_id:
                target["stableClusterID"] = stable_id
            managed_cleanup_warnings[matrix_target_key(target)] = (
                "Retained a user-edited analyst annotation-only row."
            )

    retained_marker_keys = set()
    retained_member_keys = set()
    for marker_key, members in marker_members.items():
        retain_block = (
            not marker_safety.get(marker_key, False)
            or any(not synthetic_safety.get(member, False) for member in members)
        )
        if retain_block:
            retained_marker_keys.add(marker_key)
            retained_member_keys.update(members)
        if (
            retain_block
            and marker_key[0] in wb.sheetnames
            and isinstance(marker_key[1], int)
        ):
            mark_annotation_only_marker_retained(
                wb[marker_key[0]],
                marker_key[1],
            )

    for row in range(2, state.max_row + 1):
        cell = state_destination(state, row)
        target = {
            "kind": clean(state.cell(row, 2).value),
            "locus": clean(state.cell(row, 3).value),
            "genotype": clean(state.cell(row, 4).value),
            "sample": clean(state.cell(row, 5).value),
        }
        stable_id = clean(state.cell(row, 6).value)
        if stable_id:
            target["stableClusterID"] = stable_id
        disposition = clean(state.cell(row, 8).value)
        if cell is None:
            managed_review_restoration_decisions.append({
                "action": "unresolved-cell",
                "worksheet": clean(state.cell(row, 1).value) or None,
                "cell": clean(state.cell(row, 7).value) or None,
                "target": structured_matrix_target(target),
                "disposition": disposition,
                "properties": {},
            })
            continue
        if legacy_state:
            property_decisions = {}
            if disposition == "falsePositive":
                value = clean(cell.value)
                if value.startswith("[") and value.endswith("]"):
                    cell.value = state.cell(row, 9).value
                    property_decisions["value"] = "restored"
                else:
                    property_decisions["value"] = "preserved"
                font = copy(cell.font)
                original_font = state.cell(row, 10).font
                if bool(font.italic):
                    font.italic = original_font.italic
                    property_decisions["font.italic"] = "restored"
                else:
                    property_decisions["font.italic"] = "preserved"
                if color_has_rgb_suffix(font.color, "767676"):
                    font.color = copy(original_font.color)
                    property_decisions["font.color"] = "restored"
                else:
                    property_decisions["font.color"] = "preserved"
                cell.font = font
            elif disposition == "falseNegative":
                border = copy(cell.border)
                original_border = state.cell(row, 11).border
                for side_name in ("left", "right", "top", "bottom"):
                    current_side = copy(getattr(border, side_name))
                    original_side = getattr(original_border, side_name)
                    if clean(current_side.style) == "thick":
                        current_side.style = original_side.style
                        property_decisions[
                            "border." + side_name + ".style"
                        ] = "restored"
                    else:
                        property_decisions[
                            "border." + side_name + ".style"
                        ] = "preserved"
                    if color_has_rgb_suffix(current_side.color, "000000"):
                        current_side.color = copy(original_side.color)
                        property_decisions[
                            "border." + side_name + ".color"
                        ] = "restored"
                    else:
                        property_decisions[
                            "border." + side_name + ".color"
                        ] = "preserved"
                    setattr(border, side_name, current_side)
                cell.border = border
            managed_review_restoration_decisions.append({
                "action": "restore-legacy-cell",
                "worksheet": cell.parent.title,
                "cell": cell.coordinate,
                "target": structured_matrix_target(target),
                "disposition": disposition,
                "properties": property_decisions,
            })
            continue
        if version_3_state and disposition == "falseNegative":
            property_decisions = {
                "value": "not-managed",
                "font.bold": "not-managed",
                "font.color": "not-managed",
                "fill.patternType": "not-managed",
                "fill.fgColor": "not-managed",
            }
            border = copy(cell.border)
            expected_border = state.cell(row, 16).border
            original_border = state.cell(row, 12).border
            for side_name in ("left", "right", "top", "bottom"):
                if style_matches(
                    getattr(border, side_name),
                    getattr(expected_border, side_name),
                ):
                    setattr(
                        border,
                        side_name,
                        copy(getattr(original_border, side_name)),
                    )
                    property_decisions[f"border.{side_name}"] = "restored"
                else:
                    property_decisions[f"border.{side_name}"] = "preserved"
            cell.border = border
            managed_review_restoration_decisions.append({
                "action": "restore-version-3-cell",
                "worksheet": cell.parent.title,
                "cell": cell.coordinate,
                "target": structured_matrix_target(target),
                "disposition": disposition,
                "properties": property_decisions,
            })
            continue
        property_decisions = {}
        if serialize_managed_value(cell.value) == clean(state.cell(row, 13).value):
            cell.value = deserialize_managed_value(state.cell(row, 9).value)
            property_decisions["value"] = "restored"
        else:
            property_decisions["value"] = "preserved"
        if disposition == "falsePositive":
            font = copy(cell.font)
            expected_font = state.cell(row, 14).font
            original_font = state.cell(row, 10).font
            if font.italic == expected_font.italic:
                font.italic = original_font.italic
                property_decisions["font.italic"] = "restored"
            else:
                property_decisions["font.italic"] = "preserved"
            if style_matches(font.color, expected_font.color):
                font.color = copy(original_font.color)
                property_decisions["font.color"] = "restored"
            else:
                property_decisions["font.color"] = "preserved"
            cell.font = font
        elif disposition == "falseNegative":
            font = copy(cell.font)
            expected_font = state.cell(row, 14).font
            original_font = state.cell(row, 10).font
            if font.bold == expected_font.bold:
                font.bold = original_font.bold
                property_decisions["font.bold"] = "restored"
            else:
                property_decisions["font.bold"] = "preserved"
            if style_matches(font.color, expected_font.color):
                font.color = copy(original_font.color)
                property_decisions["font.color"] = "restored"
            else:
                property_decisions["font.color"] = "preserved"
            cell.font = font
            fill = copy(cell.fill)
            expected_fill = state.cell(row, 15).fill
            original_fill = state.cell(row, 11).fill
            if style_matches(fill, expected_fill):
                cell.fill = copy(original_fill)
                property_decisions["fill.patternType"] = "restored"
                property_decisions["fill.fgColor"] = "restored"
            else:
                property_decisions["fill.patternType"] = "preserved"
                property_decisions["fill.fgColor"] = "preserved"
            border = copy(cell.border)
            expected_border = state.cell(row, 16).border
            original_border = state.cell(row, 12).border
            for side_name in ("left", "right", "top", "bottom"):
                if style_matches(
                    getattr(border, side_name),
                    getattr(expected_border, side_name),
                ):
                    setattr(border, side_name, copy(getattr(original_border, side_name)))
                    property_decisions[f"border.{side_name}"] = "restored"
                else:
                    property_decisions[f"border.{side_name}"] = "preserved"
            cell.border = border
        managed_review_restoration_decisions.append({
            "action": "restore-cell",
            "worksheet": cell.parent.title,
            "cell": cell.coordinate,
            "target": structured_matrix_target(target),
            "disposition": disposition,
            "properties": property_decisions,
        })

    rows_to_delete = [
        key for key, is_safe in synthetic_safety.items()
        if (
            is_safe
            and key not in retained_member_keys
            and key[0] in wb.sheetnames
            and isinstance(key[1], int)
        )
    ]
    markers_to_delete = []
    for marker_key, members in marker_members.items():
        if (
            marker_key not in retained_marker_keys
            and marker_safety.get(marker_key, False)
            and all(synthetic_safety.get(member, False) for member in members)
            and marker_key[0] in wb.sheetnames
            and isinstance(marker_key[1], int)
        ):
            markers_to_delete.append(marker_key)
    deletions_by_sheet = {}
    for sheet_name, row in rows_to_delete + markers_to_delete:
        deletions_by_sheet.setdefault(sheet_name, set()).add(row)
    cleanup_adapters = {}
    all_cleanup_samples = authoritative_matrix_samples()
    all_cleanup_samples.update(
        clean(state.cell(state_row, 5).value)
        for state_row in range(2, state.max_row + 1)
        if clean(state.cell(state_row, 5).value)
    )
    for sheet_name, rows in deletions_by_sheet.items():
        ws = wb[sheet_name]
        state_rows = [
            state_row for state_row in range(2, state.max_row + 1)
            if (
                clean(state.cell(state_row, 17).value) == "true"
                and clean(state.cell(state_row, 1).value) == sheet_name
            )
        ]
        adapter_kinds = {
            clean(state.cell(state_row, 18).value)
            for state_row in state_rows
        }
        state_sample_names = {
            clean(state.cell(state_row, 5).value)
            for state_row in state_rows
            if clean(state.cell(state_row, 5).value)
        }
        if len(adapter_kinds) != 1:
            raise ValueError(
                "Managed annotation-only state has ambiguous adapter ownership; "
                "workbook was not modified"
            )
        adapter = matrix_layout_adapter(
            ws, all_cleanup_samples, requires_synthesis=True
        )
        if (
            adapter is None
            or adapter["kind"] not in adapter_kinds
            or not state_sample_names.issubset(adapter["sample_columns"])
        ):
            raise ValueError(
                "Managed annotation-only state no longer matches its exact "
                "workbook adapter; workbook was not modified"
            )
        adapter_owned_column_bounds(adapter)
        adapter_owned_table(adapter)
        matrix_end = adapter_matrix_end(adapter)
        if any(
            not (adapter["header_row"] < row <= matrix_end)
            for row in rows
        ):
            raise ValueError(
                "Managed annotation-only state is outside its exact matrix "
                "ownership; workbook was not modified"
            )
        cleanup_adapters[sheet_name] = adapter
    for sheet_name, rows in deletions_by_sheet.items():
        adapter = cleanup_adapters[sheet_name]
        for row in sorted(rows, reverse=True):
            delete_managed_adapter_row(adapter, row)
    managed_review_restoration_decisions.append({
        "action": "restore",
        "state_rows": max(0, state.max_row - 1),
        "deleted_rows": sum(len(rows) for rows in deletions_by_sheet.values()),
        "retained_rows": len(retained_member_keys),
        "retained_markers": len(retained_marker_keys),
        "legacy_state": legacy_state,
    })
    del wb[MANAGED_REVIEW_STATE_SHEET]


def apply_review_format(result):
    if result["status"] != "valid":
        return
    disposition = clean(result["entry"].get("disposition"))
    target = result["entry"].get("target") or {}
    for ws, _item, cell in result["destinations"]:
        state_row = record_managed_review_state(ws, cell, target, disposition)
        if disposition == "falsePositive":
            number = numeric_review_evidence(cell.value)
            cell.value = f"[{review_display_value(cell.value, number)}]"
            font = copy(cell.font)
            font.italic = True
            font.color = "FF767676"
            cell.font = font
        else:
            fn_side = Side(style="mediumDashed", color="FFC65911")
            cell.value = "FN"
            border = copy(cell.border)
            border.left = copy(fn_side)
            border.right = copy(fn_side)
            border.top = copy(fn_side)
            border.bottom = copy(fn_side)
            cell.border = border
            cell.fill = PatternFill(fill_type="solid", fgColor="FFFFF2CC")
            font = copy(cell.font)
            font.bold = True
            font.color = "FF7F6000"
            cell.font = font
        record_expected_managed_review_state(state_row, cell)


def record_false_negative_target_decisions(matrix_review_results):
    for result in matrix_review_results:
        disposition = clean(result["entry"].get("disposition"))
        if disposition != "falseNegative":
            continue
        target = result["entry"].get("target") or {}
        destinations = result["destinations"]
        if not destinations:
            false_negative_target_cell_decisions.append({
                "worksheet": None,
                "cell": None,
                "target": structured_matrix_target(target),
                "disposition": disposition,
                "status": result["status"],
                "reason": result["reason"],
                "synthetic": False,
                "presentationPrecedence": "not-applied",
            })
            continue
        for ws, _item, cell in destinations:
            false_negative_target_cell_decisions.append({
                "worksheet": ws.title,
                "cell": cell.coordinate,
                "target": structured_matrix_target(target),
                "disposition": disposition,
                "status": result["status"],
                "reason": result["reason"],
                "synthetic": (
                    (ws.title, cell.row) in synthetic_rows_for_current_run
                ),
                "presentationPrecedence":
                    "false-negative-over-viewport-style",
            })


def apply_matrix_annotations_to_workbook(matrix_review_results):
    if not resolved_matrix_styles and not resolved_matrix_comments and not matrix_review_results:
        return
    record_false_negative_target_decisions(matrix_review_results)
    row_styles, column_styles, cell_styles = collect_matrix_style_maps()
    row_comments = {}
    column_comments = {}
    cell_comments = {}
    for entry in resolved_matrix_comments:
        target = entry.get("target") or {}
        kind, locus, genotype, sample, stable_id = matrix_target_parts(target)
        if not clean(entry.get("body")):
            continue
        if kind == "row":
            row_comments[(locus, genotype, stable_id)] = entry
        elif kind == "column":
            column_comments[sample] = entry
        elif kind == "cell":
            cell_comments[(locus, genotype, sample, stable_id)] = entry

    sample_names = known_matrix_samples()
    for ws in wb.worksheets:
        if ws.title in {
            "Matrix Annotations", "Overrides", "Audit Log", MANAGED_REVIEW_STATE_SHEET
        }:
            continue
        sample_columns = sample_columns_for_matrix(ws, sample_names)
        descriptors = matrix_row_descriptors(ws)
        if not sample_columns or not descriptors:
            continue

        for row in ws.iter_rows():
            for cell in row:
                if cell.comment and "[LGE Matrix Comments]" in cell.comment.text:
                    set_lge_comment(cell, [])

        for sample, (col, header_row) in sample_columns.items():
            if sample in column_styles:
                for item in descriptors:
                    apply_matrix_style(ws.cell(item["row"], col), column_styles[sample])
            column_entry = column_comments.get(sample)
            if column_entry:
                set_lge_comment(ws.cell(header_row, col), [comment_section("Sample Column", column_entry)])

        for (locus, genotype, stable_id), style in row_styles.items():
            target = {"kind": "row", "locus": locus, "genotype": genotype}
            if stable_id:
                target["stableClusterID"] = stable_id
            matches, _error = matching_matrix_rows(descriptors, target)
            for item in matches:
                for _sample, (col, _header_row) in sample_columns.items():
                    apply_matrix_style(ws.cell(item["row"], col), style)

        for (locus, genotype, sample, stable_id), style in cell_styles.items():
            if sample not in sample_columns:
                continue
            target = {"kind": "cell", "locus": locus, "genotype": genotype, "sample": sample}
            if stable_id:
                target["stableClusterID"] = stable_id
            matches, _error = matching_matrix_rows(descriptors, target)
            col, _header_row = sample_columns[sample]
            for item in matches:
                apply_matrix_style(ws.cell(item["row"], col), style)

        matched_row_comments = {}
        for (locus, genotype, stable_id), entry in row_comments.items():
            target = {"kind": "row", "locus": locus, "genotype": genotype}
            if stable_id:
                target["stableClusterID"] = stable_id
            matches, _error = matching_matrix_rows(descriptors, target)
            for item in matches:
                matched_row_comments[item["row"]] = entry
                set_lge_comment(
                    ws.cell(item["row"], item["label_col"]),
                    [comment_section("Allele Row", entry)]
                )

        matched_cell_comments = {}
        for (locus, genotype, sample, stable_id), entry in cell_comments.items():
            if sample not in sample_columns:
                continue
            target = {"kind": "cell", "locus": locus, "genotype": genotype, "sample": sample}
            if stable_id:
                target["stableClusterID"] = stable_id
            matches, _error = matching_matrix_rows(descriptors, target)
            for item in matches:
                matched_cell_comments[(item["row"], sample)] = entry

        for item in descriptors:
            row_entry = matched_row_comments.get(item["row"])
            for sample, (col, _header_row) in sample_columns.items():
                sections = []
                if row_entry:
                    sections.append(comment_section("Allele Row", row_entry))
                if sample in column_comments:
                    sections.append(comment_section("Sample Column", column_comments[sample]))
                cell_entry = matched_cell_comments.get((item["row"], sample))
                if cell_entry:
                    sections.append(comment_section("Cell", cell_entry))
                if sections:
                    set_lge_comment(ws.cell(item["row"], col), sections)

    for result in matrix_review_results:
        apply_review_format(result)
    finalize_managed_synthetic_state()


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

COMPACT_RECIPROCAL_HEADERS = [
    "Reciprocal BAM Path", "Reciprocal Query Name", "Reciprocal Alignment Count", "Reciprocal Target Count",
    "Reciprocal Target Alignment Counts", "Exact Match Target Names", "Closest Match Target Names",
]

SELECTED_EVIDENCE_HEADERS = [
    "Selected Evidence BAM Path", "Selected Evidence Query Name", "Selected Evidence Reference Name",
    "Selected Evidence Read Group ID", "Selected Evidence Reference Start", "Selected Evidence CIGAR",
]


def named_counts_text(values):
    values = values or {}
    return ";".join(f"{name}={values[name]}" for name in sorted(values))


def reciprocal_values(record):
    summary = record.get("reciprocal_hit_summary") or {}
    counts = summary.get("target_alignment_counts") or {}
    return [
        clean(summary.get("bam_path")),
        clean(summary.get("query_name")),
        summary.get("alignment_count"),
        len(counts),
        named_counts_text(counts),
        ";".join(sorted(summary.get("exact_match_target_names") or [])),
        ";".join(sorted(summary.get("closest_match_target_names") or [])),
    ]


def candidate_row(record, samples):
    stable_id = clean(record.get("stable_cluster_id"))
    reads = sample_read_counts(stable_id)
    prefix = [
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
    ]
    if candidate_schema_version >= 2:
        prefix += reciprocal_values(record) + evidence_values(record.get("selected_evidence"))
    else:
        prefix += evidence_values(record.get("selected_evidence"))
    return prefix + [
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
    prefix = [
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
    ]
    if unnameable_schema_version >= 2:
        return [
            prefix + reciprocal_values(record) + evidence_values(record.get("selected_evidence"))
            + [reads.get(sample) for sample in samples]
        ]
    evidence = sorted(record.get("evidence") or [], key=lambda item: (
        clean(item.get("bam_path")), clean(item.get("query_name")), clean(item.get("reference_name")),
        clean(item.get("read_group_id")), int(item.get("reference_start") or 0), clean(item.get("cigar")),
    ))
    evidence = evidence or [None]
    rows = []
    for index, locator in enumerate(evidence, start=1):
        rows.append(prefix + [
            index if locator else None,
            len(record.get("evidence") or []),
        ] + evidence_values(locator) + [reads.get(sample) for sample in samples])
    return rows


def write_candidate_artifact_sheets():
    samples = candidate_samples()
    candidate_ws = replace_sheet("Candidate Alleles")
    candidate_headers = list(CANDIDATE_HEADERS)
    if candidate_schema_version >= 2:
        candidate_headers = candidate_headers[:11] + COMPACT_RECIPROCAL_HEADERS + SELECTED_EVIDENCE_HEADERS + candidate_headers[17:]
    candidate_ws.append(candidate_headers + [f"Sample Reads: {sample}" for sample in samples])
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
    unnameable_headers = [
        "Stable Cluster ID", "Reason", "Support Class", "Independent Sample Count", "Occurrence Count",
        "Total Cluster Reads", "Supporting Sample IDs", "FASTA Record ID", "Sequence SHA-256", "Failed Metrics",
    ]
    if unnameable_schema_version >= 2:
        unnameable_headers += COMPACT_RECIPROCAL_HEADERS + SELECTED_EVIDENCE_HEADERS
    else:
        unnameable_headers += [
            "Evidence Ordinal", "Evidence Count", "Evidence BAM Path", "Evidence Query Name", "Evidence Reference Name",
            "Evidence Read Group ID", "Evidence Reference Start", "Evidence CIGAR",
        ]
    unnameable_ws.append(unnameable_headers + [f"Sample Reads: {sample}" for sample in samples])
    for record in unnameable_records:
        for row in unnameable_rows(record, samples):
            unnameable_ws.append(row)
    style_table_header(unnameable_ws)
    style_table_body(unnameable_ws)
    autosize_columns(unnameable_ws)
    unnameable_ws.freeze_panes = "A2"


def write_candidates_to_editable_view():
    managed_begin = "LGE MHC Candidate Alleles [BEGIN]"
    managed_end = "LGE MHC Candidate Alleles [END]"
    legacy_begin = "LGE MHC Candidate Alleles"
    managed_headers = ["Provisional Name", "Stable Cluster ID", "Locus", "Classification", "Support Class"]

    def generated_candidate_row(ws, row, managed_width):
        name = clean(ws.cell(row, 1).value)
        stable_id = clean(ws.cell(row, 2).value)
        locus = clean(ws.cell(row, 3).value)
        classification = clean(ws.cell(row, 4).value)
        support = clean(ws.cell(row, 5).value)
        valid_name = (classification == "novel" and re.search(r"_[1-9][0-9]*nt_nov$", name)) or (
            classification == "extension" and name.endswith("_ext")
        )
        cells = [ws.cell(row, col) for col in range(1, ws.max_column + 1)]
        if any(cell.data_type == "f" or cell.comment is not None or cell.hyperlink is not None for cell in cells):
            return False
        if any(cell.has_style for cell in cells[1:]):
            return False
        if any(clean(cell.value) for cell in cells[managed_width:]):
            return False
        for cell in cells[5:managed_width]:
            value = cell.value
            if value in (None, ""):
                continue
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                return False
        return bool(stable_id and locus and valid_name and support in {"shared", "singleton"})

    def remove_prior_managed_block(ws):
        begin_rows = [row for row in range(1, ws.max_row + 1) if clean(ws.cell(row, 1).value) == managed_begin]
        end_rows = [row for row in range(1, ws.max_row + 1) if clean(ws.cell(row, 1).value) == managed_end]
        legacy_rows = [row for row in range(1, ws.max_row + 1) if clean(ws.cell(row, 1).value) == legacy_begin]
        if len(begin_rows) > 1 or len(end_rows) > 1 or len(legacy_rows) > 1:
            raise ValueError("Ambiguous LGE candidate block markers; workbook was not modified")
        if end_rows and not begin_rows:
            raise ValueError("LGE candidate end marker has no matching begin marker; workbook was not modified")
        if begin_rows and end_rows:
            begin_row = begin_rows[0]
            end_row = end_rows[0]
            if end_row <= begin_row:
                raise ValueError("LGE candidate block markers are out of order; workbook was not modified")
            ws.delete_rows(begin_row, end_row - begin_row + 1)
            return
        if begin_rows and legacy_rows:
            raise ValueError("Ambiguous current and legacy LGE candidate block markers; workbook was not modified")
        begin_row = begin_rows[0] if begin_rows else (legacy_rows[0] if legacy_rows else None)
        if begin_row is None:
            return

        # Migrate a start-only block conservatively. Consume only the exact
        # generated header and contiguous rows that match our generated schema;
        # stop before any analyst-authored row, formula, or styled content.
        delete_through = begin_row
        header_row = begin_row + 1
        if header_row > ws.max_row or [clean(ws.cell(header_row, col).value) for col in range(1, 6)] != managed_headers:
            raise ValueError("Start-only LGE candidate block does not have the generated header; workbook was not modified")
        managed_width = max(
            5,
            max((col for col in range(1, ws.max_column + 1) if clean(ws.cell(header_row, col).value)), default=5),
        )
        delete_through = header_row
        row = header_row + 1
        while row <= ws.max_row and generated_candidate_row(ws, row, managed_width):
            delete_through = row
            row += 1
        ws.delete_rows(begin_row, delete_through - begin_row + 1)

    samples = candidate_samples()
    if "Full Sequencing Results 1" in wb.sheetnames:
        ws = wb["Full Sequencing Results 1"]
        remove_prior_managed_block(ws)
        if not candidate_records:
            return
        ws.append([])
        ws.append([managed_begin])
        ws.append(managed_headers + samples)
        for record in candidate_records:
            reads = sample_read_counts(clean(record.get("stable_cluster_id")))
            ws.append([
                clean(record.get("provisional_name")), clean(record.get("stable_cluster_id")),
                clean(record.get("locus")), clean(record.get("classification")), clean(record.get("support_class")),
            ] + [reads.get(sample) for sample in samples])
            # The provisional-name cell alone receives the category tint.
            ws.cell(ws.max_row, 1).fill = PatternFill(fill_type="solid", fgColor=candidate_argb(record))
        ws.append([managed_end])
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
    columns = {header: index + 1 for index, header in enumerate(headers) if header}
    call_type_col = columns.get("call_type", 1)
    stable_id_col = columns.get("stable_cluster_id")
    classification_col = columns.get("classification")
    for row in range(ws.max_row, 1, -1):
        call_type = clean(ws.cell(row, call_type_col).value)
        stable_id = clean(ws.cell(row, stable_id_col).value) if stable_id_col else ""
        classification = clean(ws.cell(row, classification_col).value) if classification_col else ""
        if call_type in {"candidate-novel", "candidate-extension"} and stable_id and call_type == f"candidate-{classification}":
            ws.delete_rows(row, 1)
    def pivot_value(record, reads, header):
        values = {
            "call_type": f"candidate-{clean(record.get('classification'))}",
            "call_id": clean(record.get("stable_cluster_id")),
            "display_name": clean(record.get("provisional_name")),
            "stable_cluster_id": clean(record.get("stable_cluster_id")),
            "locus": clean(record.get("locus")),
            "classification": clean(record.get("classification")),
            "support_class": clean(record.get("support_class")),
            "closest_reference": clean(record.get("closest_reference_name")),
            "match_class": clean(record.get("classification")),
            "occurrence_count": record.get("occurrence_count"),
            "sample_count": record.get("independent_sample_count"),
            "total_cluster_reads": record.get("total_cluster_reads"),
        }
        if header in values:
            return values[header]
        sample = header[len("Sample Reads: "):] if header.startswith("Sample Reads: ") else header
        return reads.get(sample) if sample in samples else None

    for record in candidate_records:
        reads = sample_read_counts(clean(record.get("stable_cluster_id")))
        ws.append([pivot_value(record, reads, header) for header in headers])
        # Only the header-named provisional/display-name cell receives the category tint.
        display_col = columns.get("display_name", 3)
        ws.cell(ws.max_row, display_col).fill = PatternFill(fill_type="solid", fgColor=candidate_argb(record))


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


def find_unified_table(ws):
    matches = []
    for row in range(1, ws.max_row + 1):
        for col in range(1, ws.max_column + 1):
            if clean(ws.cell(row, col).value) == "call_type":
                matches.append((row, col))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one call_type header in Unified Genotype Pivot; found {len(matches)}")
    row, _ = matches[0]
    headers = {
        clean(ws.cell(row, col).value): col
        for col in range(1, ws.max_column + 1)
        if clean(ws.cell(row, col).value)
    }
    required = {
        "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
        "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
        "total_cluster_reads",
    }
    missing = sorted(required.difference(headers))
    if missing:
        raise ValueError(f"Unified Genotype Pivot is missing required headers: {', '.join(missing)}")
    return row, headers


def native_cell_payload(cell):
    if cell.comment is None and not cell.has_style:
        return None
    return {
        "style": copy(cell._style) if cell.has_style else None,
        "comment": copy(cell.comment) if cell.comment is not None else None,
    }


def restore_native_cell_payload(cell, payload):
    if payload is None:
        return
    if payload["style"] is not None:
        cell._style = copy(payload["style"])
    if payload["comment"] is not None:
        cell.comment = copy(payload["comment"])


def unified_native_key(ws, table_header_row, headers, row, col):
    header = clean(ws.cell(table_header_row, col).value) or f"column:{col}"
    if row == table_header_row:
        return ("table-header", header)
    if row > table_header_row:
        identity = tuple(
            clean(ws.cell(row, headers[name]).value)
            for name in ("call_type", "call_id", "display_name", "stable_cluster_id", "locus")
        )
        if not any(identity):
            return None
        return ("table-cell",) + identity + (header,)
    row_label = clean(ws.cell(row, 1).value) or f"row:{row}"
    column_label = clean(ws.cell(1, col).value) or f"column:{col}"
    return ("summary-cell", row_label, column_label)


def capture_unified_native_content(ws, table_header_row, headers):
    captured = {}
    for row in range(1, ws.max_row + 1):
        for col in range(1, ws.max_column + 1):
            payload = native_cell_payload(ws.cell(row, col))
            if payload is None:
                continue
            key = unified_native_key(ws, table_header_row, headers, row, col)
            if key is not None and key not in captured:
                captured[key] = payload
    return captured


def restore_unified_native_content(ws, table_header_row, headers, captured):
    for row in range(1, ws.max_row + 1):
        for col in range(1, ws.max_column + 1):
            key = unified_native_key(ws, table_header_row, headers, row, col)
            if key in captured:
                cell = ws.cell(row, col)
                header = clean(ws.cell(table_header_row, col).value)
                call_type_col = headers.get("call_type")
                retains_authoritative_fill = (
                    row > table_header_row
                    and header == "display_name"
                    and call_type_col is not None
                    and clean(ws.cell(row, call_type_col).value).startswith("candidate-")
                )
                authoritative_fill = copy(cell.fill) if retains_authoritative_fill else None
                restore_native_cell_payload(cell, captured[key])
                if authoritative_fill is not None:
                    cell.fill = authoritative_fill


def unmatched_native_key(ws, headers, row, col):
    header = clean(ws.cell(1, col).value) or f"column:{col}"
    if row == 1:
        return ("unmatched-header", header)
    stable_col = headers.get("Stable Cluster ID")
    category_col = headers.get("Record Category")
    stable_id = clean(ws.cell(row, stable_col).value) if stable_col else ""
    category = clean(ws.cell(row, category_col).value) if category_col else ""
    if not stable_id and not category:
        return None
    return ("unmatched-cell", category, stable_id, header)


def capture_unmatched_native_content(ws):
    headers = {
        clean(ws.cell(1, col).value): col
        for col in range(1, ws.max_column + 1)
        if clean(ws.cell(1, col).value)
    }
    captured = {}
    for row in range(1, ws.max_row + 1):
        for col in range(1, ws.max_column + 1):
            payload = native_cell_payload(ws.cell(row, col))
            if payload is None:
                continue
            key = unmatched_native_key(ws, headers, row, col)
            if key is not None and key not in captured:
                captured[key] = payload
    return captured


def restore_unmatched_native_content(ws, captured):
    headers = {
        clean(ws.cell(1, col).value): col
        for col in range(1, ws.max_column + 1)
        if clean(ws.cell(1, col).value)
    }
    for row in range(1, ws.max_row + 1):
        for col in range(1, ws.max_column + 1):
            key = unmatched_native_key(ws, headers, row, col)
            if key in captured:
                cell = ws.cell(row, col)
                category_col = headers.get("Record Category")
                header = clean(ws.cell(1, col).value)
                retains_authoritative_fill = (
                    row > 1
                    and header == "Provisional Allele Name"
                    and category_col is not None
                    and clean(ws.cell(row, category_col).value) == "candidate"
                )
                authoritative_fill = copy(cell.fill) if retains_authoritative_fill else None
                restore_native_cell_payload(cell, captured[key])
                if authoritative_fill is not None:
                    cell.fill = authoritative_fill


def normalized_candidate_argb(row):
    classification = clean(row.get("classification_or_reason"))
    support = clean(row.get("support_class"))
    category = ("shared" if support == "shared" else "singleton") + (
        "Extension" if classification == "extension" else "Novel"
    )
    tint = (candidate_configuration.get("tints") or {}).get(category)
    if not tint:
        raise ValueError(f"Missing candidate tint: {category}")
    return "".join(f"{byte_from_unit(tint[key]):02X}" for key in ("alpha", "red", "green", "blue"))


def refresh_unified_computed_header(ws):
    mapped_row = row_for(ws, "Mapped Read Count")
    if mapped_row is None:
        return
    values = []
    for col in range(13, ws.max_column + 1):
        value = ws.cell(mapped_row, col).value
        if value in (None, ""):
            continue
        try:
            values.append(float(value))
        except (TypeError, ValueError):
            continue
    total = sum(values)
    average = total / len(values) if values else None
    ws.cell(mapped_row, 2).value = int(total) if total.is_integer() else total
    ws.cell(mapped_row, 3).value = (
        int(average) if average is not None and average.is_integer() else average
    )


def preserve_or_fill_unified_analyst_cells(ws):
    sample_columns = {
        clean(ws.cell(1, col).value): col
        for col in range(13, ws.max_column + 1)
        if clean(ws.cell(1, col).value)
    }
    for sample, calls in calls_by_sample_locus.items():
        col = sample_columns.get(sample)
        if col is None:
            continue
        for locus, call in calls.items():
            for index, key in ((1, "haplotype1"), (2, "haplotype2")):
                row = row_for(ws, f"{locus} Haplotype {index}")
                value = clean(call.get(key))
                if row is not None and value and not clean(ws.cell(row, col).value):
                    set_cell(ws.cell(row, col), value)
        comment_row = row_for(ws, "Comments")
        generated_comment = comments(sample)
        if comment_row is not None and generated_comment and not clean(ws.cell(comment_row, col).value):
            ws.cell(comment_row, col).value = generated_comment


def write_two_sheet_mhc_contract():
    if "Unified Genotype Pivot" not in wb.sheetnames:
        raise ValueError("Unified Genotype Pivot is required for an explicit full-length MHC workbook update")
    source_unified = wb["Unified Genotype Pivot"]
    source_table_header_row, source_headers = find_unified_table(source_unified)
    preserved_unified_native_content = capture_unified_native_content(
        source_unified,
        source_table_header_row,
        source_headers,
    )
    preserved_unmatched_native_content = (
        capture_unmatched_native_content(wb["Unmatched Alleles"])
        if "Unmatched Alleles" in wb.sheetnames
        else {}
    )
    sample_names = [clean(item.get("sample")) for item in workbook_samples if clean(item.get("sample"))]
    seen_sample_names = set(sample_names)
    for row in normalized_unmatched_rows:
        for sample in sorted((row.get("reads_by_sample") or {}).keys()):
            if sample not in seen_sample_names:
                sample_names.append(sample)
                seen_sample_names.add(sample)
    for call in workbook_known_calls:
        for sample in sorted((call.get("reads_by_sample") or {}).keys()):
            if sample not in seen_sample_names:
                sample_names.append(sample)
                seen_sample_names.add(sample)

    analyst_labels = [
        f"{locus} Haplotype {index}"
        for locus in ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
        for index in (1, 2)
    ] + ["Comments"]
    source_sample_columns = {
        clean(source_unified.cell(1, col).value): col
        for col in range(1, source_unified.max_column + 1)
        if clean(source_unified.cell(1, col).value) in seen_sample_names
    }
    preserved_analyst_values = {}
    for label in analyst_labels:
        source_row = row_for(source_unified, label)
        if source_row is None:
            continue
        for sample, col in source_sample_columns.items():
            value = source_unified.cell(source_row, col).value
            if clean(value):
                preserved_analyst_values[(label, sample)] = value

    source_index = wb.index(source_unified)
    del wb["Unified Genotype Pivot"]
    unified = wb.create_sheet("Unified Genotype Pivot", source_index)

    metadata_blanks = [""] * 9
    unified.append(["Client ID", "", ""] + metadata_blanks + sample_names)
    unified.append(["GS ID", "Total", "Average"] + metadata_blanks + sample_names)
    mapped_values = [item.get("mapped_read_count") for item in workbook_samples]
    mapped_numbers = [value for value in mapped_values if isinstance(value, (int, float))]
    mapped_total = sum(mapped_numbers) if mapped_numbers else None
    mapped_average = mapped_total / len(mapped_numbers) if mapped_numbers else None
    unified.append([
        "Mapped Read Count", mapped_total, mapped_average,
    ] + metadata_blanks + mapped_values)
    total_by_sample = {clean(item.get("sample")): item.get("total_read_count") for item in workbook_samples}
    retained_by_sample = {clean(item.get("sample")): item.get("retained_percent") for item in workbook_samples}
    unified.append(["total_read_count", "", ""] + metadata_blanks + [total_by_sample.get(sample) for sample in sample_names])
    unified.append([
        "percent_reads_unmapped", "", "",
    ] + metadata_blanks + [
        max(0.0, min(100.0, 100.0 - float(retained_by_sample[sample])))
        if retained_by_sample.get(sample) is not None else None
        for sample in sample_names
    ])

    def generated_haplotype(sample, locus, index):
        call = call_for(sample, locus)
        key = "haplotype1" if index == 1 else "haplotype2"
        return clean(call.get(key))

    for locus in ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]:
        for index in (1, 2):
            label = f"{locus} Haplotype {index}"
            values = []
            for sample in sample_names:
                preserved = preserved_analyst_values.get((label, sample))
                values.append(preserved if clean(preserved) else generated_haplotype(sample, locus, index))
            unified.append([label, "", ""] + metadata_blanks + values)
    comment_values = []
    for sample in sample_names:
        preserved = preserved_analyst_values.get(("Comments", sample))
        comment_values.append(preserved if clean(preserved) else comments(sample))
    unified.append(["Comments", "Subtotal", "# Obs."] + metadata_blanks + comment_values)
    unified.append([])
    table_headers = [
        "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
        "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
        "total_cluster_reads",
    ] + sample_names
    unified.append(table_headers)
    header_row = unified.max_row
    headers = {header: index + 1 for index, header in enumerate(table_headers)}

    unified_data_rows = []
    for known in workbook_known_calls:
        call_id = clean(known.get("call_id"))
        reads = known.get("reads_by_sample") or {}
        display_name = clean(known_allele_display_names.get(call_id)) or call_id
        positive_counts = [int(value) for value in reads.values() if int(value) > 0]
        unified_data_rows.append((
            allele_display_sort_key(display_name, call_id),
            [
                "known-allele", call_id, display_name, "", "", "known", "", display_name, "exact",
                len(positive_counts), len(positive_counts), sum(positive_counts),
            ] + [reads.get(sample) if int(reads.get(sample) or 0) > 0 else None for sample in sample_names],
            None,
        ))

    candidate_rows = [
        row for row in normalized_unmatched_rows
        if clean(row.get("record_category")) == "candidate"
    ]
    for record in candidate_rows:
        values = {
            "call_type": f"candidate-{clean(record.get('classification_or_reason'))}",
            "call_id": clean(record.get("stable_cluster_id")),
            "display_name": clean(record.get("provisional_allele_name")),
            "stable_cluster_id": clean(record.get("stable_cluster_id")),
            "locus": clean(record.get("locus")),
            "classification": clean(record.get("classification_or_reason")),
            "support_class": clean(record.get("support_class")),
            "closest_reference": clean(record.get("closest_reference_allele")) or clean(record.get("closest_reference_raw_id")),
            "match_class": clean(record.get("classification_or_reason")),
            "occurrence_count": record.get("occurrence_count"),
            "sample_count": record.get("independent_sample_count"),
            "total_cluster_reads": record.get("total_cluster_reads"),
        }
        reads = record.get("reads_by_sample") or {}
        for sample in sample_names:
            values[sample] = reads.get(sample)
        unified_data_rows.append((
            allele_display_sort_key(values["display_name"], values["stable_cluster_id"]),
            [values.get(header) for header in table_headers],
            normalized_candidate_argb(record),
        ))

    for _sort_key, row, tint in sorted(unified_data_rows, key=lambda item: item[0]):
        unified.append(row)
        if tint:
            unified.cell(unified.max_row, headers["display_name"]).fill = PatternFill(
                fill_type="solid", fgColor=tint
            )

    unified.freeze_panes = unified.cell(header_row + 1, 1).coordinate

    sample_order = sorted({
        sample
        for row in normalized_unmatched_rows
        for sample in (row.get("reads_by_sample") or {}).keys()
    })
    unmatched = replace_sheet("Unmatched Alleles")
    unmatched_headers = [
        "Record Category", "Stable Cluster ID", "Provisional Allele Name", "Locus",
        "Classification or Reason", "Closest Reference Allele", "Closest Reference Raw ID", "Extension Of",
        "SNP Count", "Inserted Bases", "Deleted Bases", "Long Gap Bases", "Comparable Bases",
        "Failed Metrics", "Support Class", "Independent Sample Count", "Occurrence Count",
        "Total Cluster Reads", "Supporting Sample IDs", "FASTA Record ID", "Sequence SHA-256",
        "Nucleotide Sequence", "Putative Amino Acid Translation", "Translation Status",
        "Internal Evidence Reference",
    ] + [f"Sample Reads: {sample}" for sample in sample_order]
    unmatched.append(unmatched_headers)
    for record in sorted(
        normalized_unmatched_rows,
        key=lambda row: allele_display_sort_key(
            clean(row.get("provisional_allele_name")),
            clean(row.get("stable_cluster_id")),
        ),
    ):
        failed_metrics = record.get("failed_metrics") or {}
        row = [
            clean(record.get("record_category")), clean(record.get("stable_cluster_id")),
            clean(record.get("provisional_allele_name")), clean(record.get("locus")),
            clean(record.get("classification_or_reason")), clean(record.get("closest_reference_allele")),
            clean(record.get("closest_reference_raw_id")), ";".join(record.get("extension_of") or []),
            record.get("snp_count"),
            record.get("inserted_bases"), record.get("deleted_bases"), record.get("long_gap_bases"),
            record.get("comparable_bases"), ";".join(f"{key}={failed_metrics[key]}" for key in sorted(failed_metrics)),
            clean(record.get("support_class")), record.get("independent_sample_count"),
            record.get("occurrence_count"), record.get("total_cluster_reads"),
            ";".join(record.get("supporting_sample_ids") or []), clean(record.get("fasta_record_id")),
            clean(record.get("sequence_sha256")), clean(record.get("nucleotide_sequence")),
            clean(record.get("putative_amino_acid_translation")), clean(record.get("translation_status")),
            clean(record.get("internal_evidence_reference")),
        ] + [(record.get("reads_by_sample") or {}).get(sample) for sample in sample_order]
        unmatched.append(row)
        if clean(record.get("record_category")) == "candidate":
            unmatched.cell(unmatched.max_row, 3).fill = PatternFill(
                fill_type="solid", fgColor=normalized_candidate_argb(record)
            )
    style_table_header(unmatched)
    style_table_body(unmatched)
    autosize_columns(unmatched)
    unmatched.freeze_panes = "A2"
    restore_unified_native_content(
        unified,
        header_row,
        headers,
        preserved_unified_native_content,
    )
    restore_unmatched_native_content(unmatched, preserved_unmatched_native_content)

    for worksheet in list(wb.worksheets):
        if worksheet.title not in {"Unified Genotype Pivot", "Unmatched Alleles"}:
            del wb[worksheet.title]


managed_review_state_schema()
validate_matrix_sample_header_ambiguity()
restore_prior_managed_matrix_annotations()
patch_summary_sheet("Abbreviated Haplotypes")
patch_summary_sheet("Custom Sort")
patch_full_sheet()
matrix_review_results = []
if not uses_two_sheet_mhc_contract or preserve_existing_workbook_projection:
    prepare_missing_false_negative_rows()
    matrix_review_results = validate_matrix_reviews()
    write_override_sheets(matrix_review_results)
    write_matrix_annotation_sheet(matrix_review_results)
    apply_matrix_annotations_to_workbook(matrix_review_results)
if not uses_two_sheet_mhc_contract and not preserve_existing_workbook_projection and (
    candidate_configuration.get("candidate_json_path") or candidate_configuration.get("unnameable_json_path")
):
    write_candidate_artifact_sheets()
    write_candidates_to_editable_view()
    enrich_legacy_unmatched_sheets()
if not preserve_existing_workbook_projection:
    upsert_guide_row("Workbook update source", "Lungfish.app Review viewport")
    upsert_guide_row("Workbook update note", "current.xlsx reflects sidecar haplotype overrides at the time this workbook revision was created.")
    upsert_guide_row("Workbook updated haplotype calls", str(sum(len(calls) for calls in calls_by_sample_locus.values())))
    upsert_guide_row("Workbook update overrides", str(len(call_overrides)))
    upsert_guide_row("Workbook update matrix styles", str(len(matrix_styles)))
    upsert_guide_row("Workbook update matrix comments", str(len(matrix_comments)))
    upsert_guide_row("Workbook update matrix reviews", str(len(matrix_reviews)))
    upsert_guide_row("Workbook update valid matrix reviews", str(sum(
        1 for result in matrix_review_results if result["status"] == "valid"
    )))
    upsert_guide_row("Workbook update invalid matrix reviews", str(sum(
        1 for result in matrix_review_results if result["status"] == "invalid"
    )))
    upsert_guide_row("Workbook update audit entries", str(len(audit_entries)))
    upsert_guide_row("Workbook update audit source", "annotations.json")
    upsert_guide_row("Workbook update MHC candidates", str(len(candidate_records)))
    upsert_guide_row("Workbook update un-nameable clusters", str(len(unnameable_records)))
    upsert_guide_row("Workbook candidate tint encoding", candidate_configuration.get("ooxml_alpha_semantics", ""))

if uses_two_sheet_mhc_contract and not preserve_existing_workbook_projection:
    write_two_sheet_mhc_contract()
    if resolved_matrix_styles or resolved_matrix_comments or matrix_reviews:
        prepare_missing_false_negative_rows()
        matrix_review_results = validate_matrix_reviews()
        write_override_sheets(matrix_review_results)
        write_matrix_annotation_sheet(matrix_review_results)
        apply_matrix_annotations_to_workbook(matrix_review_results)


def normalized_package_members(path):
    members = {}
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            content = archive.read(name)
            if name == "docProps/core.xml":
                content = re.sub(
                    rb"(<dcterms:modified\b[^>]*>).*?(</dcterms:modified>)",
                    rb"\1\2",
                    content,
                    flags=re.DOTALL,
                )
            members[name] = content
    return members


wb.save(output_path)
if MANAGED_REVIEW_STATE_SHEET in wb.sheetnames:
    canonical_wb = load_workbook(output_path)
    canonical_state = canonical_wb[MANAGED_REVIEW_STATE_SHEET]
    canonical_state.cell(1, 25).value = new_managed_state_authority
    canonical_state.cell(1, 26).value = managed_state_payload_digest(
        canonical_state, new_managed_state_authority
    )
    canonical_wb.save(output_path)
workbook_semantic_no_op = (
    normalized_package_members(input_path)
    == normalized_package_members(output_path)
)
if workbook_semantic_no_op:
    shutil.copyfile(input_path, output_path)
print(json.dumps({
    "python_version": platform.python_version(),
    "python_executable": sys.executable,
    "openpyxl_version": openpyxl.__version__,
    "matrix_descriptor_scan_count": matrix_descriptor_scan_count,
    "matrix_row_signature_count": matrix_row_signature_count,
    "candidate_count": len([row for row in normalized_unmatched_rows if clean(row.get("record_category")) == "candidate"]),
    "unnameable_count": len([row for row in normalized_unmatched_rows if clean(row.get("record_category")) == "un-nameable"]),
    "preserved_existing_workbook_projection": preserve_existing_workbook_projection,
    "workbook_semantic_no_op": workbook_semantic_no_op,
    "workbook_matrix_adapter_version": WORKBOOK_MATRIX_ADAPTER_VERSION,
    "workbook_adapter_decisions": workbook_adapter_decisions,
    "managed_review_restoration_decisions": managed_review_restoration_decisions,
    "false_negative_synthesis_decisions": false_negative_synthesis_decisions,
    "false_negative_target_cell_decisions": false_negative_target_cell_decisions,
}, sort_keys=True))
"""#
    }

}

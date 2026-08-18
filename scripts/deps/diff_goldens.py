#!/usr/bin/env python3
"""Compare regenerated tool outputs against the committed golden fixtures.

Reads the golden recipe manifest (``scripts/deps/goldens.json``), and for every
recipe compares each declared output in the candidate directory against the same
output in the recipe's golden directory, using a comparator chosen by the
output's ``kind``.

Comparators are deliberately tolerant of the parts of a tool's output that carry
no scientific meaning (timestamps, absolute paths, branch lengths, floating point
noise) and strict about the parts that do (taxon sets, read counts, column
headers, tree topology).

Exit codes:
    0  every compared output matched
    2  at least one output differed
    3  at least one golden directory or golden file was missing

Stdlib only; no third-party imports.
"""

import argparse
import json
import math
import pathlib
import sys

VALID_KINDS = ("text", "tsv", "tsv-header", "json", "kreport", "newick-topology")

STATUS_SAME = "same"
STATUS_DIFFERENT = "different"
STATUS_MISSING = "missing"

EXIT_CLEAN = 0
EXIT_DIFFERENT = 2
EXIT_MISSING = 3


# --------------------------------------------------------------------------
# numeric helpers
# --------------------------------------------------------------------------


def _as_number(value):
    """Return ``value`` as a float when it is numeric, else ``None``."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def numbers_match(golden, candidate, tolerance=0.0, relative=False):
    """True when two numbers agree within ``tolerance``.

    With ``relative`` the tolerance is a fraction of the golden magnitude; a
    golden of exactly zero falls back to the absolute comparison so a relative
    tolerance never silently accepts an arbitrary candidate.
    """
    if math.isnan(golden) or math.isnan(candidate):
        return math.isnan(golden) and math.isnan(candidate)
    delta = abs(golden - candidate)
    if relative and golden != 0.0:
        return delta <= abs(golden) * tolerance
    return delta <= tolerance


def values_match(golden, candidate, spec):
    """Compare two scalar values, numerically when both parse as numbers."""
    tolerance = float(spec.get("numericTolerance", 0) or 0)
    relative = bool(spec.get("relative", False))
    golden_number = _as_number(golden)
    candidate_number = _as_number(candidate)
    if golden_number is not None and candidate_number is not None:
        return numbers_match(golden_number, candidate_number, tolerance, relative)
    return golden == candidate


# --------------------------------------------------------------------------
# comparators
# --------------------------------------------------------------------------


def compare_text(golden, candidate, spec):
    """Exact text comparison, ignoring only trailing whitespace."""
    del spec
    if golden.strip() == candidate.strip():
        return []
    return [f"text differs: golden {golden.strip()!r}, candidate {candidate.strip()!r}"]


def _split_rows(text):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        rows.append(line.split("\t"))
    return rows


def _row_key(row, key_indexes):
    return tuple(row[index] if index < len(row) else "" for index in key_indexes)


def _key_rows(rows, key_indexes):
    """Map each row key to its rows, keeping duplicates rather than collapsing.

    A plain dict comprehension would silently drop all but the last row sharing a
    key, so a golden holding the same key twice would compare equal to a
    candidate holding it once. Keeping the list makes that a reportable
    difference.
    """
    grouped = {}
    for row in rows:
        grouped.setdefault(_row_key(row, key_indexes), []).append(row)
    return grouped


def _duplicate_count_diffs(golden_groups, candidate_groups):
    """Report keys whose number of occurrences differs between the two sides."""
    diffs = []
    for key in sorted(set(golden_groups) & set(candidate_groups)):
        golden_count = len(golden_groups[key])
        candidate_count = len(candidate_groups[key])
        if golden_count != candidate_count:
            diffs.append(
                f"row {'/'.join(key)} occurs {golden_count} time(s) in golden, "
                f"{candidate_count} in candidate"
            )
    return diffs


def compare_tsv(golden, candidate, spec):
    """Positional TSV comparison keyed by ``keyColumns`` index positions.

    ``compareColumns`` names the column indexes whose values must agree; when it
    is absent every column is compared.
    """
    diffs = []
    key_indexes = spec.get("keyColumns", [0])
    golden_rows = _split_rows(golden)
    candidate_rows = _split_rows(candidate)

    if len(golden_rows) != len(candidate_rows):
        diffs.append(f"row count differs: golden {len(golden_rows)}, candidate {len(candidate_rows)}")

    golden_map = _key_rows(golden_rows, key_indexes)
    candidate_map = _key_rows(candidate_rows, key_indexes)

    for key in sorted(set(golden_map) - set(candidate_map)):
        diffs.append(f"row missing from candidate: {'/'.join(key)}")
    for key in sorted(set(candidate_map) - set(golden_map)):
        diffs.append(f"row only in candidate: {'/'.join(key)}")
    diffs.extend(_duplicate_count_diffs(golden_map, candidate_map))

    for key in sorted(set(golden_map) & set(candidate_map)):
        # Compare the first row of each group; a differing number of duplicates
        # is already reported above.
        golden_row = golden_map[key][0]
        candidate_row = candidate_map[key][0]
        compare_indexes = spec.get("compareColumns")
        if compare_indexes is None:
            compare_indexes = range(max(len(golden_row), len(candidate_row)))
        for index in compare_indexes:
            golden_value = golden_row[index] if index < len(golden_row) else ""
            candidate_value = candidate_row[index] if index < len(candidate_row) else ""
            if not values_match(golden_value, candidate_value, spec):
                diffs.append(
                    f"row {'/'.join(key)} column {index}: golden {golden_value!r}, candidate {candidate_value!r}"
                )
    return diffs


def _read_header_table(text):
    rows = _split_rows(text)
    if not rows:
        return [], []
    return rows[0], rows[1:]


def compare_tsv_header(golden, candidate, spec):
    """Header-named TSV comparison. Any header change is a failure.

    A tool that renames, adds, or drops a column has changed its contract even
    when the values the recipe compares are unchanged, so the header is compared
    first and a mismatch short-circuits the value comparison.

    ``compareColumns`` distinguishes three states: absent (``None``) compares
    every column, a non-empty list compares just those columns, and an
    explicit empty list (``[]``) means "headers only": row count and row
    values are not compared at all. This lets a recipe assert schema
    conformance for a tool's output without pinning it to any particular
    dataset's row content (used by the tier 3 pipeline runner, whose live
    inputs never match the committed mini fixtures row for row).
    """
    golden_header, golden_rows = _read_header_table(golden)
    candidate_header, candidate_rows = _read_header_table(candidate)

    if golden_header != candidate_header:
        return [f"header changed: golden {golden_header}, candidate {candidate_header}"]

    compare_columns = spec.get("compareColumns")
    if compare_columns is not None and len(compare_columns) == 0:
        # Headers-only mode: the header equality check above is the entire
        # comparison, so row count and row content differences are ignored.
        return []

    compare_names = compare_columns or list(golden_header)
    missing = [name for name in compare_names if name not in golden_header]
    if missing:
        return [f"header missing declared compare columns: {missing}"]

    key_names = spec.get("keyColumns")
    if key_names:
        key_indexes = [golden_header.index(name) for name in key_names]
    else:
        key_indexes = None

    diffs = []
    if key_indexes is None:
        if len(golden_rows) != len(candidate_rows):
            diffs.append(f"row count differs: golden {len(golden_rows)}, candidate {len(candidate_rows)}")
        for position, (golden_row, candidate_row) in enumerate(zip(golden_rows, candidate_rows)):
            diffs.extend(
                _compare_named_row(golden_header, golden_row, candidate_row, compare_names, spec, f"row {position}")
            )
        return diffs

    if len(golden_rows) != len(candidate_rows):
        diffs.append(f"row count differs: golden {len(golden_rows)}, candidate {len(candidate_rows)}")

    golden_map = _key_rows(golden_rows, key_indexes)
    candidate_map = _key_rows(candidate_rows, key_indexes)
    for key in sorted(set(golden_map) - set(candidate_map)):
        diffs.append(f"row missing from candidate: {'/'.join(key)}")
    for key in sorted(set(candidate_map) - set(golden_map)):
        diffs.append(f"row only in candidate: {'/'.join(key)}")
    diffs.extend(_duplicate_count_diffs(golden_map, candidate_map))
    for key in sorted(set(golden_map) & set(candidate_map)):
        diffs.extend(
            _compare_named_row(
                golden_header,
                golden_map[key][0],
                candidate_map[key][0],
                compare_names,
                spec,
                f"row {'/'.join(key)}",
            )
        )
    return diffs


def _compare_named_row(header, golden_row, candidate_row, compare_names, spec, label):
    diffs = []
    for name in compare_names:
        index = header.index(name)
        golden_value = golden_row[index] if index < len(golden_row) else ""
        candidate_value = candidate_row[index] if index < len(candidate_row) else ""
        if not values_match(golden_value, candidate_value, spec):
            diffs.append(f"{label} column {name}: golden {golden_value!r}, candidate {candidate_value!r}")
    return diffs


def _coerce_json(value):
    if isinstance(value, (str, bytes)):
        return json.loads(value)
    return value


def compare_json(golden, candidate, spec):
    """Recursive JSON comparison honouring ``ignoreKeys`` and numeric tolerance.

    Accepts either parsed objects or raw JSON text so the comparator can be
    called directly from tests as well as from the file-driven path.
    """
    try:
        golden_value = _coerce_json(golden)
    except json.JSONDecodeError as error:
        return [f"golden is not valid JSON: {error}"]
    try:
        candidate_value = _coerce_json(candidate)
    except json.JSONDecodeError as error:
        return [f"candidate is not valid JSON: {error}"]

    ignore = set(spec.get("ignoreKeys", []))
    diffs = []
    _walk_json(golden_value, candidate_value, spec, ignore, "$", diffs)
    return diffs


def _walk_json(golden, candidate, spec, ignore, trail, diffs):
    if isinstance(golden, dict) and isinstance(candidate, dict):
        golden_keys = {key for key in golden if key not in ignore}
        candidate_keys = {key for key in candidate if key not in ignore}
        for key in sorted(golden_keys - candidate_keys):
            diffs.append(f"{trail}.{key}: missing from candidate")
        for key in sorted(candidate_keys - golden_keys):
            diffs.append(f"{trail}.{key}: only in candidate")
        for key in sorted(golden_keys & candidate_keys):
            _walk_json(golden[key], candidate[key], spec, ignore, f"{trail}.{key}", diffs)
        return

    if isinstance(golden, list) and isinstance(candidate, list):
        if len(golden) != len(candidate):
            diffs.append(f"{trail}: length golden {len(golden)}, candidate {len(candidate)}")
            return
        for index, (golden_item, candidate_item) in enumerate(zip(golden, candidate)):
            _walk_json(golden_item, candidate_item, spec, ignore, f"{trail}[{index}]", diffs)
        return

    golden_number = _as_number(golden)
    candidate_number = _as_number(candidate)
    if golden_number is not None and candidate_number is not None:
        tolerance = float(spec.get("numericTolerance", 0) or 0)
        relative = bool(spec.get("relative", False))
        if not numbers_match(golden_number, candidate_number, tolerance, relative):
            diffs.append(f"{trail}: golden {golden}, candidate {candidate}")
        return

    if golden != candidate:
        diffs.append(f"{trail}: golden {golden!r}, candidate {candidate!r}")


def parse_kreport(text):
    """Parse a Kraken2 report into ``{(rank, taxid, name): (clade, direct)}``.

    Kraken2 emits six columns by default and eight with ``--report-minimizer-data``
    (two extra numeric columns before the rank code), so the rank code is located
    by scanning from the right rather than by a fixed index.
    """
    rows = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 6:
            continue
        name = fields[-1].strip()
        taxid = fields[-2].strip()
        rank = fields[-3].strip()
        try:
            clade_reads = int(fields[1])
            direct_reads = int(fields[2])
        except (IndexError, ValueError):
            continue
        rows[(rank, taxid, name)] = (clade_reads, direct_reads)
    return rows


def compare_kreport(golden, candidate, spec):
    """Compare the taxon set and per-taxon read counts of two Kraken2 reports.

    Percentages are derived from the counts and so are not compared separately.
    The default tolerance is 0: a classification database or a Kraken2 version
    that reassigns even one read is a signal worth surfacing.
    """
    golden_rows = parse_kreport(golden)
    candidate_rows = parse_kreport(candidate)
    diffs = []

    for key in sorted(set(golden_rows) - set(candidate_rows)):
        diffs.append(f"taxon missing from candidate: {key[0]} {key[1]} {key[2]}")
    for key in sorted(set(candidate_rows) - set(golden_rows)):
        diffs.append(f"taxon only in candidate: {key[0]} {key[1]} {key[2]}")

    for key in sorted(set(golden_rows) & set(candidate_rows)):
        golden_counts = golden_rows[key]
        candidate_counts = candidate_rows[key]
        for label, golden_count, candidate_count in (
            ("clade reads", golden_counts[0], candidate_counts[0]),
            ("direct reads", golden_counts[1], candidate_counts[1]),
        ):
            if not values_match(golden_count, candidate_count, spec):
                diffs.append(
                    f"{key[0]} {key[1]} {key[2]} {label}: golden {golden_count}, candidate {candidate_count}"
                )
    return diffs


def parse_newick_leaves_and_splits(text):
    """Return ``(leaf_names, splits)`` for a Newick tree, ignoring branch lengths.

    Splits are the unrooted bipartitions induced by the internal edges, each
    normalised to the side that does not contain the lexicographically smallest
    leaf so that the same unrooted tree yields the same split set regardless of
    where it was rooted.
    """
    cleaned = text.strip()
    if cleaned.endswith(";"):
        cleaned = cleaned[:-1]

    stack = [[]]
    leaves = []
    clades = []
    token = ""

    def flush_token():
        nonlocal token
        name = token.strip().split(":")[0].strip()
        token = ""
        if name:
            leaves.append(name)
            stack[-1].append({name})

    for character in cleaned:
        if character == "(":
            flush_token()
            stack.append([])
        elif character == ",":
            flush_token()
        elif character == ")":
            flush_token()
            children = stack.pop()
            clade = set()
            for child in children:
                clade |= child
            clades.append(clade)
            stack[-1].append(clade)
        else:
            token += character
    flush_token()

    leaf_set = set(leaves)
    splits = set()
    for clade in clades:
        if len(clade) < 2 or len(clade) >= len(leaf_set):
            continue
        splits.add(_normalise_split(clade, leaf_set))
    return leaf_set, splits


def _normalise_split(clade, leaf_set):
    complement = leaf_set - clade
    if not complement:
        return tuple(sorted(clade))
    anchor = min(leaf_set)
    side = complement if anchor in clade else clade
    return tuple(sorted(side))


def compare_newick(golden, candidate, spec):
    """Compare two Newick trees by leaf set and unrooted topology."""
    del spec
    diffs = []
    golden_leaves, golden_splits = parse_newick_leaves_and_splits(golden)
    candidate_leaves, candidate_splits = parse_newick_leaves_and_splits(candidate)

    for leaf in sorted(golden_leaves - candidate_leaves):
        diffs.append(f"leaf missing from candidate: {leaf}")
    for leaf in sorted(candidate_leaves - golden_leaves):
        diffs.append(f"leaf only in candidate: {leaf}")
    if diffs:
        return diffs

    for split in sorted(golden_splits - candidate_splits):
        diffs.append(f"split missing from candidate: {'|'.join(split)}")
    for split in sorted(candidate_splits - golden_splits):
        diffs.append(f"split only in candidate: {'|'.join(split)}")
    return diffs


COMPARATORS = {
    "text": compare_text,
    "tsv": compare_tsv,
    "tsv-header": compare_tsv_header,
    "json": compare_json,
    "kreport": compare_kreport,
    "newick-topology": compare_newick,
}


# --------------------------------------------------------------------------
# recipe driving
# --------------------------------------------------------------------------


def golden_directory(recipe, dependency_set, golden_root, repo_root):
    """Resolve a recipe's golden directory for ``dependency_set``.

    ``--golden-root`` replaces the directory portion of the recipe's ``golden``
    field, keeping only its final path component, so a candidate tree produced by
    ``regenerate-goldens.sh`` (which lays out ``<out>/<id>``) can be compared as a
    golden root without editing the manifest.
    """
    relative = recipe["golden"].replace("{set}", dependency_set)
    if golden_root is not None:
        return pathlib.Path(golden_root) / pathlib.PurePosixPath(relative).name
    return pathlib.Path(repo_root) / relative


def compare_recipe(recipe, dependency_set, golden_root, candidate_root, repo_root):
    """Compare every declared output of one recipe. Returns a list of results."""
    results = []
    golden_dir = golden_directory(recipe, dependency_set, golden_root, repo_root)
    candidate_dir = pathlib.Path(candidate_root) / recipe["id"]

    for name, spec in recipe["outputs"].items():
        golden_file = golden_dir / name
        candidate_file = candidate_dir / name
        result = {"id": recipe["id"], "output": name, "kind": spec.get("kind", "text")}

        if not golden_file.is_file():
            result["status"] = STATUS_MISSING
            result["detail"] = f"missing golden file: {golden_file}"
            results.append(result)
            continue
        if not candidate_file.is_file():
            result["status"] = STATUS_MISSING
            result["detail"] = f"missing candidate file: {candidate_file}"
            results.append(result)
            continue

        comparator = COMPARATORS.get(result["kind"])
        if comparator is None:
            result["status"] = STATUS_DIFFERENT
            result["detail"] = f"unknown output kind: {result['kind']}"
            results.append(result)
            continue

        golden_text = golden_file.read_text(encoding="utf-8", errors="replace")
        candidate_text = candidate_file.read_text(encoding="utf-8", errors="replace")
        diffs = comparator(golden_text, candidate_text, spec)
        if diffs:
            result["status"] = STATUS_DIFFERENT
            result["detail"] = diffs[0]
            result["differences"] = diffs
        else:
            result["status"] = STATUS_SAME
            result["detail"] = ""
        results.append(result)

    return results


def render_markdown(results, dependency_set):
    lines = [f"### Golden comparison for dependency set `{dependency_set}`", ""]
    lines.append("| recipe | output | status | first difference |")
    lines.append("| --- | --- | --- | --- |")
    for result in results:
        detail = result.get("detail", "").replace("|", "\\|")
        if len(detail) > 160:
            detail = detail[:157] + "..."
        lines.append(f"| {result['id']} | {result['output']} | {result['status']} | {detail} |")
    lines.append("")
    same = sum(1 for result in results if result["status"] == STATUS_SAME)
    different = sum(1 for result in results if result["status"] == STATUS_DIFFERENT)
    missing = sum(1 for result in results if result["status"] == STATUS_MISSING)
    lines.append(f"{same} same, {different} different, {missing} missing.")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare regenerated tool outputs against committed golden fixtures."
    )
    parser.add_argument(
        "--recipes",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent / "goldens.json",
        help="Path to the golden recipe manifest (default: scripts/deps/goldens.json).",
    )
    parser.add_argument(
        "--candidate",
        type=pathlib.Path,
        required=True,
        help="Directory holding regenerated outputs laid out as <candidate>/<recipe id>/...",
    )
    parser.add_argument(
        "--golden-root",
        type=pathlib.Path,
        default=None,
        help="Override the directory part of each recipe's golden path (default: the repo checkout).",
    )
    parser.add_argument("--set", dest="dependency_set", required=True, help="Dependency set id, e.g. 2026.1.")
    parser.add_argument("--only", default=None, help="Comma-separated recipe ids to compare.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON instead of Markdown.")
    args = parser.parse_args(argv)

    repo_root = pathlib.Path(__file__).resolve().parents[2]
    manifest = json.loads(args.recipes.read_text(encoding="utf-8"))
    recipes = manifest.get("goldens", [])

    if args.only:
        wanted = {value.strip() for value in args.only.split(",") if value.strip()}
        unknown = wanted - {recipe["id"] for recipe in recipes}
        if unknown:
            parser.error(f"unknown recipe ids: {', '.join(sorted(unknown))}")
        recipes = [recipe for recipe in recipes if recipe["id"] in wanted]

    results = []
    for recipe in recipes:
        results.extend(
            compare_recipe(recipe, args.dependency_set, args.golden_root, args.candidate, repo_root)
        )

    if args.json:
        print(json.dumps({"set": args.dependency_set, "results": results}, indent=2, sort_keys=True))
    else:
        print(render_markdown(results, args.dependency_set))

    if any(result["status"] == STATUS_MISSING for result in results):
        return EXIT_MISSING
    if any(result["status"] == STATUS_DIFFERENT for result in results):
        return EXIT_DIFFERENT
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())

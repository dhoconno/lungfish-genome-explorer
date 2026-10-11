"""Tests for the golden prediction checker (scripts/golden/predictions.py).

Most tests perturb a small synthetic golden tree, hand the checker a predictions
document and compare the exact set of problems it reports. A problem reads
"<category> <file> <kind> <where>", for example
"unpredicted mapping/counts.json changed /mapped".
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "golden"))
sys.dont_write_bytecode = True

import predictions  # noqa: E402

# A synthetic golden tree ---------------------------------------------------------


def foundation(document) -> bytes:
    """JSON the way the Swift encoder writes goldens: sorted keys, spaces around colons, escaped slashes."""
    text = json.dumps(document, indent=2, sort_keys=True, separators=(",", " : "))
    return text.replace("/", "\\/").encode()


def indent_four(document) -> bytes:
    text = json.dumps(document, indent=4, sort_keys=True, separators=(",", " : "))
    return text.replace("/", "\\/").encode()


def reversed_keys(document) -> bytes:
    text = json.dumps(dict(reversed(list(document.items()))), indent=2, separators=(",", " : "))
    return text.replace("/", "\\/").encode()


def step(name: str) -> dict:
    return {"id": name, "toolName": name, "toolVersion": "unknown", "argv": [name, "-t", "2"], "processIdentifier": "<PID>"}


COUNTS = "mapping/counts.json"
PROVENANCE = "mapping/provenance.json"
ENVIRONMENT = "classifiers/environment.json"
MAP_HELP = "cli-help/lungfish-cli.map.txt"
INDEX_FILE = "cli-help/index.tsv"
HASH_FILE = "mapping/records.sha256"
BINARY_FILE = "tools/bgzip/outputs/test.vcf.gz"

JSON_GOLDENS = {
    COUNTS: {
        "mapped": 197,
        "total": 200,
        "ratio": 0.985,
        "verified": True,
        "perContig": {"MN908947.3": {"mapped": 197, "unmapped": 3}},
    },
    PROVENANCE: {
        "schemaVersion": 1,
        "steps": [step("minimap2"), step("samtools-sort"), step("samtools-index")],
        "runtimeIdentity": {"executablePath": "<RUN_ROOT>/bin/lungfish-cli", "dependencySet": "2026.2"},
    },
    ENVIRONMENT: {
        "files": {"v3.2.4/db.fna": {"sha256": "ab12", "sizeBytes": 10}, "v3.2.4/db.mmi": {"sha256": "cd34", "sizeBytes": 20}}
    },
}
HELP = (
    "OVERVIEW: Map reads\n\nUSAGE: lungfish-cli map [--threads <n>]\n\nOPTIONS:\n"
    "  --threads <n>  Threads (default: active cores)\n  -h, --help     Show help information.\n"
)
INDEX = (
    "command\tvisibility\texit\tfile\n"
    "lungfish-cli\tshown\t0\tlungfish-cli.txt\n"
    "lungfish-cli map\tshown\t0\tlungfish-cli.map.txt\n"
    "lungfish-cli bam\tshown\t0\tlungfish-cli.bam.txt\n"
)
BINARY = bytes([0x1F, 0x8B, 0x08, 0x00, 0xFF, 0xFE, 0x00, 0x01])
BASE = {
    **{name: foundation(document) for name, document in JSON_GOLDENS.items()},
    INDEX_FILE: INDEX.encode(),
    MAP_HELP: HELP.encode(),
    "cli-help/lungfish-cli.bam.txt": b"OVERVIEW: BAM tools\n",
    HASH_FILE: b"285b0afd6ab4  samtools view --no-PG (200 records)\n",
    BINARY_FILE: BINARY,
    "README.md": b"# Goldens\n",
}


def set_at(*path_and_value):
    """A mutator that sets the node at a path of keys and list indexes to the last argument."""
    *path, value = path_and_value

    def mutate(document):
        node = document
        for part in path[:-1]:
            node = node[part]
        node[path[-1]] = value

    return mutate


def drop_at(*path):
    def mutate(document):
        node = document
        for part in path[:-1]:
            node = node[part]
        del node[path[-1]]

    return mutate


def set_versions(*versions):
    """A mutator that gives the steps of a provenance document these tool versions, in order."""

    def mutate(document):
        for each, version in zip(document["steps"], versions):
            each["toolVersion"] = version

    return mutate


def edit_json(name: str, mutate, dump=foundation) -> dict:
    document = copy.deepcopy(JSON_GOLDENS[name])
    mutate(document)
    return {name: dump(document)}


def edit_text(name: str, old: str, new: str) -> dict:
    text = BASE[name].decode()
    assert old in text
    return {name: text.replace(old, new, 1).encode()}


def tree(edits: dict) -> dict:
    """The base tree with `edits` applied. A value of None deletes the file."""
    out = dict(BASE)
    for name, data in edits.items():
        if data is None:
            del out[name]
        else:
            out[name] = data
    return out


# Predictions documents and the checker's verdict ---------------------------------


def entry(file, **rules) -> dict:
    return {"file": file, "why": "the lane says so", **rules}


def doc(*entries, added=None, removed=None, ignore=None) -> dict:
    body = {"version": 1, "files": list(entries)}
    for key, value in (("filesAdded", added), ("filesRemoved", removed), ("ignore", ignore)):
        if value:
            body[key] = value
    return body


NOTHING = doc()


def check_trees(old: dict, new: dict, prediction):
    """What `check` does once it has read the two trees and the predictions file."""
    loaded = predictions.load_predictions(prediction if isinstance(prediction, str) else json.dumps(prediction))
    changes = predictions.compare_trees(predictions.drop_ignored(old, loaded.ignore), predictions.drop_ignored(new, loaded.ignore))
    return loaded, changes, predictions.evaluate(changes, loaded.rules)


def problems(old: dict, new: dict, prediction) -> list[str]:
    _, _, verdict = check_trees(old, new, prediction)

    def say(category: str, file: str, kind: str, place: str) -> str:
        return " ".join(part for part in (category, file, kind, place) if part)

    lines = [say("unpredicted", c.file, c.kind, predictions.where(c)) for c in verdict.unpredicted]
    lines += [say("wrong", c.file, c.kind, predictions.where(c)) for c, _rule, _problem in verdict.wrong]
    for rule, _got in verdict.unfulfilled:
        place = predictions.render_path(rule.path) if rule.path is not None else ""
        lines.append(say("unfulfilled", rule.globs[0], rule.kind, place))
    return sorted(lines)


# At least twenty perturbations ----------------------------------------------------


def case(name, edits, prediction, expected):
    return pytest.param(tree(edits), prediction, expected, id=name)


MAPPED_198 = edit_json(COUNTS, set_at("mapped", 198))
NO_PIDS = edit_json(PROVENANCE, lambda d: [s.pop("processIdentifier") for s in d["steps"]])
LONGER_DEFAULT = edit_text(MAP_HELP, "(default: active cores)", "(default: 8)")
EXTRA_OPTION = edit_text(MAP_HELP, "  -h, --help", "  --max <n>  Limit.\n  -h, --help")
BINARY_CHANGED = {BINARY_FILE: BINARY[:-1] + b"\x02"}
INDEX_LINES = INDEX.splitlines(keepends=True)
INDEX_REORDERED = {INDEX_FILE: "".join(INDEX_LINES[:1] + INDEX_LINES[:0:-1]).encode()}
NOTE_IN_TWO_FILES = {**edit_json(COUNTS, set_at("note", "x")), **edit_json(ENVIRONMENT, set_at("note", "x"))}
ESCAPED_SLASH_KEY = edit_json(ENVIRONMENT, set_at("files", "v3.2.4/db.fna", "sizeBytes", 11))

PERTURBATIONS = [
    # A value changes
    case("value-changed-and-predicted", MAPPED_198, doc(entry(COUNTS, changed=[{"path": "/mapped", "value": 198}])), []),
    case("value-changed-unpredicted", MAPPED_198, NOTHING, ["unpredicted mapping/counts.json changed /mapped"]),
    case(
        "value-differs-from-the-predicted-one",
        MAPPED_198,
        doc(entry(COUNTS, changed=[{"path": "/mapped", "value": 199}])),
        ["wrong mapping/counts.json changed /mapped"],
    ),
    case(
        "old-value-differs-from-the-predicted-one",
        MAPPED_198,
        doc(entry(COUNTS, changed=[{"path": "/mapped", "old": 150}])),
        ["wrong mapping/counts.json changed /mapped"],
    ),
    case("value-matches-the-pattern", MAPPED_198, doc(entry(COUNTS, changed=[{"path": "/mapped", "pattern": "19[0-9]"}])), []),
    case(
        "value-fails-the-pattern",
        MAPPED_198,
        doc(entry(COUNTS, changed=[{"path": "/mapped", "pattern": "2[0-9][0-9]"}])),
        ["wrong mapping/counts.json changed /mapped"],
    ),
    case(
        "a-rule-without-a-value-does-not-excuse-a-value-that-a-narrow-rule-refuses",
        edit_json(PROVENANCE, set_versions("2.28", "1.21", "/Users/dho/garbage")),
        doc(entry(PROVENANCE, changed=[{"path": "/steps[*]/toolVersion", "pattern": "[0-9.]+"}, {"path": "/steps[*]/*"}])),
        ["wrong mapping/provenance.json changed /steps[2]/toolVersion"],
    ),
    case(
        "number-is-respelled",
        edit_text(COUNTS, "0.985", "0.9850"),
        NOTHING,
        ["unpredicted mapping/counts.json changed /ratio"],
    ),
    case(
        "number-respelling-is-predicted-as-spelled",
        edit_text(COUNTS, "0.985", "0.9850"),
        '{"files": [{"file": "mapping/counts.json", "why": "x", "changed": [{"path": "/ratio", "old": 0.985, "value": 0.9850}]}]}',
        [],
    ),
    case("number-becomes-a-string", edit_json(COUNTS, set_at("total", "200")), NOTHING, ["unpredicted mapping/counts.json changed /total"]),
    case("true-becomes-1", edit_json(COUNTS, set_at("verified", 1)), NOTHING, ["unpredicted mapping/counts.json changed /verified"]),
    case("object-becomes-a-string", edit_json(COUNTS, set_at("perContig", "none")), NOTHING, ["unpredicted mapping/counts.json changed /perContig"]),
    # A key is added or removed
    case("key-added-and-predicted", edit_json(COUNTS, set_at("duplicates", 0)), doc(entry(COUNTS, added=[{"path": "/duplicates", "value": 0}])), []),
    case("key-added-unpredicted", edit_json(COUNTS, set_at("duplicates", 0)), NOTHING, ["unpredicted mapping/counts.json added /duplicates"]),
    case("key-removed-and-predicted", edit_json(COUNTS, drop_at("ratio")), doc(entry(COUNTS, removed=[{"path": "/ratio", "old": 0.985}])), []),
    case("key-removed-unpredicted", edit_json(COUNTS, drop_at("ratio")), NOTHING, ["unpredicted mapping/counts.json removed /ratio"]),
    case(
        "key-removed-but-predicted-as-changed",
        edit_json(COUNTS, drop_at("ratio")),
        doc(entry(COUNTS, changed=[{"path": "/ratio"}])),
        ["unfulfilled mapping/counts.json changed /ratio", "unpredicted mapping/counts.json removed /ratio"],
    ),
    case(
        "any-object-key-wildcard",
        edit_json(COUNTS, set_at("perContig", "MN908947.3", "mapped", 150)),
        doc(entry(COUNTS, changed=[{"path": "/perContig/*/mapped"}])),
        [],
    ),
    case(
        "a-slash-in-a-key-is-written-tilde-1",
        ESCAPED_SLASH_KEY,
        doc(entry(ENVIRONMENT, changed=[{"path": "/files/v3.2.4~1db.fna/sizeBytes", "value": 11}])),
        [],
    ),
    # Arrays
    case(
        "array-element-changed-at-any-index",
        edit_json(PROVENANCE, set_at("steps", 1, "toolVersion", "2.1")),
        doc(entry(PROVENANCE, changed=[{"path": "/steps[*]/toolVersion", "old": "unknown", "pattern": "[0-9.]+"}])),
        [],
    ),
    case(
        "array-element-changed-at-another-index-than-predicted",
        edit_json(PROVENANCE, set_at("steps", 1, "toolVersion", "2.1")),
        doc(entry(PROVENANCE, changed=[{"path": "/steps[0]/toolVersion"}])),
        ["unfulfilled mapping/provenance.json changed /steps[0]/toolVersion", "unpredicted mapping/provenance.json changed /steps[1]/toolVersion"],
    ),
    case(
        "array-element-appended",
        edit_json(PROVENANCE, lambda d: d["steps"].append(step("bcftools"))),
        doc(entry(PROVENANCE, added=[{"path": "/steps[3]"}])),
        [],
    ),
    case(
        "array-element-removed-from-the-middle",
        edit_json(PROVENANCE, lambda d: d["steps"].pop(1)),
        NOTHING,
        ["unpredicted mapping/provenance.json removed /steps[1]"],
    ),
    case(
        "array-element-removal-predicted-for-any-index",
        edit_json(PROVENANCE, lambda d: d["steps"].pop(1)),
        doc(entry(PROVENANCE, removed=[{"path": "/steps[*]", "count": 1}])),
        [],
    ),
    case("array-reordered", edit_json(PROVENANCE, lambda d: d["steps"].reverse()), NOTHING, ["unpredicted mapping/provenance.json reordered /steps"]),
    case(
        "array-reorder-predicted",
        edit_json(PROVENANCE, lambda d: d["steps"].reverse()),
        doc(entry(PROVENANCE, reordered=[{"path": "/steps"}])),
        [],
    ),
    case(
        "object-keys-reordered",
        edit_json(COUNTS, lambda d: None, dump=reversed_keys),
        NOTHING,
        ["unpredicted mapping/counts.json reordered (document)"],
    ),
    # The same change in many places
    case("count-matches", NO_PIDS, doc(entry(PROVENANCE, removed=[{"path": "/steps[*]/processIdentifier", "count": 3}])), []),
    case(
        "count-too-high",
        NO_PIDS,
        doc(entry(PROVENANCE, removed=[{"path": "/steps[*]/processIdentifier", "count": 4}])),
        ["unfulfilled mapping/provenance.json removed /steps[*]/processIdentifier"],
    ),
    case(
        "count-too-low",
        NO_PIDS,
        doc(entry(PROVENANCE, removed=[{"path": "/steps[*]/processIdentifier", "count": 2}])),
        ["unfulfilled mapping/provenance.json removed /steps[*]/processIdentifier"],
    ),
    case("one-glob-covers-two-files", NOTE_IN_TWO_FILES, doc(entry("**/*.json", added=[{"path": "/note", "value": "x", "count": 2}])), []),
    case(
        "a-single-star-stays-in-its-folder",
        NOTE_IN_TWO_FILES,
        doc(entry("*.json", added=[{"path": "/note"}])),
        [
            "unfulfilled *.json added /note",
            "unpredicted classifiers/environment.json added /note",
            "unpredicted mapping/counts.json added /note",
        ],
    ),
    case("a-list-of-files-is-one-entry", NOTE_IN_TWO_FILES, doc(entry([COUNTS, ENVIRONMENT], added=[{"path": "/note"}])), []),
    # A prediction that never happens
    case("prediction-never-happens", {}, doc(entry(COUNTS, added=[{"path": "/neverThere"}])), ["unfulfilled mapping/counts.json added /neverThere"]),
    case(
        "prediction-names-a-file-that-does-not-exist",
        {},
        doc(entry("mapping/ghost.json", reformatted=True)),
        ["unfulfilled mapping/ghost.json reformatted"],
    ),
    case("nothing-changes-and-nothing-is-predicted", {}, NOTHING, []),
    # Layout of a JSON file
    case("indentation-changes", edit_json(COUNTS, lambda d: None, dump=indent_four), NOTHING, ["unpredicted mapping/counts.json reformatted"]),
    case("indentation-change-is-predicted", edit_json(COUNTS, lambda d: None, dump=indent_four), doc(entry(COUNTS, reformatted=True)), []),
    case(
        "layout-change-does-not-hide-behind-a-predicted-key-change",
        edit_json(COUNTS, set_at("mapped", 198), dump=indent_four),
        doc(entry(COUNTS, changed=[{"path": "/mapped", "value": 198}])),
        ["unpredicted mapping/counts.json reformatted"],
    ),
    case(
        "slash-escaping-switches-to-plain",
        {PROVENANCE: BASE[PROVENANCE].replace(b"\\/", b"/")},
        NOTHING,
        ["unpredicted mapping/provenance.json reformatted"],
    ),
    case(
        "slash-escaping-change-does-not-hide-behind-a-key-change",
        {PROVENANCE: BASE[PROVENANCE].replace(b"\\/", b"/").replace(b'"schemaVersion" : 1', b'"schemaVersion" : 2')},
        doc(entry(PROVENANCE, changed=[{"path": "/schemaVersion", "value": 2}])),
        ["unpredicted mapping/provenance.json reformatted"],
    ),
    case("spaces-around-colons-change", {COUNTS: BASE[COUNTS].replace(b" : ", b": ")}, NOTHING, ["unpredicted mapping/counts.json reformatted"]),
    case("json-gains-a-final-newline", {COUNTS: BASE[COUNTS] + b"\n"}, NOTHING, ["unpredicted mapping/counts.json reformatted"]),
    # Whole files
    case("new-file-unpredicted", {"mapping/extra.txt": b"x\n"}, NOTHING, ["unpredicted mapping/extra.txt file-added"]),
    case("new-file-predicted", {"mapping/extra.txt": b"x\n"}, doc(added={"mapping/extra.txt": "a new output"}), []),
    case(
        "new-files-predicted-by-a-glob-with-a-count",
        {"cli-help/lungfish-cli.a.txt": b"a\n", "cli-help/lungfish-cli.b.txt": b"b\n"},
        doc(added={"cli-help/*.txt": {"why": "two commands", "count": 2}}),
        [],
    ),
    case(
        "fewer-new-files-than-the-count",
        {"cli-help/lungfish-cli.a.txt": b"a\n"},
        doc(added={"cli-help/*.txt": {"why": "two commands", "count": 2}}),
        ["unfulfilled cli-help/*.txt file-added"],
    ),
    case("predicted-new-file-never-appears", {}, doc(added={"mapping/extra.txt": "a new output"}), ["unfulfilled mapping/extra.txt file-added"]),
    case("file-removed-unpredicted", {"cli-help/lungfish-cli.bam.txt": None}, NOTHING, ["unpredicted cli-help/lungfish-cli.bam.txt file-removed"]),
    case(
        "file-removed-predicted",
        {"cli-help/lungfish-cli.bam.txt": None},
        doc(removed={"cli-help/lungfish-cli.bam.txt": "the command is gone"}),
        [],
    ),
    case(
        "new-file-predicted-as-removed",
        {"mapping/extra.txt": b"x\n"},
        doc(removed={"mapping/extra.txt": "wrong way round"}),
        ["unfulfilled mapping/extra.txt file-removed", "unpredicted mapping/extra.txt file-added"],
    ),
    case(
        "a-scientific-payload-changes-in-a-file-nobody-listed",
        {HASH_FILE: b"000000000000  samtools view --no-PG (200 records)\n"},
        doc(entry(COUNTS, added=[{"path": "/neverThere"}])),
        ["unfulfilled mapping/counts.json added /neverThere", "unpredicted mapping/records.sha256 changed line 1"],
    ),
    case("an-ignored-file-is-left-out", {"README.md": b"# New text\n"}, doc(ignore={"README.md": "documentation"}), []),
    case(
        "an-ignore-pattern-names-whole-files-only",
        {"README.md.bak": b"x\n", "docs/README.md": b"y\n"},
        doc(ignore={"README.md": "documentation"}),
        ["unpredicted README.md.bak file-added", "unpredicted docs/README.md file-added"],
    ),
    case("a-file-is-not-ignored-unless-the-predictions-say-so", {"README.md": b"# New text\n"}, NOTHING, ["unpredicted README.md changed line 1"]),
    # Binary files
    case("binary-file-changes", BINARY_CHANGED, NOTHING, ["unpredicted tools/bgzip/outputs/test.vcf.gz binary"]),
    case("binary-change-predicted", BINARY_CHANGED, doc(entry("tools/**/*.gz", binary=True)), []),
    # Text files, compared by line
    case("help-line-changes", LONGER_DEFAULT, NOTHING, ["unpredicted cli-help/lungfish-cli.map.txt changed line 6"]),
    case(
        "help-line-change-predicted-by-old-and-new-text",
        LONGER_DEFAULT,
        doc(
            entry(
                "cli-help/*.txt",
                changed=[{"old": "  --threads <n>  Threads (default: active cores)", "value": "  --threads <n>  Threads (default: 8)"}],
            )
        ),
        [],
    ),
    case(
        "help-line-change-differs-from-the-prediction",
        LONGER_DEFAULT,
        doc(entry("cli-help/*.txt", changed=[{"value": "  --threads <n>  Threads (default: 4)"}])),
        ["wrong cli-help/lungfish-cli.map.txt changed line 6"],
    ),
    case("help-line-added", EXTRA_OPTION, doc(entry(MAP_HELP, added=[{"pattern": "  --max <n> .*"}])), []),
    case("help-line-added-unpredicted", EXTRA_OPTION, NOTHING, ["unpredicted cli-help/lungfish-cli.map.txt added line 7"]),
    case(
        "help-line-removed",
        edit_text(MAP_HELP, "  -h, --help     Show help information.\n", ""),
        doc(entry(MAP_HELP, removed=[{"old": "  -h, --help     Show help information."}])),
        [],
    ),
    case("table-rows-reordered", INDEX_REORDERED, NOTHING, ["unpredicted cli-help/index.tsv reordered"]),
    case("table-reorder-predicted", INDEX_REORDERED, doc(entry(INDEX_FILE, reordered=[{}])), []),
    case(
        "table-row-inserted-in-the-middle-is-one-change",
        edit_text(INDEX_FILE, "lungfish-cli bam", "lungfish-cli align\tshown\t0\tlungfish-cli.align.txt\nlungfish-cli bam"),
        doc(entry(INDEX_FILE, added=[{"pattern": "lungfish-cli align\t.*", "count": 1}])),
        [],
    ),
    case("text-loses-its-final-newline", {HASH_FILE: BASE[HASH_FILE].rstrip(b"\n")}, NOTHING, ["unpredicted mapping/records.sha256 reformatted"]),
]


@pytest.mark.parametrize(("new", "prediction", "expected"), PERTURBATIONS)
def test_perturbation_is_reported_exactly(new, prediction, expected):
    assert problems(BASE, new, prediction) == sorted(expected)


def test_there_are_at_least_twenty_perturbations():
    assert len(PERTURBATIONS) >= 20


# How predictions and changes meet ---------------------------------------------------


def test_a_rule_that_gives_a_value_decides_even_when_a_rule_without_one_covers_the_change():
    prediction = doc(entry(COUNTS, changed=[{"path": "/mapped"}, {"path": "/mapped", "value": 199}]))
    # the broad rule would take any value, but the narrow one refuses 198, so the change is a wrong value
    _, _, verdict = check_trees(BASE, tree(MAPPED_198), prediction)
    assert problems(BASE, tree(MAPPED_198), prediction) == ["wrong mapping/counts.json changed /mapped"]
    assert verdict.wrong[0][2] == "new value is 198, predicted 199"


def test_a_change_that_every_rule_giving_a_value_refuses_is_counted_by_no_rule():
    prediction = doc(entry(COUNTS, changed=[{"path": "/mapped", "value": 199}, {"path": "/mapped", "count": 1}]))
    _, _, verdict = check_trees(BASE, tree(MAPPED_198), prediction)
    assert verdict.accepted == [0, 0]
    assert problems(BASE, tree(MAPPED_198), prediction) == [
        "unfulfilled mapping/counts.json changed /mapped",
        "wrong mapping/counts.json changed /mapped",
    ]


def test_a_change_that_one_deciding_rule_accepts_stands_and_the_deciding_rule_that_refused_it_is_unfulfilled():
    prediction = doc(entry(COUNTS, changed=[{"path": "/mapped", "value": 199}, {"path": "/mapped", "pattern": "19[0-9]"}, {"path": "/*"}]))
    _, _, verdict = check_trees(BASE, tree(MAPPED_198), prediction)
    # the pattern accepts 198 and the rule without a value goes along, but the rule that wanted 199 never saw it
    assert verdict.accepted == [0, 1, 1] and not verdict.wrong
    assert problems(BASE, tree(MAPPED_198), prediction) == ["unfulfilled mapping/counts.json changed /mapped"]


def test_two_rules_that_both_accept_a_change_both_count_it():
    loaded, changes, verdict = check_trees(
        BASE, tree(MAPPED_198), doc(entry(COUNTS, changed=[{"path": "/mapped", "count": 1}, {"path": "/*", "count": 1}]))
    )
    assert verdict.ok and verdict.accepted == [1, 1]


def test_a_rule_without_a_path_names_the_document_itself():
    new = tree({COUNTS: foundation(["a", "b"]), PROVENANCE: BASE[PROVENANCE]})
    assert problems(BASE, new, NOTHING) == ["unpredicted mapping/counts.json changed (document)"]
    assert problems(BASE, new, doc(entry(COUNTS, changed=[{}]))) == []


def test_indexes_of_a_removed_element_are_old_positions_and_of_an_added_one_new_positions():
    old = {"a.json": foundation({"rows": ["a", "b", "c", "d", "e"]})}
    new = {"a.json": foundation({"rows": ["a", "c", "d", "e", "f"]})}
    changes = predictions.compare_trees(old, new)
    assert [(c.kind, predictions.render_path(c.path)) for c in changes] == [("removed", "/rows[1]"), ("added", "/rows[4]")]
    # an element inserted before the removed one shifts its new position, and the removal still names the old one
    shifted = predictions.compare_trees({"a.json": foundation({"rows": ["a", "b", "c"]})}, {"a.json": foundation({"rows": ["x", "a", "c"]})})
    assert [(c.kind, predictions.render_path(c.path)) for c in shifted] == [("added", "/rows[0]"), ("removed", "/rows[1]")]


def test_a_long_array_with_one_inserted_row_is_one_change():
    rows = [{"n": n, "name": f"row{n}"} for n in range(3000)]
    grown = rows[:1500] + [{"n": -1, "name": "new"}] + rows[1500:]
    changes = predictions.compare_json("big.json", foundation({"rows": rows}).decode(), foundation({"rows": grown}).decode())
    assert [(c.kind, c.path) for c in changes] == [("added", ("rows", 1500))]


def test_invalid_json_is_never_predicted():
    new = tree({COUNTS: BASE[COUNTS][:-5]})
    found = problems(BASE, new, doc(entry(COUNTS, changed=[{"path": "/mapped"}], reformatted=True)))
    assert "unpredicted mapping/counts.json invalid-json" in found


def test_two_json_files_that_differ_only_in_trailing_blank_lines_are_reformatted():
    changes = predictions.compare_json("a.json", '{"a" : 1}\n', '{"a" : 1}\n\n')
    assert [(c.kind, c.line) for c in changes] == [("reformatted", 3)]


LAYOUT_PAIRS = [
    # Foundation writes an empty array with a blank line inside, other encoders write []
    ('{\n  "a" : [\n\n  ],\n  "b" : 1\n}', '{\n  "a" : [],\n  "b" : 2\n}', "empty containers blank line -> compact"),
    ('{"a":1,"b":2}', '{"a":1, "b":3}', "spaces after commas 0 -> 1"),
    ('{"a":1,"b":2}', '{"a": 1,"b": 3}', "spaces after colons 0 -> 1"),
    ('{"a":1,"b":2}', '{"a" :1,"b" :3}', "spaces before colons 0 -> 1"),
    ('{"a":"é","b":2}', '{"a":"\\u00e9","b":3}', "non-ASCII characters plain -> escaped"),
    ('{"a":"x/y","b":2}', '{"a":"x\\/y","b":3}', "slashes plain -> escaped"),
    ('{"a":1,"b":2}\n', '{"a":1,"b":3}', "final newline True -> False"),
    ('{"a":1,\n"b":2}\n', '{"a":1,\r\n"b":3}\r\n', "line endings LF -> CRLF"),
]


@pytest.mark.parametrize(("before", "after", "difference"), LAYOUT_PAIRS)
def test_a_layout_change_shows_even_beside_a_key_change(before, after, difference):
    changes = predictions.compare_json("x.json", before, after)
    assert [(c.kind, predictions.where(c)) for c in changes] == [("changed", "/b"), ("reformatted", "")]
    assert difference in changes[-1].note


def test_a_layout_trait_a_file_shows_no_sign_of_is_not_a_difference():
    # the new file holds no slash, no non-ASCII character and no empty array, so nothing can be said about them
    changes = predictions.compare_json("x.json", '{"a":"x\\/y","b":[]}', '{"a":1,"b":2}')
    assert [c.kind for c in changes] == ["changed", "changed"]


def test_text_that_is_valid_utf8_but_holds_a_nul_byte_is_binary():
    changes = predictions.compare_trees({"x": b"a\x00b"}, {"x": b"a\x00c"})
    assert [c.kind for c in changes] == ["binary"]


def test_every_real_json_golden_reads_and_equals_itself():
    golden = ROOT / "Tests" / "Fixtures" / "golden"
    names = sorted(path for path in golden.rglob("*.json"))
    assert len(names) > 50
    for path in names:
        text = path.read_text(encoding="utf-8")
        assert predictions.compare_json(path.name, text, text) == [], path


# The report ---------------------------------------------------------------------------


def report(old: dict, new: dict, prediction, verbose: bool = False) -> str:
    loaded, changes, verdict = check_trees(old, new, prediction)
    return "\n".join(predictions.format_verdict(verdict, loaded.rules, changes, verbose))


def test_the_report_names_the_file_and_the_path_of_every_problem():
    new = tree({**MAPPED_198, **edit_json(PROVENANCE, set_at("steps", 0, "toolVersion", "2.1")), "mapping/extra.txt": b"x\n"})
    text = report(BASE, new, doc(entry(PROVENANCE, changed=[{"path": "/steps[*]/toolVersion", "value": "3.0"}]), added={"mapping/never.txt": "x"}))
    assert "UNPREDICTED" in text and "mapping/counts.json  changed /mapped 197 -> 198" in text
    assert "mapping/extra.txt  file-added" in text
    assert "WRONG VALUE" in text and "new value is \"2.1\", predicted \"3.0\"" in text
    assert "mapping/provenance.json  changed /steps[0]/toolVersion" in text
    assert "UNFULFILLED" in text and "mapping/never.txt  file-added  (no change matched)" in text
    assert text.splitlines()[-1] == "FAILED: 3 changes in 3 files, 2 unpredicted, 1 with a wrong value, 1 of 2 predictions unfulfilled"


def test_an_unfulfilled_count_says_what_was_expected_and_what_happened():
    text = report(BASE, tree(NO_PIDS), doc(entry(PROVENANCE, removed=[{"path": "/steps[*]/processIdentifier", "count": 4}])))
    assert "expected exactly 4, accounted for 3" in text and "why: the lane says so" in text


def test_many_changes_with_one_path_pattern_print_as_one_line():
    text = report(BASE, tree(NO_PIDS), NOTHING)
    assert text.count("\n") < 6
    assert "mapping/provenance.json  removed /steps[*]/processIdentifier  x3, first /steps[0]/processIdentifier" in text


def test_verbose_lists_every_change_and_the_count_behind_every_prediction():
    prediction = doc(entry(PROVENANCE, removed=[{"path": "/steps[*]/processIdentifier"}]))
    assert "     3  mapping/provenance.json  removed  /steps[*]/processIdentifier" in report(BASE, tree(NO_PIDS), prediction, verbose=True)
    lines = report(BASE, tree(NO_PIDS), NOTHING, verbose=True).splitlines()
    assert sum("removed /steps[" in line for line in lines) == 3


def test_a_long_run_of_changed_text_lines_is_cut_short_unless_verbose():
    old = {"t.txt": "".join(f"line {n}\n" for n in range(40)).encode()}
    new = {"t.txt": "".join(f"LINE {n}\n" for n in range(40)).encode()}
    text = report(old, new, NOTHING)
    assert "t.txt  changed: 30 more, -v lists them" in text
    assert "line 40" in report(old, new, NOTHING, verbose=True)


# Reading a predictions file ------------------------------------------------------------


def entry_with(**fields) -> dict:
    return {"files": [{"file": "a.json", "why": "x", **fields}]}


INVALID = [
    ({"surprise": 1}, "surprise: unknown top-level key"),
    ({"version": 2}, "version: must be 1"),
    ({"files": {}}, "files: must be a list of entries"),
    ({"files": [{"why": "x", "reformatted": True}]}, "file must be a path or glob, or a list of them"),
    ({"files": [{"file": [], "why": "x", "reformatted": True}]}, "file must be a path or glob, or a list of them"),
    ({"files": [{"file": "a.json", "changed": [{"path": "/a"}]}]}, "needs a non-empty why"),
    (entry_with(), "predicts nothing"),
    (entry_with(changed={"path": "/a"}), "changed: must be a list of rules"),
    (entry_with(changed=[{"path": "/a", "valeu": 1}]), "'valeu' does not belong in a rule under changed"),
    (entry_with(added=[{"path": "/a", "old": 1}]), "'old' does not belong in a rule under added"),
    (entry_with(removed=[{"path": "/a", "value": 1}]), "'value' does not belong in a rule under removed"),
    (entry_with(changed=[{"path": "/a", "pattern": "("}]), "pattern is not a regular expression"),
    (entry_with(changed=[{"path": "/a", "oldPattern": 5}]), "oldPattern must be a regular expression string"),
    (entry_with(changed=[{"path": "steps"}]), "cannot read the path 'steps' at offset 0"),
    (entry_with(changed=[{"path": "/a[x]"}]), "cannot read the path"),
    (entry_with(changed=[{"path": 3}]), "path must be a string"),
    (entry_with(changed=[{"path": "/a", "count": 0}]), "count must be a whole number of at least 1"),
    (entry_with(changed=[{"path": "/a", "count": 1.5}]), "count must be a whole number of at least 1"),
    (entry_with(changed=[{"path": "/a", "count": "3"}]), "count must be a whole number of at least 1"),
    (entry_with(reformatted=False), "reformatted: must be true"),
    (entry_with(binary=1), "binary: must be true"),
    (entry_with(reformatted=True, color="red"), "unknown key 'color'"),
    ({"filesAdded": {"a.txt": ""}}, "needs a non-empty why"),
    ({"filesAdded": {"a.txt": {"why": "x", "count": 0}}}, "count must be a whole number"),
    ({"filesRemoved": {"a.txt": {"why": "x", "extra": 1}}}, "unknown key 'extra'"),
    ({"filesRemoved": ["a.txt"]}, "filesRemoved: must be an object"),
    ({"ignore": {"README.md": " "}}, "needs a non-empty why"),
]


@pytest.mark.parametrize(("prediction", "message"), INVALID)
def test_a_bad_predictions_file_is_refused_with_the_reason(prediction, message):
    with pytest.raises(predictions.SpecError) as refused:
        predictions.load_predictions(json.dumps(prediction))
    assert message in str(refused.value)


def test_the_example_in_the_module_documentation_is_a_valid_predictions_file():
    example = predictions.__doc__.split("Predictions file, one JSON object:\n", 1)[1].split("\n\n- ", 1)[0]
    loaded = predictions.load_predictions(example)
    assert [rule.kind for rule in loaded.rules] == ["changed", "added", "removed", "added", "file-added"]
    assert loaded.rules[0].globs == ("genotype/bundle/provenance/*.json", "genotype/exports/*.json")
    assert len(loaded.ignore) == 1


def test_a_predictions_file_that_is_not_json_or_not_an_object_is_refused():
    for text, message in (("{", "not JSON"), ("[]", "must hold one JSON object"), ("", "not JSON")):
        with pytest.raises(predictions.SpecError, match=message):
            predictions.load_predictions(text)


def test_all_the_mistakes_of_a_predictions_file_are_reported_together():
    bad = {"files": [{"file": "a.json", "why": "x", "changed": [{"path": "x", "count": 0, "bogus": 1}]}], "oops": 1}
    with pytest.raises(predictions.SpecError) as refused:
        predictions.load_predictions(json.dumps(bad))
    assert str(refused.value).count("\n") >= 4


def test_a_rule_takes_the_why_of_its_entry_unless_it_has_its_own():
    loaded = predictions.load_predictions(
        json.dumps(entry_with(added=[{"path": "/a"}, {"path": "/b", "why": "its own"}]))
    )
    assert [rule.why for rule in loaded.rules] == ["x", "its own"]


# Paths and globs ------------------------------------------------------------------------

PATHS = [
    ("", (), ""),
    ("/", ("",), "/"),
    ("/a/b", ("a", "b"), "/a/b"),
    ("/steps[3]/argv[0]", ("steps", 3, "argv", 0), "/steps[3]/argv[0]"),
    ("/steps[*]/x", ("steps", predictions.ANY_INDEX, "x"), "/steps[*]/x"),
    ("/steps/[*]/x", ("steps", predictions.ANY_INDEX, "x"), "/steps[*]/x"),
    ("[*]/x", (predictions.ANY_INDEX, "x"), "[*]/x"),
    ("/[*]/x", (predictions.ANY_INDEX, "x"), "[*]/x"),
    ("/a~1b/c~0d", ("a/b", "c~d"), "/a~1b/c~0d"),
    ("/a~01b", ("a~1b",), "/a~01b"),
    ("/*/x", (predictions.ANY_KEY, "x"), "/*/x"),
    ("/m[1][2]", ("m", 1, 2), "/m[1][2]"),
]


@pytest.mark.parametrize(("text", "segments", "rendered"), PATHS)
def test_paths_parse_and_render(text, segments, rendered):
    parsed = predictions.parse_path(text)
    assert parsed == segments
    assert predictions.render_path(parsed) == rendered
    assert predictions.parse_path(rendered) == segments


@pytest.mark.parametrize("text", ["steps", "/a[", "/a[x]", "/a]b", "/a~2", "/a[-1]"])
def test_unreadable_paths_are_refused(text):
    with pytest.raises(ValueError):
        predictions.parse_path(text)


def test_a_wildcard_index_does_not_match_a_key_and_a_wildcard_key_does_not_match_an_index():
    assert predictions.path_matches(predictions.parse_path("/a[*]"), ("a", 4))
    assert not predictions.path_matches(predictions.parse_path("/a[*]"), ("a", "4"))
    assert predictions.path_matches(predictions.parse_path("/a/*"), ("a", "4"))
    assert not predictions.path_matches(predictions.parse_path("/a/*"), ("a", 4))
    assert not predictions.path_matches(predictions.parse_path("/a[4]"), ("a", 5))
    assert not predictions.path_matches(predictions.parse_path("/a"), ("a", 0))


GLOBS = [
    ("mapping/*.json", "mapping/counts.json", True),
    ("mapping/*.json", "mapping/x/counts.json", False),
    ("mapping/*.json", "mapping/counts.json.bak", False),
    ("*.json", "mapping/counts.json", False),
    ("**/*.json", "counts.json", True),
    ("**/*.json", "mapping/x/counts.json", True),
    ("mapping/**", "mapping/x/y.txt", True),
    ("a/**/b.txt", "a/b.txt", True),
    ("a/**/b.txt", "a/x/y/b.txt", True),
    ("a/?.txt", "a/b.txt", True),
    ("a/?.txt", "a/bc.txt", False),
    ("a.b+c(d).txt", "a.b+c(d).txt", True),
    ("a.b+c(d).txt", "aXb+c(d).txt", False),
]


@pytest.mark.parametrize(("glob", "name", "matches"), GLOBS)
def test_globs(glob, name, matches):
    assert bool(predictions.glob_regex(glob).fullmatch(name)) is matches


# Reading trees, and the command line --------------------------------------------------

GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}
GOLDEN_ROOT = "Tests/Fixtures/golden"


def git(repo: Path, *args: str) -> None:
    command = ["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", *args]
    subprocess.run(command, check=True, capture_output=True, env=GIT_ENV)


def write_tree(folder: Path, files: dict) -> None:
    for name, data in files.items():
        target = folder / name
        if data is None:
            target.unlink()
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)


@pytest.fixture(scope="module")
def repo(tmp_path_factory):
    """A repository whose goldens went from BASE to BASE with MAPPED_198 and a new file, in two commits.

    Tests share it, so a test that touches the working tree puts it back."""
    folder = tmp_path_factory.mktemp("golden-repo")
    git(folder, "init", "-q")
    write_tree(folder / GOLDEN_ROOT, BASE)
    git(folder, "add", "-A")
    git(folder, "commit", "-q", "-m", "one")
    write_tree(folder / GOLDEN_ROOT, {**MAPPED_198, "mapping/extra.txt": b"x\n"})
    git(folder, "add", "-A")
    git(folder, "commit", "-q", "-m", "two")
    return folder


RECAPTURE = doc(entry(COUNTS, changed=[{"path": "/mapped", "value": 198}]), added={"mapping/extra.txt": "new output"})


def run_main(capsys, *argv) -> tuple[int, str, str]:
    status = predictions.main([str(a) for a in argv])
    captured = capsys.readouterr()
    return status, captured.out, captured.err


def write_predictions(tmp_path: Path, prediction=RECAPTURE) -> Path:
    path = tmp_path / "predictions.json"
    path.write_text(json.dumps(prediction), encoding="utf-8")
    return path


def test_read_directory_returns_every_file_under_its_posix_name(tmp_path):
    write_tree(tmp_path, {"a/b/c.txt": b"c", "d.json": b"{}"})
    (tmp_path / "empty").mkdir()
    assert predictions.read_directory(tmp_path) == {"a/b/c.txt": b"c", "d.json": b"{}"}
    with pytest.raises(predictions.SpecError, match="is not a folder"):
        predictions.read_directory(tmp_path / "missing")


def test_two_commits_give_the_trees_of_those_commits(repo):
    old = predictions.read_git_tree(repo, "HEAD~1", GOLDEN_ROOT)
    new = predictions.read_git_tree(repo, "HEAD", GOLDEN_ROOT)
    assert old == BASE
    assert new == tree({**MAPPED_198, "mapping/extra.txt": b"x\n"})
    assert BINARY_FILE in new and new[BINARY_FILE] == BINARY


def test_load_tree_names_what_it_read(repo, tmp_path):
    label, files = predictions.load_tree("HEAD~1", GOLDEN_ROOT, repo)
    assert label.startswith("HEAD~1 (") and files == BASE
    assert predictions.load_tree("WORKTREE", GOLDEN_ROOT, repo)[0] == f"working tree {GOLDEN_ROOT}"
    write_tree(tmp_path / "plain", {"x.txt": b"x"})
    assert predictions.load_tree(f"dir:{tmp_path / 'plain'}", GOLDEN_ROOT, repo)[1] == {"x.txt": b"x"}


@pytest.mark.parametrize("spec", ["no-such-revision", "--output=x", "HEAD:Tests"])
def test_a_spec_that_is_not_a_revision_is_refused(repo, spec):
    with pytest.raises(predictions.SpecError):
        predictions.load_tree(spec, GOLDEN_ROOT, repo)


def test_a_revision_without_the_golden_folder_is_refused(repo):
    with pytest.raises(predictions.SpecError, match="git ls-tree failed"):
        predictions.load_tree("HEAD", "Tests/Fixtures/nowhere", repo)


def test_check_passes_for_two_commits_when_everything_was_predicted(repo, tmp_path, capsys):
    status, out, _ = run_main(capsys, "check", write_predictions(tmp_path), "--old", "HEAD~1", "--new", "HEAD", "--repo", repo)
    assert status == 0, out
    assert out.splitlines()[-1].startswith("OK: 2 changes in 2 files, 0 unpredicted, 0 with a wrong value, 0 of 2 predictions unfulfilled")
    assert "HEAD~1 (" in out and "-> HEAD (" in out


def test_check_defaults_compare_head_with_the_working_tree(repo, tmp_path, capsys):
    target = repo / GOLDEN_ROOT / HASH_FILE
    original = target.read_bytes()
    try:
        target.write_bytes(b"000000000000  samtools view --no-PG (200 records)\n")
        status, out, _ = run_main(capsys, "check", write_predictions(tmp_path, NOTHING), "--repo", repo)
        assert status == 1
        assert "mapping/records.sha256  changed line 1" in out and "working tree" in out
        predicted = write_predictions(tmp_path, doc(entry(HASH_FILE, changed=[{"pattern": "0+  samtools.*"}])))
        assert run_main(capsys, "check", predicted, "--repo", repo)[0] == 0
    finally:
        target.write_bytes(original)


def test_check_exits_1_and_names_file_and_path_of_unpredicted_and_unfulfilled(repo, tmp_path, capsys):
    prediction = doc(entry(COUNTS, added=[{"path": "/neverThere"}]))
    status, out, _ = run_main(capsys, "check", write_predictions(tmp_path, prediction), "--old", "HEAD~1", "--new", "HEAD", "--repo", repo)
    assert status == 1
    assert "mapping/counts.json  changed /mapped 197 -> 198" in out
    assert "mapping/extra.txt  file-added" in out
    assert "mapping/counts.json  added  /neverThere  (no change matched)" in out


def test_check_exits_2_for_a_bad_predictions_file_a_missing_file_or_a_bad_revision(repo, tmp_path, capsys):
    broken = write_predictions(tmp_path, {"files": [{"file": "a", "why": "x", "changed": [{"valeu": 1}]}]})
    status, out, err = run_main(capsys, "check", broken, "--repo", repo)
    assert (status, out) == (2, "") and "valeu" in err
    status, _, err = run_main(capsys, "check", tmp_path / "missing.json", "--repo", repo)
    assert status == 2 and "cannot read" in err
    status, _, err = run_main(capsys, "check", write_predictions(tmp_path), "--old", "nope", "--repo", repo)
    assert status == 2 and "'nope' is not WORKTREE, dir:PATH or a revision" in err


def test_check_compares_plain_folders_too(tmp_path, capsys):
    write_tree(tmp_path / "before", BASE)
    write_tree(tmp_path / "after", tree(MAPPED_198))
    prediction = write_predictions(tmp_path, doc(entry(COUNTS, changed=[{"path": "/mapped"}])))
    assert run_main(capsys, "check", prediction, "--old", f"dir:{tmp_path / 'before'}", "--new", f"dir:{tmp_path / 'after'}")[0] == 0
    status, out, _ = run_main(capsys, "check", prediction, "--old", f"dir:{tmp_path / 'before'}", "--new", f"dir:{tmp_path / 'before'}")
    assert status == 1 and "UNFULFILLED" in out


def test_diff_prints_the_observed_changes_and_never_fails(repo, capsys):
    status, out, _ = run_main(capsys, "diff", "--old", "HEAD~1", "--new", "HEAD", "--repo", repo)
    assert status == 0
    assert "mapping/counts.json  changed /mapped 197 -> 198" in out and "mapping/extra.txt  file-added" in out
    status, out, _ = run_main(capsys, "diff", "--old", "HEAD", "--new", "HEAD", "--repo", repo)
    assert status == 0 and "no differences" in out


def test_a_report_with_non_ascii_values_prints_under_an_ascii_locale(tmp_path):
    write_tree(tmp_path / "before", {"a.json": foundation({"name": "plain"})})
    write_tree(tmp_path / "after", {"a.json": foundation({"name": "café"})})
    script = str(ROOT / "scripts" / "golden" / "predictions.py")
    command = [sys.executable, script, "diff", "--old", f"dir:{tmp_path / 'before'}", "--new", f"dir:{tmp_path / 'after'}"]
    done = subprocess.run(command, capture_output=True, env={**GIT_ENV, "PYTHONIOENCODING": "ascii"})
    assert done.returncode == 0, done.stderr
    assert b'"plain" -> "caf\\xe9"' in done.stdout


def test_the_real_golden_folder_has_no_differences_with_itself(capsys):
    golden = ROOT / GOLDEN_ROOT
    status, out, _ = run_main(capsys, "diff", "--old", f"dir:{golden}", "--new", f"dir:{golden}")
    assert status == 0 and "no differences" in out and "0 with changes" in out

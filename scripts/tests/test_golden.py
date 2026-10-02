"""Tests for the Phase 1 golden fixture normalizer and compare (scripts/golden)."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "golden"))
sys.dont_write_bytecode = True

import golden  # noqa: E402
import normalize  # noqa: E402

RUN_ROOT = "/Users/someone/Library/Caches/lungfish-golden/run"


def normalizer(**kwargs) -> normalize.Normalizer:
    return normalize.Normalizer(run_root=RUN_ROOT, app_version="2026.9.78", **kwargs)


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# Binding rules ---------------------------------------------------------------


def test_timestamps_in_every_written_shape_are_masked():
    text = (
        "a 2026-10-02T13:12:35Z b 2026-10-02T13:12:34.681073+00:00 c 2026-10-02 09:13:05,754 "
        "d 2026-10-02T09-03-00 e 2026-10-02 f 2026-10-02T13:12:35+0200"
    )
    assert normalize.mask_timestamps(text) == (
        "a <TIMESTAMP> b <TIMESTAMP> c <TIMESTAMP> d <TIMESTAMP> e <TIMESTAMP> f <TIMESTAMP>"
    )


def test_versions_and_compact_dates_are_not_timestamps():
    text = '"version" : "20260626", "dependencySet" : "2026.2", "app" : "2026.9.78", "n" : 12026-10-021'
    assert normalize.mask_timestamps(text) == text


def test_uuids_are_numbered_by_first_appearance_in_each_file():
    first = "6E4C2F1A-1111-4222-8333-944455556666"
    second = "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e"
    text = f"{first} {second} {first.lower()}"
    assert normalize.mask_uuids(text) == "<UUID-1> <UUID-2> <UUID-1>"
    assert normalize.mask_uuids(f"{second} {first}") == "<UUID-1> <UUID-2>"


def test_scratch_root_token_keeps_the_rest_of_the_path_in_every_spelling():
    escaped = RUN_ROOT.replace("/", "\\/")
    text = f'"a" : "{escaped}\\/mapping\\/out\\/x.bam", b={RUN_ROOT}/genotype/y, c=file://{RUN_ROOT}/z'
    assert normalize.replace_run_root(text, RUN_ROOT) == (
        '"a" : "<RUN_ROOT>\\/mapping\\/out\\/x.bam", b=<RUN_ROOT>/genotype/y, c=file://<RUN_ROOT>/z'
    )


def test_scratch_root_under_private_tmp_is_replaced_with_and_without_the_prefix():
    root = "/private/tmp/golden/run"
    text = "one /private/tmp/golden/run/a two /tmp/golden/run/b"
    assert normalize.replace_run_root(text, root) == "one <RUN_ROOT>/a two <RUN_ROOT>/b"


def test_epoch_keys_are_masked_only_in_a_wall_clock_range():
    text = '{"createdAt" : 1790948255.5, "startTime" : 781234567, "timestamp" : 3, "recordedAt" : 42}'
    assert normalize.mask_epoch_values(text) == (
        '{"createdAt" : "<EPOCH>", "startTime" : "<EPOCH>", "timestamp" : 3, "recordedAt" : 42}'
    )


def test_duration_keys_are_masked_as_numbers_and_as_quoted_numbers():
    text = '{"wallTimeSeconds" : 0.0937, "wallClockSeconds":"0.016493797302246094", "readLength" : 151}'
    assert normalize.mask_duration_values(text) == (
        '{"wallTimeSeconds" : "<DURATION>", "wallClockSeconds":"<DURATION>", "readLength" : 151}'
    )


def test_tool_log_durations_are_masked():
    text = (
        "INFO - Completed trim_filter in 0.29 seconds\n"
        "INFO - reactable report finished in 1.27 seconds\n"
        "fastp v1.3.7, time used: 0 seconds\n"
        "[M::mm_idx_gen::0.001*5.59] collected minimizers\n"
        "[M::main] Real time: 0.005 sec; CPU: 0.012 sec; Peak RSS: 0.005 GB\n"
        "55 sequences (0.01 Mbp) processed in 0.003s (1104.0 Kseq/m, 166.19 Mbp/m).\n"
        "  Runtime: 1.1s\n"
        "Classification completed in 12.3s\n"
        "  Shannon diversity (H'): 0.000\n"
    )
    assert normalize.mask_tool_log_durations(text) == (
        "INFO - Completed trim_filter in <DURATION> seconds\n"
        "INFO - reactable report finished in <DURATION> seconds\n"
        "fastp v1.3.7, time used: <DURATION> seconds\n"
        "[M::mm_idx_gen::<DURATION>*5.59] collected minimizers\n"
        "[M::main] Real time: <DURATION> sec; CPU: 0.012 sec; Peak RSS: 0.005 GB\n"
        "55 sequences (0.01 Mbp) processed in <DURATION>s (1104.0 Kseq/m, 166.19 Mbp/m).\n"
        "  Runtime: <DURATION>s\n"
        "Classification completed in <DURATION>s\n"
        "  Shannon diversity (H'): 0.000\n"
    )


# Ruled rules -----------------------------------------------------------------


def test_minimap2_cpu_and_memory_and_kraken2_rates_are_masked_but_counts_are_not():
    text = (
        "[M::mm_idx_gen::0.001*5.59] collected minimizers\\n"
        "[M::main] Real time: 0.005 sec; CPU: 0.012 sec; Peak RSS: 0.005 GB\\n"
        "55 sequences (0.01 Mbp) processed in 0.003s (1104.0 Kseq\\/m, 166.19 Mbp\\/m).\\n"
        "  54 sequences classified (98.18%)"
    )
    assert normalizer().text(text) == (
        "[M::mm_idx_gen::<DURATION>*<CPU-RATIO>] collected minimizers\\n"
        "[M::main] Real time: <DURATION> sec; CPU: <CPU-SECONDS> sec; Peak RSS: <PEAK-RSS> GB\\n"
        "55 sequences (0.01 Mbp) processed in <DURATION>s (<RATE> Kseq\\/m, <RATE> Mbp\\/m).\\n"
        "  54 sequences classified (98.18%)"
    )


def test_process_identifier_is_masked():
    assert normalizer().text('{"processIdentifier" : 77259, "exitStatus" : 0}') == (
        '{"processIdentifier" : "<PID>", "exitStatus" : 0}'
    )


def test_app_version_is_masked_only_under_version_keys():
    text = (
        '{"appVersion" : "Lungfish 2026.9.78 (dev)", "toolVersion" : "2026.9.78", '
        '"version" : "2.17.1", "workflowVersion" : "2026.9.78", "note" : "2026.9.78"}'
    )
    assert normalizer().text(text) == (
        '{"appVersion" : "Lungfish <APP_VERSION> (dev)", "toolVersion" : "<APP_VERSION>", '
        '"version" : "2.17.1", "workflowVersion" : "<APP_VERSION>", "note" : "2026.9.78"}'
    )


def record(path: str, digest: str, size: int) -> dict:
    return {"checksumSHA256": digest, "fileSize": size, "path": path, "sha256": digest, "sizeBytes": size}


def test_alignment_record_rule_masks_hash_and_size_of_alignment_files_only():
    bam_digest, fastq_digest = "a" * 64, "b" * 64
    text = json.dumps({"files": [record("/x/out.sorted.bam", bam_digest, 19656),
                                 record("/x/in.fastq.gz", fastq_digest, 9413)]}, indent=2, sort_keys=True)
    n = normalizer()
    n.add_path_rule(normalize.ALIGNMENT_RECORDS)
    result = json.loads(n.text(text))
    bam, fastq = result["files"]
    assert bam["sha256"] == bam["checksumSHA256"] == "<SHA256-R8>"
    assert bam["sizeBytes"] == bam["fileSize"] == "<SIZE-R8>"
    assert fastq == record("/x/in.fastq.gz", fastq_digest, 9413)


def test_registered_digest_is_masked_everywhere_and_its_record_size_too():
    volatile, stable = sha("mapping-result run 1"), sha("reference")
    text = json.dumps({
        "files": [record("/x/mapping-result.json", volatile, 611), record("/x/genome.fasta", stable, 30214)],
        "note": f"witness {volatile}",
    }, indent=2, sort_keys=True)
    n = normalizer()
    n.register(normalize.VolatileDigest(volatile, "R10", "mapping-result.json", mask_size=True))
    result = json.loads(n.text(text))
    assert result["files"][0]["sha256"] == "<SHA256-R10>"
    assert result["files"][0]["sizeBytes"] == "<SIZE-R10>"
    assert result["files"][1] == record("/x/genome.fasta", stable, 30214)
    assert result["note"] == "witness <SHA256-R10>"


def test_tokens_do_not_depend_on_two_payloads_sharing_a_digest():
    # Two exports in the same second write identical annotations, in the next
    # run they may not. Both runs must normalize to the same text.
    payloads_same = {"workbook": '{"generatedAt":"2026-10-02T13:12:35Z"}', "pivot": '{"generatedAt":"2026-10-02T13:12:35Z"}'}
    payloads_apart = {"workbook": '{"generatedAt":"2026-10-02T13:12:35Z"}', "pivot": '{"generatedAt":"2026-10-02T13:12:36Z"}'}
    outputs = []
    for payloads in (payloads_same, payloads_apart):
        n = normalizer()
        for name, text in payloads.items():
            n.register_payloads(snapshot_text({"annotations.json": text}), f"exports/{name}.xlsx.export/snapshot.json")
        outputs.append([n.snapshot(snapshot_text({"annotations.json": text}))[0] for text in payloads.values()])
        assert {entry.label for entry in n.items} == {
            "workbook.xlsx.export:annotations.json", "pivot.xlsx.export:annotations.json"}
    assert outputs[0] == outputs[1]


def test_hash_only_registration_keeps_the_size():
    digest = sha("gzip with an mtime")
    n = normalizer()
    n.register(normalize.VolatileDigest(digest, "R11", "classification.kraken.gz"))
    result = json.loads(n.text(json.dumps({"files": [record("/x/c.kraken.gz", digest, 796)]})))
    assert result["files"][0]["sha256"] == "<SHA256-R11>"
    assert result["files"][0]["sizeBytes"] == 796


def test_truncated_stderr_drops_only_the_partial_last_line():
    stderr = "line one\nCompleted x in 1.5 seconds\nkeeping temp files in /a/b/sarscov2-R1-le" + normalize.STDERR_TRUNCATION_MARKER
    text = json.dumps({"stderr": stderr, "other": "keep\nme"})
    result = json.loads(normalizer().text(text))
    assert result["stderr"] == (
        "line one\nCompleted x in <DURATION> seconds\n<TRUNCATED-LINE>" + normalize.STDERR_TRUNCATION_MARKER
    )
    assert result["other"] == "keep\nme"


def test_stderr_that_was_not_truncated_is_kept_whole():
    text = json.dumps({"stderr": "first\nsecond partial"})
    assert normalizer().text(text) == text


# Workbooks -------------------------------------------------------------------


CORE_XML = (
    '<?xml version="1.0"?><cp:coreProperties><dc:creator>LGE</dc:creator>'
    '<dcterms:created xsi:type="dcterms:W3CDTF">{created}</dcterms:created>'
    '<dcterms:modified xsi:type="dcterms:W3CDTF">{created}</dcterms:modified></cp:coreProperties>'
)
SHEET_XML = '<worksheet><c r="B2" t="inlineStr"><is><t>{when}</t></is></c><c r="C2"><v>{value}</v></c></worksheet>'


def workbook(order: list[str], created: str, when: str, value: str, date_time=(2026, 10, 2, 9, 0, 0)) -> bytes:
    parts = {
        "[Content_Types].xml": "<Types/>",
        "docProps/core.xml": CORE_XML.format(created=created),
        "xl/worksheets/sheet1.xml": SHEET_XML.format(when=when, value=value),
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name in order:
            archive.writestr(zipfile.ZipInfo(name, date_time=date_time), parts[name])
    return buffer.getvalue()


def test_xlsx_parts_are_canonical_and_only_times_are_masked():
    names = ["xl/worksheets/sheet1.xml", "docProps/core.xml", "[Content_Types].xml"]
    first = workbook(names, "2026-10-02T13:12:35Z", "2026-10-02T13:12:35Z", "376")
    second = workbook(list(reversed(names)), "2026-10-03T08:00:00Z", "2026-10-03T08:00:01Z", "376",
                      date_time=(2026, 10, 3, 8, 0, 0))
    parts = normalizer().xlsx_parts(first)
    assert list(parts) == sorted(names)
    assert b"<TIMESTAMP>" in parts["docProps/core.xml"] and b"2026-10-02" not in parts["docProps/core.xml"]
    assert parts["xl/worksheets/sheet1.xml"] == SHEET_XML.format(when="<TIMESTAMP>", value="376").encode()
    assert normalizer().xlsx_parts(second) == parts


def test_xlsx_cell_value_change_is_not_masked():
    names = ["docProps/core.xml", "xl/worksheets/sheet1.xml", "[Content_Types].xml"]
    first = normalizer().xlsx_parts(workbook(names, "2026-10-02T13:12:35Z", "x", "376"))
    second = normalizer().xlsx_parts(workbook(names, "2026-10-02T13:12:35Z", "x", "377"))
    assert first["xl/worksheets/sheet1.xml"] != second["xl/worksheets/sheet1.xml"]


def test_bare_dates_in_worksheet_cells_are_kept():
    names = ["docProps/core.xml", "xl/worksheets/sheet1.xml", "[Content_Types].xml"]
    parts = normalizer().xlsx_parts(workbook(names, "2026-10-02T13:12:35Z", "2026-09-29", "1"))
    assert b"2026-09-29" in parts["xl/worksheets/sheet1.xml"]


# Captured inputs (R16) and pending rules ------------------------------------


def snapshot_text(payloads: dict[str, str]) -> str:
    encoded = {name: base64.b64encode(text.encode()).decode() for name, text in payloads.items()}
    revision = {name: sha(text) for name, text in payloads.items()}
    text = json.dumps({"capturedScientificInputs": encoded, "generatedAt": "2026-10-02T13:13:47Z",
                       "sourceRevision": revision}, indent=2, sort_keys=True)
    return text.replace("/", "\\/")  # Foundation escapes slashes


def test_snapshot_inputs_are_decoded_normalized_and_reencoded():
    payloads = {
        "annotations.json": '{"generatedAt":"2026-10-02T13:12:35Z","schemaVersion":4}',
        "definition.json": '{"lastModified":"2026-09-29T11:46:53Z","name":"teaching set"}',
    }
    text = snapshot_text(payloads)
    n = normalizer()
    n.add_stable_values('{"lastModified":"2026-09-29T11:46:53Z"}')  # the definition ships with the inputs
    registered = n.register_payloads(text, "exports/workbook.xlsx.export/snapshot.json")
    assert [entry.label for entry in registered] == ["workbook.xlsx.export:annotations.json"]
    normalized, decoded = n.snapshot(text)
    assert decoded["annotations.json"] == b'{"generatedAt":"<TIMESTAMP>","schemaVersion":4}'
    assert decoded["definition.json"] == b'{"lastModified":"<TIMESTAMP>","name":"teaching set"}'
    result = json.loads(normalized)
    assert base64.b64decode(result["capturedScientificInputs"]["annotations.json"]) == decoded["annotations.json"]
    assert result["sourceRevision"]["annotations.json"] == "<SHA256-R16>"
    assert result["sourceRevision"]["definition.json"] == sha(payloads["definition.json"])


def test_stringified_raw_metric_objects_are_sorted_without_touching_values_when_not_strict():
    first = '{"stats":{"rawMetrics":{"pairMergeSummary":"{\\"tool\\":\\"bbmerge.sh\\",\\"mergedFragments\\":376}"}}}'
    second = '{"stats":{"rawMetrics":{"pairMergeSummary":"{\\"mergedFragments\\":376,\\"tool\\":\\"bbmerge.sh\\"}"}}}'
    assert normalize.sort_raw_metric_objects(first) == second
    assert normalize.sort_raw_metric_objects(second) == second
    assert normalizer().payload("result.json", first.encode()) == second.encode()
    assert normalizer(strict=True).payload("result.json", first.encode()) == first.encode()


def test_merge_suffixes_on_pg_ids_are_masked_and_other_ids_kept():
    header = (
        "@HD\tVN:1.6\n@PG\tPN:minimap2\tID:minimap2\tVN:2.31\n"
        "@PG\tPN:minimap2\tID:minimap2-7976BC8F\tVN:2.31\n"
        "@PG\tPN:samtools\tID:samtools.2\tPP:samtools-28922CC\tVN:1.24\n"
    )
    assert normalize.mask_merge_pg_suffixes(header) == (
        "@HD\tVN:1.6\n@PG\tPN:minimap2\tID:minimap2\tVN:2.31\n"
        "@PG\tPN:minimap2\tID:minimap2-<MERGE-ID>\tVN:2.31\n"
        "@PG\tPN:samtools\tID:samtools.2\tPP:samtools-<MERGE-ID>\tVN:1.24\n"
    )


def test_pending_registrations_are_left_out_in_strict_mode():
    digest = sha("bam with a random merge suffix")
    strict = normalizer(strict=True)
    strict.register(normalize.VolatileDigest(digest, "N2", "x.bam", mask_size=True, pending=True))
    strict.add_path_rule(normalize.PathRule("N3", ("/manifest.json",), pending=True))
    assert strict.digests == {} and strict.path_rules == []


def test_run_dependent_test_ignores_values_copied_from_inputs_and_the_app_version():
    n = normalizer()
    n.add_stable_values('{"lastModified" : "2026-09-29T11:46:53Z"}')
    assert not n.holds_run_dependent_field('{"lastModified" : "2026-09-29T11:46:53Z", "appVersion" : "2026.9.78"}')
    assert n.holds_run_dependent_field('{"generatedAt" : "2026-10-02T13:12:35Z"}')
    assert not n.holds_run_dependent_field(f'{{"path" : "{RUN_ROOT}/a"}}')


# JSON spans --------------------------------------------------------------------


def test_json_span_edits_leave_every_other_byte_alone():
    text = '{\n  "a" : [ 1, 2.5e3, "x\\/y" ],\n  "b" : { "c" : null, "d" : "\\u001b[0m" }\n}\n'
    root = normalize.parse_json(text)
    target = root.get("b").get("d")
    edited = normalize.apply_edits(text, {(target.start, target.end): '"<TOKEN>"'})
    assert edited == text.replace('"\\u001b[0m"', '"<TOKEN>"')
    assert normalize.parse_json("not json") is None
    assert normalize.parse_json('{"a" : 1} trailing') is None


def test_escape_like_keeps_foundation_slash_escaping():
    assert normalize.escape_like("a/b", '"x\\/y"') == '"a\\/b"'
    assert normalize.escape_like("a/b", '"xy"') == '"a/b"'


# Compare ---------------------------------------------------------------------


def test_one_byte_change_in_an_unmasked_field_fails_the_compare():
    raw = json.dumps({"mapped": 197, "createdAt": "2026-10-02T13:12:35Z"}, indent=2, sort_keys=True)
    expected = {"counts.json": normalizer().text(raw).encode()}
    same_run_later = raw.replace("13:12:35", "14:00:01")
    assert golden.diff_capture("mapping", expected, {"counts.json": normalizer().text(same_run_later).encode()}) == []
    changed = raw.replace('"mapped": 197', '"mapped": 198')
    report = golden.diff_capture("mapping", expected, {"counts.json": normalizer().text(changed).encode()})
    assert any(line.startswith('-  "mapped": 197') for line in report)
    assert any(line.startswith('+  "mapped": 198') for line in report)


def test_missing_and_extra_golden_files_fail_the_compare():
    report = golden.diff_capture("x", {"a.txt": b"1\n"}, {"b.txt": b"1\n"})
    assert any("golden file not produced: x/a.txt" in line for line in report)
    assert any("new file not in the goldens: x/b.txt" in line for line in report)


def test_portability_check_flags_checkout_and_raw_scratch_paths(tmp_path):
    outputs = {"a.json": f'"{golden.REPO_ROOT}/x"'.encode(), "b.json": f'"{tmp_path}/y"'.encode(), "c.json": b"ok"}
    problems = golden.portability_problems("x", outputs, tmp_path)
    assert len(problems) == 2

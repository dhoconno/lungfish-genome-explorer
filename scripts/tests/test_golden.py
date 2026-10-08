"""Tests for the Phase 1 golden fixture normalizer and compare (scripts/golden)."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "golden"))
sys.dont_write_bytecode = True

import captures  # noqa: E402
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
        "INFO - EsViritu run for sarscov2-R1-len150 finished in 00:00:09\n"
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
        "INFO - EsViritu run for sarscov2-R1-len150 finished in <DURATION>\n"
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


# Host rule -------------------------------------------------------------------


def test_host_os_version_and_build_are_masked_in_every_written_shape():
    text = (
        '{"hostOS" : "macOS 26.6.2 (arm64)", "operatingSystemVersion" : "macOS 26.7.1 (arm64)", '
        '"platform" : "Version 26.6.2 (Build 25G83)", "python" : {"platform": "macOS-26.7.1-arm64-arm-64bit"}}'
    )
    assert normalizer().text(text) == (
        '{"hostOS" : "macOS <HOST-OS-VERSION> (arm64)", "operatingSystemVersion" : "macOS <HOST-OS-VERSION> (arm64)", '
        '"platform" : "Version <HOST-OS-VERSION> (Build <HOST-OS-BUILD>)", '
        '"python" : {"platform": "macOS-<HOST-OS-VERSION>-arm64-arm-64bit"}}'
    )


def test_two_macos_builds_normalize_alike_and_the_architecture_stays_compared():
    laptop = '{"hostOS" : "macOS 26.6.2 (arm64)", "platform" : "Version 26.6.2 (Build 25G83)"}'
    desktop = '{"hostOS" : "macOS 26.7.1 (arm64)", "platform" : "Version 26.7.1 (Build 25G241)"}'
    assert normalizer().text(laptop) == normalizer().text(desktop)
    intel = '{"hostOS" : "macOS 26.6.2 (x86_64)", "platform" : "Version 26.6.2 (Build 25G83)"}'
    assert normalizer().text(intel) != normalizer().text(laptop)


def test_active_core_count_is_masked_only_as_the_active_cores_default():
    laptop = "  --chunk-jobs <chunk-jobs>\n                          (default: active cores) (default: 14)\n"
    desktop = laptop.replace("(default: 14)", "(default: 20)")
    assert normalizer().text(laptop) == normalizer().text(desktop)
    assert "(default: active cores) (default: <ACTIVE-CORES>)" in normalizer().text(laptop)
    other = "  --max-reads-per-slice <n>   (default: 100000)\n  --threads <n>   (default: 14)\n"
    assert normalizer().text(other) == other


def test_host_os_is_masked_only_under_its_keys():
    text = '{"note" : "macOS 26.6.2 (arm64)", "platform" : "linux-x86_64", "os" : "Version 26.6.2 (Build 25G83)"}'
    assert normalizer().text(text) == text


def test_a_file_that_records_the_host_os_has_a_host_dependent_digest():
    # The export stdout.json holds Python's platform string, so its digest is
    # masked wherever recorded (R10) rather than binding the goldens to a build.
    assert normalizer().holds_run_dependent_field('{"platform": "macOS-26.6.2-arm64-arm-64bit"}')


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


# Captured inputs (R16) and the second ruling round (N1 to N3) ---------------


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


def test_request_inputs_are_decoded_normalized_and_reencoded():
    provenance = '{\n  "createdAt" : "2026-10-02T13:12:35Z",\n  "status" : "completed"\n}\n'
    stable = '{"name":"teaching set"}'
    request = json.dumps({"inputs": [
        {"data": base64.b64encode(provenance.encode()).decode(), "path": f"{RUN_ROOT}/x/.lungfish-provenance.json"},
        {"data": base64.b64encode(stable.encode()).decode(), "path": f"{RUN_ROOT}/x/definition.json"},
    ], "toolVersion": "2026.9.78"}, indent=2, sort_keys=True).replace("/", "\\/")
    result = json.loads(normalizer().request(request))
    assert base64.b64decode(result["inputs"][0]["data"]).decode() == provenance.replace(
        "2026-10-02T13:12:35Z", "<TIMESTAMP>")
    assert base64.b64decode(result["inputs"][1]["data"]).decode() == stable
    assert result["inputs"][0]["path"] == "<RUN_ROOT>/x/.lungfish-provenance.json"
    assert result["toolVersion"] == "<APP_VERSION>"


def raw_metrics(member: str) -> str:
    return '{"stats":{"rawMetrics":{"pairMergeSummary":"' + member.replace('"', '\\"') + '"}},"other":"{\\"b\\":1,\\"a\\":2}"}'


def test_n1_sorts_only_the_stringified_json_under_raw_metrics():
    scrambled = raw_metrics('{"tool":"bbmerge.sh","mergedSamples":[{"sample":"A","disposition":"merged"}],"mergedFragments":376}')
    sorted_text = raw_metrics('{"mergedFragments":376,"mergedSamples":[{"disposition":"merged","sample":"A"}],"tool":"bbmerge.sh"}')
    assert normalize.sort_raw_metric_objects(scrambled) == sorted_text
    assert normalize.sort_raw_metric_objects(sorted_text) == sorted_text
    # The stringified object outside stats.rawMetrics keeps its order.
    assert '"other":"{\\"b\\":1,\\"a\\":2}"' in normalize.sort_raw_metric_objects(scrambled)


def test_n1_sorts_objects_inside_stringified_arrays_and_keeps_array_order():
    text = '{"stats":{"rawMetrics":{"groups":"[{\\"z\\":1,\\"a\\":2},{\\"y\\":3,\\"b\\":4}]"}}}'
    assert normalize.sort_raw_metric_objects(text) == (
        '{"stats":{"rawMetrics":{"groups":"[{\\"a\\":2,\\"z\\":1},{\\"b\\":4,\\"y\\":3}]"}}}')


def test_n1_applies_to_the_result_payload_and_strict_leaves_it_out():
    first = raw_metrics('{"tool":"bbmerge.sh","mergedFragments":376}')
    second = raw_metrics('{"mergedFragments":376,"tool":"bbmerge.sh"}')
    assert normalizer().payload("result.json", first.encode()) == second.encode()
    assert normalizer().payload("annotations.json", first.encode()) == first.encode()
    assert normalizer(strict=True).payload("result.json", first.encode()) == first.encode()


def test_n2_masks_the_bam_hash_and_size_and_only_the_index_hash():
    bam, bai, other = sha("bam bytes"), sha("bai bytes"), sha("other bam bytes")
    text = json.dumps({"files": [record("/x/evidence.bam", bam, 3739), record("/x/evidence.bam.bai", bai, 256),
                                 record("/x/stable.bam", other, 100)]}, indent=2, sort_keys=True)
    n = normalizer()
    n.register(normalize.VolatileDigest(bam, "N2", "bundle-bam/evidence.bam", mask_size=True, strict_skip=True))
    n.register(normalize.VolatileDigest(bai, "N2", "bundle-bam/evidence.bam.bai", strict_skip=True))
    evidence, index, stable = json.loads(n.text(text))["files"]
    assert (evidence["sha256"], evidence["sizeBytes"]) == ("<SHA256-N2>", "<SIZE-N2>")
    assert (index["sha256"], index["sizeBytes"]) == ("<SHA256-N2>", 256)
    assert stable == record("/x/stable.bam", other, 100)


def test_n2_replaces_the_base64_copy_of_a_masked_bam_in_request_inputs():
    bam_bytes = b"\x1f\x8b\x08\x04BAM with a random merge suffix"
    request = json.dumps({"inputs": [{"data": base64.b64encode(bam_bytes).decode(), "path": "/x/evidence.bam"}]})
    n = normalizer()
    n.register(normalize.VolatileDigest(hashlib.sha256(bam_bytes).hexdigest(), "N2", "evidence.bam",
                                        mask_size=True, strict_skip=True))
    assert json.loads(n.request(request))["inputs"][0]["data"] == "<BASE64-N2>"
    assert json.loads(normalizer().request(request))["inputs"][0]["data"] == base64.b64encode(bam_bytes).decode()


def test_n1_and_n2_registrations_are_left_out_in_strict_mode():
    strict = normalizer(strict=True)
    strict.register(normalize.VolatileDigest(sha("bam"), "N2", "x.bam", mask_size=True, strict_skip=True))
    strict.add_path_rule(normalize.PathRule("N2", ("/merged.bam",), strict_skip=True))
    assert strict.digests == {} and strict.path_rules == [] and strict.items == set()
    assert set(normalize.STRICT_SKIP_RULES) == {"N1", "N2"}


def test_n3_staging_folder_token_is_masked_as_a_run_id_and_the_manifest_hash_by_r10():
    first = ('{\n  "stagingRoot" : "' + RUN_ROOT.replace("/", "\\/")
             + '\\/genotype\\/tmp\\/bbmerge-476FA6BC-135D-4F17-8BA2-781285AA3D69",\n  "totalPairs" : 204\n}\n')
    second = first.replace("476FA6BC-135D-4F17-8BA2-781285AA3D69", "FDC9F431-A86C-4665-8E0F-2A0BA9FD446D")
    assert normalizer().text(first) == normalizer().text(second)
    assert "bbmerge-<UUID-1>" in normalizer().text(first) and '"totalPairs" : 204' in normalizer().text(first)
    # The manifest is deleted by the run, so its golden comes from the copy and
    # R10 masks the digest the provenance records for it.
    n = normalizer()
    assert n.holds_run_dependent_field(first)
    n.register(normalize.VolatileDigest(sha(first), "R10", "run/illumina-sample-manifest.json", mask_size=True))
    provenance = json.dumps({"inputs": [record("/x/.amplicon-genotyping/inputs/illumina-sample-manifest.json",
                                               sha(first), len(first))]})
    assert json.loads(n.text(provenance))["inputs"][0]["sha256"] == "<SHA256-R10>"


def wait_until(predicate, timeout: float = 10.0) -> bool:
    """Poll predicate until it holds or the timeout passes (no fixed sleeps)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.001)
    return predicate()


def test_during_run_copies_keep_the_last_bytes_of_a_file_deleted_before_exit(tmp_path):
    written, copy, never = tmp_path / "manifest.json", tmp_path / "copies" / "manifest.json", tmp_path / "never.bam"
    with captures.DuringRunCopies({written: copy, never: tmp_path / "copies" / "never.bam"}) as copies:
        written.write_bytes(b"first")
        assert wait_until(lambda: copies.latest.get(written) == b"first")
        written.write_bytes(b"final")
        assert wait_until(lambda: copies.latest.get(written) == b"final")
        written.unlink()
    assert copy.read_bytes() == b"final"
    assert copies.missing() == [never]


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
    assert any("this checkout's path" in problem for problem in problems)
    assert any("the raw scratch root" in problem for problem in problems)
    assert not any(problem.startswith("x/c.json") for problem in problems)


def test_portability_check_flags_the_home_folder():
    outputs = {"a.json": f'"{Path.home()}/.lungfish-shared/conda/pkgs"'.encode(),
               "b.json": b'"/Users/Shared/lungfish-golden/storage/conda/envs/samtools"'}
    problems = golden.portability_problems("x", outputs, Path("/Users/Shared/lungfish-golden/run"))
    assert problems == [f"x/a.json contains the home folder, which differs between users ({Path.home()}/)"]

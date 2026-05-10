import hashlib
import json
from pathlib import Path


RETAINED_FIXTURES = {
    "Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00": {
        "fixtureWorkflowName": "esviritu-analysis-output",
        "fixtureToolName": "esviritu",
        "purpose": "Retained GUI sidebar fixture for single-sample ESViritu analysis output.",
    },
    "Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00": {
        "fixtureWorkflowName": "esviritu-batch-analysis-output",
        "fixtureToolName": "esviritu-batch",
        "purpose": "Retained GUI sidebar fixture for ESViritu batch analysis output.",
    },
    "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00": {
        "fixtureWorkflowName": "kraken2-classification-output",
        "fixtureToolName": "kraken2",
        "purpose": "Retained classification fixture for Kraken2 and Bracken analysis output.",
    },
    "Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00": {
        "fixtureWorkflowName": "minimap2-alignment-output",
        "fixtureToolName": "minimap2",
        "purpose": "Retained alignment fixture for minimap2 BAM output.",
    },
    "Tests/Fixtures/analyses/spades-2026-01-15T13-00-00": {
        "fixtureWorkflowName": "spades-assembly-output",
        "fixtureToolName": "spades",
        "purpose": "Retained assembly fixture for SPAdes contig output.",
    },
    "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00": {
        "fixtureWorkflowName": "taxtriage-analysis-output",
        "fixtureToolName": "taxtriage",
        "purpose": "Retained taxonomy triage fixture for TaxTriage report output.",
    },
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish": {
        "fixtureWorkflowName": "sars-cov-2-alignment-fixture-generation",
        "fixtureToolName": "create_sarscov2_alignment_fixture.py",
        "purpose": "Retained SARS-CoV-2 MAFFT end-to-end alignment fixture bundle.",
    },
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa": {
        "fixtureWorkflowName": "mafft-alignment-output",
        "fixtureToolName": "mafft",
        "purpose": "Retained nested MAFFT multiple-sequence alignment output bundle.",
    },
}

REQUIRED_TOP_LEVEL_FIELDS = [
    "schemaVersion",
    "workflowName",
    "toolName",
    "toolVersion",
    "createdAt",
    "argv",
    "options",
    "runtimeIdentity",
    "output",
    "files",
    "exitStatus",
    "wallTimeSeconds",
    "stderr",
]
STALE_PATH_MARKERS = [".worktrees", "alignment-tree-viewers"]
RETAINED_PAYLOAD_SCAN_ROOTS = [
    "Tests/Fixtures/analyses",
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish",
]


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_entries(fixture_path):
    entries = []
    for path in sorted(fixture_path.rglob("*")):
        if not path.is_file() or path.name == ".lungfish-provenance.json":
            continue
        relative = path.relative_to(fixture_path).as_posix()
        file_size = path.stat().st_size
        entries.append(
            {
                "path": relative,
                "fileSize": file_size,
                "size": file_size,
                "checksumSHA256": sha256_file(path),
            }
        )
    return entries


def directory_checksum(entries):
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(entry["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(entry["fileSize"]).encode("utf-8"))
        digest.update(b"\0")
        digest.update(entry["checksumSHA256"].encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def directory_size(entries):
    return sum(entry["fileSize"] for entry in entries)


def validate_fixture_sidecar(root, relative_fixture):
    root = Path(root)
    fixture_path = root / relative_fixture
    sidecar_path = fixture_path / ".lungfish-provenance.json"
    errors = []

    if not fixture_path.is_dir():
        return [f"missing retained fixture directory: {fixture_path}"]
    if not sidecar_path.is_file():
        return [f"missing provenance sidecar: {sidecar_path}"]

    try:
        record = json.loads(sidecar_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return [f"malformed provenance JSON: {sidecar_path}: {error}"]

    if not isinstance(record, dict):
        return [f"malformed provenance JSON: {sidecar_path}: expected object"]

    for field in REQUIRED_TOP_LEVEL_FIELDS:
        if field not in record:
            errors.append(f"missing required field {field}: {sidecar_path}")

    if "reproducibleCommand" not in record and "reproducibleShellCommand" not in record:
        errors.append(f"missing required field reproducibleCommand or reproducibleShellCommand: {sidecar_path}")

    output = record.get("output")
    if not isinstance(output, dict):
        errors.append(f"invalid output object: {sidecar_path}")
        output = {}

    files = normalize_files(record.get("files"), sidecar_path, errors)
    actual_files = {entry["path"]: entry for entry in file_entries(fixture_path)}

    output_path = output.get("path")
    if output_path != relative_fixture:
        errors.append(f"stale or incorrect output.path for {sidecar_path}: {output_path!r}")
    if isinstance(output_path, str) and Path(output_path).is_absolute():
        errors.append(f"output.path must be relative: {sidecar_path}")

    output_size = output.get("fileSize", output.get("size"))
    if not isinstance(output_size, int):
        errors.append(f"missing required field output.fileSize: {sidecar_path}")
    elif output_size != directory_size(actual_files.values()):
        errors.append(f"output fileSize mismatch for {sidecar_path}: recorded {output_size}, actual {directory_size(actual_files.values())}")

    output_checksum = output.get("checksumSHA256")
    actual_checksum = directory_checksum(actual_files.values())
    if not isinstance(output_checksum, str):
        errors.append(f"missing required field output.checksumSHA256: {sidecar_path}")
    elif output_checksum != actual_checksum:
        errors.append(f"output checksum mismatch for {sidecar_path}: recorded {output_checksum}, actual {actual_checksum}")

    recorded_paths = set(files)
    actual_paths = set(actual_files)
    for missing in sorted(actual_paths - recorded_paths):
        errors.append(f"missing file provenance entry {missing}: {sidecar_path}")
    for extra in sorted(recorded_paths - actual_paths):
        errors.append(f"listed provenance file does not exist {extra}: {sidecar_path}")

    for path, entry in files.items():
        if Path(path).is_absolute():
            errors.append(f"file path must be relative {path}: {sidecar_path}")
        if any(marker in path for marker in STALE_PATH_MARKERS):
            errors.append(f"stale path marker in file path {path}: {sidecar_path}")
        if "fileSize" not in entry:
            errors.append(f"missing required field files[].fileSize for {path}: {sidecar_path}")
            recorded_size = entry.get("size")
        else:
            recorded_size = entry["fileSize"]
        if "checksumSHA256" not in entry:
            errors.append(f"missing required field files[].checksumSHA256 for {path}: {sidecar_path}")
            recorded_checksum = None
        else:
            recorded_checksum = entry["checksumSHA256"]

        actual = actual_files.get(path)
        if actual is None:
            continue
        if recorded_size != actual["fileSize"]:
            errors.append(f"file size mismatch for {path}: recorded {recorded_size}, actual {actual['fileSize']}: {sidecar_path}")
        if recorded_checksum != actual["checksumSHA256"]:
            errors.append(f"checksum mismatch for {path}: recorded {recorded_checksum}, actual {actual['checksumSHA256']}: {sidecar_path}")

    errors.extend(stale_string_errors(record, sidecar_path))
    return errors


def normalize_files(raw_files, sidecar_path, errors):
    normalized = {}
    if isinstance(raw_files, list):
        iterable = raw_files
    elif isinstance(raw_files, dict):
        iterable = []
        for key, value in raw_files.items():
            if isinstance(value, dict):
                entry = dict(value)
                entry.setdefault("path", key)
                iterable.append(entry)
            else:
                errors.append(f"invalid files entry {key}: {sidecar_path}")
        return normalize_files(iterable, sidecar_path, errors)
    else:
        errors.append(f"invalid files list: {sidecar_path}")
        return normalized

    for entry in iterable:
        if not isinstance(entry, dict):
            errors.append(f"invalid files entry: {sidecar_path}")
            continue
        path = entry.get("path")
        if not isinstance(path, str) or not path:
            errors.append(f"missing required field files[].path: {sidecar_path}")
            continue
        normalized[path] = entry
    return normalized


def stale_string_errors(value, sidecar_path, trail=""):
    errors = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_trail = f"{trail}.{key}" if trail else str(key)
            errors.extend(stale_string_errors(child, sidecar_path, child_trail))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(stale_string_errors(child, sidecar_path, f"{trail}[{index}]"))
    elif isinstance(value, str):
        for marker in STALE_PATH_MARKERS:
            if marker in value:
                errors.append(f"stale path marker {marker!r} in {trail}: {sidecar_path}")
                break
    return errors


def validate_retained_payload_text(root):
    root = Path(root)
    errors = []
    for relative_root in RETAINED_PAYLOAD_SCAN_ROOTS:
        scan_root = root / relative_root
        if not scan_root.is_dir():
            errors.append(f"missing retained fixture scan directory: {scan_root}")
            continue
        for path in sorted(scan_root.rglob("*")):
            if not path.is_file() or is_binary_file(path):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for line_number, line in enumerate(text.splitlines(), start=1):
                for marker in STALE_PATH_MARKERS:
                    if marker in line:
                        errors.append(f"stale path marker {marker!r} in payload {path}:{line_number}")
                        break
    return errors


def is_binary_file(path):
    try:
        chunk = path.read_bytes()[:4096]
    except OSError:
        return True
    return b"\0" in chunk


def main(argv=None):
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Validate retained fixture provenance sidecars.")
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2], type=Path)
    args = parser.parse_args(argv)

    errors = []
    for relative_fixture in RETAINED_FIXTURES:
        errors.extend(validate_fixture_sidecar(args.root.resolve(), relative_fixture))
    errors.extend(validate_retained_payload_text(args.root.resolve()))

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"fixture provenance audit failed: {len(errors)} issue(s)", file=sys.stderr)
        return 1

    print("fixture provenance audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

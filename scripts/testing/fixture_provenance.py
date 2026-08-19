import hashlib
import json
import shlex
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
    "Tests/Fixtures/classifier-full-viewer": {
        "fixtureWorkflowName": "classifier-full-bam-viewer-fixture-generation",
        "fixtureToolName": "generate-classifier-full-viewer-fixture.py",
        "purpose": "Wholly synthetic indexed BAM fixture for the detached classifier evidence viewer.",
        "historicalBackfillAllowed": False,
    },
    "Tests/Fixtures/conformance/2026.1/kraken2-mini-SRR35517702": {
        "fixtureWorkflowName": "conformance-golden-kraken2-mini-SRR35517702",
        "fixtureToolName": "kraken2",
        "dependencySet": "2026.1",
        "purpose": "Retained kraken2 conformance golden for dependency set 2026.1 (recipe kraken2-mini-SRR35517702).",
        "goldenRecipeID": "kraken2-mini-SRR35517702",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-flagstat": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-flagstat",
        "fixtureToolName": "samtools",
        "dependencySet": "2026.1",
        "purpose": "Retained samtools conformance golden for dependency set 2026.1 (recipe sarscov2-flagstat).",
        "goldenRecipeID": "sarscov2-flagstat",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-idxstats": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-idxstats",
        "fixtureToolName": "samtools",
        "dependencySet": "2026.1",
        "purpose": "Retained samtools conformance golden for dependency set 2026.1 (recipe sarscov2-idxstats).",
        "goldenRecipeID": "sarscov2-idxstats",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-seqkit-stats": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-seqkit-stats",
        "fixtureToolName": "seqkit",
        "dependencySet": "2026.1",
        "purpose": "Retained seqkit conformance golden for dependency set 2026.1 (recipe sarscov2-seqkit-stats).",
        "goldenRecipeID": "sarscov2-seqkit-stats",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-fastp": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-fastp",
        "fixtureToolName": "fastp",
        "dependencySet": "2026.1",
        "purpose": "Retained fastp conformance golden for dependency set 2026.1 (recipe sarscov2-fastp).",
        "goldenRecipeID": "sarscov2-fastp",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-minimap2": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-minimap2",
        "fixtureToolName": "minimap2",
        "dependencySet": "2026.1",
        "purpose": "Retained minimap2 conformance golden for dependency set 2026.1 (recipe sarscov2-minimap2).",
        "goldenRecipeID": "sarscov2-minimap2",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-spades": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-spades",
        "fixtureToolName": "spades",
        "dependencySet": "2026.1",
        "purpose": "Retained spades conformance golden for dependency set 2026.1 (recipe sarscov2-spades).",
        "goldenRecipeID": "sarscov2-spades",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-megahit": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-megahit",
        "fixtureToolName": "megahit",
        "dependencySet": "2026.1",
        "purpose": "Retained megahit conformance golden for dependency set 2026.1 (recipe sarscov2-megahit).",
        "goldenRecipeID": "sarscov2-megahit",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-vsearch-derep": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-vsearch-derep",
        "fixtureToolName": "vsearch",
        "dependencySet": "2026.1",
        "purpose": "Retained vsearch conformance golden for dependency set 2026.1 (recipe sarscov2-vsearch-derep).",
        "goldenRecipeID": "sarscov2-vsearch-derep",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-deacon": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-deacon",
        "fixtureToolName": "deacon",
        "dependencySet": "2026.1",
        "purpose": "Retained deacon conformance golden for dependency set 2026.1 (recipe sarscov2-deacon).",
        "goldenRecipeID": "sarscov2-deacon",
    },
    "Tests/Fixtures/conformance/2026.1/sarscov2-bcftools": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-bcftools",
        "fixtureToolName": "bcftools",
        "dependencySet": "2026.1",
        "purpose": "Retained bcftools conformance golden for dependency set 2026.1 (recipe sarscov2-bcftools).",
        "goldenRecipeID": "sarscov2-bcftools",
    },
    "Tests/Fixtures/conformance/2026.1/iqtree-known-sarcopterygian": {
        "fixtureWorkflowName": "conformance-golden-iqtree-known-sarcopterygian",
        "fixtureToolName": "iqtree",
        "dependencySet": "2026.1",
        "purpose": "Retained iqtree conformance golden for dependency set 2026.1 (recipe iqtree-known-sarcopterygian).",
        "goldenRecipeID": "iqtree-known-sarcopterygian",
    },
    "Tests/Fixtures/conformance/2026.2/kraken2-mini-SRR35517702": {
        "fixtureWorkflowName": "conformance-golden-kraken2-mini-SRR35517702",
        "fixtureToolName": "kraken2",
        "dependencySet": "2026.2",
        "purpose": "Retained kraken2 conformance golden for dependency set 2026.2 (recipe kraken2-mini-SRR35517702). Byte-identical to 2026.1 even though the Viral index moved to 20260626: the fixture's three synthetic reads are all unclassified, so this recipe does not exercise the index taxonomy.",
        "goldenRecipeID": "kraken2-mini-SRR35517702",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-flagstat": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-flagstat",
        "fixtureToolName": "samtools",
        "dependencySet": "2026.2",
        "purpose": "Retained samtools conformance golden for dependency set 2026.2 (recipe sarscov2-flagstat).",
        "goldenRecipeID": "sarscov2-flagstat",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-idxstats": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-idxstats",
        "fixtureToolName": "samtools",
        "dependencySet": "2026.2",
        "purpose": "Retained samtools conformance golden for dependency set 2026.2 (recipe sarscov2-idxstats).",
        "goldenRecipeID": "sarscov2-idxstats",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-seqkit-stats": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-seqkit-stats",
        "fixtureToolName": "seqkit",
        "dependencySet": "2026.2",
        "purpose": "Retained seqkit conformance golden for dependency set 2026.2 (recipe sarscov2-seqkit-stats).",
        "goldenRecipeID": "sarscov2-seqkit-stats",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-fastp": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-fastp",
        "fixtureToolName": "fastp",
        "dependencySet": "2026.2",
        "purpose": "Retained fastp conformance golden for dependency set 2026.2 (recipe sarscov2-fastp).",
        "goldenRecipeID": "sarscov2-fastp",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-minimap2": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-minimap2",
        "fixtureToolName": "minimap2",
        "dependencySet": "2026.2",
        "purpose": "Retained minimap2 conformance golden for dependency set 2026.2 (recipe sarscov2-minimap2).",
        "goldenRecipeID": "sarscov2-minimap2",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-spades": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-spades",
        "fixtureToolName": "spades",
        "dependencySet": "2026.2",
        "purpose": "Retained spades conformance golden for dependency set 2026.2 (recipe sarscov2-spades). SPAdes moved 4.2.0 to 4.3.0 and the contig statistics are unchanged.",
        "goldenRecipeID": "sarscov2-spades",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-megahit": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-megahit",
        "fixtureToolName": "megahit",
        "dependencySet": "2026.2",
        "purpose": "Retained megahit conformance golden for dependency set 2026.2 (recipe sarscov2-megahit). The megahit pin did not move this sweep; the recorded 12 contig result is what 13 of 13 isolated runs produce, while two full-batch runs produced 11, which is megahit's own nondeterminism under the recipe's two threads on a busy machine rather than a tool regression.",
        "goldenRecipeID": "sarscov2-megahit",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-vsearch-derep": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-vsearch-derep",
        "fixtureToolName": "vsearch",
        "dependencySet": "2026.2",
        "purpose": "Retained vsearch conformance golden for dependency set 2026.2 (recipe sarscov2-vsearch-derep).",
        "goldenRecipeID": "sarscov2-vsearch-derep",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-deacon": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-deacon",
        "fixtureToolName": "deacon",
        "dependencySet": "2026.2",
        "purpose": "Retained deacon conformance golden for dependency set 2026.2 (recipe sarscov2-deacon). Deacon 0.16.0 adds one additive summary key, check_pairs, which is false for this single ended recipe; every numeric field is unchanged from 2026.1.",
        "goldenRecipeID": "sarscov2-deacon",
    },
    "Tests/Fixtures/conformance/2026.2/sarscov2-bcftools": {
        "fixtureWorkflowName": "conformance-golden-sarscov2-bcftools",
        "fixtureToolName": "bcftools",
        "dependencySet": "2026.2",
        "purpose": "Retained bcftools conformance golden for dependency set 2026.2 (recipe sarscov2-bcftools). bcftools moved 1.23.1 to 1.24 and the called variants are unchanged.",
        "goldenRecipeID": "sarscov2-bcftools",
    },
    "Tests/Fixtures/conformance/2026.2/iqtree-known-sarcopterygian": {
        "fixtureWorkflowName": "conformance-golden-iqtree-known-sarcopterygian",
        "fixtureToolName": "iqtree",
        "dependencySet": "2026.2",
        "purpose": "Retained iqtree conformance golden for dependency set 2026.2 (recipe iqtree-known-sarcopterygian).",
        "goldenRecipeID": "iqtree-known-sarcopterygian",
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
STALE_SUBSTRING_MARKERS = [
    "/" + "Users" + "/" + "dho",
    "." + "worktrees",
    "alignment" + "-tree-viewers",
]
STALE_PATH_ROOTS = [
    "/" + "Volumes",
    "/" + "private" + "/" + "tmp",
    "/" + "var/folders",
    "/" + "tmp",
    "/" + ".tmp",
]
FORBIDDEN_TOP_LEVEL_FIELDS = [
    "historicalPayloadCheckout" + "Command",
    "reproducibleGitCheckout" + "Command",
]
SCIENTIFIC_PROVENANCE_EXPECTATIONS = {
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish": {
        "workflowName": "sars-cov-2-alignment-e2e-fixture-generation",
        "toolName": "create_sarscov2_alignment_fixture.py + lungfish align mafft",
    },
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa": {
        "workflowName": "multiple-sequence-alignment-mafft",
        "toolName": "lungfish align mafft",
    },
    "Tests/Fixtures/classifier-full-viewer": {
        "workflowName": "classifier-full-bam-viewer-fixture-generation",
        "toolName": "generate-classifier-full-viewer-fixture.py",
    },
}
RETAINED_PAYLOAD_SCAN_ROOTS = [
    "Tests/Fixtures/analyses",
    "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish",
    "Tests/Fixtures/classifier-full-viewer",
]
REQUIRED_MSA_PAYLOAD_FILES = [
    "alignment/input.unaligned.fasta",
    "alignment/primary.aligned.fasta",
    "alignment/source.original",
    "manifest.json",
    "analysis-metadata.json",
    "metadata/rows.json",
    "metadata/source-row-map.json",
    "metadata/coordinate-maps.json",
    ".viewstate.json",
    "cache/alignment-index.sqlite",
    "metadata/annotations.json",
    "metadata/annotations.sqlite",
]
CLASSIFIER_FULL_VIEWER_PAYLOADS = {
    "source.sam": {
        "fileSize": 535,
        "checksumSHA256": "652bcb4ce3ce4d21a0ecdf68f58e0225b8b2e6498dc59dbf658b8866f8719aa7",
    },
    "conflicting-reference.fasta": {
        "fileSize": 140,
        "checksumSHA256": "36e2d1088b5810e73fdfb3a6470accf0942d50ea9cbf986b3d110c6822bba8a4",
    },
    "conflicting-reference.fasta.fai": {
        "fileSize": 33,
        "checksumSHA256": "b846c3762ca6d66fe5076673e805eb03b44a52206b11c1ad27e1c1793730d845",
    },
    "evidence.bam": {
        "fileSize": 354,
        "checksumSHA256": "03fb3647860e1716bf31117e1d0e9c82af25fa1f764b2c6b1b9a94a8f0a35f64",
    },
    "evidence.bam.bai": {
        "fileSize": 96,
        "checksumSHA256": "9bb70dd9b082b6457415a6126ecafdf005818a8a9852d623241fe7e454bdebde",
    },
    "evidence.cram": {
        "fileSize": 970,
        "checksumSHA256": "e16d8f5963cf5410f7d4756e3a219cdedba1d10dd749120ff985d2bacbc4cad6",
    },
    "evidence.cram.crai": {
        "fileSize": 56,
        "checksumSHA256": "4f71a0de79300eac70837d06ef3115b684a89b3b53fd3b5adb1aa67d64cba6b6",
    },
}


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
    for field in FORBIDDEN_TOP_LEVEL_FIELDS:
        if field in record:
            errors.append(f"misleading historical checkout field {field} must not be present: {sidecar_path}")

    if "reproducibleCommand" not in record and "reproducibleShellCommand" not in record:
        errors.append(f"missing required field reproducibleCommand or reproducibleShellCommand: {sidecar_path}")

    errors.extend(validate_required_field_types(record, sidecar_path))

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
        marker = stale_path_marker(path)
        if marker is not None:
            errors.append(f"stale path marker {marker!r} in file path {path}: {sidecar_path}")
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
    errors.extend(validate_fixture_specific_provenance(root, fixture_path, relative_fixture, record, sidecar_path))
    return errors


def validate_required_field_types(record, sidecar_path):
    errors = []
    if "schemaVersion" in record and not is_integer(record["schemaVersion"]):
        errors.append(f"invalid schemaVersion: expected integer: {sidecar_path}")
    for field in ["workflowName", "toolName", "toolVersion", "createdAt"]:
        if field in record and not is_non_empty_string(record[field]):
            errors.append(f"invalid {field}: expected non-empty string: {sidecar_path}")

    if "argv" in record:
        argv = record["argv"]
        if not isinstance(argv, list) or not argv or not all(isinstance(argument, str) for argument in argv):
            errors.append(f"invalid argv: expected non-empty list of strings: {sidecar_path}")

    for field in ["reproducibleCommand", "reproducibleShellCommand"]:
        if field in record and not is_non_empty_string(record[field]):
            errors.append(f"invalid {field}: expected non-empty string: {sidecar_path}")

    if "options" in record and not isinstance(record["options"], dict):
        errors.append(f"invalid options: expected object: {sidecar_path}")
    if "runtimeIdentity" in record and not isinstance(record["runtimeIdentity"], dict):
        errors.append(f"invalid runtimeIdentity: expected object: {sidecar_path}")
    if "exitStatus" in record and not is_integer(record["exitStatus"]):
        errors.append(f"invalid exitStatus: expected integer: {sidecar_path}")
    if "wallTimeSeconds" in record and not is_number(record["wallTimeSeconds"]):
        errors.append(f"invalid wallTimeSeconds: expected number: {sidecar_path}")
    if "stderr" in record and record["stderr"] is not None and not isinstance(record["stderr"], str):
        errors.append(f"invalid stderr: expected string or null: {sidecar_path}")
    return errors


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_non_empty_string(value):
    return isinstance(value, str) and bool(value.strip())


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
        marker = stale_path_marker(value)
        if marker is not None:
            errors.append(f"stale path marker {marker!r} in {trail}: {sidecar_path}")
    return errors


def validate_fixture_specific_provenance(root, fixture_path, relative_fixture, record, sidecar_path):
    expected = SCIENTIFIC_PROVENANCE_EXPECTATIONS.get(relative_fixture)
    if expected is None:
        return []
    errors = []
    for field, expected_value in expected.items():
        if record.get(field) != expected_value:
            errors.append(f"expected {field} {expected_value!r}: {sidecar_path}")
    if record.get("historicalBackfill") is True or record.get("toolName") == "write-analysis-fixture-provenance.py":
        errors.append(f"{sidecar_path} must preserve scientific workflow provenance")
    if relative_fixture == "Tests/Fixtures/classifier-full-viewer":
        errors.extend(validate_classifier_full_viewer_provenance(root, fixture_path, record, sidecar_path))
    elif relative_fixture.endswith(".lungfishmsa"):
        invocations = record.get("externalToolInvocations")
        if not isinstance(invocations, list) or not invocations:
            errors.append(f"missing externalToolInvocations for MAFFT provenance: {sidecar_path}")
        else:
            errors.extend(validate_mafft_external_invocation(invocations[0], sidecar_path))
        input_record = record.get("input")
        if not isinstance(input_record, dict):
            errors.append(f"missing input object for MAFFT provenance: {sidecar_path}")
        else:
            errors.extend(validate_referenced_file_entry(root, fixture_path, input_record, sidecar_path, "input", "MAFFT"))
        input_files = record.get("inputFiles")
        if not isinstance(input_files, list) or not input_files:
            errors.append(f"missing inputFiles for MAFFT provenance: {sidecar_path}")
        else:
            for index, input_file in enumerate(input_files):
                if not isinstance(input_file, dict):
                    errors.append(f"invalid inputFiles[{index}] object for MAFFT provenance: {sidecar_path}")
                    continue
                errors.extend(validate_referenced_file_entry(root, fixture_path, input_file, sidecar_path, f"inputFiles[{index}]", "MAFFT"))
        errors.extend(validate_required_msa_payload_files(fixture_path, sidecar_path))
        if not isinstance(record.get("options"), dict) or record["options"].get("name") != "sars-cov-2-genomes-mafft":
            errors.append(f"missing MAFFT options for nested alignment provenance: {sidecar_path}")
    else:
        errors.extend(validate_root_alignment_composite_workflow(record, sidecar_path))
        input_record = record.get("input")
        if not isinstance(input_record, dict):
            errors.append(f"missing input object for root alignment provenance: {sidecar_path}")
        else:
            errors.extend(validate_referenced_file_entry(root, fixture_path, input_record, sidecar_path, "input", "alignment"))
        input_files = record.get("inputFiles")
        if input_files is not None:
            if not isinstance(input_files, list):
                errors.append(f"invalid inputFiles list for root alignment provenance: {sidecar_path}")
            else:
                for index, input_file in enumerate(input_files):
                    if not isinstance(input_file, dict):
                        errors.append(f"invalid inputFiles[{index}] object for root alignment provenance: {sidecar_path}")
                        continue
                    errors.extend(validate_referenced_file_entry(root, fixture_path, input_file, sidecar_path, f"inputFiles[{index}]", "alignment"))
        warnings = record.get("warnings")
        expected_warning = "deterministic synthetic derivatives"
        if not isinstance(warnings, list) or not any(expected_warning in str(warning) for warning in warnings):
            errors.append(f"missing deterministic derivative warning in root alignment provenance: {sidecar_path}")
    return errors


def validate_classifier_full_viewer_provenance(root, fixture_path, record, sidecar_path):
    errors = []
    if record.get("syntheticData") is not True:
        errors.append(f"classifier full-viewer fixture must be declared wholly synthetic: {sidecar_path}")

    options = record.get("options")
    if not isinstance(options, dict):
        options = {}
    expected_options = {
        "syntheticData": True,
        "contigName": "synthetic-track-A",
        "contigLength": 120,
        "excludeFlags": 3332,
        "retainedRecordNames": ["item-A", "item-B"],
        "conflictingReference": {
            "path": "conflicting-reference.fasta",
            "base": "C",
            "coveredReadBase": "A",
        },
    }
    for field, expected_value in expected_options.items():
        if options.get(field) != expected_value:
            errors.append(
                f"invalid classifier full-viewer option {field}: expected {expected_value!r}: {sidecar_path}"
            )

    argv = record.get("argv")
    expected_executed_command = shlex.join(argv) if isinstance(argv, list) else None
    executed_command = record.get("executedShellCommand")
    if not is_non_empty_string(executed_command):
        errors.append(f"missing classifier full-viewer executedShellCommand: {sidecar_path}")
    elif executed_command != expected_executed_command:
        errors.append(f"classifier full-viewer executedShellCommand does not match argv: {sidecar_path}")

    requested = options.get("requested")
    if not isinstance(requested, dict):
        errors.append(f"missing classifier full-viewer requested options: {sidecar_path}")
    else:
        for option, field in [("--output-dir", "outputDirectory"), ("--samtools", "samtools")]:
            expected_value = argv_option_value(argv, option)
            if requested.get(field) != expected_value:
                errors.append(
                    f"classifier full-viewer requested option {field} does not match argv: {sidecar_path}"
                )

    defaults = options.get("defaults")
    if not isinstance(defaults, dict):
        errors.append(f"missing classifier full-viewer default options: {sidecar_path}")
    else:
        if defaults.get("outputDirectory") != "Tests/Fixtures/classifier-full-viewer":
            errors.append(f"invalid classifier full-viewer default outputDirectory: {sidecar_path}")
        if not is_non_empty_string(defaults.get("samtools")):
            errors.append(f"invalid classifier full-viewer default samtools resolution: {sidecar_path}")

    resolved = options.get("resolved")
    if not isinstance(resolved, dict):
        errors.append(f"missing classifier full-viewer resolved options: {sidecar_path}")
    else:
        if resolved.get("outputDirectory") != "Tests/Fixtures/classifier-full-viewer":
            errors.append(f"invalid classifier full-viewer resolved outputDirectory: {sidecar_path}")
        if not is_non_empty_string(resolved.get("samtools")):
            errors.append(f"invalid classifier full-viewer resolved samtools: {sidecar_path}")

    runtime = record.get("runtimeIdentity")
    if not isinstance(runtime, dict):
        runtime = {}
    if not is_non_empty_string(runtime.get("samtoolsExecutable")):
        errors.append(f"missing classifier full-viewer samtools executable identity: {sidecar_path}")
    if not is_sha256(runtime.get("samtoolsExecutableChecksumSHA256")):
        errors.append(f"missing classifier full-viewer samtools executable checksum: {sidecar_path}")
    if record.get("status") != "completed" or record.get("exitStatus") != 0:
        errors.append(f"classifier full-viewer retained fixture generation did not complete successfully: {sidecar_path}")

    input_record = record.get("input")
    if not isinstance(input_record, dict):
        errors.append(f"missing input object for classifier full-viewer provenance: {sidecar_path}")
    else:
        if input_record.get("path") != "source.sam":
            errors.append(f"classifier full-viewer input must be source.sam: {sidecar_path}")
        errors.extend(
            validate_referenced_file_entry(
                root,
                fixture_path,
                input_record,
                sidecar_path,
                "input",
                "classifier full-viewer",
            )
        )

    required_payloads = set(CLASSIFIER_FULL_VIEWER_PAYLOADS)
    actual_payloads = {
        path.relative_to(fixture_path).as_posix()
        for path in fixture_path.rglob("*")
        if path.is_file() and path.name != ".lungfish-provenance.json"
    }
    for missing in sorted(required_payloads - actual_payloads):
        errors.append(f"missing classifier full-viewer payload file {missing}: {sidecar_path}")
    for relative_path, expected in CLASSIFIER_FULL_VIEWER_PAYLOADS.items():
        payload = fixture_path / relative_path
        if not payload.is_file():
            continue
        if payload.stat().st_size != expected["fileSize"]:
            errors.append(
                f"classifier full-viewer payload {relative_path} size does not match deterministic fixture: "
                f"{sidecar_path}"
            )
        if sha256_file(payload) != expected["checksumSHA256"]:
            errors.append(
                f"classifier full-viewer payload {relative_path} checksum does not match deterministic fixture: "
                f"{sidecar_path}"
            )

    invocations = record.get("externalToolInvocations")
    if not isinstance(invocations, list) or not invocations:
        errors.append(f"missing samtools externalToolInvocations: {sidecar_path}")
    else:
        for subcommand in ["version", "faidx", "view-bam", "index-bam", "view-cram", "index-cram", "quickcheck"]:
            invocation = next(
                (
                    candidate
                    for candidate in invocations
                    if isinstance(candidate, dict)
                    and candidate.get("name") == "samtools"
                    and candidate.get("subcommand") == subcommand
                ),
                None,
            )
            if invocation is None:
                errors.append(f"missing samtools {subcommand} externalToolInvocation: {sidecar_path}")
            else:
                errors.extend(
                    validate_samtools_external_invocation(
                        invocation,
                        subcommand,
                        runtime,
                        fixture_path,
                        sidecar_path,
                    )
                )
    return errors


def validate_samtools_external_invocation(invocation, subcommand, workflow_runtime, fixture_path, sidecar_path):
    errors = []
    if not is_non_empty_string(invocation.get("version")):
        errors.append(f"invalid samtools {subcommand} version: {sidecar_path}")
    argv = invocation.get("argv")
    expected_argv = {
        "version": ["samtools", "--version"],
        "faidx": ["samtools", "faidx", "conflicting-reference.fasta"],
        "view-bam": ["samtools", "view", "--no-PG", "-b", "-o", "evidence.bam", "source.sam"],
        "index-bam": ["samtools", "index", "evidence.bam", "evidence.bam.bai"],
        "view-cram": ["samtools", "view", "--no-PG", "-C", "-o", "evidence.cram", "evidence.bam"],
        "index-cram": ["samtools", "index", "evidence.cram", "evidence.cram.crai"],
        "quickcheck": ["samtools", "quickcheck", "evidence.bam", "evidence.cram"],
    }[subcommand]
    expected_inputs = {
        "version": [],
        "faidx": ["conflicting-reference.fasta"],
        "view-bam": ["source.sam"],
        "index-bam": ["evidence.bam"],
        "view-cram": ["evidence.bam", "conflicting-reference.fasta"],
        "index-cram": ["evidence.cram"],
        "quickcheck": ["evidence.bam", "evidence.cram"],
    }[subcommand]
    expected_outputs = {
        "version": [],
        "faidx": ["conflicting-reference.fasta.fai"],
        "view-bam": ["evidence.bam"],
        "index-bam": ["evidence.bam.bai"],
        "view-cram": ["evidence.cram"],
        "index-cram": ["evidence.cram.crai"],
        "quickcheck": [],
    }[subcommand]
    if argv != expected_argv:
        errors.append(f"invalid samtools {subcommand} argv: {sidecar_path}")
    errors.extend(
        validate_invocation_file_records(
            invocation.get("inputFiles"), expected_inputs, fixture_path, subcommand, "input", sidecar_path
        )
    )
    errors.extend(
        validate_invocation_file_records(
            invocation.get("outputFiles"), expected_outputs, fixture_path, subcommand, "output", sidecar_path
        )
    )
    command = invocation.get("reproducibleCommand")
    if not is_non_empty_string(command):
        errors.append(f"invalid samtools {subcommand} reproducibleCommand: {sidecar_path}")
    elif isinstance(argv, list) and command != shlex.join(argv):
        errors.append(f"samtools {subcommand} reproducibleCommand does not match argv: {sidecar_path}")
    runtime = invocation.get("runtimeIdentity")
    if not isinstance(runtime, dict) or not runtime:
        errors.append(f"invalid samtools {subcommand} runtimeIdentity: {sidecar_path}")
    else:
        if not is_non_empty_string(runtime.get("samtoolsExecutable")):
            errors.append(f"invalid samtools {subcommand} executable identity: {sidecar_path}")
        if not is_sha256(runtime.get("samtoolsExecutableChecksumSHA256")):
            errors.append(f"invalid samtools {subcommand} executable checksum: {sidecar_path}")
        if runtime.get("samtoolsExecutable") != workflow_runtime.get("samtoolsExecutable"):
            errors.append(
                f"samtools {subcommand} executable identity disagrees with workflow runtime: {sidecar_path}"
            )
        if runtime.get("samtoolsExecutableChecksumSHA256") != workflow_runtime.get(
            "samtoolsExecutableChecksumSHA256"
        ):
            errors.append(
                f"samtools {subcommand} executable checksum disagrees with workflow runtime: {sidecar_path}"
            )
    if not is_integer(invocation.get("exitStatus")) or invocation.get("exitStatus") != 0:
        errors.append(f"invalid samtools {subcommand} exitStatus: {sidecar_path}")
    if not is_number(invocation.get("wallTimeSeconds")):
        errors.append(f"invalid samtools {subcommand} wallTimeSeconds: {sidecar_path}")
    if not isinstance(invocation.get("stderr"), str):
        errors.append(f"invalid samtools {subcommand} stderr: {sidecar_path}")
    return errors


def validate_invocation_file_records(records, expected_paths, fixture_path, subcommand, label, sidecar_path):
    if not isinstance(records, list):
        return [f"missing samtools {subcommand} {label}Files: {sidecar_path}"]
    actual_paths = [record.get("path") for record in records if isinstance(record, dict)]
    if actual_paths != expected_paths or len(records) != len(expected_paths):
        return [f"invalid samtools {subcommand} {label}Files paths: {sidecar_path}"]
    errors = []
    for record in records:
        path = fixture_path / record["path"]
        if record.get("fileSize") != path.stat().st_size:
            errors.append(f"samtools {subcommand} {label}Files size mismatch: {sidecar_path}")
        if record.get("checksumSHA256") != sha256_file(path):
            errors.append(f"samtools {subcommand} {label}Files checksum mismatch: {sidecar_path}")
    return errors


def argv_option_value(argv, option):
    if not isinstance(argv, list):
        return None
    try:
        index = argv.index(option)
    except ValueError:
        return None
    return argv[index + 1] if index + 1 < len(argv) else None


def is_sha256(value):
    if not isinstance(value, str) or len(value) != 64:
        return False
    return all(character in "0123456789abcdef" for character in value.lower())


def validate_root_alignment_composite_workflow(record, sidecar_path):
    errors = []
    command = record.get("reproducibleCommand", record.get("reproducibleShellCommand"))
    if not is_non_empty_string(command) or "create_sarscov2_alignment_fixture.py" not in command or "lungfish align mafft" not in command:
        errors.append(f"root alignment provenance must include both fixture generation and lungfish align mafft commands: {sidecar_path}")
    argv = record.get("argv")
    if not isinstance(argv, list) or not any("create_sarscov2_alignment_fixture.py" in str(part) for part in argv) or not any("lungfish align mafft" in str(part) for part in argv):
        errors.append(f"root alignment argv must include composite fixture generation and MAFFT commands: {sidecar_path}")

    steps = record.get("workflowSteps")
    if not isinstance(steps, list) or len(steps) < 2:
        return [*errors, f"missing root alignment composite workflowSteps: {sidecar_path}"]

    generator_step = find_workflow_step(steps, "create_sarscov2_alignment_fixture.py")
    mafft_step = find_workflow_step(steps, "lungfish align mafft")
    if generator_step is None:
        errors.append(f"missing root alignment fixture generation workflow step: {sidecar_path}")
    else:
        errors.extend(validate_workflow_step(generator_step, "fixture generation", sidecar_path))
    if mafft_step is None:
        errors.append(f"missing root alignment composite MAFFT workflow step: {sidecar_path}")
    else:
        errors.extend(validate_workflow_step(mafft_step, "MAFFT alignment", sidecar_path))
        step_command = mafft_step.get("reproducibleCommand", mafft_step.get("reproducibleShellCommand"))
        if not is_non_empty_string(step_command) or "lungfish align mafft" not in step_command:
            errors.append(f"root alignment MAFFT workflow step must include lungfish align mafft command: {sidecar_path}")
    return errors


def find_workflow_step(steps, tool_name):
    for step in steps:
        if isinstance(step, dict) and step.get("toolName") == tool_name:
            return step
    return None


def validate_workflow_step(step, label, sidecar_path):
    errors = []
    if not is_non_empty_string(step.get("workflowName")):
        errors.append(f"invalid root alignment {label} workflowName: {sidecar_path}")
    if not is_non_empty_string(step.get("toolName")):
        errors.append(f"invalid root alignment {label} toolName: {sidecar_path}")
    argv = step.get("argv")
    if not isinstance(argv, list) or not argv or not all(isinstance(argument, str) for argument in argv):
        errors.append(f"invalid root alignment {label} argv: {sidecar_path}")
    command = step.get("reproducibleCommand", step.get("reproducibleShellCommand"))
    if not is_non_empty_string(command):
        errors.append(f"invalid root alignment {label} reproducibleCommand: {sidecar_path}")
    return errors


def validate_mafft_external_invocation(mafft, sidecar_path):
    errors = []
    if not isinstance(mafft, dict):
        return [f"incomplete MAFFT external invocation provenance: {sidecar_path}"]
    if mafft.get("name") != "mafft":
        errors.append(f"invalid MAFFT external invocation name: {sidecar_path}")
    if not is_non_empty_string(mafft.get("version")):
        errors.append(f"invalid MAFFT external invocation version: {sidecar_path}")
    argv = mafft.get("argv")
    if not isinstance(argv, list) or not argv or not all(isinstance(argument, str) for argument in argv):
        errors.append(f"invalid MAFFT external invocation argv: {sidecar_path}")
    if not is_non_empty_string(mafft.get("reproducibleCommand")):
        errors.append(f"invalid MAFFT external invocation reproducibleCommand: {sidecar_path}")
    if not is_integer(mafft.get("exitStatus")) or mafft.get("exitStatus") != 0:
        errors.append(f"invalid MAFFT external invocation exitStatus: {sidecar_path}")
    if not is_number(mafft.get("wallTimeSeconds")):
        errors.append(f"invalid MAFFT external invocation wallTimeSeconds: {sidecar_path}")
    if not isinstance(mafft.get("stderr"), str):
        errors.append(f"invalid MAFFT external invocation stderr: {sidecar_path}")
    for field in ["condaEnvironment", "executablePath"]:
        if not is_non_empty_string(mafft.get(field)):
            errors.append(f"invalid MAFFT external invocation {field}: {sidecar_path}")
    return errors


def validate_required_msa_payload_files(fixture_path, sidecar_path):
    errors = []
    for relative_path in REQUIRED_MSA_PAYLOAD_FILES:
        if not (fixture_path / relative_path).is_file():
            errors.append(f"missing required MAFFT payload file {relative_path}: {sidecar_path}")
    return errors


def validate_referenced_file_entry(root, fixture_path, entry, sidecar_path, field_name, context):
    errors = []
    path = entry.get("path")
    if not is_non_empty_string(path):
        return [f"invalid {context} {field_name}.path: {sidecar_path}"]
    if Path(path).is_absolute():
        errors.append(f"{context} {field_name}.path must be relative: {sidecar_path}")
        return errors
    marker = stale_path_marker(path)
    if marker is not None:
        errors.append(f"stale path marker {marker!r} in {context} {field_name}.path {path}: {sidecar_path}")

    candidate_paths = [fixture_path / path, root / path]
    actual_path = next((candidate for candidate in candidate_paths if candidate.is_file()), None)
    if actual_path is None:
        errors.append(f"{context} {field_name}.path does not exist {path}: {sidecar_path}")
        return errors

    recorded_size = entry.get("fileSize", entry.get("size"))
    actual_size = actual_path.stat().st_size
    if not is_integer(recorded_size):
        errors.append(f"invalid {context} {field_name}.fileSize: {sidecar_path}")
    elif recorded_size != actual_size:
        errors.append(f"{context} input fileSize mismatch for {field_name}: recorded {recorded_size}, actual {actual_size}: {sidecar_path}")

    recorded_checksum = entry.get("checksumSHA256")
    actual_checksum = sha256_file(actual_path)
    if not is_non_empty_string(recorded_checksum):
        errors.append(f"invalid {context} {field_name}.checksumSHA256: {sidecar_path}")
    elif recorded_checksum != actual_checksum:
        errors.append(f"{context} input checksum mismatch for {field_name}: recorded {recorded_checksum}, actual {actual_checksum}: {sidecar_path}")
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
            if not path.is_file() or path.name == ".lungfish-provenance.json" or is_binary_file(path):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            try:
                decoded = json.loads(text)
            except json.JSONDecodeError:
                decoded = None
            if decoded is not None:
                errors.extend(stale_payload_json_errors(decoded, path))
            for line_number, line in enumerate(text.splitlines(), start=1):
                marker = stale_path_marker(line)
                if marker is not None:
                    errors.append(f"stale path marker {marker!r} in payload {path}:{line_number}")
    return errors


def stale_payload_json_errors(value, path, trail=""):
    errors = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_trail = f"{trail}.{key}" if trail else str(key)
            errors.extend(stale_payload_json_errors(child, path, child_trail))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(stale_payload_json_errors(child, path, f"{trail}[{index}]"))
    elif isinstance(value, str):
        marker = stale_path_marker(value)
        if marker is not None:
            errors.append(f"stale path marker {marker!r} in payload {path} field {trail}")
    return errors


def stale_path_marker(value):
    if not isinstance(value, str):
        return None
    normalized = value.replace("\\/", "/")
    for marker in STALE_SUBSTRING_MARKERS:
        if marker in normalized:
            return marker
    for root in STALE_PATH_ROOTS:
        if contains_path_root_or_descendant(normalized, root):
            return root
    dot_tmp_root = "/" + ".tmp"
    if dot_tmp_root in normalized and contains_dot_tmp_path_segment(normalized):
        return dot_tmp_root
    return None


def contains_path_root_or_descendant(value, root):
    start = value.find(root)
    while start != -1:
        end = start + len(root)
        before = value[start - 1] if start > 0 else ""
        after = value[end] if end < len(value) else ""
        before_ok = start == 0 or before in {'"', "'", " ", "=", ":", "[", "(", ","}
        after_ok = end == len(value) or after in {"/", '"', "'", " ", "\n", "\r", "\t", ")", "]", ",", "}"}
        if before_ok and after_ok:
            return True
        start = value.find(root, start + 1)
    return False


def contains_dot_tmp_path_segment(value):
    marker = "/" + ".tmp"
    start = value.find(marker)
    while start != -1:
        end = start + len(marker)
        after = value[end] if end < len(value) else ""
        if end == len(value) or after in {"/", '"', "'", " ", "\n", "\r", "\t", ")", "]", ",", "}"}:
            return True
        start = value.find(marker, start + 1)
    return False


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

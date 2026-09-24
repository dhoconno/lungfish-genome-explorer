"""Pinned varVAMP 1.3.2 invocation and normalization for adapter schema v1."""

from __future__ import annotations

import csv
import importlib.metadata
import json
import math
import multiprocessing
import os
from pathlib import Path
import sys
from typing import Any

from common import (
    AdapterError,
    accept_pair_length,
    deterministic_id,
    native_event,
    sha256_file,
    validate_target_contract,
    write_json,
)


ENGINE_VERSION = "1.3.2"
SOURCE_HASHES = {
    "command.py": "7f08581c29effbdf09ecfe52fb80bbd09a34ebd567e957a315bf94f2f62f687a",
    "scripts/alignment.py": "8d95252c460eb190dc6a23e7f3edabad48bd2608fc5bc888a990dff9d1e4ae6d",
    "scripts/consensus.py": "06be0430adb536835b917753f2dd20d133d991afb4989aadb0819ac6fc3dd4dc",
    "scripts/reporting.py": "dcc0095c0f362a928c4713b9cc2001a800f9a7ca868cadb339cdf94ce9a20718",
    "scripts/scheme.py": "ad7fc1d98aa98af272ace6ede3d0b1709e871b272800ee4f9b85a891c6e5b27d",
    "scripts/qpcr.py": "bd4c6184a60a10077c7f192f8ad33c1d04b080ebcb1b0e8c93ed86334a510590",
    "scripts/default_config.py": "ca577086f31ccdb5f75220bb2bbc1c0d821ee03cb3536d1dbf72b1d9d0f38c1d",
    "scripts/get_config.py": "2af837621b6d51b0de4718ca85fc4b8c8e4948aa4fa222d2118a9c13aad3e179",
}

CONFIG_SPECS: dict[str, tuple[str, int | None, Any]] = {
    "TERMINAL_MASKING_THRESHOLD": ("number", None, 0.5),
    "PRIMER_TMP": ("numberArray", 3, [56, 63, 60]),
    "PRIMER_GC_RANGE": ("numberArray", 3, [35, 65, 50]),
    "PRIMER_SIZES": ("integerArray", 3, [18, 24, 21]),
    "PRIMER_MAX_POLYX": ("integer", None, 4),
    "PRIMER_MAX_DINUC_REPEATS": ("integer", None, 4),
    "PRIMER_HAIRPIN": ("number", None, 47),
    "PRIMER_GC_END": ("integerArray", 2, [1, 3]),
    "PRIMER_MIN_3_WITHOUT_AMB": ("integer", None, 3),
    "PRIMER_MAX_DIMER_TMP": ("number", None, 35),
    "PRIMER_MAX_DIMER_DELTAG": ("number", None, -9000),
    "END_OVERLAP": ("integer", None, 5),
    "QPROBE_TMP": ("numberArray", 3, [64, 70, 67]),
    "QPROBE_SIZES": ("integerArray", 3, [20, 30, 25]),
    "QPROBE_GC_RANGE": ("numberArray", 3, [40, 80, 60]),
    "QPROBE_GC_END": ("integerArray", 2, [0, 4]),
    "QPRIMER_DIFF": ("number", None, 2),
    "QPROBE_TEMP_DIFF": ("numberArray", 2, [5, 10]),
    "QPROBE_DISTANCE": ("integerArray", 2, [4, 15]),
    "QAMPLICON_GC": ("numberArray", 2, [40, 60]),
    "QAMPLICON_DEL_CUTOFF": ("integer", None, 4),
    "PCR_MV_CONC": ("number", None, 100),
    "PCR_DV_CONC": ("number", None, 2),
    "PCR_DNTP_CONC": ("number", None, 0.8),
    "PCR_DNA_CONC": ("number", None, 15),
}
QPCR_CONFIG_KEYS = {key for key in CONFIG_SPECS if key.startswith("Q")}


def verify_runtime() -> dict[str, Any]:
    try:
        import varvamp
        from varvamp import command
        from varvamp.scripts import alignment, consensus, default_config, get_config, qpcr, reporting, scheme
    except Exception as error:
        raise AdapterError("runtime_verification_failed", f"cannot import pinned varVAMP runtime: {error}") from error
    version = getattr(varvamp, "__version__", None)
    try:
        distribution_version = importlib.metadata.version("varvamp")
    except importlib.metadata.PackageNotFoundError:
        distribution_version = None
    if version != ENGINE_VERSION or distribution_version != ENGINE_VERSION:
        raise AdapterError(
            "runtime_verification_failed", "varVAMP runtime version does not match adapter contract",
            {"moduleVersion": version, "distributionVersion": distribution_version, "expected": ENGINE_VERSION},
        )
    modules = {
        "command.py": command,
        "scripts/alignment.py": alignment,
        "scripts/consensus.py": consensus,
        "scripts/reporting.py": reporting,
        "scripts/scheme.py": scheme,
        "scripts/qpcr.py": qpcr,
        "scripts/default_config.py": default_config,
        "scripts/get_config.py": get_config,
    }
    verification = []
    for name, module in modules.items():
        path = Path(module.__file__).resolve()
        actual = sha256_file(path)
        expected = SOURCE_HASHES[name]
        verification.append({
            "path": str(path), "sha256": actual, "expectedSHA256": expected,
            "byteSize": path.stat().st_size,
        })
        if actual != expected:
            raise AdapterError(
                "runtime_verification_failed", f"varVAMP source hash mismatch for {name}",
                {"path": str(path), "actual": actual, "expected": expected},
            )
    conda_path = Path(sys.prefix) / "conda-meta" / "varvamp-1.3.2-pyhdfd78af_0.json"
    if not conda_path.is_file():
        raise AdapterError("runtime_verification_failed", "exact varVAMP Conda package record is missing")
    conda_metadata = json.loads(conda_path.read_text(encoding="utf-8"))
    expected_conda = {"name": "varvamp", "version": "1.3.2", "build": "pyhdfd78af_0", "channel": "bioconda"}
    actual_conda = {key: conda_metadata.get(key) for key in expected_conda}
    if actual_conda != expected_conda:
        raise AdapterError(
            "runtime_verification_failed", "varVAMP Conda package record does not match the pinned distribution",
            {"expected": expected_conda, "actual": actual_conda, "path": str(conda_path.resolve())},
        )
    conda_record = {
        "path": str(conda_path.resolve()),
        "sha256": sha256_file(conda_path),
        "byteSize": conda_path.stat().st_size,
        **actual_conda,
        "subdir": conda_metadata.get("subdir"),
        "url": conda_metadata.get("url"),
    }
    return {
        "version": version,
        "modulePath": str(Path(varvamp.__file__).resolve()),
        "sourceVerification": verification,
        "environmentPrefix": str(Path(sys.prefix).resolve()),
        "distribution": "bioconda::varvamp=1.3.2=pyhdfd78af_0",
        "condaPackageRecord": conda_record,
        "modules": {"command": command, "alignment": alignment},
    }


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _validated_config_value(key: str, value: Any) -> Any:
    kind, length, _ = CONFIG_SPECS[key]
    if kind == "integer":
        if not _is_int(value):
            raise AdapterError("invalid_option", f"configOverrides.{key} must be an integer")
        return value
    if kind == "number":
        if not _is_number(value):
            raise AdapterError("invalid_option", f"configOverrides.{key} must be a finite number")
        return value
    if not isinstance(value, list) or len(value) != length:
        raise AdapterError("invalid_option", f"configOverrides.{key} must contain exactly {length} values")
    predicate = _is_int if kind == "integerArray" else _is_number
    if not all(predicate(item) for item in value):
        raise AdapterError("invalid_option", f"configOverrides.{key} contains a value of the wrong type")
    return list(value)


def generate_varvamp_config(
    path: Path,
    *,
    mode: str,
    minimum: int,
    maximum: int,
    overrides: dict[str, Any],
) -> dict[str, Any]:
    if mode not in {"single", "tiled", "qpcr"}:
        raise AdapterError("invalid_mode", f"unsupported varVAMP mode {mode!r}")
    if not _is_int(minimum) or not _is_int(maximum) or minimum > maximum:
        raise AdapterError("invalid_amplicon_range", "invalid varVAMP amplicon range")
    if not isinstance(overrides, dict):
        raise AdapterError("invalid_option", "configOverrides must be an object")
    if "QAMPLICON_LENGTH" in overrides:
        raise AdapterError("invalid_option", "QAMPLICON_LENGTH is controlled by the adapter")
    unknown = sorted(set(overrides) - set(CONFIG_SPECS))
    if unknown:
        raise AdapterError("invalid_option", "unknown varVAMP config override", {"unknown": unknown})
    if mode != "qpcr":
        qkeys = sorted(set(overrides) & QPCR_CONFIG_KEYS)
        if qkeys:
            raise AdapterError("invalid_option", "qPCR config overrides are not valid in this mode", {"keys": qkeys})
    resolved: dict[str, Any] = {}
    for key in sorted(overrides):
        resolved[key] = _validated_config_value(key, overrides[key])
    if mode == "qpcr":
        resolved["QAMPLICON_LENGTH"] = [minimum, maximum]
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# Generated by Lungfish Primer Design Adapter v1; validated literals only."]
    for key in sorted(resolved):
        value = resolved[key]
        literal = repr(tuple(value)) if isinstance(value, list) else repr(value)
        lines.append(f"{key} = {literal}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return resolved


def build_gap_projection(*, source_length: int, gaps: list[list[int]], deletion_cutoff: int) -> list[dict[str, Any]]:
    if not _is_int(source_length) or source_length < 0 or not _is_int(deletion_cutoff) or deletion_cutoff < 1:
        raise AdapterError("native_contract_mismatch", "invalid source length or gap cutoff")
    normalized = sorted((int(start), int(end)) for start, end in gaps)
    source_cursor = generated_cursor = 0
    blocks: list[dict[str, Any]] = []
    for start, inclusive_end in normalized:
        end = inclusive_end + 1
        if start < source_cursor or start < 0 or end > source_length or start >= end:
            raise AdapterError("native_contract_mismatch", "overlapping or invalid varVAMP gap intervals")
        if start > source_cursor:
            length = start - source_cursor
            blocks.append({
                "generatedStart": generated_cursor, "generatedEnd": generated_cursor + length,
                "sourceStart": source_cursor, "sourceEnd": start, "kind": "mapped",
            })
            generated_cursor += length
        collapsed_length = 2 if end - start >= deletion_cutoff else 1
        blocks.append({
            "generatedStart": generated_cursor, "generatedEnd": generated_cursor + collapsed_length,
            "sourceStart": start, "sourceEnd": end, "kind": "collapsed",
        })
        generated_cursor += collapsed_length
        source_cursor = end
    if source_cursor < source_length:
        length = source_length - source_cursor
        blocks.append({
            "generatedStart": generated_cursor, "generatedEnd": generated_cursor + length,
            "sourceStart": source_cursor, "sourceEnd": source_length, "kind": "mapped",
        })
    return blocks


def _read_single_fasta(path: Path) -> tuple[str, str]:
    identifier = None
    sequence: list[str] = []
    records = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith(">"):
            records += 1
            if records > 1:
                raise AdapterError("native_contract_mismatch", f"generated reference contains multiple records: {path}")
            identifier = line[1:].split()[0]
        else:
            if identifier is None:
                raise AdapterError("native_contract_mismatch", f"invalid FASTA: {path}")
            sequence.append(line)
    if records != 1 or not sequence:
        raise AdapterError("native_contract_mismatch", f"invalid generated FASTA: {path}")
    return identifier, "".join(sequence).upper()


def _read_bed(path: Path) -> dict[str, dict[str, Any]]:
    records = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            fields = raw.rstrip("\n").split("\t")
            if len(fields) < 6:
                raise AdapterError("native_contract_mismatch", f"invalid varVAMP BED row {line_number}")
            name = fields[3]
            if name in records:
                raise AdapterError("native_contract_mismatch", f"duplicate varVAMP BED oligo {name}")
            records[name] = {
                "reference": fields[0], "start": int(fields[1]), "end": int(fields[2]),
                "name": name, "score": fields[4], "strand": fields[5],
                "sequence": fields[6].upper() if len(fields) > 6 else None,
            }
    return records


def _metadata(row: dict[str, str], excluded: set[str]) -> dict[str, Any]:
    return {key: value for key, value in row.items() if key not in excluded}


def normalize_varvamp_outputs(
    native_dir: Path,
    *,
    mode: str,
    source_input_id: str,
    target_id: str,
    label: str,
    reference_path: str,
    minimum: int,
    maximum: int,
    binding_projection_path: str = "mappings/projection.json",
) -> dict[str, Any]:
    reference_file = native_dir / "ambiguous_consensus.fasta"
    reference_id, reference_sequence = _read_single_fasta(reference_file)
    oligo_bed = _read_bed(native_dir / "primers.bed")
    amplicon_bed = _read_bed(native_dir / "amplicons.bed")
    assays: list[dict[str, Any]] = []
    oligos: list[dict[str, Any]] = []
    if mode == "qpcr":
        table_path = native_dir / "qpcr_primers.tsv"
        group_field = "qpcr_scheme"
        role_field = "oligo_type"
    else:
        table_path = native_dir / "primers.tsv"
        group_field = "amlicon_name"
        role_field = "primer_name"
    with table_path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    groups: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        groups.setdefault(row[group_field], []).append(row)
    if not groups:
        raise AdapterError("no_feasible_design", "varVAMP produced no assays", {"target": label})
    ordered_names = sorted(groups, key=lambda name: (amplicon_bed.get(name, {}).get("start", 0), name))
    for rank, assay_name in enumerate(ordered_names, 1):
        amp = amplicon_bed.get(assay_name)
        if amp is None:
            raise AdapterError("native_contract_mismatch", f"missing varVAMP amplicon BED row for {assay_name}")
        start, end = amp["start"], amp["end"]
        if not accept_pair_length(end - start, minimum=minimum, maximum=maximum):
            raise AdapterError(
                "native_contract_mismatch", "varVAMP final assay violates requested span bounds",
                {"ampliconID": assay_name, "length": end - start, "minimum": minimum, "maximum": maximum},
            )
        assay_id = deterministic_id(target_id, "assay", assay_name)
        member_ids = []
        pool: str | None = None if mode in {"single", "qpcr"} else str(amp["score"])
        for row in groups[assay_name]:
            if mode == "qpcr":
                native_role = row[role_field]
                native_name = f"{assay_name}_{native_role}"
            else:
                native_name = row[role_field]
                native_role = "LEFT" if native_name.endswith("_LEFT") else "RIGHT" if native_name.endswith("_RIGHT") else ""
            role = {"LEFT": "forward", "RIGHT": "reverse", "PROBE": "probe"}.get(native_role)
            if role is None:
                raise AdapterError("native_contract_mismatch", f"unknown native oligo role {native_role!r}")
            native = oligo_bed.get(native_name)
            if native is None:
                raise AdapterError("native_contract_mismatch", f"missing varVAMP primer BED row for {native_name}")
            tsv_start, tsv_end = int(row["start"]) - 1, int(row["stop"])
            sequence = row["seq"].upper()
            if (native["start"], native["end"], native["sequence"]) != (tsv_start, tsv_end, sequence):
                raise AdapterError("native_contract_mismatch", "varVAMP TSV/BED coordinates or sequences disagree")
            oligo_id = deterministic_id(target_id, "oligo", native_name)
            member_ids.append(oligo_id)
            oligos.append({
                "id": oligo_id,
                "name": native_name,
                "role": role,
                "sequence": sequence,
                "start": tsv_start,
                "end": tsv_end,
                "strand": native["strand"],
                "assayIDs": [assay_id],
                "pool": pool,
                "nativeMetadata": _metadata(row, {group_field, role_field, "start", "stop", "seq"}),
            })
        expected_roles = {"forward", "reverse", "probe"} if mode == "qpcr" else {"forward", "reverse"}
        actual_roles = {oligo["role"] for oligo in oligos if oligo["id"] in member_ids}
        if actual_roles != expected_roles:
            raise AdapterError("native_contract_mismatch", f"{assay_name} has incorrect oligo roles")
        assays.append({
            "id": assay_id,
            "start": start,
            "end": end,
            "memberIDs": member_ids,
            "pool": pool,
            "status": "selected" if mode != "qpcr" or rank == 1 else "alternative",
            "rank": rank,
            "nativeMetadata": {"ampliconID": assay_name, "nativeScore": amp["score"]},
        })
    target = {
        "id": target_id,
        "label": label,
        "referencePath": reference_path,
        "referenceID": reference_id,
        "referenceLength": len(reference_sequence),
        "sourceInputID": source_input_id,
        "bindingProjectionPath": binding_projection_path,
        "assays": assays,
        "oligos": oligos,
    }
    validate_target_contract(target)
    return target


def _read_alignment_length(path: Path) -> int:
    lengths = []
    current: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith(">"):
            if current:
                lengths.append(len("".join(current)))
                current = []
        else:
            current.append(line)
    if current:
        lengths.append(len("".join(current)))
    if not lengths or len(set(lengths)) != 1:
        raise AdapterError("invalid_request", "varVAMP inputs must be nonempty equal-length FASTA alignments")
    return lengths[0]


def _spawn_read_qamplicon(queue):
    try:
        from varvamp.scripts import config
        queue.put(list(config.QAMPLICON_LENGTH))
    except BaseException as error:
        queue.put({"error": repr(error)})


def spawned_config_probe(config_path: Path) -> list[int]:
    previous = os.environ.get("VARVAMP_CONFIG")
    os.environ["VARVAMP_CONFIG"] = str(config_path.resolve())
    try:
        context = multiprocessing.get_context("spawn")
        queue = context.Queue()
        process = context.Process(target=_spawn_read_qamplicon, args=(queue,))
        process.start()
        process.join(30)
        if process.is_alive():
            process.terminate()
            process.join()
            raise AdapterError("runtime_verification_failed", "spawned varVAMP config probe timed out")
        if process.exitcode != 0:
            raise AdapterError("runtime_verification_failed", "spawned varVAMP config probe failed", {"exitStatus": process.exitcode})
        value = queue.get(timeout=5)
        if isinstance(value, dict):
            raise AdapterError("runtime_verification_failed", "spawned varVAMP config probe failed", value)
        return value
    finally:
        if previous is None:
            os.environ.pop("VARVAMP_CONFIG", None)
        else:
            os.environ["VARVAMP_CONFIG"] = previous


def run_varvamp(
    request: dict[str, Any], stage: Path, recorder: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any], list[list[str]], dict[str, str], dict[str, Any]]:
    recorder = recorder if recorder is not None else {"runtime": None, "nativeInvocations": [], "nativeEvents": []}
    options = request["options"]
    all_targets = []
    native_invocations: list[list[str]] = recorder.setdefault("nativeInvocations", [])
    recorded_environment: dict[str, str] = {}
    runtime: dict[str, Any] | None = None
    effective_thresholds: dict[str, float] = {}
    effective_configs: dict[str, dict[str, Any]] = {}
    for item in request["inputs"]:
        input_id = item["id"]
        native_dir = stage / "native" / input_id
        config_path = stage / "config" / input_id / "varvamp-config.py"
        with native_event(
            recorder, engine="varvamp", kind="adapterTransform", module="varvamp_adapter",
            function="generate_varvamp_config",
            arguments={
                "path": str(config_path), "mode": request["mode"],
                "minimum": options["minimumAmpliconLength"], "maximum": options["maximumAmpliconLength"],
                "overrides": options["configOverrides"],
            },
            module_path=str(Path(__file__).resolve()),
        ) as event:
            resolved_config = generate_varvamp_config(
                config_path,
                mode=request["mode"],
                minimum=options["minimumAmpliconLength"],
                maximum=options["maximumAmpliconLength"],
                overrides=options["configOverrides"],
            )
            event["result"] = {"path": str(config_path), "resolvedAssignments": resolved_config}
        effective_configs[input_id] = resolved_config
        config_path = config_path.resolve()
        previous_config = os.environ.get("VARVAMP_CONFIG")
        os.environ["VARVAMP_CONFIG"] = str(config_path)
        recorded_environment["VARVAMP_CONFIG"] = str(config_path)
        try:
            # Import only after VARVAMP_CONFIG is set. Each adapter process runs
            # one request, so all independent invocations share identical config.
            with native_event(
                recorder, engine="varvamp", kind="runtimeVerification", module="varvamp_adapter",
                function="verify_runtime", arguments={"engineVersion": ENGINE_VERSION, "sourceHashes": SOURCE_HASHES},
                module_path=str(Path(__file__).resolve()),
            ) as event:
                runtime = verify_runtime()
                recorder["runtime"] = runtime
                event["result"] = {"distribution": runtime["distribution"], "modulePath": runtime["modulePath"]}
            command = runtime["modules"]["command"]
            alignment_module = runtime["modules"]["alignment"]
            captured: dict[str, Any] = {}
            original_process_alignment = alignment_module.process_alignment

            def recording_process_alignment(preprocessed_alignment, threshold):
                cleaned, gaps = original_process_alignment(preprocessed_alignment, threshold)
                captured["gaps"] = [list(interval) for interval in gaps]
                captured["cleaned"] = cleaned
                captured["threshold"] = threshold
                return cleaned, gaps

            alignment_module.process_alignment = recording_process_alignment
            argv = [
                "varvamp", request["mode"],
                "-a", str(options["maximumPrimerAmbiguities"]),
                "-th", str(options["workers"]),
                "--name", options["schemeName"],
            ]
            threshold = options["cumulativeConsensusThreshold"]
            if threshold is not None:
                argv += ["-t", str(threshold)]
            if options["blastDatabasePath"] is not None:
                argv += ["-db", options["blastDatabasePath"]]
            if options["compatiblePrimersPath"] is not None:
                argv += ["--compatible-primers", options["compatiblePrimersPath"]]
            if request["mode"] in {"single", "tiled"}:
                argv += [
                    "-ol", str(options["minimumAmpliconLength"]),
                    "-ml", str(options["maximumAmpliconLength"]),
                ]
            if request["mode"] == "single" and options["reportCount"] is not None:
                argv += ["-n", str(options["reportCount"])]
            if request["mode"] == "tiled":
                argv += ["-o", str(options["tiledOverlap"])]
            if request["mode"] == "qpcr":
                if options["maximumProbeAmbiguities"] is not None:
                    argv += ["-pa", str(options["maximumProbeAmbiguities"])]
                argv += ["-n", str(options["qpcrTestCount"]), "-d", str(options["qpcrDeltaG"])]
            argv += [item["path"], str(native_dir)]
            replay_argv = [sys.executable, "-m", "varvamp", *argv[1:]]
            native_invocations.append(replay_argv)
            old_argv = sys.argv
            try:
                with native_event(
                    recorder, engine="varvamp", kind="inProcessCLI", module="varvamp.command",
                    function="main",
                    arguments={
                        "argv": argv,
                        "replayArgv": replay_argv,
                        "environment": {"VARVAMP_CONFIG": str(config_path)},
                    },
                    module_path=str(Path(command.__file__).resolve()),
                ) as event:
                    event["adapterContext"] = {"inputID": input_id, "mode": request["mode"], "grouping": "perInput"}
                    sys.argv = argv
                    command.main()
            finally:
                sys.argv = old_argv
                alignment_module.process_alignment = original_process_alignment
        finally:
            if previous_config is None:
                os.environ.pop("VARVAMP_CONFIG", None)
            else:
                os.environ["VARVAMP_CONFIG"] = previous_config
        if "gaps" not in captured:
            raise AdapterError("native_contract_mismatch", "varVAMP process_alignment interception did not run")
        effective_thresholds[input_id] = float(captured["threshold"])
        source_length = _read_alignment_length(Path(item["path"]))
        deletion_cutoff = resolved_config.get("QAMPLICON_DEL_CUTOFF", CONFIG_SPECS["QAMPLICON_DEL_CUTOFF"][2])
        blocks = build_gap_projection(source_length=source_length, gaps=captured["gaps"], deletion_cutoff=deletion_cutoff)
        reference_relative = (native_dir / "ambiguous_consensus.fasta").relative_to(stage).as_posix()
        _, generated_sequence = _read_single_fasta(native_dir / "ambiguous_consensus.fasta")
        if blocks and blocks[-1]["generatedEnd"] != len(generated_sequence):
            raise AdapterError("native_contract_mismatch", "captured varVAMP gap map length differs from cleaned consensus")
        map_relative = f"mappings/{input_id}.json"
        write_json(stage / map_relative, {
            "schemaVersion": 1,
            "coordinateConvention": "zeroBasedHalfOpen",
            "sourceInputID": input_id,
            "sourcePath": item["path"],
            "generatedReferencePath": reference_relative,
            "sourceLength": source_length,
            "generatedLength": len(generated_sequence),
            "blocks": blocks,
        })
        target_id = deterministic_id(request["resultID"], "target", input_id)
        all_targets.append(normalize_varvamp_outputs(
            native_dir,
            mode=request["mode"],
            source_input_id=input_id,
            target_id=target_id,
            label=item["label"],
            reference_path=reference_relative,
            minimum=options["minimumAmpliconLength"],
            maximum=options["maximumAmpliconLength"],
            binding_projection_path=map_relative,
        ))
    results = [
        {"id": deterministic_id(request["resultID"], "result", target["sourceInputID"]), "inputIDs": [target["sourceInputID"]], "targets": [target]}
        for target in all_targets
    ]
    assert runtime is not None
    engine_resolution = {
        "nativeCumulativeConsensusThresholds": effective_thresholds,
        "generatedConfigOverridesByInput": effective_configs,
        "nominalAmpliconLengthRole": "displayAndProvenanceOnly",
        "minimumAmpliconLengthNativeRole": "optLength" if request["mode"] in {"single", "tiled"} else "QAMPLICON_LENGTH.minimum",
        "maximumAmpliconLengthNativeRole": "maxLength" if request["mode"] in {"single", "tiled"} else "QAMPLICON_LENGTH.maximum",
    }
    return results, runtime, native_invocations, recorded_environment, engine_resolution

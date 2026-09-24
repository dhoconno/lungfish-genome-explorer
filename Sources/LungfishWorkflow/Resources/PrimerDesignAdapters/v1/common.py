"""Shared validation, artifact, and provenance helpers for adapter schema v1."""

from __future__ import annotations

import hashlib
import json
import math
import numbers
import os
from pathlib import Path, PurePosixPath
import platform
import shlex
import sys
import time
from typing import Any
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone


SCHEMA_VERSION = 1
ADAPTER_VERSION = "1.0.0"


class AdapterError(Exception):
    """A stable machine-readable adapter failure."""

    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}

    def payload(self, engine: str | None = None, provenance_path: str | None = None) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "schemaVersion": SCHEMA_VERSION,
            "adapterVersion": ADAPTER_VERSION,
            "engine": engine,
            "error": {"code": self.code, "message": self.message, "details": _json_primitive(self.details)},
        }
        if provenance_path is not None:
            payload["provenancePath"] = provenance_path
        return payload


REQUEST_KEYS = {
    "schemaVersion", "engine", "engineVersion", "analysisID", "runID", "resultID",
    "mode", "grouping", "inputs", "outputDirectory", "options",
}
INPUT_KEYS = {"id", "label", "path"}
COMMON_OPTION_KEYS = {
    "nominalAmpliconLength", "minimumAmpliconLength", "maximumAmpliconLength", "workers",
}
OLIVAR_DEFAULTS: dict[str, Any] = {
    "minimumVariantFrequency": 0.01,
    "degenerate": False,
    "align": False,
    "temperatureC": 60.0,
    "salinityM": 0.18,
    "maximumDimerDeltaG": -11.8,
    "minimumGC": 0.2,
    "maximumGC": 0.75,
    "minimumComplexity": 0.4,
    "maximumPrimerLength": 36,
    "checkVariants": False,
    "seed": 10,
    "effort": 1,
    "forwardPrefix": "",
    "reversePrefix": "",
    "blastDatabasePath": None,
    "riskWeights": {
        "extremeGC": 1.0,
        "lowComplexity": 1.0,
        "nonSpecificity": 1.0,
        "variation": 1.0,
        "sensitivity": 1.0,
        "combination": 1.0,
    },
}
VARVAMP_DEFAULTS: dict[str, Any] = {
    "cumulativeConsensusThreshold": None,
    "maximumPrimerAmbiguities": 2,
    "maximumProbeAmbiguities": None,
    "tiledOverlap": 25,
    "reportCount": None,
    "qpcrTestCount": 50,
    "qpcrDeltaG": -3,
    "schemeName": "varVAMP",
    "compatiblePrimersPath": None,
    "blastDatabasePath": None,
    "configOverrides": {},
}
RISK_WEIGHT_KEYS = {
    "extremeGC", "lowComplexity", "nonSpecificity", "variation", "sensitivity", "combination",
}
VARVAMP_CONFIG_OVERRIDE_KEYS = {
    "TERMINAL_MASKING_THRESHOLD", "PRIMER_TMP", "PRIMER_GC_RANGE", "PRIMER_SIZES",
    "PRIMER_MAX_POLYX", "PRIMER_MAX_DINUC_REPEATS", "PRIMER_HAIRPIN", "PRIMER_GC_END",
    "PRIMER_MIN_3_WITHOUT_AMB", "PRIMER_MAX_DIMER_TMP", "PRIMER_MAX_DIMER_DELTAG",
    "END_OVERLAP", "QPROBE_TMP", "QPROBE_SIZES", "QPROBE_GC_RANGE", "QPROBE_GC_END",
    "QPRIMER_DIFF", "QPROBE_TEMP_DIFF", "QPROBE_DISTANCE", "QAMPLICON_GC",
    "QAMPLICON_DEL_CUTOFF", "PCR_MV_CONC", "PCR_DV_CONC", "PCR_DNTP_CONC", "PCR_DNA_CONC",
}


def accept_pair_length(length: int, *, minimum: int, maximum: int) -> bool:
    if not _is_int(minimum) or not _is_int(maximum) or minimum > maximum:
        raise AdapterError(
            "invalid_amplicon_range",
            "minimum amplicon length must be less than or equal to maximum",
            {"minimum": minimum, "maximum": maximum},
        )
    if not _is_int(length):
        raise AdapterError("invalid_amplicon_length", "amplicon length must be an integer", {"length": length})
    return minimum <= int(length) <= maximum


def _is_int(value: Any) -> bool:
    return isinstance(value, numbers.Integral) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, numbers.Real) and not isinstance(value, bool) and math.isfinite(value)


def _json_primitive(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool)):
        return value
    if isinstance(value, numbers.Integral):
        return int(value)
    if isinstance(value, numbers.Real):
        return float(value)
    if isinstance(value, dict):
        return {str(key): _json_primitive(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_primitive(item) for item in value]
    if isinstance(value, Path):
        return str(value)
    return repr(value)


def _require_keys(value: dict[str, Any], allowed: set[str], required: set[str], where: str) -> None:
    unknown = sorted(set(value) - allowed)
    missing = sorted(required - set(value))
    if unknown or missing:
        raise AdapterError(
            "invalid_request",
            f"invalid keys in {where}",
            {"unknown": unknown, "missing": missing},
        )


def _validate_uuid(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise AdapterError("invalid_request", f"{name} must be a UUID string")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        raise AdapterError("invalid_request", f"{name} must be a UUID string") from None
    if str(parsed) != value:
        raise AdapterError("invalid_request", f"{name} must use canonical lowercase UUID spelling")
    return value


def _validate_finite_tree(value: Any, path: str = "options") -> None:
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return
    if isinstance(value, (int, float)):
        if not math.isfinite(value):
            raise AdapterError("invalid_option", f"{path} must be finite")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_finite_tree(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            _validate_finite_tree(item, f"{path}.{key}")
        return
    raise AdapterError("invalid_option", f"{path} has an unsupported value type")


def _validate_absolute_regular_file(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value:
        raise AdapterError("invalid_request", f"{name} must be an absolute file path")
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise AdapterError("invalid_request", f"{name} must be an existing absolute non-symlink regular file")
    return str(path)


def _validate_optional_file(value: Any, name: str) -> str | None:
    if value is None:
        return None
    return _validate_absolute_regular_file(value, name)


_BLAST_NUCLEOTIDE_COMPONENT_SUFFIXES = {
    "ndb", "nhr", "nin", "nog", "nos", "not", "nsq", "ntf", "nto", "njs",
}
_BLAST_REQUIRED_COMPONENT_SUFFIXES = {"nhr", "nin", "nsq"}


def blast_database_components(prefix: Path) -> list[Path]:
    """Return a safe materialized nucleotide BLAST database component set."""
    if not prefix.is_absolute() or prefix.is_symlink() or prefix.parent.is_symlink() or not prefix.parent.is_dir():
        raise AdapterError("invalid_option", "BLAST database prefix must have an existing absolute non-symlink parent")
    alias = Path(str(prefix) + ".nal")
    if prefix.suffix == ".nal" or alias.exists() or alias.is_symlink():
        raise AdapterError(
            "unsupported_blast_alias",
            "BLAST alias databases are not supported; select a materialized nucleotide database prefix",
            {"prefix": str(prefix), "aliasPath": str(prefix if prefix.suffix == ".nal" else alias)},
        )
    components: list[Path] = []
    groups: dict[str, set[str]] = {}
    prefix_marker = prefix.name + "."
    for candidate in sorted(prefix.parent.glob(prefix.name + ".*")):
        if not candidate.name.startswith(prefix_marker):
            continue
        tail = candidate.name[len(prefix_marker):]
        pieces = tail.split(".")
        suffix = pieces[-1]
        volume = ".".join(pieces[:-1])
        if suffix not in _BLAST_NUCLEOTIDE_COMPONENT_SUFFIXES or (volume and not all(part.isdigit() for part in pieces[:-1])):
            continue
        if candidate.is_symlink() or not candidate.is_file():
            raise AdapterError("invalid_option", "BLAST database components must be non-symlink regular files", {"path": str(candidate)})
        components.append(candidate)
        groups.setdefault(volume, set()).add(suffix)
    complete_groups = [name for name, suffixes in groups.items() if _BLAST_REQUIRED_COMPONENT_SUFFIXES <= suffixes]
    incomplete_core_groups = {
        name: sorted(suffixes & _BLAST_REQUIRED_COMPONENT_SUFFIXES)
        for name, suffixes in groups.items()
        if suffixes & _BLAST_REQUIRED_COMPONENT_SUFFIXES and not _BLAST_REQUIRED_COMPONENT_SUFFIXES <= suffixes
    }
    if not components or not complete_groups or incomplete_core_groups:
        raise AdapterError(
            "invalid_option",
            "BLAST database prefix does not identify a complete nucleotide database",
            {"prefix": str(prefix), "incompleteVolumes": incomplete_core_groups},
        )
    return components


def validate_blast_database_prefix(value: Any, name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise AdapterError("invalid_option", f"{name} must be an absolute BLAST database prefix")
    prefix = Path(value)
    blast_database_components(prefix)
    return str(prefix)


def validate_output_path(value: Any) -> Path:
    if not isinstance(value, str) or not value:
        raise AdapterError("unsafe_output_path", "outputDirectory must be an absolute path")
    path = Path(value)
    if not path.is_absolute() or path == Path(path.anchor) or path.exists() or path.is_symlink():
        raise AdapterError("unsafe_output_path", "outputDirectory must be an absolute path that does not exist")
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink():
        raise AdapterError("unsafe_output_path", "outputDirectory parent must already exist")
    return path


def _validate_common_options(options: dict[str, Any]) -> None:
    for key in ("nominalAmpliconLength", "minimumAmpliconLength", "maximumAmpliconLength", "workers"):
        if not _is_int(options.get(key)):
            raise AdapterError("invalid_option", f"{key} must be an integer")
    minimum = options["minimumAmpliconLength"]
    nominal = options["nominalAmpliconLength"]
    maximum = options["maximumAmpliconLength"]
    if minimum <= 0 or not minimum <= nominal <= maximum:
        raise AdapterError(
            "invalid_amplicon_range",
            "amplicon lengths must satisfy minimum <= nominal <= maximum and be positive",
        )
    if options["workers"] < 1:
        raise AdapterError("invalid_option", "workers must be at least 1")


def _validate_olivar_options(options: dict[str, Any]) -> None:
    if options["minimumAmpliconLength"] < 120:
        raise AdapterError("invalid_option", "Olivar minimumAmpliconLength must be at least 120")
    for key in ("minimumVariantFrequency", "minimumGC", "maximumGC"):
        if not _is_number(options[key]) or not 0 <= options[key] <= 1:
            raise AdapterError("invalid_option", f"{key} must be a finite number from 0 through 1")
    for key in ("temperatureC", "salinityM", "maximumDimerDeltaG", "minimumComplexity"):
        if not _is_number(options[key]):
            raise AdapterError("invalid_option", f"{key} must be a finite number")
    if options["minimumGC"] > options["maximumGC"]:
        raise AdapterError("invalid_option", "minimumGC cannot exceed maximumGC")
    for key in ("maximumPrimerLength", "seed", "effort"):
        if not _is_int(options[key]):
            raise AdapterError("invalid_option", f"{key} must be an integer")
    if options["maximumPrimerLength"] < 1 or options["effort"] < 1:
        raise AdapterError("invalid_option", "maximumPrimerLength and effort must be positive")
    for key in ("degenerate", "align", "checkVariants"):
        if not isinstance(options[key], bool):
            raise AdapterError("invalid_option", f"{key} must be a boolean")
    if options["align"]:
        raise AdapterError("invalid_option", "adapter v1 requires an already aligned Olivar MSA; align must be false")
    for key in ("forwardPrefix", "reversePrefix"):
        if not isinstance(options[key], str) or not set(options[key].upper()) <= set("ACGTRYSWKMBDHVN"):
            raise AdapterError("invalid_option", f"{key} must contain only IUPAC DNA bases")
    options["blastDatabasePath"] = validate_blast_database_prefix(options["blastDatabasePath"], "blastDatabasePath")
    risk = options["riskWeights"]
    if not isinstance(risk, dict) or set(risk) != RISK_WEIGHT_KEYS:
        raise AdapterError("invalid_option", "riskWeights must contain exactly the six documented keys")
    if not all(_is_number(value) and value >= 0 for value in risk.values()):
        raise AdapterError("invalid_option", "riskWeights must be finite nonnegative numbers")


def _validate_varvamp_options(options: dict[str, Any], mode: str) -> None:
    threshold = options["cumulativeConsensusThreshold"]
    if mode == "qpcr" and threshold is None:
        raise AdapterError("invalid_option", "qPCR requires cumulativeConsensusThreshold")
    if threshold is not None and (not _is_number(threshold) or not 0 < threshold <= 1):
        raise AdapterError("invalid_option", "cumulativeConsensusThreshold must be greater than 0 and at most 1")
    for key in ("maximumPrimerAmbiguities", "tiledOverlap", "qpcrTestCount"):
        if not _is_int(options[key]) or options[key] < 0:
            raise AdapterError("invalid_option", f"{key} must be a nonnegative integer")
    if options["maximumProbeAmbiguities"] is not None and (
        not _is_int(options["maximumProbeAmbiguities"]) or options["maximumProbeAmbiguities"] < 0
    ):
        raise AdapterError("invalid_option", "maximumProbeAmbiguities must be null or a nonnegative integer")
    if options["reportCount"] is not None and (not _is_int(options["reportCount"]) or options["reportCount"] < 1):
        raise AdapterError("invalid_option", "reportCount must be null or a positive integer")
    if not _is_int(options["qpcrDeltaG"]):
        raise AdapterError("invalid_option", "qpcrDeltaG must be an integer")
    if not isinstance(options["schemeName"], str) or not options["schemeName"].strip():
        raise AdapterError("invalid_option", "schemeName must be a nonempty string")
    if any(character in options["schemeName"] for character in "\r\n\t/\\"):
        raise AdapterError("invalid_option", "schemeName contains unsafe characters")
    options["compatiblePrimersPath"] = _validate_optional_file(options["compatiblePrimersPath"], "compatiblePrimersPath")
    options["blastDatabasePath"] = validate_blast_database_prefix(options["blastDatabasePath"], "blastDatabasePath")
    if not isinstance(options["configOverrides"], dict):
        raise AdapterError("invalid_option", "configOverrides must be an object")
    override_keys = set(options["configOverrides"])
    if "QAMPLICON_LENGTH" in override_keys:
        raise AdapterError("invalid_option", "QAMPLICON_LENGTH is controlled by the adapter")
    unknown_overrides = sorted(override_keys - VARVAMP_CONFIG_OVERRIDE_KEYS)
    if unknown_overrides:
        raise AdapterError("invalid_option", "unknown varVAMP config override", {"unknown": unknown_overrides})
    if mode != "qpcr":
        qpcr_overrides = sorted(key for key in override_keys if key.startswith("Q"))
        if qpcr_overrides:
            raise AdapterError("invalid_option", "qPCR config overrides are not valid in this mode", {"keys": qpcr_overrides})
    if mode != "qpcr" and options["maximumProbeAmbiguities"] is not None:
        raise AdapterError("invalid_option", "maximumProbeAmbiguities is qPCR-only")
    if mode != "single" and options["reportCount"] is not None:
        raise AdapterError("invalid_option", "reportCount is single-only")
    if mode != "tiled" and options["tiledOverlap"] != VARVAMP_DEFAULTS["tiledOverlap"]:
        raise AdapterError("invalid_option", "tiledOverlap is tiled-only")
    if mode != "qpcr" and (
        options["qpcrTestCount"] != VARVAMP_DEFAULTS["qpcrTestCount"]
        or options["qpcrDeltaG"] != VARVAMP_DEFAULTS["qpcrDeltaG"]
    ):
        raise AdapterError("invalid_option", "qpcrTestCount and qpcrDeltaG are qPCR-only")


def validate_request(request: Any) -> dict[str, Any]:
    if not isinstance(request, dict):
        raise AdapterError("invalid_request", "request must be a JSON object")
    _require_keys(request, REQUEST_KEYS, REQUEST_KEYS, "request")
    if request["schemaVersion"] != SCHEMA_VERSION:
        raise AdapterError("unsupported_schema", "unsupported request schema version")
    engine = request["engine"]
    if engine not in ("olivar", "varvamp"):
        raise AdapterError("unsupported_engine", "engine must be olivar or varvamp")
    expected_version = "1.3.3" if engine == "olivar" else "1.3.2"
    if request["engineVersion"] != expected_version:
        raise AdapterError(
            "unsupported_version", f"unsupported {engine} version {request['engineVersion']!r}",
            {"expected": expected_version},
        )
    for name in ("analysisID", "runID", "resultID"):
        _validate_uuid(request[name], name)
    modes = {"tiled"} if engine == "olivar" else {"single", "tiled", "qpcr"}
    if request["mode"] not in modes:
        raise AdapterError("invalid_mode", f"{engine} does not support mode {request['mode']!r}")
    if request["grouping"] not in {"perInput", "combined"}:
        raise AdapterError("invalid_grouping", "grouping must be perInput or combined")
    if engine == "varvamp" and request["grouping"] != "perInput":
        raise AdapterError("invalid_grouping", "varVAMP supports only perInput grouping")
    inputs = request["inputs"]
    if not isinstance(inputs, list) or not inputs:
        raise AdapterError("invalid_request", "inputs must be a nonempty array")
    seen_ids: set[str] = set()
    for index, item in enumerate(inputs):
        if not isinstance(item, dict):
            raise AdapterError("invalid_request", f"inputs[{index}] must be an object")
        _require_keys(item, INPUT_KEYS, INPUT_KEYS, f"inputs[{index}]")
        input_id = _validate_uuid(item["id"], f"inputs[{index}].id")
        if input_id in seen_ids:
            raise AdapterError("invalid_request", "input IDs must be unique")
        seen_ids.add(input_id)
        if not isinstance(item["label"], str) or not item["label"].strip():
            raise AdapterError("invalid_request", f"inputs[{index}].label must be nonempty")
        _validate_absolute_regular_file(item["path"], f"inputs[{index}].path")
    validate_output_path(request["outputDirectory"])
    supplied = request["options"]
    if not isinstance(supplied, dict):
        raise AdapterError("invalid_request", "options must be an object")
    _validate_finite_tree(supplied)
    defaults = OLIVAR_DEFAULTS if engine == "olivar" else VARVAMP_DEFAULTS
    allowed = COMMON_OPTION_KEYS | set(defaults)
    _require_keys(supplied, allowed, COMMON_OPTION_KEYS, "options")
    resolved = json.loads(json.dumps(defaults))
    for key, value in supplied.items():
        if key == "riskWeights" and isinstance(value, dict):
            resolved[key].update(value)
        else:
            resolved[key] = value
    _validate_common_options(resolved)
    if engine == "olivar":
        _validate_olivar_options(resolved)
    else:
        _validate_varvamp_options(resolved, request["mode"])
    normalized = json.loads(json.dumps(request))
    normalized["options"] = resolved
    normalized["suppliedOptions"] = json.loads(json.dumps(supplied))
    return normalized


def safe_relative_path(value: str) -> str:
    if not isinstance(value, str) or not value:
        raise AdapterError("unsafe_artifact_path", "artifact path must be nonempty")
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or ".." in candidate.parts or "." in candidate.parts:
        raise AdapterError("unsafe_artifact_path", f"artifact path escapes output: {value!r}")
    return candidate.as_posix()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_record(root: Path, path: Path, kind: str) -> dict[str, Any]:
    relative = path.relative_to(root).as_posix()
    safe_relative_path(relative)
    if path.is_symlink() or not path.is_file():
        raise AdapterError("unsafe_artifact_path", f"artifact is not a regular file: {relative}")
    return {"path": relative, "sha256": sha256_file(path), "byteSize": path.stat().st_size, "kind": kind}


def inventory_artifacts(root: Path, excluded: set[str] | None = None) -> list[dict[str, Any]]:
    excluded = excluded or set()
    records = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.relative_to(root).as_posix() not in excluded:
            relative = path.relative_to(root).as_posix()
            kind = "log" if relative.startswith("logs/") else "mapping" if relative.startswith("mappings/") else "generatedReference" if relative.startswith("generated/") else "requestSnapshot" if relative.startswith("replay/") else "configuration" if relative.endswith("varvamp-config.py") else "native"
            records.append(artifact_record(root, path, kind))
    return records


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n"
    path.write_text(encoded, encoding="utf-8")


def deterministic_id(namespace: str, *parts: str) -> str:
    return str(uuid.uuid5(uuid.UUID(namespace), "\x1f".join(parts)))


def runtime_identity(module_path: Path | None, source_verification: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "pythonExecutable": sys.executable,
        "pythonVersion": sys.version,
        "platform": platform.platform(),
        "implementation": platform.python_implementation(),
        "engineModulePath": str(module_path) if module_path else None,
        "sourceVerification": source_verification,
    }


def adapter_sha256(adapter_dir: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(adapter_dir.rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            relative = path.relative_to(adapter_dir).as_posix().encode("utf-8")
            digest.update(len(relative).to_bytes(8, "big"))
            digest.update(relative)
            data = path.read_bytes()
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
    return digest.hexdigest()


def shell_command(argv: list[str]) -> str:
    return shlex.join(argv)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@contextmanager
def native_event(
    recorder: dict[str, Any],
    *,
    engine: str,
    kind: str,
    module: str,
    function: str,
    arguments: dict[str, Any],
    module_path: str | None = None,
):
    """Append a typed event before a native call and retain its terminal state."""
    event = {
        "engine": engine,
        "kind": kind,
        "module": module,
        "function": function,
        "arguments": _json_primitive(arguments),
        "status": "attempted",
        "startedAt": _utc_now(),
        "finishedAt": None,
        "wallTimeSeconds": None,
        "exitStatus": None,
    }
    if module_path is not None:
        event["modulePath"] = module_path
    recorder.setdefault("nativeEvents", []).append(event)
    started = time.monotonic()
    try:
        yield event
    except BaseException as error:
        event.update({
            "status": "failed",
            "finishedAt": _utc_now(),
            "wallTimeSeconds": time.monotonic() - started,
            "exitStatus": 1,
            "error": {
                "type": error.__class__.__name__,
                "message": str(error),
                "code": error.code if isinstance(error, AdapterError) else None,
            },
        })
        raise
    else:
        event.update({
            "status": "succeeded",
            "finishedAt": _utc_now(),
            "wallTimeSeconds": time.monotonic() - started,
            "exitStatus": 0,
        })


def validate_target_contract(target: dict[str, Any]) -> None:
    required = {
        "id", "label", "referencePath", "referenceID", "referenceLength", "sourceInputID",
        "bindingProjectionPath", "assays", "oligos",
    }
    if set(target) != required:
        raise AdapterError("native_contract_mismatch", "normalized target has incorrect fields")
    length = target["referenceLength"]
    if not _is_int(length) or length < 1:
        raise AdapterError("native_contract_mismatch", "invalid generated reference length")
    oligos = {oligo["id"]: oligo for oligo in target["oligos"]}
    assays = {assay["id"]: assay for assay in target["assays"]}
    if len(oligos) != len(target["oligos"]) or len(assays) != len(target["assays"]):
        raise AdapterError("native_contract_mismatch", "duplicate normalized IDs")
    for assay in assays.values():
        if not (0 <= assay["start"] < assay["end"] <= length):
            raise AdapterError("native_contract_mismatch", "assay interval lies outside generated reference")
        if not assay["memberIDs"] or any(member not in oligos for member in assay["memberIDs"]):
            raise AdapterError("native_contract_mismatch", "assay references missing oligos")
        for member in assay["memberIDs"]:
            if assay["id"] not in oligos[member]["assayIDs"]:
                raise AdapterError("native_contract_mismatch", "assay/oligo membership is not reciprocal")
    for oligo in oligos.values():
        if oligo["role"] not in {"forward", "reverse", "probe"} or oligo["strand"] not in {"+", "-"}:
            raise AdapterError("native_contract_mismatch", "invalid oligo role or strand")
        if not (0 <= oligo["start"] < oligo["end"] <= length):
            raise AdapterError("native_contract_mismatch", "oligo interval lies outside generated reference")
        if not oligo["sequence"] or not set(oligo["sequence"].upper()) <= set("ACGTRYSWKMBDHVN"):
            raise AdapterError("native_contract_mismatch", "oligo sequence is not IUPAC DNA")
        if not oligo["assayIDs"] or any(assay_id not in assays for assay_id in oligo["assayIDs"]):
            raise AdapterError("native_contract_mismatch", "oligo references missing assays")
        for assay_id in oligo["assayIDs"]:
            if oligo["id"] not in assays[assay_id]["memberIDs"]:
                raise AdapterError("native_contract_mismatch", "assay/oligo membership is not reciprocal")

#!/usr/bin/env python3
"""Lungfish pinned primer-design adapter entry point (schema v1)."""

from __future__ import annotations

import argparse
import contextlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import traceback
from typing import Any

sys.dont_write_bytecode = True

from common import (
    ADAPTER_VERSION,
    AdapterError,
    adapter_sha256,
    artifact_record,
    inventory_artifacts,
    runtime_identity,
    sha256_file,
    shell_command,
    validate_request,
    write_json,
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _strict_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"non-finite JSON number {value}")))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise AdapterError("invalid_request", f"cannot read strict JSON request: {error}") from error


def _input_records(request: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "id": item["id"],
            "path": item["path"],
            "sha256": sha256_file(Path(item["path"])),
            "byteSize": Path(item["path"]).stat().st_size,
        }
        for item in request["inputs"]
    ]


def _serializable_runtime(runtime: dict[str, Any] | None) -> dict[str, Any]:
    if runtime is None:
        return runtime_identity(None, [])
    identity = runtime_identity(
        Path(runtime["modulePath"]),
        runtime["sourceVerification"],
    )
    identity.update({
        "environmentPrefix": runtime["environmentPrefix"],
        "distribution": runtime["distribution"],
        "condaPackageRecord": runtime["condaPackageRecord"],
    })
    return identity


def _provenance(
    *,
    request: dict[str, Any],
    request_path: Path,
    stage: Path,
    started_at: str,
    finished_at: str,
    wall_time: float,
    exit_status: int,
    runtime: dict[str, Any] | None,
    outputs: list[dict[str, Any]],
    native_invocations: list[list[str]],
    environment: dict[str, str],
) -> dict[str, Any]:
    adapter_dir = Path(__file__).resolve().parent
    argv = [sys.executable, str(Path(__file__).resolve()), "--request", str(request_path)]
    return {
        "schemaVersion": 1,
        "adapterVersion": ADAPTER_VERSION,
        "adapterSHA256": adapter_sha256(adapter_dir),
        "engine": request["engine"],
        "engineVersion": request["engineVersion"],
        "analysisID": request["analysisID"],
        "runID": request["runID"],
        "resultID": request["resultID"],
        "command": {
            "executable": sys.executable,
            "argv": argv,
            "replayCommand": shell_command(argv),
            "workingDirectory": str(stage),
            "environment": dict(sorted(environment.items())),
            "nativeInvocations": native_invocations,
        },
        "settings": {
            "supplied": request.get("suppliedOptions", request["options"]),
            "resolved": request["options"],
        },
        "runtime": _serializable_runtime(runtime),
        "inputs": _input_records(request),
        "outputs": outputs,
        "startedAt": started_at,
        "finishedAt": finished_at,
        "wallTimeSeconds": wall_time,
        "exitStatus": exit_status,
        "stdoutPath": "logs/native-stdout.txt",
        "stderrPath": "logs/native-stderr.txt",
    }


def _copy_failure_logs(stage: Path) -> None:
    logs = stage / "logs"
    logs.mkdir(exist_ok=True)
    index = 0
    native = stage / "native"
    if native.exists():
        for source in sorted(native.rglob("*log*")):
            if source.is_file():
                index += 1
                destination = logs / f"native-failure-{index}-{source.name}"
                shutil.copy2(source, destination)


def _classify_exception(error: BaseException) -> AdapterError:
    if isinstance(error, AdapterError):
        return error
    message = str(error)
    lowered = message.lower()
    if isinstance(error, SystemExit) and any(token in lowered for token in ("no primer", "no amplicon", "no qpcr", "no qPCR", "no regions", "no primer regions")):
        return AdapterError("no_feasible_design", message or "native engine found no feasible design")
    return AdapterError(
        "native_execution_failed",
        message or error.__class__.__name__,
        {"exceptionType": error.__class__.__name__},
    )


def _controlled_environment(stage: Path) -> tuple[dict[str, str], dict[str, str | None]]:
    cache = stage / "cache"
    (cache / "matplotlib").mkdir(parents=True)
    (cache / "xdg").mkdir()
    (cache / "tmp").mkdir()
    environment_prefix = Path(sys.executable).resolve().parent.parent
    values = {
        "PYTHONDONTWRITEBYTECODE": "1",
        "MPLBACKEND": "Agg",
        "MPLCONFIGDIR": str(cache / "matplotlib"),
        "XDG_CACHE_HOME": str(cache / "xdg"),
        "TMPDIR": str(cache / "tmp"),
        "PATH": str(environment_prefix / "bin") + os.pathsep + os.environ.get("PATH", ""),
    }
    mafft_binaries = environment_prefix / "libexec" / "mafft"
    if mafft_binaries.is_dir():
        values["MAFFT_BINARIES"] = str(mafft_binaries)
    previous = {key: os.environ.get(key) for key in values}
    os.environ.update(values)
    return values, previous


def _restore_environment(previous: dict[str, str | None]) -> None:
    for key, value in previous.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


def execute(request_path: Path) -> Path:
    raw = _strict_json(request_path)
    request = validate_request(raw)
    output = Path(request["outputDirectory"])
    stage = Path(tempfile.mkdtemp(prefix=f".{output.name}.adapter-stage-", dir=output.parent))
    os.chmod(stage, 0o700)
    logs = stage / "logs"
    logs.mkdir()
    stdout_path = logs / "native-stdout.txt"
    stderr_path = logs / "native-stderr.txt"
    started_at = _utc_now()
    start = time.monotonic()
    runtime = None
    native_invocations: list[list[str]] = []
    environment, previous_environment = _controlled_environment(stage)
    try:
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                if request["engine"] == "olivar":
                    from olivar_adapter import run_olivar
                    results, runtime, resolution = run_olivar(request, stage)
                    native_invocations = [[
                        sys.executable, "<olivar-in-process>", "build+tiling",
                        "--min-amp-len", str(request["options"]["minimumAmpliconLength"]),
                        "--max-amp-len", str(request["options"]["maximumAmpliconLength"]),
                        "--seed", str(request["options"]["seed"]),
                    ]]
                    request["options"]["adapterResolution"] = resolution
                else:
                    from varvamp_adapter import run_varvamp
                    results, runtime, native_invocations, engine_environment, resolution = run_varvamp(request, stage)
                    environment.update(engine_environment)
                    request["options"]["adapterResolution"] = resolution
        shutil.rmtree(stage / "cache", ignore_errors=True)
        artifacts = inventory_artifacts(stage, {"adapter-result-v1.json", "provenance-v1.json"})
        finished_at = _utc_now()
        wall_time = time.monotonic() - start
        provenance = _provenance(
            request=request,
            request_path=request_path,
            stage=stage,
            started_at=started_at,
            finished_at=finished_at,
            wall_time=wall_time,
            exit_status=0,
            runtime=runtime,
            outputs=artifacts,
            native_invocations=native_invocations,
            environment=environment,
        )
        result = {
            "schemaVersion": 1,
            "analysisID": request["analysisID"],
            "runID": request["runID"],
            "resultID": request["resultID"],
            "engine": request["engine"],
            "engineVersion": request["engineVersion"],
            "adapterVersion": ADAPTER_VERSION,
            "mode": request["mode"],
            "resolvedOptions": request["options"],
            "results": results,
            "artifacts": artifacts,
            "provenancePath": "provenance-v1.json",
        }
        write_json(stage / "provenance-v1.json", provenance)
        write_json(stage / "adapter-result-v1.json", result)
        os.replace(stage, output)
        _restore_environment(previous_environment)
        return output
    except BaseException as raw_error:
        error = _classify_exception(raw_error)
        _copy_failure_logs(stage)
        # Partial scientific outputs are not published as a result. Preserve
        # their native logs, then remove incomplete payloads and maps.
        for name in ("native", "generated", "mappings"):
            path = stage / name
            if path.exists():
                shutil.rmtree(path)
        shutil.rmtree(stage / "cache", ignore_errors=True)
        with stderr_path.open("a", encoding="utf-8") as stderr:
            stderr.write("\n" + "".join(traceback.format_exception(raw_error)))
        finished_at = _utc_now()
        wall_time = time.monotonic() - start
        artifacts = inventory_artifacts(stage, {"adapter-error-v1.json", "provenance-v1.json"})
        provenance = _provenance(
            request=request,
            request_path=request_path,
            stage=stage,
            started_at=started_at,
            finished_at=finished_at,
            wall_time=wall_time,
            exit_status=1,
            runtime=runtime,
            outputs=artifacts,
            native_invocations=native_invocations,
            environment=environment,
        )
        write_json(stage / "provenance-v1.json", provenance)
        write_json(stage / "adapter-error-v1.json", error.payload(request["engine"], "provenance-v1.json"))
        if not output.exists():
            os.replace(stage, output)
        else:
            shutil.rmtree(stage, ignore_errors=True)
        _restore_environment(previous_environment)
        raise error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True, type=Path)
    args = parser.parse_args(argv)
    request_path = args.request
    if not request_path.is_absolute():
        payload = AdapterError("invalid_request", "--request must be an absolute path").payload()
        print(json.dumps(payload, sort_keys=True), file=sys.stderr, flush=True)
        return 2
    try:
        output = execute(request_path)
        print(json.dumps({"schemaVersion": 1, "resultPath": str(output / "adapter-result-v1.json")}, sort_keys=True), flush=True)
        return 0
    except AdapterError as error:
        payload = error.payload()
        try:
            raw = _strict_json(request_path)
            if isinstance(raw, dict):
                payload["engine"] = raw.get("engine")
                output_value = raw.get("outputDirectory")
                if isinstance(output_value, str):
                    error_path = Path(output_value) / "adapter-error-v1.json"
                    if error_path.is_file():
                        payload = json.loads(error_path.read_text(encoding="utf-8"))
        except AdapterError:
            pass
        print(json.dumps(payload, sort_keys=True), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

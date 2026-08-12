#!/usr/bin/env python3
"""Generate the small, wholly synthetic BAM fixture used by full-viewer tests."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path


SCRIPT_VERSION = "1.0.0"
SCRIPT_PATH = "scripts/testing/generate-classifier-full-viewer-fixture.py"
DEFAULT_OUTPUT = Path("Tests/Fixtures/classifier-full-viewer")
CONTIG_NAME = "synthetic-track-A"
CONTIG_LENGTH = 120
EXCLUDE_FLAGS = 0xD04
PAYLOAD_NAMES = ("source.sam", "evidence.bam", "evidence.bam.bai")


def main(raw_arguments: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if raw_arguments is None else raw_arguments)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--samtools",
        help="samtools executable (defaults to a managed installation when available)",
    )
    args = parser.parse_args(arguments)

    started = time.monotonic()
    repo_root = Path(__file__).resolve().parents[2]
    output_dir = resolve_repo_path(repo_root, args.output_dir)
    output_relative = output_dir.relative_to(repo_root).as_posix()
    output_dir.mkdir(parents=True, exist_ok=True)
    clear_previous_outputs(output_dir)

    executed_argv = ["python3", SCRIPT_PATH, *arguments]
    invocations: list[dict[str, object]] = []
    runtime = base_runtime_identity()
    exit_status = 0
    failure_message = ""

    try:
        source_sam = output_dir / "source.sam"
        source_sam.write_text(source_sam_text(), encoding="utf-8")
        samtools = resolve_samtools(args.samtools)
        runtime.update(samtools_runtime_identity(samtools))

        version, version_invocation = query_samtools_version(samtools)
        invocations.append(version_invocation)
        require_success(version_invocation)

        view_invocation = run_samtools(
            samtools,
            ["view", "--no-PG", "-b", "-o", "evidence.bam", "source.sam"],
            output_dir,
            "view",
            version,
        )
        invocations.append(view_invocation)
        require_success(view_invocation)

        index_invocation = run_samtools(
            samtools,
            ["index", "evidence.bam", "evidence.bam.bai"],
            output_dir,
            "index",
            version,
        )
        invocations.append(index_invocation)
        require_success(index_invocation)
    except (OSError, RuntimeError) as error:
        exit_status = error.exit_status if isinstance(error, ToolFailure) else 1
        failure_message = str(error)

    payloads = existing_payload_records(output_dir)
    input_record = next((item for item in payloads if item["path"] == "source.sam"), None)
    provenance = build_provenance(
        output_relative=output_relative,
        arguments=arguments,
        executed_argv=executed_argv,
        requested_samtools=args.samtools,
        runtime=runtime,
        payloads=payloads,
        input_record=input_record,
        invocations=invocations,
        exit_status=exit_status,
        wall_time=round(time.monotonic() - started, 6),
        stderr=failure_message,
    )
    (output_dir / ".lungfish-provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    if exit_status != 0:
        print(failure_message, file=sys.stderr)
        return exit_status
    print(output_relative)
    return 0


class ToolFailure(RuntimeError):
    def __init__(self, invocation: dict[str, object]):
        self.exit_status = int(invocation["exitStatus"])
        command = str(invocation["reproducibleCommand"])
        stderr = str(invocation["stderr"]).strip()
        super().__init__(f"{command} failed with exit status {self.exit_status}: {stderr}")


def build_provenance(
    *,
    output_relative: str,
    arguments: list[str],
    executed_argv: list[str],
    requested_samtools: str | None,
    runtime: dict[str, object],
    payloads: list[dict[str, object]],
    input_record: dict[str, object] | None,
    invocations: list[dict[str, object]],
    exit_status: int,
    wall_time: float,
    stderr: str,
) -> dict[str, object]:
    reproducible_argv = [
        "python3",
        SCRIPT_PATH,
        "--output-dir",
        output_relative,
    ]
    record: dict[str, object] = {
        "schemaVersion": 1,
        "workflowName": "classifier-full-bam-viewer-fixture-generation",
        "toolName": "generate-classifier-full-viewer-fixture.py",
        "toolVersion": SCRIPT_VERSION,
        "createdAt": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "argv": executed_argv,
        "executedShellCommand": shlex.join(executed_argv),
        "reproducibleCommand": shlex.join(reproducible_argv),
        "reproducibleShellCommand": shlex.join(reproducible_argv),
        "options": {
            "syntheticData": True,
            "contigName": CONTIG_NAME,
            "contigLength": CONTIG_LENGTH,
            "excludeFlags": EXCLUDE_FLAGS,
            "retainedRecordNames": ["item-A", "item-B"],
            "requested": {
                "outputDirectory": option_value(arguments, "--output-dir"),
                "samtools": requested_samtools,
            },
            "defaults": {
                "outputDirectory": DEFAULT_OUTPUT.as_posix(),
                "samtools": "managed samtools if installed, otherwise PATH samtools",
            },
            "resolved": {
                "outputDirectory": output_relative,
                "samtools": runtime.get("samtoolsExecutable", "unresolved"),
            },
            "outputDirectory": output_relative,
            "samtools": "samtools",
        },
        "runtimeIdentity": runtime,
        "syntheticData": True,
        "input": input_record,
        "inputFiles": [input_record] if input_record is not None else [],
        "output": {
            "path": output_relative,
            "fileSize": sum(int(item["fileSize"]) for item in payloads),
            "checksumSHA256": directory_checksum(payloads),
        },
        "files": payloads,
        "externalToolInvocations": invocations,
        "status": "completed" if exit_status == 0 else "failed",
        "exitStatus": exit_status,
        "wallTimeSeconds": wall_time,
        "stderr": stderr,
        "warnings": [
            "Wholly synthetic generic alignment records for viewer behavior tests; "
            "no external volume, biological sample, or reference payload is used."
        ],
    }
    return record


def option_value(arguments: list[str], option: str) -> str | None:
    try:
        index = arguments.index(option)
    except ValueError:
        return None
    return arguments[index + 1] if index + 1 < len(arguments) else None


def resolve_repo_path(repo_root: Path, value: Path) -> Path:
    candidate = value if value.is_absolute() else repo_root / value
    resolved = candidate.resolve()
    try:
        resolved.relative_to(repo_root)
    except ValueError as error:
        raise SystemExit("--output-dir must be inside the repository so provenance remains portable") from error
    return resolved


def clear_previous_outputs(output_dir: Path) -> None:
    for name in (*PAYLOAD_NAMES, ".lungfish-provenance.json"):
        path = output_dir / name
        if path.is_file() or path.is_symlink():
            path.unlink()


def resolve_samtools(requested: str | None) -> str:
    if requested:
        discovered = shutil.which(requested)
        if discovered:
            return discovered
        raise RuntimeError(f"samtools executable is unavailable: {requested}")
    managed = Path.home() / ".lungfish" / "conda" / "envs" / "samtools" / "bin" / "samtools"
    if managed.is_file() and os.access(managed, os.X_OK):
        return str(managed)
    discovered = shutil.which("samtools")
    if discovered:
        return discovered
    raise RuntimeError("samtools is required; pass --samtools or install the managed samtools environment")


def base_runtime_identity() -> dict[str, object]:
    return {
        "pythonVersion": platform.python_version(),
        "pythonExecutable": Path(sys.executable).name,
        "operatingSystem": platform.system(),
        "operatingSystemRelease": platform.release(),
        "machine": platform.machine(),
        "pythonCondaEnvironment": os.environ.get("CONDA_DEFAULT_ENV"),
        "containerImage": os.environ.get("LUNGFISH_CONTAINER_IMAGE"),
    }


def samtools_runtime_identity(samtools: str) -> dict[str, object]:
    executable = Path(samtools).resolve()
    parts = executable.parts
    environment = None
    if "envs" in parts:
        env_index = parts.index("envs")
        if env_index + 1 < len(parts):
            environment = parts[env_index + 1]
    return {
        "samtoolsExecutable": portable_executable_identity(executable),
        "samtoolsExecutableChecksumSHA256": sha256(executable),
        "samtoolsCondaEnvironment": environment,
    }


def portable_executable_identity(executable: Path) -> str:
    home = Path.home().resolve()
    try:
        return "$HOME/" + executable.relative_to(home).as_posix()
    except ValueError:
        return "PATH:" + executable.name


def source_sam_text() -> str:
    header = [
        "@HD\tVN:1.6\tSO:coordinate",
        f"@SQ\tSN:{CONTIG_NAME}\tLN:{CONTIG_LENGTH}",
    ]
    records = [
        "item-A\t0\tsynthetic-track-A\t10\t60\t10M\t*\t0\t0\tNNNNNNNNNN\t**********",
        "filtered-duplicate\t1024\tsynthetic-track-A\t10\t60\t10M\t*\t0\t0\tNNNNNNNNNN\t**********",
        "filtered-secondary\t256\tsynthetic-track-A\t10\t60\t10M\t*\t0\t0\tNNNNNNNNNN\t**********",
        "filtered-supplementary\t2048\tsynthetic-track-A\t10\t60\t10M\t*\t0\t0\tNNNNNNNNNN\t**********",
        "item-B\t0\tsynthetic-track-A\t15\t60\t10M\t*\t0\t0\tNNNNNNNNNN\t**********",
        "filtered-unmapped\t4\t*\t0\t0\t*\t*\t0\t0\t*\t*",
    ]
    return "\n".join([*header, *records]) + "\n"


def query_samtools_version(samtools: str) -> tuple[str, dict[str, object]]:
    invocation = run_samtools(samtools, ["--version"], None, "version", "unresolved")
    stdout = str(invocation.pop("stdout"))
    version = stdout.splitlines()[0].strip() if stdout.strip() else "unresolved"
    invocation["version"] = version
    return version, invocation


def run_samtools(
    samtools: str,
    arguments: list[str],
    cwd: Path | None,
    operation: str,
    version: str,
) -> dict[str, object]:
    started = time.monotonic()
    logical_argv = ["samtools", *arguments]
    command = shlex.join(logical_argv)
    runtime = samtools_runtime_identity(samtools)
    try:
        completed = subprocess.run([samtools, *arguments], cwd=cwd, text=True, capture_output=True)
        exit_status = completed.returncode
        stdout = completed.stdout
        stderr = completed.stderr
    except OSError as error:
        exit_status = 127
        stdout = ""
        stderr = f"failed to launch {command}: {error}"
    return {
        "name": "samtools",
        "subcommand": operation,
        "operation": operation,
        "version": version,
        "argv": logical_argv,
        "reproducibleCommand": command,
        "workingDirectory": portable_working_directory(cwd),
        "runtimeIdentity": runtime,
        "exitStatus": exit_status,
        "wallTimeSeconds": round(time.monotonic() - started, 6),
        "stdout": stdout,
        "stderr": stderr,
    }


def require_success(invocation: dict[str, object]) -> None:
    if int(invocation["exitStatus"]) != 0:
        raise ToolFailure(invocation)
    invocation.pop("stdout", None)


def portable_working_directory(cwd: Path | None) -> str | None:
    if cwd is None:
        return None
    repo_root = Path(__file__).resolve().parents[2]
    try:
        return cwd.resolve().relative_to(repo_root).as_posix()
    except ValueError:
        return "$EXTERNAL_WORKING_DIRECTORY"


def existing_payload_records(output_dir: Path) -> list[dict[str, object]]:
    return [
        file_record(output_dir / name, output_dir)
        for name in PAYLOAD_NAMES
        if (output_dir / name).is_file()
    ]


def file_record(path: Path, output_dir: Path) -> dict[str, object]:
    return {
        "path": path.relative_to(output_dir).as_posix(),
        "fileSize": path.stat().st_size,
        "checksumSHA256": sha256(path),
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def directory_checksum(records: list[dict[str, object]]) -> str:
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda item: str(item["path"])):
        digest.update(str(record["path"]).encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(record["fileSize"]).encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(record["checksumSHA256"]).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build, strip and place the Linux executor that ships inside the app (CHTC program, lane C4-14).

One build command serves `release.py package` and the x86-64 step of the Linux tier (scripts/linux/portable-tier.sh),
so the tier checks the bytes a package ships. The command uses the toolchain and Static Linux SDK pinned in
scripts/linux/toolchain.json and keeps its SwiftPM scratch folder inside the checkout. It maps the scratch folder to
/swiftpm-build and the checkout to /workspace, the two maps the app's own build uses (build-notarized-dmg.sh), for the C,
C++ and Swift compilers in that order (QA's FC-Q2 ruling), so no build-machine path reaches the stripped file. It strips
with the pinned toolchain's llvm-objcopy --strip-all, never xcrun strip. The unstripped binary still names home folders
in its DWARF sections, so it goes only beside the dSYMs of the release archive and never into the app.

The app holds Contents/Resources/LinuxExecutor/x86_64/lungfish-executor with manifest.json beside it, outside the Tools
folder that signing_pipeline.py signs as code, so the app's signature seals both as resources. The manifest states the
file's SHA-256 and size and the fields of the plan's executor object (docs/formats/executor-plan.md), and the plan
writer copies them and never hashes a file it found.

This whole file is a compiler recipe of release_cache_fingerprint.py, with scripts/linux/toolchain.json.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, Callable, Mapping

ROOT = Path(__file__).resolve().parents[2]
PINS_RELATIVE_PATH = Path("scripts/linux/toolchain.json")
SCANNER_PATH = Path(__file__).resolve().parent / "scan-release-portability.py"
PRODUCT = "lungfish-executor"
DEFAULT_TRIPLE = "x86_64-swift-linux-musl"
DEFAULT_SCRATCH = Path("build/linux-executor/scratch")
FOLDER = Path("Contents/Resources/LinuxExecutor")
STAGE_FOLDER = Path("LinuxExecutor")
UNSTRIPPED_FOLDER = Path("unstripped")
MANIFEST_NAME = "manifest.json"
MAX_MANIFEST_BYTES = 64 * 1024
SCRATCH_MAP_TARGET = "/swiftpm-build"
CHECKOUT_MAP_TARGET = "/workspace"
HEX_COMMIT = re.compile(r"^[0-9a-f]{40}$")
MANIFEST_FIELDS = frozenset(
    {
        "schemaVersion",
        "relativePath",
        "sha256",
        "size",
        "lgeVersion",
        "lgeCommit",
        "targetTriple",
        "toolchainID",
        "toolchainSHA256",
        "staticLinuxSDKID",
        "staticLinuxSDKSHA256",
    }
)

# run(argv, cwd=..., capture=..., env=...) returns the standard output when capture is true and raises on a nonzero exit.
Runner = Callable[..., str]


class ExecutorBuildError(ValueError):
    """The executor could not be built, checked or placed as the release needs."""


def _run(argv: list[str], *, cwd: Path, capture: bool, env: Mapping[str, str] | None = None) -> str:
    try:
        result = subprocess.run(
            argv,
            cwd=cwd,
            env=None if env is None else dict(env),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else None,
            text=True,
            check=False,
        )
    except OSError as error:
        raise ExecutorBuildError(f"{Path(argv[0]).name} could not start: {error}") from error
    if result.returncode != 0:
        raise ExecutorBuildError(f"{Path(argv[0]).name} {argv[1]} failed with exit {result.returncode}")
    return result.stdout or ""


def load_pins(root: Path) -> dict[str, Any]:
    with (root / PINS_RELATIVE_PATH).open(encoding="utf-8") as handle:
        return json.load(handle)


def toolchain_bin(pins: Mapping[str, Any], home: Path) -> Path:
    return home / "Library/Developer/Toolchains" / f"{pins['toolchain']['name']}.xctoolchain" / "usr/bin"


def architecture_folder(triple: str) -> str:
    return triple.split("-", 1)[0]


def prefix_map_flags(scratch: Path, checkout: Path) -> list[str]:
    """The scratch map, then the checkout map, each for clang's C and C++ compilers and for swiftc."""
    flags: list[str] = []
    for source, target in ((scratch, SCRATCH_MAP_TARGET), (checkout, CHECKOUT_MAP_TARGET)):
        mapping = f"{source}={target}"
        flags += [
            "-Xcc", f"-ffile-prefix-map={mapping}",
            "-Xcxx", f"-ffile-prefix-map={mapping}",
            "-Xswiftc", "-file-prefix-map", "-Xswiftc", mapping,
        ]
    return flags


def build_arguments(
    swift: Path, sdk_id: str, triple: str, scratch: Path, checkout: Path, *, prefix_maps: bool = True
) -> list[str]:
    argv = [
        str(swift), "build", "-c", "release", "--swift-sdk", sdk_id, "--triple", triple,
        "--product", PRODUCT, "--scratch-path", str(scratch),
    ]
    if prefix_maps:
        argv += prefix_map_flags(scratch, checkout)
    return argv


def resolve_scratch(root: Path, scratch: Path | None) -> Path:
    """The real path of the scratch folder, which must sit inside the checkout so the checkout map covers it."""
    chosen = root / DEFAULT_SCRATCH if scratch is None else scratch
    if not chosen.is_absolute():
        chosen = root / chosen
    real = Path(os.path.realpath(chosen))
    if real == root or root not in real.parents:
        raise ExecutorBuildError(f"the executor's scratch folder must sit inside the checkout {root}, not {real}")
    real.mkdir(parents=True, exist_ok=True)
    return real


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _regular(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ExecutorBuildError(f"{label} is missing or not a regular file: {path}")


def build(
    root: Path,
    output: Path,
    *,
    lge_version: str,
    lge_commit: str,
    triple: str = DEFAULT_TRIPLE,
    scratch: Path | None = None,
    prefix_maps: bool = True,
    environment: Mapping[str, str] | None = None,
    home: Path | None = None,
    run: Runner = _run,
) -> dict[str, Any]:
    """Build the executor into a new stage folder and return its manifest.

    The stage holds LinuxExecutor/<arch>/lungfish-executor (stripped) with manifest.json beside it, and
    unstripped/lungfish-executor-<triple>, the copy that goes beside the dSYMs. prefix_maps=False exists only so a lane
    can show what the maps remove. No release path passes it.
    """
    root = Path(root).resolve(strict=True)
    if not lge_version or any(character.isspace() for character in lge_version):
        raise ExecutorBuildError("the LGE version must be nonempty text without spaces")
    if HEX_COMMIT.fullmatch(lge_commit) is None:
        raise ExecutorBuildError("the LGE commit must be a full lowercase commit hash")
    pins = load_pins(root)
    sdk = pins["staticSDK"]
    if triple not in sdk["triples"]:
        raise ExecutorBuildError(f"the Static Linux SDK {sdk['id']} has no triple {triple}")
    tools = toolchain_bin(pins, Path.home() if home is None else home)
    swift, objcopy = tools / "swift", tools / "llvm-objcopy"
    for tool in (swift, objcopy):
        if not os.access(tool, os.X_OK):
            raise ExecutorBuildError(
                f"{tool} is missing. Install the pinned toolchain with: bash scripts/linux/portable-tier.sh --install"
            )
    installed = run([str(swift), "sdk", "list"], cwd=root, capture=True, env=environment)
    if sdk["id"] not in (line.strip() for line in installed.splitlines()):
        raise ExecutorBuildError(
            f"the Static Linux SDK {sdk['id']} is not installed. Run: bash scripts/linux/portable-tier.sh --install"
        )
    output = Path(os.path.abspath(output))
    if output.exists() or output.is_symlink():
        raise ExecutorBuildError(f"the executor stage folder must be new: {output}")
    scratch_path = resolve_scratch(root, scratch)
    argv = build_arguments(swift, sdk["id"], triple, scratch_path, root, prefix_maps=prefix_maps)
    run(argv, cwd=root, capture=False, env=environment)
    lines = run([*argv, "--show-bin-path"], cwd=root, capture=True, env=environment).strip().splitlines()
    if not lines:
        raise ExecutorBuildError("swift build --show-bin-path printed no folder")
    unstripped = Path(lines[-1]) / PRODUCT
    _regular(unstripped, "the built executor")

    folder = output / STAGE_FOLDER / architecture_folder(triple)
    kept = output / UNSTRIPPED_FOLDER / f"{PRODUCT}-{triple}"
    folder.mkdir(parents=True)
    kept.parent.mkdir()
    shutil.copyfile(unstripped, kept)
    os.chmod(kept, 0o755)
    stripped = folder / PRODUCT
    run([str(objcopy), "--strip-all", str(unstripped), str(stripped)], cwd=root, capture=False, env=environment)
    _regular(stripped, "the stripped executor")
    os.chmod(stripped, 0o755)
    manifest = {
        "schemaVersion": 1,
        "relativePath": PRODUCT,
        "sha256": sha256_file(stripped),
        "size": stripped.stat().st_size,
        "lgeVersion": lge_version,
        "lgeCommit": lge_commit,
        "targetTriple": triple,
        "toolchainID": pins["toolchain"]["name"],
        "toolchainSHA256": pins["toolchain"]["sha256"],
        "staticLinuxSDKID": sdk["id"],
        "staticLinuxSDKSHA256": sdk["sha256"],
    }
    manifest_path = folder / MANIFEST_NAME
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    os.chmod(manifest_path, 0o644)
    return manifest


def _scanner():
    if str(SCANNER_PATH.parent) not in sys.path:
        sys.path.insert(0, str(SCANNER_PATH.parent))
    spec = importlib.util.spec_from_file_location("lungfish_scan_release_portability", SCANNER_PATH)
    if spec is None or spec.loader is None:
        raise ExecutorBuildError("the release portability scan could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def forbidden_findings(path: Path) -> list[tuple[str, int]]:
    """Each label of the release scan's table that the file holds, user-home and repository-root included."""
    scanner = _scanner()
    try:
        counts = scanner.count_patterns(path)
    except scanner.ScanError as error:
        raise ExecutorBuildError(f"the portability scan could not read {path}: {error}") from error
    return [(label, count) for label, count in counts if count]


def read_folder(folder: Path) -> dict[str, Any]:
    """Read manifest.json of one LinuxExecutor/<arch> folder and check that it names the file beside it."""
    manifest_path = folder / MANIFEST_NAME
    _regular(manifest_path, "the executor manifest")
    raw = manifest_path.read_bytes()
    if len(raw) > MAX_MANIFEST_BYTES:
        raise ExecutorBuildError("the executor manifest is too large")
    try:
        manifest = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ExecutorBuildError("the executor manifest is not valid JSON") from error
    if not isinstance(manifest, dict) or set(manifest) != MANIFEST_FIELDS or manifest["schemaVersion"] != 1:
        raise ExecutorBuildError("the executor manifest fields are missing, unknown or of another schema")
    if manifest["relativePath"] != PRODUCT:
        raise ExecutorBuildError(f"the executor manifest names {manifest['relativePath']!r}, not {PRODUCT}")
    executable = folder / PRODUCT
    _regular(executable, "the executor")
    if manifest["size"] != executable.stat().st_size or manifest["sha256"] != sha256_file(executable):
        raise ExecutorBuildError("the executor manifest's SHA-256 or size differs from the file beside it")
    return manifest


def place(stage: Path, app: Path, symbols: Path, *, triple: str = DEFAULT_TRIPLE) -> dict[str, Any]:
    """Copy the stripped executor and its manifest into the app and the unstripped copy beside the dSYMs."""
    arch = architecture_folder(triple)
    source = stage / STAGE_FOLDER / arch
    manifest = read_folder(source)
    if manifest["targetTriple"] != triple:
        raise ExecutorBuildError(f"the stage holds a {manifest['targetTriple']} executor, not {triple}")
    findings = forbidden_findings(source / PRODUCT)
    if findings:
        named = ", ".join(f"{label} {count}" for label, count in findings)
        raise ExecutorBuildError(f"the stripped executor holds build-machine paths ({named})")
    unstripped = stage / UNSTRIPPED_FOLDER / f"{PRODUCT}-{triple}"
    _regular(unstripped, "the unstripped executor")
    for folder, label in ((app, "the app"), (symbols, "the archive's dSYMs folder")):
        if folder.is_symlink() or not folder.is_dir():
            raise ExecutorBuildError(f"{label} is missing or a symlink: {folder}")
    destination = app / FOLDER / arch
    if (app / FOLDER).exists() or (app / FOLDER).is_symlink():
        raise ExecutorBuildError(f"the app already holds {FOLDER}")
    kept = symbols / f"{PRODUCT}-{triple}"
    if kept.exists() or kept.is_symlink():
        raise ExecutorBuildError(f"the archive already holds {kept.name}")
    destination.mkdir(parents=True)
    for name, mode in ((PRODUCT, 0o755), (MANIFEST_NAME, 0o644)):
        shutil.copyfile(source / name, destination / name)
        os.chmod(destination / name, mode)
    shutil.copyfile(unstripped, kept)
    os.chmod(kept, 0o755)
    return read_folder(destination)


def app_record(app: Path, *, triple: str = DEFAULT_TRIPLE) -> dict[str, Any] | None:
    """The receipt's record of the app's executor, or None when the app holds no LinuxExecutor folder."""
    if not (app / FOLDER).exists() and not (app / FOLDER).is_symlink():
        return None
    relative = FOLDER / architecture_folder(triple)
    return {"path": (relative / PRODUCT).as_posix(), "manifest": read_folder(app / relative)}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    operations = parser.add_subparsers(dest="operation", required=True)
    make = operations.add_parser("build", help="build and strip the executor into a new stage folder")
    make.add_argument("--output", required=True, type=Path)
    make.add_argument("--lge-version", required=True)
    make.add_argument("--lge-commit", required=True)
    make.add_argument("--triple", default=DEFAULT_TRIPLE)
    make.add_argument("--scratch-path", type=Path)
    put = operations.add_parser("place", help="copy a stage into an assembled app and its archive")
    put.add_argument("--stage", required=True, type=Path)
    put.add_argument("--app", required=True, type=Path)
    put.add_argument("--symbols", required=True, type=Path)
    put.add_argument("--triple", default=DEFAULT_TRIPLE)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.operation == "build":
            manifest = build(
                ROOT, args.output, lge_version=args.lge_version, lge_commit=args.lge_commit,
                triple=args.triple, scratch=args.scratch_path,
            )
            stripped = args.output / STAGE_FOLDER / architecture_folder(args.triple) / PRODUCT
            findings = forbidden_findings(stripped)
            if findings:
                named = ", ".join(f"{label} {count}" for label, count in findings)
                print(f"FAIL linux executor holds build-machine paths ({named})", file=sys.stderr)
                return 1
            print(f"PASS linux executor {manifest['targetTriple']} sha256 {manifest['sha256']} size {manifest['size']}")
        else:
            manifest = place(args.stage, args.app, args.symbols, triple=args.triple)
            print(f"PASS linux executor placed sha256 {manifest['sha256']} size {manifest['size']}")
    except (ExecutorBuildError, OSError, KeyError) as error:
        print(f"FAIL linux executor: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

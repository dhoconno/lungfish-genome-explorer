#!/usr/bin/env python3
"""Lock, verify and provision the golden environment.

    python3 scripts/golden/environment.py verify [--storage DIR]
    python3 scripts/golden/environment.py provision [--storage DIR]
    python3 scripts/golden/environment.py lock --from-storage DIR [--env NAME]
    python3 scripts/golden/environment.py lock --solve [--env NAME]
    python3 scripts/golden/environment.py lock --from-storage DIR --database NAME

The golden captures run lungfish-cli against a managed storage root that holds
eight conda environments and two classifier databases. That root lives at a
fixed path, /Users/Shared/lungfish-golden/storage, so the goldens record the
same paths on every Mac and for every user. Its content is pinned by
Tests/Fixtures/golden-environment/lock.json and one explicit conda file per
environment, which lists every package by URL and MD5.

`provision` builds the root from the lock and repairs any part that does not
match. `verify` checks it without changing anything, and golden.py runs the
same check before every capture. `lock` rewrites the explicit files, either
from environments already installed in another root or by asking micromamba to
resolve the manifest's package spec. Tests/Fixtures/golden-environment/README.md
says when to use each.
"""

from __future__ import annotations

import argparse
import grp
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
LOCK_DIR = REPO_ROOT / "Tests" / "Fixtures" / "golden-environment"
LOCK_PATH = LOCK_DIR / "lock.json"
MANIFEST_PATH = REPO_ROOT / "Sources" / "LungfishWorkflow" / "Resources" / "ManagedTools" / "third-party-tools-lock.json"
MICROMAMBA_RESOURCE = REPO_ROOT / "Sources" / "LungfishWorkflow" / "Resources" / "Tools" / "micromamba"

# Every golden path starts here. Changing it changes every golden.
GOLDEN_HOME = Path("/Users/Shared/lungfish-golden")
# The runner account and a person's account on the same Mac both write here,
# so folders are group writable and inherit the group (setgid).
SHARED_UMASK = 0o002
SHARED_FOLDER_MODE = 0o2775
SHARED_GROUP = "staff"
STORAGE_ROOT = GOLDEN_HOME / "storage"

PLATFORM = "osx-arm64"
CHANNELS = ("conda-forge", "bioconda")
BARE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
REGISTRY_NAME = "metagenomics-db-registry.json"
EXPLICIT_HEADER = (
    "# This file may be used to create an environment using:\n"
    "# $ conda create --name <env> --file <this file>\n"
    f"# platform: {PLATFORM}\n"
    "@EXPLICIT\n"
)


class LockError(RuntimeError):
    """The golden environment cannot be locked, verified or provisioned."""


# ---------------------------------------------------------------------------
# Lock


@dataclass(frozen=True)
class Package:
    url: str
    md5: str

    @property
    def line(self) -> str:
        return f"{self.url}#{self.md5}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def load_lock(path: Path = LOCK_PATH) -> dict:
    lock = json.loads(path.read_text())
    if lock.get("schemaVersion") != 1:
        raise LockError(f"{path}: unsupported schemaVersion {lock.get('schemaVersion')!r}")
    if lock.get("platform") != PLATFORM:
        raise LockError(f"{path}: platform {lock.get('platform')!r}, expected {PLATFORM}")
    return lock


def write_lock(lock: dict, path: Path = LOCK_PATH) -> None:
    path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")


def render_explicit(packages: list[Package]) -> str:
    return EXPLICIT_HEADER + "".join(package.line + "\n" for package in packages)


def parse_explicit(text: str) -> list[Package]:
    lines = text.splitlines()
    if "@EXPLICIT" not in lines:
        raise LockError("explicit file has no @EXPLICIT line")
    packages = []
    for line in lines[lines.index("@EXPLICIT") + 1:]:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        url, _, md5 = line.partition("#")
        if len(md5) != 32 or not url.startswith("https://conda.anaconda.org/"):
            raise LockError(f"explicit line is not a pinned conda URL with an MD5: {line}")
        packages.append(Package(url, md5))
    return packages


def explicit_packages(lock: dict, name: str, lock_dir: Path = LOCK_DIR) -> list[Package]:
    entry = environment_entry(lock, name)
    path = lock_dir / entry["explicit"]
    if sha256_file(path) != entry["sha256"]:
        raise LockError(f"{path.name} does not match the sha256 in lock.json")
    return parse_explicit(path.read_text())


def environment_entry(lock: dict, name: str) -> dict:
    for entry in lock["environments"]:
        if entry["name"] == name:
            return entry
    raise LockError(f"lock.json has no environment named {name}")


def manifest_package_specs(manifest_path: Path = MANIFEST_PATH) -> dict[str, str]:
    """Environment name to packageSpec, for every tool and pack tool."""
    manifest = json.loads(manifest_path.read_text())
    return {tool["environment"]: tool["packageSpec"]
            for tool in manifest.get("tools", []) + manifest.get("packTools", []) if tool.get("packageSpec")}


def installed_packages(prefix: Path) -> list[Package]:
    """The packages conda-meta records for an environment, dependencies first.

    Order is a topological sort on the recorded depends, with ties broken by
    name, so the same environment always writes the same file.
    """
    meta = prefix / "conda-meta"
    if not meta.is_dir():
        raise LockError(f"{prefix} is not a conda environment")
    records = {}
    for path in sorted(meta.glob("*.json")):
        record = json.loads(path.read_text())
        if not record.get("url") or not record.get("md5"):
            raise LockError(f"{path} records no url or md5")
        records[record["name"]] = record
    ordered: list[str] = []
    state: dict[str, int] = {}

    def visit(name: str) -> None:
        if state.get(name) == 2:
            return
        if state.get(name) == 1:
            return  # a dependency cycle, which conda allows; first visit wins
        state[name] = 1
        for dependency in sorted(spec.split()[0] for spec in records[name].get("depends", [])):
            if dependency in records:
                visit(dependency)
        state[name] = 2
        ordered.append(name)

    for name in sorted(records):
        visit(name)
    return [Package(records[name]["url"], records[name]["md5"]) for name in ordered]


def micromamba_environment(conda_root: Path) -> dict[str, str]:
    return {
        "HOME": str(Path.home()),
        "PATH": BARE_PATH,
        "MAMBA_ROOT_PREFIX": str(conda_root),
        "MAMBA_NO_BANNER": "1",
        "TMPDIR": tempfile.gettempdir(),
    }


def solved_packages(spec: str, micromamba: Path = MICROMAMBA_RESOURCE) -> list[Package]:
    """Resolve one package spec against the live channels, without installing."""
    with tempfile.TemporaryDirectory(prefix="lge-golden-solve-") as scratch:
        command = [str(micromamba), "create", "--yes", "--dry-run", "--json", "--no-rc",
                   "--override-channels", *[arg for channel in CHANNELS for arg in ("-c", channel)],
                   "--platform", PLATFORM, "-p", str(Path(scratch) / "env"), spec]
        completed = subprocess.run(command, env=micromamba_environment(Path(scratch) / "root"),
                                   capture_output=True, text=True)
    if completed.returncode != 0:
        raise LockError(f"micromamba could not resolve {spec}\n{completed.stderr[-2000:]}")
    actions = json.loads(completed.stdout).get("actions", {})
    links = actions.get("LINK", [])
    if not links:
        raise LockError(f"micromamba resolved nothing for {spec}")
    return [Package(link["url"], link["md5"]) for link in links]


def lock_environments(lock: dict, names: list[str], *, source: Path | None, lock_dir: Path = LOCK_DIR,
                      manifest_path: Path = MANIFEST_PATH) -> list[str]:
    """Rewrite the explicit file and lock entry of each named environment."""
    specs = manifest_package_specs(manifest_path)
    changed = []
    for name in names:
        entry = environment_entry(lock, name)
        if name not in specs:
            raise LockError(f"the managed-tools manifest has no environment named {name}")
        if source is not None:
            prefix = source / "conda" / "envs" / name
            packages = installed_packages(prefix)
            top = next((p for p in packages if _package_matches_spec(p, specs[name])), None)
            if top is None:
                raise LockError(f"{prefix} does not hold {specs[name]}, the manifest's pin")
        else:
            packages = solved_packages(specs[name])
        text = render_explicit(packages)
        path = lock_dir / entry["explicit"]
        if not path.exists() or path.read_text() != text:
            changed.append(name)
        path.write_text(text)
        entry["packageSpec"] = specs[name]
        entry["sha256"] = sha256_file(path)
        entry["packages"] = len(packages)
    return changed


def lock_database(lock: dict, name: str, storage: Path) -> bool:
    """Record the files of an installed database. Run after changing its
    source URL and version and letting `provision` install the new archive."""
    entry = next((entry for entry in lock["databases"] if entry["name"] == name), None)
    if entry is None:
        raise LockError(f"lock.json has no database named {name}")
    location = database_path(storage, entry)
    if not location.is_dir():
        raise LockError(f"database {name} is not installed at {location}")
    relpaths = ([str(path.relative_to(location)) for path in location.rglob("*") if path.is_file()]
                if entry.get("exactFiles") else list(entry["files"]))
    files = {}
    for relpath in sorted(relpaths):
        path = location / relpath
        if not path.is_file():
            raise LockError(f"database {name} lacks {relpath}")
        files[relpath] = {"bytes": path.stat().st_size, "sha256": sha256_file(path)}
    changed = files != entry["files"]
    entry["files"] = files
    return changed


def prepare_golden_home(home: Path = GOLDEN_HOME) -> None:
    """Create the shared folder so every account in its group can write it."""
    os.umask(SHARED_UMASK)
    if not home.exists():
        home.mkdir(parents=True)
        # /Users/Shared belongs to wheel, and a new file takes its folder's
        # group, so the top folder is given staff, the group of every account.
        os.chown(home, -1, grp.getgrnam(SHARED_GROUP).gr_gid)
        home.chmod(SHARED_FOLDER_MODE)


def _package_matches_spec(package: Package, spec: str) -> bool:
    """bioconda::minimap2=2.31=h6bd33b9_0 names minimap2-2.31-h6bd33b9_0.conda."""
    _, _, pin = spec.partition("::")
    name, version, build = (pin.split("=") + ["", ""])[:3]
    filename = package.url.rsplit("/", 1)[-1]
    return filename.startswith(f"{name}-{version}-{build}.")


# ---------------------------------------------------------------------------
# Verify


def conda_root(storage: Path) -> Path:
    return storage / "conda"


def database_root(storage: Path) -> Path:
    return storage / "databases"


def environment_problems(lock: dict, storage: Path, name: str, lock_dir: Path = LOCK_DIR) -> list[str]:
    prefix = conda_root(storage) / "envs" / name
    if not (prefix / "conda-meta").is_dir():
        return [f"environment {name} is not installed at {prefix}"]
    expected = set(explicit_packages(lock, name, lock_dir))
    try:
        actual = set(installed_packages(prefix))
    except LockError as error:
        return [f"environment {name}: {error}"]
    problems = []
    for package in sorted(expected - actual, key=lambda p: p.url):
        problems.append(f"environment {name} lacks {package.url.rsplit('/', 1)[-1]}")
    for package in sorted(actual - expected, key=lambda p: p.url):
        problems.append(f"environment {name} holds {package.url.rsplit('/', 1)[-1]}, which the lock does not list")
    return problems


def micromamba_problems(lock: dict, storage: Path) -> list[str]:
    binary = conda_root(storage) / "bin" / "micromamba"
    if not binary.exists():
        return [f"micromamba is not installed at {binary}"]
    if sha256_file(binary) != lock["micromamba"]["sha256"]:
        return [f"{binary} is not micromamba {lock['micromamba']['version']}"]
    return []


def database_path(storage: Path, entry: dict) -> Path:
    return database_root(storage) / entry["path"]


def database_file_problems(storage: Path, entry: dict) -> list[str]:
    location = database_path(storage, entry)
    problems = []
    for relpath, expected in sorted(entry["files"].items()):
        path = location / relpath
        if not path.is_file():
            problems.append(f"database {entry['name']} lacks {relpath}")
        elif path.stat().st_size != expected["bytes"] or sha256_file(path) != expected["sha256"]:
            problems.append(f"database {entry['name']} file {relpath} does not match the lock")
    if entry.get("exactFiles"):
        present = {str(path.relative_to(location)) for path in location.rglob("*") if path.is_file()}
        for relpath in sorted(present - set(entry["files"])):
            problems.append(f"database {entry['name']} holds {relpath}, which the lock does not list")
    return problems


def registry_row(storage: Path, entry: dict) -> dict:
    """The registry row the app reads for one locked database."""
    location = database_path(storage, entry)
    row = dict(entry["registry"])
    row.update({
        "name": entry["name"],
        "tool": entry["tool"],
        "version": entry["version"],
        "path": "file://" + urllib.parse.quote(str(location)) + "/",
        "isExternal": False,
        "status": "ready",
    })
    return row


def registry_problems(lock: dict, storage: Path) -> list[str]:
    path = database_root(storage) / REGISTRY_NAME
    if not path.exists():
        return [f"the database registry {path} does not exist"]
    rows = {row.get("name"): row for row in json.loads(path.read_text()).get("databases", [])}
    problems = []
    for entry in lock["databases"]:
        row = rows.get(entry["name"])
        expected = registry_row(storage, entry)
        if row is None:
            problems.append(f"the database registry has no row named {entry['name']}")
            continue
        for key in ("tool", "version", "status", "path"):
            if row.get(key) != expected[key]:
                problems.append(f"registry row {entry['name']}: {key} is {row.get(key)!r}, "
                                f"expected {expected[key]!r}")
    return problems


def verify(storage: Path = STORAGE_ROOT, lock: dict | None = None, lock_dir: Path = LOCK_DIR) -> list[str]:
    lock = lock or load_lock(lock_dir / "lock.json")
    problems = micromamba_problems(lock, storage)
    for entry in lock["environments"]:
        problems += environment_problems(lock, storage, entry["name"], lock_dir)
    for entry in lock["databases"]:
        problems += database_file_problems(storage, entry)
    problems += registry_problems(lock, storage)
    return problems


# ---------------------------------------------------------------------------
# Provision


def install_micromamba(lock: dict, storage: Path) -> None:
    if not micromamba_problems(lock, storage):
        return
    if sha256_file(MICROMAMBA_RESOURCE) != lock["micromamba"]["sha256"]:
        raise LockError(f"{MICROMAMBA_RESOURCE} does not match the micromamba sha256 in lock.json")
    binary = conda_root(storage) / "bin" / "micromamba"
    binary.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(MICROMAMBA_RESOURCE, binary)
    binary.chmod(0o755)
    print(f"provision: installed micromamba {lock['micromamba']['version']}", flush=True)


def install_environment(lock: dict, storage: Path, name: str, lock_dir: Path = LOCK_DIR) -> None:
    if not environment_problems(lock, storage, name, lock_dir):
        return
    explicit_packages(lock, name, lock_dir)  # checks the file's sha256 first
    prefix = conda_root(storage) / "envs" / name
    if prefix.exists():
        shutil.rmtree(prefix)
    command = [str(conda_root(storage) / "bin" / "micromamba"), "create", "--yes", "--no-rc", "-p", str(prefix),
               "--file", str(lock_dir / environment_entry(lock, name)["explicit"])]
    print(f"provision: creating environment {name}", flush=True)
    completed = subprocess.run(command, env=micromamba_environment(conda_root(storage)),
                               capture_output=True, text=True)
    if completed.returncode != 0:
        raise LockError(f"micromamba could not create {name}\n{completed.stderr[-2000:]}")
    problems = environment_problems(lock, storage, name, lock_dir)
    if problems:
        raise LockError("\n".join(problems))


def download(url: str, destination: Path, sha256: str | None) -> None:
    if destination.exists() and sha256 and sha256_file(destination) == sha256:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    print(f"provision: downloading {url}", flush=True)
    subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
                    "--continue-at", "-", "--output", str(partial), url], check=True)
    partial.replace(destination)
    if sha256 and sha256_file(destination) != sha256:
        destination.unlink()
        raise LockError(f"{url} does not match the archive sha256 in lock.json")


def install_database(storage: Path, entry: dict, downloads: Path) -> None:
    if not database_file_problems(storage, entry):
        return
    if database_path(storage, entry).is_dir():
        derive_files(storage, entry, database_path(storage, entry))
        if not database_file_problems(storage, entry):
            print(f"provision: completed database {entry['name']}", flush=True)
            return
    source = entry["source"]
    archive = downloads / source["url"].rsplit("/", 1)[-1]
    download(source["url"], archive, source.get("sha256"))
    location = database_path(storage, entry)
    staging = location.with_name(f".{location.name}.provision")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(staging)], check=True)
    derive_files(storage, entry, staging)
    if location.exists():
        shutil.rmtree(location)
    staging.rename(location)
    problems = database_file_problems(storage, entry)
    if problems:
        raise LockError("\n".join(problems))
    print(f"provision: installed database {entry['name']}", flush=True)


def derive_files(storage: Path, entry: dict, location: Path) -> None:
    """Make the files a database's archive lacks but its installed copy holds,
    such as the samtools FASTA index of the EsViritu Viral DB. Each command
    runs from the database folder with a locked environment's bin first on PATH."""
    for step in entry.get("derivedFiles", []):
        if (location / step["file"]).exists():
            continue
        bin_dir = conda_root(storage) / "envs" / step["environment"] / "bin"
        completed = subprocess.run(step["command"], cwd=location, capture_output=True, text=True,
                                   env={"HOME": str(Path.home()), "PATH": f"{bin_dir}:{BARE_PATH}"})
        if completed.returncode != 0:
            raise LockError(f"database {entry['name']}: {' '.join(step['command'])} failed\n{completed.stderr[-2000:]}")


def write_registry(lock: dict, storage: Path) -> None:
    """Insert or replace the locked rows and keep every other row."""
    path = database_root(storage) / REGISTRY_NAME
    registry = json.loads(path.read_text()) if path.exists() else {"version": 1, "databases": []}
    rows = {row["name"]: row for row in registry.get("databases", [])}
    for entry in lock["databases"]:
        rows[entry["name"]] = registry_row(storage, entry)
    registry["databases"] = [rows[name] for name in sorted(rows)]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n")


def provision(storage: Path = STORAGE_ROOT, lock_dir: Path = LOCK_DIR) -> None:
    lock = load_lock(lock_dir / "lock.json")
    if storage == STORAGE_ROOT:
        prepare_golden_home()
    storage.mkdir(parents=True, exist_ok=True)
    install_micromamba(lock, storage)
    for entry in lock["environments"]:
        install_environment(lock, storage, entry["name"], lock_dir)
    downloads = storage.parent / "downloads"
    for entry in lock["databases"]:
        install_database(storage, entry, downloads)
    write_registry(lock, storage)
    problems = verify(storage, lock, lock_dir)
    if problems:
        raise LockError("\n".join(problems))


# ---------------------------------------------------------------------------
# Command line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("verify", "provision"):
        command = commands.add_parser(name)
        command.add_argument("--storage", type=Path, default=STORAGE_ROOT,
                             help=f"storage root (default {STORAGE_ROOT}, the only one the goldens match)")
    lock_command = commands.add_parser("lock")
    source = lock_command.add_mutually_exclusive_group(required=True)
    source.add_argument("--from-storage", type=Path, help="copy the package lists of an installed storage root")
    source.add_argument("--solve", action="store_true", help="resolve the manifest's package spec with micromamba")
    lock_command.add_argument("--env", action="append", help="lock only this environment (repeatable)")
    lock_command.add_argument("--database", action="append",
                              help="record the installed files of this database instead (needs --from-storage)")
    args = parser.parse_args(argv)

    try:
        if args.command == "verify":
            problems = verify(args.storage.expanduser())
            for problem in problems:
                print(f"verify: {problem}", file=sys.stderr)
            print(f"verify: {args.storage} {'matches' if not problems else 'does NOT match'} the golden lock")
            return 0 if not problems else 1
        if args.command == "provision":
            provision(args.storage.expanduser())
            print(f"provision: {args.storage} matches the golden lock")
            return 0
        lock = load_lock()
        source_root = args.from_storage.expanduser() if args.from_storage else None
        if args.database:
            if source_root is None:
                parser.error("--database needs --from-storage")
            changed = [name for name in args.database if lock_database(lock, name, source_root)]
            write_lock(lock)
            print(f"lock: {len(args.database)} databases locked, changed: {', '.join(changed) or 'none'}")
            return 0
        names = args.env or [entry["name"] for entry in lock["environments"]]
        changed = lock_environments(lock, names, source=source_root)
        write_lock(lock)
        print(f"lock: {len(names)} environments locked, changed: {', '.join(changed) or 'none'}")
        return 0
    except (LockError, subprocess.CalledProcessError, OSError) as error:
        print(f"environment: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

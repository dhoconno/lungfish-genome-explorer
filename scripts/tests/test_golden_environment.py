"""Tests for the golden environment lock (scripts/golden/environment.py)."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "golden"))
sys.dont_write_bytecode = True

import captures  # noqa: E402
import environment  # noqa: E402

CHANNEL = "https://conda.anaconda.org/conda-forge/osx-arm64"


def package(name: str, depends: list[str] = ()) -> dict:
    return {"name": name, "url": f"{CHANNEL}/{name}-1.0-h0_0.conda",
            "md5": hashlib.md5(name.encode()).hexdigest(), "depends": list(depends)}


def install(prefix: Path, records: list[dict]) -> None:
    meta = prefix / "conda-meta"
    meta.mkdir(parents=True)
    for record in records:
        (meta / f"{record['name']}-1.0-h0_0.json").write_text(json.dumps(record))


def small_lock(tmp_path: Path, packages: list[environment.Package]) -> tuple[dict, Path]:
    lock_dir = tmp_path / "lock"
    lock_dir.mkdir()
    (lock_dir / "tool-osx-arm64-explicit.txt").write_text(environment.render_explicit(packages))
    data = b"database bytes"
    lock = {
        "schemaVersion": 1, "platform": "osx-arm64",
        "micromamba": {"version": "2.9.0-0", "sha256": hashlib.sha256(b"micromamba").hexdigest()},
        "environments": [{"name": "tool", "packageSpec": "bioconda::tool=1.0=h0_0",
                          "explicit": "tool-osx-arm64-explicit.txt",
                          "sha256": environment.sha256_file(lock_dir / "tool-osx-arm64-explicit.txt"),
                          "packages": len(packages)}],
        "databases": [{"name": "Viral", "tool": "kraken2", "version": "20260626", "path": "kraken2/viral",
                       "exactFiles": False, "source": {"url": "https://example.invalid/viral.tar.gz"},
                       "files": {"hash.k2d": {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}},
                       "registry": {"catalogID": "kraken2-viral", "description": "RefSeq viral genomes only",
                                    "sizeBytes": 1, "recommendedRAM": 1}}],
    }
    (lock_dir / "lock.json").write_text(json.dumps(lock))
    return lock, lock_dir


def provisioned(tmp_path: Path, lock: dict, records: list[dict]) -> Path:
    storage = tmp_path / "storage"
    binary = storage / "conda" / "bin" / "micromamba"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"micromamba")
    install(storage / "conda" / "envs" / "tool", records)
    database = storage / "databases" / "kraken2" / "viral"
    database.mkdir(parents=True)
    (database / "hash.k2d").write_bytes(b"database bytes")
    (database / "inspect.txt").write_text("extra files are allowed unless exactFiles is set\n")
    environment.write_registry(lock, storage)
    return storage


# Explicit files ----------------------------------------------------------------


def test_explicit_files_round_trip_and_match_the_header_conda_writes():
    packages = [environment.Package(f"{CHANNEL}/zlib-1.3.1-h0_0.conda", "a" * 32)]
    text = environment.render_explicit(packages)
    assert text.startswith("# This file may be used to create an environment using:\n")
    assert "# platform: osx-arm64\n@EXPLICIT\n" in text
    assert environment.parse_explicit(text) == packages


def test_explicit_lines_without_a_pinned_md5_are_refused():
    for line in (f"{CHANNEL}/zlib-1.3.1-h0_0.conda", "https://example.com/zlib.conda#" + "a" * 32):
        try:
            environment.parse_explicit("@EXPLICIT\n" + line + "\n")
        except environment.LockError:
            continue
        raise AssertionError(f"accepted {line}")


def test_installed_packages_list_dependencies_first_in_a_stable_order(tmp_path):
    install(tmp_path / "env", [package("tool", ["libz >=1.3", "python"]), package("python", ["libz"]),
                               package("libz"), package("ca-certificates")])
    names = [p.url.rsplit("/", 1)[-1].split("-1.0")[0] for p in environment.installed_packages(tmp_path / "env")]
    assert names == ["ca-certificates", "libz", "python", "tool"]


def test_lock_from_storage_requires_the_manifest_pin(tmp_path):
    lock, lock_dir = small_lock(tmp_path, [])
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"tools": [{"environment": "tool", "packageSpec": "bioconda::tool=1.0=h0_0"}]}))
    source = tmp_path / "source"
    install(source / "conda" / "envs" / "tool", [package("tool", ["libz"]), package("libz")])
    changed = environment.lock_environments(lock, ["tool"], source=source, lock_dir=lock_dir, manifest_path=manifest)
    assert changed == ["tool"]
    assert lock["environments"][0]["packages"] == 2
    assert environment.explicit_packages(lock, "tool", lock_dir)[-1].url.endswith("/tool-1.0-h0_0.conda")
    manifest.write_text(json.dumps({"tools": [{"environment": "tool", "packageSpec": "bioconda::tool=2.0=h0_0"}]}))
    try:
        environment.lock_environments(lock, ["tool"], source=source, lock_dir=lock_dir, manifest_path=manifest)
    except environment.LockError as error:
        assert "manifest's pin" in str(error)
    else:
        raise AssertionError("locked an environment that does not hold the manifest's pin")


# Verify --------------------------------------------------------------------------


def test_a_storage_built_from_the_lock_verifies(tmp_path):
    records = [package("tool", ["libz"]), package("libz")]
    packages = [environment.Package(r["url"], r["md5"]) for r in records]
    lock, lock_dir = small_lock(tmp_path, packages)
    storage = provisioned(tmp_path, lock, records)
    assert environment.verify(storage, lock, lock_dir) == []


def test_verify_names_every_drift(tmp_path):
    records = [package("tool", ["libz"]), package("libz")]
    lock, lock_dir = small_lock(tmp_path, [environment.Package(r["url"], r["md5"]) for r in records])
    storage = provisioned(tmp_path, lock, records)
    (storage / "conda" / "envs" / "tool" / "conda-meta" / "libz-1.0-h0_0.json").unlink()
    install(storage / "conda" / "envs" / "tool" / "x", [])  # an unrelated folder is not a package
    (storage / "conda" / "envs" / "tool" / "conda-meta" / "openssl-1.0-h0_0.json").write_text(
        json.dumps(package("openssl")))
    (storage / "databases" / "kraken2" / "viral" / "hash.k2d").write_bytes(b"other bytes")
    problems = environment.verify(storage, lock, lock_dir)
    assert "environment tool lacks libz-1.0-h0_0.conda" in problems
    assert "environment tool holds openssl-1.0-h0_0.conda, which the lock does not list" in problems
    assert "database Viral file hash.k2d does not match the lock" in problems


def test_exact_file_databases_refuse_extra_files(tmp_path):
    lock, lock_dir = small_lock(tmp_path, [])
    lock["databases"][0]["exactFiles"] = True
    storage = provisioned(tmp_path, lock, [])
    assert environment.database_file_problems(storage, lock["databases"][0]) == [
        "database Viral holds inspect.txt, which the lock does not list"]


def test_an_edited_explicit_file_fails_its_sha256(tmp_path):
    lock, lock_dir = small_lock(tmp_path, [])
    (lock_dir / "tool-osx-arm64-explicit.txt").write_text("@EXPLICIT\n")
    try:
        environment.explicit_packages(lock, "tool", lock_dir)
    except environment.LockError as error:
        assert "sha256" in str(error)
    else:
        raise AssertionError("accepted an explicit file whose sha256 changed")


# Registry ------------------------------------------------------------------------


def test_registry_rows_point_at_the_locked_folder_and_keep_other_rows(tmp_path):
    lock, _ = small_lock(tmp_path, [])
    storage = tmp_path / "storage"
    registry = storage / "databases" / environment.REGISTRY_NAME
    registry.parent.mkdir(parents=True)
    registry.write_text(json.dumps({"version": 1, "databases": [
        {"name": "Viral", "tool": "kraken2", "status": "missing"}, {"name": "Standard", "tool": "kraken2"}]}))
    environment.write_registry(lock, storage)
    rows = {row["name"]: row for row in json.loads(registry.read_text())["databases"]}
    assert rows["Standard"] == {"name": "Standard", "tool": "kraken2"}
    assert rows["Viral"]["status"] == "ready"
    assert rows["Viral"]["version"] == "20260626"
    assert rows["Viral"]["path"] == f"file://{storage}/databases/kraken2/viral"
    assert rows["Viral"]["isExternal"] is False
    assert environment.registry_problems(lock, storage) == []


# The committed lock --------------------------------------------------------------


def test_committed_lock_files_match_their_sha256_and_the_manifest_pins():
    lock = environment.load_lock()
    specs = environment.manifest_package_specs()
    manifest = json.loads(environment.MANIFEST_PATH.read_text())
    assert lock["micromamba"] == {
        "version": manifest["bootstrap"]["micromamba"]["version"],
        "sha256": manifest["bootstrap"]["micromamba"]["sha256"]["osx-arm64"]}
    assert environment.sha256_file(environment.MICROMAMBA_RESOURCE) == lock["micromamba"]["sha256"]
    for entry in lock["environments"]:
        assert entry["packageSpec"] == specs[entry["name"]], f"{entry['name']} needs `environment.py lock`"
        packages = environment.explicit_packages(lock, entry["name"])
        assert len(packages) == entry["packages"]
        assert any(environment._package_matches_spec(p, entry["packageSpec"]) for p in packages)


def test_committed_lock_databases_match_the_classifier_fingerprints():
    lock = environment.load_lock()
    golden = json.loads((ROOT / "Tests" / "Fixtures" / "golden" / "classifiers" / "environment.json").read_text())
    by_name = {entry["name"]: entry for entry in lock["databases"]}
    for key in ("kraken2Database", "esvirituDatabase"):
        fingerprint = golden[key]
        entry = by_name[fingerprint["name"]]
        for field in ("tool", "version", "path", "files"):
            assert entry[field] == fingerprint[field], f"{entry['name']} {field}"


def test_captures_point_the_cli_at_the_locked_storage():
    context = captures.CaptureContext(name="mapping", repo_root=ROOT, cli=None, run_root=Path("/x/run"),
                                      cache_root=Path("/x/cache"), storage_root=environment.STORAGE_ROOT)
    env = context.environment()
    assert env["LUNGFISH_STORAGE_ROOT"] == "/Users/Shared/lungfish-golden/storage"
    assert env["LUNGFISH_CONDA_SHARED_PKGS"] == "0"


def test_lock_database_records_the_installed_files(tmp_path):
    lock, _ = small_lock(tmp_path, [])
    storage = provisioned(tmp_path, lock, [])
    (storage / "databases" / "kraken2" / "viral" / "hash.k2d").write_bytes(b"a newer build")
    assert environment.lock_database(lock, "Viral", storage) is True
    assert lock["databases"][0]["files"] == {
        "hash.k2d": {"bytes": 13, "sha256": hashlib.sha256(b"a newer build").hexdigest()}}
    lock["databases"][0]["exactFiles"] = True
    environment.lock_database(lock, "Viral", storage)
    assert set(lock["databases"][0]["files"]) == {"hash.k2d", "inspect.txt"}


def test_the_golden_home_is_group_writable_and_passes_its_group_on(tmp_path):
    home = tmp_path / "lungfish-golden"
    environment.prepare_golden_home(home)
    assert home.stat().st_mode & 0o7777 == 0o2775


def test_derived_database_files_are_made_with_a_locked_environment(tmp_path):
    lock, _ = small_lock(tmp_path, [])
    storage = provisioned(tmp_path, lock, [])
    tool_bin = storage / "conda" / "envs" / "tool" / "bin"
    tool_bin.mkdir()
    (tool_bin / "index").write_text('#!/bin/sh\ntr a-z A-Z < "$1" > "$1.idx"\n')
    (tool_bin / "index").chmod(0o755)
    entry = lock["databases"][0]
    entry["derivedFiles"] = [{"file": "hash.k2d.idx", "environment": "tool", "command": ["index", "hash.k2d"]}]
    environment.derive_files(storage, entry, environment.database_path(storage, entry))
    assert (environment.database_path(storage, entry) / "hash.k2d.idx").read_bytes() == b"DATABASE BYTES"

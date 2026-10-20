"""Tests for the golden environment lock (scripts/golden/environment.py)."""

from __future__ import annotations

import hashlib
import json
import os
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


def test_a_test_only_environment_is_locked_only_by_name_and_only_by_solving(tmp_path):
    lock, lock_dir = small_lock(tmp_path, [])
    specs = "conda-forge::python=3.12 conda-forge::numpy"
    lock["environments"].append({"name": "oracle", "packageSpec": specs, "explicit": "oracle-osx-arm64-explicit.txt",
                                 "sha256": "", "packages": 0, "testOnly": True})
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"tools": [{"environment": "tool", "packageSpec": "bioconda::tool=1.0=h0_0"}]}))
    assert environment.default_lock_names(lock) == ["tool"]
    try:
        environment.lock_environments(lock, ["oracle"], source=tmp_path / "source", lock_dir=lock_dir,
                                      manifest_path=manifest)
    except environment.LockError as error:
        assert "test-only" in str(error)
    else:
        raise AssertionError("locked a test-only environment from a storage root")
    fake = [environment.Package(f"{CHANNEL}/{name}-1.0-h0_0.conda", hashlib.md5(name.encode()).hexdigest())
            for name in ("python", "numpy")]
    asked = []

    def fake_solve(spec):
        asked.append(spec)
        return fake

    real = environment.solved_packages
    environment.solved_packages = fake_solve
    try:
        changed = environment.lock_environments(lock, ["oracle"], source=None, lock_dir=lock_dir,
                                                manifest_path=manifest)
    finally:
        environment.solved_packages = real
    entry = lock["environments"][1]
    assert changed == ["oracle"] and asked == [specs]
    assert entry["packageSpec"] == specs and entry["packages"] == 2 and entry["testOnly"] is True
    assert environment.explicit_packages(lock, "oracle", lock_dir) == fake


def test_an_environment_the_manifest_lacks_needs_testonly(tmp_path):
    lock, lock_dir = small_lock(tmp_path, [])
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"tools": []}))
    try:
        environment.lock_environments(lock, ["tool"], source=None, lock_dir=lock_dir, manifest_path=manifest)
    except environment.LockError as error:
        assert "manifest has no environment named tool" in str(error)
    else:
        raise AssertionError("locked an environment that the manifest does not pin")


def test_solve_hands_micromamba_each_spec_as_its_own_argument(tmp_path):
    fake = tmp_path / "micromamba"
    fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$(dirname "$0")/argv.txt"\n'
                    'echo \'{"actions": {"LINK": [{"url": "https://example.invalid/a-1.0-h0_0.conda", "md5": "00"}]}}\'\n')
    fake.chmod(0o755)
    packages = environment.solved_packages("conda-forge::python=3.12 conda-forge::numpy", micromamba=fake)
    assert [p.url for p in packages] == ["https://example.invalid/a-1.0-h0_0.conda"]
    assert (tmp_path / "argv.txt").read_text().splitlines()[-2:] == ["conda-forge::python=3.12", "conda-forge::numpy"]


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


def lge_installed(tmp_path: Path) -> tuple[dict, Path, Path]:
    """A provisioned storage whose Viral row and receipt look as LGE's update flow leaves them."""
    lock, lock_dir = small_lock(tmp_path, [])
    storage = provisioned(tmp_path, lock, [])
    folder = storage / "databases" / "kraken2" / "viral"
    digest = environment.payload_aggregate(folder)
    lock["databases"][0]["payloadDigest"] = digest
    receipt = folder / environment.RECEIPT_NAME
    receipt.write_text(json.dumps({"workflowName": "metagenomics.database.install", "options": {"resolvedDefaults": {
        "payloadAggregateSHA256": {"type": "string", "value": digest},
        "intendedFinalPath": {"type": "string", "value": str(folder)}}}}))
    registry = storage / "databases" / environment.REGISTRY_NAME
    data = json.loads(registry.read_text())
    data["databases"][0].update({"payloadDigest": digest, "canonicalReceiptSHA256": environment.sha256_file(receipt),
                                 "installedAt": "2026-10-20T14:22:05Z"})
    registry.write_text(json.dumps(data))
    return lock, storage, folder


def test_the_payload_aggregate_is_lges_line_digest_without_the_receipt(tmp_path):
    folder = tmp_path / "db"
    (folder / "sub").mkdir(parents=True)
    (folder / "b.k2d").write_bytes(b"bb")
    (folder / "sub" / "a.txt").write_bytes(b"a")
    (folder / environment.RECEIPT_NAME).write_text("{}")
    (folder / ".install-1").mkdir()
    (folder / ".install-1" / "c").write_bytes(b"c")
    lines = (f"b.k2d\t{hashlib.sha256(b'bb').hexdigest()}\t2\n"
             f"sub/a.txt\t{hashlib.sha256(b'a').hexdigest()}\t1\n")
    assert environment.payload_aggregate(folder) == hashlib.sha256(lines.encode()).hexdigest()


def test_a_database_lge_installed_verifies_with_its_receipt_as_an_extra_file(tmp_path):
    lock, storage, _ = lge_installed(tmp_path)
    assert environment.database_file_problems(storage, lock["databases"][0]) == []
    assert environment.registry_problems(lock, storage) == []


def test_a_database_lge_installed_names_each_drift(tmp_path):
    lock, storage, folder = lge_installed(tmp_path)
    (folder / "inspect.txt").write_text("edited\n")
    assert environment.registry_problems(lock, storage) == [
        "database Viral: the files do not add up to the payloadDigest in lock.json"]
    (folder / environment.RECEIPT_NAME).write_text("{}")
    assert environment.registry_problems(lock, storage) == [
        "registry row Viral: canonicalReceiptSHA256 is not the sha256 of .lungfish-provenance.json",
        "database Viral: the install receipt names another payload or folder",
        "database Viral: the files do not add up to the payloadDigest in lock.json"]
    (folder / environment.RECEIPT_NAME).unlink()
    assert environment.registry_problems(lock, storage)[0].startswith(
        "database Viral lacks the install receipt .lungfish-provenance.json (install it with "
        "lungfish-cli conda db update kraken2-viral --yes")


def test_provision_keeps_the_row_lge_wrote_and_never_writes_a_digest(tmp_path):
    lock, storage, _ = lge_installed(tmp_path)
    environment.write_registry(lock, storage)
    registry = storage / "databases" / environment.REGISTRY_NAME
    row = json.loads(registry.read_text())["databases"][0]
    assert row["installedAt"] == "2026-10-20T14:22:05Z"
    assert environment.registry_problems(lock, storage) == []
    lock["databases"][0]["payloadDigest"] = "0" * 64
    environment.write_registry(lock, storage)
    row = json.loads(registry.read_text())["databases"][0]
    assert "payloadDigest" not in row and "installedAt" not in row
    assert environment.registry_problems(lock, storage)[0].startswith(
        f"registry row Viral: payloadDigest is None, expected {'0' * 64!r} from LGE's installer")


def test_committed_lock_gives_the_kraken2_viral_database_the_digest_lge_recorded():
    by_name = {entry["name"]: entry for entry in environment.load_lock()["databases"]}
    assert by_name[captures.KRAKEN2_DATABASE]["payloadDigest"] == (
        "7872e5a8f683cbaaeda12cc9f3cfe4bb4ef08ef77a5f4647b83bbfe9cbc88c01")
    assert "payloadDigest" not in by_name[captures.ESVIRITU_DATABASE]


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
        packages = environment.explicit_packages(lock, entry["name"])
        assert len(packages) == entry["packages"]
        if environment.is_test_only(entry):
            assert entry["name"] not in specs, f"{entry['name']} is in the manifest, so drop testOnly"
            locked = {p.url.rsplit("/", 1)[-1].rsplit("-", 2)[0] for p in packages}
            for spec in entry["packageSpec"].split():
                assert spec.partition("::")[2].split("=")[0] in locked, f"{entry['name']} lacks {spec}"
            continue
        assert entry["packageSpec"] == specs[entry["name"]], f"{entry['name']} needs `environment.py lock`"
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
    # prepare_golden_home sets the process umask for the golden run that
    # follows it, so restore it here or every later test file in this
    # pytest process makes group-writable folders.
    previous = os.umask(0o022)
    try:
        environment.prepare_golden_home(home)
    finally:
        os.umask(previous)
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


def test_share_tree_lets_the_group_replace_what_this_account_wrote(tmp_path):
    history = tmp_path / "run" / ".lungfish-operation-history" / "a"
    history.mkdir(parents=True)
    (history / "row.json").write_text("{}")
    (history / "row.json").chmod(0o600)  # as lungfish-cli writes them
    history.chmod(0o700)
    history.parent.chmod(0o755)
    (tmp_path / "run" / "link").symlink_to("/nonexistent")
    environment.share_tree(tmp_path / "run")
    assert history.stat().st_mode & 0o7777 == 0o2770
    assert history.parent.stat().st_mode & 0o7777 == 0o2775
    assert (history / "row.json").stat().st_mode & 0o777 == 0o660

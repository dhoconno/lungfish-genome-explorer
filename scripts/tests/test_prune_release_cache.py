"""Behavior tests for the explicit release compiler-cache pruning command."""

from __future__ import annotations

import contextlib
import fcntl
import importlib.util
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release" / "prune-release-cache.py"
HELPER = ROOT / "scripts" / "release" / "release_cache_fingerprint.py"
# The command imports its sibling helper by plain name, as the other release scripts do.
sys.path.insert(0, str(ROOT / "scripts" / "release"))

import release_cache_fingerprint  # noqa: E402

KEY_A = "a" * 64
KEY_B = "b" * 64
MARKER = ".lungfish-release-cache.json"
LOCK = ".build.lock"
NOW = 1_760_000_000
DAY = 86_400
GIB = 1 << 30
# The default keeps two namespaces per repository key (Preview and Stable use different
# ones). A test about removal, locks or layout needs exactly one stale namespace, so it
# asks to keep one. The default itself is pinned in DefaultKeepTests.
KEEP_ONE = ("--keep", "1")


def load_module():
    spec = importlib.util.spec_from_file_location("prune_release_cache", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fingerprint(number: int) -> str:
    """A valid 64-character fingerprint whose 12-character prefix is unique."""
    return f"{number:x}" * 64


def stamp(namespace: Path, *, directory: int, marker: int, lock: int) -> None:
    """Set the three mtimes that decide a namespace's last-used time."""
    os.utime(namespace / MARKER, (marker, marker))
    if (namespace / LOCK).exists():
        os.utime(namespace / LOCK, (lock, lock))
    os.utime(namespace, (directory, directory))  # last, creating children moves it


def make_namespace(root: Path, key: str, name: str, *, last_used: int) -> Path:
    """Imitate what prepare_cache_namespace and a finished build leave behind."""
    repository = root / "v1" / key
    namespace = repository / name
    for directory in (
        root,
        root / "v1",
        repository,
        namespace,
        namespace / "swiftpm",
        namespace / "derived-data",
    ):
        directory.mkdir(mode=0o700, exist_ok=True)
    (namespace / MARKER).write_text("{}\n", encoding="utf-8")
    (namespace / MARKER).chmod(0o600)
    (namespace / LOCK).touch(mode=0o600)
    (namespace / "derived-data" / "intermediate.o").write_bytes(b"\x01" * 4096)
    stamp(namespace, directory=last_used, marker=last_used, lock=last_used)
    return namespace


class ForeignOwner:
    """A stat result that reports a different owner and is otherwise unchanged."""

    def __init__(self, real: os.stat_result) -> None:
        self._real = real
        self.st_uid = real.st_uid + 1

    def __getattr__(self, name: str):
        return getattr(self._real, name)


@contextlib.contextmanager
def held_lock(namespace: Path):
    """Hold the namespace build lock the way a running build does."""
    descriptor = os.open(namespace / LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


class PruneTestCase(unittest.TestCase):
    def setUp(self):
        self.prune = load_module()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "cache"

    def namespace(self, key: str, number: int, *, age_days: float) -> Path:
        return make_namespace(
            self.root, key, fingerprint(number), last_used=int(NOW - age_days * DAY)
        )

    def prune_cache(self, *flags: str, root: Path | None = None) -> tuple[int, str, str]:
        return self.main("--cache-root", str(root or self.root), *flags)

    def main(self, *arguments: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = self.prune.main(list(arguments))
        return code, out.getvalue(), err.getvalue()

    @staticmethod
    def actions(output: str) -> dict[str, str]:
        """Map each listed fingerprint prefix to KEEP or REMOVE."""
        row = re.compile(
            r"^(?P<key>[0-9a-f]{12})\s+(?P<fingerprint>[0-9a-f]{12})\s+"
            r"\d+\.\d GiB\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}\s+(?P<action>KEEP|REMOVE)$"
        )
        found = {}
        for line in output.splitlines():
            match = row.match(line)
            if match:
                found[match["key"] + "/" + match["fingerprint"]] = match["action"]
        return found


class ListingTests(PruneTestCase):
    def test_dry_run_reports_the_keep_and_remove_split_and_deletes_nothing(self):
        newest = self.namespace(KEY_A, 1, age_days=1)
        middle = self.namespace(KEY_A, 2, age_days=5)
        oldest = self.namespace(KEY_A, 3, age_days=9)
        cases = (
            ("the default", (), ("KEEP", "KEEP", "REMOVE"), "would remove 1 namespace and reclaim 2.0 GiB"),
            ("--keep 1", KEEP_ONE, ("KEEP", "REMOVE", "REMOVE"), "would remove 2 namespaces and reclaim 4.0 GiB"),
        )
        for label, flags, actions, summary in cases:
            with self.subTest(label):
                with mock.patch.object(self.prune, "tree_size_bytes", return_value=2 * GIB):
                    code, out, err = self.prune_cache(*flags)

                self.assertEqual((code, err), (0, ""))
                self.assertEqual(
                    self.actions(out),
                    {f"{KEY_A[:12]}/{fingerprint(number)[:12]}": action for number, action in zip((1, 2, 3), actions)},
                )
                self.assertIn(summary, out)
                self.assertIn("Nothing was deleted", out)
                self.assertTrue(all(path.is_dir() for path in (newest, middle, oldest)))
                self.assertEqual(len(list((self.root / "v1" / KEY_A).iterdir())), 3)

    def test_listing_row_shows_size_with_one_decimal_and_the_last_used_time(self):
        self.namespace(KEY_A, 1, age_days=3)

        with mock.patch.object(
            self.prune, "tree_size_bytes", return_value=int(3.96 * GIB)
        ):
            _, out, _ = self.prune_cache()

        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(NOW - 3 * DAY))
        self.assertRegex(
            out,
            rf"(?m)^{KEY_A[:12]}\s+{fingerprint(1)[:12]}\s+4\.0 GiB\s+{when}\s+KEEP$",
        )

    def test_last_used_is_the_newest_of_directory_marker_and_lock(self):
        # Each of the three must matter on its own: without it, the namespace
        # would rank below the old one and be removed instead.
        by_lock = self.namespace(KEY_A, 1, age_days=40)
        by_marker = self.namespace(KEY_A, 2, age_days=40)
        by_directory = self.namespace(KEY_A, 3, age_days=40)
        old = self.namespace(KEY_A, 4, age_days=30)
        stamp(by_lock, directory=NOW - 40 * DAY, marker=NOW - 40 * DAY, lock=NOW)
        stamp(
            by_marker,
            directory=NOW - 40 * DAY,
            marker=NOW - 1 * DAY,
            lock=NOW - 40 * DAY,
        )
        stamp(
            by_directory,
            directory=NOW - 2 * DAY,
            marker=NOW - 40 * DAY,
            lock=NOW - 40 * DAY,
        )

        code, out, _ = self.prune_cache("--keep", "3")

        self.assertEqual(code, 0)
        self.assertEqual(
            self.actions(out),
            {
                f"{KEY_A[:12]}/{fingerprint(1)[:12]}": "KEEP",
                f"{KEY_A[:12]}/{fingerprint(2)[:12]}": "KEEP",
                f"{KEY_A[:12]}/{fingerprint(3)[:12]}": "KEEP",
                f"{KEY_A[:12]}/{fingerprint(4)[:12]}": "REMOVE",
            },
        )
        self.assertTrue(old.is_dir())

    def test_equal_last_used_times_resolve_the_same_way_every_run(self):
        first = self.namespace(KEY_A, 1, age_days=2)
        second = self.namespace(KEY_A, 2, age_days=2)

        _, dry_run, _ = self.prune_cache(*KEEP_ONE)
        code, _, _ = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual(
            self.actions(dry_run),
            {
                f"{KEY_A[:12]}/{fingerprint(1)[:12]}": "KEEP",
                f"{KEY_A[:12]}/{fingerprint(2)[:12]}": "REMOVE",
            },
        )
        self.assertEqual(code, 0)
        self.assertTrue(first.is_dir())
        self.assertFalse(second.exists())

    def test_a_missing_cache_root_is_nothing_to_do(self):
        code, out, err = self.prune_cache("--apply")

        self.assertEqual((code, err), (0, ""))
        self.assertIn("nothing to do", out)
        self.assertFalse(self.root.exists())


class ApplyTests(PruneTestCase):
    def test_apply_keeps_the_newest_and_removes_the_rest(self):
        newest = self.namespace(KEY_A, 1, age_days=1)
        middle = self.namespace(KEY_A, 2, age_days=5)
        oldest = self.namespace(KEY_A, 3, age_days=9)

        with mock.patch.object(self.prune, "tree_size_bytes", return_value=2 * GIB):
            code, out, err = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual((code, err), (0, ""))
        self.assertTrue(newest.is_dir())
        self.assertFalse(middle.exists())
        self.assertFalse(oldest.exists())
        self.assertIn("Reclaimed 4.0 GiB from 2 namespaces.", out)
        # The repository key directory, v1 and the root are never removed.
        self.assertTrue((self.root / "v1" / KEY_A).is_dir())

    def test_keep_retains_that_many_per_repository_key(self):
        namespaces = [self.namespace(KEY_A, n, age_days=n) for n in (1, 2, 3, 4)]

        code, _, _ = self.prune_cache("--keep", "2", "--apply")

        self.assertEqual(code, 0)
        self.assertEqual([path.exists() for path in namespaces], [True, True, False, False])

    def test_keeping_at_least_as_many_as_exist_removes_nothing(self):
        namespaces = [self.namespace(KEY_A, n, age_days=n) for n in (1, 2)]

        code, out, _ = self.prune_cache("--keep", "2", "--apply")

        self.assertEqual(code, 0)
        self.assertIn("Nothing to remove", out)
        self.assertTrue(all(path.is_dir() for path in namespaces))

    def test_repository_keys_are_pruned_independently(self):
        a_new = self.namespace(KEY_A, 1, age_days=1)
        a_mid = self.namespace(KEY_A, 2, age_days=2)
        a_old = self.namespace(KEY_A, 3, age_days=3)
        # Every B namespace is older than every A namespace.
        b_new = self.namespace(KEY_B, 4, age_days=50)
        b_old = self.namespace(KEY_B, 5, age_days=60)
        namespaces = (a_new, a_mid, a_old, b_new, b_old)

        code, out, _ = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual(code, 0)
        self.assertEqual([path.exists() for path in namespaces], [True, False, False, True, False])
        self.assertIn("Reclaimed", out)

    def test_each_repository_key_keeps_its_own_two_by_default(self):
        a_new = self.namespace(KEY_A, 1, age_days=1)
        a_mid = self.namespace(KEY_A, 2, age_days=2)
        a_old = self.namespace(KEY_A, 3, age_days=3)
        b_new = self.namespace(KEY_B, 4, age_days=50)
        b_mid = self.namespace(KEY_B, 5, age_days=60)
        b_old = self.namespace(KEY_B, 6, age_days=70)

        code, _, _ = self.prune_cache("--apply")

        self.assertEqual(code, 0)
        self.assertEqual(
            [path.exists() for path in (a_new, a_mid, a_old, b_new, b_mid, b_old)],
            [True, True, False, True, True, False],
            "the older key's namespaces are not crowded out by the newer key's",
        )

    def test_removal_happens_while_holding_the_namespace_lock(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        fresh = self.namespace(KEY_A, 2, age_days=1)
        removed = []
        real_rmtree = shutil.rmtree

        def rmtree_that_checks_the_lock(path, *args, **kwargs):
            descriptor = os.open(Path(path) / LOCK, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(descriptor)
            removed.append(Path(path))
            real_rmtree(path, *args, **kwargs)

        with mock.patch.object(
            self.prune.shutil, "rmtree", side_effect=rmtree_that_checks_the_lock
        ):
            code, _, _ = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual(code, 0)
        # Exactly the validated namespace, never a parent directory.
        self.assertEqual(removed, [stale])
        self.assertTrue(fresh.is_dir())

    def test_a_namespace_that_was_never_locked_is_still_removed(self):
        self.namespace(KEY_A, 1, age_days=1)
        stale = self.namespace(KEY_A, 2, age_days=9)
        (stale / LOCK).unlink()  # a prepared namespace no build has locked yet
        stamp(stale, directory=NOW - 9 * DAY, marker=NOW - 9 * DAY, lock=0)

        code, _, err = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual((code, err), (0, ""))
        self.assertFalse(stale.exists())

    def test_a_lock_taken_during_removal_stops_the_run_with_75(self):
        self.namespace(KEY_A, 1, age_days=1)
        oldest = self.namespace(KEY_A, 2, age_days=9)
        middle = self.namespace(KEY_A, 3, age_days=5)
        real_remove = self.prune.remove_namespace
        builds = []

        def remove_after_a_build_starts_on_the_middle_one(namespace, uid):
            if namespace.path == oldest:
                # A build starts on the next namespace after the probe passed.
                descriptor = os.open(middle / LOCK, os.O_RDWR)
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                builds.append(descriptor)
            real_remove(namespace, uid)

        try:
            with mock.patch.object(
                self.prune, "remove_namespace", remove_after_a_build_starts_on_the_middle_one
            ):
                code, out, err = self.prune_cache(*KEEP_ONE, "--apply")
        finally:
            for descriptor in builds:
                os.close(descriptor)

        self.assertEqual(code, 75)
        self.assertFalse(oldest.exists())
        self.assertTrue(middle.is_dir())
        self.assertIn(str(middle), err)
        self.assertIn("Reclaimed", out)


    def test_a_failed_removal_stops_the_run_with_status_1_and_says_how_to_recover(self):
        self.namespace(KEY_A, 1, age_days=1)
        stale = self.namespace(KEY_A, 2, age_days=9)
        denied = PermissionError(13, "Permission denied", str(stale))

        with mock.patch.object(self.prune.shutil, "rmtree", side_effect=denied):
            code, out, err = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual(code, 1)
        self.assertIn(f"could not remove {stale}", err)
        self.assertIn("by hand", err)
        self.assertIn("Reclaimed 0.0 GiB from 0 namespaces.", out)
        self.assertTrue(stale.is_dir())


class RefusalTests(PruneTestCase):
    def test_a_held_lock_refuses_the_whole_run_and_deletes_nothing(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        fresh = self.namespace(KEY_A, 2, age_days=1)

        for label, busy in (("a removal candidate", stale), ("a kept namespace", fresh)):
            for flags in ((), ("--apply",)):
                with self.subTest(busy=label, flags=flags), held_lock(busy):
                    code, out, err = self.prune_cache(*KEEP_ONE, *flags)
                    self.assertEqual(code, 75)
                    self.assertIn(f"busy: {busy}", err)
                    self.assertIn("Nothing was removed", err)
                    self.assertEqual(out, "")
                    self.assertTrue(stale.is_dir() and fresh.is_dir())

        # The probes left nothing locked: once the build is gone the run succeeds.
        code, _, _ = self.prune_cache(*KEEP_ONE, "--apply")
        self.assertEqual(code, 0)
        self.assertFalse(stale.exists())

    def test_every_busy_namespace_is_named(self):
        first = self.namespace(KEY_A, 1, age_days=9)
        second = self.namespace(KEY_B, 2, age_days=1)

        with held_lock(first), held_lock(second):
            code, _, err = self.prune_cache("--apply")

        self.assertEqual(code, 75)
        self.assertIn(f"busy: {first}", err)
        self.assertIn(f"busy: {second}", err)

    def test_unrecognized_entries_are_ignored_and_survive(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        fresh = self.namespace(KEY_A, 2, age_days=1)
        v1 = self.root / "v1"
        repository = v1 / KEY_A
        survivors = {
            "v1/not-a-key": v1 / "not-a-key",
            "uppercase key": v1 / ("C" * 64),
            "63 hex digits": repository / ("c" * 63),
            "not a fingerprint": repository / "not-a-fingerprint",
            "no marker": repository / fingerprint(3),
            "marker is a directory": repository / fingerprint(4),
            "root level directory": self.root / "v2",
        }
        for path in survivors.values():
            path.mkdir()
            (path / "precious").write_text("keep", encoding="utf-8")
        (repository / fingerprint(3) / "derived-data").mkdir()
        (repository / fingerprint(4) / MARKER).mkdir()
        plain_files = {
            "namespace-sized file": repository / fingerprint(5),
            "key-sized file": v1 / KEY_B,
            "root level file": self.root / "notes.txt",
        }
        for path in plain_files.values():
            path.write_text("keep", encoding="utf-8")
        # A convenience link with an ordinary name is ignored, never followed.
        shortcut = repository / "latest"
        shortcut.symlink_to(fresh, target_is_directory=True)

        code, out, err = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual((code, err), (0, ""))
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.is_dir())
        self.assertEqual(shortcut.resolve(), fresh)
        for label, path in survivors.items():
            self.assertTrue((path / "precious").is_file(), label)
        for label, path in plain_files.items():
            self.assertEqual(path.read_text(encoding="utf-8"), "keep", label)
        ignored = [line for line in out.splitlines() if line.startswith("ignored")]
        self.assertEqual(len(ignored), len(survivors) + len(plain_files) + 1)
        self.assertTrue(any("not-a-key" in line for line in ignored))
        self.assertTrue(any("notes.txt" in line for line in ignored))
        self.assertTrue(any("latest" in line for line in ignored))
        self.assertEqual(len(self.actions(out)), 2)  # the link is not a third namespace

    @staticmethod
    def snapshot(directory: Path) -> list[str]:
        """Every path under directory, links listed but never followed."""
        found = []
        for current, directories, files in os.walk(directory):
            found.extend(
                str(Path(current, name).relative_to(directory))
                for name in (*directories, *files)
            )
        return sorted(found)

    def test_symlinks_are_refused_at_every_level_and_nothing_is_touched(self):
        # Each case moves one level out of the cache and leaves a symlink to it
        # behind, so following the link would find a perfectly valid cache.
        levels = {
            "namespace": lambda stale: stale,
            "repository key": lambda stale: stale.parent,
            "v1": lambda stale: stale.parent.parent,
            "cache root": lambda stale: stale.parent.parent.parent,
            "marker": lambda stale: stale / MARKER,
            "lock": lambda stale: stale / LOCK,
        }
        for level, choose in levels.items():
            with self.subTest(level=level):
                workspace = self.base / level.replace(" ", "-")
                workspace.mkdir()
                self.root = workspace / "cache"
                self.namespace(KEY_A, 1, age_days=1)
                stale = self.namespace(KEY_A, 2, age_days=9)
                self.namespace(KEY_B, 3, age_days=9)
                target = choose(stale)
                moved = workspace / "moved"
                target.rename(moved)
                target.symlink_to(moved, target_is_directory=moved.is_dir())
                before = self.snapshot(workspace)

                code, out, err = self.prune_cache("--apply")

                self.assertEqual(code, 64, err)
                self.assertIn("is a symlink", err)
                self.assertIn("Nothing was removed", err)
                self.assertEqual(out, "")
                # The whole run is refused, so even healthy stale namespaces stay.
                self.assertEqual(self.snapshot(workspace), before)

    def test_a_namespace_owned_by_someone_else_is_refused(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        fresh = self.namespace(KEY_A, 2, age_days=1)

        with mock.patch.object(self.prune, "current_uid", return_value=os.geteuid() + 1):
            code, out, err = self.prune_cache("--apply")

        self.assertEqual(code, 64)
        self.assertIn("not owned by the current user", err)
        self.assertEqual(out, "")
        self.assertTrue(stale.is_dir() and fresh.is_dir())

    def test_a_foreign_owner_is_refused_at_every_level(self):
        # chown needs root, so present one path at a time as owned by someone else.
        levels = {
            "cache root": lambda stale: stale.parent.parent.parent,
            "v1": lambda stale: stale.parent.parent,
            "repository key": lambda stale: stale.parent,
            "namespace": lambda stale: stale,
            "marker": lambda stale: stale / MARKER,
            "lock": lambda stale: stale / LOCK,
        }
        real_lstat = Path.lstat
        for level, choose in levels.items():
            with self.subTest(level=level):
                workspace = self.base / level.replace(" ", "-")
                workspace.mkdir()
                self.root = workspace / "cache"
                fresh = self.namespace(KEY_A, 1, age_days=1)
                stale = self.namespace(KEY_A, 2, age_days=9)
                foreign = choose(stale)

                def lstat_with_a_foreign_owner(path, *, _foreign=foreign):
                    status = real_lstat(path)
                    return ForeignOwner(status) if path == _foreign else status

                with mock.patch.object(Path, "lstat", lstat_with_a_foreign_owner):
                    code, out, err = self.prune_cache("--apply")

                self.assertEqual(code, 64, err)
                self.assertIn("is not owned by the current user", err)
                self.assertIn("Nothing was removed", err)
                self.assertEqual(out, "")
                self.assertTrue(fresh.is_dir() and stale.is_dir())

    @unittest.skipIf(os.geteuid() == 0, "root can read every directory")
    def test_an_unreadable_directory_inside_a_namespace_refuses_the_run(self):
        self.namespace(KEY_A, 1, age_days=1)
        stale = self.namespace(KEY_A, 2, age_days=9)
        unreadable = stale / "derived-data" / "unreadable"
        unreadable.mkdir()
        unreadable.chmod(0o000)
        self.addCleanup(unreadable.chmod, 0o700)

        code, _, err = self.prune_cache("--apply")

        self.assertEqual(code, 64)
        self.assertIn("cannot read", err)
        self.assertIn("Nothing was removed", err)
        self.assertTrue(stale.is_dir())

    def test_a_namespace_that_changes_after_the_scan_is_not_removed(self):
        self.namespace(KEY_A, 1, age_days=1)
        stale = self.namespace(KEY_A, 2, age_days=9)
        real_listing = self.prune.print_listing
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "precious").write_text("keep", encoding="utf-8")

        def swap_in_a_symlink_after_scanning(scan, removals):
            sizes = real_listing(scan, removals)
            shutil.rmtree(stale)
            stale.symlink_to(outside, target_is_directory=True)
            return sizes

        with mock.patch.object(self.prune, "print_listing", swap_in_a_symlink_after_scanning):
            code, _, err = self.prune_cache(*KEEP_ONE, "--apply")

        self.assertEqual(code, 64)
        self.assertIn("changed since it was scanned", err)
        self.assertEqual((outside / "precious").read_text(encoding="utf-8"), "keep")


class UsageTests(PruneTestCase):
    def test_bad_arguments_are_usage_errors_that_delete_nothing(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        self.namespace(KEY_A, 2, age_days=1)
        cases = {
            "--keep 0": ["--keep", "0"],
            "--keep -1": ["--keep", "-1"],
            "--keep many": ["--keep", "many"],
            "unknown flag": ["--bogus"],
            "stray argument": ["extra"],
            "abbreviated flag": ["--app"],
            "relative cache root": ["--cache-root", "relative/path"],
        }
        for label, arguments in cases.items():
            with self.subTest(label):
                code, out, err = self.main(*arguments, "--apply")
                self.assertEqual(code, 64, err)
                self.assertEqual(out, "")
                self.assertIn("error:", err)
                self.assertTrue(stale.is_dir())

    def test_keep_zero_message_names_the_option(self):
        code, _, err = self.prune_cache("--keep", "0")

        self.assertEqual(code, 64)
        self.assertIn("--keep", err)
        self.assertIn("at least 1", err)

    def test_default_cache_root_is_the_one_the_release_scripts_use(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("LUNGFISH_RELEASE_CACHE_ROOT", None)
            default = self.prune.parse_args([]).cache_root
            os.environ["LUNGFISH_RELEASE_CACHE_ROOT"] = ""
            empty = self.prune.parse_args([]).cache_root
            os.environ["LUNGFISH_RELEASE_CACHE_ROOT"] = str(self.root)
            configured = self.prune.parse_args([]).cache_root
            explicit = self.prune.parse_args(["--cache-root", str(self.base)]).cache_root

        self.assertEqual(default, Path("/private/var/tmp/lungfish-release-cache"))
        self.assertEqual(empty, default)
        self.assertEqual(configured, self.root)
        self.assertEqual(explicit, self.base)

    def test_a_relative_cache_root_in_the_environment_is_a_usage_error(self):
        with mock.patch.dict(os.environ, {"LUNGFISH_RELEASE_CACHE_ROOT": "relative"}):
            code, _, err = self.main()

        self.assertEqual(code, 64)
        self.assertIn("LUNGFISH_RELEASE_CACHE_ROOT", err)


class DefaultKeepTests(PruneTestCase):
    """--keep defaults to 2. Preview and Stable build in different namespaces, so
    the default leaves one release of each channel warm."""

    def test_the_default_is_two_and_an_explicit_count_overrides_it(self):
        self.assertEqual(self.prune.parse_args([]).keep, 2)
        self.assertEqual(self.prune.parse_args(["--keep", "1"]).keep, 1)
        self.assertEqual(self.prune.parse_args(["--keep", "5"]).keep, 5)

    def test_the_two_most_recently_used_namespaces_survive_without_a_flag(self):
        newest = self.namespace(KEY_A, 1, age_days=1)
        second = self.namespace(KEY_A, 2, age_days=5)
        oldest = self.namespace(KEY_A, 3, age_days=9)

        code, out, err = self.prune_cache("--apply")

        self.assertEqual((code, err), (0, ""))
        self.assertTrue(newest.is_dir() and second.is_dir())
        self.assertFalse(oldest.exists())
        self.assertIn("Reclaimed", out)

    def test_two_or_fewer_namespaces_are_all_kept_by_default(self):
        for count in (1, 2):
            with self.subTest(namespaces=count):
                self.root = self.base / f"cache-{count}"
                kept = [self.namespace(KEY_A, number, age_days=number * 20) for number in range(1, count + 1)]

                code, out, err = self.prune_cache("--apply")

                self.assertEqual((code, err), (0, ""))
                self.assertIn("Nothing to remove", out)
                self.assertTrue(all(path.is_dir() for path in kept))

    def test_namespaces_the_builder_prepared_for_both_channels_survive_by_default(self):
        preview = release_cache_fingerprint.prepare_cache_namespace(self.root, KEY_A, {"fixture": "preview"})
        stable = release_cache_fingerprint.prepare_cache_namespace(self.root, KEY_A, {"fixture": "stable"})
        for paths, age in ((preview, 40), (stable, 9)):
            stamp(
                paths.namespace,
                directory=NOW - age * DAY,
                marker=NOW - age * DAY,
                lock=NOW - age * DAY,
            )

        code, out, err = self.prune_cache("--apply")

        self.assertEqual((code, err), (0, ""))
        self.assertIn("Nothing to remove", out)
        self.assertTrue(preview.namespace.is_dir() and stable.namespace.is_dir())

    def test_help_says_the_default_is_two_everywhere_it_states_one(self):
        code, out, _ = self.main("--help")

        stated = re.findall(r"\(default (\d+)", " ".join(out.split()))
        self.assertEqual(code, 0)
        self.assertGreaterEqual(len(stated), 2, "the description and the --keep option both state it")
        self.assertEqual(set(stated), {"2"})


class SizeTests(PruneTestCase):
    def test_size_counts_allocated_bytes_and_never_follows_symlinks(self):
        tree = self.base / "tree"
        (tree / "nested" / "deeper").mkdir(parents=True)
        (tree / "nested" / "deeper" / "big").write_bytes(b"\x01" * (1 << 20))
        (tree / "small").write_bytes(b"x")
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "huge").write_bytes(b"\x02" * (4 << 20))
        (tree / "link").symlink_to(outside, target_is_directory=True)

        size = self.prune.tree_size_bytes(tree)

        self.assertGreaterEqual(size, 1 << 20)
        self.assertLess(size, 2 << 20)  # the 4 MiB behind the link is not counted


class CommandLineTests(PruneTestCase):
    def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=self.base,  # the import of the sibling helper must not depend on cwd
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=60,
        )

    def test_keep_zero_exits_64_as_a_real_process(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        self.namespace(KEY_A, 2, age_days=1)

        result = self.run_script("--cache-root", str(self.root), "--keep", "0", "--apply")

        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("--keep", result.stderr)
        self.assertTrue(stale.is_dir())

    def test_a_held_lock_exits_75_as_a_real_process(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        self.namespace(KEY_A, 2, age_days=1)

        with held_lock(stale):
            result = self.run_script("--cache-root", str(self.root), "--apply")

        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn(f"busy: {stale}", result.stderr)
        self.assertTrue(stale.is_dir())

    def test_dry_run_and_apply_work_as_real_processes(self):
        stale = self.namespace(KEY_A, 1, age_days=9)
        fresh = self.namespace(KEY_A, 2, age_days=1)

        dry = self.run_script("--cache-root", str(self.root), *KEEP_ONE)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertEqual(
            self.actions(dry.stdout),
            {
                f"{KEY_A[:12]}/{fingerprint(2)[:12]}": "KEEP",
                f"{KEY_A[:12]}/{fingerprint(1)[:12]}": "REMOVE",
            },
        )
        self.assertTrue(stale.is_dir())

        applied = self.run_script("--cache-root", str(self.root), *KEEP_ONE, "--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertIn("Reclaimed", applied.stdout)
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.is_dir())

    def test_the_default_keeps_two_as_a_real_process(self):
        newest = self.namespace(KEY_A, 1, age_days=1)
        second = self.namespace(KEY_A, 2, age_days=5)
        oldest = self.namespace(KEY_A, 3, age_days=9)

        dry = self.run_script("--cache-root", str(self.root))
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertEqual(
            self.actions(dry.stdout),
            {
                f"{KEY_A[:12]}/{fingerprint(1)[:12]}": "KEEP",
                f"{KEY_A[:12]}/{fingerprint(2)[:12]}": "KEEP",
                f"{KEY_A[:12]}/{fingerprint(3)[:12]}": "REMOVE",
            },
        )
        applied = self.run_script("--cache-root", str(self.root), "--apply")

        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertTrue(newest.is_dir() and second.is_dir())
        self.assertFalse(oldest.exists())

    def test_help_states_the_safety_rules_and_exit_codes(self):
        result = self.run_script("--help")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Safety rules", result.stdout)
        self.assertIn("75", result.stdout)
        self.assertIn("--apply", result.stdout)


class BuilderCompatibilityTests(PruneTestCase):
    """The layout and lock protocol are the builder's; pin them to the real helper."""

    @staticmethod
    def wait_for_token(path: Path, token: str, timeout: float = 10.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if path.read_text(encoding="utf-8") == token + "\n":
                    return True
            except OSError:
                pass
            time.sleep(0.02)
        return False

    def test_helper_constants_are_the_ones_the_command_uses(self):
        self.assertEqual(self.prune.CACHE_MARKER, release_cache_fingerprint.CACHE_MARKER)
        self.assertEqual(self.prune.CACHE_LOCK, release_cache_fingerprint.CACHE_LOCK)
        self.assertEqual((MARKER, LOCK), (self.prune.CACHE_MARKER, self.prune.CACHE_LOCK))

    def test_namespaces_prepared_by_the_builder_are_recognized_and_a_real_build_lock_blocks_them(self):
        older = release_cache_fingerprint.prepare_cache_namespace(
            self.root, KEY_A, {"fixture": "older"}
        )
        newer = release_cache_fingerprint.prepare_cache_namespace(
            self.root, KEY_A, {"fixture": "newer"}
        )
        for paths, age in ((older, 9), (newer, 1)):
            stamp(
                paths.namespace,
                directory=NOW - age * DAY,
                marker=NOW - age * DAY,
                lock=NOW - age * DAY,
            )

        _, out, err = self.prune_cache(*KEEP_ONE)
        self.assertEqual(err, "")
        self.assertEqual(
            self.actions(out),
            {
                f"{KEY_A[:12]}/{newer.fingerprint[:12]}": "KEEP",
                f"{KEY_A[:12]}/{older.fingerprint[:12]}": "REMOVE",
            },
        )

        ready = older.namespace / (".lock-ready." + "a" * 48)
        token = "1" * 64
        holder = subprocess.Popen(
            [
                sys.executable,
                str(HELPER),
                "hold-lock",
                "--namespace",
                str(older.namespace),
                "--ready-file",
                str(ready),
                "--ready-token",
                token,
                "--parent-pid",
                str(os.getpid()),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            self.assertTrue(self.wait_for_token(ready, token), "builder lock never became ready")
            code, _, err = self.prune_cache(*KEEP_ONE, "--apply")
            self.assertEqual(code, 75, err)
            self.assertIn(f"busy: {older.namespace}", err)
            self.assertTrue(older.namespace.is_dir() and newer.namespace.is_dir())
        finally:
            holder.terminate()
            holder.wait(timeout=10)

        # A build touches its namespace, so restore the intended ages first.
        stamp(
            older.namespace,
            directory=NOW - 9 * DAY,
            marker=NOW - 9 * DAY,
            lock=NOW - 9 * DAY,
        )
        code, _, err = self.prune_cache(*KEEP_ONE, "--apply")
        self.assertEqual((code, err), (0, ""))
        self.assertFalse(older.namespace.exists())
        # What remains is still a namespace the builder accepts.
        again = release_cache_fingerprint.prepare_cache_namespace(
            self.root, KEY_A, {"fixture": "newer"}
        )
        self.assertEqual(again, newer)


if __name__ == "__main__":
    unittest.main()

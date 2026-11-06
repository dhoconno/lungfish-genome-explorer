"""RELEASE-SMOKE-DOCUMENTS-PROMPT.

The signed-app checks of scripts/smoke-test-release-tools.sh run the app's own binaries (micromamba and
lungfish-cli). When the app sits under the user's Documents folder, macOS holds each binary on the prompt
"would like to access files in your Documents folder". A remote or scripted click cannot answer that prompt, so the
publish of Preview 2026.11.1 waited five hours. The checks now run from a copy outside Documents, with a time limit
that fails in words that name the check and the prompt.

Every test runs offline on fakes. The fake app and the working folder sit under a fake home whose Documents folder
is a symlink, so a check that compares path strings and not real paths fails here.
"""
import importlib.util
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "smoke-test-release-tools.sh"
STAGE_MARKER = "lungfish-release-smoke"
TIMEOUT_VARIABLE = "LUNGFISH_RELEASE_SMOKE_CHECK_TIMEOUT_SECONDS"


def load_fake_app_builder():
    """The fake app of test_release_smoke.py, loaded by path so its tests are not collected twice."""
    spec = importlib.util.spec_from_file_location(
        "lungfish_release_smoke_fake_app", Path(__file__).with_name("test_release_smoke.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.ReleaseSmokeTests


def real_inside(path, folder):
    path, folder = os.path.realpath(path), os.path.realpath(folder)
    return path == folder or path.startswith(folder + os.sep)


RECORD = (
    "#!/bin/sh\n"
    "printf '%s\\t%s\\t%s\\n' \"$0\" \"$(pwd -P)\" \"$*\" >> \"$LUNGFISH_TEST_RUN_LOG\"\n"
)
CLI_HANG = (
    "if [ -n \"${LUNGFISH_TEST_CLI_HANG:-}\" ] && [ \"${1:-}\" = \"$LUNGFISH_TEST_CLI_HANG\" ]; then\n"
    "  echo $$ > \"$LUNGFISH_TEST_PID_FILE\"\n"
    "  exec sleep 600\n"
    "fi\n"
)


class ReleaseSmokeLocationTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        temp = Path(self._temp.name).resolve()
        self.home = temp / "home"
        self.documents_target = temp / "target-folder"
        self.documents_target.mkdir(parents=True)
        self.home.mkdir()
        # The user's Documents folder is a symlink, so only a real-path comparison can see where a path leads.
        self.documents = self.home / "Documents"
        self.documents.symlink_to(self.documents_target)
        self.work = self.documents / "worktree"
        self.work.mkdir()
        self.tmpdir = self.documents / "tmp"
        self.tmpdir.mkdir()
        self.cache = temp / "cache"
        self.cache.mkdir()
        self.run_log = temp / "runs.log"
        self.py_log = temp / "python.log"
        self.pid_file = temp / "hung.pid"
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        self.python = bin_dir / "release-python"
        self.python.write_text(
            "#!/bin/sh\n"
            "printf '%s\\t%s\\t%s\\n' \"$0\" \"$(pwd -P)\" \"$*\" >> \"$LUNGFISH_TEST_PY_LOG\"\n"
            "exec " + shlex.quote(sys.executable) + " \"$@\"\n"
        )
        self.python.chmod(0o755)
        builder = load_fake_app_builder()
        self.app = builder._make_minimal_app(
            None, self.work, include_icon=True, include_cli=True,
            notices=builder._sample_notices(None),
        )
        self._record_runs()

    def _record_runs(self):
        cli = self.app / "Contents" / "MacOS" / "lungfish-cli"
        cli.write_text(RECORD + CLI_HANG + cli.read_text().split("\n", 1)[1])
        micromamba = (
            self.app / "Contents" / "Resources" / "LungfishGenomeBrowser_LungfishWorkflow.bundle"
            / "Tools" / "micromamba"
        )
        micromamba.write_text(RECORD + micromamba.read_text().split("\n", 1)[1])

    def _environment(self, **extra):
        environment = dict(os.environ)
        environment.pop(TIMEOUT_VARIABLE, None)
        environment.update(
            HOME=str(self.home), TMPDIR=str(self.tmpdir),
            LUNGFISH_RELEASE_PYTHON=str(self.python),
            LUNGFISH_RELEASE_CACHE_ROOT=str(self.cache),
            LUNGFISH_TEST_RUN_LOG=str(self.run_log), LUNGFISH_TEST_PY_LOG=str(self.py_log),
            LUNGFISH_TEST_PID_FILE=str(self.pid_file),
        )
        environment.update(extra)
        return environment

    def run_smoke(self, limit=90, **extra):
        """Runs the smoke from a working folder under Documents, the way release.py and the builder do."""
        started = time.monotonic()
        process = subprocess.Popen(
            ["/bin/bash", str(SCRIPT), str(self.app)], cwd=self.work, env=self._environment(**extra),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=limit)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            self.fail("the smoke did not end within %s seconds, so a hung check holds the publish" % limit)
        finally:
            self._stop_hung_process()
        return process.returncode, stdout, stderr, time.monotonic() - started

    def _stop_hung_process(self):
        if self.pid_file.exists():
            try:
                os.kill(int(self.pid_file.read_text().strip()), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass

    def runs(self, log):
        if not log.exists():
            return []
        return [line.split("\t", 2) for line in log.read_text().splitlines() if line.count("\t") == 2]

    def assert_outside_documents(self, label, path):
        self.assertFalse(
            real_inside(path, self.documents),
            "%s is inside the Documents folder (%s resolves to %s)" % (label, path, os.path.realpath(path)),
        )

    def test_checks_run_from_a_copy_outside_documents(self):
        code, stdout, stderr, _ = self.run_smoke()
        self.assertEqual(code, 0, stdout + stderr)
        for name in ("micromamba", "lungfish-cli-version", "lungfish-cli-tools",
                     "signed-bootstrap-reconciliation", "lungfish-cli-qc-summary"):
            self.assertIn("PASS " + name, stdout)
        runs = self.runs(self.run_log)
        arguments = [run[2] for run in runs]
        for expected in ("--version", "version --tools", "fastq qc-summary", "tools update --plan",
                         "tools update --apply"):
            self.assertTrue(any(a.startswith(expected) for a in arguments), "no run of: " + expected)
        for binary, cwd, args in runs:
            self.assert_outside_documents("the binary " + binary, binary)
            self.assert_outside_documents("the working folder of " + binary, cwd)
            self.assertIn(STAGE_MARKER, os.path.realpath(binary), "binary is not in a smoke folder: " + binary)
            self.assertIn(STAGE_MARKER, cwd, "working folder is not the smoke folder: " + cwd)
            for token in args.split():
                if token.startswith("/"):
                    self.assert_outside_documents("the argument " + token + " of " + binary, token)
        bootstrap = [run for run in self.runs(self.py_log) if "smoke_signed_bootstrap.py" in run[2]]
        self.assertEqual(len(bootstrap), 1, "the signed bootstrap check did not run once")
        for _, cwd, args in bootstrap:
            self.assert_outside_documents("the working folder of the bootstrap check", cwd)
            for token in args.split():
                if token.startswith("/"):
                    self.assert_outside_documents("the bootstrap check argument " + token, token)
        # The copy is removed at the end, and the original is untouched.
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), [], "the smoke copy was left behind")
        self.assertTrue((self.app / "Contents" / "MacOS" / "lungfish-cli").exists())

    def test_a_check_that_never_ends_fails_in_words_that_name_the_prompt(self):
        code, stdout, stderr, elapsed = self.run_smoke(
            limit=60, LUNGFISH_TEST_CLI_HANG="--version", **{TIMEOUT_VARIABLE: "3"}
        )
        self.assertNotEqual(code, 0, stdout + stderr)
        self.assertLess(elapsed, 40, "the hung check was not stopped by its own time limit")
        self.assertIn("PASS micromamba", stdout)
        self.assertNotIn("PASS lungfish-cli-tools", stdout)
        for words in ("lungfish-cli-version", "3 seconds", "privacy prompt", "remote or scripted click",
                      "run the publish at the Mac", "System Settings", "Privacy and Security",
                      "Files and Folders"):
            self.assertIn(words, stderr)
        # The hung process is gone and so is the copy.
        pid = int(self.pid_file.read_text().strip())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), [], "the smoke copy was left behind")

    def test_a_smoke_folder_that_resolves_into_documents_is_refused(self):
        # The folder name holds no "Documents", but the symlink leads there, so only realpath can refuse it.
        inside = self.documents_target / "cache"
        code, stdout, stderr, _ = self.run_smoke(LUNGFISH_RELEASE_CACHE_ROOT=str(inside))
        self.assertNotEqual(code, 0, stdout + stderr)
        self.assertIn("Documents", stderr)
        self.assertEqual(self.runs(self.run_log), [], "a binary ran although the folder was refused")

    def test_a_bad_time_limit_is_refused_in_words(self):
        for value in ("0", "abc", "-5"):
            with self.subTest(value=value):
                code, stdout, stderr, _ = self.run_smoke(**{TIMEOUT_VARIABLE: value})
                self.assertEqual(code, 64, stdout + stderr)
                self.assertIn(TIMEOUT_VARIABLE, stderr)
                self.assertEqual(self.runs(self.run_log), [])


if __name__ == "__main__":
    unittest.main()

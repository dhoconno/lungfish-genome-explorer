"""Installs the real hook script into a throwaway git repo and commits into it."""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "install-git-hooks.sh"


class InstallGitHooksPreCommitTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.name", "Test"],
            check=True,
        )
        # install-git-hooks.sh resolves PROJECT_ROOT from its own location and
        # writes into "$(git -C "$PROJECT_ROOT" rev-parse --git-path hooks)".
        # Run it with PROJECT_ROOT pointed at our throwaway repo by copying the
        # script in and invoking it from there, so hooks land in the temp repo
        # rather than this checkout's real .git/hooks.
        scripts_dir = self.repo / "scripts"
        scripts_dir.mkdir()
        (scripts_dir / "install-git-hooks.sh").write_text(SCRIPT.read_text())
        (scripts_dir / "install-git-hooks.sh").chmod(0o755)
        result = subprocess.run(
            ["/bin/bash", str(scripts_dir / "install-git-hooks.sh")],
            cwd=self.repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.pre_commit = self.repo / ".git/hooks/pre-commit"
        self.assertTrue(self.pre_commit.exists(), result.stdout)

    def commit(self, extra_env=None, extra_args=None):
        env = dict(**{"PATH": "/usr/bin:/bin:/usr/local/bin"}, **(extra_env or {}))
        return subprocess.run(
            ["git", "commit", "-q", "-m", "test commit", *(extra_args or [])],
            cwd=self.repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def write_and_stage(self, relative_path, size_bytes):
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"a" * size_bytes)
        subprocess.run(
            ["git", "-C", str(self.repo), "add", relative_path],
            check=True,
        )

    def test_rejects_new_file_under_docs_over_default_limit(self):
        self.write_and_stage("docs/big.png", 600 * 1024)

        result = self.commit()

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("over the 500 KB docs/ limit", result.stdout)

    def test_allows_file_under_docs_within_default_limit(self):
        self.write_and_stage("docs/small.md", 10 * 1024)

        result = self.commit()

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_allows_large_file_outside_docs(self):
        self.write_and_stage("Sources/big.bin", 600 * 1024)

        result = self.commit()

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_env_var_override_raises_the_limit(self):
        self.write_and_stage("docs/medium.png", 600 * 1024)

        result = self.commit(extra_env={"LUNGFISH_DOCS_SIZE_LIMIT_KB": "1000"})

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_no_verify_bypasses_the_guard(self):
        self.write_and_stage("docs/big.png", 600 * 1024)

        result = self.commit(extra_args=["--no-verify"])

        self.assertEqual(result.returncode, 0, result.stdout)


class InstallGitHooksPrePushTagTests(unittest.TestCase):
    """Real pushes to a throwaway bare remote. The temp repo has none of the
    check scripts, so any push where the hook runs its checks fails, which
    tells a skipped hook apart from one that ran."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.remote = root / "remote.git"
        self.repo = root / "repo"
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        for key, value in (("user.email", "test@example.com"), ("user.name", "Test")):
            subprocess.run(["git", "-C", str(self.repo), "config", key, value], check=True)
        subprocess.run(["git", "-C", str(self.repo), "remote", "add", "origin", str(self.remote)], check=True)
        scripts_dir = self.repo / "scripts"
        scripts_dir.mkdir()
        (scripts_dir / "install-git-hooks.sh").write_text(SCRIPT.read_text())
        result = subprocess.run(
            ["/bin/bash", str(scripts_dir / "install-git-hooks.sh")],
            cwd=self.repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.commit("first")
        # The first branch push stands in for a push that went through the gate.
        self.git("push", "-q", "--no-verify", "origin", "main")

    def git(self, *args, check=True):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            env={"PATH": "/usr/bin:/bin:/usr/local/bin"},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check,
        )

    def commit(self, message):
        (self.repo / "file.txt").write_text(message)
        self.git("add", "file.txt")
        self.git("commit", "-q", "-m", message)

    def test_tag_on_already_pushed_commit_skips_the_checks(self):
        self.git("tag", "-a", "v1", "-m", "v1")

        result = self.git("push", "origin", "v1", check=False)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("skipping checks", result.stdout)

    def test_tag_on_unpushed_commit_still_runs_the_checks(self):
        self.commit("second")
        self.git("tag", "-a", "v2", "-m", "v2")

        result = self.git("push", "origin", "v2", check=False)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("skipping checks", result.stdout)

    def test_branch_and_tag_together_still_run_the_checks(self):
        self.git("tag", "-a", "v1", "-m", "v1")
        self.commit("second")

        result = self.git("push", "origin", "main", "v1", check=False)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("skipping checks", result.stdout)

    def test_tag_deletion_skips_the_checks(self):
        self.git("tag", "-a", "v1", "-m", "v1")
        self.git("push", "-q", "--no-verify", "origin", "v1")

        result = self.git("push", "origin", ":refs/tags/v1", check=False)

        self.assertEqual(result.returncode, 0, result.stdout)


class InstallGitHooksUnitEvidenceTests(unittest.TestCase):
    """The pre-push hook skips the unit tier only when retained evidence covers
    every pushed commit. Each script the generated hook calls is a stub, so a
    real push shows what the hook decided without running a ratchet or a test.
    The evidence stub records its arguments and exits with a chosen status. The
    unit gate stub leaves a marker file."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name).resolve()
        self.remote = root / "remote.git"
        self.repo = root / "repo"
        self.evidence_log = root / "evidence-calls.jsonl"
        self.order_log = root / "call-order.log"
        self.unit_marker = root / "unit-gate-ran"
        self.unit_arguments = root / "unit-gate-arguments"
        # The hook runs `python3`; point it at the interpreter running these tests.
        bin_directory = root / "bin"
        bin_directory.mkdir()
        (bin_directory / "python3").symlink_to(sys.executable)
        self.environment = {
            "PATH": f"{bin_directory}:/usr/bin:/bin:/usr/local/bin",
            "HOME": str(root),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "STUB_EVIDENCE_LOG": str(self.evidence_log),
            "STUB_ORDER_LOG": str(self.order_log),
            "STUB_UNIT_MARKER": str(self.unit_marker),
            "STUB_UNIT_ARGUMENTS": str(self.unit_arguments),
        }
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True, env=self.environment)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True, env=self.environment)
        for key, value in (("user.email", "test@example.com"), ("user.name", "Test")):
            self.git("config", key, value)
        self.git("remote", "add", "origin", str(self.remote))
        scripts_dir = self.repo / "scripts"
        scripts_dir.mkdir()
        (scripts_dir / "install-git-hooks.sh").write_text(SCRIPT.read_text())
        installed = subprocess.run(
            ["/bin/bash", str(scripts_dir / "install-git-hooks.sh")],
            cwd=self.repo, env=self.environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )
        self.assertEqual(installed.returncode, 0, installed.stdout)
        self.stubbed = self.stub_every_script_the_hook_calls()
        self.commit("first")
        # The first branch push stands in for a push that went through the gate.
        self.git("push", "-q", "--no-verify", "origin", "main")

    def stub_every_script_the_hook_calls(self):
        """Replace each "$REPO_ROOT/<path>" the generated hook runs with a stub
        that records its call and succeeds, then give the two scripts the tests
        watch their behavior. Returns the stubbed paths in the hook's order."""
        hook = (self.repo / ".git/hooks/pre-push").read_text()
        stubs = {}
        for line in hook.splitlines():
            for call in re.finditer(r'"\$REPO_ROOT/([^"]+)"', line):
                through_python = line[:call.start()].rstrip().endswith("python3")
                stubs[call.group(1)] = through_python
        self.assertIn("scripts/release/gate_evidence.py", stubs)
        self.assertIn("scripts/full-suite-gate.sh", stubs)
        self.assertGreaterEqual(len(stubs), 15, sorted(stubs))
        for relative, through_python in stubs.items():
            self.write_stub(relative, self.succeeding_stub(relative, through_python))
        self.write_stub("scripts/release/gate_evidence.py", (
            "import json, os, sys\n"
            "with open(os.environ['STUB_ORDER_LOG'], 'a') as order:\n"
            "    order.write('scripts/release/gate_evidence.py\\n')\n"
            "with open(os.environ['STUB_EVIDENCE_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.exit(int(os.environ.get('STUB_EVIDENCE_EXIT', '0')))\n"))
        self.write_stub("scripts/full-suite-gate.sh", (
            "#!/bin/bash\n"
            'echo "scripts/full-suite-gate.sh" >> "$STUB_ORDER_LOG"\n'
            'echo "$@" > "$STUB_UNIT_ARGUMENTS"\n'
            'touch "$STUB_UNIT_MARKER"\n'
            "exit 0\n"))
        return stubs

    @staticmethod
    def succeeding_stub(relative, through_python, status=0):
        if through_python:
            return (f"import os, sys\n"
                    f"with open(os.environ['STUB_ORDER_LOG'], 'a') as order:\n"
                    f"    order.write({relative!r} + '\\n')\n"
                    f"sys.exit({status})\n")
        return f'#!/bin/bash\necho "{relative}" >> "$STUB_ORDER_LOG"\nexit {status}\n'

    def write_stub(self, relative, content):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)

    def git(self, *args, check=True, evidence_exit=0):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            env={**self.environment, "STUB_EVIDENCE_EXIT": str(evidence_exit)},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check,
        )

    def commit(self, message, name="file.txt"):
        (self.repo / name).write_text(message)
        self.git("add", name)
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def evidence_calls(self):
        if not self.evidence_log.exists():
            return []
        return [json.loads(line) for line in self.evidence_log.read_text().splitlines()]

    def asked_about(self, call):
        return [call[index + 1] for index, argument in enumerate(call) if argument == "--commit"]

    def test_covering_evidence_skips_the_unit_gate(self):
        pushed = self.commit("second")

        result = self.git("push", "origin", "main", check=False, evidence_exit=0)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("skipping the unit-tier gate", result.stdout)
        self.assertFalse(self.unit_marker.exists(), "the unit gate must not run")
        self.assertEqual(self.evidence_calls(), [["unit-evidence", "--root", str(self.repo), "--commit", pushed]])

    def test_uncovered_commits_run_the_unit_gate(self):
        pushed = self.commit("second")

        result = self.git("push", "origin", "main", check=False, evidence_exit=1)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("skipping the unit-tier gate", result.stdout)
        self.assertIn("running unit-tier gate", result.stdout)
        self.assertTrue(self.unit_marker.exists(), "no evidence covers the push, so the unit gate must run")
        self.assertEqual(self.unit_arguments.read_text().split(), ["--tier", "unit"])
        self.assertEqual(self.asked_about(self.evidence_calls()[0]), [pushed])

    def test_code_that_already_failed_the_unit_tier_is_refused_without_a_rerun(self):
        self.commit("second")

        result = self.git("push", "origin", "main", check=False, evidence_exit=3)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("unit tier already failed on this code", result.stdout)
        self.assertFalse(self.unit_marker.exists(), "a red commit is diagnosed, never retried by the hook")

    def test_a_failing_unit_gate_still_blocks_the_push(self):
        self.commit("second")
        self.write_stub("scripts/full-suite-gate.sh", "#!/bin/bash\nexit 1\n")

        result = self.git("push", "origin", "main", check=False, evidence_exit=1)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("unit-tier gate FAILED", result.stdout)

    def called_in_order(self):
        return self.order_log.read_text().splitlines() if self.order_log.exists() else []

    def test_evidence_is_asked_after_every_other_check_and_before_the_unit_gate(self):
        self.commit("second")

        result = self.git("push", "origin", "main", check=False, evidence_exit=1)

        self.assertEqual(result.returncode, 0, result.stdout)
        order = self.called_in_order()
        self.assertEqual(order[-2:], ["scripts/release/gate_evidence.py", "scripts/full-suite-gate.sh"])
        self.assertEqual(sorted(order), sorted(self.stubbed), "every check ran once, then the evidence, then the gate")

    def test_a_failing_check_blocks_the_push_before_evidence_is_asked(self):
        self.commit("second")
        checks = [relative for relative, through_python in self.stubbed.items()
                  if through_python and relative != "scripts/release/gate_evidence.py"]
        self.assertGreaterEqual(len(checks), 15, checks)
        for position, relative in (("first", checks[0]), ("last", checks[-1])):
            with self.subTest(position=position, check=relative):
                self.order_log.unlink(missing_ok=True)
                self.write_stub(relative, self.succeeding_stub(relative, True, status=1))

                result = self.git("push", "origin", "main", check=False, evidence_exit=0)

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FAILED", result.stdout)
                self.assertEqual(self.called_in_order()[-1], relative, "nothing runs after the failing check")
                self.assertEqual(self.evidence_calls(), [], "evidence must not excuse a failed check")
                self.assertFalse(self.unit_marker.exists())
                self.write_stub(relative, self.succeeding_stub(relative, True))

    def test_every_pushed_branch_tip_is_named(self):
        main_tip = self.commit("second")
        self.git("checkout", "-q", "-b", "other")
        other_tip = self.commit("third", name="other.txt")
        self.git("checkout", "-q", "main")

        result = self.git("push", "origin", "main", "other", check=False, evidence_exit=0)

        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.evidence_calls()
        self.assertEqual(len(calls), 1, calls)
        self.assertEqual(calls[0][:3], ["unit-evidence", "--root", str(self.repo)])
        self.assertEqual(sorted(self.asked_about(calls[0])), sorted([main_tip, other_tip]))
        self.assertFalse(self.unit_marker.exists())

    def test_a_tag_on_an_unpushed_commit_asks_about_the_commit_not_the_tag_object(self):
        tagged = self.commit("second")
        self.git("tag", "-a", "v2", "-m", "v2")
        tag_object = self.git("rev-parse", "v2").stdout.strip()
        self.assertNotEqual(tag_object, tagged)

        result = self.git("push", "origin", "v2", check=False, evidence_exit=0)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.asked_about(self.evidence_calls()[0]), [tagged])
        self.assertFalse(self.unit_marker.exists())

    def test_a_tag_on_an_already_pushed_commit_skips_checks_and_never_asks(self):
        self.git("tag", "-a", "v1", "-m", "v1")

        result = self.git("push", "origin", "v1", check=False, evidence_exit=1)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("skipping checks", result.stdout)
        self.assertEqual(self.evidence_calls(), [])
        self.assertFalse(self.unit_marker.exists())

    def test_a_ref_that_does_not_resolve_to_a_commit_keeps_the_unit_gate_even_if_the_rest_is_covered(self):
        self.commit("second")
        tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.git("tag", "tree-tag", tree)

        result = self.git("push", "origin", "main", "tree-tag", check=False, evidence_exit=0)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("skipping the unit-tier gate", result.stdout)
        self.assertEqual(self.evidence_calls(), [], "evidence cannot vouch for a ref the hook could not resolve")
        self.assertTrue(self.unit_marker.exists())

    def test_a_push_that_adds_no_commit_never_asks_for_evidence(self):
        self.git("push", "-q", "--no-verify", "origin", "main:refs/heads/spare")

        result = self.git("push", "origin", ":refs/heads/spare", check=False, evidence_exit=0)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.evidence_calls(), [])


if __name__ == "__main__":
    unittest.main()

"""Argument-parsing and plan-printing tests for scripts/deps/verify.sh.

These tests only exercise argument handling and the dry-run plan line, so they
never build, never invoke swift, and never touch conda environments or
databases. Everything past the dry-run exit is covered by actually running a
sweep, not by unit tests.
"""

import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT =pathlib.Path(__file__).resolve().parents[2]
VERIFY = ROOT / "scripts" / "deps" / "verify.sh"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
MANIFEST = ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"

# Generous enough for a cold python/bash start on a loaded machine, but far
# below the runtime of any real work the script could otherwise start.
TIMEOUT_SECONDS = 60


def run_verify(args, env=None):
    return subprocess.run(
        ["/bin/bash", str(VERIFY), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=TIMEOUT_SECONDS,
        cwd=str(ROOT),
        env=env,
    )


class BashSyntaxTests(unittest.TestCase):
    def test_script_parses(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(VERIFY)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_provisioning_includes_esviritu_database_needed_by_tier_three(self):
        source = VERIFY.read_text(encoding="utf-8")
        self.assertIn('esviritu download-db --no-progress', source)


class DryRunTests(unittest.TestCase):
    def test_dry_run_prints_the_resolved_plan_line(self):
        result = run_verify(["--tier", "1", "--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verify: set=", result.stdout)
        self.assertIn("manifest=", result.stdout)
        self.assertIn("root=/tmp/lungfish-verify-test", result.stdout)
        self.assertIn("tier=1", result.stdout)

    def test_dry_run_reports_the_manifest_dependency_set(self):
        import json

        expected = json.loads(MANIFEST.read_text(encoding="utf-8"))["dependencySet"]
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"set={expected}", result.stdout)

    def test_dry_run_reports_the_manifest_sha256(self):
        digest = subprocess.run(
            ["shasum", "-a", "256", str(MANIFEST)],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.split()[0]
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertIn(f"manifest={digest}", result.stdout)

    def test_dry_run_does_not_provision_anything(self):
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        combined = result.stdout + result.stderr
        self.assertNotIn("Building lungfish-cli", combined)
        self.assertNotIn("Provisioning", combined)

    def test_dry_run_does_not_resolve_the_swiftpm_sdk(self):
        with tempfile.TemporaryDirectory() as temporary:
            command_bin = pathlib.Path(temporary) / "bin"
            command_bin.mkdir()
            marker = pathlib.Path(temporary) / "xcrun-ran"
            xcrun = command_bin / "xcrun"
            xcrun.write_text(
                f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\nexit 97\n",
                encoding="utf-8",
            )
            xcrun.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{command_bin}{os.pathsep}{environment['PATH']}"
            result = run_verify(
                ["--dry-run", "--root", "/tmp/lungfish-verify-test"],
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())

    def test_tier_defaults_to_one(self):
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertIn("tier=1", result.stdout)


class ArgumentGuardTests(unittest.TestCase):
    VALUE_FLAGS = ("--tier", "--root", "--seed-from", "--filter")

    def test_every_value_flag_without_a_value_exits_64(self):
        for flag in self.VALUE_FLAGS:
            with self.subTest(flag=flag):
                result = run_verify([flag])
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn(f"{flag} requires a value", result.stderr)

    def test_trailing_value_flag_after_valid_flags_exits_64(self):
        result = run_verify(["--tier", "1", "--root"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--root requires a value", result.stderr)

    def test_unknown_flag_exits_64(self):
        result = run_verify(["--bogus"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("unknown argument", result.stderr)

    def test_bad_tier_exits_64(self):
        # The tier is validated before any provisioning work, so a typo fails
        # immediately rather than after twenty minutes of downloads. This runs
        # without --dry-run precisely to prove the validation happens first.
        result = run_verify(["--tier", "9", "--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--tier must be one of", result.stderr)

    def test_help_exits_zero_and_describes_the_tiers(self):
        result = run_verify(["--help"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--tier", result.stdout)
        self.assertIn("--seed-from", result.stdout)

    def test_root_may_not_be_the_real_managed_storage_root(self):
        # Provisioning reinstalls environments to match the manifest, so
        # pointing verify at ~/.lungfish would rewrite the developer's own
        # 21 GB conda root. Refuse before doing any work.
        result = run_verify(["--tier", "1", "--root", str(pathlib.Path.home() / ".lungfish")])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("must not be the real managed storage root", result.stderr)

    def test_protected_root_failure_does_not_resolve_the_swiftpm_sdk(self):
        with tempfile.TemporaryDirectory() as temporary:
            command_bin = pathlib.Path(temporary) / "bin"
            command_bin.mkdir()
            marker = pathlib.Path(temporary) / "xcrun-ran"
            xcrun = command_bin / "xcrun"
            xcrun.write_text(
                f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\nexit 97\n",
                encoding="utf-8",
            )
            xcrun.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{command_bin}{os.pathsep}{environment['PATH']}"
            result = run_verify(
                ["--root", str(pathlib.Path.home() / ".lungfish")],
                env=environment,
            )
            self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
            self.assertFalse(marker.exists())

    def test_root_may_not_be_any_named_managed_storage_root(self):
        # Preview, Stable, and Debug are real managed roots too. Use --dry-run
        # so this regression test never provisions or mutates any root.
        for name in (".lungfish-preview", ".lungfish-stable", ".lungfish-debug"):
            with self.subTest(name=name):
                result = run_verify(
                    ["--tier", "1", "--dry-run", "--root", str(pathlib.Path.home() / name)]
                )
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn("must not be the real managed storage root", result.stderr)


class FilterSyncTests(unittest.TestCase):
    def test_tier1_provisions_an_isolated_parity_python_environment(self):
        """The iVar oracle must not depend on the developer's Python packages.

        IVarConverterViralReconParityTests invokes `/usr/bin/env python3`, so
        the verifier must build its fixture-oracle environment below the
        isolated storage root, prove the imports work, and make that Python
        visible only while it runs tier 1.
        """
        script = VERIFY.read_text(encoding="utf-8")
        self.assertIn('parity_python_root="${storage_root}/parity-python"', script)
        self.assertIn('python3 -m venv "${parity_python_root}"', script)
        self.assertIn(
            'pip install numpy biopython scipy pandas',
            script,
        )
        self.assertIn(
            "-c 'import numpy, Bio, scipy, pandas; print(\"parity deps OK\")'",
            script,
        )

        tier1 = re.search(
            r"^run_tier1\(\) \{\n(.*?)\n\}", script, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(tier1, "run_tier1 function not found")
        self.assertIn(
            'PATH="${parity_python_root}/bin:${PATH}"',
            tier1.group(1),
        )

    def test_tier1_include_tokens_are_retained_in_the_ci_catalog(self):
        """Retain include tokens; CI separately excludes GUI suites.

        This checks catalog vocabulary, not identical execution coverage: local
        tier 1 can select app tests that headless CI deliberately excludes.
        """
        script = VERIFY.read_text(encoding="utf-8")
        script_filter = re.search(
            r"^default_tier1_filter='([^']*)'", script, re.MULTILINE
        )
        self.assertIsNotNone(script_filter, "default_tier1_filter not found in verify.sh")
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("scripts/test.py run --profile tool-conformance --require-tools", workflow)
        catalog = json.loads((ROOT / "config/test-catalog.json").read_text())
        profile = catalog["profiles"]["tool-conformance"]
        self.assertTrue(profile["requireTools"])
        collections = {item["id"]: item for item in catalog["collections"]}
        covered = set()
        for name in profile["collections"]:
            covered.update(collections[name].get("include", "").split("|"))
        self.assertLessEqual(set(script_filter.group(1).split("|")), covered)
        conformance = collections["tool-conformance"]
        self.assertRegex(
            "LungfishAppTests.FASTQOperationRoundTripTests/testExample",
            conformance["exclude"],
        )

    def test_conformance_packs_match_the_ci_job(self):
        script = VERIFY.read_text(encoding="utf-8")
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        packs = re.search(
            r"^conformance_packs=\(\n(.*?)\n\)", script, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(packs, "conformance_packs not found in verify.sh")
        script_packs = set(packs.group(1).split())
        workflow_packs = set(re.findall(r"conda install --pack ([\w-]+)", workflow))
        self.assertEqual(
            script_packs - workflow_packs, set(), "verify.sh installs a pack the CI job does not"
        )
        self.assertEqual(
            workflow_packs - script_packs, set(), "the CI job installs a pack verify.sh does not"
        )


class Tier1FailurePropagationTests(unittest.TestCase):
    def test_cli_build_uses_the_canonical_full_xcode_selection(self):
        """A global CommandLineTools selection must not choose release Swift.

        A configured Xcode path may itself be an alias. The shared release
        resolver canonicalizes it before child processes run; the verifier must
        export that result before invoking Swift rather than inheriting the
        machine-global developer-tool selection.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            repo = root / "repo"
            verify = repo / "scripts" / "deps" / "verify.sh"
            resolver = repo / "scripts" / "release" / "release_xcode.py"
            verify.parent.mkdir(parents=True)
            resolver.parent.mkdir(parents=True)
            shutil.copy2(VERIFY, verify)
            shutil.copy2(ROOT / "scripts" / "release" / "release_xcode.py", resolver)
            shutil.copy2(
                ROOT / "scripts" / "release" / "swiftpm_build.py",
                resolver.parent / "swiftpm_build.py",
            )

            manifest = repo / "Sources" / "LungfishWorkflow" / "Resources" / "ManagedTools" / "third-party-tools-lock.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('{"dependencySet":"test"}\n', encoding="utf-8")

            developer_dir = root / "Full Xcode" / "Contents" / "Developer"
            xcodebuild = developer_dir / "usr" / "bin" / "xcodebuild"
            xcodebuild.parent.mkdir(parents=True)
            xcodebuild.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            xcodebuild.chmod(0o755)
            xcode_alias = root / "Selected Xcode"
            xcode_alias.symlink_to(developer_dir)

            command_bin = root / "bin"
            command_bin.mkdir()
            sdk_path = root / "MacOSX27.0.sdk"
            sdk_path.mkdir()
            xcrun = command_bin / "xcrun"
            xcrun.write_text(
                f"#!/bin/sh\nprintf '%s\\n' {shlex.quote(str(sdk_path))}\n",
                encoding="utf-8",
            )
            xcrun.chmod(0o755)
            captured = root / "captured-developer-dir"
            swift = command_bin / "swift"
            swift.write_text(
                "#!/bin/bash\n"
                f"printf '%s\\n' \"${{DEVELOPER_DIR:-unset}}\" >{shlex.quote(str(captured))}\n"
                "exit 42\n",
                encoding="utf-8",
            )
            swift.chmod(0o755)

            environment = os.environ.copy()
            environment["DEVELOPER_DIR"] = str(xcode_alias)
            environment["PATH"] = f"{command_bin}{os.pathsep}{environment['PATH']}"
            result = subprocess.run(
                ["/bin/bash", str(verify), "--tier", "1", "--root", str(root / "storage")],
                cwd=str(repo),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=20,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                captured.read_text(encoding="utf-8").strip(),
                str(developer_dir.resolve()),
            )

    def test_failed_parity_python_provisioning_does_not_launch_the_suite_gate(self):
        """A failed oracle setup must not be masked by the gate's final status.

        The production script runs tier functions on the left side of `||`,
        where Bash disables `errexit` for the function body. Execute an exact
        temporary copy with all expensive commands stubbed: the venv's Python
        accepts package installation but fails the import preflight, and the
        fake `bash` records whether the suite gate was nevertheless launched.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            repo = root / "repo"
            verify = repo / "scripts" / "deps" / "verify.sh"
            resolver = repo / "scripts" / "release" / "release_xcode.py"
            verify.parent.mkdir(parents=True)
            resolver.parent.mkdir(parents=True)
            shutil.copy2(VERIFY, verify)
            shutil.copy2(ROOT / "scripts" / "release" / "release_xcode.py", resolver)
            shutil.copy2(
                ROOT / "scripts" / "release" / "swiftpm_build.py",
                resolver.parent / "swiftpm_build.py",
            )
            verify.chmod(0o755)

            manifest = repo / "Sources" / "LungfishWorkflow" / "Resources" / "ManagedTools" / "third-party-tools-lock.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('{"dependencySet":"test"}\n', encoding="utf-8")

            command_bin = root / "bin"
            command_bin.mkdir()
            sdk_path = root / "MacOSX27.0.sdk"
            sdk_path.mkdir()
            gate_marker = root / "suite-gate-ran"
            preflight_marker = root / "parity-preflight-ran"

            def write_command(name, body):
                command = command_bin / name
                command.write_text("#!/bin/bash\nset -eu\n" + body, encoding="utf-8")
                command.chmod(0o755)

            swiftbuild_bin = root / "swiftbuild-bin"
            write_command(
                "swift",
                "if [[ \" $* \" == *\" --show-bin-path \"* ]]; then\n"
                f"  printf '%s\\n' {shlex.quote(str(swiftbuild_bin))}\n"
                "fi\n"
                "exit 0\n",
            )
            write_command("xcrun", f"printf '%s\\n' {shlex.quote(str(sdk_path))}\n")
            cli = swiftbuild_bin / "lungfish-cli"
            cli.parent.mkdir(parents=True)
            cli.write_text(
                "#!/bin/bash\n"
                "if [[ \"$*\" == *\"--plan --json\"* ]]; then\n"
                "  printf '%s\\n' '{\"installEnvironments\":[],\"reinstallEnvironments\":[],\"removeEnvironments\":[],\"databaseUpdates\":[],\"bootstrapUpdate\":null}'\n"
                "fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            cli.chmod(0o755)
            write_command("bash", f"touch {shlex.quote(str(gate_marker))}\nexit 99\n")
            write_command(
                "python3",
                "if [[ \"${1:-}\" == \"-m\" && \"${2:-}\" == \"venv\" ]]; then\n"
                "  target=\"$3\"\n"
                "  mkdir -p \"${target}/bin\"\n"
                "  {\n"
                "    printf '%s\\n' '#!/bin/sh'\n"
                "    printf '%s\\n' 'if [ \"${1:-}\" = \"-m\" ] && [ \"${2:-}\" = \"pip\" ]; then exit 0; fi'\n"
                f"    printf '%s\\n' 'if [ \"${{1:-}}\" = \"-c\" ]; then touch {shlex.quote(str(preflight_marker))}; exit 42; fi'\n"
                "    printf '%s\\n' 'exit 0'\n"
                "  } > \"${target}/bin/python\"\n"
                "  chmod +x \"${target}/bin/python\"\n"
                "  exit 0\n"
                "fi\n"
                f"exec {shlex.quote(sys.executable)} \"$@\"\n",
            )

            environment = os.environ.copy()
            home = root / "home"
            home.mkdir()
            developer_dir = root / "Xcode.app" / "Contents" / "Developer"
            xcodebuild = developer_dir / "usr" / "bin" / "xcodebuild"
            xcodebuild.parent.mkdir(parents=True)
            xcodebuild.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            xcodebuild.chmod(0o755)
            environment["HOME"] = str(home)
            environment["DEVELOPER_DIR"] = str(developer_dir)
            environment["PATH"] = f"{command_bin}{os.pathsep}{environment['PATH']}"
            result = subprocess.run(
                ["/bin/bash", str(verify), "--tier", "1", "--root", str(root / "storage")],
                cwd=str(repo),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=20,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(preflight_marker.exists(), "parity import preflight was not reached")
            self.assertFalse(
                gate_marker.exists(),
                "full-suite-gate ran after parity Python provisioning failed",
            )


class PlanGateTests(unittest.TestCase):
    """The post-provisioning plan gate, run against synthetic plan JSON.

    The gate decides whether a provisioned root matches the manifest closely
    enough for the tiers to measure the right dependency set. It is embedded in
    verify.sh as a heredoc, so these tests extract that block and run it with
    PLAN_JSON set, which is exactly how the script invokes it.

    The distinction under test is advisory versus blocking. `tools update --plan`
    exits 10 for any pending work at all, so gating on the exit status failed a
    correctly provisioned root whenever an optional database index the tiers do
    not use was still outstanding.
    """

    @staticmethod
    def gate_source():
        script = VERIFY.read_text(encoding="utf-8")
        match = re.search(
            r"PLAN_JSON=\"\$\{plan_json\}\" python3 - <<'PYTHON'[^\n]*\n(.*?)\nPYTHON",
            script,
            re.DOTALL,
        )
        if match is None:
            raise AssertionError("plan gate heredoc not found in verify.sh")
        return match.group(1)

    def run_gate(self, plan):
        import json

        return subprocess.run(
            ["python3", "-c", self.gate_source()],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=TIMEOUT_SECONDS,
            env={"PLAN_JSON": json.dumps(plan), "PATH": "/usr/bin:/bin"},
        )

    @staticmethod
    def empty_plan(**overrides):
        plan = {
            "installEnvironments": [],
            "reinstallEnvironments": [],
            "removeEnvironments": [],
            "databaseUpdates": [],
            "pipelinePrefetch": [],
            "bootstrapUpdate": None,
            "targetDependencySet": "2026.2",
            "estimatedDownloadBytes": 0,
        }
        plan.update(overrides)
        return plan

    def test_empty_plan_passes(self):
        result = self.run_gate(self.empty_plan())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("dependency plan is empty", result.stdout)

    def test_advisory_database_update_alone_passes_and_is_reported(self):
        plan = self.empty_plan(
            databaseUpdates=[
                {
                    "id": "kraken2-viral",
                    "displayName": "Viral",
                    "installedVersion": "20240904",
                    "targetVersion": "20260626",
                    "policy": "advisory",
                    "estimatedBytes": 600000000,
                    "managedBy": "metagenomics",
                }
            ]
        )
        result = self.run_gate(plan)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("advisory database update", result.stdout)
        self.assertIn("kraken2-viral", result.stdout)

    def test_required_database_update_blocks(self):
        plan = self.empty_plan(
            databaseUpdates=[
                {
                    "id": "human-scrubber",
                    "displayName": "Human Read Scrubber Database",
                    "installedVersion": "20250916",
                    "targetVersion": "20260706v2",
                    "policy": "required",
                    "estimatedBytes": 1,
                    "managedBy": "bundled",
                }
            ]
        )
        result = self.run_gate(plan)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("required database updates", result.stderr)

    def test_pending_environment_work_blocks(self):
        for key in ("installEnvironments", "reinstallEnvironments"):
            with self.subTest(key=key):
                plan = self.empty_plan(
                    **{
                        key: [
                            {
                                "environment": "samtools",
                                "packID": "read-mapping",
                                "currentSpec": None,
                                "targetSpec": "samtools=1.21",
                                "reason": "missing",
                                "isRequired": True,
                            }
                        ]
                    }
                )
                result = self.run_gate(plan)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(key, result.stderr)

    def test_pending_environment_removal_blocks(self):
        result = self.run_gate(self.empty_plan(removeEnvironments=["retired-tool"]))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("removeEnvironments", result.stderr)

    def test_bootstrap_update_blocks(self):
        plan = self.empty_plan(
            bootstrapUpdate={"currentVersion": "2.0.4-0", "targetVersion": "2.0.5-0"}
        )
        result = self.run_gate(plan)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("bootstrapUpdate", result.stderr)

    def test_advisory_update_does_not_mask_blocking_work(self):
        plan = self.empty_plan(
            databaseUpdates=[
                {"id": "kraken2-viral", "policy": "advisory"},
                {"id": "human-scrubber", "policy": "required"},
            ]
        )
        result = self.run_gate(plan)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("required database updates: 1", result.stderr)

    def test_pipeline_prefetch_alone_does_not_block(self):
        # Prefetching a pipeline revision does not change which tool builds the
        # tiers exercise, so it is not grounds to fail the run.
        plan = self.empty_plan(
            pipelinePrefetch=[
                {"id": "taxtriage", "currentRevision": None, "targetRevision": "v3.3.8"}
            ]
        )
        result = self.run_gate(plan)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unparseable_plan_json_is_an_error(self):
        result = subprocess.run(
            ["python3", "-c", self.gate_source()],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=TIMEOUT_SECONDS,
            env={"PLAN_JSON": "not json at all", "PATH": "/usr/bin:/bin"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not parse the plan JSON", result.stderr)

    def test_gate_reads_the_plan_from_json_rather_than_the_exit_status(self):
        """The regression: gating on `--plan`'s exit status alone.

        Exit 10 covers advisory work too, so the old form failed a root that was
        correctly provisioned. The script must ask for --json and judge the
        contents.
        """
        script = VERIFY.read_text(encoding="utf-8")
        self.assertIn("tools update --plan --json", script)
        self.assertNotRegex(
            script,
            r"plan_status\}\s*-eq 10 \]\];\s*then\n\s*echo \"verify: plan not empty",
        )


class Tier1Harness:
    """A temporary copy of verify.sh with every expensive command stubbed.

    The stubs record what the script asked of them. cli-calls.txt holds the
    argument list of each lungfish-cli call. The suite gate (a stub bash) writes
    the environment it received to gate-env.txt and its arguments to
    gate-args.txt. Nothing builds, installs or downloads, and the golden
    environment is a folder of the test's own (LUNGFISH_GOLDEN_HOME).
    """

    EMPTY_PLAN = {
        "installEnvironments": [],
        "reinstallEnvironments": [],
        "removeEnvironments": [],
        "databaseUpdates": [],
        "bootstrapUpdate": None,
    }

    def __init__(self, temporary):
        # Resolved up front, because the script resolves --root and the macOS
        # temporary folder is reached through a symlink.
        self.root = pathlib.Path(temporary).resolve()
        self.repo = self.root / "repo"
        self.home = self.root / "home"
        self.storage = self.root / "storage"
        self.golden_home = self.root / "golden"
        self.record = self.root / "record"
        self.bin = self.root / "bin"
        self.build_bin = self.root / "swiftbuild-bin"
        self.developer_dir = self.root / "Xcode.app" / "Contents" / "Developer"
        self.verify = self.repo / "scripts" / "deps" / "verify.sh"
        self._install()

    def _stub(self, name, body, directory=None):
        path = (directory or self.bin) / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
        return path

    def _install(self):
        release = self.repo / "scripts" / "release"
        self.verify.parent.mkdir(parents=True)
        release.mkdir(parents=True)
        shutil.copy2(VERIFY, self.verify)
        for name in ("release_xcode.py", "swiftpm_build.py"):
            shutil.copy2(ROOT / "scripts" / "release" / name, release / name)
        manifest = (
            self.repo / "Sources" / "LungfishWorkflow" / "Resources" / "ManagedTools"
            / "third-party-tools-lock.json"
        )
        manifest.parent.mkdir(parents=True)
        manifest.write_text('{"dependencySet":"test"}\n', encoding="utf-8")
        for folder in (self.home, self.record, self.bin, self.build_bin):
            folder.mkdir(parents=True)
        xcodebuild = self.developer_dir / "usr" / "bin" / "xcodebuild"
        xcodebuild.parent.mkdir(parents=True)
        self._stub("xcodebuild", "#!/bin/sh\nexit 0\n", xcodebuild.parent)
        sdk = self.root / "MacOSX27.0.sdk"
        sdk.mkdir()
        self._stub("xcrun", f"#!/bin/sh\nprintf '%s\\n' {shlex.quote(str(sdk))}\n")
        self._stub(
            "swift",
            "#!/bin/bash\n"
            "if [[ \" $* \" == *\" --show-bin-path \"* ]]; then\n"
            f"  printf '%s\\n' {shlex.quote(str(self.build_bin))}\n"
            "fi\n"
            "exit 0\n",
        )
        self._stub(
            "lungfish-cli",
            f"#!{sys.executable}\n"
            "import json, sys\n"
            f"with open({str(self.record / 'cli-calls.txt')!r}, 'a') as calls:\n"
            "    calls.write(' '.join(sys.argv[1:]) + '\\n')\n"
            "if '--plan' in sys.argv and '--json' in sys.argv:\n"
            f"    print(json.dumps({self.EMPTY_PLAN!r}))\n",
            self.build_bin,
        )
        # The venv python of the parity oracle accepts every call.
        self._stub(
            "python3",
            "#!/bin/bash\nset -eu\n"
            "if [[ \"${1:-}\" == \"-m\" && \"${2:-}\" == \"venv\" ]]; then\n"
            "  mkdir -p \"$3/bin\"\n"
            "  printf '%s\\n' '#!/bin/sh' 'exit 0' > \"$3/bin/python\"\n"
            "  chmod +x \"$3/bin/python\"\n"
            "  exit 0\n"
            "fi\n"
            f"exec {shlex.quote(sys.executable)} \"$@\"\n",
        )
        # The suite gate records what it was handed and passes.
        self._stub(
            "bash",
            "#!/bin/bash\nset -eu\n"
            "if [[ \"${1:-}\" == \"scripts/full-suite-gate.sh\" ]]; then\n"
            f"  env > {shlex.quote(str(self.record / 'gate-env.txt'))}\n"
            f"  printf '%s\\n' \"$@\" > {shlex.quote(str(self.record / 'gate-args.txt'))}\n"
            "  if [[ -n \"${LUNGFISH_PARITY_EVIDENCE:-}\" && -e \"${LUNGFISH_PARITY_EVIDENCE}\" ]]; then\n"
            f"    touch {shlex.quote(str(self.record / 'evidence-existed'))}\n"
            "  fi\n"
            "  exit 0\n"
            "fi\n"
            "exec /bin/bash \"$@\"\n",
        )

    def run(self, extra_env=None, args=("--tier", "1")):
        environment = {k: v for k, v in os.environ.items() if not k.startswith("LUNGFISH_")}
        environment.update(
            {
                "HOME": str(self.home),
                "DEVELOPER_DIR": str(self.developer_dir),
                "PATH": f"{self.bin}{os.pathsep}{environment['PATH']}",
                "LUNGFISH_GOLDEN_HOME": str(self.golden_home),
            }
        )
        environment.update(extra_env or {})
        return subprocess.run(
            ["/bin/bash", str(self.verify), *args, "--root", str(self.storage)],
            cwd=str(self.repo),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=60,
            env=environment,
        )

    def gate_env(self):
        path = self.record / "gate-env.txt"
        if not path.exists():
            return None
        lines = path.read_text(encoding="utf-8").splitlines()
        return dict(line.split("=", 1) for line in lines if "=" in line)

    def cli_calls(self):
        path = self.record / "cli-calls.txt"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []


class Tier1GateInputTests(unittest.TestCase):
    """The variables the tier 1 live classes read, handed to the suite gate.

    The 2.12 verify run ended red on groups R4 (LUNGFISH_DEMO_ARCHIVE_DIR
    unset), R5 (LUNGFISH_PARITY_EVIDENCE unset) and R6 (a stall, then no
    lungfish-cli, because LUNGFISH_CLI_PATH was unset), and skipped four tests
    for want of LUNGFISH_PARITY_BASELINE, LUNGFISH_LIVE_NCBI and
    LUNGFISH_LIVE_PATHOPLEXUS. Each test runs the script against stubs and reads
    the environment the stub gate received.
    """

    DEMO_ARCHIVE = "lge-demo-pathogen-detection-2026.9.70.zip"
    CALLER_VALUES = {
        "LUNGFISH_CLI_PATH": "/caller/lungfish-cli",
        "LUNGFISH_DEMO_ARCHIVE_DIR": "/caller/demo-archives",
        "LUNGFISH_PARITY_EVIDENCE": "/caller/evidence",
        "LUNGFISH_PARITY_BASELINE": "/caller/baseline",
        "LUNGFISH_LIVE_NCBI": "0",
        "LUNGFISH_LIVE_PATHOPLEXUS": "0",
    }

    def run_tier1(self, harness, extra_env=None):
        result = harness.run(extra_env)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        gate = harness.gate_env()
        self.assertIsNotNone(gate, "the suite gate was not launched\n" + output)
        return result, gate

    def add_demo_archive(self, harness):
        demos = harness.golden_home / "cache" / "demo-archives"
        demos.mkdir(parents=True)
        (demos / self.DEMO_ARCHIVE).write_bytes(b"")
        return demos

    def add_evidence(self, harness, name, days_old, with_hashes=True):
        folder = harness.storage / "parity-evidence" / name
        (folder / "X1").mkdir(parents=True)
        if with_hashes:
            (folder / "X1" / "payload-hashes.tsv").write_text("side\tsample\n", encoding="utf-8")
        stamp = time.time() - days_old * 86400
        os.utime(folder, (stamp, stamp))
        return folder

    def test_gate_gets_the_cli_the_script_built(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            _, gate = self.run_tier1(harness)
            self.assertEqual(
                gate.get("LUNGFISH_CLI_PATH"), str(harness.build_bin / "lungfish-cli")
            )

    def test_gate_gets_the_golden_demo_folder_when_it_holds_the_demo_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            demos = self.add_demo_archive(harness)
            _, gate = self.run_tier1(harness)
            self.assertEqual(gate.get("LUNGFISH_DEMO_ARCHIVE_DIR"), str(demos))

    def test_gate_gets_no_demo_folder_and_a_warning_when_the_golden_cache_lacks_the_demo(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            demos = harness.golden_home / "cache" / "demo-archives"
            demos.mkdir(parents=True)
            (demos / "lge-demo-primer-design-2026.9.58.zip").write_bytes(b"")
            result, gate = self.run_tier1(harness)
            self.assertFalse(gate.get("LUNGFISH_DEMO_ARCHIVE_DIR"))
            self.assertIn("LUNGFISH_DEMO_ARCHIVE_DIR", result.stderr)

    def test_gate_gets_a_new_evidence_folder_under_the_verify_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            _, gate = self.run_tier1(harness)
            evidence = pathlib.Path(gate.get("LUNGFISH_PARITY_EVIDENCE", ""))
            self.assertTrue(evidence.is_absolute(), f"evidence folder: {evidence}")
            self.assertEqual(evidence.parent, harness.storage / "parity-evidence")
            self.assertFalse(
                (harness.record / "evidence-existed").exists(),
                "the live pass refuses an evidence folder that already exists",
            )

    def test_every_run_gets_its_own_evidence_folder(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            _, first = self.run_tier1(harness)
            _, second = self.run_tier1(harness)
            self.assertTrue(first.get("LUNGFISH_PARITY_EVIDENCE"))
            self.assertNotEqual(
                first.get("LUNGFISH_PARITY_EVIDENCE"), second.get("LUNGFISH_PARITY_EVIDENCE")
            )

    def test_baseline_is_the_newest_earlier_evidence_that_holds_the_x1_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            self.add_evidence(harness, "older", days_old=3)
            newer = self.add_evidence(harness, "newer", days_old=1)
            self.add_evidence(harness, "stopped-early", days_old=0, with_hashes=False)
            _, gate = self.run_tier1(harness)
            self.assertEqual(gate.get("LUNGFISH_PARITY_BASELINE"), str(newer))

    def test_gate_gets_no_baseline_and_a_warning_when_no_earlier_pass_left_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            result, gate = self.run_tier1(harness)
            self.assertFalse(gate.get("LUNGFISH_PARITY_BASELINE"))
            self.assertIn("LUNGFISH_PARITY_BASELINE", result.stderr)

    def test_live_switches_of_the_database_browser_rows_default_to_on(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            _, gate = self.run_tier1(harness)
            self.assertEqual(gate.get("LUNGFISH_LIVE_NCBI"), "1")
            self.assertEqual(gate.get("LUNGFISH_LIVE_PATHOPLEXUS"), "1")

    def test_a_value_the_caller_exported_wins(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Tier1Harness(temporary)
            self.add_demo_archive(harness)
            self.add_evidence(harness, "earlier", days_old=1)
            _, gate = self.run_tier1(harness, self.CALLER_VALUES)
            for name, value in self.CALLER_VALUES.items():
                with self.subTest(name=name):
                    self.assertEqual(gate.get(name), value)

    def test_the_inputs_are_set_on_the_gate_command_only(self):
        script = VERIFY.read_text(encoding="utf-8")
        self.assertNotRegex(
            script, r"(?m)^\s*export LUNGFISH_(CLI_PATH|DEMO_ARCHIVE_DIR|PARITY_|LIVE_)"
        )
        tier1 = re.search(r"^run_tier1\(\) \{\n(.*?)\n\}", script, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(tier1, "run_tier1 function not found")
        for name in self.CALLER_VALUES:
            with self.subTest(name=name):
                self.assertIn(f"{name}=", tier1.group(1))


if __name__ == "__main__":
    unittest.main()

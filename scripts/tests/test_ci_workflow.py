import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def yaml_load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


class CIWorkflowTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2]
        self.workflow = (root / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

    def test_script_test_environments_use_shared_hashed_input(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        requirements = (ROOT / "scripts/requirements-test.txt").read_text()
        self.assertIn("PyYAML==", requirements)
        self.assertIn("--hash=sha256:", requirements)
        for job_name in ("fast", "full"):
            install = next(step for step in wf["jobs"][job_name]["steps"]
                           if "-r scripts/requirements-test.txt" in step.get("run", ""))
            self.assertIn("--require-hashes", install["run"], job_name)
            self.assertIn("scripts/requirements-test.txt", install["run"], job_name)
            self.assertNotIn("--upgrade pip", install["run"])

    def test_actions_are_pinned_to_full_reviewable_commits(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        for job in wf["jobs"].values():
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")

    def test_automatic_swift_gate_runs_compiler_negative_control_and_behavior(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["fast"]
        self.assertNotIn("if", job)
        steps = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertIn("scripts/ci-swift-smoke.py", steps)
        self.assertIn("--compile-error-control", steps)
        self.assertTrue(any(step.get("uses", "").startswith("actions/upload-artifact@") and step.get("if") == "always()" for step in job["steps"]))

    def test_portable_debug_uses_one_coordinator_build(self):
        job = yaml_load(ROOT / ".github/workflows/ci.yml")["jobs"]["build-smoke"]
        runs = [step.get("run", "") for step in job["steps"]]
        self.assertEqual(sum("release.py debug --portable --jobs 4" in run for run in runs), 1)
        self.assertFalse(any("swift build" in run or "xcodebuild" in run for run in runs))
        self.assertIn("inputs.diagnostic == 'portable-debug'", job["if"])

    def test_automatic_gate_is_compact_and_needs_no_managed_environment(self):
        job = yaml_load(ROOT / ".github/workflows/ci.yml")["jobs"]["fast"]
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertNotIn("discover -s scripts/tests", runs)
        self.assertNotIn("tools update", runs)
        self.assertNotIn("conda", runs)
        self.assertIn("scripts.tests.test_release_contract", runs)
        self.assertIn("scripts.tests.test_gate_profile_evidence", runs)
        self.assertIn("scripts/check-package-resolved-consistency.sh", runs)

    def test_extended_and_headless_are_independent_opt_in_catalog_profiles(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["full"]
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertNotIn("needs", job)
        self.assertIn("inputs.diagnostic == 'headless'", job["if"])
        self.assertIn("inputs.diagnostic == 'extended'", job["if"])
        self.assertIn('scripts/test.py run --profile "$DIAGNOSTIC_PROFILE"', runs)
        self.assertNotIn("tools update", runs)
        self.assertNotIn("swift test", runs)
        self.assertNotIn("conda", runs)
        self.assertEqual(wf[True]["workflow_dispatch"]["inputs"]["diagnostic"]["default"], "none")

    def test_toolset_conformance_job_exists_and_is_dispatch_only(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        self.assertIn("workflow_dispatch", job["if"])
        steps = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("tools update --apply --yes --required-only", steps)
        self.assertIn("LUNGFISH_REQUIRE_TOOLS", steps)
        self.assertIn("scripts/test.py run --profile tool-conformance --require-tools", steps)

    def test_toolset_conformance_provisions_conformance_packs_and_viral_db(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        steps = " ".join(step.get("run", "") for step in job["steps"])
        for pack in (
            "read-mapping",
            "assembly",
            "phylogenetics",
            "multiple-sequence-alignment",
            "metagenomics",
            "full-length-mhc-genotyping",
        ):
            self.assertIn(f"conda install --pack {pack}", steps)
        self.assertIn("conda db download Viral", steps)

    def test_toolset_conformance_uses_canonical_catalog_selection(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        runs = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("scripts/test.py run --profile tool-conformance --require-tools", runs)
        self.assertIn("inputs.diagnostic == 'tool-conformance'", job["if"])
        self.assertNotIn("--filter", runs)

    def test_conformance_skip_policy_has_no_suite_exemptions(self):
        # Task01 deliberately removed the old MAFFT fixture-skip exception.
        # Every selected test must execute under require-tools.
        gate = (ROOT / "scripts/full-suite-gate.sh").read_text()
        self.assertNotIn("CONFORMANCE_ALLOWLIST=", gate)
        evidence = (ROOT / "scripts/release/gate_evidence.py").read_text()
        self.assertIn('if require_tools and h["skipped"]:', evidence)

    def test_toolset_conformance_provisions_variant_calling_pack(self):
        # ivar/lofreq back ReadsToVariantsEndToEndTests and
        # BAMPrimerTrimSubcommandTests, both of which the filter runs.
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        steps = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("conda install --pack variant-calling", steps)

    def test_toolset_conformance_provisions_the_deacon_panhuman_index(self):
        # RecipeIntegrationTests needs it, and it is a managedData entry that
        # `db download` does not cover.
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        steps = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("db install-managed deacon-panhuman", steps)

    def test_toolset_conformance_installs_parity_test_python_dependencies(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        steps = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("--require-hashes --only-binary=:all: -r scripts/requirements-parity.txt", steps)
        # The parity test resolves python via `/usr/bin/env python3`, so the
        # venv only helps if it is on PATH.
        self.assertIn("GITHUB_PATH", steps)

    def test_provisioning_precedes_the_conformance_run(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        runs = [step.get("run", "") for step in job["steps"]]
        gate_index = next(
            index
            for index, run in enumerate(runs)
            if "scripts/test.py run --profile tool-conformance --require-tools" in run
        )
        for needle in (
            "conda install --pack variant-calling",
            "db install-managed deacon-panhuman",
            "--require-hashes --only-binary=:all: -r scripts/requirements-parity.txt",
        ):
            provision_index = next(
                index for index, run in enumerate(runs) if needle in run
            )
            self.assertLess(
                provision_index,
                gate_index,
                f"{needle!r} must run before the conformance suites",
            )

    def test_toolset_conformance_runs_golden_diff(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        steps = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("scripts/deps/diff_goldens.py", steps)
        self.assertIn("scripts/deps/regenerate-goldens.sh", steps)

    def test_toolset_conformance_caches_managed_tools_by_manifest_hash(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        cache_steps = [
            step
            for step in job["steps"]
            if step.get("uses", "").startswith("actions/cache")
        ]
        self.assertEqual(len(cache_steps), 1)
        cache_step = cache_steps[0]
        self.assertIn("~/.lungfish/conda", cache_step["with"]["path"])
        self.assertIn("manifest.outputs.hash", cache_step["with"]["key"])

    def test_toolset_conformance_verifies_the_reconciled_dependency_receipt(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        receipt_step = next(
            step
            for step in job["steps"]
            if step.get("name") == "Verify dependency receipt"
        )
        script = receipt_step.get("run", "")
        self.assertIn("dependency-receipt.json", script)
        self.assertIn(
            'receipt.get("dependencySet") != manifest.get("dependencySet")', script
        )
        self.assertIn('receipt.get("synthesized")', script)
        self.assertIn("required_environments", script)
        self.assertIn(
            'receipt_environments.get(name, {}).get("state") != "installed"', script
        )
        self.assertIn('receipt.get("manifestHash") != canonical_manifest_hash', script)

    def test_toolset_conformance_uploads_gate_logs_even_on_failure(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        upload_steps = [
            step
            for step in job["steps"]
            if step.get("uses", "").startswith("actions/upload-artifact")
        ]
        self.assertEqual(len(upload_steps), 1)
        self.assertEqual(upload_steps[0].get("if"), "always()")
        self.assertEqual(upload_steps[0]["with"]["path"], ".build/tool-conformance-evidence")

    def test_main_push_is_fast_and_release_tags_do_not_start_blocking_ci(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        push = wf[True]["push"]
        self.assertEqual(push, {"branches": ["main"]})
        self.assertNotIn("release", wf[True])
        self.assertNotIn("package-smoke", wf["jobs"])
        self.assertFalse(
            any(name.startswith("release-") for name in wf["jobs"]), wf["jobs"]
        )

    def test_advisory_build_jobs_resolve_the_supported_xcode_range(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        expected_jobs = {
            "full",
            "toolset-conformance",
        }
        resolver = 'python3 scripts/release/release_xcode.py --shell >> "$GITHUB_ENV"'
        for job_name in expected_jobs:
            selections = [
                step
                for step in wf["jobs"][job_name]["steps"]
                if step.get("name") == "Select supported Xcode"
            ]
            self.assertEqual(len(selections), 1, job_name)
            self.assertEqual(selections[0].get("run"), resolver, job_name)

        self.assertNotIn("xcode-select -s", self.workflow)
        self.assertNotIn("Xcode_26.4.1", self.workflow)

    def test_github_actions_is_read_only_advisory_and_never_publishes(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        self.assertEqual(wf["permissions"], {"contents": "read"})
        serialized = yaml.safe_dump(wf["jobs"])
        self.assertNotIn("secrets.", serialized)
        self.assertNotIn("release.py publish", serialized)
        self.assertNotIn("gh release create", serialized)
        for job in wf["jobs"].values():
            self.assertNotIn("permissions", job)
        self.assertNotIn("release", wf[True])


if __name__ == "__main__":
    unittest.main()

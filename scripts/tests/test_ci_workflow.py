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

    def test_script_test_environments_install_pyyaml(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        for job_name in ("fast", "build-smoke"):
            install = next(
                step
                for step in wf["jobs"][job_name]["steps"]
                if step.get("name") == "Install script test dependencies"
            )
            self.assertIn("PyYAML", install.get("run", ""), job_name)

    def test_fast_gate_repairs_xcode_lockfile_before_and_after_xcodebuild_then_checks_afterward(
        self,
    ):
        repair = "bash scripts/check-package-resolved-consistency.sh --repair"
        xcodebuild = "xcodebuild -project Lungfish.xcodeproj -scheme Lungfish"
        check = "bash scripts/check-package-resolved-consistency.sh"

        self.assertIn(repair, self.workflow)
        repair_positions = [
            index
            for index in range(len(self.workflow))
            if self.workflow.startswith(repair, index)
        ]
        self.assertGreaterEqual(len(repair_positions), 2)
        first_repair, second_repair = repair_positions[:2]
        final_check = self.workflow.index(check, second_repair + len(repair))
        self.assertLess(self.workflow.index("run: swift package resolve"), first_repair)
        self.assertLess(first_repair, self.workflow.index(xcodebuild))
        self.assertLess(self.workflow.index(xcodebuild), second_repair)
        self.assertLess(second_repair, final_check)

    def test_fast_gate_installs_native_tools_before_smoke_package_tests(self):
        install_tools = "brew install htslib samtools seqkit"
        htslib_link = 'ln -sf "$(brew --prefix htslib)/bin/bgzip" "$HOME/.lungfish/conda/envs/htslib/bin/bgzip"'
        samtools_link = 'ln -sf "$(brew --prefix samtools)/bin/samtools" "$HOME/.lungfish/conda/envs/samtools/bin/samtools"'
        seqkit_link = 'ln -sf "$(brew --prefix seqkit)/bin/seqkit" "$HOME/.lungfish/conda/envs/seqkit/bin/seqkit"'
        smoke_tests = "swift test --filter"

        self.assertIn(install_tools, self.workflow)
        self.assertIn(htslib_link, self.workflow)
        self.assertIn(samtools_link, self.workflow)
        self.assertIn(seqkit_link, self.workflow)
        self.assertLess(
            self.workflow.index(install_tools), self.workflow.index(htslib_link)
        )
        self.assertLess(
            self.workflow.index(htslib_link), self.workflow.index(smoke_tests)
        )
        self.assertLess(
            self.workflow.index(samtools_link), self.workflow.index(smoke_tests)
        )
        self.assertLess(
            self.workflow.index(seqkit_link), self.workflow.index(smoke_tests)
        )

    def test_full_suite_provisions_the_manifest_toolset_and_python_used_by_unfiltered_tests(
        self,
    ):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["full"]
        steps = "\n".join(step.get("run", "") for step in job["steps"])

        self.assertEqual(job["needs"], ["fast", "toolset-conformance"])
        self.assertIn("swift build --product lungfish-cli", steps)
        self.assertIn("tools update --apply --yes --required-only", steps)
        self.assertIn("pip install numpy biopython scipy pandas", steps)
        self.assertIn("GITHUB_PATH", steps)

        cache_steps = [
            step
            for step in job["steps"]
            if step.get("uses", "").startswith("actions/cache")
        ]
        self.assertEqual(len(cache_steps), 1)
        self.assertIn("~/.lungfish/conda", cache_steps[0]["with"]["path"])
        self.assertIn("manifest.outputs.hash", cache_steps[0]["with"]["key"])

        full_suite = next(
            index
            for index, step in enumerate(job["steps"])
            if step.get("name") == "Run full package tests"
        )
        provisioning = next(
            index
            for index, step in enumerate(job["steps"])
            if step.get("name") == "Provision required tools"
        )
        self.assertLess(provisioning, full_suite)

    def test_toolset_conformance_job_exists_and_is_dispatch_only(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        self.assertIn("workflow_dispatch", job["if"])
        steps = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("tools update --apply --yes --required-only", steps)
        self.assertIn("LUNGFISH_REQUIRE_TOOLS", steps)
        self.assertIn("full-suite-gate.sh --require-tools", steps)

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

    def test_toolset_conformance_filter_covers_the_conformance_allowlist(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        steps = " ".join(step.get("run", "") for step in job["steps"])
        expected_filter = (
            "Conformance|FASTQToolIntegrationTests|RecipeIntegrationTests|"
            "NativeToolRunnerTests|MAFFTAlignmentPipelineTests|"
            "ClassificationPipelineIntegrationTests|ReadsToVariantsEndToEndTests|"
            "BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests|"
            "FASTQIngestionPipelineTests|FASTQBatchImporterRecipeIntegrationTests|"
            "GenotypeWorkbookManagedRuntimeProbeTests|FASTQOperationRoundTripTests|"
            "FastqGenotypingCommandTests|PrimerTrimThenIVarTests|"
            "ExtractReadsByIdBAMProcessTests"
        )
        self.assertIn(expected_filter, steps)

    def test_ci_filter_and_gate_allowlist_name_the_same_suites(self):
        """The job filter and the gate's --require-tools allowlist must agree.

        A suite in the filter but not the allowlist can skip silently under
        --require-tools; a suite in the allowlist but not the filter never
        runs in this job, so its skips are never checked at all.
        """
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        steps = " ".join(step.get("run", "") for step in job["steps"])
        gate = (ROOT / "scripts/full-suite-gate.sh").read_text(encoding="utf-8")

        # Class names the allowlist regex enumerates, minus the generic
        # ".*Conformance.*" alternative that the filter spells "Conformance".
        allowlist_line = next(
            line
            for line in gate.splitlines()
            if line.startswith("CONFORMANCE_ALLOWLIST=")
        )
        allowlist_names = {
            name
            for name in allowlist_line.split("(", 1)[1].split(")", 1)[0].split("|")
            if name.endswith("Tests")
        }

        filter_line = next(line for line in steps.split("\n") if "--filter" in line)
        filter_names = {
            name
            for name in filter_line.split("'")[1].split("|")
            if name.endswith("Tests")
        }

        # MAFFTAlignmentPipelineTests is deliberately in the filter only: its
        # sole skip guards fixture creation, not tool availability.
        filter_only_by_design = {"MAFFTAlignmentPipelineTests"}
        self.assertEqual(
            allowlist_names - filter_names,
            set(),
            "suites in the gate allowlist but missing from the CI filter never run in this job",
        )
        self.assertEqual(
            filter_names - allowlist_names - filter_only_by_design,
            set(),
            "suites in the CI filter but missing from the gate allowlist can skip silently",
        )

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
        self.assertIn("pip install numpy biopython scipy pandas", steps)
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
            if "full-suite-gate.sh --require-tools" in run
        )
        for needle in (
            "conda install --pack variant-calling",
            "db install-managed deacon-panhuman",
            "pip install numpy biopython scipy pandas",
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
        self.assertEqual(upload_steps[0]["with"]["path"], ".build/gate-logs")

    def test_main_push_packages_both_channels_through_the_supported_front_door(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["package-smoke"]
        self.assertEqual(job["strategy"]["matrix"]["channel"], ["preview", "stable"])
        self.assertIn("github.event_name == 'push'", job["if"])
        self.assertIn("refs/heads/main", job["if"])
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertIn(
            "python3 scripts/release/release.py package ${{ matrix.channel }}", runs
        )
        self.assertNotIn("scripts/release/build-notarized-dmg.sh", runs)
        self.assertNotIn("--package-only", runs)
        self.assertNotIn("--signing-identity", runs)
        self.assertNotIn("--notary-profile", runs)
        self.assertNotIn("gh release", runs)

    def test_build_and_release_jobs_resolve_the_supported_xcode_range(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        expected_jobs = {
            "package-smoke",
            "release-dependency-receipt",
            "release-preview-gates",
            "release-stable-full",
            "release-stable-conformance",
            "build-smoke",
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

    def test_package_smoke_uses_the_validator_approved_repository_defaults(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["package-smoke"]
        build = next(
            step
            for step in job["steps"]
            if step.get("name") == "Build and verify unsigned candidate"
        )["run"]

        self.assertNotIn("--release-dir", build)
        self.assertNotIn("--archive-path", build)
        self.assertNotIn("--derived-data-path", build)
        self.assertIn(
            'package_log="$PWD/.build/package-only-${{ matrix.channel }}.log"', build
        )
        self.assertNotIn("build/Release/package-only", build)

    def test_package_evidence_excludes_apps_archives_and_private_or_signed_payloads(
        self,
    ):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["package-smoke"]
        upload = next(
            step
            for step in job["steps"]
            if step.get("uses", "").startswith("actions/upload-artifact")
        )
        paths = upload["with"]["path"]
        self.assertEqual(upload.get("if"), "always()")
        self.assertEqual(upload["with"]["if-no-files-found"], "ignore")
        self.assertIn("build/Release/${{ matrix.channel }}/", paths)
        self.assertIn("package-metadata.txt", paths)
        self.assertIn("unsigned-candidate-receipt.json", paths)
        self.assertIn(".build/package-only-${{ matrix.channel }}.log", paths)
        self.assertNotIn("Release/package-only.log", paths)
        build = next(
            step
            for step in job["steps"]
            if step.get("name") == "Build and verify unsigned candidate"
        )["run"]
        self.assertIn("package-only-${{ matrix.channel }}.log", build)
        self.assertIn('>"$package_log" 2>&1', build)
        for forbidden in ("*.app", ".xcarchive", "signed/", "*.dmg", "private"):
            self.assertNotIn(forbidden, paths)

    def test_tag_candidate_context_parses_exact_committed_channel_field(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        push = wf[True]["push"]
        self.assertEqual(push["tags"], ["v*"])
        context = wf["jobs"]["release-context"]
        runs = "\n".join(step.get("run", "") for step in context["steps"])
        self.assertIn("docs/release-notes/${version}.md", runs)
        self.assertIn("^Channel: Preview$", runs)
        self.assertIn("^Channel: Stable$", runs)
        self.assertIn("channel=preview", runs)
        self.assertIn("channel=stable", runs)

    def test_tag_candidate_has_mandatory_focused_dependency_and_channel_gates(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        jobs = wf["jobs"]
        self.assertIn("release-focused", jobs)
        self.assertIn("release-dependency-receipt", jobs)
        self.assertEqual(
            jobs["release-dependency-receipt"]["if"],
            "${{ needs.release-context.result == 'success' }}",
        )
        preview = "\n".join(
            step.get("run", "") for step in jobs["release-preview-gates"]["steps"]
        )
        self.assertIn("--tier unit", preview)
        self.assertIn("--tier integration", preview)
        stable_full = "\n".join(
            step.get("run", "") for step in jobs["release-stable-full"]["steps"]
        )
        stable_conformance = "\n".join(
            step.get("run", "") for step in jobs["release-stable-conformance"]["steps"]
        )
        self.assertIn("--tier full", stable_full)
        self.assertIn("--tier conformance --require-tools", stable_conformance)
        dependency = "\n".join(
            step.get("run", "") for step in jobs["release-dependency-receipt"]["steps"]
        )
        self.assertIn("dependency-receipt.json", dependency)
        self.assertIn("verify_dependency_receipt_file", dependency)
        self.assertNotIn("--verify-dependency-receipt", dependency)
        for job_name in (
            "release-preview-gates",
            "release-stable-full",
            "release-stable-conformance",
        ):
            self.assertIn("release-dependency-receipt", jobs[job_name]["needs"])

    def test_release_jobs_are_read_only_secretless_and_release_event_is_defense_only(
        self,
    ):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        self.assertEqual(wf["permissions"], {"contents": "read"})
        release_jobs = {
            name: job
            for name, job in wf["jobs"].items()
            if name.startswith("release-") or name == "package-smoke"
        }
        serialized = yaml.safe_dump(release_jobs)
        self.assertNotIn("secrets.", serialized)
        for job in release_jobs.values():
            self.assertNotIn("permissions", job)
        defense = wf["jobs"]["stable-release-defense"]
        self.assertIn("github.event_name == 'release'", defense["if"])
        self.assertIn("release-stable-full", wf["jobs"])
        self.assertIn("release-stable-conformance", wf["jobs"])


if __name__ == "__main__":
    unittest.main()

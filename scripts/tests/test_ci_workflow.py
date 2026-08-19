import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def yaml_load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


class CIWorkflowTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2]
        self.workflow = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")

    def test_script_test_environments_install_pyyaml(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        for job_name in ("fast", "build-smoke"):
            install = next(
                step
                for step in wf["jobs"][job_name]["steps"]
                if step.get("name") == "Install script test dependencies"
            )
            self.assertIn("PyYAML", install.get("run", ""), job_name)

    def test_fast_gate_repairs_xcode_lockfile_before_and_after_xcodebuild_then_checks_afterward(self):
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
        self.assertLess(self.workflow.index(install_tools), self.workflow.index(htslib_link))
        self.assertLess(self.workflow.index(htslib_link), self.workflow.index(smoke_tests))
        self.assertLess(self.workflow.index(samtools_link), self.workflow.index(smoke_tests))
        self.assertLess(self.workflow.index(seqkit_link), self.workflow.index(smoke_tests))

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
            line for line in gate.splitlines() if line.startswith("CONFORMANCE_ALLOWLIST=")
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
            index for index, run in enumerate(runs) if "full-suite-gate.sh --require-tools" in run
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
        cache_steps = [step for step in job["steps"] if step.get("uses", "").startswith("actions/cache")]
        self.assertEqual(len(cache_steps), 1)
        cache_step = cache_steps[0]
        self.assertIn("~/.lungfish/conda", cache_step["with"]["path"])
        self.assertIn("manifest.outputs.hash", cache_step["with"]["key"])

    def test_toolset_conformance_uploads_gate_logs_even_on_failure(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        upload_steps = [step for step in job["steps"] if step.get("uses", "").startswith("actions/upload-artifact")]
        self.assertEqual(len(upload_steps), 1)
        self.assertEqual(upload_steps[0].get("if"), "always()")
        self.assertEqual(upload_steps[0]["with"]["path"], ".build/gate-logs")


if __name__ == "__main__":
    unittest.main()

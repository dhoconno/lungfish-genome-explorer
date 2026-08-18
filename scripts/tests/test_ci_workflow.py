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
            "BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests"
        )
        self.assertIn(expected_filter, steps)

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

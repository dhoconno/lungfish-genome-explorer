"""The golden workflow runs only on the self-hosted golden runner and never
runs pull request code (docs/contracts/MACHINES.md)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "golden.yml"


class GoldenWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

    def test_runs_on_pushes_to_main_and_by_hand_but_never_on_pull_requests(self):
        triggers = self.workflow[True]
        self.assertEqual(set(triggers), {"push", "workflow_dispatch"})
        self.assertEqual(triggers["push"], {"branches": ["main"]})

    def test_every_job_runs_on_the_self_hosted_golden_runner(self):
        for name, job in self.workflow["jobs"].items():
            with self.subTest(job=name):
                self.assertEqual(job["runs-on"], ["self-hosted", "macOS", "ARM64", "lge-golden"])

    def test_actions_are_pinned_to_full_commits(self):
        for job in self.workflow["jobs"].values():
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")

    def test_read_only_without_secrets_and_one_run_at_a_time(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertNotIn("secrets.", yaml.safe_dump(self.workflow["jobs"]))
        self.assertEqual(self.workflow["concurrency"], {"group": "golden", "cancel-in-progress": False})

    def test_checks_python_before_anything_else_runs(self):
        steps = self.workflow["jobs"]["golden"]["steps"]
        self.assertEqual(steps[1]["name"], "Check Python")
        self.assertIn("(3, 11)", steps[1]["run"])

    def test_provisions_from_the_lock_before_comparing(self):
        runs = [step.get("run", "") for step in self.workflow["jobs"]["golden"]["steps"]]
        provision = runs.index("python3 scripts/golden/environment.py provision")
        compare = runs.index("python3 scripts/golden/golden.py compare")
        self.assertLess(provision, compare)


if __name__ == "__main__":
    unittest.main()

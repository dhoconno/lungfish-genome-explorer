"""Pin the full-suite gate's tier regexes against the CI workflow's copies.

The gate's named tiers (smoke/unit/integration/conformance/full) select suites
with filter regexes that also appear in .github/workflows/ci.yml. A drift
between the two silently changes what a tier covers, so this test asserts the
load-bearing equalities:

- the conformance tier's filter is byte-identical to the toolset-conformance
  job's --filter,
- the smoke tier's filter is byte-identical to the build-smoke job's smoke
  regex,
- the storage-suite list is byte-identical to the project-storage
  --no-parallel filter,
- the unit tier's skip regex is composed from the integration + conformance
  variables (so unit/integration/conformance partition the suite by
  construction),
- --parallel stays rejected for selections containing the ProjectStorage
  suites.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _gate_text() -> str:
    return (ROOT / "scripts/full-suite-gate.sh").read_text(encoding="utf-8")


def _workflow_text() -> str:
    return (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")


def _gate_var(name: str) -> str:
    match = re.search(rf"^{name}='([^']*)'", _gate_text(), re.MULTILINE)
    assert match, f"gate does not define {name} as a single-quoted variable"
    return match.group(1)


class FullSuiteGateTierTests(unittest.TestCase):
    def test_gate_defines_exactly_the_five_tiers(self):
        gate = _gate_text()
        case_block = gate.split('case "$TIER" in', 1)[1].split("esac", 1)[0]
        for tier in ("smoke)", "unit)", "integration)", "conformance)", "full)"):
            self.assertIn(tier, case_block, f"missing tier arm: {tier}")
        self.assertIn(
            "unknown tier: $TIER (smoke|unit|integration|conformance|full)",
            gate,
            "the unknown-tier error must enumerate the five tiers",
        )

    def test_conformance_tier_matches_the_ci_toolset_conformance_filter(self):
        workflow = _workflow_text()
        match = re.search(
            r"full-suite-gate\.sh --require-tools --filter '([^']*)'", workflow
        )
        self.assertIsNotNone(match, "CI no longer runs the conformance filter")
        self.assertEqual(
            _gate_var("CONFORMANCE_FILTER"),
            match.group(1),
            "gate CONFORMANCE_FILTER drifted from the toolset-conformance job",
        )

    def test_smoke_tier_matches_the_ci_smoke_regex(self):
        workflow = _workflow_text()
        match = re.search(
            r"swift test --filter '(\^\(LungfishCoreTests[^']*)'", workflow
        )
        self.assertIsNotNone(match, "CI no longer runs the smoke regex")
        self.assertEqual(
            _gate_var("SMOKE_FILTER"),
            match.group(1),
            "gate SMOKE_FILTER drifted from the build-smoke job's smoke regex",
        )

    def test_storage_suites_match_the_ci_no_parallel_filter(self):
        workflow = _workflow_text()
        match = re.search(
            r"swift test --no-parallel --filter \\\n\s*'([^']*)'", workflow
        )
        self.assertIsNotNone(match, "CI no longer runs the storage --no-parallel filter")
        self.assertEqual(
            _gate_var("STORAGE_SUITES"),
            match.group(1),
            "gate STORAGE_SUITES drifted from the project-storage job",
        )

    def test_unit_tier_skip_is_composed_from_integration_and_conformance(self):
        gate = _gate_text()
        self.assertIn(
            'INTEGRATION_FILTER="^LungfishIntegrationTests\\\\.|${CLI_E2E_SUITES}|${STORAGE_SUITES}|${PARALLEL_HAZARD_SUITES}"',
            gate,
            "INTEGRATION_FILTER must be composed from the CLI + storage + "
            "parallel-hazard variables",
        )
        self.assertIn(
            'SKIP="${INTEGRATION_FILTER}|${CONFORMANCE_FILTER}"',
            gate,
            "unit tier must skip exactly the integration + conformance selections",
        )

    def test_unit_tier_implies_parallel(self):
        gate = _gate_text()
        unit_arm = gate.split("unit)", 1)[1].split(";;", 1)[0]
        self.assertIn(
            "PARALLEL=1",
            unit_arm,
            "the unit tier must force --parallel: its --skip selection exceeds "
            "ARG_MAX in serial mode (posix_spawn: Argument list too long)",
        )

    def test_parallel_runs_retry_failing_classes_serially(self):
        gate = _gate_text()
        self.assertIn(
            'if [ "$PARALLEL" -eq 1 ] && [ "$xctest_fail" -gt 0 ] && [ "$swifttesting_fail" -eq 0 ]; then',
            gate,
            "parallel runs must retry XCTest failures serially (and never retry "
            "swift-testing failures)",
        )
        self.assertIn(
            "flaky-under-parallel, passed serial retry",
            gate,
            "a pass that needed the serial retry must loudly name the retried "
            "classes instead of masking the flakiness",
        )
        self.assertIn(
            '[ "$class_count" -le 12 ]',
            gate,
            "more than 12 failing classes means real breakage and must not retry",
        )

    def test_parallel_is_rejected_for_storage_bearing_selections(self):
        self.assertIn(
            "--parallel is not allowed for selections containing the ProjectStorage suites",
            _gate_text(),
            "the --parallel guard for integration/full/unfiltered runs is gone",
        )


if __name__ == "__main__":
    unittest.main()

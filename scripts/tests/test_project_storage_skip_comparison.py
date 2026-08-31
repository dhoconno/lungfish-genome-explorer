import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.verification.compare_project_storage_skips import (
    ComparisonError,
    compare_runs,
    parse_xctest_log,
    validated_policy,
)


def serial_log(records, terminal_skips=None):
    lines = ["Test Suite 'Selected tests' started at now."]
    for identifier, reason in records:
        lines.append(f"Test Case '{identifier}' started.")
        if reason is None:
            lines.append(f"Test Case '{identifier}' passed (0.001 seconds).")
            continue
        reason_lines = reason.split("\n")
        lines.append(
            f"/checkout/Tests/File.swift:7: {identifier} : "
            f"Test skipped - {reason_lines[0]}"
        )
        lines.extend(reason_lines[1:])
        lines.append(f"Test Case '{identifier}' skipped (0.001 seconds).")
    count = (
        sum(reason is not None for _, reason in records)
        if terminal_skips is None
        else terminal_skips
    )
    lines.extend(
        [
            "Test Suite 'Selected tests' passed at now.",
            f"\t Executed {len(records)} tests, with {count} "
            f"{'test' if count == 1 else 'tests'} skipped and 0 failures "
            "(0 unexpected) in 0.1 seconds",
        ]
    )
    return "\n".join(lines) + "\n"


class ParserTests(unittest.TestCase):
    def test_parses_darwin_identifier_and_multiline_reason_verbatim(self):
        identifier = "-[Module.ExistingTests testNeedsOptional Tool]"
        reason = (
            "optional tool missing at /checkout path/tool\n"
            "second line preserves spaces and errno=45"
        )
        parsed = parse_xctest_log(
            serial_log([(identifier, reason)]),
            swift_status=0,
            tee_status=0,
        )
        self.assertEqual(parsed.terminal_skip_count, 1)
        self.assertEqual(parsed.skip_multiset, {(identifier, reason): 1})
        self.assertEqual(parsed.started_identifiers, (identifier,))

    def test_parses_corelibs_identifier_and_reason_without_identifier(self):
        identifier = "Module.CaseSensitiveVolumeTests/testRequiresVolume"
        text = "\n".join(
            [
                "Test Suite 'All tests' started at now.",
                f"Test Case '{identifier}' started.",
                "Test skipped - requires case-sensitive volume",
                f"Test Case '{identifier}' skipped (0.1 seconds).",
                "Test Suite 'All tests' passed at now.",
                "\t Executed 1 test, with 1 test skipped and 0 failures.",
            ]
        )
        parsed = parse_xctest_log(text, swift_status=0, tee_status=0)
        self.assertEqual(
            parsed.skip_multiset,
            {(identifier, "requires case-sensitive volume"): 1},
        )

    def test_parses_dotted_corelibs_identifier_in_diagnostic(self):
        identifier = "Module.OptionalFixtureTests.testFixture"
        text = serial_log([(identifier, "fixture unavailable")])
        parsed = parse_xctest_log(
            text,
            swift_status=0,
            tee_status=0,
        )
        self.assertEqual(
            parsed.skip_multiset,
            {(identifier, "fixture unavailable"): 1},
        )

    def test_bracket_prefixed_multiline_reason_is_preserved(self):
        identifier = "-[Module.ToolTests testTool]"
        reason = (
            "optional tool unavailable\n"
            "[resolver] searched /checkout/path with spaces\n"
            "final diagnostic"
        )
        parsed = parse_xctest_log(
            serial_log([(identifier, reason)]),
            swift_status=0,
            tee_status=0,
        )
        self.assertEqual(parsed.skip_multiset, {(identifier, reason): 1})

    def test_duplicate_occurrences_are_a_multiset(self):
        identifier = "-[Module.NetworkTests testOffline]"
        parsed = parse_xctest_log(
            serial_log(
                [
                    (identifier, "network unavailable"),
                    (identifier, "network unavailable"),
                ]
            ),
            swift_status=0,
            tee_status=0,
        )
        self.assertEqual(
            parsed.skip_multiset[(identifier, "network unavailable")],
            2,
        )

    def test_crlf_is_the_only_line_ending_normalization(self):
        identifier = "-[Module.ToolTests testTool]"
        parsed = parse_xctest_log(
            serial_log([(identifier, "tool  path")]).replace("\n", "\r\n"),
            swift_status=0,
            tee_status=0,
        )
        self.assertEqual(
            parsed.skip_multiset,
            {(identifier, "tool  path"): 1},
        )

    def test_lone_carriage_return_in_reason_is_not_normalized(self):
        identifier = "-[Module.ToolTests testTool]"
        reason = "tool unavailable\rlone carriage return"
        parsed = parse_xctest_log(
            serial_log([(identifier, reason)]),
            swift_status=0,
            tee_status=0,
        )
        self.assertEqual(parsed.skip_multiset, {(identifier, reason): 1})

    def assert_parse_fails(self, text, swift_status=0, tee_status=0):
        with self.assertRaises(ComparisonError):
            parse_xctest_log(
                text,
                swift_status=swift_status,
                tee_status=tee_status,
            )

    def test_fails_on_unmatched_skip_event(self):
        text = serial_log([("-[Module.Tests testOne]", "reason")]).replace(
            "Test skipped - reason\n", ""
        )
        self.assert_parse_fails(text)

    def test_fails_on_finished_event_without_started_record(self):
        text = (
            serial_log([("-[Module.Tests testOne]", None)])
            .replace(
                "Test Case '-[Module.Tests testOne]' started.\n",
                "",
            )
            .replace("Executed 1 test", "Executed 0 tests")
        )
        self.assert_parse_fails(text)

    def test_fails_when_serial_test_starts_before_active_test_finishes(self):
        first = "-[Module.Tests testOne]"
        second = "-[Module.Tests testTwo]"
        text = serial_log([(first, None), (second, None)]).replace(
            f"Test Case '{first}' passed (0.001 seconds).\n"
            f"Test Case '{second}' started.\n",
            f"Test Case '{second}' started.\n"
            f"Test Case '{first}' passed (0.001 seconds).\n",
        )
        self.assert_parse_fails(text)

    def test_fails_on_unmatched_reason(self):
        text = serial_log([("-[Module.Tests testOne]", "reason")]).replace(
            "Test Case '-[Module.Tests testOne]' skipped (0.001 seconds).\n",
            "",
        )
        self.assert_parse_fails(text)

    def test_fails_on_ambiguous_reasons(self):
        text = serial_log([("-[Module.Tests testOne]", "reason")]).replace(
            "Test skipped - reason\n",
            "Test skipped - reason\nTest skipped - second\n",
        )
        self.assert_parse_fails(text)

    def test_fails_on_summary_count_disagreement(self):
        self.assert_parse_fails(
            serial_log(
                [("-[Module.Tests testOne]", "reason")],
                terminal_skips=0,
            )
        )

    def test_fails_on_missing_terminal_summary(self):
        self.assert_parse_fails(
            "Test Case '-[Module.Tests testOne]' started.\n"
            "Test Case '-[Module.Tests testOne]' passed.\n"
        )

    def test_fails_on_unfinished_started_event(self):
        text = (
            serial_log([])
            .replace(
                "Test Suite 'Selected tests' passed at now.\n",
                "Test Case '-[Module.Tests testUnfinished]' started.\n"
                "Test Suite 'Selected tests' passed at now.\n",
            )
            .replace("Executed 0 tests", "Executed 1 test")
        )
        self.assert_parse_fails(text)

    def test_fails_when_executed_total_disagrees_with_finished_events(self):
        text = serial_log([("-[Module.Tests testOne]", None)]).replace(
            "Executed 1 test", "Executed 2 tests"
        )
        self.assert_parse_fails(text)

    def test_fails_on_test_event_after_terminal_suite_summary(self):
        text = serial_log([]) + (
            "Test Case '-[Module.Tests testLate]' started.\n"
            "Test Case '-[Module.Tests testLate]' passed (0.001 seconds).\n"
        )
        self.assert_parse_fails(text)

    def test_fails_on_new_suite_start_after_terminal_suite_summary(self):
        text = serial_log([]) + "Test Suite 'Truncated rerun' started at now.\n"
        self.assert_parse_fails(text)

    def test_fails_on_nonzero_swift_or_tee_status(self):
        passing = serial_log([])
        self.assert_parse_fails(passing, swift_status=1)
        self.assert_parse_fails(passing, tee_status=1)


class ComparisonTests(unittest.TestCase):
    baseline = "c658f123de9d04a5d73014252ee1b93dd7736661"
    scanner_class = "ProjectStorageScannerLargeTreeTests"
    preparation_class = "ProjectStorageCleanupPreparationLargeTreeTests"
    performance_class = "ProjectStoragePerformanceTests"
    hard_link_reason_pattern = (
        "^hard-link-unavailable: errno="
        "(?:18 \\(EXDEV\\)|45 \\(ENOTSUP\\)|102 \\(EOPNOTSUPP\\))$"
    )

    allowed_rule_keys = (
        (
            scanner_class,
            "testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB",
            ("^storage-perf-disabled: LUNGFISH_RUN_STORAGE_PERF is absent$",),
        ),
        (
            performance_class,
            "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds",
            ("^storage-perf-disabled: LUNGFISH_RUN_STORAGE_PERF is absent$",),
        ),
        (
            scanner_class,
            "testCISemanticFixtureHasExactTopology",
            (hard_link_reason_pattern,),
        ),
        (
            scanner_class,
            "testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries",
            (hard_link_reason_pattern,),
        ),
        (
            scanner_class,
            "testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable",
            (hard_link_reason_pattern,),
        ),
        (
            scanner_class,
            "testHardLinkTrackingBudgetFailsClosed",
            (hard_link_reason_pattern,),
        ),
        (
            preparation_class,
            (
                "testLargePreparationReusesAttestedDescriptorsAndHashesEach"
                "UnattestedInodeOnce"
            ),
            (hard_link_reason_pattern,),
        ),
    )
    expected_inventory = (
        (scanner_class, "testCISemanticFixtureHasExactTopology"),
        (scanner_class, "testReleaseRepresentativeConfigurationIsExact"),
        (
            scanner_class,
            "testLargeTreeScanStreamsWithoutReadingOrHashingPayloads",
        ),
        (
            scanner_class,
            "testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries",
        ),
        (
            scanner_class,
            "testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable",
        ),
        (
            scanner_class,
            "testLargeTreeCancellationReturnsNoPartialResultAndMutatesNothing",
        ),
        (
            scanner_class,
            "testLargeTreeCandidateReplacementDuringScanFailsClosed",
        ),
        (
            scanner_class,
            "testLargeOperationHistoryTreeIsSkippedAndNeverOffered",
        ),
        (
            scanner_class,
            "testLargeTreeScanEmitsBalancedScanInstrumentation",
        ),
        (scanner_class, "testHardLinkTrackingBudgetFailsClosed"),
        (
            scanner_class,
            "testRetainedScannerStateMatchesDeclaredComplexityBound",
        ),
        (
            scanner_class,
            "testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB",
        ),
        (
            preparation_class,
            (
                "testLargePreparationReusesAttestedDescriptorsAndHashesEach"
                "UnattestedInodeOnce"
            ),
        ),
        (
            preparation_class,
            "testLargePreparationCancellationBeforePublicationMutatesNoSelectedRoot",
        ),
        (
            preparation_class,
            (
                "testLargePreparationEmitsBalancedDescriptorPreparation"
                "Instrumentation"
            ),
        ),
        (
            preparation_class,
            "testLargePreparationWritesCompleteCanonicalProvenance",
        ),
        (
            performance_class,
            "testProjectOpenDoesNotInvokeAutomaticStorageCleanup",
        ),
        (
            performance_class,
            "testProjectOpenLeavesStorageFixtureUnchanged",
        ),
        (
            performance_class,
            ("testDefaultScanAuthorityAndCleanupPreparationWorkersRunOff" "MainThread"),
        ),
        (
            performance_class,
            "testProgressRelayBoundsMainActorDeliveryCountWithInjectedClock",
        ),
        (
            performance_class,
            "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds",
        ),
        (
            performance_class,
            "testLargePreviewEmitsBalancedMainActorCommitInstrumentation",
        ),
    )

    def policy(self):
        return validated_policy(
            {
                "schemaVersion": 1,
                "baselineSHA": self.baseline,
                "newTestClasses": [
                    self.scanner_class,
                    self.preparation_class,
                    self.performance_class,
                ],
                "newTestInventory": [
                    {"class": class_name, "test": test_name}
                    for class_name, test_name in self.expected_inventory
                ],
                "allowedNewTestSkips": [
                    {
                        "class": class_name,
                        "test": test_name,
                        "reasonPatterns": list(patterns),
                    }
                    for class_name, test_name, patterns in self.allowed_rule_keys
                ],
            }
        )

    @classmethod
    def inventory_records(cls, reasons=None):
        reasons = reasons or {}
        records = []
        for class_name, test_name in cls.expected_inventory:
            module = (
                "LungfishAppTests"
                if class_name == cls.performance_class
                else "LungfishWorkflowTests"
            )
            records.append(
                (
                    f"-[{module}.{class_name} {test_name}]",
                    reasons.get((class_name, test_name)),
                )
            )
        return records

    def parsed(self, records):
        return parse_xctest_log(
            serial_log(records),
            swift_status=0,
            tee_status=0,
        )

    def test_accepts_unchanged_inherited_skips_and_allowed_new_skips(self):
        inherited = [
            (
                "-[Module.TrashTests testTrash]",
                "Trash unavailable at /same checkout",
            ),
            (
                "-[Module.OpenpyxlTests testWorkbook]",
                "openpyxl missing",
            ),
            (
                "-[Module.CaseSensitiveVolumeTests testRequiresVolume]",
                "requires case-sensitive volume",
            ),
            (
                "-[Module.OptionalFixtureTests testFixture]",
                "optional fixture unavailable at /same checkout",
            ),
            (
                "-[Module.OptionalToolTests testTool]",
                "optional tool seqkit unavailable",
            ),
            (
                "-[Module.NetworkTests testOffline]",
                "network unavailable",
            ),
            (
                "-[Module.LegacyPerformanceTests testHardwareBudget]",
                "performance hardware unavailable",
            ),
        ]
        allowed_reasons = {
            (
                self.scanner_class,
                "testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB",
            ): "storage-perf-disabled: LUNGFISH_RUN_STORAGE_PERF is absent",
            (
                self.performance_class,
                "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds",
            ): "storage-perf-disabled: LUNGFISH_RUN_STORAGE_PERF is absent",
            (
                self.scanner_class,
                "testCISemanticFixtureHasExactTopology",
            ): "hard-link-unavailable: errno=18 (EXDEV)",
            (
                self.scanner_class,
                "testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries",
            ): "hard-link-unavailable: errno=45 (ENOTSUP)",
            (
                self.scanner_class,
                "testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable",
            ): "hard-link-unavailable: errno=102 (EOPNOTSUPP)",
            (
                self.scanner_class,
                "testHardLinkTrackingBudgetFailsClosed",
            ): "hard-link-unavailable: errno=18 (EXDEV)",
            (
                self.preparation_class,
                (
                    "testLargePreparationReusesAttestedDescriptorsAndHashesEach"
                    "UnattestedInodeOnce"
                ),
            ): "hard-link-unavailable: errno=45 (ENOTSUP)",
        }
        implementation = inherited + self.inventory_records(allowed_reasons)
        result = compare_runs(
            self.parsed(inherited),
            self.parsed(implementation),
            self.policy(),
        )
        self.assertTrue(result["passed"])
        self.assertEqual(len(result["newTestDecisions"]), 7)

    def test_rejects_new_class_in_baseline(self):
        record = (
            "-[Module.ProjectStoragePerformanceTests "
            "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds]",
            None,
        )
        with self.assertRaises(ComparisonError):
            compare_runs(
                self.parsed([record]),
                self.parsed(self.inventory_records()),
                self.policy(),
            )

    def test_rejects_missing_extra_and_duplicate_inventory_tests(self):
        complete = self.inventory_records()
        extra = (
            "-[LungfishWorkflowTests.ProjectStorageScannerLargeTreeTests "
            "testUndeclaredExtra]",
            None,
        )
        cases = [
            complete[:-1],
            [*complete, extra],
            [*complete, complete[0]],
        ]
        for implementation in cases:
            with self.subTest(implementation=implementation[-2:]):
                with self.assertRaises(ComparisonError):
                    compare_runs(
                        self.parsed([]),
                        self.parsed(implementation),
                        self.policy(),
                    )

    def test_rejects_added_removed_reason_changed_and_count_changed_inherited(self):
        one = ("-[Module.TrashTests testTrash]", "Trash unavailable")
        changed = ("-[Module.TrashTests testTrash]", "different reason")
        cases = [
            ([], [one]),
            ([one], []),
            ([one], [changed]),
            ([one, one], [one]),
        ]
        for base, implementation in cases:
            with self.subTest(base=base, implementation=implementation):
                with self.assertRaises(ComparisonError):
                    compare_runs(
                        self.parsed(base),
                        self.parsed([*implementation, *self.inventory_records()]),
                        self.policy(),
                    )

    def test_rejects_forbidden_new_test_or_reason(self):
        forbidden_test = (
            "-[Module.ProjectStoragePerformanceTests testDeterministic]",
            "storage-perf-disabled: missing",
        )
        forbidden_reason = (
            "-[Module.ProjectStoragePerformanceTests "
            "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds]",
            "arbitrary skip",
        )
        cases = [
            [*self.inventory_records(), forbidden_test],
            self.inventory_records(
                {
                    (
                        self.performance_class,
                        (
                            "testLargePreviewMaximumMainThreadStallIsUnder"
                            "100Milliseconds"
                        ),
                    ): forbidden_reason[1]
                }
            ),
        ]
        for implementation in cases:
            with self.subTest(implementation=implementation[-1]):
                with self.assertRaises(ComparisonError):
                    compare_runs(
                        self.parsed([]),
                        self.parsed(implementation),
                        self.policy(),
                    )

    def test_rejects_mismatched_hard_link_errno_and_symbol(self):
        record = (
            "-[Module.ProjectStorageScannerLargeTreeTests "
            "testCISemanticFixtureHasExactTopology]",
            "hard-link-unavailable: errno=1 (EXDEV)",
        )
        with self.assertRaises(ComparisonError):
            compare_runs(
                self.parsed([]),
                self.parsed(
                    self.inventory_records(
                        {
                            (
                                self.scanner_class,
                                "testCISemanticFixtureHasExactTopology",
                            ): record[1]
                        }
                    )
                ),
                self.policy(),
            )

    def test_policy_requires_exact_sha_classes_and_rules(self):
        with self.assertRaises(ComparisonError):
            validated_policy(
                {
                    "schemaVersion": 1,
                    "baselineSHA": "short",
                    "newTestClasses": [],
                    "allowedNewTestSkips": [],
                }
            )
        value = {
            "schemaVersion": 1,
            "baselineSHA": self.baseline,
            "newTestClasses": [
                self.scanner_class,
                self.preparation_class,
                self.performance_class,
            ],
            "newTestInventory": [
                {"class": class_name, "test": test_name}
                for class_name, test_name in self.expected_inventory
            ],
            "allowedNewTestSkips": [
                {
                    "class": class_name,
                    "test": test_name,
                    "reasonPatterns": list(patterns),
                }
                for class_name, test_name, patterns in self.allowed_rule_keys
            ],
        }
        for mutation in [
            "baseline",
            "classes",
            "inventory-missing",
            "inventory-extra",
            "inventory-reordered",
            "rules",
        ]:
            changed = json.loads(json.dumps(value))
            if mutation == "baseline":
                changed["baselineSHA"] = "0" * 40
            elif mutation == "classes":
                changed["newTestClasses"][0] = "WrongClass"
            elif mutation == "inventory-missing":
                changed["newTestInventory"].pop()
            elif mutation == "inventory-extra":
                changed["newTestInventory"].append(
                    {
                        "class": self.scanner_class,
                        "test": "testUndeclaredExtra",
                    }
                )
            elif mutation == "inventory-reordered":
                changed["newTestInventory"][0:2] = reversed(
                    changed["newTestInventory"][0:2]
                )
            else:
                changed["allowedNewTestSkips"][0]["test"] = "wrongTest"
            with self.subTest(mutation=mutation):
                with self.assertRaises(ComparisonError):
                    validated_policy(changed)


class PolicyFileTests(unittest.TestCase):
    def test_policy_json_round_trip(self):
        root = Path(__file__).resolve().parents[2]
        policy = json.loads(
            (
                root / "scripts/verification/" "project-storage-task9-skip-policy.json"
            ).read_text(encoding="utf-8")
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            self.assertEqual(
                validated_policy(json.loads(path.read_text())).baseline_sha,
                policy["baselineSHA"],
            )

    def test_repository_policy_has_the_exact_classes_and_seven_allowances(self):
        root = Path(__file__).resolve().parents[2]
        policy = validated_policy(
            json.loads(
                (
                    root / "scripts/verification/"
                    "project-storage-task9-skip-policy.json"
                ).read_text(encoding="utf-8")
            )
        )
        self.assertEqual(
            policy.baseline_sha,
            "c658f123de9d04a5d73014252ee1b93dd7736661",
        )
        self.assertEqual(
            policy.new_test_classes,
            (
                "ProjectStorageScannerLargeTreeTests",
                "ProjectStorageCleanupPreparationLargeTreeTests",
                "ProjectStoragePerformanceTests",
            ),
        )
        self.assertEqual(
            policy.new_test_inventory,
            ComparisonTests.expected_inventory,
        )
        actual_rules = {
            (rule.class_name, rule.test_name, rule.reason_patterns)
            for rule in policy.allowed_new_test_skips
        }
        self.assertEqual(
            actual_rules,
            set(ComparisonTests.allowed_rule_keys),
        )

    def test_cli_writes_fail_closed_report_for_nonzero_status(self):
        root = Path(__file__).resolve().parents[2]
        policy = root / "scripts/verification/project-storage-task9-skip-policy.json"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            base = temporary / "base.log"
            implementation = temporary / "implementation.log"
            report = temporary / "report.json"
            base.write_text(serial_log([]), encoding="utf-8")
            implementation.write_text(serial_log([]), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(
                        root / "scripts/verification/"
                        "compare_project_storage_skips.py"
                    ),
                    "--policy",
                    str(policy),
                    "--base-log",
                    str(base),
                    "--implementation-log",
                    str(implementation),
                    "--base-swift-status",
                    "1",
                    "--base-tee-status",
                    "0",
                    "--implementation-swift-status",
                    "0",
                    "--implementation-tee-status",
                    "0",
                    "--report",
                    str(report),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            value = json.loads(report.read_text(encoding="utf-8"))
            self.assertFalse(value["passed"])
            self.assertEqual(value["rawLogs"]["base"]["swiftStatus"], 1)

    def test_cli_writes_report_for_policy_and_argument_failures(self):
        root = Path(__file__).resolve().parents[2]
        comparator = root / "scripts/verification/compare_project_storage_skips.py"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            invalid_policy = temporary / "invalid-policy.json"
            invalid_policy.write_text("{}\n", encoding="utf-8")
            for label, argv in [
                (
                    "policy",
                    ["--policy", str(invalid_policy)],
                ),
                (
                    "arguments",
                    [
                        "--policy",
                        str(
                            root / "scripts/verification/"
                            "project-storage-task9-skip-policy.json"
                        ),
                    ],
                ),
                (
                    "missing-policy-argument",
                    ["--unknown-comparator-option"],
                ),
                (
                    "invalid-status-argument",
                    [
                        "--policy",
                        str(
                            root / "scripts/verification/"
                            "project-storage-task9-skip-policy.json"
                        ),
                        "--base-swift-status",
                        "not-an-integer",
                    ],
                ),
            ]:
                report = temporary / f"{label}-report.json"
                result = subprocess.run(
                    [
                        sys.executable,
                        str(comparator),
                        *argv,
                        "--report",
                        str(report),
                    ],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                with self.subTest(label=label):
                    self.assertNotEqual(result.returncode, 0)
                    value = json.loads(report.read_text(encoding="utf-8"))
                    self.assertFalse(value["passed"])
                    self.assertIn("error", value)

    def test_cli_reports_forbidden_new_skip_as_rejected_decision(self):
        root = Path(__file__).resolve().parents[2]
        policy = root / "scripts/verification/project-storage-task9-skip-policy.json"
        forbidden = (
            "-[LungfishAppTests.ProjectStoragePerformanceTests "
            "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds]",
            "arbitrary skip",
        )
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            base = temporary / "base.log"
            implementation = temporary / "implementation.log"
            report = temporary / "report.json"
            base.write_text(serial_log([]), encoding="utf-8")
            implementation.write_text(
                serial_log(
                    ComparisonTests.inventory_records(
                        {
                            (
                                ComparisonTests.performance_class,
                                (
                                    "testLargePreviewMaximumMainThreadStall"
                                    "IsUnder100Milliseconds"
                                ),
                            ): forbidden[1]
                        }
                    )
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(
                        root / "scripts/verification/"
                        "compare_project_storage_skips.py"
                    ),
                    "--policy",
                    str(policy),
                    "--base-log",
                    str(base),
                    "--implementation-log",
                    str(implementation),
                    "--base-swift-status",
                    "0",
                    "--base-tee-status",
                    "0",
                    "--implementation-swift-status",
                    "0",
                    "--implementation-tee-status",
                    "0",
                    "--report",
                    str(report),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            value = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(
                value["newTestDecisions"],
                [
                    {
                        "decision": "rejected",
                        "occurrenceCount": 1,
                        "reason": "arbitrary skip",
                        "testIdentifier": forbidden[0],
                    }
                ],
            )

    def test_cli_does_not_treat_lone_carriage_return_as_line_feed(self):
        root = Path(__file__).resolve().parents[2]
        policy = root / "scripts/verification/project-storage-task9-skip-policy.json"
        identifier = "-[Module.OptionalToolTests testTool]"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            base = temporary / "base.log"
            implementation = temporary / "implementation.log"
            report = temporary / "report.json"
            base.write_bytes(serial_log([(identifier, "alpha\rbeta")]).encode("utf-8"))
            implementation.write_bytes(
                serial_log(
                    [
                        (identifier, "alpha\nbeta"),
                        *ComparisonTests.inventory_records(),
                    ]
                ).encode("utf-8")
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(
                        root / "scripts/verification/"
                        "compare_project_storage_skips.py"
                    ),
                    "--policy",
                    str(policy),
                    "--base-log",
                    str(base),
                    "--implementation-log",
                    str(implementation),
                    "--base-swift-status",
                    "0",
                    "--base-tee-status",
                    "0",
                    "--implementation-swift-status",
                    "0",
                    "--implementation-tee-status",
                    "0",
                    "--report",
                    str(report),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            value = json.loads(report.read_text(encoding="utf-8"))
            self.assertFalse(value["passed"])
            self.assertIn("multiset changed", value["error"])


class RunnerAndCITests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.runner = (
            self.root / "scripts/verification/run_project_storage_skip_comparison.sh"
        ).read_text(encoding="utf-8")
        self.workflow = (self.root / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )

    def workflow_job(self, name):
        match = re.search(
            rf"^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
            self.workflow,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, f"missing workflow job: {name}")
        return match.group("body")

    def test_runner_has_exact_suites_pipe_statuses_and_same_worktree(self):
        self.assertIn("ci-focused)", self.runner)
        self.assertIn("focused)", self.runner)
        self.assertIn("scientific)", self.runner)
        self.assertIn("full)", self.runner)
        self.assertIn("swift test --no-parallel", self.runner)
        self.assertIn('task9_pipeline_status=("${PIPESTATUS[@]}")', self.runner)
        self.assertIn(
            'task9_swift_status="${task9_pipeline_status[0]}"',
            self.runner,
        )
        self.assertIn(
            'task9_tee_status="${task9_pipeline_status[1]}"',
            self.runner,
        )
        self.assertEqual(
            self.runner.count('git -C "$task9_caller_root" worktree add --detach'),
            1,
        )
        self.assertIn(
            'task9_worktree="$task9_temporary_root/worktree"',
            self.runner,
        )

    def test_ci_uses_full_history_exact_block_and_always_uploads(self):
        checkout_count = self.workflow.count("uses: actions/checkout@")
        full_history_checkout_count = len(
            re.findall(
                r"uses: actions/checkout@[^\n]+\n"
                r"\s+with:\n"
                r"\s+fetch-depth: 0(?:\n|$)",
                self.workflow,
            )
        )
        self.assertGreater(checkout_count, 0)
        self.assertEqual(full_history_checkout_count, checkout_count)
        self.assertIn(
            'task9_implementation_sha="$(git log --diff-filter=A '
            "--format=%H -1 -- scripts/verification/"
            'project-storage-task9-skip-policy.json)"',
            self.workflow,
        )
        self.assertIn("--suite ci-focused", self.workflow)
        self.assertIn("if: always()", self.workflow)
        for suffix in [
            "base.log",
            "base-status.json",
            "implementation.log",
            "implementation-status.json",
            "report.json",
        ]:
            self.assertIn(f"ci-focused-{suffix}", self.workflow)

    def test_dependency_receipt_job_installs_pinned_bootstrap_before_reconcile(self):
        job = self.workflow_job("release-dependency-receipt")
        self.assertIn("- name: Install pinned micromamba bootstrap", job)
        install_index = job.index("- name: Install pinned micromamba bootstrap")
        reconcile_index = job.index("- name: Reconcile dependency receipt")
        self.assertLess(install_index, reconcile_index)
        command = job[install_index:reconcile_index]
        self.assertIn("third-party-tools-lock.json", command)
        self.assertIn("Sources/LungfishWorkflow/Resources/Tools/micromamba", command)
        self.assertIn("$HOME/.lungfish/conda/bin/micromamba", command)

    def test_ci_runs_current_head_ci_focused_storage_gate_separately(self):
        current_head_filter = (
            "'ProjectStorageScannerLargeTreeTests|ProjectStorageScannerTests|"
            "ProjectStorageCleanupPreparationLargeTreeTests|"
            "ProjectStorageCleanupProvenanceTests|"
            "ProjectStoragePublishedCleanupOutcomeReaderTests|"
            "ProjectStorageAutomaticCleanupServiceTests|"
            "ProjectStoragePerformanceTests|ProjectTempCleanupTests'"
        )
        self.assertIn(
            "- name: Test current HEAD project-storage implementation",
            self.workflow,
        )
        self.assertIn(
            'task9_current_head_sha="$(git rev-parse HEAD)"',
            self.workflow,
        )
        self.assertIn(
            'test "$(git rev-parse HEAD)" = "$task9_current_head_sha"',
            self.workflow,
        )
        self.assertIn("swift test --no-parallel --filter", self.workflow)
        self.assertIn(current_head_filter, self.workflow)
        self.assertLess(
            self.workflow.index("- name: Compare deterministic project-storage skips"),
            self.workflow.index(
                "- name: Test current HEAD project-storage implementation"
            ),
        )

    def test_runner_preflight_failure_still_writes_all_artifacts(self):
        for copy_policy in [True, False]:
            with self.subTest(copy_policy=copy_policy):
                with tempfile.TemporaryDirectory() as directory:
                    repository = Path(directory) / "repository"
                    verification = repository / "scripts/verification"
                    verification.mkdir(parents=True)
                    shutil.copy2(
                        self.root / "scripts/verification/"
                        "compare_project_storage_skips.py",
                        verification / "compare_project_storage_skips.py",
                    )
                    if copy_policy:
                        shutil.copy2(
                            self.root / "scripts/verification/"
                            "project-storage-task9-skip-policy.json",
                            verification / "project-storage-task9-skip-policy.json",
                        )
                    subprocess.run(
                        ["git", "init", "-q", str(repository)],
                        check=True,
                    )
                    output = repository / ".build/project-storage-skip-comparison"
                    report = output / "ci-focused-report.json"
                    result = subprocess.run(
                        [
                            str(
                                self.root / "scripts/verification/"
                                "run_project_storage_skip_comparison.sh"
                            ),
                            "--suite",
                            "ci-focused",
                            "--base-sha",
                            "0" * 40,
                            "--implementation-sha",
                            "1" * 40,
                            "--report",
                            str(report),
                        ],
                        cwd=repository,
                        check=False,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assert_comparison_artifacts(output, report)

    def test_runner_post_preflight_infrastructure_failure_writes_artifacts(
        self,
    ):
        baseline = "c658f123de9d04a5d73014252ee1b93dd7736661"
        implementation = "1" * 40
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            verification = repository / "scripts/verification"
            verification.mkdir(parents=True)
            for name in [
                "compare_project_storage_skips.py",
                "project-storage-task9-skip-policy.json",
            ]:
                shutil.copy2(
                    self.root / "scripts/verification" / name,
                    verification / name,
                )
            fake_bin = Path(directory) / "fake-bin"
            fake_bin.mkdir()
            fake_git = fake_bin / "git"
            fake_git.write_text(
                "#!/usr/bin/env bash\n"
                'if [[ "$*" == "rev-parse --show-toplevel" ]]; then\n'
                f"  printf '%s\\n' '{repository}'\n"
                'elif [[ "$*" == *"rev-parse "*"^" ]]; then\n'
                f"  printf '%s\\n' '{baseline}'\n"
                "fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            invalid_tmpdir = Path(directory) / "not-a-directory"
            invalid_tmpdir.write_text("file\n", encoding="utf-8")
            output = repository / ".build/project-storage-skip-comparison"
            report = output / "ci-focused-report.json"
            environment = dict(os.environ)
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["TMPDIR"] = str(invalid_tmpdir)
            result = subprocess.run(
                [
                    str(
                        self.root / "scripts/verification/"
                        "run_project_storage_skip_comparison.sh"
                    ),
                    "--suite",
                    "ci-focused",
                    "--base-sha",
                    baseline,
                    "--implementation-sha",
                    implementation,
                    "--report",
                    str(report),
                ],
                cwd=repository,
                env=environment,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assert_comparison_artifacts(output, report)
            self.assertIn(
                "infrastructure",
                json.loads(report.read_text(encoding="utf-8"))["error"],
            )

    def test_stale_passing_report_cannot_survive_final_comparator_failure(
        self,
    ):
        baseline = "c658f123de9d04a5d73014252ee1b93dd7736661"
        implementation = "1" * 40
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            repository = temporary / "repository"
            verification = repository / "scripts/verification"
            verification.mkdir(parents=True)
            for name in [
                "compare_project_storage_skips.py",
                "project-storage-task9-skip-policy.json",
            ]:
                shutil.copy2(
                    self.root / "scripts/verification" / name,
                    verification / name,
                )
            fake_bin = temporary / "fake-bin"
            fake_bin.mkdir()
            fake_git = fake_bin / "git"
            fake_git.write_text(
                "#!/usr/bin/env bash\n"
                'if [[ "$*" == "rev-parse --show-toplevel" ]]; then\n'
                f"  printf '%s\\n' '{repository}'\n"
                'elif [[ "$*" == *"rev-parse "*"^" ]]; then\n'
                f"  printf '%s\\n' '{baseline}'\n"
                'elif [[ "$*" == *"worktree add --detach"* ]]; then\n'
                '  mkdir -p "$6"\n'
                'elif [[ "$*" == *"worktree remove --force"* ]]; then\n'
                '  rm -rf "$6"\n'
                "fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            invocation_count = temporary / "swift-invocations"
            fake_swift = fake_bin / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                f"count_file='{invocation_count}'\n"
                "count=0\n"
                '[[ -f "$count_file" ]] && count="$(<"$count_file")"\n'
                "count=$((count + 1))\n"
                'printf \'%s\\n\' "$count" >"$count_file"\n'
                "printf '%s\\n' \"Test Suite 'Selected tests' started at now.\"\n"
                "printf '%s\\n' \"Test Suite 'Selected tests' passed at now.\"\n"
                "printf '\\t Executed 0 tests, with 0 failures.\\n'\n"
                'if [[ "$count" -eq 2 ]]; then\n'
                f"  rm -f '{verification}/compare_project_storage_skips.py'\n"
                "fi\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            output = repository / ".build/project-storage-skip-comparison"
            output.mkdir(parents=True)
            report = output / "ci-focused-report.json"
            report.write_text(
                '{"schemaVersion": 1, "passed": true}\n',
                encoding="utf-8",
            )
            environment = dict(os.environ)
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            result = subprocess.run(
                [
                    str(
                        self.root / "scripts/verification/"
                        "run_project_storage_skip_comparison.sh"
                    ),
                    "--suite",
                    "ci-focused",
                    "--base-sha",
                    baseline,
                    "--implementation-sha",
                    implementation,
                    "--report",
                    str(report),
                ],
                cwd=repository,
                env=environment,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assert_comparison_artifacts(output, report)
            value = json.loads(report.read_text(encoding="utf-8"))
            self.assertIn("infrastructure", value["error"])
            self.assertEqual(value["rawLogs"]["base"]["swiftStatus"], 0)
            self.assertEqual(
                value["rawLogs"]["implementation"]["swiftStatus"],
                0,
            )

    def assert_comparison_artifacts(self, output, report):
        for suffix in [
            "base.log",
            "base-status.json",
            "implementation.log",
            "implementation-status.json",
            "report.json",
        ]:
            path = output / f"ci-focused-{suffix}"
            self.assertTrue(path.is_file(), path)
        self.assertFalse(json.loads(report.read_text(encoding="utf-8"))["passed"])


if __name__ == "__main__":
    unittest.main()

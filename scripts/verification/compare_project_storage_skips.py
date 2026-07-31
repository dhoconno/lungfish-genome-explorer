#!/usr/bin/env python3
"""Fail-closed comparison of serial XCTest skip records."""

from __future__ import annotations

import argparse
import collections
import dataclasses
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


class ComparisonError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        report_updates: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.report_updates = report_updates or {}


@dataclasses.dataclass(frozen=True)
class SkipRule:
    class_name: str
    test_name: str
    reason_patterns: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class Policy:
    baseline_sha: str
    new_test_classes: tuple[str, ...]
    new_test_inventory: tuple[tuple[str, str], ...]
    allowed_new_test_skips: tuple[SkipRule, ...]


@dataclasses.dataclass(frozen=True)
class ParsedLog:
    skip_multiset: dict[tuple[str, str], int]
    started_identifiers: tuple[str, ...]
    terminal_executed_count: int
    terminal_skip_count: int
    terminal_suite: str


@dataclasses.dataclass
class _TestEvent:
    identifier: str
    reasons: list[str] = dataclasses.field(default_factory=list)
    skipped: bool = False
    finished: bool = False


_STARTED = re.compile(r"^Test Case '(.+)' started\.")
_SKIPPED = re.compile(r"^Test Case '(.+)' skipped(?:\s|\.)")
_FINISHED = re.compile(r"^Test Case '(.+)' (?:passed|failed)(?:\s|\.)")
_FINAL_SUITE = re.compile(
    r"^Test Suite '(Selected tests|All tests)' (?:passed|failed) at "
)
_SUITE_STARTED = re.compile(r"^Test Suite '.+' started(?:\s|\.|$)")
_EXECUTED = re.compile(r"Executed\s+(\d+)\s+tests?")
_SKIP_COUNT = re.compile(r"with\s+(\d+)\s+tests?\s+skipped")
_DARWIN_IDENTIFIER = re.compile(r"-\[[^\]]+\]")
_CORELIBS_IDENTIFIER = re.compile(
    r"[A-Za-z_][A-Za-z0-9_.]*\.[A-Za-z_][A-Za-z0-9_]*"
    r"/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?"
)
_DOTTED_IDENTIFIER_AT_END = re.compile(
    r"(?:^|[\s:])" r"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)" r"\s*:\s*$"
)
_REASON_BOUNDARY = re.compile(r"^(?:Test Case '|Test Suite '|◇|↳|✔|✘)")

_EXPECTED_BASELINE_SHA = "c658f123de9d04a5d73014252ee1b93dd7736661"
_EXPECTED_NEW_TEST_CLASSES = (
    "ProjectStorageScannerLargeTreeTests",
    "ProjectStorageCleanupPreparationLargeTreeTests",
    "ProjectStoragePerformanceTests",
)
_EXPECTED_NEW_TEST_INVENTORY = (
    (
        "ProjectStorageScannerLargeTreeTests",
        "testCISemanticFixtureHasExactTopology",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testReleaseRepresentativeConfigurationIsExact",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeScanStreamsWithoutReadingOrHashingPayloads",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeCancellationReturnsNoPartialResultAndMutatesNothing",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeCandidateReplacementDuringScanFailsClosed",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeOperationHistoryTreeIsSkippedAndNeverOffered",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeScanEmitsBalancedScanInstrumentation",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testHardLinkTrackingBudgetFailsClosed",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testRetainedScannerStateMatchesDeclaredComplexityBound",
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB",
    ),
    (
        "ProjectStorageCleanupPreparationLargeTreeTests",
        (
            "testLargePreparationReusesAttestedDescriptorsAndHashesEach"
            "UnattestedInodeOnce"
        ),
    ),
    (
        "ProjectStorageCleanupPreparationLargeTreeTests",
        "testLargePreparationCancellationBeforePublicationMutatesNoSelectedRoot",
    ),
    (
        "ProjectStorageCleanupPreparationLargeTreeTests",
        ("testLargePreparationEmitsBalancedDescriptorPreparation" "Instrumentation"),
    ),
    (
        "ProjectStorageCleanupPreparationLargeTreeTests",
        "testLargePreparationWritesCompleteCanonicalProvenance",
    ),
    (
        "ProjectStoragePerformanceTests",
        "testProjectOpenDoesNotInvokeAutomaticStorageCleanup",
    ),
    (
        "ProjectStoragePerformanceTests",
        "testProjectOpenLeavesStorageFixtureUnchanged",
    ),
    (
        "ProjectStoragePerformanceTests",
        ("testDefaultScanAuthorityAndCleanupPreparationWorkersRunOff" "MainThread"),
    ),
    (
        "ProjectStoragePerformanceTests",
        "testProgressRelayBoundsMainActorDeliveryCountWithInjectedClock",
    ),
    (
        "ProjectStoragePerformanceTests",
        "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds",
    ),
    (
        "ProjectStoragePerformanceTests",
        "testLargePreviewEmitsBalancedMainActorCommitInstrumentation",
    ),
)
_PERFORMANCE_DISABLED_PATTERN = (
    r"^storage-perf-disabled: LUNGFISH_RUN_STORAGE_PERF is absent$"
)
_HARD_LINK_UNAVAILABLE_PATTERN = (
    r"^hard-link-unavailable: errno="
    r"(?:18 \(EXDEV\)|45 \(ENOTSUP\)|102 \(EOPNOTSUPP\))$"
)
_EXPECTED_RULES = (
    (
        "ProjectStorageScannerLargeTreeTests",
        "testReleaseRepresentativeScanMemoryDeltaIsAtMost96MiB",
        (_PERFORMANCE_DISABLED_PATTERN,),
    ),
    (
        "ProjectStoragePerformanceTests",
        "testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds",
        (_PERFORMANCE_DISABLED_PATTERN,),
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testCISemanticFixtureHasExactTopology",
        (_HARD_LINK_UNAVAILABLE_PATTERN,),
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeHardLinksAreDeduplicatedAcrossCandidateBoundaries",
        (_HARD_LINK_UNAVAILABLE_PATTERN,),
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testLargeTreeExternalHardLinkSurvivorIsNotCreditedAsReclaimable",
        (_HARD_LINK_UNAVAILABLE_PATTERN,),
    ),
    (
        "ProjectStorageScannerLargeTreeTests",
        "testHardLinkTrackingBudgetFailsClosed",
        (_HARD_LINK_UNAVAILABLE_PATTERN,),
    ),
    (
        "ProjectStorageCleanupPreparationLargeTreeTests",
        (
            "testLargePreparationReusesAttestedDescriptorsAndHashesEach"
            "UnattestedInodeOnce"
        ),
        (_HARD_LINK_UNAVAILABLE_PATTERN,),
    ),
)


def validated_policy(value: dict[str, Any]) -> Policy:
    if value.get("schemaVersion") != 1:
        raise ComparisonError("policy schemaVersion must be 1")
    baseline = value.get("baselineSHA")
    if not isinstance(baseline, str) or not re.fullmatch(r"[0-9a-f]{40}", baseline):
        raise ComparisonError("policy baselineSHA must be 40 lowercase hex")
    if baseline != _EXPECTED_BASELINE_SHA:
        raise ComparisonError("policy baselineSHA differs from Task 9 base")
    classes = value.get("newTestClasses")
    if classes != list(_EXPECTED_NEW_TEST_CLASSES):
        raise ComparisonError("policy newTestClasses differs from Task 9")
    inventory_value = value.get("newTestInventory")
    expected_inventory_value = [
        {"class": class_name, "test": test_name}
        for class_name, test_name in _EXPECTED_NEW_TEST_INVENTORY
    ]
    if inventory_value != expected_inventory_value:
        raise ComparisonError(
            "policy newTestInventory differs from exact Task 9 inventory"
        )
    rules_value = value.get("allowedNewTestSkips")
    if not isinstance(rules_value, list):
        raise ComparisonError("policy allowedNewTestSkips must be a list")
    rules: list[SkipRule] = []
    for item in rules_value:
        if not isinstance(item, dict):
            raise ComparisonError("each skip rule must be an object")
        class_name = item.get("class")
        test_name = item.get("test")
        patterns = item.get("reasonPatterns")
        if class_name not in classes:
            raise ComparisonError("skip rule references an unknown class")
        if not isinstance(test_name, str) or not test_name:
            raise ComparisonError("skip rule test must be nonempty")
        if (
            not isinstance(patterns, list)
            or not patterns
            or any(not isinstance(pattern, str) for pattern in patterns)
        ):
            raise ComparisonError("skip rule needs reasonPatterns")
        for pattern in patterns:
            try:
                re.compile(pattern)
            except re.error as error:
                raise ComparisonError(
                    f"invalid reason pattern {pattern!r}: {error}"
                ) from error
        rules.append(SkipRule(class_name, test_name, tuple(patterns)))
    actual_rules = tuple(
        (rule.class_name, rule.test_name, rule.reason_patterns) for rule in rules
    )
    if actual_rules != _EXPECTED_RULES:
        raise ComparisonError("policy allowedNewTestSkips differs from Task 9 matrix")
    return Policy(
        baseline,
        tuple(classes),
        _EXPECTED_NEW_TEST_INVENTORY,
        tuple(rules),
    )


def load_policy(path: Path) -> Policy:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ComparisonError(f"cannot read policy {path}: {error}") from error
    if not isinstance(value, dict):
        raise ComparisonError("policy root must be an object")
    return validated_policy(value)


def _explicit_identifier(prefix: str) -> str | None:
    darwin = _DARWIN_IDENTIFIER.findall(prefix)
    corelibs = _CORELIBS_IDENTIFIER.findall(prefix)
    dotted = _DOTTED_IDENTIFIER_AT_END.search(prefix)
    identifiers = darwin or corelibs
    if not identifiers and dotted:
        identifiers = [dotted.group(1)]
    if len(identifiers) > 1:
        raise ComparisonError("skip diagnostic contains multiple test identifiers")
    return identifiers[0] if identifiers else None


def _reason_continues(line: str) -> bool:
    if "Test skipped -" in line:
        return False
    if _REASON_BOUNDARY.match(line):
        return False
    if _EXECUTED.search(line):
        return False
    return True


def parse_xctest_log(
    raw_text: str,
    *,
    swift_status: int,
    tee_status: int,
) -> ParsedLog:
    if swift_status != 0 or tee_status != 0:
        raise ComparisonError(
            f"nonzero pipeline status: swift={swift_status}, tee={tee_status}"
        )
    text = raw_text.replace("\r\n", "\n")
    if not text:
        raise ComparisonError("raw console log is absent or truncated")
    lines = text.split("\n")
    events: list[_TestEvent] = []
    active_index: int | None = None
    reason_assignments = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        started = _STARTED.match(line)
        if started:
            if active_index is not None and not events[active_index].finished:
                raise ComparisonError("serial test started before active test finished")
            events.append(_TestEvent(started.group(1)))
            active_index = len(events) - 1
            index += 1
            continue

        marker = line.find("Test skipped -")
        if marker >= 0:
            prefix = line[:marker]
            explicit = _explicit_identifier(prefix)
            first = line[marker + len("Test skipped -") :]
            if first.startswith(" "):
                first = first[1:]
            reason_lines = [first]
            cursor = index + 1
            while cursor < len(lines) and _reason_continues(lines[cursor]):
                reason_lines.append(lines[cursor])
                cursor += 1
            reason = "\n".join(reason_lines)
            candidates: list[int] = []
            if explicit is not None:
                candidates = [
                    event_index
                    for event_index, event in enumerate(events)
                    if event.identifier == explicit
                    and not event.finished
                    and not event.skipped
                ]
            elif active_index is not None:
                active = events[active_index]
                if not active.finished and not active.skipped:
                    candidates = [active_index]
            if len(candidates) != 1:
                raise ComparisonError(
                    "skip reason has zero or multiple possible events"
                )
            events[candidates[0]].reasons.append(reason)
            reason_assignments += 1
            index = cursor
            continue

        skipped = _SKIPPED.match(line)
        if skipped:
            identifier = skipped.group(1)
            candidates = [
                event_index
                for event_index, event in enumerate(events)
                if event.identifier == identifier
                and not event.finished
                and not event.skipped
            ]
            if len(candidates) != 1:
                raise ComparisonError(
                    "skipped event has zero or multiple started records"
                )
            event = events[candidates[0]]
            event.skipped = True
            event.finished = True
            if active_index == candidates[0]:
                active_index = None
            index += 1
            continue

        finished = _FINISHED.match(line)
        if finished:
            identifier = finished.group(1)
            candidates = [
                event_index
                for event_index, event in enumerate(events)
                if event.identifier == identifier and not event.finished
            ]
            if len(candidates) != 1:
                raise ComparisonError(
                    "finished event has zero or multiple started records"
                )
            events[candidates[0]].finished = True
            if active_index == candidates[0]:
                active_index = None
            index += 1
            continue
        index += 1

    skipped_events = [event for event in events if event.skipped]
    unfinished_events = [event.identifier for event in events if not event.finished]
    if unfinished_events:
        raise ComparisonError(f"unfinished started test events: {unfinished_events!r}")
    for event in skipped_events:
        if len(event.reasons) != 1:
            raise ComparisonError(
                f"skipped event {event.identifier!r} has "
                f"{len(event.reasons)} reasons"
            )
    if reason_assignments != len(skipped_events):
        raise ComparisonError("skip reason/event record counts differ")

    final_indices = [
        (line_index, match.group(1))
        for line_index, line in enumerate(lines)
        if (match := _FINAL_SUITE.match(line))
    ]
    if not final_indices:
        raise ComparisonError("final selected-suite terminal summary absent")
    final_index, final_suite = final_indices[-1]
    if any(
        _STARTED.match(line)
        or _SKIPPED.match(line)
        or _FINISHED.match(line)
        or _SUITE_STARTED.match(line)
        for line in lines[final_index + 1 :]
    ):
        raise ComparisonError(
            "test or suite event appears after terminal suite summary"
        )
    executed_match = next(
        (
            _EXECUTED.search(line)
            for line in lines[final_index + 1 : final_index + 6]
            if _EXECUTED.search(line)
        ),
        None,
    )
    if executed_match is None:
        raise ComparisonError("final selected-suite executed summary absent")
    terminal_executed_count = int(executed_match.group(1))
    if terminal_executed_count != len(events):
        raise ComparisonError(
            "finished event count differs from terminal executed summary"
        )
    executed_line = executed_match.string
    skip_match = _SKIP_COUNT.search(executed_line)
    terminal_skip_count = int(skip_match.group(1)) if skip_match else 0
    if terminal_skip_count != len(skipped_events):
        raise ComparisonError(
            "paired skipped-record count differs from terminal summary"
        )
    multiset = collections.Counter(
        (event.identifier, event.reasons[0]) for event in skipped_events
    )
    return ParsedLog(
        dict(multiset),
        tuple(event.identifier for event in events),
        terminal_executed_count,
        terminal_skip_count,
        final_suite,
    )


def _class_and_test(identifier: str) -> tuple[str, str]:
    darwin = re.fullmatch(r"-\[[^\s]+\.([^.\s]+)\s+([^\]]+)\]", identifier)
    if darwin:
        return darwin.group(1), darwin.group(2)
    corelibs = re.fullmatch(
        r"(?:[A-Za-z_][A-Za-z0-9_.]*\.)?"
        r"([A-Za-z_][A-Za-z0-9_]*)/"
        r"([A-Za-z_][A-Za-z0-9_]*)(?:\(\))?",
        identifier,
    )
    if corelibs:
        return corelibs.group(1), corelibs.group(2)
    dotted = re.fullmatch(
        r"(?:[A-Za-z_][A-Za-z0-9_]*\.)*"
        r"([A-Za-z_][A-Za-z0-9_]*)\."
        r"([A-Za-z_][A-Za-z0-9_]*)(?:\(\))?",
        identifier,
    )
    if dotted:
        return dotted.group(1), dotted.group(2)
    raise ComparisonError(f"unsupported XCTest identifier {identifier!r}")


def _serialized_multiset(
    multiset: dict[tuple[str, str], int],
) -> list[dict[str, Any]]:
    return [
        {
            "testIdentifier": identifier,
            "reason": reason,
            "occurrenceCount": count,
        }
        for (identifier, reason), count in sorted(multiset.items())
    ]


def _new_test_inventory(
    parsed: ParsedLog,
    new_classes: set[str],
) -> collections.Counter[tuple[str, str]]:
    inventory: collections.Counter[tuple[str, str]] = collections.Counter()
    for identifier in parsed.started_identifiers:
        class_name, test_name = _class_and_test(identifier)
        if class_name in new_classes:
            inventory[(class_name, test_name)] += 1
    return inventory


def _serialized_inventory(
    inventory: collections.Counter[tuple[str, str]],
) -> list[dict[str, Any]]:
    return [
        {
            "class": class_name,
            "test": test_name,
            "occurrenceCount": count,
        }
        for (class_name, test_name), count in sorted(inventory.items())
    ]


def compare_runs(
    base: ParsedLog,
    implementation: ParsedLog,
    policy: Policy,
) -> dict[str, Any]:
    new_classes = set(policy.new_test_classes)
    base_inventory = _new_test_inventory(base, new_classes)
    if base_inventory:
        raise ComparisonError(
            "baseline contains a new Task 9 test class",
            report_updates={
                "baselineNewTestInventory": _serialized_inventory(base_inventory)
            },
        )
    implementation_inventory = _new_test_inventory(
        implementation,
        new_classes,
    )
    expected_inventory = collections.Counter(policy.new_test_inventory)
    if implementation_inventory != expected_inventory:
        raise ComparisonError(
            "implementation new-test inventory differs from exact " "Task 9 inventory",
            report_updates={
                "expectedNewTestInventory": _serialized_inventory(expected_inventory),
                "implementationNewTestInventory": _serialized_inventory(
                    implementation_inventory
                ),
            },
        )

    inherited: dict[tuple[str, str], int] = {}
    new_skips: dict[tuple[str, str], int] = {}
    for key, count in implementation.skip_multiset.items():
        class_name, _test_name = _class_and_test(key[0])
        target = new_skips if class_name in new_classes else inherited
        target[key] = count
    if inherited != base.skip_multiset:
        raise ComparisonError(
            "pre-existing skip multiset changed between base and implementation"
        )

    decisions: list[dict[str, Any]] = []
    for (identifier, reason), count in sorted(new_skips.items()):
        class_name, test_name = _class_and_test(identifier)
        matching_rules = [
            rule
            for rule in policy.allowed_new_test_skips
            if rule.class_name == class_name
            and rule.test_name == test_name
            and any(re.fullmatch(pattern, reason) for pattern in rule.reason_patterns)
        ]
        if len(matching_rules) != 1:
            raise ComparisonError(
                f"forbidden new-test skip: {identifier}: {reason}",
                report_updates={
                    "newTestDecisions": [
                        *decisions,
                        {
                            "testIdentifier": identifier,
                            "reason": reason,
                            "occurrenceCount": count,
                            "decision": "rejected",
                        },
                    ]
                },
            )
        decisions.append(
            {
                "testIdentifier": identifier,
                "reason": reason,
                "occurrenceCount": count,
                "decision": "allowed",
            }
        )
    return {
        "passed": True,
        "baselineTerminalExecutedCount": base.terminal_executed_count,
        "implementationTerminalExecutedCount": implementation.terminal_executed_count,
        "baselineTerminalSkipCount": base.terminal_skip_count,
        "implementationTerminalSkipCount": implementation.terminal_skip_count,
        "baselineSkipMultiset": _serialized_multiset(base.skip_multiset),
        "implementationInheritedSkipMultiset": _serialized_multiset(inherited),
        "implementationNewTestSkipMultiset": _serialized_multiset(new_skips),
        "expectedNewTestInventory": _serialized_inventory(expected_inventory),
        "implementationNewTestInventory": _serialized_inventory(
            implementation_inventory
        ),
        "newTestDecisions": decisions,
    }


def _command_output(argv: list[str]) -> str:
    try:
        return subprocess.run(
            argv,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"


def _fingerprint() -> dict[str, Any]:
    optional_tools = [
        "openpyxl",
        "samtools",
        "seqkit",
        "bgzip",
        "trash",
    ]
    environment_flags = [
        "LUNGFISH_RUN_STORAGE_PERF",
        "LUNGFISH_STORAGE_PERF_TRIAL",
        "SWIFT_DETERMINISTIC_HASHING",
        "CI",
    ]
    return {
        "swift": _command_output(["swift", "--version"]),
        "xcode": _command_output(["xcodebuild", "-version"]),
        "macOS": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "filesystem": _command_output(["diskutil", "info", "/"]),
        "optionalToolsPresent": {
            tool: shutil.which(tool) is not None for tool in optional_tools
        },
        "pythonModulesPresent": {
            "openpyxl": importlib.util.find_spec("openpyxl") is not None
        },
        "environmentFlagsPresent": {
            name: name in os.environ for name in environment_flags
        },
    }


def _raw_metadata(
    path: Path,
    swift_status: int,
    tee_status: int,
) -> dict[str, Any]:
    data = path.read_bytes() if path.exists() else b""
    return {
        "path": str(path),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "swiftStatus": swift_status,
        "teeStatus": tee_status,
    }


def _read_utf8_exact(path: Path) -> str:
    return path.read_bytes().decode("utf-8")


class _FailClosedArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ComparisonError(f"invalid arguments: {message}")


def _arguments() -> argparse.Namespace:
    parser = _FailClosedArgumentParser()
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--print-baseline-sha", action="store_true")
    parser.add_argument("--base-log", type=Path)
    parser.add_argument("--implementation-log", type=Path)
    parser.add_argument("--base-swift-status", type=int)
    parser.add_argument("--base-tee-status", type=int)
    parser.add_argument("--implementation-swift-status", type=int)
    parser.add_argument("--implementation-tee-status", type=int)
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def _report_path_from_argv(argv: list[str]) -> Path | None:
    report: Path | None = None
    for index, item in enumerate(argv):
        if item == "--report" and index + 1 < len(argv):
            report = Path(argv[index + 1])
        elif item.startswith("--report="):
            report = Path(item.split("=", 1)[1])
    return report


def _write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "passed": False,
    }
    fallback_report = _report_path_from_argv(sys.argv[1:])
    try:
        arguments = _arguments()
    except ComparisonError as error:
        report["error"] = str(error)
        if fallback_report is not None:
            try:
                _write_report(fallback_report, report)
            except OSError as report_error:
                print(
                    "project-storage skip comparison could not write "
                    f"report: {report_error}",
                    file=sys.stderr,
                )
        print(f"project-storage skip comparison failed: {error}", file=sys.stderr)
        return 1
    try:
        if arguments.policy is None:
            raise ComparisonError("comparison --policy argument is required")
        policy = load_policy(arguments.policy)
        if arguments.print_baseline_sha:
            print(policy.baseline_sha)
            return 0
        report.update(
            {
                "baselineSHA": policy.baseline_sha,
                "machineEnvironment": _fingerprint(),
            }
        )
        required = [
            arguments.base_log,
            arguments.implementation_log,
            arguments.base_swift_status,
            arguments.base_tee_status,
            arguments.implementation_swift_status,
            arguments.implementation_tee_status,
            arguments.report,
        ]
        if any(value is None for value in required):
            raise ComparisonError("comparison arguments are incomplete")
        report.update(
            {
                "rawLogs": {
                    "base": _raw_metadata(
                        arguments.base_log,
                        arguments.base_swift_status,
                        arguments.base_tee_status,
                    ),
                    "implementation": _raw_metadata(
                        arguments.implementation_log,
                        arguments.implementation_swift_status,
                        arguments.implementation_tee_status,
                    ),
                },
            }
        )
        base = parse_xctest_log(
            _read_utf8_exact(arguments.base_log),
            swift_status=arguments.base_swift_status,
            tee_status=arguments.base_tee_status,
        )
        implementation = parse_xctest_log(
            _read_utf8_exact(arguments.implementation_log),
            swift_status=arguments.implementation_swift_status,
            tee_status=arguments.implementation_tee_status,
        )
        report.update(
            {
                "baselineTerminalExecutedCount": base.terminal_executed_count,
                "implementationTerminalExecutedCount": implementation.terminal_executed_count,
                "baselineTerminalSkipCount": base.terminal_skip_count,
                "implementationTerminalSkipCount": implementation.terminal_skip_count,
                "baselineSkipMultiset": _serialized_multiset(base.skip_multiset),
                "implementationSkipMultiset": _serialized_multiset(
                    implementation.skip_multiset
                ),
                "newTestDecisions": [],
            }
        )
        report.update(compare_runs(base, implementation, policy))
        _write_report(arguments.report, report)
        return 0
    except (OSError, UnicodeError, ComparisonError) as error:
        if isinstance(error, ComparisonError):
            report.update(error.report_updates)
        report.update({"passed": False, "error": str(error)})
        if arguments.report is not None:
            try:
                _write_report(arguments.report, report)
            except OSError as report_error:
                print(
                    "project-storage skip comparison could not write "
                    f"report: {report_error}",
                    file=sys.stderr,
                )
        print(f"project-storage skip comparison failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

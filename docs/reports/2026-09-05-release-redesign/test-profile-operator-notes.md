# Canonical test profiles

`config/test-catalog.json` records primary logical collections, explicit SwiftPM targets, resource requirements, retained legacy selections and profile policy. `scripts/test.py list --profile NAME --json` describes selection without compiling. `scripts/test.py run --profile NAME` retains Swift and Python gate results. `scripts/full-suite-gate.sh --profile NAME --evidence-dir NEW_DIRECTORY` is the coordinator adapter and emits one Swift result; the coordinator separately runs its committed compact Python checks.

| Profile | Purpose |
|---|---|
| quick | Existing deterministic core and scientific-provenance sentinel selection; four XCTest workers |
| release | Same compact Swift sentinels, plus selected Python release-policy/evidence checks; build qualification, not full regression |
| headless | Broad Core/IO/Workflow/CLI regression after explicit tool, network, expensive and shared-state suite exclusions |
| extended | Headless plus expensive/shared-state scientific matrices and **every** Python test module, including exhaustive mocked release transactions |
| ui | All GUI-capable SwiftPM targets, including their mixed semantic suites; native XCUITest remains explicitly callable via `scripts/release/app-smoke-gate.sh` with its candidate/account options |
| tool-conformance | Real tools plus mixed integration diagnostics; missing prerequisites or skips fail |

Each case belongs to exactly one collection, though profiles intentionally overlap. Conservative whole-target UI classification preserves mixed suites without pretending that all state tests are currently independent of AppKit. Tool diagnostics also include mixed suites with opt-in live network, container and installed-environment cases that the old conformance regex omitted. Native XCUITest is never launched by quick, headless or release. Running the UI profile runs SwiftPM diagnostics; its listing also exposes the separate candidate-bound native XCUITest entry point.

`scripts/test.py audit` checks the source target inventory without a build and reports `discoveryAudited: false`. Pass `--inventory FILE` containing the combined XCTest/Swift Testing exact discovered IDs to audit full ownership, ambiguity, duplicates and empty required collections. Every fresh profile gate performs that full audit after harness discovery and before executing its selection. The validation report uses retained discovery, not a newly compiled test binary.

The broad headless/extended/UI profiles conservatively use one XCTest worker to preserve filesystem/defaults/process isolation while avoiding SwiftPM's oversized serial XCTest argv. They may be slow. Swift Testing keeps existing internal suite scheduling; no new global resource scheduler or latency claim is introduced. Discovery builds once sequentially; subsequent discovery and test commands use `--skip-build`. No independent simultaneous Swift builds are introduced.

The legacy smoke/unit/integration/conformance/full tier commands retain their exact selections and behavior. The catalog's legacy snapshots and behavioral tests guard compatibility; the legacy adapter's historical source-pinning tests remain retained diagnostics during migration.

A source result never independently authorizes publication. The coordinator binds fixed profile evidence and fresh actual-artifact checks to the candidate. Source evidence reuse is disabled because complete runtime, test-binary and environment binding has not been implemented. Failed primary exits, incomplete discovery/completion, duplicate XCTest terminal records and successful diagnostic retries cannot authorize a candidate.

Gate manifest schema 2 names dependency evidence honestly: `lock-manifest` records shipped tool/dependency pins, whereas `installed-receipt` records installed dependency verification. Their policies are not interchangeable. Historical schema 1 receipts remain valid only for the installed-receipt policy.

# Release pipeline benchmark: 2026.8.6 (preview) and 2026.8.7 (stable)

Measured 2026-08-21/22 on the release machine, executing the tier-aware release
skill end to end for both channels immediately after the test-suite
optimization campaign merged. All times wall-clock.

## Preview 2026.8.6

| Phase | Duration |
| --- | --- |
| Merge campaign branch to main + script tests + validator | 1.5 min |
| Version bump + release notes | ~4 min (incl. two false starts, below) |
| Gate: unit tier (parallel, ~12K tests) | 8.0 min (second run; first run 9.5 min caught a missed pbxproj version bump) |
| Gate: integration tier (serial) | 4.9 min |
| Gate: dependency verify tier 1 (seeded isolated root, 189 conformance tests + receipt) | 2.0 min |
| Tag + atomic push + push fast gate | ~4 min |
| Notarized DMG build + Sparkle publish (archive, sign, notarize, staple, DMG, appcast-beta + alpha bridge, prune) | 26.1 min |
| Artifact verification (release record, stapling, bundle identity, CLI, live feed) | ~3 min |
| **End to end (merge done to verified preview)** | **65.9 min** |
| **Clean-path estimate (no false starts)** | **~48 min** |

False starts, both caught by the pipeline's own gates: (1) release notes
rejected by the builder's audit-field validator (bullet-list fields and a
missing `## Dependency versions` section); (2) `MARKETING_VERSION` in
`project.pbxproj` missed by the initial bump, caught by
`ReleaseBuildConfigurationTests` in the unit tier.

## Stable 2026.8.7

| Phase | Duration |
| --- | --- |
| Version bump + aggregate notes | ~3 min |
| Gate: full tier (serial, 13,535 XCTest + 597 swift-testing) | 33.2 min (third run; two earlier green runs were failed by locked-session CoreData log noise, since excluded from the gate's error scan) |
| Gate: conformance `--require-tools` | 2.2 min |
| Gate: dependency verify tier 1 (seeded) | 1.8 min |
| XCUI | Removed from the stable gate mid-release by policy decision: 22/34 robots had drifted since the 2026-07-07 menu redesign, and macOS re-binds the automation permission to each rebuilt runner, which blocks unattended runs. XCUI is now an attended diagnostic (`run-macos-xcui.sh`, with `--smoke` for the 12-test core). |
| Overnight hold | ~7.9 h waiting on the (ultimately unnecessary) console unlock for XCUI |
| Tag + atomic push + push fast gate | ~4 min |
| Notarized DMG build + Sparkle publish (appcast-stable) | 25.6 min |
| Artifact verification | ~2 min |
| CI heavy board (release-event build-smoke + toolset-conformance) | recorded on completion in the release evidence |
| **Active work end to end (excluding the overnight hold)** | **~72 min + CI board** |

## Reusable numbers for planning

- A preview release costs about **45-50 minutes** of pipeline time on this machine.
- A stable release costs about **70-75 minutes** plus the CI heavy board (
  historically 60-100 min, hands-off).
- The notarized build step is remarkably stable: 26.1 min (preview) vs
  25.6 min (stable); Apple's notarization queue was fast both times.
- The seeded dependency verify (`verify.sh --tier 1 --seed-from ~/.lungfish`)
  runs in about 2 minutes; never run it unseeded during a release (30-60 min).

## Machine-state findings folded back into the pipeline

1. Locked-session `CoreData: error:` log noise fails the gate's error scan;
   now excluded (the suite uses no CoreData; real failures always emit test
   failure lines).
2. `fseventsd` churn storms after heavy `.build` activity fail 1-2 arbitrary
   timing-bounded tests per full run; the gate's isolated serial retry (with a
   30 s settle) adjudicates these honestly.
3. macOS TCC automation grants bind to the specific `XCUITests-Runner` binary;
   every rebuild may re-prompt. This is inherent, and the reason XCUI cannot
   gate unattended releases.

## Postscript (same morning)

The XCUI diagnostic tier was subsequently repaired end to end and certified
fully green attended: 33 tests, 0 failures, 12.0 min (19 menu-model repairs,
one deprecated-feature test removed, CLI-path injection into the xctestrun,
one selection-scope fix). It remains an attended diagnostic, not a gate.

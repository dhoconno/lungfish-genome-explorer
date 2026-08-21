# Fast Iteration Workflow

**Date:** 2026-05-31
**Status:** Tooling landed; practice guide

This is the day-to-day build/test loop for Lungfish Genome Explorer, designed around
the measured reality that incremental builds are fast (~11s) but the full suite is slow
(~8 min) and a fresh-worktree cold build is the biggest avoidable cost. See
`docs/reports/2026-05-31-build-and-test-iteration-speed-analysis.md` for the analysis.

## Inner loop (seconds — do this constantly)

Work in the warm main checkout, not a fresh worktree (a fresh worktree pays a full cold
build before any edit). Build the target you touched and run only the affected tests:

```bash
swift build --target LungfishApp --skip-update      # ~11s for a leaf change
scripts/test-surface.sh mhc                          # run only Genotype/MHC/Haplotype tests
scripts/test-surface.sh 12s                          # 12S surface
scripts/test-surface.sh "ProjectDeletionPlanner"     # any name regex
```

`scripts/test-surface.sh` maps a few shortcuts (`vcf`, `12s`, `mhc`, `sidebar`, `import`)
to name filters and otherwise passes a regex straight to `swift test --filter`. This
scopes the *run*; it still compiles the test target the matched tests live in.

## Pre-push gate (the full suite, off the critical path)

Run the full suite locally on this machine before pushing — it is the regression gate.
GitHub-hosted macOS runners are Intel/older-macOS and cannot build this arm64-only app;
paid Apple-Silicon runners are slower than a local M-series Mac and usage-limited, so the
gate runs here.

```bash
scripts/full-suite-gate.sh           # run now, prints GATE PASS / GATE FAIL
scripts/full-suite-gate.sh --bg      # run in background; result lands in .build/gate-logs/
```

To enforce it automatically on every push (bypass with `git push --no-verify`):

```bash
scripts/install-git-hooks.sh         # installs a pre-push hook running the gate
scripts/install-git-hooks.sh --uninstall
```

## Worktrees: only when you need them

Reserve `git worktree add` for genuinely parallel work (multiple agents/branches at
once) or risky refactors you want isolated. Each new worktree starts with a cold
`.build`. For ordinary sequential features, the warm main checkout is faster.

## Test tags (swift-testing only; metadata today)

`Tests/LungfishWorkflowTests/TestTags.swift` defines surface tags (`.vcf`, `.twelveS`,
`.mhc`, `.sidebar`, `.releaseConfig`). Add `.tags(.<surface>)` to a swift-testing `@Test`
or `@Suite` when you touch one. NOTE: the current SwiftPM `swift test` filters only by
name (`--filter`), not by tag, so tags are useful in Xcode's test UI and as future-proof
metadata, but CLI scoping is name-based. Tags must be defined per test target that uses
them (they are module-scoped); the file in `LungfishWorkflowTests` is the template.

## Why this is fast enough

The compiler is not the bottleneck for routine edits (~11s incremental). The slow parts
are the full suite and cold builds. Keeping the inner loop name-scoped and the full suite
to a background/pre-push gate, while working in a warm checkout, recovers the iteration
time. The durable structural win (smaller per-feature modules and test targets, which
scope the *build* per surface) is tracked separately under the modularization effort.

## Tier update (2026-08-21)

The gate now has named tiers (`scripts/full-suite-gate.sh --tier <name>`); see the
script header for definitions. Measured on this machine at commit e87fd86c:

- `--tier unit` (parallel per-class, implied automatically): **379-459 s** wall-clock
  for ~12K tests across four consecutive runs. This is the pre-push hook default.
- `--tier smoke`: seconds of test time once the build is warm.
- `--tier integration` / `--tier conformance`: serial; see the dependency-sweep doc
  for conformance timing (30-60 min with provisioning).
- `--tier full`: the entire suite, serial - the stable-release gate.

Notes: serial runs of large `--skip`/`--filter` selections are impossible (SwiftPM
expands the selection past ARG_MAX), so the unit tier always runs `--parallel`.
Load-sensitive classes that fail only under parallel are either quarantined into the
serial integration tier (`PARALLEL_HAZARD_SUITES` in the gate) or, for the
nondeterministic tail, rerun serially once by the gate's flake-retry pass - a PASS
that needed the retry names the retried classes in its verdict line. Parallel runs
also write per-test timing to `.build/gate-logs/*.xunit*.xml`.

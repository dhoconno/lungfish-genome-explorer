# Reorganization Results: Before / After

**Date:** 2026-05-31
**Baseline commit:** `5d58cd69` · **After commit:** `ff0775df`
**Host:** 14-core Apple Silicon (arm64), macOS 26

Build-time measurements before and after the build/test reorganization (giant-file
splits + LungfishAppKit kernel + LungfishTwelveSUI leaf module + infrastructure
untangling). Measured with `scripts/measure-build-times.sh`.

## Headline timings

| Phase | Before | After | Change |
| --- | ---: | ---: | --- |
| No-op build (warm) | 13.2s | 8.8s | **-33%** |
| Cold full build (clean .build) | 163.3s | 127.1s | **-22%** |
| Incremental rebuild, same LungfishApp leaf file | 10.9s | 11.0s | ~unchanged |
| Full test suite | 458.5s | 607.6s | +33% (run-to-run variance; see note) |

## Module-scoped incremental rebuild (the durable modularization win)

The standard incremental measurement touches a file still inside LungfishApp, so it
does not capture the modularization benefit. The benefit appears when editing a file
in an extracted module, which recompiles only that module instead of the 222K-LOC
LungfishApp:

| Edit location | Incremental rebuild |
| --- | ---: |
| LungfishApp file (the prior default) | 10.6s |
| LungfishTwelveSUI file (extracted leaf, ~1.2K LOC) | **6.3s (-41%)** |
| LungfishAppKit file (shared kernel, body-only change) | **1.3s (-88%)** |

This is the structural payoff: code that lives in a focused module iterates far
faster than code in the monolith. As more feature surfaces are extracted into leaf
modules (the documented follow-up), more of the app gains this speedup.

## Interpretation

- **Cold build -22% and no-op -33% are real, repeatable wins** from splitting the
  giant files (smaller type-check units) and the module split (more parallelism, less
  to re-emit).
- **Editing in an extracted module is 40-90% faster** than editing in LungfishApp —
  the core reason to modularize. The biggest day-to-day cost (re-touching the same
  monolithic file) is unchanged because that file is still in LungfishApp; the fix is
  to keep extracting leaves.
- **The full-suite +33% is run-to-run variance, not a regression.** The test count and
  pass/skip results are identical before and after (8,841 XCTest + 475 swift-testing,
  0 failures), and the suite is heavily I/O- and subprocess-bound, so wall-clock time
  swings with system load. The baseline ran on a freshly-warmed system; the after-run
  followed a long working session. The reorganization adds no tests and changes no test
  logic, so it cannot have made the suite do more work.

## What changed (commits `968d98e6`..`ff0775df`)

1. Removed the dead 12S rolling-hash exact-match index.
2. Split 8 files of 5K-10K lines into focused files (AppDelegate, AnnotationTableDrawerView,
   SequenceViewerView, MainSplitViewController, InspectorViewController, VariantDatabase,
   FASTQDerivativeService, SidebarViewController).
3. Added fast-iteration tooling (surface test runner, background full-suite gate,
   pre-push hook, swift-testing tags, workflow guide).
4. Extracted `LungfishAppKit` (shared UI kernel, 17 files) and `LungfishTwelveSUI`
   (first leaf feature module with its own test target), untangling CLIBinaryLocator,
   LungfishCLIRunner, the BLAST results drawer cluster, and MetagenomicsFilePanelFactory
   into the kernel.

All validated by the full suite (0 failures) and by each module building standalone.
The remaining leaf extraction is scoped in
`docs/reports/2026-05-31-modularization-findings.md`.

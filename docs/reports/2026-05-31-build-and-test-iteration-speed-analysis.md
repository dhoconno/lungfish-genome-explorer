# Build and Test Iteration Speed Analysis

**Date:** 2026-05-31
**Status:** Analysis + recommendations (no implementation yet)
**Question:** Each small feature is taking hours, largely due to long build and test
times. Is there a better way to organize builds and testing for a faster iteration
cycle, or are the long times an inevitable consequence of LGE's complexity?

## TL;DR

The long cycles are **mostly workflow, not the compiler**. Incremental builds are
fast (~11s for a leaf-file change). The hours came from two self-inflicted
multipliers: (1) creating a fresh git worktree per feature, which forces a full
~630s cold build every time, and (2) running the full ~9,300-test suite (across two
test harnesses) as a manual, foreground pre-merge gate, repeatedly. Some cost is
inherent to a ~450K-LOC native macOS app, but a large fraction is avoidable through
process changes (immediate) and structural changes (durable).

## Measured facts (this machine, this date)

| Measurement | Time | Notes |
| --- | ---: | --- |
| One-file incremental rebuild (leaf service file) | ~11s | The compiler is not the bottleneck for routine edits |
| No-op build (nothing changed) | ~22s | SwiftPM re-validating the manifest + dependency graph |
| Cold full build (fresh worktree, empty `.build`) | ~630s | Dominated by LungfishApp + the Containerization dependency |
| Full test suite | ~5 min per harness, run twice | ~9,300 tests; XCTest and swift-testing run as separate passes |
| `.build` cache size (warm) | ~21 GB | Per checkout; a fresh worktree starts with none of this |

### Codebase size (Swift LOC per module)

| Module | Lines | Files | Role |
| --- | ---: | ---: | --- |
| LungfishCore | 26,846 | 70 | Foundation types |
| LungfishIO | 61,683 | 122 | Bundles, file formats |
| LungfishWorkflow | 104,011 | 244 | Pipelines (pulls in Containerization) |
| **LungfishApp** | **222,367** | **436** | **The app: half the codebase, depends on all others** |
| LungfishCLI | 41,895 | - | CLI |

### Test distribution (lopsided)

| Test target | ~Test fns | Test LOC |
| --- | ---: | ---: |
| LungfishCoreTests | 1,236 | 18,665 |
| LungfishIOTests | 2,087 | 36,809 |
| LungfishWorkflowTests | 1,644 | 46,251 |
| **LungfishAppTests** | **3,278** | **81,320** |
| LungfishAppWorkflowTests | 58 | 2,381 |
| LungfishCLITests | 811 | 23,041 |
| LungfishIntegrationTests | 241 | 8,787 |

### Largest single source files (compile bottlenecks)

Swift type-checks a file as a unit, so very large files slow the build and serialize
it. The biggest offenders:

| File | Lines |
| --- | ---: |
| `Sources/LungfishApp/App/AppDelegate.swift` | 10,063 |
| `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift` | 8,785 |
| `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift` | 8,450 |
| `Sources/LungfishApp/Services/FASTQDerivativeService.swift` | 6,403 |
| `Sources/LungfishIO/Bundles/VariantDatabase.swift` | 6,007 |
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | 5,879 |
| `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` | 5,212 |

## Diagnosis: where the hours actually went

1. **Fresh worktree per feature -> cold ~630s build every time.** Isolating each
   feature in a new `git worktree add` is great for safety and parallelism, but each
   new worktree has an empty `.build` and must do a full cold compile before any edit.
   Doing this ~6 times in a day is roughly an hour of pure cold-compile.
2. **Full-suite gate run manually and serially, ~6 times.** ~9,300 tests across two
   harnesses at ~5 min each is another hour-plus. It did catch real regressions (stale
   tests that asserted an old build mechanism), so it has genuine value, but running
   *all* of it for a 4-file change is overkill, and running it in the foreground blocks
   work.
3. **Editing a high-fan-in file** (AppDelegate, MainSplitViewController) recompiles a
   large slice of LungfishApp, but a leaf file is cheap (~11s). The 222K-LOC monolithic
   app module means many UI changes touch the slow path.

## What expert Swift / large-app teams do (and how it maps to LGE)

### Workflow: fast inner loop, slow outer loop
No serious team runs the full suite on every edit. The standard is a test pyramid plus
offloaded full runs:

- **Inner loop (seconds):** edit -> build the one target -> run only the directly
  affected tests. Available at LGE today (11s incremental + `swift test --filter`); the
  gap was not defaulting to it.
- **Pre-merge gate:** run the full suite automatically and in parallel, off the
  developer's critical path. Standard teams put this on CI. See the CI caveat below.
- **Worktrees** are for parallelism, not the default. A warm, reused checkout is the
  norm; a cold worktree per task is not how teams work.

### The CI caveat for an Apple-Silicon-only macOS app
The textbook advice ("add GitHub Actions") does not cleanly fit LGE:

- GitHub's **free** macOS runners are Intel x86_64, 3-4 cores, on older macOS. LGE is
  **arm64-only** (Containerization, macOS 26), so the free runners **cannot build it**,
  and would be ~2-4x slower than the local M4 even if they could.
- **Apple Silicon** hosted runners exist but are **paid**, and macOS minutes bill at
  ~10x the Linux rate, so the free monthly allotment is roughly a handful of full runs
  before incurring cost or hitting caps.

For a solo developer with a fast local Apple Silicon Mac, the value of "CI" is
**automation + parallelism**, not the cloud. The right shape is to run the full suite
**in the background on the local M4** (a script and/or a git pre-push hook), which keeps
the gate without cloud cost or arch problems. A **self-hosted GitHub Actions runner on
the developer's Mac** is the option if GitHub PR integration/visibility is wanted; it
runs on local hardware at full speed with no per-minute billing.

### Structure: small modules are the #1 build-time lever
The most-documented finding in large-Swift-app engineering: incremental build time is
dominated by the size of the module you are forced to recompile. LungfishApp at 222K LOC
in one module means every UI change recompiles all of it. Teams keep feature modules in
the ~5-30K LOC range. The consensus migration is **incremental, leaf-first extraction**,
never a big-bang rewrite: pull out leaf feature modules (e.g. an MHC/genotype module, a
viewer module, an inspector module) that the thin `Lungfish` executable composes. This
also gives each feature its **own test target**, which is the only thing that scopes the
*build* (not just the run) per surface.

## Test scoping: can we avoid running (e.g.) VCF tests when not touching VCF?

Yes. Two complementary mechanisms.

### Mechanism 1: Filtering (works today, no refactor)
`swift test --filter <regex>` selects tests by suite/class or test name:
- `swift test --filter VCF` runs only suites/tests with "VCF" in the name.
- `swift test --filter "TwelveS|Hilo"` runs the 12S suites.

Limits:
- Works only as well as the **naming** is consistent; a surface like VCF can be scattered
  across LungfishIOTests (parsing), LungfishAppTests (import UI), and LungfishWorkflowTests.
  Name-filtering misses tests that lack the keyword.
- It saves **run** time, not **build** time: filtering to 20 VCF tests inside
  LungfishAppTests still compiles all of LungfishAppTests (81K LOC) + LungfishApp.

### Mechanism 2: Tagging + per-module test targets (the durable fix)
- **swift-testing `@Tag`**: tag tests semantically and run by tag, regardless of file or
  target. Solves the "scattered across surfaces" problem name-filtering cannot. Adoptable
  incrementally as tests are touched.

  ```swift
  extension Tag { @Tag static var vcf: Self; @Tag static var twelveS: Self }
  @Test(.tags(.vcf)) func parsesVCF4() { ... }
  ```

- **Per-feature test targets** (a consequence of modularization): a change to the MHC
  module compiles and tests only that module's test target, not the 81K-LOC LungfishAppTests
  monolith. This is the only approach that scopes the *build* per surface.

The test-speed problem and the modularization problem are therefore the same problem:
you cannot fully scope tests by surface without splitting LungfishApp, because today
everything UI-related is welded into one large test target that must compile as a unit.

## Recommended program (sequenced)

Ordered so earlier steps unblock or de-risk later ones.

1. **Fast inner loop now.** Default to the warm main checkout (11s edits) and
   `--filter`-scoped tests; reserve worktrees for genuinely parallel or risky work.
   Behavioral change, zero risk, immediate.
2. **Dead / deprecated code and test pass.** Do this early: it shrinks everything
   downstream (less to compile, less to test) and clarifies boundaries for modularization.
3. **Split the giant files** (AppDelegate.swift, MainSplitViewController.swift,
   SequenceViewerView.swift, etc.) into focused files. Cheap, mechanical, a real
   incremental-build win, and a natural precursor to module extraction.
4. **Local background full-suite gate** on the M4 (script + optional pre-push hook).
   Keeps full-suite protection off the critical path, no cloud cost. Optionally a
   self-hosted GitHub Actions runner if PR integration is wanted.
5. **Add `@Tag` groups** for cross-cutting surfaces (VCF, 12S, MHC, ...). Enables scoped
   *runs* across targets even before modularization.
6. **Brainstorm and execute leaf-first modularization** of LungfishApp into feature
   modules. The durable fix that finally scopes *builds* and yields per-feature test
   targets. Substantial, multi-session; design first.

## Honest bottom line

LGE's build times are partly inherent to a ~450K-LOC Apple-Silicon-only macOS app, but
the hours-per-feature were mostly avoidable workflow: cold worktrees plus full-suite
foreground gating on a fast local machine. The immediate process changes recover most of
the lost time at zero risk; splitting the giant files is a cheap structural win; and a
leaf-first modularization of LungfishApp is the durable fix that shrinks both build and
test time and makes per-surface test scoping possible.

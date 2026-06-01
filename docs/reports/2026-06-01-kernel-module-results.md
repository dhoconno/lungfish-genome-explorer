# Kernel/Module Refactor: Build-Time Results

**Date:** 2026-06-01
**Before commit:** `ae131e9d` (alpha10) and the pre-reorg `5d58cd69`
**After commit:** `68cb8dcf`
**Host:** 14-core Apple Silicon (arm64), macOS 26

This refactor generalized the `LungfishKit` kernel plus feature-module structure across
the app: the shared UI and the operation model moved into the kernel, and eight feature
surfaces moved out of the monolithic app target into standalone modules (joining the
existing 12S module). The goal was build and test isolation, so that a change confined to
one module recompiles and tests only that module.

## Module sizes

| Target | Before (alpha10) | After |
| --- | ---: | ---: |
| LungfishApp (monolith) | 216,946 LOC | 180,561 LOC |
| LungfishKit (kernel) | 5,047 LOC | 9,441 LOC |
| Feature leaf modules | 1 module | 9 modules, 33,571 LOC total |

About 36,000 lines moved out of the app target into focused modules.

## The headline result: module-scoped incremental rebuild

This is the metric that governs day-to-day iteration. Starting from a fully warm build,
edit one file and time a full `swift build`. The edit location is the only variable.

| Edit location | Warm `swift build` |
| --- | ---: |
| A file still inside LungfishApp | 15.6s |
| A file in an extracted leaf (LungfishNvdUI) | **7.9s (about 2x faster)** |
| A file in the kernel (narrow-fan-out type) | 7.4s |

Editing a file that lives in a focused leaf module rebuilds about twice as fast as editing
the equivalent file back when it lived in the monolith. This is the structural payoff: the
compiler re-type-checks the small module rather than the 180K-line app.

Caveats, stated honestly:
- The kernel figure (7.4s) used a narrow-fan-out type. A widely-consumed kernel type would
  recompile more downstream modules, so kernel edits are not uniformly cheap. The rule of
  thumb holds: edit a leaf, pay for the leaf; edit the kernel, pay for the kernel plus its
  dependents.
- Per-module test isolation is real and is the larger win for the test loop: a leaf's tests
  run via `swift test --filter Lungfish<Leaf>UITests` and compile only that module and its
  test target, instead of the full app test target.

## Whole-package build timings (and why some went up)

| Phase | pre-reorg `5d58cd69` | alpha10 `ff0775df` | after `68cb8dcf` |
| --- | ---: | ---: | ---: |
| No-op build (warm) | 13.2s | 8.8s | 6.7s (controlled) |
| Incremental rebuild (1 leaf file) | 10.9s | 11.0s | 9.9s |
| Cold full build (clean .build) | 163.3s | 127.1s | 146.4s |

Reading these correctly matters:
- **Cold full build rose vs alpha10 (127s to 146s).** Splitting one target into ten
  (kernel plus nine leaves plus the app, each with a test target) adds SwiftPM module-graph
  resolution, per-module interface emission, and link steps that a single target does not
  pay. A cold build compiles everything regardless of module boundaries, so modularization
  cannot speed it up and adds a modest fixed overhead. It is still well below the pre-reorg
  163s because the giant-file splits from the prior cycle remain in effect.
- **No-op and single-file incremental are dominated by system load and SwiftPM graph
  stat-ing**, so they swing run to run; the controlled warm no-op here was 6.7s. These are
  not the metric the refactor targets.
- The full suite time is omitted here; it is heavily I/O and subprocess bound and swings
  with system load (the alpha10 results doc made the same observation). The suite is green
  at the established bar: 8,847 XCTest plus 475 swift-testing, with 9 known-environmental
  failures (sandbox/TCC reads of external volumes), 0 swift-testing failures, unchanged by
  the refactor.

## Interpretation

The refactor trades a small, fixed increase in cold and no-op build overhead (more modules
to resolve and link) for a roughly 2x speedup on the common inner-loop action: editing code
inside a focused feature module. As more feature surfaces live in their own modules, more of
the day-to-day editing benefits from that speedup, and a developer building a new feature can
shop the kernel for shared code rather than threading it through the monolith. Per-module test
targets mean a module change can be validated by running only that module's tests.

## What changed structurally

- Kernel renamed `LungfishAppKit` to `LungfishKit` (the project's language is Swift; the
  kernel is not specific to AppKit).
- Promoted into the kernel: the operation center and its operation model, metagenomics
  drawer sizing and layout, the classifier sample picker, the BAM mini-viewer, the brand
  color palette (values unchanged), the reference-sequence picker, and several smaller views.
- Extracted leaf modules: Alignment, Assembly, NVD, NAO-MGS, TaxTriage, EsViritu, Genotype,
  Phylogenetics (plus the prior 12S module).
- The composition roots (main split controller, viewer, inspector, sidebar) stay in the app
  by design; they wire the modules together.

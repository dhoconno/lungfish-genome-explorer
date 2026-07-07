# Weekly GitHub Issues (2026-06-29 → 2026-07-05) — Master Specification

**Status:** Ready for implementation
**Author:** Fable (planning session 2026-07-06)
**Scope:** All 8 open GitHub issues created in the last week (#20–#27) in `dhoconno/lungfish-genome-explorer`.
**Audience:** An implementing LLM (or engineer) with strong general skills but **zero prior context** on this codebase.

---

## 0. How to use this document set

This is the **index and shared context** for eight issues. Each issue has its own standalone plan file under `docs/superpowers/plans/`. Read this master spec first, then execute the per-issue plans in the recommended order below.

| # | Title | Type | Plan file | Complexity |
|---|-------|------|-----------|------------|
| 20 | EsViritu empty results report as failures | Bug | `2026-07-06-issue-20-esviritu-empty-results.md` | S |
| 21 | Can't run classification on a folder of files | Bug | `2026-07-06-issue-21-folder-classification.md` | M |
| 22 | TaxTriage no miniBAMs on downsampled reads | Bug | `2026-07-06-issue-22-downsampled-minibam.md` | M (diagnosis-first) |
| 23 | Human read removal working in VSP2? | Bug | `2026-07-06-issue-23-vsp2-human-scrub.md` | M (diagnosis-first) |
| 24 | VSP2 provenance: dedup read-removal stats | Feature | `2026-07-06-issue-24-vsp2-dedup-stats.md` | S |
| 25 | Create NCBI GenBank submissions from bundles | Feature | `2026-07-06-issue-25-genbank-submission.md` | L |
| 26 | Revise Tools menu | Feature | `2026-07-06-issue-26-tools-menu-revision.md` | L |
| 27 | Add Trim Galore --clumpify support | Feature | `2026-07-06-issue-27-trim-galore-clumpify.md` | M |

**Recommended execution order** (dependency- and risk-aware):

1. **#20** (isolated parser fix, warm-up) →
2. **#24** (small, self-contained provenance surface; establishes read-count plumbing knowledge reused by #23) →
3. **#23** (diagnosis-first; reuses #24's read-count surface to expose scrub effectiveness) →
4. **#22** (diagnosis-first; independent) →
5. **#21** (folder fan-out; touches classification entry points) →
6. **#27** (Trim Galore; touches import pipeline + tool registry) →
7. **#26** (Tools menu; large UI restructure; do after #21/#27 so menu wiring is stable) →
8. **#25** (GenBank; largest, most independent; can be done any time but is the biggest single deliverable).

Issues #23 and #22 are **diagnosis-first**: their plans begin with a verification task to confirm the root cause before changing code, because the symptom (2–5% human reads; missing miniBAMs) has more than one plausible cause. Do not skip the diagnosis task.

---

## 1. Codebase orientation (shared by all plans)

Read this once. It is the minimum context to execute any plan below.

### 1.1 What the app is

Lungfish Genome Explorer (LGE) is a **Swift 6.2 macOS app** (target macOS 26 Tahoe, Apple Silicon), built with **SwiftPM** (not Xcode project files for the build). It uses `@Observable` + `@MainActor` + strict Swift concurrency throughout. It is a bioinformatics workbench: import sequencing reads (FASTQ), run classifiers/assemblers/aligners, view results.

### 1.2 Module layering (bottom → top)

```
LungfishCore  →  LungfishIO  →  LungfishWorkflow  →  LungfishKit (shared UI/infra kernel)
   →  9 feature "leaf" UI modules  →  LungfishApp (composition roots)  →  LungfishCLI / Lungfish (executables)
```

**Hard layering rule:** a leaf module or the kernel (`LungfishKit`) may **NEVER** reference a type defined in `LungfishApp` — that is a forbidden dependency cycle. `LungfishApp` imports leaves (App → leaf is fine). `LungfishCLI` does **not** import `LungfishKit`.

Key module contents you will touch:

- **`LungfishCore`** — pure data models: `Sequence`, `SequenceAnnotation`, `GenomicDocument`, `SampleMetadataStore`. No UI, no I/O side effects.
- **`LungfishIO`** — file formats and parsers/writers: FASTQ bundles, GenBank reader/writer, GFF3, Kraken reports, EsViritu detection parser, NCBI BioSample exporter.
- **`LungfishWorkflow`** — pipelines and external-tool orchestration: classification pipelines (Kraken2, EsViritu, TaxTriage), FASTQ ingestion, recipe engine, the conda/micromamba tool manager (`CondaManager`), `NativeToolRunner`.
- **`LungfishKit`** — shared UI + **`OperationCenter`** (the operation/progress ledger). Note: it is `OperationCenter.shared` here, defined in `LungfishKit`. (One research pass reported "no OperationCenter"; that pass grepped the wrong module — it exists and is the required mechanism for every operation.)
- **`LungfishApp`** — the composition roots: `AppDelegate` (+ many `AppDelegate+*.swift` extensions), `MainMenu.swift`, sidebar, inspector, viewer, dialogs.

### 1.3 Build & test invocation (READ THIS — non-obvious)

- **`swift` has NO `-C` flag** (that is `git`). To build/test the worktree without `cd`, use:
  - `swift build --package-path <dir> --skip-update`
  - `swift test --package-path <dir> --skip-update`
- Always pass **`--skip-update`** to stay offline (avoids an NCBI network flake in `testSRASearch`).
- **SwiftPM holds a single `.build/.lock` per checkout.** Two concurrent `swift build`/`swift test` on the same checkout block each other and the waiter can be killed (exit 144, empty output). **Serialize all swift invocations.** Never run a second `swift test` while one is running. If a build seems to "hang," check `ps` for a foreign `swift-test`/`swift-build` process and the `.build/.lock` before assuming it is a test failure.
- To run a single test: `swift test --package-path <dir> --skip-update --filter <TestClass>/<testMethod>`.

### 1.4 The known-green test baseline

The full suite is ~8,847 XCTest + 475 swift-testing tests. A run is **GREEN** iff:

- XCTest failures are a **subset of these 9 known-environmental failures**, AND
- swift-testing failures = 0.

The 9 known-environmental failures (all macOS TCC `Operation not permitted` on external volumes/paths — NOT regressions):

- 6 × `GenotypeRealBundleSmokeTests` (in `LungfishGenotypeUITests`)
- 2 × `ZhangArtifactCanaryTests` (read `/Volumes/iWES_WNPRC/...`)
- 1 × `VCFRobustnessTests.testAllRealVCFsFromDownloads` (reads `~/Downloads/vcfs`)

Additional environment-specific skips that may appear from a worktree/fresh clone (also not regressions): `GenBankReaderTests.testReadKF015279` (needs a local `test-data/KF015279.gb` not in the repo), and `DatabaseServiceIntegrationTests.testSRASearch` (NCBI network flake).

When a plan says "run the suite and confirm green," it means: failures ⊆ the set above.

### 1.5 Binding process rules (from project memory — these OVERRIDE default behavior)

- **Plan-first, phased, TDD.** Every plan here uses test-driven steps: write the failing test, watch it fail, implement minimally, watch it pass, commit.
- **CLI parity.** Every user-facing operation must be reachable from `LungfishCLI` (an `AsyncParsableCommand` subcommand), not just the GUI. If a plan adds a GUI operation, it must add or extend the matching CLI command.
- **OperationCenter for every op.** Long-running operations must call **both** `OperationCenter.shared.update(...)` **and** `OperationCenter.shared.log(...)` (without `.log()`, only materialization steps persist in the expanded operation row's history). Completion/failure via `OperationCenter.shared.complete(...)` / `.fail(...)`.
- **GUI testing means Computer Use.** A code audit does not count as GUI verification. Any plan step that says "verify in the GUI" must be executed by launching the app and interacting with it (via the computer-use MCP), not by reading code. Building the debug app: `swift build --package-path <dir> --skip-update` then launch `.build/debug/Lungfish`.
- **Docs prose rules** (only if you touch `docs/user-manual/**` or `.claude/agents/*`): no em dashes; bullet caps 5 items / 2 levels. Plans and specs (this file) are exempt.
- **Accent color:** Lungfish Orange `#D47B3A` (dark mode `#E8A06A`). Classification tool colors: Kraken2 = blue, EsViritu = green, TaxTriage = purple, NAO-MGS = amber.

### 1.6 Concurrency gotchas (will bite you if ignored)

- **Background → MainActor dispatch:** NEVER `Task { @MainActor in }` from a GCD background queue; NEVER a bare `DispatchQueue.main.async` to touch `@MainActor` state; NEVER `await` a `@MainActor` member from `Task.detached`. For UI callbacks from background work use:
  ```swift
  DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { /* touch @MainActor state here */ }
  }
  ```
  For long-running pipelines, drop `@MainActor`, mark the type `@unchecked Sendable`, and use actors.
- `String(format:)` with a Swift `String` and `%s` **crashes (SIGSEGV)** — always use `%@` or interpolation.
- In `@Sendable` closures, prefer free functions over instance methods to avoid `self` isolation capture.

### 1.7 Virtual FASTQ bundles (shared by #21 and #22)

This is load-bearing for classification correctness:

- **Virtual bundles** (subset/downsample, trim, demux) store only a small `preview.fastq` (~1000 reads) plus a read-ID list or trim manifest on disk — **not** the full FASTQ.
- `FASTQBundle.resolvePrimaryFASTQURL(...)` returns the **preview** for a virtual bundle. **Never pass that to a classifier** — you would classify ~1000 reads, not the real dataset.
- The full FASTQ is reconstructed on demand by **materialization**: the app-side path is `FASTQDerivativeService.shared.materializeDatasetFASTQ(fromBundle:tempDirectory:progress:)`, driven through `resolveInputFiles(...)` / `FASTQSourceResolver`. This runs as the first pipeline step **after** a dialog closes, not before display.
- Config structs (`TaxTriageConfig.samples[i].fastq1/.fastq2`, `ClassificationConfig.inputFiles`, etc.) have **mutable** input-file fields precisely so the materialized paths can be substituted in before the tool runs. Clean up materialized temp dirs with `defer { try? FileManager.default.removeItem(at: tempDir) }`.

### 1.8 Commit conventions

- Work on the branch this worktree already created: `worktree-weekly-issues-plans` is the *planning* branch. **Implementation should happen on per-issue branches** (or the executor's chosen integration branch) — see each plan's finish step. Do not implement on the planning branch unless the user directs otherwise.
- Conventional-commit prefixes used in this repo: `fix:`, `feat:`, `docs:`, `refactor:`, `test:`.
- Commit messages end with the co-author trailer:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  ```

---

## 2. Cross-cutting risks & decisions

These apply across multiple issues; each plan references them.

### 2.1 There are TWO recipe representations — confirm which VSP2 uses (blocks #23, #24, #27)

Research surfaced a **conflict** that the implementer MUST resolve before touching VSP2:

- **Representation A (Swift `ProcessingRecipe`):** `Sources/LungfishIO/Formats/FASTQ/ProcessingRecipe.swift:315` defines `Illumina VSP2 Target Enrichment` as an ordered list of `FASTQDerivativeOperation` steps: **clumpify dedup → fastp adapter trim → fastp quality trim → deacon human scrub → bbmerge → bbduk length filter.**
- **Representation B (declarative JSON v2 `Recipe`):** `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json` defines `VSP2 Target Enrichment` as: **fastp-dedup → fastp-trim → deacon-scrub → fastp-merge → seqkit-length-filter** (no clumpify inside; clumpify runs as a separate post-recipe compression step in `FASTQBatchImporter`).

These disagree on (a) the dedup tool (clumpify vs fastp-dedup) and (b) whether clumpify is part of the recipe. **Before implementing #23, #24, or #27**, do the shared **VSP2 Recipe Reconciliation** task (defined in the #24 plan, Task 0) to determine which representation the *shipping* VSP2 import path actually executes at runtime — by reading `FASTQBatchImporter` and `RecipeRegistry`, and by running an actual VSP2 import against a fixture and inspecting the persisted `recipeApplied` provenance. All three VSP2-adjacent plans consume that finding.

### 2.2 Downsampled/virtual bundles vs classifiers (blocks #21, #22)

Both #21 (folder classification) and #22 (downsampled miniBAMs) live in the classification-input path. #22's plan begins by determining whether the failure is (a) preview.fastq leaking into TaxTriage (materialization not happening) or (b) TaxTriage genuinely producing BAMs that the output collector never harvests (`TaxTriagePipeline.collectOutputFiles` has no `.bam` branch). Do #22's diagnosis task before writing code.

### 2.3 EsViritu empty-vs-error also affects Kraken2 (informs #20)

The same "empty results file → parser throws → treated as failure" bug pattern exists in `KreportParser` (Kraken2) at `Sources/LungfishIO/Formats/Kraken/KreportParser.swift:149`. #20's plan fixes EsViritu and adds an **optional** follow-on task to apply the identical fix to Kraken2, so an empty-but-successful Kraken2 run does not report as failure either.

### 2.4 Menu wiring stability (informs #26 ordering)

#26 restructures the Tools menu, which is built programmatically in `Sources/LungfishApp/App/MainMenu.swift` and validated in `AppDelegate.swift`. #21 and #27 both add/adjust classification and import entry points. Doing #26 last avoids reworking menu structure that #21/#27 just modified.

---

## 3. Definition of done (applies to every issue)

An issue's plan is complete when ALL of the following hold:

1. Every task's tests are written first, fail as expected, then pass.
2. `swift build --package-path <dir> --skip-update` succeeds with no new warnings introduced by your change.
3. `swift test --package-path <dir> --skip-update` is **GREEN** per §1.4 (failures ⊆ the known-environmental set; swift-testing = 0).
4. CLI parity is satisfied where the issue adds/changes a user operation (§1.5).
5. Every new/changed long-running operation calls `OperationCenter.shared.update` **and** `.log`, and terminates with `.complete` or `.fail` (§1.5).
6. For GUI-visible changes, the change was verified by launching `.build/debug/Lungfish` and interacting with it via computer-use (§1.5), not by code audit alone.
7. Work is committed in small conventional commits with the co-author trailer (§1.8).
8. The issue's acceptance criteria (stated at the top of each plan) are demonstrably met.

---

## 4. Fixtures & test data (shared)

- Shared SARS-CoV-2 dataset: `Tests/Fixtures/sarscov2/` (reference MT192765.1, ~85 KB). Type-safe accessors in `Tests/LungfishIntegrationTests/TestFixtures.swift`. Formats: FASTA+FAI, paired FASTQ.GZ, sorted BAM+BAI, VCF(+GZ+TBI), BED, GFF3, GTF.
- EsViritu batch fixtures: `Tests/Fixtures/analyses/esviritu-batch-*/` (includes a `virusCount: 0` sample — reuse for #20).
- Primer-scheme fixtures: `Tests/Fixtures/primerschemes/` (symlinks).
- When you add a feature that transforms any shared fixture, add a `FunctionalFixtureTests`-style regression test.

---

## 5. Per-issue acceptance criteria (summary)

Full criteria live in each plan; this is the at-a-glance list.

- **#20:** A successful EsViritu run with zero viral hits reports as a completed operation showing "no hits," never as a per-sample failure. Regression test: header-only detection TSV parses to an empty array (no throw).
- **#21:** Selecting a folder in the sidebar and running Kraken2 / EsViritu / TaxTriage runs the classifier on every FASTQ sample in the folder. If subfolders contain additional eligible bundles, the user is asked whether to include them (top-level only vs. traverse subfolders).
- **#22:** Running a classifier (TaxTriage specifically) on a downsampled bundle produces miniBAMs and unique-read counts identical in kind to a full-dataset run.
- **#23:** After root-cause diagnosis, human-read removal in VSP2 is corrected (or its limits documented + surfaced) so residual human reads are minimized; residual fraction is measured and reported.
- **#24:** VSP2 provenance shows original read count, deduplicated read count, and percentage removed, in an obvious place (Inspector + operation log + CLI output).
- **#25:** A user can produce a GenBank-ready submission package (annotated `.gb` + BioSample TSV + source-modifier file + manifest) from an LGE assembly/consensus bundle, via GUI and a `lungfish genbank prepare` CLI command.
- **#26:** Tools menu shows FASTQ/FASTA operation categories at the top level; enabled workflows appear inside the matching category; installable-but-disabled workflows appear dimmed and, when clicked, offer to enable (routing to the workflow chooser); the standalone "Workflow Operations" menu item is gone; genotyping workflows live under a "Genotyping" category.
- **#27:** FASTQ import offers a choice of clumping tool (BBTools clumpify [default] / Trim Galore --clumpify / skip); Trim Galore is a registered core tool; the VSP2 import path uses Trim Galore --clumpify while other recipes keep BBTools.

---

*End of master spec. Proceed to the per-issue plans in the order given in §0.*

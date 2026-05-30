# Review Synthesis — Amplicon Genotyping + 12S

**Date:** 2026-05-30 · **Branch:** `codex/12s-amplicon-matching`
**Inputs:** 5 findings reports (`code-reviewer`, `architect-reviewer`, `swift-expert`,
`frontend-developer`, `ux-researcher`) + the operation-intent matrix
(`2026-05-30-operation-intent-matrix.md`).

## Headline

Both workflows are, at the implementation level, **well-built**: clean strict-concurrency Swift,
no `%s`/SIGSEGV traps, no illegal background→MainActor dispatch, thorough provenance, and (for 12S)
faithful reuse of the classifier idioms. The problems are concentrated in three places:

1. **One real P0 correctness/data-loss bug** — sample-ID collision in the multi-bundle Illumina
   genotyping path (silent overwrite + merged reads).
2. **Two parallel stacks that re-derive shared infrastructure** — three divergent reference-bundle
   designs, two CSV/TSV parsers (one not quote-aware), triplicated provenance/TSV helpers.
3. **The genotype viewport diverges from the classifier idioms 12S follows** — no
   `ClassifierActionBar`, no CLI-backed export, search/filter/provenance placed differently —
   producing a "two different apps" feel. 11 of 30 operation intents diverge as true convergence
   targets.

Cross-corroboration was high: the architect and swift-expert independently flagged the same
bundle-design inconsistencies (`isBundleURL` semantics, `formatVersion` vs `schemaVersion`+`kind`,
duplicated helpers); the frontend and ux agents independently produced the same convergence set.

## How findings map across reports (dedup)

| Theme | code-reviewer | architect | swift-expert | frontend | ux |
|---|---|---|---|---|---|
| Multi-bundle sample-ID collision (P0) | CR-01 | — | (batch concurrency clean) | — | — |
| 12S on by default | CR-02 | — | — | — | UX-01 |
| `.lungfishmhcref` consume-side half-wired | CR-05 | "partially closed" | — | — | UX-05 |
| Low-abundance filter divergence | CR-03 | A8 | — | F-01 (A) | D1/I1, UX-06 |
| Haplotype-manager `Task.detached`+`await MainActor.run` | CR-09 (P2) | A10 (P0) | — | — | — |
| Reference-bundle design divergence (`isBundleURL`, manifest fields, validation) | — | A1,A2 | SE-1,SE-2 | — | — |
| Two CSV/TSV parsers (quote-aware vs naive) | — | A3 | SE-8 | — | — |
| Triplicated provenance/dir-checksum + TSV helpers | CR-07 | A4,A7 | SE-7,SE-8 | — | — |
| Genotype lacks ClassifierActionBar/BLAST drawer | — | (A6 inline drawer) | — | F-02 | I22/I28 |
| Viewport export not CLI-backed (genotype) | — | — | — | F-02/I | UX-07, D4/I16 |
| Free-text search placement | — | — | — | F-03 (C) | UX-02, D2/I4 |
| Include/exclude idiom (menus vs pills) | — | — | — | F-04 (D/E) | D6/I8,I9 |
| 12S result table not sortable | — | — | — | — (matrix) | UX-03, D5/I6 |
| Reference-bundle builder entry points differ | — | — | — | (matrix O) | UX-08, D8/I12 |
| Bundle-export CLI command shape differs | — | — | — | — | D9/I17 |
| Provenance surface location differs | — | — | — | F-02/J | D10/I22 |
| argv executable-name drift (lungfish/lungfish-cli/lungfish-gui) | — | A11 | — | — | UX-09, D11 |
| 846-line viewport / 1028-line bundle / god-service | — | A5,A9,A12,A13 | — | F-10 | — |
| Misc Swift polish (zip shadow, dead `?? ""`, fragile `!`, dup struct) | CR-06,CR-08 | — | SE-3,SE-4,SE-5,SE-6 | F-05 | — |
| Accent color: system blue vs Lungfish Orange | — | — | — | F-07 | — |
| Other UI polish (delete color, metadata summary asymmetry, detail-rows dup) | — | — | — | F-06,F-08,F-10 | — |

## Disagreement adjudicated

- **Haplotype-manager detached task (CR-09 P2 vs A10 P0).** The code-reviewer says the
  `MainActor.run` hops are correct (no isolation violation) → P2; the architect says awaiting a
  `@MainActor` member from `Task.detached` violates a binding memory rule → P0. **Adjudication: P1.**
  It is functionally safe today (so not P0), but it literally breaks the stated rule "never `await`
  `@MainActor` from `Task.detached`" and lacks `[weak self]`, so it should be fixed, not deferred.
- **Batch path: swift-expert "clean" vs code-reviewer P0.** Not a contradiction. swift-expert
  assessed *data races / isolation* (clean — per-sample files, no shared mutable state).
  code-reviewer assessed *identifier logic* (CR-01: two inputs can sanitize to the same sample ID,
  overwriting files and merging reads). Both stand; CR-01 is a logic bug, not a concurrency bug.
- **`.lungfishmhcref` "unwired" (brief) vs "partially closed" (architect/CR/ux).** Corrected: the
  genotyping CLI *does* accept a `.lungfishmhcref` as `--reference` and auto-selects the bundle's
  **default** haplotype definition. The remaining gaps: (a) `--reference` help doesn't mention
  `.lungfishmhcref`; (b) explicit `--haplotype-definition` bypasses the bundle with no consistency
  check; (c) multi-definition bundles silently use only the default; (d) the run dialog still shows
  the full picker stack. These are the real Phase-4 work and the Phase-5 gate.

## Triaged, ordered findings

Cut line (orchestrator-set, user out of loop): **all P0 and P1 are in scope; P2 reuse refactors are
in scope where effort is justified (user opted these in).** Ordering is by severity, then leverage.

### P0 — correctness / data loss (must fix)

- **S-P0-1 (CR-01):** Multi-bundle Illumina genotyping sample-ID collision. Two input bundles whose
  names sanitize to the same ID overwrite each other's staged `*.sample-prefixed.fastq` and get
  their reads merged by the query-prefix demux → silent data loss + broken per-sample isolation.
  `ONTBarcodeDemuxGenotypingPipeline.swift:832-866,892-901`. Fix: detect duplicate sanitized IDs;
  disambiguate (append source stem / hash of `url.path`) or throw; validate unique `samples` before
  writing the manifest. **This is also a Phase-5 multi-bundle-gate prerequisite.**

### P1 — correctness-adjacent, provenance, and consistency (in scope)

- **S-P1-1 (CR-05/UX-05):** `.lungfishmhcref` consume-side completion — genotype against the bundle's
  FASTA + paired definitions; document `.lungfishmhcref` in `--reference` help; collapse the run-dialog
  picker stack to a "From bundle: <name>" summary when a bundle is selected; decide single-default vs
  all-definitions semantics. **Phase-5 bundle-format gate.**
- **S-P1-2 (CR-02/UX-01):** Remove `twelveSAmpliconMatchingID` from `defaultEnabledWorkflowIDs` so 12S
  ships opt-in. `WorkflowLibrary.swift:227-230`. Confirm no silent re-enable for existing users.
- **S-P1-3 (CR-03/A8/F-01/D1):** Converge low-abundance filtering. Add an editable minimum-reads
  control to `GenotypeResultDisplayState` mirroring 12S `minimumExactReads`; drive the cohort ~5K flag
  from it instead of a hardcoded constant. Architectural prerequisite (A8): a shared threshold model
  both display states reference.
- **S-P1-4 (F-02/UX-07/D4):** Genotype viewport export must shell out to `lungfish-cli` (binding-rule
  violation today: in-process XLSX with a `lungfish-gui` argv). Route through `genotype export-xlsx`
  (extended to take the visible/lens filter projection); verify `toolName == "lungfish-cli"`.
- **S-P1-5 (A1/A2/SE-1/SE-2):** Unify the reference-bundle design. One `isBundleURL` contract
  (manifest-existence), one manifest convention (`schemaVersion` + `kind`), shared validation with
  actionable errors. Collapse `.lungfishref`/`.lungfish12sref`/`.lungfishmhcref` onto a shared
  protocol/envelope + `SourceFile` type.
- **S-P1-6 (A3/SE-8):** Make `SampleMetadataStore` use the quote-aware parser from
  `SampleMetadataResolver` (current naive split is a latent data-corruption bug).
- **S-P1-7 (A10/CR-09):** Fix the haplotype-manager `Task.detached`+`await MainActor.run` to the
  prescribed `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }` (or a
  non-detached `MainActor` `Task`). Memory-rule compliance + `[weak self]`.
- **S-P1-8 (A11/UX-09/D11):** Normalize all replay argv to `lungfish-cli`; pick one canonical MHC
  bundle-create subcommand (`fastq mhc-reference-bundle` vs `haplotypes bundle-create`).
- **S-P1-9 (F-03/UX-02/D2):** Converge free-text search placement — adopt the in-viewport
  `NSSearchField` (classifier/genotype idiom) for 12S too.
- **S-P1-10 (F-04/D6):** Converge include/exclude + boolean filters on one idiom (the pill-row).
- **S-P1-11 (D9/I17):** Converge bundle-export CLI shape — one `genotype export --format ...` with the
  same filter flags 12S exposes, mirroring `12s-export` (unblocks S-P1-4).

### P2 — reuse refactors and polish (in scope where effort justified)

- **S-P2-1 (A5/A6/F-10):** Decompose the 846-line `TwelveSAmpliconResultViewController`: move
  display-state→row filtering into a shared model-layer filter (also fixes the two-sources-of-truth
  vs `TwelveSResultExportWorkflow.filteredRows`), extract a `BlastDrawerHosting` mixin, extract a
  shared detail-rows builder.
- **S-P2-2 (A7/CR-07/SE-7):** Extract shared `BundleBuilderSupport` + `ProvenanceDirectoryDescriptor`
  + a single `TSVTable` reader in `LungfishIO`; remove the triplicated copies across the two builders,
  the 12S workflow, and `HaplotypeDefinitionCommandService`.
- **S-P2-3 (A9):** Split `HaplotypeDefinitionCommandService` into library-CRUD vs MHC-bundle services;
  unify its two provenance writers; move manifest mutation onto `MHCAmpliconReferenceBundle`.
- **S-P2-4 (A12/A13):** Extract a `ResultBundle` protocol + shared sample-metadata snapshot; move 12S
  target-name interpretation into one resolver shared with `TwelveSTaxonGroupResolver`.
- **S-P2-5 (D5/I6, UX-03):** Make 12S result columns sortable (`sortDescriptorPrototype` +
  `sortDescriptorsDidChange`).
- **S-P2-6 (D7/I11):** Add a generic saved-filter-set service to 12S (parity with Smart Cohorts).
- **S-P2-7 (D8/I12, UX-08):** Surface both reference-bundle builders from one place (run-dialog
  reference picker).
- **S-P2-8 (D10/I22):** Pick one canonical provenance-surface location across both result viewports.
- **S-P2-9 (F-07):** Replace `Color.accentColor` (system blue) with Lungfish Orange at
  `GenotypeDropoutThresholdSection.swift:129`.
- **S-P2-10 (CR-06/SE-6):** Rename the `Swift.zip`-shadowing free function to `zipOptionals`.
- **S-P2-11 (CR-08):** Parse the designated UCHIME column index instead of scanning all fields.
- **S-P2-12 (SE-3/SE-4/SE-5, F-05, F-06, F-08, F-09):** Swift/UI polish — dead `?? ""` guard, fragile
  `targetID!`, duplicate `ResolvedDefinitionInput` struct, bespoke 12S disclosure buttons, delete-button
  color doubling, metadata-summary asymmetry, dialog reference picker vs `ReferenceSequencePickerView`.

### Domain-justified divergences — explicitly accepted, not work items

Per the matrix: I2/I3 (MHC support/dropout concepts 12S lacks), I7 (grouping), I25 (managed-definition
library), I28 (BLAST verification — MHC has no unknown-sequence need), I29 (configurable panes), I30
(haplotype color encoding), I20 (minor counter-vs-placeholder copy). Stated so their status is recorded.

## Phase-4 anchors (feed the improvement plan)

P0 + all P1 form the core of Pass B. The architectural prerequisites (S-P1-5 shared bundle design,
S-P1-3's shared threshold model, S-P1-11's unified export CLI) should land before the UI convergences
that depend on them. The Phase-5 gates (multi-bundle, `.lungfishmhcref`) are pinned to S-P0-1 and
S-P1-1.

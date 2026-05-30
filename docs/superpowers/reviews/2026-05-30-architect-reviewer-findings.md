# Architecture Review — Amplicon Genotyping + 12S (architect-reviewer)

**Date:** 2026-05-30 · **Branch:** `codex/12s-amplicon-matching`

> Persisted by the orchestrator from the architect-reviewer agent's returned findings (the
> architect-reviewer agent type is read-only and could not write this file itself). Content is the
> agent's verbatim report.

## Summary — biggest structural risks and top consolidation opportunities

The new code is competent and largely self-consistent within each workflow, but it was built as
**two parallel stacks that re-derive shared infrastructure rather than reusing it**. Three structural
themes dominate:

1. **The reference-bundle "pattern" is three near-duplicate implementations, not one shared
   abstraction.** `.lungfishref` (the established `ReferenceBundle` class with `manifest.json` +
   `BundleManifest`), `.lungfish12sref`, and `.lungfishmhcref` each invent their own enum facade, their
   own manifest filename, their own `isBundleURL`/`loadManifest`/`writeManifest`/`referenceFASTAURL`/
   `provenanceURL`, and their own `sourceFiles`/`metrics`/builder boilerplate (copy-FASTA +
   uniqueDestination + directoryDescriptor + writeProvenance, copied almost verbatim between the two new
   builders). The two new manifests disagree on field names (`schemaVersion`+`kind` vs `formatVersion`).
   Single largest reuse/divergence problem.

2. **Sample-metadata CSV/TSV parsing is duplicated inside one module.** `LungfishCore` now contains two
   independent delimited parsers — `SampleMetadataResolver` (quote-aware) and `SampleMetadataStore.parseCSV`
   (naive split, not quote-aware) — solving the same problem with different fidelity. Correctness-divergence
   risk, not just maintainability.

3. **The 846-line 12S viewport and 1028-line 12S result bundle each carry responsibilities that already
   exist as shared LGE machinery** (TSV table parsing duplicated in three files; BLAST-drawer wiring
   re-implemented inline rather than via a shared mixin; row-grouping/filtering that belongs in the model
   layer living in the view controller).

Where the architecture is **sound**: format-registry integration is correct and consistent for both new
bundles. The `.lungfishmhcref` consume-side gap is in fact **partially closed** — the genotyping CLI
resolves the default haplotype definition from the bundle. `TwelveSReferenceBundleBuilder` correctly
delegates metadata building to `TwelveSReferenceMetadataBuilder`. The 12S `Sendable`/value-type modeling
in the bundle data layer is clean.

Top consolidation opportunities (priority order): (A) extract a `ReferenceBundleProtocol` +
shared `BundleManifestBase` + shared `BundleBuilderSupport` to collapse the three reference bundles;
(B) make `SampleMetadataStore` consume `SampleMetadataResolver`'s parser; (C) extract a shared `TSVTable`
reader in `LungfishIO`; (D) extract a `BlastDrawerHosting` mixin and a shared classifier-style
`FilterableResultViewController` base.

## Findings

Schema: `ID | Severity | Surface | Location | Problem | Suggested fix | Effort`

- **A1 | P1 | cross-cutting | `MHCAmpliconReferenceBundle.swift:25-57` & `TwelveSReferenceBundle.swift:40-74`** — The two new reference-bundle manifests are divergent designs for the same concept. MHC uses `formatVersion` and has NO `kind`; 12S uses `schemaVersion` + `kind = "12s-reference"`. They duplicate identical `SourceFile` structs and each redefines a `Metrics` struct and an enum facade with the same four static methods. Fix: introduce a `ReferenceBundleManifest` protocol (or shared envelope with `schemaVersion`/`kind`/`name`/`referenceFastaPath`/`sourceFiles`/`provenancePath`/`createdAt`) and one `SourceFile` type; standardize on `schemaVersion`+`kind`. Effort: M.
- **A2 | P1 | cross-cutting | `ReferenceBundle.swift:45-123` vs the two new bundles** — The established `.lungfishref` is a `Sendable final class` with manifest validation, typed errors with `recoverySuggestion`, and a logger. The two new bundles ignore this: bare `enum` namespaces with `try? loadManifest` swallowing errors (`TwelveSReferenceBundle.referenceFASTAURL:105-109` returns `nil` on any decode failure). A corrupt bundle yields silent `nil` instead of actionable diagnostics. Fix: adopt the `ReferenceBundle` class shape (open/validate/throw) or document why amplicon bundles intentionally diverge; at minimum surface decode errors. Effort: M.
- **A3 | P1 | cross-cutting | `SampleMetadataStore.swift:56-77` vs `SampleMetadataResolver.swift:116-291`** — Two delimited parsers in the same module with different fidelity. `SampleMetadataStore.parseCSV` does naive `split(separator:)` with no quote handling, so a cell containing a comma corrupts every downstream column; `SampleMetadataResolver` is quote-aware. Both independently re-implement case-insensitive sample matching and column-scan heuristics. Latent data-corruption bug → P1. Fix: make `SampleMetadataStore` delegate to the shared quote-aware parser. Effort: M.
- **A4 | P2 | 12S | `TwelveSAmpliconResultBundle.swift:927-962`, `TwelveSReferenceBundleBuilder.swift:331-353`, `SampleMetadataResolver.swift:124-131`** — A TSV-table reader is hand-rolled ≥3 times. Fix: extract a single `TSVTable.load(from:)` in `LungfishIO`. Effort: M.
- **A5 | P2 | 12S | `TwelveSAmpliconResultViewController.swift:1-846`** — 846-line VC mixes ≥5 responsibilities (layout/data source, model-row filtering, detail formatting, BLAST-drawer lifecycle, export/NSSavePanel). Its filtering predicates duplicate `TwelveSResultExportWorkflow.filteredRows` (export 203-233) → two sources of truth for "what the display state selects" (on-screen view and exported file can silently diverge). Fix: move display-state→row filtering into a shared model-layer `TwelveSResultFilter`; extract `BlastDrawerHosting`. Effort: L.
- **A6 | P2 | cross-cutting | `TwelveSAmpliconResultViewController.swift:610-667`** — BLAST-drawer hosting (build container, swap split-view bottom constraint, drag/clamp, animate) re-implemented inline; the metagenomics surface has the same code. Fix: extract a `BlastDrawerHost` helper adopted by both; unify with `Views/Metagenomics/BlastResultsDrawerTab.swift`. Effort: M.
- **A7 | P2 | MHC | `MHCAmpliconReferenceBundleBuilder.swift:279-516` & `TwelveSReferenceBundleBuilder.swift:196-435`** — Two builders share large verbatim-duplicated private helpers (`uniqueDestination`, `copyBuildSource`, `directoryDescriptor`/`directoryChecksum`/`directorySize`, `fileFormat`, `relativePath`/`shellEscape`/`commandLine`, `safeFileName`); `HaplotypeDefinitionCommandService:738-778` carries a third copy of several. Fix: extract a `BundleBuilderSupport` in `LungfishIO`. Effort: M.
- **A8 | P1 | cross-cutting | `TwelveSResultDisplaySection.swift:234-255` vs `GenotypeResultDisplayState.swift:103-139` + `GenotypeCohortSummaryPanelView`** — "Suppress low-abundance noise" modeled with two abstractions and two control idioms; the two display-state types share no base and no shared filter type, so there is no single place to converge the idiom. Fix: define one shared low-abundance-threshold model (absolute + optional percent, shared SwiftUI control) both display states reference. This is the *architectural* prerequisite for the UX-level convergence. Effort: M.
- **A9 | P2 | MHC | `HaplotypeDefinitionCommandService.swift:21-862`** — +452-line god-service spanning validation, CRUD, MHC-bundle creation, in-bundle editing, FASTA replacement, and TWO divergent provenance writers (`writeMHCReferenceBundleProvenance:681-736` and `writeExportProvenance:780-826`, different envelope shapes). Manifest re-assembly duplicated between `saveDefinition(inMHCReferenceBundle:)` and `replaceReferenceFASTA`. Fix: split into `HaplotypeDefinitionLibraryService` + `MHCReferenceBundleService`; give `MHCAmpliconReferenceBundle` manifest-mutation helpers; unify provenance writers. Effort: L.
- **A10 | P0 | MHC | `HaplotypeDefinitionManagerWindowController.swift:322-347`** — Concurrency-rule violation: `createMHCReferenceBundle` uses `Task.detached { ... await MainActor.run { self.isWorking = ...; self.reload() ... } }`, awaiting `@MainActor` members from a detached task (rule forbids this) and capturing `self` with no `[weak self]`. Fix: run the build via a non-isolated service and marshal back with `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }`, or make it `func ... async` called from a `MainActor` `Task` (no `.detached`). Effort: S. (Overlaps code-reviewer CR-09; architect frames it as an async-boundary design issue.)
- **A11 | P2 | cross-cutting | `HaplotypeDefinitionCommandService.swift:691` & `HaplotypeDefinitionManagerWindowController.swift:135,210-214,253-258`** — Replay `argv[0]` constructed inconsistently across the haplotype surface: `lungfish` (importDefinition:135), `lungfish-cli` (saveDraft, replaceReferenceFASTA), and a `lungfish-gui` fallback (provenance:691) — three executable names. Memory rule says CLI argv uses `lungfish-cli`. Fix: standardize on `lungfish-cli` via a single `cliArgv` helper; remove `lungfish-gui`. Effort: S.
- **A12 | P2 | cross-cutting | `TwelveSAmpliconResultBundle.swift:692-697` vs `ONTGenotypeResultBundle.swift:3-49`** — The two *result* bundles also diverge structurally; no shared `ResultBundle` protocol, so sample-metadata handling, manifest load/write, and `resolvedURL` resolution are re-implemented per type. Fix: extract a `ResultBundle` protocol with default `manifestURL`/`loadManifest`/`writeManifest`/`resolvedURL` and a shared `SampleMetadataSnapshotManifest`. Effort: M.
- **A13 | P2 | 12S | `TwelveSAmpliconResultBundle.swift:611-665`** — Scientific-name grouping/parsing heuristics (`scientificNameKey`, `parseScientificName`, `metadataValue` parsing `key=value|...`) live in the IO serialization layer and overlap with `TwelveSTaxonGroupResolver` (separate name→group engine). Two name-interpretation engines in two layers. Fix: move target-name interpretation into a single resolver in `LungfishWorkflow` consumed by both. Effort: M.

## Where the architecture is sound (explicit)

- **Format-registry integration is correct and consistent.** `FormatIdentifier` registers
  `lungfish12sref` (330-335) and `lungfishmhcref` (337-342) exactly like `lungfishRef` (323-328);
  `FileTypeUtility` maps both to `.referenceBundle` (76-77) alongside `lungfishref` (75). (Result-bundle
  extensions `lungfish12s`/`genotype-result` are not registered, but neither is the genotype result bundle
  — consistent with existing convention.)
- **`.lungfishmhcref` consume-side wiring is partially closed (counter to brief candidate #2).**
  `FastqGenotypingSubcommand` accepts a `.lungfishmhcref` as `--reference` and
  `defaultBundledHaplotypeDefinition(for:):169-176` resolves the bundle's default definition, feeding
  `effectiveHaplotypeDefinition/Assay/Species` (108-111). Remaining gap is narrower: explicit
  `--haplotype-definition` bypasses the bundle and there is no consistency validation.
- **`TwelveSReferenceBundleBuilder` composes rather than duplicates** — delegates to
  `TwelveSReferenceMetadataBuilder` (88-102) instead of re-implementing MIDORI parsing.
- **The 12S model layer is well-factored as value types** (`TwelveSAmpliconTarget`/`SampleResult`/
  `ReadFate`/`ScientificNameCountRow` — clean `Codable`/`Equatable`/`Sendable` with copy-mutators; derived
  views computed, not stored).
- **`SampleMetadataResolver` itself is portable and well-bounded** (pure `LungfishCore`, Foundation-only;
  layered-precedence resolve and TSV round-trip clean). Its only architectural problem is that
  `SampleMetadataStore` re-implements parsing (A3).
- **The 12S export workflow's provenance** uses the shared `ProvenanceRunBuilder` fluent API — the right
  pattern. Notably the reference-bundle builders (A7) do NOT; converging them onto `ProvenanceRunBuilder`
  is a clean win.

## Cross-workflow divergence map (architecture lens)

| Concern | 12S | MHC | Existing LGE | Verdict |
|---|---|---|---|---|
| Reference bundle facade | enum, `12s-reference.json`, `schemaVersion`+`kind` | enum, `mhc-reference.json`, `formatVersion`, no `kind` | `ReferenceBundle` class, `manifest.json`, `BundleManifest`+validation | Divergent (A1, A2) |
| Result bundle facade | enum + Data value type, `schemaVersion`+`kind` | `ONTGenotypeResultBundle`, `schemaVersion`+`kind` | (these two are it) | Partially convergent; no shared protocol (A12) |
| TSV parsing | hand-rolled (bundle + builder) | n/a (CSV via pipeline) | scattered | Duplicated (A4) |
| Sample-metadata parsing | `SampleMetadataResolver` (quote-aware) | `SampleMetadataStore` (naive) | both in LungfishCore | Divergent + bug (A3) |
| Low-abundance filter | `minimumExactReads` (abs int) | `minimumSupportPercent` + hardcoded 5K | n/a | Divergent, no shared type (A8) |
| Builder provenance | `ProvenanceRunBuilder` (export) / hand-assembled (ref builder) | hand-assembled | `ProvenanceRunBuilder` | Inconsistent (A7) |
| Replay argv[0] | `lungfish-cli` | `lungfish`/`lungfish-cli`/`lungfish-gui` | `lungfish-cli` | Inconsistent (A11) |
| BLAST drawer hosting | inline ~60 lines | n/a | metagenomics surface (shared intent) | Duplicated (A6) |

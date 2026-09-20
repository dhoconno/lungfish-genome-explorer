# iVar Variant Fields Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Show retained iVar allele frequency and caller measurements in existing and newly imported variant tracks, and make their filters/sorts truthful.

**Architecture:** Preserve non-core sample FORMAT fields in the existing SQLite `raw_fields` column. Build an immutable presentation overlay from those records; for legacy iVar databases with missing fields, asynchronously hydrate the overlay from the final bundled VCF without modifying scientific files. Project single-sample measurements into the existing dynamic-column/query presentation, with origin metadata distinguishing FORMAT measurements from genuine INFO values.

**Tech Stack:** Swift, AppKit, SQLite, existing LungfishIO VCFReader; no dependency or schema migration.

**Spec:** The user request and read-only evidence below are the bounded specification. Coordinate with the variant controls plan for final sorting and coverage presets.

## Global Constraints

- Astra performed investigation only. Use a smaller model (Sol suggested for this data path) for implementation; builds/tests belong to Sol Medium. No compilation was performed during this investigation.
- Never modify the supplied real bundle. Smoke-test a disposable copy only if needed; primary tests use synthetic fixtures.
- No invisible rewrite of VCF, SQLite, or provenance when opening a legacy bundle. Runtime hydration is read-only.
- Scientific outputs must retain workflow/tool version, exact command, resolved options, runtime identity, input/output paths, checksums, sizes, exit status, wall time, useful stderr, and final stored artifact paths. Keep existing BundleVariantTrackAttachmentService provenance promotion behavior.
- Preserve within-sample FORMAT frequency semantics; never label a projected value `INFO/AF`, never overwrite a real INFO value, never aggregate several samples into an unexplained scalar.

## Evidence and root cause

Read-only inspection of `/Users/dho/Downloads/Household_Path_Sequence_analysis.lungfish/Analyses/minimap2-2026-09-18T20-31-01/NC_045512.lungfishref` found an iVar track `vc-481afc04-07af-44e1-b766-abd6f8abec65` containing 196 variants. The retained VCF has:

```text
NC_045512  241  .  C  T  .  PASS  TYPE=SNP  GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ  1:2140:0:0:0:2140:1033:66:1
NC_045512  509  .  GGUCAUGUUAUGGUU  G  .  ft  TYPE=DEL  GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ  1:30:30:14:65:2:0:20:0.0666667
```

SQLite has `TYPE=SNP`, DP 2140, but `raw_fields=NULL`; its only INFO definition is TYPE. `VariantDatabase+CreateFromVCF.swift` around line 933 deliberately binds NULL, incorrectly claiming all raw FORMAT fields duplicate GT/DP/GQ/AD. Thus the retained VCF has the values, SQLite loses them, and the table only creates INFO columns. Hover also recognizes AF/FREQ but not ALT_FREQ.

Trace: `IVarTSVRow` parses ALT_FREQ and totalDP → `IVarTSVToVCFConverter.sampleFields` emits ALT_FREQ and DP in FORMAT → workflow normalization → `VariantSQLiteImportCoordinator.defaultFreshImport` → `VariantDatabase.createFromVCF` drops non-core FORMAT → `AnnotationSearchIndex.variantInfoKeys` and `AnnotationTableDrawerView+Columns.configureColumns` expose INFO only. The converter's merged frequency is minimum constituent AF; MERGED_AF retains constituent frequencies. Do not recalculate AF from ALT_DP/DP, especially for merged calls.

The original TSV is not present beneath the supplied analysis directory. PVAL and TSV codon/AA fields are not written by the existing converter at all. They cannot be recovered from this bundle; do not invent them. This change targets the measurements actually retained in VCF. QUAL is intentionally `.` in this converter; ALT_QUAL is mean alternate-base quality, not variant QUAL.

Final VCF location is authoritative in manifest `track.path`; DB metadata also has `artifact_vcf_path=variants/<track>.vcf.gz`. `import_source=variants.normalized.vcf` is only a staging basename and must not be used to hydrate.

## Review Focus

- Legacy NULL raw_fields: read final retained VCF and keep source bytes unchanged (Task 2).
- Several tracks share coordinates/row IDs or several samples differ: never cross-contaminate or aggregate (Tasks 2–3).
- Zero, missing, invalid, merged frequency: preserve zero, reject invalid numeric filters, retain original merged value (Tasks 1–3).
- SQL filtering happens before runtime hydration: no false empty results or sorting only a truncated page (Task 4).
- Asynchronous completion after bundle switch/deletion: cancel or reject stale publication and invalidate rows/columns/query caches (Task 2).

## Task 1: Preserve non-core FORMAT fields on new imports

**Files:** Modify `Sources/LungfishIO/Bundles/VariantDatabase+CreateFromVCF.swift`; tests `Tests/LungfishIOTests/VariantDatabaseGenotypeTests.swift`.

- [ ] Add a synthetic one-sample VCF with the FORMAT sequence above and ALT_FREQ=0.0666667, DP=30. Import through `createFromVCF`, fetch genotypes, parse `rawFields` with `AnnotationDatabase.parseAttributes`, and assert ALT_FREQ, REF_DP, ALT_DP, ALT_QUAL survive; existing depth remains 30.
- [ ] Replace the NULL bind at parameter 10 with non-core key/value serialization. Preserve only fields beyond GT/DP/GQ/AD, in original FORMAT order; omit absent, empty, or `.` values. Existing consumers expect semicolon-delimited `key=value`, not JSON or raw colon strings:

```swift
let coreFields: Set<String> = ["GT", "DP", "GQ", "AD"]
let extras = zip(formatFields, sampleFields).compactMap { key, value -> String? in
    guard !coreFields.contains(String(key)), !value.isEmpty, value != "." else { return nil }
    return "\(key)=\(value)"
}
variantDBBindTextOrNull(insertGenotypeStmt, 10,
                      extras.isEmpty ? nil : extras.joined(separator: ";"))
```

- [ ] Retain sparse hom-reference storage policy; no giant new genotype matrix. Do not synthesize AD or alter GT. Add tests for zero ALT_FREQ, arbitrary non-core field PL, short sample payload, and two samples with distinct values. Existing GT/DP/GQ/AD-only fixture should keep rawFields nil.
- [ ] Sol Medium runs `swift test --filter VariantDatabaseGenotypeTests`; inspect failures before expanding scope. No database schema bump: raw_fields already exists.

## Task 2: Immutable read-only FORMAT overlay, including legacy VCF recovery

**Files:** Create `Sources/LungfishApp/Services/VariantFormatOverlay.swift`; modify `Sources/LungfishApp/Services/AnnotationSearchIndex.swift`; create `Tests/LungfishAppTests/VariantFormatOverlayTests.swift`.

**Interfaces to add:**

```swift
struct VariantFormatKey: Hashable, Sendable {
    let trackID: String
    let chromosome: String
    let position: Int // zero-based, unlike VCFVariant.position
    let ref: String
    let alt: String   // VCF alt.joined(separator: ",")
    let sample: String
}
struct VariantFormatOverlaySnapshot: Sendable {
    var fields: [VariantFormatKey: [String: String]] = [:]
    var singleSampleByTrack: [String: String] = [:]
    var projectedKeysByTrack: [String: Set<String>] = [:]
    // Pure functions; no IO, mutation, or main-actor access:
    func projectedInfo(trackID: String, record: VariantDatabaseRecord,
                       existing: [String: String]) -> [String: String]
    func sampleFields(trackID: String, record: VariantDatabaseRecord,
                      sample: String) -> [String: String]
}
```

- [ ] Build synthetic read-only fixtures covering preserved rawFields and old NULL rawFields with retained VCF. The loader first batch-fetches DB genotypes; decode rawFields and merge typed DP/GT/GQ/AD into the per-sample dictionary. Only legacy iVar tracks with missing non-core fields require a VCF scan. Limit hydration scope to track source iVar (case-insensitive) or records having iVar ALT_FREQ; avoid eagerly scanning unrelated large cohort tracks.
- [ ] Resolve source URL in `openVariantDatabases(bundle:)` with `bundle.memberURL(for: trackInfo.path, field: ...)`. Stream `VCFReader(validateRecords: false, parseGenotypes: true).variants(from:)` in a detached task, not AppKit callbacks. `false` is necessary because the retained real example includes U in a deletion allele. Use `VCFGenotype.fields: [String: String]`. Convert 1-based VCF coordinates exactly once. Resolve chromosome aliases using the same bundle mapping as DB records, rather than stripping `chr` blindly.
- [ ] Cache only immutable snapshots on AnnotationSearchIndex. Capture its generation and source URLs before launching. Cancel old loader tasks on reopen/close/rebuild; publish on main actor only if generation still matches. Do not mutate a dictionary being read by background query work. Reject ambiguous duplicate VCF keys with conflicting values rather than silently assigning another record's measurements.
- [ ] Missing/unreadable VCF leaves unavailable measurements absent with a logged diagnostic, not zero. Do not expose a projected key until usable values are loaded. Source identity is track ID + final URL + file size/modification time; rebuild after bundle reopen/data generation changes. Do not open per hovered row.
- [ ] On successful publication increment variant data generation, invalidate global filtered caches, refresh dynamic keys/table data, and invalidate hover cache. Notify via the existing index completion/update route; do not poll. Tests explicitly complete an old loader after a newer generation and assert it cannot publish.
- [ ] Assert synthetic DB, VCF, manifest, and provenance checksums unchanged after hydration; test two tracks with identical row IDs, distinct samples, alias match, missing VCF, and incompatible duplicate source rows.

## Task 3: Present sample-aware fields and correct hover provenance

**Files:** Modify `AnnotationSearchIndex.swift` (`variantInfoKeys` and both result conversions), `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift` (`AnnotationVariantQueryContext` snapshot and result conversion), `AnnotationTableDrawerView+Columns.swift`, `SequenceViewerView+VariantDetails.swift`; tests `VariantFormatOverlayTests.swift`, `VariantHoverDetailsTests.swift`, `VariantTableEnhancementTests.swift`.

- [ ] `projectedInfo` returns existing INFO merged with single-sample iVar fields, existing INFO winning. Project `AF ← ALT_FREQ`, `DP ← DP`, and original keys REF_DP, REF_RV, REF_QUAL, ALT_DP, ALT_RV, ALT_QUAL, ALT_FREQ, MERGED_AF, MERGED_DP. Skip empty/`.`. Only AF values finite and in 0...1 qualify as numeric AF; preserve original raw data for detail inspection. Keep constituent arrays as String columns. No INFO projection at all when more than one sample is present.
- [ ] Add dynamic field definitions for loaded projection keys to `variantInfoKeys` union even though `db.hasNonEmptyInfoValue` is false. Numeric types: AF/ALT_FREQ Float; depth/count/quality fields Integer; MERGED_AF/MERGED_DP String. Descriptions must identify source (`Within-sample frequency from iVar FORMAT/ALT_FREQ`). Column IDs remain existing `info_AF`, `info_DP`, etc., so table controls and saved layouts work. For projected-only AF/DP label column tooltip as FORMAT; retain genuine INFO metadata when both exist.
- [ ] Merge overlay at both `AnnotationSearchIndex.variantRecordsToSearchResults` and `AnnotationVariantQueryContext.variantRecordsToSearchResults`. Pass immutable snapshot as a stored property with an empty default to avoid breaking existing memberwise test construction. Never mutate `variants.info` or manufacture VCF headers.
- [ ] Hover retrieves sample dictionaries from snapshot and existing genotype records. Extend frequency recognition to ALT_FREQ and label it `Allele frequency (FORMAT/ALT_FREQ)`. Keep actual INFO/AF distinct when present. Display caller measurements REF_DP/REF_RV/REF_QUAL/ALT_DP/ALT_RV/ALT_QUAL and merged arrays in the sample block. Avoid rawField serialization/reparse churn: add an optional per-sample dictionary argument to formatter with empty default. Existing tests for ordinary INFO and AD-derived values remain valid.
- [ ] Test real-example synthetic row yields AF=1, DP=2140 and column discovery; missing/zero; merged ALT_FREQ differing from ALT_DP/DP; genuine INFO AF not overwritten; multisample no row-level scalar but correct per-sample hover; same coordinates in different tracks remain different. QUAL stays missing while ALT_QUAL appears independently.

## Task 4: Make projection filters/counts/sorts operate on complete results

**Files:** `AnnotationTableDrawerView.swift` (`AnnotationVariantQueryContext.queryVariantsInRegion`, `queryVariantCountInRegion`, `queryVariantsOnly`, `queryVariantCount`, `queryVariantsForGenes`), `AnnotationTableDrawerView+Filtering.swift`; tests in `Tests/LungfishAppTests/VariantTableEnhancementTests.swift` or dedicated `VariantFormatOverlayQueryTests.swift`.

- [ ] Coordinate with variant controls implementer before changing sorting. Their `sortDisplayedVariantCallsIfNeeded()` sorts the displayed set; projected-field sort actions must instead trigger a query rerun carrying the selected descriptor, sort the complete hydrated candidates, then apply the display cap. Freeze overlay in the context when `applyFilters` starts. A track is projection-affected when any requested INFO key or sort key belongs to its `projectedKeysByTrack`; INFO and FORMAT remain track-specific. A track containing both actual and fallback values still requires this path.
- [ ] Split requested INFO predicates by projected keys per track. Send only non-projected predicates to SQLite. Retain chromosome, type, name, sample and other independent constraints. Fetch matching candidates in bounded pages using existing cancellation token until exhaustion; do not prefix at maxDisplay before applying projected filters. For smart compound filters involving projected keys, evaluate the complete affected predicate in memory to preserve OR/NOT semantics; do not merely delete one SQL clause.
- [ ] Overlay candidates, evaluate postponed predicates using the same numeric/string/missing semantics as existing InfoFilter, then apply advanced/within-sample post-filters and final global sort from the variant-controls change. Only then slice display limit. Count from the same filtered candidate set, not a SQL count missing FORMAT values. Gene-list paths must deduplicate track+row identity before counts/slicing. Unaffected tracks retain existing SQL fast path.
- [ ] Explicit tests: only matching AF row lies beyond initial display cap; AF 0.9 versus 0.10 numeric sort; DP>100 excludes DP30 and includes DP2140; mixed LoFreq INFO AF and iVar FORMAT ALT_FREQ; equality and missing values; OR smart filter with one projected branch; region, gene and genome scopes; multi-track count equals complete filtered set; cancellation stops scans.
- [ ] Ensure cached query keys include overlay generation; stale queries cannot publish. AF presets become available after hydration and query builder discovers numeric types.

## Verification and handoff

- [ ] Sol Medium runs focused `VariantDatabaseGenotypeTests`, `VariantFormatOverlayTests`, `VariantHoverDetailsTests`, relevant `VariantTableEnhancementTests`, and query tests. Use repository test/build guidance if Package.swift excludes app tests; do not invent a new build pipeline.
- [ ] Existing `IVarTSVToVCFConverterTests` and viralrecon parity tests remain unchanged: this plan intentionally does not change converter scientific output.
- [ ] Existing `BundleVariantTrackAttachmentServiceTests` continue to assert final stored VCF/DB paths and full provenance. New import preservation must not remove provenance metadata. Read-only overlay emits no derived artifact and therefore needs no fabricated provenance event.
- [ ] Manual synthetic/copy smoke check: opening old iVar track eventually shows AF and depth; no scientific bundle file changes; numeric sort and AF/DP filter are correct; hover identifies FORMAT origin; reopen is consistent.

No user decision is needed to implement this bounded fix. Broader preservation of PVAL/codon/amino-acid TSV columns would change converter output and parity contract and belongs to a separate scientific-format change.

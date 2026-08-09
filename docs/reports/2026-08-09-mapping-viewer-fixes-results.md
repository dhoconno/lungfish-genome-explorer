# Mapping Viewer Fixes — Results (2026-08-09)

Branch `worktree-mapping-viewer-fixes` off main b6ad0dd9. Four items shipped across four commits, orchestrated spec → expert gate → plan → gated per-phase implementation.

Spec: `docs/superpowers/specs/2026-08-09-mapping-viewer-fixes-spec.md`
Plan: `docs/superpowers/plans/2026-08-09-mapping-viewer-fixes-plan.md`

## What shipped

### Item 1 (P0 bug): minimap2 reference fails to load — validator rejected the app's own symlinks — `d89443b5`
Commit e5a01250 (2026-07-05) added a post-`resolvingSymlinksInPath` descendancy re-check to `BundleManifest.validatedBundleMemberURL` that rejected the mapping viewer bundle's legitimate genome/annotations/variants/metadata symlinks into the external source bundle. Failed at `ReferenceBundle.init` before any fetch, silent under `try?`.

Fix: origin-scoped, hardened relaxation.
- `validatedBundleMemberURL` gains `allowedEscapeRoots: [URL] = []` (default = prior strict behavior). Escape permitted only when (a) the first path component is a bundle-owned top-level symlink AND (b) the resolved candidate is file-identity `(st_dev, st_ino)`-contained in an allowed root. Lexical checks on the unresolved candidate unchanged.
- `ReferenceBundleEscapeRoots` (new, LungfishIO) derives roots from `manifest.originBundlePath` under strict constraints: valid relative string; inside the same `.lungfish` project; `.lungfishref`; origin manifest validates + identifier matches viewer; not a forbidden/ancestor root; depth=1 (no transitive origins).
- Public `ReferenceBundle.memberURL(for:field:)`; migrated viewer-bundle display call sites so annotation/variant/metadata tracks resolve through the symlinks too.

Security: passed a spec-stage pentest (initial REJECT → hardened) and a re-pentest of the implemented code (APPROVE). Residual capability is confined to a sibling `.lungfishref` in the same project the user already opened — strictly narrower than the app's existing file access. TOCTOU accepted for the single-user desktop model (`NoFollowFileSystem` reads noted as a cheap follow-up).

### Item 2 (enhancement): bundle display name in selector + reference track label — `a46632a3`
Mapping viewport showed the internal FASTA contig id (e.g. `NC_078297`). Now shows the user-facing bundle display name in display strings only; contig id kept everywhere functional (coordinates, region strings, samtools regions, export record names, @RG/BAM header, selection/sort/copy keys, view-state, notifications, logging).
- `BundleDisplayLabel` (LungfishCore, pure). Selector cell = bundle-name primary + dimmed contig (+`fastaDescription`) secondary, omitted when equal; track header = name (single-contig) else `name (contig-or-description)`, no em dash. Accession stays visible without a filter action (accession-driven QC).
- Additive `BatchTableView.secondaryCellText` seam (existing `cellContent` tuple untouched → leaf overrides source-compatible) plus a per-table taller row height so the secondary line isn't clipped. `cellContent` decoupled from `columnValue` so copy/sort/filter-key keep the contig id.
- New `viewerBundleManifest` field on `ReferenceBundleViewportInput.mappingResult` (existing `manifest`/`documentTitle`/summary bar untouched). Display name cached on `ViewerViewController` for the hot re-derivation path; nil-fallback preserves non-mapping behavior.

### Item 3: select reads → copy/extract as FASTA — `d9884a9f`
The main mapping viewport already had Cmd/Shift read multi-select but no way to act on it. Added a right-click read menu.
- `AlignedReadFASTAFormatter` (LungfishKit): aligned-orientation FASTA from SAM SEQ (soft clips included, hard clips absent+counted). Header `>QNAME RNAME:1based-start-end strand=± cigar= mapq= [hardclipped=N]`. Skips empty/`*` SEQ (secondary alignments) with a reported count.
- `ReadSelectionActionMenuBuilder` (LungfishKit): "Copy as FASTA (aligned orientation)" + "Extract Reads… (original reads)" with tooltips stating the aligned-vs-original distinction. `rightMouseDown` gains a read branch via a pure testable `buildReadContextMenu` seam.
- `ReadExtractionService.extractByReadIDsFromBAM` (LungfishWorkflow): `samtools -N` name filter; excludes secondary+supplementary by default (`-F 0x900`), dedup OFF (literal selection), mates via QNAME, singletons routed separately, `--include-secondary` name-disambiguation; conversion-step `-F 0` so kept records aren't silently re-dropped; persisted read-name file for replay.
- Full OperationCenter integration with provenance (`source-fastq`|`bam-derived`) and record-vs-selection count + distinct contig set in the completion message.
- CLI: `extract reads --by-id --bam` (source-XOR-bam; `--no-keep-read-pairs` a hard error in BAM mode; `--include-secondary`/`--exclude-duplicates`; fasta parity).

Scientific correctness passed a genomics gate. A reverse-strand orientation round-trip test proves `samtools fastq` restores original read orientation (aligned-copy is reference-oriented; extract is original-oriented — both correct, distinct, disclosed).

### Item 4: dots for reference agreement — `08a5ecc7`
Match-as-dot rendering already existed but silently degraded to all-letters for minimap2 bundles (Item 1 reference-load failure + minimap2 emits no MD tags by default → everything classified as mismatch). Item 1 restores the reference; Item 4 hardens the classifier and closes the test gap.
- Extracted a three-valued `BaseRenderClass` (.mismatch/.match/.neutralN) classifier; fallback order preserved (explicit CIGAR `=`/`X` → refBytes compare → MD tag → else).
- Correctness fixes (each unit-tested): SAM `=` in SEQ → match/dot (handled on the raw byte before the `&0xDF` mask — the mask defeated the prior check and the original test hid it); read `N` → always neutral, never a dot; reference `N`/non-ACGTU → no-call, not a mismatch column; reference IUPAC ambiguity codes matched by expansion (with T/U equivalence).
- "No reference: all bases shown as mismatches" badge when no reference AND no MD tags; actionable tooltip. Inspector dots toggle gains a "(letters at max zoom)" hint. 4.0 px/base threshold unchanged.

## Process notes
- Every phase was TDD (red → green) and passed an independent review gate that I adjudicated. The gates caught three "passing tests that were actually blind": a Phase 2 NSTableView reuse test that never exercised recycling (made deterministic), a Phase 3 homopolymeric fixture blind to orientation regressions (added a reverse-strand round-trip), and a Phase 4 `=`-byte mask bug where the test fed the byte in a way that bypassed the production path (fixed + red/green-confirmed).
- Test scaffold (Phase 0) reused the existing `LungfishTestSupport` target; `MappingViewerScaffold` builds a synthetic `.lungfish` project with plain + real-bgzip payloads.

## Verification
- Full-suite green-bar: **12,797 XCTest cases passed / 0 failed; swift-testing 563 tests / 0 failed** (complete 31,299-line log, exit 0). Meets the green-bar definition (XCTest failures ⊆ 9 known-environmental + SRA flake; swift-testing 0). The 9 known-environmental failures did not appear — this worktree run did not touch the external-volume/`~/Downloads` paths they depend on.
- Whole-branch review: **MERGEABLE**. Three NOTE-level findings, all defensible / pre-existing: (1) `ReferenceBundleSourceResolver` retains its own (non-security) resolution — different purpose; (2) packed-tier mismatch ticks did not receive Item 4's classifier fixes (pre-existing, out of Item 4's dot-classifier scope — spawned as a follow-up); (3) `extractSelectedReads` uses `log` not `update()` — acceptable for a single fire-and-await op.
- GUI smoke: interactive Computer Use control of the app was declined by the user this session, so the user-visible outcomes rest on behavioral tests instead: `testPreparedViewerBundleOpensAndFetchSequenceSyncMatchesSourceBundleByteForByte` exercises the exact production symlink → validator → bgzip-fetch path (reference now loads) and the Item 4 classifier tests exercise match→dot through the real `resolveBaseRender` caller (dots render on a loaded reference). The debug app binary builds (`.build/debug/Lungfish`, 239 MB, built this session).

## Follow-ups (spawned, not in this branch)
- Review attacker-crafted absolute alignment `sourcePath` in a hand-crafted `.lungfishref` (pre-existing external-BAM read primitive, unrelated to this fix).
- `NoFollowFileSystem` reads for the validated member paths (closes the accepted TOCTOU residual cheaply).
- `MappingResult.sourceFASTQBundleURL`-style field so read extraction can use the original-FASTQ path instead of always the BAM-derived fallback.

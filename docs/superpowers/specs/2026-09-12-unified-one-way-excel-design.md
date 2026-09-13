# Unified, one-way genotype Excel export

Approved by the user on 2026-09-12 after architecture, scientific, and UI/UX assessment. This supersedes the editable three-sheet workbook design. There are no outstanding Excel files whose edits must be preserved or imported.

## Outcome

LGE is the sole editing authority. Export to Excel creates a point-in-time report, never a synchronized editor. One workbook contains, in order:

1. `Haplotype Calls`, when actual haplotype result content exists in LGE.
2. `Genotype Matrix - All`.
3. `Genotype Matrix - Filtered`.
4. `Export Metadata`.

Without haplotype content there are three sheets and no haplotype bands in either matrix. The same export serves MiSeq MHC, full-length ONT, and genotype-only analysis. An actual manual assignment establishes call content; automatic analyzed unresolved/error/no-call results remain meaningful content. Empty manually eligible placeholder records do not.

## Scientific and presentation contract

- Capture one immutable scientific snapshot: authoritative matrix evidence and stable identities, effective calls, annotations, resolved styles and palette, sample/locus order, filter state and denominators, and input/version witnesses. Produce both matrices from that snapshot using one renderer.
- All means all authoritative genotype-matrix evidence in the selected analysis, not every raw FASTQ read. It must not inherit search, sample/locus restrictions, candidate visibility, or support masks from the filtered viewport.
- Filtered means exactly the viewport's captured sample/row order, stable row identities and displayed cell values after all active filters. A one-read observation hidden by a five-read threshold must not reappear. Raw support may be recorded separately as explanatory provenance; it must not replace a masked displayed value.
- User clarification: omit genotype evidence rows from Filtered unless at least one visible sample has a positive displayed read count after filtering. Raw reads hidden by the filter, reads in excluded samples, unknown values, zero-only reviews, comments or styles do not keep an otherwise empty row. Retained rows preserve their eligible annotations, including zero-support FN cells when another visible sample retains reads. All remains complete. This rule does not remove haplotype bands or the optional calls sheet; there is no Excel keep-empty-rows override.
- Both matrix bands and the calls sheet use the same effective H1/H2 values, statuses, sources and palette, including homozygotes, swaps, manual changes, explicit absence, and errors. Bands project that common map onto the corresponding matrix axes. They do not rerun haplotyping or invent H2 values.
- Calls, colors, and annotations are static literal output, not formulas, formula-cache rewrites, conditional-format rules for editing, or editable action columns.
- Retain applicable FP/FN, row/sample/cell comments and explicit style overrides. Validate reviews against authoritative evidence: FP requires positive support; FN requires attested exact zero. Unknown is not zero. Keep duplicate/conflicting source annotation records in LGE/provenance while withholding invalid display annotations.
- Preserve candidate stable IDs even with duplicate labels, full-length ONT aggregation semantics, distinct known-call and candidate percent denominators, and native LGE scientific history.
- Reject incoherent or changed input snapshots rather than silently mixing capture-time calls with later evidence. Export failures must not mutate scientific data or replace a previously successful report.

## UI

Use one Inspector `Export to Excel…` action leading to a save panel. Briefly explain that the workbook contains both all and filtered results and is a snapshot; edits must be made in LGE. Explicitly disclose that filtering does not redact the full-data worksheet. Use a timestamped report filename, not `current.xlsx`. Ordinary progress, failure, cancellation and last-success feedback remain; role selection, synchronization state, Excel review/import actions and background current-workbook update controls disappear. Resolve pending native edits before capture. Exporting to a chosen writable location must not require modifying a readable source project.

## Code retirement and retained authority

Remove Excel import parsers, trusted editable manifests/Notes grammar, review presentation/acceptance, `current.xlsx` freshness/fingerprint/sync/open-handoff lifecycle, automatic current-workbook updating and obsolete CLI updating entry points. Do not build a legacy Excel-edit migration bridge. Remove dead workbook override scripts once consumers are eliminated.

Preserve native curation, accepted annotations/audit, scientific provenance, historical scientific artifacts, shared bundle publication locking, and interrupted project/bundle transaction recovery. A helper shared with non-Excel science must be extracted/retained rather than deleted. Existing project data is not deleted. Original pipeline artifacts may remain historical outputs, but new user-facing reports use the common one-way export; no new active `current.xlsx` lifecycle is created by pipelines or AI completion.

## Provenance

Every export records workflow name/version, exact argv or reproducible replay command, explicit options and resolved defaults, runtime identity, input/output final paths, checksums and sizes, exit status, wall time, and useful stderr. GUI exports retain replayable capture payloads and provenance at durable output locations. The workbook contains readable scope/filter/source metadata; a durable receipt can carry the workbook checksum outside the workbook itself. One workbook does not prohibit required provenance sidecars. Temporary-only replay paths or missing scientific input witnesses are blocking defects.

## Verification and scope

Use hand-derived fixtures for haplotyped, manual-only, analyzed-unresolved, empty-placeholder and genotype-only exports; compare common call slots and colors, zero/unknown, stable identities, annotations and exact filter masks. Exercise production GUI capture and CLI workflow paths, including ONT. Validate real Biomere2 data only on disposable copies and retain a read-only checksum witness for the user's original project. Inspect rendered workbook layout. Test shared recovery after removing lifecycle consumers.

Work in the existing `codex/excel-three-sheet-layout` worktree. Preserve all unrelated worktrees and local changes. This approval covers implementation and verification; do not merge, push, publish, or remove the worktree without subsequent authorization.

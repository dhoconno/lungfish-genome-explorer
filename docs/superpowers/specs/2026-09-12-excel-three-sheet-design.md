# Three-sheet Excel viewing and reviewed editing

Date: 2026-09-12
Status: Proposed detailed design for user review; no implementation yet.

## Approved direction

Both filtered Excel and current.xlsx contain exactly three worksheets, in order:
Genotype Matrix, Haplotype Calls, Export Metadata. There are no hidden extra
worksheets. current.xlsx includes all evidence and remains two-way editable,
with changes reviewed in LGE. Filtered Excel remains a one-way snapshot of the
settled LGE filters. The user explicitly confirmed retaining two-way editing.

Both matrix sheets start with full, colored H1/H2 calls for every exported
locus. These calls must agree with Haplotype Calls, including homozygotes,
manual swaps, unresolved slots, and errors. Audit/history and original data
remain in the LGE bundle; removing worksheets does not delete their source data.

## Approach and alternatives

Recommended: one shared three-sheet presentation, editable H1/H2 values in
Haplotype Calls, and structured Excel Notes on matrix cells for review/comment
edits. This preserves the matrix shape without a second large editing table.

Moving the old Edit Calls/Edit Matrix tables below the visible data would keep
three sheet names but duplicate data and preserve the navigation burden.
Hiding those sheets would violate the exactly-three-sheet requirement. Neither
is proposed. Editing raw counts is not a supported alternative.

## Shared presentation

Use a shared workbook presentation writer consumed by both production export
paths, rather than patching the legacy Full Sequencing Results template. Inputs
are an explicit workbook role, revision-bound matrix projection, effective call
projection, annotations, resolved haplotype colors, and provenance context.

For filtered Excel, use the captured visible sample/locus/row ordering and cell
mask. A hidden one-read cell cannot return because another sample retains that
row. For current.xlsx, construct the equivalent projection without visual
filters, retaining the full authoritative evidence roster and annotations.
Visual filters never rerun haplotype inference.

Genotype Matrix has sample headings, then two labeled rows per exact exported
locus (H1 and H2), then the genotype table. Freeze the sample headings,
haplotype band, and allele identity columns. Apply table filtering only to the
genotype table, not the haplotype band. Do not recreate legacy duplicate DQA/DQB
or DPA/DPB rows when LGE displays grouped DQ/DP, or omit DR via DRB alias logic.

Haplotype Calls uses the same common columns in both roles: sample, locus,
effective H1/H2, slot status/source, pipeline H1/H2, and comments. The matrix
band references these effective calls using internal, generated formulas;
protected references and value-dependent coloring keep it synchronized during
Excel editing. Generated files must contain valid initial cached display
values as well as recalculation settings. No macros or external links.

Resolve colors from LGE's active haplotype definitions/palette, including color
overrides; do not introduce a separate M-number color map. Both call views use
the same color lookup. Preserve readable foreground/background contrast and
textual status information; color is not the only indicator.

Export Metadata records role, scope, actual filters or “all evidence,” source
revision, and concise viewing/editing instructions. It is not an audit dump.
Both roles have the same structural schema; role, scope, editability, and
role-specific instructions differ intentionally.

## Editing interaction proposed for approval

In current.xlsx, edit H1/H2 directly in Haplotype Calls. The matrix band is a
linked display, not another competing editing surface. Beside the call details,
provide per-slot action dropdowns: “Use entered call” (default) and “Use pipeline
call.” The latter explicitly removes a manual override. A nonempty changed
call proposes an override; an unchanged call proposes nothing. An accidentally
blanked nonempty call produces an actionable validation error, not a deletion.
Selecting pipeline mode queues a reset for LGE review; both Excel call views
continue to show the entered value until acceptance and regeneration. Label
the dropdown as an import action so it is not mistaken for an immediate
recalculation. The same action fields exist but are locked/inactive in filtered
snapshots.

Matrix read-count cells remain immutable. Use traditional Excel Notes, not
threaded collaboration comments, for a clearly delimited editable block with
review operation/value and comment operation/value. Operations are keep, set,
and clear; unchanged default blocks propose nothing. Review values are
false-positive or false-negative. Users can add a documented block to a cell
without an existing Note; keep the brief template in Export Metadata. Preserve
existing human comments separately from generated evidence text. Row comments
attach to allele labels, sample comments to sample headings, and cell comments
to evidence cells. Cell reviews require exact cell identities.

Removing a Note or its edit block never clears a stored annotation. Require an
explicit clear operation. Unknown syntax or changes to generated evidence text
produce an actionable error; do not guess. Plain annotation text, including
formula-like text, is always stored as literal text, never executed.

FP requires attested positive raw support. FN requires attested exact zero;
absent or ambiguous evidence is not zero. Cells unavailable for authoritative
review remain ineligible. Existing legacy H1/H2 calls without raw baselines
remain read-only in Excel, with instructions to use LGE for those assignments.

## Import, migration, and safety

Version the editing schema. Keep trusted IDs, expected scientific values,
approved internal formula structure, source witnesses, and editable target
mapping in the existing bundle-controlled baseline, not extra worksheets.
Stable identity fields within the three sheets may be protected/hidden columns;
row position alone is never an identity. This is presentation protection, not
a security boundary: the importer independently validates all permitted edits.

Preserve current stale-source detection, no-clobber generation admission,
review-before-apply, transactional publication, immediate save, inference
refresh, recovery evidence, and accepted-edit retry behavior. Reject modified
counts, unknown/duplicate/missing identities, changed formulas, external links,
or schema tampering without partial application. Formatting changes alone must
not invent scientific edits. Reordering must retain exact identities and valid
internal references or fail clearly rather than retarget an edit.

Retain import support for outstanding, baseline-attested old-schema workbooks.
Never overwrite unreviewed edits during migration. After review/acceptance,
regenerate current.xlsx into the new schema. Original source workbooks, audit,
annotation history, and review evidence remain in the bundle and accessible
through existing LGE interfaces. Check those access paths before removing any
Excel-only discovery route.

Every scientific export/import records workflow/version, exact argv or
reproducible command, options and resolved defaults, runtime, input/output
paths, checksums/sizes, exit status, wall time, and useful stderr. Retain exact
reviewed workbook bytes and baseline; receipts reference final stored payloads.
Missing provenance blocks completion.

## Acceptance

- Exactly three worksheets in both roles, including no hidden extras; matching
  schema and no unfiltered companion-sheet leakage.
- Compare every matrix-band slot with Haplotype Calls and the LGE projection:
  all loci, homozygotes, swaps, explicit absence/errors, grouped/split loci,
  customized colors, and filtered scopes. Test initial caches and recalculation.
- Minimum-read cases 1/4/5/6 and mixed-support rows, percentage filters, search,
  manual visibility, FP/FN, comments, and export immediately after filter edits.
- Direct call edit and explicit reset, structured review/comment set/clear,
  accidental blanks/deleted Notes, raw-count tampering, formula injection,
  stale revisions, no-clobber, rollback, and save/reopen after accepted changes.
- Old-schema pending edits survive migration; legacy manual-only limitations
  remain explicit. Verify source data and audit/history remain accessible.
- Test real production writers/importer and visually inspect generated files.
  Use a disposable whole-project copy for private-cohort QA; never modify the
  supplied original. Report Excel-native checks separately from library checks.

## Scope and next step

This replaces workbook presentation and its editing interface, not biological
calling rules or unrelated Inspector controls. After detailed-design approval,
write the implementation plan, establish a tested baseline, and use bounded
specialist implementation/review tasks with Astra oversight as requested.
Preserve all unrelated worktrees. A new Preview release requires release gates
after implementation; no release or application changes occur in this design
step.

# LGE–Excel parity and unified export interface

Date: 2026-09-11
Status: Written specification for user review; implementation not started.

## Approved direction and latest refinement

Keep two distinct workbook roles, accessed through one Inspector button,
**Export to Excel…**. The user approved the two-role direction and requested a
choice dialog with brief explanations rather than two competing export buttons.
Both workbooks must show all effective H1/H2 calls displayed in LGE, including
homozygous calls at every locus. A homozygote shown twice in LGE must appear
twice in Excel; genuinely unresolved slots must not be filled by Excel-only
inference.

## Why two roles

A single filtered editable workbook makes absence ambiguous: a blank may mean
hidden evidence, unresolved evidence, or an intended edit. Keep the full-evidence
editable workbook distinct from a one-way visible-view snapshot. One dialog
provides discovery without combining their data contracts. Retaining separate
Inspector export buttons was considered but rejected in favor of the user's
simpler interface.

## Inspector and dialog

Replace the existing separate current-workbook and filtered-pivot launch controls
with one Excel section and one **Export to Excel…** button. The dialog offers:

- **Filtered view** (default): “Share what you see in LGE, with the current
  filters, haplotype calls, and annotations. Changes in this file do not return
  to LGE.”
- **Editable workbook — current.xlsx**: “Work with all evidence in Excel,
  including reads hidden by LGE filters. Supported edits can be reviewed and
  imported back into LGE.”

The filtered choice shows the settled filter summary, including minimum reads,
minimum percent and its denominator, sample/locus scope, and visibility/search
restrictions. The primary action becomes **Export…** or **Open in Excel** for
the selected role. Cancel has no file or project side effects.

The same Inspector section shows the current workbook's synchronization status
and a link to the most recent filtered export. When external edits exist, show a
contextual **Review Excel Changes…** action. Do not add another permanent export
button. Report export progress and actionable errors there. Do not advertise
editable round-trip behavior while the production action only opens an immutable
snapshot.

## Data authority and workbook contents

Capture a typed, revision-bound export state from the settled LGE presentation.
It includes stable sample/locus/allele identities, ordering, visible-cell values
and masks, full effective haplotype slots, review dispositions, comments, and
source revision. Extend the existing projection contract with backward-compatible
decoding rather than creating a second independent interpretation of the view.

Both workbook writers consume the same effective haplotype-call authority. Remove
legacy writable-locus omissions (including DR/DRB), preserve distinct locus
identities where LGE distinguishes them, and eliminate writer-only H2 inference.
Displayed homozygous H1/H2 values must survive all exports, regeneration, and
reopening. Visual filters must not rerun biological inference or change calls.

The filtered workbook contains a Genotype Matrix sheet and a Haplotype Calls
sheet for the visible sample/locus scope, plus clearly labeled filter/provenance
metadata. Matrix cells match the corresponding LGE matrix, not a separately
thresholded raw-data reconstruction. Below-threshold evidence must not reappear
in companion data sheets. Preserve visible false-positive/false-negative markers,
comments, manual overrides, and relevant display styling. Haplotype calls remain
the effective LGE calls for that scope, even when a visual filter hides some of
their underlying evidence. Do not invent additional scope from scroll position.

The editable workbook retains all evidence independent of visual filters, plus
complete effective haplotype calls and annotations. Raw observations are not an
editable scientific input. Clearly distinguish supported editable fields from
read-only evidence and derived display fields.

## Safe supported Excel editing

Supported edits are manual H1/H2 overrides, matrix false-positive/false-negative
review dispositions, and comments. Reuse sidecar annotation semantics and the
existing immediate-save/recomputation path; importing an edit must have the same
effect as making it in LGE. Do not import raw read-count edits as observations.

Use stable identities and a baseline revision/hash, not row positions. Detect
external changes before regenerating current.xlsx, preserve the edited file, and
present supported changes for review. Reject duplicate/unknown identities,
modified evidence, invalid values, and stale-base conflicts without partial
application. Unchanged blanks are not deletions; clearing an override must be an
explicit supported operation interpreted against the baseline. After approval,
apply the accepted edit set transactionally, save immediately, and refresh the
viewer and workbook. Preserve the input workbook revision for recovery.

## Confirmed findings and remaining diagnostic work

Source review confirmed that current-workbook serialization excludes DR/DRB,
contains an independent homozygosity heuristic, and that filtered-pivot export
retains other unfiltered sheets. The production current-workbook view action
opens an immutable copy, and the inspected import path does not complete semantic
Excel-to-LGE reconciliation.

The matrix projection already removes below-threshold cells. Therefore the exact
reported one-read leak in the target pivot is not yet reproduced; do not describe
raw surviving-row supports as its confirmed cause. Reproduce with an untouched
copy of the Biomere2 cohort, identify the sheet/cell and captured filter state,
and add a failing regression test before fixing that path. Also test export
immediately after changing a numeric filter to detect unsettled-draft races.

## Provenance and failure handling

Every scientific export/import/transformation records workflow and tool version,
exact argv or reproducible command, visible options and resolved defaults,
runtime identity when applicable, input/output paths, checksums, sizes, exit
status, wall time, and useful stderr. Retain projection/filter state, source
revision, and reviewed edit input. Bundle provenance must point to final stored
payloads, not just staging files. Missing provenance blocks publication.

Capture filters, calls, annotations, and revision atomically after committing
valid UI drafts. Abort on invalid drafts or inconsistent revision rather than
silently exporting a different state. Write to staging and publish atomically;
failure must preserve the last valid workbook and project.

## Acceptance and delivery

1. Verify counts 1/4/5/6 at minimum 5, including a row with one read in one sample
   and ten in another. Filtered cells match LGE; current.xlsx retains all evidence.
2. Verify every visible locus and exact H1/H2 value, especially homozygotes,
   DR/DRB, split/grouped DQ/DP, manual swaps, unresolved slots, and error calls.
3. Verify search, sample/locus selection, percent denominators, ordering, FP/FN,
   comments, and immediate filter-change export. No unfiltered companion leakage.
4. Verify supported Excel edit round trips, reordered rows/columns, stale-base
   conflicts, evidence tampering, duplicate IDs, rollback, and save/reopen parity.
5. Verify a single Inspector export entry point, understandable dialog copy,
   keyboard/accessibility behavior, cancellation, progress, and clear role labels.
6. Verify final-payload provenance and inspect generated workbooks visually and
   programmatically using a copy of the reported cohort; do not mutate the source.

After written-spec approval, prepare an implementation plan with bounded export,
round-trip, and UI tasks. Use specialist review and smaller delegated tasks as
requested, with integration review before merge. Run baseline and regression
tests in the isolated worktree before implementation/integration. Follow the
release skill for any subsequent Preview publication; merge and remove only this
task's worktree after successful verification. Preserve every unrelated worktree.

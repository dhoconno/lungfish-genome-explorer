# miSeq Synchronized Haplotype and Genotype Views

**Date:** 2026-08-03  
**Status:** Approved for implementation and expert review

## Objective

For a completed **miSeq amplicon MHC genotyping** analysis that includes
haplotyping, make the haplotype-call presentation the default viewport and let
analysts switch to the same genotype matrix used for full-length MHC genotyping.
Both presentations must show the same effective haplotype calls and must remain
synchronized when an analyst edits or clears a haplotype override.

The miSeq viewport will expose only two primary presentations:

1. **Haplotype Calls**
2. **Genotype Matrix**

The existing **Review** and **Audit** viewport tabs will be removed for these
results. Review controls remain available in the selected-item detail pane and
Inspector. Audit records and scientific provenance remain durable and
inspectable through the bundle and Inspector; only the redundant viewport tab
is removed.

Removing those viewport destinations must not remove their useful commands or
information. Call evidence, override editing, Confirm, Needs Review, Skip/Next,
and status actions move into the Haplotype Calls selection detail and Inspector.
Audit Timeline, current-workbook status/actions, artifacts, provenance, AI
haplotyping, and export actions remain in their existing Inspector or toolbar
locations. They are not duplicated as primary viewport presentations.

## Current State

Haplotyped miSeq bundles currently have two different matrix concepts:

- the normal haplotype-call outline/tape presentation;
- `GenotypeHaplotypeDefinitionMatrixView`, which presents diagnostic alleles
  from the selected haplotype definition set.

The full-length-style matrix is `GenotypeComparisonMatrixView`. It already
supports genotype rows by sample, matrix filtering, annotations, comments,
false-positive and false-negative review, row and column visibility, and a
disclosable haplotype band for genotype-only manual assignments. Haplotyped
miSeq results currently route Matrix mode to the diagnostic-definition matrix
instead of this comparison matrix.

Automated miSeq haplotype calls are stored in the result's
`GenotypeHaplotypeAnalysis`. Analyst corrections are stored as audited
overrides in `GenotypeAnnotationSidecar` through `GenotypeAnnotationStore`.
Genotype-only manual assignments use a separate
`ManualHaplotypeAssignment` record. Haplotyped miSeq results must not copy their
automated calls or overrides into the genotype-only manual-assignment format.

## Scope

### Included

- Haplotyped miSeq results default to **Haplotype Calls** when the bundle has no
  saved view preference.
- A two-choice viewport selector switches between **Haplotype Calls** and
  **Genotype Matrix**.
- **Genotype Matrix** uses `GenotypeComparisonMatrixView`, with the same rows,
  columns, filters, annotations, comments, accessibility behavior, and
  performance characteristics as the full-length MHC genotype matrix.
- The matrix haplotype band shows effective automated miSeq haplotype calls,
  including analyst overrides.
- Haplotype edits initiated from either presentation use the same audited
  override mutation path and refresh both presentations immediately.
- Clearing an override restores the pipeline-produced call in both
  presentations.
- The selected view is remembered per analysis bundle.
- Review and Audit are removed from the haplotyped miSeq viewport selector.
- Existing provenance and annotation audit records remain intact.

### Excluded

- Changing the miSeq workflow recipe, thresholds, reference selection,
  genotype calling, or haplotype calling.
- Changing how haplotype definition sets are imported, evaluated, or stored.
- Creating a new diagnostic-allele import/export format.
- Converting automated haplotype calls into manual haplotype assignments.
- Removing audit entries, provenance artifacts, or Inspector access to them.
- Changing non-miSeq haplotyping presentations as part of this feature.
- Changing genotype-only matrix behavior except where shared code must remain
  compatible.

## View Selection and Layout

### Applicability

The two-view presentation applies when all of the following are true:

- the result workflow kind is `miSeqAmpliconMHCGenotype`;
- the workflow mode is haplotyped;
- the completed bundle contains a usable `GenotypeHaplotypeAnalysis`; and
- the result is not being treated as genotype-only.

A usable analysis contains at least one uniquely keyed sample/locus call whose
two slots can be resolved into the effective projection. Empty or structurally
malformed analyses are not usable. Legacy bundles without the typed workflow
kind or haplotyped mode do not opt into the new policy merely because an assay
name resembles miSeq.

Genotype-only miSeq results continue to open directly in the genotype matrix.
Other workflow kinds retain their existing view rules.

### Selector

The miSeq haplotyped viewport replaces the current Summary/Review/Audit lens
control with one segmented selector:

- **Haplotype Calls**
- **Genotype Matrix**

There is no Review or Audit segment. The View Inspector reflects the same
selection and may provide the same two choices, but it must not create a second
independent state.

If no saved preference exists, **Haplotype Calls** is selected. An explicit
choice is saved in `GenotypeAnnotationSidecar.Settings` and restored when the
same bundle is reopened. Existing `outline` preferences map to Haplotype Calls;
existing `matrix` preferences map to the new full-length-style Genotype Matrix.
For a read-only bundle, switching is session-only and does not present a save
error. Stale Review/Audit/unknown state normalizes to Haplotype Calls. If the
analysis is unusable, the controller selects Genotype Matrix without overwriting
the saved preference, disables Haplotype Calls with accessible explanatory help,
and shows a persistent explanation rather than an empty view.

One result-scoped `GenotypeResultPresentationPolicy` supplies applicability,
available choices, labels, default/fallback, normalization, and Inspector state.
The viewport and Inspector must consume this one policy and one
`summaryViewMode` value; they must not maintain independent selection state.

### Haplotype Calls

Haplotype Calls retains the existing miSeq haplotype outline/tape presentation,
sorting, cohort filtering, selection, effective call status, and detail
presentation. It no longer routes analysts through a separate Review lens.
Selecting a sample or locus exposes the existing call evidence and override
controls in the detail pane and Inspector.

No selection shows Cohort Summary. A sample selection shows the sample summary
and all effective calls. A locus/slot selection shows call evidence and the
override editor. Needs Review remains an explicit Smart Cohort rather than
being activated merely by entering this presentation. Confirm, flag,
Skip/Next, and Edit Calls remain available for the appropriate selection and
retain their keyboard commands outside text editing.

### Genotype Matrix

Genotype Matrix renders `GenotypeComparisonMatrixView` from the bundle's raw
genotype calls and reviewable candidate rows. It must include the same useful
matrix capabilities as full-length MHC genotyping, including:

- read-support cells by sample;
- known, extension, novel, partial-extension, and other reviewable rows when
  present in the bundle;
- search and read-support filters;
- row and column selection and visibility commands;
- comments and false-positive/false-negative annotations;
- accessible text sizing and matrix keyboard/context-menu behavior;
- the disclosable haplotype band aligned to sample columns.

In this mode the band is titled **Haplotype Calls (N loci)**. Its ordered loci
come from the same included-locus projection as Haplotype Calls. It uses a
neutral presentation model containing sample, locus, H1/H2 value, per-slot
status, source (pipeline or analyst override), editability, tooltip, and
accessibility text. It never displays “Manual haplotypes” and never reads or
writes `ManualHaplotypeAssignment`. Genotype-only results retain their existing
manual-assignment band unchanged.

A haplotype-band cell is a distinct target identified by sample, locus, and
slot. Activating it opens the same call evidence and override editor as
Haplotype Calls. A sample-column header retains existing matrix column
selection semantics; it does not silently choose a locus or slot. Row,
genotype-cell, and multi-target selections retain existing annotation and
review behavior.

The diagnostic-definition matrix is no longer a viewport destination. Its
underlying definition data remains available to the haplotype evaluator and
call evidence UI.

## Shared Effective Haplotype Projection

Both views consume one controller-owned, immutable effective haplotype
projection. It is built in O(calls + overrides), indexed by sample/locus/slot,
and carries the active analysis/revision/definition identity. For
each sample, locus, and H1/H2 slot, the projection resolves:

1. the pipeline-produced call from the active `GenotypeHaplotypeAnalysis`;
2. the latest structurally valid analyst override from
   `GenotypeAnnotationSidecar` (latest parseable timestamp, with stable sidecar
   order as the timestamp tie-breaker);
3. the per-slot and reduced locus display status, including unresolved/error
   states;
4. whether the displayed value is automated or overridden.

The projection is the only source used to build both the haplotype outline and
the genotype matrix haplotype band. It is derived data and is not written as a
second scientific artifact.

For applicable haplotyped miSeq results, any legacy
`ManualHaplotypeAssignment` records are ignored for effective display/editing
but preserved byte-for-byte. Non-miSeq legacy behavior remains unchanged.
Haplotyped miSeq calls and corrections use only call-override records. This
prevents two independently editable representations of the same call.

An override whose recorded base analysis identity differs from the active
analysis is shown as stale and does not silently replace a new pipeline value.
The locus status reducer must not turn the whole locus into `called` because
only one ambiguous/error slot was overridden: each slot keeps its own status,
and the locus remains unresolved while either required slot remains unresolved.

## Editing and Synchronization

### From Haplotype Calls

Existing sample/locus override controls route through one controller method,
`commitEffectiveHaplotypeMutation`, backed by one store-level atomic batch
mutation. After a successful mutation, the controller rebuilds the effective
projection and refreshes both the visible Haplotype Calls presentation and the
matrix haplotype band.

### From Genotype Matrix

Activating a haplotype-band value exposes the same effective haplotype editor
in the detail pane. A single selected sample column may expose a Haplotype Calls
section that requires an explicit locus and slot choice. Saving or clearing
from this presentation
uses the same controller/store transaction, author identity, reason/rationale
requirements, and validation as Haplotype Calls. It does not call the
genotype-only manual-assignment APIs. The destructive action is labeled
**Restore Pipeline Call** and identifies the value that will return.

The transaction boundary is one user Save action. If one Save changes both H1
and H2, the store validates all targets before writing, publishes the sidecar
and provenance once, and writes one audit entry per changed slot under one
operation ID and timestamp. Either every changed slot commits or none does.
Clearing an absent override returns `didChange == false` and creates no audit,
provenance, workbook, or Inspector notification. A clear records the active
pipeline value being restored and a deterministic “Restore pipeline call”
rationale so audit and display cannot disagree after a newer analysis.

### Mutation result

A successful edit must:

- update the annotation sidecar atomically;
- append the existing audit entry with author, before/after values, locus,
  sample, slot, rationale, and timestamp;
- invalidate the effective haplotype projection;
- refresh both views without reopening the bundle;
- mark `current.xlsx` stale and schedule the existing workbook update behavior;
- notify the Inspector of the new annotation state.

A failed edit must leave both views on their prior shared projection and show a
plain-language error. It preserves the draft, selection, and focus. Read-only
bundles display calls but disable mutation, and the store rejects direct or
programmatic mutation with a typed read-only error before changing memory.
Publication or stale-revision failure rolls the in-memory sidecar, audit,
projection, workbook state, and durable bytes back to their exact prior state.

Every call target in both presentations is reachable with Full Keyboard Access
and VoiceOver. Space/Return and AXPress perform the same selection as a pointer
click. Accessible names include sample, locus, haplotype 1/2, effective value,
status, and pipeline/override source; color is never the only signal. Successful
edits preserve focus and announce “Override saved” or “Pipeline call restored.”

## State and Compatibility

The controller retains one view-selection value. The viewport selector and
Inspector are two controls for that same value. Switching views does not alter
calls, filters, annotations, or workbook contents.

Existing bundles need no migration of scientific data. Existing view
preferences retain their raw values and receive the new presentation meaning.
Existing override and audit schemas remain authoritative. The implementation
may add neutral presentation models for the shared haplotype band, but it must
not rewrite prior annotations merely because a bundle is opened.

Quick sample search and Smart Cohort filtering are shared between
presentations. Matrix allele/read/visibility filters and matrix scroll state are
matrix-local and retained while away. Haplotype Calls sorting and scroll state
are local to that presentation. Switching preserves the selected sample and
locus when representable and never changes a call or review status.

The implementation must preserve behavior for:

- miSeq genotype-only analyses;
- full-length ONT genotype-only analyses;
- full-length or other workflows whose viewport rules are outside this scope;
- read-only and older bundles with no saved view preference.

## Provenance and Traceability

Removing viewport tabs does not remove traceability. Every scientific workflow
continues to write its existing provenance. Every analyst haplotype mutation
writes annotation audit records and an override-specific reproducibility
envelope, then marks the workbook projection stale. The selector itself is a
view preference and is not a scientific call mutation.

The atomic override transaction must record the app/workflow name and version,
an exact durable replay command or equivalent replay payload, sample/locus/slot
targets, baseline/before/after values, reason and rationale, author, active
analysis/definition identity, resolved defaults, final input/output paths,
prior and output checksums and sizes, runtime identity, exit status, wall time,
and useful error detail. It must never identify a temporary staging path as the
final scientific output. The call-override replay operation must be verifiable
in tests in the same manner as matrix and manual-haplotype annotation replay.

No new scientific-data creation or transformation is introduced by switching
views. If implementation changes any export or workbook projection, its output
must continue to include the exact workflow/tool version, resolved options,
inputs and outputs, checksums, sizes, exit status, wall time, and useful stderr
as required by Lungfish provenance policy.

## Performance and User Experience

- Opening the default Haplotype Calls view must not eagerly construct the full
  genotype matrix.
- The genotype matrix is configured lazily on first selection and then reused.
- Switching views must not rerun haplotype analysis or reload the workbook.
- Override refreshes update the shared projection and affected sample band
  content without rebuilding unrelated genotype rows. If the matrix has not
  yet been configured, the mutation does not configure it; first selection
  receives the newest projection.
- Matrix virtualization, column sizing, text-size preferences, and scroll
  position preservation remain active.
- The selector uses plain labels and exposes an accessibility role, value, and
  help text describing the two presentations.
- Empty or malformed haplotype analyses fall back safely to the genotype matrix
  with a persistent accessible explanation; they do not expose blank Review or
  Audit tabs or overwrite the saved preference.
- On a retained-demultiplexing-size fixture, default Haplotype Calls opening
  performs zero matrix configurations. Warm presentation switches must meet
  p95 <= 16.7 ms and p99 <= 33.4 ms. One override may invalidate one sample's
  band content but performs zero genotype base rebuilds, column rebuilds,
  haplotype reruns, workbook reloads, or unrelated-row reloads.

## Verification Requirements

Automated tests must prove:

1. haplotyped miSeq defaults to Haplotype Calls without a saved preference;
2. the viewport exposes exactly Haplotype Calls and Genotype Matrix;
3. Review and Audit are absent and cannot be selected through notifications or
   restored stale state;
4. switching to Genotype Matrix shows `GenotypeComparisonMatrixView` and not
   `GenotypeHaplotypeDefinitionMatrixView`;
5. raw genotype and candidate rows appear with expected read support;
6. the matrix haplotype band contains automated effective calls;
7. an override initiated from Haplotype Calls before lazy matrix construction
   appears when the matrix first opens;
8. an override initiated from Genotype Matrix while Haplotype Calls is hidden
   updates Haplotype Calls, survives controller recreation, and leaves unrelated
   samples/loci unchanged;
9. clearing from either surface restores the active pipeline call in both views;
10. a two-slot Save is atomic, creates one operation with one audit entry per
    changed slot, one provenance publication, one workbook-dirty event, and one
    Inspector notification, with no manual-assignment records;
11. saved view preference restores for the same bundle;
12. read-only bundles show synchronized values with disabled editing and the
    store rejects mutation without changing memory, sidecar bytes, provenance,
    audit, workbook state, or notifications;
13. genotype-only and non-miSeq viewport behavior remains unchanged;
14. duplicate/malformed/stale overrides resolve deterministically; legacy
    manual assignments are ignored-but-preserved for applicable miSeq and keep
    their existing behavior elsewhere;
15. stale-revision, annotation-publication, and provenance-publication failures
    leave both projections and every durable byte/count unchanged;
16. successful save/restore marks current.xlsx stale once and the next workbook
    publication agrees with both views; switching, preference persistence,
    failure, read-only attempts, and no-op restore do not mark it stale;
17. viewport and Inspector control one state without feedback loops across
    same-bundle restore, different-bundle isolation, stale Review/Audit ingress,
    legacy preferences, unusable analysis fallback, and read-only sessions;
18. Haplotype Calls and band targets pass keyboard/AXPress, focus-retention,
    text-size, high-contrast, and non-color status verification;
19. view switching and targeted override refresh meet the numeric and counter
    performance budgets above with the release performance gate enabled; and
20. Debug and Release products build, the shipped Release app/DMG pass signing,
    notarization, stapling, mounting, and launch checks, and the published
    Sparkle entry's version/build/URL/length/EdDSA signature/notes match the
    released bytes and clean-main commit.

## Release Requirements

The release notes will describe the new default miSeq haplotype presentation,
the full-length-style genotype matrix option, synchronized editing, and removal
of Review/Audit viewport tabs in narrative form. The release must include all
verified pending fixes on the release branch, publish a signed and notarized DMG
and Sparkle appcast entry, and leave `main` clean with no stale feature
worktrees or branches.

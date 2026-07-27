# Project Storage, Excel False Negatives, and Manual Haplotype Assignments

**Date:** 2026-07-26  
**Status:** Approved for implementation

## Objective

Reduce genotype-project storage growth without weakening recovery or scientific
traceability, make false-negative review annotations visible in Excel even when
the genotype has no cohort-wide read support, and add audited manual haplotype
assignment editing to genotype-only MHC matrices.

The changes must preserve the existing viewport and Inspector behavior for
analyses where haplotyping was performed.

## Confirmed Current-State Findings

### Retired workbook generations

`ONTGenotypeWorkbookUpdateRecovery.removeProvenTransactionRoot` currently moves
the entire retired transaction generation to a sibling directory named
`.lungfish-workbook-generation-archive-*`. A workbook update therefore retains a
complete copy of the `.lungfishgenotype` bundle even though the active bundle
already contains:

- the prior `current.xlsx` under `artifacts/workbooks/revisions/`;
- the current and prior workbook descriptors and checksums;
- workbook revision provenance;
- the annotation sidecar and audit history.

In the inspected project, the retained full-bundle generations account for
approximately 13 GB while the workbook revisions themselves are approximately
half a megabyte each.

### Workflow staging

Full-length ONT MHC genotyping creates sibling
`.<bundle>.run-staging-<UUID>` directories and associated cohort-alignment and
candidate-artifact work directories. The current run cleans its work on the
normal path, but there is no comprehensive reclamation pass for abandoned
legacy staging. Failed or interrupted debug runs can therefore leave copied and
filtered FASTQs occupying many gigabytes.

### False-negative workbook projection

False-negative formatting is currently a thick black border applied by both
workbook-generation paths. The reported annotation is nevertheless recorded as
invalid because the workbook matrix contains only genotypes observed in at
least one sample. The LGE viewport can select a reference genotype with zero
support across the cohort, but no corresponding workbook row or target cell
exists. The annotation sheet reports:

> No workbook cell matches the exact review target.

### Genotype-only column details and manual assignments

The annotations sidecar already stores audited `ManualHaplotypeAssignment`
records keyed by sample, locus, and H1/H2 slot. The workbook already provides
manual-assignment rows in this order:

1. MHC-A Haplotype 1 / Haplotype 2
2. MHC-B Haplotype 1 / Haplotype 2
3. MHC-DRB Haplotype 1 / Haplotype 2
4. MHC-DQA Haplotype 1 / Haplotype 2
5. MHC-DQB Haplotype 1 / Haplotype 2
6. MHC-DPA Haplotype 1 / Haplotype 2
7. MHC-DPB Haplotype 1 / Haplotype 2

Full-length genotype-matrix column selection currently bypasses the existing
sample-detail renderer, leaving the detail pane empty for column-only
selections.

## Scope

### Included

- Automatic removal of future retired workbook generations after a transaction
  is durably committed or safely rolled back.
- Automatic cleanup of current-run work directories when they are no longer
  required, retaining compact failure diagnostics and honoring an explicit
  Keep Intermediates choice.
- A project-scoped storage preview and cleanup workflow for legacy hidden
  archives, orphan staging, and project temporary files.
- A durable provenance receipt for each user-requested storage cleanup.
- Annotation-only workbook rows for false-negative targets missing from the
  workbook projection.
- A reliable `FN` cell presentation plus border for false-negative annotations.
- Manual haplotype display and per-sample editing for genotype-only MHC
  analyses whose reference/result has no haplotyping information.
- Analysis-local label autocomplete and copying another sample's assignments
  into the current sample's unsaved draft.
- Audit and provenance for all manual assignment additions, changes, removals,
  and copies.
- Performance and accessibility regression coverage.

### Excluded

- Changing full-length ONT or miSeq scientific recipes, thresholds, or call
  generation.
- Content-addressed storage, binary deltas, or a general-purpose versioned
  filesystem.
- Bulk assignment editing across multiple selected samples.
- Changing the viewport or Inspector for workflows where haplotyping was
  performed.
- Automatically resolving manual labels against an external allele or
  haplotype database.
- Permanently deleting legacy project data without a preview and explicit user
  confirmation.

## 1. Storage Lifecycle

### 1.1 Workbook transactions

The workbook transaction retains both generations only while they are needed
for crash recovery and manual-save conflict resolution. Once recovery authority
has proven one of the following terminal states, the retired generation is no
longer part of the project:

- the new manifest and workbook are durably committed;
- the prior generation was safely restored;
- an unpublished prepared generation was safely discarded.

At that point, cleanup atomically detaches the validated transaction root rather
than retaining it as a permanent full-bundle archive. While holding the
publication lock and authenticated recovery authority, Lungfish:

1. exclusively renames the proven root in the same parent directory to
   `.lungfish-workbook-cleanup-pending-<transactionID>`;
2. fsyncs the parent directory;
3. durably records the detached cleanup state;
4. removes the transaction marker and attestation only after the committed or
   restored generation and cleanup state are durable;
5. recursively removes only the detached cleanup-pending quarantine.

The compact workbook revision, manifest descriptors, audit entries, and
provenance already inside the surviving generation remain authoritative.

Cleanup must retain the existing identity and authority checks. It must never
follow symlinks, remove an unbound directory, or act when final/staging
generation state is ambiguous. A crash after retired-generation removal but
before marker removal remains recoverable through the existing
committed-generation-plus-missing-staging branch.

Recursive deletion never runs against a live transaction root. If deletion of
the detached quarantine fails or the app crashes during traversal, recovery
recognizes the cleanup-pending identity and retries without making either live
generation ambiguous. The published result remains valid, but the cleanup
failure is recorded and surfaced as a storage warning.

### 1.2 Workflow work directories

Successful full-length ONT MHC and genotype-only MHC runs remove their staging,
cohort-alignment work, candidate-artifact work, and generated workflow
intermediates after all required final artifacts and provenance are durable.

On failure:

- compact logs, stderr, failure provenance, resolved options, runtime identity,
  and input/output descriptors remain;
- copied or derived FASTQ work products are removed by default;
- an explicit Keep Intermediates option retains diagnostic work and is recorded
  in provenance;
- cleanup failures are appended to the failure report with their exact paths
  and errors.

Keep Intermediates is defined consistently for success and failure. It retains
workflow/checkpoint data only when explicitly resolved true; otherwise large
staged FASTQ payloads are removed after their descriptors and compact
diagnostics are durable. The run receives a UUID, and its failure envelope and
compact diagnostics are stored append-only in project/analysis operation
history. A later run may supersede, but never delete, a prior failure envelope.
Moving explicitly retained intermediates to Trash later writes a linked
disposition/tombstone receipt containing the original descriptors and Trash
destination.

Future staging directories include a small ownership marker containing schema
version, operation/workflow identity, output bundle path, run UUID, process
identity, start time, Keep Intermediates resolution, and relevant lock path.
This allows later storage classification without guessing from a filename
alone.

### 1.3 Legacy orphan classification

A project storage scanner recognizes only exact Lungfish-owned patterns and
classifies, but does not immediately mutate:

- completed `.lungfish-workbook-generation-archive-*` directories;
- `.<bundle>.run-staging-*` directories;
- staging-associated `.cohort-alignment-work` and
  `.candidate-artifact-work` directories;
- the existing project temporary directory.

An entry is default-removable only when the scanner can establish all applicable
conditions:

- the path is a real directory within the open project hierarchy;
- no path component is a symlink or special file;
- the associated workflow or workbook publication lock is not held;
- no live or ambiguous transaction claims the generation;
- a current surviving bundle or durable failure/completion record explains why
  the directory is no longer authoritative;
- the directory is not explicitly retained by a recorded Keep Intermediates
  option.

For a legacy workbook archive to be default-removable, it must contain exactly
one structurally valid nested genotype bundle whose manifest and
`current.xlsx` descriptors map exactly to a retained revision in one
unambiguous sibling live bundle. No live transaction or attestation may claim
it. The transaction ID must agree with a recovery receipt when a receipt exists.
Prepared, rollback, or manual-save-conflict archives without unambiguous
revision mapping remain not removable.

Unknown, ambiguous, lock-held, explicitly retained, or unsafe entries are shown
as not removable, with the reason. Tampered names/content, missing live bundles,
or multiple possible live bundles fail closed. The scanner does not infer
safety solely from age.

### 1.4 Project temporary data

The existing project-open whole-root `.tmp` deletion and age-only periodic
deletion are replaced. Opening a project performs no storage mutation.
Periodic cleanup considers individual owned children through the same
ownership, identity, marker, and lock classifier; unknown, unmarked, or live
entries remain.

Markers used as cleanup authority are atomically and durably written during
directory creation. Creation fails or rolls back if the marker cannot be made
durable. A marker binds the project and directory device/inode, run UUID,
process-start and boot identity, completion state, lock path, Keep Intermediates
resolution, and creating tool/version. PID alone is never authority.

## 2. Project Storage User Experience

### 2.1 Command placement

Replace **File → Clear Temporary Files…** with:

**File → Manage Project Storage…**

Expose the same command in the sidebar context menu only when the single
selected item is the project root. Do not put the primary command in Settings
or an analysis Inspector because the scope is the active project, not the
application or selected bundle.

The command retains the existing project-open enablement rules.

### 2.2 Preview sheet

The command asynchronously scans the active window's project and presents:

**Project Storage — “Project Name”**

The sheet includes a total reclaimable size and checkable categories:

- Completed workbook publication archives
- Orphaned workflow staging data
- Temporary files

Each category discloses individual entries with name, enclosing analysis, last
modified date, and size. When useful, a separate not-removable group explains
active, ambiguous, unsafe, or explicitly retained items.

Only safety-proven entries are selected by default. The sheet reports logical
and allocated sizes, deduplicates hard-linked `(device, inode)` files, and
labels totals as estimated storage moved because Trash does not reclaim space
until emptied and filesystem clones may reclaim less than their logical size.
The destructive button uses the selected estimated allocated total:

**Move 27.4 GB to Trash**

Cancel is the secondary action. Return must not trigger deletion; Escape
cancels. The operation moves each selected entry to Trash using platform
facilities rather than permanently deleting it. Completion distinguishes
removal from disk reclamation:

> 27.4 GB removed from the project. Empty the Trash to reclaim disk space.

Partial failures leave failed items in place and show a per-item result. A
volume that cannot move an item to Trash produces an error and leaves the
original path untouched; there is no fallback to permanent deletion.

### 2.3 Crash-safe cleanup execution

Before moving any selected item, Lungfish creates and fsyncs a cleanup journal
outside every selected root at:

`<project>/.lungfish-operation-history/storage-cleanups/<cleanup-UUID>/`

The journal records each project-relative source, device/inode/type identity,
classification evidence digest, descriptor inventory, intended action, and
state. If this durable journal cannot be created, no mutation occurs.

For every item, execution:

1. acquires the associated workbook/run lock nonblocking and holds it through
   mutation;
2. revalidates classification, containment, type, and device/inode without
   following symlinks;
3. updates and fsyncs the journal;
4. atomically renames the verified source, on the same volume and while still
   holding the lock, to a unique app-owned sibling named
   `.lungfish-trash-pending-<cleanup-UUID>-<item-UUID>`;
5. fsyncs the source parent and journal, thereby detaching the original
   workflow/archive name from any future producer;
6. revalidates the detached directory identity and invokes the platform Trash
   API on that quarantine path;
7. records the resulting Trash destination and fsyncs the journal before
   releasing the lock.

The platform Trash call is path-based only after identity-bound detachment has
removed the race with the authoritative source name. On Trash failure,
Lungfish restores the original name only if that name is still absent and the
original identity/containment remain safe; otherwise it retains and reports the
trash-pending quarantine for recovery. Journals support partial completion and
restart finalization after an app crash. Recovery understands crashes after
detach and immediately before or after the Trash call. A lock acquired after
preview causes the item to be skipped, not raced.

### 2.4 Accessibility

- Categories and entries are native outline/table rows.
- VoiceOver labels include category, count, size, selection state, and safety
  status.
- Byte counts and dates are localized.
- The sheet supports Full Keyboard Access.
- Scan progress is exposed to accessibility and can be cancelled.
- Initial focus is on the heading or results list, never the destructive
  button.

### 2.5 Cleanup provenance

Each confirmed cleanup writes an append-only canonical `ProvenanceEnvelope`
beside its journal under:

`<project>/.lungfish-operation-history/storage-cleanups/<cleanup-UUID>/`

Neither the operation-history root nor any cleanup journal/receipt may be
offered by project-temp or legacy-pattern scans. Each confirmed cleanup receipt
contains:

- tool/workflow name and Lungfish version;
- reproducible argv or equivalent app command identity;
- visible selections and resolved defaults;
- runtime identity;
- project root;
- classified and selected paths;
- a complete pre-move inventory of regular files with relative path, logical
  and allocated size, and SHA-256, reusing attested descriptors where
  available;
- a deterministic aggregate tree digest;
- Trash destinations where available;
- skipped items and reasons;
- start/completion timestamps, wall time, exit status, and errors.

Preview scanning computes sizes but does not hash large payloads. After
confirmation and before mutation, a cancellable preparation phase creates the
descriptor inventory and hashes only descriptors not already attested.
Cancellation or failure during preparation causes no mutation. Receipt/journal
durability failure is blocking. Automatic workflow cleanup appends the
equivalent disposition step using descriptors already captured by workflow
provenance.

## 3. Excel False-Negative Presentation

### 3.1 Annotation-only rows

Before validating matrix reviews, workbook export/update resolves every current
false-negative target against a unique bundle-attested reviewable-row catalog.
The sidecar target is a request, never scientific authority.

Each catalog record contains locus, authoritative call ID and display label,
optional stable ID, row kind, workbook section/sort key, and evidence by
authoritative sample. The selected sample must occur exactly once and have
zero/absent evidence. Creating a cohort-zero annotation-only row additionally
requires zero/absent evidence across every authoritative sample.

The catalog is an immutable, versioned JSON artifact with a declared schema
identifier. New genotype-only runs derive it from the exact run-reference
payload, authoritative sample roster, checksummed genotype-call/evidence
projection, and manifest-attested candidate catalog/artifacts when candidates
are applicable. Every catalog evidence value and observed/unobserved identity
must reconcile exactly against those inputs. The workflow publishes the
catalog inside the result bundle with a manifest descriptor containing relative
path, byte size, and SHA-256. Its generating provenance step records
tool/version, reproducible argv, resolved options, runtime identity, descriptors
for the run reference, roster, call/evidence projection, and applicable
candidate artifacts, output descriptor, exit status, wall time, and errors.

Known/reference targets without stable IDs and candidate targets with stable
IDs use distinct exact-match rules. The workbook revision request passes the
manifest-attested catalog explicitly to the updater; Python never guesses
identity from the sidecar and never consults a currently installed allele
database. A legacy bundle without enough attested authority fails closed. An
optional migration may create the catalog only from retained, checksummed
run-reference and roster inputs and must write its own canonical provenance
step before any workbook update uses it.

When the exact genotype row is absent and the catalog proves a unique valid
zero-support record, the exporter creates an annotation-only matrix row through
a recognized workbook-layout adapter.

For the unified matrix adapter, the row:

- uses an explicit annotation-only `call_type`;
- records authoritative call ID, display name, locus, and stable ID when
  present;
- leaves stable ID blank for known alleles;
- sets occurrence count, sample count, and total cluster reads to numeric zero;
- leaves all sample evidence blank before applying the `FN` presentation;
- records zero observed samples and zero supporting reads;
- is marked as analyst annotation metadata rather than scientific evidence;
- is placed in a clearly labeled **Analyst annotation-only rows** block at the
  end of the matrix and sorted by canonical locus/genotype within that block;
- is constructed from adapter-owned styles rather than copying arbitrary
  neighboring formulas or values.

For recognized generic matrices, the adapter may write genotype, numeric
Total=0, and numeric #Obs=0 only when identity is unambiguous at the columns
available to that format. Unsupported or semantically insufficient layouts
remain invalid.

Adapters own annotation-block placement, ordering, descriptor refresh, and
explicit table/autofilter range updates. Keeping the block at the end avoids
shifting scientific rows, formulas, merged ranges, print areas, and freeze
panes. Blanket `insert_rows` is prohibited because it does not safely maintain
those structures. Newly generated workbooks build the block during table
construction; legacy `current.xlsx` updates use only a recognized adapter. If
a future workbook contains the corresponding real scientific row, the adapter
migrates the annotation to that row and safely removes the managed synthetic
row.

### 3.2 Cell presentation

The selected sample cell contains `FN` and uses:

- `Side(style="mediumDashed", color="FFC65911")` on all four sides, equivalent
  to OOXML `style="mediumDashed"`;
- solid fill `FFFFF2CC`;
- bold font color `FF7F6000`;
- preserved analyst comments through the existing single-comment composition
  mechanism.

The textual marker makes the annotation robust across Excel, Numbers, printing,
grayscale viewing, and accessibility contexts. It is annotation presentation,
not a read count.

False-negative presentation overrides any viewport fill so `FN` remains
legible. It is applied to blank and explicit numeric-zero cells. It never
creates or replaces an Excel comment.

The Matrix Annotations sheet records the review as valid only after successful
exact materialization. The hidden managed review state records schema version,
semantic identity, coordinate, synthetic-row status, original value/font/fill/
border, and the exact expected managed value/font/fill/border.

Both native and openpyxl workbook-revision provenance record the exact
annotation-sidecar revision and SHA-256, catalog schema and descriptor,
adapter/layout version, synthesized semantic row identities and target cells,
resolved precedence/restoration decisions, resulting workbook path/size/
SHA-256, exit status, wall time, and errors. The catalog and sidecar descriptors
are explicit provenance inputs, and the revised workbook is an explicit output.

### 3.3 Clearing and repeat updates

Every update performs these steps in order:

1. restore prior managed presentation and remove safely removable synthetic
   rows;
2. rebuild descriptors and synthesize required rows through adapters;
3. validate authoritative identity/evidence and blank/zero destinations;
4. write validation and audit sheets;
5. apply row, column, and cell styles/comments;
6. apply false-negative presentation last.

Restoration changes a property only if it still equals Lungfish's recorded
managed value. This preserves external Excel edits. Synthetic rows are removed
bottom-up only when their entire current state remains managed. If a synthetic
row contains unexpected user data, formulas, formatting, or comments, it is
left in place, unmanaged, and reported as a validation/cleanup warning.

When a false-negative annotation is removed:

- managed `FN` formatting and value are removed;
- pre-existing workbook state is restored;
- a row created solely for current false-negative annotations is removed when
  no current annotation targets it;
- repeated updates do not duplicate annotation-only rows;
- adding a real supported call in a later regenerated workbook replaces the
  synthetic-row role with the authoritative scientific row.

Initial workbook generation and `current.xlsx` updates must use the same
semantics.

## 4. Manual Haplotype Assignments

### 4.1 Eligibility

One shared `GenotypeManualHaplotypeEligibility` evaluator controls the band,
editor, context menu, workbook snapshot, and tests. It returns eligible only
when:

- the result kind is in the explicit allowlist for full-length ONT MHC
  genotype-only matrices or miSeq amplicon MHC genotype-only matrices;
- the manifest/result workflow mode explicitly declares `genotypeOnly`; and
- every authoritative haplotyping indicator is absent: analysis document/path,
  active/revision declaration, haplotype-call records, haplotype artifact set,
  definition-set assignment, and assay/reference metadata declaring that
  haplotyping was performed.

Legacy results with no workflow-mode declaration are eligible only when their
recognized genotype-only result schema proves the same absence. Malformed,
unresolved, contradictory, or partially migrated declarations fail closed with
a visible disabled reason. Merely having an allele reference or a manual
haplotype-definition file available in the project does not mean haplotyping
was performed.

Analyses where haplotyping was performed retain their current viewport,
Inspector, and detail behavior.

The new per-sample editor replaces the existing Audit-lens bulk manual
haplotype creator for eligible genotype-only results. Two competing creation
paths must not append conflicting records. Export Manual Definitions remains
available from the new editor's actions and exports the canonical current
assignments.

### 4.2 Canonical loci

A shared Swift canonical-locus type defines exactly:

- MHC-A
- MHC-B
- MHC-DRB
- MHC-DQA
- MHC-DQB
- MHC-DPA
- MHC-DPB

It owns normalization of accepted result/source aliases and the explicit
mapping to each supported summary/full workbook layout. Assignment identity
never keys directly on an arbitrary display locus string. Native and openpyxl
workbook paths consume the same serialized canonical order/mapping; local
duplicated constant lists are removed or tested for exact parity.

### 4.3 Matrix assignment band

A collapsible **Haplotype Assignments** band sits directly beneath the existing
sample-name/read-count header. It is a dedicated aligned subheader rather than
an indefinitely enlarged `NSTableHeaderView`.

The pinned pane displays the seven locus names once in exact workbook order.
For every sample, each aligned row displays:

`H1 · H2`

If both are unassigned it displays `—`. H1 always precedes H2. Long labels
truncate visually while tooltips and accessibility descriptions expose the
complete pair.

The band:

- defaults expanded the first time an eligible analysis opens;
- persists its disclosure state per project/window;
- scrolls and resizes in exact horizontal alignment with sample columns;
- uses the app's content text-size preference and grows row height as needed;
- uses text as the primary signal, with color only as an optional secondary
  family cue;
- does not make every display cell a keyboard focus stop;
- adds assignment summaries to each sample header's VoiceOver description.

Header rendering uses a cached immutable index:

`sample → locus → (H1, H2)`

The band is a virtualized/drawn read-only layer, not fourteen controls per
sample. It follows horizontal scrolling, column resize/reorder, search/filter,
show/hide, and pinned/sample inset changes exactly. Only affected visible
columns redraw when assignments change.

### 4.4 Single-sample editor

Column-only selection in every eligible genotype-only MHC viewport—full-length
ONT and miSeq amplicon—routes to the existing sample-detail path instead of the
allele-sequence-only path. The known early-return routing defect is specific to
the full-length controller branch, but both result kinds use the same editor.

For one selected sample, the detail pane contains:

1. Sample heading
2. Haplotype Assignments editor
3. Existing read/QC summary
4. Existing supported-alleles detail
5. Existing sample comment

The editor has seven locus rows in workbook order. Each row contains labeled H1
and H2 editable combo boxes.

Each combo box:

- autocompletes labels used previously anywhere in the same analysis;
- remains free-form so a new label can be entered;
- preserves the label's existing color token when known;
- deterministically assigns a color token for a new label;
- has a clear control that stages deletion of that slot.

Changes remain in a local draft. **Save Assignments** applies the complete
sample draft atomically and schedules `current.xlsx` once. Selection changes
with an unsaved draft offer Save, Discard, and Cancel.

A single draft-transition coordinator interposes before every state mutation
that can abandon the editor: sample or multi-selection change, filtering or
hiding the selected sample, lens change, result reload, bundle/project switch,
window close, app quit, or new analysis information that changes eligibility.
Cancel vetoes the pending transition. Persistence or sidecar-revision conflicts
leave the draft intact with Retry and Reload choices.

Right-clicking a sample header includes **Edit Haplotype Assignments…**, which
selects that column and focuses the editor.

The command is contributed through the shared matrix context-menu builder and
appears only for exactly one sample column in an eligible result. The Inspector
entry point is the **Haplotype Assignments** card at the top of the existing
Detail Inspector for exactly one selected sample. The contextual command opens
the Detail Inspector if necessary, scrolls to that card, and focuses H1 for the
first locus. Both entry points invoke the same draft coordinator.

Read-only projects show the band and detail values but disable editing with an
explanation. Save is disabled for an unchanged or invalid draft. Empty
assignments, missing/orphan legacy sample assignments, no copy candidates, and
a source sample changing while a copy draft is open have explicit non-crashing
states.

### 4.5 Copy from another sample

The editor provides **Copy from Sample…**, a searchable picker of other samples
in the active analysis. Each result shows assignment completeness and a compact
assignment summary.

Choosing a source copies its seven-locus H1/H2 labels and associated color
tokens into the current sample's local draft. The analyst can modify the draft
before saving. Copying never persists immediately and never overwrites the
source. Because this UI does not edit scientific diagnostic-allele metadata or
assignment notes, it preserves the target sample's existing
`diagnosticAlleles` and `notes` exactly for each matching slot; it does not copy
those fields from the source.

The save audit records the copied source sample for each affected slot and in
the aggregate operation metadata.

### 4.6 Multiple columns

Multiple selected columns are read-only. The detail pane displays:

- selected sample count;
- assignment completeness;
- a compact per-sample assignment summary;
- guidance to select one sample to edit.

No bulk assignment editing is included.

Large multi-column selections use a bounded/virtualized summary rather than
constructing an unbounded detail view for every selected sample.

### 4.7 Input contract

Labels are trimmed and Unicode-normalized to NFC. Matching and autocomplete are
case-preserving but case-insensitive for deduplication. H1 and H2 may contain
the same label because homozygous/manual duplicate assignments are legitimate.
Labels are limited to 128 Unicode scalar values, and control characters are
rejected.

Workbook values are always written as literal strings. Labels beginning with
`=`, `+`, `-`, or `@` must never be interpreted as formulas.

When legacy assignments disagree about the color for one normalized label, the
canonical color is chosen deterministically from the newest structured
assignment, falling back to last legacy array position and finally the
deterministic label token. The next successful save canonicalizes the selected
sample.

### 4.8 Persistence, migration, audit, and workbook sync

The sidecar schema is bumped. `ManualHaplotypeAssignment` gains:

- stable `assignmentID`;
- `updatedAt`;
- `author`.

Legacy records decode with absent metadata. For duplicate legacy keys, the
deterministic fallback is last array position because historical records have
no timestamps or identifiers. The first atomic save for a sample canonicalizes
it to exactly one record per `(sample, canonical locus, slot)` without erasing
historical audit entries.

Add an atomic annotation-store operation that replaces one sample's manual
assignments keyed by `(sample, locus, slot)`.

The operation:

- normalizes whitespace and rejects empty locus/sample identities;
- prevents duplicate current assignments for the same key;
- computes additions, label/color changes, and removals;
- assigns one operation ID and records the prior sidecar revision/hash;
- appends explicit per-slot audit entries with structured full before/after
  records (label, color, diagnostic alleles, notes, assignment ID), author,
  timestamp, and copy source when applicable;
- stores structured aggregate operation metadata and a reproducible replay
  payload;
- persists the sidecar once;
- writes annotation provenance once;
- triggers one sidecar-change notification;
- marks `current.xlsx` dirty once for the existing manual/idle sync path.

A no-op save writes no sidecar, audit entry, provenance, notification, or
workbook-dirty event.

For an existing slot, label/color editing preserves `diagnosticAlleles`,
`notes`, and stable assignment ID exactly. A new slot starts with empty
diagnostic alleles and no note. Removing a slot audits all of its prior fields.

Saving redraws only the affected assignment-band sample column and refreshes the
selected sample detail. It does not rebuild the base or derived genotype matrix
projection.

For eligible genotype-only results,
`currentWorkbookEffectiveHaplotypeCalls()` builds the complete seven-locus,
two-slot workbook-call snapshot directly from the canonical current manual
assignments rather than requiring an active haplotype analysis. The snapshot
contains explicit blanks for cleared/unassigned slots so removals propagate,
uses the same canonical workbook row mapping, and includes its sidecar
revision/hash in workbook-update provenance. The existing workbook updater
writes those values into the corresponding H1/H2 Excel rows.

## 5. Error Handling

- Storage scan failures are shown at category/item level and never silently
  converted to removable status.
- Every scan and cleanup is bound to the initiating window and an immutable
  project root device/inode identity. Project/window changes cancel or dismiss
  the operation, and only one scan/cleanup mutates a project at a time.
- A lock acquired after scanning invalidates the affected item at execution
  time; containment, symlink/special-file exclusion, source device/inode,
  transaction authority, Keep Intermediates state, and classification evidence
  are revalidated immediately before the Trash handoff. Changed items are
  skipped and reported.
- Trash failures do not fall back to permanent deletion.
- Scanning and preparation are cancellable. After Trash moves begin,
  cancellation finishes the current item, stops before the next, and finalizes
  a truthful partial-result receipt.
- After execution, the sheet retains succeeded/skipped/failed rows, recalculates
  totals, disables stale actions, and offers Retry Failed and Reveal Receipt or
  Reveal in Trash when available.
- Automatic cleanup failures preserve enough authority/marker state to retry
  safely and appear in operation history.
- Invalid false-negative targets remain in Matrix Annotations with an explicit
  validation reason and do not create ambiguous workbook rows.
- Manual assignment validation errors keep the editor draft intact.
- Each combo box and clear action has a locus-plus-slot accessibility label;
  autocomplete announces result count and validation status; the band
  disclosure exposes expanded state and keyboard action; and the copy picker
  exposes searchable completeness labels and an accessible empty state.
- Workbook publication failures do not roll back successful annotation saves;
  the workbook remains marked pending and can be updated later.

## 6. Performance Requirements

- Storage scans run off the main thread, are cancellable, and publish throttled
  incremental progress.
- Scanning does not hash large staging payloads merely to display size; required
  durable descriptor checksums are reused from provenance/manifests when
  available.
- Directory sizing is streaming and bounded-memory.
- Opening a project or bundle must not synchronously scan the entire project.
- Automatic lifecycle cleanup operates only on the current transaction/run
  paths, not through a project-wide scan.
- Assignment display lookup is O(1) per visible sample/locus cell.
- Sidecar changes rebuild only the small assignment index.
- Assignment save must not trigger base/derived matrix projection rebuilds.
- False-negative synthesis is linear in workbook row count plus current
  false-negative annotations and does not scan every worksheet cell repeatedly.
- Storage preview maintains a 100 ms maximum single main-thread stall on the
  representative large project fixture.
- In a release build on the checked-in 100-visible-sample/seven-locus benchmark
  fixture, assignment-band scroll, reorder, and resize each keep p95 main-thread
  frame work at or below 16.7 ms and p99 at or below 33.4 ms, with no more than
  a 10% p95 regression from the recorded no-band baseline.
- Saving fourteen changed slots completes sidecar persistence/audit preparation
  within 250 ms excluding filesystem latency already measured separately.
- Multi-selection detail rendering remains bounded to the visible summary
  window and does not grow linearly in mounted views.
- Signposts/counters distinguish storage scanning, descriptor preparation,
  assignment-index rebuild, assignment-band redraw, sidecar save, and workbook
  synthesis.

## 7. Verification

### Storage and transaction safety

- A committed workbook update leaves no full retired-generation archive.
- A crash before commitment preserves both recoverable generations.
- A crash after retired-generation removal but before marker removal completes
  recovery without data loss.
- Fault injection covers after quarantine detach, after cleanup-state receipt,
  after marker removal, and during quarantine traversal for committed,
  prepared-discard, rollback, and manual-save-conflict terminal branches.
- Manual-save conflict paths preserve the correct generation.
- Cleanup failure leaves a retryable marker/quarantine and records a warning.
- Scanner fixtures cover completed archives, live locks, ambiguous
  transactions, stale staging, explicit Keep Intermediates, unsafe symlinks and
  special files, partial Trash failures, and legacy names.
- Cleanup execution fixtures cover path/inode replacement after preview, a lock
  acquired after preview, app crash between items, after quarantine detach,
  immediately before and after Trash, cleanup-journal/receipt write failure,
  safe restore after Trash failure, retained quarantine when restore is unsafe,
  read-only projects, concurrent CLI work, PID reuse, marker-write failure, and
  project-open-no-mutation.
- Legacy archive fixtures cover normal finalization without a recovery receipt,
  prepared generations, manual-save winners, tampered name/content, missing
  live bundles, and duplicate live candidates.
- Failure-envelope tests prove later runs supersede but never delete prior
  compact failure provenance.
- The scanner never offers an active bundle, current workbook revision,
  project operation-history receipt/journal, workbook recovery receipt, or
  lock-held workspace.

### Excel

- A zero-support false-negative whose row is absent creates one annotation-only
  row.
- The target cell contains `FN` with the required border/fill/font.
- Native OOXML and openpyxl paths expose exact `mediumDashed` side tokens and
  required ARGB values on all four sides.
- Matrix Annotations reports the target as valid.
- Workbook open/re-save through the managed openpyxl runtime preserves the
  presentation.
- Repeated update is idempotent.
- Clearing the review removes the managed cell presentation and orphaned
  synthetic row.
- A synthetic row shared by multiple false-negative cells remains until its
  final annotation is removed.
- Existing analyst comments and unrelated workbook formatting survive.
- Blank restores to blank and explicit numeric zero restores to numeric zero.
- Composed cell/row/column comment sections survive FN application and
  clearing.
- A user-edited synthetic row fails safe and is not deleted.
- Table/autofilter/formula fixtures remain structurally valid.
- Duplicate genotype aliases across locus/stable identities fail closed.
- Native generation and openpyxl update paths produce equivalent semantics.

### Manual assignments

- Eligibility tests cover both allowlisted result kinds plus every individual
  haplotyping indicator, mixed declarations, legacy recognized schemas,
  malformed/unresolved state, and haplotyped workflows.
- The band uses workbook locus order and H1-before-H2 ordering.
- Disclosure state, typography scaling, tooltips, and VoiceOver descriptions
  are covered.
- Column-only selection reaches the sample editor for both full-length ONT and
  miSeq genotype-only results; row selection retains allele sequence details.
- Autocomplete includes unique labels used elsewhere in the analysis.
- Free-form labels save successfully.
- Unicode normalization, length/control-character rules, case-insensitive
  deduplication, same-label H1/H2, deterministic color resolution, and
  formula-like literal labels are covered.
- Copy from Sample modifies only the draft until Save.
- Copy preserves the target slot's diagnostic alleles and notes while copying
  only label/color.
- Atomic save produces correct add/update/remove audit entries and copy source.
- Atomic save records operation ID, prior sidecar hash, full structured
  before/after values, and a reproducible replay payload.
- No-op save writes nothing and does not dirty the workbook.
- Clear deletes one slot.
- Multiple-column selection remains read-only.
- Draft transition interception covers filtering/hiding, lens/reload,
  bundle/project switch, window close, and app quit; Cancel vetoes each
  transition.
- Save triggers one persist, one workbook-dirty event, and no genotype
  projection rebuild.

### Integration and regression

- Exercise a representative full-length genotype-only bundle and a miSeq
  genotype-only bundle.
- Confirm haplotyped workflows have no assignment band/editor changes.
- Run focused IO, workflow, CLI, app, and genotype UI suites.
- Run the full Swift test suite and release-specific validation.
- Record projection and storage-scan performance fixtures in verification
  documentation.

## 8. Migration and Existing Projects

No eager destructive migration runs on open.

Existing annotations decode unchanged. Existing manual assignments are indexed
by canonical sample/locus/slot identities. Structured `updatedAt` metadata
determines the current assignment when present; duplicate legacy records fall
back deterministically to last array position. The first successful atomic save
canonicalizes the selected sample to one current record per key while
preserving audit history.

Legacy hidden data is reclaimed only through **Manage Project Storage…** after
classification, preview, and confirmation. Future successful workbook updates
and workflows use the corrected lifecycle automatically.

# Manual Haplotype Refinement and Workbook Recovery Design

**Status:** Expert-approved for implementation  
**Date:** 2026-07-29

## Objective

Refine manual haplotype curation so the matrix stays compact, assignment labels
remain legible, selected-sample evidence follows the matrix exactly, and analysts
can compare another sample before staging its assignments. Repair workbook
publication recovery on exFAT without weakening cleanup substitution defenses or
losing provenance.

This work applies to eligible genotype-only full-length ONT MHC and miSeq
amplicon MHC analyses. It does not add manual curation controls to analyses in
which haplotyping was performed.

## User-visible design

### Matrix disclosure

Eligible genotype-only matrices show one pinned disclosure row labeled:

> Manual haplotypes (7 loci)

The row is collapsed for a newly viewed bundle. Expanding it reveals the seven
existing locus rows beneath the sample headers. The disclosure triangle and its
label live in the frozen left metadata region and form one keyboard- and
pointer-operable target. Space and Return toggle it. The label wraps without
clipping at 200% content text. Collapsing removes all seven locus rows and their
height rather than merely hiding their contents. VoiceOver announces the label,
expanded state, and:

> Shows seven locus-level manual haplotype assignment rows below the sample
> names.

Expansion state remains presentation-only. It is retained per viewer window and
bundle but is not written to the annotation sidecar or scientific audit.
Expanding or collapsing preserves the top visible matrix row, selected cells,
horizontal semantic anchor, sort, and filter state.

### Sample-column auto-fit

When the manual-haplotype band is expanded, each sample column uses the widest
of:

- the sample name and retained-read header;
- the analyst's stored user-preferred width; and
- the seven rendered `H1 · H2` assignment pairs plus the normal cell inset.

The complete widest assignment must be visible. Assignment labels are already
bounded to 128 Unicode scalars, so auto-fit does not add a second truncating
ceiling. The matrix remains horizontally scrollable.

Programmatic auto-fit is a transient minimum and never overwrites the stored
user width. Collapsing the band restores the user-preferred/header width.
Expansion and typography changes measure all visible samples once. A successful
manual save remeasures only changed samples. Typing in the editor does not resize
the matrix, rebuild columns, or rebuild the projection.

### Selected-sample workbench

The workbench keeps the responsive header and two-body-region structure. At wide
sizes the two regions fill the full width without the current 640-point editor
cap. At narrow sizes and large content text they stack without remounting the
editor, its draft, or its controls.

The leading region remains **Haplotype Assignments**. The trailing region has
two modes:

1. **Evidence** — the default selected-sample evidence view.
2. **Compare & Copy** — an analyst-selected source sample, its assignment
   completeness, and an aligned genotype comparison.

Changing modes or comparison sources never runs the CLI, changes the matrix
projection, writes the sidecar, or replaces the editor model.

### Supported alleles

Evidence uses the exact current top-matrix row order. The existing
`visibleSampleAlleleDetails(sample:)` result is consumed directly; the
controller does not apply a second locus/read-count sort.

The evidence table contains only:

| Allele | Read support |
|---|---:|

`Read support` is the passed unique-read count already drawn in the matrix.
Locus, Alignments, and percentage Support are removed. Allele labels preserve
known, extension, candidate, annotation, and provisional exon-2 presentation.
Accessibility reads, for example:

> Mafa-A1*018:01:01:01, read support 712.

The inline preview remains bounded to twelve rows. **Show All …** opens the
existing separate virtualized full list. If the matrix sort, search, threshold,
or row visibility changes while a sample remains selected, only the retained
evidence snapshot updates; the assignment editor and draft keep their identity
and focus.

### Compare & Copy

The existing **Copy from Sample…** action becomes **Compare & Copy…** and enters
the trailing pane's comparison mode. It does not copy immediately.

Comparison mode provides:

- a searchable, keyboard-navigable source-sample selector;
- source assignment completeness, such as `8 of 14 assignments`;
- a factual summary such as
  `12 shared · 4 only CR1178 · 6 only CR1182`; and
- a virtualized union table:

| Allele | CR1178 | CR1182 | Relationship |
|---|---:|---:|---|
| Mafa-A1… | 712 | 365 | Shared |
| Mafa-B… | 547 | — | CR1178 only |

Rows follow the current matrix order. Rows present only in the source are
appended in that source's matrix order. Exact stable row identities determine
whether evidence is shared; display-label collisions do not. Shared rows use a
subtle accent plus the word **Shared**, so color is never the sole indicator.
Absent evidence uses an em dash. A false negative is displayed as **FN**, not as
an ordinary absence. False positives, false negatives, and comments each have a
text/icon indicator and complete accessibility label; color is supplemental.

At compact widths or 200% text, each comparison row reflows rather than
squeezing four columns: the allele and relationship appear first, followed by
two clearly labeled sample/read-support values. Allele labels wrap and expose
their complete accessibility value. VoiceOver reads rows in current matrix
order, then source-only rows in source matrix order. The same source selector,
comparison model, and copy control instances survive responsive reflow.

The source selector includes every other sample in the analysis, including
samples whose columns are currently hidden. The comparison allele scope follows
the current matrix row projection. Only the focused source sample is expanded
into a comparison snapshot. Candidate search and completeness stay cached;
genotype details are not precomputed for every sample.

An explicit **Use [sample] Assignments** button stages the source assignments
through the existing draft copy method. The current sample is never offered as
a source. Blank source slots replace populated target slots, exactly like
populated source slots. If the target draft already differs from its persisted
snapshot, the app requires confirmation that identifies the source and explains
that all fourteen slots, including blanks, will replace the current draft.
Cancelling leaves the draft byte-for-byte unchanged. Staging does not save. The
editor reports:

> Assignments staged from [sample].

**Save Assignments** remains the sole persistence action, retaining the existing
audited `copySource`, sidecar transaction, header refresh, and workbook dirty
marking behavior.

### Export action

The one-item overflow menu is removed. A visible secondary button is labeled:

> Export All Haplotype Assignments…

It invokes the existing analysis-wide export path and therefore retains its
existing reproducibility provenance. Its scope is deliberately distinct from
the sample-scoped **Save Assignments** action.

### Automated support explanation

The ambiguous `QC: OK` metric becomes:

> Call-support check: Meets thresholds

The visible explanation is:

> This sample has at least one genotype call. Its totals include at least 1,000
> retained unique reads and 20 passed alignments. This automated call-support
> check is not analyst approval or confirmation that haplotype assignments are
> correct.

Equivalent states are:

- **Low support** — calls exist, but retained unique reads are below 1,000 or
  passed alignments are below 20.
- **Review needed** — there are no calls, retained unique reads are zero, or
  passed alignments are zero.

The explanation wraps visibly in the header/workbench and is also the
accessibility help. It does not rely on color or a tooltip alone.

## Workbook failure diagnosis

The affected project is on an exFAT FSKit volume. Workbook retirement cleanup
uses an exclusive-rename fallback:

1. exclusively reserve a random destination;
2. rename the source over that reservation; and
3. compare the destination inode with the source inode captured before rename.

FSKit exFAT may assign a new synthetic inode when a clusterless zero-byte file is
renamed. Cleanup therefore misclassifies an unchanged empty
`CR1178.unmatched-blast-rescue.tsv` as a substituted entry.

The first affected update durably committed `current.xlsx`, its manifest, and
successful workbook provenance before cleanup failed. Later updates correctly
stopped in preflight recovery. Consequently, the existing workbook is valid but
does not contain the later manual assignments.

## Workbook recovery design

### Portable rename witness

`PortableExclusiveRename` reports whether it used native exclusive rename or
the reservation fallback. The existing integer-returning wrapper remains for
unaffected callers.

For a regular file, cleanup opens the source with
`O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC` and holds that descriptor from
before destination reservation through final tombstone unlink. The fallback
accepts this source witness. After reserving the destination, it re-stats both
the source name and the held descriptor immediately before ordinary `renameat`.
Device, inode, entry type, and expected metadata must still match.

The reservation descriptor is also held open. Immediately before rename,
cleanup requires the random destination name and held reservation descriptor to
identify the same kernel object. If either source or reservation validation
fails, it removes only its verified reservation and fails without detaching the
source.

Ordinary `renameat` has an unavoidable syscall-sized gap after final
revalidation on filesystems that do not implement exclusive rename. That gap is
inside the held workbook publication lock and targets an unpredictable random
tombstone name in the private quarantine. The implementation and provenance
state this trust boundary explicitly; they do not claim that an uncooperative
same-user process which discovers and replaces the reservation inside that gap
can always be preserved.

### Narrow exFAT zero-byte allowance

Cleanup continues to require identical source/destination identity for:

- native exclusive rename;
- directories and symbolic links;
- nonzero regular files; and
- any entry whose metadata changes before detach.

An inode change is accepted only when all of the following hold:

- the reservation fallback was used;
- original and detached entries are regular files;
- both sizes are exactly zero;
- mode, size, and stable timestamps match;
- the original name is now absent;
- the random destination was exclusively reserved; and
- the source witness was revalidated after reservation and before rename.

After rename, cleanup re-stats the still-open source descriptor and the detached
tombstone path. The rebase allowance is enabled only if those two post-rename
kernel witnesses agree exactly on device, inode, and regular-file type. If real
exFAT leaves the held descriptor on the old inode while the destination reports
a new one, cleanup fails closed and the allowance remains disabled for that
filesystem.

The detached destination's agreed post-rename identity becomes the tombstone
witness. Immediately before unlink, cleanup revalidates the held source
descriptor and tombstone path against that exact identity. Substitution before
detach or after detach therefore remains a hard failure. No code directly
unlinks the old name, broadly ignores inode changes, follows links, or weakens
quarantine-root/survivor/attestation validation.

### Recovery and provenance

No state migration or manual deletion is needed. Existing schema-3
cleanup-pending state remains authoritative. On the first update with the fix:

1. validate the retained transaction, survivor hashes, manifest, and
   attestation;
2. resume cleanup of the partially emptied quarantine;
3. write the normal terminal `finished-committed-cleanup` receipt;
4. retire cleanup state and attestation;
5. apply the latest manual assignments to a new workbook revision; and
6. write normal workbook provenance with current inputs and exit status.

Existing warning receipts and compact revision/provenance records remain in the
bundle for traceability. No second retired full generation is created while a
cleanup-pending generation exists.

A post-commit cleanup problem returns the committed manifest and workbook as a
success-with-warning outcome. The CLI exits zero, Operations shows **Completed —
cleanup pending**, and **Update and View Current Excel Version** may open the
committed workbook. It is reported as:

> Workbook updated; retired-generation cleanup pending.

The successful attempt provenance records the committed scientific update,
exact argv/options/inputs/checksums/wall time/exit 0, and the cleanup-pending
warning without contradicting the command outcome.

A preflight recovery failure remains blocking, exits nonzero, creates no new
workbook generation, and explicitly says:

> The existing workbook is valid, but this new update was not applied because a
> prior retired generation could not be cleaned up safely.

Every command attempt writes an attempt receipt/provenance record containing the
exact argv, resolved inputs and defaults, runtime identity, input/output paths
and hashes where available, wall time, exit status, and useful stderr. A failed
preflight retry therefore has its own provenance rather than only appending a
warning to the prior transaction. The terminal cleanup receipt documents later
recovery, and the subsequent normal workbook provenance documents the next
scientific revision.

## Performance requirements

- Disclosure/typography changes may measure `O(samples × 7)` assignment pairs.
- One successful save measures only changed samples: `O(7)` per sample.
- Scrolling performs no text measurement and no comparison work.
- Evidence ordering refresh does not rebuild the matrix projection or editor.
- Selecting one comparison source is `O(visible rows)`; typing in source search
  does not build comparisons for every candidate.
- Existing release budgets remain: p95 ≤ 16.7 ms, p99 ≤ 33.4 ms, and no greater
  than 10% regression in representative matrix interactions.

## Validation

### Matrix and workbench

- New eligible bundles start collapsed; expansion state is isolated per
  window/bundle and survives controller recreation.
- Haplotyped ONT and miSeq results mount no manual disclosure or workbench.
- Expanded columns display complete widest assignment pairs and restore stored
  widths when collapsed.
- Save remeasures only changed sample columns and performs zero projection or
  table reloads.
- Evidence order matches matrix order under sorting, search, thresholds, and
  manual visibility changes.
- Evidence exposes only Allele and Read support and stays bounded for 1,001
  rows.
- Published selection/accessibility state removes the legacy Locus, Unique
  Reads, Alignments, and Support rows when the simplified evidence is active.
- Compare uses stable row identity, updates lazily, distinguishes preview,
  staged, and saved states, and preserves annotations.
- Workbench/editor/control identities, draft, focus, and accessibility survive
  resize, mode changes, evidence refresh, and 100–200% content text.
- Export button uses the existing provenance-producing callback.
- Call-support explanations are visible, accurate, and exposed to VoiceOver.

### Workbook cleanup

- Fallback strategy is reported and source witness is revalidated.
- A simulated exFAT zero-byte inode rebase is accepted only through the
  reservation fallback.
- Native or nonzero inode mismatch remains rejected.
- Existing before-detach substitution regression remains green.
- A source substitution injected after the second name revalidation and
  immediately before `renameat` moves the original aside and installs a
  metadata-identical zero-byte replacement; post-rename held-descriptor
  validation detects it, unlinks neither retained object, and fails safely.
- A reservation replacement before final reservation revalidation is detected,
  and only the verified reservation may be removed. A separate test documents
  the unavoidable post-revalidation syscall-gap trust boundary.
- A committed cleanup-pending fixture models a partially emptied quarantine
  containing the offending zero-byte path and a leftover random tombstone. It
  recovers to a terminal receipt, preserves survivor workbook/manifest hashes,
  removes only the authorized quarantine, and converges through terminal
  receipt, state retirement, and attestation retirement without stranded
  authority.
- A subsequent update includes the latest manual assignments and produces
  complete provenance.
- A post-commit cleanup problem exits zero with a committed workbook and
  warning; a preflight recovery failure exits nonzero, writes attempt
  provenance, and creates no new generation.
- Optional real-exFAT verification uses a new temporary UUID directory, never a
  production quarantine, before exercising authorized recovery of the existing
  bundle.

# Genotype Matrix Review Annotations Design

**Date:** 2026-07-24

**Status:** Approved

## Summary

Lungfish Genome Explorer will add semantic false-positive and false-negative review annotations to genotype matrix cells, editable comments at cell, allele-row, and sample-column scope, native Excel presentation, and complete audit and reproducibility provenance.

Review annotations are scientific assertions, not decorative matrix styles. They therefore receive a dedicated persisted model, explicit eligibility validation, stable visual treatment, audit history, and export behavior. Existing fill, text, border, bold, and italic styling remains available as a separate appearance feature.

The implementation must preserve the responsiveness of large genotype matrices. Selection eligibility and visible-cell rendering use indexed in-memory state; context-menu construction performs no disk access or sidecar scans; workbook regeneration remains debounced and outside the immediate interaction path.

## Goals

- Let analysts mark one or more supported genotype cells as false positives.
- Let analysts mark one or more zero-support or unsupported genotype cells as false negatives.
- Reject an entire bulk review operation when any selected cell is ineligible.
- Let analysts add, view, edit, replace, and remove one current comment per matrix target.
- Support comments on exact genotype cells, entire allele rows, and entire sample columns.
- Present row, column, and cell comments as distinct, elegant scopes in Lungfish.
- Propagate semantic reviews and all comment scopes to `current.xlsx` and explicit viewport Excel exports.
- Record every review and comment mutation in the bundle audit log and reproducibility provenance.
- Make the active analyst identity visible and configurable.
- Preserve matrix scrolling, selection, context-menu, and annotation-save performance.

## Non-Goals

- False-positive or false-negative annotations do not change automated genotype calls, read counts, filtering, or haplotype calculations.
- Row and column targets cannot receive false-positive or false-negative status.
- Review status is not inferred from generic matrix colors, fonts, or borders.
- Comments do not become threaded conversations; each target has one current editable comment.
- CSV and TSV exports do not attempt to reproduce Excel typography, borders, or native notes. Their quantitative cell values remain unchanged.
- This feature does not introduce a separate user-account system.

## Existing Foundation

The current implementation already provides:

- Stable matrix targets for rows, sample columns, and cells, including optional candidate stable-cluster identity.
- Direct and bulk matrix selection.
- Atomic `annotations.json` publication with stale-revision detection.
- Matrix styles and append-only matrix comments.
- Audit entries and provenance envelopes for GUI annotation edits.
- Debounced updates of `artifacts/workbooks/current.xlsx`.
- Explicit viewport exports through `lungfish-cli genotype export`.
- A Matrix Annotations worksheet and native Excel comments in the current-workbook update path.

The feature extends these paths instead of creating a parallel annotation store or export mechanism.

## User Experience

### Annotation Inspector

The genotype Annotations tab begins with a **Review Annotation** group above generic appearance controls.

For a selection it shows:

- Target count and target type.
- Read-support summary: all supported, all unsupported, mixed, or unavailable.
- Current review state: none, false positive, false negative, or mixed.
- **False Positive**, **False Negative**, and **Clear Review Mark** actions.
- A concise disabled explanation when an action is unavailable.

Examples:

- `3 genotype cells selected · all have read support`
- `4 genotype cells selected · no read support`
- `Selection contains cells with and without read support`

False-positive and false-negative actions are mutually exclusive. Applying one replaces the other on the same target. Clear Review Mark removes either state.

Generic fill, text, border, bold, italic, and palette controls move under an **Appearance** disclosure group. This visually separates scientific review assertions from optional decoration.

### Eligibility

Eligibility uses raw genotype evidence, not formatted text, current filters, minimum-read display thresholds, support heat maps, or hidden-highlight state.

- A cell is supported when `passedUniqueReads > 0`.
- A cell is unsupported when its support record is absent or `passedUniqueReads == 0`.
- False positive is available only when every selected target is a cell and every selected cell is supported.
- False negative is available only when every selected target is a cell and every selected cell is unsupported.
- A mixed support selection disables both actions.
- Row, column, or mixed target-type selections disable both actions.
- A read-only bundle disables every mutation.

Bulk commands validate every target again immediately before publication. Validation failure makes no changes. Commands never filter a mixed selection down to its eligible subset.

Row and column context menus may offer explicit selection helpers such as **Select Cells with Read Support** and **Select Cells without Read Support**. These commands change selection only; they do not apply an annotation.

### Context Menus

Right-clicking within the current selection preserves that selection. Right-clicking outside it first selects the clicked row, column, or cell.

Cell context menus contain the same review, clear, comment, and disabled states as the inspector. Header and allele-row menus expose scoped comment actions and selection helpers. Inspector controls and menu items consume the same cached command-state model, preventing behavior drift.

No context-menu path reads the sidecar or recomputes matrix-wide evidence.

### Matrix Presentation

Semantic review marks remain visible in Support, Highlights, and None color modes and when filtered highlights are hidden.

Layer order for a visible cell is:

1. Alternating row background and support heat map.
2. Analyst fill and text appearance.
3. False-positive typography or false-negative inner frame.
4. Analyst decorative border.
5. Selection focus corners.
6. Comment marker.

False positive:

- Retain the displayed read count.
- Render it bracketed and italic, for example `[42]`.
- Use a dynamic secondary text color with sufficient contrast.
- Do not reduce the alpha of the entire cell, because that would also fade selection and comment affordances.

False negative:

- Retain `0` when an explicit zero value is displayed.
- Show an em dash for a semantically annotated empty cell in the viewport so it cannot be mistaken for a rendering omission.
- Draw a thick inner frame independent of the existing decorative border and selection layers.

Selection uses accent-colored corner brackets rather than replacing the cell perimeter. Increased Contrast increases semantic frame and marker weight.

### Comment Presentation

A small folded-corner marker indicates a comment without adding a per-cell icon or separate accessibility stop.

Markers appear only at their native scope:

- Allele-row comments mark the genotype or allele label cell.
- Sample-column comments mark the sample header.
- Cell comments mark the exact sample/allele intersection.

The selected target's inspector presents separate editable cards:

- **Cell**
- **Allele Row**
- **Sample Column**

Each card shows the current body and concise author/update metadata. Empty cards offer Add Comment. Populated cards offer Save Changes and Remove Comment. Row and column context menus open the corresponding card.

For multiple selected targets:

- No comments: show an empty bulk composer.
- Uniform comment text: show that text and the target count.
- Mixed values: show `Multiple comments` without choosing one arbitrarily.
- Replacing mixed or existing values requires an explicit **Replace Comments on N Targets** action.

The detail tooltip aggregates applicable scopes in stable Allele Row, Sample Column, Cell order while the inspector keeps them visually separate.

### Legend and Accessibility

When semantic annotations exist, the matrix exposes a compact legend:

`[n] False positive   ▣ False negative   ◥ Comment`

Meaning never relies on color alone. VoiceOver descriptions include sample, genotype, read count or no support, review status, selection, and scoped comment counts. Comment markers are not separate VoiceOver stops.

Example accessibility descriptions:

- `Animal A, Mafa-A1*001:01, 42 unique reads, false positive, one cell comment, selected.`
- `Animal B, Mafa-A1*001:01, no supporting reads, false negative.`
- `Three genotype cells selected. All have read support. False positive is available.`
- `Selection contains cells with and without read support. Review classifications require one evidence state.`

The feature uses dynamic AppKit colors, supports Dark Mode, and increases semantic geometry under Increased Contrast.

## Analyst Identity

Lungfish Settings gains a global **Analyst identity** field.

- The default resolves to the current macOS user.
- A non-empty, trimmed user override is stored in application settings.
- The annotation inspector shows `Saving as: <resolved identity>` with a link to the relevant Settings pane.
- The identity is resolved when an edit is created and copied into the persisted annotation, audit entry, and provenance record.
- Changing the setting affects only future edits. Existing authorship is immutable.
- The setting is not editable separately on each comment or review action.

The existing `NSUserName()` behavior remains the fallback when no override is configured.

## Data Model

`GenotypeAnnotationSidecar.currentSchemaVersion` advances to version 2.

The sidecar adds:

```swift
enum MatrixReviewDisposition: String, Codable, Sendable {
    case falsePositive
    case falseNegative
}

struct MatrixReviewAnnotation: Codable, Equatable, Sendable {
    let target: MatrixTarget
    let disposition: MatrixReviewDisposition
    let author: String
    let timestamp: String
}
```

`MatrixReviewAnnotation.target` must be `.cell`. Exact identity includes locus, genotype, sample, and stable cluster ID when present. The active collection contains at most one review per target.

`matrixComments` remains an array in the JSON schema for compatibility, but version-2 mutation semantics make it a target-keyed collection with at most one current entry per target.

### Legacy Comment Resolution

Version-1 sidecars may contain multiple matrix comments for one target.

- Reading remains backward compatible.
- The current value is the entry with the latest parseable timestamp.
- Equal or unparseable timestamps resolve to the last entry in file order.
- The inspector and Excel paths expose only the resolved current value.
- On the first subsequent mutation of that target, the store replaces all legacy entries for the target with one current entry.
- Superseded values already represented in audit history remain unchanged.
- If a superseded value has no matching audit entry, the canonicalizing mutation appends an audit record that identifies the legacy value as superseded before it is removed from the active collection.

No read-only load rewrites the bundle.

## Selection Capability Model

An indexed selection-capability service produces one immutable state consumed by the inspector, context menu, keyboard commands, accessibility copy, and mutation validation.

The state includes:

- Selection target shape: none, cells, rows, columns, or mixed.
- Selected cell count.
- Supported, unsupported, and unknown counts.
- Current review state: none, uniform, or mixed.
- Current comment state by scope: empty, uniform, or mixed.
- Bundle writability.
- Per-command availability and disabled reason.

Support, review, and comment dictionaries are rebuilt only when result evidence or the sidecar revision changes. Selection aggregation is linear in selected targets.

## Commands and Persistence

The annotation store adds atomic, target-keyed operations:

- Set or replace a review disposition for a validated cell collection.
- Clear review disposition for a cell collection.
- Upsert one comment for one or more exact targets.
- Remove comments from one or more exact targets.

Each operation:

1. Normalizes and de-duplicates targets.
2. Validates target type, evidence eligibility, body rules, and writability.
3. Captures before and after values.
4. Mutates one in-memory sidecar revision.
5. Appends one audit entry per affected target using one operation timestamp and author.
6. Atomically publishes the sidecar and provenance through the existing publication coordinator.
7. Reloads only affected visible matrix targets.
8. Schedules one debounced current-workbook update.

A stale-revision error publishes nothing and restores the latest sidecar, preserving current conflict behavior.

## Audit

Audit actions are explicit semantic events:

- `setMatrixReview`
- `clearMatrixReview`
- `upsertMatrixComment`
- `removeMatrixComment`
- `canonicalizeLegacyMatrixComments`

Each entry records the exact target, previous value, new value, author, timestamp, and semantic reason. Comment audit entries retain the full previous and new bodies. Stable candidate identity is included in the target description.

The audit timeline presents semantic labels rather than generic matrix-style terminology.

## Provenance

Every GUI mutation that creates, transforms, or republishes scientific annotations writes reproducibility provenance into the final bundle.

The provenance envelope records:

- Workflow and tool name and version.
- Reproducible argv equivalent.
- Exact action.
- Exact normalized targets.
- Before and after review or comment values.
- Resolved eligibility rule and evidence counts for review actions.
- User-visible options and resolved defaults.
- Resolved analyst identity.
- Runtime identity.
- Prior sidecar input path, checksum, and size when present.
- Final stored sidecar output path, checksum, and size.
- Exit status and wall time.
- Useful error context for failed publication attempts when a failure record is produced.

GUI provenance points at the final stored `annotations.json`, never a staging file.

Workbook update provenance records the stored annotation sidecar as an input and the final stored workbook generation as output. Explicit viewport export provenance records the durable view-projection sidecar, stored annotation sidecar, and final Excel file.

## Excel Semantics

Both `artifacts/workbooks/current.xlsx` regeneration and `lungfish-cli genotype export --view-projection` consume the final stored annotation sidecar.

### False Positive

- Preserve the cell's read-count meaning.
- Write the read count as bracketed text, for example `[42]`.
- Apply italic font.
- Apply an accessible faded gray, no lighter than `#767676` on the default white Excel canvas.
- Preserve the unmodified count and semantic disposition in `annotations.json`, provenance, Matrix Annotations, and Audit Log data.

### False Negative

- Preserve an explicit `0`.
- Leave an absent value empty.
- Emit the cell even when empty so it can carry a border.
- Apply a thick border on all four sides.

### Comments

Excel supports one native note object per cell. Applicable comments are combined into one note with separately labeled sections in stable order:

1. Allele Row
2. Sample Column
3. Cell

Each section retains body, author, and timestamp.

- Allele-row comments attach to genotype or allele label cells.
- Sample-column comments attach to sample headers.
- Cell comments attach to the exact intersection.
- A target may carry FP or FN formatting and a native comment simultaneously.

### Annotation Worksheets

The Matrix Annotations worksheet adds review records with target kind, locus, genotype, sample, stable cluster ID, disposition, author, and timestamp. Comment records remain present. The Audit Log worksheet contains corresponding semantic actions.

Workbook matching uses locus, genotype, sample, and stable candidate identity where the workbook carries it. It must not match only genotype text when that could affect more than one row.

A malformed imported review record that violates its support rule remains visible in Matrix Annotations and Audit Log but is reported as invalid and is not silently applied as valid cell formatting.

## Failure Handling

The sidecar is the authoritative annotation record.

- Sidecar publication completes before workbook regeneration begins.
- A workbook update failure does not roll back a successfully audited annotation.
- The inspector shows an actionable update warning and retry command.
- The previous valid `current.xlsx` remains in place after a failed generation.
- Atomic publication prevents partial sidecar, workbook, audit, or provenance files.
- Read-only bundles display annotations and resolved comments but disable edits with a clear explanation.
- Invalid bulk selections fail as a unit and identify why the operation is unavailable.
- Stale sidecar revisions reload the latest state and ask the analyst to review before retrying.

## Performance Requirements

Performance is a product acceptance requirement, not an optional implementation detail.

- Context-menu command preparation reads cached state and performs no disk I/O or matrix-wide scan.
- Representative context menus appear within the repository UI/UX target of 50 ms.
- Selection-capability calculation is linear in selected targets.
- Semantic mutations serialize and publish once per user command.
- Matrix redraw touches only affected visible or reused cells.
- Scrolling and opening the matrix perform no per-cell sidecar scans or file access.
- Comment tooltips use cached strings and native tooltip behavior; they do not create per-cell tracking areas.
- Workbook regeneration remains debounced and outside the immediate annotation interaction path.
- Performance tests do not impose fragile sub-millisecond assertions on ordinary CI. Deterministic structural assertions run in CI; representative timing benchmarks are recorded against the existing large-matrix baseline.

## Testing Strategy

### Model and Migration

- Version-1 sidecars decode with empty review records.
- Version-2 sidecars round-trip reviews and unique comments.
- Legacy duplicate comments resolve deterministically.
- Editing a legacy target canonicalizes it and preserves missing history through audit.
- Review records retain stable candidate identity.

### Eligibility and Atomicity

- Single supported cell enables only false positive.
- Single zero or absent cell enables only false negative.
- All-supported bulk selection succeeds.
- All-unsupported bulk selection succeeds.
- Mixed support selection enables neither.
- Row, column, and mixed target selections enable neither.
- Hidden and filtered cells use raw evidence correctly.
- Display thresholds do not change eligibility.
- Stale or newly invalid evidence prevents the entire mutation.
- Read-only bundles publish nothing.

### Comments

- Add, edit, remove, and bulk replace use target-keyed upsert semantics.
- Mixed comments require explicit replacement.
- Row, column, and cell cards expose distinct current values.
- A selected cell displays applicable scopes separately in Lungfish.
- Excel combines overlapping scopes once and in stable order.

### Analyst Identity

- The default resolves to the current macOS user.
- A trimmed Settings override becomes the resolved identity.
- Empty overrides fall back to the macOS user.
- The inspector displays the resolved identity.
- Identity changes affect future edits only.
- Audit and provenance contain the resolved edit-time identity.

### Rendering and Accessibility

- FP renders bracketed italic secondary text.
- FN renders an independent thick inner frame.
- Explicit zero and absent support remain distinguishable.
- Comment markers render at native scope only.
- FP/FN and comments coexist.
- Selection does not hide FN or comment state.
- Support, Highlights, and None modes preserve semantic marks.
- Dark Mode and Increased Contrast retain meaning and sufficient contrast.
- VoiceOver descriptions contain evidence, review state, and scoped comment counts.

### Commands and Menus

- Inspector and context menu expose identical command state and disabled reasons.
- Right-click inside a selection preserves it.
- Right-click outside a selection selects the clicked target.
- Keyboard commands operate on the same state model.
- Accessibility identifiers are stable for UI testing.

### Excel

Both current-workbook update and explicit viewport export tests inspect the produced workbook structure:

- FP produces `[42]`, italic font, and accessible gray text.
- FN produces thick four-sided borders on zero and empty cells.
- Native comment XML, relationships, and anchors exist for row, column, and cell scopes.
- Overlapping scopes create one labeled note.
- FP plus comment and FN plus comment coexist.
- Matrix Annotations and Audit Log rows match sidecar semantics.
- Similar genotype labels at different loci or stable IDs do not receive each other's annotations.
- The final stored annotation sidecar and workbook appear in provenance with checksums and sizes.

### Performance

CI includes deterministic checks that:

- Menu preparation uses precomputed capabilities and performs no file access.
- Selection changes do not rebuild matrix-wide support indexes.
- Targeted edits do not trigger a full table reload.
- Visible-cell rendering uses indexed lookups.
- Workbook update requests are coalesced.

A representative large-matrix benchmark records:

- Selection aggregation time across small and large bulk selections.
- Context-menu preparation time against the 50 ms target.
- Matrix scrolling and redraw behavior with FP, FN, and comments populated.
- Sidecar publication time and allocation behavior for a large bulk edit.

Benchmark results are compared with the existing genotype viewport baseline and attached to the implementation verification report.

## Acceptance Criteria

- Analysts can apply FP only to one or more cells with reads.
- Analysts can apply FN only to one or more cells with zero or absent reads.
- Mixed evidence selections cannot be partially annotated.
- Review marks are visible, accessible, and independent of decorative styles.
- Each row, column, or cell target has one current editable comment.
- Lungfish presents overlapping comment scopes separately and elegantly.
- Excel retains read counts for FP as faded italic bracketed values.
- Excel uses thick borders for FN, including empty cells.
- Excel carries scoped native notes and semantic annotation/audit worksheets.
- Every mutation and workbook/export transformation is audited and reproducibly provenanced.
- The resolved analyst identity is visible and configurable.
- Large-matrix interaction remains responsive and meets the scoped performance requirements.


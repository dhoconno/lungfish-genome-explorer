# Savont FASTA Context Actions Design

**Date:** 2026-08-05
**Scope:** Shared multi-sequence FASTA viewport used by standalone Savont clustering results and ordinary FASTA files

## Goal

Make every FASTA row context action behave predictably for one or several selected rows. BLAST results must appear in the existing bottom-pane area, sequence extraction and derived operations must preserve reproducibility provenance, and the menu must act on the rows the user actually right-clicked.

The implementation remains shared. It does not add a Savont-only viewer or duplicate FASTA action code.

## Selection and menu behavior

The menu is rebuilt when it opens, after reconciling the clicked row with the current selection:

- Right-clicking inside an existing multi-row selection preserves that selection.
- Right-clicking a row outside the selection makes that row the sole target.
- No row selection leaves sequence actions disabled.
- Selected records are passed to actions in current visible table order.

Action availability and results are:

| Action | One row | Multiple rows | Behavior |
| --- | --- | --- | --- |
| Extract Sequence… | Enabled | Enabled | Clipboard, FASTA export, share, and reference-bundle destinations receive exactly the selected records. |
| Verify with BLAST… | Enabled | Enabled through 50 rows | The bottom pane opens immediately in BLAST mode and shows progress, results, or a useful failure. More than 50 rows is disabled with an explanation. |
| Copy FASTA | Enabled | Enabled | Copies complete selected FASTA records in visible order. |
| Export FASTA… | Enabled | Enabled | Writes complete selected records with canonical export provenance. |
| Create Bundle… | Enabled | Enabled | Creates a reference bundle whose durable provenance traces to the original FASTA input, not only temporary staging. |
| Align with MAFFT… | Disabled | Enabled for two or more rows | Opens FASTA Operations directly at Multiple Sequence Alignment / MAFFT. |
| Run Operation… | Enabled | Enabled | Opens the generic FASTA operation chooser using a provenance-complete temporary selected-FASTA bundle. |

The 50-row BLAST cap follows Lungfish's existing assembly BLAST safety limit and prevents an accidental oversized remote request. MAFFT requires at least two sequences because a one-record alignment has no analytical value.

## Bottom pane

The implementation invents no new interface. It reuses the FASTA collection's existing resizable bottom pane and its existing `FASTASelectionDetailView`, plus the existing shared `BlastResultsDrawerTab`/`BlastResultsDrawerContainerView` presentation used elsewhere in Lungfish.

- Ordinarily, selecting rows shows their complete FASTA text exactly as it does now.
- Starting BLAST collapses the selected-FASTA detail and opens the existing shared BLAST drawer below the collection split, using Lungfish's established lazy ensure/open pattern. The drawer shows submission, waiting, and parsing progress.
- Completion displays the shared BLAST result presentation, including the normal result details and links.
- Failures remain visible in that same existing presentation with a useful message.
- The existing Cancel and Rerun controls stop the active request or repeat the most recent request.
- Explicit Cancel closes the loading drawer and restores the selected-FASTA detail; it never leaves a cancelled request looking active.
- A subsequent row-selection change closes the BLAST drawer and restores the ordinary selected-FASTA text at its saved height. If BLAST is still loading, that selection change cancels the request so later progress cannot reopen the drawer for the old rows. Invoking BLAST again reuses the retained BLAST presentation and state.
- If a newer BLAST starts before an older request finishes, only the newer request may update the pane.

There is no new mode selector, tab bar, wrapper view, nested divider, or Savont-specific result UI. The selected-FASTA detail and BLAST drawer are never shown simultaneously. The collection controller adds only the state/routing glue needed to collapse one existing lower presentation and open the other.

## Selected FASTA materialization and provenance

Any action that stages selected sequences writes one normalized `selection.fasta` plus canonical root provenance. The provenance records:

- Lungfish app workflow/tool name and version;
- reproducible command/arguments and resolved defaults;
- original FASTA/Savont source paths and readable upstream provenance;
- selected sequence identifiers and count;
- output path, checksum, and file size;
- application/runtime identity, exit status, wall time, and useful error context.

Temporary staging must not become the only provenance anchor. For the Savont/standalone-FASTA path, **Create Bundle** directly runs Lungfish's existing `lungfish-cli extract contigs --contigs … --contig … --bundle` workflow against the durable source FASTA. That command accepts one or many selected identifiers, creates the `.lungfishref` itself, and writes its canonical provenance. The final bundle therefore records the command that actually ran and never depends on a temporary `selection.fasta`.

The collection display captures its durable source URLs when the collection is opened. Actions use that captured collection scope rather than inferring provenance later from mutable viewer-global state. This is required because multi-sequence documents enter the collection before the ordinary single-document viewer state is assigned.

Single-source staged operation inputs retain a durable replay command using the same existing `extract contigs` primitive and naming each selected identifier. Multi-document selection remains on the existing multi-document workflow rather than pretending that a single-source command can replay several files. Annotated extraction records both the selected FASTA content and projected annotation definitions, including the generated BED checksum and size, when it attaches the annotation track.

Temporary selected-FASTA roots have an explicit lifecycle. They are registered synchronously in session storage before being returned, remain readable while a share sheet or operation dialog consumes them, and are synchronously removed when the app quits. Failed staging removes its complete temporary root immediately.

Create Bundle uses the analyst-facing suggested name rather than the internal `selection.fasta` staging filename.

Clipboard-only copying does not create scientific output on disk and therefore does not need a sidecar. File export, share staging, bundle creation, alignment, and generic FASTA operations do.

## Error handling

The action path must not silently return after a failed write, temporary bundle creation, helper launch, or export. Errors are reported through the normal operation UI or a focused alert that names the failed action and provides a useful reason. A failed action must not leave a success state or an apparently valid partial output.

## Performance and accessibility

Menu rebuilding and selection reconciliation use existing in-memory row data. Provenance checksums are computed only when an action creates a staged or durable file. BLAST remains asynchronous and never blocks the main thread.

The reused loading state, error state, Cancel, and Rerun controls retain their existing accessibility labels. Disabled menu explanations are accessible, and keyboard/standard menu invocation operates on the current selection when there is no clicked row.

## Verification

Automated tests cover every action with one and multiple rows, selection reconciliation, action enablement at boundary counts, exact record order, loadable canonical provenance, helper argument forwarding, MAFFT routing, and BLAST loading/results/failure/cancel/rerun/stale-run behavior without contacting the network.

The existing `extract contigs` command is exercised with one and multiple selected identifiers and is verified to create a bundle whose provenance records the durable source, selected identifiers, output checksums/sizes, and actual CLI argv. Lifecycle tests prove registered temporary roots are removed on staging failure or application termination.

Manual verification uses a real Savont output and exercises all seven actions with one row and two rows, plus right-clicking inside and outside an existing selection. Exported and staged FASTA data and provenance are inspected, BLAST results are confirmed in the bottom pane, and MAFFT is confirmed as the preselected operation.

## Acceptance criteria

1. Every context action targets exactly the intended one or several visible rows.
2. BLAST progress and results are visible in the bottom pane and support cancel/rerun safely.
3. MAFFT is only available for meaningful multi-sequence selections and opens preselected.
4. Extract, export, bundle, and generic operation failures are visible to the user.
5. Every disk-backed scientific output or staged scientific input has canonical, durable provenance.
6. Existing ordinary FASTA viewing and Savont output viewing continue to share one implementation.
7. Multi-sequence actions always use the collection's captured durable source, never a stale previously viewed source.
8. Cancelling BLAST restores the normal FASTA detail immediately.
9. Derived bundle naming and temporary-root cleanup match the requested name and existing safe cleanup policy.

# Assembly Result Contig Viewport Design

Date: 2026-04-19
Status: Proposed
Branch: `codex/assembly-xcui-pilot`

## Summary

Replace the current stub `AssemblyResultViewController` with a classifier-style multi-part assembly result viewport centered on truthful contig browsing.

The v1 viewport should let users:

- browse and filter contigs from real assembly outputs
- inspect the nucleotide sequence of the selected contig or selection
- copy visible contig information quickly
- copy selected contigs as FASTA
- export selected contigs to a new FASTA file
- create a new `.lungfishref` bundle from selected contigs
- inspect assembly-level provenance and source artifacts

The viewport should look and behave like Lungfish’s classifier result browsers in overall shell and interaction quality, while remaining honest about what the assembly output actually contains. In v1, Lungfish should show real contig identity, size, sequence, and assembly provenance. It should not invent per-contig biology that is not present in the result model.

All sequence-materialization actions must be backed by `lungfish-cli`, not by ad hoc AppKit file I/O in the viewport controller.

## Goals

- Replace the current placeholder assembly viewport with a production-quality result browser.
- Follow the multi-part classifier viewport style: summary strip, filtered list, detail pane, and action surface.
- Support the same movable pane layouts the classifier views already expose.
- Make assembled contigs explorable as first-class project outputs.
- Keep the visible field set biologically and bioinformatically defensible.
- Support multi-selection for downstream reuse of selected contigs.
- Back sequence extraction, FASTA export, bundle creation, and BLAST sequence handoff through a CLI-backed path.
- Preserve room for future graph or annotation work without forcing that scope into v1.

## Non-Goals

- Do not build a Bandage-style GFA graph browser in v1.
- Do not introduce fake or inferred per-contig fields such as taxonomy, circularity, coding density, coverage depth, or completeness unless the underlying data model actually provides them.
- Do not turn the viewport into a general-purpose assembly curation workbench.
- Do not make broad external metadata import a core part of the first viewport tranche.
- Do not represent selected-contig exports as a new assembly analysis. They are derived reference subsets.
- Do not resume deep assembly XCUI work as part of this spec. Product-side foundations come first.

## Current State

The repo already has the rough pieces, but not the finished assembly viewer:

- `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
  - still uses a stub table and placeholder actions
  - currently routes BLAST with empty sequences
  - does not expose a true contig-detail view
- `Sources/LungfishWorkflow/Assembly/AssemblyResult.swift`
  - stores assembly-level metadata and artifact paths
  - does not yet provide a per-contig model
- classifier result browsers already establish the shell Lungfish should emulate:
  - summary bar
  - filterable list/table
  - detail pane
  - action bar
- the codebase already has indexed FASTA readers that can support random contig access:
  - `IndexedFASTAReader`
  - `BgzipIndexedFASTAReader`
  - `SyncBgzipFASTAReader`
- the CLI already supports extraction in other domains, but there is no assembly-contig equivalent yet:
  - `lungfish extract sequence`
  - `lungfish extract reads`

This means the missing work is not “invent an assembly browser from nothing.” The missing work is to connect the real assembly result model, indexed FASTA access, and classifier-style UI shell into one coherent viewport.

## Recommended V1 Viewport

Use a classifier-like multi-part shell, but keep the assembly-specific emphasis on `list first, sequence second`.

The assembly viewport must not lock users into a single left/right arrangement. It should follow the same pane-layout model as the classifier views.

`List | Detail`

```text
+---------------------------------------------------------------+
| Summary Strip                                                 |
+---------------------------------------------------------------+
| Contig List + Filters          | Contig Detail                |
|                                |                              |
| classifier-style table         | overview                     |
| per-column filters             | sequence                     |
| multi-select                   | assembly context             |
| keyboard + pointer             | source artifacts             |
+---------------------------------------------------------------+
| Action Bar                                                    |
+---------------------------------------------------------------+
```

`Detail | List`

```text
+---------------------------------------------------------------+
| Summary Strip                                                 |
+---------------------------------------------------------------+
| Contig Detail                 | Contig List + Filters         |
|                               |                               |
| overview                      | classifier-style table        |
| sequence                      | per-column filters            |
| assembly context              | multi-select                  |
| source artifacts              | keyboard + pointer            |
+---------------------------------------------------------------+
| Action Bar                                                    |
+---------------------------------------------------------------+
```

`List Over Detail`

```text
+---------------------------------------------------------------+
| Summary Strip                                                 |
+---------------------------------------------------------------+
| Contig List + Filters                                         |
| classifier-style table                                        |
| per-column filters                                            |
| multi-select                                                  |
+---------------------------------------------------------------+
| Contig Detail                                                 |
| overview, sequence, assembly context, source artifacts        |
+---------------------------------------------------------------+
| Action Bar                                                    |
+---------------------------------------------------------------+
```

The global app inspector remains separate. The assembly viewport’s own detail pane lives inside the main viewer content area and is not a replacement for the app-level inspector.

### Pane Layout Modes

The assembly viewport should inherit the same layout modes already used by the classifier views:

- `Detail | List`
- `List | Detail`
- `List Over Detail`

This should use the shared pane-layout foundation rather than a custom assembly-only implementation.

For the first pass, the assembly viewport should honor the same persisted layout preference the classifier views already use, unless that preference is later generalized into a broader viewer-wide setting.

Requirements:

- the selected layout persists across launches
- switching layouts preserves the current row selection, filters, and detail state
- divider positions follow the same clamp and restoration rules as the classifier views
- the action bar remains bottom-anchored in all three layouts
- accessibility identifiers remain stable enough that layout changes do not break automation

## Viewport Structure

### 1. Summary Strip

The top strip should present assembly-wide context in the same concise, glanceable style as the classifier summary bars.

Required fields:

- `Assembler`
- `Read Type`
- `Contigs`
- `Total Assembled bp`
- `N50`
- `L50`
- `Longest Contig`
- `Global GC`

Secondary fields when available:

- `Assembler Version`
- `Wall Time`

The summary strip is assembly-level only. It should not try to summarize unsupported concepts such as contig taxonomy or annotation richness.

### 2. Contig List

The list is the primary navigation surface. It should feel like the classifier tables, including search, sorting, multi-selection, and per-column filtering.

Required fixed columns:

- `Rank`
- `Contig`
- `Length (bp)`
- `GC %`
- `Share of Assembly (%)`

Column semantics:

- `Rank` is length rank, descending by default.
- `Contig` is the FASTA record identifier shown to the user.
- `Length (bp)` is the contig length from the indexed FASTA.
- `GC %` is computed from the actual contig sequence, not guessed.
- `Share of Assembly (%)` is `contig length / total assembled bp`.

Required filter behaviors:

- free-text search on contig identifier and full header text
- per-column text filter for `Contig`
- numeric range filters for `Length (bp)`, `GC %`, and `Share of Assembly (%)`
- default sort by `Length (bp)` descending

The list should support multi-selection without collapsing accessibility or keyboard behavior.

### 3. Detail Pane

The detail pane should change by selection state.

#### No Selection

Show an empty state that explains what the viewport is for and how many contigs are available.

#### Single Selection

Show four sections.

`Contig Overview`

- contig identifier
- full FASTA header
- rank
- length
- GC %
- share of assembly

`Sequence`

- read-only FASTA-style nucleotide presentation for the selected contig
- monospaced, selectable text
- clear selected-contig title above the sequence

`Assembly Context`

- assembler
- read type
- assembler version when known
- wall time
- core run statistics already present on `AssemblyResult`
- originating analysis or output directory context when available

`Source Artifacts`

- contigs FASTA path
- graph path if present
- scaffolds path if present
- log path if present
- params path if present

#### Multi-Selection

Do not concatenate all selected sequences into one giant detail view by default.

Show a selection summary instead:

- selected contig count
- total selected bp
- longest selected contig
- shortest selected contig
- length-weighted GC % across the selected contigs

Sequence-bearing actions still operate on the full selected set through the action bar and context menu.

## Interaction Model

### Quick Copy

Support a fast copy gesture for visible scalar information:

- command-click on a summary value copies that value
- command-click on a detail value copies that value
- command-click on a table cell copies that visible cell value

This quick-copy behavior is for lightweight scalar values only. It does not replace explicit sequence materialization actions.

### Sequence Materialization Actions

The viewport must expose these actions for the current selection:

- `Copy FASTA`
- `Export FASTA…`
- `Create Bundle…`
- `BLAST Selected`

These actions should exist in both:

- the bottom action bar
- the table context menu

`Copy FASTA` copies FASTA text for the selected contigs to the pasteboard.

`Export FASTA…` writes a new FASTA file containing only the selected contigs.

`Create Bundle…` creates a new `.lungfishref` bundle from the selected contigs.

`BLAST Selected` must stop using placeholder empty sequences and should receive real FASTA payloads for the selected contigs.

### Reveal / Utility Actions

The detail pane may also expose non-materialization utilities:

- `Reveal Analysis Folder`
- `Reveal Contigs FASTA`
- `Open Run Log`

These are convenience actions, not core workflow actions.

## CLI Contract

Add a new CLI primitive under `extract`.

### New Command

`lungfish extract contigs`

This command is the single backend for:

- copy selected contigs as FASTA
- export selected contigs as FASTA
- create selected-contig reference bundles
- providing real FASTA payloads for BLAST handoff

### Supported Inputs

The command should accept an assembly result in one of these forms:

- an assembly analysis directory
- an `assembly-result.json` sidecar location
- a direct contigs FASTA path

### Required Selection Inputs

At minimum:

- repeated `--contig <name>`
- `--contig-file <path>` for batch selection

### Output Modes

`FASTA output`

```bash
lungfish extract contigs \
  --assembly /path/to/analysis \
  --contig contig_7 \
  --contig contig_12 \
  -o /path/to/selected.fasta
```

`Reference bundle output`

```bash
lungfish extract contigs \
  --assembly /path/to/analysis \
  --contig-file /path/to/selection.txt \
  --bundle \
  --bundle-name SelectedContigs \
  --project-root /path/to/project
```

The command should:

- resolve the real contigs FASTA
- materialize only the requested contigs
- preserve source headers
- emit deterministic FASTA ordering based on the selection order provided to the command

The app should pass selected contigs to the CLI in the current table order so copy, export, and bundle actions stay predictable after the user sorts or filters the list.

### Bundle Semantics

Selected-contig bundle creation must produce a `.lungfishref` bundle, not a new assembly-result document.

That bundle must clearly record that it is:

- a derived subset
- produced from a source assembly result
- based on a named contig selection

The provenance should include:

- source assembly tool
- source assembly path or identifier
- source contig FASTA path
- selected contig names
- selection timestamp

The simplest honest implementation path is to materialize a subset FASTA through `lungfish extract contigs` and then build the `.lungfishref` bundle through the existing reference-bundle pipeline.

## Data Model And Loading Strategy

Add a dedicated per-contig view model layer rather than teaching `AssemblyResult` itself to hold full contig sequences.

### New Contig Catalog Layer

Introduce a workflow/service layer that can provide:

- contig identifiers
- full FASTA headers
- lengths
- GC %
- share-of-assembly values
- random-access sequence fetch for a selected contig

This layer should prefer indexed FASTA access:

- `IndexedFASTAReader` for plain indexed FASTA
- `BgzipIndexedFASTAReader` or `SyncBgzipFASTAReader` when compressed indices exist

It should not eagerly load every contig sequence into memory just to populate the table.

### Loading Policy

Initial viewport load should prioritize fast list readiness:

- load identifiers and lengths first
- compute or hydrate GC values without blocking the first paint
- fetch full sequence only for the current detail selection

This keeps large assembly outputs usable while still allowing truthful sequence display.

## Visual And Interaction Consistency

The viewport should explicitly borrow the classifier browser vocabulary:

- concise summary bar at the top
- searchable table with visible filtering affordances
- split-pane detail presentation with the same movable layout modes as classifier views
- bottom action bar for selection-scoped actions
- accessible multi-selection behavior

It does not need to mimic classifier domain content, but it should feel like the same family of result browsers.

## Accessibility Requirements

The assembly viewport should be keyboard- and automation-ready from the start.

Required basics:

- stable accessibility identifiers for the viewport root, table, search field, action buttons, and major detail sections
- meaningful accessibility labels for summary fields and artifact actions
- keyboard-reachable table filtering and row selection
- predictable focus order between filters, table, detail pane, and action bar
- multi-selection state announced clearly enough for assistive technologies to understand selection count

The command-click copy affordance must not be the only path to copy important information. Equivalent keyboard or menu-driven alternatives must exist.

## Explicit Deferrals

These should be called out as deliberate follow-on work, not silent omissions:

- GFA or assembly graph visualization
- broad CSV or TSV metadata import onto contigs
- per-contig biological annotations not already present in the source data
- contig coverage overlays
- circularity or plasmid-specific inference surfaces
- ORF prediction or translated-protein views

If later work introduces contig-keyed annotations, the table/filter architecture from this spec should be reused rather than replaced.

## Gaps This Spec Is Meant To Close

The current product gaps that should be tracked in the accompanying review/report are:

- the assembly result viewport is still a stub rather than a real browser
- BLAST integration for assembly contigs still uses placeholder empty sequences
- there is no indexed per-contig catalog layer for assembly results in the app
- there is no `lungfish extract contigs` CLI primitive
- selected-contig bundle creation does not yet have honest derived-subset semantics
- the assembly result UI does not yet match the classifier multi-part viewport quality bar
- accessibility identifiers and keyboard behavior for this viewport are not yet established

## Testing Direction

Because assembly XCUI is intentionally paused until more basic product behaviors settle, the first verification layer for this work should be:

- workflow tests for contig catalog loading and sequence extraction
- CLI tests for `lungfish extract contigs`
- app tests for list filtering, selection-state detail changes, and action routing
- provenance tests for selected-contig bundle creation

Once the viewport and action model are stable, this surface becomes a much better XCUI target than the current stub.

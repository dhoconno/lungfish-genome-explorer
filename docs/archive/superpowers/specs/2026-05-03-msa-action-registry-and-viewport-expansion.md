# Expanded Multiple Sequence Alignment Action Registry and Viewport Spec

Date: 2026-05-03
Branch: `codex/alignment-tree-viewers`

## Goal

Make the `.lungfishmsa` viewport useful as a biological workbench, not only as a static rendering of MAFFT output. The action model must be shared by:

- the native alignment viewport
- Inspector and bottom annotation drawer
- right-click/context menus
- Operation Center
- `lungfish-cli`
- XCUI and artifact tests

Any action that creates, modifies, exports, wraps, or transforms scientific data must be CLI-backed and must write complete reproducibility provenance. Purely visual actions can remain app-local, but their accessibility and graphical behavior still need tests.

## Expert Group Synthesis

Biology group consensus:

- Biologists use MSA tools to inspect conservation, variation, indels, motifs, domains, primers, CDS effects, and tree-readiness.
- Row, column, and rectangular block selection are core, not optional.
- Annotation tracks need to be visible in the alignment and usable as landmarks for selecting, centering, zooming, extracting, and projection.
- Trimming, masking, extraction, consensus creation, and tree handoff must be reproducible derived outputs rather than silent in-place edits.

UI/UX group consensus:

- The central viewport should be dedicated to alignment exploration.
- Statistics belong in the Inspector.
- The bottom drawer should stay focused on annotations first, then optional MSA-specific tabs for Sites and Rows.
- Navigation should include overview/minimap, go-to, search, previous/next variable site, previous/next annotation, and fit/center/zoom actions.
- Every important action needs stable accessibility identifiers and keyboard-accessible equivalents.

Software architecture group consensus:

- Keep `.lungfishmsa` immutable for transformations; create derived bundles with lineage.
- Keep annotation edits in the MSA annotation store, but write edit provenance.
- Split the monolithic MSA bundle implementation over time into parser, writer, manifest, annotation store, SQLite index, and provenance modules.
- Add a shared action registry used by CLI, GUI, and tests.

QA/CLI group consensus:

- Add `lungfish msa actions` and `lungfish msa describe` first so CLI/UI/tests share the same action contract.
- Every data-changing action must declare a CLI contract and provenance requirement.
- Operation Center should consume uniform JSON event envelopes for MSA actions.
- XCUI must stop depending on stale identifiers and should test the actual matrix, row gutter, annotation tracks, and inspector state.

## External Tool Survey

The registry is based on recurring features in current graphical MSA tools:

- Geneious supports alignment viewing/editing, highlighting, graphs, masking, consensus, translation alignment, MAFFT/MUSCLE/Clustal workflows, and command-line details for tool runs: [Geneious Alignments](https://manual.geneious.com/en/latest/Alignments.html).
- Jalview has alignment, sequence, group, and reference annotation rows; annotation can drive coloring, selection, and hiding; it also supports hidden rows/columns and linked tree selections: [Jalview Annotation](https://www.jalview.org/help/html/features/annotation.html), [Select/Hide Columns by Annotation](https://www.jalview.org/help/html/features/columnFilterByAnnotation.html), [Hidden Regions](https://www.jalview.org/help/html/features/hiddenRegions.html), [Tree Viewer](https://www.jalview.org/help/html/calculations/treeviewer.html).
- UGENE emphasizes region selection, alignment overview/navigation, consensus, highlighting, and alignment editing: [UGENE Alignment Editor](https://ugene.net/docs/alignment-editor/working-with-alignment/).
- NCBI MSAV documents panorama navigation, row metadata columns, row expansion for sequence annotations, consensus/anchor rows, search, hiding rows, coloring modes, and download/export behavior: [NCBI MSA Viewer Guide](https://www.ncbi.nlm.nih.gov/tools/msaviewer/tutorial1/).
- AliView emphasizes large-alignment speed, unlimited zoom, color schemes, consensus/reference difference highlighting, translated nucleotide coloring, realigning selected blocks, and manual keyboard/mouse editing: [AliView](https://ormbunkar.se/aliview/).
- CLC Genomics Workbench exposes multiple views for alignments including alignment, primer designer, and annotation table, plus tree construction workflows: [CLC View Alignments](https://resources.qiagenbioinformatics.com/manuals/clcgenomicsworkbench/2600/index.php?manual=View_alignments.html).

## Canonical Registry

The code-level registry lives in:

- `Sources/LungfishIO/Bundles/MultipleSequenceAlignmentActionRegistry.swift`

The CLI discovery surface is:

```bash
lungfish msa actions --format json
lungfish msa actions --category annotation --cli-backed --format tsv
lungfish msa describe msa.alignment.mafft --format json
```

Registry fields:

- `id`: stable action identifier such as `msa.transform.mask-columns`
- `category`: navigation, selection, inspection, display, rows, annotation, transform, export, alignment, phylogenetics
- `priority`: P0/P1/P2
- `summary` and `userIntent`
- `surfaces`: viewport, toolbar, inspector, drawer, context menu, menu bar, command line, Operation Center
- `createsOrModifiesScientificData`
- `requiresProvenance`
- `cli` contract when the action is data-changing or otherwise CLI-backed
- `implementationStatus`
- `accessibilityRequirement`
- `testRequirement`

Validation rule: any action that creates or modifies scientific data must require provenance and declare a CLI contract. Missing provenance is blocking.

## P0 Feature Set

P0 actions are the first target for a usable expert workflow:

- `msa.navigation.overview`: overview/minimap for long alignments
- `msa.navigation.goto-column`: go to column, ungapped coordinate, annotation, row, or feature
- `msa.navigation.variable-sites`: next/previous variable and informative sites
- `msa.selection.cell`: single residue inspection
- `msa.selection.block`: rectangular row/column block selection
- `msa.selection.rows`: multi-row selection from gutter/drawer/search
- `msa.inspection.selection-stats`: selection statistics in the Inspector
- `msa.inspection.coordinate-map`: aligned/source/consensus/codon coordinate display
- `msa.display.color-scheme`: residue, conservation, difference, codon, no-color modes
- `msa.display.consensus`: consensus row and quantitative tracks
- `msa.display.annotations`: visible source/projected/manual annotation tracks
- `msa.annotation.add`: add annotation from selected alignment region
- `msa.annotation.project`: project trusted annotation to selected rows
- `msa.transform.extract-selection`: extract selected rows/columns to FASTA or derived MSA; reference bundle output remains a follow-on once annotation semantics are specified
- `msa.transform.mask-columns`: explicit, gap-threshold, and annotation-driven non-destructive masks as derived bundles now; codon-position selectors remain follow-on work after CDS/reference coordinate semantics are finalized
- `msa.transform.trim-columns`: native gap-only and gap-threshold trimming as derived bundles now; external `trimAl`/`ClipKIT` wrappers remain follow-on work
- `msa.transform.consensus`: consensus FASTA output now; reference bundle output remains a follow-on once annotation semantics are specified
- `msa.phylogenetics.distance-matrix`: pairwise-deletion identity and p-distance TSV matrices with provenance sidecars now; Kimura and other model-corrected distances remain follow-on work
- `msa.alignment.mafft`: existing MAFFT workflow with complete provenance
- `msa.export.alignment-formats`: export selected/full/visible/masked alignments, warning when the target format cannot represent MSA annotations
- `msa.export.copy-fasta`: copy selected FASTA

## Viewport Requirements

The MSA viewport must keep the full central area for the alignment:

- frozen row-name gutter
- frozen site ruler
- scrollable residue matrix
- visible annotation tracks over rows
- optional consensus/conservation/gap tracks
- overview strip for long-range navigation
- no statistics table in the viewport

Inspector responsibilities:

- bundle-level MSA metadata and provenance
- selected row/site/block statistics
- coordinate conversion
- display settings
- active reference/anchor row
- selected annotation details

Bottom drawer responsibilities:

- Annotations tab using the same annotation-table idiom as `.lungfishref`
- Sites tab after P0 selection/statistics are stable
- Rows tab after row pin/hide/sort/filter are stable

## CLI and Operation Center Contract

Existing stable command:

```bash
lungfish align mafft <inputs...> --project <project> [options] --format json
```

Planned registry-backed command families:

```bash
lungfish msa actions --format json
lungfish msa describe <action-id> --format json
lungfish msa annotate add <bundle.lungfishmsa> --row <row> --columns <start-end> --name <name> --type <type> --format json
lungfish msa annotate edit <bundle.lungfishmsa> --annotation <id> [--name <name>] [--type <type>] [--strand +|-|.] [--note <text>] --format json
lungfish msa annotate delete <bundle.lungfishmsa> --annotation <id> --format json
lungfish msa annotate project <bundle.lungfishmsa> --source-annotation <id> --target-rows <rows> --format json
lungfish msa export <bundle.lungfishmsa> --output-format fasta --output <path> --rows <rows> --columns <ranges> --format json
lungfish msa extract <bundle.lungfishmsa> --rows <rows> --columns <ranges> --output <path> --output-kind fasta|msa --format json
lungfish msa mask columns <bundle.lungfishmsa> --ranges <ranges>|--gap-threshold <value>|--annotation <id> --output <path> [--reason <text>] --format json
lungfish msa trim columns <bundle.lungfishmsa> --gap-only|--gap-threshold <value> --output <path> --format json
lungfish msa consensus <bundle.lungfishmsa> --threshold <value> --gap-policy omit|include --output <path> --format json
lungfish msa export <bundle.lungfishmsa> --output-format phylip|nexus|clustal|stockholm|a2m|a3m --output <path> --format json
lungfish msa distance <bundle.lungfishmsa> --model identity|p-distance --output <path> --format json
```

Uniform event envelope:

```json
{"event":"msaActionStart","actionID":"msa.transform.mask-columns","operationID":"...","message":"Starting mask operation."}
{"event":"msaActionProgress","actionID":"msa.transform.mask-columns","operationID":"...","progress":0.5,"message":"Writing derived bundle."}
{"event":"msaActionComplete","actionID":"msa.transform.mask-columns","operationID":"...","output":"/final/path/out.lungfishmsa","warningCount":0}
```

Every Operation Center row must surface:

- action ID and human title
- inputs and final output bundle/file
- progress, warnings, failure details, and cancel state
- provenance availability

## Provenance Contract

For every data-changing action, provenance must include:

- Lungfish workflow/action name and version
- external tool name/version where applicable
- exact Lungfish wrapper argv and reproducible shell command
- resolved defaults and user-visible options
- conda environment, executable path, and container/runtime identity where applicable
- input/output paths, sizes, checksums
- bundle lineage and selected row/column/mask semantics
- exit status, wall time, stderr when useful
- final stored payload paths, not transient staging paths

## Accessibility and XCUI

P0 stable identifiers:

- `multiple-sequence-alignment-bundle-view`
- `multiple-sequence-alignment-row-gutter`
- `multiple-sequence-alignment-column-header`
- `multiple-sequence-alignment-matrix-view`
- `multiple-sequence-alignment-text-view`
- `multiple-sequence-alignment-overview`
- `multiple-sequence-alignment-search-field`
- `multiple-sequence-alignment-site-mode`
- `multiple-sequence-alignment-annotation-track-<row>-<annotation>`

XCUI must cover:

- opening MSA/tree fixtures
- matrix nonblank and annotation lane visible
- cell/block/row/column selection
- context menu enablement
- Add Annotation from Selection
- Apply Annotation to Selected Rows
- next/previous variable site
- go-to/search
- Operation Center progress for CLI-backed transformations
- provenance visible on derived outputs

Graphical tests should use semantic pixel assertions rather than brittle full screenshots: residue colors present, selected block visible, annotation track visible, no overlap between toolbar/matrix/drawer/inspector.

## Deferred Features

Manual editing, linked tree/alignment views, primer/probe design, BLAST/database handoff, and publication-grade SVG/PDF figure export are useful but should follow after P0 selection, annotation, transformation, export, and provenance are solid.

# MSA viewport and sequence extraction

Date: 2026-09-03
Status: reviewed by bioinformatics, UX, and Swift/AppKit experts; approved for planning
Branch: `claude/mafft-msa-viewport-fixes-7762b4`

## Problem

Six defects reported against the MAFFT multiple sequence alignment (MSA)
viewport and the FASTA paths adjacent to it. Each is stated below with the
code path that actually causes it, established by reading the source rather
than from the symptom alone.

### 1. No "extract selected sequences to a new bundle" on a FASTA bundle

Partly false as reported, and that matters for the fix. The multi-sequence
FASTA viewport already builds a context menu through
`FASTASequenceActionMenuBuilder.buildItems`, and that menu already carries
`Create Bundle…`, wired in `ViewerViewController` to `createReferenceBundle`.
For a durable single-FASTA source it runs `extract contigs --bundle` and
writes a new `.lungfishref` into `Reference Sequences/`.

Three real gaps remain:

- The item is named `Create Bundle…`. It does not say it acts on the
  selection, so a user looking for "extract selected sequences" does not
  recognise it.
- Nothing equivalent exists in the sidebar. Right-clicking the FASTA bundle
  itself offers `Export Sequences…` for the whole bundle only.
- The reference-bundle viewport, reached by selecting a `.lungfishref` in the
  sidebar, shows its sequences in `ChromosomeNavigatorView`, whose context menu
  offers only Copy Name, Copy Length, and Show in Inspector, and whose table is
  `allowsMultipleSelection = false`. There is no selection to extract from.

### 2. MSA runs on all sequences when a subset is selected

The selection is honoured on one path and silently lost on the other, and
neither path tells the user which happened.

From the viewport context menu, `Align with MAFFT…` passes the selected
sequences to `presentFASTAOperationDialog`, which stages them into a temporary
bundle holding `selection.fasta` and opens the operations dialog over that one
URL. The alignment is therefore already subset to the selection, invisibly.

From the Tools menu, `Multiple Sequence Alignment` resolves inputs from the
sidebar selection instead and aligns every record in the file.

By the time the dialog opens, the original record count is gone:
`FASTQOperationDialogState` sees only `selectedInputURLs`, and
`MSAAlignmentRunRequest` has no include-list field. `stageInputFASTA` in
`MAFFTAlignmentPipeline` writes every record it reads.

### 3. The MSA viewport overdraws the bottom drawer

`installNativeBundleSubview` pins the MSA view to `view.bottomAnchor` and adds
it last, so it covers the parent viewer's `annotationDrawerView` in both
geometry and z-order. `hideForNativeAlignmentTreeBundle` sets that drawer
hidden, which masks the bug, but eleven other display paths and
`toggleAnnotationDrawer` set `isHidden = false` again without re-checking
whether a native bundle owns the viewport. The screenshot shows the result:
MSA gutter rows painted over the drawer's Annotations / Variants / Samples tab
bar and search field.

The app already has the correct pattern. `updateViewerBottomConstraints` in
the annotation-drawer extension re-targets the genomics stack's bottom
constraint from `statusBar.topAnchor` to `drawer.topAnchor`. The chromosome
navigator relies on that same re-targeting and comments on it explicitly.
`installNativeBundleSubview` stores no constraint and participates in none of
this.

A second, related fact: the MSA controller owns its own 126pt annotation
drawer pinned to its own bottom. Two drawers stacked in the same place is not
a design anyone chose.

### 4. No aligned-FASTA export from an MSA bundle

The MSA canvas offers `Export FASTA…` and `Create Bundle…`, but both act on a
rectangular selection and both export ungapped residues via
`msa extract`. There is no way to get the aligned FASTA, gaps intact, for the
whole bundle, and no clipboard leg at all for aligned output.

The CLI already supports it: `msa export --output-format aligned-fasta`.
`CLIMSAActionCommandBuilder.buildExportArguments` is written, tested, and
called from nowhere in the app.

The sidebar offers nothing for a `.lungfishmsa`:
`SidebarItemType.bundleCapabilities` gives it the baseline open / show
contents / get info only.

On the reported Command-click: nothing in the sidebar or the MSA canvas
treats the Command modifier as a menu trigger, and macOS reserves
Command-click in a list for discontiguous selection. Adding a second meaning
would break selection. This design uses right-click, which is the platform
gesture for a context menu and is what the sidebar already uses everywhere.

### 5. The MSA name column cannot be resized

`MSAAlignmentCanvasMetrics.rowGutterWidth` is a `static let` of 232 points
feeding three width constraints. Inside it, row index takes 32 points and the
source-coordinate range takes 58, leaving about 122 points for the name. Long
identifiers such as `2_LC739922.1_Influenza…` truncate. The divider at the
gutter's trailing edge is a painted line with no hit-testing, no cursor
change, and no mouse handling.

### 6. Inspector and viewport options need review; the AI Assistant tab is dead

`InspectorViewModel.availableTabs` returns `.ai` for every `.genomics`
document unconditionally. `AppSettings.aiSearchEnabled` defaults to false, so
by default selecting the tab posts a notification that raises an
"AI Assistant Disabled" alert and leaves an empty pane behind. The tab is
inert for any user who has not configured a provider.

The MSA canvas menu also passes `onBlast: nil`, `onAlignWithMAFFT: nil`, and
`onRunOperation: nil`, while `onRunOperationRequested` is wired by the caller
and `runOperationOnSelectedSequences` exists and is unreachable.

## Design

Seven work items. Every one keeps CLI parity: the GUI action shells out to
`lungfish-cli` and reports through `OperationCenter`, matching
`createReferenceBundleDirectlyFromDurableFASTA` and `exportMSASelectionViaCLI`.

### A. Name the FASTA extraction action for what it does

Rename the shared menu item from `Create Bundle…` to `Extract to New Bundle…`,
and give `FASTASequenceActionHandlers` a `createBundleMenuTitle` property
defaulting to that string, following the existing `blastMenuTitle` precedent.
It keeps its current position, after `Export FASTA…`.

The MSA canvas passes `Extract Selection to New Bundle…`, since there the unit
is a rectangular block rather than whole sequences. It also renames its
`Export FASTA…` to `Export Selected Residues…`, so that item and the new
`Export Aligned FASTA…` from item F cannot be confused for each other.

The longer `Extract Selected Sequences to New Bundle…` was considered and
rejected: every item in that menu acts on the selection and none says so, so
naming it on one item implies the others do not. Peer items are two or three
words.

No behaviour change. `createReferenceBundle` already does the right thing.

### B. Give the reference-bundle viewport a selectable sequence list

Set `allowsMultipleSelection = true` on `ChromosomeNavigatorView`'s table and
add `Extract to New Bundle…` as the first context-menu item, followed by a
separator, then the existing Copy Name, Copy Length, and Show in Inspector.
It is enabled when one or more rows are selected. The view gains an `onExtractSelectedSequencesRequested: (([ChromosomeInfo]) -> Void)?`
callback; `ViewerViewController+BundleDisplay` wires it to a new method that
runs `extract contigs --contig <name>… --bundle --project-root <p>` through
`LungfishCLIRunner`, exactly as the FASTA collection path does.

Single-click selection must keep navigating to the clicked chromosome. With
multi-selection enabled, `tableViewSelectionDidChange` fires once for a
shift-click range, so the navigate handler reads `tableView.selectedRow`, the
last-clicked anchor, rather than assuming one selected row. The chromosome
currently displayed stays displayed even when it is deselected, and the
delegate suppression flag guarding programmatic selection is left alone.

The sidebar gains `Extract Sequences…` on a `.lungfishref`, above the existing
`Export Sequences…`, opening the same selection sheet.

### C. Make MSA sequence scope explicit

Add `includedSequenceNames: [String]?` to `MSAAlignmentRunRequest` as the last
init parameter, defaulting to nil, meaning every record. All eleven existing
call sites stay source-compatible, and `decodeIfPresent` synthesis lets old
persisted requests round-trip.

**Name resolution is the crux of this item, and the obvious approach is
wrong.** `parseFASTA` keeps the entire header line as the record name, so a
GenBank record parses as `MT192765.1 Severe acute respiratory syndrome
coronavirus 2 isolate ...` rather than as `MT192765.1`. Matching only that raw
string would make `--sequence MT192765.1` match nothing for essentially every
real FASTA. Raw names are also not unique: duplicate headers in a concatenated
file are legal, which is why the pipeline's `_2` disambiguator exists at all.

Resolve each requested name through an ordered tiered matcher, mirroring the
precedent already in `selectAlignedRecords` for `--rows`:

1. exact raw `record.name`
2. exact `sanitizedLabel(record.name)`, the label shown in the MSA row gutter
3. the first whitespace-delimited token of the raw name, the FASTA ID
4. the disambiguated `finalLabel`, including any `_2` suffix

First tier that matches wins. A name matching several records is an error
naming the collisions, not a silent multi-include. Unmatched names are
collected across every input file and reported together, after all inputs are
parsed, so a name living in the second of two files is not a false negative.

Filtering happens before label sanitisation in `stageInputFASTA`. Distinguish
the failure messages: `No sequence matched --sequence <name>` is not the same
condition as too few sequences, and the existing `singleSequenceInput` error
must not be made to carry both. When a filter leaves fewer than two records,
say `Select at least two different sequences to align.`

**Provenance.** `defaultWrapperArgv` enumerates every option explicitly and has
no sequence clause, so without a change a subset run would record a canonical
command that re-runs on all sequences. That is a reproducibility defect, not a
cosmetic one. Emit one `--sequence` flag per included name there and on the
GUI-supplied `wrapperArgv` path. Additionally stamp a selection block into the
bundle provenance recording the requested names, the resolved row labels, the
input record count, and the excluded names, following the precedent of
`addSelectionMetadataToBundleProvenance`. Recording only the inclusion list is
nearly enough, but the excluded list is what reveals drift if the source FASTA
is later edited, and the bundle's `inputFiles` checksums cover the whole source
file rather than the subset.

**Guard against realigning an alignment.** `stageInputFASTA` passes `-` through
to MAFFT, which treats gaps as residues, so realigning rows taken from an
existing alignment silently produces garbage. The MSA canvas deliberately does
not offer MAFFT, but the CLI path is reachable. Warn when any input record
contains a gap character, recommending de-gapping first.

**Add `--sequence` (repeatable)** to `lungfish-cli align mafft`, mirroring
`extract contigs --contig`. `CLIMSAAlignmentRunner.buildArguments` passes one
flag per included name.

In the dialog, add a scope control to the MAFFT pane above Strategy, as a radio
group in the idiom of `MultiBundleRunModePicker`:

    Sequences to align
    (•) All sequences (12)
    ( ) Selected sequences (4)

It defaults to selected when a selection arrived from the viewport, and to all
otherwise. `FASTQOperationDialogState` gains `mafftSequenceScope` plus the two
counts, supplied by the presenter. `makeMSAAlignmentRequest` sets
`includedSequenceNames` when scope is selected.

The counts have to reach the dialog. `presentFASTAOperationDialog` currently
destroys them by staging the selection to a temp file. It changes to pass the
durable source URL plus the selected names, when there is exactly one durable
FASTA source and the names resolve, so the dialog can offer a real choice.

When a real choice is not available, which is the multi-source and
synthetic-record fallback and the Tools-menu case with no selection, the radio
group is **omitted entirely** rather than rendered with a disabled row. A radio
group of one is not a choice, and a row disabled for a reason the user cannot
act on is noise. In its place goes a single line of secondary text, either
`Aligning all 12 sequences.` or `Aligning the 4 sequences you selected.`

### D. Stop the MSA viewport overdrawing the drawer

One change, not two. An earlier draft of this design also re-targeted the MSA
view's bottom constraint to the drawer's top. That is wrong and is dropped: a
hidden view still participates in Auto Layout but draws and hit-tests nothing,
so once the drawer is reliably hidden the MSA correctly occupies the full
height. Re-targeting would leave a dead band of empty parent view under the
alignment. `updateViewerBottomConstraints` is also a poor model to copy, since
it mutates by scanning `view.constraints` for a match.

Make the hide decision stateful instead of positional. Add an
`isNativeBundleViewportInstalled` computed property, true when an MSA,
phylogenetic tree, genotype, or 12S controller owns the viewport, and guard
each `annotationDrawerView?.isHidden = false` site behind it.

There are twelve such sites, and the distribution matters for whoever
implements this. Eleven are inside `hideXView()` teardown functions and only
`displayBundleSequence` is a genuine display path. Install ordering already
saves the install itself, because `hideForNativeAlignmentTreeBundle` calls
those teardowns and then sets `isHidden = true` last. The live bug is a
teardown running *after* an MSA is installed, for example a stale
`hideTaxonomyView()` from a later path, which unhides the drawer under the
alignment. An implementer who does not know this will "verify" a fix against a
symptom that install ordering already masks.

`toggleAnnotationDrawer` gets an MSA branch alongside the taxonomy and
TaxTriage branches it already has, which is the established pattern there: a
native bundle viewport has no annotations for the parent drawer to show, and
the MSA has its own.

Rejected alternative: inserting the native view below the drawer in z-order
fixes paint order only, leaving the drawer's search field and tab bar
hit-testable on top of the alignment, and it silently depends on the drawer
already existing.

The MSA keeping its own drawer is correct, since it shows alignment
annotations the parent drawer cannot render. The parent drawer stays hidden
for the whole time a native bundle is installed.

### E. Make the MSA name gutter resizable

Convert `rowGutterWidth` from a static constant to a stored property on the
view controller. It feeds exactly **two** width constraints, the corner header
and the row gutter, which must be held in properties and driven together. The
two remaining reads are arithmetic, not constraints.

Keep the painted divider line and straddle it with an 8-point handle, 4 points
each side, rather than laying a handle over the trailing edge. A visible line
plus a resize cursor is the whole affordance macOS users expect. Set the cursor
through a `.cursorUpdate` tracking area rather than `mouseEntered`, or the
cursor sticks when the view scrolls under a stationary pointer.

Clamp between 160 and 640 points. The floor is 160, not 120, because the name
field is already about 122 points wide at the current setting and truncating,
so a 120-point minimum would let users drag into a state strictly worse than
today.

During a drag, update only the two width constants and defer any column-width
recompute to mouse-up. The gutter already redraws on every scroll, and
recomputing the matrix layout per mouse-moved event would make the drag stutter.

Switch the name field to `.byTruncatingMiddle`, since accession suffixes carry
meaning, and give each row a tooltip with its full name, because truncation
still occurs at the minimum width. Expose the divider as an accessibility
element with role `.splitter`.

Rejected alternative: `NSSplitView`. The gutter, corner header, column header,
overview strip, and scroll view form one coordinated grid in a single
container, and the corner header's width must track the gutter's while sitting
above it. A two-pane split view cannot express that without restructuring the
whole canvas.

Persist under `UserDefaults` key `msaRowGutterWidth`, following the
`annotationDrawerHeight` precedent. Double-clicking the handle sizes the
gutter to the widest visible row label, capped at 600, which is the standard
table-column gesture.

`effectiveVisibleMatrixWidth` and `zoomToAnnotationRange` read the stored
property instead of the constant, or Fit Columns miscomputes after a drag.

### F. Export the aligned FASTA from an MSA bundle

Add `Export Alignment…` to the MSA canvas context menu and to the sidebar
context menu for a `.lungfishmsa`, opening a destination sheet modelled on
`ClassifierExtractionDialog`, which already solves this shape of problem.
Reuse its exact labels and its per-destination primary button title:

| Destination | Button | Produces |
|---|---|---|
| Save as Bundle | Create Bundle | a bundle, kind set by the format below |
| Save to File… | Save | a file at the save-panel URL |
| Copy to Clipboard | Copy | the alignment text on the pasteboard |

The sheet's second axis is gapped versus ungapped, which is the choice that
changes what the object *is*:

- **Aligned FASTA (keep gaps)** runs `msa extract --output-kind msa` for the
  bundle leg, producing a `.lungfishmsa`, and
  `msa export --output-format aligned-fasta` for file and clipboard.
- **Unaligned FASTA (remove gaps)** runs `--output-kind reference`, producing a
  `.lungfishref`, and `--output-format fasta` for file and clipboard.

Both legs are kept. Pulling N sequences out of an alignment to BLAST or
resubmit them is a real workflow, and dropping it would force a manual de-gap.
Gapped residues in a reference bundle would be a data defect, so the bundle
caption states which kind it will write.

I verified these semantics against the CLI rather than assuming them. On the
five-genome SARS-CoV-2 fixture, `aligned-fasta` emits 29,834 columns retaining
35 gap characters; `fasta` emits 29,829 columns with none.

The File destination also offers the other formats `ExportSubcommand` already
supports: PHYLIP, NEXUS, Clustal, Stockholm, A2M, and A3M. The registry
declares these implemented and phylogeneticists hand PHYLIP to RAxML and NEXUS
to MrBayes routinely, so hiding formats the CLI already ships would be a
parity regression. Classic PHYLIP truncates taxon names to ten characters, and
collided names produce a wrong tree rather than an error, so the exporter
verifies uniqueness after truncation and the sheet warns before writing.

Clipboard is capped at 5 MB. Present the cap as a **disabled destination with a
tooltip**, following the classifier dialog, rather than a refusal after the
user commits. The cap binds sooner than users expect, since gapped output is
roughly rows times aligned length, so thirty coronavirus genomes already
exceed it. The tooltip names the size and points at the other destinations.

Rows and columns come from the current selection when the canvas has one. Since
this is a document-scoped action reached from a selection-scoped menu, the
sheet carries a scope control, `Entire alignment (N)` versus `Selected rows (M)`,
shown only when a multi-row selection exists, so the target is never ambiguous.

A column-subset export must not mangle taxon labels. `renameColumnSubsets`
appends a suffix to the record *name*, which propagates into downstream tree
tips. Keep names stable for aligned exports and record the selected source
column intervals in the provenance and the derived bundle's manifest instead.

Note in the sheet's bundle caption that a derived `.lungfishmsa` re-imports
through `importAlignment`, so its consensus and variable sites are properties
of the subset, not of the parent.

Sidebar reach needs a new `canExportAlignment` flag on
`SidebarBundleCapabilities`, true only for `.multipleSequenceAlignmentBundle`.
It must not reuse `canExportSequences`, whose loader only understands a
`.lungfishref` manifest, and it sits in its own `if` block rather than nested
inside the export branch, per the coupling note already written there.

**Concurrency.** The clipboard leg follows `exportMSASelectionViaCLI`: an outer
`Task` on the main actor for the save panel and `OperationCenter.start`, an
inner `Task.detached` for the runner. Read the temp file and check its size on
`Data.count` inside the detached task, off the main actor, then hop back with
`DispatchQueue.main.async { MainActor.assumeIsolated { … } }` carrying only the
resulting string. Never `Task { @MainActor in }` from a detached context, and
remove the temp file in a `defer` inside the closure.

### G. Inspector and viewport option audit

Four dead surfaces, all confirmed against the source.

**The AI Assistant tab.** Filter `.ai` out of `availableTabs` unless
`AppSettings.shared.aiSearchEnabled` is true. Hiding beats showing a disabled
call-to-action: for a scientist who has never configured a provider, a visible
tab is a promise the app cannot keep, and today it produces an alert plus an
empty pane. Discovery belongs in Settings. Two mechanics matter: reset
`selectedTab` to `.bundle` when `.ai` drops out, or the content switch renders
a tab the picker no longer lists, and confirm the view model observes the
setting so the tab appears without a relaunch.

**The Analysis tab is dead for an MSA.** `contentMode` is `.genomics`, so an
alignment gets the Analysis tab, whose body reads "No alignment tracks loaded.
Import a BAM or CRAM file…". There is no BAM in an alignment bundle and never
will be. Omit `.analysis` when the document section holds an MSA document.

**The drawer's Variants and Samples tabs are dead for an MSA.** The tab control
is only disabled inside `setSearchIndex`, and the MSA populates its drawer
through `setAnnotations`, which never touches it. The result is that Samples
exposes Import Metadata, Download Template, Add Sample Field, and Sample
Groups, all acting on nothing. Disable segments one and two from the
`setAnnotations` path so the MSA drawer is an annotations-only table. Fix the
tab control's accessibility label, which omits Samples.

**The canvas menu's dead handlers.** Pass `onRunOperation` through to
`runOperationOnSelectedSequences`, which is wired by the caller and currently
unreachable. `onBlast` and `onAlignWithMAFFT` stay nil deliberately and gain a
comment saying why: BLAST of aligned rows would query gapped sequence, and
realigning an alignment is a different operation from aligning sequences.

The remaining toolbar controls are live: search, zoom in, zoom out, fit
columns, site mode, previous and next variable site, and colour scheme. Two
refinements. Previous and Next Variable silently flip the site mode to
Variable Sites as a side effect and silently no-op when no variable sites
exist; disable both buttons in that case rather than mutating another control
invisibly. They are also the only toolbar controls without accessibility
identifiers; add them.

The Inspector's View tab controls for numbering, consensus thresholds, mask
symbol, reference row, and residue display are all wired through
`onSettingsChanged`. Label the low-support threshold to say it is measured
among non-gap residues, which is what the code does and not what the current
label implies.

## Testing

Unit tests, extending the existing files rather than adding new suites where
one already covers the type:

- `FASTASequenceActionMenuBuilder` item titles, including the MSA override.
- `ChromosomeNavigatorView` multi-selection and menu contents.
- `MSAAlignmentRunRequest` include-list round-trip; `stageInputFASTA` filtering,
  including the fewer-than-two-survivors error and the multi-file case.
- `AlignCommand` `--sequence` parsing into the request.
- `CLIMSAAlignmentRunner.buildArguments` emitting one flag per name.
- The scope control's row states, following
  `testMAFFTPaneRendersCombineLockedMultiBundleRunModePicker`.
- The parent drawer stays hidden across a teardown path that would otherwise
  unhide it while an MSA is installed.
- Gutter width clamping and persistence.
- `buildExportArguments` reaching the runner for each of the three
  destinations.
- `availableTabs` excludes `.ai` when the setting is off and includes it when
  on, excludes `.analysis` for an MSA document, and resets `selectedTab` when
  the active tab disappears.
- The tiered name resolver: each tier matches, ambiguity errors, unmatched
  names are reported together, and the too-few-sequences case is a distinct
  message.
- `defaultWrapperArgv` emits one `--sequence` flag per included name, so the
  recorded command reproduces the subset rather than the whole file.
- A gapped input record triggers the realign-an-alignment warning.

End-to-end, through the CLI on a copy of
`Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish`: align a named subset,
assert the bundle holds exactly those rows, export aligned FASTA, and assert
gaps survive.

GUI verification drives a Debug build against a fresh project: import the
five-genome FASTA, select three sequences, extract to a new bundle, run MAFFT
on the selection, confirm the alignment holds three rows, confirm the drawer is
not overdrawn, drag the name gutter until full identifiers are readable, and
export the aligned FASTA to all three destinations.

## Out of scope

Column-level export presets beyond the current selection, MSA drawer redesign,
and any change to BLAST or IQ-TREE behaviour.

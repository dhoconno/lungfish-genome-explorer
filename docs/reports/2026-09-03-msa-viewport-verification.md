# MSA viewport verification

Date: 2026-09-03
Branch: `claude/mafft-msa-viewport-fixes-7762b4`
Build: `build/Debug/Lungfish Debug.app`, bundle id `com.lungfish.browser.debug`
Project: a fresh copy of the five-genome SARS-CoV-2 fixture, aligned in the app

Every defect below was exercised in the running Debug build. Where a claim
could be checked on disk rather than by eye, it was.

## 1. Extract selected sequences to a new bundle

Selected three of the five sequences in the FASTA collection viewport and
right-clicked. The menu reads:

    Extract Sequence…
    Verify with BLAST…
    Copy FASTA
    Export FASTA…
    Extract to New Bundle…
    ──────────
    Align with MAFFT…
    Run Operation…

The item a user would search for is now named for what it does. It was
previously `Create Bundle…`, which is why the action appeared to be missing.

The reference-bundle viewport, which is a separate surface reached by selecting
a `.lungfishref`, gained multi-selection and the same item. That path is
covered by unit tests rather than this walkthrough, because the test project
holds a plain FASTA rather than a reference bundle.

## 2. Aligning only the selected sequences

With three of five sequences selected, `Align with MAFFT…` opened the
operations dialog showing:

    Sequences to align
    ( ) All sequences (5)      Every sequence in the source file.
    (•) Selected sequences (3) Only the sequences selected in the viewport.

It defaults to the selection, since that is how the user arrived. Running it
produced a bundle whose alignment holds exactly the three chosen records:

    >sarscov2_fixture_A_source
    >sarscov2_fixture_B_snp_set
    >sarscov2_fixture_C_short_deletion

Before this change the viewport path silently aligned the selection while
saying nothing, and the Tools-menu path silently aligned all five. Both now
state their scope, and where no choice exists the picker is replaced by a
single line of text rather than a disabled control.

## 3. The bottom drawer is no longer overdrawn

The MSA viewport renders with the drawer's tab bar and search field fully
visible at the bottom of the window. No alignment rows are painted over them.

The cause was not the one the symptom suggested. The MSA view is pinned to the
full height deliberately, and hiding the parent drawer underneath it is
correct. The defect was that eleven `hideXView()` teardown functions unhid that
drawer unconditionally, so any teardown running after the alignment installed
would reveal the drawer beneath it. All twelve sites now route through a guard
that respects an installed native viewport, and toggling the drawer is a no-op
while one is present.

## 4. Exporting the aligned FASTA

Right-clicking the alignment offers `Export Alignment…`, which opens a sheet
with three destinations, matching the vocabulary of the existing classifier
extraction dialog:

| Destination | Button |
|---|---|
| Save as Bundle | Create Bundle |
| Save to File… | Save |
| Copy to Clipboard | Copy |

The sheet also chooses `Aligned FASTA (keep gaps)` against
`Unaligned FASTA (remove gaps)`, which is the choice that decides whether the
result is an alignment or a set of sequences, a format list for the file
destination, and a scope control.

The clipboard leg was exercised end to end. The pasteboard received 91,829
characters holding all three records with gap characters intact, confirming the
aligned rather than the ungapped path. The clipboard destination disables
itself above 5 MB with an explanation rather than refusing after the user
commits.

The gapped and ungapped CLI semantics were confirmed directly against the
fixture before the sheet was built: `aligned-fasta` emits 29,834 columns
retaining 35 gap characters, `fasta` emits 29,829 with none.

## 5. The sequence-name column resizes

Names were truncated as `sarscov2..._A_source`. Dragging the divider at the
gutter's trailing edge widened the column, and the names render in full:

    1  sarscov2_fixture_A_source          1-10125
    2  sarscov2_fixture_B_snp_set         1-10125
    3  sarscov2_fixture_C_short_deletion  1-10125

The width persists across bundle loads, clamps between 160 and 640 points, and
truncates in the middle rather than the tail so accession suffixes survive.
Double-clicking the divider sizes it to the widest visible label.

## 6. Dead controls removed

The Inspector for an alignment now shows Bundle, Selected Item, View, and
Provenance. Two tabs are gone:

- **Assistant** was always listed but the AI setting defaults to off, so
  selecting it raised a modal alert and left an empty pane. It now appears only
  once a provider is configured.
- **Analysis** rendered "No alignment tracks loaded. Import a BAM or CRAM
  file", which an alignment bundle never has.

In the drawer, Variants and Samples are greyed out for an alignment. They were
previously live, exposing Import Metadata, Download Template, Add Sample Field,
and Sample Groups, all acting on nothing.

The canvas menu regained `Run Operation…`, whose handler existed and was wired
by the caller but was passed as nil. BLAST and MAFFT stay absent from that menu
deliberately, with a comment recording why: BLAST would query gapped sequence,
and realigning an alignment is a different operation from aligning sequences.

## Test evidence

    Unit tier         GATE PASS
    Integration tier  GATE PASS, 778 tests

Three classes were flaky under parallel load and passed on isolated serial
retry, which matches the known contention pattern on this machine and is
unrelated to these changes.

## Not covered here

The drag handle's cursor behaviour and tooltip need a pointer and were checked
by hand rather than by test. The reference-bundle viewport's extraction menu is
covered by unit tests rather than this walkthrough.

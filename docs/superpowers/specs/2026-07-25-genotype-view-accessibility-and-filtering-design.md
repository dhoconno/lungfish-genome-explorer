# Genotype View Accessibility and Filtering Design

**Date:** 2026-07-25
**Status:** Approved for autonomous implementation after independent UX and technical review

## 1. Purpose

Improve the genotype matrix View controls without changing genotype calls or
annotation semantics:

- make support thresholds directly editable;
- remove avoidable lag while filters change;
- make list/table and detail text user-scalable throughout Lungfish Genome
  Explorer;
- hide haplotype-only cohort controls from genotype-only analyses;
- make sample and displayed-allele search predictable;
- give row and column selection equal visual and accessibility treatment;
- add reversible row/column visibility commands in the Inspector and context
  menus; and
- explain whether View controls apply to an explicit selection or the entire
  matrix.

This work is view state only. It does not create or transform scientific data,
does not alter calls, and does not add entries to the annotation audit log.

## 2. Design principles

1. Use native macOS controls, keyboard conventions, semantic colors, and system
   fonts.
2. Never rely on color alone to convey selected state.
3. Keep frequently adjusted values visible; do not move them into a popover.
4. Treat text/support filters and manual visibility as distinct, composable
   concepts.
5. Preserve selection, scroll position, sorting, column order, and annotations
   while view filters change.
6. Build immutable scientific projections once and perform subsequent view
   filtering over cached data.
7. Keep every context-menu action available from the Inspector.

Apple's macOS guidance encourages content personalization and menu access to
commands. macOS does not provide Dynamic Type in the iOS sense, so Lungfish
will provide its own content-size preference while continuing to use semantic
system fonts. Apple's accessibility guidance recommends supporting content
enlargement up to 200 percent where practical.

## 3. Inspector View layout

The genotype View inspector uses these sections:

1. **Content Text Size**
2. **Search and Support Filters**
3. **Selected Rows and Columns**
4. Existing **Cell Color** and **Selected Highlight** controls

### 3.1 Content Text Size

Present a compact native control:

`A−    100%    A+    Default`

The default is **System**, which resolves semantic AppKit preferred fonts and
therefore follows documented system behavior where AppKit provides it. Custom
persisted scale stops are:

`90%, 100%, 125%, 150%, 175%, 200%`

The preference applies to primary content in list/table and detail views, not
menu-bar items, toolbar chrome, Inspector controls, or sequence/base-coordinate
canvas geometry whose text is driven by scientific zoom. Text-bearing matrices
are tables for this purpose and resize their rows, headers, and columns to fit
the selected text size. The preference is also exposed through:

- **View → Content Text Size → Larger** (`⌥⌘+`)
- **View → Content Text Size → Smaller** (`⌥⌘−`)
- **View → Content Text Size → Default** (`⌥⌘0`)

The Option modifier avoids conflict with existing scientific viewport zoom
commands.

The shared typography layer supplies semantic body, emphasized body, detail,
caption, monospaced, and table-header fonts plus adaptive table row/header
heights. It uses AppKit preferred/system fonts as its baseline, retains weight
and monospaced design, applies the persisted scale, and never resolves
user-facing content below 10 points. Views update when the preference changes.

The first implementation must cover the shared `BatchTableView` path and every
primary list/table and detail controller in the Alignment, Assembly, EsViritu,
Genotype, NAO-MGS, NVD, Phylogenetics, TaxTriage, and 12S result modules.
Specialized scientific renderers whose text size is driven by zoom or
base-pixel geometry remain outside the content setting. All adopted controllers
use the same shared typography API rather than creating local scale settings.

Rows and headers grow whenever the resolved font no longer fits their current
geometry. Detail labels may wrap rather than overlap or clip. Primary content
must remain usable at 200 percent.

### 3.2 Editable thresholds

Use a labeled, trailing-aligned numeric text field with a labels-hidden Stepper
beside it:

- **Min reads**: integer, `0...100,000`, step 1.
- **Min percent**: decimal, `0...100`, step 0.5, with a separate `%` suffix.

Secondary copy reads: **“0 = Off.”**

The text field permits an empty draft while typing. A valid value commits after
200 ms idle, Return, Tab, focus loss, or a Stepper click. Escape restores the
last committed value. Out-of-range numeric input clamps on commit. Invalid
nonnumeric input never reaches matrix state and reverts to the last committed
value with an accessibility validation description.

Stepper clicks update the displayed value immediately, but repeated events are
coalesced into the latest matrix recomputation.

### 3.3 Selection and visibility

The section always shows its scope:

- **Scope: Entire matrix** when there is no explicit selection.
- **Selected: 5 sample columns**
- **Selected: 3 allele rows**
- **Selected: 12 cells (3 rows × 4 columns)**

For a mixed selection, use a combined summary such as **“Selected: 3 allele
rows and 5 sample columns.”** Guidance below the scope reads:

**“Select allele row markers or sample column headers to change visibility.
Visibility actions use the selection. Search and support filters always apply
to the currently visible matrix.”**

Two menus provide:

**Rows…**

- Hide Selected Rows
- Show Only Selected Rows
- Show All Rows

**Columns…**

- Hide Selected Columns
- Show Only Selected Columns
- Show All Columns

**Reset Visibility** restores all rows and columns without clearing the search
text or support thresholds.

Hide and Show Only are disabled when the current selection supplies no targets
for that dimension. They never interpret no selection as “all,” which prevents
an accidental empty matrix. Show All is enabled whenever that dimension has
manual visibility state.

Manual visibility is per-window, per-open-controller state. It survives search
and threshold changes while that bundle controller remains open, is not shared
with another window showing the same bundle, and is discarded when the
controller closes. It composes as follows:

1. Manual include/exclude visibility
2. Active sample/allele quick search
3. Inspector row/sample text filters
4. Support thresholds
5. Sorting

Changing quick-search text does not silently clear manual visibility. When
manual visibility is active, the Inspector scope/status makes that constraint
visible and offers recovery through Show All or Reset Visibility.

Each dimension has an optional stable-ID include set and a stable-ID exclude
set. Its visible values are:

`all IDs ∩ include IDs (when present) − exclude IDs`

- **Show Only Selected** replaces the include set with the selected IDs and
  clears the exclude set for that dimension.
- **Hide Selected** adds the selected IDs to the exclude set while preserving
  any include set.
- **Show All** clears both sets for that dimension.
- **Reset Visibility** clears both sets for both dimensions.

The selection is pruned to surviving targets after a visibility action. If the
focused target is hidden, focus moves to the nearest surviving target or the
matrix itself.

### 3.4 Context menus

The matrix context menu adds selection-aware commands:

- **Hide 5 Selected Rows**
- **Show Only 5 Selected Rows**
- **Hide 5 Selected Columns**
- **Show Only 5 Selected Columns**
- **Show All Rows and Columns**

For a cell or mixed selection, use **Row Visibility** and **Column Visibility**
submenus and deduplicate the selected row/sample identities. Right-clicking
outside the current selection first selects the clicked target, preserving the
existing native behavior.

Existing annotation/review commands remain unchanged and are separated from
visibility commands.

## 4. Search model

For genotype-only results, the quick-search placeholder and accessibility label
are:

**“Search samples or alleles”**

For haplotyped results they are:

**“Search samples, alleles, or haplotypes”**

One shared search index returns independent matches for sample identity/
metadata, projected allele rows, allele-carrying samples, and haplotype-carrying
samples. Each lens consumes those results according to its presentation:

### 4.1 Matrix lens

1. **Sample mode.** If the query matches at least one sample ID or imported
   sample metadata value/key, show the matching sample columns and rows
   supported by those samples. A coincidental row/allele match must not add a
   second row filter.
2. **Allele mode.** If no sample matches but projected rows match, filter rows
   by displayed biological allele, raw genotype, locus, stable cluster ID, and
   visible reference metadata. Keep all otherwise active sample columns.
3. **Haplotype-carrier mode.** In a haplotyped result, when neither sample nor
   projected allele matches but haplotype calls match, show the carrying sample
   columns and their supported rows.

### 4.2 Outline and Review lenses

Sample identity/metadata matches show matching samples. Allele and haplotype
queries show the samples carrying those allele or haplotype calls, preserving
the existing Outline/Review navigation behavior. Genotype-only results omit
haplotype matching entirely.

Matching is case-insensitive and also compares a token made by retaining only
Unicode letters and decimal digits, uppercasing, and preserving their order.
The raw substring must contain at least three alphanumeric characters before
normalized matching is used. Thus displayed-allele substrings such as
`A1*007`, `A1 007`, and `A1007` match consistently without turning one- or
two-character punctuation queries into broad matches.

Required examples:

- `CR1178` and `1178` both select `CR1178` and `CR1178b` and show all rows
  supported by them.
- `A1*007` matches every displayed allele containing `A1*007`, even when the
  internal genotype identifier is unrelated.

Escape clears search and `⌘F` focuses it while a genotype viewport is active. A
zero-result state says:

**“No samples or alleles match ‘query’.”**

The controller and matrix consume one shared search index; they must not
independently classify the same query using different fields. The index is
invalidated when the result, projected reference metadata, imported sample
metadata, annotations/comments, or effective haplotype overrides change.
Column rebuilds preserve order and width by stable sample ID.

The Inspector retains two advanced, independently composable fields:

- **Allele filter** — displayed allele, raw genotype, locus, cluster ID, or
  reference field.
- **Sample filter** — sample ID or imported sample metadata.

These fields apply only to the matrix. The viewport quick search is the
discoverable unified sample-or-allele entry point. Each active filter appears
in the selection/visibility status, and Reset Visibility does not clear either
text field.

## 5. Selection parity

Row selector chiclets use the row-target selection predicate directly. Column
headers continue to use the column-target predicate. Selecting an individual
cell does not imply that its entire row or column is selected.

Selected row and column controls:

- use `NSColor.controlAccentColor`;
- expose selected/not-selected accessibility values;
- include the allele/sample in their accessibility label; and
- update for single, Command, and Shift-range selection.

The selected state remains understandable with Differentiate Without Color or
VoiceOver because the accessibility value and the filled/stroked shape both
change.

## 6. Genotype-only capability

`GenotypeResultDocumentState` carries an explicit capability indicating whether
the result includes haplotyping. When false:

- Smart Cohorts and its adjacent divider are not rendered;
- Smart Cohort actions are ignored/disabled;
- any previously active in-memory cohort is cleared before applying matrix
  filters.

Persisted cohorts in `annotations.json` are preserved. Opening a genotype-only
result must not delete or rewrite them merely because their UI is hidden.

## 7. Performance architecture

The current lag is caused by rebuilding locus summaries, candidate projections,
support lookup tables, and both AppKit tables for every threshold tick.

The revised matrix separates:

- **Base projection** — rows, display allele/reference search fields, sample
  support, read counts, and denominator inputs. Rebuilt only when the result,
  candidate/reference inputs, or scientifically relevant display projection
  changes.
- **Derived view** — manual visibility, search, support thresholds, and sorting.
  Recomputed from cached base rows.

Threshold changes must not reconstruct locus summaries or unrelated Outline,
detail, anchor, or cohort-summary models. Columns rebuild only when the visible
sample set changes. Table reloads should be bounded to changed rows/columns
where practical.

Performance budgets on the representative 52-sample × 120-row fixture:

- a committed threshold edit visibly settles within 100 ms;
- no individual main-thread filtering interval exceeds 50 ms;
- twenty consecutive edits publish the latest value without stale results;
- the base projection is built once;
- selection, scroll position, sort, column order, and widths are retained.

Automated performance tests use operation counters and elapsed-time guardrails
generous enough to avoid CI noise while detecting a return to per-tick full
projection rebuilds.

## 8. State and audit boundaries

- Content text size is an application preference persisted in `AppSettings`.
- Search, thresholds, and row/column visibility remain view state.
- None of these changes creates an annotation audit entry.
- Existing comments and false-positive/false-negative annotations remain
  untouched and continue to export normally.
- Exported viewport filter context may report active view filters, but this work
  introduces no scientific-data-producing CLI workflow and therefore no new
  provenance-producing command.

## 9. Accessibility acceptance

- Numeric controls expose labels, current values, bounds, and increment/
  decrement actions.
- Text-size controls announce their action and resulting percentage.
- Selection summaries announce changes.
- Context-menu actions have Inspector equivalents.
- Filtered-empty states explain both the query and recovery.
- Semantic colors support Light Mode, Dark Mode, Increase Contrast, and system
  accent colors.
- Primary content remains readable without overlap at every supported scale.

## 10. Test acceptance

1. Numeric input covers typing, paste, Return, Tab, focus loss, Escape, bounds,
   percent formatting, invalid drafts, and Stepper interaction.
2. Search integration covers displayed-reference aliases, raw IDs, normalized
   separators, exact/substring sample queries, metadata, and state with manual
   visibility active.
3. Row chiclet tests assert the rendered/accessibility state for single,
   Command, and Shift selections.
4. Visibility tests cover hide, show only, show all, reset, mixed/cell-derived
   selections, deduplication, composition with search/thresholds, and empty
   selections.
   Context-menu construction and routing tests assert counts, disabled states,
   mixed-selection submenus, right-click retargeting, and Inspector
   equivalence.
5. Smart Cohorts is absent for genotype-only results and present for
   haplotyped results without deleting stored cohorts.
6. Typography preference tests cover System/custom persistence, bounds/stops, notifications,
   shared list fonts/heights, genotype matrix/detail adoption, and 200-percent
   layout safety.
7. Repeated threshold tests assert cached-projection reuse, bounded reloads,
   latest-value correctness, and performance budgets.
8. Existing annotation, comment, review, sorting, export, workbook,
   selection-persistence, and viewport routing suites remain green.

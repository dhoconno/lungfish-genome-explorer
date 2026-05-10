# UX Design: NCBI Taxonomy Links and BLAST Verification

**Date**: 2026-03-23
**Status**: Proposed
**Scope**: TaxonomyViewController context menu, Inspector taxon section, BLAST verification flow

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [Decision 1: External Links Strategy](#2-decision-1-external-links-strategy)
3. [Decision 2: NCBI Links Submenu Structure](#3-decision-2-ncbi-links-submenu-structure)
4. [Decision 3: BLAST UI Architecture](#4-decision-3-blast-ui-architecture)
5. [Decision 4: BLAST Configuration UI](#5-decision-4-blast-configuration-ui)
6. [Decision 5: BLAST Results Display](#6-decision-5-blast-results-display)
7. [Decision 6: Progress During BLAST](#7-decision-6-progress-during-blast)
8. [Decision 7: Inspector Integration](#8-decision-7-inspector-integration)
9. [Full Context Menu Wireframe](#9-full-context-menu-wireframe)
10. [BLAST Drawer Tab Wireframe](#10-blast-drawer-tab-wireframe)
11. [Inspector Taxon Section Wireframe](#11-inspector-taxon-section-wireframe)
12. [Accessibility Considerations](#12-accessibility-considerations)
13. [Implementation Notes](#13-implementation-notes)

---

## 1. Design Principles

The design follows three guiding principles drawn from the existing codebase
patterns and Apple Human Interface Guidelines:

**Predictability over novelty.** The app already uses `NSWorkspace.shared.open`
for dbxref links in the Inspector's SelectionSection (GeneID, UniProt, taxon).
NCBI links should follow this same convention so users build a single mental
model: "clickable link opens Safari."

**Drawer-first for in-app state.** The TaxaCollectionsDrawerView establishes
the pattern: secondary content appears in a bottom drawer below the main split
view, toggled from the action bar, resizable via a drag handle. BLAST results
are secondary content that the user needs alongside the taxonomy view, so they
belong in the same drawer system.

**Progressive disclosure.** BLAST configuration should not require a sheet
for the common case. A popover with sensible defaults lets the user fire off
a verification with one click, while advanced users can adjust parameters
before submitting.

---

## 2. Decision 1: External Links Strategy

### Recommendation: System Browser via NSWorkspace.shared.open

**Rationale:**

(a) **System browser** is the correct choice for all three reasons posed in the
question and two more from the codebase analysis:

1. NCBI pages are complex, JavaScript-heavy, and change layout frequently.
   Parsing them into Inspector-native data is fragile and creates an ongoing
   maintenance burden with no user benefit -- the data shown on the NCBI
   Taxonomy page (lineage, nomenclature history, genetic codes, external links)
   exceeds what any Inspector section could reasonably reproduce.

2. Embedding a WKWebView in the Inspector creates a "mini browser" anti-pattern
   that violates HIG section "Opening Links" -- users expect web content to
   open in their configured default browser where they have bookmarks, history,
   authentication cookies (for NCBI accounts), and accessibility settings.

3. The codebase already uses `NSWorkspace.shared.open` for opening URLs (see
   `AboutWindowController.swift`, dbxref links in `SelectionSection.swift`)
   and `Link(destination:)` in SwiftUI views. Adding a WebView would be the
   only instance of embedded web content in the entire application, creating
   inconsistency.

4. Safari on macOS 26 supports Universal Links and Handoff, so NCBI Taxonomy
   pages opened from Lungfish can be continued on iPad/iPhone -- something a
   WKWebView cannot provide.

5. System browser is the only option that works when the user is offline and has
   a cached version of the page in Safari's Reading List.

**For the Inspector panel**, we do show a lightweight "Taxon Details" section
(see Decision 7) with the data we already have in the TaxonNode model. This
is not a replacement for the NCBI page -- it is a summary with clickable
links that open Safari.

### Implementation Pattern

```swift
// Reuse the existing pattern from SelectionSection dbxref links:
if let url = URL(string: "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(node.taxId)") {
    NSWorkspace.shared.open(url)
}
```

---

## 3. Decision 2: NCBI Links Submenu Structure

### Recommendation: "NCBI" Submenu with Contextual Items

A flat list of four NCBI items clutters the context menu alongside the existing
seven items (two Extract, two Copy, separator, two Zoom). A submenu groups
related actions and keeps the primary menu scannable.

However, the submenu should only include links that are semantically meaningful
for the selected taxon. Not every taxon has a genome assembly, and PubMed
searches are only useful for named species/genera.

### Menu Structure

```
Extract Sequences for Escherichia coli...
Extract Sequences for Escherichia coli and Children...
---
NCBI                                   >  Visit Taxonomy Page           globe
                                          View GenBank Sequences         books.vertical
                                          Search PubMed                  magnifyingglass
                                          ---
                                          Copy Tax ID                    doc.on.doc
---
BLAST Matching Reads...                   bolt.badge.checkmark
---
Add to Collection...                      rectangle.stack.badge.plus
---
Copy Taxon Name
Copy Taxonomy Path
---
Zoom to Escherichia coli
Zoom Out to Root
```

### Submenu Availability Rules

| Item                    | Available When                                   | URL Pattern |
|-------------------------|--------------------------------------------------|-------------|
| Visit Taxonomy Page     | Always (taxId > 0)                               | `ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id={taxId}` |
| View GenBank Sequences  | Always (taxId > 0)                               | `ncbi.nlm.nih.gov/nuccore/?term=txid{taxId}[Organism:exp]` |
| Search PubMed           | rank <= genus (species, genus, family)            | `pubmed.ncbi.nlm.nih.gov/?term={name}[Organism]` |
| Copy Tax ID             | Always                                           | N/A (copies to pasteboard) |

The "View Genome" item from the original question is intentionally omitted
because most taxa in a metagenomic classification do not have a reference genome
assembly on NCBI. Including a link that frequently leads to "No items found"
teaches users not to trust the menu. If a genome page is needed, the user can
reach it from the Taxonomy Page in Safari.

### SF Symbol Assignments

Each submenu item gets an SF Symbol for visual scanning:

- Visit Taxonomy Page: `globe` (external navigation)
- View GenBank Sequences: `books.vertical` (sequence records)
- Search PubMed: `magnifyingglass` (search)
- Copy Tax ID: `doc.on.doc` (consistent with existing Copy actions)

### Why "BLAST Matching Reads..." Is Outside the Submenu

BLAST is a computational action that runs inside the app, not a navigation
action that opens a browser. Grouping it under "NCBI" would confuse the
mental model. It belongs at the top level, after the extraction actions
(which it is conceptually related to -- both involve reads associated with
this taxon) and before the copy/zoom utility actions.

---

## 4. Decision 3: BLAST UI Architecture

### Recommendation: Option A (Drawer Tab) with Popover Configuration

**Rationale:**

The existing TaxaCollectionsDrawerView establishes a bottom drawer that
occupies the space between the taxonomy split view and the action bar.
Adding a second tab to this drawer is the most Mac-like approach because:

1. **Spatial consistency.** Results appear in the same location where the user
   initiated the action (the taxonomy view), not in a floating panel that can
   drift behind other windows or a modal sheet that blocks interaction with
   the sunburst/table.

2. **Established pattern.** The annotation drawer in ViewerViewController uses
   tabbed content (Annotations, Genotypes, Bookmarks, Export). The taxonomy
   drawer extending to include a BLAST tab follows the same convention.

3. **No modality.** The user can continue interacting with the sunburst chart,
   selecting other taxa, or even starting additional BLAST verifications while
   a previous one is running. A sheet would block this.

4. **Persistence.** The drawer retains BLAST results across taxon selection
   changes. The user can select taxon A, run BLAST, select taxon B, run BLAST,
   then switch between results using the BLAST tab's history.

**Why not Option B (Sheet)?** The extraction sheet (`TaxonomyExtractionSheet`)
works because extraction is a one-shot configure-and-go operation. BLAST has
a multi-phase lifecycle (configure, submit, wait, parse, display) that needs
persistent UI -- a sheet would need to remain open for the entire 30s-5min
duration, blocking the taxonomy view.

**Why not Option C (Floating panel)?** Floating panels are appropriate for
tools that apply across multiple windows (like the AI Assistant panel). BLAST
results are specific to the current classification result and should live in
the same spatial context.

### Drawer Tab Structure

```
+------------------------------------------------------------------+
| [===== Drag Handle =====]                                         |
+------------------------------------------------------------------+
| [Collections]  [BLAST Results]                           [Filter] |
+------------------------------------------------------------------+
|  (tab content appears here)                                       |
+------------------------------------------------------------------+
```

The tab bar uses an NSSegmentedControl with `.selectOne` tracking mode,
matching the annotation drawer's tab pattern.

---

## 5. Decision 4: BLAST Configuration UI

### Recommendation: Popover from Context Menu

When the user clicks "BLAST Matching Reads..." in the context menu, a popover
appears anchored to the click location. The popover contains a compact form
with sensible defaults that lets the user submit with a single click on "Run
BLAST" or adjust parameters before submitting.

### Why Popover, Not Sheet

1. **Speed.** The common case is "verify this taxon with defaults." A popover
   is one click away from submission. A sheet adds visual weight and a Cancel
   button that implies the action is dangerous.

2. **Non-modal.** The user can dismiss the popover by clicking elsewhere if
   they change their mind, without needing to find a Cancel button.

3. **Spatial proximity.** The popover appears near the right-clicked taxon,
   maintaining context. A sheet appears centered on the window, disconnected
   from the trigger.

4. **HIG alignment.** Apple uses popovers for quick configuration actions
   (AirDrop preferences, Wi-Fi details, Share sheet options). Sheets are
   for operations that require commitment (Save, Export, New Document).

### Popover Layout (280pt wide)

```
+----------------------------------------------+
| BLAST Verification                           |
| Escherichia coli (taxId: 562)                |
+----------------------------------------------+
|                                              |
| Reads to submit    [====|====] 20            |
|                    10        50              |
|                                              |
| Program            [megablast      v]        |
|                                              |
| Database           [core_nt        v]        |
|                                              |
| [x] Filter results to this taxon            |
|                                              |
+----------------------------------------------+
|                          [Run BLAST]         |
+----------------------------------------------+
```

### Control Specifications

| Control              | Type                  | Default     | Range/Options |
|----------------------|-----------------------|-------------|---------------|
| Reads to submit      | NSSlider (continuous) | 20          | 10-50, step 5 |
| Program              | NSPopUpButton         | megablast   | megablast, blastn, dc-megablast |
| Database             | NSPopUpButton         | core_nt     | core_nt, nt, refseq_select |
| Filter to taxon      | NSButton (checkbox)   | on          | on/off |

### Why These Defaults

- **20 reads**: Balances statistical confidence with BLAST queue time. At 20
  reads, a 90% verification rate is statistically meaningful (binomial CI
  width ~13%). Fewer than 10 gives wide confidence intervals. More than 50
  increases queue time without proportional benefit.

- **megablast**: The default BLAST program for highly similar sequences, which
  is the expected case when verifying Kraken2 classifications (the reads
  should match organisms in the nt database).

- **core_nt**: A curated subset of nt that returns faster results. Users doing
  environmental metagenomics can switch to full `nt` for broader coverage.

- **Filter ON by default**: When verifying a classification, the user wants to
  know "did BLAST agree this read is Escherichia coli?" Filtering results to
  the taxon makes the verification summary immediately interpretable.

### Read Selection Strategy

The popover subtitle shows "20 of 1,234 reads (random sample)" to set
expectations. Reads are randomly sampled from those directly classified to
this taxon (readsDirect), not from the clade. This ensures the verification
tests the classifier's direct assignments, which are the most meaningful
for validation.

If readsDirect < requested count, all available reads are submitted and the
slider maximum adjusts down. The label changes to "All 8 reads" with the
slider disabled.

---

## 6. Decision 5: BLAST Results Display

### Recommendation: Summary Bar + Expandable Table in Drawer Tab

The BLAST tab in the drawer shows results in two tiers:

**Tier 1: Summary bar** -- Always visible at the top of the BLAST tab, provides
instant verification status.

**Tier 2: Per-read table** -- Expandable rows showing alignment details for
each submitted read.

### Summary Bar

```
+------------------------------------------------------------------+
| checkmark.circle.fill  18 of 20 reads verified (90%)    [Open in |
|                        Escherichia coli                   BLAST]  |
+------------------------------------------------------------------+
```

The summary bar uses a color-coded background:

| Verification Rate | Color                     | Interpretation |
|-------------------|---------------------------|----------------|
| >= 80%            | systemGreen (alpha 0.15)   | High confidence |
| 50-79%            | systemYellow (alpha 0.15)  | Mixed -- review |
| < 50%             | systemOrange (alpha 0.15)  | Low confidence |
| 0% or error       | systemRed (alpha 0.15)     | Likely misclassification |

The "Open in BLAST" button opens the NCBI BLAST results page in Safari via
`NSWorkspace.shared.open`, providing full alignment visualizations and
BLAST-specific tools that would be impossible to reproduce in-app.

### Per-Read Results Table

```
+------------------------------------------------------------------+
| Status | Read ID              | Top Hit          | Identity | E-val |
+--------+----------------------+------------------+----------+-------+
| check  | SRR123456.789        | Escherichia coli | 99.2%    | 0.0   |
| check  | SRR123456.1012       | Escherichia coli | 98.7%    | 0.0   |
| warn   | SRR123456.2048       | Shigella flexneri| 97.1%    | 0.0   |
| xmark  | SRR123456.4096       | No significant h | --       | --    |
+--------+----------------------+------------------+----------+-------+
```

Column specifications:

| Column    | Width  | Content |
|-----------|--------|---------|
| Status    | 24pt   | SF Symbol: `checkmark.circle.fill` (green), `exclamationmark.triangle.fill` (yellow), `xmark.circle.fill` (red) |
| Read ID   | flex   | FASTQ read identifier, truncated with tooltip |
| Top Hit   | flex   | Best BLAST hit organism name |
| Identity  | 60pt   | Percent identity, right-aligned, monospaced digits |
| E-value   | 60pt   | E-value in scientific notation, right-aligned |

### Expandable Detail Row

Clicking a row expands it to show:

```
+------------------------------------------------------------------+
| check  | SRR123456.789        | Escherichia coli | 99.2%    | 0.0 |
|        +----------------------------------------------------+    |
|        | Query:  1   ATCGATCGATCG...ATCGATCG  150            |    |
|        |             ||||||||||||| |||||||||||                |    |
|        | Sbjct:  1   ATCGATCGATCG...ATCGATCG  150            |    |
|        |                                                     |    |
|        | Accession: NZ_CP012345.1    Length: 150/150          |    |
|        | Score: 278 bits    Gaps: 0/150 (0%)                 |    |
|        +----------------------------------------------------+    |
+------------------------------------------------------------------+
```

The alignment uses a monospaced font (`.system(.caption, design: .monospaced)`)
and shows only the first 80 characters with "..." truncation. The full
alignment is available via "Open in BLAST."

### Verification Logic

A read is "verified" when the top BLAST hit's organism matches the queried
taxon or any of its parent/child taxa. The matching logic uses NCBI tax IDs
when available in BLAST results, falling back to organism name matching.

| Condition                                      | Status | Symbol |
|------------------------------------------------|--------|--------|
| Top hit tax ID is in queried clade             | Verified | checkmark.circle.fill (green) |
| Top hit is a closely related taxon             | Ambiguous | exclamationmark.triangle.fill (yellow) |
| Top hit is an unrelated organism               | Different | exclamationmark.triangle.fill (orange) |
| No significant hits (E-value > 0.001)          | No Hit | xmark.circle.fill (red) |

### BLAST Results History

The BLAST tab maintains a list of completed verifications for the current
classification session. A segmented control or popup button at the top
lets the user switch between results:

```
[Escherichia coli (90%) v]  [Staphylococcus aureus (95%) v]  [+ New]
```

This avoids re-running BLAST when the user wants to compare verification
rates across multiple taxa.

---

## 7. Decision 6: Progress During BLAST

### Recommendation: Both Drawer and Operations Panel

BLAST jobs have two distinct audiences:

1. **Active user** watching the taxonomy view: sees progress in the drawer.
2. **Multitasking user** who navigated away: sees progress in the Operations Panel.

### Drawer Progress (Primary)

When a BLAST job is running, the BLAST tab shows an inline progress view
replacing the results table:

```
+------------------------------------------------------------------+
| BLAST Verification: Escherichia coli                              |
+------------------------------------------------------------------+
|                                                                   |
|  [spinner]  Submitting 20 reads to NCBI BLAST...                 |
|                                                                   |
|  Phase 1 of 3: Submission                                        |
|  [====================================                    ] 60%   |
|                                                                   |
|  Estimated time remaining: ~2 min                                 |
|                                                                   |
|  [Cancel]                                                         |
|                                                                   |
+------------------------------------------------------------------+
```

Progress phases:

| Phase | Label | Duration Estimate |
|-------|-------|-------------------|
| 1     | Submitting reads to NCBI BLAST | 5-15s (network) |
| 2     | Waiting for BLAST results | 20s-5min (queue dependent) |
| 3     | Parsing results | 1-3s (local) |

Phase 2 uses a polling interval (5s for the first minute, then 15s) to
check the BLAST job status via the NCBI BLAST REST API. The progress bar
during Phase 2 shows an indeterminate animation (barber pole) since the
BLAST queue time is unpredictable.

### Operations Panel Entry (Secondary)

Every BLAST job also registers with `OperationCenter.shared` using the
existing pattern from taxonomy extraction:

```swift
let opID = OperationCenter.shared.start(
    title: "BLAST Verify: \(node.name)",
    detail: "Submitting 20 reads...",
    operationType: .blastVerification
)
```

This provides:
- Visibility when the user navigates away from the taxonomy view
- Cancel capability from the Operations Panel
- Completion notification (via `OperationCenter.complete`)

The Operations Panel entry shows the same phase labels as the drawer but
in a more compact format: "BLAST Verify: E. coli -- Waiting for results (2/3)".

### Notification on Completion

When the BLAST job completes and the user is not viewing the BLAST tab:

1. The OperationCenter entry updates to "Complete" with a green checkmark.
2. A subtle badge appears on the BLAST tab label: "BLAST Results (1)" where
   the number indicates unviewed completed results.
3. No system notification or sound -- BLAST completion is not urgent enough
   to interrupt the user's flow.

---

## 8. Decision 7: Inspector Integration

### Recommendation: Add a "Taxon" Section to Inspector Document Tab

When a taxon is selected in the taxonomy view (via sunburst click or table
row selection), the Inspector's Document tab should display a dedicated
"Taxon" section below the existing document metadata. This section shows
data already available in the `TaxonNode` model -- no network requests
required.

### Inspector Taxon Section Content

```
+--------------------------------------------------+
| > Taxon                                          |
+--------------------------------------------------+
|                                                  |
|  Escherichia coli                                |
|  Species  |  Tax ID: 562                         |
|                                                  |
|  ---                                             |
|                                                  |
|  Reads (clade)      1,234                        |
|  Reads (direct)       892                        |
|  Clade %             12.3%                       |
|  Children               4                        |
|                                                  |
|  ---                                             |
|                                                  |
|  Lineage                                         |
|  Bacteria > Proteobacteria > Gammaproteobacte... |
|  (click to expand full lineage)                  |
|                                                  |
|  ---                                             |
|                                                  |
|  Links                                           |
|  globe  NCBI Taxonomy       arrow.up.right       |
|  books.vertical  GenBank Sequences  arrow.up.right|
|  magnifyingglass  PubMed    arrow.up.right       |
|                                                  |
|  ---                                             |
|                                                  |
|  BLAST Status                                    |
|  checkmark.circle.fill  Verified (90%, 18/20)    |
|  Last run: 2 min ago                             |
|                                                  |
+--------------------------------------------------+
```

### Section Behavior

- The section appears only when the taxonomy view is active and a taxon is
  selected. It replaces (does not supplement) the annotation selection
  section, since the annotation system is not active during taxonomy browsing.

- NCBI links are SwiftUI `Link(destination:)` views, consistent with the
  existing dbxref links pattern in `SelectionSection.swift`. Each opens in
  the system browser.

- The BLAST Status subsection appears only after at least one BLAST
  verification has been run for this taxon. It shows the most recent
  result with a color-coded icon matching the summary bar in the drawer.
  Clicking the status line switches to the BLAST tab in the drawer.

- The lineage is computed from `node.pathFromRoot()`, which already exists
  on TaxonNode. The compact display shows a truncated path with "..."
  and a "Show Full Lineage" disclosure that expands to show every rank.

### Data Flow

The `TaxonomyViewController` already fires `onNodeSelected` callbacks that
sync the sunburst and table. The same callback can update the Inspector:

```swift
// In MainSplitViewController or the wiring code:
taxonomyVC.sunburstView.onNodeSelected = { [weak self] node in
    // Existing: sync table
    // New: update Inspector
    self?.inspectorController.updateTaxonSelection(node)
}
```

The Inspector needs a new view model section (`TaxonSectionViewModel`) that
holds the selected TaxonNode reference and exposes computed properties for
the SwiftUI view.

---

## 9. Full Context Menu Wireframe

### Sunburst / Table Right-Click on Taxon "Escherichia coli"

```
+------------------------------------------------+
|  Extract Sequences for Escherichia coli...      |
|  Extract Sequences for E. coli and Children...  |
+------------------------------------------------+
|  NCBI                                        >  |--+
+------------------------------------------------+   |
|  BLAST Matching Reads...        bolt.badge.chk  |   |
+------------------------------------------------+   |
|  Add to Collection...     rectangle.stack.badge |   |
+------------------------------------------------+   |
|  Copy Taxon Name                                |   |
|  Copy Taxonomy Path                             |   |
+------------------------------------------------+   |
|  Zoom to Escherichia coli                       |   |
|  Zoom Out to Root                               |   |
+------------------------------------------------+   |
                                                      |
   NCBI Submenu:                                      |
   +----------------------------------------------+  |
   |  Visit Taxonomy Page             globe        |<-+
   |  View GenBank Sequences     books.vertical    |
   |  Search PubMed           magnifyingglass      |
   +----------------------------------------------+
   |  Copy Tax ID                  doc.on.doc      |
   +----------------------------------------------+
```

### New Items Added (compared to current implementation)

| Item | Action | SF Symbol |
|------|--------|-----------|
| NCBI > Visit Taxonomy Page | `NSWorkspace.shared.open(taxonomyURL)` | `globe` |
| NCBI > View GenBank Sequences | `NSWorkspace.shared.open(genbankURL)` | `books.vertical` |
| NCBI > Search PubMed | `NSWorkspace.shared.open(pubmedURL)` | `magnifyingglass` |
| NCBI > Copy Tax ID | Copy `"\(node.taxId)"` to pasteboard | `doc.on.doc` |
| BLAST Matching Reads... | Show BLAST configuration popover | `bolt.badge.checkmark` |
| Add to Collection... | Show collection picker popover | `rectangle.stack.badge.plus` |

The "Add to Collection..." item is included because the context menu is the
natural place for users to bookmark a taxon for later batch extraction. This
was not in the original question but completes the workflow: discover taxon
in sunburst, verify with BLAST, add to collection, batch extract.

---

## 10. BLAST Drawer Tab Wireframe

### Tab Bar (replaces current drawer header)

```
+------------------------------------------------------------------+
| [===== Drag Handle =====]                                         |
+------------------------------------------------------------------+
| [  Collections  ] [  BLAST Results  ]                    [Filter] |
+------------------------------------------------------------------+
```

### BLAST Tab: No Results Yet

```
+------------------------------------------------------------------+
|                                                                   |
|   bolt.badge.checkmark                                            |
|                                                                   |
|   No BLAST Verifications                                          |
|   Right-click a taxon and choose "BLAST Matching Reads..."        |
|   to verify its classification against the NCBI database.         |
|                                                                   |
+------------------------------------------------------------------+
```

### BLAST Tab: In Progress

```
+------------------------------------------------------------------+
| BLAST Verification: Escherichia coli                     [Cancel] |
+------------------------------------------------------------------+
|                                                                   |
|  [spinner]  Waiting for NCBI BLAST results...                     |
|                                                                   |
|  Phase 2 of 3: Queue                                              |
|  [===========================================             ] --    |
|  (indeterminate -- NCBI queue time varies)                        |
|                                                                   |
|  Submitted 20 reads  |  Request ID: ABCD1234                     |
|  Started: 12:34 PM   |  Elapsed: 1m 23s                          |
|                                                                   |
+------------------------------------------------------------------+
```

### BLAST Tab: Results

```
+------------------------------------------------------------------+
| [Escherichia coli (90%) v] [Salmonella enterica (100%) v]         |
+------------------------------------------------------------------+
| checkmark.circle.fill  18 of 20 verified (90%)   [Open in BLAST] |
| Escherichia coli  |  megablast vs core_nt  |  20 reads submitted  |
+------------------------------------------------------------------+
| St | Read ID              | Top Hit            | Ident  | E-val  |
+----+----------------------+--------------------+--------+--------+
| CK | SRR123456.789        | Escherichia coli   | 99.2%  | 0.0   |
| CK | SRR123456.1012       | Escherichia coli   | 98.7%  | 0.0   |
| CK | SRR123456.1523       | Escherichia coli   | 99.8%  | 0.0   |
| WN | SRR123456.2048       | Shigella flexneri  | 97.1%  | 0.0   |
| XM | SRR123456.4096       | No significant hit | --     | --     |
|    |                      |                    |        |        |
|    |  (scroll for more)   |                    |        |        |
+------------------------------------------------------------------+

CK = checkmark.circle.fill (green)
WN = exclamationmark.triangle.fill (yellow)
XM = xmark.circle.fill (red)
```

---

## 11. Inspector Taxon Section Wireframe

### Document Tab with Taxon Selected

```
+--------------------------------------------------+
|  [Document] [Selection] [AI]                      |
+--------------------------------------------------+
|                                                   |
|  > Document                                       |
|    (existing bundle metadata, collapsed)          |
|                                                   |
|  v Taxon                                          |
|  +-------------------------------------------------+
|  |                                                 |
|  |  Escherichia coli                               |
|  |  Species                   Tax ID 562           |
|  |                                                 |
|  |  ---                                            |
|  |                                                 |
|  |  Reads (clade)            1,234                 |
|  |  Reads (direct)             892                 |
|  |  % of classified          14.2%                 |
|  |  Child taxa                   4                 |
|  |                                                 |
|  |  ---                                            |
|  |                                                 |
|  |  Lineage                                        |
|  |  Bacteria > Proteobacteria > Gammaproteob...    |
|  |  [Show Full Lineage]                            |
|  |                                                 |
|  |  ---                                            |
|  |                                                 |
|  |  Links                                          |
|  |  globe  NCBI Taxonomy              arrow.up     |
|  |  books.vertical  GenBank            arrow.up     |
|  |  magnifyingglass  PubMed            arrow.up     |
|  |                                                 |
|  |  ---                                            |
|  |                                                 |
|  |  BLAST                                          |
|  |  checkmark.circle.fill  Verified (90%)          |
|  |  18 of 20 reads  |  2 min ago                   |
|  |  [View in BLAST Tab]                            |
|  |                                                 |
|  +-------------------------------------------------+
```

### When No Taxon is Selected

```
+--------------------------------------------------+
|  v Taxon                                          |
|  +-------------------------------------------------+
|  |                                                 |
|  |  selection.pin.in.out                           |
|  |                                                 |
|  |  No Taxon Selected                              |
|  |  Click a segment in the sunburst chart          |
|  |  or a row in the table to view details.         |
|  |                                                 |
|  +-------------------------------------------------+
```

### Full Lineage Expanded

```
|  Lineage                                           |
|                                                    |
|  Root                                              |
|    Bacteria                               Domain   |
|      Pseudomonadota                       Phylum   |
|        Gammaproteobacteria                Class    |
|          Enterobacterales                 Order    |
|            Enterobacteriaceae              Family   |
|              Escherichia                   Genus    |
|                Escherichia coli            Species  |
|                                                    |
|  [Collapse Lineage]                                |
```

Each rank label is dimmed (`secondaryLabelColor`). Clicking any ancestor
name in the lineage fires the sunburst zoom callback to zoom to that node.

---

## 12. Accessibility Considerations

### VoiceOver

- Every SF Symbol icon in the context menu, drawer, and Inspector has an
  `accessibilityDescription` (e.g., "Verified", "Warning", "Failed").
- The BLAST summary bar reads as "18 of 20 reads verified, 90 percent,
  Escherichia coli" when focused.
- The BLAST results table uses column headers as VoiceOver labels.
- NCBI link rows read as "Visit NCBI Taxonomy Page for Escherichia coli,
  opens in browser."

### Keyboard Navigation

- All context menu items are reachable via keyboard (NSMenu handles this
  automatically).
- The BLAST configuration popover is dismissible with Escape.
- The drawer tabs are switchable with Tab/Shift-Tab when the drawer header
  has focus.
- The BLAST results table supports arrow key navigation.

### Reduced Motion

- The drawer open/close animation respects
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (already
  implemented in `TaxonomyViewController+Collections.swift`).
- The BLAST progress spinner uses `NSProgressIndicator` which respects
  system reduced motion preferences.

### Color

- Verification status uses both color AND an SF Symbol shape, never color
  alone. Green checkmark, yellow triangle, red X are distinguishable by
  shape even in grayscale or to users with color vision deficiency.
- The summary bar background tint is supplementary decoration, not the sole
  indicator of status.

---

## 13. Implementation Notes

### Files to Create

| File | Purpose |
|------|---------|
| `BLASTVerificationService.swift` | NCBI BLAST REST API client (submit, poll, parse) |
| `BLASTVerificationViewModel.swift` | @Observable view model for BLAST state management |
| `BLASTResultsDrawerView.swift` | NSView for the BLAST tab in the drawer |
| `BLASTConfigurationPopover.swift` | SwiftUI popover for BLAST parameters |
| `TaxonSectionViewModel.swift` | @Observable view model for Inspector taxon section |
| `TaxonSection.swift` | SwiftUI view for Inspector taxon section |

### Files to Modify

| File | Changes |
|------|---------|
| `TaxonomyViewController.swift` | Add NCBI submenu and BLAST item to `showContextMenu(for:at:)`, add BLAST result storage |
| `TaxonomyTableView.swift` | Add NCBI submenu and BLAST item to `buildContextMenu()` |
| `TaxaCollectionsDrawerView.swift` | Refactor into a tabbed container, extract current content into a Collections tab |
| `TaxonomyViewController+Collections.swift` | Update drawer toggle to support tabbed drawer |
| `InspectorViewController.swift` | Add taxon section, wire selection updates from taxonomy view |
| `TaxonomyActionBar.swift` | (Optional) Add "BLAST" button next to "Extract Sequences" |
| `LungfishCore/Models/Notifications.swift` | Add `.blastVerification` operation type |

### BLAST API Integration

The NCBI BLAST REST API flow:

1. **Submit**: `PUT https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi` with
   `CMD=Put`, `PROGRAM=megablast`, `DATABASE=core_nt`, `QUERY=...`
2. **Poll**: `GET https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Get&FORMAT_OBJECT=SearchInfo&RID={rid}`
3. **Retrieve**: `GET https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Get&FORMAT_TYPE=JSON2_S&RID={rid}`

The service should use `URLSession` with the traditional delegate-based API
(not async/await) per the project's established pattern for progress reporting.
See `NCBIService.swift`'s `ContinuationDownloadDelegate` for the reference
implementation.

### Threading Model

`BLASTVerificationService` should follow the `@unchecked Sendable` pattern
established by `GenBankBundleDownloadViewModel` and `GenomeDownloadViewModel`:

- The service class is `@unchecked Sendable`, not `@MainActor`
- Progress is reported via `@Sendable (Double, String) -> Void` callback
- Results are delivered via completion callback that the caller dispatches
  to the main thread using `DispatchQueue.main.async { MainActor.assumeIsolated { } }`
- Long-running polling runs in a `Task.detached` context

### URL Construction Helpers

```swift
extension TaxonNode {
    /// NCBI Taxonomy Browser URL for this taxon.
    var ncbiTaxonomyURL: URL? {
        URL(string: "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(taxId)")
    }

    /// NCBI GenBank nucleotide search URL for this taxon.
    var ncbiGenBankURL: URL? {
        URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/?term=txid\(taxId)%5BOrganism%3Aexp%5D")
    }

    /// PubMed search URL for this taxon (URL-encoded organism name).
    var pubmedSearchURL: URL? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encoded)%5BOrganism%5D")
    }

    /// NCBI BLAST results URL for a given Request ID.
    static func blastResultsURL(rid: String) -> URL? {
        URL(string: "https://blast.ncbi.nlm.nih.gov/Blast.cgi?CMD=Get&RID=\(rid)&FORMAT_TYPE=HTML")
    }
}
```

### Existing Pattern Alignment

| Pattern | Existing Example | New Usage |
|---------|-----------------|-----------|
| Context menu submenu | MainMenu.swift (File > Export) | NCBI submenu |
| Popover from button | TaxonomyProvenanceView | BLAST configuration |
| Bottom drawer with tabs | AnnotationTableDrawerView (Annotations/Genotypes/Bookmarks) | Collections/BLAST tabs |
| OperationCenter registration | ViewerViewController+Taxonomy.swift extraction | BLAST job tracking |
| NSWorkspace.shared.open | SelectionSection dbxref links | NCBI links |
| @unchecked Sendable service | GenomeDownloadViewModel | BLASTVerificationService |
| Progress via callback | MaterializationPipeline | BLAST polling progress |

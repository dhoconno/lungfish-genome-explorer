# Per-Cell Haplotype Review and Override — Design Spec

**Date:** 2026-05-23
**Branch:** `codex/lungfishgenotype-viewport-inspector`
**Status:** Ready for implementation
**Reviewers:**
- Dr. M. Wiseman, DVM, PhD — Senior MHC Haplotyping Scientist, WNPRC (scientific requirements)
- Senior UX Researcher, Lungfish Genome Explorer (interaction design)
- Senior Accessibility Tester, WCAG 2.1 AA (keyboard + assistive tech)

## Problem statement

The current per-cell click on the genotype tape opens an `NSPopover` (transient) that shows seven competing blocks of information without a clear decision-making path. Concrete failure observed by the user on DW472 at MHC-B (called M3B homozygous):

- The popover surfaces the supporting alleles for M3B (148 + 119 reads = 267)
- It does NOT prominently surface that M2B has 1 of 4 diagnostic alleles observed (`12_M2_B_019_03` at 123 reads), which is the actual data the analyst needs to decide whether M2B should be H2
- Override action lives three blocks down inside a nested menu
- Transient behavior dismisses on outside-click, hostile to reviewing 200 samples in sequence
- No "confirmed" path — the most common analyst action (analyzer was right, move on) has no audit record
- No novel-haplotype path
- No keyboard navigation between cells

The user's suggestion was "two panels (one per haplotype)." The experts converge: **the H1/H2 split is right for heterozygous calls and noise for homozygous; the bigger architectural fix is replacing the transient popover with a persistent right-side inspector**.

## Goals

1. **Decision-first hierarchy.** Information visible in a single glance ordered by what the analyst needs to decide: is the call right, and if not, what's the strongest alternative?
2. **Absence is data.** Render missing diagnostic alleles as a distinct "absent" token, not blank. The whole job is evaluating dropout.
3. **Survive 200-sample review flow.** Persistent surface, keyboard navigation, no auto-dismiss on outside click.
4. **Auditable per-cell decision.** Every analyst review (including "confirmed, no change") leaves an audit entry.
5. **Novel-haplotype path.** First-class entry point with nomenclature hint.
6. **Accessible.** Keyboard-only navigation, VoiceOver, focus management.

---

## 1. Surface: Persistent Right-Side Inspector (Replaces Transient Popover)

Replace `NSPopover` in `presentCellEvidencePopover` with a **persistent right-side inspector pane** that lives inside `detailContainer` alongside the existing Cohort Summary and Call Evidence panels.

**Why a persistent pane, not a popover:**
- NSPopover transient dismisses on outside click, killing the "fly through 200 samples" workflow
- A persistent pane lets the analyst keep the inspector open while clicking through cells; content updates as focus moves
- Side-by-side with the tape preserves cohort context — analysts use it to spot batch dropout patterns
- A modal sheet (the alternative) kills cohort context entirely

The pane is **only active during Review lens**, hidden in Summary and Audit. Width fixed at ~420pt.

**Anti-pattern (rejected):**
- ❌ Inline expansion under the row — fights with the table layout, hard to keyboard-navigate, hides adjacent samples
- ❌ Modal sheet — kills cohort context
- ❌ Floating window — non-standard for AppKit data inspectors

---

## 2. Information Hierarchy

Each section in order of importance, with explicit visual weight:

### 2.1 Sticky Header (≈56pt, top)

```
DW472 · MHC-B            [CALLED]  [Confirm] [Skip]
Call: M3B (homozygous)
Locus reads: 2,050 · 1,788 supporting · K/N: M3B 2/3
```

- **Sample · Locus** in `.title3.semibold`
- **Status chip** (CALLED / NO HAP / TMH / TMG) with brand color
- **`[Confirm]`** button writes an audit entry (`action: confirmed`, before == after, reason tag `confirmed`). One-keystroke for "analyzer was right" — the most common action.
- **`[Skip]`** moves to next review-flagged sample without recording anything
- Locus read totals and K/N score for the currently called haplotype

### 2.2 Slot Strip (≈140pt; two columns when heterozygous, single column when homozygous)

When **heterozygous** (h1 != h2 and h2 != "-"):

```
H1: M3B                  | H2: M3B (or different)
[swatch + glyph]         | [swatch + glyph]
148 reads / 7.2%         | 119 reads / 5.8%
[→ Override H1]          | [→ Override H2]
```

When **homozygous** (h2 == "-" or h2 == h1):

```
M3B (homozygous)
[swatch + glyph]
148 + 119 reads / 13.0%
[→ Override Call]    [+ Add H2 manually]
```

The split-column form only fires when actually useful. Compare-mode (see §3.2) can temporarily force the split.

### 2.3 Diagnostic-Allele Matrix (main region, flex)

**Crucial change from current implementation:** show all candidates with ≥1 hit (not just matched). Each candidate row is a small inline allele grid showing presence/absence per diagnostic allele.

```
Candidates (sortable, default by K/N then reads)

M3B    K/N 2/3  ✓✓·    267r avg
  ✓ 12_M3_B_075_01   148r  7.2%
  ✓ 12_M3_B_165_01   119r  5.8%
  · 12_M3_B_098_05    58r  2.8%   [absent above threshold]
  [→ Set H1]  [→ Set H2]                       [CALLED]

M2B    K/N 1/4  ✓···   123r avg
  ✓ 12_M2_B_019_03   123r  6.0%
  · 12_M2_B_109_04     0r  0.0%   [absent]
  · 12_M2_B_150_01_01  0r  0.0%   [absent]
  · 12_M2_B_162        0r  0.0%   [absent]
  [→ Set H1]  [→ Set H2]

M6B    K/N 1/4  ✓···
  …
+ Novel / Custom…
```

- **K/N badge** (e.g. `2/3`) and **observed-allele check string** (`✓✓·`) summarize each candidate at a glance
- **Absent rows** use a muted "·" glyph and a `[absent]` text marker (not blank — absence is data per Wiseman)
- **`[→ Set H1]` `[→ Set H2]` chips** are direct slot promotions per candidate row (NOT a nested menu)
- **The currently-called haplotype is badged `[CALLED]`** with a tinted background
- **`+ Novel / Custom…`** row at the bottom expands inline to a free-text field with nomenclature hint

### 2.4 Coverage Bar (≈40pt)

```
[================---] 1,788 / 2,050 supporting (87%)
```

The supporting-vs-total bar shows what percentage of locus reads supported any matched haplotype — a quick QC signal.

### 2.5 Neighbors (≈40pt)

```
Neighbors: DW471 M3B/M3B  |  DW473 M3B/M2B
```

One row before, one row after, with their calls at the same locus. Click to navigate to that sample.

### 2.6 Reason + Rationale (≈100pt, only when dirty)

Shown only after the analyst stages a change (clicked → Set H1 or → Set H2 or → Override Call):

```
Reason:
  (o) mis-call  ( ) dropout-suspected  ( ) cross-contamination
  ( ) novel    ( ) pedigree-conflict   ( ) analyst-judgment
  ( ) confirmed  ( ) other

Rationale (auto-filled, editable):
  "Promoting M2B at 1/4 diagnostic alleles; suspected dropout
   of 12_M2_B_109_04, 12_M2_B_150_01_01, 12_M2_B_162."

[Cancel]                                      [Save]
```

- **Reason tag is mandatory.** Controlled vocabulary above (Wiseman's list, extended from current 5-tag set).
- **Rationale is auto-filled** with a templated string summarizing the K/N delta the override implies. Editable; required text only when reason is `other` or `analyst-judgment`.
- **`[Cancel]`** discards staged changes (with confirm if dirty)
- **`[Save]`** commits the override + audit entry

---

## 3. Action Affordances

### 3.1 Promote candidate to H1 or H2

Each candidate row has explicit `[→ Set H1]` `[→ Set H2]` chip buttons. Clicking stages an override (does NOT commit immediately) — the reason/rationale section appears and the analyst confirms with `[Save]`.

Why staged commit and not per-pick:
- Per-pick pollutes the audit log with intermediate exploration states
- Per-pick makes "I was just looking" impossible
- Staged commit lets the analyst try M2B → see how the rationale auto-fills → maybe change mind → click M3B back

### 3.2 Compare two candidates

Click a candidate row to **pin it as the H1 column**; shift-click to **pin as H2**. The Slot Strip (§2.2) header then shows both candidates side-by-side with their allele-match grids aligned to the same allele names so green checks and red absent markers line up vertically. Makes the M2B-vs-M3B comparison visually trivial.

### 3.3 Novel / free-text override

The `+ Novel / Custom…` row at the bottom of the candidate list, when clicked, expands inline to:

```
+ Novel / Custom…
  Name: [_____________]   (hint: M2B_nov_01)
  Color: [glyph picker]   (palette: M1-M7 + neutral grey)
  Diagnostic alleles used (multi-select from observed):
    [ ] 12_M2_B_019_03   ← preselected (above threshold)
    [ ] …
  [→ Set H1]  [→ Set H2]
```

Reason tag is forced to `novel`. The diagnostic-allele multi-select means a later pipeline run can re-evaluate the novel claim against fresh data.

### 3.4 Confirm analyzer's call

The `[Confirm]` button in the sticky header writes an audit entry without changing the call:

```json
{ "action": "confirmed",
  "animal": "DW472", "locus": "MHC-B",
  "before": {"h1": "M3B", "h2": "M3B"},
  "after":  {"h1": "M3B", "h2": "M3B"},
  "reason_tag": "confirmed",
  "rationale": "",
  "author": "dhoconno",
  "timestamp": "2026-05-23T15:34:21Z"
}
```

This is the most common action. Currently has no audit record.

### 3.5 Skip

`[Skip]` moves the focus to the next review-flagged sample (in the active filter set) without recording anything. Used when the analyst wants to come back to this cell later.

---

## 4. Keyboard Navigation

The expert panel converged on these bindings (extending the existing ⌘R / ⌘K / ⌘⇧F / ⌘⇧O Review-lens shortcuts):

| Key | Action |
|---|---|
| `←` `→` | Move focus to previous/next locus in same sample (within the tape grid) |
| `↑` `↓` | Move focus to previous/next sample at same locus |
| `J` `K` | Next / previous sample (vim-style, alias for ↑/↓) |
| `L` `H` | Next / previous locus (vim-style, alias for ←/→) |
| `1` `2` | Focus H1 / H2 override target in the slot strip |
| `⏎` | On a candidate row: promote to the focused slot |
| `⌘⏎` | Save staged override |
| `⎋` | Discard staged changes (confirm if dirty) |
| `C` | Confirm analyzer (one-keystroke speed path) |
| `N` | Open novel-haplotype field |
| `S` | Skip to next review-flagged sample |
| `Home` / `End` | First / last locus in the row |
| `⌘Home` / `⌘End` | First / last sample |
| `PgUp` / `PgDn` | ±25 rows for fast scan |
| `Space` | (no-op when focused — `⏎` is the action key) |
| `Tab` | Move between panes (tape → inspector → filter bar), NOT between cells |

**Crucial:** Tab does NOT step through individual swatches. With 200 samples × 7 loci × 2 slots = 2,800 swatches, Tab navigation through them is unusable. Arrows handle intra-grid traversal (matches macOS HIG: Finder icon view, Numbers cells, Mail message list).

Focus on a cell uses Lungfish Orange at 2pt for the ring (≥3:1 contrast per WCAG 1.4.11).

---

## 5. Persistence Model

**Stage immediately, autosave every 5s, commit on explicit Save.**

- Clicking `[→ Set H1]` stages the change but does not commit
- Reason + rationale fields appear when staged
- `[Save]` commits + writes the audit entry
- Closing the app or switching bundles writes the staged state to a `.staged.json` companion file every 5s; surfaces a "1 unsaved override" badge in the window chrome
- Navigating to another cell while dirty prompts `[Save & Continue] [Discard] [Stay]`

Why not per-pick commit:
- Audit log integrity (intermediate exploration states are not analyst decisions)
- Lets the user try multiple candidates before committing
- Familiar pattern from Xcode/most code editors (typing isn't a commit; ⌘S is)

Why not commit-on-close:
- Reviewers expect their work to be retained across app launches
- The "1 unsaved override" badge surfaces the dirty state visibly

---

## 6. Audit Trail

Each Save appends an immutable entry to the bundle's `<bundle>/annotations.json` sidecar's `auditLog`:

```json
{
  "action": "override" | "confirmed" | "revert",
  "animal_id": "DW472",
  "gs_id": "DW472",
  "locus": "MHC-B",
  "slot": "h2",
  "before": {"h1": "M3B", "h2": "M3B"},
  "after":  {"h1": "M3B", "h2": "M2B"},
  "reason_tag": "dropout-suspected",
  "rationale": "Promoting M2B at 1/4 diagnostic alleles; suspected dropout of 12_M2_B_109_04, 12_M2_B_150_01_01, 12_M2_B_162.",
  "evidence_snapshot": {
    "locus_total_reads": 2050,
    "candidate_haplotypes": [
      {"name": "M3B", "observed_alleles": ["12_M3_B_075_01", "12_M3_B_165_01"], "k_over_n": "2/3"},
      {"name": "M2B", "observed_alleles": ["12_M2_B_019_03"],                   "k_over_n": "1/4"}
    ]
  },
  "definition_set_id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
  "definition_set_version": 1,
  "dropout_evaluator": {"absolute": 50, "locusFraction": 0.01},
  "author": "dhoconno",
  "timestamp": "2026-05-23T15:34:21Z",
  "entry_uuid": "..."
}
```

**Critical fields** (beyond the current schema):
- `evidence_snapshot` — captures the K/N matrix at decision time
- `definition_set_id` + `definition_set_version` — records which version of the definitions produced the call
- `dropout_evaluator` — the active threshold config
- `entry_uuid` — for revert references

**Revert** writes a new entry (`action: revert`) referencing the prior entry's UUID — never overwrites. The inspector shows a per-cell "History" disclosure listing all prior overrides for that animal-locus pair.

---

## 7. Accessibility Requirements

### 7.1 Focus

- `GenotypeHaplotypeTapeView` overrides `acceptsFirstResponder` and draws a visible Lungfish-Orange focus ring (2pt, ≥3:1 contrast).
- Space / Return on a focused cell triggers the same handler as mouse click.
- When the inspector opens, programmatically move first responder to the first interactive control (slot strip's Override button or the first candidate row).
- `NSAccessibility.Notification.layoutChanged` + brief `announcementRequested` ("Evidence for sample X, locus Y, H1=…, H2=…") fires on open.
- On close, restore focus to the originating cell (not the window's default responder).

### 7.2 VoiceOver structure

- Header: `.heading` level 2 ("Sample DW472, Locus MHC-B")
- Slot strip: `.heading` level 3 per slot
- Supporting alleles: `.list`
- Candidate haplotypes: `.list`, each row `.button` with composed label "M2B, K/N 1 of 4, 123 reads observed"
- Coverage bar: `.progressIndicator` with `accessibilityValue` = "1,788 of 2,050 reads, 87 percent"
- Override menu: removed in favor of `.button` chips per candidate

### 7.3 Live region for outcome

`applyOverrideFromPopover` fires `NSAccessibility.Notification.announcementRequested` with priority `.high`:
> "Override applied. H2 set to M2B. Call now M3B over M2B."

Sound-off users currently get zero feedback that an action took effect.

### 7.4 Text equivalents for visual encoding

The tape encodes "overridden" via diagonal hatching and "recombinant" via stripes. The inspector header restates these in words:
> "Manually overridden on 2026-05-18 by dhoconno"
> "Regional recombinant call (M2A on H1, M3A on H2)"

So a low-vision user at 400% zoom who can't resolve a 4pt hatch pattern still knows the call's provenance.

### 7.5 Persistent `focusedCellIndex`

`GenotypeOutlineView` stores a `focusedCellIndex: (sampleId: String, locus: String, slot: HaplotypeSlot)` and invalidates on `configure(rows:)`. Exposed via `NSAccessibility.Notification.selectedChildrenChanged` so VoiceOver tracks the focus ring without interact-mode.

---

## 8. Implementation file inventory

| File | Change |
|---|---|
| `Sources/LungfishApp/Views/Results/Genotype/GenotypeHaplotypeTapeView.swift` | `acceptsFirstResponder`, focus ring, arrow-key navigation, `focusedCellIndex` |
| `Sources/LungfishApp/Views/Results/Genotype/GenotypeOutlineView.swift` | Arrow-key routing between rows, `focusedCellIndex` getter/setter, scroll-into-view |
| `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` | Replace `presentCellEvidencePopover` with persistent inspector pane install/update; wire ⏎/⎋/C/N/J/K/L/H/1/2/⌘⏎; staged-override state machine; autosave timer |
| `Sources/LungfishApp/Views/Results/Genotype/GenotypeCallEvidenceView.swift` | Restructure to match §2 hierarchy: sticky header + slot strip + candidate matrix with `[→ Set H1] [→ Set H2]` chips + dirty-only reason/rationale block |
| `Sources/LungfishApp/Views/Results/Genotype/GenotypeNovelHaplotypeEntry.swift` (new) | Inline novel-haplotype field with multi-select observed alleles |
| `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift` | Extend `AuditEntry` with `evidenceSnapshot`, `definitionSetVersion`, `dropoutEvaluator`, `entryUUID`; extend `OverrideReasonTag` with `dropoutSuspected`, `pedigreeConflict`, `analystJudgment`, `other` |
| `Sources/LungfishApp/Views/Results/Genotype/GenotypeAnnotationStore.swift` | Staged-override state, `commitStaged()`, `discardStaged()`, autosave timer |

## 9. Out of scope (deferred)

- Pedigree-conflict detection — requires loading sire/dam metadata from LabKey or a sample-sheet column
- Cross-sample overrides ("apply this override to all samples with the same allele pattern")
- Bulk confirm ("confirm all calls in this run that match the analyzer")
- Inspector pane resize / detach into a floating window

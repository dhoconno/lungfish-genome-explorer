# FASTQ Operations UX Comprehensive Plan

**Date:** 2026-03-10
**Status:** Expert consensus from 4 independent UX/Swift review teams
**Related:** `drawer-architecture-recommendation.md` (full architecture spec)

---

## Expert Team Reports Summary

Four independent teams assessed the FASTQ operations UX:
1. **UX Panel Layout Expert** — Grey parameter bar critique, visual hierarchy
2. **UX Workflow Expert** — Demux centralization, operation flow design
3. **UX Architecture Expert** — Bottom drawer as universal ops surface
4. **Swift Implementation Expert** — Drawer height, resize mechanics, code patterns

---

## Consensus Decisions

### 1. Grey Parameter Bar → Subtle Toolbar Strip

**All teams agree:** The grey background box is visually heavy, wastes vertical space, and conflicts with macOS Tahoe Liquid Glass design language.

**Replacement:**
- Same background as the reads pane (white/system background)
- 1pt `NSColor.separatorColor` bottom border (no grey fill)
- Auto-sizing height: single row for 1-3 params, two rows for 4-6
- Standard `.small` AppKit controls (popup buttons, steppers, checkboxes)
- Slide animation on operation selection change

**For demux specifically:** When Demux Setup drawer is open, parameter bar shows a read-only summary line ("Nextera XT v2 | Both Ends | e=0.15 | Trim") — no editable controls.

### 2. Demux Configuration Centralized in Bottom Drawer

**All teams agree:** Demux controls should NOT appear in the parameter bar. The current three-location split (parameter bar, status bar, drawer) causes confusion.

**When user selects "Demultiplex (Barcodes)":**
1. Bottom drawer auto-opens to Demux Setup tab (0.2s ease-in-ease-out animation)
2. Parameter bar shows read-only summary or "Configure in panel below"
3. All config (kit, location, symmetry, error rate, trim, detect) lives in the drawer
4. "Detect Barcodes" moves INTO the Demux Setup tab (per-step, via existing `stepScoutButton`)

**Where teams disagreed and resolution:**

| Topic | Team 2 (Workflow) | Team 3 (Architecture) | Resolution |
|-------|-------------------|----------------------|------------|
| Run button location | Keep in bottom status bar for ALL ops (consistency) | Tier 3: Run only in drawer | **Keep Run in status bar for all ops.** Consistency across 15 operations wins. Drawer can have a secondary "Run" for convenience. |
| Progress indicator | Keep compact progress in status bar always | Tier 3: progress in drawer header AND run bar | **Keep compact progress in status bar.** Detailed progress in Operations Panel or drawer. Never leave user with zero visual feedback. |
| Read-only summary in param bar | Yes, confirms at-a-glance what will run | Not needed if drawer is open | **Yes, show it.** Low cost, high value for confirmation without scrolling. |

### 3. Bottom Drawer Needs Vertical Resize

**All teams agree.** Current 240pt default is too short for comfortable use.

**Implementation plan (from Swift expert research):**

| Property | Current | Proposed |
|----------|---------|----------|
| Default height | 240pt | 360pt (demux), tier-dependent for other ops |
| Min height | None | 150pt |
| Max height | None | 70% of window height |
| Resize handle | None | `DrawerDividerView` (5pt, grip indicator, drag cursor) |
| Height persistence | Key exists but never written | Persist per-operation via UserDefaults |

**Existing pattern to follow:** `AnnotationTableDrawerView` has a working `DrawerDividerView` (lines 72-110) with:
- `resetCursorRects` → `resizeUpDown` cursor
- Three subtle grip indicator lines as visual affordance
- `mouseDragged` → delta reporting via delegate
- Debounced UserDefaults persistence (0.3s DispatchWorkItem)

**Action:** Extract or replicate `DrawerDividerView` pattern for the FASTQ drawer. The handler goes in `ViewerViewController+FASTQDrawer.swift` — clamp between 150pt and 70% window, persist to `"fastqMetadataDrawerHeight"` (key already exists in code, just never written).

### 4. Tiered Hybrid Architecture for All Operations

**Teams 2 and 3 agree:** Do NOT move all operations to the drawer. Use a tiered approach:

| Tier | Operations | Config Surface | Drawer |
|------|-----------|----------------|--------|
| **Tier 1** (1-3 params) | Quality trim, fixed trim, subsample, length filter, dedup, search, quality report | Parameter bar only | Shows help/docs if open |
| **Tier 2** (4-8 params) | Adapter removal, contaminant filter, error correction, primer removal | Parameter bar (essentials) + drawer (advanced) | "Advanced..." disclosure opens drawer |
| **Tier 3** (complex) | Demultiplex, SPAdes assembly, read mapping, merge pairs, repair pairs | Drawer-primary | Auto-opens on selection |

**Key insight from Team 2:** "Demultiplexing is not a parameter tweak — it's a multi-step workflow. The drawer is the right home. But a user who wants to quality-trim at Q20 should not have to open a drawer."

### 5. Future: Operation-Aware Drawer Content

**Team 3 proposes** an `OperationDrawerContent` protocol system where the drawer adapts its tab set per operation:

| Operation | Tab 1 | Tab 2 | Tab 3 |
|-----------|-------|-------|-------|
| Demultiplex | Demux Setup | Sample Map | Barcode Kits |
| SPAdes Assembly | Assembly Config | Resource Limits | Output Options |
| Read Mapping | Reference & Algorithm | SAM/BAM Options | — |
| Tier 1 ops | Help & Tips | — | — |

**State preservation:** Dictionary keyed by `OperationKind` caches parameter values across operation switches. Clears when a new FASTQ file is loaded.

**Migration path:**
- Phase 1: Drawer resize + demux centralization + help content for Tier 1
- Phase 2: Tier 2 advanced panels
- Phase 3: Assembly/mapping drawer migration (SPAdes from modal sheet → drawer via NSHostingView)

---

## Implementation Priority (What to Build Now)

### Immediate (this sprint)

1. **Remove grey parameter bar background** — change to white/system background + 1pt separator
2. **Demux drawer centralization** — auto-open drawer on demux selection, remove inline demux controls from parameter bar, show read-only summary instead
3. **Drawer resize handle** — port `DrawerDividerView` pattern, increase default to 360pt
4. **Remove progress from reads area** — keep compact spinner in status bar only

### Next Sprint

5. **Operation-aware drawer content** — `OperationDrawerContent` protocol, help content for Tier 1
6. **State preservation** across operation switches
7. **Tier 2 advanced panels** for adapter removal, contaminant filter

### Future

8. **SPAdes assembly migration** from modal sheet to drawer
9. **Read mapping drawer**
10. **Background operation support** with progress pill

---

## Risk Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Vertical space on 1080p | High | Auto-collapse sparklines when Tier 3 drawer opens; 120pt min for preview |
| Two Run buttons confuse users | Low | Don't show both simultaneously; Tier 3 hides run bar's Run, shows drawer's |
| Drawer content churning | Medium | Cross-fade transitions, state preservation, header label showing operation name |
| Assembly migration regression | Medium | Use NSHostingView to embed existing SwiftUI form, avoid rewrite |

---

## Files to Modify (Immediate Sprint)

| File | Changes |
|------|---------|
| `FASTQDatasetViewController.swift` | Remove grey param bar background, demux parameter bar logic, progress indicator from reads area |
| `FASTQMetadataDrawerView.swift` | Add DrawerDividerView, increase default height, add Run/Detect buttons to Demux Setup tab |
| `ViewerViewController+FASTQDrawer.swift` | Resize handle delegate, height persistence, auto-open on demux selection |
| `OperationPreviewView.swift` | May need layout adjustment for taller drawer |

---

## Design Principles (for all future FASTQ UI work)

1. **Data is primary.** Parameters serve the data, not the other way around.
2. **One source of truth per operation.** Never duplicate editable controls.
3. **Tier by complexity.** Simple → param bar. Complex → drawer.
4. **Always show progress.** The user must always see that something is happening.
5. **Preserve state.** Switching operations should never lose configuration.
6. **Follow macOS conventions.** Liquid Glass aesthetics, system colors, standard controls.

# User Feedback Remediation Plan

## Overview
Systematic remediation of user-reported issues from GUI testing session.
Date: 2026-02-03

---

## Phase 1: Critical Input/Data Bugs
**Status: COMPLETE (4/4 Resolved)**

### Issues

#### ✅ 1. Backspace not working in text fields
**Root Cause:** Global key event monitor in `SidebarViewController.swift` (lines 121-134) intercepts all keyDown events across all windows, including modal sheets. The guard condition checked `firstResponder === outlineView` but didn't verify `event.window === sidebarWindow`, so events for sheet text fields were incorrectly processed.

**Fix:** Added `event.window === sidebarWindow` check to guard condition to ensure only events for the sidebar window are processed.

**File:** `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:122-126`

#### ✅ 2. SRA search works in CLI but not GUI
**Root Cause:** Timer callback loses MainActor isolation. In `SRABrowserViewModel.performSearch()`, `Timer.scheduledTimer` creates a non-MainActor closure. The `Task { }` created inside inherits non-isolation, causing `@Published` property updates to happen off the MainActor. SwiftUI doesn't observe these changes correctly.

**Fix:** Replaced Timer+Task pattern with `Task.detached` + `performOnMainRunLoop` helper (same pattern used in working `DatabaseBrowserViewController`). Added `objectWillChange.send()` before property mutations.

**Files:** `Sources/LungfishApp/Views/DatabaseBrowser/SRABrowserViewController.swift:17-28` (helper), lines 160-204 (performSearch), lines 208-271 (performDownload)

#### ✅ 3. 4 sequences selected but only 3 downloaded
**Root Cause:** `SearchResultRecord.Hashable` implementation only used `accession` field while auto-synthesized `Equatable` compared all fields including `id`. This caused Set corruption when records had same accession but different UIDs (e.g., multiple viral isolates).

**Fix:** Changed `hash(into:)` to use `id` instead of `accession` to match Equatable behavior.

**File:** `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:1865-1871`

#### ✅ 4. Duplicated Region annotations
**Status:** Investigated - NOT A BUG

**Findings:**
- GenBank parser creates annotations correctly (no duplication at parse time)
- Single-sequence mode calls `drawAnnotations()` once
- Multi-sequence mode properly filters annotations per sequence
- **Root cause: SARS-CoV-2 (NC_045512) genuinely has multiple region features** representing different genomic regions (ORF1ab, ORF1a, S protein, etc.)
- The "duplication" the user sees is the actual data structure of the virus genome

**Minor improvement made:** Added missing `case "region"` to NCBIService feature type mapping (was incorrectly falling through to `misc_feature`)

**File:** `Sources/LungfishCore/Services/NCBI/NCBIService.swift:725-726`

### Experts Assigned
- `debugger` (ad53f1e) - Backspace input: **COMPLETED**
- `debugger` (a6925c2) - SRA GUI search: **COMPLETED**
- `debugger` (a6caa7d) - Download logic: **COMPLETED**
- `debugger` (a7cd4df) - Annotation duplication: **COMPLETED** (Not a bug)

### Meeting Notes - Phase 1 Review (2026-02-03)
**Attendees:** debugger agents ad53f1e, a6925c2, a6caa7d, a7cd4df

**Key Findings:**
1. Three bugs traced to Swift concurrency/state management issues
2. Two involved improper MainActor handling (backspace: event routing, SRA: Timer callbacks)
3. One involved Hashable/Equatable contract violation
4. Annotation "duplication" was actually correct behavior - SARS-CoV-2 has multiple region features

**Action Items:**
- [x] Implement backspace fix
- [x] Implement SRA search fix
- [x] Implement download selection fix
- [x] Complete annotation investigation
- [x] Build verification
- [x] Commit Phase 1 changes

---

## Phase 2: Inspector & Selection Features
**Status: COMPLETE (4/4 Resolved)**

### Issues

#### ✅ 1. Annotation details not shown in Inspector
**Root Cause:** SelectionSection was already implemented correctly. The notification flow from viewer to Inspector was working.

**Improvement Made:** Added `objectWillChange.send()` trigger before property mutations to ensure SwiftUI observes changes.

**File:** `Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:55-60`

#### ✅ 2. Color picker not updating on selection
**Root Cause:** Multiple issues identified:
- Missing property reset on deselection (stale values)
- SwiftUI Color equality issues with @Published
- onChange handlers firing during programmatic updates
- Color extraction failing for system colors

**Fixes:**
1. Added `isUpdatingFromSelection` flag to guard onChange handlers
2. Reset all properties (name, type, color, notes) on deselection
3. Added `objectWillChange.send()` before mutations
4. Improved color extraction with NSColor fallback for system colors

**File:** `Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:39, 55-83, 115-148`

#### ✅ 3. Double-click/hover annotation popup
**Implementation:** Added double-click detection in mouseDown handler. Shows NSPopover with AnnotationPopoverView containing annotation name, type, location, length, strand, and notes.

**Files:**
- `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:976, 1908-1935, 2038-2069, 3439-3524`
- `Sources/LungfishApp/Views/Viewer/SequenceViewerView+MultiSequence.swift:958-998`

#### ✅ 4. Hit testing coordinate mismatch
**Root Cause:** `annotationAtPoint` did not clamp `startX` to 0 like `drawAnnotations` does, causing row assignment mismatches for partially visible annotations.

**Fix:** Added `let startX = max(0, rawStartX)` to match drawing logic.

**File:** `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:1800-1801`

---

## Phase 3: Viewer & Zoom Improvements
**Status: COMPLETE (4/4 Resolved)**

### Issues

#### ✅ 1. Zoom In/Out toolbar buttons
**Status:** Already implemented. Toolbar has ZoomIn/ZoomOut buttons connected to ViewerViewController zoom methods.

**File:** `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift:210-227`

#### ✅ 2. Sequence height at low zoom
**Root Cause:** At LINE_MODE zoom, sequence was drawn as thin 4px line in 40px track, looking empty.

**Fix:** Increased line thickness to proportional value: `max(8, trackHeight * 0.4)` (minimum 8px, up to 40% of track height).

**File:** `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:1715-1716`

#### ✅ 3. U→T display for RNA
**Root Cause:** Only converted T→U when RNA mode enabled. Did not convert U→T when RNA mode disabled.

**Fix:** Added bidirectional conversion logic:
- RNA mode ON: T → U
- RNA mode OFF: U → T

**File:** `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:1553-1560`

#### ✅ 4. Base coloring threshold (~1% / 300bp)
**Root Cause:** Only two rendering modes (BASE_MODE < 10 bp/pixel, LINE_MODE >= 10 bp/pixel). No intermediate colored block mode.

**Fix:** Added BLOCK_MODE (10-300 bp/pixel) that shows colored blocks with dominant base per bin:
- BASE_MODE: < 10 bp/pixel - Individual bases with letters
- BLOCK_MODE: 10-300 bp/pixel - Colored blocks (no letters)
- LINE_MODE: > 300 bp/pixel - Gray line

**File:** `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:1292-1319`

---

## Phase 4: Search & Database Features
**Status: COMPLETE (3/3 Resolved)**

### Issues

#### ✅ 1. RefSeq filter for NCBI Virus
**Implementation:** Added `refseqOnly` parameter to `searchVirus()` method. When enabled, adds `refseq[filter]` to NCBI query.

**UI:** Added "RefSeq Only" toggle checkbox that appears when Virus database is selected.

**Files:**
- `Sources/LungfishCore/Services/NCBI/NCBIService.swift:281-301`
- `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:227, 400-401, 500-507, 1154-1159`

**Tests:** Added `testSearchVirusRefseqOnlyAddsRefseqFilter()` and `testSearchVirusWithoutRefseqOnlyDoesNotAddRefseqFilter()` to NCBIServiceTests.

#### ✅ 2. Search term autocomplete cache
**Implementation:** Added search history storage using UserDefaults. Saves search terms on successful search, shows autocomplete suggestions matching current input.

**Features:**
- Stores up to 50 recent search terms
- Shows up to 5 matching suggestions as dropdown
- Click suggestion to autofill search field
- History persists across app restarts

**Files:**
- `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:294-314, 360-396, 429, 1360-1398`

#### ✅ 3. Pathoplexus integration
**Implementation:** PathoplexusService already existed but wasn't connected to search flow. Added case handler in performSearch to use Pathoplexus search API.

**File:** `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:597-608`

---

## Decision Log

### 2026-02-03 - Phase 1 Kickoff
- **Decision**: Address critical bugs first before UX improvements
- **Rationale**: Core functionality must work before enhancing features
- **Participants**: Initial planning

---

## Test Results

### Phase 1 Tests
TBD

### Phase 2 Tests
TBD

### Phase 3 Tests
TBD

### Phase 4 Tests
TBD

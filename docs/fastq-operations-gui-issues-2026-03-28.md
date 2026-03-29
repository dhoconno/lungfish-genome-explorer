# FASTQ Operations GUI Testing Report — 2026-03-28

## Test Environment
- **Build**: Debug (Xcode, commit b5dec50)
- **Project**: VSP2
- **Dataset**: School001-20260216_S132_L008 (16.35M reads, 1.79 Gb, single-end)
- **Branch**: metagenomics-workflows

---

## GLOBAL ISSUES (apply to all operations)

### G.1 [AESTHETIC/HIGH] Operations panel text truncation — NOT YET FIXED
- **Severity**: High
- **Description**: The committed Wave 2B changes (widen operations sidebar, add CLASSIFICATION section) were lost during worktree merge conflicts. All operation names remain truncated: "Compute Qu...", "Subsample...", "Adapter Re...", "Fixed Trim (...", "PCR Primer...", "Filter by Rea...", "Contaminant...", "Remove Dup...".
- **Root cause**: FASTQDatasetViewController.swift changes from worktree-agent-ac0daad2 were not fully merged — the `classifyReads` enum case and CLASSIFICATION category were lost.
- **Fix needed**: Re-implement Wave 2B: widen LayoutDefaults.minSidebarWidth to 200, add `classifyReads` case, add CLASSIFICATION category.

### G.2 [AESTHETIC/MEDIUM] Operation description text clipped on left
- **Description**: When an operation is selected, the description text in the parameter area is clipped on the left edge: "...th distribution, and quality score histograms." — the beginning of the sentence is hidden behind the operations list.
- **Expected**: Full description visible, or text wraps properly.

### G.3 [UX/MEDIUM] Status bar progress text truncated
- **Description**: During computation, "Computing rep..." is truncated. Should show full status like "Computing report..." or "Computing quality report...".

### G.4 [UX/MEDIUM] No progress bar or percentage during computation
- **Description**: The bottom bar shows "Computing quality re..." text and Cancel/Compute buttons but no progress bar or elapsed time. Quality report on 16M reads took 6+ minutes with no progress indication. User has no way to estimate remaining time.

### G.5 [FUNCTIONAL/MEDIUM] Cancel shows error dialog instead of silent return
- **Description**: Cancelling a running operation (e.g., quality report) triggers an error dialog "Quality Report Failed — CancellationError()". Cancellation is a deliberate user action and should NOT show an error alert. It should silently return to the ready state.
- **Impact**: Alarming to users — they think something broke when they intentionally cancelled.

---

## OPERATION-SPECIFIC ISSUES

### 1. Compute Quality Report (qualityReport)
- **Status**: TESTED — ran 6+ min on 16M reads, cancelled due to slow speed
- **UI**: No parameters. Single "Compute" button.
- **Issues**: G.1 (name "Compute Qu..."), G.2 (desc clipped), G.3 (status truncated), G.4 (no progress bar), G.5 (cancel shows error)

### 2. Subsample by Proportion (subsampleProportion)
- **Status**: TESTED UI — config inspected
- **UI**: "Proportion: 0.10" text field. Bottom: "Estimated output: ~1.6M reads"
- **Issues**: G.1 (name "Subsample..."), no slider for 0-1 range

### 3. Subsample by Count (subsampleCount)
- **Status**: TESTED UI — config inspected
- **UI**: "Count: 10000" text field. Bottom shows "Estimated output: 1.0k r..." (truncated)
- **Issues**: G.1 (name "Subsample..." — identical to #2), status bar shows stale "Quality:" prefix

### 4. Quality Trim (qualityTrim)
- **Status**: TESTED UI — config inspected
- **UI**: Quality threshold "4" field, "Cut Right (3')" dropdown
- **Issues**: G.1 (name "Quality Trim" — just barely fits!), parameters cramped

### 5. Adapter Removal (adapterTrim)
- **Status**: TESTED UI — config inspected
- **UI**: Dropdown "...ect" (truncated, likely "auto-detect"), "Adapter: [auto-detect]" field
- **Issues**: G.1 (name "Adapter Re..."), dropdown label truncated

### 6. Fixed Trim (fixedTrim)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Fixed Trim (...")

### 7. PCR Primer Trimming (primerRemoval)
- **Status**: SEEN in list
- **Issues**: G.1 (name "PCR Primer...")

### 8. Filter by Read Length (lengthFilter)
- **Status**: SEEN in list (name "Filter by Rea...")
- **Issues**: G.1

### 9. Contaminant Filter (contaminantFilter)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Contaminant...")

### 10. Remove Duplicates (deduplicate)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Remove Dup...")

### 11. Filter by Sequence Presence (sequencePresenceFilter)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Filter by Seq...")

### 12. Error Correction (errorCorrection)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Error Correc...")

### 13. Orient Reads (orient)
- **Status**: SEEN in list — **ONLY operation whose name fits: "Orient Reads"**
- **Note**: Requires reference FASTA. Name is 12 chars, just under the truncation limit.

### 14. Demultiplex (demultiplex)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Demultiplex..." — only needs ~1 more char)

### 15. Merge Overlapping Pairs (pairedEndMerge)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Merge Overl..."), requires interleaved PE input

### 16. Repair Paired Reads (pairedEndRepair)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Repair Paire..."), requires interleaved PE input

### 17. Find by ID/Description (searchText)
- **Status**: SEEN in list
- **Issues**: G.1 (name "Find by ID/D...")

### 18. Find by Sequence (searchMotif)
- **Status**: NOT VISIBLE — must be below "Find by ID/D..." in scrolled view
- **Issues**: Likely G.1

---

## TRUNCATION ANALYSIS

Of 18 operations, **only 1 ("Orient Reads")** has a name short enough to display fully.
The remaining **17 operations (94%)** are truncated.

| Operation | Display | Chars Visible | Full Name |
|-----------|---------|---------------|-----------|
| qualityReport | "Compute Qu..." | 10 | Compute Quality Report (22) |
| subsampleProportion | "Subsample..." | 9 | Subsample by Proportion (23) |
| subsampleCount | "Subsample..." | 9 | Subsample by Count (18) |
| qualityTrim | "Quality Trim" | 12 | Quality Trim (12) ✅ |
| adapterTrim | "Adapter Re..." | 10 | Adapter Removal (15) |
| fixedTrim | "Fixed Trim (..." | 12 | Fixed Trim (5'/3') (17) |
| primerRemoval | "PCR Primer..." | 10 | PCR Primer Trimming (19) |
| lengthFilter | "Filter by Rea..." | 13 | Filter by Read Length (20) |
| contaminantFilter | "Contaminant..." | 11 | Contaminant Filter (18) |
| deduplicate | "Remove Dup..." | 10 | Remove Duplicates (17) |
| sequencePresenceFilter | "Filter by Seq..." | 13 | Filter by Sequence (17) |
| errorCorrection | "Error Correc..." | 11 | Error Correction (16) |
| orient | "Orient Reads" | 12 | Orient Reads (12) ✅ |
| demultiplex | "Demultiplex..." | 11 | Demultiplex (11) — almost fits |
| pairedEndMerge | "Merge Overl..." | 10 | Merge Overlapping Pairs (23) |
| pairedEndRepair | "Repair Paire..." | 12 | Repair Paired Reads (19) |
| searchText | "Find by ID/D..." | 12 | Find by ID/Description (22) |
| searchMotif | "Find by Seq..." | 11 | Find by Sequence (15) |

**Current panel width accommodates ~12 chars. Need ~23 chars for full names.**
**Fix: Increase operations column width from ~100px to ~200px.**

# GUI Fix Implementation Plan — Master Sprint

## Source Documents
- `docs/gui-testing-issues-2026-03-28.md` — Metagenomics classifier testing (48 issues)
- `docs/fastq-operations-gui-issues-2026-03-28.md` — FASTQ operations testing (5 global + per-operation)
- `Tests/LungfishAppTests/GUIRegressionTests.swift` — 21 regression tests

---

## WAVE 1: CRITICAL BUGS (must fix first)

### 1A. Kraken2 Database Detection Bug
- **File**: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
- **Fix**: Add `@State private var installedDatabases: [MetagenomicsDatabaseInfo] = []` and `onAppear` handler to load from `MetagenomicsDatabaseRegistry.shared`, matching `TaxTriageWizardSheet.swift` lines 40, 459-466.
- **Verification**: Launch wizard, verify "Viral" database appears in dropdown.

### 1B. Cancel Shows Error Dialog
- **File**: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
- **Fix**: In the operation execution handler, catch `CancellationError` and return silently instead of showing alert. Pattern: `catch is CancellationError { return }` before the generic error handler.
- **Verification**: Start quality report, cancel, verify no error dialog appears.

---

## WAVE 2: HIGH-PRIORITY LAYOUT FIXES

### 2A. Operations Panel Width (fixes 17 of 18 truncated names)
- **File**: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
- **Fix**: Change `LayoutDefaults.minSidebarWidth` from ~100 to 200. Also adjust the NSSplitView constraints so the operations list column has adequate width.
- **Impact**: Fixes G.1 for all operations, fixes description clipping (G.2).

### 2B. Add CLASSIFICATION Section to Operations Panel
- **File**: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
- **Fix**: Add `case classifyReads` to `OperationKind` enum. Add `("CLASSIFICATION", [.classifyReads])` to the categories array. Wire the action to `AppDelegate.classifyReads()`.
- **Impact**: Discoverable classifier access from within the FASTQ operations panel.

### 2C. Minimum Window Width
- **File**: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` or window controller
- **Fix**: Set minimum window content size to at least 1000x600 to prevent extreme truncation.

---

## WAVE 3: METAGENOMICS RESULTS IMPROVEMENTS

### 3A. Strain Name Disambiguation
- **File**: `Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift`
- **Fix**: When multiple children share the same prefix, show the distinguishing suffix or accession number. Add tooltip with full name on hover.

### 3B. TaxTriage Truncated Columns
- **File**: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- **Fix**: Ensure "Confidence" column header is fully visible. Add auto-resize or minimum column widths. Show full organism names on hover via tooltip.

### 3C. Context Menu Enhancement
- **Files**: `EsVirituResultViewController.swift`, `TaxTriageResultViewController.swift`
- **Fix**: Add context menu items: "Copy Accession Number", "Copy Row as TSV", "Export Selected Reads", "Look Up in NCBI Taxonomy" (opens browser to taxonomy URL).

### 3D. EsViritu Bar Chart Labels
- **File**: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- **Fix**: Remove `s__` prefix from user-facing species labels. Show full species names or truncate with tooltip.

---

## WAVE 4: PROGRESS AND STATUS IMPROVEMENTS

### 4A. Progress Bar for Long Operations
- **File**: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
- **Fix**: Add `NSProgressIndicator` to the bottom bar area. Show elapsed time. For operations that support streaming progress (like seqkit), wire progress callback.

### 4B. Sidebar Result Node Updates
- **File**: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- **Fix**: When classification completes, auto-expand the FASTQ bundle in the sidebar to show the new result node. Add a badge or visual indicator.

### 4C. Stale Status Text Cleanup
- **File**: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
- **Fix**: Clear status bar text when switching operations. Prevent "Quality report failed" from persisting when switching to Subsample.

---

## WAVE 5: INSPECTOR AND POLISH

### 5A. Context-Aware Inspector for FASTQ
- **File**: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- **Fix**: When a FASTQ dataset is selected, hide genomic-specific controls (Track Height, Annotation Style). Show FASTQ-relevant info instead.

### 5B. Window Title Shows Project Name
- **File**: `Sources/LungfishApp/App/AppDelegate.swift` or window controller
- **Fix**: Set window title to "ProjectName — Lungfish Genome Explorer" when a project is open.

### 5C. Duplicate "Result Summary" in Inspector
- **File**: Inspector section for metagenomics results
- **Fix**: Remove duplicate heading text.

---

## VERIFICATION PROCESS

After each wave:
1. Build with `swift build --build-tests`
2. Run regression tests: `swift test --filter "VirusNameDisplay|ContextMenuCompleteness|ClassificationWizardDatabase|TaxTriageResultsDisplay|EsVirituHierarchy|ExportFeature|UnifiedWizard|OperationsPanel|SidebarDisplay"`
3. Build Xcode scheme: `xcodebuild -scheme Lungfish -configuration Debug build`
4. Launch app and verify visually with Claude Computer Use
5. Document any remaining issues in the issues log
6. If issues remain, loop back to implementation

---

## TESTING CHECKLIST

### Metagenomics Classifier Tests
- [ ] Kraken2 wizard shows "Viral" in database dropdown
- [ ] Kraken2 classification runs successfully
- [ ] EsViritu results show full virus names (not truncated)
- [ ] EsViritu Influenza C strains are distinguishable
- [ ] TaxTriage results show full "Confidence" column header
- [ ] TaxTriage organism names are fully visible
- [ ] Context menu has Copy Accession, Copy Row as TSV
- [ ] Bar chart removes s__ prefix

### FASTQ Operations Tests
- [ ] All 18 operation names fully visible (no truncation)
- [ ] CLASSIFICATION section appears in operations panel
- [ ] Description text not clipped on left
- [ ] Cancel does NOT show error dialog
- [ ] Quality report shows progress indicator
- [ ] Status text clears when switching operations
- [ ] Subsample estimated output text not truncated

### Layout Tests
- [ ] Minimum window width enforced (~1000px)
- [ ] Window title shows project name
- [ ] Inspector context-aware for FASTQ
- [ ] Sidebar auto-expands after classification completes

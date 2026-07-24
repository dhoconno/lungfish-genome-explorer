# Species-Agnostic MHC Allele Display Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sort full-length MHC known, novel, extension, and un-nameable rows by a species-agnostic biological locus order in initial Excel workbooks, explicit workbook updates, and the LGE viewport.

**Architecture:** Add one public Swift comparator to `LungfishIO`, which is already imported by the workflow and genotype UI targets. Initial workbook generation and the viewport call that comparator directly; the embedded Python workbook updater mirrors the same documented tuple key because it executes outside Swift. No scientific schema or artifact changes are required.

**Tech Stack:** Swift 6.2, locale-independent ASCII-natural string comparison, XCTest, Python/openpyxl embedded by the workbook revision service, Swift Package Manager.

---

### Task 1: Shared Species-Agnostic Display Order

**Files:**
- Create: `Sources/LungfishIO/Bundles/MHCAlleleDisplayOrder.swift`
- Create: `Tests/LungfishIOTests/MHCAlleleDisplayOrderTests.swift`

- [ ] **Step 1: Write the failing shared-order tests**

Create fixtures under both `Mafa-` and `Mamu-` prefixes, plus an unspecified locus, malformed name, and blank name. Assert this locus sequence:

```swift
let names = [
    "Mamu-K*01:01", "", "Mamu-B16*01:01", "Mamu-DRB*01:01",
    "Mamu-AG*01:01", "Mamu-B*010:01", "Mamu-A10*01:01",
    "Mamu-G*01:01", "Mamu-A2*01:01", "Mamu-I*01:01",
    "Mamu-F*01:01", "Mamu-J*01:01", "Mamu-B*002:01",
    "Mamu-B02ps*01:01", "Mamu-A1*01:01",
]
XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
    "Mamu-A1*01:01", "Mamu-A2*01:01", "Mamu-A10*01:01",
    "Mamu-B*002:01", "Mamu-B*010:01",
    "Mamu-B02ps*01:01", "Mamu-B16*01:01",
    "Mamu-I*01:01", "Mamu-F*01:01", "Mamu-G*01:01",
    "Mamu-AG*01:01", "Mamu-J*01:01", "Mamu-K*01:01",
    "Mamu-DRB*01:01", "",
])
```

Also assert that replacing `Mamu-` with `Mafa-` produces the same locus sequence, that mixed-prefix `A1*` precedes mixed-prefix `A2*`, and that equal names use supplied stable IDs as tie-breakers.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
swift test --filter MHCAlleleDisplayOrderTests
```

Expected: compilation fails because `MHCAlleleDisplayOrder` does not exist.

- [ ] **Step 3: Implement the minimal shared comparator**

Create a public utility with this interface:

```swift
public enum MHCAlleleDisplayOrder {
    public static func compare(
        _ lhs: String,
        _ rhs: String,
        lhsStableID: String = "",
        rhsStableID: String = ""
    ) -> ComparisonResult

    public static func lessThan(_ lhs: String, _ rhs: String) -> Bool
}
```

Parse the final `-` before the first `*` as the species/locus separator. Build a structured key whose group is: numbered `A` = 0, exact `B` = 1, numbered/suffixed `B` = 2, exact `I` = 3, `F` = 4, `G` = 5, `AG` = 6, `J` = 7, `K` = 8, unspecified nonblank = 9, blank = 10. Compare group, locus, allele, species prefix, complete name, and stable ID with the same locale-independent ASCII digit/non-digit token comparator used by the embedded Python updater, followed by exact scalar fallbacks. Treat comparisons that remain equal as `.orderedSame`.

- [ ] **Step 4: Run the shared tests and verify GREEN**

Run:

```bash
swift test --filter MHCAlleleDisplayOrderTests
```

Expected: all `MHCAlleleDisplayOrderTests` pass.

- [ ] **Step 5: Commit the shared contract**

```bash
git add Sources/LungfishIO/Bundles/MHCAlleleDisplayOrder.swift Tests/LungfishIOTests/MHCAlleleDisplayOrderTests.swift
git commit -m "feat: add species-agnostic MHC allele ordering"
```

### Task 2: Initial Excel Workbook Ordering

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`

- [ ] **Step 1: Write failing Unified and Unmatched worksheet tests**

Add a Unified fixture containing raw known IDs mapped to out-of-order `Mamu-A2*`, `Mamu-B*010`, `Mamu-B02ps*`, and `Mamu-A1*` display names plus candidate rows. Assert that all known and candidate rows form one sequence sorted by `display_name`, not separate known/candidate blocks. Preserve distinct stable IDs when candidate names collide.

Add normalized unmatched rows whose provisional names span `A`, `B`, numbered B, `I`, `F`, `G`, `AG`, `J`, `K`, unspecified, and `nil`. Assert the worksheet's `Provisional Allele Name` column follows the shared order and blank un-nameable rows end in stable-ID order.

- [ ] **Step 2: Run the workflow tests and verify RED**

Run:

```bash
swift test --filter FullLengthONTMHCWorkbookProjectionTests
```

Expected: ordering assertions fail because the current builders use raw call ID, artifact order, and record category/stable ID.

- [ ] **Step 3: Sort the initial workbook rows**

In `FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildRows`, construct all known and candidate data rows first, then sort the combined rows with:

```swift
MHCAlleleDisplayOrder.compare(
    lhs[2], rhs[2],
    lhsStableID: lhs[3].isEmpty ? lhs[1] : lhs[3],
    rhsStableID: rhs[3].isEmpty ? rhs[1] : rhs[3]
) == .orderedAscending
```

Keep the header fixed at index zero. In `FullLengthONTMHCUnmatchedWorksheetBuilder.rowLess`, compare provisional names and stable IDs through the same utility; do not group candidate rows ahead of un-nameable rows.

- [ ] **Step 4: Run the workflow tests and verify GREEN**

Run:

```bash
swift test --filter FullLengthONTMHCWorkbookProjectionTests
```

Expected: all projection tests pass.

- [ ] **Step 5: Commit initial workbook ordering**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift
git commit -m "feat: biologically sort MHC workbook rows"
```

### Task 3: Explicit Workbook Update Ordering

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Modify: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

- [ ] **Step 1: Write a failing explicit-update integration test**

Create an existing two-sheet workbook fixture, feed out-of-order known calls and normalized candidate/un-nameable rows under a `Mamu-` prefix, run `GenotypeWorkbookRevisionService`, and inspect the rebuilt workbook with openpyxl. Assert the Unified `display_name` column and Unmatched `Provisional Allele Name` column match the same expected list used by the Swift tests, while analyst header values remain preserved.

- [ ] **Step 2: Run the revision test and verify RED**

Run:

```bash
swift test --filter GenotypeWorkbookRevisionServiceTests/testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder
```

Expected: the assertion fails because the update script sorts known calls and candidates independently and sorts unmatched rows by category/stable ID.

- [ ] **Step 3: Mirror the ordering key in the embedded Python script**

Add a pure Python helper before workbook construction:

```python
def mhc_display_sort_key(display_name, stable_id=""):
    name = clean(display_name)
    if not name:
        return (10, natural_key(""), natural_key(""), natural_key(""), natural_key(""), natural_key(stable_id))
    star = name.find("*")
    dash = name.rfind("-", 0, star) if star >= 0 else -1
    if star < 0 or dash < 0:
        return (9, natural_key(name), natural_key(""), natural_key(""), natural_key(name), natural_key(stable_id))
    species = name[:dash]
    locus = name[dash + 1:star]
    allele = name[star + 1:]
    group = mhc_locus_group(locus)
    return (group, natural_key(locus), natural_key(allele), natural_key(species), natural_key(name), natural_key(stable_id))
```

Implement `natural_key` with ASCII-lowercased digit/non-digit chunks and `mhc_locus_group` with the same exact groups as Swift. Numeric chunks compare by overflow-free magnitude, and exact string fallbacks resolve natural ties. Build one combined Unified row list before appending it, and sort normalized unmatched rows solely by provisional-name key plus stable ID.

- [ ] **Step 4: Run revision and related projection tests**

Run:

```bash
swift test --filter 'GenotypeWorkbookRevisionServiceTests|FullLengthONTMHCWorkbookProjectionTests'
```

Expected: both suites pass, including analyst-value preservation and atomic-failure tests.

- [ ] **Step 5: Commit update-path ordering**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
git commit -m "feat: preserve MHC allele order on workbook update"
```

### Task 4: Viewport Ordering

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing viewport ordering tests**

Build a full-length MHC result containing known and candidate rows under a `Mamu-` prefix in deliberately scrambled locus order. Assert `testingVisibleGenotypes` follows the shared biological order on initial load. Invoke the existing test sort hook for the allele column in ascending and descending directions and assert biological order and its exact reverse. Include two candidate rows with the same provisional name but different stable IDs.

- [ ] **Step 2: Run the viewport test and verify RED**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testFullLengthMHCRowsUseSpeciesAgnosticBiologicalAlleleOrder
```

Expected: the row-order assertion fails because the current comparator sorts by raw locus/name text.

- [ ] **Step 3: Use the shared comparator for allele sorting**

Change `GenotypeCandidateMatrixProjection.rowComesBefore` to call `MHCAlleleDisplayOrder.compare` on `alleleName`, passing candidate stable ID or deterministic row identity. In `GenotypeComparisonMatrixView.compare`, use the same comparator when the active key is the genotype column or the configured GenBank allele field. Keep all other user-selected column comparators unchanged. Reverse the final comparison result for descending order without changing tie-break semantics.

- [ ] **Step 4: Run viewport and shared tests**

Run:

```bash
swift test --filter 'MHCAlleleDisplayOrderTests|GenotypeResultViewportTests'
```

Expected: all shared and viewport tests pass.

- [ ] **Step 5: Commit viewport ordering**

```bash
git add Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: biologically sort MHC viewport rows"
```

### Task 5: End-to-End Verification and Debug Relaunch

**Files:**
- Verify only; no production files expected.

- [ ] **Step 1: Run all focused suites**

```bash
swift test --filter 'MHCAlleleDisplayOrderTests|FullLengthONTMHCWorkbookProjectionTests|FullLengthONTMHCGenotypingPipelineTests|GenotypeWorkbookRevisionServiceTests|GenotypeResultViewportTests|AppDebugLaunchConfigurationTests'
```

Expected: zero failures.

- [ ] **Step 2: Re-run the four-sample CLI analysis**

Use the approved CR1178/CR1178b/CR1182/CR1182b inputs and `IPD-MHC_NHKIR_classI_Mafa.lungfishref` reference to create a fresh verification bundle. Confirm scientific provenance records the final workbook and all inputs with checksums, sizes, runtime identity, argv, defaults, exit status, and wall time.

- [ ] **Step 3: Inspect the generated workbook**

Use `@oai/artifact-tool` to verify the workbook still has exactly `Unified Genotype Pivot` and `Unmatched Alleles`, contains no formula errors, and both requested name columns follow the biological comparator. Render both sheets and visually inspect them.

- [ ] **Step 4: Build and relaunch the debug app**

```bash
./scripts/build-app.sh --configuration debug --log-dir .superpowers/build-logs
```

Quit every running Lungfish process, launch `build/Debug/Lungfish.app` with the fresh bundle, and verify the sole process path, `CFBundleDisplayName = Lungfish Debug`, and `CFBundleIdentifier = com.lungfish.browser.debug`.

- [ ] **Step 5: Final repository verification**

```bash
git diff --check
git status --short --branch
```

Expected: no uncommitted tracked changes and no whitespace errors.

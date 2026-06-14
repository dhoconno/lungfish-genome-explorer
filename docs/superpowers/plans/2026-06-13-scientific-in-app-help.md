# Scientific In-App Help Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable, style-checked in-app help catalog and apply a first pass of macOS-native help to scientific workflows and dialogs.

**Architecture:** Put stable help copy and helper APIs in `LungfishKit` so AppKit and SwiftUI surfaces can consume the same reviewed language. Wire the first pass into shared operation dialogs, FASTQ operation panes, BAM primer-trim and variant-calling panes, classifier result action bars, and bundled Help topics. Keep data-changing provenance requirements visible in help copy without changing scientific workflow behavior.

**Tech Stack:** Swift 6.2, AppKit, SwiftUI, XCTest, Swift Package Manager.

---

## File Structure

- Create `Sources/LungfishKit/LungfishHelpContent.swift`
  Shared help item model, catalog IDs, style lint helpers, SwiftUI modifiers, and AppKit control helpers.
- Create `Tests/LungfishKitTests/LungfishHelpContentTests.swift`
  Catalog uniqueness, non-empty copy, banned-language, sentence-length, and provenance-copy tests.
- Modify `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`
  Attach catalog help to tool sidebar rows, status text, and Run.
- Modify `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
  Attach catalog help to overview, inputs, output strategy, readiness, auxiliary-input controls, and advanced scientific settings.
- Modify `Sources/LungfishApp/Views/BAM/BAMPrimerTrimToolPanes.swift`
  Attach catalog help to primer scheme, thresholds, primer offset, and readiness.
- Modify `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift`
  Attach catalog help to alignment track, output track, caller thresholds, iVar confirmation, model fields, extra arguments, and readiness.
- Modify `Sources/LungfishKit/ClassifierActionBar.swift`
  Attach AppKit tooltips and accessibility help to BLAST, Export, Extract FASTQ, and Provenance controls.
- Modify `Sources/LungfishApp/Views/Help/HelpWindowController.swift`
  Register new help topics for reads/workflows, classification review, alignments/variants, and provenance.
- Add `Sources/LungfishApp/Resources/Help/reads-and-workflows.md`
- Add `Sources/LungfishApp/Resources/Help/classification-review.md`
- Add `Sources/LungfishApp/Resources/Help/alignments-and-variants.md`
- Add `Sources/LungfishApp/Resources/Help/provenance.md`
- Modify existing bundled help files to remove style conflicts and add provenance notes where data is created or imported.
- Modify `Tests/LungfishAppTests/HelpSystemTests.swift`
  Expect the expanded topic list and style-clean bundled help.
- Create `docs/superpowers/reviews/2026-06-13-in-app-help-surface-map.md`
  Document the first-pass surface map and follow-up gaps from expert review.

### Task 1: Shared Help Catalog

**Files:**
- Create: `Tests/LungfishKitTests/LungfishHelpContentTests.swift`
- Create: `Sources/LungfishKit/LungfishHelpContent.swift`

- [ ] **Step 1: Write the failing catalog tests**

```swift
import XCTest
@testable import LungfishKit

final class LungfishHelpContentTests: XCTestCase {
    func testCatalogIDsAreUniqueAndNonEmpty() {
        let items = LungfishHelpContent.allItems
        XCTAssertFalse(items.isEmpty)
        XCTAssertEqual(items.map(\.id).count, Set(items.map(\.id)).count)
        for item in items {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.summary.isEmpty)
        }
    }

    func testCatalogAvoidsBannedDocumentationLanguage() {
        let banned = ["revolutionary", "breakthrough", "powerful", "cutting-edge", "AI-powered", "game-changing", "unleash", "leverages", "!"]
        for item in LungfishHelpContent.allItems {
            let copy = "\(item.summary) \(item.detail ?? "")"
            for word in banned {
                XCTAssertFalse(copy.localizedCaseInsensitiveContains(word), "\(item.id) contains \(word)")
            }
            XCTAssertFalse(copy.contains("—"), "\(item.id) contains an em dash")
        }
    }

    func testProvenanceRelevantItemsSayWhatProvenanceHelpsVerify() {
        for item in LungfishHelpContent.allItems where item.provenanceRelevant {
            let copy = "\(item.summary) \(item.detail ?? "")".lowercased()
            XCTAssertTrue(copy.contains("provenance"), "\(item.id) should mention provenance")
            XCTAssertTrue(copy.contains("command") || copy.contains("inputs") || copy.contains("checksums") || copy.contains("runtime"), "\(item.id) should mention reproducibility evidence")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LungfishHelpContentTests`

Expected: FAIL because `LungfishHelpContent` is not defined.

- [ ] **Step 3: Implement the catalog**

Create `LungfishHelpContent` with `HelpItem`, `Audience`, static item definitions for shared operation, FASTQ, BAM primer-trim, BAM variant-calling, classifier result, export, and provenance copy. Add `public extension View` with `lungfishHelp(_:)` and `lungfishHelpSummary(_:)`. Add `public extension NSControl` with `applyLungfishHelp(_:)`.

- [ ] **Step 4: Run the catalog tests**

Run: `swift test --filter LungfishHelpContentTests`

Expected: PASS.

### Task 2: Scientific Dialog Help Wiring

**Files:**
- Modify: `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
- Modify: `Sources/LungfishApp/Views/BAM/BAMPrimerTrimToolPanes.swift`
- Modify: `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationToolPanesSourceTests.swift`
- Test: `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift`

- [ ] **Step 1: Write failing source coverage tests**

Add tests that read each changed SwiftUI source file and assert it imports `LungfishKit` where needed and contains `lungfishHelp(` calls for core controls.

- [ ] **Step 2: Run the source tests to verify they fail**

Run:

```bash
swift test --filter FASTQOperationToolPanesSourceTests
swift test --filter BAMVariantCallingDialogRoutingTests
```

Expected: FAIL because the target sources do not contain the new help calls.

- [ ] **Step 3: Wire help into shared operation dialog and scientific panes**

Attach catalog IDs to sidebar tool rows, status text, Run, FASTQ sections, auxiliary input buttons, output strategy, readiness, primer-trim fields, variant-calling fields, iVar confirmation, model fields, and extra arguments.

- [ ] **Step 4: Run source tests**

Run:

```bash
swift test --filter FASTQOperationToolPanesSourceTests
swift test --filter BAMVariantCallingDialogRoutingTests
```

Expected: PASS.

### Task 3: Classifier Action Bar Help

**Files:**
- Modify: `Sources/LungfishKit/ClassifierActionBar.swift`
- Test: `Tests/LungfishKitTests/LungfishHelpContentTests.swift`

- [ ] **Step 1: Add failing AppKit helper test**

Extend `LungfishHelpContentTests` to instantiate `ClassifierActionBar` and assert BLAST, Export, Extract FASTQ, and Provenance buttons have tooltips and accessibility help.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LungfishHelpContentTests/testClassifierActionBarAppliesScientificHelp`

Expected: FAIL because the buttons lack catalog-backed help.

- [ ] **Step 3: Apply AppKit help**

Use `applyLungfishHelp(_:)` inside `ClassifierActionBar.setupUI()`.

- [ ] **Step 4: Run the test**

Run: `swift test --filter LungfishHelpContentTests`

Expected: PASS.

### Task 4: Bundled Help Topics And Style Cleanup

**Files:**
- Modify: `Sources/LungfishApp/Views/Help/HelpWindowController.swift`
- Modify: `Tests/LungfishAppTests/HelpSystemTests.swift`
- Add: `Sources/LungfishApp/Resources/Help/reads-and-workflows.md`
- Add: `Sources/LungfishApp/Resources/Help/classification-review.md`
- Add: `Sources/LungfishApp/Resources/Help/alignments-and-variants.md`
- Add: `Sources/LungfishApp/Resources/Help/provenance.md`
- Modify: existing files in `Sources/LungfishApp/Resources/Help`

- [ ] **Step 1: Write failing topic/style tests**

Update `HelpSystemTests` to expect nine topics, require the new topic IDs, and scan bundled Markdown for banned hype words, em dashes, and exclamation marks.

- [ ] **Step 2: Run help tests to verify they fail**

Run:

```bash
swift test --filter HelpTopicTests
swift test --filter HelpResourceTests
```

Expected: FAIL because topics and style cleanup are not complete.

- [ ] **Step 3: Add topics and clean existing help**

Register the four new topics. Add concise Markdown files with primers, procedures, interpretation, and provenance notes. Remove conflicting phrases from existing topics.

- [ ] **Step 4: Run help tests**

Run: `swift test --filter HelpSystemTests`

Expected: PASS.

### Task 5: Surface Map And Final Verification

**Files:**
- Create: `docs/superpowers/reviews/2026-06-13-in-app-help-surface-map.md`

- [ ] **Step 1: Combine expert review output**

Write the surface map with columns for persona, file, surface, first-pass action, suggested copy, and follow-up.

- [ ] **Step 2: Run targeted verification**

Run:

```bash
swift test --filter LungfishHelpContentTests
swift test --filter FASTQOperationToolPanesSourceTests
swift test --filter BAMVariantCallingDialogRoutingTests
swift test --filter HelpTopicTests
swift test --filter HelpResourceTests
```

Expected: all targeted tests pass.

- [ ] **Step 3: Run build verification**

Run: `swift build`

Expected: build succeeds.

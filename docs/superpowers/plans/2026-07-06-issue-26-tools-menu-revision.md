# Issue #26 — Revise Tools Menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first**, especially §2.4 (do #26 after #21 and #27 so menu wiring is stable).

**Goal:** Restructure the Tools menu so FASTQ/FASTA operation categories sit at the TOP level; enabled workflows appear INSIDE the matching category; installable-but-disabled workflows appear DIMMED and, when clicked, offer to enable them (routing to the workflow chooser); the standalone "Workflow Operations" item is removed; genotyping workflows live under a new "Genotyping" category.

**Architecture:** The main menu is built programmatically in `MainMenu.swift` (`createToolsMenu(...)`), not a XIB. Today the Tools menu nests all operation categories under a single "FASTQ/FASTA Operations" submenu and shows a separate "Workflow Operations…" item. We flatten: promote each category (QC & Reporting, Demultiplexing, Trimming & Filtering, Decontamination, Read Processing, Search & Subsetting, Multiple Sequence Alignment, Mapping, Assembly, Classification, Reverse Complement, Translate) to top-level Tools submenus, add a new "Genotyping" category, and inside each category append the workflows whose `category` matches. Enabled workflows are normal clickable items; disabled-but-installable workflows are `isEnabled = false` (dimmed) with a click path that shows an NSAlert → opens the Workflow Library (chooser). Menu state comes from `WorkflowLibraryCatalog` + `WorkflowLibraryEnablementStore`; validation goes through the existing `NSMenuItemValidation` in `AppDelegate`.

**Tech Stack:** Swift 6.2, AppKit (NSMenu/NSMenuItem, NSMenuItemValidation), XCTest.

## Global Constraints

- Build/test/serialization/green-bar per master spec §1.3–§1.4.
- Menu-item accessibility identifiers must remain stable where UI tests reference them (grep `MainMenuAccessibilityID` and `accessibilityIdentifier` in `Tests/`); update tests that assert the OLD structure.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. Tools menu shows operation categories at the top level (no "FASTQ/FASTA Operations" wrapper submenu).
2. A new "Genotyping" category exists; the three genotyping workflows (`ontGenotyping`, `full-length-ont-mhc-genotyping`, `12s-amplicon-matching`) appear under it.
3. Enabled workflows appear inside their matching category and launch normally.
4. Installable-but-disabled workflows appear dimmed within their category; clicking one shows an alert offering to enable it, and choosing "Enable" opens the Workflow Library window (chooser).
5. The standalone "Workflow Operations…" Tools-menu item is gone.
6. Existing FASTQ/FASTA operation items still launch their dialogs.
7. Suite is GREEN, and updated menu-structure UI tests pass.

## Key files

- `Sources/LungfishApp/App/MainMenu.swift` (`createToolsMenu` ~633–793; FASTQ/FASTA submenu ~643–706; Workflow Operations item ~708–715; disabled-item examples ~319/809/838)
- `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` (category action methods `showFASTQ<Category>Operations(_:)` ~16–62; `showWorkflowOperations(_:)` ~1203–1220)
- `Sources/LungfishApp/App/AppDelegate.swift` (`validateMenuItem(_:)` ~1207–1331)
- `Sources/LungfishApp/Services/WorkflowLibrary.swift` (`WorkflowLibraryCatalog.builtIn` ~137–252; `WorkflowLibraryEnablementStore` ~330–530: `isWorkflowEnabled`, `setWorkflow(_:enabled:)`, `.workflowLibraryEnablementChanged`; `WorkflowFeatureAvailability.current()` ~72–104)
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift` (`FASTQOperationCategoryID` ~4–46)
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` (tool→category mapping, e.g. `.ontGenotyping → .mapping` ~1791–1816)
- `Sources/LungfishApp/Views/WorkflowLibrary/WorkflowLibraryWindowController.swift` (opens the chooser)

---

### Task 1: Introduce a "Genotyping" category and remap genotyping workflows

**Files:**
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift` (`FASTQOperationCategoryID` — add `.genotyping`)
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` (map genotyping tools to `.genotyping`)
- Test: `Tests/LungfishAppTests/ToolsMenuStructureTests.swift` (create)

**Interfaces:**
- Produces: `FASTQOperationCategoryID.genotyping` with a display title "Genotyping"; genotyping tools (`ontGenotyping`, `fullLengthONTMHCGenotyping`, `twelveSAmpliconMatching`) report `.genotyping` as their category.

- [ ] **Step 1: Write the failing test.**

```swift
import XCTest
@testable import LungfishApp

final class ToolsMenuStructureTests: XCTestCase {
    func testGenotypingCategoryExists() {
        XCTAssertTrue(FASTQOperationCategoryID.allCases.contains(.genotyping))
    }
    func testGenotypingWorkflowsMapToGenotypingCategory() {
        XCTAssertEqual(FASTQOperationToolID.ontGenotyping.category, .genotyping)
        XCTAssertEqual(FASTQOperationToolID.fullLengthONTMHCGenotyping.category, .genotyping)
        XCTAssertEqual(FASTQOperationToolID.twelveSAmpliconMatching.category, .genotyping)
    }
}
```
(Confirm the actual accessor for a tool's category — it may be a `category` property or a switch. Match it.)

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement.** Add `case genotyping` to `FASTQOperationCategoryID` with title "Genotyping" (add to the title switch / display-name mapping). Change the three genotyping tools' category from their current values (e.g. `.mapping`, `.classification`) to `.genotyping`. Verify nothing else relied on those tools being in their old category for dialog routing (grep their raw values). If `ontGenotyping` being `.mapping` was load-bearing for a required-plugin check, preserve that plugin requirement independent of category.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `feat(menu): add Genotyping category and remap genotyping workflows`.

---

### Task 2: Pure model of the new Tools-menu tree (testable, AppKit-free)

**Files:**
- Create: `Sources/LungfishApp/App/ToolsMenuModel.swift`
- Test: `Tests/LungfishAppTests/ToolsMenuStructureTests.swift` (extend)

**Interfaces:**
- Produces a pure description of the menu so the tree is unit-testable without building NSMenus:
  ```swift
  struct ToolsMenuModel {
      struct WorkflowEntry { let toolID: FASTQOperationToolID; let title: String; let isEnabled: Bool; let isInstallable: Bool }
      struct Category { let id: FASTQOperationCategoryID; let title: String; let workflows: [WorkflowEntry] }
      let categories: [Category]   // top-level, in display order
      static func build(catalog: [WorkflowLibraryCatalogItem],
                        isEnabled: (WorkflowLibraryCatalogItem) -> Bool) -> ToolsMenuModel
  }
  ```

**Before you start:** Read `WorkflowLibraryCatalog.builtIn` and the catalog item type (name, category, maturity, capabilities). Decide the category display order (mirror today's order, then append "Genotyping"). "Installable" = the workflow exists in the catalog but is not enabled (maturity `.specialized`/`.experimental` and `isEnabled == false`); "enabled" = `isEnabled == true` (core is always enabled).

- [ ] **Step 1: Write the failing test.**

```swift
    func testBuildGroupsWorkflowsUnderCategoriesWithEnabledFlag() {
        // Construct a fake catalog: one enabled classification workflow,
        // one disabled genotyping workflow.
        let model = ToolsMenuModel.build(
            catalog: fakeCatalog(),
            isEnabled: { $0.id == "enabled.one" }
        )
        let genotyping = model.categories.first { $0.id == .genotyping }
        XCTAssertNotNil(genotyping)
        let disabled = genotyping?.workflows.first { !$0.isEnabled }
        XCTAssertNotNil(disabled)
        XCTAssertTrue(disabled?.isInstallable ?? false)
        // Categories appear in stable order with Genotyping present:
        XCTAssertTrue(model.categories.map(\.id).contains(.genotyping))
    }
```
Provide `fakeCatalog()` returning catalog items (use the real catalog-item type; if hard to construct, add an internal initializer for tests).

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `ToolsMenuModel.build`.** Enumerate all categories in display order; for each, collect catalog workflows whose category matches, mapping each to a `WorkflowEntry` with `isEnabled` from the closure and `isInstallable = !isEnabled`. Keep FASTQ/FASTA operation categories present even when they have zero workflows (they still hold the built-in operation items, added at the AppKit layer in Task 3).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `feat(menu): add pure ToolsMenuModel for the flattened tree`.

---

### Task 3: Rebuild `createToolsMenu` from the model (flatten + workflows + dimming)

**Files:**
- Modify: `Sources/LungfishApp/App/MainMenu.swift` (`createToolsMenu`)
- Modify: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` (add a handler for clicking a dimmed workflow)

**Interfaces:**
- Consumes: `ToolsMenuModel` (Task 2); existing category action selectors (`showFASTQClassificationOperations(_:)` etc.).
- Produces: a flattened Tools menu; each category is a top-level submenu containing (a) the built-in operation item(s) that open the operations dialog for that category, then (b) a separator, then (c) that category's workflow items (enabled = clickable launching the workflow; disabled = dimmed).

**Before you start:** List every current category action selector in `AppDelegate+ToolsMenu.swift`. Each becomes the "open this category's operations" item. Decide how an enabled workflow launches — reuse the workflow-operations launch path (`showWorkflowOperations`-style) but pre-targeted to that workflow (pass the workflow tool id). Confirm whether launching a specific workflow needs a dedicated selector or a represented-object carrying the tool id.

- [ ] **Step 1: Rewrite `createToolsMenu`.** Replace the single "FASTQ/FASTA Operations" wrapper with top-level submenus, one per `FASTQOperationCategoryID` (including `.genotyping`). For each category submenu:
  - Add the category's built-in "open operations dialog" item (existing selector, e.g. `showFASTQClassificationOperations(_:)`).
  - If the category has workflows (from `ToolsMenuModel`), add a separator then one item per workflow:
    - Enabled: `action` launches that workflow (set `representedObject` = the workflow tool id; target = AppDelegate; selector = a new `launchWorkflowFromMenu(_:)`).
    - Disabled/installable: create the item with the same title but set `isEnabled = false` to dim it, AND still assign an action/target so a click can be intercepted. NOTE: a truly `isEnabled = false` NSMenuItem does not fire its action. To get a "dimmed but clickable → show enable prompt" behavior, either (a) keep `isEnabled = true` but render it visually de-emphasized (attributed gray title) with the action showing the enable prompt, or (b) intercept via the menu delegate. **Recommended:** keep the item enabled (so the click fires), give it a grayed attributed title to read as "dimmed," append a " (not enabled)" hint, and route its action to `promptEnableWorkflowFromMenu(_:)`. Document this choice in a code comment.
  - Remove the standalone "Workflow Operations…" item entirely.

- [ ] **Step 2: Add the two menu handlers** in `AppDelegate+ToolsMenu.swift`:
  ```swift
  @objc func launchWorkflowFromMenu(_ sender: NSMenuItem) {
      guard let toolID = sender.representedObject as? FASTQOperationToolID else { return }
      // Launch that workflow via the existing workflow-operations path, pre-selected.
      showWorkflowOperations(preselectedToolID: toolID)   // add/extend this entry
  }

  @objc func promptEnableWorkflowFromMenu(_ sender: NSMenuItem) {
      guard let toolID = sender.representedObject as? FASTQOperationToolID,
            let window = activeMainWindowController()?.window else { return }
      let alert = NSAlert()
      alert.messageText = "Enable “\(sender.title)”?"
      alert.informativeText = "This workflow is available but not yet enabled. Enable it in the Workflow Library?"
      alert.addButton(withTitle: "Open Workflow Library")   // .alertFirstButtonReturn
      alert.addButton(withTitle: "Cancel")
      alert.beginSheetModal(for: window) { response in
          guard response == .alertFirstButtonReturn else { return }
          WorkflowLibraryWindowController.show()   // opens the chooser (match real API)
      }
  }
  ```
  (Match the real `WorkflowLibraryWindowController` presentation API and the `showWorkflowOperations` signature; extend it to accept a preselected tool id, or add a thin variant.)

- [ ] **Step 3: Build.** `swift build --package-path <worktree> --skip-update` → succeeds.

- [ ] **Step 4: Rebuild menu on enablement change.** The menu is built once; when a workflow is enabled/disabled it must refresh. Observe `.workflowLibraryEnablementChanged` (already posted by `WorkflowLibraryEnablementStore`) and rebuild the Tools menu (or the affected submenus) when it fires. Confirm there is a single owner of the main menu to rebuild.

- [ ] **Step 5: Commit** `feat(menu): flatten Tools menu, inline workflows, dim installable ones`.

---

### Task 4: Update validation and remove dead wiring

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift` (`validateMenuItem` ~1207–1331 — remove the `showWorkflowOperations` visibility rule that hid the now-removed item; add validation for the new workflow items if needed)

- [ ] **Step 1:** Remove the `validateMenuItem` branch that toggled `isHidden` for the removed "Workflow Operations…" item. Ensure `launchWorkflowFromMenu` / `promptEnableWorkflowFromMenu` items validate as enabled. Confirm no other code references the removed `MainMenuAccessibilityID.workflowOperations` (grep; if a UI test asserts it, that test moves to Task 5).
- [ ] **Step 2: Build** → succeeds.
- [ ] **Step 3: Commit** `refactor(menu): drop validation for removed Workflow Operations item`.

---

### Task 5: Update menu-structure UI tests

**Files:** `Tests/` — search for tests asserting the OLD Tools menu shape (`grep -rn "FASTQ/FASTA Operations\|Workflow Operations\|toolsMenu\|MainMenuAccessibilityID" Tests`).

- [ ] **Step 1:** Update/replace assertions to expect the NEW structure: top-level category submenus, a "Genotyping" submenu, no "FASTQ/FASTA Operations" wrapper, no "Workflow Operations…" item, workflows nested under categories. Add assertions that a disabled workflow item exists and is dimmed (attributed/grayed) and that clicking it targets `promptEnableWorkflowFromMenu`.
- [ ] **Step 2:** Run the menu tests: `swift test --package-path <worktree> --skip-update --filter ToolsMenu` (and any renamed suites). Expect PASS.
- [ ] **Step 3: Commit** `test(menu): assert flattened Tools menu structure`.

---

### Task 6: GUI verification (required)

- [ ] Build `.build/debug/Lungfish`, launch via computer-use. Open Tools menu. Verify:
  - Categories are top-level (Classification, Assembly, Mapping, …, Genotyping).
  - No "FASTQ/FASTA Operations" wrapper; no "Workflow Operations…" item.
  - An enabled workflow appears under its category and launches.
  - A disabled workflow appears dimmed under its category; clicking it shows the enable prompt; "Open Workflow Library" opens the chooser.
  - After enabling a workflow in the chooser, the Tools menu reflects it as enabled (menu rebuild on `.workflowLibraryEnablementChanged`).
  Screenshot the open Tools menu and the enable prompt.

---

### Final verification

- [ ] `swift build/test --package-path <worktree> --skip-update` → clean + GREEN, menu tests pass.
- [ ] Screenshots attached to issue #26.
- [ ] No dead references to the removed items (grep clean).

## Self-review checklist

- Spec coverage: Genotyping category (T1), pure tree model (T2), flatten+inline+dim (T3), validation cleanup (T4), tests (T5), GUI (T6) → all criteria mapped.
- No placeholders: model, menu build strategy, both handlers, and the enable-prompt are concrete; the one AppKit subtlety (disabled items do not fire actions) is called out with a chosen resolution.
- Type consistency: `ToolsMenuModel`, `WorkflowEntry`, `launchWorkflowFromMenu`, `promptEnableWorkflowFromMenu` named identically across tasks.
- Ordering: this plan assumes #21 and #27 already landed (master spec §2.4).

# Kernel/Module Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the LungfishAppKit kernel + leaf-module architecture across the whole app — promote all shared UI/infrastructure into the kernel and extract every clean feature surface (plus OperationCenter and Phylogenetics) into standalone leaf modules, so a module edit recompiles/tests only that module.

**Architecture:** `LungfishAppKit` is a shared kernel below `LungfishApp` and above Core/IO/Workflow. Leaf modules (`LungfishTwelveSUI` and the new ones) own one feature surface each, import only the kernel + lower layers, and expose callbacks. `LungfishApp` keeps the composition hubs (Viewer/MainSplit/Inspector/Sidebar) and imports the leaves. A module below `LungfishApp` may never reference a type defined in `LungfishApp`.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 26 (arm64), AppKit + SwiftUI, XCTest + swift-testing.

---

## Critical execution rules (read before any task)

1. **Serialize all `swift` invocations.** A single `.build/.lock` exists per checkout. NEVER
   run a second `swift build`/`swift test` while one is in flight (it blocks or gets killed
   with exit 144). Dispatch implementer subagents ONE AT A TIME.
2. **Always offline:** every `swift` command uses `--skip-update` (avoids the `testSRASearch`
   NCBI flake).
3. **Standalone-build proof:** after moving a type into the kernel or a leaf, the module MUST
   build alone (`swift build --package-path . --target <Module> --skip-update`). If it builds
   alone, it has no back-dependency on `LungfishApp`. This is the core correctness check for
   every move task.
4. **Full suite is the behavior-preservation gate.** Pure module-moves change no behavior;
   the proof is that the full suite stays green (current bar: 8,841 XCTest + 475
   swift-testing, 0 failures). Run it at the end of each phase, not each task (it is slow,
   ~10-12 min).
5. **`open` vs `public`:** a type subclassed across modules must be `open` (e.g.
   `BatchTableView` already is). A type only *used* across modules is `public`. `@testable
   import` does NOT re-export dependency modules — leaf test files need explicit `import
   LungfishAppKit` etc.
6. **`Package.swift` registration:** new leaf targets need a `.target`, a `.library` product,
   a `.testTarget`, and an addition to `LungfishApp`'s `dependencies:`. Mirror the existing
   `LungfishTwelveSUI` + `LungfishTwelveSUITests` stanzas exactly.
7. **`.gitignore` is deny-by-default** (line 3 is `*`). `Sources/**` and `Tests/**` are
   already allow-listed, so new files under them are tracked automatically. No new top-level
   files are introduced by this plan.
8. **Commit cadence:** one commit per task (or per tightly-coupled type-move group). Linear
   history on `main`, no merge commits. Co-author line:
   `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.

## Reference: the proven leaf pattern (LungfishTwelveSUI)

- Leaf dir: `Sources/LungfishTwelveSUI/` — holds VC + display-state + export-service.
- Leaf imports: `Foundation`/`AppKit`/`LungfishCore`/`LungfishIO`/`LungfishWorkflow`/`LungfishAppKit`.
- Glue stays in App: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift`
  imports the leaf and wires app services to the VC's callbacks.
- Test target: `Tests/LungfishTwelveSUITests/` (mirror its structure for each new leaf).
- `Package.swift` stanzas for `LungfishTwelveSUI` (target/product/testTarget) are the template.

---

## Phase 1 — Clean kernel cluster

Promote the mechanically-clean shared UI/util types into the kernel. Each is a file MOVE
(`git mv` the source file from `Sources/LungfishApp/...` to `Sources/LungfishAppKit/`,
change nothing but access modifiers as needed, fix the now-redundant imports). After each
group, build the kernel standalone + build LungfishApp.

### Task 1.1: Promote pure AppKit/SwiftUI shared views

**Files:**
- Move: `Sources/LungfishApp/Views/Shared/LungfishAppKitControlStyle.swift` → `Sources/LungfishAppKit/LungfishAppKitControlStyle.swift`
- Move: `Sources/LungfishApp/Views/Shared/GenomicSummaryCardBar.swift` → `Sources/LungfishAppKit/GenomicSummaryCardBar.swift`
- Move: `Sources/LungfishApp/Views/Layout/ScrollViewSplitPaneContainerView.swift` (contains `ScrollViewSplitPaneContainerView` + `SplitPaneFillContainerView`) → `Sources/LungfishAppKit/ScrollViewSplitPaneContainerView.swift`
- Move: `Sources/LungfishApp/Views/Shared/FASTASequenceActionMenuBuilder.swift` (contains `FASTASequenceActionMenuBuilder` + `FASTASequenceActionHandlers`) → `Sources/LungfishAppKit/FASTASequenceActionMenuBuilder.swift`
- Move: `Sources/LungfishApp/Views/Shared/ZoomShortcutHandler.swift` → `Sources/LungfishAppKit/ZoomShortcutHandler.swift`

(If any listed path differs slightly, `rg -l 'class LungfishAppKitControlStyle|struct GenomicSummaryCardBar|class ScrollViewSplitPaneContainerView|enum FASTASequenceActionMenuBuilder|class ZoomShortcutHandler|class FASTASequenceActionHandlers' Sources/LungfishApp` to locate the true file before moving.)

- [ ] **Step 1: Locate exact definition files**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'class LungfishAppKitControlStyle|struct GenomicSummaryCardBar|class ScrollViewSplitPaneContainerView|struct ScrollViewSplitPaneContainerView|class SplitPaneFillContainerView|enum FASTASequenceActionMenuBuilder|struct FASTASequenceActionMenuBuilder|class ZoomShortcutHandler|enum FASTASequenceActionHandlers' Sources/LungfishApp --type swift`
Expected: one definition site per type; note the actual file paths.

- [ ] **Step 2: Move each file into the kernel with git mv**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git mv Sources/LungfishApp/Views/Shared/LungfishAppKitControlStyle.swift Sources/LungfishAppKit/LungfishAppKitControlStyle.swift
git mv Sources/LungfishApp/Views/Shared/GenomicSummaryCardBar.swift Sources/LungfishAppKit/GenomicSummaryCardBar.swift
git mv Sources/LungfishApp/Views/Layout/ScrollViewSplitPaneContainerView.swift Sources/LungfishAppKit/ScrollViewSplitPaneContainerView.swift
git mv Sources/LungfishApp/Views/Shared/FASTASequenceActionMenuBuilder.swift Sources/LungfishAppKit/FASTASequenceActionMenuBuilder.swift
git mv Sources/LungfishApp/Views/Shared/ZoomShortcutHandler.swift Sources/LungfishAppKit/ZoomShortcutHandler.swift
```
(Adjust source paths to the ones found in Step 1.)

- [ ] **Step 3: Widen access modifiers to `public`**

In each moved file, the top-level type and any members referenced from `LungfishApp` must be
`public` (the type was likely `internal`/no-modifier when it lived in the app). For
`open`-needed cases (subclassed elsewhere), use `open`. Concretely: change `class X` →
`public class X` (or `open` if subclassed), `struct X` → `public struct X`, and every
property/method/init that `LungfishApp` code touches → `public`. Find what App touches:

Run: `rg -n 'LungfishAppKitControlStyle|GenomicSummaryCardBar|ScrollViewSplitPaneContainerView|SplitPaneFillContainerView|FASTASequenceActionMenuBuilder|FASTASequenceActionHandlers|ZoomShortcutHandler' Sources/LungfishApp --type swift`
Then make exactly those referenced members `public`. Add `import AppKit`/`import SwiftUI` at the top of each moved file if it relied on an app-wide umbrella import.

- [ ] **Step 4: Build the kernel standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishAppKit --skip-update 2>&1 | tail -20`
Expected: `Build complete!` (proves no back-dependency on LungfishApp). If it fails with "cannot find type X in scope", that type is another app-internal dependency — STOP and report it; do not force-add it.

- [ ] **Step 5: Build LungfishApp**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tail -20`
Expected: `Build complete!` (App now imports these from the kernel; `import LungfishAppKit` is already present in the consuming files — if not, add it where the compiler reports "cannot find X in scope").

- [ ] **Step 6: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(kernel): promote pure AppKit/SwiftUI shared views to LungfishAppKit

Move LungfishAppKitControlStyle, GenomicSummaryCardBar, the split-pane
containers, FASTASequenceActionMenuBuilder/Handlers, and ZoomShortcutHandler
into the kernel. Pure relocation; kernel builds standalone.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 1.2: Promote clean metagenomics/util types

**Files:**
- Move: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift` → kernel
- Move: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsLayoutPreference.swift` (contains `MetagenomicsPanelLayout`) → kernel
- Move: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift` (contains `MetagenomicsDrawerView` + `MetagenomicsDrawerDelegate`) → kernel
- Move: `Sources/LungfishApp/Views/Metagenomics/ClassifierUniqueReads.swift` → kernel
- Move: `Sources/LungfishApp/Views/Metagenomics/BlastConfigPopoverView.swift` → kernel
- Move: `Sources/LungfishApp/Services/FASTQDisplayNameResolver.swift` → kernel
- Move: `Sources/LungfishApp/App/AppUITestConfiguration.swift` → kernel

- [ ] **Step 1: Locate exact definition files**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'struct MetagenomicsPaneSizing|enum MetagenomicsPaneSizing|enum MetagenomicsPanelLayout|class MetagenomicsDrawerView|protocol MetagenomicsDrawerDelegate|struct ClassifierUniqueReads|struct BlastConfigPopoverView|enum FASTQDisplayNameResolver|struct FASTQDisplayNameResolver|enum AppUITestConfiguration|struct AppUITestConfiguration' Sources/LungfishApp --type swift`
Expected: one definition site per type.

- [ ] **Step 2: git mv each into the kernel**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git mv Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift Sources/LungfishAppKit/MetagenomicsPaneSizing.swift
git mv Sources/LungfishApp/Views/Metagenomics/MetagenomicsLayoutPreference.swift Sources/LungfishAppKit/MetagenomicsLayoutPreference.swift
git mv Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift Sources/LungfishAppKit/MetagenomicsDrawerView.swift
git mv Sources/LungfishApp/Views/Metagenomics/ClassifierUniqueReads.swift Sources/LungfishAppKit/ClassifierUniqueReads.swift
git mv Sources/LungfishApp/Views/Metagenomics/BlastConfigPopoverView.swift Sources/LungfishAppKit/BlastConfigPopoverView.swift
git mv Sources/LungfishApp/Services/FASTQDisplayNameResolver.swift Sources/LungfishAppKit/FASTQDisplayNameResolver.swift
git mv Sources/LungfishApp/App/AppUITestConfiguration.swift Sources/LungfishAppKit/AppUITestConfiguration.swift
```
(Adjust to Step 1 paths.)

- [ ] **Step 3: Widen access modifiers**

Same procedure as Task 1.1 Step 3: make each type and its App-referenced members `public`; add `import` lines the file relied on via umbrella imports. `MetagenomicsPaneSizing` imports `CoreGraphics` + `LungfishAppKit`-internal — since it now IS in the kernel, drop any `import LungfishAppKit`. `FASTQDisplayNameResolver` needs `import LungfishIO`.

- [ ] **Step 4: Build kernel standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishAppKit --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Build LungfishApp**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(kernel): promote clean metagenomics/util types to LungfishAppKit

Move MetagenomicsPaneSizing/PanelLayout/DrawerView, ClassifierUniqueReads,
BlastConfigPopoverView, FASTQDisplayNameResolver, AppUITestConfiguration into
the kernel. Pure relocation; kernel builds standalone.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 1.3: Split SavePanelPresenting/Pasteboard protocols out of TaxonomyReadExtractionAction

The protocols `SavePanelPresenting`, `DefaultSavePanelPresenter`, `DefaultPasteboard` are
reusable, but they live in `Views/Metagenomics/TaxonomyReadExtractionAction.swift` whose
ACTION type depends on `OperationCenter` (stays in App until Phase 5). Split the protocols
into a new kernel file; leave the action in App.

**Files:**
- Create: `Sources/LungfishAppKit/SavePanelPresenting.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift`

- [ ] **Step 1: Read the current definitions**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'protocol SavePanelPresenting|class DefaultSavePanelPresenter|struct DefaultSavePanelPresenter|protocol .*Pasteboard|class DefaultPasteboard|struct DefaultPasteboard' Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift`
Then read the file to capture the exact protocol/struct bodies.

- [ ] **Step 2: Create the kernel file with the moved protocols**

Create `Sources/LungfishAppKit/SavePanelPresenting.swift` containing the `SavePanelPresenting` protocol, `DefaultSavePanelPresenter`, the pasteboard-writing protocol, and `DefaultPasteboard` — each marked `public`, with `public` initializers and members. Add `import AppKit`. (Copy the exact bodies read in Step 1; do not paraphrase.)

- [ ] **Step 3: Remove the moved definitions from the App file**

Delete the protocol/struct definitions from `TaxonomyReadExtractionAction.swift` (keep the action type). Add `import LungfishAppKit` at the top if not present.

- [ ] **Step 4: Build kernel standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishAppKit --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Build LungfishApp**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 6: Run the full suite (end of Phase 1)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift test --skip-update 2>&1 | tail -40`
Expected: 0 failures (8,841 XCTest + 475 swift-testing). This is the Phase 1 behavior-preservation gate.

- [ ] **Step 7: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(kernel): extract SavePanelPresenting/Pasteboard protocols to kernel

Split the reusable save-panel/pasteboard protocols out of
TaxonomyReadExtractionAction (whose action stays in App, OperationCenter-bound)
into LungfishAppKit. Full suite green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — First leaf: Alignment

Extract `AlignmentResultViewController` into a new `LungfishAlignmentUI` leaf. The audit
confirmed zero non-kernel blockers; it already conforms to the kernel `ResultViewportController`.

**Files:**
- Create dir: `Sources/LungfishAlignmentUI/`
- Move: `Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift` → `Sources/LungfishAlignmentUI/AlignmentResultViewController.swift`
- Create: `Tests/LungfishAlignmentUITests/AlignmentResultViewControllerTests.swift`
- Modify: `Package.swift` (add target + product + testTarget; add to LungfishApp deps)
- Possibly create: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Alignment.swift` (only if glue currently lives inline in the VC file and references App types)

- [ ] **Step 1: Confirm the leaf has no App-internal blockers**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'ViewerFilePanelFactory|OperationCenter|AppDelegate|MainSplitViewController|InspectorViewController|FASTQOperationDialogState' Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift`
Expected: NO matches in code (doc-comment matches are fine). If a real reference appears, STOP and report — the audit said zero; a surprise means re-survey.

- [ ] **Step 2: Add the leaf target to Package.swift**

In `Package.swift`, copy the `LungfishTwelveSUI` target/product/testTarget stanzas and adapt to `LungfishAlignmentUI`:
- a `.target(name: "LungfishAlignmentUI", dependencies: ["LungfishCore", "LungfishIO", "LungfishWorkflow", "LungfishAppKit"])`
- a `.library(name: "LungfishAlignmentUI", targets: ["LungfishAlignmentUI"])`
- a `.testTarget(name: "LungfishAlignmentUITests", dependencies: ["LungfishAlignmentUI", "LungfishCore", "LungfishIO", "LungfishWorkflow", "LungfishAppKit"])`
- add `"LungfishAlignmentUI"` to the `LungfishApp` target's `dependencies:` array.

- [ ] **Step 3: Move the VC into the leaf**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
mkdir -p Sources/LungfishAlignmentUI
git mv Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift Sources/LungfishAlignmentUI/AlignmentResultViewController.swift
```
Then in the moved file: change the VC class to `public` (and `open` if subclassed — check `rg -n 'AlignmentResultViewController' Sources/LungfishApp`), make every member App touches `public`, and ensure imports are `Foundation`/`AppKit`/`LungfishWorkflow`/`LungfishAppKit` (the audit said it imports AppKit + Workflow + AppKit-kernel types). Add an `import LungfishAlignmentUI` to whichever App file constructs the VC.

- [ ] **Step 4: Build leaf standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishAlignmentUI --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Write a smoke test for the leaf**

Create `Tests/LungfishAlignmentUITests/AlignmentResultViewControllerTests.swift`:

```swift
import XCTest
import AppKit
@testable import LungfishAlignmentUI
import LungfishWorkflow
import LungfishAppKit

final class AlignmentResultViewControllerTests: XCTestCase {
    @MainActor
    func testViewControllerInstantiates() {
        let vc = AlignmentResultViewController()
        XCTAssertNotNil(vc.view)  // forces viewDidLoad; proves the leaf links + lays out
    }
}
```
(If `AlignmentResultViewController()` requires init args, read the VC's designated initializer and pass minimal valid values; do not invent a parameterless init that doesn't exist.)

- [ ] **Step 6: Run the leaf test target**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift test --filter LungfishAlignmentUITests --skip-update 2>&1 | tail -20`
Expected: test passes. This demonstrates the per-module test isolation payoff (only the leaf compiles/tests).

- [ ] **Step 7: Build LungfishApp + run full suite**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tail -10 && swift test --skip-update 2>&1 | tail -40`
Expected: App builds; full suite 0 failures.

- [ ] **Step 8: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(modules): extract Alignment result viewport into LungfishAlignmentUI leaf

First post-12S leaf. Zero non-kernel blockers; builds standalone with its own
test target. Full suite green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Mid leaves: Mapping, Assembly

### Task 3.1: Promote ReferenceBundleViewportController, then extract Mapping leaf

**Files:**
- Move (promote): `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift` → `Sources/LungfishAppKit/ReferenceBundleViewportController.swift` (it is the only blocker for Mapping; if it has its own App-internal deps, STOP and report)
- Create dir: `Sources/LungfishMappingUI/`
- Move: `Sources/LungfishApp/Views/Results/Mapping/*` → `Sources/LungfishMappingUI/`
- Create: `Tests/LungfishMappingUITests/MappingResultViewControllerTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Verify ReferenceBundleViewportController is kernel-safe**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'OperationCenter|AppDelegate|ViewerViewController|InspectorViewController|MainSplitViewController|FASTQOperationDialogState' Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
Expected: no real code references. If clean, promote it (git mv into kernel, make `public`/`open`, build kernel standalone). If not, report and stop.

- [ ] **Step 2: Promote it + build kernel**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git mv Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Sources/LungfishAppKit/ReferenceBundleViewportController.swift
```
Make the type + App-referenced members `public`/`open`. Then:
Run: `swift build --target LungfishAppKit --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 3: Enumerate the Mapping directory**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && ls Sources/LungfishApp/Views/Results/Mapping/ && rg -ln 'OperationCenter|AppDelegate|ViewerViewController|InspectorViewController|MainSplitViewController|FASTQOperationDialogState' Sources/LungfishApp/Views/Results/Mapping/`
Expected: list of files; no real App-internal references after the promotion. Report any surprise blocker.

- [ ] **Step 4: Add the leaf target to Package.swift**

Mirror Phase-2 Step 2 for `LungfishMappingUI` (deps Core/IO/Workflow/AppKit; product; testTarget; add to LungfishApp deps).

- [ ] **Step 5: Move the Mapping files into the leaf**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
mkdir -p Sources/LungfishMappingUI
git mv Sources/LungfishApp/Views/Results/Mapping/*.swift Sources/LungfishMappingUI/
```
Make the result VC + members App touches `public`/`open`; fix imports; add `import LungfishMappingUI` where App constructs the VC.

- [ ] **Step 6: Build leaf standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishMappingUI --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 7: Smoke test the leaf**

Create `Tests/LungfishMappingUITests/MappingResultViewControllerTests.swift` mirroring the Phase-2 smoke test, instantiating the Mapping result VC (read its initializer for required args).

Run: `swift test --filter LungfishMappingUITests --skip-update 2>&1 | tail -20`
Expected: passes.

- [ ] **Step 8: Build LungfishApp (defer full suite to end of phase)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 9: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(modules): extract Mapping result viewport into LungfishMappingUI leaf

Promote ReferenceBundleViewportController to the kernel (its only blocker),
then extract Mapping. Leaf builds standalone with its own test target.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 3.2: Extract Assembly leaf

Prereqs already in kernel after Phase 1: `LungfishAppKitControlStyle`, `MetagenomicsPaneSizing`,
`FASTASequenceActionMenuBuilder`/`Handlers`, `SavePanelPresenting`/`DefaultPasteboard`.

**Files:**
- Create dir: `Sources/LungfishAssemblyUI/`
- Move: `Sources/LungfishApp/Views/Results/Assembly/*` → `Sources/LungfishAssemblyUI/`
- Create: `Tests/LungfishAssemblyUITests/AssemblyResultViewControllerTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Enumerate + verify no remaining App-internal blockers**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && ls Sources/LungfishApp/Views/Results/Assembly/ && rg -ln 'OperationCenter|AppDelegate|ViewerViewController|InspectorViewController|MainSplitViewController|FASTQOperationDialogState' Sources/LungfishApp/Views/Results/Assembly/`
Expected: after Phase 1, no real blockers (audit said Assembly does NOT touch OperationCenter). If a blocker remains, identify which type and whether it was supposed to be promoted in Phase 1; report.

- [ ] **Step 2: Add the leaf target to Package.swift** (mirror, `LungfishAssemblyUI`).

- [ ] **Step 3: Move files into the leaf**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
mkdir -p Sources/LungfishAssemblyUI
git mv Sources/LungfishApp/Views/Results/Assembly/*.swift Sources/LungfishAssemblyUI/
```
Make types/members `public`/`open`; fix imports; add `import LungfishAssemblyUI` where App constructs the VC.

- [ ] **Step 4: Build leaf standalone**

Run: `swift build --target LungfishAssemblyUI --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Smoke test** (mirror Phase-2 smoke test for the Assembly result VC).

Run: `swift test --filter LungfishAssemblyUITests --skip-update 2>&1 | tail -20`
Expected: passes.

- [ ] **Step 6: Build LungfishApp + full suite (end of Phase 3)**

Run: `swift build --target LungfishApp --skip-update 2>&1 | tail -10 && swift test --skip-update 2>&1 | tail -40`
Expected: App builds; full suite 0 failures.

- [ ] **Step 7: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(modules): extract Assembly result viewport into LungfishAssemblyUI leaf

Uses kernel types promoted in Phase 1; no op-pipeline coupling. Builds
standalone with its own test target. Full suite green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Metagenomics infra + leaves

> **Discovered during Phase 1 (Task 1.2):** `MetagenomicsDrawerView` (+ `MetagenomicsDrawerDelegate`,
> `MetagenomicsDrawerTab`, `MetagenomicsDividerView`) is NOT kernel-clean — it holds stored
> properties of two App-internal types `SampleFilterDrawerTab`
> (`Views/Metagenomics/SampleFilterDrawerTab.swift`) and `TaxaCollectionsDrawerView`
> (`Views/Metagenomics/TaxaCollectionsDrawerView.swift`), which are themselves used by the
> Taxonomy hub. It was therefore LEFT in App (the audit's "clean" tag was wrong for it).
> `EsVirituResultViewController` and `TaxTriageResultViewController` reference
> `MetagenomicsDrawerView` directly, so those two leaves cannot be extracted until this is
> resolved. Before extracting EsViritu/TaxTriage, decide at Phase-4 time whether to (a) invert
> the drawer dependency (the result VC exposes a drawer-content callback the App satisfies, like
> the 12S pattern), or (b) promote `SampleFilterDrawerTab` + `TaxaCollectionsDrawerView` if they
> turn out to be kernel-safe on closer inspection. Prefer (a) — inversion — since those two
> types are Taxonomy-hub-coupled. NaoMgs/Nvd reference only the notification (kernel-resident),
> so they may be less blocked — re-verify per leaf.

### Task 4.1: Extract pinchZoomFactor + promote MiniBAMViewController

**Files:**
- Modify: `Sources/LungfishApp/.../SequenceViewerView*.swift` (extract the `pinchZoomFactor` static helper)
- Create: `Sources/LungfishAppKit/PinchZoomFactor.swift`
- Move: `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift` → kernel

- [ ] **Step 1: Locate pinchZoomFactor**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'pinchZoomFactor' Sources/LungfishApp --type swift`
Expected: a definition on `SequenceViewerView` (used at `MiniBAMViewController.swift:439`) plus call sites. Read the definition body.

- [ ] **Step 2: Move the helper into a free kernel function**

Create `Sources/LungfishAppKit/PinchZoomFactor.swift` with the logic as a `public` free function or a `public enum` static (e.g. `public enum PinchZoom { public static func factor(...) -> CGFloat }`). Copy the exact body. Add `import CoreGraphics`/`import AppKit` as needed.

- [ ] **Step 3: Update SequenceViewerView + MiniBAM call sites to use the kernel helper**

Replace the `SequenceViewerView.pinchZoomFactor` definition with a thin call to the kernel function (or delete it and update call sites). Update `MiniBAMViewController.swift:439` to call the kernel helper. Run `rg -n 'pinchZoomFactor' Sources/LungfishApp` to find all call sites and update each.

- [ ] **Step 4: Promote MiniBAMViewController**

Verify its only remaining blockers are now kernel-resident (`ZoomShortcutHandler` from Phase 1, the new pinch helper):
Run: `rg -n 'OperationCenter|AppDelegate|ViewerViewController|SequenceViewerView' Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`
Expected: no real code refs to App-internal types. Then:
```bash
git mv Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift Sources/LungfishAppKit/MiniBAMViewController.swift
```
Make `public`/`open`; fix imports.

- [ ] **Step 5: Build kernel standalone + App**

Run: `swift build --target LungfishAppKit --skip-update 2>&1 | tail -20 && swift build --target LungfishApp --skip-update 2>&1 | tail -10`
Expected: both `Build complete!`

- [ ] **Step 6: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(kernel): promote MiniBAMViewController + pinch-zoom helper to kernel

Extract SequenceViewerView.pinchZoomFactor into a kernel helper so
MiniBAMViewController (its last app-internal blocker, plus ZoomShortcutHandler)
can move into LungfishAppKit. Kernel builds standalone.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 4.2: Extract EsViritu, NAO-MGS, NVD, TaxTriage leaves (one leaf per sub-task)

Each metagenomics result VC becomes its own leaf (`LungfishEsVirituUI`, `LungfishNaoMgsUI`,
`LungfishNvdUI`, `LungfishTaxTriageUI`). They share kernel infra (now promoted) but not each
other's VC classes. Do them **one at a time**, each its own commit + standalone build. Repeat
this template for each:

**Files (per leaf, example EsViritu):**
- Create dir: `Sources/LungfishEsVirituUI/`
- Move: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` (+ any EsViritu-only helper files in that dir) → leaf
- Create: `Tests/LungfishEsVirituUITests/EsVirituResultViewControllerTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Identify the leaf's files + verify blockers are kernel-resident**

Run (example): `cd /Users/dho/Documents/lungfish-genome-explorer && rg -ln 'class EsVirituResultViewController|EsViritu' Sources/LungfishApp/Views/Metagenomics/ && rg -n 'OperationCenter|AppDelegate|ViewerViewController|TaxonomyViewController|MainSplitViewController|FASTQOperationDialogState' Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
Expected: the VC file (+ maybe an EsViritu summary-bar file); no real refs to App-internal hubs. If the VC references `TaxonomyViewController` in code (not comments), that VC stays in App (like CzId) — report and skip that leaf.

- [ ] **Step 2: Add the leaf target to Package.swift** (mirror).

- [ ] **Step 3: Move the leaf's files** (`git mv` VC + leaf-only helpers), make `public`/`open`, fix imports, add `import LungfishEsVirituUI` at the App construction site.

- [ ] **Step 4: Build leaf standalone**

Run: `swift build --target LungfishEsVirituUI --skip-update 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Smoke test** (mirror Phase-2; instantiate the VC).

Run: `swift test --filter LungfishEsVirituUITests --skip-update 2>&1 | tail -20`
Expected: passes.

- [ ] **Step 6: Build LungfishApp**

Run: `swift build --target LungfishApp --skip-update 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 7: Commit** (one per leaf).

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "refactor(modules): extract EsViritu result viewport into LungfishEsVirituUI leaf

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

Repeat Steps 1-7 for **NAO-MGS** (`LungfishNaoMgsUI`, `NaoMgsResultViewController` + `NaoMgsSummaryBar`), **NVD** (`LungfishNvdUI`, `NvdResultViewController`), **TaxTriage** (`LungfishTaxTriageUI`, `TaxTriageResultViewController`). Note: the `Views/Results/Taxonomy/TaxonomyResultViewController.swift` file is a protocol-conformance extension file for the Taxonomy + NaoMgs hubs — the NaoMgs *conformance extension* may need to move into the NaoMgs leaf or stay as App glue; decide based on whether it references `TaxonomyViewController` (if yes, keep as App glue).

- [ ] **Step 8: Full suite (end of Phase 4)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift test --skip-update 2>&1 | tail -40`
Expected: 0 failures.

---

## Phase 5 — OperationCenter promotion (HIGH BLAST RADIUS — reviewed phase)

`OperationCenter` (671 LOC, `Sources/LungfishApp/Services/OperationCenter.swift`) + its
op-model types move into the kernel. The audit confirmed NO `LungfishApp`-internal back-deps
(already decoupled from `AppDelegate` via `onBundleReady` callbacks; needs only
`WindowStateScope`, already in kernel). 45 files reference it, so the move is wide but
mechanical.

**Files:**
- Move: `Sources/LungfishApp/Services/OperationCenter.swift` → `Sources/LungfishAppKit/OperationCenter.swift`
- Modify: up to 45 files that reference `OperationCenter`/op-model types — only to add `import LungfishAppKit` where the compiler reports the types missing (most consuming files already import the kernel).

- [ ] **Step 1: Inventory all referencing files (baseline)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -ln '\bOperationCenter\b|\bOperationType\b|\bOperationLogEntry\b|\bOperationLogLevel\b|\bOperationRouteContext\b|\bOperationRetryMetadata\b' Sources/LungfishApp --type swift | sort > /tmp/opcenter-refs.txt && wc -l /tmp/opcenter-refs.txt && cat /tmp/opcenter-refs.txt`
Expected: ~45 files. Keep this list — it's the set that may need an `import LungfishAppKit` added.

- [ ] **Step 2: Confirm no App-internal back-deps in OperationCenter itself**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'AppDelegate|ViewerViewController|MainSplitViewController|InspectorViewController|SidebarViewController' Sources/LungfishApp/Services/OperationCenter.swift`
Expected: only doc comments (the audit confirmed lines 242, 520 are comments; `onBundleReady` is a closure, not an `AppDelegate` reference). If a real reference exists, STOP — the move is not clean.

- [ ] **Step 3: Move the file into the kernel**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git mv Sources/LungfishApp/Services/OperationCenter.swift Sources/LungfishAppKit/OperationCenter.swift
```
Verify the class + all op-model types + `shared` + every member referenced from App are `public` (it is already `public final class` per the audit; confirm the nested `Item`/`Item.State`, the enums, and the methods used by consumers are `public`). Add `import LungfishCore`/`import LungfishWorkflow`/`import SwiftUI` as needed (drop any `import LungfishAppKit`, since it now IS the kernel).

- [ ] **Step 4: Build kernel standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishAppKit --skip-update 2>&1 | tail -30`
Expected: `Build complete!` If it reports a missing type, that type is an undiscovered App-internal dep — STOP and report (do not pull it down blindly).

- [ ] **Step 5: Build LungfishApp, adding imports where needed**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tee /tmp/opcenter-appbuild.log | tail -40`
For each "cannot find 'OperationCenter' (or op type) in scope" error, add `import LungfishAppKit` to the named file. Re-run until `Build complete!`. (Most files already import the kernel; expect only a handful of additions.)

- [ ] **Step 6: Build the CLI target (it does NOT depend on the kernel)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishCLI --skip-update 2>&1 | tail -20`
Expected: `Build complete!` — confirms no CLI code depended on `OperationCenter` (it shouldn't; CLI doesn't import the kernel). If the CLI references it, that's a real cross-boundary problem to report.

- [ ] **Step 7: Full suite (Phase 5 gate)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift test --skip-update 2>&1 | tail -40`
Expected: 0 failures. Because the import pipeline runs through `OperationCenter`, pay special attention to any OperationCenter / import / pipeline test failures.

- [ ] **Step 8: Commit (this commit will be code-reviewed before proceeding)**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(kernel): promote OperationCenter + op-model types to LungfishAppKit

OperationCenter has no LungfishApp-internal back-dependencies (decoupled from
AppDelegate via onBundleReady callbacks; needs only the kernel's
WindowStateScope). Pure relocation; ~N consuming files gained an explicit
import LungfishAppKit. Kernel + App + CLI build; full suite green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — SelectionSection split + Genotype leaf

### Task 6.1: Split SelectionSection.swift per feature

`Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:18-63` co-defines four
features' selection-state types. Split into per-feature files so Genotype's can move with its
leaf and Phylogenetics' with its leaf later.

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultSelectionState.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/PhylogeneticTreeSelectionState.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/MultipleSequenceAlignmentSelectionState.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/SequenceRegionSelectionState.swift`

- [ ] **Step 1: Read the four selection-state definitions**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && sed -n '1,90p' Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift`
Capture each type's exact body.

- [ ] **Step 2: Move each type into its own file**

Create the four files, each containing one selection-state type (exact body from Step 1, same access level — keep `internal`/whatever they are now; they stay in App for now). Remove the four definitions from `SelectionSection.swift` (keep anything else in that file). This is a pure within-App reorg.

- [ ] **Step 3: Build LungfishApp**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tail -20`
Expected: `Build complete!` (same types, new files).

- [ ] **Step 4: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "refactor: split SelectionSection into per-feature selection-state files

Prerequisite for extracting Genotype and Phylogenetics leaves.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 6.2: Extract Genotype leaf

The Genotype<->Inspector knot: the Genotype VC uses 9 `Inspector/Sections/Genotype*Section.swift`
files (Genotype-specific), and `InspectorViewController` uses `GenotypeResultDisplayState`/
`GenotypeAnnotationStore`/`GenotypeResultSelectionState`. Resolution: move all Genotype-specific
types (VC, display-state, annotation-store, export-service, the 9 Genotype inspector sections,
`GenotypeResultSelectionState`) into the leaf; `InspectorViewController` then `import`s the leaf.

**Files:**
- Create dir: `Sources/LungfishGenotypeUI/`
- Move: `Sources/LungfishApp/Views/Results/Genotype/*` → leaf
- Move: the 9 `Sources/LungfishApp/Views/Inspector/Sections/Genotype*Section.swift` → leaf
- Move: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultSelectionState.swift` (from Task 6.1) → leaf
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController*.swift` (+ `Inspector/Sections/GenotypeResultDisplaySection.swift`) — add `import LungfishGenotypeUI`
- Create: `Tests/LungfishGenotypeUITests/GenotypeResultViewControllerTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Enumerate all Genotype-specific files**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && ls Sources/LungfishApp/Views/Results/Genotype/ && ls Sources/LungfishApp/Views/Inspector/Sections/Genotype*Section.swift`
Capture the full file list.

- [ ] **Step 2: Verify the leaf set's only upward references are now movable**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'OperationCenter|AppDelegate|ViewerViewController|MainSplitViewController|FASTQOperationDialogState|ViewerFilePanelFactory' Sources/LungfishApp/Views/Results/Genotype/ Sources/LungfishApp/Views/Inspector/Sections/Genotype*Section.swift`
Expected: `OperationCenter` is now kernel-resident (Phase 5) so refs are fine; any other hub references in code mean that piece is glue that stays in App — report. (`InspectorViewController` itself stays in App and imports the leaf — that's the allowed App->leaf direction.)

- [ ] **Step 3: Add the leaf target to Package.swift** (mirror, `LungfishGenotypeUI`; deps Core/IO/Workflow/AppKit).

- [ ] **Step 4: Move all Genotype-specific files into the leaf**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
mkdir -p Sources/LungfishGenotypeUI
git mv Sources/LungfishApp/Views/Results/Genotype/*.swift Sources/LungfishGenotypeUI/
git mv Sources/LungfishApp/Views/Inspector/Sections/GenotypeAuditTimelineSection.swift Sources/LungfishGenotypeUI/
git mv Sources/LungfishApp/Views/Inspector/Sections/GenotypeDropoutThresholdSection.swift Sources/LungfishGenotypeUI/
git mv Sources/LungfishApp/Views/Inspector/Sections/GenotypeManualHaplotypingSection.swift Sources/LungfishGenotypeUI/
git mv Sources/LungfishApp/Views/Inspector/Sections/GenotypeOverrideSection.swift Sources/LungfishGenotypeUI/
git mv Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultSelectionState.swift Sources/LungfishGenotypeUI/
# plus the remaining Genotype*Section.swift files found in Step 1
```
Make every type/member that App (`InspectorViewController`, `GenotypeResultDisplaySection`) references `public`/`open`. Fix imports inside the moved files.

- [ ] **Step 5: Add import to the App-side Inspector files**

Add `import LungfishGenotypeUI` to `InspectorViewController.swift`, `InspectorViewController+PublicAPI.swift`, and `Inspector/Sections/GenotypeResultDisplaySection.swift` (the files the audit flagged at lines 68/404/298). Find all: `rg -ln 'GenotypeResultDisplayState|GenotypeAnnotationStore|GenotypeResultSelectionState' Sources/LungfishApp` and add the import to each.

- [ ] **Step 6: Build leaf standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishGenotypeUI --skip-update 2>&1 | tail -30`
Expected: `Build complete!` (proves the Genotype<->Inspector cycle is broken — the leaf no longer needs anything from App).

- [ ] **Step 7: Smoke test the leaf**

Create `Tests/LungfishGenotypeUITests/GenotypeResultViewControllerTests.swift` instantiating the Genotype result VC (read its initializer for required args; it may need a display-state — construct a minimal one).

Run: `swift test --filter LungfishGenotypeUITests --skip-update 2>&1 | tail -20`
Expected: passes.

- [ ] **Step 8: Build LungfishApp + full suite (Phase 6 gate)**

Run: `swift build --target LungfishApp --skip-update 2>&1 | tail -10 && swift test --skip-update 2>&1 | tail -40`
Expected: App builds; full suite 0 failures. Genotype is heavily tested — watch for any genotype/inspector test failures.

- [ ] **Step 9: Commit (code-reviewed before proceeding)**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(modules): extract Genotype into LungfishGenotypeUI leaf

Break the Genotype<->Inspector knot by moving Genotype-specific inspector
sections + selection state into the leaf; InspectorViewController now imports
the leaf (allowed App->leaf direction). Leaf builds standalone; full suite green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7 — Phylogenetics leaf (HARDEST — reviewed phase)

Blockers (audit): `FASTQOperationDialogState` (op/dialog-pipeline-bound, NOT moved),
`DatasetOperationsDialog`/`DatasetOperationSection`/`DatasetOperationToolSidebarItem`,
`MultipleSequenceAlignmentTreeInferenceRequest` (in the MSA VC), `ViewerFilePanelFactory`,
`LungfishAppKitControlStyle` (now kernel), `PhylogeneticTreeSelectionState` (split in 6.1).
Strategy: invert the dialog/file-panel dependencies via protocols injected from App; move only
the VC + IQTree options into the leaf; keep the dialog *presenter* App-side.

**Files:**
- Create dir: `Sources/LungfishPhylogeneticsUI/`
- Create: `Sources/LungfishPhylogeneticsUI/PhylogeneticsDialogPresenting.swift` (new protocol the App satisfies)
- Move: `Sources/LungfishApp/Views/Viewer/PhylogeneticTreeViewController.swift`, `Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceOptions.swift` → leaf
- Move: `Sources/LungfishApp/Views/Inspector/Sections/PhylogeneticTreeSelectionState.swift` (from 6.1) → leaf
- Keep in App (glue): `IQTreeInferenceDialog.swift`, `IQTreeInferenceDialogPresenter.swift` — refactor to satisfy the new protocol
- Create: `Tests/LungfishPhylogeneticsUITests/PhylogeneticTreeViewControllerTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Map every blocker reference precisely**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n 'FASTQOperationDialogState|DatasetOperationsDialog|DatasetOperationSection|DatasetOperationToolSidebarItem|MultipleSequenceAlignmentTreeInferenceRequest|ViewerFilePanelFactory|PhylogeneticTreeSelectionState' Sources/LungfishApp/Views/Viewer/PhylogeneticTreeViewController.swift Sources/LungfishApp/Views/Phylogenetics/*.swift`
For EACH reference, decide: (a) move the type to the leaf, (b) move to kernel, or (c) invert via protocol. The dialog/dataset-operation types are op-pipeline-bound → invert (c). The MSA request type → define a leaf-local request struct the App glue translates. `ViewerFilePanelFactory` → inject via a protocol.

- [ ] **Step 2: Define the injection protocol in the leaf**

Create `Sources/LungfishPhylogeneticsUI/PhylogeneticsDialogPresenting.swift`:

```swift
import AppKit

/// The App satisfies this so the leaf can request tree inference / file selection
/// without referencing the App-internal dialog + operation pipeline.
@MainActor
public protocol PhylogeneticsDialogPresenting: AnyObject {
    /// Present the IQ-TREE inference dialog; the App wires this to its
    /// FASTQOperationDialogState-backed presenter and invokes `completion`
    /// with the user's chosen options (or nil if cancelled).
    func presentTreeInferenceDialog(completion: @escaping (PhylogeneticsInferenceChoice?) -> Void)
    /// Present a file panel for exporting/selecting; App wires this to
    /// ViewerFilePanelFactory.
    func presentFilePanel(kind: PhylogeneticsFilePanelKind, completion: @escaping (URL?) -> Void)
}

/// Leaf-local, App-independent description of an inference choice. The App glue
/// translates this to/from its internal MultipleSequenceAlignmentTreeInferenceRequest.
public struct PhylogeneticsInferenceChoice: Sendable {
    public var model: String
    public var bootstrapReplicates: Int
    public init(model: String, bootstrapReplicates: Int) {
        self.model = model
        self.bootstrapReplicates = bootstrapReplicates
    }
}

public enum PhylogeneticsFilePanelKind: Sendable { case exportNewick, exportImage }
```
(Adjust the fields of `PhylogeneticsInferenceChoice` to match what `IQTreeInferenceOptions` actually carries — read that file and mirror its user-facing fields.)

- [ ] **Step 3: Add the leaf target to Package.swift** (mirror, `LungfishPhylogeneticsUI`).

- [ ] **Step 4: Move the VC + options into the leaf and rewrite blocker references**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
mkdir -p Sources/LungfishPhylogeneticsUI
git mv Sources/LungfishApp/Views/Viewer/PhylogeneticTreeViewController.swift Sources/LungfishPhylogeneticsUI/
git mv Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceOptions.swift Sources/LungfishPhylogeneticsUI/
git mv Sources/LungfishApp/Views/Inspector/Sections/PhylogeneticTreeSelectionState.swift Sources/LungfishPhylogeneticsUI/
```
In the moved VC:
- Replace direct `IQTreeInferenceDialog`/`DatasetOperationsDialog` presentation with a `weak var dialogPresenter: PhylogeneticsDialogPresenting?` call.
- Replace `ViewerFilePanelFactory` use with `dialogPresenter?.presentFilePanel(...)`.
- Replace the `MultipleSequenceAlignmentTreeInferenceRequest` reference with the leaf-local `PhylogeneticsInferenceChoice`.
- Make the VC + members App touches `public`/`open`; imports = Foundation/AppKit/Workflow/AppKit-kernel.

- [ ] **Step 5: Build leaf standalone**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishPhylogeneticsUI --skip-update 2>&1 | tail -30`
Expected: `Build complete!` If a blocker remains, it wasn't fully inverted — fix the specific reference (do not pull the op-pipeline type into the leaf).

- [ ] **Step 6: Implement the App-side presenter conforming to the protocol**

Create `Sources/LungfishApp/Views/Viewer/ViewerViewController+Phylogenetics.swift` (glue): make an App type conform to `PhylogeneticsDialogPresenting`, wiring `presentTreeInferenceDialog` to the existing `IQTreeInferenceDialogPresenter` (translating `PhylogeneticsInferenceChoice` <-> `MultipleSequenceAlignmentTreeInferenceRequest` / `IQTreeInferenceOptions`) and `presentFilePanel` to `ViewerFilePanelFactory`. Set `phyloVC.dialogPresenter = self` where the VC is created. Add `import LungfishPhylogeneticsUI`.

- [ ] **Step 7: Build LungfishApp**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --target LungfishApp --skip-update 2>&1 | tail -30`
Expected: `Build complete!`

- [ ] **Step 8: Smoke + wiring test**

Create `Tests/LungfishPhylogeneticsUITests/PhylogeneticTreeViewControllerTests.swift`:

```swift
import XCTest
import AppKit
@testable import LungfishPhylogeneticsUI

final class PhylogeneticTreeViewControllerTests: XCTestCase {
    @MainActor
    final class StubPresenter: PhylogeneticsDialogPresenting {
        var dialogRequested = false
        func presentTreeInferenceDialog(completion: @escaping (PhylogeneticsInferenceChoice?) -> Void) {
            dialogRequested = true
            completion(PhylogeneticsInferenceChoice(model: "GTR", bootstrapReplicates: 1000))
        }
        func presentFilePanel(kind: PhylogeneticsFilePanelKind, completion: @escaping (URL?) -> Void) {
            completion(nil)
        }
    }

    @MainActor
    func testInferenceRequestRoutesThroughInjectedPresenter() {
        let vc = PhylogeneticTreeViewController()
        let stub = StubPresenter()
        vc.dialogPresenter = stub
        XCTAssertNotNil(vc.view)
        vc.requestTreeInference()  // whatever the public entry point is named; read the VC
        XCTAssertTrue(stub.dialogRequested)
    }
}
```
(Adapt the VC init args and the `requestTreeInference()` call to the VC's actual public API — read the moved VC to get exact names.)

Run: `swift test --filter LungfishPhylogeneticsUITests --skip-update 2>&1 | tail -20`
Expected: passes (proves the dependency inversion works without App).

- [ ] **Step 9: Full suite (Phase 7 gate)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift test --skip-update 2>&1 | tail -40`
Expected: 0 failures. Phylogenetics + MSA + FASTQ-operation tests are the risk area; inspect any failure there closely.

- [ ] **Step 10: Commit (code-reviewed before proceeding)**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "$(cat <<'EOF'
refactor(modules): extract Phylogenetics into LungfishPhylogeneticsUI leaf

Invert the dialog/file-panel dependencies via a PhylogeneticsDialogPresenting
protocol the App satisfies, so the VC no longer references the
FASTQOperationDialogState-backed op/dialog pipeline. Leaf builds standalone;
full suite green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8 — Benchmark, release alpha11, clean main

### Task 8.1: Re-benchmark builds + module-scoped isolation

**Files:**
- Create: `docs/reports/baselines/after-kernel-module-<sha>.md` (via the measure script)
- Create: `docs/reports/2026-06-01-kernel-module-results.md`

- [ ] **Step 1: Run the standard build-time measurement**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && bash scripts/measure-build-times.sh after-kernel-module 2>&1 | tail -30`
(Reads/writes `docs/reports/baselines/after-kernel-module-<sha>.md`. The script serializes its own swift calls.)

- [ ] **Step 2: Measure module-scoped incremental rebuild (the payoff)**

Demonstrate "test only what changed". For an extracted leaf and the kernel, time a one-line touch + rebuild of ONLY that target:
```bash
cd /Users/dho/Documents/lungfish-genome-explorer
# warm build
swift build --skip-update >/dev/null 2>&1
# leaf-only edit
touch Sources/LungfishAlignmentUI/AlignmentResultViewController.swift
/usr/bin/time -p swift build --target LungfishAlignmentUI --skip-update 2>&1 | tail -5
# leaf-only test
/usr/bin/time -p swift test --filter LungfishAlignmentUITests --skip-update 2>&1 | tail -5
```
Record wall-clock for the leaf-only build+test vs a full `swift build` + `swift test`.

- [ ] **Step 3: Write the results doc**

Create `docs/reports/2026-06-01-kernel-module-results.md` comparing the `ae131e9d` baseline (in `docs/reports/baselines/`) to the post-refactor numbers: cold build, no-op, full-suite, AND the module-scoped leaf-only build/test times. State the headline: a leaf edit now recompiles/tests only that leaf. Follow the docs prose rules (no em dashes, bullet cap 5/2) since this is a `docs/reports/` file (NOT exempt like specs/plans).

- [ ] **Step 4: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add docs/reports/
git commit -m "docs: kernel/module refactor build-time results vs alpha10 baseline

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 8.2: Version bump alpha10 -> alpha11

**Files (all ~13 sites — bump TOGETHER or version tests fail):**
- `Sources/LungfishCLI/LungfishCLI.swift`
- `Sources/LungfishCLI/.../SequenceCommand.swift`
- `Sources/LungfishCLI/.../PrimerCommand.swift`
- `Sources/LungfishApp/.../AboutWindowController.swift`
- `Sources/LungfishApp/.../WelcomeWindowController.swift`
- `Sources/LungfishApp/Resources/.../HelpBook .../Info.plist` (HelpBook)
- `third-party-tools-lock.json`
- `Tests/.../CLIRegressionTests.swift` (asserts `"0.5.0-alpha11"`)
- `Tests/.../CondaManagerTests.swift`
- `Lungfish.xcodeproj/project.pbxproj` (4 `MARKETING_VERSION` sites)
- Create: `docs/release-notes/v0.5.0-alpha11.md`

- [ ] **Step 1: Find every occurrence**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n '0\.5\.0-alpha10' --hidden -g '!.build' | sort`
Expected: ~13 lines across the files above. This is the authoritative list to change.

- [ ] **Step 2: Bump each site with a per-file loop (NOT a multi-file sed)**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
bump() { /usr/bin/sed -i '' 's/0\.5\.0-alpha10/0.5.0-alpha11/g' "$1"; }
# run bump on each file from Step 1's output, one call each, e.g.:
# bump Sources/LungfishCLI/LungfishCLI.swift
# ... (every file listed)
```
(A single sed over a multi-line file list mangles paths — call `bump` once per file.)

- [ ] **Step 3: Verify zero alpha10 remain**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -n '0\.5\.0-alpha10' --hidden -g '!.build' || echo "ALL BUMPED"`
Expected: `ALL BUMPED`.

- [ ] **Step 4: Write release notes**

Create `docs/release-notes/v0.5.0-alpha11.md` summarizing the kernel/module refactor (developer-facing: kernel now holds the shared UI/op infrastructure; feature surfaces are isolated leaf modules with per-module tests; no user-facing behavior change). Follow docs prose rules.

- [ ] **Step 5: Build + version tests**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build --skip-update 2>&1 | tail -5 && swift test --filter 'testLungfishCLIVersion|CondaManagerTests' --skip-update 2>&1 | tail -20`
Expected: build complete; version tests pass asserting alpha11.

- [ ] **Step 6: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -A
git commit -m "release: bump version to 0.5.0-alpha11

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 8.3: Full suite, push, notarized DMG + Sparkle, clean main

- [ ] **Step 1: Final full suite**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift test --skip-update 2>&1 | tail -40`
Expected: 0 failures.

- [ ] **Step 2: Push main to origin (REQUIRED before release tagging)**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && git push origin main && git rev-parse --short HEAD origin/main`
Expected: push succeeds; HEAD == origin/main. (gh release create --target fails HTTP 422 if the commit is not on origin.)

- [ ] **Step 3: Build notarized DMG + Sparkle appcast from the CLEAN tree**

Run:
```bash
cd /Users/dho/Documents/lungfish-genome-explorer
bash scripts/release/build-notarized-dmg.sh \
  --signing-identity "Developer ID Application: Pathogenuity LLC (29G3WN2GSA)" \
  --team-id 29G3WN2GSA \
  --notary-profile LungfishNotary \
  --sparkle-public-ed-key "FtnZIDTqGTwkglQR0z8iSgVvxvT26a05QB3cI4xQw/c=" \
  --sparkle-generate-appcast "$(pwd)/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --sparkle-publish-release sparkle-alpha
```
Expected: archive -> notarize -> staple -> DMG at `build/Release/Lungfish-0.5.0-alpha11-arm64.dmg`; `v0.5.0-alpha11` GitHub release created with the DMG; `appcast-alpha.xml` published to `sparkle-alpha`. NEVER pass `--reuse-archive` after a successful notarize (re-signing corrupts the stapled bundle); on any post-notarization failure, `rm -rf build/Release/Lungfish.xcarchive build/Release/*.dmg` and rebuild fresh.

- [ ] **Step 4: Confirm clean local + remote main, no leftovers**

Run:
```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git status --porcelain=v1 -uno; echo "(end dirty)"
echo "in-sync: $([ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && echo YES || echo NO)"
git worktree list; git branch; git stash list; echo "(end)"
gh release view v0.5.0-alpha11 --json tagName --jq .tagName
```
Expected: no dirty tracked files; in-sync YES; one worktree, only `main`, no stashes; release tag present.

---

## Self-review notes (for the executor)

- This plan covers every spec phase 1-8. The hubs (Viewer/MainSplit/Inspector/Sidebar) are
  intentionally NOT extracted (composition roots).
- If ANY task surfaces a blocker the audit did not predict, STOP that task and report rather
  than pulling an op-pipeline type into a leaf/kernel. A clean boundary beats a half-untangled
  one.
- Run the full suite at each phase boundary, not each task (it is slow). Standalone-target
  builds are the per-task correctness check.
- Phases 5, 6.2, and 7 (OperationCenter, Genotype, Phylogenetics) are the reviewed phases —
  expect a code-review pass after each before continuing.

# iVar, Annotations, and Import Center Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The user has directed that each PR auto-merges to `main` between phases — no human approval gate between PRs 1-5. PR 6 has an explicit external gate (user rebuilds the release app from `main`).

**Goal:** Consolidate Lungfish's file-import UX onto Import Center only, add a GFF3/GTF/BED Annotations section anchored to an existing reference, fix the FASTA grey-out bug in Import Center → References, regenerate the `sarscov2-clinical` fixture against NC_045512.2 with an iVar-called VCF carrying `ANN=` consequences, rewrite chapter `04-variants/01-reading-a-vcf.md` end-to-end, and capture the final shots.

**Architecture:** Six phased PRs, each merging to `main` automatically. PR 1 is a pure docs/notes PR enumerating diagnosis findings so every subsequent PR has concrete file paths. PRs 2-3 are Swift app changes (menu removal, Annotations section, FASTA fix). PR 4 regenerates the fixture outside the app using iVar 1.4+ with `--output-format vcf`. PR 5 rewrites the chapter with 5-6 initial recipe stubs that get pruned during prose revision. PR 6 drives Computer Use against the rebuilt release app to capture PNGs.

**Tech Stack:** Swift 6.2 / LungfishApp, NCBI EDirect (`efetch`), bwa/samtools/bcftools, iVar 1.4+, MkDocs, Computer Use MCP (`mcp__computer-use__*`), subagent-driven-development skill.

---

## Scope check

This plan covers the six-PR spec at `docs/superpowers/specs/2026-04-15-ivar-annotations-import-center-design.md`. The spec is intentionally tight (one chapter + the minimum app/fixture changes needed to teach it). No further decomposition needed.

## Branch and worktree

All work happens on branch `claude/sad-morse` in the existing worktree at `.claude/worktrees/sad-morse`. The spec explicitly rejects switching to `main` for the code work because the parallel `codex/portable-bundle…` worktree is on a separate branch with no file collision risk. Auto-merge to `main` happens via `git checkout main && git merge --ff-only claude/sad-morse && git push origin main` after each PR's review passes.

**Worktree build restriction (from MEMORY.md):** Swift builds and tests work in this worktree, but Java-based tools (BBTools, Clumpify) fail because `*.dylib` is gitignored. This plan's Swift tasks use `swift test` and `swift build --build-tests`, which is fine. Runtime UI testing of Java-dependent tools is not needed by this plan.

## File structure

Files created or modified by this plan. Each PR's tasks touch a narrow slice.

### PR 1 — Investigation notes

- `docs/superpowers/notes/2026-04-15-ivar-annotations-import-center-investigation.md` (create) — captures (a) FASTA grey-out root cause + file/line, (b) File menu `CommandGroup` location, (c) GFF3/GTF/BED parser inventory, (d) sample-metadata-attachment UX status, (e) Import Center section list location.

### PR 2 — Remove File > Import submenu

- `Sources/LungfishApp/App/MainMenu.swift` (modify) — remove the `Import` submenu and its items. The `Import Center…` item stays and moves up to take the submenu's old slot.
- Any CLI / URL handler that references the removed menu action selectors (grep in Phase 2.1 to enumerate).
- Help text files (grep in Phase 2.1): any string referring to `File > Import > …`.
- Tests: `Tests/LungfishAppTests/MainMenuTests.swift` (modify or create) — assert `Import Center…` is present with ⇧⌘Y and that no `Import` submenu title exists.

### PR 3 — Annotations section + FASTA fix

- `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift` (modify) — add Annotations section to the section list.
- `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift` (modify) — add eligibility predicate for `.gff`/`.gff3`/`.gtf`/`.bed`, reference-picker state, "Attach to reference" dropdown wiring.
- New: `Sources/LungfishApp/Views/ImportCenter/AnnotationsSection.swift` — SwiftUI view for the Annotations section.
- Bug-fix file: whichever Swift file PR 1's investigation named as the FASTA grey-out root cause (almost certainly `ImportCenterViewModel.swift` or a nearby predicate helper).
- Tests: `Tests/LungfishAppTests/ImportCenterTests.swift` (create or extend) — (a) References section accepts `.fasta`/`.fa`/`.fna`/`.ffn`; (b) Annotations section accepts `.gff`/`.gff3`/`.gtf`/`.bed`; (c) Annotations section shows helper row when project has no references.

### PR 4 — Fixture regeneration

All files in `docs/user-manual/fixtures/sarscov2-clinical/`.

- `reference.fasta`, `reference.fasta.fai` (replace) — NC_045512.2.
- `alignments.bam`, `alignments.bam.bai` (replace) — re-aligned against NC_045512.2.
- `annotations.gff3` (create) — NCBI RefSeq GFF3 for NC_045512.2.
- `variants.vcf.gz`, `variants.vcf.gz.tbi` (replace) — iVar-called VCF with `ANN=`.
- `fetch.sh` (modify) — provenance record; regenerates reference + GFF3 + BAM, documents the iVar command.
- `README.md` (modify) — list new accession, explain iVar `ANN`, record iVar version.
- `docs/user-manual/fixtures/sarscov2-clinical/ivar-version.txt` (create) — captured `ivar version` output at the moment of generation.

### PR 5 — Chapter rewrite

- `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` (rewrite wholesale).
- `docs/user-manual/GLOSSARY.md` (modify) — add entries: GFF3, annotation-track, synonymous, nonsynonymous, missense, consequence, sample-metadata, iVar.
- `docs/user-manual/features.yaml` (modify) — add `import.center`, `import.reference`, `import.annotations`, `sample-metadata` entries. Keep existing `import.vcf` and `viewport.variant-browser`. Remove any entries that described the now-deleted File > Import submenu (none exist yet per current file).
- `docs/user-manual/assets/recipes/04-variants/` — stub files (create):
  - `import-center-empty.yaml`
  - `import-reference.yaml`
  - `import-annotations.yaml`
  - `import-vcf.yaml` (supersedes existing `vcf-open-dialog.yaml`)
  - `variant-table-with-consequences.yaml` (supersedes existing `vcf-variant-table.yaml`)
  - `sample-metadata-attached.yaml`
- `docs/user-manual/assets/recipes/04-variants/vcf-open-dialog.yaml`, `vcf-variant-table.yaml` (delete) — superseded.

### PR 6 — Shot capture + compositing

- `docs/user-manual/assets/shots/04-variants/*.png` (create) — one PNG per surviving recipe.
- `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` (final modify) — set `brand_reviewed: true` and `lead_approved: true` after review subagents pass.

---

## Phase gates

Between PRs the executing agent runs: `git checkout main && git pull origin main && git merge --ff-only claude/sad-morse && git push origin main && git checkout claude/sad-morse`. If the fast-forward merge fails (remote main has diverged), the agent halts and reports; it does not attempt a rebase or merge commit without human direction.

---

## PR 1 — Investigation notes

**Goal:** Land a notes file that names the exact files and lines every subsequent PR will touch.

**Files:**
- Create: `docs/superpowers/notes/2026-04-15-ivar-annotations-import-center-investigation.md`

### Task 1.1: Reproduce the FASTA grey-out bug on main

- [ ] **Step 1: Switch to main**

Run:
```
git fetch origin main
git worktree add -B investigation-probe ../investigation-probe origin/main
cd ../investigation-probe
```

- [ ] **Step 2: Build and launch the release app from main**

Run:
```
bash scripts/release/build-notarized-dmg.sh --skip-notarize 2>&1 | tail -20
```

Or (faster for investigation, no DMG):
```
swift build -c release --product LungfishApp
open .build/release/LungfishApp.app
```

Expected: App launches. If the release build script requires signing/notarization credentials, fall back to `swift build`.

- [ ] **Step 3: Create an empty project and open Import Center**

Manual. Launch app → File → New Project → pick an empty directory → File → Import Center… (⇧⌘Y) → click References.

- [ ] **Step 4: Drop in the fixture FASTA**

Select `docs/user-manual/fixtures/sarscov2-clinical/reference.fasta`. Observe whether it appears greyed-out / ineligible.

- [ ] **Step 5: Record the symptom**

Open `docs/superpowers/notes/2026-04-15-ivar-annotations-import-center-investigation.md` in the investigation worktree and paste the observed symptom (exact UI text, whether the file is visible but disabled, etc.).

### Task 1.2: Trace the eligibility predicate

- [ ] **Step 1: Find the References-section eligibility code**

Run (from `../investigation-probe`):
```
grep -n "fasta\|\.fa\"\|\.fna\|\.ffn" Sources/LungfishApp/Views/ImportCenter/*.swift
```

Record the file + line of every allow-list / predicate hit.

- [ ] **Step 2: Find the overall Import Center section registry**

Run:
```
grep -n "References\|Alignments\|Variants\|Reads" Sources/LungfishApp/Views/ImportCenter/*.swift
```

Record the file + line where the section list is defined. That's where PR 3 will slot in the Annotations section.

- [ ] **Step 3: Step through the predicate with a synthetic FASTA**

Under a debugger (or by adding temporary print statements and rebuilding), determine which branch of the predicate returns "ineligible" for the fixture FASTA. Candidates per the spec's risk log:
- Extension allow-list omits `.fasta` (only `.fa`)
- MIME check failing
- Symlink resolution bug
- Size zero-check false positive
- Text-encoding false negative

Record the root cause with file + line number.

- [ ] **Step 4: Commit the investigation worktree and remove it**

Run:
```
cd ..
rm -rf investigation-probe
git worktree prune
```

The investigation worktree is throwaway. All findings live in the notes file on `claude/sad-morse`.

### Task 1.3: Locate the File menu `CommandGroup`

- [ ] **Step 1: Grep from the sad-morse worktree**

Run (from `.claude/worktrees/sad-morse`):
```
grep -n "Import\|importCenter\|CommandGroup" Sources/LungfishApp/App/MainMenu.swift
```

Record every line that defines an `Import`-named menu item.

- [ ] **Step 2: Capture the full Import submenu definition**

Use `sed -n '<start>,<end>p' Sources/LungfishApp/App/MainMenu.swift` (via the Read tool in the executing session) on the range identified in step 1. Paste it verbatim into the notes file.

### Task 1.4: Parser inventory

- [ ] **Step 1: Check for GFF/GTF/BED parsers already in LungfishIO**

Run:
```
grep -rln "class.*GFF\|class.*GTF\|class.*BED\|struct.*GFF" Sources/LungfishIO/ Sources/LungfishCore/
```

Record which formats have native parsers.

- [ ] **Step 2: Check what BigBed imports**

Run:
```
grep -n "BigBed\|\.bb\|\.bigbed" Sources/LungfishApp/ Sources/LungfishIO/ --include="*.swift" -r
```

Record the code path BigBed uses. The new Annotations section for GFF3/GTF/BED reuses existing parsers — if a format's parser is missing, flag it as a parser sub-task for PR 3.

### Task 1.5: Sample-metadata UX inventory

- [ ] **Step 1: Find the VCF sample-metadata UI**

Run:
```
grep -rln "sample.*metadata\|SampleMetadata\|metadataColumn" Sources/LungfishApp/ --include="*.swift"
```

The user confirmed Lungfish already supports attaching sample metadata to a VCF. Record the exact UI entry point (menu item, inspector tab, drag target). The chapter's Section 3.5 reflects whatever exists.

- [ ] **Step 2: If no UX exists, flag the chapter Section 3.5 as a pointer-only section**

The spec's risk log handles this case (Section 3.5 becomes a "see X feature documentation" pointer, and the `sample-metadata-attached` shot gets dropped). Record the decision in the notes file.

### Task 1.6: Write the notes file and commit

- [ ] **Step 1: Write the notes file**

Create `docs/superpowers/notes/2026-04-15-ivar-annotations-import-center-investigation.md` with this structure:

```markdown
# iVar, Annotations, and Import Center — Investigation Notes

**Date:** 2026-04-15
**Parent spec:** `docs/superpowers/specs/2026-04-15-ivar-annotations-import-center-design.md`

## 1. FASTA grey-out root cause

- **File:** `<path>:<line>`
- **Symptom observed:** <paste>
- **Root cause:** <one-paragraph explanation>

## 2. File menu `CommandGroup` location

- **File:** `Sources/LungfishApp/App/MainMenu.swift:<start>-<end>`
- **Current definition:** (paste verbatim)

## 3. Parser inventory

| Format | Parser file | Notes |
| --- | --- | --- |
| GFF3 | `<path>` or MISSING | ... |
| GTF | `<path>` or MISSING | ... |
| BED | `<path>` or MISSING | ... |
| BigBed | `<path>` | already used where |

## 4. Sample-metadata UX

- **Entry point:** `<menu / inspector tab / drag target>`
- **File:** `<path>:<line>`
- **Decision:** full walkthrough in chapter, OR pointer-only with shot dropped

## 5. Import Center section registry

- **File:** `<path>:<line>`
- **Registration pattern:** (paste the code snippet that adds each section)

## 6. Decisions for downstream PRs

- PR 2 touches: (list files)
- PR 3 touches: (list files, including whether new parsers are needed)
- PR 5 Section 3.5: (full walkthrough / pointer-only)
```

- [ ] **Step 2: Commit PR 1**

Run:
```
git add docs/superpowers/notes/2026-04-15-ivar-annotations-import-center-investigation.md
git commit -m "docs(notes): investigation findings for Import Center consolidation

Documents the FASTA grey-out root cause, File menu CommandGroup
location, GFF3/GTF/BED parser inventory, sample-metadata UX status,
and Import Center section registry. Feeds PRs 2-5.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 3: Auto-merge PR 1 to main**

Run:
```
git checkout main
git pull origin main
git merge --ff-only claude/sad-morse
git push origin main
git checkout claude/sad-morse
```

Expected: Fast-forward succeeds. If it fails, halt and report.

---

## PR 2 — Remove File > Import submenu

**Goal:** Single import entry point. `File > Import Center…` (⇧⌘Y) is the only way into imports.

**Files:**
- Modify: `Sources/LungfishApp/App/MainMenu.swift` (at the line range identified by Task 1.3)
- Modify: `Tests/LungfishAppTests/MainMenuTests.swift` (or create if it doesn't exist)
- Modify: any additional file flagged by Task 1.2 / 1.5 grep that references removed selectors

### Task 2.1: Enumerate all references to the Import submenu

- [ ] **Step 1: Grep for menu item titles and selectors**

Run:
```
grep -rn "Import > \|File > Import\|import.*Files\|@Published.*showImport" Sources/ Tests/ docs/ --include="*.swift" --include="*.md" --include="*.yml"
```

Record every hit. The test file, any help/welcome text, and any AppleScript hooks must be updated.

- [ ] **Step 2: Document the surface area in a scratch file**

Keep a running list (in your scratch memory or a temp markdown file) of every file that will be touched in PR 2. This surface is the PR 2 acceptance criterion.

### Task 2.2: Write the failing MainMenu test

- [ ] **Step 1: Read existing `MainMenuTests.swift` if present**

Run:
```
cat Tests/LungfishAppTests/MainMenuTests.swift 2>/dev/null || echo "does not exist"
```

- [ ] **Step 2: Write or extend the test**

Add (or create the file with) this test:

```swift
import XCTest
@testable import LungfishApp

final class MainMenuImportConsolidationTests: XCTestCase {
    @MainActor
    func test_fileMenu_hasNoImportSubmenu() {
        let menu = MainMenu.buildFileMenu()
        // No menu item titled "Import" should exist in the File menu.
        let importSubmenu = menu.items.first { $0.title == "Import" }
        XCTAssertNil(importSubmenu,
            "File > Import submenu should be removed; Import Center is the sole import entry point.")
    }

    @MainActor
    func test_fileMenu_hasImportCenterWithShortcut() {
        let menu = MainMenu.buildFileMenu()
        let importCenter = menu.items.first { $0.title == "Import Center…" }
        XCTAssertNotNil(importCenter, "File > Import Center… must be present.")
        XCTAssertEqual(importCenter?.keyEquivalent, "y")
        XCTAssertTrue(importCenter!.keyEquivalentModifierMask.contains([.command, .shift]))
    }
}
```

If `MainMenu` currently constructs the File menu inline inside `AppDelegate.applicationDidFinishLaunching` (not via a static builder), add a test-only factory method `static func buildFileMenu() -> NSMenu` that returns the constructed menu without side effects. Tests import the factory.

- [ ] **Step 3: Run the test and verify it fails**

Run:
```
swift test --filter MainMenuImportConsolidationTests 2>&1 | tail -30
```

Expected: FAIL with "File > Import submenu should be removed" because the submenu still exists.

### Task 2.3: Remove the Import submenu

- [ ] **Step 1: Delete the `Import` submenu block in MainMenu.swift**

Locate the block identified in Task 1.3's notes. It looks roughly like:

```swift
let importMenu = NSMenu(title: "Import")
importMenu.addItem(withTitle: "Files…", action: ..., keyEquivalent: "")
importMenu.addItem(withTitle: "VCF…", action: ..., keyEquivalent: "")
// ...
let importItem = NSMenuItem(title: "Import", action: nil, keyEquivalent: "")
importItem.submenu = importMenu
fileMenu.addItem(importItem)
```

Delete the entire block. Ensure `Import Center…` remains and occupies roughly the same slot in the menu ordering.

- [ ] **Step 2: Remove now-orphan selectors**

Any `@objc func importFiles(_:)`, `@objc func importVCF(_:)`, etc. that were targets of the removed menu items and have no other callers get deleted. Check `grep -n "importFiles\|importVCF\|importBAM" Sources/LungfishApp/ -r` — if a selector is referenced only from the deleted menu, remove its declaration too. If it's referenced from a URL handler or CLI bridge, leave the selector but remove its menu-wiring.

- [ ] **Step 3: Run the test**

Run:
```
swift test --filter MainMenuImportConsolidationTests 2>&1 | tail -20
```

Expected: PASS.

### Task 2.4: Update help strings and references

- [ ] **Step 1: Replace `File > Import > …` mentions**

For every file flagged in Task 2.1, replace textual references like `"File > Import > Files…"` with `"File > Import Center…"` (or `"Import Center"` if bare). If a string refers specifically to a removed path (e.g. "File > Import > VCF…"), replace it with `"Import Center → Variants"`.

- [ ] **Step 2: Run the full test suite**

Run:
```
swift test 2>&1 | tail -40
```

Expected: All tests pass. If any pre-existing test referred to the submenu and now fails, update that test (it's describing stale behavior).

### Task 2.5: Commit PR 2 and merge to main

- [ ] **Step 1: Commit**

Run:
```
git add -A
git commit -m "feat(app): remove File > Import submenu, Import Center is sole entry

Users had two import doors (File > Import > … and File > Import Center…)
which confused navigation and bypassed Import Center's curation + the
reference-eligibility logic that the new Annotations section depends on.
Single door now: File > Import Center… (⇧⌘Y).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 2: Auto-merge to main**

Run:
```
git checkout main
git pull origin main
git merge --ff-only claude/sad-morse
git push origin main
git checkout claude/sad-morse
```

If fast-forward fails, halt and report.

---

## PR 3 — Annotations section + FASTA fix

**Goal:** Import Center → Annotations accepts GFF3/GTF/BED and binds the track to a chosen reference. References section stops greying out valid FASTA files.

**Files:**
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
- Create: `Sources/LungfishApp/Views/ImportCenter/AnnotationsSection.swift`
- Modify: the file PR 1 named as the FASTA grey-out root cause (typically `ImportCenterViewModel.swift`)
- Create or extend: `Tests/LungfishAppTests/ImportCenterTests.swift`

### Task 3.1: Write the failing FASTA-eligibility regression test

- [ ] **Step 1: Read existing ImportCenter tests**

Run:
```
ls Tests/LungfishAppTests/ImportCenter* 2>/dev/null
cat Tests/LungfishAppTests/ImportCenterTests.swift 2>/dev/null | head -60
```

- [ ] **Step 2: Add the FASTA eligibility test**

Create or extend `Tests/LungfishAppTests/ImportCenterTests.swift`:

```swift
import XCTest
@testable import LungfishApp

final class ImportCenterEligibilityTests: XCTestCase {
    @MainActor
    func test_referencesSection_acceptsAllFastaExtensions() {
        let vm = ImportCenterViewModel()
        for ext in ["fasta", "fa", "fna", "ffn"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertTrue(vm.isEligible(url, for: .references),
                "References section must accept .\(ext) extension")
        }
    }

    @MainActor
    func test_referencesSection_rejectsUnrelatedExtensions() {
        let vm = ImportCenterViewModel()
        for ext in ["vcf", "bam", "bed", "gff3"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertFalse(vm.isEligible(url, for: .references),
                "References section must reject .\(ext) extension")
        }
    }
}
```

If `isEligible(_:for:)` does not exist as a public API, add the test in terms of whatever entry point the viewmodel already exposes (per PR 1 investigation). The key contract: given a URL, the viewmodel must return a boolean decision for a named section.

- [ ] **Step 3: Run the test and verify it fails**

Run:
```
swift test --filter ImportCenterEligibilityTests 2>&1 | tail -30
```

Expected: FAIL — at least one FASTA extension is greyed out per the PR 1 reproduction.

### Task 3.2: Fix the FASTA grey-out bug

- [ ] **Step 1: Apply the fix at the file/line named in PR 1's notes**

The exact fix depends on root cause. Common cases and their fixes:

- **If the allow-list omits `.fasta`:** add the missing extension to the allow-list constant.
- **If MIME check fails:** replace the MIME-based predicate with an extension-based one for FASTA.
- **If size zero-check false positive:** relax the size predicate to tolerate files of any non-negative size.
- **If symlink resolution bug:** resolve symlinks once via `url.resolvingSymlinksInPath()` before checking.

Use whichever fix PR 1's notes prescribe.

- [ ] **Step 2: Run the FASTA eligibility test**

Run:
```
swift test --filter ImportCenterEligibilityTests 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 3: Run the full test suite to guard against regressions**

Run:
```
swift test 2>&1 | tail -40
```

Expected: All tests pass. If any other section's eligibility test now fails, the shared predicate relaxation was too broad. Narrow the fix and re-run.

### Task 3.3: Write the failing Annotations-section tests

- [ ] **Step 1: Add three tests for the new section**

Extend `Tests/LungfishAppTests/ImportCenterTests.swift`:

```swift
final class ImportCenterAnnotationsSectionTests: XCTestCase {
    @MainActor
    func test_annotationsSection_acceptsGFF3AndGTFAndBED() {
        let vm = ImportCenterViewModel()
        for ext in ["gff", "gff3", "gtf", "bed"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertTrue(vm.isEligible(url, for: .annotations),
                "Annotations section must accept .\(ext)")
        }
    }

    @MainActor
    func test_annotationsSection_rejectsFastaAndVcf() {
        let vm = ImportCenterViewModel()
        for ext in ["fasta", "vcf", "bam", "fastq"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertFalse(vm.isEligible(url, for: .annotations),
                "Annotations section must reject .\(ext)")
        }
    }

    @MainActor
    func test_annotationsSection_blocksImportWhenNoReferenceInProject() {
        let vm = ImportCenterViewModel()
        vm.referencesInProject = []  // empty project
        let url = URL(fileURLWithPath: "/tmp/sample.gff3")
        XCTAssertTrue(vm.isEligible(url, for: .annotations), "file-level eligibility stays true")
        XCTAssertFalse(vm.canStartAnnotationsImport,
            "Annotations import must be blocked when project has no references.")
        XCTAssertEqual(vm.annotationsHelperText,
            "Import a reference first.",
            "Helper text must prompt user to import a reference.")
    }
}
```

If `ImportCenterViewModel` does not yet expose `referencesInProject`, `canStartAnnotationsImport`, or `annotationsHelperText`, add the test — these are the contract the new code will satisfy.

- [ ] **Step 2: Run the tests and verify they fail**

Run:
```
swift test --filter ImportCenterAnnotationsSectionTests 2>&1 | tail -30
```

Expected: FAIL — `.annotations` section does not exist yet.

### Task 3.4: Add the Annotations section type

- [ ] **Step 1: Extend the section enum**

In whichever Swift file defines the section enum (per PR 1's notes; typically `ImportCenterViewModel.swift`), add a case. If the enum is:

```swift
enum ImportCenterSection: String, CaseIterable, Identifiable {
    case references
    case alignments
    case variants
    case reads
    case metadata
    case other
    var id: String { rawValue }
    var displayName: String { … }
    var iconName: String { … }
}
```

Add:

```swift
case annotations
```

and update `displayName`:

```swift
case .annotations: return "Annotations"
```

and `iconName` (use `"scroll.fill"` or whatever SF Symbol the existing sections pattern suggests).

- [ ] **Step 2: Add eligibility for Annotations**

In the viewmodel's `isEligible(_:for:)` method, add the branch:

```swift
case .annotations:
    return ["gff", "gff3", "gtf", "bed"].contains(url.pathExtension.lowercased())
```

- [ ] **Step 3: Add the references-in-project gate**

Add to `ImportCenterViewModel`:

```swift
@Published var referencesInProject: [ReferenceSequenceSummary] = []
@Published var selectedAnnotationReferenceID: String? = nil

var canStartAnnotationsImport: Bool {
    !referencesInProject.isEmpty && selectedAnnotationReferenceID != nil
}

var annotationsHelperText: String {
    if referencesInProject.isEmpty {
        return "Import a reference first."
    }
    return ""
}
```

Wire `referencesInProject` to the current project state via whatever dependency the existing sections use (the References section already queries project references to populate its list — reuse the same provider).

- [ ] **Step 4: Run the tests**

Run:
```
swift test --filter ImportCenterAnnotationsSectionTests 2>&1 | tail -20
```

Expected: PASS.

### Task 3.5: Build the AnnotationsSection SwiftUI view

- [ ] **Step 1: Create the view file**

Create `Sources/LungfishApp/Views/ImportCenter/AnnotationsSection.swift`:

```swift
import SwiftUI

struct AnnotationsSection: View {
    @ObservedObject var viewModel: ImportCenterViewModel
    @Binding var selectedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "scroll.fill")
                    .foregroundStyle(.lungfishOrange)
                Text("Annotations")
                    .font(.headline)
            }

            if viewModel.referencesInProject.isEmpty {
                HStack {
                    Text(viewModel.annotationsHelperText)
                        .foregroundStyle(.secondary)
                    Button("Go to References") {
                        viewModel.activeSection = .references
                    }
                    .buttonStyle(.link)
                }
                .padding(.vertical, 8)
            } else {
                filePicker
                referencePicker
                importButton
            }
        }
        .padding(16)
    }

    private var filePicker: some View {
        HStack {
            Text(selectedURL?.lastPathComponent ?? "No file selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Choose file…") {
                pickAnnotationFile()
            }
        }
    }

    private var referencePicker: some View {
        Picker("Attach to reference", selection: $viewModel.selectedAnnotationReferenceID) {
            Text("Select a reference").tag(String?.none)
            ForEach(viewModel.referencesInProject) { ref in
                Text(ref.displayName).tag(Optional(ref.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var importButton: some View {
        Button {
            Task {
                await viewModel.importAnnotations(from: selectedURL)
            }
        } label: {
            Text("Import")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canStartAnnotationsImport || selectedURL == nil)
    }

    private func pickAnnotationFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gff, .gff3, .gtf, .bed].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            selectedURL = panel.url
        }
    }
}

private extension UTType {
    static var gff: UTType? { UTType(filenameExtension: "gff") }
    static var gff3: UTType? { UTType(filenameExtension: "gff3") }
    static var gtf: UTType? { UTType(filenameExtension: "gtf") }
    static var bed: UTType? { UTType(filenameExtension: "bed") }
}
```

- [ ] **Step 2: Register the section in the Import Center's section list view**

Open `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`. Find the `switch activeSection` (or equivalent) that renders each section. Add:

```swift
case .annotations:
    AnnotationsSection(viewModel: viewModel, selectedURL: $selectedAnnotationURL)
```

If `selectedAnnotationURL` state doesn't exist in the parent view, add it as `@State private var selectedAnnotationURL: URL? = nil`.

- [ ] **Step 3: Add the sidebar entry**

Wherever the Import Center's left sidebar lists sections (same file, probably a `List` or `VStack` iterating `ImportCenterSection.allCases`), the new `.annotations` case renders automatically because `CaseIterable` emits it. Verify ordering matches the spec: References, Annotations, Alignments, Variants, Reads, Metadata, Other.

- [ ] **Step 4: Wire `importAnnotations(from:)` in the viewmodel**

Add to `ImportCenterViewModel`:

```swift
func importAnnotations(from url: URL?) async {
    guard let url, let referenceID = selectedAnnotationReferenceID else { return }
    do {
        try await AnnotationImporter.import(url, attachedTo: referenceID, project: projectContext)
    } catch {
        presentError(error)
    }
}
```

If `AnnotationImporter` does not exist (per PR 1's parser inventory), create a minimal one that reuses existing GFF/GTF/BED parsers. The inventory flagged whether new parser code is needed; if so, add a sub-task here using existing parsers from `LungfishIO` as reference.

### Task 3.6: Build and smoke-test the UI

- [ ] **Step 1: Build the app**

Run:
```
swift build --product LungfishApp 2>&1 | tail -20
```

Expected: Build succeeds.

- [ ] **Step 2: Run the full test suite**

Run:
```
swift test 2>&1 | tail -40
```

Expected: All tests pass.

- [ ] **Step 3: Manual smoke test (optional, deferred to PR 6's verification)**

Manual smoke testing of the built UI is deferred to PR 6 when the user rebuilds a release. For PR 3's acceptance, unit-test coverage is sufficient.

### Task 3.7: Commit PR 3 and merge to main

- [ ] **Step 1: Commit**

Run:
```
git add -A
git commit -m "feat(import-center): Annotations section + FASTA fix

Adds Annotations section accepting GFF3/GTF/BED anchored to an existing
project reference. Shows helper row when project has no references yet.

Fixes the FASTA grey-out bug in References section: <one-line root-cause
summary from PR 1 notes>.

Regression tests cover eligibility for every FASTA extension and the
references-required gate for annotations.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 2: Auto-merge to main**

Run:
```
git checkout main
git pull origin main
git merge --ff-only claude/sad-morse
git push origin main
git checkout claude/sad-morse
```

---

## PR 4 — Fixture regeneration

**Goal:** `docs/user-manual/fixtures/sarscov2-clinical/` carries NC_045512.2 + matching GFF3 + BAM re-aligned to the new reference + iVar-called VCF with `ANN=`.

**Requirements (external tools on the executing machine):** `efetch` (NCBI EDirect), `bwa`, `samtools`, `bgzip`, `tabix`, `ivar` 1.4+. If any are missing, install them first:
```
# macOS via homebrew
brew install homebrew/science/efetch ncbi-edirect bwa samtools htslib ivar 2>/dev/null || \
brew install edirect bwa samtools htslib ivar
```

**Files:** all in `docs/user-manual/fixtures/sarscov2-clinical/`.

### Task 4.1: Pull NC_045512.2 reference and GFF3

- [ ] **Step 1: Back up existing fixture files**

Run:
```
cd docs/user-manual/fixtures/sarscov2-clinical
mkdir -p .backup-mt192765
cp reference.fasta reference.fasta.fai alignments.bam alignments.bam.bai variants.vcf.gz variants.vcf.gz.tbi .backup-mt192765/
```

The backup lets you revert if fetch fails partway. Delete `.backup-mt192765` after PR 4 merges.

- [ ] **Step 2: Fetch the new reference**

Run:
```
efetch -db nucleotide -id NC_045512.2 -format fasta > reference.fasta
samtools faidx reference.fasta
```

Expected: `reference.fasta` header starts with `>NC_045512.2`. `wc -l reference.fasta` ≈ 500 lines. `reference.fasta.fai` has one line with `NC_045512.2\t29903\t…`.

- [ ] **Step 3: Fetch the GFF3**

Run:
```
efetch -db nucleotide -id NC_045512.2 -format gff3 > annotations.gff3
```

Expected: `ls -l annotations.gff3` ≈ 60 KB. `head -3 annotations.gff3` shows `##gff-version 3` and `##sequence-region NC_045512.2 1 29903`.

- [ ] **Step 4: Sanity-check the GFF3 has CDS entries**

Run:
```
grep -c "^NC_045512.2" annotations.gff3
grep -c "	CDS	" annotations.gff3
```

Expected: first count > 0, second count > 10 (ORF1ab polyprotein alone has multiple CDS features).

### Task 4.2: Re-align reads to the new reference

- [ ] **Step 1: Index the reference for bwa**

Run:
```
bwa index reference.fasta
```

Expected: Creates `reference.fasta.amb`, `.ann`, `.bwt`, `.pac`, `.sa`.

- [ ] **Step 2: Align and sort**

Run:
```
bwa mem -t 4 reference.fasta reads_R1.fastq.gz reads_R2.fastq.gz 2>/dev/null \
  | samtools sort -o alignments.bam -
samtools index alignments.bam
```

Expected: `alignments.bam` created, `alignments.bam.bai` created.

- [ ] **Step 3: Verify BAM header references NC_045512.2**

Run:
```
samtools view -H alignments.bam | grep "^@SQ"
```

Expected: Output contains `SN:NC_045512.2` and `LN:29903`.

- [ ] **Step 4: Delete bwa index files (not fixture artifacts)**

Run:
```
rm reference.fasta.amb reference.fasta.ann reference.fasta.bwt reference.fasta.pac reference.fasta.sa
```

Only `reference.fasta` and `reference.fasta.fai` ship in the fixture.

### Task 4.3: Call variants with iVar

- [ ] **Step 1: Capture iVar version**

Run:
```
ivar version 2>&1 | head -5 > ivar-version.txt
cat ivar-version.txt
```

Expected: Version string (e.g., `iVar version 1.4.2`). Check version ≥ 1.4 (required for `--output-format vcf`). If version is < 1.4, upgrade iVar first.

- [ ] **Step 2: Run iVar variants with VCF output**

Run:
```
samtools mpileup \
  -aa -A -d 600000 -B -Q 20 -q 0 \
  -f reference.fasta \
  alignments.bam \
  | ivar variants \
      -p variants \
      -q 20 -t 0.0 -m 1 \
      -r reference.fasta \
      -g annotations.gff3 \
      --output-format vcf
```

Expected: Creates `variants.vcf`. `head -30 variants.vcf` shows `##fileformat=VCFv4.x`, `##source=iVar`, `##INFO=<ID=ANN,…>`, and a data row.

- [ ] **Step 3: Verify VCF has iVar header and ANN field**

Run:
```
grep -c "^##source=iVar" variants.vcf
grep -c "^##INFO=<ID=ANN" variants.vcf
grep -cE "ANN=[^;]*(missense|nonsynonymous)" variants.vcf
```

Expected: First two counts == 1 each; third count ≥ 1 (at least one nonsynonymous variant).

If third count == 0, the reads don't contain enough variation to produce a consequence-flagged variant. In that case, lower iVar's minimum-depth threshold (`-m 1` → `-m 1`, already minimum) or drop the allele-frequency threshold (`-t 0.0`, already zero). If still zero, sample a broader subset of the upstream read pool — but this is outside the plan's scope and should be escalated.

- [ ] **Step 4: Compress and index the VCF**

Run:
```
bgzip -f variants.vcf
tabix -p vcf variants.vcf.gz
```

Expected: `variants.vcf.gz` and `variants.vcf.gz.tbi` both exist. `wc -c variants.vcf.gz` ≥ 500 bytes.

### Task 4.4: Rewrite fetch.sh as provenance record

- [ ] **Step 1: Write the new fetch.sh**

Replace `fetch.sh` entirely with:

```bash
#!/usr/bin/env bash
# Provenance record for the sarscov2-clinical fixture.
#
# This script regenerates reference.fasta, reference.fasta.fai, annotations.gff3,
# and alignments.bam deterministically from NCBI. It does NOT re-run iVar;
# variants.vcf.gz was produced once by the iVar command block below and
# committed as-is.
#
# Required tools: efetch (ncbi-edirect), samtools, bwa.
# For the iVar command block (informational only): ivar 1.4+, bgzip, tabix.
set -euo pipefail

cd "$(dirname "$0")"

echo "[1/4] Fetching reference NC_045512.2 …"
efetch -db nucleotide -id NC_045512.2 -format fasta > reference.fasta
samtools faidx reference.fasta

echo "[2/4] Fetching annotations GFF3 for NC_045512.2 …"
efetch -db nucleotide -id NC_045512.2 -format gff3 > annotations.gff3

echo "[3/4] Aligning reads to NC_045512.2 …"
bwa index reference.fasta
bwa mem -t 4 reference.fasta reads_R1.fastq.gz reads_R2.fastq.gz 2>/dev/null \
  | samtools sort -o alignments.bam -
samtools index alignments.bam
rm reference.fasta.amb reference.fasta.ann reference.fasta.bwt reference.fasta.pac reference.fasta.sa

echo "[4/4] Done. variants.vcf.gz is NOT regenerated; see iVar command below."
echo ""
echo "Variants were called once with this command using iVar $(cat ivar-version.txt 2>/dev/null | head -1):"
echo ""
cat <<'IVAR_COMMAND'
# samtools mpileup \
#   -aa -A -d 600000 -B -Q 20 -q 0 \
#   -f reference.fasta \
#   alignments.bam \
#   | ivar variants \
#       -p variants \
#       -q 20 -t 0.0 -m 1 \
#       -r reference.fasta \
#       -g annotations.gff3 \
#       --output-format vcf
# bgzip -f variants.vcf
# tabix -p vcf variants.vcf.gz
IVAR_COMMAND
```

- [ ] **Step 2: Make it executable**

Run:
```
chmod +x fetch.sh
```

### Task 4.5: Update README.md

- [ ] **Step 1: Rewrite the README**

Replace `docs/user-manual/fixtures/sarscov2-clinical/README.md` with (adjusting the "What's included" list to match exactly what committed):

```markdown
# SARS-CoV-2 Clinical Isolate Fixture

Small real-world dataset for the Lungfish user manual's `04-variants` chapter.
Size: ≈85 KB total. License: MIT (nf-core/test-datasets).

## What's included

| File | Purpose |
| --- | --- |
| `reference.fasta` + `.fai` | SARS-CoV-2 Wuhan-Hu-1 reference, NCBI RefSeq accession NC_045512.2 (29,903 bp) |
| `annotations.gff3` | NCBI RefSeq GFF3 for NC_045512.2 |
| `reads_R1.fastq.gz` + `reads_R2.fastq.gz` | ≈100 paired-end short reads from a clinical isolate |
| `alignments.bam` + `.bai` | Reads aligned to NC_045512.2 with bwa mem, sorted+indexed |
| `variants.vcf.gz` + `.tbi` | Variants called with iVar `--output-format vcf`, with `ANN=` functional annotations |
| `ivar-version.txt` | iVar version that produced `variants.vcf.gz` |
| `fetch.sh` | Provenance: regenerates reference/GFF3/BAM from NCBI; documents the iVar command |

## Regenerating

Running `bash fetch.sh` re-derives `reference.fasta`, `annotations.gff3`, and `alignments.bam` byte-identically on a clean machine with `efetch`, `bwa`, and `samtools` installed. It does **not** re-run iVar; the committed `variants.vcf.gz` is the canonical artifact.

## Why NC_045512.2

NC_045512.2 is the canonical NCBI RefSeq accession for SARS-CoV-2 Wuhan-Hu-1. Its sequence is identical to the earlier GenBank accession MT192765.1 (both 29,903 bp), but RefSeq ships a standard-format GFF3 that matches the reference exactly — critical for iVar's functional annotation logic.

## iVar `ANN` field

iVar annotates each variant with `ANN=<feature_id>|<aa_change>|<consequence>` in the VCF INFO column. Example: `ANN=GU280_gp01|L2048P|missense_variant`. See chapter `04-variants/01-reading-a-vcf.md` for how to interpret these.
```

### Task 4.6: Fixture acceptance checks

- [ ] **Step 1: Verify the fixture regenerates deterministically**

Run:
```
cd docs/user-manual/fixtures/sarscov2-clinical
# Check current state
sha256sum reference.fasta annotations.gff3 alignments.bam > /tmp/before-regen.sha256
# Regenerate from scratch
rm reference.fasta reference.fasta.fai annotations.gff3 alignments.bam alignments.bam.bai
bash fetch.sh
sha256sum reference.fasta annotations.gff3 alignments.bam > /tmp/after-regen.sha256
diff /tmp/before-regen.sha256 /tmp/after-regen.sha256
```

Expected: `diff` output is empty (files are byte-identical). If `alignments.bam` differs, that's acceptable — BAM compression is non-deterministic under some samtools builds. In that case, note the known non-determinism in the README rather than failing the task.

- [ ] **Step 2: Verify VCF integrity**

Run:
```
zcat variants.vcf.gz | head -40 | grep -q "source=iVar"
zcat variants.vcf.gz | grep -cE "ANN=[^;]*(missense|nonsynonymous)" 
```

Expected: First command exits 0. Second command prints ≥ 1.

- [ ] **Step 3: Verify backup is still intact**

Run:
```
ls .backup-mt192765/
```

Expected: All original MT192765.1 files listed. Do NOT delete the backup yet — it survives until PR 4 merges.

### Task 4.7: Commit PR 4 and merge to main

- [ ] **Step 1: Remove the backup**

Only after verifying Step 2 of 4.6 passed:

```
rm -rf docs/user-manual/fixtures/sarscov2-clinical/.backup-mt192765
```

- [ ] **Step 2: Commit**

Run:
```
git add docs/user-manual/fixtures/sarscov2-clinical/
git commit -m "docs(fixtures): regenerate sarscov2-clinical against NC_045512.2 with iVar VCF

- Swap reference from MT192765.1 to canonical RefSeq NC_045512.2 (same
  29,903 bp sequence, standard GFF3 available).
- Add annotations.gff3 from NCBI RefSeq.
- Re-align reads_R{1,2}.fastq.gz against the new reference.
- Re-call variants with iVar --output-format vcf against the GFF3,
  producing variants.vcf.gz with ANN=<feature>|<aa>|<consequence>.
- Rewrite fetch.sh as a provenance record; document iVar command.
- Capture iVar version in ivar-version.txt.

The committed VCF carries at least one nonsynonymous/missense variant
for the chapter's functional-impact walkthrough.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 3: Auto-merge to main**

Run:
```
git checkout main
git pull origin main
git merge --ff-only claude/sad-morse
git push origin main
git checkout claude/sad-morse
```

---

## PR 5 — Chapter rewrite + recipe stubs + GLOSSARY + features.yaml

**Goal:** End-to-end chapter teaching the Import Center flow (reference → annotations → VCF → sample metadata), with a deep-dive on iVar `ANN` functional interpretation.

**Files:**
- Modify: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md`
- Modify: `docs/user-manual/GLOSSARY.md`
- Modify: `docs/user-manual/features.yaml`
- Create: 6 recipe stub files in `docs/user-manual/assets/recipes/04-variants/`
- Delete: `docs/user-manual/assets/recipes/04-variants/vcf-open-dialog.yaml`, `vcf-variant-table.yaml`

### Task 5.1: Extend features.yaml

- [ ] **Step 1: Read the current features.yaml**

Run:
```
cat docs/user-manual/features.yaml
```

- [ ] **Step 2: Add the new entries**

Append to `docs/user-manual/features.yaml` (keep existing entries intact, keep alphabetical ordering within each section):

```yaml
# Import Center
- id: import.center
  title: Import Center
  category: import
  surfaces:
    - menu: "File > Import Center…"
      shortcut: "⇧⌘Y"
  source_refs:
    - Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift
    - Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift
  summary: "Single import entry point for every file type. Sections: References, Annotations, Alignments, Variants, Reads, Metadata, Other."

- id: import.reference
  title: Import reference sequence
  category: import
  surfaces:
    - import_center_section: "References"
  source_refs:
    - Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift
  summary: "Import a FASTA reference (.fasta, .fa, .fna, .ffn). Creates a .lungfishref bundle anchored to the project."

- id: import.annotations
  title: Import annotation track
  category: import
  surfaces:
    - import_center_section: "Annotations"
  source_refs:
    - Sources/LungfishApp/Views/ImportCenter/AnnotationsSection.swift
    - Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift
  summary: "Import a GFF3, GTF, or BED annotation track and attach it to an existing reference sequence in the project."
  prereqs:
    - "At least one reference sequence must already be imported (via import.reference)."

- id: sample-metadata
  title: Attach sample metadata to a VCF
  category: metadata
  surfaces:
    - <set from PR 1 investigation notes; menu / inspector tab / drag target>
  source_refs:
    - <set from PR 1 investigation notes>
  summary: "Attach a CSV/TSV metadata file so the sample column in a VCF surfaces patient ID, Ct, collection date, and other fields."
```

Replace the `<set from PR 1 investigation notes>` placeholders with the concrete values recorded in PR 1's notes file. If PR 1 determined that sample-metadata UX does not exist in Lungfish, drop the `sample-metadata` entry entirely and remove it from the chapter's `features_refs` list.

- [ ] **Step 3: Validate YAML**

Run:
```
python3 -c "import yaml; yaml.safe_load(open('docs/user-manual/features.yaml'))"
```

Expected: No output (success) means YAML parses.

### Task 5.2: Extend GLOSSARY.md

- [ ] **Step 1: Read the current glossary**

Run:
```
cat docs/user-manual/GLOSSARY.md
```

- [ ] **Step 2: Append new entries in alphabetical order**

Insert into `docs/user-manual/GLOSSARY.md`:

```markdown
### Annotation track

A set of coordinate-anchored features (genes, CDS, UTRs, etc.) overlaid on a reference sequence. Common formats: GFF3, GTF, BED. Without a reference to anchor them to, annotations have no meaningful position.

### Consequence

A short label describing how a variant affects a protein-coding sequence. Common consequences: `synonymous_variant` (codon changes but amino acid stays the same), `missense_variant` / `nonsynonymous_variant` (amino acid changes), `stop_gained` (premature stop codon introduced), `stop_lost` (stop codon disrupted), `frameshift_variant` (insertion/deletion disrupts reading frame).

### GFF3

General Feature Format version 3. A tab-delimited format for describing genomic features. Each row is one feature with columns for sequence name, source, type, start, end, score, strand, phase, and a semicolon-delimited attributes column. GFF3 is the standard format NCBI RefSeq ships for annotated genomes.

### iVar

A command-line variant caller designed for viral short-read sequencing data. When given a reference FASTA and an annotation GFF3, iVar annotates each variant with its functional consequence in the VCF `INFO` column's `ANN=` field.

### Missense variant

A single-nucleotide change that causes one amino acid in a protein to be replaced by a different amino acid. Synonym: nonsynonymous variant. Contrast with synonymous variant.

### Nonsynonymous variant

See: missense variant.

### Sample metadata

Per-sample information attached alongside a VCF's sample columns — patient ID, collection date, Ct value, clinical outcome, etc. Loaded from a CSV or TSV that joins on sample names.

### Synonymous variant

A single-nucleotide change that does not alter the amino acid a codon encodes. Does not change the protein sequence. Contrast with nonsynonymous / missense variant.
```

- [ ] **Step 3: Lint the glossary**

Run:
```
node docs/user-manual/build/scripts/manual_lint.mjs docs/user-manual/GLOSSARY.md
```

Expected: Exit 0.

### Task 5.3: Replace the recipe stubs

- [ ] **Step 1: Delete old recipe files**

Run:
```
rm docs/user-manual/assets/recipes/04-variants/vcf-open-dialog.yaml
rm docs/user-manual/assets/recipes/04-variants/vcf-variant-table.yaml
```

- [ ] **Step 2: Create import-center-empty.yaml**

Create `docs/user-manual/assets/recipes/04-variants/import-center-empty.yaml`:

```yaml
id: import-center-empty
chapter: 04-variants/01-reading-a-vcf
caption: "Import Center with all sections visible, project empty."
fixtures:
  project: empty-project
window:
  size:
    width: 1600
    height: 1000
  position:
    x: 100
    y: 100
actions:
  - open_application:
      bundle_id: com.lungfish.browser
  - wait_ready: {}
  - key:
      text: "shift+cmd+y"
  - wait_ready: {}
  - screenshot: {}
annotations: []
```

- [ ] **Step 3: Create import-reference.yaml**

```yaml
id: import-reference
chapter: 04-variants/01-reading-a-vcf
caption: "References section with reference.fasta selected."
fixtures:
  project: empty-project
  files:
    - docs/user-manual/fixtures/sarscov2-clinical/reference.fasta
window:
  size:
    width: 1600
    height: 1000
  position:
    x: 100
    y: 100
actions:
  - open_application:
      bundle_id: com.lungfish.browser
  - wait_ready: {}
  - key:
      text: "shift+cmd+y"
  - wait_ready: {}
  - click_sidebar_item:
      label: "References"
  - screenshot: {}
annotations:
  - type: callout
    target: "References"
    text: "FASTA files go here"
```

- [ ] **Step 4: Create import-annotations.yaml**

```yaml
id: import-annotations
chapter: 04-variants/01-reading-a-vcf
caption: "Annotations section with annotations.gff3 picked and reference selected."
fixtures:
  project: empty-project-with-reference
  files:
    - docs/user-manual/fixtures/sarscov2-clinical/annotations.gff3
window:
  size:
    width: 1600
    height: 1000
  position:
    x: 100
    y: 100
actions:
  - open_application:
      bundle_id: com.lungfish.browser
  - wait_ready: {}
  - key:
      text: "shift+cmd+y"
  - wait_ready: {}
  - click_sidebar_item:
      label: "Annotations"
  - screenshot: {}
annotations:
  - type: callout
    target: "Attach to reference"
    text: "Choose which reference the annotations anchor to"
```

- [ ] **Step 5: Create import-vcf.yaml**

```yaml
id: import-vcf
chapter: 04-variants/01-reading-a-vcf
caption: "Variants section with variants.vcf.gz picked."
fixtures:
  project: empty-project-with-reference-and-annotations
  files:
    - docs/user-manual/fixtures/sarscov2-clinical/variants.vcf.gz
window:
  size:
    width: 1600
    height: 1000
  position:
    x: 100
    y: 100
actions:
  - open_application:
      bundle_id: com.lungfish.browser
  - wait_ready: {}
  - key:
      text: "shift+cmd+y"
  - wait_ready: {}
  - click_sidebar_item:
      label: "Variants"
  - screenshot: {}
annotations: []
```

- [ ] **Step 6: Create variant-table-with-consequences.yaml**

```yaml
id: variant-table-with-consequences
chapter: 04-variants/01-reading-a-vcf
caption: "Variant browser showing ANN consequence annotations."
fixtures:
  project: sarscov2-fully-loaded
window:
  size:
    width: 1600
    height: 1000
  position:
    x: 100
    y: 100
actions:
  - open_application:
      bundle_id: com.lungfish.browser
  - wait_ready: {}
  - open_sidebar_item:
      kind: variants
      name: "variants.vcf.gz"
  - wait_ready: {}
  - screenshot: {}
annotations:
  - type: callout
    target: "Consequence column"
    text: "missense / synonymous labels decoded from iVar's ANN= field"
```

- [ ] **Step 7: Create sample-metadata-attached.yaml**

```yaml
id: sample-metadata-attached
chapter: 04-variants/01-reading-a-vcf
caption: "Variant browser with sample metadata columns populated."
fixtures:
  project: sarscov2-with-metadata
window:
  size:
    width: 1600
    height: 1000
  position:
    x: 100
    y: 100
actions:
  - open_application:
      bundle_id: com.lungfish.browser
  - wait_ready: {}
  - open_sidebar_item:
      kind: variants
      name: "variants.vcf.gz"
  - wait_ready: {}
  - screenshot: {}
annotations:
  - type: callout
    target: "Patient ID"
    text: "Sample metadata CSV surfaces here"
```

If PR 1 found no sample-metadata UX, delete this recipe and remove the shot from the chapter's frontmatter.

- [ ] **Step 8: Validate recipes**

Run:
```
bash docs/user-manual/build/scripts/run-shot.sh plan docs/user-manual/assets/recipes/04-variants/import-center-empty.yaml
```

Expected: Planner validates the recipe schema (does not actually run Computer Use — PR 6 does that). If the `run-shot.sh plan` subcommand doesn't exist, the PR 1 investigation should have flagged it; fall back to a `yq` YAML-parse check.

### Task 5.4: Write the chapter

- [ ] **Step 1: Read existing chapter (for structural reference)**

Run:
```
cat docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```

- [ ] **Step 2: Rewrite the chapter wholesale**

Replace `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` with:

```markdown
---
title: Reading a VCF file
chapter_id: 04-variants/01-reading-a-vcf
audience: bench-scientist
prereqs: []
estimated_reading_min: 15
shots:
  - id: import-center-empty
    caption: "Import Center with all sections visible, project empty."
  - id: import-reference
    caption: "References section with reference.fasta selected."
  - id: import-annotations
    caption: "Annotations section with annotations.gff3 picked and reference chosen."
  - id: import-vcf
    caption: "Variants section with variants.vcf.gz picked."
  - id: variant-table-with-consequences
    caption: "Variant browser showing ANN consequence annotations."
  - id: sample-metadata-attached
    caption: "Variant browser with sample metadata columns populated."
glossary_refs: [VCF, REF, ALT, genotype, allele-frequency, GFF3, annotation-track, synonymous, nonsynonymous, missense, consequence, sample-metadata, iVar]
features_refs: [import.center, import.reference, import.annotations, import.vcf, viewport.variant-browser, sample-metadata]
fixtures_refs: [sarscov2-clinical]
brand_reviewed: false
lead_approved: false
---

# Reading a VCF file

## What it is

A VCF (Variant Call Format) file lists positions in a genome where your reads differ from a reference sequence. Each row is one variant: a position, the reference base, the observed variant base, quality metrics, filters, and per-sample genotype.

When the variant caller also has access to an annotation track, each row carries a `consequence` label — does this change swap one amino acid for another, or leave the protein unchanged? The `iVar` variant caller writes these consequences directly into the VCF's `ANN=` field.

<!-- SHOT: import-center-empty -->

## Why this matters

A raw VCF tells you where mutations are. A consequence-annotated VCF tells you which mutations might matter. In viral genomics, a single missense variant in a receptor-binding domain can mean the difference between a variant that spreads and one that doesn't. This chapter walks you from zero to a fully annotated variant table you can browse, filter, and interpret.

## Procedure

You'll need four files from the fixture bundled with the manual:

1. `reference.fasta` — the NC_045512.2 SARS-CoV-2 reference.
2. `annotations.gff3` — the matching NCBI RefSeq annotation track.
3. `variants.vcf.gz` — iVar-called variants with `ANN=` consequences.
4. (Optional) `samples.csv` — sample metadata to join on the VCF's sample columns.

### 1. Open Import Center

Press ⇧⌘Y, or pick **File > Import Center…** from the menu bar. Import Center is the single door for every file type in Lungfish.

<!-- SHOT: import-center-empty -->

### 2. Import the reference

Click **References** in the sidebar. Click **Choose file…** and pick `reference.fasta`. Click **Import**. Lungfish creates a `.lungfishref` bundle in your project's `Reference Sequences/` folder.

<!-- SHOT: import-reference -->

### 3. Import the annotation track

Click **Annotations** in the sidebar. Click **Choose file…** and pick `annotations.gff3`. From the **Attach to reference** dropdown, select the reference you just imported. Click **Import**. The annotation track is now anchored to the reference.

<!-- SHOT: import-annotations -->

If the Annotations sidebar shows "Import a reference first", step 2 didn't complete. Go back, import the reference, and return here.

### 4. Import the VCF

Click **Variants** in the sidebar. Click **Choose file…** and pick `variants.vcf.gz`. Click **Import**.

<!-- SHOT: import-vcf -->

The variant browser opens on the first record.

### 5. (Optional) Attach sample metadata

<!-- TODO: This section is written against the sample-metadata UX recorded in PR 1's investigation notes. Adjust entry-point wording accordingly before submitting for review. -->

Right-click the VCF entry in the project sidebar and pick **Attach sample metadata…**. Pick your CSV or TSV. Lungfish joins on the VCF's sample column name and surfaces your fields (patient ID, Ct, collection date, etc.) alongside the variant data.

<!-- SHOT: sample-metadata-attached -->

## Interpreting what you see

### Reading the table

Each variant row shows:

- **POS** — 1-based position on the reference.
- **REF / ALT** — reference base vs. observed alternate.
- **QUAL** — Phred-scaled call confidence.
- **FILTER** — `PASS` if iVar's thresholds were met; otherwise a named filter.
- **Genotype (GT)** — per-sample call.
- **Consequence** — decoded from iVar's `ANN=` field (see below).

### Functional impact via iVar's ANN field

iVar writes one `ANN=` attribute per variant in the VCF `INFO` column. Its format is:

```
ANN=<feature_id>|<amino_acid_change>|<consequence>
```

Example: `ANN=GU280_gp01|L2048P|missense_variant` means "in feature GU280_gp01, codon 2048 changes from Leucine to Proline; this is a missense (nonsynonymous) variant."

The consequence labels you'll see most:

- `synonymous_variant` — codon changed, amino acid didn't. No protein-level effect.
- `missense_variant` — one amino acid swapped for another. Synonym: `nonsynonymous_variant`. Potentially functionally significant.
- `stop_gained` — a premature stop codon appeared. Often truncates the protein.

Note that iVar's `ANN` encoding is lighter-weight than SnpEff's or VEP's `ANN` encoding. If you've worked with SnpEff before, don't expect the same field order or level of detail — iVar's is deliberately compact.

<!-- SHOT: variant-table-with-consequences -->

### Using sample metadata

Once metadata is attached, the variant table gains columns for every field in your CSV/TSV. You can sort and filter on them like any other column. For a cohort of 50 patients, this is how you answer "which variants are Ct-correlated?" or "which variants show up only in the immunocompromised subgroup?"

## Next steps

- To call variants yourself (instead of importing a pre-called VCF), see `04-variants/02-calling-variants.md` (coming soon).
- To visualize variants against the reference in the genome browser, click any variant row to jump to its genomic context.
- To export filtered variants to CSV for downstream analysis, use **File > Export Table…**.
```

- [ ] **Step 3: Lint the chapter**

Run:
```
node docs/user-manual/build/scripts/manual_lint.mjs docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
```

Expected: Exit 0. Common lint hits and fixes:
- Em dashes: replace every `—` with ` - ` or restructure the sentence.
- Too many bullets per H2: check bullet cap (5 items / 2 lists per H2). Break long lists into sub-sections.

### Task 5.5: Prune shots based on the prose

- [ ] **Step 1: Re-read the chapter with fresh eyes**

Open the rewritten chapter and, for each `<!-- SHOT: … -->` marker, ask: *Does removing this image degrade the reader's ability to follow the step?* If the answer is no, delete:
1. The `<!-- SHOT: id -->` marker in the prose.
2. The corresponding entry in the frontmatter `shots:` list.
3. The recipe YAML file.

Typical pruning outcome: drop 1-3 of the 6 shots. The ones most likely to survive: `import-center-empty`, `import-annotations`, `variant-table-with-consequences`. The ones most likely to prune: `import-reference` and `import-vcf` if the prose steps are self-evident, `sample-metadata-attached` if Section 3.5 became a pointer.

- [ ] **Step 2: Commit the prune separately**

After pruning, commit separately from the rewrite so the review can evaluate the prune decisions:

```
git add docs/user-manual/chapters/04-variants/01-reading-a-vcf.md docs/user-manual/assets/recipes/04-variants/
git commit -m "docs(chapter): prune shots not strictly needed by prose

Dropped <N> shots whose removal did not degrade the reader's ability to
follow the step. Kept <N> shots.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 5.6: Full chapter lint + features/glossary cross-check

- [ ] **Step 1: Run the full lint**

Run:
```
node docs/user-manual/build/scripts/manual_lint.mjs docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
node docs/user-manual/build/scripts/manual_lint.mjs docs/user-manual/GLOSSARY.md
```

Expected: Both exit 0.

- [ ] **Step 2: Check that every glossary_ref in the chapter exists in GLOSSARY.md**

Run:
```
python3 <<'PY'
import yaml, re, pathlib
md = pathlib.Path("docs/user-manual/chapters/04-variants/01-reading-a-vcf.md").read_text()
m = re.search(r"^---\n(.*?)\n---", md, re.S)
fm = yaml.safe_load(m.group(1))
glossary = pathlib.Path("docs/user-manual/GLOSSARY.md").read_text()
missing = [r for r in fm.get("glossary_refs", []) if f"### {r}" not in glossary and f"### {r.replace('-', ' ').title()}" not in glossary.lower().replace('-', ' ')]
if missing:
    print("MISSING:", missing)
else:
    print("OK")
PY
```

Expected: Prints `OK`. If missing terms are listed, either add them to GLOSSARY.md or remove them from `glossary_refs`.

- [ ] **Step 3: Same check for features_refs**

Run:
```
python3 <<'PY'
import yaml, re, pathlib
md = pathlib.Path("docs/user-manual/chapters/04-variants/01-reading-a-vcf.md").read_text()
m = re.search(r"^---\n(.*?)\n---", md, re.S)
fm = yaml.safe_load(m.group(1))
features = yaml.safe_load(pathlib.Path("docs/user-manual/features.yaml").read_text())
ids = {f["id"] for f in features}
missing = [r for r in fm.get("features_refs", []) if r not in ids]
if missing:
    print("MISSING:", missing)
else:
    print("OK")
PY
```

Expected: Prints `OK`.

### Task 5.7: Commit PR 5 and merge to main

- [ ] **Step 1: Stage everything**

Run:
```
git add docs/user-manual/
git status --short
```

- [ ] **Step 2: Commit**

Run:
```
git commit -m "docs(chapter): rewrite 04-variants/01-reading-a-vcf end-to-end

Teaches the Import Center flow (reference → annotations → VCF →
sample metadata), with a deep dive on iVar's ANN= functional
consequence field (synonymous / missense / nonsynonymous).

Extends GLOSSARY.md with iVar-relevant terms and features.yaml with
import.center, import.reference, import.annotations, sample-metadata.

Replaces the earlier 2-shot stub with 3-6 recipe stubs (pruned during
prose revision); shot PNGs land in PR 6.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 3: Auto-merge to main**

Run:
```
git checkout main
git pull origin main
git merge --ff-only claude/sad-morse
git push origin main
git checkout claude/sad-morse
```

### Task 5.8: Halt before PR 6 — user rebuild gate

- [ ] **Step 1: Tell the user**

Print to the session:

> PRs 1-5 are merged to main. Before PR 6 captures shots, please rebuild the release app from main:
>
> ```
> git checkout main
> git pull origin main
> bash scripts/release/build-notarized-dmg.sh
> ```
>
> Launch the rebuilt app and confirm: (a) File > Import Center… is the only import entry, (b) References section imports `reference.fasta` cleanly, (c) Annotations section appears and imports `annotations.gff3` anchored to the reference.
>
> Reply when the rebuild is ready and verified. PR 6 resumes from there.

- [ ] **Step 2: Wait for user confirmation**

Do not proceed to PR 6 until the user replies with confirmation of rebuild success.

---

## PR 6 — Shot capture + compositing

**Goal:** Every recipe that survived the prune has a final PNG. Chapter sets `brand_reviewed: true` and `lead_approved: true`.

**Prerequisites:** User has rebuilt the release app from main and confirmed PRs 2-3 are functioning.

**Files:**
- Create: `docs/user-manual/assets/shots/04-variants/*.png` (one per recipe)
- Modify: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` (flip the two `brand_reviewed` / `lead_approved` flags after reviews pass)

### Task 6.1: Verify rebuild

- [ ] **Step 1: Confirm the rebuilt app is in `/Applications/Lungfish.app` or `.build/release/LungfishApp.app`**

Run:
```
ls -la /Applications/Lungfish.app 2>/dev/null || ls -la .build/release/LungfishApp.app 2>/dev/null
```

- [ ] **Step 2: Get computer-use access**

Call `request_access` with `com.lungfish.browser` and a short description.

- [ ] **Step 3: Size the app window to 1600×1000 logical points**

Use the `defaults write` approach (AppleScript fails with assistive-access-denied):

```
defaults write com.lungfish.browser "NSWindow Frame MainWindow" "100 670 1600 1000 0 0 3200 1770 "
osascript -e 'tell application "Lungfish" to quit'
open -a Lungfish
```

Wait for the app to launch. Take a screenshot to verify size.

### Task 6.2: Capture each surviving recipe

- [ ] **Step 1: For each recipe YAML in `docs/user-manual/assets/recipes/04-variants/`:**

Follow the recipe's `actions` list step-by-step via `mcp__computer-use__*` calls. The runner is manual here — PR 6 doesn't rely on the `run-shot.sh` script, which hasn't been built yet for the full action set.

- [ ] **Step 2: Save each screenshot to the matching path**

Screenshot path convention: `docs/user-manual/assets/shots/04-variants/<recipe-id>.png`. Example: `import-center-empty.png`.

- [ ] **Step 3: Apply annotations from the recipe**

If the recipe's `annotations:` field lists callouts, composite them onto the PNG post-capture. Use ImageMagick or a small Python script with Pillow. The existing documentation pipeline may already have a compositor — check `docs/user-manual/build/scripts/` for `annotate.mjs` or similar.

### Task 6.3: Review gate

- [ ] **Step 1: Dispatch the brand-copy-editor sub-agent**

Dispatch the `brand-copy-editor` subagent over the chapter file. If it passes (no structural rewrites, only voice/palette polish), set `brand_reviewed: true` in the frontmatter.

- [ ] **Step 2: Dispatch the documentation-lead sub-agent for Gate 2**

Dispatch the `documentation-lead` subagent over the chapter. If approved, set `lead_approved: true` in the frontmatter.

- [ ] **Step 3: Run the full MkDocs build**

Run:
```
cd docs/user-manual
mkdocs build --strict 2>&1 | tail -30
```

Expected: Build succeeds with no warnings. If strict mode flags a missing shot or broken link, fix and re-run.

### Task 6.4: Commit PR 6 and merge to main

- [ ] **Step 1: Commit**

Run:
```
git add docs/user-manual/
git commit -m "docs(shots): capture final shots for 04-variants/01-reading-a-vcf

Drives Computer Use against the rebuilt release app to capture screenshots
per recipe YAML, composites callout annotations, and flips the chapter's
brand_reviewed and lead_approved flags after review sub-agents pass.

MkDocs --strict build is clean.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 2: Auto-merge to main**

Run:
```
git checkout main
git pull origin main
git merge --ff-only claude/sad-morse
git push origin main
git checkout claude/sad-morse
```

- [ ] **Step 3: Report completion to the user**

Print a summary:

> All six PRs merged to main. Chapter 04-variants/01-reading-a-vcf is complete, lint-green, and brand-approved. Final artifacts:
> - Spec: `docs/superpowers/specs/2026-04-15-ivar-annotations-import-center-design.md`
> - Plan: `docs/superpowers/plans/2026-04-15-ivar-annotations-import-center-plan.md`
> - Investigation notes: `docs/superpowers/notes/2026-04-15-ivar-annotations-import-center-investigation.md`
> - Chapter: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md`
> - Fixture: `docs/user-manual/fixtures/sarscov2-clinical/` (NC_045512.2 + iVar VCF)
> - Swift changes: MainMenu.swift (Import submenu removed), ImportCenterView/ViewModel.swift + AnnotationsSection.swift (new section + FASTA fix)

---

## Self-review checklist

**Spec coverage:**

| Spec section | Addressed by |
| --- | --- |
| 2.B1 Remove File > Import submenu | PR 2 |
| 2.B2 Add Annotations section | PR 3 Tasks 3.3-3.5 |
| 2.B3 Fix FASTA grey-out | PR 3 Tasks 3.1-3.2 |
| 3.C1 Swap reference to NC_045512.2 | PR 4 Task 4.1 |
| 3.C2 Regenerate alignments.bam | PR 4 Task 4.2 |
| 3.C3 Add annotations.gff3 | PR 4 Task 4.1 (bundled with reference fetch) |
| 3.C4 Re-call variants with iVar | PR 4 Task 4.3 |
| 3.C5 Update fetch.sh + README.md | PR 4 Tasks 4.4-4.5 |
| 4 Chapter rewrite | PR 5 Task 5.4 |
| 4 GLOSSARY extension | PR 5 Task 5.2 |
| 4 features.yaml extension | PR 5 Task 5.1 |
| 4 Shot pruning rule | PR 5 Task 5.5 |
| 5 Phase ordering & auto-merge | Every PR has an auto-merge step |
| 6 Success criteria | Lint + test steps in each PR |
| PR 1 investigation | PR 1 Tasks 1.1-1.5 |

**Placeholder scan:** Searched for "TBD", "TODO", "fill in" — only remaining placeholder is in Task 5.1 Step 2's `<set from PR 1 investigation notes>` markers, which is intentional (the plan explicitly forwards these to PR 1's output). Also one "TODO" comment in the chapter's section 3.5 prose, which is intentional (it reminds the executing agent to adjust the wording to match PR 1's UX findings).

**Type consistency:** `ImportCenterSection` enum case is `.annotations` throughout. `isEligible(_:for:)` signature is consistent across Tasks 3.1, 3.3, 3.4. `referencesInProject`, `selectedAnnotationReferenceID`, `canStartAnnotationsImport`, `annotationsHelperText` match between the tests in Task 3.3 and the viewmodel code in Task 3.4.

**Scope:** Plan is one spec → six PRs. No sub-project decomposition needed.

---

## Execution handoff

This plan is designed for `superpowers:subagent-driven-development` with auto-merge between PRs (no human approval gate). The hand-off prompt for the next session is in the brainstorming session's output — paste it into a fresh Claude Code session rooted at the `sad-morse` worktree.

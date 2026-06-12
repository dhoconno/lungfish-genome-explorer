# Folder Sidebar Workflow Batch Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Workflow Operations treat selected sidebar folders as batch shortcuts for eligible `.lungfishfastq` bundles while keeping workflow launch requests concrete and reproducible.

**Architecture:** Add a focused resolver that expands selected `SidebarItem` values into direct and recursive FASTQ bundle URL sets, with summary metadata for the dialog. Wire that resolver through `AppDelegate.showWorkflowOperations`, `WorkflowOperationsWindowController`, and `WorkflowOperationDialogState`, then render the summary and subfolder checkbox in `WorkflowOperationsDialog`. Built-in workflows receive all resolved bundle URLs; imported workflow packages are disabled for multi-read folder batches because their current parameter mapping accepts only one read bundle.

**Tech Stack:** Swift 6, AppKit, SwiftUI, XCTest, Swift Package Manager, existing `LungfishApp`, `LungfishIO`, and `LungfishWorkflow` modules.

---

## File Structure

- Create `Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift`
  - Owns pure selection resolution from sidebar items to concrete workflow read bundle URLs.
  - Provides summary text and detail rows for the Workflow Operations dialog.
- Modify `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift`
  - Builds a `WorkflowSidebarInputSelection` from `sidebarController.selectedItems()` for Workflow Operations.
  - Keeps existing static URL-only resolver methods for older tests and callers.
- Modify `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsWindowController.swift`
  - Accepts and forwards the optional selection model.
- Modify `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
  - Stores the selection model, toggles direct vs recursive folder expansion, updates `selectedReadURLs`, and exposes summary/readiness properties.
- Modify `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift`
  - Renders resolved-input summary text, duplicate/empty-folder messages, details, and `Include subfolders`.
- Modify `Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift`
  - Adds resolver tests using lightweight `SidebarItem` trees.
- Modify `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`
  - Adds state/toggle/package/run-request tests.

## Task 1: Add Pure Sidebar Folder Resolver

**Files:**
- Create: `Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift`
- Test: `Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift`

- [ ] **Step 1: Write failing resolver tests**

Append these tests to `Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift` inside `SidebarViewControllerSelectionTests`:

```swift
    func testWorkflowInputSelectionExpandsDirectFolderFASTQBundlesOnly() {
        let folderURL = URL(fileURLWithPath: "/tmp/project/Runs", isDirectory: true)
        let first = folderURL.appendingPathComponent("A.lungfishfastq", isDirectory: true)
        let second = folderURL.appendingPathComponent("B.lungfishfastq", isDirectory: true)
        let nested = folderURL
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("C.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(title: "A", type: .fastqBundle, url: first),
                SidebarItem(title: "B", type: .fastqBundle, url: second),
                SidebarItem(
                    title: "Nested",
                    type: .folder,
                    children: [
                        SidebarItem(title: "C", type: .fastqBundle, url: nested),
                    ],
                    url: folderURL.appendingPathComponent("Nested", isDirectory: true)
                ),
            ],
            url: folderURL
        )

        let selection = WorkflowSidebarInputSelection.resolve(items: [folder], projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true))

        XCTAssertEqual(selection.directReadURLs, [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(selection.recursiveReadURLs, [first.standardizedFileURL, second.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertEqual(selection.selectedReadURLs(includeSubfolders: false), [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(selection.selectedReadURLs(includeSubfolders: true), [first.standardizedFileURL, second.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertEqual(selection.folderSelectionCount, 1)
        XCTAssertEqual(selection.additionalDescendantBundleCount, 1)
        XCTAssertTrue(selection.hasAdditionalDescendantBundles)
        XCTAssertEqual(selection.summaryText(includeSubfolders: false), "Folder \"Runs\" expands to 2 eligible FASTQ bundles.")
    }

    func testWorkflowInputSelectionCombinesMultipleFoldersAsOneDeduplicatedBatch() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let shared = projectURL.appendingPathComponent("A.lungfishfastq", isDirectory: true)
        let unique = projectURL.appendingPathComponent("B.lungfishfastq", isDirectory: true)
        let runs = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(title: "A", type: .fastqBundle, url: shared),
                SidebarItem(title: "B", type: .fastqBundle, url: unique),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )
        let selectedAgain = SidebarItem(title: "A", type: .fastqBundle, url: shared)

        let selection = WorkflowSidebarInputSelection.resolve(items: [runs, selectedAgain], projectURL: projectURL)

        XCTAssertEqual(selection.directReadURLs, [shared.standardizedFileURL, unique.standardizedFileURL])
        XCTAssertEqual(selection.explicitBundleCount, 1)
        XCTAssertEqual(selection.folderSelectionCount, 1)
        XCTAssertEqual(selection.selectedFolderNames, ["Runs"])
        XCTAssertEqual(selection.duplicateBundleCount, 1)
        XCTAssertEqual(selection.duplicateSummaryText, "Skipped 1 duplicate bundle already included by another selected item.")
        XCTAssertEqual(selection.summaryText(includeSubfolders: false), "2 FASTQ bundles selected from 1 folder and 1 explicit bundle.")
    }

    func testWorkflowInputSelectionDoesNotRecurseIntoFASTQBundleChildren() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let top = projectURL.appendingPathComponent("Top.lungfishfastq", isDirectory: true)
        let demuxChild = top
            .appendingPathComponent("demux", isDirectory: true)
            .appendingPathComponent("Barcode01.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(
                    title: "Top",
                    type: .fastqBundle,
                    children: [
                        SidebarItem(title: "Barcode01", type: .fastqBundle, url: demuxChild),
                    ],
                    url: top
                ),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )

        let selection = WorkflowSidebarInputSelection.resolve(items: [folder], projectURL: projectURL)

        XCTAssertEqual(selection.directReadURLs, [top.standardizedFileURL])
        XCTAssertEqual(selection.recursiveReadURLs, [top.standardizedFileURL])
        XCTAssertEqual(selection.additionalDescendantBundleCount, 0)
    }

    func testWorkflowInputSelectionReportsEmptyFolderWithSubfolderBundles() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let nestedBundle = projectURL
            .appendingPathComponent("Runs/Nested/C.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(
                    title: "Nested",
                    type: .folder,
                    children: [
                        SidebarItem(title: "C", type: .fastqBundle, url: nestedBundle),
                    ],
                    url: projectURL.appendingPathComponent("Runs/Nested", isDirectory: true)
                ),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )

        let selection = WorkflowSidebarInputSelection.resolve(items: [folder], projectURL: projectURL)

        XCTAssertTrue(selection.directReadURLs.isEmpty)
        XCTAssertEqual(selection.recursiveReadURLs, [nestedBundle.standardizedFileURL])
        XCTAssertEqual(selection.emptyFolderSummaryText, "No eligible FASTQ bundles were found directly in \"Runs\".")
        XCTAssertEqual(selection.subfolderSummaryText, "Subfolders contain 1 additional eligible FASTQ bundle.")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter SidebarViewControllerSelectionTests/testWorkflowInputSelection
```

Expected: FAIL to compile with `cannot find 'WorkflowSidebarInputSelection' in scope`.

- [ ] **Step 3: Implement the resolver**

Create `Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift`:

```swift
import Foundation

struct WorkflowSidebarInputSelection: Equatable {
    struct DetailRow: Equatable {
        let url: URL
        let displayPath: String
    }

    let directReadURLs: [URL]
    let recursiveReadURLs: [URL]
    let detailRows: [DetailRow]
    let folderSelectionCount: Int
    let explicitBundleCount: Int
    let duplicateBundleCount: Int
    let skippedItemCount: Int
    let selectedFolderNames: [String]
    let emptyFolderNames: [String]
    let additionalDescendantBundleCount: Int

    var hasAdditionalDescendantBundles: Bool {
        additionalDescendantBundleCount > 0
    }

    var duplicateSummaryText: String? {
        guard duplicateBundleCount > 0 else { return nil }
        let noun = duplicateBundleCount == 1 ? "bundle" : "bundles"
        return "Skipped \(duplicateBundleCount) duplicate \(noun) already included by another selected item."
    }

    var emptyFolderSummaryText: String? {
        guard let first = emptyFolderNames.first else { return nil }
        if emptyFolderNames.count == 1 {
            return "No eligible FASTQ bundles were found directly in \"\(first)\"."
        }
        return "No eligible FASTQ bundles were found directly in \(emptyFolderNames.count) selected folders."
    }

    var subfolderSummaryText: String? {
        guard additionalDescendantBundleCount > 0 else { return nil }
        let noun = additionalDescendantBundleCount == 1 ? "bundle" : "bundles"
        return "Subfolders contain \(additionalDescendantBundleCount) additional eligible FASTQ \(noun)."
    }

    func selectedReadURLs(includeSubfolders: Bool) -> [URL] {
        includeSubfolders ? recursiveReadURLs : directReadURLs
    }

    func summaryText(includeSubfolders: Bool) -> String {
        let count = selectedReadURLs(includeSubfolders: includeSubfolders).count
        let bundleNoun = count == 1 ? "bundle" : "bundles"
        if folderSelectionCount == 1, explicitBundleCount == 0 {
            let selectedCount = includeSubfolders ? recursiveReadURLs.count : directReadURLs.count
            if selectedCount == 0, let emptyFolderSummaryText {
                return emptyFolderSummaryText
            }
            let folderLabel = selectedFolderNames.first ?? "selected folder"
            return "Folder \"\(folderLabel)\" expands to \(selectedCount) eligible FASTQ \(bundleNoun)."
        }
        if folderSelectionCount > 1, explicitBundleCount == 0 {
            return "\(folderSelectionCount) folders selected: \(count) eligible FASTQ \(bundleNoun). They will run as one batch."
        }
        if folderSelectionCount > 0 {
            let folderNoun = folderSelectionCount == 1 ? "folder" : "folders"
            let explicitNoun = explicitBundleCount == 1 ? "explicit bundle" : "explicit bundles"
            return "\(count) FASTQ \(bundleNoun) selected from \(folderSelectionCount) \(folderNoun) and \(explicitBundleCount) \(explicitNoun)."
        }
        return count == 0 ? "No read bundles selected" : "\(count) FASTQ \(bundleNoun) selected."
    }

    static func resolve(items: [SidebarItem], projectURL: URL?) -> WorkflowSidebarInputSelection {
        var directURLs: [URL] = []
        var recursiveURLs: [URL] = []
        var detailRows: [DetailRow] = []
        var directSeen = Set<String>()
        var recursiveSeen = Set<String>()
        var duplicateCount = 0
        var skippedCount = 0
        var folderCount = 0
        var folderNames: [String] = []
        var explicitCount = 0
        var emptyFolders: [String] = []
        var additionalDescendantCount = 0

        func appendDirect(_ url: URL) {
            let standardized = url.standardizedFileURL
            if directSeen.insert(standardized.path).inserted {
                directURLs.append(standardized)
            } else {
                duplicateCount += 1
            }
        }

        func appendRecursive(_ url: URL) {
            let standardized = url.standardizedFileURL
            if recursiveSeen.insert(standardized.path).inserted {
                recursiveURLs.append(standardized)
                detailRows.append(
                    DetailRow(
                        url: standardized,
                        displayPath: WorkflowSidebarInputSelection.displayPath(for: standardized, relativeTo: projectURL)
                    )
                )
            }
        }

        for item in items {
            guard item.type != .group else {
                skippedCount += 1
                continue
            }

            if isFASTQBundle(item) {
                if let url = item.url {
                    explicitCount += 1
                    appendDirect(url)
                    appendRecursive(url)
                }
                continue
            }

            if item.type == .folder || item.type == .project {
                folderCount += 1
                folderNames.append(item.title)
                let directChildren = directFASTQBundleChildren(of: item)
                if directChildren.isEmpty {
                    emptyFolders.append(item.title)
                }
                for child in directChildren {
                    if let url = child.url {
                        appendDirect(url)
                        appendRecursive(url)
                    }
                }

                let recursiveChildren = recursiveFASTQBundleChildren(of: item)
                let directPaths = Set(directChildren.compactMap { $0.url?.standardizedFileURL.path })
                for child in recursiveChildren {
                    guard let url = child.url else { continue }
                    if !directPaths.contains(url.standardizedFileURL.path) {
                        additionalDescendantCount += 1
                    }
                    appendRecursive(url)
                }
                continue
            }

            if let url = item.url,
               let bundleURL = AppDelegate.resolveWorkflowOperationReadInputURL(from: url) {
                explicitCount += 1
                appendDirect(bundleURL)
                appendRecursive(bundleURL)
            } else {
                skippedCount += 1
            }
        }

        return WorkflowSidebarInputSelection(
            directReadURLs: directURLs,
            recursiveReadURLs: recursiveURLs,
            detailRows: detailRows,
            folderSelectionCount: folderCount,
            explicitBundleCount: explicitCount,
            duplicateBundleCount: duplicateCount,
            skippedItemCount: skippedCount,
            selectedFolderNames: folderNames,
            emptyFolderNames: emptyFolders,
            additionalDescendantBundleCount: additionalDescendantCount
        )
    }

    private static func isFASTQBundle(_ item: SidebarItem) -> Bool {
        item.type == .fastqBundle
            || item.url.map { AppDelegate.resolveWorkflowOperationReadInputURL(from: $0) != nil } == true
    }

    private static func directFASTQBundleChildren(of item: SidebarItem) -> [SidebarItem] {
        item.children.filter { isFASTQBundle($0) }
    }

    private static func recursiveFASTQBundleChildren(of item: SidebarItem) -> [SidebarItem] {
        var result: [SidebarItem] = []
        func visit(_ current: SidebarItem) {
            for child in current.children {
                if isFASTQBundle(child) {
                    result.append(child)
                    continue
                }
                if child.type == .folder || child.type == .project {
                    visit(child)
                }
            }
        }
        visit(item)
        return result
    }

    private static func displayPath(for url: URL, relativeTo projectURL: URL?) -> String {
        guard let projectURL else { return url.lastPathComponent }
        let projectPath = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == projectPath || path.hasPrefix(projectPath + "/") else {
            return url.lastPathComponent
        }
        let relative = String(path.dropFirst(projectPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? url.lastPathComponent : relative
    }
}
```

- [ ] **Step 4: Run tests and fix compile/detail issues**

Run:

```bash
swift test --filter SidebarViewControllerSelectionTests/testWorkflowInputSelection
```

Expected: PASS.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift
git commit -m "feat: resolve workflow inputs from sidebar folders"
```

## Task 2: Wire Folder Selection Through Workflow Operations State

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsWindowController.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`

- [ ] **Step 1: Write failing state tests**

Append these tests to `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift` inside `WorkflowOperationDialogStateTests`:

```swift
    func testWorkflowOperationDialogStateUsesDirectFolderSelectionByDefaultAndCanIncludeSubfolders() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let direct = projectURL.appendingPathComponent("Runs/A.lungfishfastq", isDirectory: true)
        let nested = projectURL.appendingPathComponent("Runs/Nested/B.lungfishfastq", isDirectory: true)
        let selection = WorkflowSidebarInputSelection(
            directReadURLs: [direct.standardizedFileURL],
            recursiveReadURLs: [direct.standardizedFileURL, nested.standardizedFileURL],
            detailRows: [
                .init(url: direct.standardizedFileURL, displayPath: "Runs/A.lungfishfastq"),
                .init(url: nested.standardizedFileURL, displayPath: "Runs/Nested/B.lungfishfastq"),
            ],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["Runs"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 1
        )

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: [],
            sidebarInputSelection: selection
        )

        XCTAssertEqual(state.selectedReadURLs, [direct.standardizedFileURL])
        XCTAssertFalse(state.includeSubfolderBundles)
        XCTAssertEqual(state.selectedReadsDisplay, "Folder \"Runs\" expands to 1 eligible FASTQ bundle.")
        XCTAssertEqual(state.folderSubfolderNoticeText, "Subfolders contain 1 additional eligible FASTQ bundle.")

        state.setIncludeSubfolderBundles(true)

        XCTAssertEqual(state.selectedReadURLs, [direct.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertTrue(state.includeSubfolderBundles)
        XCTAssertEqual(state.selectedReadsDisplay, "Folder \"Runs\" expands to 2 eligible FASTQ bundles.")
    }

    func testWorkflowOperationDialogConfigureProjectReplacesSidebarInputSelection() {
        let firstProject = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
        let secondProject = URL(fileURLWithPath: "/tmp/second", isDirectory: true)
        let first = firstProject.appendingPathComponent("A.lungfishfastq", isDirectory: true)
        let second = secondProject.appendingPathComponent("B.lungfishfastq", isDirectory: true)
        let firstSelection = WorkflowSidebarInputSelection(
            directReadURLs: [first.standardizedFileURL],
            recursiveReadURLs: [first.standardizedFileURL],
            detailRows: [.init(url: first.standardizedFileURL, displayPath: "A.lungfishfastq")],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["first"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 0
        )
        let secondSelection = WorkflowSidebarInputSelection(
            directReadURLs: [second.standardizedFileURL],
            recursiveReadURLs: [second.standardizedFileURL],
            detailRows: [.init(url: second.standardizedFileURL, displayPath: "B.lungfishfastq")],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["second"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 0
        )

        let state = WorkflowOperationDialogState(
            projectURL: firstProject,
            selectedReadURLs: [],
            sidebarInputSelection: firstSelection
        )

        state.configureProject(
            projectURL: secondProject,
            selectedReadURLs: [],
            sidebarInputSelection: secondSelection
        )

        XCTAssertEqual(state.selectedReadURLs, [second.standardizedFileURL])
        XCTAssertEqual(state.selectedReadsDisplay, "Folder \"second\" expands to 1 eligible FASTQ bundle.")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter 'WorkflowOperationDialogStateTests/testWorkflowOperationDialogStateUsesDirectFolderSelectionByDefaultAndCanIncludeSubfolders|WorkflowOperationDialogStateTests/testWorkflowOperationDialogConfigureProjectReplacesSidebarInputSelection'
```

Expected: FAIL to compile because `sidebarInputSelection`, `includeSubfolderBundles`, `setIncludeSubfolderBundles`, and `folderSubfolderNoticeText` do not exist.

- [ ] **Step 3: Add state properties and initializer/configure wiring**

Modify `WorkflowOperationDialogState`:

```swift
    var selectedReadURLs: [URL]
    var sidebarInputSelection: WorkflowSidebarInputSelection?
    var includeSubfolderBundles: Bool
```

Change the initializer signature:

```swift
        projectURL: URL?,
        selectedReadURLs: [URL] = [],
        sidebarInputSelection: WorkflowSidebarInputSelection? = nil,
        enablementStore: WorkflowLibraryEnablementStore = .shared,
        packageStore: WorkflowLibraryImportedPackageStore = .shared
```

In the initializer, before assigning `selectedReadURLs`, compute:

```swift
        self.sidebarInputSelection = sidebarInputSelection
        self.includeSubfolderBundles = false
        let initialReadURLs = sidebarInputSelection?.selectedReadURLs(includeSubfolders: false) ?? selectedReadURLs
        let standardizedReadURLs = Self.deduplicated(initialReadURLs.map(\.standardizedFileURL))
```

Add:

```swift
    var folderSubfolderNoticeText: String? {
        sidebarInputSelection?.subfolderSummaryText
    }

    var folderDuplicateNoticeText: String? {
        sidebarInputSelection?.duplicateSummaryText
    }

    var folderEmptyNoticeText: String? {
        sidebarInputSelection?.emptyFolderSummaryText
    }

    var resolvedReadDetailRows: [WorkflowSidebarInputSelection.DetailRow] {
        sidebarInputSelection?.detailRows ?? selectedReadURLs.map {
            WorkflowSidebarInputSelection.DetailRow(
                url: $0,
                displayPath: Self.displayPath(for: $0, relativeTo: projectURL)
            )
        }
    }

    func setIncludeSubfolderBundles(_ include: Bool) {
        includeSubfolderBundles = include
        guard let sidebarInputSelection else { return }
        setReads(sidebarInputSelection.selectedReadURLs(includeSubfolders: include))
    }
```

Update `selectedReadsDisplay`:

```swift
    var selectedReadsDisplay: String {
        if let sidebarInputSelection {
            return sidebarInputSelection.summaryText(includeSubfolders: includeSubfolderBundles)
        }
        guard !selectedReadURLs.isEmpty else { return "No read bundles selected" }
        return selectedReadURLs
            .map { Self.displayPath(for: $0, relativeTo: projectURL) }
            .joined(separator: ", ")
    }
```

Change `configureProject` signature:

```swift
    func configureProject(
        projectURL: URL?,
        selectedReadURLs: [URL],
        sidebarInputSelection: WorkflowSidebarInputSelection? = nil
    ) {
```

Inside `configureProject`, before `setReads(...)`:

```swift
        self.sidebarInputSelection = sidebarInputSelection
        includeSubfolderBundles = false
        let nextReadURLs = sidebarInputSelection?.selectedReadURLs(includeSubfolders: false) ?? selectedReadURLs
        setReads(nextReadURLs)
```

Remove the old direct `setReads(selectedReadURLs)` call.

- [ ] **Step 4: Wire the window controller and AppDelegate**

In `WorkflowOperationsWindowController.show`, add parameter:

```swift
        sidebarInputSelection: WorkflowSidebarInputSelection? = nil
```

Pass it into the initializer/configure methods, and update the initializer/state construction:

```swift
        self.state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: selectedReadURLs,
            sidebarInputSelection: sidebarInputSelection
        )
```

Update `configure` to accept and pass `sidebarInputSelection`.

In `AppDelegate+ToolsMenu.swift`, change `showWorkflowOperations(_:)` to build the selection model:

```swift
        let sidebarItems = sourceController?.mainSplitViewController?.sidebarController?.selectedItems() ?? []
        let sidebarInputSelection = WorkflowSidebarInputSelection.resolve(items: sidebarItems, projectURL: projectURL)
        let selectedReadURLs = sidebarInputSelection.selectedReadURLs(includeSubfolders: false)
```

Pass `sidebarInputSelection: sidebarInputSelection` into `WorkflowOperationsWindowController.show(...)`.

Keep `gatherWorkflowOperationReadInputURLs(controller:)` unchanged unless existing callers require it; `showWorkflowOperations` should use the richer resolver directly.

- [ ] **Step 5: Run state tests**

Run:

```bash
swift test --filter 'WorkflowOperationDialogStateTests/testWorkflowOperationDialogStateUsesDirectFolderSelectionByDefaultAndCanIncludeSubfolders|WorkflowOperationDialogStateTests/testWorkflowOperationDialogConfigureProjectReplacesSidebarInputSelection'
```

Expected: PASS.

- [ ] **Step 6: Commit Task 2**

Run:

```bash
git add Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsWindowController.swift Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift
git commit -m "feat: pass folder-resolved inputs to workflow operations"
```

## Task 3: Render Resolved Folder Inputs in Workflow Operations Dialog

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`

- [ ] **Step 1: Write failing source-level UI test**

Append this test to `WorkflowOperationDialogStateTests`:

```swift
    func testWorkflowOperationsDialogShowsFolderBatchSummaryAndSubfolderToggleText() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Include subfolders"))
        XCTAssertTrue(source.contains("When enabled, all eligible bundles in descendant folders are added to this batch."))
        XCTAssertTrue(source.contains("folderSubfolderNoticeText"))
        XCTAssertTrue(source.contains("folderDuplicateNoticeText"))
        XCTAssertTrue(source.contains("folderEmptyNoticeText"))
        XCTAssertTrue(source.contains("resolvedReadDetailRows"))
        XCTAssertTrue(source.contains("workflow-operations-include-subfolders"))
    }
```

- [ ] **Step 2: Run the UI source test to verify it fails**

Run:

```bash
swift test --filter WorkflowOperationDialogStateTests/testWorkflowOperationsDialogShowsFolderBatchSummaryAndSubfolderToggleText
```

Expected: FAIL because the dialog source does not contain the new summary/toggle strings.

- [ ] **Step 3: Update the read picker UI**

Replace `readPicker` in `WorkflowOperationsDialog.swift` with:

```swift
    private var readPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("FASTQ Bundles")
            VStack(alignment: .leading, spacing: 6) {
                Text(state.selectedReadsDisplay)
                    .font(.caption)
                    .foregroundStyle(state.selectedReadURLs.isEmpty ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(3)
                    .accessibilityIdentifier("workflow-operations-resolved-input-summary")
                if let emptyText = state.folderEmptyNoticeText {
                    helperText(emptyText)
                        .accessibilityIdentifier("workflow-operations-empty-folder-notice")
                }
                if let subfolderText = state.folderSubfolderNoticeText {
                    helperText(subfolderText)
                        .accessibilityIdentifier("workflow-operations-subfolder-notice")
                    Toggle("Include subfolders", isOn: Binding(
                        get: { state.includeSubfolderBundles },
                        set: { state.setIncludeSubfolderBundles($0) }
                    ))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("workflow-operations-include-subfolders")
                    helperText("When enabled, all eligible bundles in descendant folders are added to this batch.")
                        .accessibilityIdentifier("workflow-operations-include-subfolders-help")
                }
                if let duplicateText = state.folderDuplicateNoticeText {
                    helperText(duplicateText)
                        .accessibilityIdentifier("workflow-operations-duplicate-folder-inputs")
                }
                if state.resolvedReadDetailRows.count > 1 {
                    DisclosureGroup("Resolved inputs") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(state.resolvedReadDetailRows, id: \.url) { row in
                                Text(row.displayPath)
                                    .font(.caption2)
                                    .foregroundStyle(Color.lungfishSecondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.leading, 12)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("workflow-operations-resolved-input-details")
                }
            }
        }
    }
```

- [ ] **Step 4: Run the UI source test**

Run:

```bash
swift test --filter WorkflowOperationDialogStateTests/testWorkflowOperationsDialogShowsFolderBatchSummaryAndSubfolderToggleText
```

Expected: PASS.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift
git commit -m "feat: show folder batch inputs in workflow dialog"
```

## Task 4: Guard Imported Workflow Packages Against Multi-Bundle Folder Batches

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`

- [ ] **Step 1: Write failing package guard test**

Append this helper and test to `WorkflowOperationDialogStateTests`:

```swift
    private func makeRunnableWorkflowPackage(id: String = "package-test") -> WorkflowPackageValidationResult {
        let temp = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
        let manifest = WorkflowPackageManifest(
            id: id,
            name: "Package Test",
            version: "1.0.0",
            summary: "Fixture package",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [
                WorkflowPackageInput(
                    id: "reference",
                    label: "Reference",
                    bundleTypes: [.lungfishref],
                    required: true
                ),
                WorkflowPackageInput(
                    id: "reads",
                    label: "Reads",
                    bundleTypes: [.lungfishfastq],
                    required: true
                ),
            ],
            parameters: []
        )
        return WorkflowPackageValidationResult(packageURL: temp, manifest: manifest, diagnostics: [])
    }

    func testWorkflowPackageIsNotRunnableWithFolderBatchMultiReadSelection() {
        let state = WorkflowOperationDialogState(
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            selectedReadURLs: [
                URL(fileURLWithPath: "/tmp/project/A.lungfishfastq", isDirectory: true),
                URL(fileURLWithPath: "/tmp/project/B.lungfishfastq", isDirectory: true),
            ]
        )
        state.setReference(URL(fileURLWithPath: "/tmp/project/ref.lungfishref", isDirectory: true))
        state.outputDirectoryURL = URL(fileURLWithPath: "/tmp/project/Analyses", isDirectory: true)
        state.testingReplaceTools([
            WorkflowOperationTool(
                id: "package-test",
                title: "Package Test",
                subtitle: "Fixture package",
                kind: .workflowPackage(makeRunnableWorkflowPackage()),
                availability: .available
            ),
        ])
        state.selectTool("package-test")

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(
            state.readinessText,
            "Imported workflow packages currently accept one FASTQ bundle. Select one bundle, or choose a built-in workflow for folder batches."
        )
    }
```

If `WorkflowPackageManifest`, `WorkflowPackageRunner`, or `WorkflowPackageInput` initializer labels differ, inspect `Sources/LungfishWorkflow/WorkflowPackageManifest.swift` or the existing tests around `WorkflowLibraryImportedPackageStore` and adjust the helper to compile.

If no `testingReplaceTools` exists, add this `#if DEBUG` method to `WorkflowOperationDialogState`:

```swift
    func testingReplaceTools(_ tools: [WorkflowOperationTool]) {
        cachedTools = tools
        selectedToolID = tools.first?.id ?? Self.ontGenotypingID
        workflowAvailabilityRevision &+= 1
    }
```

- [ ] **Step 2: Run the package guard test to verify it fails**

Run:

```bash
swift test --filter WorkflowOperationDialogStateTests/testWorkflowPackageIsNotRunnableWithFolderBatchMultiReadSelection
```

Expected: FAIL because package workflows currently use the first selected read bundle and do not disable multi-read launches.

- [ ] **Step 3: Add package multi-read readiness guard**

In `WorkflowOperationDialogState.readinessText`, after the existing package runnable guard, add:

```swift
        if case .workflowPackage = selectedTool?.kind,
           selectedReadURLs.count > 1 {
            return "Imported workflow packages currently accept one FASTQ bundle. Select one bundle, or choose a built-in workflow for folder batches."
        }
```

Confirm this guard appears before the final `return "Ready to run."`.

- [ ] **Step 4: Run the package guard test**

Run:

```bash
swift test --filter WorkflowOperationDialogStateTests/testWorkflowPackageIsNotRunnableWithFolderBatchMultiReadSelection
```

Expected: PASS.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift
git commit -m "fix: prevent package workflows from dropping folder batch inputs"
```

## Task 5: Verify Launch Requests Use Concrete Resolved Bundle URLs

**Files:**
- Modify: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`

- [ ] **Step 1: Write failing launch request test**

Append this test to `WorkflowOperationDialogStateTests`:

```swift
    func testFolderResolvedBuiltInWorkflowLaunchRequestUsesConcreteBundleURLs() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let direct = projectURL.appendingPathComponent("Runs/A.lungfishfastq", isDirectory: true)
        let nested = projectURL.appendingPathComponent("Runs/Nested/B.lungfishfastq", isDirectory: true)
        let selection = WorkflowSidebarInputSelection(
            directReadURLs: [direct.standardizedFileURL],
            recursiveReadURLs: [direct.standardizedFileURL, nested.standardizedFileURL],
            detailRows: [
                .init(url: direct.standardizedFileURL, displayPath: "Runs/A.lungfishfastq"),
                .init(url: nested.standardizedFileURL, displayPath: "Runs/Nested/B.lungfishfastq"),
            ],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["Runs"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 1
        )
        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: [],
            sidebarInputSelection: selection
        )
        state.selectTool(WorkflowOperationDialogState.twelveSAmpliconMatchingID)
        state.setReference(projectURL.appendingPathComponent("ref.fasta"))
        state.outputDirectoryURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        state.outputName = "folder-batch"
        state.setIncludeSubfolderBundles(true)

        let request = try state.makeLaunchRequest()

        guard case .twelveSAmpliconMatching(let config) = request else {
            return XCTFail("Expected 12S amplicon matching launch request")
        }
        XCTAssertEqual(config.inputFASTQs, [direct.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertFalse(config.inputFASTQs.contains(projectURL.appendingPathComponent("Runs", isDirectory: true)))
    }
```

- [ ] **Step 2: Run the launch request test**

Run:

```bash
swift test --filter WorkflowOperationDialogStateTests/testFolderResolvedBuiltInWorkflowLaunchRequestUsesConcreteBundleURLs
```

Expected before Task 2: FAIL to compile. Expected after Tasks 2-4: PASS or FAIL only because the selected tool ID constant is not visible. If the ID is private, select the 12S tool by finding it in `state.tools` where `kind == .twelveSAmpliconMatching`.

- [ ] **Step 3: Fix any request construction issue**

If the test fails because `selectedReadURLs` still contains only direct URLs after `setIncludeSubfolderBundles(true)`, fix `setIncludeSubfolderBundles(_:)` in `WorkflowOperationDialogState` to call:

```swift
        setReads(sidebarInputSelection.selectedReadURLs(includeSubfolders: include))
```

If it fails because `setReads` resets `selectedGenotypingReadType` incorrectly for 12S, do not special-case 12S; keep the read type update as-is because 12S does not use it.

- [ ] **Step 4: Run all targeted workflow/sidebar tests**

Run:

```bash
swift test --filter 'SidebarViewControllerSelectionTests/testWorkflowInputSelection|WorkflowOperationDialogStateTests/testWorkflowOperationDialogStateUsesDirectFolderSelectionByDefaultAndCanIncludeSubfolders|WorkflowOperationDialogStateTests/testWorkflowOperationDialogConfigureProjectReplacesSidebarInputSelection|WorkflowOperationDialogStateTests/testWorkflowOperationsDialogShowsFolderBatchSummaryAndSubfolderToggleText|WorkflowOperationDialogStateTests/testWorkflowPackageIsNotRunnableWithFolderBatchMultiReadSelection|WorkflowOperationDialogStateTests/testFolderResolvedBuiltInWorkflowLaunchRequestUsesConcreteBundleURLs'
```

Expected: PASS.

- [ ] **Step 5: Commit Task 5**

Run:

```bash
git add Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift
git commit -m "test: verify folder batch workflow launch inputs"
```

## Task 6: Final Verification And Review

**Files:**
- No planned code edits unless verification finds defects.

- [ ] **Step 1: Run focused test suites**

Run:

```bash
swift test --filter SidebarViewControllerSelectionTests
swift test --filter WorkflowOperationDialogStateTests
```

Expected: PASS.

- [ ] **Step 2: Run FASTQ operation routing smoke test**

Run:

```bash
swift test --filter FASTQOperationDialogRoutingTests/testDerivativeToolsExposeStandardizedPaneSectionsAndOutputStrategy
```

Expected: PASS. This confirms low-level FASTQ operation dialog construction was not broken by shared app/module changes.

- [ ] **Step 3: Inspect changed files**

Run:

```bash
git status --short
git diff --stat HEAD~5..HEAD
```

Expected: only the spec, plan, resolver, workflow operation files, and targeted tests changed.

- [ ] **Step 4: Request final code review**

Dispatch a high-reasoning reviewer with:

- What was implemented: folder sidebar selection expansion for Workflow Operations.
- Requirements: this plan and the design spec.
- Base SHA: commit before Task 1.
- Head SHA: current HEAD.
- Focus: resolver semantics, package multi-input guard, UI state consistency, provenance safety that workflow requests use concrete bundle URLs.

- [ ] **Step 5: Fix review issues and rerun verification**

If review finds Critical or Important issues, fix them with tests first, then rerun:

```bash
swift test --filter SidebarViewControllerSelectionTests
swift test --filter WorkflowOperationDialogStateTests
```

Expected: PASS.

## Plan Self Review

Spec coverage:
- One folder direct expansion: Task 1.
- Multiple folder single-batch semantics: Task 1.
- Parent folder direct-only default and recursive toggle: Tasks 1-3.
- Avoiding bundle-internal recursion: Task 1.
- Dialog microcopy and accessibility identifiers: Task 3.
- Built-in launch requests use concrete bundle URLs: Task 5.
- Imported workflow package multi-input guard: Task 4.
- Provenance safety through concrete CLI input paths: Task 5.

Placeholder scan:
- No `TBD`, `TODO`, or open-ended implementation steps remain.
- The only conditional instructions are bounded compile-adjustment notes with specific files and expected fixes.

Type consistency:
- `WorkflowSidebarInputSelection`, `DetailRow`, `sidebarInputSelection`, `includeSubfolderBundles`, `setIncludeSubfolderBundles`, and summary property names are used consistently across tasks.

# Database Search Operations Dialog and XCUI Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor online database search into the shared launcher-style operations dialog, preserve existing NCBI/SRA/Pathoplexus behavior, remove decorative glyphs from the search surfaces, and add the first reusable XCUI foundation for menu-driven GUI testing.

**Architecture:** Keep the current search logic stable by composing a new `DatabaseSearchDialogState` out of three existing `DatabaseBrowserViewModel` instances, one per destination. Reuse `DatasetOperationsDialog` for the shell, extract the right pane into a shared `DatabaseBrowserPane` plus destination wrappers, and slim `DatabaseBrowserViewController` down to AppKit hosting and callback wiring. Layer a reusable app-level UI-test configuration surface plus a deterministic database-search automation backend on top so real XCUITests can drive the `Tools` menu path without depending on live network responses.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Observation, LungfishCore database models, XCTest, XCUITest, xcodebuild

**Spec:** `docs/superpowers/specs/2026-04-19-database-search-operations-dialog-design.md`

**Branch:** `codex/search-online-database-refactor` (already created)

**Current Branch Status:** Tasks 1-4 from this plan are already implemented on `codex/search-online-database-refactor` through commit `82eb391a`. The remaining work on this branch is the XCUI foundation and the first menu-driven app tests in Tasks 5-7 below.

---

## File Map

- Modify: `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`
  - Add a customizable primary-action title while preserving the existing default `Run` behavior for FASTQ operations.
- Modify: `Tests/LungfishAppTests/DatasetOperationsDialogTests.swift`
  - Lock the default/custom primary-action-title contract.
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialogState.swift`
  - Destination enum, sidebar metadata, three preserved provider view models, shared footer/action state, callback fan-out.
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift`
  - Wrapper that feeds `DatasetOperationsDialog` and switches the right pane by destination.
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift`
  - Shared right-pane layout for summary text, search controls, advanced filters, results, and empty/progress states.
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift`
  - Wrapper for the NCBI-backed destination, including the NCBI mode picker in the right pane.
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift`
  - Wrapper for the SRA/ENA-backed destination, including accession import in the right pane.
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift`
  - Wrapper for Pathoplexus; create a minimal shell wrapper in Task 3, then expand it with consent gating and organism chips in Task 4.
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`
  - Host `DatabaseSearchDialog` instead of the legacy monolithic SwiftUI view, apply initial destination/search mode, and keep sheet callbacks.
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
  - Keep menu routing but present one unified sheet title for the new destination-switching dialog.
- Create: `Tests/LungfishAppTests/DatabaseSearchDialogStateTests.swift`
  - State and routing tests for the new destination wrapper.
- Create: `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`
  - Source-level regression guards proving the new dialog uses the shared shell, keeps destination-specific controls in the right pane, and avoids banned decorative glyphs.
- Create: `Sources/LungfishApp/App/AppUITestConfiguration.swift`
  - Shared launch-argument/environment parser for app-driven UI tests and named scenarios.
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchAutomationBackend.swift`
  - Deterministic database-search scenario backend for XCUI, with a reusable pattern for future app surfaces.
- Create: `Tests/LungfishAppTests/AppUITestConfigurationTests.swift`
  - Unit tests for UI-test-mode detection and scenario parsing.
- Create: `Tests/LungfishAppTests/DatabaseSearchAutomationBackendTests.swift`
  - Unit tests for deterministic search results and no-op download handling in the named database-search scenario.
- Modify: `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`
  - Add a reusable accessibility namespace so shared launcher shells can expose stable XCUI identifiers.
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift`
  - Pass the database-search accessibility namespace and root identifiers into the shared shell.
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift`
  - Expose searchable, selectable, and result-list identifiers needed by XCUITest.
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift`
  - Tag the NCBI mode picker for XCUI coverage.
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift`
  - Tag the consent buttons and any Pathoplexus-specific controls needed by initial GUI flows.
- Modify: `Lungfish.xcodeproj/project.pbxproj`
  - Add a real `LungfishXCUITests` UI-testing bundle target that hosts XCUITest sources.
- Modify: `Lungfish.xcodeproj/xcshareddata/xcschemes/Lungfish.xcscheme`
  - Add the new UI-test bundle to the shared test action so `xcodebuild test` runs app-driven XCUI flows.
- Create: `Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift`
  - Shared XCUI launch and menu-navigation helper for future app-wide GUI tests.
- Create: `Tests/LungfishXCUITests/DatabaseSearchXCUITests.swift`
  - The first menu-driven GUI tests for online database search.

### Task 1: Make the Shared Launcher Shell Reusable for Search Actions

Keep `DatasetOperationsDialog` as the single launcher shell, but add the one missing capability the database search dialog needs: a configurable primary-action title.

**Files:**
- Modify: `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`
- Modify: `Tests/LungfishAppTests/DatasetOperationsDialogTests.swift`

- [ ] **Step 1: Write failing tests for default and custom primary-action titles**

Add to `Tests/LungfishAppTests/DatasetOperationsDialogTests.swift`:

```swift
    @MainActor
    func testPrimaryActionTitleDefaultsToRun() {
        let dialog = DatasetOperationsDialog(
            title: "Operations",
            subtitle: "Configure a tool",
            datasetLabel: "sample.fastq",
            tools: [],
            selectedToolID: "tool",
            statusText: "Ready",
            isRunEnabled: true,
            onSelectTool: { _ in },
            onCancel: {},
            onRun: {}
        ) {
            EmptyView()
        }

        XCTAssertEqual(dialog.primaryActionTitle, "Run")
    }

    @MainActor
    func testPrimaryActionTitleCanBeCustomized() {
        let dialog = DatasetOperationsDialog(
            title: "Search",
            subtitle: "Choose a destination",
            datasetLabel: "Online sources",
            tools: [],
            selectedToolID: "genbank",
            statusText: "Enter a query and choose Search.",
            primaryActionTitle: "Search",
            isRunEnabled: true,
            onSelectTool: { _ in },
            onCancel: {},
            onRun: {}
        ) {
            EmptyView()
        }

        XCTAssertEqual(dialog.primaryActionTitle, "Search")
    }
```

- [ ] **Step 2: Run the shared-shell tests to verify the custom-title case fails**

Run: `swift test --filter DatasetOperationsDialogTests 2>&1 | tail -10`
Expected: build failure complaining about an extra `primaryActionTitle` argument or missing stored property.

- [ ] **Step 3: Add a defaulted primary-action title to the shared shell**

Update `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`:

```swift
struct DatasetOperationsDialog<Detail: View>: View {
    let title: String
    let subtitle: String
    let datasetLabel: String
    let tools: [DatasetOperationToolSidebarItem]
    let selectedToolID: String
    let statusText: String
    let primaryActionTitle: String = "Run"
    let isRunEnabled: Bool
    let onSelectTool: (String) -> Void
    let onCancel: () -> Void
    let onRun: () -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            toolSidebar
                .frame(width: 260)
                .background(Color.lungfishSidebarBackground)
            Divider()
            VStack(spacing: 0) {
                detailPane
                Divider()
                footerBar
            }
            .background(Color.lungfishCanvasBackground)
        }
        .background(Color.lungfishCanvasBackground)
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
            Spacer()
            Button("Cancel", action: onCancel)
            Button(primaryActionTitle, action: runIfEnabled)
                .buttonStyle(.borderedProminent)
                .tint(.lungfishCreamsicleFallback)
                .disabled(!isRunEnabled)
        }
        .padding(16)
        .background(Color.lungfishCanvasBackground)
    }
}
```

- [ ] **Step 4: Re-run the shared-shell tests**

Run: `swift test --filter DatasetOperationsDialogTests 2>&1 | tail -10`
Expected: `DatasetOperationsDialogTests` passes with the new default/custom label coverage and no FASTQ dialog regressions.

- [ ] **Step 5: Commit the shared-shell change**

```bash
git add Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift Tests/LungfishAppTests/DatasetOperationsDialogTests.swift
git commit -m "refactor: allow custom launcher primary action labels"
```

### Task 2: Add the Unified Database Search Dialog State

Create a dedicated wrapper state that preserves one `DatabaseBrowserViewModel` per destination and exposes the shared shell metadata, footer state, and primary action.

**Files:**
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialogState.swift`
- Create: `Tests/LungfishAppTests/DatabaseSearchDialogStateTests.swift`

- [ ] **Step 1: Write failing state tests for approved destination labels, state preservation, and footer action labeling**

Create `Tests/LungfishAppTests/DatabaseSearchDialogStateTests.swift`:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class DatabaseSearchDialogStateTests: XCTestCase {
    private func makeRecord(
        accession: String = "NC_045512.2",
        source: DatabaseSource = .ncbi
    ) -> SearchResultRecord {
        SearchResultRecord(
            id: accession,
            accession: accession,
            title: "Test Record",
            source: source
        )
    }

    func testSidebarItemsUseApprovedDestinationTitlesAndSubtitles() {
        let state = DatabaseSearchDialogState()

        XCTAssertEqual(state.sidebarItems.map(\.title), [
            "GenBank & Genomes",
            "SRA Runs",
            "Pathoplexus",
        ])
        XCTAssertEqual(state.sidebarItems.map(\.subtitle), [
            "Nucleotide, assembly, and virus records from NCBI",
            "Sequencing runs and FASTQ availability",
            "Open pathogen records and surveillance metadata",
        ])
    }

    func testSwitchingDestinationsPreservesEachDestinationSearchText() {
        let state = DatabaseSearchDialogState()

        state.genBankGenomesViewModel.searchText = "influenza A virus"
        state.selectDestination(.sraRuns)
        state.sraRunsViewModel.searchText = "SRR35517702"
        state.selectDestination(.pathoplexus)
        state.pathoplexusViewModel.searchText = "mpox"

        state.selectDestination(.genBankGenomes)
        XCTAssertEqual(state.activeViewModel.searchText, "influenza A virus")

        state.selectDestination(.sraRuns)
        XCTAssertEqual(state.activeViewModel.searchText, "SRR35517702")

        state.selectDestination(.pathoplexus)
        XCTAssertEqual(state.activeViewModel.searchText, "mpox")
    }

    func testPrimaryActionTitleStartsAsSearch() {
        let state = DatabaseSearchDialogState()
        XCTAssertEqual(state.primaryActionTitle, "Search")
    }

    func testPrimaryActionTitleSwitchesToDownloadSelectedWhenRowsAreSelected() {
        let state = DatabaseSearchDialogState()
        let record = makeRecord()

        state.genBankGenomesViewModel.results = [record]
        state.genBankGenomesViewModel.selectedRecords = [record]

        XCTAssertEqual(state.primaryActionTitle, "Download Selected")
    }

    func testDatabaseSourceMappingMatchesExistingMenuEntrypoints() {
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .ncbi), .genBankGenomes)
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .ena), .sraRuns)
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .pathoplexus), .pathoplexus)
    }
}
```

- [ ] **Step 2: Run the new state tests to confirm they fail before the type exists**

Run: `swift test --filter DatabaseSearchDialogStateTests 2>&1 | tail -10`
Expected: build failure because `DatabaseSearchDialogState` and `DatabaseSearchDestination` do not exist yet.

- [ ] **Step 3: Implement the destination enum and wrapper state**

Create `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialogState.swift`:

```swift
import Foundation
import Observation
import LungfishCore

enum DatabaseSearchDestination: String, CaseIterable, Identifiable, Sendable {
    case genBankGenomes
    case sraRuns
    case pathoplexus

    init(databaseSource: DatabaseSource) {
        switch databaseSource {
        case .ncbi:
            self = .genBankGenomes
        case .ena:
            self = .sraRuns
        case .pathoplexus:
            self = .pathoplexus
        default:
            self = .genBankGenomes
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .genBankGenomes:
            return "GenBank & Genomes"
        case .sraRuns:
            return "SRA Runs"
        case .pathoplexus:
            return "Pathoplexus"
        }
    }

    var subtitle: String {
        switch self {
        case .genBankGenomes:
            return "Nucleotide, assembly, and virus records from NCBI"
        case .sraRuns:
            return "Sequencing runs and FASTQ availability"
        case .pathoplexus:
            return "Open pathogen records and surveillance metadata"
        }
    }

    var sidebarItem: DatasetOperationToolSidebarItem {
        DatasetOperationToolSidebarItem(
            id: rawValue,
            title: title,
            subtitle: subtitle,
            availability: .available
        )
    }
}

@MainActor
@Observable
final class DatabaseSearchDialogState {
    var selectedDestination: DatabaseSearchDestination
    var onCancel: (() -> Void)?

    let genBankGenomesViewModel: DatabaseBrowserViewModel
    let sraRunsViewModel: DatabaseBrowserViewModel
    let pathoplexusViewModel: DatabaseBrowserViewModel

    init(initialDestination: DatabaseSearchDestination = .genBankGenomes) {
        self.selectedDestination = initialDestination
        self.genBankGenomesViewModel = DatabaseBrowserViewModel(source: .ncbi)
        self.sraRunsViewModel = DatabaseBrowserViewModel(source: .ena)
        self.pathoplexusViewModel = DatabaseBrowserViewModel(source: .pathoplexus)
    }

    var dialogTitle: String { "Online Database Search" }
    var dialogSubtitle: String { "Choose a destination and search public records." }
    var contextLabel: String { "Online sources" }
    var sidebarItems: [DatasetOperationToolSidebarItem] { DatabaseSearchDestination.allCases.map(\.sidebarItem) }
    var selectedToolID: String { selectedDestination.rawValue }

    var activeViewModel: DatabaseBrowserViewModel {
        switch selectedDestination {
        case .genBankGenomes:
            return genBankGenomesViewModel
        case .sraRuns:
            return sraRunsViewModel
        case .pathoplexus:
            return pathoplexusViewModel
        }
    }

    var primaryActionTitle: String {
        if !activeViewModel.selectedRecords.isEmpty {
            return "Download Selected"
        }
        return activeViewModel.isSearching ? "Searching" : "Search"
    }

    var isPrimaryActionEnabled: Bool {
        if !activeViewModel.selectedRecords.isEmpty {
            return !activeViewModel.isSearching && !activeViewModel.isDownloading
        }
        return activeViewModel.isSearchTextValid && !activeViewModel.isSearching && !activeViewModel.isDownloading
    }

    var statusText: String {
        if let error = activeViewModel.errorMessage {
            return error
        }
        if activeViewModel.isDownloading {
            return activeViewModel.statusMessage ?? "Downloading selected records..."
        }
        if activeViewModel.isSearching {
            return activeViewModel.searchPhase.message
        }
        if !activeViewModel.selectedRecords.isEmpty {
            return "\(activeViewModel.selectedRecords.count) selected"
        }
        return "Enter a query and choose Search."
    }

    func selectDestination(_ destination: DatabaseSearchDestination) {
        selectedDestination = destination
    }

    func selectDestination(named rawValue: String) {
        guard let destination = DatabaseSearchDestination(rawValue: rawValue) else {
            return
        }
        selectedDestination = destination
    }

    func cancel() {
        onCancel?()
    }

    func performPrimaryAction() {
        if activeViewModel.selectedRecords.isEmpty {
            activeViewModel.performSearch()
        } else {
            activeViewModel.performBatchDownload()
        }
    }

    func applyCallbacks(
        onCancel: (() -> Void)?,
        onDownloadStarted: (() -> Void)?
    ) {
        self.onCancel = onCancel

        for viewModel in [genBankGenomesViewModel, sraRunsViewModel, pathoplexusViewModel] {
            viewModel.onCancel = onCancel
            viewModel.onDownloadStarted = onDownloadStarted
        }
    }
}
```

- [ ] **Step 4: Re-run the new state tests**

Run: `swift test --filter DatabaseSearchDialogStateTests 2>&1 | tail -10`
Expected: `DatabaseSearchDialogStateTests` passes and proves the preserved per-destination state model works before any SwiftUI extraction begins.

- [ ] **Step 5: Commit the new wrapper state**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialogState.swift Tests/LungfishAppTests/DatabaseSearchDialogStateTests.swift
git commit -m "feat: add unified database search dialog state"
```

### Task 3: Extract the Shared Right Pane and the GenBank/SRA Destination Wrappers

Create the new shell wrapper and extract the shared right-pane content into a reusable `DatabaseBrowserPane`, then layer `GenBank & Genomes` and `SRA Runs` wrappers on top.

**Files:**
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift`
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift`
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift`
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift`
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift`
- Create: `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`

- [ ] **Step 1: Write failing source tests for shell reuse and destination-specific right-pane controls**

Create `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`:

```swift
import XCTest

final class DatabaseSearchDialogSourceTests: XCTestCase {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDatabaseSearchDialogUsesSharedOperationsShell() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("DatasetOperationsDialog("))
        XCTAssertTrue(source.contains("primaryActionTitle: state.primaryActionTitle"))
        XCTAssertTrue(source.contains("onRun: state.performPrimaryAction"))
    }

    func testGenBankPaneKeepsNCBIModePickerInRightPane() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Picker(\"Mode\", selection: $viewModel.ncbiSearchType)"))
        XCTAssertTrue(source.contains("Text(\"Nucleotide\").tag(NCBISearchType.nucleotide)"))
        XCTAssertTrue(source.contains("Text(\"Genome\").tag(NCBISearchType.genome)"))
        XCTAssertTrue(source.contains("Text(\"Virus\").tag(NCBISearchType.virus)"))
    }

    func testSRARunsPaneRetainsAccessionImportFlowInRightPane() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Button(\"Import Accessions\")"))
        XCTAssertTrue(source.contains("viewModel.importAccessionList()"))
    }
}
```

- [ ] **Step 2: Run the source tests to verify the new files are still missing**

Run: `swift test --filter DatabaseSearchDialogSourceTests 2>&1 | tail -10`
Expected: file-read failures for the new dialog and pane files because they do not exist yet.

- [ ] **Step 3: Create the shared shell wrapper and the GenBank/SRA panes**

Create `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift`:

```swift
import SwiftUI

struct DatabaseSearchDialog: View {
    @Bindable var state: DatabaseSearchDialogState

    var body: some View {
        DatasetOperationsDialog(
            title: state.dialogTitle,
            subtitle: state.dialogSubtitle,
            datasetLabel: state.contextLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: state.statusText,
            primaryActionTitle: state.primaryActionTitle,
            isRunEnabled: state.isPrimaryActionEnabled,
            onSelectTool: state.selectDestination(named:),
            onCancel: state.cancel,
            onRun: state.performPrimaryAction
        ) {
            switch state.selectedDestination {
            case .genBankGenomes:
                GenBankGenomesSearchPane(viewModel: state.genBankGenomesViewModel)
            case .sraRuns:
                SRARunsSearchPane(viewModel: state.sraRunsViewModel)
            case .pathoplexus:
                PathoplexusSearchPane(viewModel: state.pathoplexusViewModel)
            }
        }
    }
}
```

Create `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift`:

```swift
import SwiftUI
import LungfishCore

struct DatabaseBrowserPane<TopControls: View, SearchExtras: View>: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel
    let title: String
    let summary: String
    let placeholder: String
    @ViewBuilder let topControls: () -> TopControls
    @ViewBuilder let searchExtras: () -> SearchExtras

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            topControls()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    AppKitTextField(
                        text: $viewModel.searchText,
                        placeholder: placeholder,
                        onSubmit: { viewModel.performSearch() }
                    )
                    .frame(minWidth: 280)

                    searchExtras()

                    Button(viewModel.isSearching ? "Searching" : "Search") {
                        viewModel.performSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.isSearchTextValid || viewModel.isSearching || viewModel.isDownloading)
                }

                if viewModel.searchScope != .all {
                    Text(viewModel.searchScope.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                resultsSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if viewModel.isSearching {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: viewModel.searchPhase.progress)
                    .progressViewStyle(.linear)
                Text(viewModel.searchPhase.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if viewModel.results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No results yet")
                    .font(.headline)
                Text("Enter a search and use the controls above to load records.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Results")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(viewModel.filteredResults.count) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                List(viewModel.filteredResults, selection: $viewModel.selectedRecords) { record in
                    DatabaseSearchResultRow(
                        record: record,
                        isSelected: viewModel.selectedRecords.contains(record),
                        onToggle: {
                            if viewModel.selectedRecords.contains(record) {
                                viewModel.selectedRecords.remove(record)
                            } else {
                                viewModel.selectedRecords.insert(record)
                            }
                        }
                    )
                    .tag(record)
                }
                .listStyle(.plain)
            }
        }
    }
}

struct DatabaseSearchResultRow: View {
    let record: SearchResultRecord
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.accession)
                        .font(.headline.monospaced())
                    Spacer()
                    if let length = record.length {
                        Text("\(length) bp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(record.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let organism = record.organism {
                    Text(organism)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
```

Create `Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift`:

```swift
import SwiftUI
import LungfishCore

struct GenBankGenomesSearchPane: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel

    var body: some View {
        DatabaseBrowserPane(
            viewModel: viewModel,
            title: "GenBank & Genomes",
            summary: "Search nucleotide, assembly, and virus records from NCBI without leaving the shared launcher.",
            placeholder: "Search NCBI records"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Mode", selection: $viewModel.ncbiSearchType) {
                    Text("Nucleotide").tag(NCBISearchType.nucleotide)
                    Text("Genome").tag(NCBISearchType.genome)
                    Text("Virus").tag(NCBISearchType.virus)
                }
                .pickerStyle(.segmented)
            }
        } searchExtras: {
            EmptyView()
        }
    }
}
```

Create `Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift`:

```swift
import SwiftUI

struct SRARunsSearchPane: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel

    var body: some View {
        DatabaseBrowserPane(
            viewModel: viewModel,
            title: "SRA Runs",
            summary: "Search SRA runs and FASTQ-backed sequencing records through the shared launcher.",
            placeholder: "Search SRA runs or paste accessions"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Supports single accessions, pasted accession lists, and broader SRA/ENA discovery queries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } searchExtras: {
            Button("Import Accessions") {
                viewModel.importAccessionList()
            }
        }
    }
}
```

Create `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift`:

```swift
import SwiftUI

struct PathoplexusSearchPane: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel

    var body: some View {
        DatabaseBrowserPane(
            viewModel: viewModel,
            title: "Pathoplexus",
            summary: "Browse open pathogen surveillance records and metadata through the shared launcher.",
            placeholder: "Search Pathoplexus accessions or browse all"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pathoplexus adds consent-aware browsing and organism targeting on top of the shared search controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } searchExtras: {
            EmptyView()
        }
    }
}
```

- [ ] **Step 4: Re-run the new source tests**

Run: `swift test --filter DatabaseSearchDialogSourceTests 2>&1 | tail -10`
Expected: `DatabaseSearchDialogSourceTests` passes and proves the new shell wraps `DatasetOperationsDialog`, keeps the NCBI mode picker in the right pane, and preserves the SRA accession-import flow.

- [ ] **Step 5: Commit the shared right pane and the first two destination wrappers**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift
git commit -m "refactor: extract shared database search panes"
```

### Task 4: Add Pathoplexus, Wire the Unified Controller, and Lock the Visual-Language Regression Guards

Finish the migration by adding the Pathoplexus wrapper, moving the controller to the new dialog/state, using one unified sheet title, and adding source guards that keep decorative glyphs from creeping back in.

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`
- Modify: `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`

- [ ] **Step 1: Extend the source tests to cover Pathoplexus, controller hosting, and banned decorative symbols**

Add to `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`:

```swift
    func testPathoplexusPaneKeepsConsentGateAndOrganismSelector() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("if viewModel.isShowingPathoplexusConsent"))
        XCTAssertTrue(source.contains("ForEach(viewModel.pathoplexusOrganisms)"))
        XCTAssertTrue(source.contains("viewModel.acceptPathoplexusConsent()"))
    }

    func testDatabaseBrowserControllerHostsUnifiedSearchDialog() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("DatabaseSearchDialogState(initialDestination:"))
        XCTAssertTrue(source.contains("DatabaseSearchDialog(state: dialogState)"))
        XCTAssertFalse(source.contains("public struct DatabaseBrowserView: View"))
    }

    func testUnifiedSearchFilesDoNotUseLegacyDecorativeSystemImages() throws {
        let paths = [
            "Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift",
        ]

        let bannedSymbols = [
            "doc.text.magnifyingglass",
            "building.columns",
            "globe.europe.africa",
            "microbe",
            "clock.arrow.circlepath",
            "line.3.horizontal.decrease.circle",
            "slider.horizontal.3",
        ]

        for path in paths {
            let source = try String(
                contentsOf: repositoryRoot().appendingPathComponent(path),
                encoding: .utf8
            )

            for symbol in bannedSymbols {
                XCTAssertFalse(
                    source.contains(#"Image(systemName: "\#(symbol)")"#),
                    "\(path) should not reintroduce decorative symbol \(symbol)"
                )
            }
        }
    }
```

Add to `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`:

```swift
    func testPathoplexusAllowsEmptySearchTextForBrowseMode() {
        let pathoplexusViewModel = DatabaseBrowserViewModel(source: .pathoplexus)
        pathoplexusViewModel.searchText = ""
        XCTAssertTrue(pathoplexusViewModel.isSearchTextValid)
    }
```

- [ ] **Step 2: Run the Pathoplexus/controller regression tests and confirm they fail before the wiring exists**

Run: `swift test --filter 'DatabaseSearchDialogSourceTests|DatabaseBrowserViewModelTests/testPathoplexusAllowsEmptySearchTextForBrowseMode' 2>&1 | tail -15`
Expected: source assertions fail because `PathoplexusSearchPane.swift` still lacks the consent/organism code and `DatabaseBrowserViewController.swift` still hosts the legacy `DatabaseBrowserView`.

- [ ] **Step 3: Add the Pathoplexus pane and switch the controller to the unified dialog**

Create `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift`:

```swift
import SwiftUI

struct PathoplexusSearchPane: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel

    var body: some View {
        if viewModel.isShowingPathoplexusConsent {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pathoplexus Access Notice")
                    .font(.title3.weight(.semibold))
                Text("Lungfish shows only open Pathoplexus records. Proceed only if you understand and agree to respect the data-use terms attached to the records you access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") {
                        viewModel.onCancel?()
                    }
                    Spacer()
                    Button("I Understand and Agree") {
                        viewModel.acceptPathoplexusConsent()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            DatabaseBrowserPane(
                viewModel: viewModel,
                title: "Pathoplexus",
                summary: "Browse open pathogen surveillance records and metadata without leaving the shared launcher.",
                placeholder: "Search Pathoplexus accessions or browse all"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Organism")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    PathoplexusChipFlowLayout(spacing: 6) {
                        ForEach(viewModel.pathoplexusOrganisms) { organism in
                            Button(organism.displayName) {
                                if viewModel.pathoplexusOrganism?.id == organism.id {
                                    viewModel.pathoplexusOrganism = nil
                                } else {
                                    viewModel.pathoplexusOrganism = organism
                                }
                                viewModel.results = []
                                viewModel.selectedRecords = []
                                viewModel.selectedRecord = nil
                                viewModel.totalResultCount = 0
                                viewModel.hasMoreResults = false
                                viewModel.searchPhase = .idle
                                viewModel.errorMessage = nil
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } searchExtras: {
                EmptyView()
            }
        }
    }
}

struct PathoplexusChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, x + size.width)
            x += size.width + spacing
        }

        return CGSize(width: totalWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
    }
}
```

Update `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` `loadView()` to host the unified dialog:

```swift
    private var dialogState: DatabaseSearchDialogState!

    public override func loadView() {
        dialogState = DatabaseSearchDialogState(
            initialDestination: DatabaseSearchDestination(databaseSource: databaseSource)
        )

        if let searchType = initialSearchType {
            dialogState.genBankGenomesViewModel.ncbiSearchType = searchType
        }

        dialogState.applyCallbacks(
            onCancel: { [weak self] in
                guard let self = self else { return }
                if let window = self.view.window {
                    if let parent = window.sheetParent {
                        parent.endSheet(window)
                    } else {
                        window.close()
                    }
                }
                self.onCancel?()
            },
            onDownloadStarted: { [weak self] in
                self?.onDownloadStarted?()
            }
        )

        let browserView = DatabaseSearchDialog(state: dialogState)
        hostingView = NSHostingView(rootView: browserView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        self.view = hostingView
    }
```

After the new host wiring compiles, delete the legacy `DatabaseBrowserView` SwiftUI block and its local helper views from `DatabaseBrowserViewController.swift` so the controller file contains AppKit hosting and model/helper code only.

Update `Sources/LungfishApp/App/AppDelegate.swift` in `showDatabaseBrowser(source:)`:

```swift
    private func showDatabaseBrowser(source: DatabaseSource) {
        guard let window = mainWindowController?.window else { return }

        let browserController = DatabaseBrowserViewController(source: source)

        browserController.onDownloadStarted = {
            debugLog("onDownloadStarted: Dismissing sheet immediately")
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }

        let browserWindow = NSWindow(contentViewController: browserController)
        browserWindow.title = "Search Online Databases"

        window.beginSheet(browserWindow) { _ in
            debugLog("Sheet dismissed callback executing")
        }
    }
```

- [ ] **Step 4: Run the focused regression matrix**

Run: `swift test --filter 'DatasetOperationsDialogTests|DatabaseSearchDialogStateTests|DatabaseSearchDialogSourceTests|DatabaseBrowserViewModelTests|FASTQOperationDialogRoutingTests'`
Expected: all focused launcher, state, database-search, and FASTQ-operations regression suites PASS.

- [ ] **Step 5: Commit the Pathoplexus/controller integration and the visual-language regression guards**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift
git commit -m "refactor: route database search through shared launcher dialog"
```

### Task 5: Add Shared UI-Test Configuration and a Deterministic Database Search Automation Backend

Create the reusable launch-configuration layer and the first deterministic feature backend so real XCUITests can drive the app without hitting live network services.

**Files:**
- Create: `Sources/LungfishApp/App/AppUITestConfiguration.swift`
- Create: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchAutomationBackend.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialogState.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`
- Create: `Tests/LungfishAppTests/AppUITestConfigurationTests.swift`
- Create: `Tests/LungfishAppTests/DatabaseSearchAutomationBackendTests.swift`

- [ ] **Step 1: Write failing tests for app-wide UI-test launch parsing**

Create `Tests/LungfishAppTests/AppUITestConfigurationTests.swift`:

```swift
import XCTest
@testable import LungfishApp

final class AppUITestConfigurationTests: XCTestCase {
    func testLaunchArgumentEnablesUITestModeAndCapturesScenario() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--skip-welcome", "--ui-test-mode"],
            environment: ["LUNGFISH_UI_TEST_SCENARIO": "database-search-basic"]
        )

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.scenarioName, "database-search-basic")
    }

    func testNormalLaunchLeavesUITestModeDisabled() {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish"],
            environment: [:]
        )

        XCTAssertFalse(config.isEnabled)
        XCTAssertNil(config.scenarioName)
    }
}
```

- [ ] **Step 2: Write failing tests for deterministic database-search scenarios**

Create `Tests/LungfishAppTests/DatabaseSearchAutomationBackendTests.swift`:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class DatabaseSearchAutomationBackendTests: XCTestCase {
    func testBasicScenarioReturnsDeterministicRecordsPerDestination() async throws {
        let backend = try XCTUnwrap(DatabaseSearchAutomationBackend(scenarioName: "database-search-basic"))

        let ncbi = try await backend.search(
            DatabaseSearchAutomationRequest(
                source: .ncbi,
                ncbiSearchType: .nucleotide,
                searchText: "coronavirus"
            )
        )
        XCTAssertEqual(ncbi.records.map(\.accession), ["NC_045512.2", "PP000001.1"])

        let sra = try await backend.search(
            DatabaseSearchAutomationRequest(
                source: .ena,
                ncbiSearchType: .nucleotide,
                searchText: "SRR000001"
            )
        )
        XCTAssertEqual(sra.records.map(\.accession), ["SRR000001"])

        let pathoplexus = try await backend.search(
            DatabaseSearchAutomationRequest(
                source: .pathoplexus,
                ncbiSearchType: .nucleotide,
                searchText: "mpox"
            )
        )
        XCTAssertEqual(pathoplexus.records.map(\.accession), ["MPXV-OPEN-001"])
    }

    func testBasicScenarioSupportsNoOpDownloadSimulation() async throws {
        let backend = try XCTUnwrap(DatabaseSearchAutomationBackend(scenarioName: "database-search-basic"))
        let records = [
            SearchResultRecord(
                id: "NC_045512.2",
                accession: "NC_045512.2",
                title: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1, complete genome",
                source: .ncbi
            )
        ]

        try await backend.simulateDownload(records: records, source: .ncbi)
    }
}
```

- [ ] **Step 3: Run the new tests to verify they fail before the infrastructure exists**

Run: `swift test --filter 'AppUITestConfigurationTests|DatabaseSearchAutomationBackendTests' 2>&1 | tail -20`
Expected: build failures because `AppUITestConfiguration`, `DatabaseSearchAutomationBackend`, and `DatabaseSearchAutomationRequest` do not exist yet.

- [ ] **Step 4: Implement the reusable launch configuration and named database-search scenario backend**

Create `Sources/LungfishApp/App/AppUITestConfiguration.swift`:

```swift
import Foundation

struct AppUITestConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let scenarioName: String?

    init(arguments: [String], environment: [String: String]) {
        let explicitFlag = arguments.contains("--ui-test-mode")
        let envFlag = environment["LUNGFISH_UI_TEST_MODE"] == "1"
        self.isEnabled = explicitFlag || envFlag
        self.scenarioName = environment["LUNGFISH_UI_TEST_SCENARIO"]
    }

    static let current = AppUITestConfiguration(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
}
```

Create `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchAutomationBackend.swift`:

```swift
import Foundation
import LungfishCore

struct DatabaseSearchAutomationRequest: Sendable {
    let source: DatabaseSource
    let ncbiSearchType: NCBISearchType
    let searchText: String
}

enum DatabaseSearchUITestScenario: String, Sendable {
    case basic = "database-search-basic"
}

struct DatabaseSearchAutomationBackend: Sendable {
    let scenario: DatabaseSearchUITestScenario

    init?(scenarioName: String) {
        guard let scenario = DatabaseSearchUITestScenario(rawValue: scenarioName) else {
            return nil
        }
        self.scenario = scenario
    }

    init?(configuration: AppUITestConfiguration) {
        guard configuration.isEnabled,
              let scenarioName = configuration.scenarioName else {
            return nil
        }
        self.init(scenarioName: scenarioName)
    }

    func search(_ request: DatabaseSearchAutomationRequest) async throws -> SearchResults {
        let records: [SearchResultRecord]

        switch (scenario, request.source, request.ncbiSearchType) {
        case (.basic, .ncbi, .nucleotide):
            records = [
                SearchResultRecord(
                    id: "NC_045512.2",
                    accession: "NC_045512.2",
                    title: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1, complete genome",
                    organism: "Severe acute respiratory syndrome coronavirus 2",
                    length: 29_903,
                    source: .ncbi
                ),
                SearchResultRecord(
                    id: "PP000001.1",
                    accession: "PP000001.1",
                    title: "Synthetic respiratory virus reference",
                    organism: "Synthetic respiratory virus",
                    length: 14_552,
                    source: .ncbi
                ),
            ]

        case (.basic, .ena, _):
            records = [
                SearchResultRecord(
                    id: "SRR000001",
                    accession: "SRR000001",
                    title: "Example Illumina run",
                    length: 1_500_000,
                    source: .ena
                )
            ]

        case (.basic, .pathoplexus, _):
            records = [
                SearchResultRecord(
                    id: "MPXV-OPEN-001",
                    accession: "MPXV-OPEN-001",
                    title: "Open Pathoplexus mpox record",
                    organism: "Mpox virus",
                    length: 197_209,
                    source: .pathoplexus
                )
            ]

        default:
            records = []
        }

        return SearchResults(
            totalCount: records.count,
            records: records,
            hasMore: false,
            nextCursor: nil
        )
    }

    func simulateDownload(records: [SearchResultRecord], source: DatabaseSource) async throws {
        _ = (records, source)
    }
}
```

- [ ] **Step 5: Thread the optional automation backend through the database-search stack without disturbing live behavior**

Update `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialogState.swift`:

```swift
    init(
        initialDestination: DatabaseSearchDestination = .genBankGenomes,
        automationBackend: DatabaseSearchAutomationBackend? = nil
    ) {
        self.selectedDestination = initialDestination
        self.genBankGenomesViewModel = DatabaseBrowserViewModel(source: .ncbi, automationBackend: automationBackend)
        self.sraRunsViewModel = DatabaseBrowserViewModel(source: .ena, automationBackend: automationBackend)
        self.pathoplexusViewModel = DatabaseBrowserViewModel(source: .pathoplexus, automationBackend: automationBackend)
    }
```

Update `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` in `loadView()`:

```swift
        let automationBackend = DatabaseSearchAutomationBackend(configuration: AppUITestConfiguration.current)

        dialogState = DatabaseSearchDialogState(
            initialDestination: DatabaseSearchDestination(databaseSource: databaseSource),
            automationBackend: automationBackend
        )
```

Update `DatabaseBrowserViewModel` in the same file:

```swift
    private let automationBackend: DatabaseSearchAutomationBackend?

    init(source: DatabaseSource, automationBackend: DatabaseSearchAutomationBackend? = nil) {
        self.source = source
        self.automationBackend = automationBackend
        loadSearchHistory()
    }
```

At the top of `performSearch()`:

```swift
        if let automationBackend {
            currentSearchTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await automationBackend.search(
                        DatabaseSearchAutomationRequest(
                            source: self.source,
                            ncbiSearchType: self.ncbiSearchType,
                            searchText: self.searchText
                        )
                    )

                    await MainActor.run {
                        self.errorMessage = nil
                        self.results = response.records
                        self.selectedRecord = nil
                        self.selectedRecords = []
                        self.totalResultCount = response.totalCount
                        self.hasMoreResults = response.hasMore
                        self.searchPhase = .complete(count: response.records.count)
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.searchPhase = .failed(error.localizedDescription)
                    }
                }
            }
            return
        }
```

At the top of `performBatchDownload()` after `recordsToDownload` is computed:

```swift
        if let automationBackend {
            onDownloadStarted?()
            Task { [weak self] in
                do {
                    try await automationBackend.simulateDownload(records: recordsToDownload, source: self?.source ?? .ncbi)
                } catch {
                    await MainActor.run {
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }
```

- [ ] **Step 6: Re-run the focused automation-backend tests**

Run: `swift test --filter 'AppUITestConfigurationTests|DatabaseSearchAutomationBackendTests|DatabaseSearchDialogStateTests'`
Expected: all three suites PASS, proving the new launch configuration and deterministic search backend work without changing the live path.

- [ ] **Step 7: Commit the shared UI-test configuration and automation backend**

```bash
git add Sources/LungfishApp/App/AppUITestConfiguration.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchAutomationBackend.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialogState.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift Tests/LungfishAppTests/AppUITestConfigurationTests.swift Tests/LungfishAppTests/DatabaseSearchAutomationBackendTests.swift
git commit -m "test: add database search automation backend"
```

### Task 6: Add a Reusable Accessibility Contract for the Shared Launcher Shell and Database Search

Expose stable XCUI identifiers through the shared shell and the database-search panes so future app-wide XCUI work can reuse the same naming pattern.

**Files:**
- Modify: `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift`
- Modify: `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`

- [ ] **Step 1: Add failing source tests for reusable XCUI identifiers**

Extend `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`:

```swift
    func testDatabaseSearchDialogDeclaresReusableXCUIIdentifiers() throws {
        let shellSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift"),
            encoding: .utf8
        )
        let dialogSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift"),
            encoding: .utf8
        )
        let paneSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift"),
            encoding: .utf8
        )
        let genbankSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift"),
            encoding: .utf8
        )
        let pathoplexusSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(shellSource.contains("accessibilityNamespace"))
        XCTAssertTrue(dialogSource.contains("accessibilityNamespace: \"database-search\""))
        XCTAssertTrue(shellSource.contains("accessibilitySlug"))
        XCTAssertTrue(paneSource.contains("database-search-query-field"))
        XCTAssertTrue(paneSource.contains("database-search-results-list"))
        XCTAssertTrue(paneSource.contains("database-search-result-"))
        XCTAssertTrue(genbankSource.contains("database-search-ncbi-mode-picker"))
        XCTAssertTrue(pathoplexusSource.contains("database-search-pathoplexus-consent-accept"))
        XCTAssertTrue(pathoplexusSource.contains("database-search-pathoplexus-consent-cancel"))
    }
```

- [ ] **Step 2: Run the source tests to verify the new identifiers are missing**

Run: `swift test --filter DatabaseSearchDialogSourceTests 2>&1 | tail -20`
Expected: the new identifier assertions fail because the shared shell and panes do not expose stable XCUI identifiers yet.

- [ ] **Step 3: Add a namespaced accessibility API to the shared shell and wire the database-search pane IDs**

Update `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift`:

```swift
struct DatasetOperationsDialog<Detail: View>: View {
    let title: String
    let subtitle: String
    let datasetLabel: String
    let tools: [DatasetOperationToolSidebarItem]
    let selectedToolID: String
    let statusText: String
    let isRunEnabled: Bool
    let primaryActionTitle: String
    let accessibilityNamespace: String?
    let onSelectTool: (String) -> Void
    let onCancel: () -> Void
    let onRun: () -> Void
    @ViewBuilder let detail: () -> Detail

    private func scopedID(_ suffix: String) -> String? {
        accessibilityNamespace.map { "\($0)-\(suffix)" }
    }

    private func accessibilitySlug(for value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    var body: some View {
        HStack(spacing: 0) {
            toolSidebar
                .frame(width: 260)
                .background(Color.lungfishSidebarBackground)
            Divider()
            VStack(spacing: 0) {
                detailPane
                Divider()
                footerBar
            }
            .background(Color.lungfishCanvasBackground)
        }
        .lungfishAccessibilityIdentifier(scopedID("dialog"))
        .background(Color.lungfishCanvasBackground)
    }

    @MainActor
    init(
        title: String,
        subtitle: String,
        datasetLabel: String,
        tools: [DatasetOperationToolSidebarItem],
        selectedToolID: String,
        statusText: String,
        isRunEnabled: Bool,
        primaryActionTitle: String = "Run",
        accessibilityNamespace: String? = nil,
        onSelectTool: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onRun: @escaping () -> Void,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.title = title
        self.subtitle = subtitle
        self.datasetLabel = datasetLabel
        self.tools = tools
        self.selectedToolID = selectedToolID
        self.statusText = statusText
        self.isRunEnabled = isRunEnabled
        self.primaryActionTitle = primaryActionTitle
        self.accessibilityNamespace = accessibilityNamespace
        self.onSelectTool = onSelectTool
        self.onCancel = onCancel
        self.onRun = onRun
        self.detail = detail
    }

    private var toolSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ...
                ForEach(tools) { tool in
                    Button {
                        selectToolIfAvailable(tool)
                    } label: {
                        ...
                    }
                    .lungfishAccessibilityIdentifier(scopedID("tool-\(accessibilitySlug(for: tool.title))"))
                    .buttonStyle(.plain)
                    .disabled(!canSelect(tool))
                }
            }
            .padding(16)
        }
        .lungfishAccessibilityIdentifier(scopedID("sidebar"))
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .lungfishAccessibilityIdentifier(scopedID("status-text"))
                .font(.caption)
                .foregroundStyle(isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
            Spacer()
            Button("Cancel", action: onCancel)
                .lungfishAccessibilityIdentifier(scopedID("cancel"))
            Button(primaryActionTitle, action: runIfEnabled)
                .lungfishAccessibilityIdentifier(scopedID("primary-action"))
                .buttonStyle(.borderedProminent)
                .tint(.lungfishCreamsicleFallback)
                .disabled(!isRunEnabled)
        }
        .padding(16)
        .background(Color.lungfishCanvasBackground)
    }
}

private extension View {
    @ViewBuilder
    func lungfishAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
```

Update `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift`:

```swift
        DatasetOperationsDialog(
            title: state.dialogTitle,
            subtitle: state.dialogSubtitle,
            datasetLabel: state.contextLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: statusText,
            isRunEnabled: isPrimaryActionEnabled,
            primaryActionTitle: primaryActionTitle,
            accessibilityNamespace: "database-search",
            onSelectTool: state.selectDestination(named:),
            onCancel: state.cancel,
            onRun: state.performPrimaryAction
        ) {
            detail()
        }
```

Update `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift`:

```swift
            AppKitTextField(
                text: $viewModel.searchText,
                placeholder: searchPlaceholder,
                onSubmit: {
                    viewModel.performSearch()
                }
            )
            .accessibilityIdentifier("database-search-query-field")
            .frame(minWidth: 260)
```

```swift
                List(viewModel.filteredResults) { record in
                    DatabaseSearchResultRow(
                        record: record,
                        isSelected: viewModel.selectedRecords.contains(record),
                        onToggle: {
                            toggleSelection(for: record)
                        }
                    )
                    .listRowSeparator(.hidden)
                }
                .accessibilityIdentifier("database-search-results-list")
                .listStyle(.plain)
```

```swift
        .accessibilityIdentifier("database-search-result-\(record.accession)")
        .buttonStyle(.plain)
```

Update `Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift`:

```swift
                Picker("Mode", selection: $viewModel.ncbiSearchType) {
                    Text("Nucleotide").tag(NCBISearchType.nucleotide)
                    Text("Genome").tag(NCBISearchType.genome)
                    Text("Virus").tag(NCBISearchType.virus)
                }
                .accessibilityIdentifier("database-search-ncbi-mode-picker")
                .pickerStyle(.segmented)
```

Update `Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift` consent buttons:

```swift
            Button("Cancel") {
                viewModel.onCancel?()
            }
            .accessibilityIdentifier("database-search-pathoplexus-consent-cancel")

            Button("I Understand and Agree") {
                viewModel.acceptPathoplexusConsent()
            }
            .accessibilityIdentifier("database-search-pathoplexus-consent-accept")
            .buttonStyle(.borderedProminent)
```

- [ ] **Step 4: Re-run the database-search source tests**

Run: `swift test --filter DatabaseSearchDialogSourceTests`
Expected: the source tests PASS and prove the reusable XCUI identifier contract is present in the shared shell and database-search surfaces.

- [ ] **Step 5: Commit the accessibility contract**

```bash
git add Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift
git commit -m "test: add reusable xcui identifiers for database search"
```

### Task 7: Add the Real Xcode UI-Test Bundle and the First Menu-Driven Database Search Flows

Create the actual XCUITest target, hook it into the shared `Lungfish` scheme, and cover the first menu-driven app flows using the deterministic database-search scenario.

**Files:**
- Modify: `Lungfish.xcodeproj/project.pbxproj`
- Modify: `Lungfish.xcodeproj/xcshareddata/xcschemes/Lungfish.xcscheme`
- Create: `Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift`
- Create: `Tests/LungfishXCUITests/DatabaseSearchXCUITests.swift`

- [ ] **Step 1: Write the first real XCUITest files**

Create `Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift`:

```swift
import XCTest

struct LungfishAppRobot {
    let app = XCUIApplication()

    func launchDatabaseSearchScenario(named scenario: String) {
        app.launchArguments = ["--skip-welcome", "--ui-test-mode"]
        app.launchEnvironment["LUNGFISH_UI_TEST_SCENARIO"] = scenario
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    func openDatabaseSearch(named menuTitle: String) {
        app.menuBars.menuBarItems["Tools"].click()

        let searchDatabases = app.menuItems["Search Online Databases..."]
        XCTAssertTrue(searchDatabases.waitForExistence(timeout: 2))
        searchDatabases.click()

        let menuItem = app.menuItems[menuTitle]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2))
        menuItem.click()

        XCTAssertTrue(app.otherElements["database-search-dialog"].waitForExistence(timeout: 5))
    }
}
```

Create `Tests/LungfishXCUITests/DatabaseSearchXCUITests.swift`:

```swift
import XCTest

final class DatabaseSearchXCUITests: XCTestCase {
    func testToolsMenuOpensUnifiedDatabaseSearchDialog() {
        let robot = LungfishAppRobot()
        robot.launchDatabaseSearchScenario(named: "database-search-basic")
        robot.openDatabaseSearch(named: "Search NCBI...")

        let app = robot.app
        XCTAssertTrue(app.buttons["database-search-tool-genbank-genomes"].exists)
        XCTAssertTrue(app.buttons["database-search-tool-sra-runs"].exists)
        XCTAssertTrue(app.buttons["database-search-tool-pathoplexus"].exists)
        XCTAssertEqual(app.buttons["database-search-primary-action"].label, "Search")
    }

    func testPathoplexusRequiresConsentBeforeSearching() {
        let robot = LungfishAppRobot()
        robot.launchDatabaseSearchScenario(named: "database-search-basic")
        robot.openDatabaseSearch(named: "Search Pathoplexus...")

        let app = robot.app
        XCTAssertFalse(app.buttons["database-search-primary-action"].isEnabled)
        app.buttons["database-search-pathoplexus-consent-accept"].click()
        XCTAssertTrue(app.buttons["database-search-primary-action"].isEnabled)
    }

    func testDestinationSwitchingPreservesEnteredQueries() {
        let robot = LungfishAppRobot()
        robot.launchDatabaseSearchScenario(named: "database-search-basic")
        robot.openDatabaseSearch(named: "Search NCBI...")

        let app = robot.app
        let queryField = app.textFields["database-search-query-field"]

        queryField.click()
        queryField.typeText("coronavirus")

        app.buttons["database-search-tool-sra-runs"].click()
        queryField.click()
        queryField.typeText("SRR000001")

        app.buttons["database-search-tool-genbank-genomes"].click()
        XCTAssertEqual(queryField.value as? String, "coronavirus")
    }

    func testStubbedSearchTransitionsPrimaryActionToDownloadSelected() {
        let robot = LungfishAppRobot()
        robot.launchDatabaseSearchScenario(named: "database-search-basic")
        robot.openDatabaseSearch(named: "Search NCBI...")

        let app = robot.app
        let queryField = app.textFields["database-search-query-field"]
        queryField.click()
        queryField.typeText("coronavirus")

        let primaryAction = app.buttons["database-search-primary-action"]
        primaryAction.click()

        XCTAssertTrue(app.otherElements["database-search-results-list"].waitForExistence(timeout: 5))

        let resultRow = app.buttons["database-search-result-NC_045512.2"]
        XCTAssertTrue(resultRow.waitForExistence(timeout: 5))
        resultRow.click()

        XCTAssertEqual(primaryAction.label, "Download Selected")
    }
}
```

- [ ] **Step 2: Run the new XCUI command to verify it fails before the Xcode target exists**

Run: `xcodebuild test -project /Users/dho/Documents/lungfish-genome-explorer/.worktrees/search-online-database-refactor/Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/DatabaseSearchXCUITests`
Expected: failure because `LungfishXCUITests` is not yet a testable target in the Xcode project or shared scheme.

- [ ] **Step 3: Add the real `LungfishXCUITests` bundle target and include it in the shared scheme**

Update `Lungfish.xcodeproj/project.pbxproj` so the project contains a new native target named `LungfishXCUITests` with:

- product type `com.apple.product-type.bundle.ui-testing`
- a product named `LungfishXCUITests.xctest`
- a target dependency on `Lungfish`
- a sources build phase containing:
  - `Tests/LungfishXCUITests/DatabaseSearchXCUITests.swift`
  - `Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift`

Update `Lungfish.xcodeproj/xcshareddata/xcschemes/Lungfish.xcscheme` `TestAction` to include a `TestableReference` for `LungfishXCUITests.xctest` alongside the app scheme’s normal test action.

The shared scheme must end up with a `TestableReference` that points at `BlueprintName = "LungfishXCUITests"` and `BuildableName = "LungfishXCUITests.xctest"` so `xcodebuild test` can discover the new GUI tests.

- [ ] **Step 4: Run the menu-driven XCUI flow end-to-end**

Run: `xcodebuild test -project /Users/dho/Documents/lungfish-genome-explorer/.worktrees/search-online-database-refactor/Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/DatabaseSearchXCUITests`
Expected: the new app-driven GUI tests PASS, proving:

- the app launches in reusable UI-test mode
- the `Tools` menu opens the online database search dialog
- Pathoplexus consent gating works
- destination switching preserves entered query text
- the deterministic search scenario transitions the primary action from `Search` to `Download Selected`

- [ ] **Step 5: Commit the new XCUI target and tests**

```bash
git add Lungfish.xcodeproj/project.pbxproj Lungfish.xcodeproj/xcshareddata/xcschemes/Lungfish.xcscheme Tests/LungfishXCUITests/TestSupport/LungfishAppRobot.swift Tests/LungfishXCUITests/DatabaseSearchXCUITests.swift
git commit -m "test: add menu-driven database search xcui coverage"
```

## Self-Review

### Spec Coverage

- Shared shell reuse is covered by Task 1 and Task 3.
- Approved destination names and preserved per-destination state are covered by Task 2.
- Destination-specific panes and right-pane-only NCBI mode selection are covered by Task 3 and Task 4.
- Pathoplexus consent gating is covered by Task 4.
- Decorative glyph removal is covered by Task 3 shared pane extraction and Task 4 banned-symbol source tests.
- Reuse/extraction of launcher-style framework pieces is covered by Task 1 plus the new shell/state/pane files.
- The reusable app-level UI-test configuration layer is covered by Task 5.
- The deterministic database-search backend and named scenario plumbing are covered by Task 5.
- The reusable XCUI accessibility contract is covered by Task 6.
- The real app-driven `XCUIApplication` harness, menu navigation, and first menu-driven flows are covered by Task 7.

### Placeholder Scan

- No `TODO`, `TBD`, or “implement later” placeholders remain.
- Every task includes concrete files, tests, commands, code, and commit messages.

### Type Consistency

- `DatabaseSearchDestination`, `DatabaseSearchDialogState`, `DatabaseSearchDialog`, and `DatabaseBrowserPane` are named consistently across all tasks.
- The controller wiring uses `dialogState` everywhere, not a mix of `state`, `viewModel`, and `dialogModel`.
- The shared shell continues using `primaryActionTitle` while preserving `onRun` for existing FASTQ callers.
- The reusable launch parser is consistently named `AppUITestConfiguration`.
- The deterministic GUI fixture path consistently uses `DatabaseSearchAutomationBackend` and the named scenario `database-search-basic`.
- The XCUI files consistently use the `database-search-*` accessibility namespace so future features can follow the same pattern.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-19-database-search-operations-dialog.md`. Two execution options:

1. Subagent-Driven (recommended) - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?

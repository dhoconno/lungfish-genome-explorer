# Unified Classifier Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the separate Kraken2, EsViritu, and TaxTriage run sheets with one shared classifier runner window that uses the Lungfish sidebar pattern, standardized copy, and consistent shared sections.

**Architecture:** Refactor the existing `UnifiedMetagenomicsWizard` from a two-step chooser into the real shared runner shell. Keep the underlying run callbacks and config types unchanged in the first pass, but extract the old sheet views into panel content that renders inside a common sidebar + shared footer container. Route every classifier launch path through that shell with a preselected tool.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit `NSPanel` + `NSHostingController`, LungfishApp, LungfishWorkflow, XCTest.

---

## File Map

### Existing files to modify

- `Sources/LungfishWorkflow/Conda/PluginPack.swift`
  - Update the visible metagenomics pack description.
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
  - Update classifier action labels/tooltips and keep dispatch routing stable.
- `Sources/LungfishApp/App/AppDelegate.swift`
  - Route all three launch actions through the unified runner shell with a preselected tool.
- `Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift`
  - Convert from chooser-style flow into the shared classifier runner shell.
- `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
  - Strip standalone shell concerns and expose Kraken2 content in shared-section form.
- `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift`
  - Strip standalone shell concerns and expose EsViritu content in shared-section form.
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`
  - Strip standalone shell concerns, rename header/title copy, and expose TaxTriage content in shared-section form.
- `Tests/LungfishAppTests/GUIRegressionTests.swift`
  - Update existing unified wizard metadata assertions to the new names and structure.
- `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
  - Assert the metagenomics pack description matches the new wording.

### New files to create

- `Sources/LungfishApp/Views/Metagenomics/UnifiedClassifierRunnerSection.swift`
  - Shared section container, header block, prerequisite row, and shared footer helpers for the runner shell.
- `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`
  - Focused view-model/source-level tests for selected tool state, sidebar labels, shared section order, and launch copy.

### Existing files intentionally left untouched in this pass

- Execution pipelines and config types in `Sources/LungfishWorkflow/Metagenomics/`
- Import-oriented metagenomics flows such as NVD and NAO-MGS
- Classifier result viewers

---

## Task 1: Lock terminology with failing tests first

**Files:**
- Modify: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
- Modify: `Tests/LungfishAppTests/GUIRegressionTests.swift`
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`

- [ ] **Step 1: Write the failing pack-description test**

Add to `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`:

```swift
func testMetagenomicsPackUsesPathogenDetectionDescription() {
    let pack = try! XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))
    XCTAssertEqual(
        pack.description,
        "Taxonomic classification and pathogen detection from metagenomic samples"
    )
}
```

- [ ] **Step 2: Write the failing unified-wizard copy test**

Add to `Tests/LungfishAppTests/GUIRegressionTests.swift` inside `UnifiedWizardTests`:

```swift
func testAnalysisTypeMetadataUsesUpdatedToolLabels() {
    let typeMap = Dictionary(uniqueKeysWithValues: UnifiedMetagenomicsWizard.AnalysisType.allCases.map { ($0, $0.toolName) })
    XCTAssertEqual(typeMap[.classification], "Classify & Profile (Kraken2)")
    XCTAssertEqual(typeMap[.viralDetection], "Detect Viruses (EsViritu)")
    XCTAssertEqual(typeMap[.clinicalTriage], "Detect Pathogens (TaxTriage)")
}
```

- [ ] **Step 3: Write the failing FASTQ operation label test**

Add to `Tests/LungfishAppTests/GUIRegressionTests.swift`:

```swift
func testFastqOperationSourceUsesUpdatedTaxTriageLabel() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains(#"case .comprehensiveTriage: return "Detect Pathogens (TaxTriage)""#))
    XCTAssertFalse(source.contains(#"case .comprehensiveTriage: return "Clinical Triage (TaxTriage)""#))
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run:

```bash
swift test --filter 'PluginPackRegistryTests|UnifiedWizardTests' 2>&1 | tail -40
```

Expected:
- Failure for the old metagenomics description
- Failure for old `AnalysisType.toolName`
- Failure because the FASTQ dataset source still contains `Clinical Triage (TaxTriage)`

- [ ] **Step 5: Implement the minimal copy changes**

Update `Sources/LungfishWorkflow/Conda/PluginPack.swift`:

```swift
PluginPack(
    id: "metagenomics",
    name: "Metagenomics",
    description: "Taxonomic classification and pathogen detection from metagenomic samples",
    sfSymbol: "leaf.fill",
    packages: ["kraken2", "bracken", "esviritu"],
```

Update `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`:

```swift
case .classifyReads: return "Classify & Profile (Kraken2)"
case .detectViruses: return "Detect Viruses (EsViritu)"
case .comprehensiveTriage: return "Detect Pathogens (TaxTriage)"
```

And update the tooltip copy:

```swift
case .comprehensiveTriage:
    return "Run TaxTriage for end-to-end pathogen detection from metagenomic reads with confidence scoring and organism reporting."
```

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
swift test --filter 'PluginPackRegistryTests|UnifiedWizardTests' 2>&1 | tail -40
```

Expected:
- PASS

- [ ] **Step 7: Commit**

Run:

```bash
git add Sources/LungfishWorkflow/Conda/PluginPack.swift \
        Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift \
        Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift \
        Tests/LungfishAppTests/GUIRegressionTests.swift
git commit -m "refactor: update classifier terminology"
```

---

## Task 2: Define the shared runner shell contract with tests

**Files:**
- Create: `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift`

- [ ] **Step 1: Write the failing selected-tool and sidebar tests**

Create `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`:

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class UnifiedClassifierRunnerTests: XCTestCase {

    func testClassifierToolCasesExposeDisplayNames() {
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.classification.sidebarTitle, "Kraken2")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.viralDetection.sidebarTitle, "EsViritu")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.clinicalTriage.sidebarTitle, "TaxTriage")
    }

    func testClassifierToolCasesExposeUpdatedRunnerTitles() {
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.classification.runnerTitle, "Kraken2")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.viralDetection.runnerTitle, "EsViritu")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.clinicalTriage.runnerTitle, "TaxTriage")
    }

    func testClassifierToolCasesExposeSharedSectionOrder() {
        XCTAssertEqual(
            UnifiedMetagenomicsWizard.sharedSectionOrder,
            ["Overview", "Prerequisites", "Samples", "Database", "Tool Settings", "Advanced Settings"]
        )
    }

    func testWizardSupportsPreselectedToolInitialization() {
        let wizard = UnifiedMetagenomicsWizard(
            inputFiles: [],
            initialSelection: .clinicalTriage
        )

        XCTAssertEqual(wizard.testingInitialSelection, .clinicalTriage)
    }
}
```

- [ ] **Step 2: Write the failing source-layout test**

Append to `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`:

```swift
func testUnifiedWizardSourceUsesSidebarInsteadOfChooseTypeStep() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains("sidebarSelection"))
    XCTAssertTrue(source.contains("runnerSidebar"))
    XCTAssertFalse(source.contains("WizardStep"))
    XCTAssertFalse(source.contains("analysisTypeSelector"))
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
swift test --filter UnifiedClassifierRunnerTests 2>&1 | tail -40
```

Expected:
- Missing `sidebarTitle`, `runnerTitle`, `sharedSectionOrder`, `initialSelection`, and `testingInitialSelection`
- Source test fails because the file still contains the old chooser-step identifiers

- [ ] **Step 4: Implement the minimal shell contract**

In `Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift`, add the new API surface:

```swift
struct UnifiedMetagenomicsWizard: View {
    let inputFiles: [URL]
    let initialSelection: AnalysisType

    init(
        inputFiles: [URL],
        initialSelection: AnalysisType = .classification,
        onRunClassification: (([ClassificationConfig]) -> Void)? = nil,
        onRunEsViritu: (([EsVirituConfig]) -> Void)? = nil,
        onRunTaxTriage: ((TaxTriageConfig) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.initialSelection = initialSelection
        self.onRunClassification = onRunClassification
        self.onRunEsViritu = onRunEsViritu
        self.onRunTaxTriage = onRunTaxTriage
        self.onCancel = onCancel
        _sidebarSelection = State(initialValue: initialSelection)
    }

    #if DEBUG
    var testingInitialSelection: AnalysisType { initialSelection }
    #endif

    @State private var sidebarSelection: AnalysisType

    static let sharedSectionOrder = [
        "Overview", "Prerequisites", "Samples", "Database", "Tool Settings", "Advanced Settings",
    ]
}
```

And update `AnalysisType`:

```swift
enum AnalysisType: String, CaseIterable, Identifiable {
    case classification
    case viralDetection
    case clinicalTriage

    var id: String { rawValue }

    var sidebarTitle: String {
        switch self {
        case .classification: return "Kraken2"
        case .viralDetection: return "EsViritu"
        case .clinicalTriage: return "TaxTriage"
        }
    }

    var runnerTitle: String { sidebarTitle }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
swift test --filter UnifiedClassifierRunnerTests 2>&1 | tail -40
```

Expected:
- PASS

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift \
        Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift
git commit -m "refactor: define unified classifier runner shell contract"
```

---

## Task 3: Build the shared runner shell and section components

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/UnifiedClassifierRunnerSection.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`
- Modify: `Tests/LungfishAppTests/WindowAppearanceTests.swift`

- [ ] **Step 1: Write the failing shared-layout source tests**

Add to `Tests/LungfishAppTests/WindowAppearanceTests.swift`:

```swift
func testUnifiedClassifierRunnerSourceUsesSidebarLayout() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains("NavigationSplitView") || source.contains("HSplitView"))
    XCTAssertTrue(source.contains("runnerSidebar"))
    XCTAssertTrue(source.contains("runnerDetail"))
    XCTAssertTrue(source.contains("Color.lungfishCanvasBackground"))
}

func testToolPanelsNoLongerRenderStandaloneFooterShells() throws {
    let classificationSource = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift"),
        encoding: .utf8
    )
    let esvirituSource = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift"),
        encoding: .utf8
    )
    let taxtriageSource = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift"),
        encoding: .utf8
    )

    XCTAssertFalse(classificationSource.contains("Button(\"Cancel\")"))
    XCTAssertFalse(esvirituSource.contains("Button(\"Cancel\")"))
    XCTAssertFalse(taxtriageSource.contains("Button(\"Cancel\")"))
    XCTAssertFalse(classificationSource.contains("Divider()\n\n            // Action buttons"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter WindowAppearanceTests 2>&1 | tail -60
```

Expected:
- Failure because the unified wizard still uses the old chooser flow
- Failure because the three tool views still include their own footer/button shells

- [ ] **Step 3: Create the shared section helper file**

Create `Sources/LungfishApp/Views/Metagenomics/UnifiedClassifierRunnerSection.swift`:

```swift
import SwiftUI

struct UnifiedClassifierRunnerSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            content
        }
    }
}

struct UnifiedClassifierRunnerHeader: View {
    let title: String
    let subtitle: String
    let datasetLabel: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }
            Spacer()
            Text(datasetLabel)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
```

- [ ] **Step 4: Convert the unified wizard into the shared shell**

Update `UnifiedMetagenomicsWizard.swift` so the body uses:

```swift
var body: some View {
    HStack(spacing: 0) {
        runnerSidebar
            .frame(width: 220)
            .background(Color.lungfishPeachSidebarBackground)

        Divider()

        VStack(alignment: .leading, spacing: 0) {
            runnerDetail
            Divider()
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lungfishCanvasBackground)
    }
    .frame(width: 880, height: 620)
    .onAppear { checkToolAvailability() }
}
```

And introduce:

```swift
private var runnerSidebar: some View { ... }
private var runnerDetail: some View { ... }
private var footerBar: some View { ... }
```

The footer must own:

```swift
Button("Cancel") { onCancel?() }
Button("Run") { runSelectedTool() }
```

- [ ] **Step 5: Strip standalone shell concerns from the three tool views**

For each of the three tool views:

- remove outer header
- remove outer footer/action buttons
- keep their inner sections
- expose a body that can render inside `runnerDetail`

Use a pattern like:

```swift
struct ClassificationWizardSheet: View {
    let inputFiles: [URL]
    let embeddedInUnifiedRunner: Bool
    ...
}
```

And gate legacy outer-shell code behind:

```swift
if embeddedInUnifiedRunner {
    embeddedContent
} else {
    legacyStandaloneContent
}
```

Then immediately switch all callers in this pass to `embeddedInUnifiedRunner: true`.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
swift test --filter 'WindowAppearanceTests|UnifiedClassifierRunnerTests|UnifiedWizardTests' 2>&1 | tail -80
```

Expected:
- PASS

- [ ] **Step 7: Commit**

Run:

```bash
git add Sources/LungfishApp/Views/Metagenomics/UnifiedClassifierRunnerSection.swift \
        Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift \
        Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift \
        Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift \
        Tests/LungfishAppTests/WindowAppearanceTests.swift \
        Tests/LungfishAppTests/GUIRegressionTests.swift \
        Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift
git commit -m "refactor: build shared classifier runner shell"
```

---

## Task 4: Route all classifier launches through the unified shell

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`

- [ ] **Step 1: Write the failing launch-routing source test**

Add to `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`:

```swift
func testAppDelegateLaunchesUseUnifiedRunnerWithPreselectedTool() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains("UnifiedMetagenomicsWizard("))
    XCTAssertTrue(source.contains("initialSelection: .classification"))
    XCTAssertTrue(source.contains("initialSelection: .viralDetection"))
    XCTAssertTrue(source.contains("initialSelection: .clinicalTriage"))
    XCTAssertFalse(source.contains("let sheet = ClassificationWizardSheet("))
    XCTAssertFalse(source.contains("let sheet = EsVirituWizardSheet("))
    XCTAssertFalse(source.contains("let sheet = TaxTriageWizardSheet("))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter UnifiedClassifierRunnerTests 2>&1 | tail -40
```

Expected:
- Failure because `AppDelegate` still instantiates the three old sheet types directly

- [ ] **Step 3: Implement unified launch wiring**

In `Sources/LungfishApp/App/AppDelegate.swift`, replace each direct sheet construction with:

```swift
let sheet = UnifiedMetagenomicsWizard(
    inputFiles: bundleURLs,
    initialSelection: .classification,
    onRunClassification: { [weak self] configs in
        window.endSheet(wizardPanel)
        guard let self else { return }
        self.runClassification(configs: configs, viewerController: viewerController)
    },
    onRunEsViritu: { [weak self] configs in
        window.endSheet(wizardPanel)
        guard let self else { return }
        self.runEsViritu(configs: configs, viewerController: viewerController)
    },
    onRunTaxTriage: { [weak self] config in
        window.endSheet(wizardPanel)
        guard let self else { return }
        self.runTaxTriage(config: config, viewerController: viewerController)
    },
    onCancel: { window.endSheet(wizardPanel) }
)
```

Then repeat with `initialSelection: .viralDetection` and `.clinicalTriage` in the other launch methods.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter UnifiedClassifierRunnerTests 2>&1 | tail -40
```

Expected:
- PASS

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/LungfishApp/App/AppDelegate.swift \
        Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift
git commit -m "refactor: route classifier launches through unified runner"
```

---

## Task 5: Normalize TaxTriage-specific copy and shared footer behavior

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`
- Modify: `Tests/LungfishAppTests/GUIRegressionTests.swift`
- Modify: `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`

- [ ] **Step 1: Write the failing TaxTriage title/copy tests**

Add to `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`:

```swift
func testTaxTriageSourceUsesSimpleTitle() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains(#"Text("TaxTriage")"#))
    XCTAssertFalse(source.contains("TaxTriage Metagenomic Triage"))
    XCTAssertFalse(source.contains("Comprehensive taxonomic classification pipeline"))
}
```

Add to `Tests/LungfishAppTests/GUIRegressionTests.swift`:

```swift
func testAnalysisTypeDescriptionAvoidsClinicalTriageLabel() {
    XCTAssertFalse(UnifiedMetagenomicsWizard.AnalysisType.clinicalTriage.analysisDescription.contains("clinical triage"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter 'UnifiedClassifierRunnerTests|UnifiedWizardTests' 2>&1 | tail -40
```

Expected:
- Failure because TaxTriage source still uses the old title/subtitle
- Failure because the old unified wizard description still says `clinical triage`

- [ ] **Step 3: Implement the TaxTriage copy normalization**

Update `UnifiedMetagenomicsWizard.AnalysisType`:

```swift
case .clinicalTriage:
    return "Detect pathogens from metagenomic reads using TaxTriage with alignment-based confidence scoring."
```

Update `TaxTriageWizardSheet.swift` header content:

```swift
UnifiedClassifierRunnerHeader(
    title: "TaxTriage",
    subtitle: "Detect pathogens from metagenomic reads with confidence scoring",
    datasetLabel: datasetLabel
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter 'UnifiedClassifierRunnerTests|UnifiedWizardTests' 2>&1 | tail -40
```

Expected:
- PASS

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift \
        Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift \
        Tests/LungfishAppTests/GUIRegressionTests.swift \
        Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift
git commit -m "refactor: simplify taxtriage runner copy"
```

---

## Task 6: Final regression pass and cleanup

**Files:**
- Modify: any files touched above only if final fixes are required

- [ ] **Step 1: Run the focused classifier runner regression suite**

Run:

```bash
swift test --filter 'PluginPackRegistryTests|UnifiedWizardTests|UnifiedClassifierRunnerTests|WindowAppearanceTests|GUIRegressionTests' 2>&1 | tail -100
```

Expected:
- PASS

- [ ] **Step 2: Run the impacted launch/setup regression suite**

Run:

```bash
swift test --filter 'WelcomeSetupTests|ImportCenterMenuTests|DatabasesTabTests|RuntimeResourceLocatorTests|CLIRegressionTests' 2>&1 | tail -100
```

Expected:
- PASS

- [ ] **Step 3: Build the app target**

Run:

```bash
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS' build | tail -40
```

Expected:
- `** BUILD SUCCEEDED **`

- [ ] **Step 4: Sanity-check final source invariants**

Run:

```bash
rg -n 'Clinical Triage \\(TaxTriage\\)|TaxTriage Metagenomic Triage|analysisTypeSelector|WizardStep' \
  Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift \
  Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift \
  Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift
```

Expected:
- No matches

- [ ] **Step 5: Final commit**

Run:

```bash
git status --short
git add Sources/LungfishApp/App/AppDelegate.swift \
        Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift \
        Sources/LungfishWorkflow/Conda/PluginPack.swift \
        Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift \
        Sources/LungfishApp/Views/Metagenomics/UnifiedClassifierRunnerSection.swift \
        Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift \
        Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift \
        Tests/LungfishAppTests/GUIRegressionTests.swift \
        Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift \
        Tests/LungfishAppTests/WindowAppearanceTests.swift \
        Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift
git commit -m "refactor: unify classifier runner interface"
```

---

## Spec Coverage Check

- Updated optional-pack wording:
  - Covered by Task 1.
- Updated FASTQ dataset labels:
  - Covered by Task 1.
- Replace separate runner sheets with one consistent interface:
  - Covered by Tasks 2–4.
- Shared right-panel elements and section rhythm:
  - Covered by Task 3.
- TaxTriage title simplification:
  - Covered by Task 5.
- Keep imports separate from run flow:
  - Preserved by scope; no import files are modified in this plan.

## Notes For Execution

- Keep the pipeline callbacks and config types untouched unless a compile fix requires a trivial signature adapter.
- Prefer extracting shared view fragments over introducing a generic form engine.
- If one tool cannot naturally show a section, omit the body content but preserve the overall order in the shell where the section exists.
- Do not expand scope into NVD, NAO-MGS, or classifier result viewers during this plan.

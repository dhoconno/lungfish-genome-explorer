# Harmonized Reference Mapping View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `.lungfishref` bundle use the same list/detail reference mapping viewport as mapping bundles, with track-aware Inspector controls, explicit full-viewport focus mode, and no stale browse-first default behavior.

**Architecture:** Introduce a generalized reference-bundle viewport input around the existing mapping viewport/detail renderer, then route direct `.lungfishref` bundles and mapping analysis directories through that shared path. Reuse lower-level bundle summary/list utilities where useful, but remove or rewrite old browse-first route entry points and tests. Inspector state flows from one loaded bundle context and track-capability model.

**Tech Stack:** Swift, AppKit, SwiftUI Inspector sections, XCTest, existing LungfishCore/LungfishIO/LungfishWorkflow bundle and mapping models.

---

## File Structure

- Create `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportInput.swift` for direct bundle vs mapping-result input state.
- Create `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift` by extracting/generalizing `MappingResultViewController`.
- Create `Sources/LungfishApp/Views/Results/Reference/ReferenceSequenceListTableView.swift` if `MappingContigTableView` cannot cleanly accept reference sequence rows.
- Create `Sources/LungfishApp/Views/Inspector/ReferenceBundleTrackCapabilities.swift` for visible/disabled action readiness.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift` to host the generalized viewport and keep mapping compatibility wrappers.
- Modify `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` to route `.referenceBundle` sidebar selections to the generalized viewport.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift` to remove browse-first default use, retaining only direct sequence loading needed by the embedded detail renderer.
- Modify `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` to update direct bundles and mapping viewer bundles through the same alignment/variant/action wiring.
- Modify `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift` and `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift` to support direct bundle context plus optional mapping provenance.
- Delete or rewrite browse-first tests in `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`, `Tests/LungfishAppTests/BundleViewerTests.swift`, `Tests/LungfishAppTests/BundleBrowserViewControllerTests.swift`, and `Tests/LungfishAppTests/BundleBrowserLayoutPreferenceTests.swift`.
- Keep `Sources/LungfishApp/Services/BundleBrowserLoader.swift`, `Sources/LungfishApp/Services/BundleBrowserMirrorStore.swift`, and `Sources/LungfishApp/Services/BundleSequenceSummarySynthesizer.swift` as sequence-summary utilities unless later tasks prove them unused.

---

### Task 1: Add Viewport Input and Direct Bundle Row Model

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportInput.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleViewportInputTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

final class ReferenceBundleViewportInputTests: XCTestCase {
    func testDirectBundleInputBuildsDocumentTitleFromManifestAndHasNoMappingContext() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/reference.lungfishref", isDirectory: true)
        let manifest = BundleManifest(
            name: "SARS-CoV-2 Reference",
            identifier: "org.lungfish.test.reference",
            source: .init(type: .imported, originalPath: nil, importedDate: Date(timeIntervalSince1970: 1)),
            genome: nil
        )

        let input = ReferenceBundleViewportInput.directBundle(
            bundleURL: bundleURL,
            manifest: manifest
        )

        XCTAssertEqual(input.renderedBundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(input.documentTitle, "SARS-CoV-2 Reference")
        XCTAssertNil(input.mappingResult)
        XCTAssertNil(input.mappingResultDirectoryURL)
        XCTAssertFalse(input.hasMappingRunContext)
    }

    func testMappingInputUsesViewerBundleAndKeepsResultDirectoryContext() throws {
        let resultDirectory = URL(fileURLWithPath: "/tmp/project/Analyses/minimap2-run", isDirectory: true)
        let viewerBundle = resultDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        let bam = resultDirectory.appendingPathComponent("sample.sorted.bam")
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundle,
            bamURL: bam,
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )

        let input = ReferenceBundleViewportInput.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectory,
            provenance: nil
        )

        XCTAssertEqual(input.renderedBundleURL, viewerBundle.standardizedFileURL)
        XCTAssertEqual(input.mappingResultDirectoryURL, resultDirectory.standardizedFileURL)
        XCTAssertTrue(input.hasMappingRunContext)
    }

    func testMappingInputWithoutViewerBundlePreservesUnavailableRenderableBundleState() throws {
        let resultDirectory = URL(fileURLWithPath: "/tmp/project/Analyses/minimap2-run", isDirectory: true)
        let bam = resultDirectory.appendingPathComponent("sample.sorted.bam")
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: nil,
            bamURL: bam,
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )

        let input = ReferenceBundleViewportInput.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectory,
            provenance: nil as MappingProvenance?
        )

        XCTAssertNil(input.renderedBundleURL)
        XCTAssertEqual(input.documentTitle, "minimap2-run")
        XCTAssertEqual(input.mappingResult, result)
        XCTAssertEqual(input.mappingResultDirectoryURL, resultDirectory.standardizedFileURL)
        XCTAssertTrue(input.hasMappingRunContext)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReferenceBundleViewportInputTests`

Expected: FAIL with `cannot find 'ReferenceBundleViewportInput' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportInput.swift`:

```swift
import Foundation
import LungfishCore
import LungfishWorkflow

struct ReferenceBundleViewportInput: Equatable {
    enum Kind: Equatable {
        case directBundle
        case mappingResult
    }

    let kind: Kind
    let renderedBundleURL: URL?
    let manifest: BundleManifest?
    let mappingResult: MappingResult?
    let mappingResultDirectoryURL: URL?
    let mappingProvenance: MappingProvenance?

    var documentTitle: String {
        manifest?.name
            ?? mappingResultDirectoryURL?.lastPathComponent
            ?? renderedBundleURL?.deletingPathExtension().lastPathComponent
            ?? "Reference Bundle"
    }

    var hasMappingRunContext: Bool {
        mappingResult != nil
    }

    static func directBundle(
        bundleURL: URL,
        manifest: BundleManifest
    ) -> ReferenceBundleViewportInput {
        ReferenceBundleViewportInput(
            kind: .directBundle,
            renderedBundleURL: bundleURL.standardizedFileURL,
            manifest: manifest,
            mappingResult: nil,
            mappingResultDirectoryURL: nil,
            mappingProvenance: nil
        )
    }

    static func mappingResult(
        result: MappingResult,
        resultDirectoryURL: URL?,
        provenance: MappingProvenance?
    ) -> ReferenceBundleViewportInput {
        ReferenceBundleViewportInput(
            kind: .mappingResult,
            renderedBundleURL: result.viewerBundleURL?.standardizedFileURL,
            manifest: nil,
            mappingResult: result,
            mappingResultDirectoryURL: resultDirectoryURL?.standardizedFileURL,
            mappingProvenance: provenance
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReferenceBundleViewportInputTests`

Expected: PASS with 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportInput.swift Tests/LungfishAppTests/ReferenceBundleViewportInputTests.swift
git commit -m "feat(app): add reference bundle viewport input"
```

---

### Task 2: Generalize Mapping Viewport Into Reference Bundle Viewport

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class ReferenceBundleViewportControllerTests: XCTestCase {
    func testDirectReferenceBundleShowsSequenceListAndLoadsFirstSequenceDetail() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200)
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr1", "chr2"])
        XCTAssertEqual(vc.testSelectedSequenceName, "chr1")
        XCTAssertFalse(vc.testEmbeddedViewerShowsBundleBrowser)
        XCTAssertEqual(vc.testPresentationMode, .listDetail)
    }
}
```

Add the fixture helper in the same test file:

```swift
private enum ReferenceViewportFixture {
    struct Chromosome {
        let name: String
        let length: Int
    }

    static func makeReferenceBundle(
        name: String,
        chromosomes: [Chromosome],
        includeAlignment: Bool,
        includeVariant: Bool
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-viewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)

        let fasta = chromosomes.map { ">\($0.name)\n\(String(repeating: "A", count: $0.length))\n" }.joined()
        let fastaURL = genomeURL.appendingPathComponent("sequence.fa")
        try fasta.write(to: fastaURL, atomically: true, encoding: .utf8)

        let chromInfos = chromosomes.enumerated().map { index, chrom in
            ChromosomeInfo(name: chrom.name, length: Int64(chrom.length), offset: Int64(index * 1000), lineBases: 80, lineWidth: 81)
        }

        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.tests.\(UUID().uuidString)",
            source: .init(type: .imported, originalPath: nil, importedDate: Date()),
            genome: .init(path: "genome/sequence.fa", indexPath: nil, format: .fasta, chromosomes: chromInfos),
            annotations: [],
            variants: [],
            tracks: [],
            alignments: [],
            browserSummary: BundleBrowserSummary(
                schemaVersion: 1,
                aggregate: .init(annotationTrackCount: 0, variantTrackCount: includeVariant ? 1 : 0, alignmentTrackCount: includeAlignment ? 1 : 0, totalMappedReads: includeAlignment ? 10 : nil),
                sequences: chromosomes.map {
                    BundleBrowserSequenceSummary(name: $0.name, length: Int64($0.length), isPrimary: true)
                }
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReferenceBundleViewportControllerTests`

Expected: FAIL with `cannot find 'ReferenceBundleViewportController' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ReferenceBundleViewportController` by copying the structure of `MappingResultViewController` and replacing `MappingResult`-only configuration with `ReferenceBundleViewportInput`.

Required public/test surface:

```swift
@MainActor
final class ReferenceBundleViewportController: NSViewController {
    enum PresentationMode: Equatable {
        case listDetail
        case focusedDetail
    }

    private(set) var currentInput: ReferenceBundleViewportInput?
    private(set) var presentationMode: PresentationMode = .listDetail
    var onEmbeddedReferenceBundleLoaded: ((ReferenceBundle) -> Void)?

    func configure(input: ReferenceBundleViewportInput) throws {
        currentInput = input
        presentationMode = .listDetail
        // If input.renderedBundleURL is nil, show the existing mapping-unavailable placeholder.
        // Otherwise load BundleManifest from input.renderedBundleURL if input.manifest is nil.
        // Load BundleBrowserLoader summary.
        // Configure the sequence list.
        // Select first row and call displaySelectedSequence.
    }

    func reloadViewerBundleForInspectorChanges() throws {
        guard let input = currentInput else { return }
        try configure(input: input)
    }
}

#if DEBUG
extension ReferenceBundleViewportController {
    func configureForTesting(input: ReferenceBundleViewportInput) throws {
        try configure(input: input)
    }

    var testDisplayedSequenceNames: [String] { sequenceRows.map(\.name) }
    var testSelectedSequenceName: String? { currentSelectedSequence()?.name }
    var testPresentationMode: PresentationMode { presentationMode }
    var testEmbeddedViewerShowsBundleBrowser: Bool {
        embeddedViewerController.testBundleBrowserController != nil
    }
}
#endif
```

Leave `MappingResultViewController` as a compatibility typealias or thin subclass only after tests compile:

```swift
typealias MappingResultViewController = ReferenceBundleViewportController
```

If a typealias breaks existing debug extensions, keep a tiny wrapper:

```swift
@MainActor
final class MappingResultViewController: ReferenceBundleViewportController {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReferenceBundleViewportControllerTests`

Expected: PASS.

- [ ] **Step 5: Run existing mapping viewport tests**

Run: `swift test --filter MappingResultViewControllerTests`

Expected: PASS or compile failures only where test type names need to be rewritten to `ReferenceBundleViewportControllerTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift Tests/LungfishAppTests/MappingResultViewControllerTests.swift
git commit -m "feat(app): generalize mapping viewport for reference bundles"
```

---

### Task 3: Route Direct `.lungfishref` Bundles Through Harmonized Viewport

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Test: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`

- [ ] **Step 1: Rewrite the failing routing test**

Replace `testBundleOpenPathsUseExplicitBrowseAndSequenceModes` with:

```swift
func testReferenceBundlesRouteThroughHarmonizedReferenceViewport() throws {
    let mainWindowSource = try loadSource(at: "Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift")
    let viewerMappingSource = try loadSource(at: "Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift")

    XCTAssertTrue(mainWindowSource.contains("displayReferenceBundleViewportFromSidebar(at: url)"))
    XCTAssertFalse(mainWindowSource.contains("displayBundle(at: url, mode: .browse)"))
    XCTAssertTrue(viewerMappingSource.contains("displayReferenceBundleViewport("))
    XCTAssertTrue(viewerMappingSource.contains("ReferenceBundleViewportController()"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MappingViewportRoutingTests/testReferenceBundlesRouteThroughHarmonizedReferenceViewport`

Expected: FAIL because `displayReferenceBundleViewportFromSidebar` does not exist and browse routing is still present.

- [ ] **Step 3: Implement direct reference bundle route**

In `MainSplitViewController.displayContent`, change:

```swift
if item.type == .referenceBundle, let url = item.url {
    displayReferenceBundle(at: url)
    return
}
```

to:

```swift
if item.type == .referenceBundle, let url = item.url {
    displayReferenceBundleViewportFromSidebar(at: url)
    return
}
```

Add:

```swift
private func displayReferenceBundleViewportFromSidebar(at url: URL, forceReload: Bool = false) {
    logger.info("displayReferenceBundleViewport: Opening '\(url.lastPathComponent, privacy: .public)'")
    activityIndicator.show(message: "Loading \(url.lastPathComponent)...", style: .indeterminate)

    DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
            guard let self else { return }
            defer { self.activityIndicator.hide() }

            do {
                let manifest = try BundleManifest.load(from: url)
                let input = ReferenceBundleViewportInput.directBundle(
                    bundleURL: url,
                    manifest: manifest
                )
                self.inspectorController.clearSelection()
                try self.viewerController.displayReferenceBundleViewport(input)
                self.wireReferenceViewportInspectorUpdates()
            } catch {
                logger.error("displayReferenceBundleViewport: Failed - \(error.localizedDescription, privacy: .public)")
                self.viewerController.clearViewport(statusMessage: "Unable to load reference bundle.")
            }
        }
    }
}
```

Add shared wiring:

```swift
private func wireReferenceViewportInspectorUpdates() {
    guard let controller = viewerController.referenceBundleViewportController else { return }
    controller.onEmbeddedReferenceBundleLoaded = { [weak self, weak controller] bundle in
        guard let self, let controller else { return }
        self.inspectorController.updateReferenceBundleTrackSections(
            from: bundle,
            mappingContext: controller.currentInput,
            applySettings: { payload in
                controller.applyEmbeddedReadDisplaySettings(payload)
            }
        )
    }
    controller.notifyEmbeddedReferenceBundleLoadedIfAvailable()
}
```

In `ViewerViewController+Mapping.swift`, add:

```swift
public func displayReferenceBundleViewport(_ input: ReferenceBundleViewportInput) throws {
    hideQuickLookPreview()
    hideFASTQDatasetView()
    hideVCFDatasetView()
    hideFASTACollectionView()
    hideTaxonomyView()
    hideEsVirituView()
    hideTaxTriageView()
    hideNaoMgsView()
    hideNvdView()
    hideAssemblyView()
    hideMappingView()
    clearBundleDisplay()
    hideCollectionBackButton()
    contentMode = .mapping

    let controller = ReferenceBundleViewportController()
    addChild(controller)
    let referenceView = controller.view
    referenceView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(referenceView)
    NSLayoutConstraint.activate([
        referenceView.topAnchor.constraint(equalTo: view.topAnchor),
        referenceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        referenceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        referenceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    try controller.configure(input: input)
    referenceBundleViewportController = controller
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MappingViewportRoutingTests/testReferenceBundlesRouteThroughHarmonizedReferenceViewport`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift Tests/LungfishAppTests/MappingViewportRoutingTests.swift
git commit -m "feat(app): route reference bundles through harmonized viewport"
```

---

### Task 4: Add Full-Viewport Focus Mode With Back Button

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift`

- [ ] **Step 1: Write the failing focus/back test**

```swift
func testFocusModeUsesVisibleBackButtonAndRestoresListDetailSelection() throws {
    let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
        name: "Reference",
        chromosomes: [
            .init(name: "chr1", length: 100),
            .init(name: "chr2", length: 200)
        ],
        includeAlignment: false,
        includeVariant: false
    )
    let manifest = try BundleManifest.load(from: bundleURL)
    let vc = ReferenceBundleViewportController()
    _ = vc.view
    try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

    vc.testSelectSequence(named: "chr2")
    vc.enterFocusedDetailModeForTesting()

    XCTAssertEqual(vc.testPresentationMode, .focusedDetail)
    XCTAssertEqual(vc.testFocusedBackButtonAccessibilityIdentifier, "reference-viewport-back-button")
    XCTAssertEqual(vc.testSelectedSequenceName, "chr2")

    vc.testInvokeFocusedBackButton()

    XCTAssertEqual(vc.testPresentationMode, .listDetail)
    XCTAssertEqual(vc.testSelectedSequenceName, "chr2")
    XCTAssertFalse(vc.testListPaneIsHidden)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReferenceBundleViewportControllerTests/testFocusModeUsesVisibleBackButtonAndRestoresListDetailSelection`

Expected: FAIL because focus mode and back button do not exist.

- [ ] **Step 3: Implement focus and back controls**

Add a focus button near the detail pane toolbar or summary bar:

```swift
private let focusButton: NSButton = {
    let button = NSButton(title: "Focus", target: nil, action: nil)
    button.bezelStyle = .rounded
    button.setAccessibilityIdentifier("reference-viewport-focus-button")
    return button
}()
```

Add a back button:

```swift
private let focusedBackButton: NSButton = {
    let button = NSButton(title: "Back", target: nil, action: nil)
    button.bezelStyle = .rounded
    button.setAccessibilityIdentifier("reference-viewport-back-button")
    button.isHidden = true
    return button
}()
```

Wire actions:

```swift
@objc private func enterFocusedDetailMode() {
    presentationMode = .focusedDetail
    listContainer.isHidden = true
    splitView.isHidden = true
    focusedBackButton.isHidden = false
    focusedContainer.isHidden = false
    moveDetailView(into: focusedContainer)
}

@objc private func exitFocusedDetailMode() {
    presentationMode = .listDetail
    focusedBackButton.isHidden = true
    focusedContainer.isHidden = true
    splitView.isHidden = false
    listContainer.isHidden = false
    moveDetailView(into: detailContainer)
    restoreSelectedRowIfNeeded()
}
```

Add DEBUG hooks:

```swift
#if DEBUG
extension ReferenceBundleViewportController {
    func enterFocusedDetailModeForTesting() {
        enterFocusedDetailMode()
    }

    func testInvokeFocusedBackButton() {
        exitFocusedDetailMode()
    }

    var testFocusedBackButtonAccessibilityIdentifier: String? {
        focusedBackButton.accessibilityIdentifier()
    }

    var testListPaneIsHidden: Bool {
        listContainer.isHidden
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReferenceBundleViewportControllerTests/testFocusModeUsesVisibleBackButtonAndRestoresListDetailSelection`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift
git commit -m "feat(app): add focused reference detail mode"
```

---

### Task 5: Unify Inspector Track Capabilities and Disabled Actions

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/ReferenceBundleTrackCapabilities.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleTrackCapabilitiesTests.swift`
- Test: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`

- [ ] **Step 1: Write the failing capability tests**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

final class ReferenceBundleTrackCapabilitiesTests: XCTestCase {
    func testReferenceOnlyBundleDisablesMappedReadAndVariantActionsWithReasons() throws {
        let bundle = ReferenceBundle(
            url: URL(fileURLWithPath: "/tmp/reference.lungfishref", isDirectory: true),
            manifest: BundleManifest(
                name: "Reference",
                identifier: "org.lungfish.reference",
                source: .init(type: .imported, originalPath: nil, importedDate: Date()),
                genome: nil,
                annotations: [],
                variants: [],
                tracks: [],
                alignments: []
            )
        )

        let capabilities = ReferenceBundleTrackCapabilities(bundle: bundle)

        XCTAssertFalse(capabilities.mappedReads.hasTracks)
        XCTAssertFalse(capabilities.mappedReads.canFilterBAM.isEnabled)
        XCTAssertEqual(capabilities.mappedReads.canFilterBAM.disabledReason, "No alignment tracks are available.")
        XCTAssertFalse(capabilities.variants.canCallVariants.isEnabled)
        XCTAssertEqual(capabilities.variants.canCallVariants.disabledReason, "No analysis-ready BAM tracks are available.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReferenceBundleTrackCapabilitiesTests`

Expected: FAIL with `cannot find 'ReferenceBundleTrackCapabilities' in scope`.

- [ ] **Step 3: Implement capability model**

Create:

```swift
import Foundation
import LungfishIO

struct ReferenceActionAvailability: Equatable {
    let isEnabled: Bool
    let disabledReason: String?

    static let enabled = ReferenceActionAvailability(isEnabled: true, disabledReason: nil)
    static func disabled(_ reason: String) -> ReferenceActionAvailability {
        ReferenceActionAvailability(isEnabled: false, disabledReason: reason)
    }
}

struct ReferenceBundleTrackCapabilities: Equatable {
    struct MappedReads: Equatable {
        let hasTracks: Bool
        let canFilterBAM: ReferenceActionAvailability
        let canPrimerTrim: ReferenceActionAvailability
    }

    struct Variants: Equatable {
        let hasTracks: Bool
        let canCallVariants: ReferenceActionAvailability
    }

    struct Annotations: Equatable {
        let hasTracks: Bool
        let canCreateFromMappedReads: ReferenceActionAvailability
    }

    let mappedReads: MappedReads
    let variants: Variants
    let annotations: Annotations

    init(bundle: ReferenceBundle) {
        let hasAlignments = !bundle.manifest.alignments.isEmpty
        let hasVariants = !bundle.manifest.variants.isEmpty
        let hasAnnotations = !bundle.manifest.annotations.isEmpty
        let noAlignments = "No alignment tracks are available."
        let noAnalysisReadyBAM = "No analysis-ready BAM tracks are available."

        mappedReads = MappedReads(
            hasTracks: hasAlignments,
            canFilterBAM: hasAlignments ? .enabled : .disabled(noAlignments),
            canPrimerTrim: hasAlignments ? .enabled : .disabled(noAnalysisReadyBAM)
        )
        variants = Variants(
            hasTracks: hasVariants,
            canCallVariants: hasAlignments ? .enabled : .disabled(noAnalysisReadyBAM)
        )
        annotations = Annotations(
            hasTracks: hasAnnotations,
            canCreateFromMappedReads: hasAlignments ? .enabled : .disabled(noAlignments)
        )
    }
}
```

- [ ] **Step 4: Wire Inspector through shared update method**

Add to `InspectorViewController`:

```swift
func updateReferenceBundleTrackSections(
    from bundle: ReferenceBundle,
    mappingContext: ReferenceBundleViewportInput?,
    applySettings: @escaping ([AnyHashable: Any]) -> Void
) {
    viewModel.selectionSectionViewModel.referenceBundle = bundle
    viewModel.documentSectionViewModel.bundleURL = bundle.url
    viewModel.documentSectionViewModel.referenceTrackCapabilities = ReferenceBundleTrackCapabilities(bundle: bundle)
    updateMappingAlignmentSection(from: bundle, applySettings: applySettings)
}
```

Add storage to `DocumentSectionViewModel`:

```swift
var referenceTrackCapabilities: ReferenceBundleTrackCapabilities?
```

Use this state in SwiftUI sections to keep major mapped-read and variant actions visible but disabled with `.help(disabledReason ?? "")`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ReferenceBundleTrackCapabilitiesTests`

Expected: PASS.

Run: `swift test --filter InspectorMappingModeTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector/ReferenceBundleTrackCapabilities.swift Sources/LungfishApp/Views/Inspector/InspectorViewController.swift Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift Tests/LungfishAppTests/ReferenceBundleTrackCapabilitiesTests.swift Tests/LungfishAppTests/InspectorMappingModeTests.swift
git commit -m "feat(app): derive reference track capabilities for inspector"
```

---

### Task 6: Preserve Mapping Analysis Provenance and Service Targets

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift`
- Test: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Test: `Tests/LungfishAppTests/MappingDocumentStateBuilderTests.swift`

- [ ] **Step 1: Write failing compatibility tests**

Add to `MappingResultViewControllerTests` or the renamed reference viewport test file:

```swift
func testFilteredAlignmentServiceTargetStillUsesMappingResultDirectory() throws {
    let vc = ReferenceBundleViewportController()
    _ = vc.view
    let resultDirectory = tempDir.appendingPathComponent("mapping-run", isDirectory: true)
    try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
    let viewerBundleURL = try makeReferenceBundleWithAnnotationDatabase()
    let result = MappingResult(
        mapper: .minimap2,
        modeID: MappingMode.defaultShortRead.id,
        sourceReferenceBundleURL: nil,
        viewerBundleURL: viewerBundleURL,
        bamURL: resultDirectory.appendingPathComponent("example.sorted.bam"),
        baiURL: resultDirectory.appendingPathComponent("example.sorted.bam.bai"),
        totalReads: 200,
        mappedReads: 198,
        unmappedReads: 2,
        wallClockSeconds: 1.5,
        contigs: makeContigs()
    )

    try vc.configureForTesting(input: .mappingResult(result: result, resultDirectoryURL: resultDirectory, provenance: nil))

    XCTAssertEqual(vc.testFilteredAlignmentServiceTarget, .mappingResult(resultDirectory.standardizedFileURL))
}
```

- [ ] **Step 2: Run test to verify it fails or proves current behavior**

Run: `swift test --filter MappingResultViewControllerTests/testFilteredAlignmentServiceTargetStillUsesMappingResultDirectory`

Expected: FAIL if the generalized viewport does not expose `filteredAlignmentServiceTarget`; PASS if Task 2 preserved it.

- [ ] **Step 3: Implement service target preservation**

In `ReferenceBundleViewportController`:

```swift
var filteredAlignmentServiceTarget: AlignmentFilterTarget? {
    if let resultDirectoryURL = currentInput?.mappingResultDirectoryURL {
        return .mappingResult(resultDirectoryURL.standardizedFileURL)
    }
    if let bundleURL = currentInput?.renderedBundleURL {
        return .bundle(bundleURL.standardizedFileURL)
    }
    return nil
}
```

In mapping analysis routing, replace direct `displayMappingResult` logic with:

```swift
let input = ReferenceBundleViewportInput.mappingResult(
    result: result,
    resultDirectoryURL: url,
    provenance: provenance
)
try viewerController.displayReferenceBundleViewport(input)
inspectorController.updateMappingDocument(
    MappingDocumentStateBuilder.build(result: result, provenance: provenance, projectURL: projectURL)
)
wireReferenceViewportInspectorUpdates()
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MappingResultViewControllerTests`

Expected: PASS.

Run: `swift test --filter MappingDocumentStateBuilderTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift Tests/LungfishAppTests/MappingResultViewControllerTests.swift Tests/LungfishAppTests/MappingDocumentStateBuilderTests.swift
git commit -m "feat(app): preserve mapping context in reference viewport"
```

---

### Task 7: Remove or Rewrite Browse-First Bundle View Tests and Hooks

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Tests/LungfishAppTests/BundleViewerTests.swift`
- Delete or reduce: `Tests/LungfishAppTests/BundleBrowserViewControllerTests.swift`
- Delete or reduce: `Tests/LungfishAppTests/BundleBrowserLayoutPreferenceTests.swift`

- [ ] **Step 1: Write failing source-level guard test**

Add to `MappingViewportRoutingTests`:

```swift
func testLegacyBrowseFirstBundleRoutingIsRemoved() throws {
    let viewerSource = try loadSource(at: "Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift")
    let mainWindowSource = try loadSource(at: "Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift")

    XCTAssertFalse(viewerSource.contains("case .browse"))
    XCTAssertFalse(viewerSource.contains("displayBundleBrowser("))
    XCTAssertFalse(mainWindowSource.contains("bundleBrowserController != nil"))
    XCTAssertFalse(mainWindowSource.contains("restoring browse mode"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MappingViewportRoutingTests/testLegacyBrowseFirstBundleRoutingIsRemoved`

Expected: FAIL because browse-first code remains.

- [ ] **Step 3: Remove old browse-first entry points**

In `ViewerViewController+BundleDisplay.swift`:

- Remove `BundleDisplayMode.browse` handling.
- Keep `displayBundle(at:mode: .sequence(...))` or replace it with:

```swift
func displayBundleSequenceForEmbeddedDetail(
    at url: URL,
    sequenceName: String?,
    restoreViewState: Bool
) throws {
    let context = try loadBundleDisplayContext(at: url)
    activateBundleDisplayContext(context)
    try displayBundleSequence(
        preferredSequenceName: sequenceName,
        context: context,
        installChromosomeNavigator: false,
        restoreViewState: restoreViewState
    )
}
```

In `ViewerViewController.swift`:

- Remove `bundleBrowserController` if no longer used.
- Remove `hideBundleBrowserView()` if no longer used.
- Keep `showBundleBackNavigationButton` only if focus mode or other non-bundle flows still use it; otherwise remove it after focus mode has its own back button.

- [ ] **Step 4: Rewrite or delete legacy tests**

In `BundleViewerTests.swift`, replace browse-first tests with harmonized route tests:

```swift
func testDisplayReferenceBundleViewportDoesNotCreateLegacyBundleBrowser() throws {
    let vc = ViewerViewController()
    _ = vc.view
    let bundleURL = try makeBundleWithTwoChromosomes()
    let manifest = try BundleManifest.load(from: bundleURL)

    try vc.displayReferenceBundleViewport(.directBundle(bundleURL: bundleURL, manifest: manifest))

    XCTAssertNotNil(vc.testReferenceBundleViewportController)
    XCTAssertNil(vc.testBundleBrowserController)
}
```

Delete tests whose only assertion is old browser state restoration:

- `testBundleBrowserDrillDownAndBackRestoresBrowserState`
- `testFailedBrowseOpenPreservesExistingBundleBrowserState`
- tests asserting `displayBundle(at: bundleURL, mode: .browse)` creates `testBundleBrowserController`

Keep table/filter tests only if `BundleBrowserSequenceTableView` is reused as `ReferenceSequenceListTableView`; otherwise move their useful assertions to `ReferenceBundleViewportControllerTests`.

- [ ] **Step 5: Run guard and affected tests**

Run: `swift test --filter MappingViewportRoutingTests/testLegacyBrowseFirstBundleRoutingIsRemoved`

Expected: PASS.

Run: `swift test --filter BundleViewerTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Tests/LungfishAppTests/MappingViewportRoutingTests.swift Tests/LungfishAppTests/BundleViewerTests.swift Tests/LungfishAppTests/BundleBrowserViewControllerTests.swift Tests/LungfishAppTests/BundleBrowserLayoutPreferenceTests.swift
git commit -m "refactor(app): remove legacy browse-first reference bundle view"
```

---

### Task 8: Reload Mutating Workflows Through Harmonized Viewport

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Test: `Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift`
- Test: `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift`

- [ ] **Step 1: Write failing reload target test**

Add a unit test near existing filtered alignment workflow tests:

```swift
func testFilteredAlignmentWorkflowReloadsReferenceViewportForDirectBundle() throws {
    let bundleURL = URL(fileURLWithPath: "/tmp/reference.lungfishref", isDirectory: true)
    let context = FilteredAlignmentWorkflowLaunchContext(
        bundleURL: bundleURL,
        serviceTarget: .bundle(bundleURL),
        reloadTarget: .referenceViewport
    )
    var reloadedReferenceViewport = false

    try context.reload(
        using: FilteredAlignmentWorkflowReloadActions(
            reloadReferenceViewport: { reloadedReferenceViewport = true },
            reloadMappingViewerBundle: { XCTFail("Mapping reload should not be used") },
            displayBundle: { _ in XCTFail("Legacy displayBundle reload should not be used") }
        )
    )

    XCTAssertTrue(reloadedReferenceViewport)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AlignmentFilterInspectorStateTests/testFilteredAlignmentWorkflowReloadsReferenceViewportForDirectBundle`

Expected: FAIL because `.referenceViewport` and `reloadReferenceViewport` do not exist.

- [ ] **Step 3: Implement harmonized reload target**

Change:

```swift
enum FilteredAlignmentWorkflowReloadTarget {
    case mappingViewer
    case bundleViewer
}
```

to:

```swift
enum FilteredAlignmentWorkflowReloadTarget: Equatable {
    case referenceViewport
}
```

Change actions:

```swift
struct FilteredAlignmentWorkflowReloadActions {
    let reloadReferenceViewport: () throws -> Void
}
```

Change reload:

```swift
func reload(using actions: FilteredAlignmentWorkflowReloadActions) throws {
    try actions.reloadReferenceViewport()
}
```

Add to `ViewerViewController+Mapping.swift`:

```swift
func reloadReferenceBundleViewportIfDisplayed() throws {
    try referenceBundleViewportController?.reloadViewerBundleForInspectorChanges()
}
```

Update workflow completion blocks to call:

```swift
try split.viewerController.reloadReferenceBundleViewportIfDisplayed()
```

- [ ] **Step 4: Run affected tests**

Run: `swift test --filter AlignmentFilterInspectorStateTests`

Expected: PASS.

Run: `swift test --filter BAMVariantCallingDialogRoutingTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector/InspectorViewController.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift
git commit -m "refactor(app): reload bundle workflows through reference viewport"
```

---

### Task 9: Final Verification and Cleanup

**Files:**
- Review all touched files.
- Remove dead source files only if `rg` shows no references.

- [ ] **Step 1: Search for stale browse-first references**

Run:

```bash
rg -n "displayBundle\\(at: .*mode: \\.browse|displayBundleBrowser|bundleBrowserController|BundleBrowserPanelLayout|bundleBrowserLayoutSwapRequested|restoring browse mode" Sources Tests
```

Expected: No matches for old route/controller symbols. Matches in `BundleBrowserLoader`, `BundleBrowserMirrorStore`, `BundleSequenceSummarySynthesizer`, or `BundleBrowserSummary` are acceptable only when they are sequence-summary data utilities still referenced by the harmonized viewport.

- [ ] **Step 2: Run targeted test suite**

Run:

```bash
swift test --filter ReferenceBundleViewport
swift test --filter MappingResultViewControllerTests
swift test --filter MappingViewportRoutingTests
swift test --filter BundleViewerTests
swift test --filter ReferenceBundleTrackCapabilitiesTests
swift test --filter AlignmentFilterInspectorStateTests
swift test --filter BAMVariantCallingDialogRoutingTests
```

Expected: all PASS.

- [ ] **Step 3: Run broader app tests if targeted tests pass**

Run:

```bash
swift test --filter LungfishAppTests
```

Expected: PASS. If unrelated long-running or environment-gated tests are skipped/fail, record the exact failures in the final handoff.

- [ ] **Step 4: Build the app target**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 5: Commit cleanup**

```bash
git status --short
git add Sources/LungfishApp Tests/LungfishAppTests
git commit -m "test(app): verify harmonized reference bundle viewport"
```

Only commit if Step 5 has remaining cleanup changes. Do not stage unrelated deleted files under `scripts/analyses/`.

---

## Self-Review

- Spec coverage: Tasks 1-3 cover unified `.lungfishref` routing and direct bundle support. Task 4 covers full-viewport focus and Back. Task 5 covers visible-disabled track capabilities. Task 6 covers mapping provenance and service targets. Task 7 removes legacy browse-first route/tests. Task 8 unifies mutation reload behavior. Task 9 covers verification.
- Placeholder scan: the plan contains concrete test names, commands, expected outcomes, and implementation targets.
- Type consistency: `ReferenceBundleViewportInput`, `ReferenceBundleViewportController`, `ReferenceBundleTrackCapabilities`, and `ReferenceActionAvailability` are introduced before later tasks reference them.

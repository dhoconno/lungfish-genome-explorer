# Assembly Plugin Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an active `assembly` micromamba plugin pack for `SPAdes`, `MEGAHIT`, `SKESA`, `Flye`, and `Hifiasm`, replace the SPAdes-only assembly surfaces with a read-type-aware shared configuration flow, and move assembly execution off the Apple Container path onto managed micromamba environments.

**Architecture:** Activate the pack first, then add an assembler-neutral assembly domain model (`AssemblyTool`, `AssemblyReadType`, `AssemblyRunRequest`, `AssemblyResult`, compatibility and option catalogs). Refactor the FASTQ and standalone assembly UI onto that model, execute tool-specific commands through `CondaManager`, normalize each tool's outputs into one result/bundle shape, and keep backward compatibility for existing SPAdes analysis bundles.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Swift ArgumentParser, XCTest, `CondaManager`, `PluginPackStatusService`, existing `SequencingPlatform` detection, micromamba-managed Bioconda environments.

---

## File Map

- Create: `docs/superpowers/specs/2026-04-19-assembly-assembler-option-inventory.md`
  Responsibility: the curated v1 option inventory, read-type compatibility matrix, default profiles, and explicit deferred flags for each assembler.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyTool.swift`
  Responsibility: the assembler enum, display strings, environment names, executable names, and default output conventions.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyReadType.swift`
  Responsibility: the `Illumina short reads` / `ONT reads` / `PacBio HiFi` model plus FASTQ-based detection helpers.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`
  Responsibility: the v1 compatibility matrix and user-facing block/warning reasons.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyOptionCatalog.swift`
  Responsibility: the shared controls, capability-scoped controls, and advanced-option disclosures that drive both UI and CLI mapping.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyRunRequest.swift`
  Responsibility: the assembler-neutral run request passed from app and CLI layers into workflow execution.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyResult.swift`
  Responsibility: the normalized assembly result wrapper used by bundles, provenance, and the viewer.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyOutputNormalizer.swift`
  Responsibility: per-tool output discovery and normalization into `AssemblyResult`.
- Create: `Sources/LungfishWorkflow/Assembly/GFASegmentFASTAWriter.swift`
  Responsibility: convert Hifiasm primary-contig GFA output into FASTA without requiring another managed tool.
- Create: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
  Responsibility: run the selected assembler through `CondaManager`, stream progress, and hand normalized output back to the app/CLI.
- Create: `Sources/LungfishApp/Views/Assembly/AssemblyCompatibilityPresentation.swift`
  Responsibility: small UI model that maps compatibility/readiness states onto Lungfish palette tokens.
- Create: `Tests/LungfishWorkflowTests/Assembly/AssemblyCompatibilityTests.swift`
  Responsibility: matrix coverage for tool/read-type combinations and mixed-read-class blocking.
- Create: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`
  Responsibility: command-building and output-normalization coverage without requiring real assembler installs.
- Create: `Tests/LungfishWorkflowTests/Assembly/GFASegmentFASTAWriterTests.swift`
  Responsibility: Hifiasm GFA-to-FASTA conversion coverage.
- Create: `Tests/LungfishAppTests/AssemblyCompatibilityPresentationTests.swift`
  Responsibility: readiness/compatibility strip semantics and palette-token mapping.
- Create: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`
  Responsibility: generic assembly result rendering coverage.
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
  Responsibility: activate the assembly pack, pin arm64-supported packages, add requirement metadata and smoke tests.
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
  Responsibility: replace SPAdes-only state with generic assembly request state, add tool IDs, and use read-type detection.
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
  Responsibility: route all assembly tools into the shared assembly pane and keep readiness text aligned with the rest of the operations dialog.
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift`
  Responsibility: replace the SPAdes-specific sheet with the shared v1 assembly UI and palette-compliant compatibility messaging.
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewController.swift`
  Responsibility: route standalone assembly into the same shared sheet model.
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift`
  Responsibility: switch standalone assembly launching from `SPAdesAssemblyConfig` to `AssemblyRunRequest`.
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
  Responsibility: launch pending assembly requests through the managed assembly pipeline instead of the SPAdes-only path.
- Modify: `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`
  Responsibility: carry generic assembly launch requests through execution planning and CLI invocation building.
- Modify: `Sources/LungfishCLI/Commands/AssembleCommand.swift`
  Responsibility: replace the SPAdes/container-specific command surface with assembler-neutral CLI options backed by micromamba execution.
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyProvenance.swift`
  Responsibility: record managed-environment execution metadata while remaining backward compatible with existing container-backed SPAdes bundles.
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyBundleBuilder.swift`
  Responsibility: accept the generic assembly result/config model and preserve the existing `.lungfishref` layout.
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
  Responsibility: render generic assembly results instead of `SPAdesAssemblyResult`.
- Modify: `Sources/LungfishIO/Bundles/AnalysesFolder.swift`
  Responsibility: add display-name recognition for `skesa`, `flye`, and `hifiasm`.
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
  Responsibility: route new assembly tool IDs into the assembly result viewer.
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
  Responsibility: add icon/name handling for the new assembly tools.
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`
  Responsibility: show the new assembly tools with consistent section styling.
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift`
  Responsibility: describe the new assembly tool names correctly in exported summaries.
- Modify tests: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`, `Tests/LungfishCLITests/CondaPacksCommandTests.swift`, `Tests/LungfishWorkflowTests/CondaManagerTests.swift`, `Tests/LungfishAppTests/AboutAcknowledgementsTests.swift`, `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`, `Tests/LungfishAppTests/WelcomeSetupTests.swift`, `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`, `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`, `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`, `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`, `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`, `Tests/LungfishWorkflowTests/AssemblyBundleBuilderTests.swift`, `Tests/LungfishWorkflowTests/Assembly/SPAdesResultSidecarTests.swift`, `Tests/LungfishCLITests/CLIRegressionTests.swift`
  Responsibility: lock in the new pack visibility, routing, CLI, bundle, and backward-compatibility behavior.

## Task 1: Activate The Assembly Plugin Pack And Fix Pack-Facing Regressions

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Modify: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
- Modify: `Tests/LungfishCLITests/CondaPacksCommandTests.swift`
- Modify: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
- Modify: `Tests/LungfishAppTests/AboutAcknowledgementsTests.swift`
- Modify: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- Modify: `Tests/LungfishAppTests/WelcomeSetupTests.swift`

- [ ] **Step 1: Add failing expectations for the now-active assembly pack**

Update the pack-facing tests to expect both active optional packs and an `Assembly` acknowledgements section:

```swift
XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["assembly", "metagenomics"])
XCTAssertEqual(PluginPack.visibleForCLI.map(\.id), ["lungfish-tools", "assembly", "metagenomics"])

let sections = AboutAcknowledgements.currentSections()
XCTAssertEqual(
    sections.map(\.title),
    ["Bundled Bootstrap", "Third-Party Tools", "Genome Assembly", "Metagenomics"]
)
```

- [ ] **Step 2: Run the pack-facing tests and verify they fail before the pack change**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter CondaPacksCommandTests
swift test --filter AboutAcknowledgementsTests
swift test --filter PluginPackVisibilityTests
swift test --filter WelcomeSetupTests
```

Expected: FAIL because `assembly` is still inactive and multiple tests still assume `metagenomics` is the only active optional pack.

- [ ] **Step 3: Activate the assembly pack with explicit arm64-safe requirements**

Replace the current bare package list with explicit managed-tool entries patterned after the metagenomics pack:

```swift
PluginPack(
    id: "assembly",
    name: "Genome Assembly",
    description: "De novo genome assembly from short and long reads",
    sfSymbol: "puzzlepiece.extension.fill",
    packages: ["spades", "megahit", "skesa", "flye", "hifiasm"],
    category: "Assembly",
    isActive: true,
    requirements: [
        PackToolRequirement(
            id: "spades",
            displayName: "SPAdes",
            environment: "spades",
            installPackages: ["bioconda::spades=4.2.0"],
            executables: ["spades.py"],
            smokeTest: .command(
                executable: "spades.py",
                arguments: ["--version"],
                requiredOutputSubstring: "SPAdes"
            ),
            version: "4.2.0",
            license: "GPL-2.0-only",
            sourceURL: "https://github.com/ablab/spades"
        ),
        PackToolRequirement(
            id: "megahit",
            displayName: "MEGAHIT",
            environment: "megahit",
            installPackages: ["bioconda::megahit=1.2.9"],
            executables: ["megahit"],
            smokeTest: .command(arguments: ["-h"], requiredOutputSubstring: "MEGAHIT"),
            version: "1.2.9",
            license: "GPL-3.0",
            sourceURL: "https://github.com/voutcn/megahit"
        ),
        PackToolRequirement(
            id: "skesa",
            displayName: "SKESA",
            environment: "skesa",
            installPackages: ["bioconda::skesa=2.5.1"],
            executables: ["skesa"],
            smokeTest: .command(arguments: ["--version"], requiredOutputSubstring: "2.5.1"),
            version: "2.5.1",
            license: "Public Domain",
            sourceURL: "https://github.com/ncbi/SKESA"
        ),
        PackToolRequirement(
            id: "flye",
            displayName: "Flye",
            environment: "flye",
            installPackages: ["bioconda::flye=2.9.6"],
            executables: ["flye"],
            smokeTest: .command(arguments: ["--version"], requiredOutputSubstring: "2.9.6"),
            version: "2.9.6",
            license: "BSD",
            sourceURL: "https://github.com/mikolmogorov/Flye"
        ),
        PackToolRequirement(
            id: "hifiasm",
            displayName: "Hifiasm",
            environment: "hifiasm",
            installPackages: ["bioconda::hifiasm=0.25.0"],
            executables: ["hifiasm"],
            smokeTest: .command(
                arguments: [],
                acceptedExitCodes: [0, 1],
                requiredOutputSubstring: "Usage"
            ),
            version: "0.25.0",
            license: "MIT",
            sourceURL: "https://github.com/chhylp123/hifiasm"
        ),
    ],
    estimatedSizeMB: 1300
)
```

- [ ] **Step 4: Fix the tests that index into `activeOptionalPacks[0]`**

Replace order-fragile indexing with explicit lookup by `id`:

```swift
let assemblyPack = try XCTUnwrap(
    PluginPack.activeOptionalPacks.first(where: { $0.id == "assembly" })
)
XCTAssertEqual(assemblyPack.name, "Genome Assembly")
```

- [ ] **Step 5: Re-run the pack-facing test slice**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter CondaPacksCommandTests
swift test --filter AboutAcknowledgementsTests
swift test --filter PluginPackVisibilityTests
swift test --filter WelcomeSetupTests
```

Expected: PASS with `assembly` visible to both the GUI and CLI pack listings.

## Task 2: Write The Assembler Option Inventory And Add The Neutral Assembly Domain Model

**Files:**
- Create: `docs/superpowers/specs/2026-04-19-assembly-assembler-option-inventory.md`
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyTool.swift`
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyReadType.swift`
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyOptionCatalog.swift`
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyRunRequest.swift`
- Create: `Tests/LungfishWorkflowTests/Assembly/AssemblyCompatibilityTests.swift`

- [ ] **Step 1: Write the inventory document before wiring the UI**

The inventory document should include, for each tool:

- supported v1 read class
- allowed input topology (`single-end`, `paired-end`, `single long-read file`, etc.)
- shared controls
- capability-scoped controls
- advanced controls surfaced in disclosure groups
- explicitly deferred capabilities that exist upstream but are out of scope in v1

The document must call out the deliberate v1 simplifications:

- `Flye --pacbio-hifi` is deferred even though Flye supports it upstream
- `Hifiasm --ont` is deferred even though current upstream versions can run ONT workflows
- SPAdes hybrid/supplementary long-read flags stay out of v1
- hybrid assembly, trio, Hi-C, ultra-long, and polishing workflows remain out of scope

- [ ] **Step 2: Add failing compatibility tests for the approved v1 matrix**

Create tests like:

```swift
import XCTest
@testable import LungfishWorkflow

final class AssemblyCompatibilityTests: XCTestCase {
    func testIlluminaShortReadsEnableOnlyShortReadAssemblers() {
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .spades, readType: .illuminaShortReads))
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .megahit, readType: .illuminaShortReads))
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .skesa, readType: .illuminaShortReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .flye, readType: .illuminaShortReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .hifiasm, readType: .illuminaShortReads))
    }

    func testOntReadsEnableOnlyFlye() {
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .flye, readType: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .spades, readType: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .megahit, readType: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .skesa, readType: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .hifiasm, readType: .ontReads))
    }

    func testMixedDetectedReadTypesAreBlockedInV1() {
        XCTAssertEqual(
            AssemblyCompatibility.mixedReadClassMessage,
            "Hybrid assembly is not supported in v1. Select one read class per run."
        )
    }
}
```

- [ ] **Step 3: Run the new compatibility tests and verify they fail**

Run:

```bash
swift test --filter AssemblyCompatibilityTests
```

Expected: FAIL because the neutral assembly types do not exist yet.

- [ ] **Step 4: Add the shared assembly types**

Use a compact model that app, CLI, and workflow code can share:

```swift
public enum AssemblyTool: String, CaseIterable, Codable, Sendable {
    case spades
    case megahit
    case skesa
    case flye
    case hifiasm

    public var environmentName: String { rawValue }
    public var executableName: String {
        switch self {
        case .spades: return "spades.py"
        default: return rawValue
        }
    }
}

public enum AssemblyReadType: String, CaseIterable, Codable, Sendable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi

    public static func detect(fromFASTQ url: URL) -> Self? {
        switch try? SequencingPlatform.detect(fromFASTQ: url) {
        case .illumina?: return .illuminaShortReads
        case .oxfordNanopore?: return .ontReads
        case .pacbio?: return .pacBioHiFi
        default: return nil
        }
    }
}

public struct AssemblyRunRequest: Sendable, Codable, Equatable {
    public let tool: AssemblyTool
    public let readType: AssemblyReadType
    public let inputURLs: [URL]
    public let projectName: String
    public let outputDirectory: URL
    public let threads: Int
    public let memoryGB: Int?
    public let minContigLength: Int?
    public let selectedProfileID: String?
    public let extraArguments: [String]
}
```

- [ ] **Step 5: Encode the v1 compatibility matrix and the curated option catalog**

Keep the compatibility layer strict and the option catalog explicit:

```swift
public enum AssemblyCompatibility {
    public static let mixedReadClassMessage =
        "Hybrid assembly is not supported in v1. Select one read class per run."

    public static func isSupported(tool: AssemblyTool, readType: AssemblyReadType) -> Bool {
        switch (tool, readType) {
        case (.spades, .illuminaShortReads),
             (.megahit, .illuminaShortReads),
             (.skesa, .illuminaShortReads),
             (.flye, .ontReads),
             (.hifiasm, .pacBioHiFi):
            return true
        default:
            return false
        }
    }
}
```

`AssemblyOptionCatalog` should keep the UI honest by describing exactly which controls each tool gets in:

- shared controls
- capability-scoped primary settings
- advanced disclosure rows

- [ ] **Step 6: Re-run the compatibility tests**

Run:

```bash
swift test --filter AssemblyCompatibilityTests
```

Expected: PASS with the approved v1 matrix locked in.

## Task 3: Refactor FASTQ Assembly Routing From SPAdes-Only To Generic Assembly Requests

**Files:**
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`
- Modify: `Tests/LungfishAppTests/UnifiedClassifierRunnerTests.swift`

- [ ] **Step 1: Add failing dialog-state tests for the five assembly tools and the new request payload**

Add assertions like:

```swift
func testAssemblyCategoryExposesAllV1Assemblers() {
    let state = FASTQOperationDialogState(initialCategory: .assembly, selectedInputURLs: [sampleFASTQ])
    XCTAssertEqual(
        state.toolIDs(for: .assembly),
        [.spades, .megahit, .skesa, .flye, .hifiasm]
    )
}

func testCaptureAssemblyRequestStoresGenericAssemblyRequest() {
    let state = FASTQOperationDialogState(initialCategory: .assembly, selectedInputURLs: [sampleFASTQ])
    let request = AssemblyRunRequest(
        tool: .spades,
        readType: .illuminaShortReads,
        inputURLs: [sampleFASTQ],
        projectName: "Demo",
        outputDirectory: URL(fileURLWithPath: "/tmp/out"),
        threads: 8,
        memoryGB: nil,
        minContigLength: nil,
        selectedProfileID: nil,
        extraArguments: []
    )

    state.captureAssemblyRequest(request)

    guard case .assemble(let storedRequest, _) = state.pendingLaunchRequest else {
        return XCTFail("Expected generic assembly request")
    }
    XCTAssertEqual(storedRequest.tool, .spades)
}
```

- [ ] **Step 2: Run the FASTQ routing tests and verify they fail**

Run:

```bash
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter FASTQOperationExecutionServiceTests
swift test --filter FASTQOperationRoundTripTests
```

Expected: FAIL because the dialog state still hardcodes `.spades`, `pendingSPAdesConfig`, and `.assemble(inputURLs:outputMode:)`.

- [ ] **Step 3: Replace the SPAdes-only state with generic assembly state**

Use a small targeted refactor instead of threading SPAdes config everywhere:

```swift
var pendingAssemblyRequest: AssemblyRunRequest?

enum FASTQOperationLaunchRequest: Sendable, Equatable {
    case refreshQCSummary(inputURLs: [URL])
    case derivative(request: FASTQDerivativeRequest, inputURLs: [URL], outputMode: FASTQOperationOutputMode)
    case map(inputURLs: [URL], referenceURL: URL, outputMode: FASTQOperationOutputMode)
    case assemble(request: AssemblyRunRequest, outputMode: FASTQOperationOutputMode)
    case classify(tool: FASTQOperationToolID, inputURLs: [URL], databaseName: String)
}
```

Update:

- `normalizeSelectionState()`
- `toolIDs(for: .assembly)`
- `defaultToolID` for `.assembly`
- `title`, `subtitle`, `requiredInputKinds`, and readiness helpers

to understand `.megahit`, `.skesa`, `.flye`, and `.hifiasm`.

- [ ] **Step 4: Add read-type detection and hybrid blocking in dialog state**

Use the selected FASTQ inputs to infer read type where possible:

```swift
var detectedAssemblyReadType: AssemblyReadType? {
    let detected = Set(selectedInputURLs.compactMap(AssemblyReadType.detect))
    if detected.count == 1 { return detected.first }
    return nil
}

var assemblyReadClassMismatchMessage: String? {
    let detected = Set(selectedInputURLs.compactMap(AssemblyReadType.detect))
    return detected.count > 1 ? AssemblyCompatibility.mixedReadClassMessage : nil
}
```

The dialog should never silently allow mixed Illumina and long-read inputs in the same v1 run.

- [ ] **Step 5: Update the execution-service tests to expect assembler-aware CLI planning**

`FASTQOperationExecutionServiceTests` should assert the new CLI invocation shape:

```swift
XCTAssertEqual(
    invocation,
    CLIInvocation(
        subcommand: "assemble",
        arguments: [
            sampleFASTQ.path,
            "--assembler", "spades",
            "--read-type", "illumina-short-reads",
            "--project-name", "Demo",
            "--threads", "8",
            "--output", "/tmp/assembly-out"
        ]
    )
)
```

- [ ] **Step 6: Re-run the FASTQ routing slice**

Run:

```bash
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter FASTQOperationExecutionServiceTests
swift test --filter FASTQOperationRoundTripTests
swift test --filter FASTQOperationsCatalogTests
swift test --filter UnifiedClassifierRunnerTests
```

Expected: PASS with no remaining references to `pendingSPAdesConfig` or SPAdes-only assembly launch requests in the FASTQ dialog path.

## Task 4: Build The Shared Assembly Pane With Palette-Compliant Compatibility Messaging

**Files:**
- Create: `Sources/LungfishApp/Views/Assembly/AssemblyCompatibilityPresentation.swift`
- Create: `Tests/LungfishAppTests/AssemblyCompatibilityPresentationTests.swift`
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewController.swift`
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`

- [ ] **Step 1: Add failing UI-state tests for compatibility strips and mixed-read blocking**

Create focused unit tests against a presentation model instead of brittle view inspection:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AssemblyCompatibilityPresentationTests: XCTestCase {
    func testBlockedCombinationUsesAttentionStyling() {
        let presentation = AssemblyCompatibilityPresentation(
            tool: .flye,
            readType: .illuminaShortReads,
            packReady: true
        )

        XCTAssertEqual(presentation.state, .blocked)
        XCTAssertEqual(presentation.fillStyle, .attention)
        XCTAssertEqual(
            presentation.message,
            "Flye is not available for Illumina short reads in v1."
        )
    }
}
```

- [ ] **Step 2: Run the new assembly UI presentation tests and verify they fail**

Run:

```bash
swift test --filter AssemblyCompatibilityPresentationTests
```

Expected: FAIL because the presentation model does not exist yet and the sheet still uses ad hoc SPAdes/runtime state.

- [ ] **Step 3: Replace the SPAdes-only sheet with the shared assembly UI**

The shared pane should keep the current section rhythm:

1. `Inputs`
2. `Primary Settings`
3. `Advanced Settings`
4. `Output`
5. `Readiness`

Structure the sheet around the neutral request model:

```swift
struct AssemblyWizardSheet: View {
    @State private var selectedTool: AssemblyTool = .spades
    @State private var selectedReadType: AssemblyReadType = .illuminaShortReads
    @State private var projectName = ""
    @State private var threads = 8
    @State private var memoryGB: Int? = nil
    @State private var minContigLength: Int? = nil
    @State private var selectedProfileID: String? = nil
    @State private var extraArgumentsText = ""

    var onRun: ((AssemblyRunRequest) -> Void)?
}
```

Use `AssemblyOptionCatalog` so the shared pane is data-driven instead of becoming five hardcoded forms.

- [ ] **Step 4: Replace the container-runtime check with pack/tool readiness**

Remove:

```swift
let available = await NewContainerRuntimeFactory.createRuntime() != nil
```

and replace it with pack/tool readiness derived from managed tools:

```swift
let service = PluginPackStatusService()
let packState = try? await service.status(forPackID: "assembly")
let packReady = packState?.isInstalled == true
```

The readiness section should report missing managed tools, blocked read-type/tool combinations, and mixed-read-class input without referencing Apple Container entitlements.

- [ ] **Step 5: Use Lungfish palette tokens for every compatibility strip and warning state**

Do not use raw `.red`, `.orange`, or `.green` in assembly messaging. Route the UI through a tiny semantic layer:

```swift
enum AssemblyCompatibilityFillStyle {
    case card
    case attention
    case success
}

var fillColor: Color {
    switch fillStyle {
    case .card: return .lungfishCardBackground
    case .attention: return .lungfishAttentionFill
    case .success: return .lungfishSuccessFill
    }
}
```

Text and borders should continue to use:

- `Color.lungfishSecondaryText`
- `Color.lungfishOrangeFallback`
- `Color.lungfishStroke`

- [ ] **Step 6: Route both FASTQ assembly and standalone assembly through the same request builder**

`FASTQOperationToolPanes` should call `state.captureAssemblyRequest(_:)`, and `AssemblyConfigurationViewController` / `AssemblyConfigurationViewModel` should stop using `SPAdesAssemblyConfig` directly.

- [ ] **Step 7: Re-run the assembly UI test slice**

Run:

```bash
swift test --filter AssemblyCompatibilityPresentationTests
swift test --filter FASTQOperationDialogRoutingTests
```

Expected: PASS with palette-compliant compatibility/readiness messaging and no remaining container-only assembly checks.

## Task 5: Replace The SPAdes-Only Execution Path With Micromamba-Backed Multi-Assembler Execution

**Files:**
- Create: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyOutputNormalizer.swift`
- Create: `Sources/LungfishWorkflow/Assembly/GFASegmentFASTAWriter.swift`
- Create: `Tests/LungfishWorkflowTests/Assembly/ManagedAssemblyPipelineTests.swift`
- Create: `Tests/LungfishWorkflowTests/Assembly/GFASegmentFASTAWriterTests.swift`
- Modify: `Sources/LungfishCLI/Commands/AssembleCommand.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`

- [ ] **Step 1: Add failing pipeline tests for command construction and output normalization**

Start with command-building tests, not a real assembler run:

```swift
import XCTest
@testable import LungfishWorkflow

final class ManagedAssemblyPipelineTests: XCTestCase {
    func testBuildsSpadesCommandForIlluminaReads() throws {
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "ecoli",
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            threads: 8,
            memoryGB: 16,
            minContigLength: 500,
            selectedProfileID: "isolate",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "spades.py")
        XCTAssertTrue(command.arguments.contains("--threads"))
        XCTAssertTrue(command.arguments.contains("--memory"))
    }

    func testBuildsFlyeCommandForOntReads() throws {
        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .ontReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/ont.fastq.gz")],
            projectName: "ont-demo",
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            threads: 16,
            memoryGB: nil,
            minContigLength: 1000,
            selectedProfileID: "nano-hq",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertTrue(command.arguments.contains("--nano-hq"))
        XCTAssertTrue(command.arguments.contains("--out-dir"))
    }
}
```

- [ ] **Step 2: Add a failing Hifiasm normalization test**

The normalizer must convert the primary GFA output into FASTA:

```swift
func testHifiasmPrimaryContigsAreExportedFromGFA() throws {
    let gfa = """
    H\tVN:Z:1.0
    S\tctg0001\tACGTACGT
    S\tctg0002\tTTTTCCCC
    """
    let gfaURL = tempDir.appendingPathComponent("sample.bp.p_ctg.gfa")
    try gfa.write(to: gfaURL, atomically: true, encoding: .utf8)

    let fastaURL = tempDir.appendingPathComponent("contigs.fa")
    try GFASegmentFASTAWriter.writePrimaryContigs(from: gfaURL, to: fastaURL)

    let fasta = try String(contentsOf: fastaURL)
    XCTAssertTrue(fasta.contains(">ctg0001"))
    XCTAssertTrue(fasta.contains("ACGTACGT"))
}
```

- [ ] **Step 3: Run the new workflow tests and verify they fail**

Run:

```bash
swift test --filter ManagedAssemblyPipelineTests
swift test --filter GFASegmentFASTAWriterTests
```

Expected: FAIL because there is no neutral pipeline or Hifiasm output normalizer yet.

- [ ] **Step 4: Implement the managed assembly pipeline on top of `CondaManager`**

Use `CondaManager.runTool` as the common execution primitive:

```swift
let condaManager = CondaManager.shared
let result = try await condaManager.runTool(
    name: command.executable,
    arguments: command.arguments,
    environment: request.tool.environmentName,
    workingDirectory: request.outputDirectory,
    timeout: 24 * 3600,
    stderrHandler: { line in progress?(Self.progressMessage(from: line)) }
)
```

Each tool needs a small command builder:

- `SPAdes`: `spades.py`, `-1` / `-2` or `-s`, `-o`, optional mode/profile flags
- `MEGAHIT`: `megahit`, `-1` / `-2` or `-r`, `-o`, optional `--presets`
- `SKESA`: `skesa`, `--reads`, optional `--use_paired_ends`, `--contigs_out`
- `Flye`: `flye`, `--nano-hq` or other curated profile from `AssemblyOptionCatalog`, `--out-dir`
- `Hifiasm`: `hifiasm`, `-o`, `-t`, input FASTQ, then normalize `*.bp.p_ctg.gfa`

- [ ] **Step 5: Replace the CLI assemble command surface with assembler-neutral options**

`AssembleCommand` should stop constructing `SPAdesAssemblyConfig` directly:

```swift
@Option(name: .long) var assembler: AssemblyTool = .spades
@Option(name: .long) var readType: AssemblyReadType?
@Option(name: .long) var projectName: String = "assembly"
@Option(name: .long) var threads: Int = 8
@Option(name: .long) var memoryGB: Int?
@Option(name: .long) var minContigLength: Int?
@Option(name: .long) var profile: String?
@Option(name: .long, parsing: .upToNextOption) var extraArg: [String] = []
```

Expected CLI behavior:

- `lungfish assemble --help` no longer mentions SPAdes or Apple Containers
- invalid tool/read-type combinations fail early with the same compatibility messages used by the UI
- actual execution routes through `ManagedAssemblyPipeline`

- [ ] **Step 6: Update AppDelegate to launch the generic request**

Replace the SPAdes-only handoff:

```swift
if let request = state.pendingAssemblyRequest {
    try await ManagedAssemblyPipeline().run(request: request)
}
```

The Apple Container-only assembly branch should be removed from the active assembly code path, not from unrelated container code elsewhere in the app.

- [ ] **Step 7: Update `FASTQOperationExecutionService` to build the new CLI invocation**

The `assemble` case should now serialize the neutral request:

```swift
case .assemble(let request, _):
    var arguments = request.inputURLs.map(\.path)
    arguments += [
        "--assembler", request.tool.rawValue,
        "--read-type", request.readType.cliArgument,
        "--project-name", request.projectName,
        "--threads", "\(request.threads)",
        "--output", outputTargetPath,
    ]
```

Append optional `--memory-gb`, `--min-contig-length`, `--profile`, and repeated `--extra-arg` values only when present.

- [ ] **Step 8: Re-run the workflow and CLI test slice**

Run:

```bash
swift test --filter ManagedAssemblyPipelineTests
swift test --filter GFASegmentFASTAWriterTests
swift test --filter FASTQOperationExecutionServiceTests
swift test --filter AssembleCommandRegressionTests
```

Expected: PASS with micromamba-backed command planning and no active assembly dependence on Apple Container entitlement checks.

## Task 6: Normalize Results, Bundles, Provenance, And Viewer Routing Across All Assembly Tools

**Files:**
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyResult.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyProvenance.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyBundleBuilder.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Sources/LungfishIO/Bundles/AnalysesFolder.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift`
- Modify: `Tests/LungfishWorkflowTests/AssemblyBundleBuilderTests.swift`
- Modify: `Tests/LungfishWorkflowTests/Assembly/SPAdesResultSidecarTests.swift`
- Create: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`

- [ ] **Step 1: Add failing tests for generic results and backward compatibility**

Add one new-tool bundle test and one legacy SPAdes fixture compatibility test:

```swift
func testBundleBuilderAcceptsGenericAssemblyResult() async throws

func testLegacySpadesSidecarStillDecodesAfterProvenanceExpansion() throws
```

The backward-compatibility test should load the existing fixture at:

`Tests/Fixtures/analyses/spades-2026-01-15T13-00-00`

and assert that older SPAdes analyses still load successfully after the provenance/result-model changes.

- [ ] **Step 2: Replace `SPAdesAssemblyResult` as the viewer-facing type**

Use a generic result wrapper:

```swift
public struct AssemblyResult: Sendable, Codable, Equatable {
    public let tool: AssemblyTool
    public let readType: AssemblyReadType
    public let contigsPath: URL
    public let graphPath: URL?
    public let logPath: URL?
    public let assemblerVersion: String?
    public let commandLine: String
    public let outputDirectory: URL
}
```

`AssemblyResultViewController` should switch its stored result from `SPAdesAssemblyResult?` to `AssemblyResult?`.

- [ ] **Step 3: Expand provenance for managed-tool execution without breaking old bundles**

Prefer additive changes over destructive renames:

```swift
public enum AssemblyExecutionBackend: String, Codable, Sendable {
    case appleContainerization
    case micromamba
}

public struct AssemblyProvenance: Codable, Sendable {
    public let executionBackend: AssemblyExecutionBackend
    public let managedEnvironment: String?
    public let launcherCommand: String?
    public let containerImage: String?
    public let containerRuntime: String?
}
```

Decode older container-backed records by giving the new managed-tool fields sensible defaults.

- [ ] **Step 4: Update bundle building and analysis-shell routing**

`AssemblyBundleBuilder` should no longer assume SPAdes-specific names such as `spades.log`; it should copy the normalized artifact names from `AssemblyResult`.

Update:

- `AnalysesFolder.swift`
- `MainSplitViewController.swift`
- `SidebarViewController.swift`
- `AnalysesSection.swift`
- `ProvenanceExporter.swift`

so `skesa`, `flye`, and `hifiasm` behave like first-class assembly tools in the UI shell.

- [ ] **Step 5: Re-run the result and viewer slice**

Run:

```bash
swift test --filter AssemblyBundleBuilderTests
swift test --filter SPAdesResultSidecarTests
swift test --filter AssemblyResultViewControllerTests
```

Expected: PASS with generic assembly result handling and no regression for the existing SPAdes analysis fixture.

## Task 7: Run The Final Verification Slice And Manual Smoke Checks

**Files:**
- None

- [ ] **Step 1: Run the focused regression slices in the order they were built**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter AssemblyCompatibilityTests
swift test --filter AssemblyCompatibilityPresentationTests
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter FASTQOperationExecutionServiceTests
swift test --filter ManagedAssemblyPipelineTests
swift test --filter GFASegmentFASTAWriterTests
swift test --filter AssemblyBundleBuilderTests
swift test --filter AssembleCommandRegressionTests
```

Expected: PASS.

- [ ] **Step 2: Run the CLI smoke checks**

Run:

```bash
swift run LungfishCLI conda packs
swift run LungfishCLI assemble --help
```

Expected:

- `conda packs` lists `assembly` alongside `metagenomics`
- `assemble --help` shows `--assembler`, `--read-type`, `--project-name`, and no Apple Container wording

- [ ] **Step 3: Run the full Swift test suite**

Run:

```bash
swift test
```

Expected: PASS for the full package test suite.

- [ ] **Step 4: Perform one manual GUI smoke check in the assembly worktree**

Verify manually:

- the FASTQ operations dialog shows five assembly tools
- mixed read classes are blocked before launch
- `Flye` is unavailable for Illumina input
- `Hifiasm` is unavailable for ONT input
- compatibility strips and readiness messaging use Lungfish palette tokens instead of ad hoc colors
- missing-pack/tool messaging references managed environments, not Apple Container entitlements

- [ ] **Step 5: Commit in logical slices, not one giant change**

Recommended commits:

1. `feat: activate assembly plugin pack`
2. `feat: add neutral assembly request and compatibility model`
3. `feat: unify assembly configuration UI`
4. `feat: run assembly tools via micromamba`
5. `feat: generalize assembly results and provenance`

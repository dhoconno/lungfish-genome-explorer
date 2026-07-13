# MHC Reference GenBank Annotations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build schema-v2 `.lungfishmhcref` bundles from FASTA, GenBank, or EMBL sources, retain recoverable annotations with warnings, and show the embedded canonical reference through the standard reference viewport.

**Architecture:** Extract ordinary reference-source preparation into a shared workflow service, then have the MHC builder create a nested canonical `.lungfishref` payload and retain its FASTA path for existing genotyping consumers. Keep the MHC root UI in SwiftUI and wrap the existing AppKit reference viewport with `NSViewControllerRepresentable`; schema-v1 bundles continue through the legacy path.

**Tech Stack:** Swift 6, XCTest, SwiftUI/AppKit interoperability, LungfishCore bundle manifests, LungfishIO GenBank/FASTA and SQLite annotations, LungfishWorkflow native bundle builder and provenance.

---

## File Map

- Modify `Sources/LungfishIO/Formats/GenBank/GenBankReader.swift`: add per-feature recovery and structured parser warnings without weakening sequence errors.
- Create `Sources/LungfishWorkflow/Bundles/ReferenceSourcePreparer.swift`: shared FASTA/GenBank/EMBL preparation, decompression, metadata, and warning model.
- Modify `Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift`: delegate preparation to the shared component.
- Modify `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift`: schema-v2 manifest, warnings, embedded reference lookup, compatibility validation.
- Modify `Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift`: build the embedded reference and final-path provenance.
- Modify `Sources/LungfishCLI/Commands/FastqMHCReferenceBundleSubcommand.swift`: format-neutral help and warning output while retaining `--reference-fasta`.
- Modify `Sources/LungfishApp/Views/Results/MHCReference/MHCReferenceBundleViewport.swift`: Reference/Haplotypes mode model and SwiftUI wrapper.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+MHCReferenceBundle.swift`: host the revised SwiftUI MHC view and forward reference selections.
- Modify `Sources/LungfishApp/Views/Inspector/Sections/MHCReferenceBundleDocumentSection.swift` and `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`: warnings and embedded artifacts.
- Test in the corresponding `LungfishIOTests`, `LungfishWorkflowTests`, `LungfishCLITests`, and `LungfishAppTests` files.

### Task 1: Recover Valid GenBank Features and Report Invalid Ones

**Files:**
- Modify: `Sources/LungfishIO/Formats/GenBank/GenBankReader.swift`
- Test: `Tests/LungfishIOTests/GenBankReaderTests.swift`

- [ ] **Step 1: Write the failing recovery test**

Add a GenBank record containing a valid `gene 1..6` feature and invalid `CDS bad..location`, then assert the sequence and gene survive while one warning identifies the CDS and invalid location:

```swift
let result = try GenBankReader(url: testFile).readAllRecoveringAnnotationsSync()
XCTAssertEqual(result.records.single?.sequence.bases, "ATGCATGCATGC")
XCTAssertEqual(result.records.single?.annotations.map(\.type), [.gene])
XCTAssertEqual(result.warnings.count, 1)
XCTAssertEqual(result.warnings[0].recordIdentifier, "RECOVER1")
XCTAssertEqual(result.warnings[0].featureType, "CDS")
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter GenBankReaderTests/testRecoveringAnnotationsKeepsSequenceAndValidFeatures`

Expected: compile failure because `readAllRecoveringAnnotationsSync()` does not exist.

- [ ] **Step 3: Add the minimal recovery API**

Introduce public sendable `GenBankParseWarning` and `GenBankRecoveryResult`. Thread a warning collector through record/feature parsing. In `finalizeCurrentFeature`, catch only feature parsing errors, append a warning with record ID, feature type, raw location, and localized reason, reset feature state, and continue. Existing strict `readAll*` methods retain their current throwing behavior; new recovery methods opt into tolerance.

- [ ] **Step 4: Verify GREEN and strict compatibility**

Run: `swift test --filter GenBankReaderTests`

Expected: all GenBank reader tests pass, including the new recovery test.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Formats/GenBank/GenBankReader.swift Tests/LungfishIOTests/GenBankReaderTests.swift
git commit -m "feat: recover valid GenBank annotations"
```

### Task 2: Share Reference-Source Preparation

**Files:**
- Create: `Sources/LungfishWorkflow/Bundles/ReferenceSourcePreparer.swift`
- Modify: `Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleImportServiceTests.swift`
- Test: `Tests/LungfishWorkflowTests/GenBankBEDConversionTests.swift`

- [ ] **Step 1: Write failing shared-preparation tests**

Assert that FASTA yields no annotations/warnings and mixed-validity GenBank yields canonical FASTA, one annotation input, retained valid features after conversion, and one structured warning.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'ReferenceSourcePreparerTests|ReferenceBundleImportServiceTests'`

Expected: compile failure because `ReferenceSourcePreparer` is missing.

- [ ] **Step 3: Extract the shared component**

Create:

```swift
public struct ReferenceImportWarning: Codable, Equatable, Sendable {
    public let category: String
    public let message: String
    public let recordIdentifier: String?
    public let featureType: String?
    public let sourceLocation: String?
}

public struct PreparedReferenceSource: Sendable {
    public let fastaURL: URL
    public let annotationInputs: [AnnotationInput]
    public let sourceInfo: SourceInfo
    public let sequenceNames: [String]
    public let warnings: [ReferenceImportWarning]
}
```

Move extension classification, decompression, FASTA preparation, and tolerant GenBank preparation behind `ReferenceSourcePreparer.prepare(sourceURL:bundleName:tempDirectory:)`. Delegate `ReferenceBundleImportService` to it without changing its public result or provenance behavior.

- [ ] **Step 4: Verify ordinary import parity**

Run: `swift test --filter 'ReferenceBundleImportServiceTests|GenBankBEDConversionTests'`

Expected: all tests pass and annotated ordinary GenBank imports still contain queryable annotation rows.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Bundles/ReferenceSourcePreparer.swift Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift Tests/LungfishAppTests/ReferenceBundleImportServiceTests.swift Tests/LungfishWorkflowTests/GenBankBEDConversionTests.swift
git commit -m "refactor: share reference source preparation"
```

### Task 3: Add Schema-v2 Embedded Reference Contracts

**Files:**
- Modify: `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift`
- Test: `Tests/LungfishIOTests/MHCAmpliconReferenceBundleTests.swift`

- [ ] **Step 1: Write failing v1/v2 tests**

Add tests that decode a legacy manifest, resolve a v2 embedded reference, validate its standard manifest and annotation database, and reject traversal/missing paths.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter MHCAmpliconReferenceBundleTests`

Expected: compile failure because `referenceBundlePath` and `warnings` are absent.

- [ ] **Step 3: Implement versioned manifest decoding**

Add optional `referenceBundlePath`, defaulted `warnings`, schema-aware decoding, and `embeddedReferenceBundleURL(in:)`. Support versions `1...2`; require and deeply validate the embedded ordinary manifest for v2. Keep `referenceFASTAURL(in:)` and all haplotype APIs source-compatible.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter 'MHCAmpliconReferenceBundleTests|ReferenceBundleEnvelopeTests'`

Expected: all format/envelope tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift Tests/LungfishIOTests/MHCAmpliconReferenceBundleTests.swift Tests/LungfishIOTests/ReferenceBundleEnvelopeTests.swift
git commit -m "feat: version MHC embedded reference payload"
```

### Task 4: Build FASTA and GenBank MHC Payloads with Provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift`
- Test: `Tests/LungfishWorkflowTests/MHCAmpliconReferenceBundleBuilderTests.swift`

- [ ] **Step 1: Write failing FASTA and GenBank builder tests**

The FASTA test asserts schema v2, embedded `manifest.json`, sequence-only annotations, and a working `referenceFASTAURL`. The GenBank test asserts a queryable embedded annotation DB and warning persistence for an invalid sibling feature. Provenance assertions reject `.staging-` paths and require original source and final published embedded paths.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter MHCAmpliconReferenceBundleBuilderTests`

Expected: failures because the builder still copies a top-level FASTA and writes schema v1.

- [ ] **Step 3: Implement the embedded build**

Change configuration terminology to `referenceSource` while retaining a deprecated/source-compatible `referenceFASTA` initializer label if required by existing call sites. Prepare the source, call `NativeBundleBuilder` with provenance disabled to create the nested canonical payload, resolve its manifest FASTA path, copy haplotypes/sources, write v2 warnings, validate, and publish atomically.

Expand root provenance inputs/options to use the original source format. Add warnings to options/step stderr and enumerate all staged files as final published output descriptors. Never record the embedded native builder's staging path as durable output.

- [ ] **Step 4: Verify GREEN and rollback behavior**

Run: `swift test --filter MHCAmpliconReferenceBundleBuilderTests`

Expected: all builder, provenance, and replacement rollback tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift Tests/LungfishWorkflowTests/MHCAmpliconReferenceBundleBuilderTests.swift
git commit -m "feat: build annotated MHC reference payloads"
```

### Task 5: Preserve the CLI Contract and Emit Warnings

**Files:**
- Modify: `Sources/LungfishCLI/Commands/FastqMHCReferenceBundleSubcommand.swift`
- Test: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`
- Test: `Tests/LungfishCLITests/FastqGenotypingBundleReferenceTests.swift`

- [ ] **Step 1: Write failing CLI tests**

Assert `--reference-fasta` parses both FASTA and GenBank configuration, help names all supported formats, replay argv retains the legacy option, and warnings are written to stderr after a successful build.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'FastqGenotypingCommandTests|FastqGenotypingBundleReferenceTests'`

- [ ] **Step 3: Update CLI plumbing**

Keep the option spelling, pass the value as `referenceSource`, update help, and render each result warning as `Warning: <message>` without changing exit status.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter 'FastqGenotypingCommandTests|FastqGenotypingBundleReferenceTests'`

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCLI/Commands/FastqMHCReferenceBundleSubcommand.swift Tests/LungfishCLITests/FastqGenotypingCommandTests.swift Tests/LungfishCLITests/FastqGenotypingBundleReferenceTests.swift
git commit -m "feat: accept GenBank MHC reference sources"
```

### Task 6: Add SwiftUI Reference/Haplotypes Modes and Inspector Details

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/MHCReference/MHCReferenceBundleViewport.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+MHCReferenceBundle.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/MHCReferenceBundleDocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Test: `Tests/LungfishAppTests/MHCReferenceBundleViewportTests.swift`
- Test: `Tests/LungfishAppTests/MHCReferenceBundleSidebarTests.swift`

- [ ] **Step 1: Write failing viewport/inspector tests**

Assert v2 defaults to `.reference`, v1 defaults to `.haplotypes`, the model exposes the embedded bundle URL/manifest, the representable configures `ReferenceBundleViewportController`, toggling retains both models, and inspector state includes warnings and embedded payload/annotation artifacts.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'MHCReferenceBundleViewportTests|MHCReferenceBundleSidebarTests'`

- [ ] **Step 3: Implement the SwiftUI modes**

Add `MHCReferenceBundleViewportMode`, mode state, and a segmented picker. Extract the legacy raw-FASTA/haplotype content into Haplotypes mode. Add `MHCEmbeddedReferenceViewport: NSViewControllerRepresentable` that constructs and configures `ReferenceBundleViewportController` from `.directBundle(bundleURL:manifest:)` once and preserves the controller across SwiftUI updates.

- [ ] **Step 4: Add warnings and artifacts to the inspector**

Extend `MHCReferenceBundleDocumentState` with `warningRows`. Render a Warnings disclosure only when non-empty. Enumerate embedded manifest annotation payload/database paths through validated bundle-member resolution and keep the outer MHC bundle as provenance target.

- [ ] **Step 5: Verify GREEN**

Run: `swift test --filter 'MHCReferenceBundleViewportTests|MHCReferenceBundleSidebarTests|ReferenceBundleViewportControllerTests'`

Expected: all MHC and shared viewport tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Results/MHCReference/MHCReferenceBundleViewport.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+MHCReferenceBundle.swift Sources/LungfishApp/Views/Inspector/Sections/MHCReferenceBundleDocumentSection.swift Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift Tests/LungfishAppTests/MHCReferenceBundleViewportTests.swift Tests/LungfishAppTests/MHCReferenceBundleSidebarTests.swift
git commit -m "feat: browse MHC annotations in reference mode"
```

### Task 7: Full Verification and Documentation Consistency

**Files:**
- Modify if needed: `docs/superpowers/specs/2026-07-13-mhc-reference-genbank-annotations-design.md`

- [ ] **Step 1: Run focused feature suites**

Run:

```bash
swift test --filter 'GenBankReaderTests|ReferenceBundleImportServiceTests|MHCAmpliconReferenceBundleTests|MHCAmpliconReferenceBundleBuilderTests|FastqGenotypingCommandTests|FastqGenotypingBundleReferenceTests|MHCReferenceBundleViewportTests|MHCReferenceBundleSidebarTests|ReferenceBundleViewportControllerTests'
```

Expected: zero failures.

- [ ] **Step 2: Run package tests and build**

Run: `swift test`

Run: `swift build`

Expected: both exit 0 without new warnings attributable to this feature.

- [ ] **Step 3: Audit provenance and compatibility requirements**

Search generated test bundles/provenance assertions for original inputs, resolved defaults, checksums/sizes, final output paths, warning text, exit status, and wall time. Confirm legacy FASTA CLI, schema-v1 loading, and all existing MHC builder call sites compile.

- [ ] **Step 4: Review diff and commit any final corrections**

```bash
git diff --check
git status --short
```

Commit only required final corrections with a focused message.

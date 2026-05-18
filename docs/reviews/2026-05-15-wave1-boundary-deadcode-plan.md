# Wave 1 Boundary Dead-Code Plan

Goal: perform low-risk module-boundary cleanup in `codex/wave1-boundary-deadcode` while avoiding broad API or module removals that need cross-worker coordination.

## Wave 1 Changes

1. Split `OperationCenter` out of `Sources/LungfishApp/Services/DownloadCenter.swift`.
   - Create `Sources/LungfishApp/Services/OperationCenter.swift` containing `OperationType`, operation log/retry/route models, `OperationCenter`, and the private ETA formatter.
   - Keep `DownloadCenter.swift` as a compatibility shim with `public typealias DownloadCenter = OperationCenter`.
   - Preserve existing `cancel(id:)` behavior for running operations without an `onCancel` callback: do not mark cancelled and do not release bundle locks while underlying work may still continue. Leave callback gaps to the dedicated cancellation wave.
   - Verification: run targeted `LungfishAppTests` covering `OperationCenter`, operation routing, and `DownloadCenter` compatibility.

2. Remove only deprecated public aliases with no internal references.
   - Candidate removals:
     - `LungfishCore.DocumentType` alias for `DocumentCategory`.
     - `IlluminaBarcodeDefinition`, `IlluminaBarcode`, and `IlluminaBarcodeKitRegistry` aliases for barcode kit models.
   - Keep non-deprecated aliases (`DownloadCenter`, `FileCategory`, `WorkflowSchema`, `ParameterGroup`, `WorkflowParameter`) unless a later API review approves their removal.
   - Verification: run targeted package tests and a build to catch compile-time references.

3. Do not move Core AppKit usage in Wave 1.
   - `SequenceAppearance`, `AppSettings`, and `SemanticColors` expose `NSColor` in public APIs. Replacing these requires adapters and migration tests across Core, UI, and App.
   - Wave 1 output should document a precise Wave 2 extraction path instead of making a large API change.

4. Do not delete broad modules in Wave 1.
   - `LungfishUI` and `LungfishPlugin` are package products with dedicated tests, and `LungfishUI` is a dependency of `LungfishApp` and integration tests.
   - `WorkflowConfigurationPanel` appears production-unreferenced except for tests, while `SnakemakeRunner` appears test-only inside `LungfishWorkflowTests`; both need a Wave 2 deprecation/removal plan before deletion.

## Verification Commands

- `swift test --filter OperationCenter`
- `swift test --filter DownloadCenterTests`
- `swift test --filter IlluminaBarcodeKitTests`
- `swift test --filter DocumentCategoryRegressionTests`
- `swift build`
- `git diff --check`

## Wave 1 Findings

- `DownloadCenter` cannot be removed in Wave 1. It is still used by `AppDelegate`, `DatabaseBrowserViewController`, `MainSplitViewController`, extraction UI paths, and `DownloadCenterTests`.
- Deprecated aliases removed in Wave 1 have no Swift references outside their definitions:
  - `LungfishCore.DocumentType`
  - `IlluminaBarcodeDefinition`
  - `IlluminaBarcode`
  - `IlluminaBarcodeKitRegistry`
- Core AppKit removal is larger than Wave 1. `SequenceAppearance`, `AppSettings`, and `SemanticColors` expose `NSColor` in public APIs and conversion helpers.
- `LungfishUI` is not dead: it is a public product, a `LungfishApp` dependency, and imported by unit/integration tests.
- `LungfishPlugin` is not deleted in Wave 1: it is a public product with dedicated plugin tests. It appears unwired from app workflows, but removal would be product/API work.
- `WorkflowConfigurationPanel` is production-defined but appears only self-referenced plus `WorkflowConfigurationPanelTests`; no app entry point creates it in the current tree.
- `SnakemakeRunner` is production-defined but appears instantiated only by `ManagedWorkflowRunnerPathTests`; classify as Wave 2 review before deprecation or test-support migration.

## Wave 2 Implementation Spec

1. Core color boundary:
   - Add a `ColorValue: Codable, Sendable, Equatable` type to Core with RGBA components and hex conversion.
   - Change Core settings models to store and expose `ColorValue` or hex strings, not `NSColor`.
   - Add App/UI extensions such as `ColorValue+AppKit.swift` outside Core for `NSColor` conversion.
   - Test Codable round trips, malformed hex fallback behavior, and AppKit conversion equivalence for current default colors.

2. Workflow surface pruning:
   - Add an explicit feature owner decision for `WorkflowConfigurationPanel`: revive with a menu/toolbar entry, move to experimental app code, or delete with its tests.
   - Add an explicit API owner decision for `SnakemakeRunner`: keep public workflow SDK surface, mark deprecated, or move implementation into test support.
   - Before deletion, run `rg -n "WorkflowConfigurationPanel|SnakemakeRunner"` across Swift, docs, scripts, and archived plans to update or preserve any intentional references.

3. Product boundary review:
   - For `LungfishUI`, decide whether `LungfishApp` still needs the package dependency or whether rendering code has migrated elsewhere.
   - For `LungfishPlugin`, decide whether plugins should be wired into `LungfishApp`/`LungfishCLI`, kept as SDK-only, or removed from published products.
   - Any product deletion must include `Package.swift` product/target/test changes plus a full package build and affected test target run.

# Wave 2 AppKit Concurrency and Modal Safety Plan

## Issue IDs

- W2C-1: Unsafe AppKit callback hops still use `Task { @MainActor ... }` or `Task.detached { await MainActor.run { ... } }` in UI paths.
- W2C-2: Production `.runModal(` calls are not guarded by a source regression or legacy exception comments.
- W2C-3: OperationCenter progress updates in BLAST verification, taxonomy extraction, FASTQ ingestion, GATK, and barcode scout paths can update visible status without a corresponding operation history log.
- W2C-4: EsViritu, NCBI, and native tool provisioning downloads need explicit Swift task cancellation bridged to `URLSessionDownloadTask` plus byte/progress callbacks.

## Red Tests / Static Regressions

- Added `DownloadCenterTests.testUpdateWithLogDeduplicatesAdjacentProgressMessages`.
  - Red command: `swift test --filter DownloadCenterTests`
  - Red result:

```text
Tests/LungfishAppTests/DownloadCenterTests.swift:95:16: error: value of type 'DownloadCenter' (aka 'OperationCenter') has no member 'updateWithLog'
center.updateWithLog(id: id, progress: 0.1, detail: "Parsing reads")
```

- Added `AppKitConcurrencyModalSafetyTests` to flag production `.runModal(` without `runModal-legacy-allowed` comments and targeted unsafe AppKit actor hops.
  - Red command: `swift test --filter AppKitConcurrencyModalSafetyTests`
  - Red result:

```text
Unexpected production runModal calls without runModal-legacy-allowed justification:
Sources/LungfishApp/App/AppDelegate.swift:637
Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift:589
Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:1304
...

Unsafe AppKit callback actor hops must use DispatchQueue.main/MainActor.assumeIsolated or performOnMainRunLoop:
Sources/LungfishApp/App/AppDelegate.swift: contains Task { @MainActor
Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift: contains Task { @MainActor
Sources/LungfishApp/Services/CLIMSAActionRunner.swift: contains await MainActor.run
...
```

- Added `NCBIDownloadCancellationSourceTests` and `DownloadCancellationSourceTests` to flag delegate-backed downloads missing cancellation, progress, and single-resume guards.
  - Red commands: `swift test --filter NCBIDownloadCancellationSourceTests`, `swift test --filter DownloadCancellationSourceTests`
  - Red result:

```text
XCTAssertTrue failed: source contains "withTaskCancellationHandler"
XCTAssertTrue failed: source contains ".cancel()"
XCTAssertTrue failed: source contains "resumeOnce"
XCTAssertTrue failed: ToolProvisioner download is cancellable/progressive
```

## Implementation

- Added `OperationCenter.updateWithLog(id:progress:detail:level:deduplicateAdjacent:)` and migrated feasible progress-only updates in FASTQ ingestion, BLAST verification, VCF/GATK-style import progress, BAM import progress, NVD BLAST parsing, and CZ-ID import.
- Replaced targeted AppKit callback actor hops with main-run-loop or main-queue `MainActor.assumeIsolated` helpers in `AppDelegate`, `AssemblyConfigurationViewModel`, `DatabaseBrowserViewController`, and CLI runner files.
- Migrated practical modal alert/open-panel call sites to `beginSheetModal` or async `begin` flows in workflow builder, database browser, primer scheme import, CZ-ID import, and annotation drawer create/edit flows. Remaining production `runModal` calls are isolated fallback paths with `runModal-legacy-allowed because ...` comments.
- Converted EsViritu, NCBI, and ToolProvisioner downloads to delegate-backed `URLSessionDownloadTask` wrappers with `withTaskCancellationHandler`, locked task storage, progress callbacks, session invalidation, cancellation error mapping, and single-resume delegates.

## Verification

- `swift test --filter AppKitConcurrencyModalSafetyTests` - passed, 2 tests.
- `swift test --filter DownloadCenterTests/testUpdateWithLogDeduplicatesAdjacentProgressMessages` - passed, 1 test.
- `swift test --filter NCBIDownloadCancellationSourceTests` - passed, 1 test.
- `swift test --filter DownloadCancellationSourceTests` - passed, 2 tests.
- `swift build --target LungfishApp` - passed.
- `git diff --check` - passed.

## Residual Risks

- Some `runModal` sites remain as no-presenter-window or synchronous utility fallbacks. They are documented and guarded by the source regression.
- Source regressions are intentionally conservative; they guard known anti-patterns but do not prove every async callback is semantically correct.
- Download cancellation tests are source-level guards rather than live network cancellation tests to avoid brittle external dependencies.
- Barcode scout status is currently drawer-local rather than OperationCenter-backed, so there was no corresponding OperationCenter history stream to migrate in this lane.

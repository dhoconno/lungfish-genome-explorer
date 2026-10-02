# LungfishKit

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

The shared UI kernel between LungfishWorkflow and the leaf UI modules. It holds the operation registry, the CLI subprocess transport, shared AppKit components (BLAST drawer, classifier action bar, split panes, batch tables, row commands) and brand styling. Anything two leaves need goes here, not in LungfishApp (memory file project_module_architecture.md).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, AppKit, SwiftUI and Combine. Never LungfishApp or a leaf UI module, since leaves import Kit and Kit must stay below them.

## The operation path

| Step | Type | Path |
|---|---|---|
| Register the operation and take bundle locks | `OperationCenter.begin` | Sources/LungfishKit/OperationCenter.swift line 641 |
| Spawn `lungfish-cli` and decode its event stream | `CLISubprocessTransport.run` | Sources/LungfishKit/CLISubprocessTransport.swift line 94 |
| Map each `CLIEvent` onto the operation row | `OperationCenterCLIBridge` | Sources/LungfishApp/Services/OperationCenterCLIBridge.swift line 20 |
| Find the CLI binary | `CLIBinaryLocator` | Sources/LungfishKit/CLIBinaryLocator.swift line 17 |
| Track and reveal the analysis folder | `OperationCenter.trackAnalysisOutput` | OperationCenter.swift line 1170 |

`begin` returns `.started` or `.refused`, so a bundle-lock conflict cannot be ignored. Pass `operationType` and `cliCommand` every time. The bridge currently lives in LungfishApp, so leaves reach the path only through App glue until the Phase 3 launcher lands. Pipeline steps call both `update` and `log`, or the expanded row loses its history (memory file reference_runtime_patterns.md).

## Other entry points

| Type | Path |
|---|---|
| Window-scoped notification key | `WindowStateScope`, Sources/LungfishKit/WindowStateScope.swift line 3 |
| Shared result table | Sources/LungfishKit/BatchTableView.swift |
| Row commands for menus and accessibility | `RowCommand`, Sources/LungfishKit/Accessibility/RowCommand.swift line 35 |
| BLAST results drawer | `BlastResultsDrawerContainerView`, Sources/LungfishKit/BlastResultsDrawerContainerView.swift line 68 |
| Brand colors | Sources/LungfishKit/LungfishColors.swift |

## Contracts this module owns

- Bundle locks serialize operations on one bundle (`canStartOperation`, `activeLockHolder`, OperationCenter.swift lines 510 and 515).
- Every operation records a non-nil CLI command (REVIEW.md invariants).
- Kit types are `public` and free of App types.

## Tests

Target LungfishKitTests in Tests/LungfishKitTests (OperationCenter suites, row actions, BLAST drawer). Run only it with `swift test --skip-update --filter LungfishKitTests`.

## Known traps

| Trap | Evidence |
|---|---|
| `start` is deprecated but still has 58 callers, and new code copies it | `@available` at OperationCenter.swift line 596 (R4) |
| `operationType` defaults to `.download` and `cliCommand` to nil | OperationCenter.swift lines 389, 398, 601, 605, 644 and 648 (R4) |
| Bundle import after completion runs through a closure AppDelegate sets once | `onBundleReady`, OperationCenter.swift lines 433 to 435 (R4) |
| The file named ResultViewportController.swift holds no viewport protocol, only export and BLAST request types | Sources/LungfishKit/ResultViewportController.swift lines 15 and 40 (R1) |
| Production code branches on whether tests are running | Sources/LungfishKit/TestHarnessDetection.swift line 11 (R10) |
| Process() is created directly | CLISubprocessTransport.swift, LungfishCLIRunner.swift and CLIBinaryLocator.swift (R7) |

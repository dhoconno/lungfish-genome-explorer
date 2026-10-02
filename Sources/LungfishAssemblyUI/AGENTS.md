# LungfishAssemblyUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for de novo assembly results. It shows the contig table, the summary strip, the contig detail pane and the action bar, and it can materialize selected contigs. Assembly itself runs in Sources/LungfishWorkflow/Assembly (`ManagedAssemblyPipeline`, `SPAdesAssemblyPipeline`).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `AssemblyResultViewController` and `configure(result:)` | Sources/LungfishAssemblyUI/AssemblyResultViewController.swift lines 20 and 664 |
| Contig table | Sources/LungfishAssemblyUI/AssemblyContigTableView.swift |
| Contig materialization action | Sources/LungfishAssemblyUI/AssemblyContigMaterializationAction.swift |
| Panel layout preference | `AssemblyPanelLayout`, Sources/LungfishAssemblyUI/AssemblyLayoutPreference.swift line 9 |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift |

## Contracts this module owns

- The controller reaches app services only through its `on...` callbacks, wired by the App glue file.

## Tests

Target LungfishAssemblyUITests in Tests/LungfishAssemblyUITests. Run only it with `swift test --skip-update --filter LungfishAssemblyUITests`. AssemblyResultViewControllerTests is in PARALLEL_HAZARD_SUITES, so the gate runs it serially (scripts/full-suite-gate.sh line 151).

## Known traps

| Trap | Evidence |
|---|---|
| Rapid arrow-key navigation between contigs can crash in Apple Containers NIO with a bad file descriptor | memory file known-issues.md |
| BLAST result display is copied per viewport | `showBlastResults`, AssemblyResultViewController.swift line 576 (R14) |
| The App has 86 files that mention Assembly, so the leaf did not remove App coupling | REVIEW.md R1 |

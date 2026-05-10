# Architecture Refactoring Plan — Expert Report

## Critical Recommendation: Do NOT Split LungfishApp Module

The architecture expert analyzed the codebase and **recommends against** splitting LungfishApp into separate modules. The cost far exceeds the benefit because:
- Deep coupling through view controller chains (30+ call sites)
- Circular dependencies between "dataset" and "genome browser" components
- Swift concurrency boundary hazards at module interfaces
- Test disruption (1,397+ tests use internal APIs)
- No build time improvement (modules would have mutual dependencies)

## Instead: Decompose AppDelegate (4,500 lines → ~400 lines)

### Phase 0: Convenience Accessors (30 min)
- Add `activeViewerController`, `activeSidebarController`, etc. to AppDelegate
- Replace all 30+ triple-chain accesses (`mainWindowController?.mainSplitViewController?.viewerController`)

### Phase 1: Extract Coordinators (4-8 hours, highest value)
| New File | Lines Moved | Responsibility |
|---|---|---|
| FileImportCoordinator.swift | ~800 | VCF/BAM/ONT/metadata import |
| FileExportCoordinator.swift | ~700 | FASTA/GenBank/GFF3/image/FASTQ export |
| SequenceActionCoordinator.swift | ~300 | Reverse complement, translate, go-to, extract |
| ToolsCoordinator.swift | ~200 | SPAdes, primers, database search |
| AIAssistantCoordinator.swift | ~250 | AI service, tool registry |
| DownloadCoordinator.swift | ~250 | Download handling, file copy/dedup |
| SyncFileLoader.swift | ~400 | Background file loading, embedded parsers |

AppDelegate becomes ~400 lines: lifecycle + one-line action forwarding.

### Phase 2: Menu Reorganization
Proposed structure:
```
File | Edit | View | Navigate | Tools | Window | Help
```
- **Navigate**: Go to Position, Go to Gene, Search Online Databases
- **Tools**: Assembly, Primer Design, Alignment, ORFs, Restriction Sites
- Move Operations Panel to **View** menu
- Remove standalone Sequence and Operations top-level menus
- Keep "Tools" name (bioinformatics convention, not "Analyze")

### Phase 3: Module Split — NOT RECOMMENDED
Defer indefinitely. Only revisit if app grows beyond 200 files AND team beyond 2-3 developers.

## Status: Phases 0 and 2 partially complete
- Phase D already added Go to Gene shortcut and fixed keyboard shortcuts
- Convenience accessors (Phase 0) and coordinator extraction (Phase 1) deferred to next session

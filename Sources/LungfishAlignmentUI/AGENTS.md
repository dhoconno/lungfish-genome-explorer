# LungfishAlignmentUI

Line numbers were checked at commit a0eec8b32.

## Purpose

Leaf UI module with one 300-line summary viewport for BAM read-mapping results. Pileup and coverage drawing live in the genome browser code in Sources/LungfishApp/Views/Viewer, not here (REVIEW.md R13).

## Allowed imports

LungfishWorkflow, LungfishKit, LungfishCore, LungfishIO and AppKit, as declared in Package.swift. Never LungfishApp or another leaf module.

## Entry points

| Type | Path |
|---|---|
| `AlignmentResultViewController` and `configure(result:)` | Sources/LungfishAlignmentUI/AlignmentResultViewController.swift lines 68 and 257 |
| Result type it renders | `Minimap2Result`, from Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift |

## Contracts this module owns

- Shows a summary of a sorted, indexed BAM. It never writes alignments.

## Tests

Target LungfishAlignmentUITests in Tests/LungfishAlignmentUITests. Run only it with `swift test --skip-update --filter LungfishAlignmentUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| No file in Sources/LungfishApp imports this module at a0eec8b32, so the viewport is not reachable from the app today | grep for `import LungfishAlignmentUI` finds only tests. The review plans to fold or fill it (R13) |
| `Minimap2Pipeline` survives as this view's result type although the live mapping path is `ManagedMappingPipeline` | Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift (R15). Phase 0 keeps both untouched |
| Splice-aware views for RNA-seq would land in the App renderer, which has no plug-in seam | Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift lines 312 to 328 handle CIGAR N and D (R13) |

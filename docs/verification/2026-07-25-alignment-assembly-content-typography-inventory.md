# Result Viewport Content Typography Inventory

This inventory records the Task 3b audit of primary content in the Alignment,
Assembly, Phylogenetic, and 12S result viewports. Each adopted surface resolves from
`ContentTypography` at creation and responds to
`contentTextSizeDidChange` without scaling an already-scaled font.

| Source | Surface | Classification | Resolution and geometry |
| --- | --- | --- | --- |
| `AlignmentResultViewController.swift` | Alignment summary label | Primary result content | Caption role; summary bar height grows from resolved line metrics. |
| `AlignmentResultViewController.swift` | BAM identity and explanatory placeholder | Primary detail content | Detail role; unlimited word wrapping and bounded horizontal margins. |
| `AssemblyContigDetailPane.swift` | Section headings | Primary detail content | Table-header role. |
| `AssemblyContigDetailPane.swift` | Contig title | Primary detail content | Emphasized-body role with unlimited word wrapping. |
| `AssemblyContigDetailPane.swift` | Length, GC, rank, and assembly-share metrics | Primary detail content | Body role; one row at ordinary sizes and two rows at 175–200 percent. |
| `AssemblyContigDetailPane.swift` | FASTA sequence preview | Primary detail content | Monospaced role; adaptive minimum height. Selection and scroll origin are restored after a live update. |
| `AssemblyContigTableView.swift` | Search field, headers, and contig cells | Primary list content through shared path | Inherits the reviewed `BatchTableView` body/monospaced/table-header fonts and adaptive row/header heights. It declares no local font override. User column widths are not changed; full header text remains in tooltips. |
| `AssemblyResultViewController.swift` | No-contigs empty state | Primary result content | Emphasized-body role with existing unlimited wrapping. |
| `AssemblySummaryStrip.swift` | Metric titles and values | Primary summary content | Caption/body roles; metrics wrap into multiple rows at large sizes and the strip height follows resolved metrics. Optional fields use the current typography when created. |
| `PhylogeneticTreeViewController.swift` | Loaded-tree summary | Primary summary content | Emphasized-body role; unlimited word wrapping and measured toolbar height. |
| `PhylogeneticTreeViewController.swift` | Selected-node detail and Nodes drawer title | Primary detail content | Detail/table-header roles; detail is capped at three visual lines while preserving the complete tooltip and accessibility value, with a canvas-reserved detail region and a content-measured drawer height. |
| `PhylogeneticTreeViewController.swift` | Node-table cells and headers | Primary list content | Body/table-header roles with adaptive row/header height and stable, recoverable user column baselines. The table and cells expose full accessible values. |
| `TwelveSAmpliconResultViewController.swift` | Result title and summary | Primary title/summary content | Stable 18-point semibold and 12-point regular baselines follow System metrics and custom percentage scaling. Both wrap without truncating and expose their full accessible values. |
| `TwelveSAmpliconResultViewController.swift` | Viewport result search | Primary result content | Body role; field height and fitting width follow resolved font metrics. |
| `TwelveSTargetTableView.swift` | Target search, headers, result cells, and late sample-metadata columns | Primary list content through shared path | Inherits `BatchTableView`; row/header/search geometry and stable user column baselines scale and recover. Columns added or re-added while enlarged receive current fonts and geometry immediately. |
| `TwelveSUnresolvedTableView.swift` | Unresolved search, headers, and result cells | Primary list content through shared path | Inherits `BatchTableView`; the Bases cell preserves its fixed-pitch 11-point baseline while following System/custom scale. |

The two 12S result modes have distinct table/search accessibility identifiers
and labels. Full scientific names, metadata strings, and base sequences remain
available through their cell text/accessibility values even when a column is
narrower than the rendered content.

## Control chrome retained

Assembly action buttons and menus remain native AppKit control chrome. Their
fonts are owned by AppKit and are intentionally not overridden by the content
text-size preference.

Phylogenetic search, fit/reset/zoom/layout/color controls, tip popups, and menus
remain native control chrome. In 12S, the Targets/Unresolved segmented control,
sample filter/column buttons, action bar, menus, popovers, and BLAST controls
remain native control chrome.

## Scientific rendering exclusions

- BAM pileup, coverage tracks, base-coordinate rulers, and other
  pixels-per-base renderers are controlled by scientific zoom, not content text
  size. They are not implemented in `AlignmentResultViewController.swift`.
- Assembly graph/tape geometry and future base-coordinate renderers remain
  scientific zoom surfaces. The ordinary FASTA sequence `NSTextView` in the
  detail pane is primary detail text and is therefore included.
- The phylogenetic canvas is deliberately excluded bit-for-bit: its 11-point
  tip labels, 9-point support/scale labels, margins, tip spacing, node radius,
  label gap/width, base size, coordinates, branch scale, hit geometry, zoom,
  layout, color, collapse, selection, fit, and center behavior remain owned by
  scientific rendering. A content typography notification neither configures
  nor recomputes the tree.
- 12S aggregation, display filtering, reference-sequence lookup, detail
  emission, and display-summary notifications are scientific/result-state
  operations and are not invoked by typography updates.

No audited primary-content site in these four result families retains an
unscaled fixed AppKit font size after this adoption.

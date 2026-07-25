# Alignment and Assembly Content Typography Inventory

This inventory records the Task 3b-A audit of primary content in the Alignment
and Assembly result viewports. Each adopted surface resolves from
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

## Control chrome retained

Assembly action buttons and menus remain native AppKit control chrome. Their
fonts are owned by AppKit and are intentionally not overridden by the content
text-size preference.

## Scientific rendering exclusions

- BAM pileup, coverage tracks, base-coordinate rulers, and other
  pixels-per-base renderers are controlled by scientific zoom, not content text
  size. They are not implemented in `AlignmentResultViewController.swift`.
- Assembly graph/tape geometry and future base-coordinate renderers remain
  scientific zoom surfaces. The ordinary FASTA sequence `NSTextView` in the
  detail pane is primary detail text and is therefore included.

No audited Alignment or Assembly primary-content site retains a fixed AppKit
font size after this adoption.

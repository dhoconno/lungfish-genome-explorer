# FASTA/FASTQ View Harmonization — Expert Analysis

## Verdict: Separate view controllers, shared summary card component

The FASTQ Dashboard and FASTA Collection View serve fundamentally different workflows and should NOT be unified into a single view. However, they should share a common summary card bar component.

## Why Not Unify?

| FASTQ Dashboard | FASTA Collection |
|---|---|
| Quality scores (Q20, Q30, boxplots) | No quality scores |
| No annotations | Rich annotations (genes, CDS, etc.) |
| 17 FASTQ-specific operations | Different operations (translate, align, BLAST) |
| Read preview table (4-line records) | Sequence table with annotation maps |
| QC-centric workflow | Browse-and-inspect workflow |

## What to Share

### 1. GenomicSummaryCardBar (extract from FASTQSummaryBar)
A generic horizontal card strip that both views subclass. The drawing logic already exists in FASTQSummaryBar — just needs the card array construction pulled out.

### 2. Display-in-place-of-viewer pattern
Both views replace the ViewerViewController content area using the same child-VC mechanism.

### 3. Shared formatters (formatCount, formatBases)

## FASTA Collection View Design

```
+------------------------------------------------------------------+
| [Summary Cards: 500 seqs | 4.8 Mb | 12,450 annotations | ...]   |
+------------------------------------------------------------------+
| Name          | Length  | Annotations | GC%  | Mini Map           |
| NC_045512.2   | 29,903 | 42          | 38.0 | [====||==||=]      |
| MN908947.3    | 29,903 | 41          | 37.9 | [====||==||=]      |
| (selected)                                                        |
+------------------------------------------------------------------+
| Detail Panel: NC_045512.2 — SARS-CoV-2 isolate...                |
| Features: 12 CDS, 6 gene, 3 mat_peptide, 21 misc                |
| [Open in Browser]  [Export]                                       |
+------------------------------------------------------------------+
```

### Key elements:
- **Annotation count column** — sortable, filterable
- **Mini annotation map** — thin colored bar per row showing feature positions
- **Bottom detail panel** on selection — description, feature breakdown, "Open in Browser"
- **"Open in Browser"** switches to genome browser with that sequence + annotations

## Auto-detection trigger (in displayDocument)
```
if document.sequences.count > 1 → show FASTACollectionViewController
if document.sequences.count == 1 → show genome browser (existing)
```

## New files needed
1. `GenomicSummaryCardBar.swift` — shared base class (extract from FASTQSummaryBar)
2. `FASTACollectionViewController.swift` — the new view controller
3. `FASTAAnnotationMapCell.swift` — mini annotation map table cell

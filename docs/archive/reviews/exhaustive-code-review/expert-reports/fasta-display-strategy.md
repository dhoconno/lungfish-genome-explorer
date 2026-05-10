# Multi-Sequence FASTA Display Strategy — Expert Analysis

## Key Insight
No tool tries to make one view do everything. Separate "reference browsing" from "sequence comparison." Auto-detect which mode to use.

## Auto-Detection Heuristic
```
IF count == 1:           → Single-sequence genome browser view
ELIF count ≤ 50 AND max_length > 50kb: → Reference mode (chromosome navigator)
ELIF count > 50 OR max_length < 10kb:  → Sequence List view (table)
ELSE:                    → Reference mode (default), user can switch
```

## Do NOT Stack Unaligned Sequences
Stacking unaligned sequences in a coordinate browser is misleading — position 500 in Allele-A has no biological relationship to position 500 in Allele-B. Reserve stacking for aligned sequences only.

## Recommended Priorities

| Priority | Action | Effort |
|----------|--------|--------|
| **P0** | Fix display bug (done: commit caddfe4) | Done |
| **P0** | Show all sequences via chromosome navigator for raw FASTA | Small |
| **P0** | Auto-detect reference vs. collection mode | Small |
| **P1** | Sequence List view (table with name/length/desc, click-to-view) | Medium |
| **P1** | "View as Reference / View as List" toggle | Small |
| **P2** | "Align selected" via MAFFT/NativeToolRunner | Medium |
| **P2** | Open aligned FASTA as pseudo-BAM in existing viewer | Medium |
| **P3** | Dedicated MSA viewer | Large |

## The .lungfishref Bundle Does NOT Change
The bundle is the canonical format for indexed references. What changes is that raw FASTA files get context-aware presentation recognizing not every FASTA is a reference genome.

## How Other Tools Handle This
- **IGV**: FASTA = reference only, one chromosome at a time
- **Geneious**: Auto-detects; reference mode vs list/alignment mode
- **SnapGene**: Single sequence focus, multi-FASTA = pick one
- **JBrowse2**: FASTA = reference, comparison needs separate view type

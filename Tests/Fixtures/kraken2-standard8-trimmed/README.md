# kraken2-standard8-trimmed

A trimmed Kraken 2 report from a real Standard-8 run on a single human-derived
Illumina library (11,284,830 reads, 99.28% unclassified). It was written with
`--report-minimizer-data`, so it has the 8-column layout, and it exercises the
report features the taxonomy sunburst must handle:

- non-canonical rank codes (`R1`, `R2`, `K`, `K1`..`K3`, `D1`, `P1`..`P9`,
  `C1`..`C4`, `O1`..`O4`, `F1`, `G1`, `S1`, `S2`)
- a lineage 31 levels deep (root to Homo sapiens)
- a domain whose share of classified reads is under 0.1% (Archaea, 69 reads)
- direct reads on internal nodes (root has 833, Bacteria has thousands)

## How it was trimmed

`root`, `cellular organisms`, `Bacteria`, `Pseudomonadati`, `Pseudomonadota`,
`Gammaproteobacteria`, and `Viruses` are kept as a path. The subtrees under
`Moraxellales`, `Eukaryota`, `Archaea`, and `Floreoviria` are kept whole. Every
other subtree was removed and its clade reads were folded into the nearest kept
ancestor's direct count, so every kept node still satisfies
`clade == direct + sum(children clade)` and every kept node's clade count and
percentage are the original values. The unclassified line is unchanged.

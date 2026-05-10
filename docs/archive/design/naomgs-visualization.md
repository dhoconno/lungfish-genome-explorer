# NAO-MGS Visualization Design

## Overview

The NAO-MGS result viewer displays imported metagenomic surveillance results from the securebio/nao-mgs-workflow pipeline. Data comes from `virus_hits_final.tsv.gz` files containing per-read alignment data against viral references.

## Data Model

Each row in the TSV represents one read that aligned to a viral reference genome. Key fields:

| Field | Purpose |
|-------|---------|
| `aligner_taxid_lca` | LCA taxonomy ID (for taxonomy grouping) |
| `prim_align_genome_id_all` | GenBank accession (for reference grouping) |
| `prim_align_ref_start` | Alignment position on reference (0-based) |
| `query_seq` / `query_qual` | Read sequence and quality |
| `prim_align_query_rc` | Strand (True=reverse, False=forward) |
| `prim_align_edit_distance` | Mismatches from reference |
| `prim_align_fragment_length` | Insert size for paired-end |
| `prim_align_best_alignment_score` | Alignment quality |

## Tier 1 -- Essential for Veracity Assessment

1. **Taxonomy Summary Table** -- NSTableView sorted by hit count
   - Columns: Taxon ID, Organism Name, Hit Count, Accessions, Avg Edit Distance
   - Right-click BLAST verification (default 20 reads, max 50)
   - Coverage-stratified read selection for BLAST

2. **Coverage Plots Per Reference** -- Sparkline per accession
   - Real detections show >60% genome coverage across the reference
   - False positives show reads stacking at a single locus
   - Color: Lungfish Orange (#D47B3A)

3. **Edit Distance Distribution** -- Histogram
   - Real infections: consistently low (0-5 for 150bp Illumina)
   - Misclassification: bimodal or high-mean distribution

## Tier 2 -- Deeper Investigation

4. **Read Pileup Per Reference** -- AlignedRead display
   - Synthesize CIGAR from query_len when explicit CIGAR absent
   - Download reference via NCBI efetch using GenBank accession
   - FLAG bits from prim_align_query_rc (0x10 for reverse)

5. **Fragment Length Distribution** -- Histogram
   - Real PE alignments: tight distribution around library insert size (200-500bp)
   - Spurious alignments: scattered or extreme fragment sizes

## Tier 3 -- Multi-Sample Surveillance

6. **Taxa x Samples Heatmap** -- When multiple virus_hits files loaded
   - Rows: viral taxa (species level), Columns: samples
   - Color scale: white -> Lungfish Orange -> deep rust
   - Cluster by taxonomy and collection date

7. **Time Series** -- Line charts per taxon when dates parseable from sample names

8. **Relative Abundance** -- Toggle between absolute counts and relative abundance

## BLAST Verification

- Right-click taxon row -> "BLAST Verify (N reads)"
- Default N = min(20, hitCount), max = min(50, hitCount)
- Coverage-stratified read selection:
  1. Bin reads by genome quartile (0-25%, 25-50%, 50-75%, 75-100%)
  2. Pick lowest edit distance reads first per quartile
  3. Fill remaining with highest edit distance reads
- Reuse existing BlastService and BLAST drawer infrastructure

## Architecture Note

Group reads by **accession** (genome_id) for coverage/pileup views.
Group reads by **aligner_taxid_lca** for taxonomy table.
These are orthogonal views of the same data.

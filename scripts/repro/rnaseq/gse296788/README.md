# GSE296788 reproduction (Pisu 2026, Mucosal Immunology)

Pisu D, Sunny PS, Nelson ML, et al. *Mycobacterium tuberculosis preferentially infects specific macrophage subsets in primate granulomas during the early stages of tuberculosis.* Mucosal Immunology 19(3), article 100321, 2026. PMC13335628, GEO GSE296788, BioProject PRJNA1261050.

This folder reproduces the five 10x 3' mRNA libraries of flow-sorted mCherry+ cells (cells infected by mCherry Mtb Erdman) from public reads, with STARsolo set to Cell Ranger 6.0's behaviour, and scores the result against the deposited matrices. The panel kept only this subset (R2 tally, Q2).

| GEO | Library | Tissue | Animal | Runs | Spots (million) |
| --- | --- | --- | --- | --- | --- |
| GSM8976774 | I3 | granuloma | 2 | 8 | 154.0 |
| GSM8976780 | I4 | granuloma | 3 | 8 | 452.8 |
| GSM8976782 | 3I | non-diseased lung | 2 | 8 | 155.6 |
| GSM8976784 | 4I | non-diseased lung | 3 | 8 | 172.8 |
| GSM8976786 | I2 | granuloma | 1 | 16 | 353.3 |

Animal numbers follow the GEO titles ("Monkey 1" to "Monkey 3").

## What the paper did

- **Counting.** Methods, single-cell paragraph. The mRNA libraries went through Cell Ranger 6.0 on a custom reference of Macaca fascicularis 5.0 (GCF_000364345.1) plus the Mtb Erdman genome. The paper prints the Erdman accession as "GCA_00668235.1", a digit short. The ADT and hashtag libraries went through CITE-seq-Count 1.4.3.
- **QC.** Same paragraph. Cells with under 700 genes or over 5% ribosomal protein genes (RPS and RPL) were removed. Doublet removal and hashtag demultiplexing are not described anywhere in the paper or the supplementary methods.
- **Downstream.** Supplementary Methods. Seurat 4.3, SCTransform per sample, Harmony, jackstraw PCs, Louvain clusters, Monocle 3, scWGCNA, MiloR and GSEA.
- **Infected cell.** Results, Fig. 8 paragraph. An infected cell is a cell from the mCherry+ flow sort, not a cell with Mtb reads. The paper keeps 511 mCherry+ cells after QC across the three animals (SupFig. 9A). TR-AMs are 155 of 380 infected granuloma cells and 50 of 131 infected non-diseased cells (Fig. 8A).
- **Differential expression.** Supplementary Methods, statistics paragraph, and Results, Fig. 8 paragraph. DE used Seurat's Wilcoxon rank-sum test on single cells with FDR under 0.05. Infected against uninfected TR-AMs was tested this way. With three animals the test treats cells as replicates. Pseudobulk by animal would sit at LGE's three-animal floor.

## The deposit, as read here

- Every mRNA deposit holds a round number of barcodes, 500, 1,000 or 2,000 for the sorted libraries and 10,000 to 16,000 for the main ones. These are forced counts (Cell Ranger `--force-cells`), not Cell Ranger's own call. So the cell count cannot be checked. The barcode overlap with our top N barcodes by UMI count can.
- The features list (28,847) equals, in order, the gene ids of the exon lines of the RefSeq Annotation Release 101 GTF, then `tb001 MTB` and `tb002 MTB2`, with two changes (below). `ref.py check` proves the match.
- All 142,713 deposited barcodes are in 10x's 3M-february-2018 list, so the chemistry is 3' v3 or v3.1 (28 nt barcode read, G chip).

## What the scripts do

| Script | Step |
| --- | --- |
| `stage_mtb.sh` | Fetches GCA_000668235.1 (Myco_tube_Erdman_V1) from NCBI, checks NCBI's md5, writes sha256 ledger rows |
| `ref.py` | Builds the combined GTF, checks it against the deposited features, lists the mitochondrial genes by contig |
| `run.sh` | Reference, STAR index, STARsolo per library, BAM slice, top-N cells, then the comparison |
| `heavy.sh` | Waits for the shared heavy lock, the PAUSE file, free memory and the load gate, then runs one heavy step |
| `chain.sh` | Runs `run.sh` unattended from a snapshot of the scripts and retries refused heavy steps |
| `compare.py` | Cell overlap, per-cell and per-gene agreement, medians, Mtb UMIs, mitochondrial share and QC counts |
| `mtb.py` | Mtb UMIs per cell by strand, from the kept BAM slice |
| `claims.py` | Writes `claims.tsv` from the comparison |

Run from the repository root:

```bash
bash scripts/repro/rnaseq/gse296788/stage_mtb.sh <data_root>
LOCKS=<data_root>/locks nohup bash scripts/repro/rnaseq/gse296788/chain.sh <data_root> <work_dir> <env> > <work_dir>/logs/chain.log 2>&1 &
```

STARsolo settings follow STARsolo's own "match Cell Ranger 4 and later" options, as REPRO-10X proved on 10x's data. These are `--soloCBwhitelist 3M-february-2018`, `--soloUMIlen 12`, `--soloStrand Forward`, `--clipAdapterType CellRanger4`, `--outFilterScoreMin 30`, `--soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts`, `--soloUMIfiltering MultiGeneUMI_CR` and `--soloUMIdedup 1MM_CR`. The count is the exon-only preset (`Gene`), since Cell Ranger 6.0 does not count introns by default. `GeneFull_Ex50pAS` is written beside it for reference. Cells are called twice. First as the top N barcodes by UMI count (N from the deposit, as `--force-cells` does), then with EmptyDrops_CR at Cell Ranger's default 3,000 expected cells.

## Deviations and assumed steps

1. **Mitochondrial genes.** The NCBI GTF gives the 13 mitochondrial protein-coding genes only as gene and CDS lines, and Cell Ranger counts exons. The deposit counts all 13, so the authors' GTF had exons for them. We count each over its gene span. This is an assumed step (or a later NCBI GTF than the authors had), recorded for adjudication.
2. **Mitochondrial tRNA and rRNA.** Their 24 exons carry an empty `gene_id` in the NCBI GTF and are absent from the deposit, so they are dropped.
3. **Mtb features.** Each Mtb scaffold is one gene over its whole length, on the plus strand, named as in the deposit. The strand of the authors' features is not stated. Cell Ranger counts sense reads only, so a plus-strand whole-scaffold feature counts about half of Mtb's reads. `mtb.py` counts both strands and checks which rule equals the deposit.
4. **STAR index.** `--genomeSAsparseD 2` under the shared machine's memory rule. This changes speed and memory, not alignments. `--sjdbOverhang 100` as Cell Ranger's `mkref` uses.
5. **STAR version.** STARsolo 2.7.11b stands in for the STAR 2.7.2a inside Cell Ranger 6.0. This is version drift, scored by the close class.

## Mtb reads are mostly rRNA

Mtb mRNA has no poly(A) tail, so 10x 3' capture takes little of it. In the small test (200,000 reads a library against chromosome 19, the mitochondrion and Mtb), every unique Mtb alignment fell in the Erdman 16S and 23S rRNA genes on the plus strand, and most had 2 to 9 mismatches over 52 bases. A read from Erdman itself should have 0 or 1. Host rRNA has no annotated gene in the cynomolgus assembly, and its conserved stretches can land on Mtb's rRNA. So `mtb.py` splits each cell's Mtb UMIs into near-exact (0 or 1 mismatches) and the rest, and into rRNA and other loci. The full run settles how much of the deposit's `MTB` count is Mtb.

## Mitochondrial genes

The route finds mitochondrial genes by contig. The assembly report names NC_012670.1 as the mitochondrion, and 13 genes lie on it (ND1, ND2, COX1, COX2, ATP8, ATP6, COX3, ND3, ND4L, ND4, ND5, ND6, CYTB). A test for the `MT-` prefix finds none of them.

## Outputs

Derived files go to the work folder. `compare/summary.tsv` and `compare/<GSM>.json` hold every figure. `compare/<GSM>.mtb_per_cell.tsv` and `compare/<GSM>.mtb_strand.tsv` hold per-cell Mtb counts, and `compare/mtb_background.tsv` holds the same figures for the 10 main deposited matrices (6 GEO samples of unsorted cells). `solo/<GSM>/nonhost_and_mt.bam` is the BAM slice of both Mtb scaffolds and the mitochondrion, kept for good. A full BAM is deleted once its library's counts pass. `claims.tsv` here is the scored claim list.

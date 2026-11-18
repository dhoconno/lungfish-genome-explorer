# RNA-seq results

An RNA-seq result of Lungfish Genome Explorer (LGE) is one folder, `<name>.lungfishrnaseq`, that holds the bulk or single-cell counts of one route on one reference set. This page gives its layout, its manifest, the one component that writes it and what a reader does with it. It is written for developers and for the Phase 5 lanes RS-KIND, RS-BULK-IMPORT, RS-QUANT, RS-HANDOFF and RS-UI-KIND. Phase 5.1 sets the layout. `RNASeqResultManifest` and `RNASeqResultBundle` in `Sources/LungfishIO/Bundles/` read it, and `RNASeqResultWriter` in `Sources/LungfishWorkflow/RNASeq/` writes it. The reference set it names is in [reference-set.md](reference-set.md), and the test fixtures are in `Tests/Fixtures/rnaseq/` (`Tests/Fixtures/rnaseq/README.md:1-12`).

## A bundle kind kept under Analyses

The result is a bundle kind with a bulk or single-cell modality, as the program plan sets (`docs/plans/2026-10-02-architecture-program.md:115`), and not a plain `Analyses/` folder.

- A kind shown as one row has its own viewport, and the sidebar never lists the files inside it (`docs/formats/bundle-kinds.md:84`). Exit X1 asks for a project holding a CLI-written RNA-seq folder with none of its files offered for edit (`docs/plans/2026-10-02-architecture-program.md:200`). An `Analyses/` folder that no rule recognizes is a grouping folder whose entries the sidebar lists (`docs/formats/analyses-layout.md:102`).
- Import comes first, from salmon, nf-core/rnaseq, DRAGEN, Cell Ranger and STARsolo files (`docs/plans/2026-10-02-architecture-program.md:101,103`). An import is no run of an analysis kind, and `analysis-metadata.json` holds only the kind, the batch flag and the date (`docs/formats/analyses-layout.md:32`), so it cannot carry a modality, a route, a reference set or checksums.
- The deletion planner and the copier treat a kind's folder as one object (`docs/formats/bundle-kinds.md:86-88`).

The folder lives in the project's `Analyses/` folder, as the genotype and 12S results do (`Sources/LungfishIO/Bundles/BundleKindRegistry.swift:109,117`), where a folder whose extension the sidebar classifies as a bundle shows as that bundle (`docs/formats/analyses-layout.md:100`). The one sample sanitizer names it (`docs/contracts/EXPERT-PANEL.md:50`). The extension alone recognizes it, and the manifest is `rnaseq-result.json`. Its row is in [bundle-kinds.md](bundle-kinds.md) and in `BundleKindRegistry` under the id `rnaseq-result`, and the kind is in the view-switch test (`Tests/LungfishAppTests/SafetyNets/ViewSwitchKinds.swift`), as `docs/contracts/SCOPE-AND-DELIVERY.md:93` asks. The registry lists 16 kinds (`docs/formats/bundle-kinds.md:3`).

## Layout

```
<name>.lungfishrnaseq/
  rnaseq-result.json
  .lungfish-provenance.json
  provenance/
  samples.tsv
  genes.tsv
  counts/
    genes.counts.tsv
    genes.masked.tsv
    transcripts.counts.tsv
  quality/
    samples.quality.tsv
  source/
    <sample id>/
    tables/
  cells.sqlite
```

| File | Holds | Modality |
| --- | --- | --- |
| `rnaseq-result.json` | The manifest below | Both |
| `.lungfish-provenance.json`, `provenance/` | The root record and the record folder of the standard rule (`docs/formats/bundle-kinds.md:103`, `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift:11-12`). The record holds the run facts, such as `Poly-G trimming: off (LGE default)` and `Duplicates: kept. LGE removes duplicates only with UMIs.` (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:100,103`), the bias flags with the version and the four index hashes (`docs/plans/2026-10-02-architecture-program.md:194-195`), and for each Trim Galore call the adapter's name and sequence, the read 2 adapter, the length cutoff and the console line that says how Trim Galore chose the adapter. A result whose samples got different adapters says so in one sentence under `adapters` (`Sources/LungfishWorkflow/RNASeq/TrimGaloreAdapterReport.swift`) | Both |
| `samples.tsv` | One row a sample, with the sample id, the animal, species and origin (`docs/plans/2026-10-02-architecture-program.md:111,134`), the group, the run accessions and its folder under `source/` | Both |
| `genes.tsv` | The reference set's gene table for the result's rows, with the gene id, name, biotype, contig, length, the not-host flag (`true` or `false`, empty for Not recorded), the mask and the unreliable mark of the MHC, KIR, immunoglobulin and T cell receptor loci (`docs/plans/2026-10-02-architecture-program.md:111,113`). When the result keeps every gene of its set, the file equals the set's `derived/genes.tsv` by sha256, so a result reads without the set. A result that keeps fewer genes holds only those rows, and the manifest's `genes` entry holds the file's own sha256. A result whose `referenceSet` is null holds the feature ids of its count tables and leaves every other column empty, which a reader shows as Not recorded | Both |
| `counts/genes.counts.tsv` | Genes by samples in the route's unit, loaded whole (`docs/plans/2026-10-02-architecture-program.md:115`) | Bulk |
| `counts/genes.masked.tsv` | The second column of the features a mask moves out of the default count, written only when a mask applies (`docs/plans/2026-10-02-architecture-program.md:113`). A set's rRNA mask holds intervals and moves UMIs and no feature, so a single-cell result keeps its masked column in `cells.sqlite` and writes no such table | Both |
| `counts/transcripts.counts.tsv` | Transcript rows, kept and exported (`docs/plans/2026-10-02-architecture-program.md:109`) | Bulk |
| `quality/samples.quality.tsv` | The quality numbers of the tools' own files (`docs/plans/2026-10-02-architecture-program.md:105`), such as salmon's `num_processed`, `percent_mapped` and library type (`Tests/Fixtures/rnaseq/salmon-c1/SRR896663/aux_info/meta_info.json:41,46`, `Tests/Fixtures/rnaseq/salmon-c1/SRR896663/lib_format_counts.json:6`) | Both |
| `source/<sample id>/` | The tool's own files as given, byte for byte, each with its sha256 in the manifest | Both |
| `cells.sqlite` | The per-cell summary of one streaming pass, which the tables page from (`docs/plans/2026-10-02-architecture-program.md:115`) | Single cell |

### The tool's own files

`source/<sample id>/` keeps each file the reader reads in the folder layout the tool wrote. For salmon these are `quant.sf`, `cmd_info.json`, `lib_format_counts.json` and `aux_info/meta_info.json` (`Tests/Fixtures/rnaseq/salmon-c1/`). For Cell Ranger they are `outs/filtered_feature_bc_matrix/` with `metrics_summary.csv` (`Tests/Fixtures/rnaseq/cellranger-pbmc_1k_v3/`), and for STARsolo `Solo.out/Gene/filtered/` with `Summary.csv` and `Log.final.out` (`Tests/Fixtures/rnaseq/starsolo-pbmc_1k_v3/`). A result adopted from a STAR GeneCounts plan keeps `star/ReadsPerGene.out.tab`, all three columns, and one adopted from a featureCounts plan keeps `featurecounts/counts.txt` and `featurecounts/counts.txt.summary`, each at the path its step returned it (`Tests/Fixtures/rnaseq/star-adopt/`). A result adopted from a plan of LGE's default route, STAR then salmon `-a`, keeps salmon's four files as the import of a salmon folder does (`Tests/Fixtures/rnaseq/star-salmon-adopt/`), and one adopted from a plan of the UMI branch keeps `umi/counts.tsv` at the path its step returned it (`Tests/Fixtures/rnaseq/umi-adopt/`). The record names the run's other returned files as left out, such as STAR's `Log.final.out`, the trim reports, `ReadsPerGene.out.tab` for featureCounts and the default route, and for the UMI branch each check's file, each extraction log and featureCounts' summary. The writer copies each file once, hashes it as it reads it (`docs/contracts/EXPERT-PANEL.md:44`) and lists it in the manifest with its sha256 and size. No later step changes a byte under `source/`. A file the reader does not read, such as an HDF5 matrix, `molecule_info.h5` or a web summary, stays out of the bundle, and the record names each one left out, so no fact is lost without a word (`docs/contracts/EXPERT-PANEL.md:57`). A file that holds several samples, such as a plain count table, one of nf-core/rnaseq's merged tables or a DRAGEN table, is kept as given in `source/tables/<file name>`, and its `sourceFiles` entry leaves `sample` empty. No sample folder is named `tables`. The writer gives such a sample the next free suffix, `tables-2`, as `batchSampleDirectory(named:in:)` does (`docs/formats/analyses-layout.md:28`). An import of nf-core/rnaseq's salmon folders also keeps each folder's `quant.genes.sf` as given, which no reader reads, since its gene sums come from nf-core's own table and not from the person's `--tx2gene` (`Sources/LungfishWorkflow/RNASeq/SalmonQuantFolderReader.swift`).

### Single cell

A single-cell matrix stays in `source/` as given, with its gzip or without it, and is never loaded, rewritten or converted (`docs/plans/2026-10-02-architecture-program.md:115`). LGE reads Matrix Market text and links no HDF5 library (same line). One streaming pass reads each matrix once, from the copy the writer has just hashed under `source/`, and writes `cells.sqlite`. A barcode list of 10x never enters the bundle, so an import never copies Cell Ranger's `raw_feature_bc_matrix/` or STARsolo's `raw/`, whose barcodes are the whole list. A list the person supplied enters no LGE folder or bundle either. The person places it, and only its name and sha256 enter the record (`docs/plans/2026-10-02-architecture-program.md:103`, BIO-NOTHOST-BARCODE item 15). The not-host pass below reads the raw matrix by path and names it by sha256. Cell Ranger states its version on line 2 of its matrix, `%metadata_json: {"format_version": 2, "software_version": "3.0.0"}` (version 5.0 writes `cellranger-5.0.0`, and the prefix is dropped), and the import records it as the tool's version in `origin` and `route` when every folder states the same one. Otherwise, and for STARsolo, whose folder states none, the version reads Not recorded.

The pass reads only the header `%%MatrixMarket matrix coordinate integer general`. Before the writer starts, the folder reader refuses in words any other header (`real`, `pattern`, `complex`, `array`, `symmetric`) and a size line whose rows or columns differ from the features or barcodes. While the pass reads the copy in the stage, it refuses in words any value that is not an unsigned decimal integer, such as `1.5` or `-1`, since a rounded count would be a false one, an entry count unlike the size line's, a row or column out of range and a gzip stream that ends early. A refusal in the pass removes the stage, so nothing is published.

Only features of type `Gene Expression` enter a cell's totals, and the record counts the features of each other type. A feature with no type column, as in an older `genes.tsv`, is `Gene Expression`. For a reference of two or more genomes the person names each genome by the id prefix Cell Ranger gives its genes, such as `hg19` for `hg19_ENSG00000223972`, and the record says the genomes were named so. The pass has no mitochondrial column, because those genes are found by contig and never by a name prefix (`docs/plans/2026-10-02-architecture-program.md:111`).

`cells.sqlite` holds these tables in schema 2. A schema 1 file holds the first six, and the reader reads its not-host tables as empty.

| Table | One row a | Columns |
| --- | --- | --- |
| `meta` | fact | `key`, `value`. `schema_version` is `2`, and `sha256:<path>` holds the sha256 of each matrix, features and barcodes file the pass read, by its path in the result |
| `samples` | sample | `sample` (from 1), `name` as in `samples.tsv`, `matrix` (its path in the result), `cells`, `features`, `entries` |
| `cells` | barcode | `cell` (from 1 over all samples), `sample`, `column` (the barcode's column in its matrix, from 1), `barcode` as given (STARsolo's bare, 10x's with `-1`), `umis` and `genes` (the `Gene Expression` features with a count). One sample holds a barcode once |
| `features` | feature | `feature` (its row in the matrix, from 1), `id`, `name`, `type`, `genome` (null unless genomes are named), `total` (its UMIs in every cell) and `cells` (the cells with a count) |
| `genomes` | named genome | `genome` (from 1) and `name`, the prefix the person gave |
| `cell_genomes` | cell and genome | `cell`, `genome`, `umis` and `genes` of that genome's features. Written only when genomes are named |
| `not_host_extras` | not-host extra of the set | `extra` (from 1), `name`, `kind` (`virus`, `bacterium` or `spike-in`), `mask` (its name, file, sha256 and gene count, or null) and `mask_words`, the words of the masked column (`on <organism> rRNA genes, source not resolved`, the organism being the extra's name in the set), or `rRNA not masked: no annotation given for <extra>` for a bacterium with no mask |
| `not_host_records` | not-host sequence record | `record` (from 1, the records of each extra in turn), `extra`, `name` and `length` in bases |
| `ambient_pools` | sample | `sample`, `barcodes_with_umi`, `pool_barcodes`, `first_rank` and `last_rank`, `umi_min` and `umi_max` (the pool's UMI range), `umis`, and `words`, empty or `not computed: N barcodes, too few for an ambient pool`, when the ranks and range are null |
| `ambient_pool_counts` | sample, extra and record | `umis` and `masked_umis` of the pool's barcodes, and `rate` on the extra's own row |
| `not_host_barcodes` | sample and barcode | every cell and every other barcode of the raw list with a not-host UMI, with `cell` (null outside the cells), `raw_umis` and `in_pool` |
| `not_host_counts` | barcode, extra and record | `umis` and `masked_umis`, the default and masked columns, and `umis_nm01` and `masked_umis_nm01`, those with an alignment at nM 0 or 1. Written only where a count is above 0 |
| `not_host_calls` | cell and virus or bacterium extra | `p`, `q` and `flag`, the flag's words, empty when the cell is not flagged, or the words that say why no flag was computed, when `p` and `q` are null |

In `ambient_pool_counts` and `not_host_counts` a `record` of 0 is the extra's own figure over its records. Every sample of a result lists the same features in the same order, or the import is refused, so `features` sums over every sample.

### Not-host RNA

`lungfish-cli import rnaseq` counts not-host RNA in each cell and in the ambient pool when the person names `--reference-set <set folder>` and `--not-host-bam <sample>=<path>` for each sample (gate GN, `docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:94`). The pass runs at import, so the result and its `cells.sqlite` are written once (BIO-NOTHOST-BARCODE item 8). The result's genes come from the set's `derived/genes.tsv`, an id the set lacks is refused in words, and `notHost` lists the set's not-host features. Each BAM is coordinate-sorted and indexed, and a BAM whose header lacks a not-host record of the set, or holds it at another length, is refused in words. The BAM and the raw matrix (`Solo.out/Gene/raw/` or `outs/raw_feature_bc_matrix/`) are read by path and never copied, so a moved result opens its not-host tables without them.

- One `samtools view` a sample over the set's not-host records gives the alignments. A UMI is a unique (CB, UB) pair among primary alignments at NH 1 that carry both tags, kept per record, and an extra's figure is its unique pairs over its records, so a pair on two records counts once (ADJ-SC-3 item 3).
- A pair is in the default column when any of its alignments lies outside the extra's rRNA mask, and in the masked column otherwise. An alignment lies in the mask when its reference span overlaps a mask gene by 1 base or more (BIO-NOTHOST-BARCODE item 7).
- The ambient pool is ranks 45,000 to 90,000 by UMI in the raw matrix among barcodes with a UMI, every feature summed, ties in barcode-byte order. With fewer than 90,000 such barcodes it runs to the last, and with fewer than 45,000 there is none and the counts still show (ADJ-SC-3 item 1). A barcode with a not-host UMI and no UMI in the raw matrix keeps its row with `raw_umis` 0, as `virus.py` keeps it (`mtb.py` drops it in `raw_totals`). STARsolo's matrix leaves out reads that fall in no feature, so a barcode's not-host UMIs can exceed its raw UMIs, and a share of them needs its denominator named.
- The rate is (pool not-host UMIs + 1) / pool UMIs (ADJ-SC-3 item 2). A cell's p is the Poisson upper tail of its default not-host UMIs at its raw UMIs times the rate, Benjamini-Hochberg runs over the library's cells, and a cell with 2 or more UMIs and q under 0.001 reads `viral RNA above ambient` for a virus and `bacterial RNA above ambient` for a bacterium.
- A spike-in gets counts and no flag. A bacterium with no rRNA mask reads `not computed: no rRNA mask for <extra>`, since a bacterium counted without its mask gives false flags (BIO-NOTHOST-BARCODE item 6).

The record names the set id, each mask's name and sha256, each BAM's path, sha256 and size, each raw matrix's path and sha256, and the samtools version that ran.

## The manifest

`rnaseq-result.json` is JSON with camel-case keys, as the 12S result's `schemaVersion` is (`Sources/LungfishIO/Bundles/TwelveSAmpliconResultModels.swift:5-7`). Schema 1 holds these keys.

| Key | Holds |
| --- | --- |
| `schemaVersion` | 1 |
| `kind` | `rnaseq-result` |
| `modality` | `bulk` or `single-cell` |
| `name`, `createdAt` | The display name and an ISO 8601 date |
| `origin` | `imported` with the tool and version that made the files, `quantified` when LGE ran the route, or `pseudobulk` with the tool and version of the single-cell result whose cells LGE summed (Pseudobulk below) |
| `route` | One route, with its id, the counting tool, its version and every setting that changes counts, such as salmon with selective alignment on reads, STAR GeneCounts and its column, or featureCounts with its `-M`, `-O`, `-s` and `--fraction` settings (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:102`). `lungfish-cli rnaseq quant` writes the id `salmon-selective-alignment-reads` with the settings `mapping`, `libraryType` (`A`), `detectedLibraryType`, `k`, `decoys`, `index` and the index's hashes (`indexSeqHash`, `indexNameHash`, `indexDecoySeqHash`, `indexDecoyNameHash`), `seqBias`, `gcBias` and `posBias` (`off` as LGE runs salmon), `trimming` (`Reads not trimmed` or the poly-G line), `adapter` when Trim Galore runs (`Adapter: chosen by Trim Galore <version> from read 1 (auto-detection)`), `duplicates`, `counts` (`NumReads`) and `geneSums` (`Sources/LungfishWorkflow/RNASeq/SalmonQuantRoute+Record.swift`). `duplicates` takes one of four forms ([executor-plan.md](executor-plan.md), the `duplicates` paragraph), kept, Not recorded or removed at import for every sample when the samples share a state, and the form that counts the samples of each state only for a result whose samples differ. `lungfish-cli import rnaseq <folder> --adopt` writes `origin` `quantified` with the tool and version of the plan's `route`, and the plan's `route` with the run's `detectedLibraryType`, `seqBias`, `gcBias`, `posBias` and index hashes read from salmon's files under the same keys, and `duplicates` in the result's form. For a plan of a STAR chain it writes `origin` `quantified` with `STAR` or `featureCounts` and the version of the plan's `route`, and the plan's `route` with `duplicates` in the result's form. A STAR GeneCounts result holds column 2 of `ReadsPerGene.out.tab`, the unstranded count, and its `route` adds `geneCountsColumn`, which names that column and says that columns 3 and 4 are not counts of the result. A featureCounts result holds the count column of its table. Either holds one gene table in `pairs` or `reads` and no transcript table. For a plan of LGE's default route, STAR then salmon `-a` on STAR's transcriptome alignments, it writes the salmon result above, with `origin` `quantified`, `salmon` and the plan's version, and the plan's `route`, whose `alignmentScoring` the adopt checks against the salmon step's recorded argv and never against `cmd_info.json`, which names no flag. For a plan of the UMI branch it writes `origin` `quantified` with `umi_tools` and the plan's version, the plan's `route` with `duplicates` in the result's UMI form, and one gene table of umi_tools' count of UMIs per gene in `umis` and no transcript table. umi_tools lists only the genes it counted a UMI on, so a gene of the set that its table does not list reads 0. The record's counting step adds `umiCheck`, the words of each UMI layout check with its verdict and shares, and `umiExtraction`, the share of read pairs that `umi_tools extract` kept. For a STARsolo plan of `lungfish-cli rnaseq solo-plan` it writes a single-cell result with `origin` `quantified`, `STAR` and the plan's version, and the plan's `route` as written, whose `countingGTF` names the 10x filter rule, its list, the made file's sha256 and size, the sha256 of `derived/genes.gtf`, the set and the genes left out. It keeps the filtered matrix of `Solo.out/Gene` as an import of a STARsolo folder does, and the record's counting step adds the barcode list's source and the line on multi-mappers. A plan of the introns preset, whose matrix is `Solo.out/GeneFull_Ex50pAS`, is refused |
| `referenceSet` | The set's `id` and `layout`, `lge` or `deposit` ([reference-set.md](reference-set.md)), or `null` when the imported files state none, which a reader shows as Not recorded (`docs/plans/2026-10-02-architecture-program.md:189`) |
| `samples`, `genes` | The path and sha256 of `samples.tsv` and `genes.tsv` |
| `counts` | One entry a count table, with its path, sha256, rows (`gene` or `transcript`), unit (`reads`, `pairs`, `umis` or `estimated`) and column (`default` or `masked`) |
| `sourceFiles` | One entry a kept file, with its path, sha256, size, sample and tool |
| `matrices` | Single cell. One entry a sample, with `sample`, then `matrix`, `features` and `barcodes`, each a `path` under `source/` and its `sha256`, then `format` (`matrix-market`), `isGzip` (whether the matrix file is gzip), and `cellCount`, `featureCount` and `entryCount` from its size line, which the pass checks |
| `cellsSummary` | Single cell. The `path` (`cells.sqlite`), `sha256` and `schemaVersion` of `cells.sqlite`, which the writer fills from the file it wrote |
| `quality` | The path and sha256 of `quality/samples.quality.tsv`, which the writer writes when the caller gives the table. The header is `sample_id` and then the columns the caller names, with one row a sample and an empty cell for a number the tool did not give. The writer refuses a row whose sample is not in `samples.tsv`. A result with no `quality` key reads quality as Not recorded |
| `notHost` | The ids of the not-host features, each one feature a genome or segment, which stay out of size factors (`docs/plans/2026-10-02-architecture-program.md:113`) |

The run facts stay in the record and the manifest repeats none of them.

## One table, one route

A result holds the counts of one route on one reference set. A second route, or the same route on a second set, makes a second result. Counts from two routes or two reference sets never join in one table (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:102`, `docs/plans/2026-10-02-architecture-program.md:113`), so the export refuses in words a table whose columns come from more than one route or set (`docs/plans/2026-10-02-architecture-program.md:190`). A not-host feature keeps its count in `counts/genes.counts.tsv`, its flag in `genes.tsv` and its id in `notHost`, and the export leaves it out of size factors (`docs/plans/2026-10-02-architecture-program.md:113`).

## Pseudobulk

`lungfish-cli rnaseq pseudobulk <result> --labels <table> --output <new result>` sums the raw UMI counts of a single-cell result by sample and by a label table that the analyst exports from Seurat or Scanpy. It writes a bulk result that the export reads, since five benchmarks find that tests on single cells give false discoveries (`docs/plans/2026-10-02-architecture-program.md:107`). `RNASeqPseudobulk` in `Sources/LungfishWorkflow/RNASeq/` reads and sums, and `Sources/LungfishCLI/Commands/RNASeqPseudobulkSubcommand.swift` is the leaf. The leaf writes through the one writer, so a refusal, an error or a cancel leaves no folder.

### The label table

The table is tab-separated with a header, plain or gzip. It holds a `barcode` and a `label` column, and a `sample` column when the result holds two or more samples. Other columns are read past. A barcode matches `cells.barcode` as given, so a STARsolo barcode is bare and a 10x barcode ends in `-1`. A `sample` matches a `sample_id` of `samples.tsv`. A cell that the table does not list has no label.

### Groups and the sum

A group is one sample and one label. After `RNASeqResultBundle.verifyChecksums`, the pass reads each matrix under `source/` once and adds every entry of a labelled cell to its group, in whole numbers and never rounded. The rows are the `Gene Expression` features only, as a cell's totals are, and the record counts the features of each other type. A group of fewer than 10 cells is left out, and standard output and the record say `Group <sample> <label> holds <n> cells, under 10, and is left out.` Cells with no label are left out too, and the same two places give their count in each sample.

### The result

Each group kept is one column of `counts/genes.counts.tsv`, with rows `gene`, unit `umis` and column `default`. The column id is `<sample>_<label>`. The columns follow the order of the samples, and within a sample the code-point order of the labels. Each column's row of `samples.tsv` carries the sample's `animal`, `species`, `origin` and `runs`, with the label as `group`, so the export can count the animals of a group. `genes.tsv` holds the rows of the single-cell result's `genes.tsv` for the `Gene Expression` features. The result keeps the single-cell result's `route` and `referenceSet` and adds the route setting `pseudobulk`, so its counts never join a bulk route in one table. Its `origin` is `pseudobulk`, with the single-cell result's tool and version, and it keeps no file under `source/`.

The record names the single-cell result with the sha256 of its manifest and the label table with its sha256. It lists the groups kept and the groups left out, each with its cells and UMIs, the cells with no label in each sample with their UMIs, and the features of each other type. The UMIs of the groups kept, the groups left out and the cells with no label add up to the `Gene Expression` UMIs of the single-cell result.

### What it refuses

Each refusal comes before anything is written, in words that name the file and what to do.

- A bulk result, and a single-cell result whose files differ from the sha256 values of its manifest.
- A label table with no `barcode` or `label` column, a table with no `sample` column for a result of two or more samples, and a line whose cells differ in number from the header's.
- Barcodes that the sample does not hold, with their count and the first 10, a barcode listed twice for one sample, an empty label and a `sample` that the result does not hold.
- Two groups that would get one column id, such as sample `A_1` with label `T` and sample `A` with label `1_T`, and a table that leaves no group of 10 or more cells.
- An output that exists, and an output whose name does not end in `.lungfishrnaseq`.

## The export

`lungfish-cli rnaseq export <result>... --output <new folder>` writes the counts of one or more bulk results into a new folder that DESeq2, edgeR, limma voom and dream read. A single-cell result is exported by itself, as its matrices in a new folder that Seurat and Scanpy read (see A single-cell result below). `RNASeqExport.run` in `Sources/LungfishWorkflow/RNASeq/` does the work and `Sources/LungfishCLI/Commands/RNASeqExportSubcommand.swift` is the leaf, so a later viewer runs the same code. The folder must not exist. The export writes it into a stage and renames it into place through `ScientificFileExportProvenance`, so a refusal, an error or a cancel leaves neither a folder nor a stage. Every refusal comes before the first file is written.

### What the export reads and refuses

The export reads each result with `RNASeqResultBundle` after `RNASeqResultBundle.verifyChecksums`, so a replaced `quant.sf` or table is refused in words that name the file. It reads the route and the reference set from each result at every export and caches neither, so a copied or moved project exports the same files and refuses the same joins.

A route is the tool, its version and every setting that changes counts (the `route` key above). The same tool at two versions is two routes, and paired and single-end samples counted by one route are one route. The export refuses each of these in words that name the results and their sample counts.

- Results of more than one route.
- Results counted against more than one reference set, by id or by layout.
- A join where a reference set reads Not recorded, or where a tool reads Not recorded, since LGE cannot show that the results match. One such result alone exports.
- Results that list different genes, mark different features as not host, count in different units or hold one sample id twice.

No flag overrides a refusal, and the export never joins by a union with zeros or by an intersection. To compare samples of two routes, count all of them again by one route.

### The folder

| File | Holds |
| --- | --- |
| `counts.tsv` | Genes by samples in the default column, with the gene id in the first column and the samples in the order the results are given |
| `counts.masked.tsv` | The masked column, written beside `counts.tsv` when every result holds one and never joined to it. A join where only some results hold one is refused |
| `genes.tsv` | The gene table of the results with its `not_host` flag |
| `samples.tsv` | One row a sample, with the columns below |
| `deseq2.R`, `edger-limma-dream.R` | The two scripts, described below. A pseudobulk export adds the animals rule to each |
| `.lungfish-provenance.json` | The record |

`samples.tsv` holds `sample_id`, `animal`, `species`, `origin`, `group` and `runs` from the results, then the other columns of the optional `--sample-sheet`, and last `route` and `reference_set`, which the export reads from each result. The sheet is tab-separated and names its samples in a `sample` or `sample_id` column. A value in the sheet replaces the result's value for `animal`, `species`, `origin`, `group` and `runs` when it is not empty. The sample ids of the sheet and of the results must be the same set, and the export refuses a sheet that differs and lists the ids that do. A sheet column named `route` or `reference_set` decides nothing, so a sheet reopened later cannot hide a mix.

### Design, cutoff and alpha

`--design COLUMN` names a column of `samples.tsv` that enters the model. Repeat it, and the last one is the tested factor. `--contrast FACTOR:NUMERATOR:DENOMINATOR` names a contrast and repeats. `--padj-cutoff` is the adjusted p-value cutoff and is 0.05 unless the person picks another. `deseq2.R` passes the same number as `alpha` to `results()`, so the independent filtering of DESeq2 aims at the cutoff the person reads. `--lfc-bar` is a bar on the absolute log2 fold change and is none by default. The bar applies to the unshrunken (MLE) log2 fold change, with padj beside it. A shrunken value goes into its own column and never decides which genes pass.

`--batch COLUMN` and `--batch-correction none|combat-seq|sva` name an optional batch step, and none is the default. `combat-seq` corrects the counts with `ComBat_seq` and passes the tested factor as the group. `sva` runs `svaseq` with the design as the full model and the batch as the null model and puts the batch and the surrogate variables into the model. Its count of surrogate variables has a fixed seed, and when it finds none the script says so and the model holds the batch and the design only. A batch without a batch step, and a batch step without `--batch` or `--design`, are refused in words.

The design check runs in Swift before any file is written, and again in each script before its batch step, so a sheet edited after the export is refused in R as well. It refuses `combat-seq` and `sva` when a batch is nested in or equal to a level of a design factor, or holds only whole levels of it, since the batch then cannot be told apart from those levels. The words name the batch, the factor and its levels, and say that `~ batch + design` loses full rank only when it does. A batch that crosses the levels of the factor passes. Batch B of the GSE290671 study holds exactly days 3 and 10 (`scripts/repro/rnaseq/gse290671/de.R:10-12`), so both steps are refused with `~ day`.

### Animals in a pseudobulk comparison

A pseudobulk result sums the cells of each sample and label into one column. A test on single cells gives false discoveries, so a pseudobulk comparison counts animals and not cells. When any result of the export came from `rnaseq pseudobulk` and `--design` is given, the export reads the `animal` column of `samples.tsv` (a `--sample-sheet` can give it) and counts the two levels each `--contrast` compares, on that contrast's own factor. The levels are counted in the order of the contrasts, the two of one contrast in code-point order, and each once. A level that no contrast names is not counted, since DESeq2's contrast of two levels does not move with a third level. With no `--contrast` every level of the last `--design` is counted. The export refuses a column with no animal. It refuses a compared level that holds columns of fewer than 3 animals (`RNASeqExportDesignCheck.minimumAnimals`), and a named level that no column holds counts 0 animals. The words name the level, its factor, its animals and the way on, which is to add animals or to compare levels that already hold 3. With no `--design` nothing is tested and nothing is refused. A bulk result is not held to this count.

Both scripts of a pseudobulk export carry the same rule, so a `samples.tsv` edited down after the export is refused in R as well. Their settings block holds `min_animals <- 3` and each script calls `check_animals` with the contrasts of the settings block right after it reads the table, before the fit. A script of a bulk export holds neither.

### The scripts and the record

`deseq2.R` needs DESeq2, and sva for a batch step. `edger-limma-dream.R` needs edgeR and limma, sva for a batch step and `variancePartition` for the dream part. The dream part runs only when `variancePartition` is installed. Otherwise the script stops in words after edgeR and limma have written their results. Both scripts keep their settings in a block at the top, so a person edits the cutoff or the contrasts there and runs the script again. The scripts of a pseudobulk export also hold `min_animals` there and refuse in R a `samples.tsv` that no longer meets the animals rule above. A script from an export made without `--design` and `--contrast` stops in words before it reads a table.

Both scripts take size factors and normalization factors from the host rows alone and keep the not-host rows in the table and in the results, with a `not_host` column. `deseq2.R` rounds `estimated` counts to whole counts, as DESeq2 needs, and says so in a comment. It writes `deseq2-results/` and `edger-limma-dream.R` writes `edger-limma-dream-results/`, each beside the script.

The record names each result with its route and reference set, the design, the contrasts, the batch step, the padj cutoff, `alpha` and the fold-change bar (`none` by default), and it lists every file of the folder with its sha256. A pseudobulk export also records `minimumAnimals`. The command it records parses to the options of the run, and a replay writes files of equal sha256 except for the record.

### A single-cell result

A single-cell result is exported by itself, because its matrices are not a table of counts that DESeq2 or edgeR read. The export refuses a bulk result or a second single-cell result given with it, in words that name both results, before it writes anything. `RNASeqExportCells` in `Sources/LungfishWorkflow/RNASeq/` does the work right after `RNASeqExportReader.read` and before the join of bulk results.

Each sample's `matrix.mtx`, `features.tsv` (or `genes.tsv` of an older Cell Ranger) and `barcodes.tsv` are copied as they were imported, plain or gzip, into a folder of the sample's own. Each copy is hashed as it is written, and the export refuses and writes nothing when a sha256 differs from the row of the result's manifest.

| File | Holds |
| --- | --- |
| `<sample folder>/matrix.mtx`, `features.tsv`, `barcodes.tsv` | The three files of each sample as imported, with `.gz` kept when the import had it |
| `genes.tsv` | The gene table of the result with its `not_host` flag |
| `samples.tsv` | One row a sample, with the columns of a bulk `samples.tsv` and last `folder`, `route` and `reference_set` |
| `seurat.R`, `scanpy.py` | The two templates, described below |
| `.lungfish-provenance.json` | The record |

`--sample-sheet` works as it does for bulk results, and a sheet column named `folder`, `route` or `reference_set` decides nothing. `--design`, `--contrast`, `--batch`, `--batch-correction`, `--lfc-bar` and a `--padj-cutoff` other than 0.05 do nothing here, so the export refuses each one given in words that point to `lungfish-cli rnaseq pseudobulk`, which sums the cells into a bulk result that those flags apply to.

The record names the result and holds `modality` (`single-cell`), `route`, `referenceSet`, `results` and `matrixFiles`. A record lists flat names only, so the files inside the sample folders are in `matrixFiles` with their path in the export, sha256, size and source path in the result.

`seurat.R` reads each matrix with `Matrix::readMM` and `scanpy.py` with `scipy.io.mmread`, and neither calls `read_10x_mtx`. Both read `samples.tsv` and `genes.tsv`, refuse a matrix whose rows differ in number from its features file or whose columns differ in number from its barcodes file, and print `cells <sample> <n>` for each sample, then `cells total <n>`, `not-host features <n>` and `features <n>, of them <m> not Gene Expression`. The Seurat object and the AnnData hold every feature type together, so the Antibody Capture rows of a feature-barcode set (19 of the 36,620 features of sc5p_v2_hs_PBMC_1k) sit in the RNA assay and in `X` beside the genes and enter `nCount_RNA`, `nFeature_RNA` and a normalisation. Subset by `type` before normalising. Each writes a table of cells, `seurat-cells.tsv` or `scanpy-cells.tsv`, with the columns `cell`, `sample`, `barcode`, `umis` and `genes`. The `umis` and `genes` count Gene Expression rows only, as `cells.sqlite` does, so the three can be compared. With two samples or more the barcode in `cell` is prefixed with `<sample>_`.

The table is written before Seurat is called, so `seurat.R` in an R without Seurat writes it and stops in words. In an R with Seurat it ends with a Seurat object that holds the `name`, `type` and `not_host` of each feature. Seurat shows a feature id with each `_` written as `-`, and the script matches the rows by position.

## The one writer

One component in `Sources/LungfishWorkflow/RNASeq/` creates, settles and discards every result, for an import and for a quantification alike, and writes its root record last (`docs/contracts/EXPERT-PANEL.md:49`, `docs/plans/2026-10-02-architecture-program.md:188`). `RNASeqResultWriter` is that component, `RNASeqResultBundle` is its reader and `RNASeqResultManifest` holds the manifest (lane RS-KIND). It works in this order.

1. It makes a staging folder `.<name>.lungfishrnaseq.creating-<UUID>` in `Analyses/`, as `AnalysesFolder` stages a result folder (`Sources/LungfishIO/Bundles/AnalysesFolder.swift:136`).
2. It copies the tool's files into `source/`, writes the tables and `cells.sqlite`, and publishes the manifest through `DurableReplace` (`docs/formats/analyses-layout.md:42`).
3. It writes the root record last through `ProvenanceWriter` (`Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift:113`).
4. It renames the folder into place with `RENAME_EXCL` through `PortableRename` (`Sources/LungfishIO/Bundles/AnalysesFolder.swift:159`, `AGENTS.md:76`), so no listing sees a result without its record.

A failed or cancelled run removes its staging folder. Planning writes nothing (`docs/contracts/EXPERT-PANEL.md:49`), no other component writes inside a published result, and reading never writes into the project (`AGENTS.md:72`). A changed count makes a new result through the writer and never edits an old one.

## No file offered for edit

The kind declares no app state file in schema 1, so every file is covered by the record (`docs/formats/bundle-kinds.md:107`). The sidebar shows the folder as one row and lists no file inside it (`docs/formats/bundle-kinds.md:84`). No viewer, Inspector panel or menu offers any file of the bundle for edit, rename or move, which is what exit X1 walks on a CLI-written result (`docs/plans/2026-10-02-architecture-program.md:200`). The viewer shows the tables read-only, and deletion removes the folder as one object (`docs/formats/bundle-kinds.md:86`).

## A newer schema

A reader knows schema 1 to its own highest number and reads each of them. It reads no other.

- A manifest with a higher `schemaVersion` is refused in words, `This RNA-seq result was written by a newer LGE (schema <n>). Open it with that version or a later one.`, and the reader writes nothing. The executor plan refuses a newer schema the same way (`docs/formats/executor-plan.md:52`), and the genotype result names an unsupported schema in its refusal (`Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift:871-874`).
- The sidebar row, deletion and copy still work, because an id from a newer build decodes and keeps the artifact (`Sources/LungfishIO/Bundles/BundleKind.swift:11`).
- A missing or unreadable manifest shows the row with `The RNA-seq result has no readable manifest.` and nothing is rewritten.
- A `cells.sqlite` whose `meta` schema is newer than the reader knows leaves the cell table unshown with the same words, and the manifest and counts still open.

A new key enters only with a new schema number, so a schema 1 reader never meets a key it must guess at.

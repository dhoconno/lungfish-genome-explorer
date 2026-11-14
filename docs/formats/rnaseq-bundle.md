# RNA-seq results

An RNA-seq result of Lungfish Genome Explorer (LGE) is one folder, `<name>.lungfishrnaseq`, that holds the bulk or single-cell counts of one route on one reference set. This page gives its layout, its manifest, the one component that writes it and what a reader does with it. It is written for developers and for the Phase 5 lanes RS-KIND, RS-BULK-IMPORT, RS-QUANT, RS-HANDOFF and RS-UI-KIND. Phase 5.1 sets the layout. `RNASeqResultManifest` and `RNASeqResultBundle` in `Sources/LungfishIO/Bundles/` read it, and `RNASeqResultWriter` in `Sources/LungfishWorkflow/RNASeq/` writes it. The reference set it names is in [reference-set.md](reference-set.md), and the test fixtures are in `Tests/Fixtures/rnaseq/` (`Tests/Fixtures/rnaseq/README.md:1-12`).

## A bundle kind kept under Analyses

The result is a bundle kind with a bulk or single-cell modality, as the program plan sets (`docs/plans/2026-10-02-architecture-program.md:115`), and not a plain `Analyses/` folder.

- A kind shown as one row has its own viewport, and the sidebar never lists the files inside it (`docs/formats/bundle-kinds.md:84`). Exit X1 asks for a project holding a CLI-written RNA-seq folder with none of its files offered for edit (`docs/plans/2026-10-02-architecture-program.md:200`). An `Analyses/` folder that no rule recognizes is a grouping folder whose entries the sidebar lists (`docs/formats/analyses-layout.md:102`).
- Import comes first, from salmon, nf-core/rnaseq, DRAGEN, Cell Ranger and STARsolo files (`docs/plans/2026-10-02-architecture-program.md:101,103`). An import is no run of an analysis kind, and `analysis-metadata.json` holds only the kind, the batch flag and the date (`docs/formats/analyses-layout.md:32`), so it cannot carry a modality, a route, a reference set or checksums.
- The deletion planner and the copier treat a kind's folder as one object (`docs/formats/bundle-kinds.md:86-88`).

The folder lives in the project's `Analyses/` folder, as the genotype and 12S results do (`Sources/LungfishIO/Bundles/BundleKindRegistry.swift:109,117`), where a folder whose extension the sidebar classifies as a bundle shows as that bundle (`docs/formats/analyses-layout.md:100`). The one sample sanitizer names it (`docs/contracts/EXPERT-PANEL.md:50`). The extension alone recognizes it, and the manifest is `rnaseq-result.json`. Its row in [bundle-kinds.md](bundle-kinds.md) and in `BundleKindRegistry` lands with RS-UI-KIND, which joins the kind to the view-switch test in the same change (`docs/plans/2026-10-02-architecture-program.md:188`, `docs/contracts/SCOPE-AND-DELIVERY.md:93`). Until then the registry lists 15 kinds and none of them is this one (`docs/formats/bundle-kinds.md:3`).

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
| `.lungfish-provenance.json`, `provenance/` | The root record and the record folder of the standard rule (`docs/formats/bundle-kinds.md:103`, `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift:11-12`). The record holds the run facts, such as `Poly-G trimming: off (LGE default)` and `Duplicates: kept. LGE removes duplicates only with UMIs.` (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:100,103`), the bias flags with the version and the four index hashes (`docs/plans/2026-10-02-architecture-program.md:194-195`) | Both |
| `samples.tsv` | One row a sample, with the sample id, the animal, species and origin (`docs/plans/2026-10-02-architecture-program.md:111,134`), the group, the run accessions and its folder under `source/` | Both |
| `genes.tsv` | The reference set's gene table for the result's rows, with the gene id, name, biotype, contig, length, the not-host flag, the mask and the unreliable mark of the MHC, KIR, immunoglobulin and T cell receptor loci (`docs/plans/2026-10-02-architecture-program.md:111,113`). When the result keeps every gene of its set, the file equals the set's `derived/genes.tsv` by sha256, so a result reads without the set. A result that keeps fewer genes holds only those rows, and the manifest's `genes` entry holds the file's own sha256. A result whose `referenceSet` is null holds the feature ids of its count tables and leaves every other column empty, which a reader shows as Not recorded | Both |
| `counts/genes.counts.tsv` | Genes by samples in the route's unit, loaded whole (`docs/plans/2026-10-02-architecture-program.md:115`) | Bulk |
| `counts/genes.masked.tsv` | The second column of the features a mask moves out of the default count, written only when a mask applies (`docs/plans/2026-10-02-architecture-program.md:113`) | Both |
| `counts/transcripts.counts.tsv` | Transcript rows, kept and exported (`docs/plans/2026-10-02-architecture-program.md:109`) | Bulk |
| `quality/samples.quality.tsv` | The quality numbers of the tools' own files (`docs/plans/2026-10-02-architecture-program.md:105`), such as salmon's `num_processed`, `percent_mapped` and library type (`Tests/Fixtures/rnaseq/salmon-c1/SRR896663/aux_info/meta_info.json:41,46`, `Tests/Fixtures/rnaseq/salmon-c1/SRR896663/lib_format_counts.json:6`) | Both |
| `source/<sample id>/` | The tool's own files as given, byte for byte, each with its sha256 in the manifest | Both |
| `cells.sqlite` | The per-cell summary of one streaming pass, which the tables page from (`docs/plans/2026-10-02-architecture-program.md:115`) | Single cell |

### The tool's own files

`source/<sample id>/` keeps each file the reader reads in the folder layout the tool wrote. For salmon these are `quant.sf`, `cmd_info.json`, `lib_format_counts.json` and `aux_info/meta_info.json` (`Tests/Fixtures/rnaseq/salmon-c1/`). For Cell Ranger they are `outs/filtered_feature_bc_matrix/` with `metrics_summary.csv` (`Tests/Fixtures/rnaseq/cellranger-pbmc_1k_v3/`), and for STARsolo `Solo.out/Gene/filtered/` with `Summary.csv` and `Log.final.out` (`Tests/Fixtures/rnaseq/starsolo-pbmc_1k_v3/`). The writer copies each file once, hashes it as it reads it (`docs/contracts/EXPERT-PANEL.md:44`) and lists it in the manifest with its sha256 and size. No later step changes a byte under `source/`. A file the reader does not read, such as an HDF5 matrix, `molecule_info.h5` or a web summary, stays out of the bundle, and the record names each one left out, so no fact is lost without a word (`docs/contracts/EXPERT-PANEL.md:57`). A file that holds several samples, such as a plain count table, one of nf-core/rnaseq's merged tables or a DRAGEN table, is kept as given in `source/tables/<file name>`, and its `sourceFiles` entry leaves `sample` empty. No sample folder is named `tables`. The writer gives such a sample the next free suffix, `tables-2`, as `batchSampleDirectory(named:in:)` does (`docs/formats/analyses-layout.md:28`).

### Single cell

A single-cell matrix stays in `source/` as given, with its gzip or without it, and is never loaded, rewritten or converted (`docs/plans/2026-10-02-architecture-program.md:115`). LGE reads Matrix Market text and links no HDF5 library (same line). One streaming pass reads each matrix once and writes `cells.sqlite`, whose table `cells` has one row a barcode with its sample and per-cell totals and whose table `meta` holds its own schema version and the sha256 of every matrix it read. Phase 5.2 sets the columns of `cells` (`docs/plans/2026-10-02-architecture-program.md:113`, the ambient pool and the flag words). A barcode list of 10x never enters the bundle unless the person supplied it, checked by sha256 (`docs/plans/2026-10-02-architecture-program.md:103`).

## The manifest

`rnaseq-result.json` is JSON with camel-case keys, as the 12S result's `schemaVersion` is (`Sources/LungfishIO/Bundles/TwelveSAmpliconResultModels.swift:5-7`). Schema 1 holds these keys.

| Key | Holds |
| --- | --- |
| `schemaVersion` | 1 |
| `kind` | `rnaseq-result` |
| `modality` | `bulk` or `single-cell` |
| `name`, `createdAt` | The display name and an ISO 8601 date |
| `origin` | `imported` with the tool and version that made the files, or `quantified` when LGE ran the route |
| `route` | One route, with its id, the counting tool, its version and every setting that changes counts, such as salmon with selective alignment on reads, STAR GeneCounts and its column, or featureCounts with its `-M`, `-O`, `-s` and `--fraction` settings (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:102`) |
| `referenceSet` | The set's `id` and `layout`, `lge` or `deposit` ([reference-set.md](reference-set.md)), or `null` when the imported files state none, which a reader shows as Not recorded (`docs/plans/2026-10-02-architecture-program.md:189`) |
| `samples`, `genes` | The path and sha256 of `samples.tsv` and `genes.tsv` |
| `counts` | One entry a count table, with its path, sha256, rows (`gene` or `transcript`), unit (`reads`, `pairs`, `umis` or `estimated`) and column (`default` or `masked`) |
| `sourceFiles` | One entry a kept file, with its path, sha256, size, sample and tool |
| `matrices` | Single cell. One entry a sample, with the paths of its matrix, features and barcodes, each sha256, the format `matrix-market`, whether it is gzip, and its cells, features and entries |
| `cellsSummary` | Single cell. The path, sha256 and schema version of `cells.sqlite` |
| `notHost` | The ids of the not-host features, each one feature a genome or segment, which stay out of size factors (`docs/plans/2026-10-02-architecture-program.md:113`) |

The run facts stay in the record and the manifest repeats none of them.

## One table, one route

A result holds the counts of one route on one reference set. A second route, or the same route on a second set, makes a second result. Counts from two routes or two reference sets never join in one table (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:102`, `docs/plans/2026-10-02-architecture-program.md:113`), so the export refuses in words a table whose columns come from more than one route or set (`docs/plans/2026-10-02-architecture-program.md:190`). A not-host feature keeps its count in `counts/genes.counts.tsv`, its flag in `genes.tsv` and its id in `notHost`, and the export leaves it out of size factors (`docs/plans/2026-10-02-architecture-program.md:113`).

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

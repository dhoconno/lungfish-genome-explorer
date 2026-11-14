# Reference sets and the salmon index cache

A reference set of Lungfish Genome Explorer (LGE) is one named folder with checksums that RNA-seq counting shares across bulk and single cell, the Mac and Linux (`docs/plans/2026-10-02-architecture-program.md:111`). This page gives its kind, where it lives, its one owner, its id, its layout and its deposit layout, how a reference written before Phase 5 still opens, and the salmon index cache beside it. It is written for developers and for the lanes RS-REFSET and RS-INDEX. Phase 5.1 sets the layout, and no code writes it yet. The results that name a set are in [rnaseq-bundle.md](rnaseq-bundle.md).

## A new kind, not a `.lungfishref`

A set is a new kind, `<set id>.lungfishrefset`, and no extension of the `.lungfishref` reference bundle.

- A `.lungfishref` holds one genome with the tracks drawn on it (`docs/formats/reference-bundle.md:3`). A set holds the genome FASTA, the GTF with its source and release, the transcript FASTA and gene table derived from them, and extra sequences such as a virus (`docs/plans/2026-10-02-architecture-program.md:111`).
- The reference manifest is `BundleManifest` in LungfishCore (`docs/formats/reference-bundle.md:43`). Adding the set's parts there would put RNA-seq types outside `Sources/LungfishWorkflow/RNASeq/`, the domain folder that may leave for its own target only when no other folder names its types (`docs/plans/2026-10-02-architecture-program.md:188`).
- A set's id comes from its content, so a changed virus sequence makes a new id (`docs/plans/2026-10-02-architecture-program.md:193`). The reference bundle's `identifier` is a reverse-DNS name (`docs/formats/reference-bundle.md:48`), and its mutators set a new modified date with every track (`docs/formats/reference-bundle.md:61`).

No project holds a set, so it gets no row in [bundle-kinds.md](bundle-kinds.md) and no sidebar row.

## A shared cache, not the project

Sets live in one folder of the LGE storage root, `<storage root>/rnaseq-reference-sets/`, beside the `conda` and `databases` folders that root already holds (`Sources/LungfishCore/Storage/ManagedStorageLocation.swift:41-47`). The default root is a folder in the home folder named by the app identity (`Sources/LungfishCore/Storage/ManagedStorageLocation.swift:58-67`), and a root inside a project is refused (`Sources/LungfishCore/Storage/ManagedStorageLocation.swift:16-17`), so a set never sits inside a project.

- A human set holds the whole GRCh38 genome and its indexes, and C1's decoy-aware salmon index alone took 23.7 GB to build (`docs/plans/2026-10-02-architecture-program.md:174`). A copy in each project would repeat that.
- Bulk and single cell, the Mac and Linux share one set by its id (`docs/plans/2026-10-02-architecture-program.md:111`).
- A result keeps what it needs to read without the set. Its `genes.tsv` equals the set's gene table by sha256, and its manifest names the set's id and layout ([rnaseq-bundle.md](rnaseq-bundle.md)). A project moved to a Mac without the set opens every count and shows the set as not on this Mac.

The owner derives the folder from `ManagedStorageLocation.rootURL` (`Sources/LungfishCore/Storage/ManagedStorageLocation.swift:35`), so no Core or IO type names it.

## The one owner

One component in `Sources/LungfishWorkflow/RNASeq/` creates, settles and discards every set, and writes its root record last (`docs/contracts/EXPERT-PANEL.md:49`). RS-REFSET writes it. No other component writes under `rnaseq-reference-sets/`.

1. It builds in a staging folder `.<set id>.lungfishrefset.creating-<UUID>` inside `rnaseq-reference-sets/`, the staging form of a result folder (`Sources/LungfishIO/Bundles/AnalysesFolder.swift:136`).
2. It copies each input, checks its sha256 as it reads it, derives the transcript FASTA and gene table, and publishes `reference-set.json` through `DurableReplace` (`docs/formats/analyses-layout.md:42`).
3. It writes the root record `.lungfish-provenance.json` last through `ProvenanceWriter` (`Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift:11,113`).
4. It renames the folder into place with `RENAME_EXCL` through `PortableRename` (`Sources/LungfishIO/Bundles/AnalysesFolder.swift:159`, `AGENTS.md:76`). When a set of the same id is already there, the rename fails, the owner removes its staging folder and uses the published set after it checks the manifest.

A failed or cancelled build removes its staging folder. A published set never changes. Settling means the owner checks the manifest and each file's size before a run, and every sha256 when the person asks for a check, and refuses in words a set whose files differ.

## The id

A set's id is `<species>-<assembly>-<annotation source and release>-<layout>-<digest>`, such as `macaca_mulatta-Mmul_10-ensembl100-lge-3f9a1c2b7d10`. The digest is the first 12 hex digits of the sha256 of a content list, one line `<role>\t<file name>\t<sha256>` for the genome, the annotation and each extra sequence by name, then `layout\t<layout>` and `derive\tgffread <version>`. A changed byte in any input, a changed extra, a changed layout or a changed gffread makes a new id, so a changed virus sequence makes a new id (`docs/plans/2026-10-02-architecture-program.md:193`). The derived files are not in the list, since they follow from it.

## Layout

```
<set id>.lungfishrefset/
  reference-set.json
  .lungfish-provenance.json
  provenance/
  genome/<file as given>
  annotation/<file as given>
  extras/<name>.fa
  derived/transcripts.fa
  derived/genes.tsv
```

| Key of `reference-set.json` | Holds |
| --- | --- |
| `schemaVersion` | 1. A higher number is refused in words, as a result's is ([rnaseq-bundle.md](rnaseq-bundle.md)) |
| `id`, `name`, `species` | The id above, a display name and the species |
| `assembly` | The assembly name, accession and source URL, such as GRCh38, Mmul_10 or T2T-MFA8v1.1 (`docs/plans/2026-10-02-architecture-program.md:111`) |
| `annotation` | The GTF's source and release, its path and sha256 |
| `genome` | The genome FASTA's path and sha256, and the `.lungfishref` it came from with that bundle's `md5_checksum` when it came from one |
| `extras` | One entry a sequence the person added, with its name, kind (virus, bacterium or spike-in), path, sha256 and records, each flagged not-host (`docs/plans/2026-10-02-architecture-program.md:113`) |
| `layout` | `lge`, or `deposit` with the study it reproduces |
| `mitochondrialContigs` | The contigs whose genes are mitochondrial, since a gene is never called mitochondrial by its name (`docs/plans/2026-10-02-architecture-program.md:111`) |
| `masks` | The features a mask moves out of the default count, such as a pathogen's rRNA genes, with the mask's name (`docs/plans/2026-10-02-architecture-program.md:113`) |
| `derived` | The transcript FASTA and the gene table, each with its path, sha256, tool and version |

In LGE's layout a not-host sequence counts as one feature a sequence record (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:91`). A gene with a CDS and no exon gets its CDS and stop codon as an exon that the record names, or a refusal in words (`docs/plans/2026-10-02-architecture-program.md:111`). A transcript id in one file and not the other is refused with the names listed, and nothing is renamed (`docs/plans/2026-10-02-architecture-program.md:193`).

### The deposit layout

The deposit layout is a named reproduce option, `deposit layout`, and never LGE's default (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:91`). It keeps a deposit's own not-host features, only to check that deposit (`docs/plans/2026-10-02-architecture-program.md:113`). Its id carries `deposit-<study>` where LGE's layout carries `lge`, and its record says which deposit it reproduces. Mmul_10 Ensembl 100 with NC_045512.2 gives 35,443 features in the deposit layout of GSE183579 and 35,433 in LGE's layout (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:91`).

## A reference written before Phase 5

Nothing in the `.lungfishref` kind changes, so every reference bundle written before Phase 5 opens as it does today (`docs/contracts/EXPERT-PANEL.md:50`). `BundleManifest.load(from:)` reads an older manifest as before (`docs/formats/reference-bundle.md:61`). A set may take its genome from a `.lungfishref`. The owner reads the FASTA that the manifest's `genome` names, records the bundle's `md5_checksum` beside its own sha256 (`docs/formats/reference-bundle.md:71`) and writes nothing into the reference bundle.

## The salmon index cache

RS-INDEX fills one cache of salmon indexes outside every project, `<storage root>/rnaseq-index-cache/`, keyed by the set id, the salmon version, k and the decoys (`docs/plans/2026-10-02-architecture-program.md:194`).

```
rnaseq-index-cache/
  <set id>/
    salmon-<version>-k<k>-<decoys>/
      index-key.json
      .lungfish-provenance.json
      provenance/
      index/
      uses/
        <sha256 of a result path>.json
```

`<decoys>` is `genome-decoys` or `no-decoys`. C1's index, salmon 2.11.0 with k 31 and the whole GRCh38 primary assembly as decoys (`scripts/repro/rnaseq/seqc-gse47774/index.sh:2-3,9`, `Tests/Fixtures/rnaseq/salmon-c1/SRR896663/aux_info/meta_info.json:2`), would be `salmon-2.11.0-k31-genome-decoys`. `index/` holds the files salmon wrote. `index-key.json` holds the four key fields, the set's `reference-set.json` sha256, salmon's build, the argv, and the four index hashes, `index_seq_hash`, `index_name_hash`, `index_decoy_seq_hash` and `index_decoy_name_hash`, which every quantification repeats in its `aux_info/meta_info.json` (`Tests/Fixtures/rnaseq/salmon-c1/SRR896663/aux_info/meta_info.json:20-25`). Each result's record names them (`docs/plans/2026-10-02-architecture-program.md:194`).

### Its one owner

One component in `Sources/LungfishWorkflow/RNASeq/`, which RS-INDEX writes, is the only writer under `rnaseq-index-cache/` (`docs/contracts/EXPERT-PANEL.md:49`). It builds in a staging folder `.salmon-<version>-k<k>-<decoys>.creating-<UUID>` beside the final name, writes `index-key.json`, then the root record last, and renames the folder into place with `RENAME_EXCL` through `PortableRename` (`AGENTS.md:76`). A second build of the same key that loses the rename removes its staging folder and uses the published index, so a second run reuses it (`docs/plans/2026-10-02-architecture-program.md:194`). C1's decoy-aware index took 53 minutes and 23.7 GB on a loaded galah (`docs/plans/2026-10-02-architecture-program.md:174`), so a build that cannot fit is refused in words before it starts (`docs/plans/2026-10-02-architecture-program.md:196`).

### Cleanup

Cleanup deletes nothing a record names (`docs/contracts/EXPERT-PANEL.md:51`), and an index is never deleted while a record names its hashes (`docs/plans/2026-10-02-architecture-program.md:194`). No cleanup of LGE reaches these folders today. Launch cleanup removes only temporary folders with LGE's prefixes (`Sources/LungfishCore/Services/TempFileManager.swift:75-83`), and `lungfish-cli storage dedupe` replaces duplicate files with APFS clones and keeps every byte (`Sources/LungfishCLI/Commands/StorageCommand.swift:101-104`).

- No automatic cleanup deletes a set, an index or a file in either. A later cleanup that walks the storage root skips `rnaseq-reference-sets/` and `rnaseq-index-cache/`.
- A result whose record names an index or a set gets one file in that folder's `uses/`, `<sha256 of the result path>.json`, holding the result's path and its record's sha256. The owner creates it once and never rewrites it, so two runs never write one file.
- Only the owner removes an index or a set, and only when the person asks. It lists the uses and refuses in words while a listed result still exists and its record names that index's hashes or that set's id. A use whose result is gone, or whose record names other hashes, holds nothing.
- A set stays while an index or a use names it.

## Where the types live

Every type this page asks for lives in `Sources/LungfishWorkflow/RNASeq/`, and both folders come from `ManagedStorageLocation.rootURL` there, so no type outside that folder names a set or an index (`docs/plans/2026-10-02-architecture-program.md:188`).

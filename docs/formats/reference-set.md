# Reference sets and the salmon index cache

A reference set of Lungfish Genome Explorer (LGE) is one named folder with checksums that RNA-seq counting shares across bulk and single cell, the Mac and Linux (`docs/plans/2026-10-02-architecture-program.md:111`). This page gives its kind, where it lives, its one owner, its id, its layout and its deposit layout, how a reference written before Phase 5 still opens, and the salmon index cache beside it. It is written for developers and for the lanes RS-REFSET and RS-INDEX. Phase 5.1 sets the layout, and `ReferenceSetOwner` in `Sources/LungfishWorkflow/RNASeq/` writes it (lane RS-REFSET). The results that name a set are in [rnaseq-bundle.md](rnaseq-bundle.md).

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
- A result keeps what it needs to read without the set. Its `genes.tsv` holds the set's gene rows for the result's genes, and equals the set's gene table by sha256 when the result keeps every gene. Its manifest names the set's id and layout ([rnaseq-bundle.md](rnaseq-bundle.md)). A project moved to a Mac without the set opens every count and shows the set as not on this Mac.

The owner derives the folder from `ManagedStorageLocation.rootURL` (`Sources/LungfishCore/Storage/ManagedStorageLocation.swift:35`), so no Core or IO type names it.

## The one owner

One component in `Sources/LungfishWorkflow/RNASeq/` creates, settles and discards every set, and writes its root record last (`docs/contracts/EXPERT-PANEL.md:49`). RS-REFSET writes it. No other component writes under `rnaseq-reference-sets/`.

1. It builds in a staging folder `.<set id>.lungfishrefset.creating-<UUID>` inside `rnaseq-reference-sets/`, the staging form of a result folder (`Sources/LungfishIO/Bundles/AnalysesFolder.swift:136`).
2. It copies each input, checks its sha256 as it reads it, derives the transcript FASTA and gene table, and publishes `reference-set.json` through `DurableReplace` (`docs/formats/analyses-layout.md:42`).
3. It writes the root record `.lungfish-provenance.json` last through `ProvenanceWriter` (`Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift:11,113`).
4. It renames the folder into place with `RENAME_EXCL` through `PortableRename` (`Sources/LungfishIO/Bundles/AnalysesFolder.swift:159`, `AGENTS.md:76`). When a set of the same id is already there, the rename fails, the owner removes its staging folder and uses the published set after it checks the manifest.

A failed or cancelled build removes its staging folder. A published set changes only by the files of `uses/`, which the owner adds after the root record and no record names. Settling means the owner checks the manifest and each file's size before a run, and every sha256 when the person asks for a check, and refuses in words a set whose files differ.

## The id

A set's id is `<species>-<assembly>-<annotation source and release>-<layout>-<digest>`, such as `macaca_mulatta-Mmul_10-ensembl100-lge-3f9a1c2b7d10`. The digest is the first 12 hex digits of the sha256 of a content list, one line `<role>\t<file name>\t<sha256>` for the genome, the annotation and each extra sequence by name, with `extra annotation\t<file name>\t<sha256>` right after its extra's line when that extra brings its own GTF (the deposit layout only), then `assembly report\t<file name>\t<sha256>` when the person gives an assembly report and `mitochondrial contig\t<name>\t` for each contig the person names, so another report or another contig makes another id, then `layout\t<layout>` and `derive\tgffread <version>`. The lines keep the order given, so each GTF stays tied to its extra, and two sets that differ only in an extra's GTF get two ids. A changed byte in any input, a changed extra, a changed layout or a changed gffread makes a new id, so a changed virus sequence makes a new id (`docs/plans/2026-10-02-architecture-program.md:193`). The derived files are not in the list, since they follow from it.

## Layout

```
<set id>.lungfishrefset/
  reference-set.json
  .lungfish-provenance.json
  provenance/
  genome/<file as given>
  annotation/<file as given>
  extras/<name>.fa
  extras/<name>.gtf
  derived/transcripts.fa
  derived/genes.tsv
  derived/transcripts.tsv
  derived/genes-without-features.tsv
  uses/
```

An input given as a symbolic link is read and copied as the file the link names, under the name given, so a set holds no link.

| Key of `reference-set.json` | Holds |
| --- | --- |
| `schemaVersion` | 1. A higher number is refused in words, as a result's is ([rnaseq-bundle.md](rnaseq-bundle.md)) |
| `id`, `name`, `species` | The id above, a display name and the species |
| `assembly` | The assembly name, accession and source URL, such as GRCh38, Mmul_10 or T2T-MFA8v1.1 (`docs/plans/2026-10-02-architecture-program.md:111`) |
| `annotation` | The GTF's source and release, its path and sha256 |
| `genome` | The genome FASTA's path and sha256, and the `.lungfishref` it came from with that bundle's `md5_checksum` when it came from one |
| `extras` | One entry a sequence the person added, with its name, kind (virus, bacterium or spike-in), path, sha256 and records, and in the deposit layout the path and sha256 of the extra's own GTF (`annotationPath`, `annotationSHA256`, kept as `extras/<name>.gtf`), each flagged not-host (`docs/plans/2026-10-02-architecture-program.md:113`) |
| `layout` | `lge`, or `deposit` with the study it reproduces |
| `mitochondrialContigs` | The contigs whose genes are mitochondrial, since a gene is never called mitochondrial by its name (`docs/plans/2026-10-02-architecture-program.md:111`). An empty list means the set holds no mitochondrial contig, as in the two T2T sets, whose RefSeq files leave the mitochondrion out although the assembly report lists it. A reader says `mitochondrial share not measured (no mitochondrial contig)` and never 0%, and the leaf prints a note. |
| `masks` | The features a mask moves out of the default count, such as a pathogen's rRNA genes, with the mask's name (`docs/plans/2026-10-02-architecture-program.md:113`) |
| `derived` | The transcript FASTA, the gene table and the transcript table, each with its path, sha256, size, tool and version |
| `derivation` | What the owner changed from the annotation as given, in `exonsAdded`, the genes given their CDS and stop codon as an exon (LGE's layout), `keptWithoutExon`, the genes with a CDS and no exon kept as the deposit gave them (the deposit layout), `droppedFeatures`, each feature of empty `gene_id` as `<contig>\t<type>\t<start>\t<end>`, `renamedTranscripts`, each transcript id that named more than one gene, contig or strand with its gene and its new id, and `genesWithoutFeatures`, the path, count and sha256 of `derived/genes-without-features.tsv` |

In LGE's layout a not-host sequence counts as one feature a sequence record (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:91`). A gene with a CDS and no exon gets its CDS and stop codon as an exon that the record names, or a refusal in words (`docs/plans/2026-10-02-architecture-program.md:111`). A transcript id in one file and not the other is refused with the names listed, and nothing is renamed (`docs/plans/2026-10-02-architecture-program.md:193`). A name that `derived/transcripts.fa` holds twice is refused the same way, since a count could not tell the two records apart. The check counts names, not sets of names.

`derived/genes.tsv` has the columns `gene_id`, `name`, `biotype`, `contig`, `length`, `not_host`, `mask` and `unreliable`, the names the result's reader reads ([rnaseq-bundle.md](rnaseq-bundle.md)). Its genes come in the order of their first exon line, or of their first CDS line for a gene with no exon, as a deposit's feature list reads (`scripts/repro/rnaseq/gse296788/ref.py:4-10`), and each extra's genes come last in the order given. `length` is the gene's exonic length in bases, 0 for a gene kept without an exon. `not_host` is `true` or `false`, and `mask` and `unreliable` are empty in 5.1. A feature of empty `gene_id` is dropped. `derived/transcripts.tsv` has `transcript_id` and `gene_id` first, as `scripts/repro/rnaseq/seqc-gse47774/tx2gene.py:5-6` writes them, one row a record of `derived/transcripts.fa`, so gene sums read it. A gene with no exon line and no CDS line, such as a pseudogene that RefSeq gives only a gene line, is listed in `derived/genes-without-features.tsv` with the columns `gene_id`, `contig` and `biotype`, in the order of its first line, and stays out of `genes.tsv` and `transcripts.tsv`. The build is not refused, since no read can land on such a gene. Cynomolgus RefSeq 5.0 has 4,523 such genes and rhesus RefSeq Mmul_10 5,664.

gffread writes the transcript FASTA from the genome and a GTF that LGE writes in the stage (`gffread -w <out> -g <genome> <gtf>`), and never reads the annotation as given. That GTF holds the annotation's feature lines with these changes.

- Each line of empty `gene_id` is left out.
- A gene line loses a `transcript_id ""` attribute, so gffread reads the gene by its `gene_id`, as it reads the gene lines of Ensembl and of RefSeq Macaca_fascicularis_5.0. RefSeq Mmul_10 release 103 and the two T2T releases write `transcript_id ""` on each gene line, and gffread 0.12.9 refuses such a line with `no valid ID found for GFF record`.
- Each line of a gene with no exon and no CDS is left out, since gffread 0.12.9 writes a record from a transcript line alone.
- A `transcript_id` that names more than one `gene_id`, contig or strand becomes `<gene_id>:<transcript_id>` on each line, and `renamedTranscripts` lists each old id, gene and new id. RefSeq gives the tRNA, rRNA and CDS lines of a mitochondrion one id, `unknown_transcript_1`, and gffread 0.12.9 then writes two chimeric records of that one name.
- In LGE's layout each transcript of a gene given an exon gets one exon line from its CDS and stop codon span.
- In the deposit layout each line of a gene kept without an exon that carries a `transcript_id` is left out, so gffread writes no record for a gene that counts 0.

Each extra's records follow in the order given, as `scripts/repro/rnaseq/seqc-gse47774/ref.sh:30` joins ERCC92. An extra with its own annotation in the deposit layout gives gffread's records of a GTF that LGE writes from that annotation by the same rules. The mitochondrial contigs are the ones the person names, else the sequence an NCBI assembly report types Mitochondrion, else a FASTA header that says mitochondrion, else a contig named `MT`, `chrM`, `chrMT`, `M` or `Mt`, never a gene name prefix (`scripts/repro/rnaseq/refs/refcheck.py:225`).

### The deposit layout

The deposit layout is a named reproduce option, `deposit layout`, and never LGE's default (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:91`). It keeps a deposit's own not-host features, only to check that deposit (`docs/plans/2026-10-02-architecture-program.md:113`). Its id carries `deposit-<study>` where LGE's layout carries `lge`, and its record says which deposit it reproduces. Mmul_10 Ensembl 100 with NC_045512.2 gives 35,443 features in the deposit layout of GSE183579 and 35,433 in LGE's layout (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:91`). The deposit layout also keeps a gene with a CDS and no exon as the deposit gave it. It adds no exon, so the gene counts 0. In GSE296788's deposit layout the 13 mitochondrial genes keep no exon, as all 15 deposits do, and the quality view reads `mitochondrial share not measured (13 genes without exons)` and never 0% (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:91`). RefSeq Macaca_fascicularis_5.0 release 101 with the two Mtb scaffolds KK339487.1 and KK339488.1, one feature each, gives the deposit's 28,847 features in order in both layouts, and the 24 tRNA and rRNA exons of empty `gene_id` are dropped and listed in the set's record (same line).

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

Every build passes `salmon index -t <gentrome> -d <decoy names> -k <k> -p 8 --ramLimit 4 -i index`, and no `-d` pair for `no-decoys`. `-p` and `--ramLimit` are fixed, never chosen by the Mac's memory or by the person, and are not in the key, since `--ramLimit` changes no byte of the index (Phase 5.1 ruling ADJ-SPIKE-BIO, items 1 to 5). With GRCh38 chromosomes 1, 2 and 3 as decoys, `--ramLimit` 1 and 16 gave byte-equal index files and `quant.sf`. At full scale, RS-INDEX's one build of GRCh38 with ERCC92 at `-p 8 --ramLimit 4` (set `homo_sapiens-GRCh38-ensembl100-lge-a149f6aa50d5`, salmon 2.11.0 build `hfc06a8d_0`, galah, 2026-11-14) gave all nine index files byte-equal by `cmp` to C1's build at `--ramLimit 16`, and the `quant.sf` of SRR896663 on that index byte-equal to C1's (sha256 `7bef17c6d4a502aa5b5cb1d940b77976e0d91c13fe979c925dd1a47c5dc1240d`). The four index hashes cover the input sequences and names only, so they are no evidence of equal bytes, and the nine `cmp` results are. That one build did not test a second build of the same key, another sample or set, a `-p` other than 8, another salmon build or another host. The argv in `index-key.json` names the stage's files by their names in it (`gentrome.fa`, `decoys.txt`, `index`). The gentrome is the set's `derived/transcripts.fa` and then, for `genome-decoys`, the set's genome, and each decoy name is a genome header up to its first space or tab (`scripts/repro/rnaseq/seqc-gse47774/ref.sh:28-31`). Both are written in the stage's `.work/`, which goes before the rename. The salmon version of the key comes from the `conda-meta` record of salmon's environment, so a reuse starts no process. A build whose `info.json` gives another `k`, `salmon_version` or `num_decoys` than it asked for publishes nothing.

### Its one owner

`SalmonIndexCache` in `Sources/LungfishWorkflow/RNASeq/`, which RS-INDEX writes, is the only writer under `rnaseq-index-cache/` (`docs/contracts/EXPERT-PANEL.md:49`), and `lungfish-cli rnaseq index` is its command. Before a build it checks with `RunFitPreflight` that the Mac has about 16.6 GB of memory and 64 GB of free disk, and checks again with a need scaled from the gentrome when that is larger than GRCh38 with ERCC92's (Phase 5.1 ruling ADJ-SPIKE-ARCH, items 1 to 5). A reuse runs no check. It builds in a staging folder `.salmon-<version>-k<k>-<decoys>.creating-<UUID>` beside the final name, writes `index-key.json`, then the root record last, and renames the folder into place with `RENAME_EXCL` through `PortableRename` (`AGENTS.md:76`). A second build of the same key that loses the rename removes its staging folder and uses the published index, so a second run reuses it (`docs/plans/2026-10-02-architecture-program.md:194`). C1's decoy-aware index at `--ramLimit 16` took 53 minutes and 23.7 GB on a loaded galah (`docs/plans/2026-10-02-architecture-program.md:174`). LGE's at `-p 8 --ramLimit 4` took 19 minutes 19 seconds on the same Mac at a load of 10 to 47, with a peak resident set of 20,371,177,472 bytes as `/usr/bin/time -l` reports it for the CLI and salmon together (RS-INDEX stage run, 2026-11-14). The check compares the Mac's memory with 17,780,281,048 bytes, the peak memory footprint of the `--ramLimit 16` build, which bounds the 15,681,106,880 bytes of a build at `--ramLimit 4`, and the free disk with 63,897,293,195 bytes (SPIKE-SALMON, 2026-11-14), so a build that cannot fit is refused in words before it starts (`docs/plans/2026-10-02-architecture-program.md:196`).

### Cleanup

Cleanup deletes nothing a record names (`docs/contracts/EXPERT-PANEL.md:51`), and an index is never deleted while a record names its hashes (`docs/plans/2026-10-02-architecture-program.md:194`). No cleanup of LGE reaches these folders today. Launch cleanup removes only temporary folders with LGE's prefixes (`Sources/LungfishCore/Services/TempFileManager.swift:75-83`), and `lungfish-cli storage dedupe` replaces duplicate files with APFS clones and keeps every byte (`Sources/LungfishCLI/Commands/StorageCommand.swift:101-104`).

- No automatic cleanup deletes a set, an index or a file in either. A later cleanup that walks the storage root skips `rnaseq-reference-sets/` and `rnaseq-index-cache/`.
- A result whose record names an index or a set gets one file in that folder's `uses/`, `<sha256 of the result path>.json`, holding the result's path and its record's sha256. The owner creates it once and never rewrites it, so two runs never write one file.
- Only the owner removes an index or a set, and only when the person asks. It lists the uses and refuses in words while a listed result still exists and its record names that index's hashes or that set's id. A use whose result is gone, or whose record names other hashes, holds nothing. A use of an index holds it while the result's `.lungfish-provenance.json` holds each of the index's hashes. Removing the last index of a set also removes that set's empty folder in `rnaseq-index-cache/`.
- A set stays while an index or a use names it.

Two events leave folders that these rules must still reach.

- A crash leaves a staging folder, `.<name>.creating-<UUID>`, in either folder. No record names it, so the owner removes the ones that no running build holds before it starts a build, and removes nothing else. A running build holds its stage with an exclusive `flock` on the folder, so a stage whose lock the owner can take is one a crash left.
- A change of storage root copies `databases` to the new root and runs the tool install there, then removes from the old root only `conda`, `databases` and the receipt, and the root itself when it is then empty (`Sources/LungfishWorkflow/Storage/ManagedStorageCoordinator.swift:43-44,75-76,104-120`). It leaves `rnaseq-reference-sets/` and `rnaseq-index-cache/` at the old root and removes none of them. The copy that carries them is `ReferenceSetOwner`'s copy of each set to the new root, which checks every sha256 at the new root first and is not built in 5.1, and neither adds a folder to the list at `Sources/LungfishWorkflow/Storage/ManagedStorageCoordinator.swift:104-108` before that copy exists.

## Where the types live

Every type this page asks for lives in `Sources/LungfishWorkflow/RNASeq/`, and both folders come from `ManagedStorageLocation.rootURL` there, so no type outside that folder names a set or an index (`docs/plans/2026-10-02-architecture-program.md:188`).

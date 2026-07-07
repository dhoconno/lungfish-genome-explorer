---
title: File Formats
chapter_id: appendices/file-formats
audience: analyst
prereqs: []
estimated_reading_min: 14
task: Look up the structure and conventions of any file format Lungfish reads or writes.
tags: [reference, file-formats, fasta, fastq, bam, vcf, gff3, lungfishref, bundles]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish reads and writes two kinds of file: standard bioinformatics formats and its own bundle formats. This appendix says what sits inside each one, how Lungfish produces or consumes it, and how to inspect it from the terminal. The standard formats keep a Lungfish project interoperable with command-line tools and other genome browsers. The bundle formats wrap related files together with a manifest and provenance, so a reference, a primer scheme, or a phylogeny moves between machines as a single unit.

## Standard sequence formats

| Format | Extension | Purpose | Spec |
|---|---|---|---|
| FASTA | `.fa`, `.fasta`, `.fna` | Nucleotide or protein sequence | [NCBI FASTA](https://www.ncbi.nlm.nih.gov/genbank/fastaformat/) |
| FASTA index | `.fai` | Random access into FASTA | [samtools faidx](http://www.htslib.org/doc/faidx.html) |
| FASTQ | `.fastq`, `.fq`, `.fastq.gz` | Reads with per-base quality | [FASTQ format](https://maq.sourceforge.net/fastq.shtml) |
| GenBank | `.gb`, `.gbk` | Annotated sequence record | [NCBI GenBank](https://www.ncbi.nlm.nih.gov/Sitemap/samplerecord.html) |

FASTA files hold one or more records. Each record begins with a `>` header line followed by sequence lines:

```fasta
>MN908947.3 Severe acute respiratory syndrome coronavirus 2
ATTAAAGGTTTATACCTTCCCAGGTAACAAACCAACCAACTTTCGATCTCTTGTAGATCT
GTTCTCTAAACGAACTTTAAAATCTGTGTGGCTGTCACTCGGCTGCATGCTTAGTGCACT
```

FASTQ files store reads in four-line records:

```fastq
@SRR36291587.1 1/1
ATTAAAGGTTTATACCTTCCCAGGTAACAAACCAAC
+
FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
```

Lungfish takes FASTA at every reference picker, takes FASTQ (single or paired) for read import, and writes FASTA when it exports a consensus sequence. GenBank records come in and get converted to FASTA plus a GFF3 annotation track during reference materialization.

## Standard annotation formats

| Format | Extension | Purpose | Spec |
|---|---|---|---|
| GFF3 | `.gff`, `.gff3` | Hierarchical features | [GFF3 spec](https://github.com/The-Sequence-Ontology/Specifications/blob/master/gff3.md) |
| GTF | `.gtf` | Gene transfer format | [Ensembl GTF](https://useast.ensembl.org/info/website/upload/gff.html) |
| BED | `.bed` | Genomic intervals | [UCSC BED](https://genome.ucsc.edu/FAQ/FAQformat.html#format1) |

GFF3 is the annotation format Lungfish prefers for references. Each line carries nine tab-separated columns: `seqid`, `source`, `type`, `start`, `end`, `score`, `strand`, `phase`, and `attributes`. Lungfish converts GTF to GFF3 on import. BED does other duty: primer coordinates inside `.lungfishprimers` bundles, amplicon regions, and arbitrary track overlays. Its minimal three-column form is:

```text
MN908947.3	100	150
MN908947.3	200	275
```

BED is 0-based and half-open by spec, while GFF3 and VCF are 1-based and inclusive. Lungfish keeps whatever convention each file uses internally and shows you 1-based inclusive coordinates on every UI surface.

## Standard alignment formats

| Format | Extension | Purpose | Spec |
|---|---|---|---|
| SAM | `.sam` | Text alignment | [SAMv1 spec](https://samtools.github.io/hts-specs/SAMv1.pdf) |
| BAM | `.bam` | Binary alignment | Same as SAM |
| BAM index | `.bai` | Random access into BAM | Same as SAM |

SAM is the human-readable form. BAM is the binary, block-compressed (BGZF) form that pairs with a `.bai` index for random access. Lungfish always reads and writes sorted, indexed BAM, and it never keeps SAM as a deliverable. When a tool emits SAM, Lungfish runs it through `samtools sort` plus `samtools index` and then deletes the intermediate file.

Inspect a BAM from the terminal:

```bash
samtools view -h alignment.bam | head
samtools flagstat alignment.bam
samtools idxstats alignment.bam
```

## Standard variant formats

| Format | Extension | Purpose | Spec |
|---|---|---|---|
| VCF | `.vcf` | Variant call format | [VCFv4.4 spec](https://samtools.github.io/hts-specs/VCFv4.4.pdf) |
| BGZipped VCF | `.vcf.gz` | Compressed VCF | Same as VCF |
| Tabix index | `.tbi` | Random access into `.vcf.gz` | [tabix spec](https://samtools.github.io/hts-specs/tabix.pdf) |

VCF records variants relative to a reference. Lungfish reads VCF 4.0, 4.1, 4.2, 4.3, and 4.4 only, either as plain VCF for small files or as bgzipped VCF with a tabix index for large ones. A VCFv3 file has to be converted to VCF 4.x with an external converter before import. The header declares the fields and contigs, and the body lists one variant per line:

```vcf
##fileformat=VCFv4.2
##contig=<ID=MN908947.3,length=29903>
#CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO
MN908947.3	241	.	C	T	.	PASS	DP=523
MN908947.3	3037	.	C	T	.	PASS	DP=611
```

Lungfish consumes VCF from `bcftools`, `lofreq`, and `ivar variants` (once the converter has run). Variants produced inside Lungfish live in the reference bundle's `variants/` subdirectory (see `.lungfishref` below), not in a standalone bundle.

## Standard tree format

| Format | Extension | Purpose | Spec |
|---|---|---|---|
| Newick | `.nwk`, `.tree`, `.treefile` | Tree topology with branch lengths | [Newick format](https://evolution.genetics.washington.edu/phylip/newicktree.html) |

Newick is a compact parenthesis-based notation. A three-leaf tree:

```text
((sample_a:0.012,sample_b:0.014):0.003,sample_c:0.020);
```

Lungfish reads Newick produced by IQ-TREE, FastTree, or RAxML, and stores the original alongside its metadata in a `.lungfishtree` bundle.

## Lungfish bundle formats

A Lungfish bundle is a folder with a fixed extension. Finder presents it as a single document, yet from the terminal its contents are just ordinary files you can open. Every bundle carries a `manifest.json` at the root that names the bundle, declares its kind and version, and lists the files inside. Most also carry a `provenance/` subdirectory that records the operation, inputs, parameters, and tool versions behind them.

| Bundle type | Extension | Holds |
|---|---|---|
| Reference | `.lungfishref` | A FASTA, its index, optional annotations, attached tracks, variants |
| Assembly | `.lungfishref` (in `Assemblies/`) | Same structure as a reference; distinguished by folder location |
| FASTQ dataset | `.lungfishfastq` | Reads (or a virtual subset), metadata, manifest |
| Primer scheme | `.lungfishprimers` | Primer BED, primer FASTA, manifest |
| MSA | `.lungfishmsa` | Aligned FASTA, FAI, optional metadata |
| Tree | `.lungfishtree` | Newick, optional metadata, optional source MSA |
| 12S reference | `.lungfish12sref` | 12S amplicon reference sequences plus taxonomy metadata |
| MHC reference | `.lungfishmhcref` | MHC amplicon reference sequences plus allele metadata |
| Haplotype definitions | `.lungfishhaplotypedef` | ONT genotyping haplotype definition set |
| CZ-ID taxonomy | `.lungfishtax` | A CZ-ID taxon report normalized into Lungfish's classifier schema |

A few conventions hold across every bundle. The folder uses a fixed extension. A `manifest.json` at the root declares `kind`, `version`, and `files`. An optional `provenance/` subdirectory records how the bundle was produced. Companion indices sit next to their primary files. And the text is UTF-8 with LF line endings, with JSON pretty-printed at a two-space indent.

A minimal manifest:

```json
{
  "kind": "lungfishref",
  "version": 1,
  "name": "MN908947.3",
  "files": {
    "sequence": "reference.fasta",
    "index": "reference.fasta.fai",
    "annotations": "annotations.gff3"
  }
}
```

### `.lungfishref`: reference bundle

Holds a FASTA, its index, and any annotation or track data that should travel with the reference. Created when you import a reference from a file, fetch one from NCBI, or derive one from a GenBank record.

Typical layout:

```text
MN908947.3.lungfishref/
  manifest.json
  provenance/
    bundle.lungfish-provenance.json
    fasta-index.lungfish-provenance.json
  genome/
    reference.fasta
    reference.fasta.fai
  annotations/
    MN908947.3.gff3
    MN908947.3.gff3.lungfish-provenance.json
  tracks/
    SRR36291587.minimap2.bam
    SRR36291587.minimap2.bam.bai
  variants/
    iVar variants.vcf.gz
    iVar variants.vcf.gz.tbi
```

Inspect without unpacking:

```bash
ls MN908947.3.lungfishref/
cat MN908947.3.lungfishref/manifest.json
samtools faidx MN908947.3.lungfishref/genome/reference.fasta MN908947.3:1-100
```

### `.lungfishprimers`: primer scheme bundle

Pairs primer coordinates (BED) with primer sequences (FASTA) and a manifest that describes the scheme.

```text
QIASeqDIRECT-SARS2.lungfishprimers/
  manifest.json
  primers.bed
  primers.fasta  # optional
  PROVENANCE.md
```

The BED file lists each primer with chromosome, start, end, name, pool, and strand columns:

```text
MN908947.3	30	54	SARS-CoV-2_1_LEFT	1	+
MN908947.3	385	410	SARS-CoV-2_1_RIGHT	1	-
```

The current release ships the `QIASeqDIRECT-SARS2` built-in scheme. Import ARTIC, midnight, vendor, or lab schemes through `File > Import Center > Primer Scheme`, and the resulting `.lungfishprimers` bundle lands in the project's `Primer Schemes/` folder, ready for the Primer Trim dialog. See [Primer Scheme Bundles](primer-schemes.md#appendix-primer-schemes).

### `.lungfishfastq`: FASTQ dataset bundle

Wraps imported reads, or a virtual subset of them, together with sample metadata and a manifest. This is the central read container for the import and 12S workflows. Created when you import FASTQ files, or derived when you subset, trim, or demultiplex an existing dataset.

Virtual bundles (subset, trim, demux) keep only a small `preview.fastq` on disk and rebuild the full reads on demand. Run `lungfish fastq materialize <bundle> -o <path>` to write the full FASTQ out. Per-bundle PHA4GE-aligned metadata lives in `metadata.csv` inside the bundle, and you manage it with `lungfish metadata`.

### `.lungfish12sref`: 12S amplicon reference bundle

Holds 12S amplicon reference sequences and their taxonomy metadata for the 12S metabarcoding workflow. Produced by `lungfish fastq 12s-reference-bundle`.

### `.lungfishmhcref`: MHC amplicon reference bundle

Holds MHC amplicon reference sequences and allele metadata for ONT genotyping. Produced by `lungfish fastq mhc-reference-bundle`, and consumed by the `haplotypes` command when building haplotype definition sets.

### `.lungfishhaplotypedef`: haplotype definition bundle

Holds an ONT genotyping haplotype definition set. Managed with the `lungfish haplotypes` command. Its definitions are sourced from a project's `.lungfishmhcref` bundles and consumed by the ONT genotyping workflow.

### `.lungfishtax`: CZ-ID taxonomy bundle

Stores a CZ-ID taxon report, normalized into Lungfish's classifier-result schema so the taxonomy viewport can render it. Only the CZ-ID import path produces this bundle (`lungfish cz-id import` or `File > Import Center > CZ-ID`). It is not the storage format for Kraken2, EsViritu, TaxTriage, or NAO-MGS results, which the taxonomy viewport reads from their own result directories and SQLite databases. The manifest records the imported sample and the source report.

### `.lungfishmsa`: multiple sequence alignment bundle

Wraps a multiple sequence alignment in FASTA form together with metadata about how it was produced.

```text
spike-isolates.lungfishmsa/
  manifest.json
  provenance/
  alignment.fasta
  alignment.fasta.fai
  metadata.tsv
```

The `alignment.fasta` is a standard aligned FASTA: every record is the same length, and gaps are written as `-`. The optional `metadata.tsv` carries per-sample columns (collection date, lineage, origin) that the MSA viewport can color or sort by. Provenance records which aligner ran (MAFFT, MUSCLE, Nextclade) and with what parameters.

### `.lungfishtree`: phylogenetic tree bundle

Wraps a Newick tree with optional metadata and the alignment that produced it.

```text
spike-isolates.lungfishtree/
  manifest.json
  provenance/
  tree.nwk
  metadata.tsv
  alignment.fasta
```

The `tree.nwk` is the canonical Newick file. `metadata.tsv` shares the same per-sample schema as the MSA bundle, so coloring and tip labels stay consistent from one viewport to the next. The optional `alignment.fasta` lets Lungfish jump from a tree node straight back to the underlying alignment column.

Variants get no standalone bundle format. They live inside the reference bundle's `variants/` subdirectory as a bgzipped VCF plus a tabix index, next to their provenance sidecar. To export variants on their own, copy that subdirectory, or run `lungfish provenance export` to produce an audit-ready report.

The `.lungfishflow` workflow bundle, referenced by `lungfish workflow diff`, stores a saved Lungfish workflow graph (its nodes, parameters, and connections) as JSON. It is a workflow definition, not a data bundle, so the standard sequence tools never inspect it.

## Manifest schema

Every manifest declares at minimum:

```json
{
  "kind": "lungfishref",
  "version": 1,
  "name": "human-readable label",
  "created": "2026-05-09T14:32:00Z",
  "files": { "role": "relative/path" }
}
```

The fields beyond that depend on `kind`, and every manifest uses snake_case keys. A reference manifest adds a `genome` block with the assembly accession and length. A primer manifest adds `primer_count` and `amplicon_count` (see [Primer Scheme Bundles](primer-schemes.md#appendix-primer-schemes) for the full primer manifest). The per-kind fields described here are painted in broad strokes and may differ in detail from what is on disk. The manifest itself is always the authority. MSA and tree manifests carry the aligner or inference method plus a sample count. The CZ-ID `.lungfishtax` manifest records the imported sample and source report.

## Provenance schema

Provenance sidecars share a common shape:

```json
{
  "workflow": "variants.call.ivar",
  "version": "0.5.0-alpha11",
  "command": "ivar variants -p variants -q 20 -t 0.05 -m 10 -r ref.fasta -g annotations.gff3",
  "inputs": [
    {"path": "alignments/trimmed.bam", "sha256": "...", "bytes": 16742391, "role": "alignment"}
  ],
  "outputs": [
    {"path": "variants/iVar.vcf.gz", "sha256": "...", "bytes": 4218}
  ],
  "runtime": {
    "host": "tarpon.local",
    "os": "macOS 26.1",
    "arch": "arm64",
    "wall_time_seconds": 11.3,
    "exit_status": 0
  },
  "tool": {
    "name": "ivar",
    "version": "1.4.4",
    "plugin_pack": "variant-calling",
    "plugin_pack_version": "0.3.2"
  },
  "steps": [
    {"command": "samtools mpileup -aa -A -d 600000 -B -Q 20 ref.fasta trimmed.bam", "exit_status": 0},
    {"command": "ivar variants ...", "exit_status": 0}
  ]
}
```

The `inputs[]` and `outputs[]` arrays carry a SHA-256 checksum and a byte size for every file. The `steps[]` array breaks a multi-process pipeline (such as `samtools mpileup | ivar variants`) into one entry per process.

## Sharing bundles

Bundles are folders. Compress to share:

```bash
zip -r MN908947.3.lungfishref.zip MN908947.3.lungfishref
```

The recipient unzips it and drops the bundle into a Lungfish project. macOS Finder treats the folder as a single document, so dragging it into Mail or Messages attaches the zipped bundle with no extra steps.

For team workflows, keep bundles in a Git repository (reach for Git LFS for the binaries inside) or in a shared object store. The manifest and provenance files diff cleanly as plain text.

## Inspecting bundles from the terminal

Because a bundle is just a folder, every standard CLI tool works on it without any unpacking:

```bash
samtools faidx ref.lungfishref/genome/reference.fasta MN908947.3:1-100
bcftools view ref.lungfishref/variants/iVar\ variants.vcf.gz
bedtools intersect -a primers.lungfishprimers/primers.bed -b regions.bed
jq . any.lungfishref/manifest.json
```

## Next

See [CLI Reference](cli-reference.md) for the commands that read and write each format. See [Power User Notes](power-user-notes.md) for the canonical tool flags Lungfish wraps, including iVar's mpileup flags and LoFreq's indelqual step.

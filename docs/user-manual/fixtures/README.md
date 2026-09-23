# Fixtures

Real-world, provenance-tracked data used by chapters and tests. Fixtures are
docs-only. They are never imported from app unit tests, and they are never
modified in place by the agents.

## Size discipline

Per-file cap is 10 MB. Per-fixture-set cap is 50 MB. Files larger than these
caps ship a `fetch.sh` that pulls from a pinned NCBI or ENA URL and caches
locally.

`hg002-chr20/` and `hg002-long-reads/` exceed the per-fixture-set cap (18 MB
and 14 MB) and no test reads them, so they live in the pinned manual-media
repo instead of here. Run `docs/user-manual/build/scripts/fetch-media.sh` to
fetch them (see `docs/user-manual/media.lock`); the script places them back
at these same relative paths.

## Required metadata

Every fixture set has a `README.md` that records source (accession, DOI, or
URL), license (must permit redistribution in this repo), a citation block in
BibTeX or equivalent format that chapters can include, total and per-file
size, and notes on internal consistency such as whether reads align to the
included reference and whether variants were called from those reads.

## Read file naming

Paired FASTQ fixtures use `_R1` and `_R2` (underscore, not a dot) because
those are the suffixes the app's Import Center and CLI importer pair reads
on, alongside `_R1_001`/`_R2_001` and `_1`/`_2`. A dot-delimited mate suffix
is not recognised and never pairs, so a reader who drops dot-named files on
the Import Center gets two unpaired singles instead of one bundle.

## Example data tiers

Chapters choose fixtures from this ordered list unless a specific reason
pushes them elsewhere (deviations require one sentence of justification in
the fixture README).

1. **Human.** Public-domain Genome in a Bottle HG002 data sliced to small
   regions, the human mitochondrial genome and reads, and a human gene
   GenBank record.
2. **Rhesus macaque.** The lab's own MiSeq amplicon genotyping project, kept
   outside the repo as a demo asset under `~/Desktop/lge-docs`. A
   genotyping-only example, with a haplotyping placeholder.
3. **Primate comparative.** Mitochondrial genomes of human, chimpanzee,
   gorilla, rhesus, and cynomolgus macaque, for the alignment and tree
   chapters.
4. **Viral.** Only where the feature is viral by design. Viral Recon,
   Freyja, EsViritu, NVD, and the classification chapters keep SARS-CoV-2
   or metagenomic data.

## Sets

`hg002-chr20/` is the human tier's mapping and variant-calling fixture. It
supports the mapping, alignment-reading, variant-calling, and
variant-browser chapters with a 500 kb GRCh38 chromosome 20 slice, matching
HG002 Illumina reads, and the GIAB benchmark VCF over that slice.

`human-mito/` is the human tier's assembly fixture. It pairs the rCRS human
mitochondrial reference with HG002 reads sliced to chrM, and supports the
assembly chapters with a real 16.5 kb genome that assembles in seconds. It
also stands as the human entry in the primate comparative set alongside
`primate-mito/`.

`hg002-long-reads/` is the human tier's long-read fixture. It supports the
ONT-run, nanopore variant-calling, and long-read assembly chapters with
HG002 ONT and HiFi reads sliced to chrM against the same rCRS reference as
`human-mito/`, plus a minimal ONT run-folder layout under `ont-run/` that
the app's ONT import recognizes.

`hbb-gene/` is the human tier's annotated-record fixture. It supports the
sequence-viewing, annotation, extraction, and translation chapters with the
RefSeqGene record for the human beta-globin locus, including the sickle
cell disease worked example.

`primate-mito/` is the primate comparative fixture. It supports the
alignment chapter as unaligned input and the tree chapter as aligned input,
with five primate mitochondrial reference genomes (human, chimpanzee,
gorilla, rhesus macaque, cynomolgus macaque).

`primate-12s/` is a constructed teaching fixture cut from the two above it. It
supports the 12S amplicon metabarcoding chapter with a five-species primate 12S
reference sliced out of `primate-mito/`'s genomes and a human 12S amplicon read
set selected out of `human-mito/`'s HG002 chrM reads. It is not a published 12S
dataset, and its README says so and explains the trade-off. Deviating from the
tier list is not at issue here because the fixture stays inside the human and
primate comparative tiers it is built from.

`demo-assets/` is a README pointing at the rhesus macaque tier's demo
asset, the lab's own 30-sample MiSeq amplicon genotyping project. The
project is too large to commit, so it stays outside the repo under
`~/Desktop/lge-docs` and capture recipes reference it by path. It supports
the genotyping chapters as a genotyping-only example, with the
haplotype-analysis section marked as a labeled placeholder.

`nvd-demo/` supports the NVD import chapter, viral by design, with a
minimal NVD BLAST results directory shaped exactly as the CLI's
`import nvd` command expects.

`demo-project/` holds the build script for the manual's demo project. The
project draws on the human, primate comparative, and viral fixtures
together (chr20 mapping and variants, the chrM assembly, the primate MSA
and tree, an NVD import, and a Kraken 2 and Viral Recon run over the
SARS-CoV-2 fixture reads) so every chapter's screenshots come from one
running project.

`sarscov2-srr36291587/` and `sarscov2-clinical/` are viral by design, used
by the Viral Recon, Freyja, EsViritu, classification, and NVD chapters.
`sarscov2-srr36291587/` is the current pilot fixture, supporting chapter
`04-variants/01-reads-to-variants` with a public SARS-CoV-2 reference, SRA
reads fetched by the regeneration script, and committed expected iVar and
LoFreq VCF outputs. `sarscov2-clinical/` is a legacy compact clinical-isolate
fixture retained for older VCF-import review notes and future comparison
examples. It is not the active pilot fixture.

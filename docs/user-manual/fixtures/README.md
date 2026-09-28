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
   outside the repo as a demo asset under `~/Desktop/lge-docs`, as the
   "at scale" genotyping-only example. The reproducible genotyping and
   haplotyping example is `mhc-simulated/` (cynomolgus macaque alleles from
   public INSDC records, with a small MCM haplotype definition set).
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

`giab-trio-chr20/` extends `hg002-chr20/` to the GIAB Ashkenazi family. It
holds HG003 (father) and HG004 (mother) Illumina reads over the same 500 kb
chromosome 20 slice, sliced the same way from the same GIAB BAMs, with their
GIAB benchmark VCFs, so the joint-genotyping chapter can genotype a real
three-sample trio. Its four FASTQ files live in the pinned manual-media repo
like `hg002-chr20/`'s; the benchmarks and scripts are committed.

`mhc-simulated/` also carries `mhc-simulated-mcm-teaching.lungfishhaplotypedef.json`,
a three-region MCM haplotype definition set limited to the fixture's three
alleles, each assigned to the haplotype its public INSDC record names. The
MHC Genotyping demo project ships it as a `.lungfishmhcref` bundle so the
genotyping chapters can run deterministic haplotyping.

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
cell disease example.

`primate-mito/` is the primate comparative fixture. It supports the
alignment chapter as unaligned input and the tree chapter as aligned input,
with five primate mitochondrial reference genomes (human, chimpanzee,
gorilla, rhesus macaque, cynomolgus macaque).

`primate-12s/` is a constructed teaching fixture cut from the two above it. It
supports the 12S amplicon metabarcoding chapter with a six-record primate 12S
reference sliced out of `primate-mito/`'s genomes (plus one rhesus record
shared with the Japanese macaque genome committed there), a human 12S amplicon
read set selected out of `human-mito/`'s HG002 chrM reads, and a SIMULATED
human, rhesus, and cynomolgus mixture at known proportions made with wgsim
from the same genomes, because no public 12S run with human and macaque reads
at known proportions exists. It is not a published 12S dataset, and its README
says so, records the simulator, seeds, and commands, and explains the
trade-off. Deviating from the tier list is not at issue here because the
fixture stays inside the human and primate comparative tiers it is built from.

`nrg1-ont-barcoded/` is the human tier's barcoded Oxford Nanopore run. It
supports the ONT-run chapter's import and demultiplexing with six samples of
human NRG1 amplicons from ENA study PRJEB62796, sequenced with the Native
Barcoding Kit 96 V14 and uploaded with the barcodes still on the reads, laid
out as a `fastq_pass` run folder (1,000 reads per barcode in two chunk files,
plus an `unclassified` folder) and as one pooled file for Demultiplex
Barcodes. It exists because the `hg002-long-reads/` run folder has no barcodes
left on its reads, so every demultiplex of it assigns zero.

`demo-assets/` is a README pointing at the rhesus macaque tier's demo
asset, the lab's own 30-sample MiSeq amplicon genotyping project. The
project is too large to commit, so it stays outside the repo under
`~/Desktop/lge-docs` and capture recipes reference it by path. It supports
the genotyping chapters as a genotyping-only example, with the
haplotype-analysis section marked as a labeled placeholder.

`nvd-demo/` supports the NVD import chapter, viral by design, with a
minimal NVD BLAST results directory shaped exactly as the CLI's
`import nvd` command expects.

`demo-project/` holds the build script for the screenshot project, a
contributor tool that readers never build. It draws on the human, primate
comparative, and viral fixtures together (chr20 mapping and variants, the chrM
assembly, the primate MSA and tree, an NVD import, and a Kraken 2 run over the
SARS-CoV-2 fixture reads) so older screenshot recipes can open one running
project. Readers use the demo projects that **Help > Demo Projects…**
downloads, which `scripts/demo-projects/` builds from these same fixtures.

`mhc-primer-design/` supports the Primer Design chapters with public
full-length genomic rhesus macaque MHC class I records from ENA: a panel of 12
Mamu-A1 alleles from 11 lineages, the four Mamu-A1*001 lineage alleles, and an
exclusion set of 18 sequences (eleven other Mamu-A1 lineages plus Mamu-A2, A3,
A4, A6, A7 and B alleles). Deviating from the human tier is the point here,
since the chapters design primers for a macaque gene family.

`naomgs` and `czid` are not in this folder. They live in the app's test
fixtures, `Tests/Fixtures/naomgs/` and `Tests/Fixtures/czid/`, because the
import code's unit tests read them. The manual uses them as display fixtures
for the NAO-MGS and CZ ID import chapters, and the Pathogen Detection demo
project carries copies.

Chapters link each fixture folder at a release tag so the files match the
chapter's numbers. `kraken-protocol-cornea/`, `Tests/Fixtures/naomgs/` and
`Tests/Fixtures/czid/` are present at tag `v2026.9.52`. `mhc-primer-design/`,
`giab-trio-chr20/` and `nrg1-ont-barcoded/` are not in any release tag yet, and
the current `primate-12s/` and `mhc-simulated/` files (the simulated 12S
mixture and the MCM haplotype definition set) are newer than `v2026.9.52`, so
links to those five name `main` until the release that ships this edition of
the manual is tagged.

`sarscov2-srr36291587/` and `sarscov2-clinical/` are viral by design, used
by the Viral Recon, Freyja, EsViritu, classification, and NVD chapters.
`sarscov2-srr36291587/` lives under `Tests/Fixtures/` and is the active
SARS-CoV-2 fixture, supporting the primer trimming, Viral Recon, calling
variants, EsViritu, and Freyja chapters with a public SARS-CoV-2 reference,
SRA reads fetched by the regeneration script, and committed expected iVar and
LoFreq VCF outputs. `sarscov2-clinical/` is a legacy compact clinical-isolate
fixture retained for older VCF-import review notes and future comparison
examples. It is not the active pilot fixture.

`kraken-protocol-cornea/` is a README only. It supports the Kraken 2,
TaxTriage, and BLAST verification chapters with two public human corneal
tissue runs from BioProject PRJNA381365, `SRR12486983` (herpes simplex
keratitis, the pathogen-identification example of the Kraken protocol paper)
and `SRR12486989`. The reads are fetched from the SRA inside the app, and
none are stored here. Its README explains why EsViritu and Freyja keep the
SARS-CoV-2 fixture instead.

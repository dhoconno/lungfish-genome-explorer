# Primate 12S amplicon fixture

A six-record primate 12S reference, a matching human amplicon read set cut
from real HG002 reads, and a SIMULATED three-species mixture at known
proportions, supporting the 12S Amplicon Metabarcoding chapter
(`docs/user-manual/chapters/06-classification/10-twelve-s-metabarcoding.md`).

This is a constructed teaching fixture, not a published 12S dataset. Nothing
here was downloaded from a metabarcoding study. The reference and the HG002
reads come from two fixtures already in this directory, cut down to the 12S
locus so the chapter's figures come from real primate mitochondrial sequence
and real HG002 reads rather than from invented numbers. The mixture is
simulated, and every file that belongs to it carries `SIMULATED` in its name.

## Why it is constructed

There is no published 12S amplicon dataset in this repository, and no public
12S metabarcoding run was found that contains both human and macaque reads at
proportions anyone knows. Ushio and colleagues' MiMammal pond-water study
(2017) detected Japanese macaque and human DNA but published no read
accession. The trade-off is worth stating plainly. A reader following the
chapter gets a run whose numbers they can reproduce exactly and whose truth
is known to the read, but the HG002 read set is a selection out of a
whole-mitochondrion library rather than a real amplicon library off a
sequencer, the mixture never went through a PCR or a sequencer, and the
reference holds six primate records rather than the thousands of vertebrates
a working MIDORI reference would carry.

## How it was constructed

Both source fixtures are read only. Neither is modified.

**The reference.** `build_ref.py` reads
`../primate-mito/primate-mito.fasta`, the five primate mitochondrial genomes.
Human MT-RNR1, the 12S rRNA gene, is `NC_012920.1:648-1601`. The script cuts a
60-base slice from inside that gene, starting at offset 900 of the human
genome, and finds the homologous slice in each of the other four genomes by
anchoring on the conserved 18-base flank at the slice's 5' end. Anchor
identity came out 18 of 18 for human and gorilla, 17 of 18 for chimpanzee, and
16 of 18 for both macaques. All five slices are distinct, so nothing collapsed
during deduplication.

The sixth record is a second rhesus macaque target. It is the first 60-base
window inside the rhesus MiFish-U amplicon, `NC_005943.1:917-976`, that also
occurs verbatim in the Japanese macaque genome `NC_025513.1` (committed here,
16.5 kb) and in none of the other genomes. A deduplicated reference records a
sequence shared by two species once, under one name, with the other species
in the header's `also_matches` field:

```
>Rhesus macaque (Macaca mulatta)|also_matches=Japanese macaque (Macaca fuscata)
```

The matcher reads that field, the export lists Japanese macaque under Other
Potential Matches for the rhesus row, and the viewport's Alternates column is
nonzero for rhesus. The Japanese macaque has no record of its own and no
reads, so it never appears as a species row. It is there so the chapter can
show what a shared sequence looks like.

Sixty bases is short on purpose. The matcher requires flanking read bases on
both sides of the matched target, so a target has to be short enough that a
read can contain it whole and still have bases left over at each end.

Headers are written in the `Common name (Scientific name)` form. The metadata
joiner parses the species out of the FASTA header, so an underscored header
joins nothing and leaves every metadata column empty.

**The HG002 reads.** `make_amplicon.py` reads
`../human-mito/HG002.chrM_R1.fastq.gz`, 9,958 Illumina reads of 250 bases from
the human mitochondrion. It keeps the reads that overlap the human 12S locus,
deciding overlap by an exact 24-base seed shared with `NC_012920.1:648-1601`
in either orientation. 631 of the 9,958 reads are kept, which makes the
selection behave like a 12S amplicon library rather than whole-mitochondrion
shotgun.

**Orientation.** `regenerate.sh` then runs `lungfish-cli fastq orient` over
those 631 reads against the reference. The 12S matcher has no
reverse-complement pass, so reverse-strand reads go unmatched until this step
flips them. 186 of the 631 reads survive orientation (173 against the earlier
five-record reference; the sixth record lets vsearch place 13 more). That drop
is the point of the step and the chapter says so.

**The SIMULATED mixture.** `simulate_mixture.py` cuts the MiFish-U amplicon,
primer site to primer site, out of three genomes: human `NC_012920.1:874-1092`
(219 bases), rhesus macaque `NC_005943.1:832-1043` (212 bases), and cynomolgus
macaque `NC_012670.1:839-1050` (212 bases). Each contains its species' 60-base
target with flanks on both sides, and the rhesus amplicon contains both rhesus
targets. The primer sites are the genome's own bases, not the primer oligos.
The three templates are written to `SIMULATED-12S-mixture.amplicons.fasta`.

It then runs wgsim (Li, samtools project, version 1.24 at build time) once
per template, with the fragment length equal to the template length so that
read 1 is the whole amplicon on one strand or the other, the way an unoriented
merged read set looks. Substitutions only, at 0.2 percent per base, no
mutations and no indels:

```
wgsim -e 0.002 -d 219 -s 0 -N 1400 -1 219 -2 219 -r 0 -R 0 -X 0 -S 12001 human.fa ...
wgsim -e 0.002 -d 212 -s 0 -N 500  -1 212 -2 212 -r 0 -R 0 -X 0 -S 12002 rhesus.fa ...
wgsim -e 0.002 -d 212 -s 0 -N 100  -1 212 -2 212 -r 0 -R 0 -X 0 -S 12003 cynomolgus.fa ...
```

Read 2 of each pair is discarded. The 2,000 read-1 records are shuffled at
seed 12000 and written to `SIMULATED-12S-mixture.fastq.gz`, so the truth is 1,400
human (70 percent), 500 rhesus (25 percent), and 100 cynomolgus (5 percent).
`SIMULATED-12S-mixture.truth.tsv` names the species of every read, and the
read names keep wgsim's form, `<template>_<start>_<end>_<subs:indels:errors on
read 1>_<same for read 2>_<serial>/1`, so the species and the number of
simulated errors are readable from the name itself. wgsim writes one constant
quality character (`<`, Phred 27) for every base, which is the one place the
file does not look like an instrument's output.

`regenerate.sh` orients the mixture the same way as the HG002 reads, into
`SIMULATED-12S-mixture-oriented.fastq.gz`. All 2,000 reads survive, because every
one contains a target.

## Species

| Reference header | Scientific name | NCBI taxid | Source genome | Target |
| --- | --- | --- | --- | --- |
| `Human (Homo sapiens)` | *Homo sapiens* | 9606 | `NC_012920.1` | 901-960 |
| `Chimpanzee (Pan troglodytes)` | *Pan troglodytes* | 9598 | `NC_001643.1` | 323-382 |
| `Western gorilla (Gorilla gorilla)` | *Gorilla gorilla* | 9593 | `NC_011120.1` | 324-383 |
| `Rhesus macaque (Macaca mulatta)` | *Macaca mulatta* | 9544 | `NC_005943.1` | 859-918 |
| `Cynomolgus macaque (Macaca fascicularis)` | *Macaca fascicularis* | 9541 | `NC_012670.1` | 866-925 |
| `Rhesus macaque (Macaca mulatta)\|also_matches=Japanese macaque (Macaca fuscata)` | *Macaca mulatta*, shared with *Macaca fuscata* (9542) | 9544 | `NC_005943.1`, identical in `NC_025513.1` | 917-976 |

Each target is 60 bases. The taxids were taken from NCBI Taxonomy and are
carried in `primate-12s-midori.tsv` with `name_source` set to `NCBI`, which
has a row for all six species so the shared record's alternate joins its
metadata too.

## Read counts

| Stage | Reads |
| --- | --- |
| `../human-mito/HG002.chrM_R1.fastq.gz` (input) | 9,958 |
| `HG002-12S-amplicon.fastq.gz` (overlap the 12S locus) | 631 |
| `HG002-12S-oriented.fastq` (after orientation) | 186 |
| `SIMULATED-12S-mixture.fastq.gz` (wgsim, both strands) | 2,000 |
| `SIMULATED-12S-mixture-oriented.fastq.gz` (after orientation) | 2,000 |

All read files are committed. The chapter uses the amplicon file to show what
an unoriented run looks like, the oriented HG002 file for the single-species
example, and the oriented mixture for the multi-species example.

## Sources, license, and citation

This fixture inherits its sources and its license from the two fixtures it is
cut from. See `../primate-mito/README.md` and `../human-mito/README.md` for
the full source records, the accession verification, and the citation blocks.

The reference genomes are RefSeq organelle records, fetched via NCBI eutils
efetch by `../primate-mito/fetch.sh`. `NC_025513.1` (Macaca fuscata
mitochondrion, complete genome, 16,565 bp) was fetched the same way on
2026-09-27:

`https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=NC_025513.1&rettype=fasta&retmode=text`

The reads are HG002/NA24385 (Ashkenazim son) NIST/GIAB Illumina 2x250bp data,
sliced to `chrM` and downsampled by `../human-mito/fetch.sh`.

Both source sets are US government works and are in the public domain in the
United States, so the cut-down and simulated material here carries no
additional restriction. Check your local jurisdiction if redistributing
outside the U.S.

Cite the underlying resources rather than this fixture. The RefSeq citation is
in `../primate-mito/README.md`. The rCRS and GIAB citations are in
`../human-mito/README.md`. For the simulator:

```bibtex
@misc{li2011wgsim,
  author = {Li, Heng},
  title  = {wgsim: a small tool for simulating sequence reads from a reference genome},
  year   = {2011},
  url    = {https://github.com/lh3/wgsim},
  note   = {Distributed with samtools; version 1.24 used here}
}
```

## Committed files

| File | Size |
| --- | --- |
| `primate-12s-dedup.fasta` | <1 KB (608 bytes) |
| `primate-12s-midori.tsv` | <1 KB (696 bytes) |
| `primate-12s-targets.tsv` | 2 KB |
| `NC_025513.1.fasta` | 17 KB |
| `HG002-12S-amplicon.fastq.gz` | 67 KB |
| `HG002-12S-oriented.fastq` | 98 KB |
| `SIMULATED-12S-mixture.amplicons.fasta` | <1 KB |
| `SIMULATED-12S-mixture.fastq.gz` | 17 KB |
| `SIMULATED-12S-mixture-oriented.fastq.gz` | 16 KB |
| `SIMULATED-12S-mixture.truth.tsv` | 86 KB |
| `build_ref.py`, `make_amplicon.py`, `simulate_mixture.py`, `regenerate.sh` | 16 KB |

Total committed is about 420 KB, far under the 50 MB fixture-set cap, and
every file is far under the 10 MB per-file cap.

The `.lungfish12sref` bundle is deliberately not committed. The workflow
dialog's **Create 12S Reference...** button builds that bundle from the
deduplicated FASTA and the metadata TSV, which is the route the chapter walks
the reader through, so the two loose files are both the smaller form and the
form the procedure actually needs. `lungfish-cli fastq 12s-match` accepts
either the loose FASTA or a bundle at `--reference`.

Provenance sidecars (`*.lungfish-provenance.json`) are written beside the CLI
outputs and are gitignored, matching the sibling fixtures.

## Results

Runs of `lungfish-cli fastq 12s-match` against `primate-12s-dedup.fasta` on
2026-09-27 (Lungfish Preview 2026.9.49 CLI):

| Input | Reads | Exact | Unresolved | Species rows with reads |
| --- | --- | --- | --- | --- |
| `HG002-12S-oriented.fastq` | 186 | 110 (59.1 %) | 76 (40.9 %), 69 clusters | Homo sapiens 110 (100.0 %) |
| the earlier 173-read HG002 file, same reference | 173 | 110 (63.6 %) | 63 (36.4 %), 56 clusters | Homo sapiens 110 (100.0 %) |
| `SIMULATED-12S-mixture-oriented.fastq.gz` | 2,000 | 1,817 (90.9 %) | 183 (9.2 %), 143 clusters | Homo sapiens 1,235 (68.0 %), Macaca mulatta 491 (27.0 %), Macaca fascicularis 91 (5.0 %) |
| `SIMULATED-12S-mixture.fastq.gz` (unoriented) | 2,000 | 935 (46.8 %) | 1,065 (53.3 %), 344 clusters | Homo sapiens 625, Macaca mulatta 260, Macaca fascicularis 50 |

The full numbers, including the per-target counts and the cluster size
histograms, are in the results brief the chapter quotes from.

## Internal consistency

The HG002 result is biologically correct in a way that makes the fixture
self-checking. The reads are human, and the only species that takes any reads
is human. The chimpanzee, gorilla, and macaque targets sit at zero even though
they differ from the human target by only a handful of bases across the
60-base window, which confirms that the matcher is doing exact containment
rather than approximate matching, and that the reference targets really are
distinct from one another. The extra 13 reads of the 186-read file all land
in the unresolved tail, so the exact count stays at 110.

The mixture result matches its truth. Every exact match went to the species
its read was simulated from (the truth table and the read names agree with
the per-target counts), and no read crossed species. The species shares come
out at 68.0, 27.0, and 5.0 percent against a truth of 70, 25, and 5, because
the unresolved reads are the ones whose simulated errors fell inside a
target, and the rhesus amplicon holds two targets, so a rhesus read survives
an error in one of them. 491 of 500 rhesus reads matched (443 on the first
target, 48 on the shared one), 1,235 of 1,400 human reads, and 91 of 100
cynomolgus reads. The unresolved tail is 108 single-read clusters, 30 of two
reads, and 5 of three, all Not Detected by the chimera check, which is what
sequencing error looks like. The unoriented file shows the other failure
mode: its largest unresolved clusters (448, 153, and 32 reads) are the
error-free reverse-strand copies of the three amplicons.

## Regenerating

```bash
LUNGFISH_CLI=/path/to/lungfish-cli WGSIM=/path/to/wgsim \
  bash docs/user-manual/fixtures/primate-12s/regenerate.sh
```

Nothing is fetched from the network. The script rebuilds every committed
artifact from `../primate-mito/primate-mito.fasta`,
`../human-mito/HG002.chrM_R1.fastq.gz`, and `NC_025513.1.fasta`, so both
sibling fixtures must be present first. It needs `python3` (standard library
only), `wgsim`, and a `lungfish-cli` with the managed vsearch environment
installed for the two orientation steps. `LUNGFISH_CLI` defaults to
`.build/debug/lungfish-cli` and `WGSIM` to `wgsim` on the PATH.

Regeneration was verified on 2026-09-27 with the Lungfish Preview 2026.9.49
CLI and wgsim 1.24. The gzip output is written with a zeroed timestamp so even
the compressed read file is stable across runs.

## A note on `--compress`

`regenerate.sh` writes the oriented reads to plain `.fastq` names rather than
asking for `--compress` and a `.gz` name. `lungfish-cli fastq orient` writes
plain text regardless of that flag, so requesting compression produces a file
whose name claims gzip and whose contents are not. Writing the plain name
keeps the committed file honest.

# NRG1 barcoded Oxford Nanopore run fixture

A small, real, barcoded Oxford Nanopore run folder whose reads still carry
their native barcodes, so that a demultiplex in Lungfish Genome Explorer
assigns reads. Supports the Oxford Nanopore Runs chapter
(`docs/user-manual/chapters/03-reads/07-ont-runs.md`): the run-folder import,
the `unclassified` folder, and Demultiplex Barcodes.

The reads are human (tier 1). They are NRG1 (neuregulin 1) transcript
amplicons from six samples, three cell types at two amplicon lengths,
sequenced on a GridION with Oxford Nanopore's Native Barcoding Kit 96 V14
(SQK-NBD114-96). MinKNOW sorted the reads into their barcode folders during
the run, and the submitters uploaded them without trimming, so every read
still begins with the sequencing adapter, the barcode, and its flanks. That
is what the `hg002-long-reads` ONT fixture lacks. Its reads were cut from an
aligned BAM long after their adapters and barcodes were removed, which is why
every demultiplex on it assigns zero reads.

## Layout

```
ont-run/fastq_pass/barcode85/nrg1_pass_barcode85_0.fastq.gz   500 reads
ont-run/fastq_pass/barcode85/nrg1_pass_barcode85_1.fastq.gz   500 reads
ont-run/fastq_pass/barcode86/...                              1,000 reads in 2 files
ont-run/fastq_pass/barcode87/...                              1,000 reads in 2 files
ont-run/fastq_pass/barcode89/...                              1,000 reads in 2 files
ont-run/fastq_pass/barcode90/...                              1,000 reads in 2 files
ont-run/fastq_pass/barcode91/...                              1,000 reads in 2 files
ont-run/fastq_pass/unclassified/nrg1_pass_unclassified_0.fastq.gz   204 reads
pooled/nrg1-pooled.fastq.gz                                   400 of each barcode's reads, 2,400 in all, shuffled
nrg1-barcodes.csv                                             custom barcode definition, six barcodes with sample names
```

`nrg1` stands where MinKNOW writes the flow cell id. Each barcode folder holds
two numbered chunk files, the way MinKNOW writes a run in pieces, so the
importer's concatenation has something to do. The `unclassified` folder holds
reads in which the barcode could not be found by sequence (see How it was
built), which stand in for the reads a real run leaves unclassified. The
importer skips that folder by default and `--include-unclassified` brings it
in.

`pooled/nrg1-pooled.fastq.gz` is the input for Demultiplex Barcodes. It holds
400 reads from each of the six barcode folders, 2,400 in all, shuffled, so a
demultiplex of it can be checked against the folders, and every read name
begins with its ENA run accession, which names its true barcode (table
below). It is capped at 400 per barcode so the file stays under the
repository's 500 KB limit for files under `docs/`.

## Samples and barcodes

| ENA run | Barcode folder | Barcode (SQK-NBD114-96) | ENA sample title | Reads in run | Reads carrying the barcode | Mean length of the 1,000 kept |
| --- | --- | --- | --- | --- | --- | --- |
| ERR12259924 | barcode85 | NB85 `AACGGAGGAGTTAGTTGGATGATC` | NRG1Amplicon_IPSCProgenitors_long | 35,000 | 28,289 (80.8 %) | 1,735 bases |
| ERR12259925 | barcode86 | NB86 `AGGTGATCCCAACAAGCGTAAGTA` | NRG1Amplicon_IPSCMacrophages_long | 35,000 | 29,646 (84.7 %) | 1,189 bases |
| ERR12259926 | barcode87 | NB87 `TACATGCTCCTGTTGTTAGGGAGG` | NRG1Amplicon_Monocytes_long | 35,000 | 30,657 (87.6 %) | 1,544 bases |
| ERR12259928 | barcode89 | NB89 `ACAGCATCAATGTTTGGCTAGTTG` | NRG1Amplicon_IPSCProgenitors_short | 35,000 | 31,288 (89.4 %) | 606 bases |
| ERR12259929 | barcode90 | NB90 `GATGTAGAGGGTACGGTTTGAGGC` | NRG1Amplicon_IPSCMacrophages_short | 35,000 | 24,115 (68.9 %) | 606 bases |
| ERR12259930 | barcode91 | NB91 `GGCTCCATAGGAACTCACGCTACT` | NRG1Amplicon_Monocytes_short | 35,000 | 28,757 (82.2 %) | 605 bases |

"Reads carrying the barcode" is this fixture's own check, described below,
not MinKNOW's. The barcode sequences are Oxford Nanopore's published NB85 to
NB91 and match the entries LGE ships for its ONT Native Barcoding V14
(SQK-NBD114-96, 96) kit. `nrg1-barcodes.csv` lists the same six sequences with
a sample name each, in the `id,sequence,secondary_sequence,sample_name` form
LGE's custom barcode definition takes.

## Where the barcode sits in a read

Every read that carries a barcode shows the same arrangement at its 5' end,
here read ERR12259928.1 with the barcode in brackets:

```
CATACTTCGTTCAGTTACATGCTATTGCTGGTGCTG[ACAGCATCAATGTTTGGCTAGTTG]TTAACCTACTTGCC...
 ^ Y-adapter                   ^ AGGTGCTG  ^ NB89, forward     ^ TTAACCTT  ^ insert
```

The Y-adapter comes first, then the flank `AGGTGCTG`, then the barcode in the
orientation Oxford Nanopore publishes it, then the flank `TTAACCTT`, then the
insert. In 1,000 reads of ERR12259928 the barcode began 30 to 45 bases in on
768 reads and its reverse complement sat within 10 to 20 bases of the 3' end
on 487 reads, 366 reads carrying both. This is the arrangement Oxford
Nanopore's own basecaller classified these runs by, and it is the reverse
complement of the arrangement LGE's cutadapt route expects
(`AAGGTTAA` + barcode + `CAGCACCT`), which is why the built-in kit assigns
almost nothing on these reads while the Exact Bare Barcode engine, which
searches the whole read in both orientations, assigns most of them. The
results brief for this fixture records both runs.

## How it was built

`fetch.sh` downloads the six ENA FASTQ files (31 MB together) into the
gitignored `source/` folder and checks each against the SHA-256 recorded when
the fixture was built. `subsample.py` then, at seed 2026:

1. Scans every read of each run for its own barcode, allowing up to 3
   mismatches within the first or last 120 bases on either strand.
2. Draws 1,000 reads that carry the barcode and writes them as two 500-read
   chunk files under `ont-run/fastq_pass/barcodeNN/`.
3. Draws 34 reads per run in which the barcode was not found and writes the
   204 of them under `ont-run/fastq_pass/unclassified/`. MinKNOW had put these
   reads in their barcode folders by its own scoring; here they play the part
   of a run's unclassified reads, and the README says so rather than
   pretending MinKNOW wrote the folder.
4. Writes the first 400 kept reads of each barcode, 2,400 in all, shuffled, to
   `pooled/nrg1-pooled.fastq.gz`.

Gzip members carry a zeroed timestamp so a rerun reproduces every file byte
for byte. Rebuild with:

```bash
bash docs/user-manual/fixtures/nrg1-ont-barcoded/fetch.sh
python3 docs/user-manual/fixtures/nrg1-ont-barcoded/subsample.py
```

Only `python3` (standard library) and `curl` are needed.

## Sources, license, and citation

ENA study PRJEB62796 (secondary ERP147915), "Discovery of NRG1 isoforms",
The University of Melbourne, first public 2023-09-01,
`https://www.ebi.ac.uk/ena/browser/view/PRJEB62796`. The submitters uploaded
unaligned BAM files of basecalled reads (`submitted_format` BAM;BAI); the
FASTQ files here are ENA's conversions of them, fetched from the `fastq_ftp`
paths recorded in `fetch.sh` and verified on 2026-09-27.

Data in ENA is available without restriction under the INSDC data-sharing
policy. Cite the study and its preprint:

```bibtex
@article{berrocalrubio2024nrg1vii,
  author  = {Berrocal-Rubio, Miguel {\'A}ngel and Pawer, Yair David Joseph
             and Dinevska, Marija and De Paoli-Iseppi, Ricardo
             and Widodo, Samuel S. and Gleeson, Josie and Rajab, Nadia
             and De Nardo, Will and Hallab, Jeannette and Li, Anran
             and Mantamadiotis, Theo and Clark, Michael B.
             and Wells, Christine A.},
  title   = {Discovery of {NRG1-VII}: a novel myeloid-derived class of
             {NRG1} isoforms},
  journal = {bioRxiv},
  year    = {2024},
  doi     = {10.1101/2023.02.02.525781},
  note    = {Reads: ENA PRJEB62796, runs ERR12259924, ERR12259925,
             ERR12259926, ERR12259928, ERR12259929, ERR12259930}
}
```

## Committed files

| File | Size |
| --- | --- |
| `ont-run/fastq_pass/barcode85/` (2 files) | 250 KB |
| `ont-run/fastq_pass/barcode86/` (2 files) | 189 KB |
| `ont-run/fastq_pass/barcode87/` (2 files) | 223 KB |
| `ont-run/fastq_pass/barcode89/` (2 files) | 89 KB |
| `ont-run/fastq_pass/barcode90/` (2 files) | 89 KB |
| `ont-run/fastq_pass/barcode91/` (2 files) | 90 KB |
| `ont-run/fastq_pass/unclassified/` (1 file) | 40 KB |
| `pooled/nrg1-pooled.fastq.gz` | 436 KB |
| `nrg1-barcodes.csv`, `fetch.sh`, `subsample.py`, `README.md` | under 20 KB |

Total committed is about 1.4 MB, far under the 50 MB fixture-set cap, and every
file is under the repository's 500 KB limit for files under `docs/`. The 31 MB
of source runs are not committed and are fetched on demand.

## Internal consistency

`lungfish-cli fastq import-ont ont-run/fastq_pass` reports 6 barcodes and 6,000
reads (1,000 per barcode), and 7 barcodes and 6,204 reads with
`--include-unclassified`. Demultiplexing `pooled/nrg1-pooled.fastq.gz` with
`nrg1-barcodes.csv` and the Exact Bare Barcode engine assigned 1,921 of the
2,400 reads (80.0 percent), every one to the barcode its run accession names,
with 479 left unassigned because the barcode carries at least one basecalling
error at both ends of those reads. Per sample: NB85 339, NB86 332, NB87 305,
NB89 348, NB90 286, NB91 311. All 2,400 reads are accounted for. (On the full
6,000 kept reads pooled the same way, 4,733 were assigned, one of them wrongly.)
The same pool through the built-in ONT Native Barcoding V14 (SQK-NBD114-96,
96) kit on the cutadapt engine assigned 5 reads, for the reason given under
Where the barcode sits in a read.

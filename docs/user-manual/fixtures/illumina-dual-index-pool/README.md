# Illumina dual-index pool fixture

A small pool of human reads whose names carry the two indexes of a dual-indexed Illumina library, as bcl2fastq and BCL Convert write them (`1:N:0:<i7>+<i5>`). Chapter 03-reads/09 uses it to split a pool by the indexes in its read names (the Read Names engine and the Demux tab) and to find the barcodes of a pool (Detect Barcodes). The pool is constructed. Four library names share the reads of one person and each pair of reads goes to one of them at random, so the libraries differ in their index pair and in nothing else. `truth.tsv` records the true library of every pair, so a split can be checked read by read.

| File | What it holds | Bytes |
| --- | --- | --- |
| `reads_R1.fastq.gz`, `reads_R2.fastq.gz` | 9,958 read pairs of 65 to 250 bases (mean 248). Read 1 names end in `1:N:0:<i7>+<i5>` and read 2 names in `2:N:0:<i7>+<i5>`, for example `@D00360:94:H2YT5BCXX:1:1101:1554:80041 1:N:0:TCCGGAGA+ATAGAGGC` | 1,592,155 and 1,764,397 |
| `truth.tsv` | One row per pair, in file order. The columns are `read` (the name before the space), `true_sample`, `i7_in_name`, `i5_in_name` and `index_status` (`exact`, `one_mismatch`, `two_mismatch` or `hopped`) | 734,202 |
| `kit.csv` | The four index pairs with their sample names, as a custom kit for `fastq demultiplex --kit` (columns `id`, `sequence`, `secondary_sequence`, `sample_name`) | 199 |
| `reference.fasta` | NC_012920.1, the revised Cambridge Reference Sequence of the human mitochondrion, 16,569 bases. It is the file `human-mito/NC_012920.1.fasta` | 16,864 |
| `make.py` | Builds the two read files, `truth.tsv` and `kit.csv` from the reads of `human-mito/` | 5,706 |

## The four libraries

The index pairs are the TruSeq HT Dual pairs D701-D501 to D704-D504 of the built-in kit `truseq-ht-dual`, i7 first, each i5 as the kit lists it.

| Sample | Pair | i7 | i5 | Pairs | Exact | One mismatch | Two mismatches | Hopped i5 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| HG002-lib1 | D701-D501 | ATTACTCG | TATAGCCT | 3,600 | 3,477 | 82 | 29 | 12 |
| HG002-lib2 | D702-D502 | TCCGGAGA | ATAGAGGC | 2,800 | 2,700 | 64 | 25 | 11 |
| HG002-lib3 | D703-D503 | CGCTCATT | CCTATCCT | 2,200 | 2,116 | 55 | 23 | 6 |
| HG002-lib4 | D704-D504 | GAGATTCC | GGCTCTGA | 1,358 | 1,305 | 39 | 13 | 1 |

A one-mismatch pair has one base of one index changed, and 20 of the 240 have a no-call `N` in that place. A two-mismatch pair has two bases of one index changed. A hopped pair keeps its library's i7 and carries the i5 of another library, which is what index hopping looks like in a name.

## Source

The reads are the HG002 (NA24385) chrM read pairs of the fixture `human-mito/`, which cut them from the Genome in a Bottle (GIAB) 2 x 250 Illumina novoalign BAM of the National Institute of Standards and Technology (`https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x250bps/novoalign_bams/HG002.GRCh38.2x250.bam`). The fixture `human-mito/` holds how they were cut. The read names are the sequencer's own and come from five flowcells of the GIAB run (`HISEQ1:93:H2YHMBCXX` 2,243 pairs, `D00360:94:H2YT5BCXX` 2,206, `D00360:97:H2YVMBCXX` 2,023, `D00360:96:H2YLYBCXX` 1,823 and `D00360:95:H2YWMBCXX` 1,663). A real pool holds one flowcell, so a reader who looks past the index sees five. Only the index part of each name is new.

`make.py` shuffles the pairs with a fixed seed (2026), gives each pair a library and an index status, and writes the names, `truth.tsv` and `kit.csv`.

```sh
python3 -I make.py <folder with HG002.chrM_R1.fastq.gz and HG002.chrM_R2.fastq.gz> <new output folder>
```

It uses the standard library only. It writes the two read files with no file name and time 0 in the gzip header, so a rebuild is byte equal. A rebuild on 2026-11-21 from `human-mito/` was byte equal for `reads_R1.fastq.gz`, `reads_R2.fastq.gz`, `truth.tsv` and `kit.csv`. The output folder gets no `reference.fasta`, which is a copy of the file in `human-mito/`.

## License

The reads and the reference are public domain. NIST and GIAB distribute their reference materials as U.S. government work with no usage restriction, and the reference is an NCBI RefSeq record (`NC_012920.1`), as `human-mito/README.md` says. Check your local jurisdiction if you redistribute outside the U.S. The read names are the original names with the index added, and the reads are not changed.

`make.py`, `truth.tsv` and `kit.csv` were written by Lungfish Genome Explorer (LGE) and are under LGE's MIT licence.

## Citation

```bibtex
@article{andrews1999reanalysis,
  author  = {Andrews, Richard M. and Kubacka, Iwona and Chinnery, Patrick F. and Lightowlers, Robert N. and Turnbull, Douglass M. and Howell, Neil},
  title   = {Reanalysis and revision of the Cambridge reference sequence for human mitochondrial DNA},
  journal = {Nature Genetics},
  year    = {1999},
  volume  = {23},
  pages   = {147},
  doi     = {10.1038/13779}
}

@article{zook2019giab,
  author  = {Zook, Justin M. and McDaniel, Jennifer and Olson, Nathan D. and Wagner, Justin and Parikh, Hemang and Heaton, Haynes and Irvine, Sean A. and Trigg, Len and Truty, Rebecca and McLean, Cory Y. and De La Vega, Francisco M. and Xiao, Chunlin and Sherry, Stephen and Salit, Marc},
  title   = {An open resource for accurately benchmarking small variant and reference calls},
  journal = {Nature Biotechnology},
  year    = {2019},
  volume  = {37},
  pages   = {561--566},
  doi     = {10.1038/s41587-019-0074-6}
}
```

## Size

The set is 4,113,523 bytes (3.9 MB) in 6 files. The largest file is `reads_R2.fastq.gz` at 1,764,397 bytes, so no file nears the 10 MB cap and the set is far under the 50 MB cap. `SHA256SUMS` lists the SHA-256 and the path of every file but itself and this README.

## Internal consistency

Both mates of a pair carry the same index pair, and the 9,958 names are all different. `truth.tsv` has one row for each pair, and its `i7_in_name` and `i5_in_name` are the indexes as written in the names, so a row with a changed base shows the change. Each pair is in the file once, and the four libraries hold 3,600, 2,800, 2,200 and 1,358 pairs.

The reads are from one person and one organelle, and `reference.fasta` is the mitochondrial sequence they were mapped to. The libraries are labels only. A variant call on each library would show the same genome, so read no biology from a difference between libraries. `make.py` changes only the names, so the bases are the original reads and only the names carry the indexes.

## What the runs showed

These commands ran in a scratch project with the `lungfish-cli` of Lungfish Preview 2026.11.15, and each ended with exit 0. Create the project folder first (`mkdir demo.lungfish`), since the commands do not create it, and run them in a scratch folder that holds a copy of these files.

```sh
lungfish-cli import fastq reads_R1.fastq.gz reads_R2.fastq.gz --project demo.lungfish
lungfish-cli fastq scout demo.lungfish/Imports/reads.lungfishfastq --kit truseq-ht-dual --output scout.json
lungfish-cli fastq demultiplex demo.lungfish/Imports/reads.lungfishfastq --kit kit.csv --engine header-index -o demux-custom
lungfish-cli fastq demultiplex demo.lungfish/Imports/reads.lungfishfastq --kit truseq-ht-dual --engine header-index -o demux-builtin
```

The import pairs the two files as one bundle, `reads.lungfishfastq`, of 19,916 reads (9,958 pairs).

Detect Barcodes (`fastq scout`) scanned the first 10,000 reads of the bundle with the kit `truseq-ht-dual` and read the indexes from the names (`countSource` is `read-name-index`). It assigned 9,924 reads (99.2 percent) and accepted 7 barcode pairs. The four true pairs hold 3,588 reads (35.88 percent), 2,736 (27.36), 2,216 (22.16) and 1,358 (13.58). Three index-hopped combinations were accepted too, D701-D502 with 6 reads, D702-D503 with 6 and D703-D501 with 4, which are 0.04 to 0.06 percent each. Five more combinations with 2 reads each were rejected. So read the percentages, and expect a few accepted pairs that no library owns.

The split with `kit.csv` (four pairs, header-index engine) read 19,916 reads. It assigned 19,676 (98.8 percent) and left 240 unassigned. The four bundles hold 7,118, 5,528, 4,342 and 2,688 reads, which are 3,559, 2,764, 2,171 and 1,344 pairs, and the log counts 9,838 mate pairs with both mates called alike. Tallied against `truth.tsv`, every read of each bundle belongs to the library that bundle is named for, so no read was put in a wrong library. The bundles hold the exact pairs and the one-mismatch pairs and no others. The 240 unassigned reads (120 pairs) are the 30 hopped pairs (60 reads) and the 90 two-mismatch pairs (180 reads).

The split with the built-in kit `truseq-ht-dual` (96 index pairs) gave the same four bundles with the same reads. It sent the 30 hopped pairs to ten more bundles named for their wrong combination (D701-D502 with 12 reads, D702-D503 with 10, D701-D503, D701-D504, D702-D501, D702-D504 and D703-D504 with 6 each, D703-D501 with 4, and D703-D502 and D704-D501 with 2 each), and it left only the 180 reads of the two-mismatch pairs unassigned. A hopped read is in a bundle named for a pair it does not belong to, so a reader who splits with the whole kit finds small extra bundles and drops them.

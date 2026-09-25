# Kraken protocol corneal samples fixture

Two public human corneal tissue runs from the NCBI Sequence Read Archive,
used as the worked example in the Kraken 2, TaxTriage, and BLAST
verification chapters. No reads are stored in this repository. Fetch them
from the SRA as described below.

## Source

BioProject `PRJNA381365`, "Diagnosing corneal infections in formalin fixed
specimens using next generation sequencing". Human corneal tissue,
sequenced on an Illumina NextSeq 550, library strategy WGS, paired-end,
up to 76 bases per read (trimmed reads run down to 35 bases). Checked
against the ENA run records.

| Run | Sample | Organism recorded | Read pairs | Used by |
|---|---|---|---|---|
| `SRR12486983` | Cornea-Case16 | Human alphaherpesvirus 1 (HSV-1, herpes simplex keratitis) | 4,819,760 (9,639,520 reads, 721.5 Mb) | Kraken 2, TaxTriage, BLAST |
| `SRR12486989` | Cornea-Case02 | Streptococcus agalactiae | 5,440,369 | TaxTriage (second sample of the batch) |

`SRR12486983` is the pathogen-identification example in the Kraken
software suite protocol paper, whose companion notebooks are at
https://github.com/martin-steinegger/kraken-protocol.

## Why this fixture deviates from the tier list

The classification chapters need a real clinical metagenome with a known
pathogen, and the Kraken authors' own tutorial sample gives readers a
published reference point. The sample is human tissue, so it stays close to
the human tier.

EsViritu and Freyja keep `sarscov2-srr36291587`. EsViritu 1.3.3 keeps only
read alignments at least 100 bases long (`alignLength >= 100` in its
`minimap2_f` filter), so these 76-base reads give it no detections. Freyja
names SARS-CoV-2 lineages and needs SARS-CoV-2 reads.

## Fetching in LGE

In Lungfish Genome Explorer (LGE), download each run through the SRA route,
as the manual chapter `03-reads/02-downloading-from-sra.md` describes. Each
run imports as one interleaved paired bundle, `Imports/SRR12486983.lungfishfastq`
and `Imports/SRR12486989.lungfishfastq`.

Command-line equivalent, with a project created in the window:

```bash
lungfish-cli fetch sra download SRR12486983 --output-dir ./SRR12486983
lungfish-cli import fastq ./SRR12486983 --project ~/Documents/MyProject.lungfish
```

Repeat with `SRR12486989` for the TaxTriage batch. `import-fastq` is an
alias of `import fastq`.

## Reference results

Kraken 2 2.17.1 with Bracken 3.0.1, 20260626 Viral database, Sensitivity
Balanced, default advanced settings, on `SRR12486983`. 3,926,054 pairs
unclassified (81.46%), 893,706 classified (18.54%), with 886,221 pairs
(18.39%) at Human alphaherpesvirus 1 (taxid 10298). The same reads against
the 20260626 Standard-16 database leave 4,476,436 unclassified (92.88%) and
put 89,294 (1.85%) at Human alphaherpesvirus 1.

## License

NCBI SRA public data. Both runs are publicly available from the NCBI
Sequence Read Archive under NCBI's data use policies. No reads are
redistributed here, only accessions and summary counts. Check your local
jurisdiction before redistributing the reads.

## Citation

```bibtex
@article{lu2022kraken,
  author  = {Lu, Jennifer and Rincon, Natalia and Wood, Derrick E. and
             Breitwieser, Florian P. and Pockrandt, Christopher and
             Langmead, Ben and Salzberg, Steven L. and Steinegger, Martin},
  title   = {Metagenome analysis using the Kraken software suite},
  journal = {Nature Protocols},
  year    = {2022},
  volume  = {17},
  number  = {12},
  pages   = {2815--2839},
  doi     = {10.1038/s41596-022-00738-y}
}
```

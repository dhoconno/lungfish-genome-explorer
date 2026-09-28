# Human Mapping and Variants (with results)

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the same practice data as the Human Mapping and Variants project, and on top of it the work those chapters ask you to do, already done. The HG002 reads are mapped to the chromosome 20 slice with minimap2, variants are called on that alignment with bcftools and with LoFreq, and the GIAB benchmark calls are imported beside them. Every result was made by `lungfish-cli`, the same program the window runs, with every setting left at its default, so each result carries the run record the window would have written.

Open this project when a chapter reads a finished project rather than building one. The project chapter uses it to show a sidebar with something in every folder, the provenance chapter reads its run records, the provenance export chapter exports its mapping run, and the file-format appendix quotes the files inside it.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq` | HG002 Illumina 2x250 reads from a 500 kb slice of chromosome 20, one paired bundle of 91,148 reads (45,574 pairs) |
| `Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref` | The matching 500,001-base slice of GRCh38 chromosome 20 as a reference bundle, untouched by the mapping |
| `Analyses/minimap2-2026-09-25T00-00-00/` | The mapping result, holding the sorted, indexed BAM the mapper wrote, its `mapping-result.json` and `mapping-provenance.json` sidecars, and the reference copy below |
| `Analyses/minimap2-2026-09-25T00-00-00/GRCh38.chr20.10.0-10.5Mb.lungfishref` | The copy of the reference LGE makes inside a mapping result, carrying the alignment track `HG002 minimap2` (its BAM sits under `alignments/mapped/`, named by a generated track id) and the three variant tracks under `variants/` |
| Variant track `HG002 bcftools` | bcftools calls on that alignment, diploid, minimum allele frequency 0.05 and minimum depth 10, 1,040 rows |
| Variant track `HG002 LoFreq` | LoFreq calls on the same alignment with the same thresholds, 862 rows |
| Variant track `HG002.chr20.10.0-10.5Mb.benchmark.vcf` | The GIAB benchmark calls over the slice, imported as a track and stored as its database alone, 961 rows |
| `Practice Data/hg002-chr20/` | The reference as a plain FASTA with its `.fai` index, and the benchmark VCF with its `.tbi` index, the files the chapters import by hand |

The reference slice's sequence is named `chr20_10.0-10.5Mb`, and its coordinates run from 1 to 500,001. The benchmark VCF was shifted to the same coordinates, so it lines up with the slice without any conversion.

The mapping folder is named for the date and time a run starts. In your own projects that stamp is the moment you clicked Run. Here it is fixed, so the paths this README and the manual quote stay the same from one download to the next.

## Where the data came from

The reads come from HG002 (NA24385), the Genome in a Bottle (GIAB) Ashkenazi son, sliced from the NIST/GIAB 2x250 PCR-free alignment of HG002 against GRCh38 over `chr20:10,000,000-10,500,000`. The reference is that stretch of UCSC hg38 chromosome 20, whose sequence is identical to GRCh38. The benchmark calls are the GIAB NISTv4.2.1 small-variant benchmark for HG002 against GRCh38, cut to the same stretch.

GIAB reference materials are U.S. government work in the public domain, and the UCSC hg38 download is freely redistributable. Check your local rules before redistributing these files elsewhere. Cite Zook and colleagues (2019), An open resource for accurately benchmarking small variant and reference calls, Nature Biotechnology 37, 561 to 566, https://doi.org/10.1038/s41587-019-0074-6.

The results were produced by minimap2 (Li 2018, Bioinformatics 34, 3094 to 3100, https://doi.org/10.1093/bioinformatics/bty191), samtools and bcftools (Danecek and colleagues 2021, GigaScience 10, giab008, https://doi.org/10.1093/gigascience/giab008) and LoFreq (Wilm and colleagues 2012, Nucleic Acids Research 40, 11189 to 11201, https://doi.org/10.1093/nar/gks918). The exact versions are in each result's provenance record, which the Inspector's Provenance tab shows.

## Chapters that use this project

{{CHAPTERS}}

None of these chapters runs an analysis on this project, so nothing here needs a plugin pack. To repeat the mapping and calling yourself, start from the Human Mapping and Variants project and follow Mapping Reads to a Reference and Calling Variants, which produce the same three tracks with a fresh time stamp on the folder.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Expand `Analyses` in the sidebar, then `minimap2-2026-09-25T00-00-00`, and click the `GRCh38.chr20.10.0-10.5Mb` bundle nested inside it. The alignment opens in the viewport.
3. Open the Inspector with **View > Show Inspector** and click its **Provenance** tab. The Source picker at the top offers the bundle and each variant track. Choose `HG002 bcftools` and open **Lineage** to read the steps that made it.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. Reading the results needs no pack. Calling more variants on the alignment needs the Variant Calling pack for LoFreq and iVar, and mapping again needs the Read Mapping pack. Install them from **Tools > Plugin Manager...** as the Plugin Packs chapter shows. bcftools and samtools arrive with the Required Setup pack, which the Welcome window offers to install the first time you open LGE.

---
title: Tool Bibliography
chapter_id: appendices/bibliography
audience: power-user
prereqs: []
estimated_reading_min: 8
task: Cite upstream tools used by Lungfish workflows.
tags: [reference, bibliography, citations, doi, provenance]
tools: []
entry_points:
  - "CLI: lungfish provenance bibliography <bundle>"
shots: []
illustrations: []
glossary_refs: [provenance]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-bibliography"></a>

## What it is

This appendix collects canonical citations for upstream tools that Lungfish ships, manages, wraps, or commonly references in workflow provenance. It is intentionally offline and conservative: when a tool has no DOI-backed canonical publication, cite the project page or source repository and rely on the Lungfish provenance sidecar for the exact version, argv, inputs, outputs, and checksums.

To generate a citation list for a specific result bundle, run:

```bash
lungfish provenance bibliography <bundle>
```

The command reads the root `.lungfish-provenance.json` sidecar when present, otherwise it looks for a bundle roll-up such as `provenance/bundle.lungfish-provenance.json`. It matches tool names with a local alias table, prints known citations, and lists unmatched tools so you can add any lab-specific scripts manually.

## Managed and Bundled Tools

| Tool | Canonical citation | DOI or source |
|---|---|---|
| micromamba | Mamba and micromamba package managers. | <https://mamba.readthedocs.io/> |
| Nextflow | Di Tommaso P, Chatzou M, Floden EW, et al. Nextflow enables reproducible computational workflows. Nature Biotechnology. 2017. | 10.1038/nbt.3820 |
| Snakemake | Moelder F, Jablonski KP, Letcher B, et al. Sustainable data analysis with Snakemake. F1000Research. 2021. | 10.12688/f1000research.29032.2 |
| BBTools | Bushnell B. BBTools software package. Joint Genome Institute. | <https://sourceforge.net/projects/bbmap/> |
| fastp | Chen S, Zhou Y, Chen Y, Gu J. fastp: an ultra-fast all-in-one FASTQ preprocessor. Bioinformatics. 2018. | 10.1093/bioinformatics/bty560 |
| Deacon | Deacon host-depletion toolkit. | <https://github.com/bede/deacon> |
| SAMtools, BCFtools, HTSlib | Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021. | 10.1093/gigascience/giab008 |
| SeqKit | Shen W, Le S, Li Y, Hu F. SeqKit: a cross-platform and ultrafast toolkit for FASTA/Q file manipulation. PLOS ONE. 2016. | 10.1371/journal.pone.0163962 |
| Cutadapt | Martin M. Cutadapt removes adapter sequences from high-throughput sequencing reads. EMBnet.journal. 2011. | 10.14806/ej.17.1.200 |
| VSEARCH | Rognes T, Flouri T, Nichols B, Quince C, Mahe F. VSEARCH: a versatile open source tool for metagenomics. PeerJ. 2016. | 10.7717/peerj.2584 |
| pigz | Adler M. pigz: a parallel implementation of gzip. | <https://zlib.net/pigz/> |
| SRA Tools | NCBI Sequence Read Archive Toolkit. | <https://github.com/ncbi/sra-tools> |
| UCSC bigBed/bigWig tools | Kent WJ, Zweig AS, Barber G, Hinrichs AS, Karolchik D. BigWig and BigBed: enabling browsing of large distributed datasets. Bioinformatics. 2010. | 10.1093/bioinformatics/btq351 |

## Workflow and Analysis Tools

| Tool | Canonical citation | DOI or source |
|---|---|---|
| nf-core/viralrecon | Patel H, Varona S, Monzon S, et al. nf-core/viralrecon: assembly and intrahost/low-frequency variant calling for viral samples. | 10.5281/zenodo.3901628 |
| iVar | Grubaugh ND, Gangavarapu K, Quick J, et al. An amplicon-based sequencing framework for accurately measuring intrahost virus diversity using PrimalSeq and iVar. Genome Biology. 2019. | 10.1186/s13059-018-1618-7 |
| LoFreq | Wilm A, Aw PPK, Bertrand D, et al. LoFreq: a sequence-quality aware, ultra-sensitive variant caller. Nucleic Acids Research. 2012. | 10.1093/nar/gks918 |
| Medaka | Oxford Nanopore Technologies. Medaka sequence correction and consensus toolkit. | <https://github.com/nanoporetech/medaka> |
| Kraken 2 | Wood DE, Lu J, Langmead B. Improved metagenomic analysis with Kraken 2. Genome Biology. 2019. | 10.1186/s13059-019-1891-0 |
| minimap2 | Li H. Minimap2: pairwise alignment for nucleotide sequences. Bioinformatics. 2018. | 10.1093/bioinformatics/bty191 |
| BWA | Li H, Durbin R. Fast and accurate short read alignment with Burrows-Wheeler transform. Bioinformatics. 2009. | 10.1093/bioinformatics/btp324 |
| Bowtie 2 | Langmead B, Salzberg SL. Fast gapped-read alignment with Bowtie 2. Nature Methods. 2012. | 10.1038/nmeth.1923 |
| BEDTools | Quinlan AR, Hall IM. BEDTools: a flexible suite of utilities for comparing genomic features. Bioinformatics. 2010. | 10.1093/bioinformatics/btq033 |
| MAFFT | Katoh K, Misawa K, Kuma K, Miyata T. MAFFT: a novel method for rapid multiple sequence alignment based on fast Fourier transform. Nucleic Acids Research. 2002. | 10.1093/nar/gkf436 |
| IQ-TREE | Nguyen LT, Schmidt HA, von Haeseler A, Minh BQ. IQ-TREE: a fast and effective stochastic algorithm for estimating maximum-likelihood phylogenies. Molecular Biology and Evolution. 2015. | 10.1093/molbev/msu300 |
| MultiQC | Ewels P, Magnusson M, Lundin S, Kaller M. MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics. 2016. | 10.1093/bioinformatics/btw354 |
| Pangolin | O'Toole A, Scher E, Underwood A, et al. Assignment of epidemiological lineages in an emerging pandemic using the pangolin tool. Virus Evolution. 2021. | 10.1093/ve/veab064 |
| Nextclade | Aksamentov I, Roemer C, Hodcroft EB, Neher RA. Nextclade: clade assignment, mutation calling and quality control for viral genomes. Journal of Open Source Software. 2021. | 10.21105/joss.03773 |

## Using This With Methods Text

Do not copy this table alone into a methods section. Combine the citation list with the bundle provenance so the methods text names both the publication and the exact executable version used in your run. For lab scripts or tools that do not match the built-in bibliography, `lungfish provenance bibliography` prints a "Tools without known citations" section; add those citations manually before submitting.

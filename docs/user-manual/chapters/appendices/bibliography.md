---
title: Tool Bibliography
chapter_id: appendices/bibliography
audience: power-user
prereqs: []
estimated_reading_min: 18
task: Cite the upstream tools a Lungfish Genome Explorer run used, and cite the app itself.
tags: [reference, bibliography, citations, doi, provenance]
tools: []
entry_points:
  - "CLI: lungfish-cli provenance bibliography <bundle>"
shots: []
illustrations: []
glossary_refs: [alias-table, bundle, checksum, citation, conda, container, dependency-set, doi, exit-status, host-depletion, json, operations-panel, pinned, plugin-pack, positional-argument, preprint, provenance, provenance-sidecar, reference-manager, tool-lock-manifest]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-bibliography"></a>

## What it is

This appendix covers citing the tools a Lungfish Genome Explorer (LGE) run used, and citing LGE itself, and nothing else. Journals require you to credit the software that produced each number. Most of the analysis in LGE is done by other people's tools, so you owe a [citation](../../GLOSSARY.md#citation), the formal reference to the paper or project page that describes a tool, to the authors of every tool that ran.

This appendix holds two things.

1. A command that reads one finished run and prints the citations for the tools that ran in it.

2. Tables covering every tool this release of LGE ships or installs, with its citation, so you can look one up without a run in front of you, or fill in what the command misses.

The command's built-in list of tool names is smaller than the tool set LGE ships, so it misses some tools, and in some cases it prints a citation for the wrong tool. [Tools the command mishandles](#tools-the-command-mishandles) says which.

A [DOI](../../GLOSSARY.md#doi), or digital object identifier, is the permanent address of a published article, a string like `10.1093/bioinformatics/bty191`. Put `https://doi.org/` in front of it to make a working link. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. That record is what the bibliography command reads.

Name the [dependency set](../../GLOSSARY.md#dependency-set), the named list of tool versions a release pins, beside the app version in a methods section. The versions themselves are listed in [Tool Versions](tool-versions.md), and this appendix carries no version numbers of its own.

## What the bibliography command prints

No window in LGE prints a citation list, so this step uses the command line. This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it. [Before you type anything](cli-reference.md#before-you-type-anything) shows how to open Terminal and move it into your project folder. Run this from there, replacing the example path with your own result folder.

```bash
lungfish-cli provenance bibliography ./Analyses/mapping-HG002
```

A path beginning with `./` is read from the folder you are in. HG002 is the widely used human reference sample this manual takes its human examples from.

Point the command at a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, or at any output folder. The command finds the provenance record inside it, trying the `.lungfish-provenance.json` at the top of the folder first and then the `provenance/` subfolder.

Then it walks the steps that sidecar recorded. For each step it takes the recorded tool name and looks it up in an **[alias table](../../GLOSSARY.md#alias-table)**, a fixed list built into LGE of the different names one tool can be recorded under, so that `bwa`, `bwa-mem`, and `bwa-mem2` all reach one entry.

Matching works in three tiers, and the third is where it goes wrong. An exact name match wins first. Failing that, a name that contains the other wins, which is why `samtools sort` matches SAMtools. Failing that, a single shared word is enough, which is loose enough to reach a wrong entry entirely. Every step whose name matches contributes one citation, with duplicates removed and the list sorted by tool name. Every step whose name matches nothing is listed separately under a heading of its own.

On a minimap2 mapping run of the HG002 chromosome 20 reads, two citations come back.

```
Bibliography for bundle: /Users/you/Documents/HG002-project/Analyses/mapping-HG002

- minimap2: Li H. Minimap2: pairwise alignment for nucleotide sequences. Bioinformatics. 2018. DOI: 10.1093/bioinformatics/bty191 https://github.com/lh3/minimap2
- SAMtools: Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021. DOI: 10.1093/gigascience/giab008 https://www.htslib.org/
```

LGE runs SAMtools behind the scenes to sort and index the mapping output, so two tools ran and two citations came back, each with author list, title, journal, year, DOI, and project URL. [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) reports the same pair for the same run. A tool with no DOI in the table prints only its project URL after the citation sentence, and a tool with neither prints the citation sentence alone.

The second half of the output appears whenever a step matched nothing. On a GATK HaplotypeCaller run of the same reads, nothing matched at all, and this block is the command's entire output.

```
Bibliography for bundle: /Users/you/Documents/HG002-project/Analyses/gatk-hc

No known tool citations were matched from this provenance record.

Tools without known citations
- gatk-haplotype-caller 4.6.2.0
```

The command's [exit status](../../GLOSSARY.md#exit-status), the number a script tests, is 0 in all three of the cases above, including the case where it matched nothing at all. Only a folder with no sidecar in it fails, and it prints `Error: Workflow execution failed: No Lungfish provenance sidecar found in <path>` and exits 64. A script must not test the exit status to decide whether citations came back, because an empty bibliography still exits 0.

### Tools the command mishandles

The alias table is smaller than the tool set LGE ships, so a missing citation is common rather than exceptional. Five causes account for what you will see. Only the fifth means anything is wrong with what you would publish.

The first is a tool that is genuinely absent from the alias table. Broadly, most assembly and variant-calling tools are missing, along with several classification tools. By name, that is every assembler (SPAdes, MEGAHIT, SKESA, Flye, and hifiasm), most GATK steps, Clair3, WhatsHap, Freyja, BLAST, Bracken, EsViritu, RiboDetector, Savont, TaxTriage, Primer3, PrimalScheme, pysam, and openpyxl. A run using any of them prints the tool under the unmatched heading. A SPAdes assembly, for instance, prints `- spades 4.3.0` as the only line under that heading. Take the citation for those from the tables below and add it by hand.

The second is a recorded step name that does not resemble the tool it ran. GATK steps are recorded as `gatk-haplotype-caller`, `gatk-bqsr`, and similar, and Freyja as `lungfish freyja demix`. Add those citations by hand.

The third is LGE's own steps, recorded under names beginning `lungfish`, such as `lungfish extract reads`. No citation is owed for those beyond citing LGE once, though a few of them wrongly print one, as the fifth cause below describes. The fourth is your own scripts, which need a citation you supply.

The fifth is the one to watch, because here the command recognises too much rather than too little. That third matching tier, a single shared word, reaches a wrong entry for many step names, and the result is a complete and confident citation for a tool that never ran. The step `trim_galore` prints an iVar citation, because it shares the word `trim` with iVar's recorded name `ivar trim`. The step `gatk-variants-to-table` also prints iVar, sharing `variants` with `ivar variants`. And `gatk-variant-filtration` prints a Medaka citation, sharing `variant` with `medaka variant`. Trim Galore installs with every copy of LGE, so this is reachable without any plugin pack. Others follow the same pattern. `gatk-select-variants` and LGE's own consensus and alignment-trimming steps also print iVar, LGE's variant database import prints Medaka, its QC summary steps print MultiQC, its tree reroot, relabel, and subtree steps print IQ-TREE, and a step named `gzip` prints HTSlib. Check every printed citation against the tools your run really used, delete any that do not belong, and take the right one from the tables below.

The wrong-citation case is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

Three more entries print an older paper than the one to cite. The command prints Li and Durbin 2009 for BWA-MEM2, the 2002 MAFFT paper, and the 2015 IQ-TREE paper, while the tables below give the paper for the version LGE installs.

## Tools installed with every copy of LGE

These tools are present in every copy of LGE. Their versions are in [Tools installed with every copy of LGE](tool-versions.md#tools-installed-with-every-copy-of-lge).

Rows carrying a project page rather than a DOI belong to tools that never published a paper, and for those the project page is what you cite. To turn a bare DOI in the last column into a working link, put `https://doi.org/` in front of it.

| Tool | DOI or project page |
|---|---|
| Nextflow | 10.1038/nbt.3820 |
| Snakemake | 10.12688/f1000research.29032.2 |
| BBTools | <https://sourceforge.net/projects/bbmap/> |
| fastp | 10.1093/bioinformatics/bty560 |
| Deacon | <https://github.com/bede/deacon> |
| SAMtools | 10.1093/gigascience/giab008 |
| BCFtools | 10.1093/gigascience/giab008 |
| HTSlib | 10.1093/gigascience/giab008 |
| SeqKit | 10.1371/journal.pone.0163962 |
| Cutadapt | 10.14806/ej.17.1.200 |
| Trim Galore | <https://github.com/FelixKrueger/TrimGalore> |
| VSEARCH | 10.7717/peerj.2584 |
| pigz | <https://zlib.net/pigz/> |
| SRA Tools | <https://github.com/ncbi/sra-tools> |
| UCSC bedGraphToBigWig | 10.1093/bioinformatics/btq351 |
| pysam | <https://github.com/pysam-developers/pysam> |
| openpyxl | <https://openpyxl.readthedocs.io/> |
| micromamba | <https://mamba.readthedocs.io/> |

The author, title, journal, and year for each of those follow. Article titles are transcribed exactly as published, punctuation and accented characters included. Each reference is completed by the DOI or project page in the table above, so a finished entry is built by joining the two.

```
Nextflow          Di Tommaso P, Chatzou M, Floden EW, et al. Nextflow enables reproducible computational workflows. Nature Biotechnology. 2017.
Snakemake         Moelder F, Jablonski KP, Letcher B, et al. Sustainable data analysis with Snakemake. F1000Research. 2021.
BBTools           Bushnell B. BBTools software package. Joint Genome Institute.
fastp             Chen S, Zhou Y, Chen Y, Gu J. fastp: an ultra-fast all-in-one FASTQ preprocessor. Bioinformatics. 2018.
Deacon            Deacon host-depletion toolkit.
SAMtools          Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021.
BCFtools          Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021.
HTSlib            Danecek P, Bonfield JK, Liddle J, et al. Twelve years of SAMtools and BCFtools. GigaScience. 2021.
SeqKit            Shen W, Le S, Li Y, Hu F. SeqKit: a cross-platform and ultrafast toolkit for FASTA/Q file manipulation. PLOS ONE. 2016.
Cutadapt          Martin M. Cutadapt removes adapter sequences from high-throughput sequencing reads. EMBnet.journal. 2011.
Trim Galore       Krueger F. Trim Galore. Babraham Bioinformatics.
VSEARCH           Rognes T, Flouri T, Nichols B, Quince C, Mahe F. VSEARCH: a versatile open source tool for metagenomics. PeerJ. 2016.
pigz              Adler M. pigz: a parallel implementation of gzip.
SRA Tools         NCBI Sequence Read Archive Toolkit.
bedGraphToBigWig  Kent WJ, Zweig AS, Barber G, Hinrichs AS, Karolchik D. BigWig and BigBed: enabling browsing of large distributed datasets. Bioinformatics. 2010.
pysam             pysam, a Python interface to SAM, BAM, and VCF files.
openpyxl          openpyxl, a Python library to read and write Excel 2010 files.
micromamba        Mamba and micromamba package managers.
```

Several entries above carry no author and no year, because the tool has neither a paper nor a stated release date. A **[reference manager](../../GLOSSARY.md#reference-manager)** that requires a year takes `n.d.`, meaning no date, in that field.

### One worked example

Here is one finished reference, assembled from a table row and the command's own output, in a common author-date style. The command printed this line for the HG002 mapping run.

```
- minimap2: Li H. Minimap2: pairwise alignment for nucleotide sequences. Bioinformatics. 2018. DOI: 10.1093/bioinformatics/bty191 https://github.com/lh3/minimap2
```

Rearranged into a reference list entry, using only the fields that line and the table carry, it becomes this.

```
Li H. (2018). Minimap2: pairwise alignment for nucleotide sequences.
Bioinformatics. https://doi.org/10.1093/bioinformatics/bty191
```

A software tool with no paper follows the same shape with `n.d.` for the year and the project page in place of the DOI.

```
Krueger F. (n.d.). Trim Galore. Babraham Bioinformatics.
https://github.com/FelixKrueger/TrimGalore
```

A citation without a DOI is normal for software and journals accept it. Match the punctuation to whatever style your own journal asks for, and the fields above are all you need.

Remember to cite three rows that are easy to miss. pysam reads the BAM files that produce a viewport's coverage and depth readouts, openpyxl writes the genotyping workbooks, and micromamba is the package manager that installed every other tool named in this appendix. If a number in your figure came out of a genotyping workbook or a coverage readout, one of those three helped produce it.

## Tools installed by a plugin pack

The Pack column names the [plugin pack](../../GLOSSARY.md#plugin-pack) that installs each tool, and [Tools installed by a plugin pack](tool-versions.md#tools-installed-by-a-plugin-pack) gives its version.

Cite only the tools your own sidecar names, not the whole table. The command's output is that list, and the next section gives a route to the same list without a terminal.

| Tool | Pack | DOI or project page |
|---|---|---|
| minimap2 | read-mapping | 10.1093/bioinformatics/bty191 |
| BWA-MEM2 | read-mapping | 10.1109/IPDPS.2019.00041 |
| Bowtie 2 | read-mapping | 10.1038/nmeth.1923 |
| Savont | full-length-mhc-genotyping | <https://github.com/bluenote-1577/savont> |
| BLAST+ | full-length-mhc-genotyping | 10.1186/1471-2105-10-421 |
| Primer3 | pcr-primer-design | 10.1093/nar/gks596 |
| PrimalScheme | pcr-primer-design | 10.1038/nprot.2017.066 |
| LoFreq | variant-calling | 10.1093/nar/gks918 |
| iVar | variant-calling | 10.1186/s13059-018-1618-7 |
| Medaka | variant-calling | <https://github.com/nanoporetech/medaka> |
| Clair3 | variant-calling | 10.1038/s43588-022-00387-x |
| GATK4 | gatk-core | 10.1101/gr.107524.110 |
| WhatsHap | phasing | 10.1101/085050 |
| SPAdes | assembly | 10.1089/cmb.2012.0021 |
| MEGAHIT | assembly | 10.1093/bioinformatics/btv033 |
| SKESA | assembly | 10.1186/s13059-018-1540-z |
| Flye | assembly | 10.1038/s41587-019-0072-8 |
| hifiasm | assembly | 10.1038/s41592-020-01056-5 |
| MAFFT | multiple-sequence-alignment | 10.1093/molbev/mst010 |
| IQ-TREE | phylogenetics | 10.1093/molbev/msaa015 |
| Kraken 2 | metagenomics | 10.1186/s13059-019-1891-0 |
| Bracken | metagenomics | 10.7717/peerj-cs.104 |
| EsViritu | metagenomics | <https://github.com/cmmr/EsViritu> |
| RiboDetector | metagenomics | 10.1093/nar/gkac112 |
| Freyja | wastewater-surveillance | 10.1038/s41586-022-05049-6 |

A pack name is a label LGE uses to group tools for installation, not something a journal wants, so leave it out of a methods section. `full-length-mhc-genotyping` installs the tools for typing MHC genes, the major histocompatibility complex, the highly variable immune-system region that this pack's workflow genotypes. The WhatsHap DOI resolves to a bioRxiv **[preprint](../../GLOSSARY.md#preprint)**, an article posted before peer review, so check whether your journal accepts one before you use it.

The matching references follow, in the same order.

```
minimap2      Li H. Minimap2: pairwise alignment for nucleotide sequences. Bioinformatics. 2018.
BWA-MEM2      Vasimuddin Md, Misra S, Li H, Aluru S. Efficient architecture-aware acceleration of BWA-MEM for multicore systems. IEEE IPDPS. 2019.
Bowtie 2      Langmead B, Salzberg SL. Fast gapped-read alignment with Bowtie 2. Nature Methods. 2012.
Savont        Savont read clustering toolkit.
BLAST+        Camacho C, Coulouris G, Avagyan V, et al. BLAST+: architecture and applications. BMC Bioinformatics. 2009.
Primer3       Untergasser A, Cutcutache I, Koressaar T, et al. Primer3, new capabilities and interfaces. Nucleic Acids Research. 2012.
PrimalScheme  Quick J, Grubaugh ND, Pullan ST, et al. Multiplex PCR method for MinION and Illumina sequencing of Zika and other virus genomes directly from clinical samples. Nature Protocols. 2017.
LoFreq        Wilm A, Aw PPK, Bertrand D, et al. LoFreq: a sequence-quality aware, ultra-sensitive variant caller. Nucleic Acids Research. 2012.
iVar          Grubaugh ND, Gangavarapu K, Quick J, et al. An amplicon-based sequencing framework for accurately measuring intrahost virus diversity using PrimalSeq and iVar. Genome Biology. 2019.
Medaka        Oxford Nanopore Technologies. Medaka sequence correction and consensus toolkit.
Clair3        Zheng Z, Li S, Su J, et al. Symphonizing pileup and full-alignment for deep learning-based long-read variant calling. Nature Computational Science. 2022.
GATK4         McKenna A, Hanna M, Banks E, et al. The Genome Analysis Toolkit, a MapReduce framework for analyzing next-generation DNA sequencing data. Genome Research. 2010.
WhatsHap      Martin M, Patterson M, Garg S, et al. WhatsHap: fast and accurate read-based phasing. bioRxiv. 2016.
SPAdes        Bankevich A, Nurk S, Antipov D, et al. SPAdes: a new genome assembly algorithm and its applications to single-cell sequencing. Journal of Computational Biology. 2012.
MEGAHIT       Li D, Liu CM, Luo R, Sadakane K, Lam TW. MEGAHIT: an ultra-fast single-node solution for large and complex metagenomics assembly via succinct de Bruijn graph. Bioinformatics. 2015.
SKESA         Souvorov A, Agarwala R, Lipman DJ. SKESA: strategic k-mer extension for scrupulous assemblies. Genome Biology. 2018.
Flye          Kolmogorov M, Yuan J, Lin Y, Pevzner PA. Assembly of long, error-prone reads using repeat graphs. Nature Biotechnology. 2019.
hifiasm       Cheng H, Concepcion GT, Feng X, Zhang H, Li H. Haplotype-resolved de novo assembly using phased assembly graphs with hifiasm. Nature Methods. 2021.
MAFFT         Katoh K, Standley DM. MAFFT multiple sequence alignment software version 7: improvements in performance and usability. Molecular Biology and Evolution. 2013.
IQ-TREE       Minh BQ, Schmidt HA, Chernomor O, et al. IQ-TREE 2: new models and efficient methods for phylogenetic inference in the genomic era. Molecular Biology and Evolution. 2020.
Kraken 2      Wood DE, Lu J, Langmead B. Improved metagenomic analysis with Kraken 2. Genome Biology. 2019.
Bracken       Lu J, Breitwieser FP, Thielen P, Salzberg SL. Bracken: estimating species abundance in metagenomics data. PeerJ Computer Science. 2017.
EsViritu      EsViritu read mapping and reporting for viral genomes.
RiboDetector  Deng ZL, Munch PC, Mreches R, McHardy AC. Rapid and accurate identification of ribosomal RNA sequences via deep learning. Nucleic Acids Research. 2022.
Freyja        Karthikeyan S, Levy JI, De Hoff P, et al. Wastewater sequencing reveals early cryptic SARS-CoV-2 variant transmission. Nature. 2022.
```

Three rows need a note, and each note names one paper you cite and one you may add beside it. A secondary citation is a second reference kept alongside the first for the original method, and both go in your reference list when you use one.

BWA-MEM2 is what LGE installs, so cite the 2019 architecture paper above. Keep Li and Durbin 2009 (`10.1093/bioinformatics/btp324`) as the secondary citation for the underlying Burrows-Wheeler algorithm, the text-indexing method BWA uses to search a genome quickly, which is what a reviewer asking where the method came from wants.

MAFFT is version 7, so the 2013 paper is the one to cite. Katoh and colleagues 2002 (`10.1093/nar/gkf436`) is the secondary citation for the original method.

LGE installs IQ-TREE 3.1.3, and IQ-TREE 3 had not published its own paper when this release was built, so the IQ-TREE 2 paper above is correct for now. Check <http://www.iqtree.org> for a version 3 paper before you submit, since one may have appeared since.

## Pinned external pipelines

A pipeline runs many separate tools in a fixed order, so citing one commits you to citing what it contains as well. The pinned releases are in [Pinned external pipelines](tool-versions.md#pinned-external-pipelines).

| Pipeline | DOI or project page |
|---|---|
| nf-core/viralrecon | 10.5281/zenodo.3901628 |
| TaxTriage | <https://github.com/jhuapl-bio/taxtriage> |

```
nf-core/viralrecon  Patel H, Varona S, Monzon S, et al. nf-core/viralrecon: assembly and intrahost/low-frequency variant calling for viral samples.
TaxTriage           TaxTriage, a Nextflow pipeline for pathogen identification from metagenomic reads. Johns Hopkins University Applied Physics Laboratory.
```

Neither entry carries a year, so use `n.d.` and the pinned release number. Cite the pipeline itself, cite the Nextflow paper from the first table, and then cite the pipeline's own component tools. Each nf-core pipeline, nf-core being a community collection of Nextflow pipelines, states its citation requirements in the CITATIONS file at the top of its own repository, and for viralrecon 3.0.0 that file names every tool the run touched.

Four tools reach a result only inside these pipelines, in [containers](../../GLOSSARY.md#container) the pipeline manages rather than through LGE's own installation. A container is a packaged copy of a program with everything it needs to run. BEDTools, MultiQC, Pangolin, and Nextclade are the four, and a viralrecon run's CITATIONS file lists all four, so a viralrecon methods section names them. Their citations are Quinlan and Hall 2010 for BEDTools (`10.1093/bioinformatics/btq033`), Ewels and colleagues 2016 for MultiQC (`10.1093/bioinformatics/btw354`), O'Toole and colleagues 2021 for Pangolin (`10.1093/ve/veab064`), and Aksamentov and colleagues 2021 for Nextclade (`10.21105/joss.03773`). LGE does not install, version, or manage any of the four.

## Reference databases

A classification result depends on the database as much as on the classifier, so name the database and its version beside the tool. [Reference databases](tool-versions.md#reference-databases) lists the version of every database this release pins. The NCBI Taxonomy is not pinned at all, so record the date you ran the classification, which your provenance record also holds.

## Which tools you actually need to cite

Your provenance sidecar is the authoritative list. Cite what it names and nothing else. There are three routes to that list, and only the first needs a terminal.

1. Run `lungfish-cli provenance bibliography` against the result folder, as above, and read both the citation list and the unmatched heading below it. Both halves are tools that ran.

2. In the Operations Panel, find the run's row. The copied command names the main tool, though not helpers such as SAMtools. To see the same run as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes.

3. Open the sidecar itself. It is the file named `.lungfish-provenance.json` beside your result, or inside the bundle's `provenance/` folder. Finder hides names beginning with a dot, so press Cmd-Shift-period in the Finder window to show them. It is plain text, so any text editor opens it, and the `toolName` entries are the tools that ran.

Routes 2 and 3 need no terminal, and route 3 is the one that gives the same complete list the command reads.

## Citing LGE itself

LGE has no published paper and no DOI of its own, so the citation is the project page together with the version string. Include the dependency set, because that is what lets somebody else install the same tool versions.

```
Lungfish Genome Explorer, version 2026.9.40, dependency set 2026.2.
https://github.com/dhoconno/lungfish-genome-explorer
```

That block is a usable default. In the author-date style of the worked example, with the year of the release you used, it reads like this.

```
Lungfish Genome Explorer. (2026). Version 2026.9.40, dependency set 2026.2.
https://github.com/dhoconno/lungfish-genome-explorer
```

To read your own version rather than the one printed here, open **Lungfish Genome Explorer > About Lungfish Genome Explorer**, which needs no terminal. From a terminal, `lungfish-cli --version` prints the same number and nothing else, reporting `2026.9.40` for this release. Both the version and the dependency set are recorded in every provenance sidecar, so a reader who has your sidecar can recover them without asking you.

## Using this with a methods section

Do not paste these tables into a paper. A citation says which tool you used, and a methods section also needs which build ran with which arguments. Run `provenance bibliography` against the finished run for the citations, and export a methods draft for the commands and versions, as [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure) shows. Write the methods paragraph from the pair.

Three rules keep your citations accurate.

1. Cite only the tools your own run used, not everything in the tables above. A reviewer who reads a citation for a tool that never ran will doubt the rest of your methods.

2. Add by hand every tool the command listed as unmatched, and delete any wrong citation the command printed, as [Tools the command mishandles](#tools-the-command-mishandles) describes. Check each name against the tables here.

3. Name the database version and the run date for any classification result, because the tool version alone does not identify what it searched.

## Next

[Tool Versions](tool-versions.md) gives the version, license, and environment of every managed tool. See [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) for the methods export that pairs with this command, and [CLI Reference](cli-reference.md) for the rest of the `provenance` subcommands.

---
title: Amplicons and Shotgun Sequencing
chapter_id: 01-foundations/03-amplicon-vs-shotgun
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/02-sequencing-reads]
estimated_reading_min: 8
task: Understand the difference between amplicon and shotgun sequencing and why amplicon data needs primer trimming.
tags: [foundations, amplicon, shotgun, primers, primer-scheme, artic, qiaseq]
tools: []
entry_points: []
shots: []
illustrations:
  - id: amplicon-vs-shotgun
    brief: "Top row: shotgun sequencing schematic showing a genome with reads scattered randomly across it, each read starting and ending at arbitrary positions. Bottom row: amplicon sequencing showing the same genome with reads starting and ending at fixed primer positions, with about 8-10 overlapping amplicons covering the genome. Use Lungfish Creamsicle for read positions, Peach for primer positions."
  - id: primer-scheme-diagram
    brief: "A 2000-base region of a genome backbone in Deep Ink, with three primer pairs marked above the backbone (forward primers as right-pointing Creamsicle arrows, reverse primers as left-pointing arrows), creating three overlapping amplicons. Below the backbone, a small table showing the BED-style start/end coordinates of each primer."
  - id: primer-trim-soft-clip
    brief: "A single read shown twice. Top: untrimmed read, with the leftmost ~20 bases highlighted in Peach (primer-derived) and the body of the read in Lungfish Creamsicle (sample-derived). Bottom: same read after primer trim, with primer-derived bases shown lightened/struck-through to indicate soft-clipping, body unchanged. Annotate 'Primer bases ignored by the variant caller'."
glossary_refs: [amplicon, shotgun, primer, primer-scheme, primer-trim, soft-clip]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Sample DNA reaches the sequencer in one of three main ways. It can be chopped at random into small fragments before being read ([shotgun](../../GLOSSARY.md#shotgun) sequencing), amplified at fixed positions across the genome by PCR with carefully chosen primers ([amplicon](../../GLOSSARY.md#amplicon) sequencing), or enriched by hybridisation to oligonucleotide probes that selectively pull target sequences out of a complex background (target-enrichment sequencing, also called capture-based sequencing). All three approaches produce FASTQ files that look identical at the file level: same four-line records, same Phred scores, same paired-end conventions. The differences live in how the reads sit on the genome, and those differences change how you must analyse them.

This chapter explains what amplicon protocols are, why they dominate viral surveillance ([SARS-CoV-2 ARTIC](https://artic.network/ncov-2019) and [QIAseq Direct](https://www.qiagen.com/), [dengue PrimalSeq](https://github.com/grubaughlab), monkeypox amplicon panels), and what a primer scheme is as a file. It also explains why amplicon data needs primer trimming before variant calling, and why skipping that step produces phantom variants that look real but are not. A short subsection at the end introduces target-enrichment sequencing as a third approach often used for harder samples.

![Shotgun reads scattered randomly compared with tiled overlapping amplicons at fixed positions](../../assets/illustrations-imagegen/01-foundations/03-amplicon-vs-shotgun/amplicon-vs-shotgun.png)

So what should you do with this? Before you start any variant analysis in LGE, find out which library prep your sample used. If the protocol name contains "ARTIC", "QIAseq", "PrimalSeq", or any panel name with a version number tied to a virus, the data is amplicon and you will need a [primer scheme](../../GLOSSARY.md#primer-scheme). If the protocol name is "Nextera XT", "TruSeq DNA", "NEBNext Ultra", or similar, the data is shotgun and primer trimming does not apply. If the protocol name mentions a "capture" or "panel" product such as Twist Comprehensive Viral or IDT xGen, the data is target-enriched and behaves like shotgun for primer-trimming purposes.

## Shotgun sequencing: random fragments

In shotgun prep, total nucleic acid from the sample is enzymatically or mechanically broken into short pieces, sequencing adapters are ligated to both ends, and the resulting library is sequenced. Where any given read lands on the genome is essentially random. The position depends on where the fragmentation enzyme happened to cut, which is dictated by physics and chemistry rather than design.

The benefit is that shotgun captures whatever DNA is in the tube without bias toward known sequence. If your sample contains an unknown pathogen, a recombinant, or a wildly diverged variant, shotgun will see it as long as enough template is present. The cost is sensitivity at low template abundance, because most of the reads come from the dominant background (host, microbiome, contaminants) and only a fraction reach the target.

A quick back-of-the-envelope makes this concrete. Suppose viral reads are 0.01% of total reads in a shotgun library. Then on average one read in 10,000 is viral. A 30 kb viral genome requires roughly 200 perfectly placed 150 bp reads to reach 1x nominal coverage. Combining those two facts, you would expect to need about 2 million total reads to see ~200 viral reads, before accounting for the usual losses to host depletion, duplicates, mapping failures, uneven coverage, and quality filters. In practice plan for several million to tens of millions of total reads to get usable amplifying coverage at this fraction. That is why shotgun viral sequencing usually requires either a high-titre clinical isolate or a sample that has been physically enriched for the target.

Shotgun reads do not need primer trimming, because there are no fixed primers. The adapter sequences attached during library prep are removed by the sequencer's basecaller or by a tool such as [fastp](https://github.com/OpenGene/fastp) before alignment, and that adapter trim is a separate concern from primer trim.

## Amplicon sequencing: fixed PCR products

In amplicon prep, instead of fragmenting first, the protocol uses PCR to make many copies of a defined region of the genome. A pair of [primers](../../GLOSSARY.md#primer), each a short oligonucleotide of 18 to 30 bases, binds to two known positions on the reference, and DNA polymerase extends between them. The product is called an [amplicon](../../GLOSSARY.md#amplicon): a double-stranded DNA molecule whose ends are exactly the two primer binding sites and whose middle is the genomic sequence between them.

A single primer pair only covers one stretch of the genome, so real surveillance protocols use many primer pairs in two or more pools to tile the entire region of interest. ARTIC v3 for SARS-CoV-2 uses 98 primer pairs across two pools to produce 98 overlapping amplicons of about 400 bp each, covering the 30 kb genome end to end. After PCR, the amplicons are pooled, given sequencing adapters, and sequenced exactly like a shotgun library.

The benefit is sensitivity at low template input. PCR amplifies the target by orders of magnitude, so amplicon protocols routinely pull out useful viral genomes from clinical samples with cycle-threshold (Ct) values up to around 32 or 33. (Ct is the qPCR cycle number at which a positive signal first appears; lower values indicate higher viral load. Ct 32 to 33 corresponds to roughly 10^3 viral copies per microlitre for many SARS-CoV-2 assays, though exact values vary by assay.) Coverage is also predictable: every amplicon should produce reads at its assigned coordinates, so a coverage drop tells you something specific (a primer failure, a deletion, a mutation under one of the primer-binding sites). The cost is that amplicon protocols only see what the primers were designed to amplify. A novel virus, or a variant that mutates a primer-binding site, may be invisible or under-represented.

PCR also introduces artifacts beyond what shotgun shows: chimeric reads where two templates were joined by the polymerase, jackpot effects where a single early molecule dominates an amplicon's read pile, and polymerase errors propagated through cycles. Most of these surface as low-frequency variants rather than fixed ones, so they are usually filtered out by the default minimum-allele-frequency threshold. The [Variants and VCF Files](05-variants-and-vcf.md) chapter and the variant-calling workflow chapters cover the filter settings in detail.

## What an amplicon looks like, end to end

A worked example helps. Imagine an amplicon defined by:

- A 22 bp forward primer at reference positions 1000 to 1021.
- A 22 bp reverse primer at reference positions 1378 to 1399.

The full amplicon is 400 bp long, spanning positions 1000 to 1399. After PCR, every copy of this molecule starts and ends at exactly those coordinates. After sequencing on a 150 bp paired-end Illumina run, you get two reads per molecule: read 1 sequences the first 150 bases (positions 1000 to 1149), read 2 sequences the last 150 bases from the other strand (positions 1250 to 1399). The middle of the amplicon (positions 1150 to 1249) is covered only when reads from neighbouring overlapping amplicons fill it in.

Now, here is the part that matters for variant calling. The first 22 bases of read 1 are not the sample's DNA. They are the primer sequence, copied into the read because the primer itself was incorporated as the 5' end of the amplicon during PCR. Whatever the sample's true sequence at positions 1000 to 1021 happens to be, the read at those positions will display the primer sequence. Likewise, the last 22 bases of read 2 will display the reverse primer sequence rather than the sample. Across thousands of reads from this amplicon, every single one shows the same primer-derived bases at the same positions.

If a variant caller looks at position 1015 and sees the primer base at 100% of reads when the reference says something different, the caller has no way to know that this is a protocol artifact. It will report a high-confidence, high-frequency variant. That variant is not real. It is the primer.

![Before and after primer trimming, showing soft-clipped primer bases](../../assets/illustrations-imagegen/01-foundations/03-amplicon-vs-shotgun/primer-trim-soft-clip.png)

## Primer trimming and soft-clipping

The fix is [primer trimming](../../GLOSSARY.md#primer-trim). Two approaches exist, and LGE supports both depending on where in the workflow you want the trim to happen.

The first approach is **read-based primer trimming**. A tool such as `fastp` is given the primer sequences and walks each FASTQ read end, removes primer bases by matching primer sequence at the read's 5' edge, and writes a trimmed FASTQ. The trim happens before alignment and works without a reference, but it is sensitive to primer-binding-site mutations: if your sample has a SNP under a primer site, the read end may no longer match the canonical primer sequence and bases will pass through untrimmed. Read-based trimming also loses primer information for QC after the fact.

The second approach is **alignment-based primer trimming**. A tool such as `ivar trim` or `samtools ampliconclip` is given the primer coordinates in a [BED](../../GLOSSARY.md#primer-scheme) file, walks each aligned read in the BAM, finds where the read's mapped position overlaps a primer footprint, and marks those bases as [soft-clipped](../../GLOSSARY.md#soft-clip) in the BAM. Soft-clipping is the alignment format's way of saying "these bases are still present in the record, but ignore them when computing pileup, coverage, or variants" ([Alignment Files](04-alignment-files.md) covers soft-clipping in more detail). Alignment-based trimming is robust to primer-site mutations because it uses coordinates rather than sequences, and it preserves the original bases in the BAM for later inspection. It is the approach recommended by the ARTIC project and is the LGE default for the iVar variant-calling lane.

In LGE, the BAM-level primer trim runs `ivar trim` against a selected primer scheme after alignment and before variant calling. Most reads pass through with primer ends soft-clipped, but some `ivar trim` options can drop reads whose remaining aligned span is too short or whose ends do not match any expected primer; the operation's provenance sidecar records the exact options used, so it is always recoverable.

## What a primer scheme is, as a file

A [primer scheme](../../GLOSSARY.md#primer-scheme) is at heart a coordinate table. For each primer, it lists the contig name, the start coordinate, the end coordinate, the primer name (which usually encodes its pool and direction, for example `nCoV-2019_1_LEFT` and `nCoV-2019_1_RIGHT`), a score, and a strand. The most common on-disk format is BED, a tab-separated text file where each row is one primer and the standard six columns are chrom, start, end, name, score, strand. Standard BED does not include the primer sequence; the primer sequences live in a companion FASTA or TSV file when the scheme provides them. Some schemes use extended BED variants with additional columns for pool number or sequence, but the six-column form is the baseline.

A minimal BED row for the forward primer in the example above would read:

```
MN908947.3	999	1021	nCoV-2019_1_LEFT	1	+
```

(BED is zero-based half-open, so a primer at one-based positions 1000 to 1021 is written as 999 to 1021.)

LGE packages primer schemes as `.lungfishprimers` bundles. A bundle is a folder containing the BED file, the primer sequences as a companion FASTA, and a provenance note naming the source and reference accession the coordinates apply to. Bundles live in the project's `Primer Schemes/` folder and appear in the primer picker whenever a workflow needs one. The bundle layout is documented in [Primer Scheme Bundles](../appendices/primer-schemes.md#appendix-primer-schemes).

![ARTIC-style primer scheme showing forward primers, reverse primers, and overlapping amplicon bands](../../assets/illustrations-imagegen/01-foundations/03-amplicon-vs-shotgun/primer-scheme-diagram.png)

## Amplicon versus shotgun, side by side

| Property | Shotgun | Amplicon |
|---|---|---|
| Where reads start | Random across the genome | At fixed primer coordinates |
| Sensitivity at low input | Low; needs high titre or enrichment | High; routinely works to Ct ~32 |
| Sample input required | Often hundreds of ng | A few ng or less |
| Primer trim required? | No | Yes |
| Default strand-bias behaviour | Filter useful as a default check | Filter thresholds need adjustment; inspect protocol context |
| Cost per genome | Higher | Lower |
| Detects novel sequence? | Yes | Only what primers target |

When to choose shotgun: high-titre cultures, metagenomic discovery, samples where you do not yet know what virus you are looking at, host-depleted clinical samples with substantial viral load. When to choose amplicon: targeted surveillance of a known pathogen, low-titre clinical samples, large sample batches where cost matters, settings where uniform coverage is needed for variant comparison across samples.

The amplicon protocols you choose between depend on what is currently maintained for your target. The next subsection lists the canonical SARS-CoV-2 options at the time of writing; for any specific run, verify the scheme name and version against the wet-lab record or the [ARTIC primer scheme repository](https://github.com/artic-network/primer-schemes).

## Common SARS-CoV-2 amplicon protocols

Most public SARS-CoV-2 sequence in archives such as SRA and ENA was produced by one of a handful of amplicon protocols. Knowing which protocol generated a sample tells you which primer scheme to select in LGE.

- **[ARTIC v3](https://github.com/artic-network/artic-ncov2019).** The original 98-amplicon, 400 bp scheme; widespread in 2020 and 2021. Coordinates target Wuhan-Hu-1 (`MN908947.3`).
- **[ARTIC v4.1](https://community.artic.network/t/sars-cov-2-version-4-scheme-release/312).** Released in late 2021 to handle mutations in Alpha, Delta, and early Omicron primer sites. Same 400 bp amplicon size; revised primer positions.
- **[ARTIC v5.3.2](https://community.artic.network/t/sars-cov-2-version-5-3-2-scheme-release/462) (released January 2023).** A redesigned 400 bp scheme rebalanced for coverage uniformity. The ARTIC project continues to release further updates (such as the v5.4.2 scheme released for JN.1-era mutations), so always verify the scheme version against your protocol metadata.
- **QIAseq Direct SARS-CoV-2.** A commercial enhanced-amplicon kit with shorter (~250 bp) amplicons designed for fragmented RNA. Useful for archival and FFPE samples.
- **[Midnight (1200 bp)](https://github.com/quick-lab/SARS-CoV-2_Midnight_Nanopore).** A coarser, 1200 bp amplicon scheme designed for Oxford Nanopore long reads.

Picking the wrong scheme is one of the most common causes of phantom variants in viral surveillance pipelines. If you trim a sample that was generated with ARTIC v4.1 against the v3 BED file, the primers in the BAM will not match what the trimmer is looking for, and the real primer bases will pass through into the pileup. The result is a clean-looking VCF that lists ten or twenty fixed-frequency "variants" at the v4.1 primer footprints. They will not appear in any database, they will not match any lineage, and they will track perfectly with the protocol metadata if you compare across samples.

## So how do you tell which protocol a sample used?

In practice, three places usually carry the answer. The sample's submission record in SRA or ENA names the library prep kit in the `library_strategy` and `library_construction_protocol` fields. The publication or sequencing centre's protocol documentation names the version. The wet-lab notebook of whoever prepared the sample is the authoritative record. If none of these are available, the coverage profile can sometimes give it away: amplicon coverage shows characteristic step changes at primer junctions, while shotgun coverage looks smoother and varies with GC content rather than at fixed coordinates.

When in doubt, ask the person who prepared the library. Guessing at a primer scheme is worse than running the analysis untrimmed, because trimming with the wrong scheme can soft-clip real sample bases at positions that happen to overlap an unrelated primer.

## Target-enrichment sequencing

A third major library-prep approach sits between amplicon and shotgun. Target-enrichment (also called capture-based or hybridisation-capture sequencing) uses biotinylated oligonucleotide probes that bind to predefined regions of interest, allowing the targeted nucleic acid to be physically pulled out of a high-background sample before sequencing. The Twist Comprehensive Viral Research Panel, the IDT xGen Pan-Viral panel, and the broader Viral Surveillance Panel 2 (VSP2) family are common examples.

Capture-based libraries sit between amplicon and shotgun on several axes. Like amplicons, they target known sequence and need probe panels designed in advance; unlike amplicons, they do not produce reads anchored to fixed coordinates with primer-derived ends, so they do not require primer trimming. Like shotgun, they generate randomly-sheared inserts and tolerate broad sequence diversity within the probe footprint, including some divergence from the probe sequence; unlike shotgun, they concentrate on the targets and reach useful viral coverage at much lower template input. Coverage is usually more uneven than amplicon coverage and shows characteristic drops at probe boundaries and in regions that mutated away from probe affinity.

For LGE workflows, treat capture-based data like shotgun data. Skip primer trimming, choose a variant caller appropriate for the platform, and watch the coverage profile for probe-boundary dropouts rather than amplicon-junction dropouts.

## Next

Continue to [Alignment Files](04-alignment-files.md) to learn what happens after FASTQ reads are mapped to the reference, including how soft-clipping is recorded in a BAM file.

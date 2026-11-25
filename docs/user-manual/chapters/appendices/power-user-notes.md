---
title: Power User Notes
chapter_id: appendices/power-user-notes
audience: power-user
prereqs: []
estimated_reading_min: 25
task: Look up the exact arguments Lungfish Genome Explorer passes to each wrapped tool, and the limits on repeating a run and getting the same answer.
tags: [reference, power-user, mpileup, ivar, lofreq, bcftools, fastp, bbduk, minimap2, kraken2, assembly, gatk, determinism, reproducibility]
tools: [samtools, bcftools, ivar, lofreq, fastp, bbduk, cutadapt, minimap2, bwa-mem2, bowtie2, kraken2, spades, megahit, skesa, flye, hifiasm, gatk]
entry_points: []
shots: []
illustrations: []
glossary_refs: [adapter, allele-frequency, alternate-read, amplicon, argument, assembly-graph, baq, bbduk, bed, bracken, bundle, codon, command-line-flag, conda, contig, cutadapt, dependency-set, determinism, environment-variable, fastp, gvcf, haplotype, hg002, indel, interleaved-fastq, ivar, k-mer, kraken2, linkage, lofreq, mapping-quality, mate, oci-layout, phase, phred-score, pileup, pivot-workbook, plugin-pack, primer-dimer, primer-trim, provenance, provenance-sidecar, read-group, ref-alt, reference-bundle, secondary-alignment, sliding-window-trimming, strand-bias, thread, vcf, wrapper]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) is a [wrapper](../../GLOSSARY.md#wrapper), a program that builds and runs other programs' command lines for you. The workflow chapters of this manual describe what each setting does and leave out the command underneath it. This appendix holds those commands, the exact list of [arguments](../../GLOSSARY.md#argument) LGE passes to each wrapped tool, and the limits on repeating a run and getting the same answer. A [flag](../../GLOSSARY.md#command-line-flag) is a hyphen-prefixed argument such as `-q` or `--threads`.

Every command here was read from the LGE source that builds it, and checked against the source of the release this manual documents. The same commands appear in the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) LGE writes beside each result. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a checksum of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. The fields inside the sidecar are listed in [Provenance sidecars](file-formats.md#provenance-sidecars). When this page and a run's own sidecar disagree, the sidecar wins, because it records what happened.

The argument lists are shown in grey blocks with file paths shortened, because the real paths point into a scratch folder LGE creates and removes for you. None of these blocks is a step to type. The values shown are the defaults of [dependency set](../../GLOSSARY.md#dependency-set) `2026.2`, the pinned tool versions [Tool Versions](tool-versions.md) lists.

## Before you type anything

The commands in the grey blocks below are for reading, not typing. The few you might type, in the later sections, run the `lungfish-cli` program that ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

## Reproducibility caveats at a glance

The problems in this table stop a rerun from matching the first run. Check for each before you promise anyone an identical result.

| Caveat | What to do |
|---|---|
| A setting that is not passed to the tool | The iVar tuning flags configure LGE's own converter, not iVar ([The four iVar tuning flags](#the-four-ivar-tuning-flags-do-not-reach-ivar)), and the merge threshold changes nothing ([Codon merging](#codon-merging)). The minimum contig length and the memory limit never reach some assemblers ([Two settings are ignored on some assemblers](#two-settings-are-ignored-on-some-assemblers)). Read the recorded command in the sidecar rather than the one you meant to run. |
| Your own extra arguments losing to LGE's | On some tools LGE's value comes after yours and wins. Each section below says which way round it is. |
| Tool version drift | Compare each step's `toolVersion` in the two sidecars before comparing results ([Cross-architecture and cross-version drift](#cross-architecture-and-cross-version-drift)). |
| Thread count | Pin `--threads` to one number for every run you mean to compare ([What was measured](#what-was-measured)). |
| A fault in LGE itself | Several faults change what a sidecar records or what a command does. They are known defects, listed with their workarounds in [Known defects in this release](troubleshooting.md#known-defects-in-this-release). |

## Reading a command out of the source

This section is for readers with a copy of the LGE source code. Everyone else can skip to [iVar variant calling](#ivar-variant-calling), since every argument list is quoted in full below.

Each section names the source file that builds its command, under `Sources/LungfishWorkflow/` unless the section names another folder. The code that builds an argument list only assembles text and runs nothing, so reading it tells you the whole command. Two habits of these builders matter. Some put your extra arguments before LGE's own and some after, and since most tools read the last value of a repeated flag, that order decides whose value wins. And several builders add an argument only when a condition holds, so a flag missing from one run can still appear in another.

## iVar variant calling

An [iVar](../../GLOSSARY.md#ivar) call is three programs in a row. `samtools mpileup` walks the alignment and reports what every read says at each position, which is a [pileup](../../GLOSSARY.md#pileup). That output is piped straight into `ivar variants`, which writes a tab-separated table. Then a converter built into LGE turns the table into a [VCF](../../GLOSSARY.md#vcf). All three appear as separate steps in the sidecar. The builders are in `Variants/ViralVariantCallingPipeline.swift`.

### samtools mpileup, as LGE calls it

The mpileup arguments are fixed. No dialog control and no command-line flag changes them.

```bash
samtools mpileup -aa -A -d 600000 -B -Q 20 -q 0 -f reference.fasta alignment.bam
```

| Flag | Meaning | Why LGE sets it |
|---|---|---|
| `-aa` | Report every position, including those with no reads | iVar needs a complete pileup |
| `-A` | Keep read pairs whose mate is unmapped or oddly oriented | [Amplicon](../../GLOSSARY.md#amplicon) pairs often look odd after [primer trimming](../../GLOSSARY.md#primer-trim), and dropping them loses real evidence |
| `-d 600000` | Raise the per-position read cap from the default of 8,000 | Amplicon panels reach tens of thousands of reads at one position |
| `-B` | Turn off [BAQ](../../GLOSSARY.md#baq), a per-base penalty near likely misalignments | BAQ assumes randomly broken DNA and wrongly penalizes bases near primer ends |
| `-Q 20` | Ignore bases whose [Phred score](../../GLOSSARY.md#phred-score) is under 20 | Matches the floor LGE gives iVar |
| `-q 0` | Set no [mapping quality](../../GLOSSARY.md#mapping-quality) floor | Placement is judged later |

The flag most often missing from a hand-built pipeline is `-d 600000`. Without it a position read 20,000 times reports as 8,000, and every [allele frequency](../../GLOSSARY.md#allele-frequency) computed from that pileup is wrong.

### ivar variants, as LGE calls it

```bash
ivar variants -p ivar.tsv-prefix -q 20 -t 0.05 -m 10 -r reference.fasta -g annotations.gff3
```

Text you pass with `--extra-args` goes straight after `variants`, before LGE's arguments. iVar reads the last value of a repeated flag, so LGE's value wins and a `-t` of your own has no effect. `-t` is the Minimum Allele Frequency setting, `--min-af` on the command line, defaulting to 0.05. `-m` is Minimum Depth, `--min-depth`, defaulting to 10. The `-q` floor of 20 and the `-p` prefix are fixed.

`-g` appears only when the [reference bundle](../../GLOSSARY.md#reference-bundle) carries gene annotations, which LGE first writes out as a GFF3 file. If the bundle has none, or that export fails, the flag is dropped without a message, and the calls then carry no [codon](../../GLOSSARY.md#codon) context.

### The same thresholds on other callers

For every caller except iVar and GATK HaplotypeCaller, Minimum Allele Frequency and Minimum Depth are applied after calling, as a `bcftools view -i` step that keeps only the rows meeting both values. iVar applies the two settings itself while calling, and GATK HaplotypeCaller takes neither. The frequency is read from each caller's own field, `INFO/AF` for LoFreq, the per-allele read counts in `INFO/SR` for Medaka, `FORMAT/AF` for Clair3, and the allele depths `FORMAT/AD` for bcftools. When the caller's VCF does not declare the field a threshold needs, LGE skips that threshold and does not record it as applied, so check the recorded parameters before you assume a threshold took effect.

### The four iVar tuning flags do not reach iVar

`--ivar-consensus-af` (default 0.75), `--ivar-merge-af-threshold` (default 0.25), `--ivar-bad-quality-threshold` (default 20), and `--ivar-no-ignore-strand-bias` all go to LGE's own table-to-VCF converter, which runs after iVar finishes. None is passed to `ivar variants`. In the window they are the four controls under **iVar options** in the Call Variants dialog. So running `ivar variants` yourself with the flags LGE records will not reproduce LGE's VCF, because the part these flags control is LGE's own code.

LGE's converter ignores [strand bias](../../GLOSSARY.md#strand-bias) by default, meaning it keeps a call even when the reads carrying the change come mostly from one strand. On amplicon data that imbalance usually reflects the primer layout, so ignoring it is right. `--ivar-no-ignore-strand-bias` turns the filter on for data where the balance is meaningful.

### Codon merging

The converter folds changes inside one codon into a single VCF row with a multi-base [REF and ALT](../../GLOSSARY.md#ref-alt), so the row names the one amino acid they produce together. It merges a group only when every frequency in it is above the consensus threshold, `--ivar-consensus-af`, default 0.75, in `Variants/IVarCodonMerger.swift`. Any other group is written as one row per change, each with the frequency and depth iVar measured. `--ivar-merge-af-threshold`, default 0.25, is recorded with the run, but the merge rule does not read it.

None of this reads [phase](../../GLOSSARY.md#phase), which of a sample's two chromosome copies a change sits on, or [linkage](../../GLOSSARY.md#linkage), whether two changes sit on one molecule, from the reads. The rule rests on arithmetic instead. When two changes both have a frequency above 0.75, more than half of the reads must carry both, assuming the same reads cover both positions. Phased [haplotypes](../../GLOSSARY.md#haplotype) are a separate job, covered in [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md).

## LoFreq variant calling

[LoFreq](../../GLOSSARY.md#lofreq) builds an error model from the base qualities and calls a change where the [alternate reads](../../GLOSSARY.md#alternate-read) clearly outnumber the errors that model expects. In the ordinary case LGE runs one command.

```bash
lofreq call -f reference.fasta -o variants.raw.vcf alignment.bam
```

Your `--extra-args` text goes between `call` and `-f`, before LGE's own flags, so LGE's value wins on a flag you both set. There is no `call-parallel` and no `--no-default-filter` anywhere in LGE.

LoFreq calls no [indels](../../GLOSSARY.md#indel), insertions and deletions, unless `--call-indels` appears in your extra arguments. When LGE sees that exact text it runs two preparation steps first.

```bash
lofreq indelqual --dindel -f reference.fasta -o lofreq.indelqual.bam alignment.bam
lofreq index lofreq.indelqual.bam
lofreq call --call-indels -f reference.fasta -o variants.raw.vcf lofreq.indelqual.bam
```

`indelqual` writes per-base indel quality scores into a copy of the alignment, which LoFreq's indel model needs. A hand-built pipeline that goes straight to `lofreq call --call-indels` reports fewer indels than the data hold, without a message. Because indels are opt-in, LoFreq and bcftools run with defaults on one alignment give very different row counts, much of it bcftools' indels. [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) works through that comparison.

## bcftools variant calling

bcftools runs as `bcftools mpileup` piped into `bcftools call`.

```bash
bcftools mpileup -Ou -A -d 0 -a FORMAT/AD,FORMAT/DP,INFO/AD -f reference.fasta alignment.bam
bcftools call --ploidy 2 -mv -Ov -o variants.raw.vcf
```

`-d 0` removes the per-position read cap. `-a` asks for per-sample allele depths and total depth, which the threshold step above reads. `--ploidy` carries the dialog's **Ploidy** setting, `1` for a haploid genome such as a virus and `2` for a diploid one such as a human. The block shows `2`, the value LGE picks for the HG002 fixture. Your extra arguments go straight after `call`, before LGE's own, and a `--ploidy` among them is refused so that the setting has one source.

## Primer trimming

Primer trimming on an alignment runs `ivar trim`, then sorts and indexes the result, in `Primers/BAMPrimerTrimPipeline.swift`. [Removing primers from reads](#removing-primers-from-reads) covers the step that works on reads instead.

```bash
ivar trim -b scheme.bed -i input.bam -p output-prefix -q 20 -m 30 -s 4 -x 0 -e
```

`-b` is the scheme's [BED](../../GLOSSARY.md#bed) file. Three values describe [sliding-window trimming](../../GLOSSARY.md#sliding-window-trimming), which averages the quality of a short run of bases and cuts where that average first drops too low. `-q` is `--ivar-min-quality` at 20, the average that must hold. `-s` is `--ivar-sliding-window` at 4, the run length in bases. `-m` is `--ivar-min-length` at 30, the shortest read kept. `-x` is `--ivar-primer-offset` at 0, which shifts the primer coordinates when primer bases survive at read ends after a trim that reported success.

`-e` is fixed and keeps reads that match no primer instead of discarding them, so a read from a randomly fragmented library passing through an amplicon bundle is not lost.

Before trimming, LGE matches the scheme's accessions against the sequence names in the alignment's header, and stops with an error naming both when nothing matches. `--target-reference` overrides that match on the command line, as [Primer Scheme Bundles](primer-schemes.md#matching-the-scheme-to-your-alignment) explains.

## Trimming reads with fastp

The **fastp Adapter & Quality Trim** pane runs [`fastq trim`](cli-reference.md#fastq-trim), which builds the [fastp](../../GLOSSARY.md#fastp) arguments in `Ingestion/FastpTrimOptions.swift` and runs them through `Ingestion/FastpPairedRunner.swift`. At the pane's defaults the first call is a paired bundle and the second a single-read one.

```bash
fastp -i r1.fastq -I r2.fastq -o out_R1.fastq -O out_R2.fastq --detect_adapter_for_pe \
    -w 8 -W 4 -M 20 --disable_quality_filtering --disable_length_filtering \
    --json /dev/null --html /dev/null --cut_right
fastp -i reads.fastq -o out.fastq -w 8 -W 4 -M 20 \
    --disable_quality_filtering --disable_length_filtering \
    --json /dev/null --html /dev/null --cut_right \
    -a AGATCGGAAGAGCACACGTCTGAACTCCAGTCA --adapter_fasta fastp-known-adapters.fasta
```

`-W 4` and `-M 20` are **Window Size** and **Threshold**, and `--cut_right` is **Cut Right** under **Mode**. `-w` is the Mac's core count, at most 16. The two `--disable` flags stop fastp from dropping reads by its own quality and length rules, which is why **Filter by Read Length** is a separate step, and the reports go to `/dev/null`, which discards them.

A paired bundle keeps its pairs in one [interleaved file](../../GLOSSARY.md#interleaved-fastq), so LGE first splits it by read name into the two files above. fastp's paired mode then keeps or drops both [mates](../../GLOSSARY.md#mate) together and finds [adapters](../../GLOSSARY.md#adapter) where the mates overlap, and with no adapter named `--detect_adapter_for_pe` adds fastp's own adapter search. That search guesses from the reads fastp meets first, so LGE hands it the pairs in a fixed shuffled order, the same on every rerun. A single-read file with no adapter named gets `-a` with the TruSeq Read 1 adapter and `--adapter_fasta` with five known adapters, TruSeq Read 1 and Read 2, Nextera, and two small RNA adapters. fastp then guesses nothing, and the result does not depend on the order of the reads. The single reads of a file that mixes pairs with single reads run in their own fastp call without those two flags, so fastp guesses their adapter.

Naming an adapter, with **Manual Sequence** in the pane or `--adapter` on the command line, replaces the search with `--adapter_sequence`. In an import recipe the trim step names its kit's pair with `--adapter_sequence` and `--adapter_sequence_r2`, the Nextera pair for the **VSP2 target enrichment** preset and the TruSeq pair otherwise. Your `--extra-args` text comes after LGE's options and, on a single-read file, before the two adapter flags.

## Removing primers from reads

The **Primer Trimming** pane removes PCR primers from the reads themselves, before mapping, by running [`fastq primer-remove`](cli-reference.md#fastq-primer-remove). Its tool calls are built in `Sources/LungfishCLI/Commands/FastqPrimerRemovalSubcommand.swift` and the `+ReadThrough` file beside it. With a typed primer the pane uses [bbduk](../../GLOSSARY.md#bbduk), which runs twice. The block assumes one 24-base primer and a single-read file.

```bash
bbduk.sh in=reads.fastq out=five-prime.fastq ktrim=l k=15 mink=11 hdist=1 rcomp=f \
    restrictleft=91 interleaved=f literal=<primer> qin=33 qout=33 maxcalledquality=93
bbduk.sh in=five-prime.fastq out=trimmed.fastq ktrim=r k=24 mink=11 hdist=1 rcomp=f \
    restrictright=24 interleaved=f literal=<primer-reverse-complement> qin=33 qout=33 maxcalledquality=93
```

The first pass finds the primer as written (`rcomp=f`) and cuts it with every base before it (`ktrim=l`), but only when the match ends within the first 91 bases, the longest primer plus 67. Those 67 bases are a nanopore adapter and barcode that may still sit in front of the primer, and the limit keeps bbduk off a primer of another amplicon deeper inside a long read. `k`, `mink`, and `hdist` are the pane's **k**, **mink**, and **hdist**, where k is the length of the [k-mer](../../GLOSSARY.md#k-mer), or exact-match word, bbduk looks for. A `k` longer than the shortest primer is refused before bbduk starts.

The second pass removes a primer that a read runs through at its far end. A single read loses the primer's reverse complement when it ends within the last 24 bases, the longest primer, matched with a `k` as long as the shortest primer and at most 31. A pair runs `tbo=t interleaved=t` instead, which trims each mate where it overlaps its partner. bbduk drops a read that either pass leaves under 10 bases, such as a [primer dimer](../../GLOSSARY.md#primer-dimer), and in a pair it drops the mate too. The `qin=33 qout=33 maxcalledquality=93` flags set the score encoding and keep scores above Q50, which bbduk would otherwise lower to 50.

With **Reference FASTA** as the **Primer Source**, the pane uses the cutadapt-linked engine instead, which runs [cutadapt](../../GLOSSARY.md#cutadapt) and keeps only reads that hold both primers of an amplicon. A file that mixes pairs with single reads is split by read name, each part runs on its own, and the outputs are joined with the pairs first.

## Mapping

The mappers are built in `Mapping/MappingCommandBuilder.swift`.

```bash
minimap2 -a -x sr -t 8 -R '@RG\tID:...' --secondary=no -o out.sam reference.fasta reads.fastq
bwa-mem2 mem -t 8 -R '@RG\tID:...' index-prefix reads.fastq
bowtie2 -x index-prefix -p 8 --rg-id ... --rg SM:... --rg LB:... --rg PL:... --rg PU:... -S out.sam -1 r1.fastq -2 r2.fastq
bbmap.sh qin=33 ref=reference.fasta out=out.sam threads=8 nodisk=t overwrite=t secondary=f rgid=... rgsm=... rglb=... rgpl=... rgpu=... in=r1.fastq in2=r2.fastq
```

The `\t` and `...` stand for a tab and the sample's own identifiers, which LGE fills in. Three things hold across the mappers. The minimap2 `-x` preset follows the read class of the reads, `sr` for short reads, `map-ont` for Nanopore reads, `map-hifi` for PacBio HiFi reads, and `map-pb` for other PacBio reads, and a preset you choose always wins. A [read group](../../GLOSSARY.md#read-group), the `@RG` header naming the sample, library, and platform, is always written. And [secondary alignments](../../GLOSSARY.md#secondary-alignment), extra lower-scoring placements of one read, are off unless you ask for them. Asking adds `-k 10` on bowtie2. A bundle stored as one file in which every read is followed by its mate maps as pairs, with `-p` on bwa-mem2 and `--interleaved` on bowtie2.

Your extra arguments land in different places. On minimap2, bwa-mem2, and bowtie2 they come after LGE's options and before the output and input files, so your value wins on a flag you both set. On BBMap they come after `qin=33` and before LGE's other options, so your `qin=` wins and LGE's value wins on any other flag you both set.

## Kraken 2 classification

The command is built in `Metagenomics/ClassificationConfig.swift`.

```bash
kraken2 --db database/ --threads 8 --confidence 0.2 --minimum-hit-groups 2 \
    --output out.kraken --report out.kreport --report-minimizer-data reads.fastq
```

| Flag | Meaning | Where it comes from |
|---|---|---|
| `--confidence 0.2` | The share of a read's matches that must agree before Kraken 2 keeps its assignment | The Confidence setting, 0.2 under the default Balanced preset. Raising it drops weakly supported assignments |
| `--minimum-hit-groups 2` | At least this many separate stretches of matching sequence are needed | The Min hit groups setting, `--min-hit-groups` on the command line, 2 under the Balanced preset |
| `--memory-mapping` | Reads the database from disk instead of loading it into memory | Added only when you ask |
| `--quick` | Stops examining a read at its first match | Added only when you ask |
| `--paired` | Declares a paired read set | Added from the input you chose |

`--report-minimizer-data` is always present and adds two columns to the [Kraken 2](../../GLOSSARY.md#kraken2) report, which [Bracken](../../GLOSSARY.md#bracken) needs to redistribute reads to species. An LGE report is therefore eight columns wide rather than the usual six, which matters only to another program expecting six. Your extra arguments come after every LGE flag, so your value wins.

## Assembly

The five assemblers are built in `Assembly/ManagedAssemblyPipeline.swift`. SPAdes, MEGAHIT, and SKESA take short reads. Flye and hifiasm take long ones.

```bash
spades.py --isolate -1 r1.fastq -2 r2.fastq -o out/ --threads 8 --memory 24
megahit -1 r1.fastq -2 r2.fastq -o out/ --num-cpu-threads 1 --min-contig-len 200 \
    --memory 25769803776 --no-hw-accel
skesa --reads r1.fastq,r2.fastq --contigs_out contigs.fasta --cores 8 --memory 24 \
    --min_contig 200 --min_count 2
flye --nano-hq reads.fastq --out-dir out/ --threads 8
hifiasm -o out/prefix -t 8 reads.fastq
```

The memory and minimum contig length values are examples, and each flag appears only when that limit is set. The window sets a memory limit of three quarters of the Mac's memory, capped at 32 GB, and passes MEGAHIT its limit in bytes, so 24 GB becomes 25,769,803,776. The command line sets neither unless you ask.

The `-1` and `-2` form is a pair stored as two files. A bundle that stores its pairs in one interleaved file reaches SPAdes and MEGAHIT as `--12 reads.fastq` and SKESA as `--reads reads.fastq --use_paired_ends`, so the mates are assembled as pairs. A file that mixes pairs with merged or single reads is split by read name first. Its pairs then go in as `-1` and `-2`, and its other reads go beside them as `--merged` and `-s` on SPAdes, `-r` on MEGAHIT, and one more `--reads` each on SKESA. On the command line `--read-layout` says how the records of one file relate, as `auto`, `single-end`, `interleaved`, or `mixed`. The default, `auto`, reads the bundle's metadata and then the read names, as [`assemble`](cli-reference.md#assemble) explains.

SPAdes opens with `--isolate` for one cultured organism, `--meta` for a mixed sample, or `--plasmid`, defaulting to `--isolate`. A MEGAHIT profile is passed as `--presets`. Flye's read mode becomes the flag itself. PacBio HiFi reads take `--pacbio-hifi`, and reads whose names mark them as PacBio subreads take `--pacbio-raw`, Flye's mode for older, noisier PacBio CLR reads. Other long reads take `--nano-raw` when their measured read quality is under Q10, and `--nano-hq` otherwise or when no quality can be measured. A profile you choose replaces that choice. hifiasm gets `--ont` at the front when the reads are Nanopore, and its haploid-viral profile adds `--n-hap 1`, `-l0`, and `-f0` unless your extra arguments set them. hifiasm can exit 0 without writing its contig [graph](../../GLOSSARY.md#assembly-graph), the `<name>.bp.p_ctg.gfa` file, so LGE counts a run without that file as failed.

Three are LGE's own choices. On an Apple Silicon Mac, MEGAHIT runs on one thread whatever **Threads** says, because more threads can crash it, and the note under **Threads** in the assembly dialog says so. MEGAHIT there also gets `--no-hw-accel`, which turns off processor-specific fast instructions, unless your extra arguments already set it. SKESA is pinned to `--min_count 2`, its documented default, because leaving it automatic can produce no contigs at all on a small input. Your extra arguments come after LGE's options on all five, and on hifiasm before the reads file.

### Two settings are ignored on some assemblers

The minimum contig length reaches MEGAHIT and SKESA and never reaches SPAdes, Flye, or hifiasm. The memory limit reaches SPAdes, MEGAHIT, and SKESA and never reaches Flye or hifiasm. [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md) and [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md) say where each lands.

## GATK

HaplotypeCaller is built in `Variants/GATKCommandBuilder.swift`.

```bash
gatk HaplotypeCaller -R reference.fasta -I input.bam -O output.g.vcf.gz \
    --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE \
    --native-pair-hmm-threads 4 -ERC GVCF
```

`--sample-ploidy` is the number of copies of each chromosome, 2 for a human. `--max-alternate-alleles` caps how many different alternate bases GATK weighs at one position. `--pcr-indel-model` sets how much insertion and deletion noise to expect from the library's PCR step. All three default to GATK's own defaults. `--native-pair-hmm-threads` is 4 unless `gatk haplotype-caller --pair-hmm-threads` sets another value. `-ERC GVCF` asks for a [GVCF](../../GLOSSARY.md#gvcf), a VCF with a record for every position that lets several samples be genotyped together later, and is the default of `lungfish-cli gatk haplotype-caller`. GATK HaplotypeCaller in the Call Variants dialog, the window route [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) works through, runs without it, writing an ordinary VCF, and adds `--standard-min-confidence-threshold-for-calling 30` instead.

A GATK track is stored at `variants/gatk/<track-id>.vcf.gz` inside the [bundle](../../GLOSSARY.md#bundle), with a SQLite database beside it. Every other caller writes to `variants/<track-id>.vcf.gz`. In both, `<track-id>` is a generated track id such as `vc-` followed by a long random string, not the track's display name.

## Reaching a flag LGE does not wrap

No dialog shows every flag of its tool. There are three ways around that, each keeping less of the provenance record.

The first is extra arguments, `--extra-args` on most commands, which inserts your text into the command LGE builds and keeps the provenance record. The sections above say whether your value or LGE's wins. Some commands take `--extra-args` as one quoted string and others take a repeatable `--extra-arg`, one argument each time.

The second is `lungfish-cli conda run [--env <env>] <tool-and-args> ...`, which runs a tool from its managed environment and passes its output and [exit status](../../GLOSSARY.md#exit-status) straight through. It writes no provenance record.

The third is running the tool yourself with no LGE involvement, which also writes no record, and gives a loose file where later LGE commands expect an LGE result folder. Prefer the second.

## Reproducibility, honestly

[Determinism](../../GLOSSARY.md#determinism) means that the same command on the same inputs gives the same output. LGE can promise that in some places and not in others.

### What was measured

Only what is listed here was measured, during the manual's 2026-09 checks.

- The MHC genotyping route gave the same 102 allele rows for sample `Animal_01` in a whole-plate run and in a rerun of three of its samples. The agreement matters, not the number.
- Two exports of the same [pivot workbook](../../GLOSSARY.md#pivot-workbook) differ only in `docProps/core.xml`, a timestamp inside the file, so compare the sheets rather than the files.
- MEGAHIT can crash on Apple Silicon even on its one thread, and a crash always ends with a nonzero exit and no [contigs](../../GLOSSARY.md#contig), so a run that does finish can be trusted. The defect registry in [Known defects in this release](troubleshooting.md#known-defects-in-this-release) gives the details, and SPAdes is the alternative for short reads.
- A long-read assembler can report a circular genome, such as the mitochondrion, as a contig about twice its true length. Compare a contig's length with the known genome length, as [When to Assemble](../07-assembly/01-when-to-assemble.md#circular-genomes-trimmed-overlapped-or-walked-twice) explains.
- Tools that run on several [threads](../../GLOSSARY.md#thread) can give slightly different output at different thread counts, so fix `--threads` to one number for every run you compare.

### Cross-architecture and cross-version drift

Some tools use processor-specific instructions, so files can differ byte for byte between two kinds of processor while agreeing scientifically, for example between an Apple Silicon Mac and another machine rerunning a workflow exported from LGE. A byte comparison is the wrong check across processors, and the sidecar's `runtimeIdentity.architecture` field shows when two runs came from different ones.

A minor release of a wrapped tool can change how reads are trimmed or placed without announcing it. Each step's `toolVersion` in the sidecar is how a rerunner catches that. This release pins every tool under one dependency set, listed in [Tool Versions](tool-versions.md), and a sidecar recording other versions came from a different installation.

## Pinning an environment

Reproducing a run months later means installing the same tools at the same versions. A [plugin pack](../../GLOSSARY.md#plugin-pack) pins its tools, but not every package those tools depend on, so reinstalling the same pack later can resolve slightly different underlying packages as the [conda](../../GLOSSARY.md#conda) channels move.

An offline pack copies a pack's installed environments, with a checksum for every file, and installs them on another Mac with no network. It reproduces an environment exactly, where a fresh install may not. [Install a pack without internet access](../01-foundations/07-plugin-packs.md#install-a-pack-without-internet-access) shows the commands, and [Running in CI](06-running-in-ci.md#offline-packs) uses them on a build machine.

`lungfish-cli conda lock --pack <name> --output <file>` writes the requested environment specification, meaning what was asked for, not what was installed, so it does not guarantee an identical rebuild. Its companion `conda install --from-lockfile` refuses by design, as its own help says, because exact reconstruction is not supported.

`lungfish-cli bundle export --export-format container` writes a bundle as an [OCI layout](../../GLOSSARY.md#oci-layout) container image, a single tarball that gives byte-identical output each time the same bundle is exported. Its `--plugin-pack` flag writes the IDs of the packs you name into the image metadata, which records which packs the data was made with but does not carry the tools themselves.

## Shared workstations

Skip this section unless you look after a Mac that several people share. Nothing in it is needed to use LGE on your own Mac.

On a shared Mac, an administrator can put the packs and databases on a larger shared drive so every user draws on one installation. LGE reads the `LUNGFISH_CONDA_ROOT` [environment variable](../../GLOSSARY.md#environment-variable), a named setting the system passes to every program it starts. Set it, and every LGE process, window and command line alike, installs to and reads from that location. To move the whole shared storage folder, databases included, set `LUNGFISH_STORAGE_ROOT` instead. When both are set, `LUNGFISH_CONDA_ROOT` still decides where the tools go.

The pattern that works is to set the variable in a shell startup file the other accounts share, install the packs and databases once from the Plugin Manager as the administrator, then leave the folder readable by everyone but writable only by the administrator. Other users then see the packs and databases as installed and can run analyses with them. An install attempt by another user stops with `conda root is read-only; reinstall as the admin user`, and only the administrator can fix that.

### One Mac, two copies of LGE

A Mac that runs both the Preview and the stable copy of LGE keeps a storage folder for each, `~/.lungfish` and `~/.lungfish-stable`, so a Preview experiment can never disturb the stable copy. The two folders do not cost double. Tool packages land once in `~/.lungfish-shared/conda/pkgs`, a cache both copies list first, and each copy's environments link to it. A database one copy has already installed and verified is cloned into the other copy's folder with an APFS clone, a copy that shares its blocks with the original until one side changes. Cloning only happens on the same APFS volume. If you moved one storage folder to another drive, that copy downloads its own files as before.

Folders that were filled before this sharing existed still hold two full copies. `lungfish-cli storage dedupe` finds identical files across the storage folders and replaces each duplicate with a clone of one kept copy. It reports first and changes nothing until you add `--apply`, and it refuses to apply while a pack or database install is running. Set `LUNGFISH_CONDA_SHARED_PKGS=0` to switch the shared package cache off, or set it to an absolute path to put the cache somewhere else.

## Next

The next appendix is [Shared Projects and Bundle Migration](shared-projects.md), for a project that two people or two Macs work on. See [CLI Reference](cli-reference.md) for every flag of the commands named here, [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) for reading a run record, and [Running in CI](06-running-in-ci.md) for repeating runs on a fresh machine.

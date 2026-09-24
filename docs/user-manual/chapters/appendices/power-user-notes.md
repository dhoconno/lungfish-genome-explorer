---
title: Power User Notes
chapter_id: appendices/power-user-notes
audience: power-user
prereqs: []
estimated_reading_min: 22
task: Look up the exact arguments Lungfish Genome Explorer passes to each wrapped tool, and the limits on repeating a run and getting the same answer.
tags: [reference, power-user, mpileup, ivar, lofreq, bcftools, minimap2, kraken2, assembly, gatk, determinism, reproducibility]
tools: [samtools, bcftools, ivar, lofreq, minimap2, bwa-mem2, bowtie2, kraken2, spades, megahit, skesa, flye, hifiasm, gatk]
entry_points: []
shots: []
illustrations: []
glossary_refs: [allele-frequency, alternate-read, amplicon, argument, baq, bed, bracken, bundle, codon, command-line-flag, conda, contig, dependency-set, determinism, environment-variable, gvcf, haplotype, hg002, indel, ivar, kraken2, linkage, lofreq, mapping-quality, oci-layout, phase, phred-score, pileup, pivot-workbook, plugin-pack, primer-trim, provenance, provenance-sidecar, read-group, ref-alt, reference-bundle, secondary-alignment, sliding-window-trimming, strand-bias, thread, vcf, wrapper]
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

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

## Reproducibility caveats at a glance

The problems in this table stop a rerun from matching the first run. Check for each before you promise anyone an identical result.

| Caveat | What to do |
|---|---|
| A setting that is not passed to the tool | The iVar tuning flags configure LGE's own converter, not iVar ([The four iVar tuning flags](#the-four-ivar-tuning-flags-do-not-reach-ivar)). The minimum contig length and the memory limit never reach some assemblers ([Two settings are ignored on some assemblers](#two-settings-are-ignored-on-some-assemblers)). Read the recorded command in the sidecar rather than the one you meant to run. |
| Your own extra arguments losing to LGE's | On some tools LGE's value comes after yours and wins. Each section below says which way round it is. |
| Tool version drift | Compare each step's `toolVersion` in the two sidecars before comparing results ([Cross-architecture and cross-version drift](#cross-architecture-and-cross-version-drift)). |
| Thread count | Pin `--threads` to one number for every run you mean to compare ([What was measured](#what-was-measured)). |
| A fault in LGE itself | Several faults change what a sidecar records or what a command does. They are known defects, listed with their workarounds in [Known defects in this release](troubleshooting.md#known-defects-in-this-release). |

## Reading a command out of the source

This section is for readers with a copy of the LGE source code. Everyone else can skip to [iVar variant calling](#ivar-variant-calling), since every argument list is quoted in full below.

Each section names the source file that builds its command, under `Sources/LungfishWorkflow/`. The code that builds an argument list only assembles text and runs nothing, so reading it tells you the whole command. Two habits of these builders matter. Some put your extra arguments before LGE's own and some after, and since most tools read the last value of a repeated flag, that order decides whose value wins. And several builders add an argument only when a condition holds, so a flag missing from one run can still appear in another.

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
| `-B` | Turn off [BAQ](../../GLOSSARY.md#baq), a per-base penalty near likely misalignments | BAQ assumes randomly broken DNA and wrongly penalises bases near primer ends |
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

For every caller except iVar, Minimum Allele Frequency and Minimum Depth are applied after calling, as a `bcftools view -i` step that keeps only the rows meeting both values. The frequency is read from each caller's own field, `INFO/AF` for LoFreq and Medaka, `FORMAT/AF` for Clair3, and the allele depths `FORMAT/AD` for bcftools. When the caller's VCF does not declare the field a threshold needs, LGE skips that threshold and does not record it as applied, so check the recorded parameters before you assume a threshold took effect.

### The four iVar tuning flags do not reach iVar

`--ivar-consensus-af` (default 0.75), `--ivar-merge-af-threshold` (default 0.25), `--ivar-bad-quality-threshold` (default 20), and `--ivar-no-ignore-strand-bias` all configure LGE's own table-to-VCF converter, which runs after iVar finishes. None is passed to `ivar variants`. In the window they are the four controls under **iVar Options** in the Call Variants dialog. So running `ivar variants` yourself with the flags LGE records will not reproduce LGE's VCF, because the part these flags control is LGE's own code.

LGE's converter ignores [strand bias](../../GLOSSARY.md#strand-bias) by default, meaning it keeps a call even when the reads carrying the change come mostly from one strand. On amplicon data that imbalance usually reflects the primer layout, so ignoring it is right. `--ivar-no-ignore-strand-bias` turns the filter on for data where the balance is meaningful.

### Codon merging

The converter folds changes inside one codon into a single VCF row with a multi-base [REF and ALT](../../GLOSSARY.md#ref-alt), so the row names the one amino acid they produce together. A group merges if any one of three tests passes, in `Variants/IVarCodonMerger.swift`. Every frequency is above the consensus threshold, `--ivar-consensus-af`, default 0.75. Every frequency lies between 0.40 and 0.60, a band fixed in the code with no setting. Or no two neighbouring frequencies, sorted by value, differ by the merge threshold, `--ivar-merge-af-threshold`, default 0.25, or more.

None of this knows about [phase](../../GLOSSARY.md#phase), which of a sample's two chromosome copies a change sits on. A merged row asserts a codon boundary and nothing about [linkage](../../GLOSSARY.md#linkage), whether the two changes sit on one molecule. Phased [haplotypes](../../GLOSSARY.md#haplotype) are a separate job, covered in [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md).

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

Primer trimming runs `ivar trim`, then sorts and indexes the result, in `Primers/BAMPrimerTrimPipeline.swift`.

```bash
ivar trim -b scheme.bed -i input.bam -p output-prefix -q 20 -m 30 -s 4 -x 0 -e
```

`-b` is the scheme's [BED](../../GLOSSARY.md#bed) file. Three values describe [sliding-window trimming](../../GLOSSARY.md#sliding-window-trimming), which averages the quality of a short run of bases and cuts where that average first drops too low. `-q` is `--ivar-min-quality` at 20, the average that must hold. `-s` is `--ivar-sliding-window` at 4, the run length in bases. `-m` is `--ivar-min-length` at 30, the shortest read kept. `-x` is `--ivar-primer-offset` at 0, which shifts the primer coordinates when primer bases survive at read ends after a trim that reported success.

`-e` is fixed and keeps reads that match no primer instead of discarding them, so a read from a randomly fragmented library passing through an amplicon bundle is not lost.

Before trimming, LGE matches the scheme's accessions against the sequence names in the alignment's header, and stops with an error naming both when nothing matches. `--target-reference` overrides that match on the command line, as [Primer Scheme Bundles](primer-schemes.md#matching-the-scheme-to-your-alignment) explains.

## Mapping

The mappers are built in `Mapping/MappingCommandBuilder.swift`.

```bash
minimap2 -a -x sr -t 8 -R '@RG\tID:...' --secondary=no -o out.sam reference.fasta reads.fastq
bwa-mem2 mem -t 8 -R '@RG\tID:...' index-prefix reads.fastq
bowtie2 -x index-prefix -p 8 --rg-id ... --rg SM:... --rg LB:... --rg PL:... --rg PU:... -S out.sam -1 r1.fastq -2 r2.fastq
bbmap.sh ref=reference.fasta out=out.sam threads=8 nodisk=t overwrite=t secondary=f rgid=... rgsm=... rglb=... rgpl=... rgpu=... in=r1.fastq in2=r2.fastq
```

The `\t` and `...` stand for a tab and the sample's own identifiers, which LGE fills in. Three things hold across the mappers. The minimap2 `-x` preset follows the read type you choose and defaults to `sr`, for short reads. A [read group](../../GLOSSARY.md#read-group), the `@RG` header naming the sample, library, and platform, is always written. And [secondary alignments](../../GLOSSARY.md#secondary-alignment), extra lower-scoring placements of one read, are off unless you ask for them. Asking adds `-k 10` on bowtie2.

Your extra arguments land in different places. On minimap2, bwa-mem2, and bowtie2 they come after LGE's options and before the output and input files, so your value wins on a flag you both set. On BBMap they come first, so LGE's value wins.

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
megahit -1 r1.fastq -2 r2.fastq -o out/ --num-cpu-threads 8 --min-contig-len 200 --no-hw-accel
skesa --reads r1.fastq,r2.fastq --contigs_out contigs.fasta --cores 8 --min_count 2
flye --nano-hq reads.fastq --out-dir out/ --threads 8
hifiasm -o out/prefix -t 8 reads.fastq
```

The `--memory`, `--min-contig-len`, and similar values are examples. They appear only when a memory limit or minimum contig length is set. The window sets a memory limit of three quarters of the Mac's memory, capped at 32 GB, and passes MEGAHIT its limit in bytes. The command line sets neither unless you ask.

SPAdes opens with `--isolate` for one cultured organism, `--meta` for a mixed sample, or `--plasmid`, defaulting to `--isolate`. Flye's read mode becomes the flag itself, so the `nano-hq` profile gives `flye --nano-hq`. hifiasm gets `--ont` at the front when the reads are Nanopore.

Two are LGE's own choices. On Apple Silicon Macs, where LGE also caps MEGAHIT's threads, MEGAHIT gets `--no-hw-accel`, which turns off processor-specific fast instructions, unless your extra arguments already set it. SKESA is pinned to `--min_count 2`, its documented default, because leaving it automatic can produce no contigs at all on a small input. Your extra arguments come after LGE's on all five.

### Two settings are ignored on some assemblers

The minimum contig length reaches MEGAHIT and SKESA and never reaches SPAdes, Flye, or hifiasm. The memory limit reaches SPAdes, MEGAHIT, and SKESA and never reaches Flye or hifiasm. [Running SPAdes](../07-assembly/02-running-spades.md) and [Running Flye or hifiasm](../07-assembly/03-running-flye-or-hifiasm.md) say where each lands.

## GATK

HaplotypeCaller is built in `Variants/GATKCommandBuilder.swift`.

```bash
gatk HaplotypeCaller -R reference.fasta -I input.bam -O output.g.vcf.gz \
    --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE \
    --native-pair-hmm-threads 4 -ERC GVCF
```

`--sample-ploidy` is the number of copies of each chromosome, 2 for a human. `--max-alternate-alleles` caps how many different alternate bases GATK weighs at one position. `--pcr-indel-model` sets how much insertion and deletion noise to expect from the library's PCR step. All three default to GATK's own defaults. `--native-pair-hmm-threads` is 4 unless `gatk haplotype-caller --pair-hmm-threads` sets another value. `-ERC GVCF` asks for a [GVCF](../../GLOSSARY.md#gvcf), a VCF with a record for every position that lets several samples be genotyped together later, and is the default of `lungfish-cli gatk haplotype-caller`. The window's HaplotypeCaller runs without it, writing an ordinary VCF, and adds `--standard-min-confidence-threshold-for-calling 30` instead.

A GATK track is stored at `variants/gatk/<track-id>.vcf.gz` inside the [bundle](../../GLOSSARY.md#bundle), with a SQLite database beside it, where every other caller writes to `variants/<name>.vcf.gz`.

## Reaching a flag LGE does not wrap

No dialog shows every flag of its tool. There are three ways around that, each keeping less of the provenance record.

The first is extra arguments, `--extra-args` on most commands, which inserts your text into the command LGE builds and keeps the provenance record. The sections above say whether your value or LGE's wins. Some commands take `--extra-args` as one quoted string and others take a repeatable `--extra-arg`, one argument each time.

The second is `lungfish-cli conda run [--env <name>] <tool> [args...]`, which runs a tool from its managed environment and passes its output and [exit status](../../GLOSSARY.md#exit-status) straight through. It writes no provenance record.

The third is running the tool yourself with no LGE involvement, which also writes no record, and gives a loose file where later LGE commands expect an LGE result folder. Prefer the second.

## Reproducibility, honestly

[Determinism](../../GLOSSARY.md#determinism) means that the same command on the same inputs gives the same output. LGE can promise that in some places and not in others.

### What was measured

Only what is listed here was measured, during the manual's 2026-09 checks.

- The MHC genotyping route gave the same 104 allele rows for sample `WD1_S148_L001` in a whole-plate run and in a rerun of three of its samples. The agreement matters, not the number.
- Two exports of the same [pivot workbook](../../GLOSSARY.md#pivot-workbook) differ only in `docProps/core.xml`, a timestamp inside the file, so compare the sheets rather than the files.
- MEGAHIT fails most runs on Apple Silicon, three of four in one test. A failure is never silent, since it exits nonzero and writes no [contigs](../../GLOSSARY.md#contig), so a run that does finish can be trusted. SPAdes is the alternative for short reads.
- Flye sometimes, and hifiasm consistently, doubles the circular mitochondrial genome, so the contig holds the genome twice. Compare a contig's length with the known genome length.
- Tools that run on several [threads](../../GLOSSARY.md#thread) can give slightly different output at different thread counts, so fix `--threads` to one number for every run you compare.

### Cross-architecture and cross-version drift

Some tools use processor-specific instructions, so files can differ byte for byte between an Intel Mac and an Apple Silicon Mac while agreeing scientifically. A byte comparison is the wrong check across processors, and the sidecar's `runtimeIdentity.architecture` field shows when two runs came from different ones.

A minor release of a wrapped tool can change how reads are trimmed or placed without announcing it. Each step's `toolVersion` in the sidecar is how a rerunner catches that. This release pins every tool under one dependency set, listed in [Tool Versions](tool-versions.md), and a sidecar recording other versions came from a different installation.

## Pinning an environment

Reproducing a run months later means installing the same tools at the same versions. A [plugin pack](../../GLOSSARY.md#plugin-pack) pins its tools, but not every package those tools depend on, so reinstalling the same pack later can resolve slightly different underlying packages as the [conda](../../GLOSSARY.md#conda) channels move.

`lungfish-cli conda offline-export --pack <id> --output <folder>` copies the installed environments into a folder with a checksum for every file, and `lungfish-cli conda offline-install <pack-folder>` installs them elsewhere with no network. That pair is the route that reproduces an environment today, and [Running in CI](06-running-in-ci.md#offline-packs) uses it.

`lungfish-cli conda lock --pack <name> --output <file>` writes the requested environment specification, meaning what was asked for, not what was installed, so it does not guarantee an identical rebuild. Its companion `conda install --from-lockfile` refuses by design, as its own help says, because exact reconstruction is not supported.

`lungfish-cli bundle export --format container` is meant to write a bundle as an [OCI layout](../../GLOSSARY.md#oci-layout) container image, but the command cannot be run. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

## Shared workstations

Skip this section unless you look after a Mac that several people share. Nothing in it is needed to use LGE on your own Mac.

On a shared Mac, an administrator can put the packs and databases on a larger shared drive so every user draws on one installation. LGE reads the `LUNGFISH_CONDA_ROOT` [environment variable](../../GLOSSARY.md#environment-variable), a named setting the system passes to every program it starts. Set it, and every LGE process, window and command line alike, installs to and reads from that location. To move the whole shared storage folder, databases included, set `LUNGFISH_STORAGE_ROOT` instead. When both are set, `LUNGFISH_CONDA_ROOT` still decides where the tools go.

The pattern that works is to set the variable in a shell startup file the other accounts share, install the packs and databases once from the Plugin Manager as the administrator, then leave the folder readable by everyone but writable only by the administrator. Other users then see the packs and databases as installed and can run analyses with them. An install attempt by another user stops with `conda root is read-only; reinstall as the admin user`, and only the administrator can fix that.

## Next

See [CLI Reference](cli-reference.md) for every flag of the commands named here, [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) for reading a run record, and [Running in CI](06-running-in-ci.md) for repeating runs on a fresh machine.

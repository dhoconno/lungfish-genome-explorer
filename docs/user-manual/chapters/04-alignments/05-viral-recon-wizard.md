---
title: The Viral Recon Wizard
chapter_id: 04-alignments/05-viral-recon-wizard
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming]
estimated_reading_min: 21
task: Run the nf-core/viralrecon pipeline from a four-control wizard so one SARS-CoV-2 amplicon sample yields an alignment, variant calls, a consensus genome, and lineage assignments in one pass.
tags: [alignments, workflows, viralrecon, nf-core, nextflow, amplicon, consensus, sars-cov-2]
tools: [nextflow, nf-core/viralrecon, bowtie2, ivar, bcftools, pangolin, nextclade]
parameters_refs: [workflow.viral-recon]
entry_points:
  - "Tools > Mapping > Viral Recon..."
  - "CLI: lungfish-cli workflow run nf-core/viralrecon"
shots:
  - id: viral-recon-menu-item
    caption: "The open Tools > Mapping submenu, with Viral Recon... as its fifth item below minimap2, BWA-MEM2, Bowtie2, and BBMap."
  - id: viral-recon-wizard-overview
    caption: "The Viral Recon sheet, showing the Viral Recon header and its Docker Desktop note above the Inputs, Primer Scheme, Minimum mapped reads, collapsed Advanced, and Readiness sections."
  - id: viral-recon-advanced-open
    caption: "The Advanced disclosure expanded, showing the annotation note, the Choose GFF... button, and the Extra parameters field with its schema-checking caption."
  - id: viral-recon-inspector-outputs
    caption: "The Inspector after a finished run, listing the Consensus, Lineage, Variants, Quality, and Provenance sections with one row per output file."
illustrations: []
glossary_refs: [alignment-track, amplicon-dropout, bam, consensus-fasta, container, docker, ivar, lineage, mosdepth, multiqc, nextflow, nf-core, operations-panel, primer-scheme, provenance, reference-bundle, run-bundle, sample-sheet]
features_refs: [align.viral-recon]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

Every chapter before this one asked you to run a single operation and look at what it produced. Map the reads, then trim the primers, then call the variants, then build a consensus. Each step is a separate dialog, and you decide between them whether the result is good enough to carry forward. A [pipeline](../../GLOSSARY.md#nextflow) chains those steps together and runs them without stopping to ask. You supply reads and a primer scheme at one end and collect an alignment, a variant table, a consensus genome, and a stack of quality reports at the other.

The pipeline behind this chapter is [nf-core/viralrecon](../../GLOSSARY.md#nf-core), an openly published viral reconstruction workflow. Reconstruction here means rebuilding the sample's own genome sequence from reads compared against a known reference. nf-core is a community that curates pipelines written in [Nextflow](../../GLOSSARY.md#nextflow), a language for describing analysis steps and the files that pass between them.

Five programs do the work inside viralrecon, and each one owns a single step.

| Program | What it contributes |
|---|---|
| Bowtie2 | Places each read at the position on the reference it matches best |
| [iVar](../../GLOSSARY.md#ivar) | Cuts primer sequence off the read ends, then calls the variant positions |
| BCFtools | Writes the [consensus genome](../../GLOSSARY.md#consensus-fasta), the sample's own sequence with its variants applied |
| Pangolin | Assigns the consensus a SARS-CoV-2 [lineage](../../GLOSSARY.md#lineage) name |
| Nextclade | Assigns the same consensus a clade under a second naming system |

Lungfish Genome Explorer (LGE) pins release 3.0.0 of the pipeline. Pinning means fixing the version so it never moves under you, and LGE has already done it for you by recording the revision in its tool lock manifest, the file that names the exact version of every outside program the app runs. The same reads therefore give the same answer months apart.

The Viral Recon wizard is LGE's front end onto that pipeline. It shows four controls. Everything else the pipeline needs, and there is a great deal of it, the wizard settles for you. It reads the sequencing platform, meaning the kind of machine that produced the reads, out of the metadata your read bundle recorded when the reads were imported rather than asking you for it. It then writes the [samplesheet](../../GLOSSARY.md#sample-sheet), a small table listing which read files belong to which sample, obtains the reference genome, and stages the primer files. Just before Nextflow starts, and never after, it records a [run bundle](../../GLOSSARY.md#run-bundle) describing exactly what it is about to do. When the run finishes, LGE copies the outputs back into your project and registers the alignment, variants, and consensus as tracks over one [reference bundle](../../GLOSSARY.md#reference-bundle). A track is one layer of data drawn over a genome, so three tracks over one genome means three views of the same coordinates.

The wizard works for one virus only, and that narrowness is worth stating plainly. The reference is always the Wuhan-Hu-1 genome `MN908947.3`, which is why the sheet offers no reference control at all. Every read the pipeline handles is compared against that one fixed genome, and every position it reports is a position on it. The trailing `.3` is the version of that GenBank record rather than a third genome, and this is the record every SARS-CoV-2 result in the literature is reported against. The protocol is always [amplicon](../01-foundations/03-amplicon-vs-shotgun.md), meaning the virus was amplified in numbered pieces by PCR rather than sheared at random. A SARS-CoV-2 [primer scheme](../../GLOSSARY.md#primer-scheme) is required before the run will start. The rule that follows is simple. Use the wizard when your sample is SARS-CoV-2 amplicon material and you want the whole standard analysis in one pass. For any other virus, or a shotgun library, assemble the individual mapping, primer-trim, and variant-calling dialogs from the earlier chapters instead.

This chapter uses a SARS-CoV-2 dataset because viralrecon is a viral pipeline by design and the wizard refuses every other organism, so no human or macaque example is possible here.

## Why you would do this

Running the four steps by hand is not hard, and the earlier chapters show that it teaches you a great deal about what each one does. The case for a pipeline is not that it is easier. It is that it is the same every time.

Consider a laboratory sequencing twenty SARS-CoV-2 samples a week for public health surveillance. Every sample needs the same treatment, and the interesting comparison is between one sample and another rather than between two runs of the same sample. If sample 7 was mapped with slightly different settings than sample 12, any difference you see between their consensus genomes might be biology or might be the settings, and you have no way to tell which. A pipeline removes that doubt because every sample gets the same settings. Every sample passes through identical steps with identical parameters, so a difference in the output is a difference in the sample.

The second reason is completeness. viralrecon produces outputs you would probably not build by hand, and two of them matter more than they look. [Amplicon dropout](../../GLOSSARY.md#amplicon-dropout) is when one amplicon fails to amplify, so no reads cover that stretch of the genome and the variant caller reports nothing there. On screen, no reads and no variants look exactly the same as a stretch that matched the reference perfectly, which is the most dangerous way for an analysis to be wrong. The per-amplicon coverage table is the only thing that tells the two apart, because it shows the missing reads directly. The consensus genome, meanwhile, arrives already assigned to a Pangolin lineage and a Nextclade clade, which is the form a surveillance database expects.

This chapter works against the SRR36291587 SARS-CoV-2 reads, a QIAseq Direct amplicon library of 86,281 paired-end Illumina read pairs from a public NCBI Sequence Read Archive run. Paired-end means each fragment was read from both ends, so the two reads of a pair sit a known distance apart on the genome. The library is large enough to behave like a real patient sample rather than a teaching toy.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the SRR36291587 SARS-CoV-2 reads. The reads themselves are too large to store on GitHub, so fetch them from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The supporting files sit with the manual's practice data on GitHub at

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/Tests/Fixtures/sarscov2-srr36291587

and you do not need to download them for this chapter, because the wizard obtains its own reference.

This pipeline runs inside Docker containers, so Docker Desktop must be installed and running. A [container](../../GLOSSARY.md#container) is a packaged copy of a program together with everything it needs to run, which is how a pipeline guarantees that the Bowtie2 on your Mac behaves like the Bowtie2 on everyone else's. [Docker](../../GLOSSARY.md#docker) is the software that runs those containers, and Docker Desktop is its Mac application, downloaded from https://www.docker.com/products/docker-desktop/ rather than from the LGE Plugin Manager. Start it before you open the wizard and leave it running for the whole analysis. You can tell it is running by the small whale icon in the Mac menu bar at the top right of the screen. Docker is also the only execution profile that reaches a working run here. An execution profile is the pipeline's setting for where its programs come from and run, and this wizard offers no choice of one because the app will not start the run any other way.

Nextflow itself comes with the Required Setup pack, which means you have it already if the app opened your project at all and there is no check for you to run. See [Plugin Packs](../01-foundations/07-plugin-packs.md) in the rare case the Plugin Manager shows that pack as not yet installed.

The first run also downloads two things over the internet. LGE fetches the `MN908947.3` reference from NCBI GenBank if your project does not already hold it, and Nextflow pulls the pipeline's container images. Both are cached afterwards, so a second run skips them.

## Procedure

The worked example runs the SRR36291587 reads through the pipeline using the QIAseq Direct scheme, which is the scheme this library was actually prepared with.

### Opening the wizard

1. Import the SRR36291587 reads into the project if they are not already there, following [Importing Sequencing Reads](../03-reads/01-importing-fastq.md). The imported reads appear as one row in the left sidebar. Click that row once to highlight it, which selects the bundle rather than opening it. The wizard takes whatever is selected as its input, so selecting the wrong thing is the usual way to reach a sheet whose Readiness line names a missing input and whose Run button stays greyed out.

2. Choose **Tools > Mapping > Viral Recon...**. It is the fifth item in that submenu, below minimap2, BWA-MEM2, Bowtie2, and BBMap.

    Note. Viral Recon sits among the mappers because it produces an alignment as they do. The separate **Workflow Operations...** item elsewhere in the Tools menu is a general Nextflow and Snakemake runner rather than this wizard.

    <!-- SHOT: viral-recon-menu-item -->

3. Read the sheet from the top. It opens with a heading reading Viral Recon and one line beneath it saying "SARS-CoV-2 consensus and variant analysis from FASTQ bundles. Requires Docker Desktop." Below that heading sit four sections in a fixed order. Inputs, Primer Scheme, Minimum mapped reads, and Readiness, with a collapsed Advanced section sitting between the third and the fourth. A disclosure is a collapsible section, closed until you click its triangle.

    <!-- SHOT: viral-recon-wizard-overview -->

### Filling in the four controls

1. Check the **Inputs** summary. One selected bundle shows its path relative to the project, which for these reads reads `Imports/SRR36291587.lungfishfastq`, and several selected bundles show a count instead. Underneath sits a line reading `Platform: Illumina` or `Platform: Oxford Nanopore`, which LGE read off the bundle metadata rather than asking you. A **Platform** control with an Illumina and a Nanopore segment appears here only when that detection failed, so most runs never see it at all. Mixing platforms in one selection is refused outright, with a message asking you to split the run by platform, which is easy to trigger by shift-clicking a whole folder of bundles where some were sequenced on a MiSeq and others on a MinION.

2. Open the **Primer Scheme** menu and choose **QIAseq Direct SARS-CoV-2 with Booster A**. The menu holds the same eight bundled SARS-CoV-2 schemes the primer-trim dialog offers, each marked Built-in, plus any `.lungfishprimers` folder in the project's own Primer Schemes folder, marked Project. Under the menu a caption names the scheme's accession, its primer count, and its amplicon count. For this scheme it reads `MN908947.3 · 563 primers · 223 amplicons`, and those are that one scheme's own fixed numbers rather than anything measured from your reads, so a different scheme shows different ones. The primer count should be roughly twice the amplicon count, since each amplicon needs a primer at each end. Match the caption against the numbers your kit's documentation gives, because a wrong scheme trims the wrong positions and nothing in the interface will tell you. When you have no kit box in hand, the scheme name is usually recorded on the kit insert or in the sample metadata that came with the reads, and otherwise the person who prepared the library is the one to ask.

3. Leave **Minimum mapped reads** at 1000 unless you have a reason to move it. It is the number of reads that must align to the virus before a sample is analysed at all, and a sample below it is dropped rather than given a consensus built on too little evidence.

4. Leave **Advanced** collapsed. It holds a replacement annotation file and a free-text parameter field, and a standard run needs neither. The picture below is posed with the section clicked open so you can see what is inside, which is the one place the illustration and the procedure differ.

    <!-- SHOT: viral-recon-advanced-open -->

5. Read the **Readiness** line at the foot of the sheet. When everything is set it reads "Ready to run Viral Recon." and Run is enabled. When something is missing it names only the first missing piece, not all of them, working through inputs, then a platform, then a scheme, so a second message can appear after you fix the first.

### Running and watching

Click **Run**. LGE writes a `viralrecon.lungfishrun` bundle into the project's `Analyses/` folder, recording the pipeline name, the pinned release, the executor, the inputs, and every parameter, then launches Nextflow from it. A run bundle is a folder holding the full description of one run, so a colleague can see what was asked for without rerunning anything.

Watch the row titled `Viral Recon` in the [Operations Panel](../../GLOSSARY.md#operations-panel), which you open with **Operations > Show Operations Panel** (Cmd-Shift-P). Its detail line names the platform, the sample count, and the reference accession. Expand the row to read the pipeline's own output as it streams in, which is how you follow a long run. Right-clicking the row copies a text record of exactly what the app asked the pipeline to do, which is worth pasting into an email or a lab notebook when a run fails and someone else has to work out why.

Leave the app running and the Mac awake meanwhile. This is a genuine multi-step pipeline over a real amplicon library, and it takes far longer than any single dialog in the earlier chapters. No measured time is quoted here because no timed run of this fixture has been recorded, so plan for an unattended stretch rather than a coffee break.

When the run succeeds, LGE copies the outputs into a new folder under `Analyses/viralrecon-<timestamp>/` and adds it to the sidebar. Clicking it opens the reference bundle inside it rather than the folder itself, because the alignment, the variants, and the consensus are all registered as tracks over that one genome.

## Settings

The wizard's five settings are documented below. Three sit in plain view and two live inside the Advanced disclosure. Each entry ends with a short sentence naming how the setting reaches the command line, and a reader working only in the app can skip that closing sentence every time. One label below ends with a stray colon before its period, which is copied from the label the sheet itself draws, so no word is missing there.

**Platform.** Tells the pipeline which sequencing machine produced the reads, because short paired Illumina reads and long Nanopore reads pass through different steps of the workflow. The default is Illumina, and this control appears at all only when the selected bundles do not name their own platform, so a normal run never shows it. Set it by hand when the Readiness line says the platform could not be detected, which happens when reads are copied out of a bundle and back in as bare files, because the small metadata file that recorded the machine does not travel with them. On the command line this is `--param platform=<illumina|nanopore>`, where the angle brackets and the upright bar mean you type one of the two words shown and no brackets.

**Scheme.** Names the set of PCR primers used to amplify the virus, so the pipeline knows where each amplicon starts and ends and can cut the primer sequence off the reads. The default is the first scheme in alphabetical order, which is ARTIC SARS-CoV-2 V3 marked Built-in. That default was not chosen for your sample and is almost always the wrong one, so change it on every run unless your kit really is ARTIC V3. Always match the scheme to the kit the wet-lab protocol used, because a mismatched scheme trims the wrong positions and leaves real primer sequence behind. Primer bases are copies of the primer rather than of the sample, so leaving them in fakes variant calls at the amplicon edges. On the command line this is `--param primer_bed=<path>`, together with `--param primer_left_suffix` and `--param primer_right_suffix` read off the scheme.

**Minimum mapped reads:.** Sets how many reads must align to the SARS-CoV-2 genome before a sample is kept, and a sample with fewer is dropped from the run rather than given a consensus sequence built on too little evidence. The default is 1000, and the small up and down arrows beside the field move the number in hundreds anywhere from 1 to 1,000,000, though you can also select the field and type a value straight in. Lower it when you deliberately sequenced low-titre samples, meaning samples carrying very little virus, and want a partial consensus anyway. Raise it when you would rather see nothing than a genome full of unresolved positions. On the command line this is `--param min_mapped_reads`.

**Annotation.** Points the run at a gene annotation file, a General Feature Format or GFF file listing where each gene sits on the genome, so a variant is reported as falling inside a named gene rather than at a bare position. The default is none, because the reference LGE downloads already carries its own GFF3 annotations, which is what the note above the button says. Most readers will never change this. Choose a file only when you hold a curated annotation that differs from the reference's own, for example one with an added or renamed open reading frame, which is a stretch of sequence read as one protein-coding unit, and a Clear button appears beside the chooser once you have picked one. On the command line this is `--param gff`.

**Extra parameters.** Passes further pipeline parameters straight to viralrecon. Each one is two dashes, then the parameter name, then a space, then the value, and several are separated by spaces, so `--variant_caller bcftools --skip_fastqc true` sets two of them. Type the dashes exactly as shown. The default is empty, and each name you type is checked against the pipeline's own parameter list, published at https://nf-co.re/viralrecon/3.0.0/parameters, before the run starts, so a misspelling is refused at the sheet rather than several minutes into a run. Use it for a pipeline option the wizard does not expose, and expect a parameter the wizard owns to be refused with a message naming it. On the command line this is `--param`.

Two groups of parameters behave differently in that field, and the distinction is worth knowing before you type into it. Parameters the wizard owns are refused, because overriding them would contradict the inputs you chose on the sheet. Those are `input`, `outdir`, `platform`, `protocol`, the four primer parameters `primer_bed`, `primer_fasta`, `primer_left_suffix`, and `primer_right_suffix`, then `genome`, `fasta`, `gff`, `fastq_dir`, `sequencing_summary`, and the two Freyja skips `skip_freyja` and `skip_freyja_boot`. Everything else the pipeline defines is accepted, including `variant_caller`, `consensus_caller`, `min_mapped_reads`, `max_cpus`, `max_memory`, and every skip step other than Freyja's.

## Reading the results

A finished run leaves a folder under `Analyses/viralrecon-<timestamp>/`. Click it in the sidebar and the viewport opens the `MN908947.3` reference bundle it contains, with three layers over one coordinate system, meaning positions counted along the reference genome. The [alignment track](../../GLOSSARY.md#alignment-track) is the primer-trimmed [BAM](../../GLOSSARY.md#bam) the variant caller actually read, so the reads you look at and the calls you read are the same evidence. The untrimmed alignment is kept too, in the raw pipeline output tree beside the bundle, and it is there for checking rather than for reading. The variant track holds the iVar calls, and you read them on the Variants tab of the table drawer exactly as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) describes. The consensus is the sample's own genome sequence.

Do not assume the consensus lines up with the reference position for position. On one recorded run of SRR11140748, a different SARS-CoV-2 sample and not the fixture this chapter uses, the consensus came out 29,900 bases against a 29,903 base reference. BCFtools applied that sample's deletions when it built the sequence, among them an `AATT` becoming a single `A` at position 20,297, a loss of three bases. A shortfall of a few bases is expected on any sample carrying deletions. LGE corrects for those missing bases when it draws the consensus, so that position 500 on the reference still points at the matching base of the consensus rather than at whichever base happens to be five hundredth in the file.

The rest of the run is catalogued in the Inspector, grouped by what each file answers rather than by which directory the pipeline wrote it to. The sections appear in a fixed order, most interpreted result first, and only sections with files in them appear at all.

<!-- SHOT: viral-recon-inspector-outputs -->

| Section | Rows you will see |
|---|---|
| Consensus | Consensus Sequence, the assembled genome for this sample |
| Lineage | Pangolin Lineage and Nextclade Clade, two independent assignments |
| Variants | Variant Calls, every position where the sample differs from the reference |
| Quality | Run Quality Summary, the two coverage tables, and the read reports |
| Provenance | Sorted Alignment and Alignment Index, the evidence files the rest was derived from rather than an interpretation |

Read the Quality section first, before you trust anything above it. Run Quality Summary is one row per sample carrying read counts, coverage, and variant totals, which is the fastest way to see whether the run is worth reading at all. Coverage Depth by Amplicon is the [mosdepth](../../GLOSSARY.md#mosdepth) table giving read depth for each amplicon separately, and it is the table that catches dropout. Read depth is the number of reads stacked over one position of the genome. Coverage Depth Across Genome gives the same measure along the whole genome. Full Run Report is the [MultiQC](../../GLOSSARY.md#multiqc) page combining every step of the run, and clicking it leaves LGE and opens the page in your web browser.

The two lineage rows deserve a word, because they are the pipeline's most quotable output and the easiest to over-read. Pangolin assigns a SARS-CoV-2 lineage name and reports how confident it is. Nextclade assigns a clade under a different naming system and adds its own per-sample quality flags. They are separate tools reading the same consensus, so agreement between them is reassuring and disagreement is a signal to look at coverage before believing either. No confidence figure is quoted here, because no run of this fixture has been recorded to read one off.

The Alignment Index in that last row is a small helper file that lets the app jump straight to any position of the alignment instead of reading it from the start, and you will never need to open it yourself. The raw pipeline output tree is preserved untouched beside the bundle rather than moved into it, so the [provenance](../../GLOSSARY.md#provenance) record stays checkable against what Nextflow actually wrote. The bundle keeps its own copies of the consensus, lineage, and report files, which is why the Inspector still resolves after that tree is cleaned up.

## What good looks like

Four checks, in order. A failure at any one of them makes the checks after it meaningless, so work down the list rather than picking the one that interests you.

First, confirm the sample was not dropped. A sample with fewer mapped reads than the Minimum mapped reads threshold produces no consensus at all, so an empty Consensus section usually means the pipeline set that sample aside on purpose rather than that the run broke.

Second, read the per-amplicon coverage. Every amplicon should carry reads. An amplicon at or near zero depth is dropout, and the stretch of genome under it has no evidence either way, so the absence of variant calls there means nothing at all. No cut-off depth is quoted here because none has been measured on this fixture, so read the column against the other amplicons of the same run and treat any amplicon far below its neighbours as suspect. Amplicon dropout is common in real surveillance material and is not by itself a reason to discard a sample, but it is always a reason to qualify what you say about that region.

Third, look at the consensus for runs of `N`. The letter `N` stands for an unknown base, one the pipeline had too little evidence to name, which is what masking means. A consensus that is mostly `N` is a low-coverage sample rather than a novel genome. No percentage of `N` is given here as a pass mark, because that threshold depends on the surveillance programme you report to rather than on the pipeline. Where the `N` runs fall should match the amplicons the coverage table showed as thin, and a mismatch between the two is worth investigating before you go further.

Fourth, compare the two lineage calls. Pangolin and Nextclade reading the same consensus should tell a consistent story. When they disagree, or when Pangolin reports low confidence, the usual cause is a consensus carrying too many masked positions for either tool to place it. That sends you back to the coverage table rather than to the lineage call.

Freyja is worth naming here because you will see it referred to in the pipeline's own documentation and will not see it in your results. viralrecon's Freyja lineage-abundance step and its bootstrap are always skipped and cannot be turned back on. The pipeline pins Freyja to a container built for Intel processors only. Macs have shipped with Apple Silicon chips since late 2020, and you can check yours under **Apple menu > About This Mac**, where an Apple Silicon machine reads M1 or later. On those Macs the helper processes Freyja's bootstrap step starts are killed, which fails the whole run after every other output has already been written. LGE runs Freyja natively from the wastewater-surveillance pack instead, where a real Apple Silicon build exists, and [Running Freyja](../06-classification/07-running-freyja.md) covers that path. Assembly and Kraken2 are also skipped by default, though those two you can switch back on with `--skip_assembly false` or `--skip_kraken2 false` in the Extra parameters field.

## On the command line

This section is optional. A reader working entirely in the app can stop at the previous section and lose nothing.

The wizard builds a `lungfish-cli` command and runs it, so the command line is the same path rather than a parallel one. The difference is the input. The wizard writes the pipeline's samplesheet for you from the bundles you selected, while on the command line you write it yourself and pass exactly one with `--input`.

The block below is a hand-written command that reproduces the procedure, not a transcript of what the wizard itself runs. It differs in two places. For the reference the wizard stages a local copy and passes `--param fasta=` and `--param gff=` where the block passes `--param genome=MN908947.3`, and it writes its run bundle with `--bundle-path` where the block uses `--bundle-root`. Both forms are accepted.

```bash
lungfish-cli workflow run nf-core/viralrecon \
  --executor docker \
  --version 3.0.0 \
  --input samplesheet.csv \
  --results-dir Analyses/viralrecon-results \
  --expected-output Analyses/viralrecon-results \
  --bundle-root Analyses \
  --param platform=illumina \
  --param protocol=amplicon \
  --param primer_bed=Primer\ Schemes/QIASeqDIRECT-SARS2.lungfishprimers/primers.bed \
  --param genome=MN908947.3 \
  --param min_mapped_reads=1000 \
  --cpus 8 \
  --memory 8.GB
```

`viralrecon` is accepted as shorthand for `nf-core/viralrecon`. The backslash before the space in the primer path is not a typing mistake. It tells the shell that the space belongs to the `Primer Schemes` folder name rather than separating two arguments. The parameters the wizard refuses in its Extra parameters field, `primer_bed` and `genome` among them, are required here, because on the command line there is no wizard control that owns them.

Six options are worth knowing beyond the ones above. `--prepare-only` writes the run bundle and prints the command preview without launching Nextflow, which is how you inspect a run before committing to it. `--dry-run` validates without executing. `--params-file` reads parameters from a JSON or YAML file instead of repeating `--param`. `--repeat-from <bundle>` validates an earlier run bundle and then starts a fresh attempt from it, which is the reproducibility path. `--resume` continues from the last checkpoint of an interrupted run. `--workdir` overrides where Nextflow keeps its intermediate files. The `--cpus 8` and `--memory 8.GB` in the block match the wizard's own defaults on a machine with eight or more cores. On a smaller Mac, set `--cpus` to the number of cores you have and leave `--memory` alone.

Two behaviours will surprise you if you read `--help` alone, and neither is a bug worth reporting. `--executor` accepts `docker`, `conda`, and `local`, then refuses everything but `docker` with a message saying so. The other two words are accepted only because the flag is shared with other workflows, since release 3.0.0 defines no local profile and LGE never enables Nextflow's conda support for it. `--timeout` is accepted in the same way and then has no effect here, because that flag belongs to the local-workflow path where it does work.

`lungfish-cli provenance bibliography <bundle>` reads any bundle carrying LGE provenance and prints a first-pass citation list, which is where a methods section starts.

## Next

That closes this part. Continue to [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md), which walks through by hand the same variant calling the pipeline just did silently. Run it after the pipeline rather than instead of it. Doing the steps yourself is how you find out which settings the pipeline chose for you and what you gave up by letting it choose.

---
title: Nanopore Variant Calling
chapter_id: 05-variants/04-nanopore-variant-calling
audience: analyst
prereqs: [05-variants/01-calling-variants-from-amplicons, 03-reads/07-ont-runs]
estimated_reading_min: 10
task: Call variants from Oxford Nanopore amplicon reads using Medaka or Clair3.
tags: [variants, medaka, clair3, nanopore, ont, long-read]
tools: [medaka, clair3]
entry_points:
  - "Inspector > Analysis > Variant Calling > Call Variants (Medaka tab)"
  - "Inspector > Analysis > Variant Calling > Call Variants (Clair3 tab)"
  - "CLI: lungfish variants call --caller medaka"
  - "CLI: lungfish variants call --caller clair3"
shots: []
planned_shots:
  - id: variant-call-dialog-medaka
    caption: "The Variant Calling dialog with Medaka selected on the tool sidebar and the empty model field showing its placeholder."
  - id: medaka-model-field
    caption: "The free-text Medaka model field with a basecaller model string typed in and the Run button enabled."
illustrations: []
glossary_refs: [variant-caller, basecaller, simplex-read, duplex-read]
features_refs: [variants.call]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Oxford Nanopore reads have a different error profile than Illumina. Per-base accuracy on a modern R10.4.1 flow cell sits around Q15 to Q20 for simplex reads (roughly 1 to 3 percent error per base) and reaches Q30 or higher for duplex reads, which is comparable to Illumina. The errors are not random. They cluster near homopolymer runs and certain k-mers that the basecaller has trouble resolving, and their shape changes with each release of the basecaller and with each pore chemistry.

Generic variant callers struggle with this. iVar and LoFreq both assume Illumina-grade per-base quality scores, and on raw ONT data they will either flag every homopolymer as a variant or miss real low-frequency variants in the noise. The right caller for ONT data is one that has learned the basecaller's error profile. In Lungfish, the ONT-specific choices are **Medaka** and **Clair3**, both model-backed callers keyed to specific basecaller versions and pore chemistries.

The catch is that the model has to match. A Medaka model trained against Dorado v4.2.0 simplex output will give silently worse results on reads basecalled by Guppy v6, and vice versa. Before you call variants you need to know which basecaller produced the FASTQ.

The practical takeaway: confirm the basecaller version that produced your ONT reads, type the matching Medaka model string or Clair3 model path into the Variant Calling dialog's model field, and treat any "unknown" answer as a flag to stop and investigate before calling variants.

## What you will learn

Expect to come away knowing which Medaka or Clair3 model to pick for a given ONT run, how to drive the Variant Calling dialog with an ONT caller selected, and how to read the resulting VCF. You will also learn what to do when the basecaller version is missing from the run metadata.

## A note on fixture status

This chapter is partially aspirational. The Lungfish test fixture set does not yet contain a public ONT amplicon SARS-CoV-2 run with full provenance. The dialog flow below is exercised against a hypothetical run we refer to as `ONT-SAMPLE-01`. When a real fixture lands (the candidate is an ARTIC v3 SARS-CoV-2 run from the ENA with a known Dorado basecall version), the worked example will be re-run against that fixture and the screenshots will replace the planned shot markers. The dialog flow itself is current.

## Choosing the right Medaka model

Medaka model names encode the pore chemistry, the basecaller chemistry preset, the speed mode, the basecaller accuracy mode, and the basecaller version. The string `r1041_e82_400bps_sup_v4.2.0` decodes as: R10.4.1 pore, E8.2 chemistry preset, 400 base-per-second sampling, super-accuracy basecalling, Dorado v4.2.0. If any of those five tokens disagree with how your reads were produced, the model is wrong for your data.

The table below lists the models you are most likely to need. The dialog does not list them for you: you type the exact string into the model field, so confirm it against your basecaller output (the next section shows how) rather than relying on the app to offer it.

| Medaka model | Pore | Basecaller | Mode | Use when |
|---|---|---|---|---|
| `r1041_e82_400bps_sup_v4.2.0` | R10.4.1 | Dorado v4.2.x | Super-accuracy | Recent (2024-2025) ONT runs at 400 bps with `dorado basecaller --model sup` |
| `r1041_e82_400bps_hac_v4.2.0` | R10.4.1 | Dorado v4.2.x | High-accuracy | Recent runs basecalled with `--model hac` (faster, slightly less accurate) |
| `r1041_e82_400bps_sup_v5.0.0` | R10.4.1 | Dorado v5.0.x | Super-accuracy | Reads basecalled with Dorado 5.0 or later |
| `r941_min_sup_g507` | R9.4.1 | Guppy v5.0.7 | Super-accuracy | Older R9.4.1 runs basecalled by Guppy 5; still common in legacy data |
| `r941_prom_sup_g507` | R9.4.1 (PromethION) | Guppy v5.0.7 | Super-accuracy | Older PromethION R9.4.1 runs |

Mismatched model selection is the single most common reason ONT variant calls go quietly wrong. Picking a model whose pore chemistry is off by one generation (R9.4.1 model on R10.4.1 reads, for example) typically inflates the false-positive rate around homopolymers and depresses sensitivity at real low-frequency variants, without producing any error message. The VCF will look reasonable, just wrong.

## What to do when the basecaller is unknown

ONT FASTQ files written by Dorado record the basecaller model in the read header. You can confirm it from the terminal:

```bash
zcat ONT-SAMPLE-01.fastq.gz | head -n 1
```

A Dorado-basecalled read header looks like this. The `model_version_id` field is the value you want.

```
@abcd1234-... runid=... ch=42 start_time=2025-03-14T12:00:00Z model_version_id=dna_r10.4.1_e8.2_400bps_sup@v4.2.0 ...
```

Translate that field into the matching Medaka model: `dna_r10.4.1_e8.2_400bps_sup@v4.2.0` becomes `r1041_e82_400bps_sup_v4.2.0`.

If the header is silent (older Guppy basecalls did not always embed the model, and some downstream tools strip the optional fields), fall back in this order. Check the run's MinKNOW or MinION report PDF; it carries the basecaller version in the run summary. Ask whoever produced the data; the wet-lab record usually has it. As a last resort, choose the most recent R10.4.1 super-accuracy model and treat the resulting VCF as a draft. Re-call once the model is confirmed. Do not pick a model at random and ship the call set as final.

## Procedure

The procedure assumes you have already imported the ONT run as described in [ONT Runs](../03-reads/07-ont-runs.md) and that the reference bundle for your target genome is already attached to the project. The four steps below mirror the Illumina amplicon procedure but swap the mapping preset and the variant caller.

### Step 1. Map ONT reads with the map-ont preset

Mapping in the GUI is a two-step selection. You do not pick the reads or the mapper inside the wizard. First, in the sidebar, click the ONT FASTQ bundle so it is the selected item. ONT runs are single-end, so the run will not look for an `_1` / `_2` pair. Then choose `Tools > FASTQ/FASTA Operations > Mapping…` and click the `minimap2` tool row. The wizard opens already knowing the reads (your sidebar selection) and the mapper (the row you clicked).

The wizard has five sections: `Reference`, `Preset`, `Read Group`, `Input Compatibility`, and `Advanced Settings`. Under `Reference`, choose the target bundle. Under `Preset`, choose `Map ONT (map-ont)`, which configures minimap2 for noisy long reads. Do not pick `Short-read` for ONT data; the preset is wrong and the resulting alignment will be unusable for variant calling. Click `Run`.

When the operation finishes, a fresh alignment track named `minimap2 Mapping` (the mapper name plus "Mapping") appears under `Alignments` in the sidebar. You can rename it.

### Step 2. Primer-trim if the data is amplicon

If the run is amplicon-sequenced (ARTIC, Midnight, QIAseq Direct ONT), primer-trim the alignment exactly as you would for Illumina amplicon data. Click the new alignment track, open `Primer-trim BAM…` from the Inspector's `Analysis` section, choose the matching primer scheme from the picker, and click `Run`. Skip this step for shotgun ONT data.

The output is a new track suffixed `Primer-trimmed (<scheme>)`, with primer-trim provenance attached. Medaka, like iVar, will see the sidecar and know the alignment is already trimmed.

### Step 3. Open the Variant Calling dialog and choose an ONT caller

Click the primer-trimmed alignment track. In the Inspector's `Analysis` section, select `Variant Calling` and click `Call Variants…`. The dialog opens with three columns: a tool sidebar on the left, an `Inputs` section in the middle, and an `Output` section on the right. The sidebar lists seven entries (`LoFreq`, `iVar`, `Medaka`, `bcftools`, `Clair3`, `GATK HaplotypeCaller`, and `GATK + WhatsHap Phased`), with `LoFreq` selected by default.

On the sidebar, click `Medaka` or `Clair3`. The middle column updates to show a single caller-specific control: a model field. Both Medaka and Clair3 read from the same model field, so there is one field to fill regardless of which of the two you picked. For Medaka you type a basecaller model name; for Clair3 you type a model path or identifier. The field starts empty, and the `Run` button stays disabled until you type a value into it.

<!-- planned: variant-call-dialog-medaka -->

### Step 4. Type the model and run

The model field is a free-text box, not a dropdown. It shows a placeholder string (`r1041_e82_400bps_sup_v5.0.0`) to illustrate the format, but nothing is selected for you and the placeholder is not used unless you type it. There is no curated list grouped by pore chemistry; you supply the exact model string yourself.

<!-- planned: medaka-model-field -->

If you confirmed the basecaller version in the previous section, type the matching Medaka model string (or, for Clair3, the model path). If you did not, see "What to do when the basecaller is unknown" above. The model is the only caller-specific control; depth comes from the shared `Minimum Depth` threshold, which defaults to `10`. Name the output track `Medaka variants` and click `Run`. If you leave the model field empty, the run stays disabled, and the Medaka pipeline will refuse to start without model metadata.

Behind the dialog Lungfish reconstructs a FASTQ from the primer-trimmed alignment, then runs Medaka against that FASTQ and the reference FASTA, and bgzips and tabix-indexes the resulting VCF. The Medaka command is `medaka variant -i <fastq> -r <reference> -o <out> -m <model> -t <threads>`; Medaka reads the reconstructed FASTQ through `-i`, not the BAM. Clair3 runs against the BAM directly, with `--bam_fn`, `--ref_fn`, `--model_path`, `--platform=ont`, and `--threads`, and Lungfish reads back its `merge_output.vcf.gz`. A new variant track appears under `Variants` in the sidebar when the operation finishes.

The CLI equivalent is one command:

```bash
lungfish variants call \
    --bundle MyReference.lungfishref \
    --alignment-track <trimmed-track-id> \
    --caller medaka \
    --medaka-model r1041_e82_400bps_sup_v4.2.0 \
    --name "Medaka variants"
```

For Clair3, keep the same bundle and alignment arguments and change the caller plus model:

```bash
lungfish variants call \
    --bundle MyReference.lungfishref \
    --alignment-track <trimmed-track-id> \
    --caller clair3 \
    --medaka-model /models/clair3/r1041_e82_400bps_sup_v5.0.0 \
    --name "Clair3 variants"
```

## Worked example: ONT-SAMPLE-01

The hypothetical fixture `ONT-SAMPLE-01` is a SARS-CoV-2 ARTIC v3 amplicon run, basecalled with Dorado v4.2.0 in super-accuracy mode against R10.4.1 chemistry at 400 bps. Reads are roughly 400 bp long, single-end, with the model identifier `dna_r10.4.1_e8.2_400bps_sup@v4.2.0` in the FASTQ header.

The sequence of decisions for this run is: map with `Map ONT (map-ont)`, primer-trim with the bundled `ARTIC-v3-SARS2` scheme, choose Medaka in the Variant Calling dialog, type `r1041_e82_400bps_sup_v4.2.0` into the model field, leave the shared depth threshold at its default, click `Run`.

The expected output for an Omicron-lineage isolate at this read depth is roughly 60 to 90 PASS variants. Medaka calls fewer rows than iVar on the same biological sample because it filters more aggressively at the low-allele-frequency end, which is the right behaviour for ONT data where low-frequency rows are dominated by basecall error.

When the real fixture lands, this section will be re-run against it. The numbers above are the order of magnitude to expect for this isolate, not exact counts and not a guarantee.

## Choosing between Medaka and Clair3

Clair3 is a separate neural-network ONT variant caller that has gained ground for human germline variant calling and for some viral applications. Like Medaka, Clair3 is model-specific and the same basecaller-version-matching rule applies; the model file extensions and naming conventions differ. For SARS-CoV-2 amplicon work, Medaka remains the conservative choice when you need compatibility with established viral consensus pipelines, while Clair3 is useful when your lab has validated Clair3 models or wants an orthogonal ONT call set for comparison.

Both callers share the same model field in the dialog and the same `--medaka-model` CLI flag; the value you put in differs.

| Caller | Use it when | Model input | Lungfish surface |
|---|---|---|---|
| Medaka | You want the established viral ONT caller used by common consensus workflows. | Medaka model name such as `r1041_e82_400bps_sup_v4.2.0`. | Variant Calling dialog model field and `lungfish variants call --caller medaka --medaka-model`. |
| Clair3 | You have validated Clair3 for the run type or want an independent ONT call set. | Clair3 model path or identifier (passed to Clair3 as `--model_path`). | Variant Calling dialog model field and `lungfish variants call --caller clair3 --medaka-model`. |

## Interpretation

Open the `Medaka variants` track in the variant browser. The browser layout and filters are the ones you used for the iVar VCF in [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md). Three things to check before trusting the call set.

First, count PASS rows. For a SARS-CoV-2 Omicron amplicon run at typical ONT amplicon depth, expect tens to low hundreds of PASS rows. Zero or single-digit PASS rows usually means either the alignment is broken (wrong preset, wrong reference) or the model selection is wrong. Several thousand PASS rows usually means the model is mismatched against the basecaller and homopolymer noise is leaking through.

Second, click the track and read the Inspector's provenance sidecar. It records the Medaka version, the model string, the input alignment checksum, and the reference checksum. The model string is the audit trail for "which model called this VCF." If you ever need to re-call after correcting a model mismatch, this is where you confirm what was used the first time.

Third, sanity-check a few high-confidence rows against expected biology. For a SARS-CoV-2 Omicron sample, the spike RBD cluster, the N-protein `R203K` / `G204R` codon, and the `nsp3` synonymous run should all appear. Medaka does not perform iVar's GFF3-driven codon merging, so the N-protein changes will appear as individual single-nucleotide rows rather than a merged dinucleotide row. The biology is the same; the representation differs.

If something looks off, the most common cause is the model. Re-check the basecaller version, re-run with the correct model, and compare. The second most common cause is forgetting to primer-trim an amplicon run. The third is choosing the `Short read (sr)` minimap2 preset by accident.

## Next

Continue to [Consensus and Lineage](05-consensus-and-lineage.md) for downstream consensus workflows. For a refresher on how the same dialog handles Illumina amplicon data, revisit [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md).

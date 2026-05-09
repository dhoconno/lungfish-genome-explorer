---
title: Consensus and Lineage
chapter_id: 05-variants/05-consensus-and-lineage
audience: bench-scientist
prereqs: [05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 8
task: Produce a consensus FASTA from a VCF and submit it for downstream lineage assignment.
tags: [variants, consensus, lineage, pangolin, nextclade]
tools: [ivar, bcftools]
entry_points:
  - "Inspector > Analysis > Variant Calling > Call Variants (consensus output)"
shots: []
planned_shots:
  - id: consensus-threshold-field
    caption: "The consensus AF threshold field in the iVar Variant Calling dialog, set to the default of 0.75."
  - id: consensuses-folder
    caption: "The Consensuses subfolder under the reference bundle, with one FASTA per call."
  - id: export-consensus-menu
    caption: "File > Export > Consensus FASTA, with the active consensus track preselected."
illustrations: []
glossary_refs: [VCF, allele-frequency, consensus-FASTA, lineage]
features_refs: [variants.call]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A consensus FASTA is the reference sequence with high-confidence variants from your sample applied in place. Where the reads call a confident SNP, the consensus carries the alternate base. Where the reads do not give a confident call (low coverage, mixed signal, or no read at all), the consensus carries an `N` mask. The result is a single sequence, the same length as the reference, that represents what your sample looks like as a genome rather than as a list of differences.

Consensus is the format that downstream lineage and clade assignment tools expect. Pangolin assigns SARS-CoV-2 Pango lineages from a consensus FASTA. Nextclade assigns Nextstrain clades and flags amino-acid changes from a consensus FASTA. GISAID and NCBI both accept a consensus FASTA as the deposit format for surveillance submission. None of these tools accept a VCF directly, which is why the consensus step exists between variant calling and lineage reporting.

Lungfish writes a consensus FASTA as a side output of the iVar Variant Calling step (covered in [Calling Variants from Amplicons](01-calling-variants-from-amplicons.md)) whenever the consensus allele-frequency threshold is set in the dialog. The threshold is what tells iVar where to draw the line between "call this base" and "mask this position as `N`". So what should you do with this? Run iVar Variant Calling once, find the consensus FASTA Lungfish drops next to the VCF, and submit that file to whichever external lineage tool your surveillance program uses.

## What you will learn

By the end of this chapter you will be able to set the consensus AF threshold in the iVar Variant Calling dialog with an understanding of what that threshold means biologically, locate the resulting consensus FASTA inside the project's reference bundle, export or copy the consensus for use in external tools, run that consensus through Pangolin to get a Pango lineage call, and recognise which adjacent steps Lungfish leaves to external software.

## Procedure

The consensus is produced by the same iVar run that produced the VCF in V01. You do not run a separate operation. You set one extra field, then read a different output file.

1. Open the project from V01 and select the BAM you called variants on. The BAM lives under the reference bundle, in the `Alignments/` subfolder.
2. In the Inspector, choose **Analysis > Variant Calling > Call Variants**. The dialog is the same one you used in V01.
3. Confirm **Caller** is set to **iVar**. The consensus output is iVar-specific in Lungfish; LoFreq and Medaka write a VCF only.
4. Set **Consensus AF threshold** to the value appropriate for your sample type. The default of `0.75` is correct for most clinical isolates. See the table below for the trade-off. <!-- planned: consensus-threshold-field -->
5. Click **Run**. When the operation finishes, Lungfish writes the VCF and a paired consensus FASTA into the reference bundle.

### Consensus AF threshold choices

The threshold is the minimum allele frequency at which iVar will write the alternate base into the consensus. Below the threshold, the position becomes `N`. The right value depends on what biological situation your sample represents.

| Threshold | What gets called as consensus | Use this when |
|---|---|---|
| `0.5` | Any base supported by more than half the reads. Mixtures and minor variants pull the consensus toward the majority allele. | The sample is genuinely a mixed population (wastewater, co-infection) and you want a "majority rule" view. Expect more `N`s and a noisier sequence. |
| `0.75` (default) | The alternate base is called only when at least 75 percent of reads agree. Borderline positions become `N`. | Most clinical isolates and surveillance samples. This is the iVar paper's default and what Pangolin and Nextclade have been benchmarked against. |
| `0.9` | The alternate base is called only when at least 90 percent of reads agree. Anything close to a 50/50 split becomes `N`. | High-confidence reference deposits for GISAID or NCBI, where you would rather mask a position than risk encoding a sequencing artefact. |

If you do not know which to pick, leave the field at `0.75`.

## Interpretation

When the run finishes, look in two places.

The first is the **Consensuses** subfolder of the reference bundle in the sidebar. Lungfish creates this folder the first time a consensus is written and stores one FASTA per call, named after the source BAM. The track also appears as a sequence track on the reference bundle itself, so you can open it in the viewport alongside the reference and see the differences as colored columns. <!-- planned: consensuses-folder -->

The second is the Operations Panel. The iVar row will show two output files: the VCF you used in V01 and a new `.consensus.fa`. Both carry their own provenance sidecar, recording the iVar version, the BAM checksum, the threshold used, and the resulting checksum of the FASTA. If you submit the consensus and a reviewer asks "what threshold did you use", the sidecar answers without you having to remember.

Open the consensus FASTA in the viewport to spot-check it. A clean SARS-CoV-2 consensus from amplicon data typically shows a small handful of base differences from the Wuhan-Hu-1 reference and a few short `N` runs at amplicon dropouts. Long stretches of `N` (more than a few hundred bases at a time) usually mean an amplicon failed and the sample needs re-sequencing or re-pooling before it is fit for lineage assignment. Pangolin will accept a sequence with up to about 50 percent `N` content but the call quality drops sharply past 10 percent.

### Exporting the consensus

To get the FASTA out of the project for use with an external tool, use either of these paths.

1. Choose **File > Export > Consensus FASTA**, pick the consensus track from the dropdown, and save to disk. <!-- planned: export-consensus-menu -->
2. Right-click the consensus track in the sidebar and choose **Save As FASTA**.

Both paths write a plain `.fa` file with one header (the sample name) and the consensus sequence. No metadata is added; the file is exactly what Pangolin and Nextclade expect.

### Worked example: V01 to a Pango lineage

The V01 chapter walked through calling iVar variants on the SARS-CoV-2 fixture (MN908947.3 with paired amplicon FASTQs). Picking up from there:

1. Re-open that V01 project and re-run **Call Variants** on the same BAM, this time leaving **Consensus AF threshold** at `0.75`. The VCF output is unchanged; the new artifact is the FASTA.
2. Open the **Consensuses** folder under the reference bundle. The new file is named after the BAM, for example `sample01.consensus.fa`. Click it to load the sequence track and confirm the length matches the reference (29,903 bases for MN908947.3) and the `N` content is low.
3. Choose **File > Export > Consensus FASTA** and save to your Desktop.
4. In a web browser, open the Pangolin web interface at `https://pangolin.cog-uk.io`. Drag the exported FASTA into the upload area or paste the sequence text directly. Pangolin runs in your browser session and returns a lineage assignment, a confidence score, and the version of the pangolin-data designation set it used. The fixture isolate, sequenced in early 2020, will resolve to lineage `B` or one of its early sublineages.
5. Record the lineage call and the pangolin-data version in your sample sheet or project notes. The Lungfish provenance sidecar already records the iVar version and the threshold; the lineage call is the one piece of metadata Lungfish cannot produce on its own.

The same FASTA goes to Nextclade unchanged. Open `https://clades.nextstrain.org`, choose the SARS-CoV-2 dataset, drop in the file, and read off the Nextstrain clade and any flagged QC issues.

## What Lungfish does not do

Lungfish stops at the consensus FASTA. Three adjacent steps are deliberately left to external software:

- **Pangolin** assigns SARS-CoV-2 Pango lineages. It updates its designation database often (sometimes weekly during a wave) and is run online at `pangolin.cog-uk.io` or locally as a separate conda package. Bundling it inside Lungfish would mean shipping a stale database.
- **Nextclade** assigns Nextstrain clades and reports amino-acid substitutions. It runs in the browser at `clades.nextstrain.org` or as a CLI, and likewise pins to a dataset version that updates outside Lungfish's release cycle.
- **GISAID and NCBI submission** require an account, metadata forms, and (for GISAID) a per-submitter agreement. Both portals accept the consensus FASTA Lungfish exports without modification. Lungfish does not automate the upload; the credentials and the metadata forms belong to the depositor, not the analysis tool.

The boundary is intentional. A consensus FASTA is a stable file format. Lineage nomenclature is a moving target. Keeping the two on separate update cycles means you can re-run a lineage call with a fresher database six months from now without re-running the variant call.

## Next

Continue to [Importing Existing VCFs](06-importing-existing-vcfs.md) if you have a VCF from an external pipeline you want to view in Lungfish.

# MCM MHC MiSeq Prompt Preset Design

## Goal

Wire the prompt-based MCM MHC MiSeq haplotyping workflow into the CLI and GUI as a preset that pins the exact curated MCM reference and GPT-5.5 medium-reasoning specialist prompt behavior.

## Scope

The hybrid deterministic/provisional approach is obsolete for this workflow. The MCM preset uses the specialist prompt, bundled knowledge pack, and locked reference database. Users must not be able to pair this preset with a different reference FASTA or a different haplotype definition set.

## Locked Reference

- Source FASTA: `/Users/dho/Desktop/sandbox/mcm-mhc-miseq-reference-20260617/mcm_mhc_miseq_reference.trimmed.unique.fasta`
- Record count: 189
- Size: 77,084 bytes
- SHA-256: `13134729eba56d42479e251b53299152d823947a0bc2c64fb82a61023e1b6561`
- Definition ID: `mcm-mhc-miseq-20260617`
- Assay ID: `MHC-exon2-miSeq`
- Species code: `MCM`

## CLI Behavior

Add an MCM preset option to amplicon genotyping commands. When the preset is selected:

- Resolve the reference from bundled resources, not from `--reference`.
- Reject explicit `--reference`, `--haplotype-definition`, `--haplotype-assay`, or `--haplotype-species` values that conflict with the preset.
- Pass the preset definition metadata into the genotyping request.
- Use the existing result-bundle provenance machinery, extended with preset ID, reference digest, and locked reference path.

AI haplotyping for this preset must use:

- Provider: OpenAI
- Model: `gpt-5.5`
- Reasoning effort: `medium`
- Temperature: `0`
- Prompt template: current MCM specialist prompt template in `AIHaplotypingPromptRegistry`
- Knowledge pack: bundled `macaque-mhc-v1.json`

## GUI Behavior

Expose the preset as a dedicated MCM MHC MiSeq workflow selection. The GUI should construct the same preset-backed request as the CLI and should not expose a user-editable reference selector for this preset.

## Provenance

Every generated scientific output must record:

- Preset ID and version
- Locked reference bundle/resource path
- Locked reference SHA-256 and size
- Haplotype definition ID, assay ID, and species code
- AI provider, model, reasoning effort, prompt template ID/version/hash, and knowledge pack digest when AI haplotyping is run
- Exact CLI argv or GUI-derived reproducible command

## Verification

Implementation must be test-first. Required checks:

- CLI preset parsing and validation reject incompatible reference/haplotype overrides.
- GUI request construction pins the bundled reference and preset metadata.
- AI haplotyping defaults resolve to GPT-5.5 medium reasoning for the preset.
- Bundle provenance includes preset and locked reference details.
- A small-sample workflow output matches the previous GPT-5.5 medium-reasoning benchmark.

## Release

After implementation and verification:

- Merge the current LLM endpoint work into `main`.
- Remove stale worktrees and branches that are fully merged or explicitly obsolete.
- Build, sign, notarize, and publish the release DMG.
- Publish the Sparkle notification/appcast update.

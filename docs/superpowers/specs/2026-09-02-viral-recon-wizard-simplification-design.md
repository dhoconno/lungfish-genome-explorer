# Viral Recon wizard simplification

Date: 2026-09-02
Status: approved for planning
Scope: track B of two. Track A (results integration) is a separate design.
Input: `2026-09-02-viral-recon-wizard-simplification-panel.md`

## Problem

The Viral Recon sheet presents about nineteen controls to a user whose goal is to
analyse one sample. A panel session with bioinformatics experts and four novice
students found that most of those controls cannot be reasoned about by the
intended audience, and that two of them are actively broken.

The wizard is 1,132 lines in
`Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift`.

## Verified findings

These were checked directly against the code and the installed pipeline, not
taken from the panel on trust. One panel claim was overstated and is corrected
below.

### Only Docker works

`NFCoreRunRequest` appends the executor's raw value as `-profile` with no
special-casing:

    args += ["-profile", executor.rawValue]

viralrecon 3.0.0 defines these profiles: debug, conda, mamba, docker,
singularity, podman, shifter, charliecloud, apptainer, wave, gpu, and the test
profiles. There is no `local` profile. Nextflow's `local` is an executor, a
different namespace, so selecting Local aborts the run before any work happens.

`conda` names a real profile, but Lungfish never enables Nextflow's conda support
for this workflow. The launch path adds a conda `bin` directory to PATH and sets
`MAMBA_ROOT_PREFIX`, and stops there.

Correction to the panel: it reported `NXF_CONDA_ENABLED` as absent from the
codebase. It occurs twice, in `CondaManager` and `TaxTriagePipeline`. Neither is
on the Viral Recon launch path, so the conclusion holds, but the claim as stated
was wrong.

Docker is the only genuinely supported executor. It is the default in both GUI
and CLI, `/usr/local/bin` is on the engine PATH specifically for Docker Desktop,
and every mitigation shipped on this branch is container-shaped.

### The duplicate FASTA control is structural

All eight bundled primer schemes ship `manifest.json` and `primers.bed` and no
`primers.fasta`. `primerRequiresLocalReference` is therefore true for every
built-in scheme, and the local-FASTA picker renders in both branches of the mode
switch. The duplicate control the product owner noticed is not a layout slip. The
default configuration is blocked on a control the user has no reason to expect,
on first run.

### The advanced escape hatch is currently impossible

`ViralReconRunRequest.validateAdvancedParams` throws on every `skip_*` key plus
`variant_caller`, `consensus_caller` and `min_mapped_reads`. Those are exactly the
keys an advanced field exists to reach. The reject list must become an override
list for tuning keys, while still refusing structural keys the wizard owns and the
two forced Freyja skips.

## Design

### Visible controls

Five, in this order.

1. Inputs. Read-only summary with detected platform shown as static text. The
   platform control appears only when detection fails, and the Auto segment is
   dropped when it does.
2. Reference. A single menu over project reference bundles whose accession matches
   the selected primer scheme. No mode picker, no accession field, no file panel.
   When no matching bundle exists, the wizard offers to download it from NCBI
   GenBank through the existing fetch path, which builds a proper `.lungfishref`.
3. Primer scheme. Unchanged, including the accession, primer count and amplicon
   detail line. The panel found this control already works for novices.
4. Minimum mapped reads. Stepper, default 1000, with a caption stating that it
   drops whole samples.
5. Readiness. Promoted above Run, and also the surface for advanced-parse errors.

### Invisible defaults

Docker executor, pipeline version 3.0.0, iVar variant caller, BCFtools consensus
caller, `skip_assembly`, `skip_kraken2`, and the resource caps. The two Freyja
skips remain forced and unreachable, for the architecture reason established
earlier on this branch.

### Advanced escape hatch

A collapsed disclosure containing a GFF picker and an extra-parameters text field
using `AdvancedCommandLineOptions.parse`, the pattern six other wizards already
use and this one never adopted. It must reach the callers, the skip options, the
resource caps and `min_mapped_reads`.

Parameter names are validated against the pipeline's `nextflow_schema.json` so a
typo is refused at the sheet rather than failing minutes into a run. Structural
keys owned by the wizard, and the forced Freyja skips, are refused with a message
naming the control that owns them.

### Executor removal

Docker becomes the only offered executor and the picker disappears.

The `conda` and `local` enum cases are not deleted. Four existing tests assert
those values and saved run bundles may record them, so deletion would break both.
They are removed from the picker, and refused at launch with a message stating
that only Docker is supported. The CLI flag keeps parsing them and fails the same
way, rather than silently producing a run that cannot work.

The user manual currently claims all three executors work. That claim is corrected
in the same change.

## Testing

- Reference resolution: matching bundle present, absent and downloaded, and
  scheme mismatch refused.
- Advanced parsing: tuning keys override defaults, structural keys refused,
  Freyja skips refused, unknown names refused by schema validation.
- Executor: conda and local refused at launch with an actionable message, and the
  four existing executor tests still pass.
- Wizard state: five controls visible by default, platform control hidden when
  detection succeeds.
- Full unit gate before merge.

## Out of scope

- Track A results integration.
- Restoring conda. That requires PATH provisioning, a cache directory and a real
  end to end run, and should not be reinstated until those exist.

# Full-Length MHC BAM Inspector Artifacts

## Goal

Make the alignment artifacts already published by the full-length ONT MHC
genotyping workflow visible from Lungfish's artifact surfaces without parsing or
loading BAM contents into the genotype detail pane.

## Scope

This change applies only to full-length ONT MHC genotype result bundles whose
typed candidate-artifact manifest declares validated alignment artifacts. It
does not change artifact generation, scientific analysis, provenance, candidate
detail rendering, or other Lungfish workflows.

## Design

The bundle loader will expose the resolved URLs of the two validated BAM/BAI
pairs already declared by `ONTMHCCandidateArtifactManifest`:

- Genotyping Evidence BAM
- Genotyping Evidence BAI
- Reciprocal Evidence BAM
- Reciprocal Evidence BAI

The loader remains the integrity boundary. It will expose these URLs only after
the existing path, size, and checksum validation for the candidate-artifact
manifest succeeds. A missing manifest pair remains absent. If candidate-artifact
validation fails, the existing integrity warning behavior remains authoritative
and no alignment artifact URL is exposed.

Both user-facing artifact lists will consume the same validated URL projection:

1. The document Inspector's **Artifacts** section.
2. The genotype viewport's **Artifacts** lens.

This keeps the two artifact surfaces consistent. The BAM and BAI rows will be
ordinary file links using the existing artifact-row behavior.

## Performance and Safety

Adding a row resolves a local URL only. It must not open, index, enumerate, or
parse either BAM. BAM paths remain excluded from the selected-allele detail
pane, preserving the compact, immediate detail rendering introduced to address
the prior memory failure.

The BAI files are shown alongside their BAMs because they are part of the
published, sorted-and-indexed evidence artifact and are required by standard
downstream tools.

## Testing

Focused regression tests will verify that:

- The Inspector lists all four declared and validated BAM/BAI artifacts.
- The viewport Artifacts lens lists the same four artifacts.
- Bundles without declared BAM pairs do not show alignment rows.
- Invalid candidate-artifact manifests continue to withhold the alignment URLs
  through the existing integrity-validation path.

Relevant LungfishIO, LungfishApp, and LungfishGenotypeUI tests will be run before
building and relaunching `Lungfish Debug`.

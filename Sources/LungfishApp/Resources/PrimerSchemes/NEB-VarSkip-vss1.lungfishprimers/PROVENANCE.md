# PROVENANCE - NEB VarSkip Short v1

## Workflow

| Field | Value |
|---|---|
| Tool/workflow | `scripts/build-primer-bundle.swift` |
| Tool version | `1.1.0` |
| Bundle schema version | `1` |
| Bundle content version | `1.0.0` |
| Started | `2026-09-01T22:13:12Z` |
| Completed | `2026-09-01T22:13:12Z` |
| Wall time | `0.693 seconds` |
| Exit status | `0` after validation, NCBI equivalence checks, and file writes completed |
| Runtime | `Version 26.6.2 (Build 25G83)` |
| Conda environment | `(not set)` |
| Container | `(not applicable)` |
| Bundle created timestamp | `2026-09-01T22:13:12Z` |

## Command

```sh
scripts/build-primer-bundle.swift --name NEB-VarSkip-vss1 --display-name 'NEB VarSkip Short v1' --description 'New England Biolabs VarSkip short-amplicon scheme for SARS-CoV-2, designed to tolerate variant-driven primer mismatches.' --organism 'Severe acute respiratory syndrome coronavirus 2' --canonical MN908947.3 --equivalent NC_045512.2 --bed scripts/inputs/neb-varskip-vss1-primers.bed --source-url https://github.com/nf-core/test-datasets/tree/viralrecon/genome/MN908947.3/primer_schemes/NEB/nCov-2019/vss1 --output Sources/LungfishApp/Resources/PrimerSchemes/NEB-VarSkip-vss1.lungfishprimers
```

## Options

| Option | Resolved value |
|---|---|
| --name | NEB-VarSkip-vss1 |
| --display-name | NEB VarSkip Short v1 |
| --description | New England Biolabs VarSkip short-amplicon scheme for SARS-CoV-2, designed to tolerate variant-driven primer mismatches. |
| --organism | Severe acute respiratory syndrome coronavirus 2 |
| --canonical | MN908947.3 |
| --equivalent | NC_045512.2 |
| --bed | /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/scripts/inputs/neb-varskip-vss1-primers.bed |
| --fasta | (not supplied) |
| --source-url | https://github.com/nf-core/test-datasets/tree/viralrecon/genome/MN908947.3/primer_schemes/NEB/nCov-2019/vss1 |
| --source | built-in |
| --version | 1.0.0 |
| --output | /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/NEB-VarSkip-vss1.lungfishprimers |

## Reference Verification

| Accession | Role | Sequence SHA-256 |
|---|---|---|
| MN908947.3 | canonical | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |
| NC_045512.2 | equivalent | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |

## Computed Counts

| Field | Value |
|---|---|
| Primers | `148` |
| Amplicons | `74` |

## Inputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Source BED | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/scripts/inputs/neb-varskip-vss1-primers.bed` | 7423 | `52b524a83429b31774b98b89e03e6ca89be2f14ea80da85cf5955bf06743a45e` |

## Outputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Bundle directory | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/NEB-VarSkip-vss1.lungfishprimers` | 0 | `(directory)` |
| Manifest | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/NEB-VarSkip-vss1.lungfishprimers/manifest.json` | 736 | `7b26c3aca50c02ad1637aee4d131b1a64fbe2aca66312f2d5e9067c7ded9cef5` |
| Bundled BED | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/NEB-VarSkip-vss1.lungfishprimers/primers.bed` | 7423 | `52b524a83429b31774b98b89e03e6ca89be2f14ea80da85cf5955bf06743a45e` |

## Stderr

Successful runs write NCBI fetch progress and reference SHA-256 lines to stderr.
No warning or error stderr was emitted for this completed bundle.
## Source and license

Retrieved from the nf-core/viralrecon test-datasets primer scheme collection (https://github.com/nf-core/test-datasets/tree/viralrecon), the copy the pipeline itself resolves. Licensed MIT by nf-core. Retrieval date: 2026-09-01.

Primer coordinates anchored to a public reference are not independently copyrightable. Verify against the upstream scheme before clinical or production use.

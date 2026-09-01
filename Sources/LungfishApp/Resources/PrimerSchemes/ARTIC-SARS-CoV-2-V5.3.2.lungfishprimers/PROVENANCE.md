# PROVENANCE - ARTIC SARS-CoV-2 V5.3.2

## Workflow

| Field | Value |
|---|---|
| Tool/workflow | `scripts/build-primer-bundle.swift` |
| Tool version | `1.1.0` |
| Bundle schema version | `1` |
| Bundle content version | `1.0.0` |
| Started | `2026-09-01T22:12:58Z` |
| Completed | `2026-09-01T22:12:59Z` |
| Wall time | `0.851 seconds` |
| Exit status | `0` after validation, NCBI equivalence checks, and file writes completed |
| Runtime | `Version 26.6.2 (Build 25G83)` |
| Conda environment | `(not set)` |
| Container | `(not applicable)` |
| Bundle created timestamp | `2026-09-01T22:12:59Z` |

## Command

```sh
scripts/build-primer-bundle.swift --name ARTIC-SARS-CoV-2-V5.3.2 --display-name 'ARTIC SARS-CoV-2 V5.3.2' --description 'ARTIC Network SARS-CoV-2 400 bp amplicon scheme, version 5.3.2. The current ARTIC recommendation.' --organism 'Severe acute respiratory syndrome coronavirus 2' --canonical MN908947.3 --equivalent NC_045512.2 --bed scripts/inputs/artic-ncov2019-V5.3.2-primers.bed --source-url https://github.com/artic-network/artic-ncov2019/tree/master/primer_schemes/nCoV-2019/V5.3.2 --output Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V5.3.2.lungfishprimers
```

## Options

| Option | Resolved value |
|---|---|
| --name | ARTIC-SARS-CoV-2-V5.3.2 |
| --display-name | ARTIC SARS-CoV-2 V5.3.2 |
| --description | ARTIC Network SARS-CoV-2 400 bp amplicon scheme, version 5.3.2. The current ARTIC recommendation. |
| --organism | Severe acute respiratory syndrome coronavirus 2 |
| --canonical | MN908947.3 |
| --equivalent | NC_045512.2 |
| --bed | /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/scripts/inputs/artic-ncov2019-V5.3.2-primers.bed |
| --fasta | (not supplied) |
| --source-url | https://github.com/artic-network/artic-ncov2019/tree/master/primer_schemes/nCoV-2019/V5.3.2 |
| --source | built-in |
| --version | 1.0.0 |
| --output | /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V5.3.2.lungfishprimers |

## Reference Verification

| Accession | Role | Sequence SHA-256 |
|---|---|---|
| MN908947.3 | canonical | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |
| NC_045512.2 | equivalent | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |

## Computed Counts

| Field | Value |
|---|---|
| Primers | `192` |
| Amplicons | `96` |

## Inputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Source BED | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/scripts/inputs/artic-ncov2019-V5.3.2-primers.bed` | 9918 | `0d9d041004bae338fc046cb9c56ad0eb1d25575b25a3a0f0a4e29913ca8a7190` |

## Outputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Bundle directory | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V5.3.2.lungfishprimers` | 0 | `(directory)` |
| Manifest | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V5.3.2.lungfishprimers/manifest.json` | 706 | `3aeec277cb23a8907fdfaa17d52af24af017c8e9a223ef314c58675dd26c052c` |
| Bundled BED | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V5.3.2.lungfishprimers/primers.bed` | 9918 | `0d9d041004bae338fc046cb9c56ad0eb1d25575b25a3a0f0a4e29913ca8a7190` |

## Stderr

Successful runs write NCBI fetch progress and reference SHA-256 lines to stderr.
No warning or error stderr was emitted for this completed bundle.
## Source and license

Retrieved from the ARTIC Network `artic-ncov2019` repository (https://github.com/artic-network/artic-ncov2019), which the nf-core/viralrecon pipeline resolves for its bundled ARTIC primer sets. Licensed CC-BY-4.0 by the ARTIC Network. Retrieval date: 2026-09-01.

Primer coordinates anchored to a public reference are not independently copyrightable. Verify against the upstream scheme before clinical or production use.

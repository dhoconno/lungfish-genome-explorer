# Native Multiple Sequence Alignment and Phylogenetic Tree Support

Date: 2026-05-02
Branch: `codex/alignment-tree-viewers`

## Goal

Add first-class native Lungfish support for multiple sequence alignments and phylogenetic trees:

- Import common MSA/tree files into native bundle directories.
- View alignments and trees without requiring Geneious or any other vendor GUI.
- Route Geneious and other application exports into native bundles when the contained files are parseable.
- Keep unsupported rich/vendor-native artifacts out of the initial import result unless a future explicit preservation option is enabled.
- Back all scientific creation/import workflows with `lungfish-cli` and project-local temp directories.
- Preserve reproducibility provenance in every created bundle.

## Expert Team Synthesis

The MSA team recommended a dedicated `.lungfishmsa` bundle rather than reusing ordinary `Sequence` rows, because gap characters, case/profile state, column coordinates, consensus, and row metadata are part of the scientific model.

The tree team recommended a dedicated `.lungfishtree` bundle and a tree viewport. First usable scope should import and inspect existing trees/results, then add inference workflows after the native model and viewer are reliable.

The implementation should treat read alignments, MSAs, and phylogenetic trees as separate viewer families.

## Bundle Formats

### `.lungfishmsa`

Recommended layout:

```text
Example.lungfishmsa/
  manifest.json
  alignment/primary.aligned.fasta
  alignment/source.original
  metadata/rows.json
  cache/alignment-index.sqlite
  .viewstate.json
  .lungfish-provenance.json
```

Required manifest fields:

- `schemaVersion`
- `bundleKind = "multiple-sequence-alignment"`
- `identifier`
- `name`
- `createdAt`
- `sourceFormat`
- `sourceFileName`
- `rowCount`
- `alignedLength`
- `alphabet`
- `gapAlphabet`
- `referenceRowID`
- `warnings`
- `capabilities`

Required row fields:

- stable row id
- source/display name
- row order
- alphabet
- aligned/ungapped length
- gap and ambiguous counts
- SHA-256 checksum
- optional accession, organism, gene/product, haplotype/clade, metadata map

Required cached statistics:

- consensus residue per column
- per-column residue counts
- gap fraction
- conservation/entropy
- variable-site flag
- parsimony-informative flag
- optional reference coordinate and codon phase

### `.lungfishtree`

Recommended layout:

```text
Example.lungfishtree/
  manifest.json
  tree/source.original
  tree/primary.nwk
  tree/primary.normalized.json
  metadata/samples.tsv
  annotations/clades.tsv
  cache/tree-index.sqlite
  .viewstate.json
  .lungfish-provenance.json
```

Required manifest fields:

- `schemaVersion`
- `bundleKind = "phylogenetic-tree"`
- `identifier`
- `name`
- `createdAt`
- `sourceFormat`
- `sourceFileName`
- `treeCount`
- `primaryTreeID`
- `isRooted`
- `tipCount`
- `internalNodeCount`
- `branchLengthUnit`
- `dateScale`
- `warnings`
- `capabilities`

Required node/edge fields:

- stable node id
- raw/display label
- parent id
- ordered child ids
- tip/internal flag
- branch length
- cumulative divergence
- date/decimal year and precision when present
- height/HPD/rate/support metadata when present
- descendant tip count

Support values must retain their source interpretation where possible (`bootstrap`, `posterior`, `ufboot`, `shalrt`, `fasttreeLocal`, `unknown`) and preserve raw values.

## Import Scope

P0 MSA import:

- Aligned FASTA: `.fa`, `.fasta`, `.fas`, `.fna`, `.faa`
- CLUSTAL: `.aln`, `.clustal`, `.clw`
- PHYLIP sequential/interleaved: `.phy`, `.phylip`
- NEXUS matrix: `.nex`, `.nexus`
- Stockholm: `.sto`, `.stockholm`
- A2M/A3M: `.a2m`, `.a3m`
- Limited simple single-block MAF preview/import with warnings

P0 tree import:

- Newick: `.nwk`, `.newick`, `.tree`, `.tre`
- NEXUS tree blocks with `TRANSLATE`
- IQ-TREE `.treefile`, `.contree`
- RAxML/RAxML-NG best/support tree files
- FastTree Newick outputs
- Auspice JSON when it contains a tree payload
- TSV/CSV metadata attach keyed by exact tip label

Unsupported in first usable scope:

- Direct UShER protobuf/MAT parsing
- HAL/Cactus/pangenome graph alignments
- Full PhyloXML/NeXML semantic round trip
- BEAST posterior tree clouds and MCMC diagnostics
- Manual alignment/tree editing

These formats should fail cleanly or warn with no partial bundle until a native model or explicit conversion path exists.

## Viewer Requirements

### MSA Viewer

Use the central viewport as a full alignment exploration surface rather than a result table. The viewport owns aligned sequence exploration; the Inspector owns statistics, provenance, view settings, and selected item details. Include:

- One scrollable aligned-character canvas with frozen row-name gutter, frozen site ruler, and a labeled `Consensus` row.
- Residue color schemes, gap highlighting, variable-site highlighting, conserved-site highlighting, ambiguous/missing-base highlighting, and parsimony-informative-site filtering.
- Row, site, range, and block selections with explicit coordinate semantics: alignment columns versus per-sequence ungapped coordinates.
- Row/search navigation and variable-site next/previous controls as lightweight viewport navigation controls.
- Context menus on selected rows/ranges/blocks that use the existing FASTA extraction idiom: `Extract Sequence…` or `Extract Sequences…`, `Copy FASTA`, `Export FASTA…`, `Create Bundle…`, and `Run Operation…`.
- A collapsible lower `Annotations` drawer, matching existing sequence-view idioms, for annotations relevant to the visible region, selected sequence, or selected range. This drawer must not become a statistics/detail drawer.
- View state for scroll, selection, reference row, color scheme, filters, consensus settings, annotation visibility, and visible annotation tracks.

The Inspector Bundle tab must show MSA summary metadata: bundle name, source format/file, row count, aligned length, alphabet, variable-site count, parsimony-informative count, warnings, consensus preview, source/provenance summary, checksums, and artifact sizes. The Inspector Selected Item tab must show the selected row/site/range/block: sequence name, residue, consensus residue, alignment column, ungapped coordinate when applicable, conservation, gap fraction, residue counts, and variable/parsimony flags.

MAFFT and other MSA tools are sequence-only transforms. Lungfish must preserve source annotations by exporting controlled FASTA headers plus a sidecar mapping before MAFFT, then rehydrating annotations into the `.lungfishmsa` bundle after alignment. The final bundle, not the aligned FASTA, is the annotation carrier. The bundle stores source annotation records in original ungapped coordinates, row identity maps, source sequence checksums, alignment-column coordinate maps, and derived aligned spans for display/extraction.

FASTQ inputs are valid for MSA only when they represent assembled sequences, consensus sequences, or contigs rather than raw read sets. Lungfish may convert such FASTQ records to controlled FASTA internally, preserving source FASTQ paths, record identifiers, sequence checksums, and quality summaries as sidecar metadata. FASTQ quality data is not preserved by MAFFT and must not be represented as if it were aligned sequence data; it can be mapped only to ungapped source coordinates and exposed conservatively.

Annotation projection between aligned sequences is an explicit user action, not an automatic import side effect. Projection maps source ungapped feature intervals to alignment columns, then maps those columns to target ungapped coordinates, preserving segmented intervals where needed. Projected annotations must carry provenance, source annotation IDs, target sequence IDs, validation status, conflict policy, and warnings for gaps, partial coverage, ambiguity, frame disruption, low identity, and overlapping target annotations.

### Tree Viewer

Use a dedicated AppKit canvas rather than recursive SwiftUI node views. Include:

- Rectangular phylogram/cladogram mode.
- Pan, zoom, fit, reset.
- Tip table/search alongside the canvas.
- Selection inspector for tip/node metadata, branch support, dates, mutations, and clade membership.
- Collapse/expand clades.
- Metadata/clade/support coloring.
- Subtree export.
- View state for layout, collapsed clades, color mode, zoom, selected node, and visible metadata columns.

## Plugin Packs

Create two active optional packs.

### Multiple Sequence Alignment Pack

Initial conda package targets verified through `micromamba repoquery` for `osx-arm64`/`noarch`:

- `conda-forge::mafft=7.526`
- `bioconda::muscle=5.3`
- `bioconda::clustalo=1.2.4`
- `bioconda::famsa=2.4.1`
- `bioconda::trimal=1.5.1`
- `bioconda::clipkit=2.12.0`
- `bioconda::goalign=0.4.0`

`seqkit` stays in the required setup pack and is not duplicated in the MSA pack.

### Phylogenetics Pack

Initial conda package targets verified through `micromamba repoquery` for `osx-arm64`/`noarch`:

- `bioconda::iqtree=3.1.1`
- `bioconda::fasttree=2.2.0`
- `bioconda::raxml-ng=2.0.1`
- `bioconda::treetime=0.12.1`
- `bioconda::gotree=0.5.1`
- `bioconda::treeswift=1.1.45`

These packs expose installed-tool status and smoke checks first. Running alignment and inference tools should be added after bundle import/viewer correctness is tested.

Do not place `modeltest-ng` or `newick_utils` in the Apple Silicon default packs until they have native `osx-arm64` or `noarch` builds. `nextclade`, `usher`, `augur`, and `auspice` belong in a future viral/Nextstrain extension pack rather than the default generic phylogenetics pack because they solve pathogen surveillance/MAT workflows and have different dependency constraints.

## Import Center

Add native cards:

- “Multiple Sequence Alignments” in Alignments.
- “Phylogenetic Trees” in Alignments.

Application-export cards must route parseable MSA/tree files into `.lungfishmsa` and `.lungfishtree` bundles. Unsupported content should produce warnings and not be copied into the result by default.

## CLI and Provenance

Required CLI entry points:

- `lungfish import msa <file> --project <project> [--name <name>] --format json`
- `lungfish import tree <file> --project <project> [--name <name>] --format json`

Every created bundle must include `.lungfish-provenance.json` with:

- workflow/tool name and version
- exact argv or reproducible command
- resolved user options/defaults
- runtime/conda identity when applicable
- input/output final paths
- checksums and file sizes
- warnings
- exit status
- wall time
- useful stderr

Temporary work must use `<project>.lungfish/.tmp/`; `/tmp` is not acceptable for app or CLI import staging.

## Acceptance Criteria

- CLI imports create valid `.lungfishmsa` and `.lungfishtree` bundles with manifests, normalized payloads, view state, indexes, source copies, warnings, and provenance.
- Import Center cards dispatch through `lungfish-cli` and update Operation Center progress.
- Geneious/application export imports route parseable alignment/tree files into native bundles.
- MSA fixtures cover FASTA, CLUSTAL, PHYLIP, NEXUS, Stockholm, A2M/A3M, and warning paths.
- Tree fixtures cover Newick, NEXUS `TRANSLATE`, IQ-TREE support conventions, BEAST-style Nexus comments, and warning paths.
- Viewers open bundle fixtures and expose stable UI/accessibility hooks for artifact/XCUI tests.
- Plugin pack registry exposes active MSA and Phylogenetics packs with exact package metadata and smoke tests.
- No new scientific import workflow ships without provenance.

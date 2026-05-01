# MSA, Tree, And Phylogenetics Format Notes

Date: 2026-05-01

These notes preserve the non-Geneious material for a later MSA/tree viewer and phylogenetics-tooling spec. They are intentionally deferred from the first Geneious import spec so the Geneious importer can ship a useful baseline without waiting on new native bundle types.

## Candidate Native Bundle Types

- `.lungfishmsa`: multiple sequence alignment bundle with source file preservation, normalized sequence/row metadata, optional reference-coordinate links, chunked residue storage, and provenance.
- `.lungfishtree`: phylogenetic tree bundle with source file preservation, parsed topology, branch lengths, labels, support values, annotations, optional mutation metadata, and provenance.
- `.lungfishphylo`: possible combined analysis bundle for an MSA plus one or more trees and tool-run provenance. This may be useful for generated analyses, but standalone MSA/tree bundles should probably exist first.

## Format Matrix

| Category | Formats to assess | Notes |
| --- | --- | --- |
| Core MSA | aligned FASTA, PHYLIP, NEXUS, Clustal, MEGA | Common Geneious exports and tool inputs. |
| Rich/profile MSA | Stockholm, A3M, A2M | Important for protein/profile workflows and HMM-oriented tools. |
| Whole-genome alignment | MAF, bigMaf, HAL/Cactus | Needs indexed or chunked access; not appropriate for simple in-memory MSA models. |
| Rearranged microbial alignments | XMFA/Mauve | Useful for bacterial and viral comparative genomics. |
| Pangenome-adjacent | GFA, rGFA, GBZ, GAF | Graph formats are not MSAs but may belong in a future pangenome viewer/importer. |
| Core trees | Newick, Extended Newick/NHX, NEXUS | Minimum viable tree viewer support. |
| Rich trees | PhyloXML, NeXML, BEAST `.trees` | Carries metadata and posterior/tree-set information. |
| Pathogen-scale trees | Nextstrain/Auspice JSON, UShER MAT protobuf, Taxonium JSONL | Designed for large public-health phylogenies and mutation-annotated trees. |
| Placement | JPlace | Used by EPA-ng, pplacer, and gappa-style placement workflows. |
| Nextclade outputs | aligned FASTA, TSV/CSV, JSON/NDJSON, translations, Auspice JSON | Should be treated as an analysis result set, not only as tree or alignment input. |

## Large Dataset Design Implications

- Do not parse large alignments or million-tip trees into single monolithic Swift values.
- Preserve the source file and generate indexed sidecars for fast viewport access.
- Design viewers around paging, virtualization, and lazy loading.
- Keep metadata and topology/residue storage separable so tree, MSA, and analysis-result views can share selections without requiring one combined file.
- For mutation-annotated trees, preserve mutation-level metadata rather than flattening to plain Newick.

## Candidate Tool Packs To Verify

Alignment:

- FAMSA.
- MUSCLE 5.
- Clustal Omega.
- MAFFT, with current Apple Silicon conda availability verified before making it a default dependency.

Tree inference:

- FastTree or VeryFastTree.
- IQ-TREE.
- RAxML-NG.

Placement and large public-health phylogenetics:

- UShER and matUtils.
- Nextclade and Nextalign outputs through the Nextclade CLI.
- Nextstrain Augur/Auspice workflow pieces where packaging is reasonable.
- EPA-ng, pplacer, and gappa for placement workflows.

Each tool needs current verification for conda availability, osx-arm64/noarch support, license compatibility, binary size, and runtime behavior before it becomes part of an LGE plug-in pack.

## Viewer Scope For Later Spec

MSA viewer:

- Virtualized alignment grid.
- Residue coloring schemes.
- Consensus and conservation rows.
- Sequence search, row filtering, sorting, and metadata columns.
- Optional reference-coordinate projection.
- Export of selected rows/ranges.

Tree viewer:

- Rectangular and radial layouts.
- Phylogram/cladogram mode.
- Branch labels, support values, and metadata coloring.
- Reroot, ladderize, collapse/expand, search, and selection linking.
- Linked selection with MSA rows and reference features.

## Relationship To Geneious Import

The Geneious importer should recognize MSA and tree objects and preserve the source data, but it should not block on these native bundles. Once `.lungfishmsa` and `.lungfishtree` exist, the Geneious importer can route recognized alignment/tree documents into those bundles instead of preserving them as unsupported content.

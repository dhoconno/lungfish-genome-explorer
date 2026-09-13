# Primer analysis results

The `.lungfishprimeranalysis` directory format preserves externally produced analysis files and the provenance of their import into LGE. It is separate from the `.lungfishprimers` scheme exchange format. The implementation provides workflow APIs, CLI inspection, and a read-only app viewer; it does not install or execute Primer3 or PrimalScheme, attach results to source documents, or provide a graphical design interface.

## Durable records

`manifest.json` is the authoritative versioned inventory. It records stable analysis, run, input, and result UUIDs; the independent or combined grouping mode; result-to-input membership; and each stored artifact's relative path, descriptive role, format, SHA-256 digest, and byte size. The canonical import provenance is separately inventoried. The manifest is not included in its own checksum inventory.

Input and result labels are display metadata. Duplicate labels are allowed because identity comes from UUIDs. The confirmed example categories for the future design workflows are full-length MHC class I, class II DP, class II DQ, and class II DRB. These categories do not imply an experimentally validated assay or preset.

`independent` means the caller describes the saved analysis as separate schemes; `combined` describes a combined scheme. The container preserves this declaration and each result's input membership. It does not evaluate pool compatibility or infer how the native tool produced the files. In particular, grouping files in one container is not evidence that a combined design has been performed.

Unknown native outputs remain opaque files and are preserved byte-for-byte. Original upstream provenance can also be retained as an artifact. The wrapper records its own actual invocation; it never fabricates an upstream tool execution from an imported filename or tool label.

Each input record must reference an artifact with role `input`, and the inventory must contain at least one `nativeOutput` artifact. Results may be empty, allowing an upstream analysis that produced no candidates to retain its files. The roles `provenance` and `provenance-support` are reserved for the wrapper's own records.

## Integrity and provenance

The loader rejects unsupported schema versions, malformed inventories, invalid references, missing payloads, unsafe paths, mismatched sizes or checksums, and missing or structurally incomplete canonical provenance. All inventoried files must be regular files. Manifest paths are relative to the bundle and cannot traverse outside it.

Publication uses a new sibling staging directory and exclusive atomic publication to the destination. Existing destinations are preserved. Provenance refers to final stored payloads, while exact historical argv remain unchanged. A relocated bundle resolves current artifact URLs relative to its new location and can be inspected without the original files or design tools installed.

The writer requires an existing destination parent and the `.lungfishprimeranalysis` extension. Source and bundle paths must traverse real directories without symbolic links. Callers must coordinate access during writing and inspection: these checks do not provide isolation from another process concurrently modifying the same directory tree.

Integrity verification detects accidental changes and inconsistency between the inventory and payloads. It is not proof of biological validity or independent authentication of the author. The IO loader checks a documented structural subset of canonical provenance; the Workflow layer constructs that provenance using LGE's canonical writer.

## CLI inspection

```sh
lungfish-cli primers analysis inspect /path/to/results.lungfishprimeranalysis
lungfish-cli primers analysis inspect /path/to/results.lungfishprimeranalysis --json
```

Both output modes verify the complete stored inventory before returning output. Inspection is read-only and does not add another provenance record or change the bundle. The JSON mode prints the verified manifest.

## Opening in LGE

Select an analysis bundle in the project sidebar or open it using File > Open. Packaged app builds also register the format for opening from Finder. The sidebar treats the bundle as one item, including when its contents are invalid, so internal files do not become independent project inputs.

The read-only viewer validates the inventory off the main thread before displaying Overview, Results and Binding inspection. Overview and Results share primer/amplicon selection with saved spans, pools and oligo membership. Files and Provenance live in the standard Inspector. Files lists the inventoried payloads; Provenance displays canonical wrapper, engine execution and derived worksheet records from the bytes verified during loading, without legacy repair or rewriting. Results interprets versioned Primer3 normalized output and native PrimalScheme3 BED/reference files, preserving alternative primers and coordinate conventions. Integrity failures appear as loading errors. Switching to another document removes the analysis viewer, clears its Inspector scope and cancels validation, which checks for cancellation between file reads. These read-only presentations do not change the bundle schema.

This viewer does not require design tools to be installed. It does not invoke generic legacy provenance repair, modify the bundle, or claim experimental validation of the stored designs. Analysis details, Files and Provenance use the standard Inspector.

## Annotation links

Plain FASTA does not store annotations. Native LGE annotations can retain a typed `PrimerAnalysisAnnotationLink` using these scalar qualifiers:

| Qualifier | Value |
| --- | --- |
| `lungfish_primer_link_version` | `1` |
| `lungfish_primer_analysis_id` | Saved analysis UUID |
| `lungfish_primer_result_id` | Saved result UUID |
| `lungfish_primer_input_id` | Saved input UUID |

The helper returns no link when all four qualifiers are absent. Partial, unsupported, invalid, or multivalued link metadata is rejected. Reattaching the same link is idempotent; replacing a different existing link is rejected. Other feature metadata is preserved.

These stable references are independent of renderer-created annotation UUIDs. JSON and native BED14/SQLite roundtrips are covered by tests. The helper does not resolve the referenced bundle, validate source sequence checksums or coordinate mappings, publish annotations to source bundles, or repair malformed raw attributes that an upstream parser has already discarded.


## Engine payload conventions

Primer3 keeps original FASTA/native MSA snapshots under `source-inputs/`, selected unmasked templates under `inputs/`, exact Boulder input/output under `native/`, versioned results at `results/primer3-normalized-v1.json`, and linked BED14 features under `annotations/`. Normalized coordinates are zero-based half-open; oligo sequences are stored in their synthesis orientation. Conserved-region masking is recorded separately from the unmasked template and retains the same coordinates. Engine and normalization provenance reside in `execution-provenance/`, outside the reserved canonical wrapper directory, with roles `toolProvenance` and `workflowProvenance`.

PrimalScheme3 keeps every native output under `native/<resultID>/`, including BED, reference FASTA, native configuration, plots, logs and intermediate products. Independent schemes each have one input membership; a combined native panel has all selected memberships. Execution FASTA files use deterministic unique filenames and safe row identifiers. `inputs/<inputID>-row-map.json` schema 1 binds each original header and row index to its execution identifier without changing bases or row order. Original source bundles, including upstream provenance and coordinate maps, remain intact in their snapshots. Native BED uses the ARTIC v3 pool column, which must not be interpreted as a standard BED score.

`Create Annotated Reference` and `primers analysis annotated-reference` materialize the selected Primer3 template and linked BED14 features into a new `.lungfishref`. The import and annotation steps record their real invocation and source analysis, and retain the stable analysis/result/input links. The analysis remains immutable.

New PrimalScheme3-LGE custom-fork runs record their distinct tool name/version, explicit terminal-gap policy and native discovery backend. Their managed runtime receipt includes exact fork/upstream source revisions and a pinned release wheel. Stock PrimalScheme3 analyses retain their original provenance and remain readable.

### PrimalScheme ordering worksheet, version 1

New PrimalScheme analyses include `ordering-v1.csv` beside each stored
`primer.bed`. This is an LGE-derived artifact, not a file emitted by PrimalScheme.
It belongs to that scheme's result membership and is included in the bundle's
checksummed artifact inventory and publication provenance. The bundle format
remains version 1: older bundles without this optional artifact remain readable.

The vendor-neutral CSV has one row per native BED record, sorted by numeric pool
and retaining native order within each pool. Alternative oligos are never merged,
and pool identifiers remain scoped to their individual scheme. Columns preserve
oligo name, native 5′–3′ sequence (including reverse-strand oligos), length, native
reference identifier, 1-based inclusive binding coordinates, strand, and ambiguous
base count. Synthesis scale, purification, modifications, and order notes are
intentionally blank for the researcher to complete in a working copy. No vendor,
quantity, mixing ratio, completeness, or assay performance is inferred. CSV cells
are quoted and spreadsheet formula triggers are escaped with a leading apostrophe.

The result viewer groups oligos by pool, exposes sequences and ambiguity, and
reveals the stored worksheet. Its loader verifies the worksheet checksum and
recomputes the deterministic CSV from the stored BED before offering it. Editing
files inside a bundle invalidates integrity checks; make a working copy for order
preparation. All native outputs remain available in the Files inventory.

Mapped reference spans may differ from oligo sequence lengths because alignment
insertions or deletions affect coordinates. The worksheet preserves both values
separately; the oligo length is computed from its synthesis sequence, never from
the reference span.

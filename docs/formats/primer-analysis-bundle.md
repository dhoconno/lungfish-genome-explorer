# Primer analysis results

The `.lungfishprimeranalysis` directory format preserves externally produced analysis files and the provenance of their import into LGE. It is separate from the `.lungfishprimers` scheme exchange format. The initial implementation provides workflow APIs and CLI inspection; it does not install or execute Primer3 or PrimalScheme, attach results to source documents, or provide a graphical design interface.

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

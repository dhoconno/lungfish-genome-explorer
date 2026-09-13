# Primer order directory, version 1

A displayed-oligo order is a project-owned analysis directory under `Analyses/`. Its `analysis-metadata.json` uses tool ID `primer-order`, so renaming the directory preserves sidebar routing. It does not use the design, trimming-scheme or reference-bundle extensions: an arbitrary displayed subset need not contain complete amplicons and is not a new design execution.

## Contents

| Path | Purpose |
| --- | --- |
| `primer-order.xlsx` | Populated IDT `Sheet1` followed by `Order metadata` |
| `IDT-oPools.xlsx` | Identical vendor sheet in a single-sheet upload copy |
| `ordering.csv` | One row per captured oligo, including identity and optional order details |
| `order.json` | Schema version, order metadata, frozen selection, normalized ordered oligos, template SHA-256 and original publication path |
| `template.xlsx` | Exact hash-pinned template used by this export |
| `template-parts/` | Untouched extracted OpenXML template |
| `upload-parts/`, `workbook-parts/` | Generated OpenXML packages used by the recorded ZIP commands |
| `source-analysis/` | Byte-identical source manifest and all inventoried design evidence |
| Canonical provenance | Workflow/packaging identities, actual argv, resolved options, runtime, final input/output hashes and sizes, timing, status and useful stderr |

`order.json` uses schemaVersion 1. Its selection contains the captured time, source URL and complete manifest, display settings, compatibility readiness/counts and ordered selected primer IDs. Dates use Foundation Codable's seconds since 2001-01-01 UTC; workbook dates are ISO 8601. Individual oligo records retain primer, target, source-result, reference and amplicon identities, saved 5′–3′ sequence, zero-based half-open coordinates, original numeric pool and a distinct order pool name. Workbook and CSV coordinates are one-based inclusive. Source-result ordinals are assigned from the complete saved analysis so hiding one scheme does not renumber another.

The service reloads and validates source artifacts before resolving the frozen IDs, rejects a changed manifest or contradictory selection, and publishes without overwriting an existing directory. Compatibility is observed positional compatibility among assessable alignment rows, with unassessed rows recorded separately; it is not native discovery frequency or assay coverage. Changing display controls after opening the review sheet does not change that draft. An active compatibility filter without completed measurements cannot be captured.

The vendor sheet retains the supplied template's instructions, formatting and mixed-base reference. Entry columns remain `Pool name` and `Sequence`; optional metadata never becomes a sequence modification. Excel text cells preserve literal text, and CSV formula triggers receive a leading apostrophe. The template resource documents sanitization of irrelevant vendor author/workstation properties and both original and retained hashes.

Reopening verifies every output descriptor against current files, using the original publication root only to resolve relative membership after a move. The viewport and Inspector share the exact verified provenance envelope. Editing archived outputs produces an integrity error; editable working copies should be made outside the retained order. No submission to a supplier is performed.

# Project Storage Legacy Cleanup Fix

**Date:** 2026-07-30
**Status:** Approved by the user’s request for autonomous investigation and
implementation

## Problem

Manage Project Storage correctly discovers the old hidden data in the inspected
project, but classifies nearly all of it as not removable.

The inspected project contains:

- 15 retired workbook-generation archives using 13,632,405,504 bytes.
- 14 workflow staging/work directories using 12,128,485,376 bytes.
- only three visible genotype result bundles in the analysis directory.

Two implementation defects explain the retention:

1. Historical workbook manifests append a new
   `artifacts/workbooks/current.xlsx` descriptor on each update. The rest of
   Lungfish treats the last matching descriptor as authoritative, but the
   storage classifier requires exactly one matching descriptor. Thirteen
   archives map by size and SHA-256 to exactly one retained file in the
   surviving `32355-Ionis-CR-merged.lungfishgenotype` bundle, yet all archives
   after the first are rejected.
2. Every inspected workflow staging directory predates ownership markers.
   The scanner currently rejects a missing marker immediately, despite the
   approved storage design explicitly including legacy staging cleanup.

The deletion executor also assumes every workflow staging item has a marker,
so changing preview classification alone would still make cleanup fail.

## Chosen Approach

Use three cleanup confidence levels:

1. **Proven removable** — selected by default. This includes marker-backed
   terminal work and checksum-verified retired workbook generations.
2. **Legacy review required** — manually selectable, unchecked by default.
   This is limited to an exact historical staging name with a parseable run
   UUID and an existing, non-held historical run lock. It is never eligible
   for automatic cleanup.
3. **Not removable** — unselectable. This continues to include malformed
   names, missing or unsafe locks, held locks, symlinks, special files,
   identity changes, and live or ambiguous workbook authority.

Age and the number of visible bundles are never deletion authority.

## Workbook Archive Classification

- Resolve the archived current workbook using the last manifest revision whose
  path equals `currentWorkbookPath`, matching the established workbook
  validation rule.
- Verify the archived file’s size and SHA-256 against that descriptor.
- Search sibling live genotype bundles for retained revisions matching that
  descriptor.
- Verify each candidate retained file’s size and SHA-256 without following
  symlinks.
- Count matching live bundles, not stale manifest entries. Exactly one live
  bundle must match.
- Preserve all publication-lock, transaction-attestation, receipt, path,
  containment, and identity checks.

## Legacy Workflow Classification

A shared parser recognizes only:

- `.<bundle>.lungfishgenotype.run-staging-<UUID>`
- `..<bundle>.lungfishgenotype.run-staging-<UUID>.cohort-alignment-work`
- `..<bundle>.lungfishgenotype.run-staging-<UUID>.candidate-artifact-work`

The parser derives the intended visible result bundle and historical
`.<bundle>.lungfishgenotype.full-length-ont-mhc-run.lock`.

Classification requires the lock to exist and be safely probeable:

- held: not removable;
- missing or unsafe: not removable;
- unlocked: continue.

Every exact-pattern, markerless legacy item with an unlocked historical lock
is manual-review cleanup. It is never promoted to automatic or default-selected
cleanup merely because a result bundle or failure sidecar exists. This keeps
the rule easy to understand and avoids treating incomplete historical metadata
as deletion authority.

## User Interface

Manage Project Storage adds:

**Legacy workflow staging — review before moving**

These entries:

- are checkable but unchecked initially;
- explain that they predate ownership markers;
- state that the historical run lock is currently free;
- remain recoverable in Trash;
- are included in cleanup receipts when selected.

The existing proven categories remain selected by default. “Not Removable”
remains uncheckable.

## Execution and Provenance

The cleanup executor uses the same shared legacy parser to acquire and hold the
derived historical run lock through revalidation, detachment, and movement to
Trash. Marker-backed entries continue using marker-recorded locks.

Every selected legacy-review item receives the existing full inventory,
checksums, classification evidence, journal, disposition, Trash destination,
and canonical provenance envelope. No permanent-delete fallback is added.

Automatic cleanup remains restricted to marker-backed project temporary
entries and cannot select legacy-review staging.

## Tests

- Historical workbook manifests with repeated current paths use the last
  descriptor and become removable only when one live retained file matches by
  size and SHA-256.
- Same-size tampering, multiple live bundles, missing retained files, live
  authority, and malformed descriptors remain blocked.
- Legacy staging parser accepts only the three exact patterns.
- An exact legacy path plus an unlocked historical lock is review-required and
  unchecked by default.
- Held, missing, unsafe, and malformed cases remain blocked.
- The executor acquires the derived legacy lock and rejects a classification
  change between preview and execution.
- Cleanup preparation and receipts preserve full provenance requirements.
- Existing scanner, executor, view-model, accessibility, and performance
  suites remain green.

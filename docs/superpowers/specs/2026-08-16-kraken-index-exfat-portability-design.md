# Kraken Index ExFAT Portability Hotfix — Design

Date: 2026-08-16
Status: Approved by explicit user authorization for autonomous beta28 recovery

## Problem and evidence

Beta28 Kraken2 batch indexes are valid, fully checkpointed SQLite databases, but the builder leaves their persistent journal mode set to WAL. On the ExFAT analysis volume, a read-only SQLite connection opens and then fails on its first prepared query with `SQLITE_IOERR` because WAL readers require shared-memory/locking support. All 56 affected indexes pass `PRAGMA quick_check` when opened immutably, have zero-byte WAL files, and retain the original checksums during diagnosis. A copied index becomes normally readable after changing its journal mode to DELETE.

## Design

- Open a legacy index with SQLite's `immutable=1` URI only when its WAL sidecar is absent or exactly empty. This is safe for the completed beta28 indexes because no uncheckpointed transaction can be hidden in a nonempty WAL, and it prevents SQLite from creating or locking sidecars. A nonempty WAL must use normal SQLite semantics; Lungfish must never ignore potentially committed data.
- Reuse the same read-opening strategy for queries and staleness validation.
- Keep WAL for build performance, then require a successful truncate checkpoint and switch to DELETE before reporting success. Check the finalization results so provenance cannot describe an incomplete index as completed.
- Do not rewrite the user's existing scientific batch. The compatibility reader preserves its bytes and provenance; future indexes are portable single-file databases.

## Verification and release

Add regression coverage for the legacy empty-WAL decision and portable output, run focused and broader tests, then exercise a patched CLI/app query against the real ExFAT batch read-only. Publish as an explicitly authorized in-place beta28 recovery: retain marketing version `0.5.0-beta28`, use a higher Sparkle build number, replace the notarized DMG and mutable beta/legacy feeds, and independently verify the published artifact.

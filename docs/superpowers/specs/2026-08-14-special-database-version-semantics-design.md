# Special Database Version Semantics

## Problem

Kraken2 special databases are catalog recipes that Lungfish builds locally. The
catalog uses a recipe version such as `kraken2-special-v1`, but the installer
currently replaces that value with a generated build identifier such as
`built-20260815-8e9a80931c70`. Update detection compares the installed and
catalog `version` fields directly, so every newly built SILVA or Greengenes
database immediately reports a false update.

## Design

For a managed catalog installation, `MetagenomicsDatabaseInfo.version` remains
the catalog recipe version. The registry resolves the current catalog entry by
stable `catalogID` after preparation and persists its version. Non-catalog
installations retain the installer's generated version as a fallback.

The locally produced payload remains uniquely and reproducibly identified by
the existing `payloadDigest`, `installedAt`, `lastUpdated`, and canonical
installation provenance. No provenance field or checksum is removed.

Existing successful special-database records produced by the affected debug
build are repaired only when their final provenance identifies the same recipe
version as the current catalog. This prevents a genuinely older special recipe
from being silently treated as current.

## Failure and Compatibility Behavior

- Pre-built catalog databases continue to compare their published build
  version normally.
- User-imported and other non-catalog databases retain their existing version
  behavior.
- A special database with missing, unreadable, failed, or mismatched provenance
  is not migrated and continues to report an update.
- Manifest persistence remains atomic. A migration is saved only after the
  provenance check succeeds.

## Verification

Tests must demonstrate that:

1. A newly installed SILVA catalog database stores `kraken2-special-v1` and
   does not report an update.
2. A non-catalog installation keeps the generated `built-*` fallback.
3. A legacy `built-*` special record migrates only when successful provenance
   reports the current catalog recipe version.
4. Mismatched provenance continues to report a genuine update.
5. Existing database registry, installer, provenance, and Plugin Manager tests
   remain green.

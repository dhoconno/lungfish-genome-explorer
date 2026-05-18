# Slice D Database Recommendation Note

Date: 2026-05-16
Branch: `codex/wave2-db-recommendation`

## Scope

Centralize Kraken2 database recommendation in `MetagenomicsDatabaseRegistry` so
the Plugin Manager header and row badge use the same registry-selected
recommendation source. The recommendation set is the general-purpose Kraken2
catalog intended for whole-system defaults.

## Intended Behavior

- Prefer the largest general-purpose catalog database whose recommended RAM is
  no more than 60% of physical RAM.
- If no general-purpose catalog database fits the 60% headroom threshold,
  recommend the smallest general-purpose database whose recommended RAM does not
  exceed physical RAM.
- If no general-purpose catalog database fits physical RAM, show no
  recommendation rather than marking an oversized database as recommended.
- Never recommend a database whose RAM requirement exceeds physical RAM.
- Specialist catalogs such as Viral, MinusB, and EuPathDB remain visible and
  selectable, but are not default whole-system recommendations.

## Verification Plan

Add focused Databases tab tests for 48 GB, 128 GB, 8 GB, and sub-8 GB
recommendation scenarios before changing production logic, then run
`swift test --filter DatabasesTabTests` and `swift build --target LungfishApp`.

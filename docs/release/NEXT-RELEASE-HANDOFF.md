# Historical handoff: dependency set 2026.2 release preparation

Status: completed by the CalVer preview release train. `v2026.8.1` was the
first CalVer tag, but its downloadable artifact was withdrawn after a
portability defect was found in the bundled micromamba binary. The corrected
replacement is `v2026.8.3`; see `docs/release-notes/2026.8.3.md`. The
intermediate `v2026.8.2` preparation tag was not published. Use the
release skill and current remote ledger for every later version rather than
the pre-release instructions below.

Merged to main on 2026-08-19 at f99b2bf6 (tag `deps-plan-c-complete`). Main was
fast-forwarded from `claude/lge-dependency-upgrade-plan-b6b53b`, 115 commits.

At the time of this handoff the branch had not bumped the app version and main
still read `0.5.0-beta29`. That historical instruction has now been completed.

## Version bump sites (all must move together)

- `Sources/LungfishCore/AppVersion.swift` is the single source for the app version.
- `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, the
  top-level `"version"` field (NOT the per-tool `version` fields, which are tool pins).
- `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist`.
- Current-version test expectations such as
  `Tests/LungfishCoreTests/AppVersionTests.swift`. Preserve deliberate legacy
  decoding fixtures in dependency and provenance tests.

Write `docs/release-notes/<new-version>.md` before building: the release script copies
it into the Sparkle appcast entry. `docs/release-notes/deps-2026.2.md` already holds the
dependency-set notes and contains a draft block intended for that file.

## What ships in this release

Dependency set 2026.2: 31 manifest entries moved, plus SwiftPM package updates. Full
detail in `docs/release-notes/deps-2026.2.md` and
`docs/reports/2026-08-18-dependency-sweep-2026.2-results.md`.

The upgrade path was rehearsed against a clone of a real 57-environment install before
merge: see `docs/verification/2026-08-19-upgrade-path-rehearsal.md`. Users upgrading
from an earlier set get 23 environment reinstalls, 3 advisory database updates and a
micromamba bootstrap, about 3.5 GB, with no environments removed.

## Merged after the first handoff draft

Two additional bodies of work landed on main after the section below was written:

- The tier 3 first run and its fixes: a shipped esviritu detect path bug, the
  TaxTriage v3.3.8 --db requirement, and refreshed pipeline goldens. See
  docs/verification/2026-08-19-tier3-first-run.md.
- The codex/fix-bracken-installer branch, reconciled by merge: the Metagenomics
  pack now builds Bracken 3.1 from source (sha256-pinned tarball plus pinned
  toolchain), and Kraken read indexes are portable (main's implementation kept;
  the two branches had built the same feature independently). Serialized conda
  environment mutations, special database version migration, and per-sample
  Kraken extraction scoping also arrive with this merge.

## Known state at merge

- Full suite on merged main: see the run recorded in the rehearsal document. The only
  failures are the known environmental ones (`FileSystemWatcherTests` FSEvents, and a
  load-sensitive MEGAHIT 1.2.9 crash that passes in isolation and in tier 1).
- Tier 3 (`scripts/deps/run-pipelines.sh`) has still never run: it needs Apple
  Containers or Docker on the build host.
- CI `toolset-conformance` has not been dispatched, because the branch was never pushed
  before merging. Consider running it against main now that main carries the manifest.

## Release invocation

See `project_release_build` notes and `docs/release/sparkle-updates.md`. Two gotchas that
have bitten before: the tagged commit must already exist on origin before
`gh release create --target <sha>`, and never pass `--reuse-archive` after a successful
notarize and staple, because re-signing corrupts the stapled bundle.

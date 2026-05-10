# Repository Hygiene Spring Cleaning - Design Spec

**Date:** 2026-05-10
**Status:** Approved concept, written spec for review
**Scope:** Repository organization, stale artifact cleanup, canonical agent layout, documentation archive policy, test fixture hygiene, provenance guardrails, README/RTD update, version bump, and release readiness for the next alpha DMG.

---

## 1. Context

Lungfish Genome Explorer has accumulated planning records, review artifacts, generated assets, duplicated agent definitions, and fixture experiments across several top-level and documentation directories. This makes it harder to tell which files are current implementation guidance and which files are historical context.

The current repository state is clean on `main` and aligned with `origin/main`. The active codebase is concentrated in `Sources/`, `Tests/`, release scripts, CI, and the Read the Docs manual under `docs/user-manual/`. The cruft is mostly not source code. It is historical plans/specs/reviews, duplicate illustration asset trees, stale test fixture directories, tool-specific agent definitions split across hidden directories, and ignored local build artifacts.

This cleanup must preserve scientific reproducibility. Any retained fixture or workflow output that represents scientific data must either have valid Lungfish provenance or be explicitly quarantined as historical/non-active material. Missing provenance is a blocking defect for retained active scientific fixtures.

## 2. Goals

- Make it obvious which repository files are active sources of truth.
- Move old plans, specs, reviews, and prompts into an archive that preserves history without presenting those records as current guidance.
- Consolidate active agent definitions, process docs, and expert roles under one canonical `agents/` tree.
- Keep tool-specific agent discovery paths working for Codex and Claude where tests or local tooling require them.
- Remove or archive unreferenced test fixtures, duplicate docs assets, stale generated files, and orphaned test scripts.
- Preserve or backfill provenance for retained scientific fixtures and bundle outputs.
- Reconcile the user manual illustration assets so the manual uses one current asset tree.
- Update `README.md` to mention the primitive Read the Docs manual.
- Bump the app/CLI release version and prepare release notes that explain changes since `v0.4.0-alpha.11`.
- Verify the cleaned repository with the relevant build, test, docs, and release gates before producing a new notarized DMG.

## 3. Non-goals

- Rewriting application architecture or scientific workflow behavior as part of cleanup.
- Deleting active May 2026 expert review issues, product specs, release docs, or Read the Docs manual sources.
- Using a top-level junk-drawer archive for unrelated uncertain files.
- Publishing a release before signing/notarization credentials and Sparkle configuration are available.
- Treating git history alone as enough for decision records that are still useful to developers.
- Hiding provenance failures by moving active scientific fixtures out of sight.

## 4. Recommended approach

Use an active/archive split plus a canonical agent tree.

Active product, process, and release material stays in place:

- `Sources/`
- `Tests/` active SwiftPM and Xcode targets
- `docs/user-manual/`
- `docs/issues/`
- `docs/product-specs/`
- `docs/release/`
- `docs/release-notes/`
- `.github/`
- `scripts/`
- `containers/`
- package and Xcode project files

Historical documentation moves under `docs/archive/`, because the material is documentation history rather than runtime project infrastructure. A top-level `archive/` would encourage mixed-content dumping. `docs/archive/` keeps the rule narrower: archived docs are preserved for context, but are not current product or implementation guidance.

Active agent infrastructure moves under a top-level `agents/` directory because agents are operational project infrastructure, not product documentation. `.codex/agents/` and `.claude/agents/` remain tool-facing adapter locations when required, but they should no longer be the only place a developer can discover active project roles.

## 5. Target documentation layout

The active documentation surface should be small and intentional:

- `docs/user-manual/` - Read the Docs and PDF manual source.
- `docs/issues/` - active issue backlogs and reconciliation indexes.
- `docs/product-specs/` - active product-level epics and near-term technical programs.
- `docs/release/` - release process documentation.
- `docs/release-notes/` - published release notes.
- `docs/archive/` - historical plans, specs, reviews, and research that should not drive new work directly.

Archive structure:

- `docs/archive/README.md`
- `docs/archive/plans/`
- `docs/archive/designs/`
- `docs/archive/reviews/`
- `docs/archive/research/`
- `docs/archive/superpowers/plans/`
- `docs/archive/superpowers/specs/`
- `docs/archive/superpowers/reviews/`
- `docs/archive/superpowers/research/`
- `docs/archive/superpowers/prompts/`

Each archive folder should contain a short README or inherit the root archive README. The README must state that archived records are historical context, not active instructions.

## 6. Target agent layout

Canonical project agent infrastructure should live under:

- `agents/README.md`
- `agents/definitions/codex/`
- `agents/definitions/claude/`
- `agents/process/`
- `agents/specialists/`
- `agents/archive/`

`agents/README.md` is the single roster and dispatch guide. It should explain which agents are active, what each owns, which tool-facing adapter file mirrors it, and where review outputs belong.

`agents/definitions/codex/` contains canonical Codex agent definitions such as the release agent and GitHub issue engagement orchestrator.

`agents/definitions/claude/` contains canonical Claude/manual agent definitions such as documentation lead, code cartographer, bioinformatics educator, screenshot scout, brand copy editor, and any active manual-specific persona.

`agents/process/` contains lead-agent workflows and review protocols currently split across `docs/process/`.

`agents/specialists/` contains the expert role files currently in `roles/`. The implementation should fix the duplicate `21-*` numbering collision and update any stale references to "20 specialists."

Tool-facing adapter paths:

- `.codex/agents/` may keep mirror files or thin forwarding notes when tests/tooling require direct files there.
- `.claude/agents/` may keep mirror files or thin forwarding notes when Claude discovery requires direct files there.

The implementation must update tests that enforce `.codex/agents/release-agent.md` so they either validate the canonical `agents/` file or explicitly validate the adapter relationship.

## 7. Cleanup policy

Use this decision matrix for each candidate file or directory:

| Candidate type | Action |
| --- | --- |
| Active source, release script, CI, package/project file | Keep active |
| Active user manual source, RTD config, manual build script | Keep active |
| Current May 2026 issue backlog or product spec | Keep active |
| Historical plan/spec/review with decision value | Move to `docs/archive/` |
| Tool-facing active agent path | Keep as adapter or mirror |
| Canonical active agent/process/role | Move to `agents/` |
| Duplicate stale generated docs asset with no references | Delete after reference scan |
| Unreferenced scientific test fixture | Delete or archive only if not needed for provenance/history |
| Retained scientific fixture missing provenance | Backfill provenance before completion |
| Ignored local build output, local cache, `.DS_Store`, node modules | Delete locally, keep ignored |
| Orphaned script tests with useful coverage | Wire into verification or move to archive with explanation |

Archiving should use `git mv` so file history remains discoverable. Deletion should be reserved for files confirmed unused by tests, docs, release scripts, or app runtime.

## 8. Tests and fixtures

The active SwiftPM test roots declared in `Package.swift` remain active:

- `Tests/LungfishCoreTests`
- `Tests/LungfishIOTests`
- `Tests/LungfishUITests`
- `Tests/LungfishPluginTests`
- `Tests/LungfishWorkflowTests`
- `Tests/LungfishAppTests`
- `Tests/LungfishCLITests`
- `Tests/LungfishIntegrationTests`
- `Tests/Support/LungfishTestSupport`

The Xcode UI test target remains active through the Xcode project and `scripts/testing/run-macos-xcui.sh`.

Initial fixture cleanup candidates:

- Remove or archive `Tests/LungfishXCUITests/PrimerTrim/VariantCallingAutoConfirmXCUITests.swift` if it is still not part of the active Xcode sources build phase and only skips pending a missing fixture.
- Remove `Tests/Fixtures/gui-test-fastq/` if a fresh reference scan confirms no active usage.
- Remove or archive `Tests/Fixtures/metagenomics/` if a fresh reference scan confirms current tests synthesize fixtures instead.
- Preserve heavily referenced fixtures such as `Tests/Fixtures/sarscov2/`, active classifier fixtures, active iVar parity fixtures, SRA/NVD/NAO-MGS fixtures, primer scheme fixtures, and user-manual SARS-CoV-2 fixtures.
- Treat `scripts/tests/*.py` as orphaned until wired into CI/release verification or archived.

Before deleting any test fixture, run `rg` against `Sources/`, `Tests/`, `docs/`, `.github/`, and `scripts/`, and confirm the fixture is absent from package, Xcode, CI, docs, and release paths.

## 9. Provenance requirements

The cleanup must enforce the repository's Lungfish provenance requirements.

Retained active scientific bundles, derived outputs, classifier results, extraction fixtures, FASTQ fixtures, and workflow outputs must include provenance that records:

- tool or workflow name and version
- exact argv or reproducible shell command
- user-visible options and resolved defaults
- conda, container, and runtime identity when applicable
- input and output paths
- checksums
- file sizes
- exit status
- wall time
- useful stderr

GUI-imported CLI outputs must preserve or rehydrate CLI provenance so final `.lungfish*` bundles point at final stored payloads, not only staging files.

Known provenance audit candidates from the hygiene review include retained analysis fixtures under `Tests/Fixtures/analyses/`. The implementation plan must either backfill credible fixture provenance for retained analysis outputs or move those fixtures out of the active test surface.

## 10. User manual and illustrations

The Read the Docs manual is active and should stay under `docs/user-manual/`.

The manual currently references `docs/user-manual/assets/illustrations-imagegen/` from chapter Markdown, while `docs/user-manual/illustrations.yaml` and the older generator still reference `docs/user-manual/assets/illustrations/`. The cleanup should make one tree canonical.

Recommended outcome:

- Keep `assets/illustrations-imagegen/` as the current manual asset tree if chapter references remain pointed there.
- Update or retire `illustrations.yaml` and the old illustration generator so they do not imply that `assets/illustrations/` is current.
- Delete the older `assets/illustrations/` tree only after all references and generator tests are updated or removed.
- Preserve the recent May 10 illustration expert review while it remains salient.

The README update should add a concise "User Manual" or documentation sentence pointing to `https://lungfish.readthedocs.io/` and noting that the manual is primitive/early.

## 11. Version and release readiness

The next release target is `0.4.0-alpha.12`.

The implementation must synchronize version references in:

- `Lungfish.xcodeproj/project.pbxproj`
- `Sources/LungfishCLI/LungfishCLI.swift`
- `scripts/build-app.sh`
- app/help metadata that exposes the version
- release docs and examples that name the previous alpha version
- tests that assert release/version metadata
- new `docs/release-notes/v0.4.0-alpha.12.md`

`CFBundleVersion` should remain monotonic and may continue to be stamped by `scripts/release/build-notarized-dmg.sh` from the git commit count or `LUNGFISH_BUILD_NUMBER`.

The new release notes must summarize changes since `v0.4.0-alpha.11`, including:

- repository hygiene and active/archive split
- canonical agent organization
- stale fixture and asset cleanup
- provenance fixture repairs or quarantines
- README Read the Docs mention
- any release tooling/version metadata changes

The notarized DMG path remains `scripts/release/build-notarized-dmg.sh`.

## 12. Verification gates

Minimum verification before claiming cleanup complete:

- `git status --short --branch`
- `swift package resolve`
- `swift build --product Lungfish`
- `swift build --product lungfish-cli`
- CI fast gate equivalent from `.github/workflows/ci.yml`
- `swift test`
- `bash scripts/testing/run-macos-xcui.sh` when the local macOS/Xcode environment is available
- user manual build through the Read the Docs MkDocs config
- release script dry-run style checks where available
- release packaging tests if retained or wired into a runner
- provenance audit for retained scientific fixture directories

Minimum verification before publishing a DMG:

- signed/notarized build using `scripts/release/build-notarized-dmg.sh`
- `codesign --verify --deep --strict`
- `xcrun stapler validate`
- `spctl -a -vv -t open`
- SHA-256 checksum recorded
- `release-metadata.txt` inspected
- `notary-app-log.json` and `notary-dmg-log.json` retained as release artifacts
- GitHub release and Sparkle appcast verified after upload

## 13. Risks and mitigations

**Risk:** Moving agent files breaks tool discovery.

**Mitigation:** Keep `.codex/agents/` and `.claude/agents/` as adapters or mirrors until tool behavior and tests prove otherwise.

**Risk:** Archiving too much makes useful current backlog less visible.

**Mitigation:** Keep May 2026 issues, product specs, and recent expert reviews active until reconciled into an issue index or resolved work plan.

**Risk:** Deleting fixtures breaks hidden e2e flows.

**Mitigation:** Require reference scans and target-specific test runs before deleting fixtures.

**Risk:** Historical plans still appear in search and confuse future agents.

**Mitigation:** Add archive READMEs and update process docs so future work starts from active specs, issues, product specs, and `agents/README.md`.

**Risk:** Version bump misses a duplicated version string.

**Mitigation:** Use `rg "0\\.4\\.0-alpha\\.11|0\\.4\\.0-alpha\\.12"` and release tests before packaging.

## 14. Implementation sequence

1. Create archive and agent directory scaffolding with explanatory READMEs.
2. Move historical documentation into `docs/archive/`.
3. Consolidate agent definitions/process/roles into `agents/`, preserving required adapter paths.
4. Reconcile manual illustration assets and generator references.
5. Remove confirmed unused fixtures and local/generated cruft.
6. Backfill or quarantine provenance-missing retained scientific fixtures.
7. Update README, RTD mention, version metadata, and release notes.
8. Run verification gates and fix regressions.
9. Build the notarized DMG and verify release artifacts.
10. Push the clean `main`, publish the release, and verify remote state.

## 15. Success criteria

- A developer can identify active docs, archived historical records, active agents, and active tests without reading old plans.
- Active agents have one canonical roster under `agents/`.
- Tool-specific agent paths still work where required.
- Historical plans/specs/reviews are preserved but clearly marked as non-current.
- Duplicate illustration assets are reconciled.
- Unused fixtures and orphaned scripts are deleted or archived with evidence.
- Retained scientific fixtures satisfy provenance requirements or are removed from active use.
- README links to the early Read the Docs manual.
- Version metadata is bumped consistently to `0.4.0-alpha.12`.
- Release notes describe changes since `v0.4.0-alpha.11`.
- Local and remote `main` are clean after the cleanup is pushed.
- A fresh signed/notarized DMG is built and verified.

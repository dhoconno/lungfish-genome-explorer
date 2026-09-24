# Documentation storage strategy

**2026-09-23 · Recommendation · measured at HEAD `a1f439076`**

The question: should the docs move to a separate GitHub repository, or is there a better practice when docs take up this much space?

**Short answer:** do not move the docs as a whole. Split them by content type. Text that describes the product stays with the code. Binary media moves to a media repo pinned per release. Finished engineering records are deleted. Test fixtures move into `Tests/`. Do not rewrite git history now. The reason is specific to this repository and is given under "History" below.

## What is actually taking the space

| Content | Working tree | In git history (on disk) | What it is |
|---|---:|---:|---|
| `docs/user-manual/assets/illustrations-imagegen` | 148 MB | most of the 292 MB for `docs/user-manual` | Generated illustrations. Each is stored about three times, and the 26 `.source.png` files (53 MB) are referenced nowhere |
| `docs/user-manual/assets/screenshots` + `shots/` | 98 MB | (included above) | App screenshots, replayable from recipes (`build/scripts/run-shot.sh`) |
| `docs/user-manual/fixtures` | 37 MB | (included above) | Sample datasets. **Four Swift tests read these** (see below) |
| `docs/user-manual/reviews` | 17 MB | (included above) | Records from the reviewer and fidelity campaigns |
| `docs/user-manual/chapters` + YAML metadata | ~3 MB | small | The manual text itself |
| `docs/superpowers`, `docs/reports`, `docs/reviews`, `docs/archive` | ~6 MB, 700+ files | ~20 MB | Plans, specs, reports and archives written by agents |
| `Sources/LungfishWorkflow` resources (for comparison) | | 173 MB | Bundled runtime binaries |

- The whole `docs/` tree is 317 MB of a 512 MB checkout. The git object store is 1.15 GiB.
- Churn matters as much as bytes. Since 2026-09-01, 375 of 603 commits (62%) touched `docs/`. Docs added about 182K lines against 197K for everything else.
- The product docs are about 3 MB of text. Almost all of the weight comes from binary media and process records.

## Coupling that constrains the choice

- **Tests read manual fixtures:**
  - [DocumentationFixtureThresholdTests.swift:13](../../../Tests/LungfishCLITests/DocumentationFixtureThresholdTests.swift:13)
  - [FetchNCBIGFF3Tests.swift:71](../../../Tests/LungfishCLITests/FetchNCBIGFF3Tests.swift:71)
  - [IVarConverterViralReconParityTests.swift:122](../../../Tests/LungfishIntegrationTests/IVarConverterViralReconParityTests.swift:122)
  - [ManualMetadataConsistencyTests.swift:48](../../../Tests/LungfishAppViewTests/ManualMetadataConsistencyTests.swift:48), which checks `features.yaml`, `help-ids.yaml` and `parameters.yaml` against the app
- **The fidelity process checks chapters against the Swift source and the CLI binary.** That review is only meaningful when text and code are at the same commit.
- **The release tooling requires `docs/release-notes/<version>.md`** with specific header lines.
- **The in-app Help Book is built from `Sources/LungfishApp/Resources/HelpBook`, not from `docs/`.** The landing site (`docs/site`, Quarto, `pages.yml`) is small.

## Options considered

| Option | Verdict | Why |
|---|---|---|
| Move all docs to a separate repo | **No** | It saves space and churn but breaks docs-as-code. Chapters, `features.yaml` and parameter tables can no longer change in the same commit as the code they describe. The fidelity tooling would need a pinned code revision. Four tests lose their fixtures. Drift between manual and app is already the main documentation defect found in this audit (FEA-16, UX-13), and a split would make it worse. |
| Git LFS for binaries | **Possible, not preferred** | This is the standard answer for large binaries in one repo. However, GitHub LFS storage and bandwidth are metered, and you have said GitHub costs matter. Every worktree and agent clone also has to handle LFS pointers, and agents often get this wrong. |
| Git submodule for docs or assets | **No** | Submodules are awkward with the many worktrees and agents this project uses: detached heads, forgotten `submodule update`, SHA bumps in unrelated commits. |
| **Split by content type (recommended)** | **Yes** | Each kind of content goes where it is best versioned. See below. |

## Recommended layout

1. **Stays in the main repo (docs-as-code, about 5 MB):**
   - `docs/user-manual/chapters`, `features.yaml`, `parameters.yaml`, `help-ids.yaml`, `illustrations.yaml`, `GLOSSARY.md`, `ARCHITECTURE.md`
   - the manual build scripts, image recipes and lint rules
   - `docs/release-notes`, `docs/release`, `docs/design`, `docs/formats`, `docs/site`
   - the current audit and any spec or plan being actively implemented

   These change together with the code, and tests or release tooling depend on them.
2. **Moves to a separate media repo, e.g. `lungfish-manual-media`:**
   - final screenshots and illustrations only, one copy each
   - the `.source.png` intermediates are deleted, not moved

   The main repo records a small lock file (`docs/user-manual/media.lock`: repo URL, commit SHA, per-file SHA-256). The manual build script fetches that exact revision into an ignored folder. Chapters keep referencing the same relative paths. Screenshots are replayable from recipes, so the media repo is a cache of outputs, not a source of truth. This gives you what LFS offers without the metering, and needs no submodule.
3. **Deleted once finished (owner decision, see the end of this report):**
   - `docs/superpowers` (plans and specs once implemented), `docs/archive`, `docs/reviews`, older `docs/reports`
   - `docs/user-manual/reviews` campaign records

   These are working memory for agents, not product documentation. They drive most of the docs churn and make `git log` and code review noisy. When a plan is finished, delete its spec, plan and results in one commit. Git history keeps them.
4. **Moves into `Tests/Fixtures`:** the manual fixtures that tests read (`sarscov2-srr36291587` at least). Tests should never depend on `docs/`. For the large human fixtures (`hg002-*`, 32 MB), fetch-on-demand with a checksum fits the existing environment-gated test pattern better.
5. **Guardrails, all local (no GitHub runners):**
   - a pre-commit check rejecting new binaries over about 500 KB under `docs/` outside the media lock
   - a check that `features.yaml` entry points exist (already proposed in FEA-16)
   - a rule that plan and spec documents are deleted once finished

## History: do not rewrite it now

Moving files out does not shrink the existing clone. About 292 MB of manual history stays in the 1.15 GiB object store. Reclaiming it would take a one-time `git filter-repo` rewrite. **In this repository that is unusually dangerous:**

- **Sparkle build numbers come from the commit count.** [build-notarized-dmg.sh:1269](../../../scripts/release/build-notarized-dmg.sh:1269) sets `SPARKLE_BUILD_NUMBER=$(git rev-list --count HEAD)`. By default `filter-repo` drops commits that become empty. That would remove hundreds of docs-only commits, lower the count, and make every future build look *older* than what users have installed, so Sparkle would stop offering updates.
- **Commit SHAs are recorded everywhere.** Every SHA would change, which invalidates:
  - release tags and the "Previous versioned release" lines in release notes
  - provenance records and receipts that cite commits
  - all worktrees and open branches
  - every `file:line` link in reports that names a commit

**Recommendation:** accept the historical weight for now. Local worktrees share one object store, so you pay the cost once per machine. If you later want a slim history, do it only after REL-07 (single version source) has moved the build number off `rev-list --count`. Run it with `--prune-empty never`, re-create the tags, and schedule it between releases.

Moving docs churn out of the main repo still reduces the commit count going forward. The build number stays monotonic, so this is safe.

## Suggested sequence

1. **Delete the 53 MB of unreferenced `.source.png` files and the duplicate illustration copies.** This is a quick, low-risk start. Check references with `illustrations.yaml` first.
2. **Move the test-read fixtures into `Tests/Fixtures`** and update the four tests.
3. **Delete finished plans, specs, reviews and archives.** Add the "active only, delete when done" rule to the agent process docs.
4. **Create the media repo, the lock file and the fetch step in the manual build.** Move screenshots and illustrations. Keep the recipes in the main repo.
5. **Add the local pre-commit size guard.**
6. **Later, optionally:** a history rewrite, following the constraints above.

## Owner decisions (2026-09-23)

- **Finished engineering notes are deleted, not archived.** Git history preserves them. No `lungfish-engineering-notes` repo is created. Step 3 of the sequence becomes: delete finished plans, specs, reviews, `docs/archive` and campaign review records from the main repo. Keep only active specs and plans (and this audit until its plan is complete). Add the "active only, delete when done" rule to the agent process docs.
- **Manual media is pinned per app release.** `docs/user-manual/media.lock` names the media-repo commit and per-file SHA-256 for the manual that ships with each app version. The media repo is tagged `manual-v<app version>` at release time, so any past manual can be rebuilt exactly.

# Release Engineering, Signing/Updates, and Runtime Dependencies (REL)

Audit date: 2026-09-23. HEAD `a1f439076` (Preview 2026.9.38).
Reviewer area: release engineering, code signing and notarization, Sparkle update channels, version management, and third-party runtime dependency management.

## Scope

- `scripts/release/` (the `release.py` front door, about 25 Python modules, `build-notarized-dmg.sh`, the nightly coordinator, receipts and gates), `config/release-contract.json`, `config/test-catalog.json`.
- `docs/release/`, `docs/release-notes/` (read as claims to verify, not as evidence).
- `Lungfish.xcodeproj` vs `Package.swift`, both `Package.resolved` files, `Lungfish-Info.plist`, `lungfish-cli.entitlements`, the HelpBook `Info.plist`.
- Sparkle feed design (Debug / Preview / Stable), appcast generation, bridge feeds.
- Runtime dependencies: `Sources/LungfishWorkflow/Conda/`, `Sources/LungfishWorkflow/Dependencies/`, `ManagedTools/third-party-tools-lock.json`, bundled micromamba, managed Python runtime, database downloads, `containers/`, `scripts/bundle-native-tools.sh`.
- Supply chain: `.github/workflows/`, THIRD-PARTY-NOTICES.

## Method

- Read the coordinator, builder, signing pipeline, independent verification, appcast generation and GitHub publication code end to end.
- Ran `release.py --help` only. Did not run the release script, sign, notarize, publish or touch credentials.
- Inspected shipped artifacts read-only: the installed `/Applications/Lungfish Preview.app` (2026.9.37), `Lungfish.app` (Stable 2026.9.28), `Lungfish Debug.app`, and the 2026.9.38 candidate directory in the primary checkout (`build/Release/preview/a1f4390…/`). Mounted the published 2026.9.38 DMG with `hdiutil attach -readonly -nobrowse` to inspect file modes, then detached.
- Queried GitHub read-only with `gh run list`, `gh run view`, `gh release list`, `gh repo view`.
- Compared both `Package.resolved` files programmatically, hashed the committed micromamba against the lock, listed the bundled rootfs, and identified the bundled kernel with `file`/`strings`.

## Limits

- No build was run, so nothing about compile behavior is confirmed here.
- I did not execute a Sparkle update end to end, so claims about Sparkle behavior across a bundle-identifier change are Suspected.
- I could not see which machine serves the `xcode-27` runner label.
- Upload throughput numbers come from the project's own notes, not from a measurement I made.

## Executive summary

The release pipeline is careful about artifact integrity. It builds a credential-free unsigned candidate, binds it to a receipt, signs inside out with a journaled transaction, notarizes, staples, uploads the DMG before the appcast, and verifies the published assets by digest afterwards. The old `--reuse-archive` path that corrupted stapled bundles has been retired in favor of `--resume-candidate`. Those parts should be kept.

It still ships a real defect. The builder sets `umask 077` before `xcodebuild`, so every DMG since at least Stable 2026.9.28 contains an owner-only app bundle (0700 root, 270 of 276 entries not world-readable). On a shared lab Mac another account cannot launch an app installed by an admin. None of the roughly 25 gates checks file modes.

Around that core the process is overbuilt for a single-maintainer project shipping about 38 previews a month. There are about 12,250 lines of release Python and Bash and about 12,600 lines of tests for them. The actual regression gate is 8 XCTest classes, and no gate launches the GUI. CI has been failing on every push since 2026-09-14 because of an invalid workflow expression. Twelve previews shipped over red CI, and nothing in the release path notices.

There is no written or scripted way to pull a bad preview from Sparkle users. The build-number floor gate actually blocks republishing the previous appcast item.

On the dependency side, top-level conda specs are pinned to exact builds and the Python runtime is hash-locked, which is good. Transitive conda packages are resolved live, and multi-gigabyte database archives are not checksummed. The shipped Linux kernel (GPL-2.0) has no license notice or source offer. THIRD-PARTY-NOTICES is not in the app bundle and describes a tool set that no longer ships.

My overall view: fix the permissions and licensing defects now, repair CI, add a yank path, and then shrink the release machinery rather than extend it.

## Preserve (do not "fix" these away)

- **The two-phase `package` then `publish` split.** Packaging holds no credentials, and publish resumes against the exact receipt ([release.py:172-203](scripts/release/release.py:172), [release.py:280-314](scripts/release/release.py:280)). This is the right shape.
- **`--resume-candidate` in place of `--reuse-archive`.** The resigning trap is closed ([build-notarized-dmg.sh:36-37](scripts/release/build-notarized-dmg.sh:36)).
- **The journaled signing transaction.** It records an artifact per stage and refuses to proceed if a retained artifact changed. Signing is inside out with `--timestamp`, `--options runtime`, per-Mach-O signing of bundled tools, then Sparkle components, then the app, then a Team ID check ([signing_pipeline.py:132-162](scripts/release/signing_pipeline.py:132)).
- **Publication order.** The DMG is published before the appcast ([build-notarized-dmg.sh:1649-1657](scripts/release/build-notarized-dmg.sh:1649)). Mutable assets are uploaded only if the remote digest differs ([build-notarized-dmg.sh:996-1010](scripts/release/build-notarized-dmg.sh:996)). Recovery refuses to overwrite a DMG whose digest differs ([build-notarized-dmg.sh:930-946](scripts/release/build-notarized-dmg.sh:930)).
- **Post-publish independent verification.** It covers codesign, both staples, `spctl` on the DMG, the tool smoke test, and remote asset digests for the DMG, the feed and the bridge ([release.py:1856-1973](scripts/release/release.py:1856)).
- **Sparkle hardening.** The EdDSA public key is committed in the contract ([release-contract.json](config/release-contract.json)). `SUVerifyUpdateBeforeExtraction` is set in shipped builds.
- **Build number and version guard.** The build number comes from `git rev-list --count HEAD` and is checked live against every feed floor ([release.py:1669-1714](scripts/release/release.py:1669)). CalVer is verified against the built plist ([build-notarized-dmg.sh:1372-1375](scripts/release/build-notarized-dmg.sh:1372)).
- **Distinct bundle IDs per channel** going forward: Debug, Preview and Stable ([release-contract.json:8](config/release-contract.json:8), [:21](config/release-contract.json:21), [:36](config/release-contract.json:36)). This gives clean side-by-side installs.
- **SwiftPM hygiene.**
  - The Xcode project is a thin wrapper over the local package (`XCLocalSwiftPackageReference "."`).
  - Sparkle is `exactVersion 2.9.6` in both `Package.swift` and the pbxproj.
  - The two `Package.resolved` files are identical (29 pins each).
  - `check-package-resolved-consistency.sh` runs in CI and in the builder ([build-notarized-dmg.sh:1293](scripts/release/build-notarized-dmg.sh:1293)).
- **micromamba provenance.** The committed binary's sha256 equals the lock's `bootstrap.micromamba.sha256` (`ec2a072f…`, verified). The candidate receipt re-checks it ([release-candidate-receipt.py:469](scripts/release/release-candidate-receipt.py:469)).
- **Hash-locked Python runtime.** pip runs with `--require-hashes --only-binary=:all: --no-deps`, then an offline `--no-index` install ([ManagedPythonRuntimeInstaller.swift:382-390](Sources/LungfishWorkflow/Conda/ManagedPythonRuntimeInstaller.swift:382)). The Bracken source build is pinned by sha256.
- **Conda top-level specs** carry exact version and build string (all 17 tools and 25 pack tools). Installs use `--override-channels` ([CondaManager.swift:573](Sources/LungfishWorkflow/Conda/CondaManager.swift:573)).
- **`ci.yml` Actions** are SHA-pinned with `permissions: contents: read`, and CI pip uses `--require-hashes`.
- **No implicit pruning.** Prerelease pruning is off by default ([release.py:445](scripts/release/release.py:445)).

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| REL-01 | P0 | Shipped app bundles are owner-only (0700/0600) because of `umask 077` | Confirmed | S |
| REL-02 | P1 | CI workflow invalid since 2026-09-14, 24 straight failures, 12 previews shipped on red | Confirmed (failure), Traced (cause) | S |
| REL-03 | P1 | GPL-2.0 Linux kernel shipped without notice or source offer; THIRD-PARTY-NOTICES stale and not bundled | Confirmed | M |
| REL-04 | P1 | No rollback or yank path for a bad Sparkle release; the floor gate blocks the obvious one | Traced | M |
| REL-05 | P1 | Every `gh` call, including the ~167 MB DMG upload, is capped at 180 s | Traced | S |
| REL-06 | P2 | App version inside the hashed dependency manifest resets "Later" and stales receipts every release | Traced | S |
| REL-07 | P2 | Five hand-maintained version sites where one would do | Traced | S |
| REL-08 | P2 | Legacy alpha bridge and pre-2026.9.2 previews are offered updates with a different bundle ID | Suspected | S |
| REL-09 | P2 | Release machinery is heavy while the regression gate is thin and no gate launches the app | Traced | L |
| REL-10 | P2 | Release builds from the live working checkout, so stray untracked files block releases | Traced | M |
| REL-11 | P2 | Conda transitive dependencies are unpinned, so a "dependency set" is not reproducible | Traced | M |
| REL-12 | P2 | Database archives and one pipeline are not integrity-pinned; one catalog ID/URL mismatch | Traced | S |
| REL-13 | P2 | Pages deploy job (pages:write, id-token:write) uses tag-pinned third-party actions | Traced | S |
| REL-14 | P2 | Code claims a Stable release triggers CI conformance; no workflow listens for it | Traced | S |
| REL-15 | P3 | Nightly coordinator auto-commits agent worktrees into main inside the release tool, and is effectively unused | Traced | S |
| REL-16 | P3 | Dead or stale release/dependency artifacts (`containers/`, nonexistent smoke script reference) | Traced | S |
| REL-17 | P3 | Double notarization and no delta updates, so a full 167 MB download for each of about 38 releases a month | Traced | M |

---

### REL-01 (P0): Shipped app bundles are owner-only

**Evidence**

- [build-notarized-dmg.sh:1254](scripts/release/build-notarized-dmg.sh:1254) runs `umask 077` in the package phase. It is intended to protect private release directories, but it then runs `xcodebuild` ([build-notarized-dmg.sh:1296](scripts/release/build-notarized-dmg.sh:1296)) under that umask. Every file the build writes into the app is created 0600 or 0700.
- Nothing afterwards normalizes modes. The signing pipeline copies with `ditto`, which preserves modes ([signing_pipeline.py:141](scripts/release/signing_pipeline.py:141), [:182](scripts/release/signing_pipeline.py:182), [:190](scripts/release/signing_pipeline.py:190)). `grep` finds no `chmod -R` or `a+rX` anywhere in the release path.
- **Confirmed on the published 2026.9.38 DMG** (mounted read-only):
  - `Lungfish Preview.app` is `drwx------`.
  - `Contents/Resources/Lungfish.help` is `drwx------`.
  - `…/ManagedTools/third-party-tools-lock.json` is `-rw-------`.
  - `find … ! -perm -o=r` counts 270 entries, against 6 that are world-readable.
- The installed Preview 2026.9.37 and Stable 2026.9.28 in `/Applications` show the same modes. The locally built Debug app is `drwxr-xr-x`, which isolates the cause to the release packager.

**Impact / failure scenario.** An admin on a shared lab or core-facility Mac installs `Lungfish.app` into `/Applications`. Any other macOS account double-clicks it and gets "You do not have permission to open the application", or the app launches and fails to read its resource bundles. That includes the dependency lock, the help book and the Containerization kernel. Sparkle updates preserve the archive's modes, so installs that are already affected stay broken. This is release-breaking for any multi-user deployment, and it is invisible to a single-user maintainer.

**Recommendation**

- In `build-notarized-dmg.sh`, restrict `umask 077` to the subshell or commands that create private directories. The simplest option is `mkdir -m 700` or `install -d -m 700` for those directories, with `umask 022` for `xcodebuild`.
- Alternatively, normalize the unsigned candidate before the receipt is written with `chmod -R u+rwX,go+rX,go-w "$RELEASE_APP_PATH"`. Mode bits are not part of the code signature seal, but normalizing before the receipt keeps the receipt honest.
- Add a mode check to `scripts/smoke-test-release-tools.sh`, which runs both in signing and in `independent_verify`. It should fail if any path in the app lacks `o+r`, or any directory or Mach-O lacks `o+x`.

**Acceptance test.** Mount a newly built DMG read-only. `find "<mnt>/Lungfish Preview.app" ! -perm -o=r | wc -l` returns 0, and `find … -type d ! -perm -o=x` returns nothing. A second macOS user account can launch the app from `/Applications`. A unit test in `scripts/tests/test_release_smoke.py` feeds the smoke script an app containing one 0600 file and expects a failure.

**Effort.** S.

---

### REL-02 (P1): CI workflow invalid since 2026-09-14; releases shipped on red

**Evidence**

- `gh run list --workflow ci.yml`: every run since `96ccddd48` (2026-09-15 02:32Z) is `failure`, 24 in a row. The last green run was `c68203929` (2026-09-14 17:27Z). `gh run view 35871686435` reports "This run likely failed because of a workflow file issue", which means no job started.
- The failures begin with commit `821ca701a` (2026-09-14). That commit added a job-level `env: LUNGFISH_STORAGE_ROOT: ${{ runner.temp }}/lungfish-storage` ([ci.yml:144-145](.github/workflows/ci.yml:144)). The `runner` context is not available in `jobs.<id>.env`. The allowed contexts there are `github`, `needs`, `strategy`, `matrix`, `vars`, `secrets` and `inputs`. That makes the whole file invalid, including the push-triggered "Fast gate".
- The same commit changed every `runs-on` from `macos-26` to `xcode-27` ([ci.yml:37](.github/workflows/ci.yml:37)). `gh api …/actions/runners` returns `total_count: 0`. Once the expression is fixed, jobs may queue indefinitely unless a runner or a larger-runner label with that name exists.
- Previews 2026.9.27 through 2026.9.38 were tagged during this window. `release.py` never checks CI status.

**Impact / failure scenario.** The only automatic check on pushes is gone. Script-contract regressions, shell syntax errors, manifest round-trip drift and `Package.resolved` drift all go unnoticed. The maintainer sees permanently red CI and learns to ignore it.

The repository is public. If `xcode-27` ever becomes a self-hosted runner, the `pull_request` trigger would run fork code on that machine, which is plausibly the signing Mac. That is a security concern for later, not a current defect.

**Recommendation**

- Move `LUNGFISH_STORAGE_ROOT` to a step (`echo "LUNGFISH_STORAGE_ROOT=$RUNNER_TEMP/lungfish-storage" >> "$GITHUB_ENV"`) and keep job env static.
- Confirm that `xcode-27` resolves to a GitHub-hosted image. If it does not, revert to `macos-26` or the hosted label that carries Xcode 27.
- If a self-hosted runner is ever introduced, restrict it to `push` and `workflow_dispatch` and never `pull_request`.
- Add `actionlint` to the fast gate.
- Have `release.py doctor` warn, not block, when the latest `ci.yml` run on the candidate commit is not green.

**Acceptance test.** A push to main produces a green "Fast gate" run. `actionlint .github/workflows/*.yml` passes in CI. `release.py doctor` prints the CI state for HEAD.

**Effort.** S.

---

### REL-03 (P1): GPL kernel shipped without notice; notices stale and not bundled

**Evidence**

- `Sources/LungfishWorkflow/Resources/Containerization/vmlinux` is committed and ships in every app under `…/LungfishWorkflow.bundle/Contents/Resources/Containerization/vmlinux` (14.7 MB). `file` identifies it as "Linux kernel ARM64 boot executable Image", and `strings` shows "Linux version 6.12.28 … Ubuntu 22.04 gcc". The Linux kernel is GPL-2.0. Distributing the binary requires the license text and a source offer or accompanying source.
- [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) has no kernel, vmlinux or Kata entry (`grep -in "vmlinux|kernel"` returns nothing).
- The notices file describes a bundle that no longer exists:
  - It lists SAMtools, BCFtools, HTSlib, UCSC tools, pigz, SeqKit, vsearch and cutadapt as bundled ([THIRD-PARTY-NOTICES:31-260](THIRD-PARTY-NOTICES:31)).
  - The shipped `Tools/VERSIONS.txt` says "Only micromamba remains bundled".
  - It names micromamba "2.0.5-0" ([THIRD-PARTY-NOTICES:263](THIRD-PARTY-NOTICES:263)), but 2.9.0-0 ships.
- It omits compiled-in or embedded components that do ship: Sparkle.framework (MIT, bundled in `Contents/Frameworks`), grpc-swift, swift-protobuf, swift-nio, swift-nio-ssl and swift-crypto (which carry BoringSSL/OpenSSL/ISC notices), and the `vminitd`/`vmexec` rootfs from apple/containerization. The app bundle contains `SwiftProtobuf_SwiftProtobuf.bundle`, `swift-nio-ssl_NIOSSL.bundle` and `swift-crypto_Crypto.bundle`.
- THIRD-PARTY-NOTICES is **not in the shipped app**: `find "/Applications/Lungfish Preview.app" -name "THIRD-PARTY-NOTICES*"` returns nothing. The About window's loader tries `Bundle.main.url(forResource: "THIRD-PARTY-NOTICES")` ([ThirdPartyLicensesWindowController.swift:86](Sources/LungfishApp/App/ThirdPartyLicensesWindowController.swift:86)) and falls back to a summary generated from `tool-versions.json`. That summary contains only micromamba.

**Impact.** This is a license compliance defect on a public binary distribution: a GPL binary with no notice or offer, plus missing MIT/BSD/Apache attribution for bundled code. It is low probability of enforcement and high embarrassment, and it is the kind of thing an institutional software review flags.

**Recommendation**

- Generate the notices at build time from the sources of truth, not by hand. The inputs are `Package.resolved` (fetch each package's LICENSE from the SwiftPM checkout), `tool-versions.json`, and a new small `ManagedTools/bundled-payloads.json` describing `vmlinux` and `init.rootfs.tar.gz` with origin, version, license and source URL.
- Copy the result into `Contents/Resources/THIRD-PARTY-NOTICES` through a pbxproj resource or build phase.
- For the kernel, include GPL-2.0 text and a written offer or a stable URL to the exact kernel source and config used. Apple's containerization kernel recipe works if that is the origin; record it.
- Separate "bundled" from "installed on demand" in the file. The conda tools are not distributed by LGE, so they need only an informational list.
- Add a release gate: the notices must contain an entry for every Mach-O and payload under `Contents/` and every `Package.resolved` identity.

**Acceptance test.**

- `Contents/Resources/THIRD-PARTY-NOTICES` exists in the DMG.
- A script cross-checks it against `Package.resolved` pins and the bundle's payload list with zero misses.
- The About > Licenses window shows the Sparkle and Linux kernel entries.

**Effort.** M.

---

### REL-04 (P1): No rollback or yank path for a bad Sparkle release

**Evidence**

- Each publish generates the appcast from a fresh per-commit directory ([build-notarized-dmg.sh:1016-1060](scripts/release/build-notarized-dmg.sh:1016)). The appcast therefore has exactly one `<item>`. This was verified on the 2026.9.38 `appcast-beta.xml`, which contains a single item with `sparkle:version 4965`. It overwrites the mutable `sparkle-beta` asset.
- `validate_sparkle_build_number` requires the planned build to exceed the live feed's build ([release.py:1669-1714](scripts/release/release.py:1669), `check-sparkle-build-number.py`). Republishing the previous item (build N-1) through the supported front door is therefore refused.
- No document or command covers withdrawing a release. `grep -riE "rollback|yank|withdraw"` over `docs/release` and `scripts/release` finds only a historical note ([NEXT-RELEASE-HANDOFF.md:127](docs/release/NEXT-RELEASE-HANDOFF.md:127)) saying 2026.8.1 "was withdrawn" by shipping 2026.8.3.
- The only forward fix is a full `package` plus `publish`. The project's notes put that at 20 to 65 minutes, plus notarization latency.

**Impact / failure scenario.** A preview ships that corrupts projects or crashes on launch. Sparkle keeps offering it to every Preview user who has not updated yet until a new build is packaged, notarized and published. The maintainer's fastest move is a manual `gh release upload sparkle-beta appcast-beta.xml --clobber` with an older file from some `build/Release/preview/<old-commit>/` directory. That step is undocumented, bypasses every gate, and the independent verifier will not re-check it. Users who already updated cannot be moved back by Sparkle at all, because it never downgrades.

**Recommendation.** Add `release.py yank preview|stable [--to vX]`. It should:

1. Download the currently published appcast and keep it as evidence.
2. Fetch the previous versioned release's appcast item from its retained candidate directory, or regenerate it from that release's DMG and signature.
3. Upload it to the mutable feed and the bridge after digest-verifying the DMG still exists on its tag.
4. Mark the bad GitHub release with a "Withdrawn" title prefix and keep the tag.
5. Record a `docs/release-notes/<bad>.withdrawn.md`.

The build-number floor should accept an explicit `--yank` mode that allows equality with a known prior published build. Document the forward-fix path as `git revert` then `release.py package/publish`. Commit-count build numbers make the revert automatically higher.

**Acceptance test.** In a dry-run or fork contract, `release.py yank preview --to v2026.9.37 --dry-run` prints the exact appcast that would be published, and it matches the retained 9.37 appcast byte for byte. A unit test proves the floor gate rejects a lower build without `--yank` and accepts the named prior build with it.

**Effort.** M.

---

### REL-05 (P1): Every `gh` call, including the DMG upload, is capped at 180 s

**Evidence**

- `github_cli()` wraps all `gh` calls in `bounded_process.py --timeout 180` ([build-notarized-dmg.sh:657-660](scripts/release/build-notarized-dmg.sh:657)). That includes `release create … "$DMG_PATH"` ([:972](scripts/release/build-notarized-dmg.sh:972)) and the recovery `release upload` ([:944](scripts/release/build-notarized-dmg.sh:944)).
- The 2026.9.38 DMG is 166,935,984 bytes. At 180 s the upload needs a sustained rate of about 0.93 MB/s. The project's own release memory records about 100 KB/s uploads. At that rate the upload takes about 28 minutes, so it will time out.
- The recovery path has the same bound. After a timeout the operator has to upload by hand and re-run publish. That is the documented workaround in the 2026.9.31 notes.
- `gh release create` with an asset creates the public release first and then uploads. A timeout leaves a published prerelease with no DMG. Recovery handles that state ([:930-946](scripts/release/build-notarized-dmg.sh:930)), which is good, but it is subject to the same timeout.

**Impact.** Publishing depends on the network speed at the time. The step most likely to hit the timeout is the one operators then perform by hand outside the gates.

**Recommendation.** Give uploads their own phase with a size-derived budget, for example `max(600, size_bytes / 50_000)` seconds, or no wall-clock cap with a stall detector on progress. Also consider `gh release create --draft`, upload, verify the asset digest, and only then `gh release edit --draft=false`. The public release would then never exist without its DMG. `ensure_mutable_release` and metadata calls can keep 180 s.

**Acceptance test.** A unit test in `test_release_builder_phases.py` asserts that DMG uploads receive a timeout scaled to the file size, and that versioned release creation goes through a draft, upload, then undraft sequence. A throttled-network rehearsal (Network Link Conditioner at 1 Mbps) completes publish without operator intervention.

**Effort.** S.

---

### REL-06 (P2): App version inside the hashed dependency manifest

**Evidence**

- The lock carries the app version at top level: `"version": "2026.9.38"` ([third-party-tools-lock.json:4](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:4)). It is bumped with every release by the nightly helper ([nightly_prerelease_release.py:26-30](scripts/release/nightly_prerelease_release.py:26)).
- `ManagedToolLock` encodes `version` ([ManagedToolLock.swift:192-196](Sources/LungfishWorkflow/Conda/ManagedToolLock.swift:192)). `manifestHash` is sha256 of the sorted-key encoding of the whole manifest ([DependencyManifestSections.swift:332-338](Sources/LungfishWorkflow/Dependencies/DependencyManifestSections.swift:332)). The hash therefore changes on every release even when no tool changed.
- The user's "Later" choice on the Update Tools sheet is keyed to that hash ([AppDelegate+DependencyReconciliation.swift:131-136](Sources/LungfishApp/App/AppDelegate+DependencyReconciliation.swift:131)). The fast-path skip also requires `receipt.manifestHash == manifest.manifestHash` ([:52-55](Sources/LungfishApp/App/AppDelegate+DependencyReconciliation.swift:52)).
- The release-side receipt check compares the same hash ([release.py:238-277](scripts/release/release.py:238)). That is the documented "receipt stales on every version bump" trap. It is currently dormant only because `dependencyPolicy` is `"manifest"` ([release-contract.json:84](config/release-contract.json:84)).

**Impact.** For any user with outstanding optional tool work, the Update Tools sheet reappears after every preview update, about 38 times a month, even though the tool set did not change. Every update also forces a full reconciliation plan at launch. Release operators hit a stale receipt on every bump if the installed policy is re-enabled.

**Recommendation.** Remove the app version from the lock file. The lock should be identified by `dependencySet` plus a content hash of `tools`, `packTools`, `pipelines`, `databases` and `bootstrap`. If a pack version is still needed for UI display, derive it from `LungfishAppVersion.short` at runtime. Compute `manifestHash` over the dependency sections only, and keep a one-time migration that treats old receipts whose hash matched the full encoding as current. Update `CondaManagerTests` to stop comparing the lock version to the app version.

**Acceptance test.** Bump `LungfishAppVersion.short` without touching tools. `ManagedToolLock.bundled.manifestHash` is unchanged. A unit test asserts that the deferral survives a version-only change and is cleared by a tool spec change.

**Effort.** S.

---

### REL-07 (P2): Five hand-maintained version sites

**Evidence.** The release version is written in:

- [AppVersion.swift:6](Sources/LungfishCore/AppVersion.swift:6)
- [AppVersionTests.swift](Tests/LungfishCoreTests/AppVersionTests.swift), a literal assertion
- `MARKETING_VERSION` in four build configurations in [project.pbxproj:430](Lungfish.xcodeproj/project.pbxproj:430) (plus 461, 541, 563)
- the HelpBook `Info.plist` ([Info.plist:15-16](Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist:15))
- the tool lock ([third-party-tools-lock.json:4](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:4))

The builder already treats `AppVersion.swift` as the source ([build-notarized-dmg.sh:494](scripts/release/build-notarized-dmg.sh:494)) and already overrides `CFBundleVersion` with `plutil` ([:873](scripts/release/build-notarized-dmg.sh:873)). The nightly helper carries a validator for all five ([nightly_prerelease_release.py:557-605](scripts/release/nightly_prerelease_release.py:557)), which shows this has already caused drift.

**Impact.** Every release is a five-file commit. Any miss produces a mismatch, which is caught late at package time.

**Recommendation.** Keep `AppVersion.swift` as the single source.

- Pass `MARKETING_VERSION="$SOURCE_VERSION"` on the `xcodebuild` command line and set the pbxproj value to a placeholder such as `0.0.0` that is never shipped.
- Stamp the HelpBook plist in the existing "Index Help Book" build phase.
- Drop the lock `version` (REL-06).
- Change `AppVersionTests` to assert the CalVer format and the `cliToolVersion` composition, not a literal.
- Add a script `scripts/release/bump-version.py <version>` that edits the one file and writes the release-notes skeleton.

**Acceptance test.** `git grep -n "2026\.9\.38"` outside `docs/` returns only `AppVersion.swift`. A packaged app shows the right `CFBundleShortVersionString` and HelpBook version.

**Effort.** S.

---

### REL-08 (P2): Legacy bridge and old previews are offered updates with a different bundle ID

**Evidence**

- Preview switched to `com.lungfish.browser.preview` on 2026-08-30 (`efb11fdb1`, [release-contract.json:8](config/release-contract.json:8)). The project's own document states "Older Preview builds used the Stable identifier and therefore require a one-time manual reinstall" ([sparkle-updates.md:49-55](docs/release/sparkle-updates.md:49)).
- Every preview publish still copies the new preview item into the `sparkle-alpha/appcast-alpha.xml` legacy bridge ([release-contract.json:14-15](config/release-contract.json:14), [build-notarized-dmg.sh:1086-1095](scripts/release/build-notarized-dmg.sh:1086)). The only consumers of that feed are old Alpha builds with the old identifier. Old Beta-feed previews with the old identifier also read `appcast-beta.xml`.
- The project notes say Sparkle rejects updates whose bundle ID differs from the installed app. I did not run such an update, so the rejection path is Suspected.

**Impact.** If the notes are right, those installs get an update prompt on every check that then fails to install, possibly with an error dialog. The bridge also adds a third feed to maintain, verify and gate.

**Recommendation.** Decide one of two options.

- **(a) Retire the bridge.** Publish a final static `appcast-alpha.xml` whose item points to a one-time "migration" build that keeps the old ID and shows a "download Lungfish Preview" notice. Then freeze it and remove `legacyBridge*` from the contract and the floor checks.
- **(b) Verify empirically** that Sparkle 2.9.6 installs across the ID change, and document it.

Also consider having the app detect an old-ID preview on first launch of the new ID and offer to move settings.

**Acceptance test.** Install an old-ID Preview (2026.8.x) on a clean VM, point it at the live feeds, and record the outcome. After the fix, the old install sees either nothing or a working migration build.

**Effort.** S.

---

### REL-09 (P2): Heavy release machinery, thin regression gate, no GUI launch

**Evidence**

- Release code is 12,253 lines (`wc -l scripts/release/*.py scripts/release/*.sh`). Release-specific tests are about 12,600 lines across 25 files. The largest are [test_release_builder_phases.py](scripts/tests/test_release_builder_phases.py) (2,305 lines), [test_nightly_prerelease_release.py](scripts/tests/test_nightly_prerelease_release.py) (2,211) and [test_release_preflight.py](scripts/tests/test_release_preflight.py) (1,735).
- `scripts/release` changed in 55 commits since 2026-08-01.
- The actual Swift regression gate for both channels is the `release` profile ([test-catalog.json:177-195](config/test-catalog.json:177)). Its filter selects 8 XCTest classes: BundleManifest, GenomicRegion, RuntimeResourceLocator, Sequence, BAMPrimerTrimProvenance, MappingProvenance, ScientificProvenancePolicy and ScientificCLIProvenanceCoverage.
- `appSmokeRequired` is `false` ([release-contract.json:85](config/release-contract.json:85)). The signed-app smoke ([signing_pipeline.py:160-165](scripts/release/signing_pipeline.py:160)) exercises micromamba and the CLI. Nothing launches the GUI app from the candidate.
- Much of the machinery guards against threats that do not fit a one-person signing Mac: symlinked JSON, hard-link counts, file-mode audits of private caches, sanitized environments, boot-bound credential proof ([release-doctor.py:895-922](scripts/release/release-doctor.py:895)), cache fingerprints and namespace locks. Meanwhile the defects that actually shipped were permissions (REL-01), a timeout (REL-05) and an invalid CI file (REL-02). None of the guards caught them.

**Impact.** The process takes 20 to 65 minutes and traps the operator in ways the notes record: stale receipts, clean-tree trips, boot-expired proofs and upload timeouts. It still does not test what users run. Each new guard adds a new failure mode and another thousand lines of tests. For roughly daily previews, the cost-to-assurance ratio is poor.

**Recommendation.** Rebalance rather than add.

1. **Collapse to four phases.** Build (xcodebuild from a clean export, REL-10). Verify the artifact: codesign, modes (REL-01), notices (REL-03), portability scan, CLI smoke, and a 30-second headless GUI launch using the existing `testReleaseCandidateLaunchAndChannelIdentity` XCUITest or `open -W --args --smoke-exit`. Sign and notarize (keep `signing_pipeline.py` as is). Publish and verify (keep `independent_verify`).
2. **Retire** the nightly coordinator (REL-15), the legacy bridge (REL-08), fork configuration if no fork exists, cache fingerprinting (Xcode DerivedData is already content-addressed enough for one machine), and boot-bound setup proof, or keep that last one as a warning only.
3. **Make `appSmokeRequired: true`** for Stable, and for Preview at least run the launch-and-channel-identity test.
4. **Widen the Swift gate for Stable** to the `headless` profile. Preview can stay compact.
5. **Set a budget:** after refactoring, target under 4,000 lines of release code with tests proportional to it.

**Acceptance test.** The package-to-publish wall time for a preview is under 25 minutes on the release Mac. The candidate GUI launches in the gate. Every trap listed in the project's release notes has either a removal or a regression test.

**Effort.** L. Do it in slices after WP1 to WP3.

---

### REL-10 (P2): Release builds from the live working checkout

**Evidence**

- Package and publish require a spotless working tree, including untracked files anywhere: [release-doctor.py:649-655](scripts/release/release-doctor.py:649), [gate_evidence.py:82-90](scripts/release/gate_evidence.py:82) (`--untracked-files=all`) and [release-candidate-receipt.py:119-121](scripts/release/release-candidate-receipt.py:119).
- The 2026.9.31 release was blocked by stray untracked docs.
- The Xcode "Hydrate worktree resources" phase runs `scripts/setup-worktree.sh` in every configuration, including Release. It copies gitignored runtime files and symlinks database payloads from the primary checkout into `SRCROOT` (pbxproj phase at line ~310, [setup-worktree.sh](scripts/setup-worktree.sh)). Ignored files are invisible to the clean-tree check and the worktree digest.

**Impact.** Operators lose time cleaning unrelated files. Meanwhile the "built from the exact commit" guarantee is weaker than it looks, because ignored inputs can enter the build.

**Recommendation.** Have `release.py package` create a disposable `git worktree add --detach <tmp> <commit>`, or `git archive`, and build from there. Stray files in the operator's checkout then do not matter, and ignored files cannot leak in. Skip the hydrate phase when `CONFIGURATION=Release`, and fail if a required ignored payload is missing. Keep the "commit exists on origin" and "HEAD is ancestor of origin/main" checks.

**Acceptance test.** With an untracked `notes.md` in the primary checkout, `release.py package preview` succeeds. The unsigned candidate is byte-identical, modulo timestamps, to one built from a pristine clone. Release builds log that hydration was skipped.

**Effort.** M.

---

### REL-11 (P2): Conda transitive dependencies are unpinned

**Evidence**

- Every lock spec pins one top-level package with a build string (for example `bioconda::minimap2=2.31=h6bd33b9_0`). Installs call `micromamba create/install -n <env> --override-channels -c … <spec>` ([CondaManager.swift:573-576](Sources/LungfishWorkflow/Conda/CondaManager.swift:573), [:724-727](Sources/LungfishWorkflow/Conda/CondaManager.swift:724)).
- Dependencies such as htslib, python, numpy, zlib and libcxx are solved live against the current channel state.
- `CondaRequestedEnvironmentSpecification` says so itself: "Requested inputs only. No package solve … is implied" ([CondaLockfileService.swift:33-34](Sources/LungfishWorkflow/Conda/CondaLockfileService.swift:33)).
- There is no `@EXPLICIT` lock with URLs and md5 or sha256, and no package-level checksum verification.

**Impact.** Two users on "dependency set 2026.2" can run different htslib or numpy builds, depending on install date. This affects scientific reproducibility claims (provenance records the top-level version only), and a bad upstream rebuild can break installs with no code change. Supply-chain exposure is limited to conda-forge and bioconda themselves, but nothing pins what was actually tested.

**Recommendation**

- Generate per-environment explicit lockfiles for `osx-arm64` (`micromamba env export --explicit --md5`, or `conda-lock`) on the release Mac when a dependency set is cut.
- Commit them under `ManagedTools/locks/<env>.txt` and install with `micromamba create -n <env> --file <lock>` (explicit mode skips the solve and verifies md5).
- Record the lock digest in the dependency receipt and in provenance.
- Keep the top-level spec as the human-facing identity.

**Acceptance test.** Installing the same dependency set on two machines a month apart gives identical `conda list --explicit --md5` output. A tampered package md5 in the lock fails the install.

**Effort.** M.

---

### REL-12 (P2): Database archives and one pipeline are not integrity-pinned

**Evidence**

- Kraken2 databases are dated immutable archives, for example `k2_standard_20260626.tar.gz`. EsViritu v3.2.4 on Zenodo is also immutable. All are declared `"sourcePolicy": "unpinnedArchive"` with no `sha256` or `md5` ([third-party-tools-lock.json:62-71](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:62)).
- The installer verifies only when a digest is present ([MetagenomicsDatabaseInstallProvenance.swift:469-482](Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstallProvenance.swift:469)). Otherwise it just records whatever hash it got.
- `nf-core-viralrecon` is pinned to `"revision": "3.0.0"`, a mutable tag, while taxtriage is pinned to a commit SHA ([third-party-tools-lock.json:58-59](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:58)).
- The catalog entry `kraken2-eupathdb46` / "EuPathDB46" downloads `k2_eupathdb48_20230407.tar.gz` ([third-party-tools-lock.json:70](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:70)). The user-visible name and ID say 46 while the data is 48.

**Impact.** A truncated or corrupted multi-GB download that still extracts gives silently wrong classifications. Provenance would faithfully record the wrong hash. The EuPathDB label misstates which database produced a result.

**Recommendation.** Record `sha256` for every dated archive. Upstream publishes md5 for Zenodo records, and the index zone lists sizes and md5s. Switch those entries to `pinnedArchive`. Pin viralrecon to the commit behind 3.0.0. Rename the EuPathDB entry to 48, keeping an alias for existing installs. Keep `unpinnedArchive` only for truly rolling sources, and `liveSnapshot` for taxdump.

**Acceptance test.** A lock validator test fails if any `unpinnedArchive` URL contains a date or version stamp without a digest. Corrupting one byte of a cached archive makes the install fail with `archiveChecksumMismatch`.

**Effort.** S.

---

### REL-13 (P2): Pages deploy job uses tag-pinned third-party actions

**Evidence.** [pages.yml:18-21](.github/workflows/pages.yml:18) grants `pages: write` and `id-token: write`. It uses `quarto-dev/quarto-actions/setup@v2` ([:47](.github/workflows/pages.yml:47)), `actions/upload-pages-artifact@v3` ([:55](.github/workflows/pages.yml:55)) and `actions/deploy-pages@v4` ([:69](.github/workflows/pages.yml:69)) by mutable tag. It runs on every published release. `ci.yml` pins by SHA, so this is an inconsistency.

**Impact.** A compromised `quarto-actions` tag could deploy arbitrary content to lungfish.bio, which is the page users download DMGs from. Notarization limits the damage for the app itself, but a phishing redirect is enough.

**Recommendation.** SHA-pin all three actions with version comments. Add Dependabot or Renovate for `github-actions`, restricted to digest updates.

**Acceptance test.** `grep -E "uses: [^@]+@v[0-9]" .github/workflows/*.yml` returns nothing. An actionlint or pinact check in the fast gate enforces it.

**Effort.** S.

---

### REL-14 (P2): Claimed post-release CI conformance does not exist

**Evidence.** [build-notarized-dmg.sh:957-958](scripts/release/build-notarized-dmg.sh:957) says "A full release fires the 'released' event, which runs CI's heavy board (build smoke + toolset conformance) on this tag." `ci.yml` triggers only on `push`, `pull_request` and `workflow_dispatch` ([ci.yml:3-19](.github/workflows/ci.yml:3)). Toolset conformance runs only on manual dispatch. The only workflow listening to `release` is Pages.

**Impact.** Stable releases go out believing a conformance run follows them. None does. Stable 2026.8.4's MEGAHIT defect was caught this way in the past ([NEXT-RELEASE-HANDOFF.md:122-124](docs/release/NEXT-RELEASE-HANDOFF.md:122)), so the lost safety net has already paid for itself once.

**Recommendation.** Either add `release: types: [released]` to `ci.yml` for `toolset-conformance`, pinned to the tag, or run `scripts/test.py run --profile tool-conformance` as a required Stable pre-publish gate on the release Mac. Delete the stale comment in either case.

**Acceptance test.** Publishing a Stable release, in a fork or by dry run, produces a toolset-conformance run on that tag, or `release.py publish stable` refuses without conformance evidence.

**Effort.** S.

---

### REL-15 (P3): Nightly coordinator merges and auto-commits agent work inside the release tool

**Evidence**

- `run-nightly-prerelease.sh` calls `nightly_prerelease_release.py` (931 lines). That script can `git add -A && git commit` inside approved agent worktrees ([nightly_prerelease_release.py:453-475](scripts/release/nightly_prerelease_release.py:453)), merge them into main ([:477-497](scripts/release/nightly_prerelease_release.py:477)), bump version sites, and publish ([:912-918](scripts/release/nightly_prerelease_release.py:912)).
- The last auto-capture commit was 2026-06-06 (`fd1463b30`). All recent previews are "Prepare Lungfish Preview …" commits made by hand.
- It carries 2,211 lines of tests.

**Impact.** It is an unused, high-privilege code path that combines integration, versioning and release. It is a trap if someone revives it, and a maintenance cost meanwhile.

**Recommendation.** Delete `nightly_prerelease_release.py`, `run-nightly-prerelease.sh` and their tests. Replace `docs/release/nightly-alpha-releases.md` with a pointer to `sparkle-updates.md`. Keep collision-free CalVer selection as a small helper in `bump-version.py` (REL-07).

**Acceptance test.** `git grep nightly_prerelease` returns nothing outside history. The release tests still pass.

**Effort.** S.

---

### REL-16 (P3): Dead or stale release and dependency artifacts

**Evidence**

- `containers/` (four Dockerfiles and `build-images.sh`, last touched 2026-05-16) is referenced by nothing in `Sources`, `scripts`, `.github` or `docs/release`. [Dockerfile.ucsc-tools:23](containers/Dockerfile.ucsc-tools:23) downloads a **macOS** `bedGraphToBigWig` into an Alpine Linux image over plain `http://` with no checksum, which would never have worked for arm64.
- The test catalog's `ui` profile names `scripts/release/app-smoke-gate.sh` ([test-catalog.json:221-222](config/test-catalog.json:221)), which does not exist. The implementation is `app_smoke_gate.py`.
- Many tests still reference micromamba 2.0.5 (`scripts/tests/test_bump.py:87`). That is harmless but stale.

**Recommendation.** Delete `containers/`. Fix the catalog path, or remove `nativeXCUITestCommand` if unused.

**Acceptance test.** `ls containers` fails. A catalog test asserts every referenced script path exists.

**Effort.** S.

---

### REL-17 (P3): Double notarization and no delta updates

**Evidence**

- The signing pipeline notarizes the app zip ([signing_pipeline.py:177](scripts/release/signing_pipeline.py:177)) and then the DMG ([:203](scripts/release/signing_pipeline.py:203)), which means two notary round trips.
- Apple's guidance is to notarize the outermost container. Submitting the signed DMG notarizes the nested app's code, and the app can then be stapled from that ticket.
- The appcast directory holds only the new DMG ([build-notarized-dmg.sh:1041-1042](scripts/release/build-notarized-dmg.sh:1041)), so `generate_appcast` never produces deltas.
- Each preview is a full 167 MB download. At about 38 releases a month that is roughly 6 GB per tester.

**Recommendation**

- Notarize only the DMG. Staple both the DMG and the app, keeping the app staple so an extracted app validates offline.
- Keep the last 3 to 5 DMGs in a persistent per-channel appcast workspace, or download them from their tags, so `generate_appcast` emits `sparkle:deltas`.
- Separately, consider whether a daily preview cadence serves testers.

**Acceptance test.** One `notarytool submit` per release in the transaction journal, with `stapler validate` passing on both artifacts. The appcast contains `<sparkle:deltas>` for the previous build, and a Sparkle update from N-1 downloads a delta.

**Effort.** M.

---

## Proposed work packages

Order matters. Each package is independently reviewable.

**WP1: Ship-blocker fixes (REL-01, REL-02). Risk: low.**

- Files: `scripts/release/build-notarized-dmg.sh` (umask scope or chmod normalization), `scripts/smoke-test-release-tools.sh` (mode check), `scripts/tests/test_release_smoke.py`, `.github/workflows/ci.yml` (env fix, runner label, actionlint).
- Cut a preview immediately after, then verify from a second macOS account.
- Dependencies: none.

**WP2: License compliance (REL-03). Risk: low code risk, some legal judgment.**

- Files: a new `scripts/release/generate-notices.py`, a new `ManagedTools/bundled-payloads.json`, a pbxproj resource entry, `THIRD-PARTY-NOTICES` (generated), `ThirdPartyLicensesWindowController.swift` (drop the manifest fallback or make it complete), and a release gate in the smoke script.
- Dependencies: none. It can run in parallel with WP1.

**WP3: Publication robustness (REL-05, REL-04, REL-14). Risk: medium, because it touches the publish path.**

- Files: `build-notarized-dmg.sh` (upload budget, draft-then-publish), `release.py` (new `yank` subcommand, floor-gate `--yank` mode), `check-sparkle-build-number.py`, `ci.yml` or the Stable gate list in `release-contract.json`, and `docs/release/sparkle-updates.md` (yank and forward-fix runbook).
- Dependencies: WP1, so CI is green to validate it.

**WP4: One version source (REL-06, REL-07). Risk: medium, because it touches runtime receipt compatibility.**

- Files: `third-party-tools-lock.json`, `ManagedToolLock.swift`, `DependencyManifestSections.swift` (hash scope and migration), `AppDelegate+DependencyReconciliation.swift` tests, `AppVersionTests.swift`, `project.pbxproj`, the HelpBook plist phase, `build-notarized-dmg.sh` (`MARKETING_VERSION` override), a new `scripts/release/bump-version.py`, and `CondaManagerTests`.
- Dependencies: none, but land it before WP5 so the simplification works on the reduced surface.

**WP5: Simplification (REL-09, REL-10, REL-15, REL-16, REL-17). Risk: medium to high. Do it in slices, each ending with a real preview release.**

- Slice A: delete the nightly coordinator, `containers/` and the stale catalog path (REL-15, REL-16).
- Slice B: build from a clean `git worktree` export and skip hydration in Release (REL-10).
- Slice C: add a GUI launch gate and set `appSmokeRequired: true` for Stable (REL-09 part 3).
- Slice D: single notarization and delta feeds (REL-17).
- Slice E: remove cache fingerprinting and fork configuration if unused, and demote boot-bound proof to a warning (REL-09 part 2).
- Dependencies: WP1, WP3 and WP4.

**WP6: Dependency pinning (REL-11, REL-12, REL-13). Risk: medium for REL-11, because explicit locks change install behavior. Low for the rest.**

- Files: `third-party-tools-lock.json` (digests, viralrecon SHA, EuPathDB rename with alias), a new `ManagedTools/locks/*.txt`, `CondaManager.swift` (explicit install path), the dependency receipt schema, and `pages.yml`.
- Dependencies: WP4, so the manifest hash semantics are settled first.

**WP7: Legacy identity cleanup (REL-08). Risk: low.**

- First run the empirical Sparkle test on a VM, then choose between retiring the bridge and shipping a migration build.
- Files: `release-contract.json`, `build-notarized-dmg.sh` bridge code, `release.py` floors and verification.
- Dependencies: WP3, since the yank tooling touches the same feed code.

### Accept (do not fix)

- **Commit-count build numbers.** They are monotonic on main and make a revert-based forward fix automatically "newer". The floor gate already catches history rewrites.
- **Distinct Preview bundle ID.** It is the right long-term design. Only the migration of old installs (REL-08) needs attention.
- **Two notarization-independent verifications.** `stapler validate` plus `spctl` on the DMG is cheap and worth keeping even after WP5.
- **The Containerization kernel and rootfs in the bundle.** They are used by the TaxTriage and Nextflow runtimes (`NextflowRunner.swift:402`, `TaxTriagePipeline.swift:214`), so removing them to save 100 MB is not warranted. Only the notice obligation (REL-03) needs fixing.
- **`unpinnedArchive` for truly rolling sources and `liveSnapshot` for NCBI taxdump.** They are honest labels. Only the dated archives should gain digests.

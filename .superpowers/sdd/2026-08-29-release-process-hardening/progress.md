# SDD ledger — plan: docs/superpowers/plans/2026-08-29-release-process-hardening.md

## Pre-flight consistency scan

| Scope | Producer / consumer relationship | Finding / ruling |
|---|---|---|
| Task 1 internal | JSON contract → strict loader → builder channel query tests | Consistent; behavioral output is the contract boundary. |
| Task 2 internal | Contract/toolchain policy → Doctor; pinned Package.resolved → Sparkle resolver | Consistent; package mode excludes credentials, credentials mode extends it. |
| Task 3 internal | Deterministic scratch token → scanner allowlist; unsigned payload → receipt | Consistent; allowlist is exact and receipt binds transformed binaries. |
| Task 4 internal | Doctor → output preparation → package → receipt → sign/resume | Consistent; destructive preparation is after Doctor and receipt precedes signing. |
| Task 5 internal | Package receipt → tag push → exact-SHA CI → sign/publish | Consistent; CI cannot publish and coordinator owns ordering. |
| Task 6 internal | Contract semantics → validator/docs; process evidence → smallest test stabilization | Consistent; no production timeout behavior changes without reproduction. |
| Task 7 internal | Full tests + real unsigned dual-channel package + Sol review | Consistent; signing/publication are explicitly excluded. |
| Tasks 1 & 2 | Task 1 contract is consumed by Doctor and resolver in Task 2 | Interface names and exact toolchain bounds agree. |
| Tasks 1 & 4 | Builder query introduced in Task 1 is expanded into phase behavior in Task 4 | Shared builder edit is sequential; Task 4 preserves contract-derived values. |
| Tasks 1 & 6 | Contract semantic values are consumed by validator/docs in Task 6 | Coexistence and shared bundle identifier agree with Global Constraints. |
| Tasks 2 & 4 | Doctor and Sparkle resolver are invoked by phased builder | Task 4 must not duplicate preflight logic; consume CLI reports. |
| Tasks 2 & 5 | Coordinator invokes Doctor and supplies local credential profile | Tracked coordinator/wrapper must not reintroduce machine constants. |
| Tasks 3 & 4 | Scanner and receipt CLIs are consumed by package/resume phases | Exact scratch path and candidate app path are shared; schemas are fixed in Task 3. |
| Tasks 3 & 7 | Receipt/scanner evidence is rechecked in whole-branch package verification | Consistent; final verification uses real produced candidates. |
| Tasks 4 & 5 | Builder phases are orchestrated by the common coordinator and CI | Coordinator must call interfaces, not copy assembly/signing logic. |
| Tasks 4 & 6 | Builder usage/docs and compatibility flag migration are reconciled | Docs must name receipt resume, not raw path reuse. |
| Tasks 4 & 7 | Package-only dual-channel candidate is the real final build gate | Consistent; no credentials or remote side effects. |
| Tasks 5 & 6 | Coordinator/CI ordering is encoded in semantic authority validation | Consistent; exact-SHA CI precedes publication everywhere. |
| Tasks 5 & 7 | CI/coordinator tests and real package run prove final ordering and packaging | Consistent; network publication is stubbed/forbidden during verification. |
| Tasks 6 & 7 | Stabilized process test and semantic validator are rerun in final gate | Consistent; no task depends on an unverified process-test change. |

Ruling: Preserve `com.lungfish.browser` for both channels while enforcing distinct app filenames, names, feeds, and updater hosts — changing the identifier would strand existing Preview Sparkle users — cost if wrong: Launch Services/defaults/TCC may remain shared even though both app paths coexist.

Ruling: Support Xcode 26.4.1 through the end of major version 26 and Swift 6.2 through the end of major version 6 instead of an exact patch pin — both CI 26.4.1 and the release Mac 26.6/Swift 6.3.3 must be valid — cost if wrong: a future compatible-looking patch may require an explicit deny/pin after regression evidence.

Ruling: Set the release-build free-space floor to 20 GiB — recent archive, SwiftPM, DMG, and dual-channel package work need substantial transient storage — cost if wrong: smaller release Macs will be rejected until the threshold is deliberately lowered with evidence.

Ruling: Permit package-only to apply only literal-identity `-`, timestamp-free ad-hoc seals to Mach-O payloads after path sanitization and before exact-payload executable smoke — arm64 macOS kills a transformed executable with either an invalid or removed signature, while these identity-free seals use no private credential and are replaced by Developer ID only after receipt verification — cost if wrong: CI candidates may be mistaken for distribution-signed artifacts, so documentation, tests, and metadata must continue to distinguish ad-hoc sealing from Developer ID signing.

Ruling: Validate the exact scratch, release, archive, and DerivedData targets through one shared read-only boundary before Doctor may create a probe or the builder may clean/build — recognized ignored repository defaults remain supported while aliases, symlinks, overlaps, repository escapes, and unrelated external outputs fail closed — cost if wrong: older unmarked custom output directories require an explicit safe migration instead of silent reuse.

Ruling: Preserve the receipt-bound unsigned candidate and apply Developer ID signatures only to a private disposable copy after receipt verification — a separately named signed output is retained only after successful app notarization — cost if wrong: release staging uses one additional app-sized copy, but any signing/notarization/DMG failure remains resumable without repackaging.

Task 1: fix round 1/5 (3 addressed, 0 open; commits 77f2254..1852f56)
Task 1: minor (deferred): implementer report overstates the ordering of Stable bridge rejection relative to the current credential guard; Task 4 will move credentials into the later phase.
Task 1: complete (commits 189aec5..1852f56, review clean)
Task 2: fix round 1/5 (4 Important and 1 Minor addressed; commits 5b87883..3a7d603)
Task 2: fix round 2/5 (1 Critical cache-provenance finding addressed; commit dcd1429)
Task 2: fix round 3/5 (1 Important ancestor-rename finding addressed; commit 177e397)
Task 2: complete (commits 5b87883..177e397, 48 focused and 75 broader tests green, independent Sol review clean)
Task 3: fix round 1/5 (5 Important and 1 Minor scanner/receipt findings addressed; commit f088d637)
Task 3: fix round 2/5 (2 Important filesystem-alias/dynamic-fallback findings addressed; commit 818ab6c)
Task 3: fix round 3/5 (1 Important exact-string-boundary finding addressed; commit 3cda13c)
Task 3: complete (commits eef1499..3cda13c, 34 focused and 114 broader tests green, independent Sol review clean)
Ruling: Permit identity-free ad-hoc seals on transformed Mach-O files during package-only assembly so macOS can execute the exact payload before receipt creation — this does not access a Developer ID or Keychain and the receipt binds the sealed bytes — cost if wrong: the candidate is distribution-unsigned but not literally signature-free, and Developer ID signing replaces those local seals later.
Task 4: fix round 1/5 (1 Critical and 3 Important target/retry/tool-path findings addressed; commit 95d7a91)
Task 4: fix round 2/5 (1 Critical archive-ownership and 1 Important late-DMG retry finding addressed; commit 5d1e2ad)
Task 4: fix round 3/5 (1 Critical relocated-receipt cleanup finding addressed; commit a28a366)
Task 4: complete (commits 7417540..a28a366, 69 focused and 174 broader tests green, real dual-channel package evidence at 7417540, independent Sol review clean; final current-HEAD real rerun deferred to Task 7)
Task 4: fix round 1/5 (4 independent-review findings addressed; 62 focused and 166 broader release Python tests green; real dual-channel package rerun deferred to Task 7 by ruling)
Task 4: fix round 2/5 (1 Critical archive-ownership and 1 Important late-retry finding addressed; 66 focused and 171 broader release Python tests green; real dual-channel package rerun remains deferred to Task 7)
Task 4: fix round 3/5 (1 Critical relocated-receipt deletion finding addressed; 69 focused and 174 broader release Python tests green; real dual-channel package rerun remains deferred to Task 7)
Task 5: fix round 1/5 (2 Critical, 4 Important, and 2 Minor independent-review findings addressed; immutable recovery and exact remote verification added; final verification recorded in task-5-report.md)
Task 5: fix round 2/5 (4 Important and 1 Minor independent-review findings addressed; complete-vs-partial transaction classification, canonical signed ancestors/hashes, selected-remote GitHub binding, and detach-safe recovery added; 117 focused and 202 broader release tests green; final evidence appended to task-5-report.md)
Task 5: fix round 3/5 (1 Critical and 3 Important independent-review findings addressed; github.com host binding, effective fetch/push identity, receipt-bound mutable completion evidence, and selected-repository Sparkle URLs added; 30 final focused and 193 broader release tests green; final evidence appended to task-5-report.md)
Task 5: fix round 4/5 (3 Important independent-review findings addressed; exact canonical receipt verification before tagged-state classification, contract-exact appcast evidence, and lowercase ASCII GitHub identity across package recovery added; final evidence appended to task-5-report.md)

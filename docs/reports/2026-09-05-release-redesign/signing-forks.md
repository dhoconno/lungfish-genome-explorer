# Signing, unattended operation, and fork identity audit

Read-only audit on 2026-09-05. No credential store read, credential probe, UI, build, signing, or publishing was performed. Only this ignored findings document was written.

## Current evidence and defects

- `scripts/release/release.py:49` hardcodes the upstream Sparkle public key. `_base_request` always uses it. A new fork cannot choose its own key through the supported frontend.
- `release.py:103` securely opens strict v1 machine JSON (ownership, mode, symlink, ancestor checks, bounded size, file-descriptor race checks). Preserve these protections. Its five fields are schemaVersion, repository, signingIdentity, teamId, notaryProfile. There is no selected signing keychain or Sparkle Keychain account.
- `release.py:601` verifies current candidate before credentials and checks profile repository matches origin. Preserve. Repository identity helpers already bind fetch/push URLs and GitHub destination; avoid regressing this into untrusted ambient GH_REPO selection.
- `release-doctor.py:45,90` bounds each probe at 30 seconds, but subprocess.run timeout is not a robust process-group cancellation strategy. This bounds duration, not whether a Keychain authorization dialog appears.
- `release-doctor.py:736` labels a successful `security find-identity` listing as a usable signing identity. It never exercises the private key. An identity can enumerate successfully while actual codesign blocks on authorization.
- `release-doctor.py:795` accepts an explicit private key file internally; otherwise it uses Sparkle's default Keychain account. `_sparkle_key` accepts any nonempty public output. `_sparkle_probe` signs and verifies using the same selected private-key source, without comparing it to the expected embedded public key. A wrong key can pass. This is a blocking correctness defect for a configurable fork.
- `build-notarized-dmg.sh:1583–1707` invokes codesign and notarytool directly. App and DMG notarization use `submit --wait` without timeout or a separately durable submission-ID state transition. A credential prompt or service delay can strand a release; an interrupted wait can cause duplicate submission on recovery.
- `build-notarized-dmg.sh:593` already derives feed host/repository from resolved Git origin. Channel feeds, names, and bundle IDs live in `config/release-contract.json`. That is the natural public identity authority.
- `Lungfish.xcodeproj/project.pbxproj:419,450,516,538` retains bundle defaults and UI-test IDs. `Sources/LungfishApp/App/AppDelegate+MenuActions.swift:878` hardcodes upstream release-history URL. `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist` hardcodes help identity. Many com.lungfish strings are log, error, notification, or format identifiers; do not indiscriminately replace scientific format identifiers or persisted-data keys.
- `lungfish-cli.entitlements` requests virtualization only. The builder uses this file for the CLI and app. Do not add broad JIT/library-validation/debugging exceptions to solve signing problems.

## Recommended product boundary

Keep public, reviewable product identity in committed `config/release-contract.json`; keep machine selectors in private per-repository profiles. A machine profile must not silently mutate an existing product's bundle ID, feed, or public key at publish time. These values must be in the unsigned candidate receipt before signing.

Proposed public identity additions:

```
identity.repository = OWNER/REPO
identity.productSlug = fork-product
identity.sparklePublicEdKey = validated base64 32-byte public key
identity.releaseHistoryURL = derived canonical repository releases URL
channels.* = existing per-channel bundle names, IDs and feed asset names
channels.*.migrationFeeds = explicit list (empty on a new fork)
```

Retain existing upstream identity and migration feeds verbatim in this repository. A fork initializer should emit a reviewable public configuration change with a unique reverse-DNS base plus preview/debug variants, distinct visible app names, its own repository and Sparkle key. Never import upstream migration feeds by default. Feeds must be HTTPS and bound to declared repository or explicitly validated custom hosting. Candidate receipt/cache identity must bind the full public identity digest. Cross-repository or changed-public-key candidate reuse must fail.

Recommended private v2 schema (illustrative; exact interface should match root design):

```json
{
  "schemaVersion": 2,
  "repository": "OWNER/REPO",
  "signing": {
    "identity": "Developer ID Application: Example (ABCDEFGHIJ)",
    "certificateSha1": "40_HEX_SELECTOR",
    "teamId": "ABCDEFGHIJ",
    "keychainPath": "/Users/release/Library/Keychains/release.keychain-db"
  },
  "notary": {"profile": "product-notary", "keychainPath": "/Users/release/Library/Keychains/login.keychain-db"},
  "sparkle": {"account": "OWNER.REPO.ed25519"},
  "github": {"host": "github.com", "authMode": "gh"}
}
```

These values are selectors, not secret payloads. Certificate SHA-1 is codesign's identity selector, not a proposed artifact-integrity algorithm; artifacts remain SHA-256. Validate selected certificate's Developer ID type/team and actual signature team. Sparkle stock tools support an account selector; do not invent a keychain-path flag they lack. Do not silently change global keychain search order.

Default lookup should namespace repository identity, e.g. `~/.config/lungfish/releases/<repository-key>.json`, while accepting `--profile`. v1 remains readable: map its fields, preserve login/default Sparkle selection as legacy, and mark unattended signing proof incomplete until actual probes succeed. Migration produces owner-only v2 via atomic creation; no credential reads, exports, deletion, or regeneration. The current `release.json` must never be silently overwritten.

## Provisioning and frontend

A supported `setup`/`configure` frontend can write selector profiles, identify installed tools, validate public identity and explain missing provisioning. It must distinguish configuration from credential provisioning. No arbitrary script hooks in profiles.

One-time operator provisioning includes Apple enrollment/agreements, Xcode license/components, Developer ID certificate/private-key import, trusted tool access to that key, notary credential storage, GitHub login, and Sparkle key import/generation under the chosen account. Prefer a dedicated release user and, where operationally practical, a dedicated signing keychain; retain a login-Keychain-compatible path for Sparkle. An unattended machine still needs an approved way to make its keychain usable after reboot. A locked keychain is not repairable by pretending stdin is noninteractive.

Allow the operator to approve narrow, tool-specific Keychain access during an explicit setup session. Document `codesign`, the exact Xcode notarytool, and the pinned Sparkle tools used. Never set allow-all-application ACLs, disable Gatekeeper/SIP, strip quarantine to fix execution, automate password dialogs, or run broad partition-list rewrites against a personal login keychain. If a dedicated-keychain partition ACL is required, treat it as explicit credential provisioning with its blast radius explained; do not place unlock/import passwords in argv, environment dumps, logs, or agent conversation. Avoid an automated `security ... -p PASSWORD` bootstrap because it exposes argv. An interactive trusted provisioning workflow or reviewed Security-framework helper can receive secrets directly without making them CLI arguments.

Multiple machines for the SAME product must retain the same Sparkle trust key (secure operator transfer or managed secret service) and compatible Apple signing identity. Independent forks should have independent keys. Do not generate a fresh Sparkle key on each machine. Secure transfer is an explicit provisioning operation; package/publish must never export keys.

## Probes and runtime supervision

Doctor has distinct package-ready, credentials-configured, credentials-usable-now, and unattended-ready results. Enumeration alone is configured, never usable. Record observation time and host/tool selectors, not durable permission guarantees.

1. Validate tool identities, private profile, selected repo/public identity, and exact tool capability flags without reading secrets.
2. A disposable copy of a minimal Mach-O is signed with selected certificate/keychain under the same executable path/session as production signing, then strict-verified with team/certificate extraction. This tests private-key use; do not sign a user app as a probe. Use timeout 30 seconds, stdin DEVNULL, isolated process group, TERM then KILL descendants, and sanitized result codes.
3. Run bounded notarytool history using selected profile/keychain. It proves current authentication, not that Apple's future submission will finish.
4. Obtain selected Sparkle public key using pinned tool/account and compare to contract key; sign disposable bytes and verify with an independent public-key-only verifier against that exact contract key. Never equate same-private-key roundtrip with trust continuity.
5. GH_PROMPT_DISABLED=1, GIT_TERMINAL_PROMPT=0, batch-mode SSH for configured SSH transport; bounded gh auth/repository permission read. Read permission metadata is useful but does not conclusively prove branch protections, token scope, or a future write. Preserve remote push endpoint binding.

Closing stdin or a timeout does NOT suppress OS Keychain UI. `SecKeychainSetUserInteractionAllowed(false)` affects the calling process; setting it in Python does not establish no-dialog behavior in an exec'ed Apple/Sparkle process. Strict no-dialog mode requires either an independently provisioned account/session whose trusted-tool probes already succeed or a reviewed in-process Security API helper that fails with interaction-not-allowed (and does not export private keys). Do not promise a generic cross-process switch. If no such implementation exists in scope, honestly label native CLI probes as bounded but potentially interactive and provide a setup-only mode for them; unattended mode must fail early when setup proof is absent. Proof can go stale after reboot/lock/tool update, so every actual command remains bounded.

All credentialed production calls need phase budgets and process-tree cleanup, plus durable phase status. Notary submit should persist returned ID before polling `info` with bounded exponential backoff. `Accepted`, `Invalid`, `In Progress`, transport failure, and deadline expiry are distinct. A timeout retains submission ID and artifact SHA-256; retry polls the same submission. If upload response is lost before ID, record ambiguous submission and reconcile conservatively instead of asserting no upload occurred. Apple service delay is a recoverable waiting state, not proof of invalid credentials. Preserve downloaded diagnostic log and final staple/verification evidence.

Log only allowlisted selectors and redacted command forms. Secrets never belong to release provenance; record credential reference type and safe identity fingerprint. Do not replay raw stderr from a secret-consuming tool without sanitization. Test timeout descendants, wrong Sparkle key, mismatched team/certificate, locked keychain simulation, missing profile, changing tool path, bad repository, and v1 migration entirely with fake runners before requesting any real credential exercise.

## Primary sources checked

- Apple [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow): Keychain profile references, submission IDs, status and logs. Supports durable submission recovery.
- Apple [Customizing the Xcode archive process](https://developer.apple.com/documentation/security/customizing-the-xcode-archive-process): published example uses an explicit notary timeout and acknowledges Keychain access approval.
- Apple [TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool): DEVELOPER_DIR can select notarytool without changing global Xcode selection.
- Apple [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution): Developer ID, hardened runtime, signatures and notarization requirements.
- Sparkle [documentation](https://sparkle-project.org/documentation/): EdDSA keys stored in Keychain, secure machine transfer, HTTPS, Developer ID, per-app public key. Key rotation changes Apple identity or EdDSA trust one at a time; do not silently rotate both. New signed-feed features require compatible pinned Sparkle versions and are outside a blind rollout.
- Sparkle upstream [sign_update source](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/sign_update/main.swift): account selector defaults to ed25519; verification loads public key alongside selected private key; Keychain error branches include interaction-not-allowed. Feature availability must be checked against the repository's pinned version rather than assuming latest source applies.

Implementation judgment above separates secure provisioning from runtime guarantees; no claim that macOS authorization can be bypassed was made.

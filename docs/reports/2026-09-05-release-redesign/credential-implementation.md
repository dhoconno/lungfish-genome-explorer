# Credential configuration and bounded execution implementation

Task3 uses only fake credential tools and temporary placeholder files for validation. No real credentials were read, enumerated, signed with, unlocked, imported, exported, or published during implementation. The public-key-only Swift verifier is supplied for coordinator validation; this task did not compile Swift.

## Private profile interface

`release_profiles.ReleaseProfile` retains repository/signing_identity/team_id/notary_profile positional fields. Optional selectors are signing_keychain, certificate_sha1, notary_keychain, sparkle_account (`ed25519` legacy default), and schema_version. `load_release_profile(path, expected_repository=...)` reads private v1 or v2; `write_release_profile(path, profile)` atomically creates without overwriting. `profile_payload(profile)` supplies the JSON shape.

V2 has exactly schemaVersion, repository, signing {identity, teamId, keychainPath, certificateSha1}, notary {profile, keychainPath}, sparkle {account}. Optional keychain/certificate values are null. Public profiles contain no secret payload or private key file. Parent directories are mode0700; files are regular owned single-link mode0600, with symlink/unsafe-ancestor/duplicate-key/size/race validation. Existing v1 is never rewritten while loading. Root translates ProfileError to its public ReleaseError.

## Doctor interface

New internal flags: --signing-keychain, --certificate-sha1, --notary-keychain, --sparkle-account, --sparkle-public-ed-key, --credential-probe-mode setup|unattended (default unattended), --setup-receipt.

Explicit setup binds a private receipt to selected repository/key/team/account, tool paths and content hashes, user/host, Xcode directory, boot identity and expected public key. Beginning setup invalidates previous readiness; any failed refresh leaves incomplete evidence. Successful probes write completion. Unattended checks require a matching completed receipt from the same bound boot (no arbitrary time expiry), then skip repeated disposable credential probes. Changing tool/selector/boot identity or missing/incomplete evidence fails before credential access.

Setup uses a disposable copy of /usr/bin/true, selected certificate/keychain codesign, strict verification and TeamIdentifier comparison. Identity enumeration alone is never labeled usable. Sparkle generate_keys --account ACCOUNT -p must return exactly the independently supplied candidate public key. sign_update signs disposable bytes; `verify-sparkle-signature.swift` uses CryptoKit and only the expected public key, signature, and disposable payload. It never loads a private key. Legacy internal --sparkle-ed-key-file retains strict owned regular mode0600 validation and independent expected-key signature verification; it is excluded from unattended profile operation.

Setup evidence is a bound observation, not a no-dialog guarantee. Keychains may relock, ACLs may change, and Apple/Sparkle CLI tools can still request OS authorization. Closing stdin and process timeouts do not disable that UI. Do not claim unattended publication is guaranteed after arbitrary OS changes, or automate passwords to recover.

## Process and notarization interfaces

`bounded_process.run_bounded(argv, timeout=..., env=..., cwd=...)` closes stdin, creates a new process group and terminates TERM-ignoring descendants with KILL on timeout. `safe_record` emits only phase/executable basename/status/timeout/wall time, never raw argv/stdout/stderr. The CLI accepts --timeout SECONDS --phase NAME -- COMMAND; it prints only the safe record. Tool output is available in memory to Python consumers for structured parsing.

`durable_notary.notarize(artifact, state_path, profile, run=..., timeout=180, poll_budget=600, poll_interval=5, env=...)` requires a private mode0700 state parent, acquires a nonblocking owned state lock, binds artifact path/SHA256/size plus notary repository/profile/keychain context, and records Submitting before upload. Any returned valid submission UUID is persisted before polling, even if the submit process also reports failure. A missing/lost UUID becomes AmbiguousUpload and is never automatically resubmitted. Pending status retains the UUID and resume polls that exact submission. Accepted and Invalid are terminal. Changed artifact/context is rejected. Safe command metadata, not raw diagnostics, is retained.

CLI: `durable_notary.py --artifact PATH --state PATH --repository OWNER/REPO --notary-profile NAME [--notary-keychain PATH] [--command-timeout180 --poll-budget600]`. Exit0=Accepted,2=Invalid,75=pending,76=ambiguous/blocked. Root preserves state across publication recovery and uses separate app/DMG state files. Submitting left by process interruption deliberately requires external reconciliation; do not remove it and retry upload blindly.

## Verified evidence

20 credential behavioral tests and 6 signing-stage recovery tests pass, including real disposable fake-child process timeout/descendant cleanup, safe logging, profile atomic no-overwrite and repository boundaries, duplicate keys, unsafe path modes/symlinks, setup invalidation, same-boot lifetime and optional explicit expiry, wrong Sparkle public key, public-only verifier routing, notarization durable ID/resume, nonzero-with-ID response, pending/Invalid outcomes and ambiguous upload preservation. Existing Doctor/repository tests ran61cases:59passed initially and2legacy keyfile compatibility failures were corrected; both corrected tests passed with the14new tests afterward. A subsequent64case aggregate run passed after cache identity reconstruction and explicit setup dirty-tree support; later review regressions are included in the targeted credential suite.

Pinned Sparkle2.9.6 command capabilities were checked against official source: https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.6/generate_keys/main.swift and https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.6/sign_update/main.swift. Lookup -p does not create a missing key, and --account is supported. sign_update --verify uses the private-key source's public key, so it is insufficient by itself for independently established candidate trust.

## Persistent signing stages

The builder now calls signing_pipeline.py with candidate receipt, canonical unsigned/signed app and DMG paths, private transaction directory, selected profile fields, entitlements and source smoke helper. A private transaction journal binds candidate receipt digest, unsigned payload, selector profile, expected public key and entitlements/smoke recipe hashes. Completed stages retain and revalidate signed app input, app ZIP, stapled output app, signed input DMG and final stapled output DMG. Pending or ambiguous notarization preserves original upload bytes and submission state. An interrupted local staple stage can restart from its immutable signed input without signing or ZIP/DMG reconstruction. A partial success cannot mark the whole pipeline complete. Both app and DMG notarization remain required.

The default helper phase budget is180seconds, with600seconds of bounded notary polling per invocation. The signed input DMG is never stapled in place; its final distribution copy receives the staple so notary recovery can continue checking the original submitted SHA256/inode. Builder retries no longer clear the signed app, ZIP, DMG or notary logs. Credentialed GH and Sparkle calls are process-supervised. Successful GH protocol stdout is explicitly forwarded for existing parsers; failures never forward raw diagnostics.

Builder fixture copies now include every new helper and globally replace absolute Apple credential tool paths with fake paths, rejecting leftovers and requiring fake executables before launch. No real credentialed builder tests are permitted through an unadapted fixture.

Signed app input is recorded only after strict signature verification and an exact TeamIdentifier match to the machine profile. Transaction context also binds the DMG volume name. Operator authorities document the seven-command coordinator, explicit setup, incremental Debug and opt-in graphical/tool diagnostics.

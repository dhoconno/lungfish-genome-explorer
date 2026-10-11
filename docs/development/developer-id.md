# Developer ID certificate

Lungfish Genome Explorer (LGE) releases are signed with a Developer ID Application certificate. Apple's original Developer ID Certification Authority, the G1 Sub-CA, expires on 2027-02-01 at 22:12:15 UTC, and every certificate it issued stops working then. Releases that are already notarized and carry a secure timestamp keep opening. New releases need a certificate from the Developer ID Certification Authority (G2), which Apple keeps valid to 2031. Apple's notice says each G2 certificate expires one year after it is issued, so it is renewed every year.

## What a release signs

Signing happens only on the release Mac, inside `release.py publish` (see [MACHINES.md](../contracts/MACHINES.md)). `scripts/release/signing_pipeline.py` signs `lungfish-cli`, every Mach-O tool bundled in the app, Sparkle's nested code and framework, the app itself and then the DMG. Every signature uses a secure timestamp (`--timestamp`), and every code signature also uses the hardened runtime (`--options runtime`). `notarytool` notarizes the app and then the DMG, and `stapler` staples both.

LGE ships no `.pkg` installer, so nothing needs to be re-signed before the cutoff. Debug builds are signed ad hoc. The release archive is built with Xcode signing turned off (`CODE_SIGNING_ALLOWED=NO`), so the Xcode project's signing settings never choose the certificate.

## How a release picks its certificate

The private release profile on each release Mac names the signing identity. It lives at `~/.config/lungfish/releases/<key>.json`, or at the older `~/.config/lungfish/release.json`, and `developer_id.py show` prints which one is in use. A v2 profile may also hold one certificate choice.

| Profile field | Meaning |
|---|---|
| `signing.certificateSha1` | Sign with this certificate, found by its SHA-1 fingerprint |
| `signing.certificatePolicy` set to `newest-g2` | Sign with the most recently issued valid G2 identity that has the profile's name |
| neither | The name must match exactly one valid identity |

`release.py doctor`, `release.py setup` and `release.py publish` turn the choice into one SHA-1 before anything else runs, and the doctor, the setup proof and the signing pipeline all use that SHA-1. An old and a G2 certificate of one team share one name, so once both are installed a profile without a choice stops with an error that lists both SHA-1s with their issuers and expiry dates.

The doctor and the setup proof print the selected certificate's issuer and expiry.

| Result | When |
|---|---|
| `PASS signing certificate` | A G2 certificate with more than 60 days left |
| `WARN signing certificate` | 60 days or fewer left, or a certificate from the original Sub-CA before its cutoff |
| `FAIL signing certificate` | The certificate has expired, or it comes from the original Sub-CA and the cutoff has passed |

## Commands

| Command | What it does |
|---|---|
| `python3 scripts/release/developer_id.py show` | Lists every Developer ID Application identity in the keychain with its SHA-1, issuer, expiry and trust, then the one the profile selects and its expiry check. It only reads the keychain. |
| `python3 scripts/release/developer_id.py verify [--certificate-sha1 SHA1]` | Signs a throwaway app in a new temporary folder with the selected identity, or with the given one, exactly as a release signs code. It then checks the signature, the certificate chain, the Team ID, the secure timestamp, the hardened runtime, the requirement Sparkle checks and the Gatekeeper origin, and deletes the folder. It never touches a release artifact. |
| `python3 scripts/release/release.py doctor` | Package readiness, then the identity and certificate checks and the rest of publish readiness |

## Moving to a G2 certificate

The Account Holder runs these steps at the Mac Studio, which is the release Mac, and then on the laptop.

### Create and prove the certificate

1. Create the certificate. In Xcode open Settings, then Accounts, select the team and click Manage Certificates. Click the add button and pick Developer ID Application, and pick G2 Sub-CA if Xcode asks for a Sub-CA. The other way is the website. On developer.apple.com open Certificates, click the add button, pick Developer ID Application and then G2 Sub-CA, and upload a certificate signing request made with Keychain Access (Certificate Assistant, then Request a Certificate From a Certificate Authority). Download the certificate and open it so it lands in the login keychain.
2. Check the chain. Run `developer_id.py show`. The new identity shows the issuer `Developer ID Certification Authority (G2)`. If it shows `not trusted`, for example `CSSMERR_TP_NOT_TRUSTED`, download the Developer ID G2 intermediate from https://www.apple.com/certificateauthority/, open it to add it to the login keychain and run `show` again. The intermediate has the subject `CN=Developer ID Certification Authority, OU=G2, O=Apple Inc., C=US` and the SHA-1 fingerprint `5B45F61068B29FCC8FFFF1A7E99B78DA9E9C4635`, and it is valid to 2031-09-17, so check a download against those. Xcode ships the same file as `DeveloperIDCA-G2.cer` in `/Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/Resources/`, so you can open that copy instead of downloading one. Until the new SHA-1 is selected, `show` ends with a `FAIL` line that names both identities, and that is expected. To keep releasing with the old certificate in the meantime, first select it with `release.py configure-machine --replace ... --certificate-sha1 <old SHA-1>`, using the SHA-1 that `show` lists for the original Sub-CA.
3. Prove that it signs. Run `developer_id.py verify --certificate-sha1 <new SHA-1>` and check that every line reads PASS. The first run may ask to let `codesign` use the new private key. Click Always Allow, so later unattended runs need no dialog.

### Switch releases to it

1. Select it. Run `python3 scripts/release/release.py configure-machine --replace --signing-identity "<identity name>" --team-id <Team ID> --notary-profile <notary profile> --certificate-sha1 <new SHA-1>` with the identity name, Team ID and notary profile that the current profile holds. Add `--signing-keychain` or `--notary-keychain` when the current profile names a keychain. To let each yearly renewal take over without a profile change, pass `--certificate-policy newest-g2` instead of `--certificate-sha1`.
2. Check readiness. `release.py doctor` prints `PASS signing certificate` with the G2 issuer. Then run `release.py setup`, because the setup proof binds the selected SHA-1 and the old proof no longer counts.
3. Release as usual with `release.py package` and `release.py publish`. Sparkle accepts an update when its signature satisfies the designated requirement of the installed build. That requirement names the team and Apple's Developer ID markers rather than a Sub-CA, and the `requirement` line of `verify` checks the new signature against it.

### Finish on both Macs

1. Copy the identity to the laptop, the standby release Mac. In Keychain Access on the Mac Studio, export the new certificate together with its private key as a `.p12` file with a strong password. Move it over a private channel such as AirDrop, never email or git. Import it on the laptop, delete the `.p12` file on both Macs, check the chain and prove the certificate as above, then select it and run `doctor` and `setup` there too.
2. Remove the old identity after the first G2-signed release has shipped and updated an installed copy through Sparkle. Delete the old certificate and its private key in Keychain Access on both Macs, or let it expire. Keep the certificate choice in the profile.

## Every year

A G2 certificate expires one year after it is issued, and the doctor warns 60 days before that. Create the next one and prove it with `verify --certificate-sha1` as above, select it with `configure-machine --replace` (a `newest-g2` profile picks it up by itself), then run `doctor` and `setup`, copy it to the laptop and remove the old identity once a release signed with the new one has shipped. Releases signed while the old certificate was valid keep working, because their secure timestamp proves when they were signed.

## Where the rules live in code

| Rule | Code |
|---|---|
| Reading the keychain, selecting an identity, the expiry check and `verify` | `scripts/release/developer_id.py` |
| The profile fields and `configure-machine --replace` | `scripts/release/release_profiles.py` and `run_configure_machine` in `scripts/release/release.py` |
| One SHA-1 before the doctor, the setup proof and the builder | `select_signing_certificate` in `scripts/release/release.py` |
| The doctor checks named `signing identity` and `signing certificate` | `scripts/release/release-doctor.py` |
| Tests with fake `security`, `codesign` and `spctl` output | `scripts/tests/test_developer_id.py`, `test_release_preflight.py`, `test_release_credentials.py`, `test_release_configuration.py` and `test_release_signing_pipeline.py` |

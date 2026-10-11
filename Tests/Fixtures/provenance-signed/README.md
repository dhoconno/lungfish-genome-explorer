# Signed provenance fixtures

This folder holds provenance records that Lungfish Genome Explorer (LGE) signed before the Phase 2.6 reader changes. Each one must keep verifying after any later change to a reader, a decoder or the signing code. `ProvenanceSignedFixtureTests` in `Tests/LungfishWorkflowTests/Provenance` copies them to a temporary folder and verifies them there.

## Why they exist

Signing covers canonical bytes only for a file that decodes as `ProvenanceEnvelope`. Any other file is signed as its own bytes (`ProvenanceSigningPayload.data` in `Sources/LungfishWorkflow/Provenance/ProvenanceSigning.swift`). A decoder that accepts fewer files, or more, changes what a released signature covers, and that signature then fails to verify. These records catch that.

## Files

The folder holds two signed records, each with its signature and public key beside it.

| Record | What it is |
|---|---|
| `Signed.lungfish/Reference Sequences/Signed-Fixture.lungfishref/.lungfish-provenance.json` | One envelope record for a reference import |
| `Signed.lungfish/Reference Sequences/Signed-Fixture.lungfishref/provenance/bundle.lungfish-provenance.json` | The bundle roll-up the writer made for the same record |

The signature of each record is the file of the same name with `.signature.json` added, and its public key adds `.pub`.

## How they were made

They were written once at commit `b44a9795b` by `testCaptureSignedFixture` with `LUNGFISH_CAPTURE_SIGNED_PROVENANCE_FIXTURE=1`. The signing code at that commit is the code of `ddfe9b778`, the main commit Phase 2.6 started from. No file named `ProvenanceSigning*` changed between the two, so these records are signed exactly as `ddfe9b778` signs.

The capture builds the envelope from fixed values, writes it with `ProvenanceWriter` and the local signer inside a temporary `.lungfish` project and copies the six files here. The signing key is `unit-test-private-key`, the key of the first case of `ProvenanceSigningTests`. The project-relative `@/` paths, the fixed dates and the fixed runtime identity mean that no file names a home folder, a temporary folder or an account.

## Rules

- A file here is never edited or replaced. An edited record no longer matches its signature.
- The capture refuses to overwrite a file, and the gate never sets its variable.
- A change that makes these records fail to verify breaks every signature users already hold. Fix the change, not the fixture.

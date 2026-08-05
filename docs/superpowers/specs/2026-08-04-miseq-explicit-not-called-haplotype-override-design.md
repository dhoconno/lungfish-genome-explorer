# miSeq Explicit Not-Called Haplotype Override Design

## Problem

The haplotyped miSeq editor currently interprets an empty draft as a request to
restore the workflow-generated haplotype call. Consequently, an analyst cannot
clear only H1 or H2 and preserve that slot as intentionally not called. When the
workflow supplied the same label for both slots, this is especially misleading:
clearing one field appears to leave or reapply the workflow value rather than
recording an independent blank.

## Required behavior

- Clearing H1 or H2 saves an explicit not-called override for that slot only.
- The cleared editor field remains empty. Compact haplotype presentations show
  the existing empty marker (`—`).
- Clearing one slot never changes the other slot.
- Restoring the workflow-generated call is a separate operation.
- Both clearing and restoring are durable, audited sidecar mutations and mark
  `current.xlsx` as needing an update.
- The effective call projection, both miSeq viewport presentations, and workbook
  publication consume the same resulting state.
- Full-length genotype-only manual assignments retain their current behavior.

## Representation

Use the canonical string `-` as the stored not-called override value. This keeps
the existing `CallOverride` record, replay payload, and provenance format intact
while avoiding the ambiguity of an empty serialized string. The value is an
internal persistence representation, not a user-entered haplotype label.

The effective-call authority will recognize `-` as an analyst not-called value:

- effective display value: empty;
- slot status: `noHaplotype`;
- source: analyst override;
- authoritative override: retained for audit and restoration.

The editor adapts the effective empty value to an empty text field. Other views
continue using their established empty rendering (`—`, blank cell, or equivalent
presentation appropriate to that view).

## Editor interaction

The existing clear control means **Mark Not Called** for a haplotyped miSeq
effective-call field. Its accessibility label and tooltip must state that
meaning rather than implying that the override will be removed.

An overridden slot exposes a compact reset control labelled **Restore Workflow
Call**. Activating it stages the original pipeline value for that slot. Saving
then removes the authoritative override through the existing baseline-restoration
path. The reset control is not shown for an unmodified pipeline slot.

The editor continues to save all changed fields in one transaction, but each
mutation retains its own `(sample, locus, slot)` address. No locus-wide or
paired-slot expansion is permitted.

## Persistence and audit

Saving an explicit blank writes a `CallOverride` whose `overrideCall` is `-`,
with the existing analysis identity, author, timestamp, operation ID, replay
payload, and publication provenance. The audit entry records an override from
the prior effective call to `-` with a plain-language not-called rationale.

Restoring the workflow call sets the mutation target to its baseline. The
existing mutation service removes the override and records `clearOverride` with
the workflow value as the resulting call. Failed publication leaves the draft
visible and does not partially refresh either viewport.

## Compatibility

- Existing nonempty overrides remain unchanged.
- Existing sidecars and replay payloads require no migration.
- A literal `-` already represents an empty haplotype in viewport presentation;
  the effective authority will now classify it explicitly as not called instead
  of called.
- Empty or malformed persisted override strings remain invalid and ignored or
  rejected according to current validation rules.

## Verification

Automated tests must demonstrate:

1. Clearing only H1 stages and saves `-` for H1 while H2 remains unchanged.
2. The effective projection exposes H1 as empty/not-called and retains H2.
3. The matrix band and haplotype calls view receive the same per-slot result.
4. Reloading the annotation sidecar preserves the explicit blank.
5. Restoring H1 removes only its override and returns its workflow call.
6. Both changes create audit/replay provenance and mark the workbook dirty once
   per Save.
7. Publication failure retains the unsaved blank draft and does not partially
   update synchronized views.
8. Existing nonempty overrides and full-length manual assignments do not regress.


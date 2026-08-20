# Channel-Aware App Identity and First Stable Release Design

**Date:** 2026-08-20
**Scope:** Distinct Preview and Stable presentation, followed by Lungfish's first
stable CalVer release

## Goal

Make the installed release channel unmistakable without creating two products:
lab and early-adopter Preview installations visibly identify themselves and
continue receiving rapid Preview updates, while public Stable installations use
the normal Lungfish name and receive only Stable updates. Publish the current
verified Preview baseline as a freshly built first Stable release.

## Decisions

### One product, two distribution channels

Both channels retain the executable name `Lungfish`, app wrapper
`Lungfish.app`, bundle identifier `com.lungfish.browser`, preferences, document
associations, and suffix-free CalVer sequence. Installing the other channel's
DMG replaces the existing application and switches the baked Sparkle feed.
Preview and Stable are not designed to run side by side.

There is no in-app channel toggle. A user deliberately opts into Preview by
installing a Preview DMG and returns to Stable by installing a Stable DMG. This
keeps outside users on Stable unless they intentionally download Preview.

### Channel-specific visible names

The release builder stamps the following values into the archived app before
Developer ID signing and notarization:

| Channel | `CFBundleDisplayName` | `CFBundleName` | `LungfishReleaseChannel` |
| --- | --- | --- | --- |
| Preview | `Lungfish Genome Explorer Preview` | `Lungfish Preview` | `preview` |
| Stable | `Lungfish Genome Explorer` | `Lungfish` | `stable` |

`CFBundleDisplayName` is the full user-facing identity. `CFBundleName` is the
short identity used where macOS or Lungfish needs a compact name. The custom
channel key allows runtime UI to present a Preview warning without inferring
state from a feed URL or parsing a name.

Source and ordinary local builds default to the Stable product name. Debug
build identity remains unchanged. Release packaging is authoritative for a
shipped build and verifies all three channel values before signing.

### Runtime branding boundary

A small `LungfishAppIdentity` value in `LungfishCore` reads the three bundle
keys and supplies stable fallbacks. App chrome consumes this value for:

- the application menu's short title and its About, Hide, and Quit commands;
- the About window title and product label;
- main, project, welcome, and third-party-software window titles; and
- other app-owned window chrome that currently hard-codes the full product
  name.

Help-book metadata and scientific identity strings remain `Lungfish Genome
Explorer`. Likewise, provenance `toolName` values, generated-file attribution,
HTTP user agents, CLI descriptions, and workflow metadata remain channel-neutral
product identifiers. A result created by Preview must still identify the same
scientific application, with its exact app version carrying reproducibility.

### Preview warning

Preview remains publicly downloadable as a GitHub prerelease. Every Preview
release note and the Preview identity shown in the About window carries this
caveat:

> Preview builds are under rapid iterative development. Features may be
> incomplete, change quickly, or require additional feedback.

Stable release notes explain how to opt into Preview through the Preview DMG and
how to return to Stable. Stable builds do not show the Preview warning.

### Version and promotion semantics

A version identifies exactly one signed artifact and one release channel. A
Stable build never reuses a Preview version, tag, DMG, or signature because its
name and Sparkle feed differ inside the signed bundle.

If no concurrent release appears, the first Stable release is `2026.8.4`. It is
a fresh Stable-channel build from the current verified `v2026.8.3` Preview
baseline plus the channel-identity implementation. Its notes describe that
promotion relationship; they do not claim the Preview DMG itself was promoted.

Future Preview and Stable builds continue sharing the monotonically increasing
`YYYY.M.PATCH` line. A `2026.8.4` Stable installation polls only
`sparkle-stable/appcast-stable.xml`; a `2026.8.3` Preview installation remains on
`sparkle-beta/appcast-beta.xml` until a later Preview build is published.

## First Stable release notes

The first Stable notes aggregate the product delta from the recorded bootstrap
baseline `v0.5.0-beta29`, reconciled with the intervening release ledger. They
must include:

- audit fields for Stable, previous versioned release `v2026.8.3`, no prior
  Stable release, and dependency set `2026.2`;
- an `Included preview releases` section listing published previews
  `v2026.8.1` (withdrawn artifact) and `v2026.8.3` (portable corrected build);
- a separate historical note that `v2026.8.2` was an unpublished preparation
  tag, not an included Preview artifact;
- the channel names, manual enrollment/switching behavior, and Preview caveat;
- aggregated user-facing workflow, reliability, provenance, updater, and
  release-portability changes; and
- complete current managed-tool, pipeline, database, bootstrap, Sparkle, and
  SwiftPM version identities.

The candidate version is recomputed from live tags and GitHub releases before
version preparation and again before tagging. `2026.8.4` is not reserved until
those collision checks pass.

## Release and verification behavior

The stable builder invocation uses `--channel stable`, which must:

- stamp Stable names and the Stable channel key;
- bake the Stable Sparkle feed into the app;
- create a new signed, notarized, stapled DMG;
- publish a non-draft, non-prerelease GitHub versioned release;
- publish the signed item to the mutable `sparkle-stable` feed container; and
- trigger the heavy validation board automatically through GitHub's `released`
  event, without a manual CI dispatch.

Verification must inspect the archived app, release app, mounted DMG app,
GitHub release, stable appcast, release-note bytes, signatures, notarization,
staples, bundle names, bundle channel, feed URL, version/build ordering, DMG
digest, tag/commit identity, and automatic Stable CI. The existing Preview feed
and `v2026.8.3` artifact must remain unchanged.

## Acceptance criteria

1. A Preview build visibly reports `Lungfish Genome Explorer Preview` and
   `Lungfish Preview`, includes the rapid-development caveat, and polls only the
   Preview feed.
2. A Stable build visibly reports `Lungfish Genome Explorer` and `Lungfish`,
   omits the Preview caveat, and polls only the Stable feed.
3. Both builds remain `Lungfish.app` with bundle identifier
   `com.lungfish.browser`; installing one channel replaces the other.
4. Scientific provenance and generated-data product identity remain
   channel-neutral and continue recording the exact app version.
5. The first Stable release uses a new collision-free CalVer and a newly built
   artifact rather than reusing the Preview version or DMG.
6. Stable release notes aggregate from `v0.5.0-beta29`, accurately reconcile the
   Preview ledger, and list all pinned dependency versions.
7. The Stable GitHub release, Sparkle feed, notarized DMG, and automatic heavy CI
   board all pass independent verification before the release is declared
   complete.

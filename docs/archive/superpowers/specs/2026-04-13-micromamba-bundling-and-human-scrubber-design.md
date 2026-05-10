# Micromamba Bundling and Human Scrubber Database Packaging Design

Date: 2026-04-13
Status: Proposed

## Scope

This design covers two narrowly scoped distribution changes:

1. Bundle a pinned `micromamba` binary in the app and use that bundled version for both GUI and CLI conda operations.
2. Remove the embedded human-scrubber database from the app bundle and install it on demand into the user-managed databases location the first time it is needed.

This design does not change the current Tier 1 vs Tier 2 tool boundary. Core tools remain bundled.

## Goals

- Remove runtime network bootstrap for `micromamba` itself.
- Keep conda environments rooted at `~/.lungfish/conda` so existing no-space path assumptions remain valid.
- Ensure GUI and CLI share the same `micromamba` bootstrap and version-selection behavior.
- Reduce app size substantially by removing the embedded human-scrubber database from the app bundle.
- Preserve current behavior for users who never use human-read scrubbing workflows.

## Non-Goals

- Replacing bundled Tier 1 tools with conda-installed versions.
- Redesigning plugin packs or changing per-tool conda environments.
- Reworking containerization packaging.
- Replacing the human-scrubber executable itself.

## Current State

`CondaManager` stores environments under `~/.lungfish/conda` and currently downloads `micromamba` from GitHub on demand if the binary is missing. This makes first use depend on network access and an external latest-release URL.

The release app is large primarily because the workflow resource bundle includes:

- `Databases/human-scrubber`: about 983 MB
- `Tools`: about 152 MB
- `Containerization`: about 96 MB

The bundled tools are not the main size driver. The embedded human-scrubber database is.

## Design

### 1. Bundled Micromamba

Add a pinned `micromamba` binary to the bundled tool resources and track its version in the existing tool manifest/notices flow.

`CondaManager.ensureMicromamba()` will:

1. Keep the existing `~/.lungfish/conda` root prefix.
2. Check for `~/.lungfish/conda/bin/micromamba`.
3. If missing, copy the bundled binary from app resources into `~/.lungfish/conda/bin/micromamba`.
4. If present but older than the bundled version, replace it atomically.
5. Set executable permissions and verify `--version`.

Normal operation will not download `micromamba` from the network.

This behavior applies equally to GUI and CLI code because both already go through `CondaManager`.

### 2. Human Scrubber Database as Managed Data

Remove the human-scrubber database from the app bundle and treat it as managed database content.

The app will:

1. Register the database in the existing database catalog/registry.
2. Store it in the configured database storage location, not inside the app bundle.
3. Check for its presence when a recipe or operation requiring human-read scrubbing starts.
4. If missing, prompt the user to install it before continuing.
5. Download and verify it into managed storage, then resume or allow the user to retry the operation.

Users who never run workflows requiring the database will never download it.

### 3. UX Behavior

For micromamba:

- There is no new prompt on first conda use unless the bundled binary is missing or invalid.
- First use becomes a local copy into `~/.lungfish/conda/bin/`, not a network fetch.

For human-scrubber:

- When a user first selects a workflow that requires the database, the app presents a blocking prompt:
  - explain that a large database is required
  - show approximate size
  - offer install now or cancel
- If install succeeds, the workflow can proceed.
- If install fails, the workflow remains blocked with a specific error.

### 4. Versioning and Updates

Micromamba:

- Pin a specific version in the repo.
- Update it deliberately as part of release engineering.
- Add notices/metadata for the bundled binary.

Human-scrubber database:

- Version the managed database explicitly.
- Store database version metadata alongside the installed asset.
- Permit later refresh/update logic without coupling it to app updates.

## Error Handling

### Micromamba

- If bundled `micromamba` is missing from app resources, surface a reinstall/corrupt-bundle error.
- If copy fails, surface a filesystem/permissions error.
- If version verification fails, do not continue with conda operations.

### Human Scrubber Database

- If the database is missing, prompt instead of failing late inside the tool.
- If download fails, return a clear actionable error.
- If verification fails, delete the partial artifact and treat the database as not installed.

## Testing

Add CI and unit/integration coverage for:

- bundled `micromamba` exists in resources and is executable
- `ensureMicromamba()` copies the bundled binary into a fresh `~/.lungfish/conda/bin`
- installed `micromamba` is upgraded when the bundled version is newer
- normal `ensureMicromamba()` path does not depend on network access
- tool metadata, notices, and bundled version manifest stay in sync
- human-scrubber database absence triggers the install-required path
- successful database installation makes the requiring workflow runnable
- failed or partial human-scrubber downloads are handled cleanly

## License Review Requirements

Before shipping the branch:

- verify redistribution terms for bundled `micromamba`
- re-audit currently bundled third-party tools against actual redistribution permissions
- ensure `THIRD-PARTY-NOTICES`, README summaries, and tool metadata reflect the shipped set accurately

Particular attention should be given to:

- `micromamba`
- BBTools custom license text
- VSEARCH dual-license selection
- UCSC binary redistribution terms
- bundled OpenJDK runtime terms

## Implementation Plan Shape

This design is expected to split into two implementation tracks in one branch:

1. Bundled `micromamba` resource/bootstrap/versioning/tests.
2. Human-scrubber database packaging/catalog/download/prompt flow/tests.

The second track should be implemented without changing unrelated database-management behavior.

## Open Decisions Resolved

- Tier 1 bundled tools remain bundled.
- GUI and CLI both use bundled `micromamba`.
- Human-scrubber database moves out of the app bundle and becomes on-demand managed content.

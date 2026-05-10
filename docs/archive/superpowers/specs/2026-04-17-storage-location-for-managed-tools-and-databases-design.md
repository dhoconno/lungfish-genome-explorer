# Storage Location For Managed Tools And Databases Design

Date: 2026-04-17
Status: Proposed

## Summary

Add an advanced storage-location feature that lets users place Lungfish's managed third-party tools and downloaded databases on a different volume, such as an external SSD, while keeping the default first-launch experience fast and simple.

This feature should:

- keep the default storage location as the recommended path
- make alternative storage visible on first launch for disk-space-constrained users
- support later migration from app preferences
- treat tools and databases differently during migration
  - databases are copied to the new root and only removed from the old root after successful cutover
  - micromamba-managed tools are reinstalled from pinned package definitions
- replace hard-coded `~/.lungfish` assumptions in app and CLI runtime paths with one shared storage-root resolver
- reject unsupported destinations up front, especially paths containing spaces

The goal is not to make arbitrary existing conda environments movable. The goal is to make Lungfish's managed support files relocatable in a safe, deterministic way.

## Goals

- Let advanced users place large managed support files on external storage.
- Keep the default onboarding path simple for most users.
- Ensure app and CLI paths resolve tools and databases from the same active storage root.
- Preserve deterministic managed tool installation by reinstalling from the pinned lock manifest instead of moving conda environments directly.
- Make storage problems understandable:
  - distinguish `storage location unavailable` from `tools missing`
  - distinguish validation failure from migration failure
- Let users reclaim old local disk space only after the new storage root is verified.

## Non-Goals

- Do not support arbitrary paths containing spaces in this first version.
- Do not support direct Finder-style relocation of existing conda environments.
- Do not add offline migration or prepackaged environment import in this pass.
- Do not support multiple active storage roots at once.
- Do not redesign the entire setup experience beyond the storage affordance needed for this feature.

## Current State

Database storage already has partial path indirection:

- `AppSettings` persists `DatabaseStorageLocation`
- `MetagenomicsDatabaseRegistry` can initialize from a custom path
- Plugin Manager already exposes database storage controls

Managed tools do not have equivalent shared indirection yet. Several runtime paths still assume `~/.lungfish`, including:

- `CondaManager`
- `CoreToolLocator`
- `ProcessManager`
- `SRAService`
- tool launch environment setup for Nextflow and Snakemake

This means Lungfish currently has two different storage models:

- databases: partly configurable
- tools: effectively fixed to `~/.lungfish/conda`

That split is acceptable for the current release shape, but it is not sufficient for a user-facing storage relocation feature.

## Design Principles

### Default First

The default storage location should remain the primary, recommended path because:

- it is simpler
- it avoids removable-drive edge cases
- it keeps the main setup flow focused

Alternative storage should be clearly available, but visually secondary.

### Safe Over Clever

Tool storage relocation should be implemented as reinstall plus verification, not by physically moving existing conda environments. Conda-installed scripts and wrappers can embed absolute prefixes, so copying or moving an environment tree is not the safe contract.

### One Source Of Truth

App UI, setup flows, migration flows, and CLI tool/database resolution must all read the active storage root from one shared model.

### Explicit Constraints

The feature should reject unsupported destinations before any migration begins. This is better than allowing users to pick an invalid location and then failing later in a confusing way.

## User-Facing Design

### Welcome Screen

The first-launch setup card should keep the default install action primary.

The required-setup area should add a small secondary action such as:

`Need more space? Choose another storage location…`

This should not become an equal first-launch fork. It should be discoverable but clearly advanced.

Selecting that action opens a dedicated storage-location sheet that explains:

- the default location is recommended
- external SSD storage is supported for large tool and database footprints
- only supported destinations can be used
- tools will be reinstalled there
- databases will be copied there and old local copies can be removed after successful migration

If the user does nothing, setup continues using the default storage root.

The destination picker should prevent invalid choices from being committed. The user should not be able to confirm a location that Lungfish already knows will fail.

### Preferences

After setup, the same feature should live in app preferences as an app-wide `Storage` section.

That section should show:

- current storage location
- whether it is the default location
- current status
  - available
  - unavailable
  - migration in progress
  - verification failed
- `Change Location…`
- `Remove old local copies…` only when a previous root still has reclaimable data after successful migration

### Language

Do not describe this feature as relocating `.lungfish` in the UI.

Use user-facing language such as:

- `Storage Location`
- `Third-Party Tools and Databases`
- `Current Location`
- `Change Location…`
- `Remove old local copies…`

The filesystem implementation can still use a Lungfish-owned root directory under the selected location.

## Storage Model

Introduce one shared managed storage root abstraction, for example:

- `ManagedStorageRoot`

This abstraction should own the active root directory and derive all managed subpaths from it.

At minimum it should expose:

- managed root
- tool root
- conda root
- database root
- migration staging locations if needed
- validation helpers

Example derived layout under a user-selected root:

```text
<StorageRoot>/
  conda/
    bin/micromamba
    envs/<tool>/
  databases/
    ...
  state/
    ...
```

The default root remains:

```text
~/.lungfish/
```

The key change is that `~/.lungfish` becomes the default managed storage root, not a permanently hard-coded assumption.

## Path Validation Rules

The first version should only allow destinations that satisfy all of the following:

- resolved path exists or can be created
- writable by the current user
- local filesystem supported for executable managed tools
- path contains no spaces anywhere in the fully resolved path
- volume is currently mounted and reachable
- path is not nested inside the app bundle, temp directories, or project folders

### Destination Picker Behavior

The destination-selection UI must be proactive, not permissive.

Requirements:

- the picker only allows directory selection
- the confirmation action stays disabled until the selected path passes validation
- if the platform file picker cannot fully hide invalid folders in advance, Lungfish must still reject them immediately on selection rather than allowing the user to proceed
- validation must run on the fully resolved path, not just the displayed folder name
- symlink resolution must be included before checking for spaces, writability, and filesystem support

Examples of destinations that must be rejected before migration can begin:

- `/Volumes/My SSD/Lungfish`
- `/Users/name/Desktop/Lungfish Tools`
- any directory whose resolved path traverses a parent path with spaces
- any unmounted or non-local target

Recommended support policy:

- support APFS and HFS+
- reject or warn on exFAT, NTFS, SMB, and similarly risky filesystems for tool storage

If databases are later allowed on a wider set of filesystems than tools, that can be a future enhancement. In this first version, the destination should be valid for the combined storage model.

## Persistence Model

Replace the current split storage persistence with a shared managed storage preference.

The feature should persist:

- active managed storage root
- whether it is the default
- previous root eligible for cleanup
- migration state if a migration is interrupted

Existing database-only storage preference should be folded into this shared model so the app no longer has one setting for databases and another implicit location for tools.

### Bootstrap Config

The active storage-root pointer must live in a stable location that both the app and CLI can read before they know where managed tools and databases currently live.

Use a small bootstrap config file in a fixed, local, space-free path such as:

```text
~/.config/lungfish/storage-location.json
```

That file should store:

- active managed storage root
- previous root pending cleanup, if any
- migration state, if any

The app can still mirror user-facing state into preferences if needed for UI bindings, but the filesystem bootstrap config should be the source of truth for runtime resolution because the CLI must be able to read it without relying on app-only preference domains.

For compatibility:

- existing users with no custom setting continue using `~/.lungfish`
- existing custom database-only configurations should migrate into the new shared model through an explicit compatibility path

## Runtime Refactor Surface

All managed tool and database lookup paths must derive from the shared storage root.

This explicitly includes:

- `CondaManager`
- `CoreToolLocator`
- `ProcessManager`
- `SRAService`
- database registries
- setup/install flows
- Plugin Manager status and actions
- welcome-screen required setup status
- CLI provisioning and status commands
- any launch environment construction for Nextflow, Snakemake, Deacon, SRA Toolkit, and other managed tools

The spec requirement is:

- no app or CLI path that participates in managed setup may silently fall back to hard-coded `~/.lungfish` once the storage-root abstraction exists

## Tool Installation Behavior

Managed third-party tools should continue to install from the pinned lock manifest for the current app release.

Changing storage location should:

1. validate the new destination
2. ensure bundled `micromamba` can be staged there
3. reinstall required managed tools from the release lock manifest into the new `conda/` root
4. rerun functional smoke checks from the new root

The migration should only switch the active storage root after those checks pass.

### Why Reinstall Instead Of Move

This is a core design rule:

- conda environments may contain absolute prefixes
- wrappers and launcher scripts may break after relocation
- some tools already need path-specific repair behavior

So the contract is:

- databases may be copied or moved
- tools are reinstalled

## Database Migration Behavior

Databases should be migrated separately from tools.

Preferred behavior:

- copy databases to the new root
- verify presence and readiness from the new root
- optionally delete old copies only after successful cutover

Copy is safer than immediate move because it preserves rollback if validation fails.

If space pressure later requires a move-first option, that can be a future enhancement. The initial user-facing flow should prioritize successful migration over minimal temporary disk usage.

## Migration Workflow

The migration workflow should be explicit and multi-stage.

### First-Launch Alternate Storage

1. User opens `Choose another storage location…`
2. App validates the destination
3. App installs tools and downloads required databases to that location
4. App runs required smoke checks
5. App marks the new root active
6. Setup continues normally

No cleanup step is needed on first launch if nothing was previously installed locally.

### Post-Setup Relocation

1. User opens `Storage` preferences and chooses `Change Location…`
2. App validates the destination
3. App copies databases to the new root
4. App reinstalls managed tools to the new root
5. App reruns tool and database smoke checks from the new root
6. App switches the active root only after verification succeeds
7. App records the previous root as reclaimable
8. App offers `Remove old local copies…` as a separate explicit action

### Cleanup

Cleanup must never happen before successful cutover.

`Remove old local copies…` should:

- show what will be removed
- operate only on the previous inactive Lungfish-managed root
- refuse to remove the active root
- tolerate partially missing files
- leave a clear success or failure summary

## Status And Error States

The feature needs storage-aware health states, not just install states.

At minimum:

- `Using Default Location`
- `Using Custom Location`
- `Migration In Progress`
- `Verification Failed`
- `Storage Location Unavailable`
- `Cleanup Available`

`Storage Location Unavailable` is especially important. If an external SSD is unplugged, the app should not interpret that as:

- missing tools
- missing databases
- prompt to reinstall into the default location

Instead it should explain that the configured storage location is currently unavailable and guide the user to reconnect it or choose a different location.

## Smoke Checks

This feature depends on the shared smoke-check system already introduced for managed tools and required data.

Requirements:

- smoke checks must run against the active configured storage root
- storage migration cannot complete until required checks pass from the new root
- tool checks should remain lightweight where possible
- database checks should validate both existence and compatibility, not just directory presence

The storage feature does not change the definition of tool readiness. It changes where readiness is evaluated.

## CLI Behavior

The CLI must respect the same managed storage root as the app.

This means:

- the CLI cannot assume `~/.lungfish`
- CLI provisioning/status commands should report the configured location
- CLI operations that need managed tools or databases must resolve from the shared storage root

If the configured external storage is unavailable, CLI errors should say that directly.

The storage root should not be an app-only preference inaccessible to the CLI.

## Filesystem And Security Considerations

### Path Spaces

The first version should reject any destination whose resolved path contains spaces.

This includes:

- volume names
- parent directories
- final directory name

This is restrictive, but it matches the current realities of multiple bundled and managed bioinformatics tools and avoids promising unsafe behavior.

### Permissions

The app should validate write and execute viability before migration:

- create directory
- create temporary file
- verify executable placement rules needed for managed tools

### Missing Volume

A removable drive becoming unavailable should not corrupt the stored configuration. The app should keep the configured root and report that it is unavailable.

## Compatibility And Migration From Existing Installations

Existing users may already have:

- default `~/.lungfish`
- custom database path only
- managed tools in the default location and databases elsewhere

The first launch after this feature lands should normalize these cases into the new storage-root model.

Recommended compatibility behavior:

- default-only users remain on default
- users with custom database storage and default tools should be treated as a legacy split-layout state
- the app should surface a non-blocking recommendation to consolidate into one managed storage root

The spec does not require automatic forced migration of split-layout users on day one. It does require that the feature can detect and explain that state.

## Preferences And Welcome-Screen Relationship

The same storage system should be exposed in two places:

- welcome-screen setup card
- app preferences

They should share the same controller/service logic. The difference is only entry point and copy.

The welcome-screen version is:

- discoverable
- secondary
- focused on first setup

The preferences version is:

- full management UI
- current location visibility
- migration and cleanup actions

## Apple HIG Considerations

The welcome-screen storage affordance should remain visually secondary to the main required-setup action.

The storage sheet should:

- explain consequences in plain language
- avoid jargon such as `conda root prefix`
- present one clear recommended choice
- prevent users from committing destinations that are known to be invalid
- show progress during migration or installation
- keep destructive cleanup separate from the initial migration action

This aligns with the current Lungfish direction of making setup approachable for non-technical users while still exposing advanced options for those who need them.

## Testing

### Unit Tests

- storage-root resolver derives all managed subpaths correctly
- invalid destinations are rejected:
  - spaces
  - unsupported filesystem
  - unwritable path
- default root and custom root persistence behave correctly
- compatibility behavior for legacy split storage is detected

### Migration Tests

- first-launch alternate storage installs into the selected root
- later relocation copies databases and reinstalls tools into the new root
- active root switches only after verification succeeds
- failed migration leaves the old active root unchanged
- cleanup only removes the inactive prior root

### App UI Tests

- welcome screen shows the advanced storage action but keeps default install primary
- preferences show current location and cleanup state
- unavailable external storage surfaces the correct message

### CLI Tests

- CLI resolves tools and databases from configured storage root
- CLI status output reports the active location
- unavailable configured storage produces a storage-unavailable error, not a missing-tool error

### Integration Tests

- required setup works from a custom space-free external-style root
- Nextflow, Snakemake, samtools, bbtools, deacon, and required databases all resolve from the selected root
- SRA Toolkit and other managed tools resolve from the selected root in both app and CLI flows

## Risks

- The current tool-path assumptions are spread across more codepaths than the UI suggests, so the refactor boundary must be audited carefully.
- Legacy users with split database/tool storage may need careful compatibility messaging.
- External-drive reliability introduces a new class of user error that the app must explain well.
- Strict no-spaces validation may frustrate some users, but silently allowing unsafe paths would be worse.

## Recommendation

Implement this as a shared managed-storage-root refactor with two user-facing entry points:

- a secondary advanced action on the welcome-screen required-setup card
- a full `Storage` preferences panel after setup

Use reinstall-plus-verify for tools, copy-plus-verify for databases, and require a supported space-free destination path. This gives disk-constrained users a clear supported path to external storage without degrading the default setup experience for everyone else.

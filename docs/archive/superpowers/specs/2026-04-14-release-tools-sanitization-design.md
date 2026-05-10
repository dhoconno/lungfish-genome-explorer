# Release Tools Sanitization Design

Date: 2026-04-14
Status: Approved

## Scope

This design fixes macOS Developer ID export for the Release app bundle by sanitizing executable permissions in the copied `LungfishWorkflow` tools resource bundle.

It does not redesign tool discovery, replace BBTools wrappers, or change the bundled tool set.

## Problem

`xcodebuild -exportArchive` fails during Developer ID export with:

`Reached end of file while looking for: Mach-O slice`

The archived app bundle contains thousands of files under `Contents/Resources/.../Tools` that retain executable bits even though they are not executable code. The copied bundle currently includes:

- Java `.class` files marked executable
- plain text and config files marked executable
- compressed data files marked executable
- non-macOS binary artifacts marked executable

This makes the export/signing pipeline treat resource files as nested code candidates.

## Goals

- Make Release archive/export compatible with Developer ID export and notarization.
- Keep the small set of runtime-invoked wrapper scripts runnable.
- Avoid noisy repo-wide file mode churn in the source tree.
- Verify behavior against the packaged app bundle, not only source resources.

## Non-Goals

- Replacing wrapper scripts with explicit interpreter launches.
- Refactoring `NativeToolRunner`.
- Repacking or pruning the BBTools payload.

## Design

### 1. Release-Only Bundle Sanitizer

Add a dedicated script, `scripts/sanitize-bundled-tools.sh`, that operates on the copied tools directory inside the built app bundle.

The sanitizer will:

1. Walk files inside the provided tools directory.
2. Keep executable bits on Mach-O binaries.
3. Keep executable bits on an explicit allowlist of wrapper scripts that Lungfish launches directly.
4. Remove executable bits from all other files.

This keeps the source checkout unchanged and only normalizes the packaged artifact.

### 2. Xcode Build Integration

Add a Release-only Xcode shell build phase after resources are copied and before final signing/export uses the built app bundle.

The phase will call:

`$SRCROOT/scripts/sanitize-bundled-tools.sh "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools"`

Debug builds remain unaffected.

### 3. Allowlisted Scripts

The allowlist should cover only scripts that Lungfish launches as entrypoints today:

- `bbtools/clumpify.sh`
- `bbtools/bbduk.sh`
- `bbtools/bbmerge.sh`
- `bbtools/repair.sh`
- `bbtools/tadpole.sh`
- `bbtools/reformat.sh`
- `scrubber/scripts/scrub.sh`
- `scrubber/scripts/cut_spots_fastq.py`
- `scrubber/scripts/fastq_to_fasta.py`

Helper files sourced from these scripts, such as `bbtools/calcmem.sh`, do not need executable permissions.

## Testing

Add regression coverage for:

- the sanitizer script exists and is referenced by the Xcode Release build
- the sanitizer removes `+x` from fake text/data files
- the sanitizer preserves `+x` for allowlisted wrapper scripts

Manual/package verification must then confirm:

- Release archive succeeds
- Developer ID export no longer fails with Mach-O slice parsing
- packaged `bbduk.sh`, `bbmerge.sh`, `reformat.sh`, `repair.sh`, `tadpole.sh`, and `clumpify.sh` execute from the built app bundle
- packaged scrubber helper chain still executes from the built app bundle

## Risk

The main risk is an incomplete allowlist. That is why packaged-app execution checks are part of the acceptance criteria, not a follow-up task.

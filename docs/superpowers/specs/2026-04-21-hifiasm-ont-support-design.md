# Hifiasm ONT Support Design

Date: 2026-04-21
Status: Draft for review

## Summary

Lungfish currently exposes `Hifiasm` only for `PacBio HiFi/CCS` reads, even though upstream `hifiasm` now supports Oxford Nanopore assembly with `--ont`. This design updates the shared assembly surface so ONT datasets can run either `Flye` or `Hifiasm`, while HiFi datasets continue to run `Hifiasm` in its existing mode.

The design keeps `Hifiasm` as one tool entry. We do not create separate UI tools such as `Hifiasm (ONT)` and `Hifiasm (HiFi)`. Instead, the confirmed read type drives the runtime mode: HiFi input keeps the current command shape, and ONT input adds `--ont`.

## Goals

- Allow users to run `Hifiasm` on ONT reads.
- Keep `Flye` available for ONT reads.
- Preserve the existing `Hifiasm` flow for PacBio HiFi/CCS reads.
- Keep the assembly wizard honest about the active read type.
- Preserve normalized assembly outputs, provenance, and result viewport behavior.

## Non-Goals

- No new assembly result type.
- No separate `Hifiasm (ONT)` tool entry.
- No new viewport or inspector surface.
- No hybrid long-read support changes.
- No ONT-specific advanced `Hifiasm` tuning in this pass beyond enabling `--ont`.

## Current Gap

The current app wiring still treats `Hifiasm` as HiFi-only:

- Assembly compatibility exposes `Flye` only for ONT and `Hifiasm` only for HiFi.
- The wizard defaults `Hifiasm` to `PacBio HiFi/CCS`.
- The command builder rejects `Hifiasm` runs unless the input is treated as a single HiFi FASTQ.

This conflicts with current upstream `hifiasm`, which supports ONT assembly through `--ont`.

## Design

### 1. Compatibility and Tool Availability

`AssemblyCompatibility` should allow:

- `Illumina short reads` -> `SPAdes`, `MEGAHIT`, `SKESA`
- `ONT reads` -> `Flye`, `Hifiasm`
- `PacBio HiFi/CCS` -> `Hifiasm`

`Hifiasm` remains blocked for Illumina data.

This keeps the shared assembly surface simple: one tool catalog, one `Hifiasm` entry, and read-type-aware compatibility.

### 2. Wizard and Selection Behavior

The assembly wizard should keep read type as the controlling state.

For ONT input:

- Both `Flye` and `Hifiasm` appear as valid assemblers.
- Choosing `Hifiasm` must not silently change the read type from `ONT reads` to `PacBio HiFi/CCS`.

For HiFi input:

- `Hifiasm` remains available.
- Choosing `Hifiasm` keeps the read type as `PacBio HiFi/CCS`.

The existing `Hifiasm`-specific controls, such as `Primary contigs only`, remain visible in both ONT and HiFi modes unless the upstream tool later proves otherwise.

### 3. Command Construction

`ManagedAssemblyPipeline.buildHifiasmCommand(for:)` should branch on `request.readType`:

- `PacBio HiFi/CCS`: keep the current command shape.
- `ONT reads`: add `--ont` to the `hifiasm` invocation.

Both modes continue to require a single-input FASTQ topology in this pass.

The output normalization path stays unchanged. `Hifiasm` still produces the same normalized assembly result bundle shape and uses the existing output conversion logic.

### 4. Provenance and User-Facing Reporting

Run records should reflect the actual selected read type and actual command mode.

That means:

- provenance stores `ONT reads` when `Hifiasm` is run with ONT input
- runtime errors and operation dialogs report `ONT reads`
- assembly summary strips and inspector content continue to show the selected read type accurately

There is no need to create a new tool ID or analysis prefix. This remains a `Hifiasm` analysis.

## Testing

### Compatibility

Update compatibility tests so they assert:

- ONT enables both `Flye` and `Hifiasm`
- HiFi enables `Hifiasm`
- Illumina does not enable `Hifiasm`

### Command Builder

Add command-builder coverage for:

- `Hifiasm + ONT` emits `--ont`
- `Hifiasm + HiFi` does not emit `--ont`
- `Hifiasm + ONT` still uses the single-input topology

### Wizard and UI State

Add UI-state coverage for:

- selecting `Hifiasm` while the confirmed read type is ONT does not force the read type back to HiFi
- ONT datasets show both `Flye` and `Hifiasm` as runnable

## Risks and Tradeoffs

- Upstream `Hifiasm` ONT mode may want ONT-specific advanced flags in the future. This design intentionally does not expose those yet.
- Users may compare `Flye` and `Hifiasm` on the same ONT dataset and get materially different assembly shapes. That is expected and should not require separate UI handling.
- If upstream `Hifiasm` later differentiates ONT output semantics in a way that affects normalization, that should be handled as a separate follow-up rather than complicating this enablement patch.

## Recommendation

Implement the smallest change set that makes `Hifiasm` genuinely dual-mode for long reads:

1. Expand compatibility to expose `Hifiasm` for ONT.
2. Keep the read type authoritative in the wizard.
3. Add `--ont` only when the selected read type is ONT.
4. Cover the change with compatibility, command-builder, and wizard regression tests.

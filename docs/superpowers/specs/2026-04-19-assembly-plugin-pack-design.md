# Assembly Plugin Pack Design

Date: 2026-04-19
Status: Proposed

## Summary

Introduce an active `assembly` micromamba plugin pack for FASTQ-driven de novo assembly workflows, with a first release focused on five assemblers that have a credible `macOS-arm64` story and meaningful user demand:

- `SPAdes`
- `MEGAHIT`
- `SKESA`
- `Flye`
- `Hifiasm`

The v1 user model should be read-type-driven, not "every possible assembler mode" driven. The UI should support exactly three input classes:

- `Illumina short reads`
- `ONT reads`
- `PacBio HiFi`

Hybrid assembly is explicitly out of scope for v1.

The app should replace the current SPAdes-only assembly surface with a shared assembly configuration experience that:

- exposes the five supported assemblers in the `ASSEMBLY` category
- presents harmonized common controls where concepts overlap
- keeps tool-specific knobs under advanced disclosure sections
- blocks invalid assembler and input combinations before launch
- executes assemblers from managed micromamba environments rather than depending on Apple Containers

## Goals

- Ship a real `assembly` plugin pack backed by micromamba-managed environments.
- Make the FASTQ operations `ASSEMBLY` category expose multiple assemblers instead of only SPAdes.
- Support the three approved v1 read classes:
  - `Illumina short reads`
  - `ONT reads`
  - `PacBio HiFi`
- Keep the assembly UI consistent with the existing operations dialog structure:
  - `Inputs`
  - `Primary Settings`
  - `Advanced Settings`
  - `Output`
  - `Readiness`
- Normalize common assembly concepts so users do not need to relearn the whole dialog for each assembler.
- Preserve tool-specific power through advanced disclosures instead of flattening away meaningful differences.
- Prevent obviously wrong runs, such as:
  - `Flye` with Illumina short reads
  - `Hifiasm` with ONT reads
  - mixed read classes presented as a single v1 run
- Use the existing Lungfish color palette for compatibility strips, warning states, readiness text, and related status messaging.
- Establish a foundation for future hybrid assembly, polishing, and assembly-QC work without pretending those are solved in v1.

## Non-Goals

- Do not support hybrid assembly in v1.
- Do not support mixed read-class runs in v1.
- Do not add `QUAST` in v1.
- Do not add `Unicycler` in v1.
- Do not add polishing, scaffolding, circularization, trio assembly, or Hi-C assembly workflows in v1.
- Do not attempt to expose every assembler flag in the primary UI.
- Do not preserve the Apple Container requirement as the primary execution path for assembly.
- Do not redesign unrelated FASTQ operation categories.

## Current State

The repository already contains several assembly-related pieces, but they are not yet aligned with the intended v1 experience:

- `PluginPack` already defines an inactive built-in `assembly` pack with `spades`, `megahit`, `flye`, and `quast`.
- The FASTQ operations dialog currently exposes only `SPAdes` under the `ASSEMBLY` category.
- `AssemblyWizardSheet` is SPAdes-specific in both presentation and configuration output.
- `AssembleCommand` is SPAdes-only and currently assumes Apple Containers.
- `AssemblyResultViewController` already hints at "SPAdes or compatible" result viewing, but the underlying data model is still SPAdes-shaped.

This means the v1 work is not greenfield. The key change is to convert assembly from a one-tool path into a managed, read-type-aware multi-tool surface.

## Tool Selection

### Included In V1

The first pack should contain:

- `SPAdes`
- `MEGAHIT`
- `SKESA`
- `Flye`
- `Hifiasm`

### Selection Rationale

- `SPAdes` remains the most familiar short-read assembler already present in Lungfish and now has current `osx-arm64` Bioconda availability.
- `MEGAHIT` broadens short-read coverage for metagenome-style or faster memory-efficient short-read assembly.
- `SKESA` gives a conservative short-read microbial option with a smaller, easier-to-constrain parameter surface.
- `Flye` is the clearest ONT-first assembler in this set and has current `osx-arm64` Bioconda support.
- `Hifiasm` is the clearest PacBio HiFi-first assembler in this set and has current `osx-arm64` Bioconda support.

### Explicit Deferrals

- `QUAST` is deferred because current Bioconda packaging does not expose `macOS-arm64` support.
- `Unicycler` is deferred because the current release lineage still constrains SPAdes compatibility in a way that conflicts with current arm64-friendly SPAdes packaging, and it would blur the v1 no-hybrid boundary.

## Read-Type Scope

### Supported Read Classes

V1 supports exactly three visible read classes:

- `Illumina short reads`
- `ONT reads`
- `PacBio HiFi`

The UI should use those names directly. The product should not mention `CLR` in the v1 surface.

### Hybrid Boundary

Hybrid assembly is intentionally deferred. If the selected inputs imply more than one read class, the run should be blocked with a clear message that hybrid assembly is not supported in v1.

## User-Facing Model

### Assembly Category

The `ASSEMBLY` category in the FASTQ operations dialog should expose five tools:

- `SPAdes`
- `MEGAHIT`
- `SKESA`
- `Flye`
- `Hifiasm`

The assembly UI should remain tool-driven in the sidebar, but read-type-aware in the main pane.

### Shared Pane Shape

The current SPAdes-specific assembly surface should become a shared assembly pane that follows the established operation-dialog section rhythm:

1. `Inputs`
2. `Primary Settings`
3. `Advanced Settings`
4. `Output`
5. `Readiness`

### Primary Controls

The primary controls should include:

- `Assembler`
- `Read Type`
- `Project Name`
- `Threads`
- `Output Location`

Capability-scoped controls should appear only when the selected assembler supports the concept, while keeping labels consistent where possible:

- `Memory Limit`
- `Minimum Contig Length`
- `Assembly Mode` or `Profile`
- `K-mer Strategy`
- `Error Correction` or `Polishing`

## Compatibility Model

### Compatibility First, Not Advisory

Invalid assembler and read-type combinations should be blocked before run. The UI should not allow the user to "try anyway" for combinations that are known to be wrong or poor fits for v1.

### V1 Compatibility Matrix

- `Illumina short reads`
  - enable `SPAdes`
  - enable `MEGAHIT`
  - enable `SKESA`
  - disable `Flye`
  - disable `Hifiasm`
- `ONT reads`
  - enable `Flye`
  - disable `SPAdes`
  - disable `MEGAHIT`
  - disable `SKESA`
  - disable `Hifiasm`
- `PacBio HiFi`
  - enable `Hifiasm`
  - disable `SPAdes`
  - disable `MEGAHIT`
  - disable `SKESA`
  - disable `Flye`

### Read-Type Detection

The app should attempt a best-effort auto-detection from selected FASTQ metadata or filename conventions where possible, but the current read type must remain visible in the UI so users can understand why certain tools are available or unavailable.

If confidence is low, the UI can require the user to confirm the read type instead of silently inferring one.

## Option Harmonization

### Core Principle

The design should normalize labels, placement, and readiness behavior where concepts genuinely overlap. It must not invent false equivalence between assemblers that expose different models.

### Layered Option Model

The assembly pane should expose options in three layers:

1. Shared controls
2. Capability-scoped controls
3. Tool-specific advanced controls

### Shared Controls

These should feel stable across assemblers:

- `Assembler`
- `Read Type`
- `Project Name`
- `Threads`
- `Output Location`

### Capability-Scoped Controls

These should appear only when supported by the selected tool, but retain shared names and placement:

- `Memory Limit`
- `Minimum Contig Length`
- `Assembly Mode` or `Profile`
- `K-mer Strategy`
- `Error Correction` or `Polishing`

### Tool-Specific Advanced Controls

Tool-native details should remain available but move behind advanced disclosures. Examples:

- `SPAdes`
  - mode
  - custom k-mers
  - careful
  - coverage cutoff
- `MEGAHIT`
  - preset
  - k-list
  - pruning and simplification knobs
- `SKESA`
  - its smaller native parameter surface
- `Flye`
  - genome size
  - long-read mode toggles such as meta or plasmid when supported
  - polishing-style controls that belong to Flye itself
- `Hifiasm`
  - HiFi-specific advanced toggles that make sense for standalone HiFi assembly

### Required Investigation Deliverable

Before implementation details are finalized, the work should produce an explicit option inventory across the five assemblers. That inventory should map:

- common user-facing concept
- assembler-native flag or parameter
- whether the concept belongs in:
  - shared controls
  - capability-scoped controls
  - advanced controls
- whether the parameter is safe for v1 exposure
- what validation or guardrails apply

This inventory is required because the user approved a harmonized option model only if it is grounded in each assembler's real parameter surface.

## Visual And Status Language

### Established Palette Only

Compatibility strips, readiness states, and related warning messages must use the existing Lungfish palette semantics rather than introducing ad hoc colors.

Use the established tokens already present in the app:

- neutral and helper text:
  - `Color.lungfishSecondaryText`
- blocked or attention text:
  - `Color.lungfishOrangeFallback`
- optional filled backgrounds for attention and success states:
  - `Color.lungfishAttentionFill`
  - `Color.lungfishSuccessFill`
- standard surface and stroke colors:
  - `Color.lungfishCardBackground`
  - `Color.lungfishStroke`

### Compatibility Strip Behavior

The shared assembly pane should show a compatibility strip near the top of the main pane:

- `Supported for selected inputs`
- `Unavailable for selected inputs`

The strip should explain the reason in one plain sentence, for example:

- `Flye is for ONT reads. Select ONT reads or choose a short-read assembler.`
- `Hifiasm in v1 is restricted to PacBio HiFi inputs.`
- `Hybrid assembly is not supported in v1.`

The strip should visually match the rest of the application's status language instead of looking like a custom warning banner from a different subsystem.

## Plugin Pack Design

### Built-In Pack

Add or convert the built-in `assembly` pack into an active optional pack backed by explicit tool requirements rather than only a loose package name list.

The pack should include per-tool metadata similar to the current `metagenomics` pack:

- environment name
- pinned install package string
- expected executable names
- smoke test
- version
- license
- source URL

### Pack Contents

The pack should define one requirement per assembler:

- `spades`
- `megahit`
- `skesa`
- `flye`
- `hifiasm`

### Smoke Tests

Each requirement should include a lightweight smoke test appropriate to the tool, such as:

- `--help`
- `--version`

The smoke tests should confirm that the installed executable is runnable on the host and not merely that the environment exists.

### CLI And UI Visibility

The assembly pack should be visible through the same status and install surfaces used for other managed tool packs, including:

- plugin-pack status queries
- CLI pack management
- FASTQ category gating

## Execution Model

### Micromamba As The Primary Path

The v1 assembly feature should execute from managed micromamba environments, not from Apple Container images.

This is important both for architectural consistency with managed tool packs and because the current SPAdes Apple Container entitlement regression should not remain on the critical path for assembly usability.

### Assembly Command Refactor

`AssembleCommand` should evolve from a SPAdes-only command into an assembler-aware entry point that can dispatch to the correct managed tool for the selected configuration.

This does not require a giant one-shot CLI rewrite, but it does require a new execution contract that can carry:

- selected assembler
- selected read type
- normalized shared options
- tool-specific advanced options

### App Execution Bridge

The FASTQ operation execution layer should stop treating `assemble` as a thin SPAdes alias and instead route through the normalized assembly request.

Grouped-result and per-input behavior should continue to use the existing operation-dialog execution pattern where possible.

## Result Model

### Assembler-Neutral Result Shape

The assembly result ingestion path should converge on either:

- an assembler-neutral assembly result model
- or a compatibility wrapper around the current SPAdes result model

The important requirement is that Lungfish should be able to display outputs from all five v1 assemblers without pretending their artifact sets are identical.

### Required Output Expectations

The viewer and importer should standardize around the artifacts Lungfish actually needs:

- main contig FASTA
- optional scaffold FASTA
- optional graph output
- primary log
- tool version
- command line or normalized provenance
- basic assembly statistics where derivable

Tool-specific extras can be preserved as side artifacts without forcing every assembler into a SPAdes-only schema.

## Validation Rules

### Blocking Rules

The run should be blocked when:

- no input FASTQ datasets are selected
- output location is unavailable
- no assembler is selected
- the selected assembler is incompatible with the selected read type
- the selected inputs imply mixed read classes
- required shared parameters are missing
- tool-specific advanced parameters fail validation

### Readiness Messaging

The readiness footer should remain short and operational:

- explain what is missing
- explain why the tool is blocked
- avoid hidden inference where possible

### No Soft Failure For Known Bad Fits

The UI should not allow combinations that are already known to be inappropriate for v1. Known bad fits belong in the compatibility model, not in post-launch error handling.

## Testing Expectations

The implementation plan should include tests for:

- plugin-pack registry entries and pinned metadata
- plugin-pack status evaluation and smoke-test behavior
- FASTQ assembly category tool list and default behavior
- read-type compatibility gating
- mixed-input blocking behavior
- common option to tool-native option mapping
- advanced disclosure visibility per assembler
- CLI invocation building for each supported assembler
- result ingestion for each assembler's primary outputs

Tests should emphasize behavior and routing, not only static snapshots.

## Implementation Boundary

### In Scope

- activate and define the `assembly` micromamba pack
- add the five approved assemblers
- expose the five tools in the FASTQ `ASSEMBLY` category
- replace the SPAdes-only assembly sheet with a shared assembly pane
- add read-type-aware compatibility gating
- define and implement the common option model
- expose advanced assembler-specific controls through disclosures
- route assembly execution through managed micromamba environments
- support result ingestion for the five approved assemblers

### Out Of Scope

- hybrid assembly
- mixed read-class runs
- `QUAST`
- `Unicycler`
- polishing-only workflows
- scaffolding-only workflows
- Hifiasm trio or Hi-C flows
- assembly benchmarking dashboards
- unrelated FASTQ category refactors beyond what is needed for the assembly surface

## Open Follow-On Work

Likely follow-on areas after v1:

- hybrid assembly support
- assembly QC and benchmarking tools
- explicit polishing and post-assembly finishing workflows
- richer assembly graph inspection
- broader long-read and metagenome assembly surfaces

Those should build on the v1 pack and shared assembly request model rather than bypassing it.

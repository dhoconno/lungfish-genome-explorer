# macOS Tool and Plugin Hardening Design

## Context

A release build installed on another Mac completed first launch and plugin installation, but the app then reported some installed tools as needing reinstall and blocked ONT read mapping. The shared project at `/Users/dho/Downloads/SIV_10x_test.lungfish` shows an ONT import whose provenance recorded Oxford Nanopore while the FASTQ sidecar lacked both `sequencingPlatform` and `assemblyReadType`. Its FASTQ header is generic, so downstream header sniffing cannot recover the user's import choice.

## Goals

- Treat successful managed-tool installs as ready when executables are present and smoke-test failures are transient.
- Persist user-confirmed FASTQ platform/read-type choices into portable sidecars during local and ENA/SRA imports.
- Make mapping use the same persisted metadata fallback as assembly read-type detection.
- Auto-select compatible mapping presets, especially minimap2 `map-ont` for ONT reads.
- Prevent stale embedded wizard readiness callbacks from changing the currently selected operation's Run state.
- Gate embedded assembly runs on managed pack readiness instead of failing after Run.
- Notify already-open views after first-launch managed resource installation.

## Non-Goals

- Do not add new plugin systems or new mapper/assembler support.
- Do not change the FASTQ bundle format beyond existing sidecar fields.
- Do not remove smoke tests; make them less brittle and more deterministic.

## Design

FASTQ import writes `sequencingPlatform` for the confirmed workflow platform and writes `assemblyReadType` when the platform maps safely to v1 assembly classes. ONT maps to `ontReads`; Illumina maps to `illuminaShortReads`; PacBio remains explicit-only for assembly because generic PacBio is not always HiFi/CCS.

Mapping read-class detection loads `assemblyReadType` first, then sniffs the FASTQ header, then falls back to `sequencingPlatform`. Mapping input inspection calls this metadata-aware detector on the user-selected bundle/file, so project transfers across Macs retain the import choice. `MappingMode` exposes a preferred-mode helper so UI and tests can keep minimap2 ONT inputs on `map-ont`.

Plugin pack smoke tests retry short transient failures before surfacing a reinstall state. After an install, the status service invalidates snapshots, recomputes the installed pack status, and caches that fresh result. The Plugin Manager awaits this refreshed status before clearing install state, and Welcome posts `managedResourcesDidChange` after first-launch install success.

Embedded operation readiness is scoped to the tool that created the callback. A delayed assembly callback cannot mark minimap2 ready or not-ready after the user switches tools. Assembly's `canRun` includes the compatibility presentation's managed-tool readiness.

## Acceptance Criteria

- A fake snakemake/bcftools first smoke failure followed by success yields immediate Ready status without app restart.
- Local FASTQ import and ENA/SRA import sidecars preserve ONT as `sequencingPlatform: oxfordNanopore` and `assemblyReadType: ontReads`.
- Mapping inspection classifies generic-header ONT bundles from sidecar metadata.
- minimap2 selects Oxford Nanopore mode automatically for detected ONT reads.
- Stale embedded callbacks for another tool do not alter the active tool's readiness.
- Assembly Run stays disabled when the selected assembler is not ready.

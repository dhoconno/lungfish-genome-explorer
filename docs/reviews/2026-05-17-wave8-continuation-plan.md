# Wave 8 Continuation Plan

Date: 2026-05-17
Branch: `codex/wave8-continuation`
Base: Wave 7 continuation commit `64e81f84`

## Triage Result

Independent triage found that the Wave 7 scientific provenance blockers are now addressed:

- managed assembly materializes derived virtual FASTQ inputs before execution
- FASTQ derivatives, merge flows, ONT import, GUI-imported CLI outputs, metagenomics batches, and NVD import write canonical durable provenance
- Core no longer imports AppKit/SwiftUI, and the CLI no longer imports LungfishApp
- GenBank and Kraken2 URL parsing now stream instead of reading whole files
- production AppKit `runModal()` calls are gone

The remaining actionable queue is quality and polish work rather than a new scientific-provenance blocker.

## Wave 8 Scope

1. Finish residual CLI exit-code classification in scientific/import/packaging commands.
   - Replace generic `ExitCode.failure` with `CLIExitCode` categories.
   - Add cheap subprocess regressions for the changed paths.

2. Remove dead/deprecated architectural surface that is now confirmed unused.
   - Delete unused dead protocols and legacy helpers.
   - Remove remaining explicit `wantsLayer = true` assignments where layer-backed drawing is already implied.

3. Clean up BigBed/BigWig detection-only surface.
   - Keep format detection.
   - Remove parser-shaped public marker API that implies supported reading.
   - Keep managed UCSC `bedGraphToBigWig` provenance/tool references where still required for bedGraph signal conversion.

4. Replace high-value brittle source-string tests with behavior/state/routing tests.
   - Keep only true static policy guards where no runtime seam exists.

5. Apply small runtime polish with low blast radius.
   - Menu naming and status/action behavior where runtime review identified visible drift.
   - Add or update focused tests where an existing seam already exists.

## Verification

Required before completion:

- focused tests owned by each worker
- `swift test --build-path /Users/dho/Documents/lungfish-genome-explorer/.build --disable-index-store -Xswiftc -gnone`
- debug app build for local review

## Deferred Follow-Up

The AppDelegate and large viewer/controller file-size issues remain real but should continue as separate, narrow extraction slices. This wave will not perform a broad AppDelegate rewrite because provenance-sensitive launch/import behavior is now passing and a large split would add risk without a focused behavior target.

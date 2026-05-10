# Hifiasm Profiles and Empty Assembly Outcome Design

Date: 2026-04-21
Status: Draft for review

## Summary

This design adds curated `Hifiasm` profiles to the shared assembly wizard and changes assembly result handling so runs that exit successfully but produce zero contigs are treated as successful assembly analyses with a distinct `no contigs generated` outcome instead of as failures.

The `Hifiasm` surface keeps a single tool entry. The selected read type still controls ONT versus HiFi mode, while the selected profile controls curated tuning. `Diploid` remains the default profile. `Haploid/Viral` becomes an alternate profile for both ONT and PacBio HiFi/CCS runs and maps to the curated upstream flags `--n-hap 1 -l0 -f0`.

For assembly outcomes, the app should distinguish:

- assembler/tool execution failed
- assembler completed and produced contigs
- assembler completed but produced no contigs

That third case is assembly-specific successful completion with an informational warning, not an operation failure.

## Goals

- Add explicit `Hifiasm` profile choices to the existing assembly wizard.
- Keep `Diploid` as the default `Hifiasm` profile.
- Make `Haploid/Viral` available for both ONT and PacBio HiFi/CCS `Hifiasm` runs.
- Preserve the existing `--ont` behavior for ONT input and keep read type authoritative.
- Keep `Primary contigs only` as a separate toggle rather than folding it into the curated profiles.
- Rewire all assembly flows so zero-contig runs are recorded and displayed as completed analyses with no contigs generated.

## Non-Goals

- No new assembler entry such as `Hifiasm (ONT)` or `Hifiasm (Haploid)`.
- No new assembly viewport family or inspector family.
- No guarantee that the new `Haploid/Viral` preset will make every ONT dataset assemble successfully under `Hifiasm`.
- No broad app-wide redefinition of success/failure semantics for non-assembly workflows.
- No expansion of `Hifiasm` tuning beyond the curated `Haploid/Viral` preset in this pass.

## Current Gaps

### Hifiasm Profiles

The current assembly wizard has no curated `Hifiasm` profile options:

- `AssemblyWizardSheet.profileOptions` returns no entries for `Hifiasm`
- `AssemblyWizardSheet.defaultProfileID(for:)` returns `nil` for `Hifiasm`
- `AssemblyWizardSheet.curatedAdvancedArguments` only adds `--primary` for the `Primary contigs only` toggle

That means Lungfish can expose ONT-capable `Hifiasm`, but users have no guided way to request the common small-genome or haploid-oriented argument set we want to support.

### Empty Assembly Results

The current managed assembly normalizer treats zero-contig outputs as errors:

- `AssemblyOutputNormalizer` throws `emptyPrimaryOutput`
- CLI assembly runs surface that as a hard failure
- app operation surfaces report it as an operation failure

That behavior is too strict. An assembler that exits normally but yields no contigs did run. The right user-facing message is that the assembly completed without generating contigs, with logs and artifacts preserved for inspection.

## Design

### 1. Hifiasm Profile Model

`Hifiasm` should participate in the existing curated `Profile` picker in `AssemblyWizardSheet`.

The picker should expose two profiles:

- `Diploid`
- `Haploid/Viral`

`Diploid` is the default for `Hifiasm` regardless of whether the confirmed read type is ONT or PacBio HiFi/CCS.

The selected profile is independent of read type:

- ONT + `Diploid` is valid
- ONT + `Haploid/Viral` is valid
- HiFi + `Diploid` is valid
- HiFi + `Haploid/Viral` is valid

Switching between ONT and HiFi must not silently replace the selected `Hifiasm` profile unless the current profile becomes invalid, which should not happen in this design because both profiles are legal for both long-read classes.

### 2. Hifiasm Command Construction

`ManagedAssemblyPipeline.buildHifiasmCommand(for:)` remains the single place where `Hifiasm` runtime mode is assembled.

Command behavior should separate read-type mode from profile mode:

- ONT input adds `--ont`
- PacBio HiFi/CCS input does not add `--ont`
- `Diploid` adds no extra curated `Hifiasm` arguments
- `Haploid/Viral` adds `--n-hap 1 -l0 -f0`

The existing `Primary contigs only` toggle remains separate and continues to append `--primary` through the existing curated-arguments path.

That means a valid ONT haploid-style command becomes conceptually:

```bash
hifiasm --ont -o <prefix> -t <threads> --n-hap 1 -l0 -f0 [--primary?] <reads.fastq.gz>
```

while a HiFi diploid-style command remains the current baseline:

```bash
hifiasm -o <prefix> -t <threads> [--primary?] <reads.fastq.gz>
```

### 3. Provenance and Stored Settings

The chosen `Hifiasm` profile should continue to travel through `AssemblyRunRequest.selectedProfileID` so the selection is preserved in:

- runtime requests
- saved assembly sidecars
- provenance or manifest parameters
- later inspector display

The important invariant is that user-facing reporting must preserve both:

- the confirmed read type actually used for the run
- the curated profile actually chosen for the run

`Haploid/Viral` must therefore appear as a real selected profile in saved metadata, not as an implicit guess reconstructed from raw extra arguments.

### 4. Empty-Contig Assembly Outcome

Assembly execution should gain a distinct successful outcome for `assembler exited normally but generated zero contigs`.

This is a semantic third outcome for assembly runs, but it does not need to force a broad app-wide change to generic analysis success/failure plumbing. The recommended representation is:

- generic analysis status remains successful or `completed`
- assembly-specific persisted metadata records a `noContigsGenerated` outcome
- operation and viewer surfaces render that successful-warning outcome explicitly for assembly analyses

In practical terms:

- a nonzero assembler exit code is still a true failure
- a zero exit code plus zero contigs is not a failure
- a zero exit code plus one or more contigs is the normal successful case

### 5. CLI Behavior for Empty-Contig Runs

`lungfish-cli assemble` should exit successfully when the assembler completed but produced no contigs.

The CLI should:

- keep the output directory and logs
- write the persisted assembly result metadata needed for later inspection
- print a result summary that clearly says the assembly completed without generating contigs
- avoid printing the current success-style contig statistics block as though a normal assembly was produced

Representative success copy:

`Assembly completed, but no contigs were generated.`

This preserves scriptability. A caller can distinguish:

- failure by nonzero exit status
- no-contig completion by zero exit status plus clear message and persisted metadata

### 6. App Behavior for Empty-Contig Runs

The app should persist and present zero-contig assembly runs as completed analyses.

Expected behavior:

- the run appears in the project analysis list
- the analysis opens normally
- the right-sidebar `Document` inspector still shows assembly context and source artifacts
- the viewport shows the normal assembly shell with an empty-results state instead of a failure screen
- the empty-results state explains that the assembler completed without generating contigs and points the user to logs and source artifacts
- the operations panel and bottom-drawer surfaces use informational warning copy rather than `Operation Failure Report`

The empty viewport should not pretend there are contigs to browse. It should show a clear empty table or placeholder state with direct access to the log and any relevant generated artifacts.

### 7. Stored Result Shape for Empty Assemblies

The recommended implementation direction is to allow persisted managed assembly results to represent zero contigs directly rather than throwing during normalization.

That means the normalized assembly result path should be able to save:

- the selected tool
- the selected read type
- output directory
- log path
- graph path when one exists
- empty contig FASTA path when the assembler created one
- statistics with `contigCount == 0`
- an explicit assembly outcome marker indicating `no contigs generated`

If a FASTA index is only meaningful for non-empty FASTA, index creation should be skipped for the zero-contig case rather than turning the run back into an error.

### 8. User-Facing Copy

Assembly wording should distinguish verification failure from empty output.

Preferred copy family:

- `Assembly completed successfully.` for normal contig-producing runs
- `Assembly completed, but no contigs were generated.` for empty-contig runs
- `Assembly failed.` only for real tool or pipeline failures

Any existing red error banners, failure modals, or operation-report titles triggered only by zero contigs should be replaced with the completed-with-warning wording.

## Testing

### Hifiasm Profile Coverage

Add command-builder tests that prove:

- `Hifiasm + ONT + Diploid` emits `--ont` and does not emit the haploid flags
- `Hifiasm + ONT + Haploid/Viral` emits `--ont --n-hap 1 -l0 -f0`
- `Hifiasm + HiFi + Diploid` omits `--ont` and omits the haploid flags
- `Hifiasm + HiFi + Haploid/Viral` omits `--ont` and emits `--n-hap 1 -l0 -f0`
- `--primary` remains additive and independent of profile selection

### Wizard and State Coverage

Add UI-state coverage that proves:

- `Hifiasm` now exposes `Diploid` and `Haploid/Viral` in the profile picker
- `Diploid` is the default `Hifiasm` profile
- changing between ONT and HiFi while `Hifiasm` is selected does not silently reset the chosen profile
- ONT datasets continue to show both `Flye` and `Hifiasm` as runnable

### Empty-Assembly Coverage

Add assembly outcome tests that prove:

- zero-contig outputs from any assembler are not surfaced as execution failures
- persisted assembly metadata can represent the empty-contig outcome
- CLI empty-contig runs exit successfully and print the completed-without-contigs message
- app operation summaries and assembly analysis manifests record the run as completed, with detail that no contigs were generated
- the assembly viewer shows the empty-results state instead of a failure state

## Risks and Tradeoffs

- The `Haploid/Viral` preset is intentionally curated and narrow. Some datasets may still need more aggressive tuning, but that should be a later expansion rather than part of this pass.
- Treating empty-contig output as successful means downstream surfaces must not assume `completed` implies `contigCount > 0`. The empty state needs to be explicit anywhere assembly results are opened.
- Keeping the generic analysis status as `completed` reduces scope and compatibility risk, but it means assembly-aware surfaces must consult the assembly outcome metadata when they want to render the warning state.

## Recommendation

Implement this as one assembly-focused design change:

1. Add `Diploid` and `Haploid/Viral` as real curated `Hifiasm` profiles, with `Diploid` as default.
2. Map `Haploid/Viral` to `--n-hap 1 -l0 -f0`, while keeping read type responsible for whether `--ont` is present.
3. Preserve `Primary contigs only` as an independent toggle.
4. Reclassify zero-contig assembly runs from failure to `completed with no contigs`, persist that outcome in assembly metadata, and render it consistently across CLI, operations, analysis history, inspector, and viewport surfaces.

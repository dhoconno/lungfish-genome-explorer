# MHC Current Excel Haplotype Decoration Design

Date: 2026-06-03

## Summary

MHC amplicon genotyping currently creates a primary Excel workbook and then copies that workbook byte-for-byte to `artifacts/workbooks/current.xlsx`. That is correct when no haplotyping is performed: the naked generated workbook is the only meaningful workbook artifact. When haplotyping is performed, however, the `.lungfishgenotype` bundle already has enough haplotype analysis data to show MCM haplotypes in the native viewport, and the current workbook should communicate the same haplotype assignments in a client-ready Excel report.

The workflow should keep two workbook artifacts:

- The primary workbook remains the raw/generated report artifact referenced by `primaryWorkbookPath`.
- The current workbook is the editable/shareable report artifact referenced by `currentWorkbookPath`.

For MCM haplotyped runs, the current workbook should be generated in the same client-facing worksheet shape as the supplied final report:

1. `Interpretation Guide`
2. `MHC Alleles Per MHC Haplotype`
3. `Abbreviated Haplotypes`
4. `Full Sequencing Results 1`
5. `Custom Sort`

The attached client workbook is a visual and structural contract, not a repo asset. It contains real client/sample content and must not be embedded as a runtime template.

## Goals

- Preserve the existing no-haplotyping behavior: `current.xlsx` is a copy of the primary workbook.
- For MCM haplotyped runs, create a decorated `current.xlsx` that shows haplotype assignments and M1-M7 color cues.
- Reuse existing Lungfish MCM/Budde 2010 color semantics from `HaplotypeColorToken`.
- Keep the native viewport and workbook driven by the same `GenotypeHaplotypeAnalysis` data.
- Keep the final `.lungfishgenotype` manifest pointing at both the immutable primary workbook and the decorated current workbook.
- Preserve reproducibility provenance for the current workbook creation step, including final stored output paths, checksums, file sizes, argv/replay command, runtime identity, exit status, and wall time.
- Keep imported/revised workbook history compatible with the existing workbook revision model.

## Non-Goals

- Do not add InRh/rhesus client report layout in this change.
- Do not parse Excel workbook edits back into genotype calls.
- Do not replace canonical CSV, stats, or haplotype analysis JSON with workbook-derived data.
- Do not commit the supplied client report or any private sample content as a fixture.
- Do not make the primary workbook client-decorated; it remains the generated/original report artifact.

## Current Behavior

`ONTBarcodeDemuxGenotypingPipeline.run` writes the primary workbook through the embedded OpenPyXL report script, then calls `createInitialCurrentWorkbookCopy(for:)`. That helper copies `request.workbookURL` to:

```text
artifacts/workbooks/current.xlsx
```

The manifest records:

```swift
primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL)
currentWorkbookPath: relativePath(from: request.outputDirectory, to: request.currentWorkbookURL)
```

Existing tests assert that non-haplotyped runs keep the primary/current workbook bytes identical. That assertion should remain true for runs without `haplotypeAnalysis`.

The embedded report script already supports `--haplotype-analysis-json`, fills haplotype rows in generated workbooks, writes a `Haplotype Calls` sheet, and records the haplotype JSON as a provenance input. The missing behavior is that `current.xlsx` is not generated as a client-facing decorated current artifact.

## Workbook Design

### Artifact Roles

The primary workbook remains a naked generated report:

- It is written at `request.workbookURL`.
- It remains referenced by `primaryWorkbookPath`.
- It remains immutable after bundle creation.

The current workbook becomes role-dependent:

- No haplotyping: copy the primary workbook byte-for-byte to `artifacts/workbooks/current.xlsx`.
- MCM haplotyping: generate a decorated client-facing workbook at `artifacts/workbooks/current.xlsx`.

The pipeline result and UI should continue to open/share `result.workbookURL`, which is already the current workbook path.

### MCM Decorated Workbook Shape

The decorated current workbook should have these worksheets, in this order:

1. `Interpretation Guide`
   - A static, non-private guide explaining how to read the report, including the meaning of M1-M7 haplotype colors, `?`, `-`, and error/comment cells.
   - This sheet should not include private examples from the supplied workbook.

2. `MHC Alleles Per MHC Haplotype`
   - A generated lookup sheet derived from the active MCM haplotype definition set.
   - Columns represent M1-M7 families.
   - Rows are grouped by source locus when possible.
   - Haplotype family columns use the canonical M1-M7 fills from `HaplotypeColorToken`.

3. `Abbreviated Haplotypes`
   - One row per sample.
   - Columns include client/sample ID, mapped read count, abbreviated Haplotype 1/2, per-locus haplotype slots, and comments.
   - Haplotype cells use the existing M1-M7 color scheme by assigning the style from the called haplotype name.

4. `Full Sequencing Results 1`
   - A sample-column matrix similar to the existing report output.
   - Rows 1-20 carry sample metadata, mapped reads, MHC haplotype slot calls, and comments.
   - Remaining rows carry observed genotype/read-count data.
   - Freeze panes should keep the first three columns and top haplotype/summary rows visible.
   - Haplotype call cells use M1-M7 styles.
   - Error/no-call values use the existing danger/error styling.

5. `Custom Sort`
   - A client-ready per-sample table sorted/grouped by MCM haplotype pair.
   - Include homozygous samples first, then heterozygous samples grouped by normalized Haplotype 1/2 family.
   - Include comments for non-called loci and error statuses.
   - Haplotype cells use the same M1-M7 styles as the other sheets.

The workbook can use direct cell styles rather than Excel conditional formatting for the generated haplotype cells. Direct styles are easier to verify, deterministic, and do not require preserving client-specific conditional formatting ranges from the supplied workbook.

### Haplotype Mapping Rules

For each `GenotypeHaplotypeSampleAnalysis`:

- Use `haplotype1` and `haplotype2` from each per-locus call.
- Treat `-` and empty strings as absent.
- Treat strings beginning with `ERR:` as error cells and include concise comments.
- Map MCM names such as `M1A`, `M2B`, `M3DR`, `M4DQ`, and `M5DP` to M1-M7 using `HaplotypeColorToken.assigned(forName:)`.
- Build abbreviated whole-animal haplotypes from the called M family where every analyzed locus supports the same family.
- Use recombinant labels such as `recM2M1` when per-locus families are mixed within a haplotype slot.
- Use `?` when a slot cannot be summarized because required calls are missing or errored.

The initial MCM scope should support the existing analyzed loci present in the active definition set. If a definition uses separate `MHC-DQA`, `MHC-DQB`, `MHC-DPA`, and `MHC-DPB` loci, the report should render those labels. If future MCM definitions use combined DQ/DP labels, the generator can render those labels without changing the workbook contract.

## Implementation Approach

Add a focused decorated current workbook generation path to the existing OpenPyXL report script embedded in `ONTBarcodeDemuxGenotypingPipeline.swift`.

The pipeline should replace `createInitialCurrentWorkbookCopy(for:)` with a role-aware helper:

```swift
createInitialCurrentWorkbook(
    for request: ONTBarcodeDemuxGenotypingRunRequest,
    haplotypeAnalysis: GenotypeHaplotypeAnalysis?
) throws -> WorkbookCopyResult
```

Behavior:

- If `haplotypeAnalysis == nil`, keep the existing byte-for-byte copy.
- If `haplotypeAnalysis != nil` and the active haplotype definition is MCM, generate the decorated current workbook.
- If `haplotypeAnalysis != nil` but the species is not MCM, keep the existing copy and defer InRh/rhesus decoration to a separate scoped design.

The embedded report script already receives `--haplotype-analysis-json` for primary workbook creation. It should gain an explicit current-workbook mode or helper that can write the five-sheet decorated workbook at `request.currentWorkbookURL` using the same CSV, stats, reference, and haplotype JSON inputs. The Swift pipeline should record that step in the main provenance as the creation of the `current-report` output.

No temporary staging path should be recorded as the final output. Provenance and manifest fields must point at `artifacts/workbooks/current.xlsx`.

## Error Handling

- If decorated current workbook generation fails, the workflow fails before writing the final manifest.
- The pipeline should not silently fall back to an undecorated current workbook for MCM haplotyped runs.
- The primary workbook may exist on disk after failure for diagnostics, but the final manifest should not be written unless the whole workflow succeeds.
- Workbook validation should keep using OpenXML-compatible `.xlsx` output written by OpenPyXL.

## Provenance

The existing workflow provenance must continue to satisfy the Lungfish provenance requirements.

For the current workbook step, record:

- tool/workflow name and Lungfish version;
- exact argv or reproducible command, including current workbook output path;
- explicit options and resolved defaults;
- input paths for CSV summaries, stats JSON, reference FASTA, barcode definitions, primary workbook, haplotype analysis JSON, and haplotype definition snapshot when present;
- output path for `artifacts/workbooks/current.xlsx`;
- SHA-256 checksums and file sizes;
- OpenPyXL/Python/conda/runtime identity;
- exit status, wall time, and useful stderr.

The workbook revision entry for the initial current workbook should keep role `.initialCurrentCopy` for compatibility, but its label should distinguish the decorated MCM case, for example `Initial decorated MCM current workbook`.

## Tests

Add or update workflow tests around `ONTBarcodeDemuxGenotypingPipeline` and the embedded report script:

- Non-haplotyped run still creates `current.xlsx` as a byte-for-byte copy of the primary workbook.
- MCM haplotyped run creates `current.xlsx` with the five expected worksheet names.
- MCM haplotyped current workbook contains MHC-A haplotype values in `Full Sequencing Results 1`.
- MCM haplotyped current workbook contains matching rows in `Abbreviated Haplotypes` and `Custom Sort`.
- M1-M7 style fills appear in the decorated current workbook for called haplotypes.
- The manifest still records `primaryWorkbookPath`, `currentWorkbookPath`, and the workbook revision checksum/size for the actual current workbook.
- The canonical workflow provenance includes the decorated `current-report` output path and haplotype analysis input.

Use synthetic CSV/JSON/reference fixtures generated inside tests. Do not use the supplied client report as a committed fixture.

## Rollout

This change is backward-compatible for existing bundles and no-haplotyping runs. New MCM haplotyped runs receive a decorated current workbook automatically. Existing workbook import/restore flows continue to operate on `currentWorkbookPath` and should not need new UI concepts.

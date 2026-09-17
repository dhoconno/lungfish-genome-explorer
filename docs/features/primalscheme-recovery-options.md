# PrimalScheme recovery options

PrimalScheme's Advanced settings expose two opt-in recovery workflows for combined panels. Ordinary independent and combined designs retain their existing defaults.

## Runtime

Select a local PrimalScheme3-LGE executable supporting the recovery options. The adapter checks its version, capability evidence, and required command options. The currently managed runtime predates recovery support; these controls do not install or publish a new runtime. Clear the executable selection to return to the managed runtime for ordinary design.

## Bounded dimer salvage

This creates the strict legacy panel first, then considers additional pairs at progressively more permissive dimer scores. Advanced controls specify the score sequence and floor, limits on relaxed interactions and affected primers in each pool, minimum added reference coverage, and maximum candidate evaluations.

Use uniform position weighting and leave both amplicon-count limits blank for recovery modes.

The interaction limits are heuristics, not experimentally established thresholds for PCR success. In the evaluated A1/A2 fixture, this mode added no amplicons under its default limits.

## Independent follow-up scheme

Choose a parent native PrimalScheme output directory or a saved `.lungfishprimeranalysis` containing one native result. For an analysis with multiple results, select the desired native result directory explicitly. Select the same source MSAs used for that result. Saved LGE inputs are checked against the parent source sequences, including non-reference alleles, and their consumed identifiers and normalization are restored. An input file can be renamed without changing its sequence identity.

Follow-up pools are **separate PCR reactions**. They are not added to the parent's pools. The pool-count field controls the follow-up scheme. This mode requires combined, equal-weight legacy panel selection and the legacy alignment-end policy; it cannot be combined with dimer salvage.

Enable additional candidate generation for uncovered regions to consider bounded alternatives. Defaults are 2,000 anchors and 1,000 pair checks per MSA. A larger search can change the selected scheme without improving coverage, so these are controls rather than promises about output quality.

The saved result contains the follow-up primers, a parent snapshot, native coverage reports describing primary/follow-up/combined reference coverage, and provenance mapping execution artifacts to their final bundle locations. The standard primer list and ordering sheet describe the follow-up reactions only.

The evaluated A1/A2 fixture improved combined primer-trimmed reference coverage from 74.27%/74.33% with the original follow-up candidates to 81.29%/75.86% with bounded candidate expansion. These are computational design coverage figures, not measured amplification outcomes.

## GUI integration verification (2026-09-17)

The development build passed 61 selected tests: 29 existing pipeline regression tests, 10 recovery option/contract/native tests, 21 dialog-state tests, and one visual test. Both native tests executed against source commit `abc3e85f4b321991abeb75fe5b260fcb34e2510b` (PrimalScheme3-LGE `3.3.0+lge.4`). The follow-up test creates a normal LGE parent analysis, reuses its two-row MSA from a renamed file, requests three follow-up pools, and checks parent immutability and published reports/provenance. The salvage smoke test also executes the real native tool. No selected tests were skipped.

Run with `LUNGFISH_REAL_GAP_EXECUTABLE` pointing to that native executable and `LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR` pointing to an output directory:

```sh
swift test --skip-update --filter 'LungfishWorkflowTests.(PrimalScheme3Recovery|PrimalScheme3DesignPipelineTests)|LungfishAppTests.PrimerDesignDialog(State|Visual)Tests'
```

The managed runtime and installed application were not updated as part of this development change.

# Genotype Matrix Review Annotations Verification

Date: 2026-07-24  
Branch: `codex/genotype-matrix-review-annotations`  
Verified HEAD: `1f2980eea2f5da164d617aca121a282972154ecd`  
Host: macOS 26.5.2, arm64  
Status: **acceptance complete**

The focused feature suites, deterministic structural checks, representative benchmark,
retained scientific-artifact inspections, repository hygiene checks, and complete package
regression suite passed. The retained provenance names final stored payloads and records the
workflow identity, exact reproducible command, structured options and defaults, runtimes,
checksums, sizes, status, and truthful elapsed times.

## Test Results

All focused suites were run sequentially with
`swift test --skip-update --filter <suite>`.

| Suite | Passed | Failed |
| --- | ---: | ---: |
| `GenotypeAnnotationSidecarTests` | 17 | 0 |
| `GenotypeMatrixReviewCapabilityTests` | 7 | 0 |
| `GenotypeAnnotationStoreTests` | 45 | 0 |
| `GenotypeResultViewportTests` | 258 | 0 |
| `GenotypeResultDisplaySectionTests` | 38 | 0 |
| `AppSettingsTests` | 20 | 0 |
| `SettingsAndImportXCUIReadinessTests` | 15 | 0 |
| `GenotypeWorkbookRevisionServiceTests` | 77 | 0 |
| `GenotypeExportSubcommandTests` | 13 | 0 |
| `GenotypeViewportExcelExportTests` | 8 | 0 |
| **Focused total** | **498** | **0** |

The complete package suite was run at the verified HEAD:

```text
swift test --skip-update
```

It passed with these final aggregates:

- XCTest: 10,860 tests executed, 31 skipped, 0 failures in 547.105 seconds
  (547.696 seconds total).
- Swift Testing: 547 tests in 68 suites passed in 119.096 seconds.
- Process exit status: `0`.
- Complete log: `/tmp/lungfish-task9-final-full-1f2980ee.log`.

## Eligibility, Atomicity, and UX

The capability and store suites passed positive-support, zero-support, absent-support,
mixed-selection, non-cell, stale-revision, read-only, replacement, clear, and
legacy-comment canonicalization assertions. The retained review mutation used:

```text
kind=cell
locus=MHC-A1
genotype=Mafa-A1*001:01
sample=Animal-1
stableClusterID=candidate-17
passedUniqueReads>0
```

It changed the disposition atomically from `null` to `falsePositive`. Persisted option
evidence recorded `targetCount=1`, `supportedCount=1`, `unsupportedCount=0`,
`eligibilityRule="passedUniqueReads > 0"`, `supportThreshold="passedUniqueReads > 0"`,
and `absentEvidence="unsupported"`. The store suite also verified that mutations publish
once, mixed or stale selections publish nothing, and review status does not alter the
underlying genotype evidence.

The viewport, display-section, settings, and XCUI-readiness suites cover row, column, and
cell command availability; inspector/menu capability parity; disabled reasons; analyst
identity routing; accessibility labels; selection behavior; keyboard/menu routes; and
semantic reload publication.

The deterministic structural checks passed:

| Structural check | Recorded result |
| --- | --- |
| Context menu inside/outside selection | Evidence-index and annotation-index build counts unchanged |
| Actual AppKit context menu | Cached immutable snapshot read once; AppKit auto-enable disabled |
| Review mutation reload | Full reload count `0`; partial reload count greater than `0`; evidence-index build count unchanged |
| Row-comment mutation reload | Pinned and sample full reload counts `0`; both tables partially reloaded |
| Inspector/menu shared capability | Same capability snapshot; evidence-index and annotation-index build counts unchanged |
| Multi-cell semantic publication | Exactly two requested cell reloads; full reload `0`; partial reload count `2`; reloaded cell count `2` |
| Workbook update coalescing | Two successful annotation commands; zero immediate updates; one delayed update after scheduler fire |

The menu-I/O assertion is structural: the production menu builder accepts only an
immutable cached value snapshot, and the `NSMenu` test observes one cached snapshot read.
This fixture does not contain a separate filesystem-syscall counter.

## Current Workbook Artifact and Provenance

The final retained evidence test passed 1/1 in 1.344 seconds:

```text
LUNGFISH_TASK9_RETAIN_EVIDENCE=1 swift test --skip-update \
  --filter GenotypeWorkbookRevisionServiceTests.testApplyHaplotypeOverridesProvenanceNamesFinalStoredSidecarAndWorkbook
```

Retained root:

```text
/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/GenotypeWorkbookRevisionServiceTests-FE5E7183-150E-4BDB-B898-07931F9A7140
```

The source sidecar contains the exact review:

```text
target: cell MHC-A / Mamu-I*collision / Sample-FP / cluster-a
disposition: falsePositive
author: reviewer
timestamp: 2026-07-24T10:00:00Z
```

The workbook contains `Interpretation Guide`, `matrix`, `Overrides`, `Audit Log`,
`Matrix Annotations`, and hidden `_LGE Matrix Review State` worksheets. The target
resolves to `matrix!D7`; its value remains `[42]` and its font is italic gray `#767676`.
The audit record is:

```text
action=validateMatrixReview
target=cell MHC-A / Mamu-I*collision / Sample-FP / cluster-a
before=null
after=falsePositive
author=reviewer
timestamp=2026-07-24T10:00:00Z
validationStatus=valid
```

| Role | Exact path | Size | SHA-256 |
| --- | --- | ---: | --- |
| Final sidecar | `/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/GenotypeWorkbookRevisionServiceTests-FE5E7183-150E-4BDB-B898-07931F9A7140/semantic-provenance.lungfishgenotype/annotations.json` | 1,878 B | `7f3d6cfae381ac50f09fc98f969a3b424e639e404bf814dde99bb781a165b906` |
| Final current workbook | `/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/GenotypeWorkbookRevisionServiceTests-FE5E7183-150E-4BDB-B898-07931F9A7140/semantic-provenance.lungfishgenotype/artifacts/workbooks/current.xlsx` | 9,628 B | `75a059aae05f405e323f15da74ed726c2b97a62df23fbccb1be77bc523ef5b90` |
| Provenance | `/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/GenotypeWorkbookRevisionServiceTests-FE5E7183-150E-4BDB-B898-07931F9A7140/semantic-provenance.lungfishgenotype/artifacts/workbooks/provenance/1970-01-01T021640Z-update-current-workbook-8EEFC3D1.lungfish-provenance.json` | 45,908 B | `3165706192db593f2d7edb3a79af2977c0d483d511b0b21ca03a2f4c26c07564` |

The provenance records:

- Workflow `Genotype Workbook Revision`, tool `Lungfish.app`, version
  `Lungfish 16.0 (24904)`.
- Created/start/end `1970-01-01T02:16:40Z`, top-level `wallTimeSeconds=0`,
  status `completed`, exit status `0`.
- Runtime process `xctest` PID `75750`, macOS 26.5.2 arm64, user `dho`.
- Python `3.12.13`, openpyxl `3.1.5`, conda environment `openpyxl`, and the
  managed runtime prefix.
- Python and atomic-exchange step start/end times equal to the fixed test clock,
  nonnegative zero-second wall times, exit status `0`, and empty Python stderr.
- Durable Python argv pointing to the retained script and source workbook, final
  `current.xlsx`, retained haplotype calls and candidate configuration, and final
  bundle `annotations.json`.
- Explicit action, bundle, final workbook, six additional inputs, MHC counts,
  filters, tints, and alpha rule; declared defaults and resolved current-workbook
  and revision-history locations.
- A final output descriptor whose path, size, and SHA-256 match the final stored
  `current.xlsx`.

This verifies the corrected elapsed-time calculation and final-payload provenance
rehydration.

## Explicit Viewport Export Artifact and Provenance

The final retained evidence test passed 1/1 in 0.046 seconds:

```text
LUNGFISH_TASK9_RETAIN_EVIDENCE=1 swift test --skip-update \
  --filter GenotypeExportSubcommandTests.testAnnotationBearingProjectionExportEmbedsMatrixAnnotationsAndStableSidecarProvenance
```

Retained root:

```text
/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25
```

The two-row by two-sample projection (`lens=summary.matrix`,
`cellColorMode=nativeAnnotations`) produced `View` and `Matrix Annotations`
worksheets. The annotation worksheet contains eight semantic records: four styles
and four current comments, including hidden and stable-cluster-disambiguated targets.
`View!D2` contains the native note:

```text
Cell
Body: Visible cell comment.
Author: qa
Timestamp: 2026-06-30T10:02:00Z
```

Raw OOXML inspection confirmed:

```text
xl/comments1.xml                           372 B
xl/drawings/commentsDrawing1.vml        1,129 B
xl/worksheets/_rels/sheet1.xml.rels       451 B
```

The exact reproducible command is:

```text
lungfish-cli genotype export --bundle /var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/fixture.lungfishgenotype --export-format xlsx --output /var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/view.xlsx --sample S1 --sample S2 --view-projection /var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/projection.json --annotations /var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/fixture.lungfishgenotype/annotations.json --force
```

| Role | Exact path | Size | SHA-256 |
| --- | --- | ---: | --- |
| Projection input | `/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/projection.json` | 220 B | `ea441bff9ddecbede948e81f9f5cc92f0cbfa6c263b47d3daa62cc716faa5185` |
| Annotation input | `/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/fixture.lungfishgenotype/annotations.json` | 4,078 B | `926a7233794491c48d82eeee1b0290b366064a33057548a5f00a2c6b48b0c4e3` |
| Final XLSX | `/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/view.xlsx` | 6,486 B | `b7b0f1b8ab7067e418a18ad0a0369cdd394878f2bee1d5dceacc6bfc41c0f032` |
| Provenance | `/var/folders/pw/r9x37tvs2q5d6c044x2fhp200000gn/T/genotype-export-matrix-annotations-CD626EF8-6868-4B2B-A952-031A75764C25/view.xlsx.lungfish-provenance.json` | 24,137 B | `c158c3cd9adda0de74ef5d5d6e9521502961d7ebf3a6ecfb53fd3ee435b8554d` |

The provenance records workflow `lungfish genotype export`, tool `lungfish-cli`,
version `Lungfish 16.0 (24904)`, start/end `2026-07-24T18:57:39Z`, wall time
`0.01403498649597168` seconds, status `completed`, exit status `0`, and runtime
`xctest` PID `76507` on macOS 26.5.2 arm64 as user `dho`. Its final output
descriptor matches the final XLSX path, size, and checksum.

Structured explicit options include annotations, bundle, `exportFormat=xlsx`,
`force=true`, output, `outputCount=1`, samples `[S1,S2]`, and view projection.
Declared defaults include active haplotype definition, bundle annotation fallback,
`exportFormat=xlsx`, filter, `force=false`, lens, minimum reads, empty samples, and
view projection. Resolved defaults record every final value, including the exact
annotation, bundle, output, and projection paths; `force=true`; output count; and
samples. This verifies complete structured CLI option provenance as well as exact
argv reproducibility.

## Review and Comment Mutation Provenance

The retained review mutation audit records `setMatrixReview` on
`cell MHC-A1 / Mafa-A1*001:01 / Animal-1 / candidate-17`, changing `null` to
`falsePositive` as `Resolved Reviewer` at `2026-07-24T16:42:11Z`.
Its final `annotations.json` is 3,623 B with SHA-256
`c1d194c01ad72e4e65cf2382ab6ff4fb148dac8d030f8cd70ff246a323f08283`.
Its provenance is 35,460 B with SHA-256
`fa529b202a5076178f7478e8cf6d9a22c80ac9753f329aa52e2c1331589c0001`,
records wall time `0.0008840560913085938` seconds, status `completed`, exit `0`,
and preserves the immutable prior sidecar as a provenance input.

The retained comment audit records `upsertMatrixComment` on `column Animal-1`,
changing `null` to `authored at edit time` as `Resolved Analyst` at
`2026-07-24T16:42:12Z`. Its final `annotations.json` is 3,464 B with SHA-256
`c7c25f9cf96007643dff3b1f4757e195a8072a2760997637b34b2908d3262880`.
Its provenance is 31,297 B with SHA-256
`4f5fc35676a80d9824b6db66e1f66afe0fb41c0d2aaaabbc4d786f3dd7e9d799`,
records wall time `0.0011140108108520508` seconds, status `completed`, exit `0`,
and preserves the immutable prior sidecar.

Both mutation records identify the final stored `annotations.json` as output,
include the final author, target, before/after state, counts and edit mode, and
provide a reproducible `lungfish-cli genotype replay-matrix-annotation` command.
The final 45-test store suite passed after the production hardening changes.

## Performance Observations

The representative benchmark passed 1/1 in 0.137 seconds:

```text
swift test --skip-update \
  --filter GenotypeResultViewportTests.testMatrixRepresentativeBenchmarkRecordsLinearTargetsAndMenuProductObservation
```

The fixture has 40 rows by 8 samples, or 320 calls.

| Observation | Fixture size | Recorded time |
| --- | ---: | ---: |
| Small selection aggregation | 8 targets | 0.778 ms |
| Large selection aggregation | 200 targets | 0.419 ms |
| Cached menu construction | 200 targets | 0.821 ms |
| Visible redraw | 30 rows × 8 samples = 240 visible cells | 21.814 ms |
| Bulk sidecar application | 200 targets | 0.603 ms |

The 200-target cached menu observation is below the 50 ms product target. These
timings are observations; structural counter tests enforce complexity and reload
boundaries deterministically.

## Full-Suite Diagnostic History

The final complete run passed. Earlier full-suite attempts exposed unrelated or
interaction-sensitive defects that were diagnosed and corrected before final
acceptance:

1. At `d4605eb5`, the suite stopped in
   `FullLengthONTMHCCohortAlignmentBuilderTests.testPublicationLockContentionCannotOverwriteOrLoseUnrelatedArtifact`.
   `/tmp/xctest_2026-07-24_113629_SUxw.sample.txt` showed an unbounded
   `Process.waitUntilExit()`. The test passed isolated 1/1 in 0.671 seconds and
   its class passed 34/34 in 8.620 seconds. The helper was hardened.
2. At `e27ca7ed`, the suite completed but found tracked ignored task reports and a
   direct `.systemRed` palette use. Commit `199621d4` fixed repository hygiene and
   palette compliance; the 38 targeted checks passed.
3. At `199621d4`, an ONT barcode-demux fixture wedged in production process waiting.
   The test passed isolated 1/1 in 1.283 seconds. Commit `e1968a85` bounded and made
   the demux process waits cancellation-aware.
4. At `e1968a85`, a hierarchy test compared constraint object identities and a
   BBTools managed-Java fixture encountered `SIGPIPE`. Commits `e2cb4845` and
   `ee55ed65` changed the constraint assertion to semantic comparison and hardened
   the fixture.
5. At `e2cb4845`, two CLI cancellation tests exceeded a brittle 0.75-second
   threshold by approximately 8–14 ms in the full suite. Commit `1f2980ee` made
   CLI event cancellation nonblocking. Its target class then passed 3/3, and the
   final full package suite passed.

## Acceptance-Criteria Traceability

| Criterion | Evidence | Status |
| --- | --- | --- |
| Sidecar v2, exact stable identity, deterministic current comments | 17 sidecar tests | Pass |
| Evidence-gated false-positive/false-negative eligibility | 7 capability tests and 45 store tests | Pass |
| Atomic command publication and stale/read-only failure | Store suite and retained review mutation | Pass |
| Edit-time analyst identity and accessibility routing | 20 settings tests and 15 XCUI-readiness tests | Pass |
| Cached menu/inspector capability and bounded redraw | 258 viewport tests, 38 display tests, seven structural checks | Pass |
| Coalesced workbook regeneration | Structural scheduler assertion | Pass |
| Current workbook exact identity, review formatting, audit, and final paths | 77 workbook tests and retained XLSX inspection | Pass |
| Current workbook complete truthful provenance | Final retained provenance inspection | Pass |
| Explicit viewport XLSX annotation sheet and native note | 13 CLI tests, 8 OOXML tests, retained package inspection | Pass |
| Explicit viewport complete structured option provenance | Final retained provenance inspection | Pass |
| CSV/TSV quantitative preservation | Focused CLI/export tests | Pass |
| Full package regression suite | XCTest and Swift Testing aggregates, exit `0` | Pass |
| Repository hygiene | No tracked ignored files, temporary evidence hooks, or report markers | Pass |

Overall acceptance is complete at
`1f2980eea2f5da164d617aca121a282972154ecd`.

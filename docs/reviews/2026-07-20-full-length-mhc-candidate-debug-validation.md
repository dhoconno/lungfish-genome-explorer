# Full-length MHC candidate viewport debug validation

Date: 2026-07-20 (America/Chicago)

Branch: `codex/full-length-mhc-candidate-viewport`

## Debug artifact

- App: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/full-length-mhc-candidate-viewport/build/Debug/Lungfish.app`
- `CFBundleName`: `Lungfish Debug`
- `CFBundleIdentifier`: `com.lungfish.browser.debug`
- Bundled CLI version: `0.5.0-beta8`
- `codesign --verify --deep --strict`: passed
- The app was launched with the validated result bundle as its argument.

## Exemplar run

Validated bundle:

`/Volumes/iWES_WNPRC/32355/32355.lungfish/Analyses/Full-length ONT MHC genotyping results/2026-07-20-1400-candidate-debug.lungfishgenotype`

Inputs were the four requested CR1178, CR1178b, CR1182, and CR1182b sample bundles under `/Volumes/iWES_WNPRC/32355/32355.lungfish/32355/`, using `IPD-MHC_NHKIR_classI_Mafa.lungfishref` as the reference.

The completed analysis contains two sorted/indexed cohort evidence pairs, candidate JSON/FASTA, un-nameable JSON/FASTA, the reference catalog, workbook projection input, initial/current workbooks, the result manifest, and full provenance.

Observed candidate classification:

- 28 stable candidate sequences, all distinct rows.
- 17 shared candidates and 11 singleton candidates.
- 27 unique provisional names for 28 stable IDs, confirming that a real provisional-name collision remains separated by stable cluster ID.
- All 28 candidates in this exemplar are `_nov`; the four `_ext` tint/filter paths remain covered by focused unit tests because this dataset produced no qualifying extensions.
- No `_0nt_nov`, legacy `_extension`, or legacy `_<N>SNP` names were produced.
- 34 unique un-nameable stable IDs were retained as a separate JSON/FASTA artifact.

All eight candidate/BAM artifacts declared by `genotype-result.json` matched their declared sizes and SHA-256 checksums after workbook publication.

## Explicit workbook update on ExFAT

The bundled CLI successfully executed `fastq update-current-workbook` against only the candidate-debug bundle, using an empty displayed-call snapshot to exercise candidate refresh without changing reviewed haplotype calls.

- Exit status: 0.
- Workbook revisions: 1 before, 3 after. The update intentionally created a snapshot of the previous `current.xlsx` plus the new current revision.
- Published current workbook SHA-256: `4309399d7143337b57461da2bb644c2361b86449738f65eb418d40dd7aa8ab80`.
- Published manifest SHA-256: `81951d27d46173e1a6a34d10a45f22d1721378f04973aac4882bb68c5dd29235`.
- The current workbook bytes match the final revision descriptor.
- Provenance exit status is 0 and records the actual `exfat-journaled-three-rename-v2` publication mechanism, exact argv, resolved options, runtime, checksums, file sizes, final bundle paths, and wall times.
- No live workbook transaction marker, attestation, or staging directory remained after success.
- The retired generation was intentionally retained at `.lungfish-workbook-generation-archive-2026-07-20T211836Z-update-current-workbook-2CD15198`. Debug builds do not delete retired generations automatically; explicit retention/cleanup UI is a pre-broad-release follow-up.

Workbook inspection after the update found:

- All 13 expected worksheets rendered.
- 28/28 candidate stable IDs present in `Candidate Alleles`.
- All 34/34 unique un-nameable stable IDs present in `Un-nameable Clusters` (110 evidence rows total).
- Candidate name fills: 17 shared-novel cells with `F5D78E` and 11 singleton-novel cells with `F5B97A`.
- No formula-error tokens matched `#REF!`, `#DIV/0!`, `#VALUE!`, `#NAME?`, or `#N/A`.

## Verification

Fresh root-run verification after the final recovery commits:

- `swift test --filter GenotypeWorkbookRevisionServiceTests`: 59 tests, 0 failures.
- `git diff --check`: passed.
- Independent code re-review: no remaining findings in the workbook-publication scope.
- Fresh `scripts/build-app.sh --configuration debug`: passed.
- App identity, CLI version, and strict code-sign checks: passed.

The original `/Volumes/iWES_WNPRC/32355/32355.lungfish/Analyses/Full-length ONT MHC genotyping results/2026-07-19.lungfishgenotype` was not modified. Its directory mtime remained `2026-07-19T10:07:16-0500`; manifest SHA-256 remained `13f7b6979b174b2df22f1444ca3cce9b1294066fe398da38dbc27ca76c6f75eb`; and current workbook SHA-256 remained `a17f7fe132ddc869e4a4e7ecf6f7cab10935538372baa757b808280e55a6fda5`.

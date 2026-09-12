# Three-sheet Excel acceptance — 2026-09-12

This records Task 6 acceptance of the approved three-sheet design. Whole-branch review and release authorization are separate gates. No original scientific project, source workbook, calling rule, threshold, or inference schedule was changed.

## Workbook and workflow checks

Both roles contain exactly `Genotype Matrix`, `Haplotype Calls`, and `Export Metadata`. Editable current workbooks retain manifest-bound call/Note targets; filtered workbooks remain one-way snapshots. Hidden identities never substitute for scientific authority.

H1/H2 now sit together in the call sheet, with matching display sample names and palette colors in both call views. Locked scientific cells remain independently validated, while Excel protection permits selecting cells and editing traditional Notes. Metadata explains editing the existing structured block, JSON quoting and newline escapes, explicit keep/set/clear, and saving before returning to LGE for review/acceptance. Current workbooks with read-only calls still explain eligible Note editing; filtered metadata does not instruct users to import it. Audit history has contextual Show all / Show recent without discarding entries.

Full current uses the established biological sorter and reference display-label resolver. Exact raw identifiers, scientific loci and stable cluster IDs remain unchanged. Filtered order remains the settled viewport order, including its custom locus order. Long source-revision metadata wraps to a fitted row height.

Analyst fill, text, border, bold and italic survive the snapshot/projection/payload boundaries. Resolved nil/false values are authoritative. Headless current uses legacy row → exact row → column → legacy cell → exact cell precedence, per property. Captured translucent paint is converted to sRGB and composited on white. Tests cover suppressed filtered highlights, None mode, support/fraction coloring, candidate-name-only tints and contrast/manual-text priority.

FP remains numeric with `[n]` display and gray italic font. FN remains numeric zero with `FN` number format, bold text, pale fill and four dashed orange edges. An FN semantic frame takes the single Excel cell edge; the analyst border remains retained and returns when the review is cleared. Exact OOXML numeric and style records are tested. An independently attested 8/9/0 fixture verifies FP/FN and explicitly captured palette overrides without reading old calls or science from a source XLSX.

## Disposable real-cohort acceptance

Every loader/writer operated on an additional whole-project clone of a disposable copy. Parent read-only witnesses confirmed all 636 original files unchanged, tree SHA-256 `bd99dc7a0c29acefae4ac2bd6adb40a95f6e34d6f60de09070e44db33ce9c86c`. Private paths and identifiers are deliberately omitted here.

The real controller emits the current-workbook request, including palette and full input fingerprint, into the production execution service and this worktree's explicitly selected CLI executable. Its version, path and binary hash are recorded in a private QA witness. The filtered export also invokes that executable, not an installed Preview app.

Initial, accepted-set and explicit-clear phases each compare all 4,160 filtered evidence cells (160 rows × 26 samples), all 4,394 current evidence cells (169 × 26), and all 260 call slots in each role. Comparison includes raw/display values, masks, annotations, call fields, formula caches and colors/styles. Every current display name is compared against the same exact raw/locus/stable identity in an unfiltered LGE snapshot. Set/clear exercise a direct call, positive-support FP, row comment and cell comment; reopening reproduces the immediately accepted view and raw calls remain unchanged.

The cohort contains no independently attested zero eligible for FN. Missing CSV pairs remain unknown, not synthesized zero. Therefore a separate reference-zero MiSeq controller fixture proves FN set → review/accept → save/reopen → regenerate both roles → explicit clear. Emitted numeric zero and visible FN formatting are asserted on set; neither role retains FN on clear. Candidate stable-ID disambiguation is covered separately by `GenotypeWorkbookRevisionServiceTests.testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity`, its collision/duplicate tests, and the three-sheet exact Note-target import tests. This is not a claim that MiSeq displays full-length candidate rows.

Retained baseline, payload, layout, renderer, runtime, reviewed XLSX and annotation receipt descriptors are checked against stored bytes and sizes. Current revision provenance binds actual executable argv, version, options, runtime, exit status and wall time. Import receipts retain reviewed bytes and replay inputs. Source sidecars remain preserved; invalid and duplicate reviews are withheld rather than rewritten.

## Independent rendering and native Excel

Parent independently imported the production renderer artifacts into ArtifactTool, inspected all three sheets and rendered initial/current/filtered views. Changed ranges verified adjacent call readability, active palette, compact biological labels, fitted revision metadata, role-specific guidance, gray `[n]` FP and reference-zero FN. Edited then cleared cohort header bands visibly change and restore only the intended slot. PNG previews do not prove Note contents.

In a disposable in-memory synthetic copy, H1 change updated the linked matrix value and color while H2 stayed unchanged. This is library recalculation evidence, separately from native Excel.

Parent opened only disposable synthetic workbooks in native Excel. Direct H1 editing and existing traditional Note editing saved successfully without changing the numeric evidence. A native-saved/reopened workbook was then successfully inspected by the production importer using its matching original manifest.

Native Excel exposed stale conditional colors despite correct formula cache values. The minimal fix emits the same opaque active RGB in both differential-fill foreground and background channels. On a fresh copy, changing H1 followed by Calculate Sheet produced the correct matrix and call-sheet color; H2 stayed unchanged. Excel's pre-existing manual calculation setting was not changed globally, and no other workbook was calculated or edited. Native Note/import evidence comes from the earlier saved copy; native color evidence comes from the fresh fixed copy.

## Automated verification

Focused failures preceded scoped fixes for geometry/FP/FN/order, style transport, audit expansion, malformed-Note repair context, native differential fills, stale v1-to-v2 test routing, compact headless labels and role guidance. Final focused FN acceptance passed 1 test, 0 failures, 0 skips in 16.887 seconds. The complete real-cohort round trip passed independently before the integrated run.

The single integrated affected run uses `swift test --jobs 6` with `LUNGFISH_EXCEL_QA_PROJECT`, `LUNGFISH_EXCEL_QA_BUNDLE` and `LUNGFISH_EXCEL_NATIVE_QA` pointing only at disposable QA fixtures. It includes the planned suites, shared eligibility suite, new style/audit/FN suites and exact extended UI style tests. Exact filter and intermediate logs are recorded in the Task 6 implementation report.

Integrated result: 442 tests, 5 assertion failures in 2 stale-layout test helpers, 0 unexpected failures, 0 skips, 486.987 seconds. Both helpers were migrated to actual schema/manifest extraction without changing their scientific expectations. A new role-copy regression first failed as expected, then passed after a narrow guidance-only fix. The covering run executed 12 tests, with 11 passing and one remaining stale empty-string expectation for an omitted optional transient analysis revision. That assertion was corrected to independently verify absence in both captured and emitted metadata; the real definition ID remains asserted.

Final one-test fixture verification: **1 passed, 0 failures, 0 skips, 0.907 seconds**. All integrated failures are now accounted for by fresh passing checks. The complete integrated run was not repeated or described as a clean run. Whole-branch review remains the parent's separate gate.

## Limitations

Sheet protection is usability assistance, not security. Native Excel coverage is synthetic, not the private cohort. No release, merge or push was performed. The parent owns final whole-branch review.

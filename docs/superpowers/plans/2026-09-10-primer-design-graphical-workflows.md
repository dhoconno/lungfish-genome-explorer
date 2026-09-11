# PCR primer graphical workflows

Approved scope: the PCR primer pack proposal, with MHC class I, class II DP, DQ and DRB examples. Work only in `codex/pcr-primer-design`; Astra supervises delegated engine and runtime work.

## User interface and execution

- [x] Add Tools → PCR Primer Design with a sheet following existing Lungfish operation patterns.
- [x] Show full input paths, duplicate-safe record indices and explicit MSA template selection.
- [x] Use shared engine input inspection and bind selection to source fingerprints.
- [x] Expose Primer3 region/product constraints, independent record selection, primer properties and internal-probe choice.
- [x] Expose per-MSA versus combined PrimalScheme3 panel creation, amplicon size and pool count.
- [x] Keep unsupported custom terminal-end coverage policy visibly unavailable in the stock managed runtime.
- [x] Connect actual pipelines to run/cancel/error/result-opening controls.
- [x] Add normalized candidate results, annotated template display and actual executed-tool provenance.
- [x] Complete durable annotated-reference integration.
- [x] Run integrated GUI/model/routing tests after engine adapters compile.
- [x] Render and inspect both design sheets and normalized results.
- [x] Complete independent Astra review and record evidence.

MHC example buttons select names, not scientifically validated assay presets. The design inputs must supply the sequence context needed to flank the requested target. Plain FASTA contains sequence data; feature coordinates and stable analysis links belong in durable annotation artifacts or native annotated reference bundles.

## Verification

Tests cover malformed numeric text (no silent reuse of old values), target coordinate ordering, duplicate names, empty record selections, input failures/retry, normalized result membership and bounds, and Tools menu routing. Opt-in offscreen rendering uses synthetic display fixtures and does not interact with the user's running app.

Engine adapters, installation receipts and their separate tests are tracked in the Primer3, PrimalScheme3 and managed-Python-runtime plans. The original checkout and the concurrent MHC work remain outside this implementation.

Final integrated verification: `.build/primer-design-integrated-10.log` records 173 XCTest cases (one optional live installer check omitted, zero failures) and 65 Swift Testing cases passing. The live installer passed in integrated run 9. Offscreen design/result renderings were inspected, including actual human MHC Primer3 and PrimalScheme3 results. The CLI annotation check produced 15 linked primer/probe features and verified exact argv plus final payload hashes and sizes. See `docs/features/pcr-primer-design-validation.md` for native fixture evidence.

Independent Astra integration review approved the final source after the passing integrated suite, with the stock-runtime and experimental-validation limits documented explicitly.

# Task: LGE allele-label display and provenance bridge

Date: 2026-09-16
Owner: Sol bounded implementation; Astra independent review pending
Native contract: `primalscheme3.allele-label-map/v1`, approved native source `236e74a`

## Result

The LGE allele-aware design pipeline now preserves the native label map and produces an additional display-only map that joins:

1. native target, observed-class and row IDs;
2. the exact LGE normalized FASTA row map used by the native process; and
3. original `.lungfishmsa` source-row metadata when that metadata exists.

Each displayed row keeps its source occurrence and row index, native row ID, normalized header, consumed original aligned header, human original label, and stable LGE row ID when available. Repeated human labels remain repeated and are distinguished by row indices and immutable IDs. Raw FASTA inputs without source-row metadata use their consumed original FASTA description as the display label.

This transform does not rewrite native coverage, target, class, candidate, cache, history, validation or assignment identities.

## Fail-closed checks

A newly advertised native map is accepted only when:

- `panel-optimizer.json` advertises the exact supported schema and contained map path;
- fresh native audit evidence reports the map valid with matching path and target/row/class counts;
- the retained audit file is byte-identical to the audit bytes validated by the LGE native contract;
- every stored native input still has its advertised hash and size;
- native source occurrences exactly match the result's input order;
- LGE row maps have the expected input UUID, count and contiguous order;
- native descriptions/record IDs match the exact normalized headers consumed by native;
- optional `.lungfishmsa` metadata has complete, unique stable row IDs/names and joins every consumed row;
- native classes cover each native row exactly once and retain their multiplicities and aliases.

Historical results whose optimizer does not advertise an allele label map remain readable without synthesizing one.

## Publication and provenance

The pipeline preserves the native `allele-label-map.json` as a `nativeOutput` and publishes:

- `derived/<result-id>/allele-label-map.json` (`derived-label-map`)
- `logs/<result-id>/allele-label-map.json` (`derivedProvenance`)

The transform receipt records the host invocation/version/runtime, resolved schema/result/input IDs and display-only scope. It hashes and sizes the final stored panel optimizer, native map, native stored FASTAs, native audit validation, LGE normalized row maps, optional source-row metadata, and final derived output. Paths point to the final `.lungfishprimeranalysis` bundle and retain scratch origins.

Text `primers analysis inspect` prints human labels with native IDs, stable LGE IDs when available, and one-based source/row positions. Both text and `--json` inspection reject an advertised derived map detached from its result; JSON output itself remains the verified manifest. Old results continue to show their existing native aliases.

## Test evidence

Test-first evidence:

- Initial bridge test failed to compile before the bridge types existed.
- Initial inspect label test failed because the command still printed native aliases.

Final focused runs:

- `swift test --filter PrimalScheme3AlleleLabelMapTests`: 5 passed
- `swift test --filter PrimerAnalysisInspectCommandTests`: 8 passed
- `swift test --filter PrimalScheme3PublicationTests`: passed (existing publication, relocation, failure and legacy/coverage regressions)

The focused cases cover duplicate display labels with distinct stable IDs, two source occurrences, raw-FASTA fallback, complete transform provenance, historical map absence, missing audit evidence, byte-detached retained audit, normalized-header detachment, readable inspect output, stale result IDs, and text/JSON fail-closed behavior.

## Review gates

Independent Astra review approved `6a5a2f2e9`. The frozen matrix11 design, saved derived map, human-label inspect output, relocation, history and fresh-audit checks described below also passed.

## Frozen matrix11 real smoke

The independently approved bridge commit `6a5a2f2e9` was built once and exercised with frozen matrix11 native source `236e74af6b186367fd66f15e73b558a0c3e44a74` on the retained 500-byte, two-row synthetic FASTA.

Retained root:

`/private/tmp/lge-matrix11-label-smoke-01`

Final relocated bundle:

`/private/tmp/lge-matrix11-label-smoke-01/relocated-design.lungfishprimeranalysis`

Result ID: `9A8F7037-6468-447C-B7C5-63EB8ED17AE1`

Design, text inspect, JSON inspect, history and fresh audit all exited zero. The bundle was then moved to the retained relocation path and text inspect, history and fresh audit again exited zero while the original `/private/tmp/lge4-task10-small-source.fasta` was temporarily unavailable. The input was restored in a `finally` path with its original SHA-256 `9194587e219bedb585e19b7ed518324affef946f8643392fb0059e5620bab311` and 500-byte size. A current CLI read-only inspection of the historical matrix10 bundle without an advertised label map also exited zero.

The real derived class has multiplicity 2 and preserves the two raw labels `fixture-reference` and `fixture-duplicate`, each beside its distinct native row ID. The saved native audit and both later fresh audits report `allele_label_map` advertised/valid with 1 target, 2 rows and 1 class. The transform receipt consumes and binds the native map, panel optimizer, native stored FASTA, fresh audit validation and LGE row map at the creation destination. It publishes only the display map and records the exact wrapper argv/runtime/status/wall time.

Verification record:

`/private/tmp/lge-matrix11-label-smoke-01/verification.json`

Verification passed across 9 captured zero-exit commands, with empty stderr for each. Before writing the final verification record the retained root contained 92 regular files and 30,223,596 bytes. Key hashes:

- derived map: `d18a3fbd8892cf57469517f27d4c721dd4e118346117216233f5950c782c9c06`
- derived transform provenance: `97d5feda873592cc915e55c12ec755fe2b5d80db36eb18e8a809bda92d50e96f`
- relocated bundle manifest: `19ef6b86533c970b9e4b78cfb88c880432e177bf91d3de9fdeef20795c516070`
- native capability source digest: `326e51fc62de3e206447668a7f19dcf9b0c3c3fbdcd02cadd88cb86dd28d8e80`

The tiny result's 67.83% modeled coverage and one amplicon are fixture behavior only, not a quality or biological result.

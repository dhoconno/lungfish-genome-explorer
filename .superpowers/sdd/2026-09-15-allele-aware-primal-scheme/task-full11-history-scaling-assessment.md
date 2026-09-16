# Full11 history scaling assessment

## Decision summary

The prepared completed-panel → audit → cache export → cached-selection path does **not** replay all historical records through `SQLiteCoverageHistory._reload`. It does repeatedly hash the entire immutable origin database, and fully materializes catalogs, stage ledgers and discovery snapshot dispositions. These are real scaling hazards, but static inspection does not establish that the workflow cannot finish. Proceed serially with the first required gate and one informative arm; do not launch the whole optional matrix before observing their actual time/RSS/disk use. No validation relaxation is recommended.

Scope: read-only code inspection on 2026-09-16, mutable HEAD `74102b8effef79f98487b4962c65b112454425d3`, plus small JSON receipts from completed A1 runs. Relevant code below is byte-identical to frozen matrix11. No live cold output/database was opened, no science or benchmark ran, and no helper or production source was changed. The reported 24.56 million records / 47.18 GiB is parent-supplied context, not a measurement made here.

## Concrete paths and costs

Locations are relative to the native repository, `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primalscheme`.

| Step | Facts from code | Large origin-history cost |
|---|---|---|
| `panel-audit` | `panel/allele_inspection.py:738–817` under `primalscheme3/`: hashes every source-bundle file into audit inputs, invokes audit, then hashes inputs again for mutation detection. `audit_allele_bundle:506–513` independently verifies all source output descriptors. | **Three complete SHA-256 reads** of every root-provenance-listed history file, including copied origin history on cached panels. No semantic record replay. |
| Stage science within audit | `allele_inspection.py:664–682` loads complete stage catalog and authoritative targets; calls `allele_publication.py:280–334`, which verifies stage artifact bytes, loads complete catalog and ledger, recomputes their semantic digests and invokes fresh validation. | No history read by the stage validator (`history=None`). Catalog is loaded twice simultaneously across caller/callee; ledger also fully loaded. Repeats per successful selected stage; default audits all successful stages. |
| `panel-cache` export | `allele_catalog_cache.py:199–329`: verifies source DB hash; loads catalog; gets discovery snapshot; copies DB; hashes all pending artifacts for manifest; verifies copied DB again against source receipt. Successful outer finalizer reuses descriptors (`:390–414`) rather than hashing DB a fourth time. | **Three SHA-256 reads**: source once, destination twice. Copy may add another full read/write. Export does not itself run a new independent biological audit; prepared external fresh-audit gate remains necessary. |
| Discovery snapshot | `allele_catalog_cache.py:153–177`: immutable read-only SQLite; indexed stream/stage query fetches discovery snapshot payloads only, decodes each whole snapshot, checks catalog identity/completeness/count bounds. | Does not scan all evidence/assessments/events. However a snapshot's compressed payload and entire decoded dispositions mapping are materialized, not streamed; memory scales with entity dispositions. Manifest embeds the complete snapshot too. |
| Cached native load | `allele_catalog_cache.py:574–680`: hashes every cache artifact, fully parses catalog, validates settings/raw inputs/semantic digest, reads discovery snapshot. | One DB hash, indexed snapshot read; no full history replay. |
| Cached native materialization | `allele_catalog_cache.py:682–707`: copies all cache artifacts to local `origin-discovery`, then verifies their hashes. `allele_pipeline.py:117–145` opens a **new empty** current selection history, not the old origin DB. | One destination DB hash, and possible physical copy. Old origin decisions remain separate. |
| Native final receipt | `coverage_provenance.py:345–351`: recursively fingerprints every output file, including `origin-discovery/history/history.sqlite`. | Another complete origin DB hash, plus current selection history. |
| Prepared v5 outer runner | External `run_cached_allele_control_v5.py:148,158,190–200` invokes frozen native benchmark helper `cache_inputs`, then rehashes all input identities after execution. `scripts/benchmark_cached_allele_panel.py:120–163` hashes every cache artifact during validation and **again** to return descriptors. | Two preflight origin DB hashes and one after-run hash, in addition to native/audit reads. Helper also fully parses catalog for basic length/profile diagnostics. |

The history paths above use streaming 1 MiB hashing (`allele_catalog_cache.py:90`, publication `artifact_descriptor`, provenance helpers). They do not allocate a 47 GiB byte string. `immutable_copy.py:38–80` attempts Darwin `clonefile` (distinct inode, copy-on-write); unsupported/cross-volume cases use a bounded 1 MiB byte-copy fallback. Cloning can avoid copying all storage blocks, but does **not** remove required checksum reads. No hard link or live writer attachment is used.

### Profile projections are an additional nontrivial cost

For an unchanged union profile, `_project` returns the existing catalog immediately (`allele_catalog_cache.py:453–456`). For normal/high-GC projection, it traverses eligible sites/evidence and performs indexed evidence-membership lookups with a 4096-entry LRU (`:459–504`), then rebuilds families using forward-anchor × reverse-anchor iteration and site-pair geometry (`:505–563`). This is neither full history replay nor cheap constant-time filtering. Its work and memory can grow with anchor/family counts; it creates projected catalog/derived evidence alongside the original. It is independent of the selector's 3600-second search budget. A union cached baseline should precede optional profile ablations.

## Read amplification accounting (not runtime estimates)

Assuming success and the standard v5 wrapper:

- Initial standalone audit + export: **6 H** bytes fed to SHA-256 for the origin database.
- Each cached arm including its final independent audit and wrapper: **9 H** origin-database hash bytes (wrapper 3 + native load/materialize 2 + native final receipt 1 + audit 3).
- For parent-reported H = 47.18 GiB: approximately **283.08 GiB** initial gate/export logical hash reads and **424.62 GiB per arm**, before other files and any fallback copy reads/writes.

These are logical sequential reads, not disk-device traffic: OS cache/shared clone blocks may serve some reads. They do not predict seconds or full-run speed. Failed paths, retrying gates, external diagnostic hash verification, additional stage data and current selection history add work. The current DB size may also grow before completion.

## Memory and completed A1 evidence

Catalog loading is `json.load` followed by typed record construction; `VariantCatalog.semantic_digest` builds another sites/families dictionary representation and canonical serialization (`coverage_types.py:370–416`). Peak memory can exceed compressed file size greatly. Stage ledger parsing is likewise whole-file. Outer bundle audit keeps its catalog alive while the inner stage auditor independently constructs another. Repeated stages are processed sequentially, although reports retain selected validation evidence. Discovery snapshot `.to_dict()`/manifest serialization also creates expanded representations of its full dispositions.

Read only these existing receipts (not their databases):

- `BASE/mamu-a1-cached-quality09-3600-01-execution/provenance.json` and panel receipt: native 3986.46 s, audit 146.27 s; direct-child `wait4` peak RSS native 5,666,750,464 bytes, audit 4,400,398,336 bytes. Origin DB saved size 5,253,275,648 bytes; new selection DB 3,061,755,904 bytes. Recorded reuse/discovery phase 63.83 s.
- `BASE/mamu-a1-cached-narrow09-3600-01-execution/provenance.json` and panel receipt: native 3939.43 s, audit 146.20 s; peak RSS native 5,144,625,152 bytes, audit 4,450,729,984 bytes. Same origin DB size; new selection DB 2,060,718,080 bytes. Recorded reuse phase 64.64 s.

Both saved wrappers report success and native/audit exit 0. These are reported receipt measurements; this assessment did not independently rehash their multi-GB payloads. `wait4` RSS is Darwin direct-child rusage (may include reaped descendants per OS), not simultaneous process-tree aggregate. Timings include science/serialization/hash work and do not isolate hashing. A1 demonstrates completion at smaller scale and already multi-GB memory use, not linear full11 extrapolation.

## Recommendations, in priority order

1. **Keep completion/closed-DB/fresh-audit gates.** No immutable read-only connection before writer closure, no substituting cached valid flags, no opening the origin with the history writer merely to inspect it. Do not migrate the 47 GiB v1 origin just to run selection.
2. **Run one gate and one union narrow-budget baseline serially, recording existing receipts and external phase/RSS observations.** Selector time limit excludes cache verification/materialization, publication and independent audit. Long silent hashing is not evidence of a hung selector. Avoid parallel full11 audits/arms competing for memory and disk bandwidth.
3. **Account for copy fallback and growing current selection histories.** Same-volume supported clonefile reduces duplicated origin blocks, but fallback needs approximately another H per cache/arm plus selection outputs. Existing code does not report which copy path actually ran; do not assume every copy cloned successfully. Preserve all provenance even if disk pressure pauses optional arms.
4. **A low-risk future optimization candidate is descriptor reuse within one validation boundary**, especially helper `cache_inputs` hashing each artifact twice and exporter hashing the same fresh copy for both manifest and source comparison. One actual digest can satisfy both comparisons; retain end-of-run mutation checking and receipt bindings. This is optional reviewed work, not authorization to change frozen commands now.
5. **Memory optimization, if measured necessary:** avoid holding two equivalent complete stage catalogs during audit; pass/reuse a verified immutable parsed catalog without dropping fresh raw-target comparison or fresh scientific validation. Streaming selected-ledger reads and snapshot/disposition representation changes are broader work requiring dedicated semantic tests; do not improvise on the critical path.
6. **Do not expand the matrix until the first baseline's actual cost is known.** Profile projection and multiple salvage stage audits add costs outside the search budget. The earlier priority/gating plan is appropriate; no requirement to execute every optional arm before scientific diagnosis.

Conclusion: no identified accidental full historical semantic reload in the prepared downstream path. The concrete risks are repeated sequential hashing, full JSON/semantic-digest allocations and profile-family reconstruction. Their code-level existence is proven; their full11 elapsed/RSS impact remains unmeasured. No evidence here warrants weakening validation or declaring finishing impossible.

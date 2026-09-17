# Bounded v2 checkpoint join optimization

Native base236e74af6b186367fd66f15e73b558a0c3e44a74. Edit only mutable allele-aware-primalscheme worktree. Preserve frozen benchmark/matrix worktrees and live MHC output.

Replace only v2 checkpoint closure query with physical integer relations: record_links_int source_key/target_key join records.position, keeping exact same kind/source stream/source ordinal/target ordinal inequalities. V1 query remains unchanged. Keep all three checks and all digest/inheritance/disposition/FK/reload/corruption checks; no count-based skip, trust flags, schema/CLI/science change or migration. Scientific discovery fingerprints and IDs remain unchanged.

Astra assessment/addendum: task-full-prefix-checkpoint-assessment.md. Exact algebra depends on records.id UNIQUE and current native v2 view definitions. Existing view+ID query has5searches; physical form3. No full-MHC speed claim or activev1 improvement.

Meaningful tests: compare original and physical query results for all3linkkinds across full/valid-truncated/invalid-truncated prefixes; v1/v2 complete-stage output IDs/digests/export parity; equal-count ordinal-corruption rejection; unique-ID alteration and dangling relations preserve semantics/FKreload rejection. Keep existing storage regression suites green. Tests must exercise production helper/query through checkpoint where appropriate. No timing assertions. Optional small closed synthetic query benchmark needs its own exact runtime/argv/records/options/output hash receipt; not necessary for correctness.

Sol implements/tests/commits and writes task-v2-prefix-joins-report.md; root dispatches separate Astra review. No broad fullsuite or scientific rerun while implementing; root owns final frozen fullsuite. No changes to rootprogress/publicreport.

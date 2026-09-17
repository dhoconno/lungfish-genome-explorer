# Gap-focused candidate expansion

## Approved objective

Expand the candidate pool for independent follow-up schemes specifically around bases uncovered by the fixed primary scheme. Rebuild the follow-up pools from the union of original and expanded candidates. Existing follow-up assignments may change; primary assignments cannot change.

The previous A1+A2 follow-up reached 2171/2923 and 2291/3082 trimmed reference bases. Its available-candidate ceilings were 2172 and 2291. More pool-search effort alone cannot fill the large intervals absent from those candidates.

## Generation hypothesis

Legacy pairing already enumerates permitted combinations of generated primer clouds. Additional choices must come from earlier discovery: retaining further compatible lengths beyond the first Tm-passing length, and retaining confirmed single-oligo alternatives when whole-cloud filtering discarded otherwise viable members.

Use existing row-local variant discovery in all-length mode at bounded gap-focused anchors. Do not build an allele catalog, exhaustive rejection database, or combinatorial primer-subset optimizer. Ambiguous expansions are excluded. A new pair must have at least one observed row supporting both concrete primers. Record that witness and both alignment footprints. Reject footprints that cannot be represented faithfully by the native endpoint/sequence-length coordinate model.

Keep resolved legacy chemistry and amplicon-size semantics. The effective existing Tm upper bound includes the native `primer_tm_max + 2` tolerance; this is not a new relaxation. Apply strict self-dimer, pair-dimer and follow-up pool admission checks. Preserve full supplied MSAs for mapping and specificity.

## Bounded search and controls

Add `--gap-expansion off|bounded`, default off, requiring gap-completion mode when enabled. Controls default to 2000 direction-plus-anchor evaluations per MSA and 1000 unique geometry-eligible same-row pair checks per MSA. A pair check limit is not a promise to generate that many accepted pairs. Explicit advanced controls with expansion disabled must fail clearly.

Spread anchor sampling across positions, parent gap windows and both directions. Spread pair families across eligible anchors before consuming additional row/length alternatives at the same sites. Apply cheap geometry checks before charging pair-check quotas, deduplicate before quotas, and generate alternatives lazily. Record actual work and truncation; report unknown omitted work honestly rather than asserting exhaustive exploration.

## Selection, audit and evaluation

Union and deduplicate original plus expanded candidates, retaining origin metadata. Reuse the positive-trimmed-gain follow-up selector and independent strict pool checks; do not apply the prior dimer salvage budgets. Recompute the ceiling for the actually explored candidate pool and distinguish generation-limited gaps from pool-conflict gaps.

Persist compact generation counts by rejection cause, selected source-row witnesses, bounds and cap status, raw input/parent identities, and report references in success/failure provenance. Fresh published-output audits must use the actual selected objects, not unselected duplicate candidate objects.

Luna owns implementation, tests and job monitoring. Astra reviews algorithm decisions and evidence. Test off-path parity, support/mapping, spatial cap allocation, duplicate identities, actual workflow/provenance and configurable pools. After a clean-source test gate, run one strict two-pool A1+A2 comparison against the saved parent and previous follow-up. Use a 600-second/8-GiB external guard and preserve failures. Any stronger experiment requires evidence-based review. No GUI, installed runtime or full eleven-MSA run in this task.

# Independent gap-completion schemes

## Approved objective

Create a separate follow-up primer scheme targeting reference bases left uncovered by a completed primary scheme after primer trimming. Primary and follow-up pools represent separate PCR reactions. Parent primers seed the coverage calculation but never populate follow-up conflict checks. Existing legacy operations remain unchanged.

## CLI contract

Use `panel-create --gap-completion-parent PATH` with existing `--n-pools N` (default two, any supported positive integer). Initial scope is legacy selection, equal mode, first-row mapping, linear references, full supplied MSAs, and no imported primers, region mode, or simultaneous bounded salvage. Require a fresh output directory disjoint from the parent and inputs.

Retain original normal legacy chemistry and dimer settings by default. Generate candidates using full MSAs, preserving flanking sequence and the full specificity background. This version does not crop MSAs or regenerate candidates under permissive chemistry.

## Selection

1. Validate parent target identities, reference sequences, primer coordinates and derived amplicon geometry against supplied MSAs. Reject duplicate target identities. Record the level of input verification that the parent artifacts support.
2. Compute per-target half-open ungapped reference unions for parent full and primer-trimmed spans.
3. Generate the original legacy candidate pool. Compute its unconstrained union as a coverage ceiling, not a promise that all candidates can coexist.
4. Greedily choose positive marginal primer-trimmed coverage against the parent plus follow-up union, with deterministic candidate/pool ties. A one-base gain must remain eligible; avoid legacy integer-score rounding that removes it.
5. Admit candidates only against fresh follow-up pools using original overlap, dimer and MatchDB rules. Do not apply the previous salvage exposure budgets.
6. Stop when no admissible candidate adds coverage. Preserve residual gaps and rejection reasons rather than forcing a coverage target.

## Outputs and validation

Standard primer BED, full/trimmed amplicon BED and reference FASTA describe follow-up reactions only. Preserve parent scientific artifacts separately under `parent/`. Report independent parent/follow-up/combined coverage, remaining gaps, candidate-union ceiling, stable candidate status and published primer identities, and distinct scheme/pool namespaces. Do not publish a misleading combined single-scheme pool BED.

Fresh validation reparses published primers and replays strict follow-up admission independently, verifies selected identities and pool assignments, and checks both amplicon BEDs against the primer BED. Provenance records exact commands, resolved defaults, source/runtime versions, original inputs and preserved copies, parent hashes, output hashes/sizes, status and wall time. Verify parent and raw inputs remain unchanged. Record failure provenance when output ownership has begun.

## Implementation and evaluation ownership

Luna owns core implementation, CLI, tests and job monitoring; Astra makes algorithm decisions and reviews evidence. Focused tests cover geometry, one-base gains, independent pools, arbitrary pool counts, parent immutability, malformed inputs, fresh validation and provenance. Run an appropriate stable-source regression suite, then one bounded strict two-pool A1+A2 experiment using the saved authentic legacy inputs and parent. Evaluate per-MSA reference coverage after trimming as primary, full spans as secondary. No GUI, installed-runtime changes, full eleven-MSA run, or automatic threshold sweep.

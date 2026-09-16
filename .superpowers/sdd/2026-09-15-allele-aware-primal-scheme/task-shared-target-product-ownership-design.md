# Shared exact product ownership: design assessment, not implementation

## Evidence and limit

The completed fixed-A1 screen plus full-oligo annotation establishes17/18 saved configurations have at least one complete-exact added-background150–250 product, with166 such unary witnesses. This motivates representing deliberately shared target products explicitly. It does not mean every observed cross-locus product is wanted.

It is also not a sufficient quick fix. Removing only both-full-exact witnesses leaves1435 mismatch-dependent unary witnesses, and even the150–250 subset leaves1250 covering **all18** configurations. Therefore exact shared-target ownership alone would not make this unchanged panel pass the existing terminal screening gate. Do not successively loosen predicates merely until the observed panel passes. Unknown/shifted/undeclared products remain independently important.

## Current architectural mismatch

Each `SelectionConfiguration` has one target, one family and one anchor pair. Coverage is exact same-row support on that target; intended and ordered-secondary certificates are owned by the selected configuration's target. Unary validity is tested before insertion, and search caches invalid results by immutable configuration ID. The construction engine assumes a candidate rejected as intrinsically invalid cannot become valid merely by adding another candidate later.

If physical F/R species have legitimate intended roles at both A1 and A2, representing them as two independent target-local configurations and allowing the A2 role to rescue A1 only once both are selected breaks that assumption. Each may fail unary screening before the other is reachable. A global mutable registry of currently selected target roles would make cached unary/pair results stale and invalidate consumed-candidate monotonicity; it must not be bolted onto the existing predicate silently. Merely deleting the certificate's target check is unsafe and is not an ownership representation.

## Two coherent models

### A. Immutable declared assay roles (narrower screening contract)

Supply an explicit, immutable set of intended paired target-site roles for a physical configuration before search. A role binds target occurrence, a legitimate desired target region/family, selected physical oligo/site species on both ends, orientation, full designated endpoints/anchors and permitted product geometry. It is part of the candidate's scientific dependency identity, not a label map or after-the-fact exemption list. Membership in the eleven supplied targets alone is insufficient.

For a first conservative exact-only role, require both complete oligos to match on the same fully observed row, inward geometry, the intended paired endpoints and desired150–250 bounds. Preserve all original specificity products; permit only the exactly certified occurrence. Shifted alternative occurrences, crossed roles, long products, uncertain footprints and mismatch-dependent products still block. Roles are pair-local and cannot combine a forward designation from one unrelated configuration with a reverse designation from another. If ordered secondary products are included at all, all four selected intended sites must form complete same-row ordered/disjoint roles on that target; external hits alone are insufficient.

This model makes unary validity stationary because the declared role set is known before selection. It can retain zero additional coverage credit initially, avoiding an unreviewed coverage extension. However it is a scientific policy change and needs an explicit versioned option/manifest, cache identity, allowed-witness certificate, provenance and fresh authoritative-row audit. It is not useful to claim broader target coverage until the objective also understands those products. On current evidence an exact-only implementation would not rescue the fixed panel; the model's primary value would be correct assay declaration, not a promised score increase.

Role origin must be justified independently of the rejection list: explicit assay specification, or target-specific intended site/family roles whose legitimacy was established by the current discovery/chemistry/geometry rules and deliberately included in the candidate model. A1 alignment coordinates cannot simply be reused in an unrelated A2 alignment. A manifest generated solely by labeling every rejected hit “intended” is circular.

### B. Atomic multi-target physical configuration (more complete future model)

Represent one selected physical oligo set with multiple explicit target-local paired roles, selected as a unit. This avoids the unreachable joint-state problem without changing unary validity to depend on the current pool. A minimal exact sharing case uses the same physical F/R species as legitimate target-local site pairs in two or more target families, with all roles present in the candidate before it is screened. Do not merge configurations merely because their coverage vectors happen to match.

The candidate's identity must bind the physical species and the ordered target-role records. For every target/class, credit only exact full binding of a declared pair on that same row and its own primer-trimmed interior, intersected with the observed mask. Never union forward support from one class with reverse support from another, and never award coverage from a mismatch-based screening certificate. Thus one physical selected object can legitimately contribute exact coverage to multiple target-specific observed-class vectors.

This is the scientifically cleaner representation if useful coamplification is intended, but it is a larger design. Current search queues and gain methods assume one candidate target; counts/caps, target-deficit priority, requested-size distance, amplicon burden and result BED naming also assume one target/family per configuration. These must get explicit definitions. Physical oligo burden and dimer/exposure count each species once per pool; biological products and coverage remain target-local. The objective must not double-count a physical tube solely because two target role records exist, nor erase a real product burden by calling it one configuration.

The intended/secondary evaluator should consume the immutable target-local role list rather than infer ownership from species-wide membership. Every predicted product must still have a complete matching certificate or reject. The candidate remains subject to **unchanged strict numerical dimer and cumulative physical-exposure rules**, uncertainty handling, pool placement, and all unintended-product checks. New roles do not authorize unrelated sites or make a dimer disappear.

## Recommended next work after full11 discovery

No production implementation yet. Use the finished finite catalogs to establish the data needed for role proposals: which exact physical F/R pairs occur as eligible target-local pairs across A1/A2/A4/B/E, on which full paired anchors, with what exact class support and reference/row geometry. This is a bounded candidate-role inventory, not automatic acceptance. Require independent target-local eligibility and explicit intended-region meaning. Compare both complete-exact products and remaining mismatch-dependent rejections for each proposed role bundle before predicting usefulness.

If the user chooses an assay contract permitting those specific coamplified regions, prefer atomic role bundles or immutable candidate role manifests over selection-state-dependent exemptions. Start with exact same-physical-pair sharing only; broader clouds, partial species overlap and mismatch-tolerant cross-target certificates can be separately considered if evidence and assay intent warrant them. Keep the old single-target representation/policy as the default/control and old artifacts readable.

A diagnostic can first evaluate the complete products of a **fixed proposed role manifest**, keeping every excluded witness and original strict audit result. It must not label the counterfactual as a validated design. This separates whether a scientifically declared role accounts for the observed product from whether the optimizer can exploit it and whether residual off-target products still reject it.

## Required invariants/tests for a future implementation

- Same physical pair/two explicit roles receives exact same-row coverage on each target, no cross-row or cross-target ends; class denominators and partial nonreference contributions remain unchanged.
- Adding another unrelated selected candidate cannot retroactively alter cached unary validity. Distinct role sets have distinct scientific IDs/dependencies. Original fixed-work behavior is unchanged under the default model.
- A valid role pair authorizes only its own complete occurrence. Shifted repeats, reversed/overlapping geometry, mixed ends, missing/ambiguous cells, outside-region products, mismatch-only support and undeclared targets remain blocked.
- Secondary certificates require all four complete paired roles on the witness row with correct ordered/disjoint geometry and physical ownership. Shared species do not permit owner mixing.
- Full exact coverage and screening permissions are separate. Nonexact intended/secondary certificates remain zero coverage unless a separately approved exact-support rule applies.
- Strict dimer scores, unique physical edges/species exposure and pool constraints are identical for the same physical contents, regardless of target role count.
- Role manifest tampering or raw-row changes invalidate fresh audit; source provenance identifies role origin and user declaration. All generated role candidates, failures, allowed products and discarded alternatives remain queryable.
- Old single-target outputs, cache interfaces and labels remain compatible. The eleven frozen discovery files should remain unchanged unless a separately reviewed discovery requirement actually arises.

## Ruling recommendation

The data supports investigating explicit shared target ownership, not a blanket exemption. The atomic multi-target model resolves the real unary/joint-state representation issue, but it should be scoped as a new scientific model after full11 evidence and assay intent are clear. For now retain defaults, report the cross-target restriction and exactness annotation, and avoid increasing effort budgets as a substitute for understanding candidate feasibility.

# 12S Abundance Reassignment Hardening — Plan

> REQUIRED SUB-SKILL: subagent-driven-development / executing-plans. Checkbox steps. TDD, commit per task. End commits with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Serialize swift, `--skip-update`. GREEN = failures ⊆ environmental/skipped, swift-testing 0, exit 0.

Spec: `docs/superpowers/specs/2026-06-02-twelve-s-abundance-reassignment-hardening-design.md`. Adjudication: memory `project-twelve-s-abundance-reassignment`.

## H1 — Reassigner: per-sample + policy (pure)
- [ ] Test: per-sample winner differs from global (X:A5000/B0, Y:A0/B800 → A→X, B→Y); pooled fallback only when local abstains; fallback blocked when global winner 0 local; conservative (2x+floor10) leaves 4-vs-3 unresolved but anyNonzeroLead resolves it; ties unassigned; conservation; Move carries sample + decidedBy.
- [ ] Implement `ResolutionPolicy` enum + per-`(sequence,sample)` Tier1/Tier2 logic; `Move{sequence,sample,toSpecies,toTarget,reads,decidedBy}`.
- [ ] Run `--filter LungfishWorkflowTests.TwelveSAbundanceReassignerTests`; commit.

## H2 — Workflow: reassigned channel + persisted reassignments.tsv + IO + integration test (M1)
- [ ] `ClassifiedReads.reassignedReadsBySample` + `reassignmentMoves`; `applyAbundanceReassignment` adds moved→reassigned (not exact), subtract ambiguous, store moves.
- [ ] `TwelveSAmpliconSampleResult.reassignedReads` (default 0); makeSamples sets it; `unresolvedReads = inputReads - exact - reassigned`; read-fate gains field.
- [ ] IO: manifest `reassignmentsTablePath: String?`; `TwelveSReassignmentRecord`; write/load `reassignments.tsv`; loader tolerates absence; bundle exposes `reassignments: [...]`.
- [ ] Integration test (M1): two refs identical core + abundance elsewhere → per sample `exact+reassigned+unresolved==input`, `ambiguous>=0`, `sum(counts[*][sample])==exact+reassigned`.
- [ ] Run workflow + IO tests; commit.

## H3 — Viewport: donor-row visibility
- [ ] Test: a species that is a reassignment donor (in candidateSpecies, not toSpecies) is NOT hidden by hide-zero even at 0 reads; old/empty reassignments → unchanged.
- [ ] Implement: VC reads `bundleData.reassignments`, exempts donors from the zero-row filter.
- [ ] Run leaf; commit.

## H4 — CLI `--ambiguity-resolution strict|conservative`
- [ ] Add flag to the 12S CLI command (default strict = anyNonzeroLead; conservative = (2.0,10)); thread into config → workflow → reassigner policy.
- [ ] Test the arg parse + mapping; commit. (Bump version sites only if a release is cut — not here.)

## H5 — Code-review M2 + L1
- [ ] M2: `TwelveSSampleMatrixColumns` percent-encode/decode the sampleID component; test `plate::A1` round-trip.
- [ ] L1: `TwelveSSpeciesLinks.wikipediaURL` encode `/`; test `X/Y` name.
- [ ] Run leaf; commit.

## H6 — Full suite + GUI smoke
- [ ] `swift test --skip-update > /tmp/12s-h.log 2>&1; echo SWIFT_EXIT=$?` → green.
- [ ] GUI smoke (needs computer-use MCP): re-profile a human/pan-style dataset; confirm reassignment, donor row visible, reassignments.tsv exported; conservative flag reduces low-margin moves.

## Self-review
- Spec coverage: per-sample→H1, persist/channel→H2, donor-vis→H3, configurable→H1+H4, M1→H2, M2/L1→H5. All covered.
- Back-compat: manifest path optional; sample field defaulted; empty reassignments → legacy behavior. Existing bundles load unchanged.
- Conservation re-asserted in H1 unit + H2 integration.

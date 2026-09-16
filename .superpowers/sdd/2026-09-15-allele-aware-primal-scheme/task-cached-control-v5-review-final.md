# Cached-control v5: independent root review

Approved external runner after full source review and follow-up fixes. Preparation now starts inside a retained minimal-receipt envelope; individual missing-input and output-inventory errors preserve the primary failure. Existing output locations are rejected before creating an execution directory. Repeated MSA paths retain explicit order. Options JSON and all resolved native configuration values are retained; source/runtime and cache/input byte identities are checked. Cwd and UTC timestamps make relative argv reproducible; wrapper wall time includes final checks.

The first independent test invocation exposed a pytest7 xunit naming collision (`setup` helper), not a production failure. Renaming it to `make_fixture` fixed portability. Root reran the exact frozen matrix10 interpreter: **6 passed in 0.09s**, exit0.

Root then executed a real bounded reuse of the preexisting single-target tiny cache through frozen matrix10. `v5-small-cache-smoke-01` native panel and fresh audit both exit0; wrapper exit0/success in5.944228834s, `discovery_reused=true`, both identity invariants true and no secondary errors. Receipt: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/v5-small-cache-smoke-01-execution/provenance.json`. The original cache/source remain unchanged. Multi-target argument order is unit-tested; this smoke does not substitute for the pending real11target comparison.

Reviewed runner SHA-256: `e3bd97df791bbc0eb8f4a3b103a4ee08c9a7488b7d6b1ad9cc38bf1e8103bcd1`. Live hour-run wrapperv4 and frozen evaluations were not edited.

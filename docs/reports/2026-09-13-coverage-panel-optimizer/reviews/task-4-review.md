# Task 4 review

Reviewed `be8c1ce..cbcdde0` on `codex/coverage-panel-optimizer`.

- Spec compliance: **FAIL**, pending the two important fixes below.
- Code quality: **NEEDS FIXES**.
- Findings: 0 critical, 2 important. No algorithm-core changes requested.

## Important findings

### 1. [P1] A failed forced rerun retains the previous run's success provenance

Location: `primalscheme3/panel/panel_main.py:660–667`, particularly the `not provenance.exists()` condition at line 666; input replacement occurs at lines 200–202.

`--force` permits reuse of an existing output. If that output contains `panel-provenance.json` from a successful run, a failure while reading/discovering the new inputs occurs before `run_coverage_pipeline` gets control. The outer failure handler skips finalization because the old provenance already exists. The directory then contains newly overwritten inputs/log bytes with an unchanged `status: success`, `exitStatus: 0` record from the prior run. This violates the explicit failure-record and final-byte provenance requirements.

Minimal reproducer executed with `.venv/bin/python`, using only a temporary synthetic input and mocked discovery:

```python
opts = dict(selection_algorithm="coverage", amplicon_size=200,
            amplicon_size_min=150, amplicon_size_max=280,
            amplicon_size_metric="reference-span", mismatch_product_size=2000)
src.write_text(">ref\nACGT\n")
(out / "work").mkdir(parents=True)
(out / "panel-provenance.json").write_text(
    '{"status":"success","exitStatus":0,"marker":"previous run"}')
with patch("primalscheme3.panel.panel_main.PanelMSA",
           side_effect=RuntimeError("synthetic new-run discovery failure")):
    try:
        panelcreate([src], out, Config(**opts), None,
                    mode=PanelRunModes.EQUAL, force=True)
    except RuntimeError:
        pass
```

Observed: `work/0000-in.fasta` exists from the new attempt, while the provenance remains exactly `{'status': 'success', 'exitStatus': 0, 'marker': 'previous run'}`.

Required fix: track whether this invocation has begun modifying the output and whether it finalized provenance for this invocation. Once a forced run starts, an early failure must replace/invalidate prior success evidence and write this attempt's failure record with the current final-byte inventory. Do not equate file existence with current-run finalization. Preserve the existing directory on rejected preflight/non-force calls; the current handler can also add a failure manifest to a pre-existing directory that lacks one even when execution was rejected before output creation.

Regression: prepopulate a successful output, force a mocked discovery failure, and verify failure status/argv/input identity plus hashes for all final descriptors. Also verify rejected preflight/non-force calls leave existing outputs unchanged.

### 2. [P2] Validate coverage numeric settings before coercion and before scientific execution

Locations: `primalscheme3/core/config.py:129–161` and `:297–300`; coverage CLI discovery settings at `primalscheme3/cli.py:454–465`.

The constructor calls `assign_kwargs` before integer validation. Its `int(value)` coercion makes the subsequent `type(...) is int` checks ineffective for fractional new optimizer values. The pre-coercion boolean guard covers only the five optimizer fields, leaving coverage profile integers such as pool count and product bound silently accepting booleans. Separately, coverage does not reject nonfinite discovery settings at its public boundary: Click's numeric range handling does not reject NaN.

Targeted observed results with the valid coverage settings above:

```text
Config(..., optimizer_starts=1.7).optimizer_starts == 1
Config(..., optimizer_seed=1.7).optimizer_seed == 1
Config(..., optimizer_repair_rounds=1.7).optimizer_repair_rounds == 1
Config(..., n_pools=True).n_pools == 1
Config(..., mismatch_product_size=True).mismatch_product_size == 1
```

With `primalscheme3.cli.panelcreate` mocked, `CliRunner` invoked a fully specified valid coverage command (`--mode equal --amplicon-size 200 --amplicon-size-min 150 --amplicon-size-max 280`) plus either `--dimer-score nan` or `--min-base-freq nan`. Both returned exit 0 and called the workflow. Thus they pass the boundary that must reject invalid options before output creation/discovery. Profile construction is currently after discovery and cannot provide that boundary; minimum base frequency is also outside its thermochemistry checks.

Required fix: validate the new integer optimizer values before lossy conversion, and validate coverage's scientific/discovery numeric settings for finite values, declared ranges, and non-boolean integer identity at construction/public entry. Scope changes for existing scientific Config fields to coverage so historical legacy Config coercion and programmatic legacy product-size behavior remain compatible. Add direct Python fractional/boolean cases and CLI NaN cases using otherwise fully valid coverage arguments, asserting rejection before workflow/output creation.

## Reviewed behavior that meets the contract

- Coverage branches after existing discovery and bypasses legacy selection/MatchDB state; shared scientific candidates are not mutated by detached pair construction or projected report views.
- Frozen assignment records control both native full/interior BED geometry and stable semantic amplicon naming. Reference IDs and source copies retain duplicate target occurrences; projected plots declare their coordinate system.
- Successful native artifacts link the versioned catalogue, optimizer, validation and provenance contracts. Catalogue semantic identity and compressed-byte identity have distinct fields. The offline plot setting added by `cbcdde0` is now recorded in completed config/resolved options.
- Capabilities identify the actual local package, editable source files/build, dependency versions, Python environment and native extension bytes. Start/end source/runtime identities and durable consumed copies support reproducibility. Final success hashing occurs after logging and excludes only the provenance file to avoid a cycle.
- Feasible empty publication, cloud/count preservation, gapped projected plots and relocation/final-byte checks are present in focused tests. Root independently verified the human C/E smoke's 17 output descriptors, two durable inputs, assignment/geometry/coverage correspondence, and reported 117 passing fork tests. Those results are accepted as supplied evidence, not represented as reviewer reruns.

The reviewer ran only the bounded reproductions above; no broad biological workflows, implementation edits, dependency installs, delegates or pushes. The remaining fixes concern failure ownership and input validation, not the separately reviewed search/scientific-rule core.

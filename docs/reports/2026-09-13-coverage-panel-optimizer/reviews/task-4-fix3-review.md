# Task 4 fix round 3 review

Reviewed `a0e3313..39aea29`, the Task 4 contract, the fix report, and the adjacent finalization/caller paths necessary to assess log ownership. Review scope is the reported cross-invocation mutation of finalized output bytes.

- Open final-byte logging finding: **ADDRESSED**.
- Spec compliance: **PASS for this scoped fix**.
- Code quality: **PASS**.
- Important new breakage in the fix diff: **none identified**.

## Finding disposition

The original selected-run log was finalized at 78,732 bytes, then grew by an 81-byte completion record from a later coverage invocation. Moving the run output file handler off the root logger removes that cross-invocation destination: only the named run logger now owns and emits to its output file, while console handling remains on the root logger.

The new `close_owned_file_handlers` helper flushes the run-owned stream, removes its handler from the logger, and closes the stream/handler before provenance inventories output files. Later records through either that same logger or another logger therefore have no retained handler capable of appending to the finalized output. Ownership is explicit and scoped; unrelated root/application handlers are not reset or closed.

The early public-entry failure path now retains and forwards its run logger through `_CoverageInvocationState`, so it uses the same file-close boundary as successful or failed pipeline finalization. The earlier output-ownership/current-finalization decisions remain unchanged. No scientific thresholds, option defaults, capability schemas, output artifact paths, managed identities, or algorithm semantics are changed here.

The logger helper is production lifecycle code used by setup and provenance finalization, not a production test-only helper. A call-site read found the native workflows use the returned logger; the diff does not introduce an important loss of native run logging. Closing owned handlers before reopening a same-named logger also prevents retained duplicate file handlers.

## Evidence and verification

Accepted supplied evidence, not reviewer reruns:

- Exact two-run producer reproduced RED with the first log growing from 78,732 to 78,813 bytes and a second completion record.
- `.venv/bin/python -m pytest tests/lge/test_coverage_publication.py::test_finalized_file_log_stays_byte_stable_during_later_coverage_run -q`: RED 1 failed, then GREEN 1 passed.
- `.venv/bin/python -m pytest tests/lge/test_coverage_publication.py tests/lge/test_coverage_cli.py -q`: 54 passed.
- Exact producer-derived GREEN retained a single completion record and 78,732 log bytes; all 15 selected-run and 14 empty-run descriptors matched final bytes.
- `.venv/bin/python -m pytest tests/lge -q`: 141 passed.
- Reported scoped Ruff/format/compile/diff checks passed.

The regression exercises the original mechanism by removing existing test root handlers temporarily, setting up the normal run file logger, finalizing the first pipeline, running a second pipeline through another logger, and verifying unchanged first-log bytes plus every recorded descriptor. Its root-logger restoration is confined to test cleanup.

Reviewer independently read the diff and relevant source/call sites, ran `git diff --check a0e3313..39aea29` (clean), and confirmed a clean tracked worktree. No unresolved concern required repeating the reported tests. No production edits, delegates, scientific runs, installed-package changes, prior-output overwrites, publication, managed-pin changes, or broad suite runs were performed. Only this ignored scratch report was written.

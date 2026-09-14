# Task 5 fix round 2 review

Reviewed LGE `5a9cb1f44..bc535d90f`, the support-semantics finding in `task-5-fix1-review.md`, final Task 5 constraints, fix report, changed Swift implementation/tests, and the new fixture generator/record.

- Open support-diagnostics false rejection: **ADDRESSED**.
- Scoped spec compliance: **PASS**.
- Code quality: **PASS**.
- Important new breakage in this fix diff: **none identified**.

## Finding disposition

The wrapper now preserves the distinction between catalogue unknown-only rows and fresh uncertainty diagnostics. It retains exact catalogue/fresh equality for confirmed `joint_rows` and `row_product_spans`, while checking:

```text
freshUnknown - freshJoint == catalogueUnknown
```

This matches the actual native catalogue `elif` and fresh-validator separate-`if` semantics. Fresh uncertainty may overlap confirmed joint support without becoming a publication error. The wrapper retains the original fresh diagnostic bytes; it does not erase uncertainty, rewrite native science, or promote unknown-only support.

The surrounding checks remain strict: complete selected-candidate support keys, exact known diagnostic fields, typed nonempty row identifiers, unique target/joint/unknown rows, known-row membership, typed positive-span coordinates, unique spans, and catalogue product-row/joint-row correspondence. Confirmed joint/product support must still match exactly. The change is confined to the differing meaning of the unknown-row lists.

## Regression evidence

The new compact D=199 fixture exercises the exact previously rejected native-valid case: a 23/24-base forward cloud, an uncertain base confined to the longer member's extra footprint, two confirmed joint rows, and a fresh unknown diagnostic on the second joint row. Its generation record explicitly declares deterministic manual candidate construction through real native FKmer/RKmer objects and execution through normal catalogue/optimizer/fresh-validator/export/provenance APIs. It does not claim public discovery produced that candidate. Presentation stubs are declared, and the earlier public-discovery fixtures remain available.

The positive Swift regression publishes the fixture and reads the final stored validation artifact to verify that joint/unknown overlap survived. The negative loop mutates unknown row identity, unknown-row duplication, a span coordinate to boolean/malformed data, confirmed joint rows, and product spans. Those mutations synchronize embedded validation and refresh native descriptors, then require semantic support errors and an absent destination. The existing missing-support regression remains.

Accepted supplied verification, not reviewer reruns:

- Positive fixture RED before the production fix: `Validation support diagnostic differs from the selected catalogue candidate.`
- Targeted positive/negative support tests: 2 passed.
- `swift test --skip-update --filter 'PrimalScheme3DesignPipelineTests|PrimalScheme3PublicationTests|PrimerDesignCommandTests'`: 35 passed.
- `swift build --skip-update --product lungfish-cli`: succeeded; reported help checks passed.
- New native fixture: one valid assignment, matching joint/spans, preserved fresh uncertainty, and 15 matching final-byte descriptors.

Reviewer inspected the actual diff and generator, ran source/test/generator scoped `git diff --check` successfully, and confirmed a clean tracked worktree. No unresolved concern required repeating the supplied tests or native generation. No production/test edits, delegates, biological runs, installed/managed/original-worktree changes, prior-output overwrites, pins, GUI, release or remote changes were performed. Only this ignored scratch report was written.

This approves the Task 5 fix gate; the final whole-branch review remains a separate step after Task 6.

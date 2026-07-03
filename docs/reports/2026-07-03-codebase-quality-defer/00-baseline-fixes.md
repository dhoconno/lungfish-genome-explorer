# Baseline fixes (pre-refactor)

Before any refactoring began, the green-bar baseline run on untouched `main`
surfaced two pre-existing NON-environmental test failures. Per the user's
decision ("fix both first, then baseline"), both were root-caused and fixed as a
dedicated pre-refactor commit so the refactor gates against a truly clean tree.
Neither failure was caused by the refactor.

## 1. ViewerViewController concurrency-lint failure

Test: `AppKitConcurrencyModalSafetyTests.testTargetedAppKitCallbacksAvoidUnsafeMainActorTaskHops`.

Root cause: `runMSAInPlaceAnnotationAction` bridged a `Task.detached`
(background) block back to the main actor with the banned
background-to-main-actor Task hop, to `await` a main-actor async call
(`controller.displayBundle`). The correct pattern was already used 20 lines below
in the same function's error handler.

Fix: `CLIMSAActionRunner` is an actor, so `runner.run` executes off the main
actor regardless of the launching context. Switched the outer `Task.detached` to
a main-actor `Task`, so the CLI work still runs off-main (actor-isolated + async)
while the follow-up UI work is natural main-actor code with no forbidden hop.
Also removed a redundant explicit `@MainActor` annotation on the `Task` in
`ViewerViewController+Mapping.presentMappingConsensusExtraction` (the method is
already `@MainActor`-isolated, so the annotation had no behavioral effect but
tripped the lint's substring scan).

Note for reviewers: the lint test does a naive substring match on the literal
`Task {` followed by `@MainActor`, so even a source *comment* containing that
literal trips it. Comments describing the pattern must avoid the exact string.

## 2. MHC reference-bundle external-open routing failure

Test: `MappingViewportRoutingTests.testExternalOpenMHCReferenceBundlePopulatesInspectorAndProvenanceTarget`.

Root cause: commit `89321935` ("perf: move MHC reference bundle FASTA file read
off the main actor") converted `displayMHCReferenceBundleFromExternalOpen` into a
fire-and-forget async method. The test calls it and synchronously checks that the
inspector document state, provenance target, and viewport controller are
populated; with the async version none of that had happened yet on return.

Fix: reverted this one-shot external-open path to the synchronous `load` it used
before `89321935`, matching its non-MHC sibling
`displayReferenceBundleFromExternalOpen` (which also reads synchronously). The
sidebar path keeps `loadAsync`, where rapid navigation can spam large reference
reads and the off-main read genuinely matters. External open is a one-shot Finder
double-click / Open Recent, so a brief synchronous read is acceptable and keeps
the inspector and viewport populated together on return.

No deferrals from this pre-refactor step; both fixes are complete and verified by
the affected suites plus the full green-bar run.

# Wave 1 AppKit Polish Plan

Goal: make low-risk AppKit/HIG cleanup changes in `codex/wave1-appkit-polish` without touching scientific data workflows or other workers' worktrees.

## Scope

- Add `hasDestructiveAction` to destructive `NSAlert` first buttons in the named UI files, preserving the existing `AnnotationTableDrawerView` exemplar.
- Replace stale `.texturedRounded` button and segmented-control styles with modern local AppKit styles.
- Delete `MapReadsWizardSheet` only if source search confirms it has no production instantiations; remove tests only when they are exclusively tied to that dead dialog.
- Rename `Tools > Search Online Databases...` to `Tools > Search Online Databases` while keeping submenu entries unchanged.
- Migrate only directly touched `runModal` sites when sheet conversion is local and low risk; otherwise leave a short remaining-sites note.

## Test Strategy

- Add focused source-level regression tests for destructive-alert flags, deprecated textured styles, menu title, dead dialog removal, and remaining `runModal` inventory where UI automation would be excessive.
- Run targeted Swift tests for those source-level checks.
- Run a build or targeted compile/test command for the App target if the local toolchain permits it.

## Risks

- Some alert flows are synchronous by design; broad async sheet conversion is out of scope for this polish pass.
- Removing `MapReadsWizardSheet` should be limited to source/test references and avoid archive documentation churn.

## Remaining `runModal` Sites In Touched Files

- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift` still has synchronous save/delete/name/run prompts; converting these requires callback or async restructuring beyond this low-risk polish pass.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift` still has fallback/status alerts in helper paths; the primary deletion confirmations already use sheets.
- `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift` still has add/edit dialog confirmations using `runModal`; these are not touched by the destructive-alert cleanup.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` retains the no-window fallback for derived-alignment removal.

# Initial GitHub Issue Triage: Issues #6-#13

Date: 2026-05-08
Mode: triage plus authorized GitHub feedback mutation; labels and comments applied, no closures or assignments applied.
Repository: `dhoconno/lungfish-genome-explorer`

## Summary

Issues #6 through #13 are all actionable alpha feedback. The batch splits into four implementation tracks:

- Repository hygiene and agent safety: #6.
- Workspace and layout state persistence: #7, #10, with #8 depending on durable filter state.
- Scientific result exploration and alignment interaction polish: #8, #9, #11.
- Operations panel macOS behavior and debugging access: #12, #13.

No issue in this batch should be closed during initial triage. The public response posture is acceptance with clear routing, while avoiding any claim that implementation has already happened.

## Refreshed Issue State

`gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 50 --json number,title,labels,author,createdAt,updatedAt,url` showed issues #6 through #13 open on 2026-05-08. All eight issues were authored by `nrminor` and had no labels at the initial refresh time.

Each issue was then inspected with `gh issue view <number> --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`. None had comments at refresh time.

After the maintainer clarified that comments and closures are acceptable forms of feedback, this pass moved from read-only triage into authorized feedback mutation. Reusable labels were created, labels were applied issue by issue, and acceptance comments were posted. All eight issues remain open.

## Label Gaps

Only the default repository labels were available at refresh time: `bug`, `documentation`, `duplicate`, `enhancement`, `good first issue`, `help wanted`, `invalid`, `question`, and `wontfix`.

The following reusable labels were created for issue routing:

- `status:accepted`
- `area:developer-experience`
- `area:session-state`
- `area:classification`
- `area:alignment`
- `area:layout`
- `area:tables`
- `area:operations-panel`
- `risk:provenance`
- `risk:scientific-correctness`
- `risk:privacy`

## Issue-By-Issue Dispositions

### #6: Developer request: Switch to deny-by-default .gitignore so unwanted files are not accidentally committed by agents

Disposition: accepted.

Rationale: This is valid developer-experience and repository-hygiene work. The current `.gitignore` is allow-by-exception in some areas but still primarily deny-by-pattern; the issue links a concrete accidentally tracked `.superpowers/brainstorm/.../state` path. A deny-by-default policy is a reasonable response for a repo with autonomous agent commits, but it needs a careful implementation plan to avoid dropping required SwiftPM, Xcode, docs, fixtures, resources, and provenance-related test artifacts.

Proposed labels: `enhancement`, `status:accepted`, `area:developer-experience`.

Implementation track: repository hygiene. Route through Development Lead because the change affects packaging, fixtures, docs generation, Xcode project files, and agent workflows.

Proposed public comment:

> Accepted. This is a good repository-safety improvement for an agent-heavy project, and the accidentally tracked `.superpowers` state is a concrete example of the risk. I want to handle it as a careful repo-hygiene change rather than a quick `.gitignore` swap, because we need to preserve SwiftPM, Xcode, docs, fixture, resource, and provenance test artifacts that are intentionally tracked. I will route this into a developer-experience implementation slice for a deny-by-default policy plus verification that required tracked assets remain visible to git.

### #7: [Request]: Save more session state that can be reloaded at startup

Disposition: accepted.

Rationale: Lungfish already has some bundle view-state persistence via `.viewstate.json`, including annotation/variant display and navigation fields, but the report correctly identifies broader workspace/session state gaps such as alignment viewport position and filter overlays. This should become a deliberate session-state model rather than one-off per-view defaults.

Proposed labels: `enhancement`, `status:accepted`, `area:session-state`.

Implementation track: workspace/session persistence. Route through Project Lead Phase 0 and Development Lead for a state schema that covers bundle-local view state, app-window state, pane layout, filters, and alignment viewport state without storing sensitive data.

Proposed public comment:

> Accepted. Lungfish has some bundle-level view-state persistence today, but this report points at the broader session-resume behavior users will expect: alignment viewport position, active filters, pane layout, and other view-specific context. I will route this as a session-state design slice so we can define what belongs in portable bundle state versus local app preferences, and so related work like #8 and #10 can share the same persistence model.

### #8: [Request]: Inverted (exclude-style) filtering and boolean filter sets

Disposition: accepted.

Rationale: Exclude filters and boolean composition are directly useful for classification and table exploration workflows, especially viral/metagenomic result review where high-frequency background taxa can dominate. The request carries scientific-correctness risk because filter semantics must be explicit, inspectable, and preserved across resumed sessions and exports.

Proposed labels: `enhancement`, `status:accepted`, `area:classification`, `area:tables`, `area:session-state`, `risk:scientific-correctness`.

Implementation track: classifier/table filter model. Route through Development Lead and Data Integrity & Provenance review for a structured filter expression model, visible active-filter UI, deterministic serialization, and tests for AND, OR, and NOT semantics.

Proposed public comment:

> Accepted. Exclude-style filters and boolean filter composition fit the way users inspect metagenomic classifier output, especially when common background taxa crowd out the taxa of interest. I will route this into the classifier/table filter model rather than treating it as a cosmetic control change, because the filter logic needs explicit AND, OR, and NOT semantics and should persist cleanly with the session-state work in #7.

### #9: [Request]: Improvements to alignment UX

Disposition: accepted.

Rationale: Native-feeling panning and zooming are appropriate expectations for alignment views. The issue should be scoped as interaction polish for alignment viewport controls, with collapse/minimize needs coordinated with #10 so alignment-specific work does not invent a separate pane model.

Proposed labels: `enhancement`, `status:accepted`, `area:alignment`, `area:layout`.

Implementation track: alignment interaction polish. Route through GUI Lead for trackpad/mouse interaction behavior, accessibility, and AppKit gesture handling, then Development Lead for testable viewport-state updates.

Proposed public comment:

> Accepted. Alignment views should support native-feeling mouse and trackpad navigation, including horizontal and vertical panning plus pinch zoom where the viewport supports it. I will route the interaction work through the alignment UI track, and keep the collapsible/minimizable pane portion linked to #10 so pane behavior stays consistent across the app.

### #10: [Request]: All panes should be collapsible

Disposition: accepted.

Rationale: Collapsible panes are a good fit for a dense native genomics workbench and are related to #7 because user layout choices should persist. The scope should be "systematic pane collapse and restoration" rather than draggable editor-style pane rearrangement, at least for the first implementation.

Proposed labels: `enhancement`, `status:accepted`, `area:layout`, `area:session-state`.

Implementation track: pane collapse and layout persistence. Route through GUI Lead and Development Lead for a shared split-view/pane policy that covers sidebar, inspectors, result tables, alignment views, and metagenomics panes without breaking minimum useful sizes.

Proposed public comment:

> Accepted. Collapsible panes are a strong fit for Lungfish because users need both focused inspection and dense multi-pane context. I will route this as shared layout infrastructure tied to the session-state work in #7. The first pass should focus on consistent collapse/restore behavior and persistence, not full editor-style pane rearrangement.

### #11: [Request]: Columns in table explorers should have units and/or column descriptions on mouse hover

Disposition: accepted.

Rationale: Table columns in scientific result explorers need discoverable units and meanings. This is especially important for generated metadata, classifier metrics, variant fields, and alignment statistics where labels can be terse. The implementation should avoid ad hoc tooltip strings scattered through views by creating reusable table-column metadata.

Proposed labels: `enhancement`, `status:accepted`, `area:tables`, `risk:scientific-correctness`.

Implementation track: table metadata and tooltip work. Route through GUI Lead plus Data Integrity & Provenance for scientific field definitions and units.

Proposed public comment:

> Accepted. Table column units and descriptions would make result explorers more understandable without adding visual clutter. I will route this as reusable table-column metadata so tooltips and headers can share consistent field definitions, especially for classifier metrics, variant fields, alignment statistics, and generated metadata columns.

### #12: [Bug]: The operations panel always floats on top of other windows

Disposition: accepted.

Rationale: The report matches the current implementation: `OperationsPanelController` creates an `NSPanel` and sets `panel.isFloatingPanel = true`. This is a user-facing macOS window-behavior bug because it prevents normal layering and can consume limited screen space during long-running operations.

Proposed labels: `bug`, `status:accepted`, `area:operations-panel`.

Implementation track: operations panel window behavior. Route through GUI Lead. Likely first slice is to remove floating behavior or make it optional while preserving menu access, operation progress visibility, and keyboard behavior.

Proposed public comment:

> Accepted. This matches the current operations panel implementation: it is configured as a floating panel, which makes it behave differently from a normal macOS window. I will route this as an operations-panel window-behavior bug. The likely fix is to make the panel layer normally, or make always-on-top behavior an explicit option rather than the default.

### #13: [Request]: A more obvious pathway to access operation debug logs from the operations panel

Disposition: accepted.

Rationale: The operations panel currently exposes inline log detail and context-menu copy actions, and README guidance says the Operations Panel can export run logs. The request asks for a clearer first-class path to view logs and reveal them in Finder. This is valuable for debugging and public issue reporting, but carries privacy risk because logs may include local paths, commands, accessions, and possibly sensitive user data.

Proposed labels: `enhancement`, `status:accepted`, `area:operations-panel`, `risk:privacy`.

Implementation track: operations panel log access. Route through GUI Lead plus Security & Input Validation for log redaction and safe sharing guidance. Coordinate with provenance requirements for scientific workflow outputs so logs and provenance remain distinct but cross-referenceable.

Proposed public comment:

> Accepted. The operations panel already has inline logs and copy actions, but the access path is not obvious enough for debugging. I will route this as an operations-panel enhancement for clear actions such as View Log and Reveal in Finder. We should also review the privacy boundary while implementing it, because operation logs can include local paths, commands, and dataset identifiers that users may not want to paste into a public issue.

## Grouped Implementation Tracks

### Track A: Repository Hygiene

Issues: #6.

Recommended owner: Development Lead.

Scope: create a deny-by-default `.gitignore` and verification checklist that confirms required source, project, docs, fixtures, resources, and provenance test artifacts remain tracked. Include a `git ls-files` or packaging validation step so the change does not silently hide necessary files from future commits.

### Track B: Session State And Layout Persistence

Issues: #7, #10, related portion of #8 and #9.

Recommended owners: Project Lead, Development Lead, GUI Lead.

Scope: define durable local and bundle-portable state boundaries. Persist alignment viewport position, active filters, pane collapse state, and split positions where appropriate. Avoid storing private paths or sensitive workflow data in portable shared bundles unless already part of the scientific bundle contract.

### Track C: Scientific Explorer Interaction And Metadata

Issues: #8, #9, #11.

Recommended owners: GUI Lead, Development Lead, Data Integrity & Provenance.

Scope: add explicit filter expressions with AND, OR, and NOT; improve alignment panning and zooming; introduce reusable column metadata for table tooltips and units. Verify filter semantics with tests because incorrect filtering can change scientific interpretation.

### Track D: Operations Panel Behavior And Debugging

Issues: #12, #13.

Recommended owners: GUI Lead, Security & Input Validation.

Scope: make operations panel layering match macOS expectations and add visible log actions. Preserve existing copy/report affordances while adding View Log and Reveal in Finder flows. Redact or warn before public sharing when logs may contain sensitive paths, commands, or dataset identifiers.

## GitHub Mutations Applied

GitHub feedback mutation was authorized after the initial read-only pass. Labels were created or updated with reusable descriptions, proposed labels were applied, and public acceptance comments were posted:

- #6: `enhancement`, `status:accepted`, `area:developer-experience`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/6#issuecomment-4402657257`.
- #7: `enhancement`, `status:accepted`, `area:session-state`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/7#issuecomment-4402657372`.
- #8: `enhancement`, `status:accepted`, `area:classification`, `area:tables`, `area:session-state`, `risk:scientific-correctness`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/8#issuecomment-4402657502`.
- #9: `enhancement`, `status:accepted`, `area:alignment`, `area:layout`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/9#issuecomment-4402657659`.
- #10: `enhancement`, `status:accepted`, `area:layout`, `area:session-state`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/10#issuecomment-4402657780`.
- #11: `enhancement`, `status:accepted`, `area:tables`, `risk:scientific-correctness`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/11#issuecomment-4402657877`.
- #12: `bug`, `status:accepted`, `area:operations-panel`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/12#issuecomment-4402657995`.
- #13: `enhancement`, `status:accepted`, `area:operations-panel`, `risk:privacy`; comment posted at `https://github.com/dhoconno/lungfish-genome-explorer/issues/13#issuecomment-4402658114`.

All eight issues were intentionally left open. No assignees were set; implementation sequencing remains with the Project Lead and downstream expert teams.

## Verification Notes

Commands used during triage:

- `gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 50 --json number,title,labels,author,createdAt,updatedAt,url`
- `gh issue view 6 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh issue view 7 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh issue view 8 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh issue view 9 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh issue view 10 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh issue view 11 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh issue view 12 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh issue view 13 --repo dhoconno/lungfish-genome-explorer --json number,title,body,labels,comments,url,createdAt,updatedAt,state,author`
- `gh label list --repo dhoconno/lungfish-genome-explorer --limit 100`
- `gh label create|edit ... --repo dhoconno/lungfish-genome-explorer`
- `gh issue edit <number> --repo dhoconno/lungfish-genome-explorer --add-label ...`
- `gh issue comment <number> --repo dhoconno/lungfish-genome-explorer --body ...`
- `gh issue list --repo dhoconno/lungfish-genome-explorer --state open --limit 20 --json number,title,labels,url`
- `sed -n '1,220p' .gitignore`
- `sed -n '1,120p' Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`
- `sed -n '930,1040p' Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`
- `sed -n '1088,1145p' Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`
- `sed -n '1,180p' Sources/LungfishCore/Bundles/BundleViewState.swift`

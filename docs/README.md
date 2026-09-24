# docs/

What lives here, and the rule that keeps it small.

## Product documentation (living, stays forever)

- `user-manual/` — the user manual: chapters, `features.yaml`, `parameters.yaml`,
  `help-ids.yaml`, `illustrations.yaml`, `GLOSSARY.md`, `ARCHITECTURE.md`, build
  scripts, lint rules, and image/screenshot recipes. Media referenced by chapters
  is fetched from a separate media repo at build time; see
  `user-manual/media.lock` and `user-manual/build/scripts/fetch-media.sh`.
- `release-notes/` — one file per shipped version. Never deleted.
- `release/` — release process documentation.
- `design/` — durable design references that outlive any one plan (for example
  `viewport-interface-classes.md`, the shared viewport-class contract cited by
  the documentation-lead and code-cartographer agents).
- `formats/` — file-format references.
- `site/` — the GitHub Pages landing site (Quarto).
- `help/` — in-app Help Book source notes.
- `development.md`, `development/` — contributor-facing developer docs.

## Working memory (delete when the work finishes)

- `superpowers/plans/`, `superpowers/specs/` — implementation plans and design
  specs for work in progress. **When a plan's work merges, delete its plan and
  spec in the same commit that completes the work.** Git history preserves
  them; nothing here is archived.
- `plans/`, `product-specs/`, `proposals/`, `verification/`, `issues/`,
  `features/` — other in-flight planning and verification records. Same rule:
  delete once the described work has shipped.
- `reports/` — investigation and audit reports. Delete a report once its
  findings are resolved or superseded, unless it is still cited as evidence
  by release notes, a test-file comment, a script, or another active report
  (in which case keep it, or replace the citation with a commit-pinned GitHub
  URL and delete the file).

## The rule

Plans, specs, reviews, and reports are agent working memory, not product
documentation. Keeping them after their work ships makes `git log` and code
review noisy, encourages copying stale guidance (a dead dialog template, a
deleted file path), and is most of this repository's documentation churn.

**Delete finished plans, specs, and reviews in the commit that completes the
work they describe.** Do not move them to an archive directory or a separate
repository — git history already has them, and nobody should need to browse
"old plans" as a first-class location. If you are unsure whether a plan's
work has merged, check `git log` and open branches; when genuinely unsure,
keep it rather than delete it.

This rule is also stated in `agents/README.md`, `agents/process/PROJECT-LEAD-AGENT.md`,
and `SKILLS.md` for agents that write plans and reports.

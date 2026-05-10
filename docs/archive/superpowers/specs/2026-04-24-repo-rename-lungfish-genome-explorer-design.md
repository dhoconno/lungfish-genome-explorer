# Repo Rename: Lungfish Genome Explorer — Design Spec

**Date:** 2026-04-24
**Status:** Draft for review
**Scope:** Spec 1 of 3 in the "From reads to variants" documentation program
**Related specs:** Spec 2 (`2026-04-24-bam-primer-trim-and-primer-scheme-bundles-design.md`), Spec 3 (`2026-04-24-reads-to-variants-chapter-artifacts-design.md`)

---

## 1. Context

The GitHub repository has been renamed from `lungfish-genome-browser` to `lungfish-genome-explorer`, and the product itself is now called the **Lungfish Genome Explorer** rather than the Lungfish Genome Browser. Locally, the working copy, git remote, prose across the docs and design trees, and the Claude Code memory directory still carry the old name. This spec defines the rename sweep that brings the local state into alignment with the online state.

## 2. Goals and non-goals

### Goals

- Rename the local working directory to `lungfish-genome-explorer`.
- Update the `origin` git remote to the new repository URL.
- Replace the user-facing product name "Lungfish Genome Browser" with "Lungfish Genome Explorer" in active documentation, README, and design docs.
- In `README.md` specifically, also replace bare user-facing "Lungfish" (when it refers to the product) with "Lungfish Genome Explorer," since the README is the first thing a reader sees and needs the full product name consistently. This rule applies to `README.md` only; the user manual and other docs continue to use "Lungfish" as the short form after a first full-name introduction (see §4.3 for the rule).
- Sweep absolute path references in markdown files (specs, plans, TODOs, agent definitions, memory) to the new path.
- Move the Claude Code memory directory to match the new path.
- Leave the `swift build` pipeline working from the new directory with no further changes.

### Non-goals

- Changing commit messages, historical design-doc preambles, archived session logs, or any content whose value lies in accurately reporting what was true at a past moment. Rename is for active content only.
- Renaming Swift module names (`LungfishCore`, `LungfishApp`, etc.). They never encoded "Browser."
- Changing the app bundle identifier, binary name, or anything in `Info.plist` beyond what this sweep surfaces. A separate audit will confirm whether any marketing-name fields need updating; this spec does not pre-emptively touch them.
- Touching `build/Release/Lungfish.app`. The shipped app binary uses the display name "Lungfish" and does not need rebuilding for this rename.
- Any remote-side operation on GitHub. The rename was done already on the GitHub side; this spec is local-only.

## 3. Inventory

A `grep` across `docs/`, `README.md`, and `.claude/` against the patterns `Lungfish Genome Browser`, `genome-browser`, and `lungfish-genome-browser` returns approximately 70 hits. They fall into four buckets:

1. **Product-name prose** — e.g., `README.md` tagline, `docs/design/APP-ICON-DESIGN-SPECIFICATION.md` body, `docs/designs/cli-system-proposal.md`, `docs/designs/container-integration.md`, `docs/designs/format-conversion-architecture.md`. These are active content that users of the repository will read today, and they need to reflect the current product name.
2. **Absolute paths** inside specs, plans, MEMORY notes, and agent persona files — e.g., `/Users/dho/Documents/lungfish-genome-browser/...`. After the directory rename these paths resolve only through shell resolution of a symlink (if one is created) or not at all. These need sweeping to the new path for correctness.
3. **Historical preambles** — design docs whose opening paragraph literally says "at the time of writing, this project was called…" Those are not touched.
4. **Commit messages and archived logs** (accessible via `git log`) — not touched.

The sweep in §4 applies to buckets 1 and 2 only.

## 4. What changes, concretely

### 4.1 Local directory

`/Users/dho/Documents/lungfish-genome-browser` → `/Users/dho/Documents/lungfish-genome-explorer`.

A one-shot `mv` operation, performed with no other Claude Code sessions or editors or builds holding the old path open.

### 4.2 Git remote

```
git remote set-url origin git@github.com:<owner>/lungfish-genome-explorer.git
```

Verified with `git remote -v`. The exact URL form (`git@` vs `https://`) matches whatever form `origin` currently uses.

### 4.3 Product-name prose sweep

Two substitutions run together:

**Substitution 1: "Lungfish Genome Browser" → "Lungfish Genome Explorer".**
Every active occurrence in `README.md`, `docs/user-manual/**/*.md`, `docs/design/**/*.md`, `docs/designs/**/*.md`, and `.claude/agents/**/*.md` is rewritten to the new product name.

**Substitution 2: bare "Lungfish" → "Lungfish Genome Explorer" in `README.md` only.**
The README is the first thing a reader encounters and needs the full product name consistently. Every bare user-facing "Lungfish" in `README.md` that refers to the product is rewritten to "Lungfish Genome Explorer," with the following exceptions that apply even inside `README.md`:

- **File-type and module names** (`.lungfishfastq`, `LungfishCore`, etc.) and compound internal terms (e.g., `LungfishApp`, `NativeToolRunner`) are not touched.
- **The word "Lungfish" as a brand/company mark** (e.g., "the Lungfish team," if it appears) is not touched; that is a company reference, not a product reference.
- **Code fences and command-line examples** (where "Lungfish" is a binary or CLI name) are not touched.

**This full-name rule does not apply to the user manual or other docs.** The user manual, agent definitions, and design docs continue to use "Lungfish" as a short-form after a first full-name introduction, because forcing the full name into every sentence of a long chapter produces stilted prose. Those documents keep Substitution 1 only.

**Exceptions (both substitutions):**

- Occurrences inside an explicit history/preamble block that documents the product's former name as a historical fact.
- Occurrences inside code fences that reproduce a past commit message, log line, or document.
- Occurrences inside fixed-text artifacts (glossary entries defining the historical name, change-log entries from before the rename).

Both exception sets are evaluated per-occurrence. When in doubt, rename (it is easier to restore a historical reference than to find a missed active one).

### 4.4 Absolute-path sweep

Every `/Users/dho/Documents/lungfish-genome-browser/...` in `.md` files across `docs/`, `.claude/`, and any root-level markdown is rewritten to `/Users/dho/Documents/lungfish-genome-explorer/...`. No exceptions: these are mechanical paths, not prose with semantic meaning.

Code files (`.swift`, scripts, config) are inspected but only changed where the old path is hard-coded (rare; most are relative paths).

### 4.5 Claude Code memory directory

Current: `/Users/dho/.claude/projects/-Users-dho-Documents-lungfish-genome-browser/memory/`
New: `/Users/dho/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer/memory/`

The directory is moved (not copied, not symlinked). Any references inside `MEMORY.md` to the old absolute path are rewritten as part of §4.4.

### 4.6 GitHub repository URL references in prose

The repository's canonical URL appears in the brand guide, README, and possibly a few design docs. Wherever the old URL form is written out, it is updated to the new form.

## 5. Ordering and verification

Steps run in this order, with verification at each step, so a breakage is caught immediately:

1. Close all open builds, editors, and Claude Code sessions that hold the old path.
2. `mv /Users/dho/Documents/lungfish-genome-browser /Users/dho/Documents/lungfish-genome-explorer`.
3. From the new directory: `git remote -v` (sanity check), then `git remote set-url origin <new URL>`, then `git remote -v` again. Verify `git fetch` succeeds.
4. From the new directory: `swift build` to confirm the build still works without any further edits.
5. Sweep prose (§4.3) and paths (§4.4) using targeted ripgrep-driven replacements. Commit as a single commit titled `chore: rename Lungfish Genome Browser to Lungfish Genome Explorer`.
6. Move the Claude Code memory directory (§4.5). Verify a new Claude Code session opens cleanly against the new path and finds its memory.
7. Final pass: `rg "lungfish-genome-browser" --type md` and `rg "Lungfish Genome Browser" --type md` — both should return only historical preambles and code-fence reproductions.

## 6. Risks and rollback

- **Open handles.** The directory rename fails or produces broken state if an editor, build, or session holds the old path open. Mitigation: verify by closing everything before the `mv`. If the rename fails partway, `mv` back to the old name and retry.
- **Git remote misconfiguration.** A typo in the new remote URL means `fetch` fails. Mitigation: run `git remote -v` + `git fetch` immediately after setting. Rollback: re-run `git remote set-url origin` with the correct URL.
- **Hidden absolute paths in non-markdown files.** `swift build` catches hardcoded paths in Swift sources; hooks and shell scripts may not. Mitigation: a final grep pass across `.sh`, `.yaml`, and `.json` after the main sweep, inspecting any hits.
- **Claude Code memory loss.** If the memory move is botched, a new session creates a fresh empty memory. Mitigation: move the directory (atomic on the same filesystem), then immediately open a new session to verify memory is intact.

## 7. Out of scope, explicitly

- Renaming the local Swift product name in `Package.swift`. The product is `Lungfish`, not `LungfishBrowser` — nothing to change.
- Auditing `Info.plist` and Xcode scheme names. A follow-up micro-audit is listed in §8, not built into this sweep.
- Updating historical design docs whose headers say "Lungfish Genome Browser" as a statement of what the product was called at the time of writing.

## 8. Follow-ups (not built in this spec)

- Micro-audit: one-hour scan of `Info.plist`, Xcode scheme, build scripts, DMG packaging, release notes templates, and any screenshot watermarks for the old product name. Ticket-sized, separate PR.

## 9. "Done" criteria

- `pwd` from the working copy shows `/Users/dho/Documents/lungfish-genome-explorer`.
- `git remote -v` shows the new repository URL for `origin`; `git fetch` succeeds.
- `swift build` passes from the new directory with no edits beyond this sweep.
- `rg "Lungfish Genome Browser" --type md` returns only historical preambles and explicit reproductions.
- `rg "lungfish-genome-browser" --type md` returns only those same historical exceptions.
- Claude Code opens a new session against the new directory and finds its memory.
- One commit in the branch titled `chore: rename Lungfish Genome Browser to Lungfish Genome Explorer`, containing both the prose sweep and the path sweep.

## 10. Deliverables

- One branch off `main`, one PR, one merge.
- No new files, no new directories (other than the moved memory folder).
- A short PR description enumerating the seven "Done" criteria, each checked.

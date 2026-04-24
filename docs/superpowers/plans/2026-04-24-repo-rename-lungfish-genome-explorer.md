# Repo Rename: Lungfish Genome Explorer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the local working copy to `lungfish-genome-explorer`, update the git remote, sweep user-facing product-name prose and stale absolute paths, and move the Claude Code memory directory — so the local state matches the renamed GitHub repository.

**Architecture:** Three substitution domains (directory move, git remote, prose/path sweep in markdown) plus a memory directory move. Done in sequence, with `swift build` verification at the critical junction. Runs directly on `main` (not a worktree) because the rename is in-place and affects paths that a worktree would carry.

**Tech Stack:** git, zsh, ripgrep, `swift build`. No code changes.

**Spec:** `docs/superpowers/specs/2026-04-24-repo-rename-lungfish-genome-explorer-design.md`

---

## Preconditions

- Working tree clean on `main` (`git status` shows nothing to commit).
- No other Claude Code sessions open against this project.
- No editors or IDEs holding handles to files under `/Users/dho/Documents/lungfish-genome-browser`.
- No running `swift build`, app launch, or other process holding the old path open.

If any of these are not met, stop and fix before proceeding.

---

## File Structure

This plan does not add or modify source files. It:

- **Renames** a single directory: `/Users/dho/Documents/lungfish-genome-browser` → `/Users/dho/Documents/lungfish-genome-explorer`.
- **Moves** a single directory: `~/.claude/projects/-Users-dho-Documents-lungfish-genome-browser/` → `~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer/`.
- **Edits** text in many `.md` files under `docs/`, `.claude/`, and `README.md`, plus any matching files at the repo root. Edits are limited to prose substitutions and path substitutions.
- **Updates** one git config value (`remote.origin.url`).

---

## Task 1: Verify preconditions and record starting state

**Files:** None modified. Information gathering only.

- [ ] **Step 1: Confirm working tree is clean**

Run: `cd /Users/dho/Documents/lungfish-genome-browser && git status`
Expected output: `On branch main … nothing to commit, working tree clean`. If dirty, stop.

- [ ] **Step 2: Record current remote URL for later comparison**

Run: `git -C /Users/dho/Documents/lungfish-genome-browser remote -v`
Expected output:
```
origin	https://github.com/dhoconno/lungfish-genome-browser.git (fetch)
origin	https://github.com/dhoconno/lungfish-genome-browser.git (push)
```
Save this value; we rewrite it in Task 3.

- [ ] **Step 3: Verify the new GitHub URL is reachable**

Run: `curl -sI https://github.com/dhoconno/lungfish-genome-explorer | head -1`
Expected output: `HTTP/2 200`. If not, stop — the GitHub side is not actually renamed yet.

- [ ] **Step 4: Confirm no other processes hold the old path**

Run: `lsof +D /Users/dho/Documents/lungfish-genome-browser 2>/dev/null | head -20`
Expected output: empty, or only the current shell's `zsh` processes. If any editors, builds, or other Claude sessions appear, close them before proceeding.

---

## Task 2: Rename the local directory

**Files:**
- Rename: `/Users/dho/Documents/lungfish-genome-browser` → `/Users/dho/Documents/lungfish-genome-explorer`

- [ ] **Step 1: Move the directory**

Run: `mv /Users/dho/Documents/lungfish-genome-browser /Users/dho/Documents/lungfish-genome-explorer`
Expected output: none (silent success).

- [ ] **Step 2: Verify directory moved**

Run: `ls -d /Users/dho/Documents/lungfish-genome-browser 2>&1; ls -d /Users/dho/Documents/lungfish-genome-explorer`
Expected:
- First command: `ls: /Users/dho/Documents/lungfish-genome-browser: No such file or directory`
- Second command: `/Users/dho/Documents/lungfish-genome-explorer`

- [ ] **Step 3: Verify git still works from new location**

Run: `git -C /Users/dho/Documents/lungfish-genome-explorer status`
Expected output: `On branch main … nothing to commit, working tree clean`.

---

## Task 3: Update the git remote

**Files:**
- Modify: `.git/config` (via `git remote set-url`)

- [ ] **Step 1: Update remote URL**

Run: `git -C /Users/dho/Documents/lungfish-genome-explorer remote set-url origin https://github.com/dhoconno/lungfish-genome-explorer.git`
Expected output: none (silent success).

- [ ] **Step 2: Verify new URL**

Run: `git -C /Users/dho/Documents/lungfish-genome-explorer remote -v`
Expected output:
```
origin	https://github.com/dhoconno/lungfish-genome-explorer.git (fetch)
origin	https://github.com/dhoconno/lungfish-genome-explorer.git (push)
```

- [ ] **Step 3: Verify remote is reachable**

Run: `git -C /Users/dho/Documents/lungfish-genome-explorer fetch origin`
Expected output: either silent success or a `From https://github.com/dhoconno/lungfish-genome-explorer` header with no errors.

---

## Task 4: Smoke-test the build before editing files

**Files:** None modified.

Why: catching a broken state here (after the directory rename, before prose edits) localizes any failure to the rename itself.

- [ ] **Step 1: Run `swift build`**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build 2>&1 | tail -5`
Expected output: the last lines end with `Build complete!` or equivalent. If the build fails for reasons unrelated to paths (e.g., real code issues), document the failure and stop.

- [ ] **Step 2: Commit nothing — this is just verification**

No commit. Proceed to Task 5.

---

## Task 5: Create a working branch

**Files:** None modified.

- [ ] **Step 1: Create and switch to a new branch**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && git checkout -b chore/rename-to-lungfish-genome-explorer`
Expected output: `Switched to a new branch 'chore/rename-to-lungfish-genome-explorer'`.

---

## Task 6: Sweep product-name prose (bucket 1 of 2)

**Files:**
- Modify: any `.md` under `docs/`, `.claude/`, and repo root containing `Lungfish Genome Browser` in active prose.

The substitution pattern is literal string `Lungfish Genome Browser` → `Lungfish Genome Explorer`, with exceptions enumerated in the spec's §4.3.

- [ ] **Step 1: List candidate files**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -l "Lungfish Genome Browser" --type md`
Expected: a list of markdown files (approximately 8–15 files).

- [ ] **Step 2: Inspect each match to classify active-vs-historical**

For each file listed, read the matches in context:
Run: `rg "Lungfish Genome Browser" --type md -n -C 2 <file>`

For each occurrence, decide whether it falls under one of the spec's exceptions:
- inside a history/preamble block documenting the former name as historical fact,
- inside a code fence reproducing a past artifact,
- inside a fixed-text artifact (glossary defining the historical name, change-log from before the rename).

If none of those, it's active prose and gets rewritten.

- [ ] **Step 3: Apply substitutions**

For each active occurrence, edit the file in place using the Edit tool. Example:
```
Old: "...the Lungfish Genome Browser uses..."
New: "...the Lungfish Genome Explorer uses..."
```

Do not use a global `sed` — the per-occurrence human-judgment pass is required because the spec's exceptions cannot be encoded mechanically.

- [ ] **Step 4: Verify remaining occurrences are only exception-categories**

Run: `rg "Lungfish Genome Browser" --type md -n`
Expected: only matches inside history/preamble blocks, code fences, or glossary entries explicitly defining the historical name. No active prose hits.

- [ ] **Step 5: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add docs/ README.md .claude/ 2>/dev/null || git add -u
git commit -m "$(cat <<'EOF'
chore: rename Lungfish Genome Browser to Lungfish Genome Explorer in prose

Substitute the product name throughout active documentation, README, design docs, and agent persona files. Historical preambles, code-fenced reproductions, and glossary entries defining the former name are preserved as-is per spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Apply the README-only full-name substitution

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/README.md`

The README needs a second substitution: bare user-facing `Lungfish` (when referring to the product) → `Lungfish Genome Explorer`, with exceptions for file-type names, module names, code fences, and brand/company references. Spec §4.3 Substitution 2.

- [ ] **Step 1: List bare "Lungfish" occurrences in README**

Run: `rg -n "\bLungfish\b" /Users/dho/Documents/lungfish-genome-explorer/README.md`
Review each line in context.

- [ ] **Step 2: Apply substitutions per the spec's rules**

For each occurrence, decide:
- Is it a bare product reference (e.g., "Lungfish opens the file…")? → rewrite to "Lungfish Genome Explorer."
- Is it a file-type or module name (`.lungfishfastq`, `LungfishCore`, `LungfishApp`)? → leave alone.
- Is it inside a code fence or command-line example? → leave alone.
- Is it "the Lungfish team" or similar brand/company reference? → leave alone.

Use the Edit tool per occurrence.

- [ ] **Step 3: Verify the README no longer contains bare product references**

Run: `rg -n "\bLungfish\b" /Users/dho/Documents/lungfish-genome-explorer/README.md`
Review remaining hits: each should fall under one of the exception categories. Note any borderline cases in the commit message for reviewer context.

- [ ] **Step 4: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add README.md
git commit -m "$(cat <<'EOF'
chore: expand bare Lungfish to full product name in README

The README is the first thing a reader encounters and needs the full product name consistently. File-type names (.lungfishfastq, etc.), module names (LungfishCore, etc.), code fences, and brand/company references are preserved as-is per spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Sweep absolute path references (bucket 2 of 2)

**Files:**
- Modify: any `.md` under `docs/`, `.claude/`, and repo root containing `/Users/dho/Documents/lungfish-genome-browser/` in prose.

The substitution pattern is literal string `/Users/dho/Documents/lungfish-genome-browser` → `/Users/dho/Documents/lungfish-genome-explorer`, with the same three exception categories as Task 6.

- [ ] **Step 1: List candidate files**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && rg -l "lungfish-genome-browser" --type md`

- [ ] **Step 2: Inspect each match and apply substitutions**

For each file, review matches in context. Paths in spec/plan preambles that describe historical state (rare) are exceptions; all other paths are mechanical references that must be updated to resolve correctly. Use the Edit tool.

For bulk path rewrites within a single file (e.g., a file with many matches and no exceptions), `Edit` with `replace_all: true` is acceptable.

- [ ] **Step 3: Check non-markdown files for hardcoded paths**

Run: `rg "lungfish-genome-browser" --type-add 'conf:*.{sh,yaml,yml,json,toml}' --type conf`
Expected: minimal or no hits. If hits appear, inspect and update each as a judgment call (these are likely to be shell scripts with hardcoded paths that need to work post-rename).

- [ ] **Step 4: Verify remaining occurrences are only exception-categories**

Run: `rg "lungfish-genome-browser" --type md -n`
Expected: only historical preambles and code-fence reproductions.

- [ ] **Step 5: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git add -u
git commit -m "$(cat <<'EOF'
chore: rewrite absolute paths to lungfish-genome-explorer

Update hardcoded /Users/dho/Documents/lungfish-genome-browser paths in specs, plans, TODOs, agent persona files, and supporting scripts to the new directory name. Paths inside historical preambles and code-fenced reproductions are preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Move the Claude Code memory directory

**Files:**
- Move: `~/.claude/projects/-Users-dho-Documents-lungfish-genome-browser/` → `~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer/`

- [ ] **Step 1: Confirm the old memory path exists**

Run: `ls -d ~/.claude/projects/-Users-dho-Documents-lungfish-genome-browser`
Expected: the path lists successfully.

- [ ] **Step 2: Confirm no new memory path has been auto-created**

Run: `ls -d ~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer 2>&1`
Expected: `ls: … No such file or directory`. If a new directory was already auto-created by a Claude session, stop — we would need to merge memory manually.

- [ ] **Step 3: Move the directory**

Run: `mv ~/.claude/projects/-Users-dho-Documents-lungfish-genome-browser ~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer`
Expected output: none.

- [ ] **Step 4: Verify the move**

Run: `ls ~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer/memory/ | head -5`
Expected: a listing of memory files (e.g., `MEMORY.md`, topic files).

- [ ] **Step 5: Sweep MEMORY.md for old-path references**

Run: `rg "lungfish-genome-browser" ~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer/memory/`
If any hits appear, edit the files to use the new path. These edits are outside the git repository and are not committed; they affect your local Claude memory only.

- [ ] **Step 6: No commit here — memory directory is not in the repo**

---

## Task 10: Final verification

**Files:** None modified.

- [ ] **Step 1: Build cleanly from new path**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && swift build 2>&1 | tail -3`
Expected: `Build complete!`.

- [ ] **Step 2: Confirm rename sweep is complete**

Run:
```bash
cd /Users/dho/Documents/lungfish-genome-explorer
echo "=== Active product-name hits ==="
rg "Lungfish Genome Browser" --type md
echo "=== Active path hits ==="
rg "lungfish-genome-browser" --type md
```
Expected: both sections show only historical preambles, code fences, and explicit glossary entries. No active prose.

- [ ] **Step 3: Confirm README full-name substitution**

Run: `rg -n "\bLungfish\b" README.md | rg -v "lungfishfastq|lungfishref|lungfishprimers|LungfishCore|LungfishApp|LungfishIO|LungfishUI|LungfishWorkflow|LungfishPlugin|LungfishCLI"`
Review remaining hits. They should be either: brand/company references ("the Lungfish team"), explicit product references that were intentionally preserved, or text inside a code fence.

- [ ] **Step 4: Confirm remote is set correctly**

Run: `git -C /Users/dho/Documents/lungfish-genome-explorer remote -v`
Expected: both lines show `https://github.com/dhoconno/lungfish-genome-explorer.git`.

- [ ] **Step 5: Confirm Claude memory is reachable**

Run: `ls ~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer/memory/MEMORY.md && head -5 ~/.claude/projects/-Users-dho-Documents-lungfish-genome-explorer/memory/MEMORY.md`
Expected: the `MEMORY.md` exists and its first few lines render.

---

## Task 11: Push and open PR

**Files:** None modified.

- [ ] **Step 1: Push the branch**

Run: `cd /Users/dho/Documents/lungfish-genome-explorer && git push -u origin chore/rename-to-lungfish-genome-explorer`
Expected: GitHub acknowledges the new branch and prints a PR URL hint.

- [ ] **Step 2: Open PR**

Run:
```bash
gh pr create --title "chore: rename to Lungfish Genome Explorer" --body "$(cat <<'EOF'
## Summary

- Renames the local working directory to `lungfish-genome-explorer` to match the GitHub rename.
- Updates the `origin` remote URL.
- Sweeps user-facing product-name prose ("Lungfish Genome Browser" → "Lungfish Genome Explorer") across active docs, README, and design docs.
- Expands bare "Lungfish" → "Lungfish Genome Explorer" in `README.md` only (per spec §4.3 Substitution 2).
- Rewrites absolute path references to the new directory name in `.md` files.
- Moves the Claude Code memory directory to match the new path (out-of-repo; noted here for completeness).

## Test plan

- [ ] `swift build` passes from the new directory.
- [ ] `git remote -v` shows the new URL.
- [ ] `rg "Lungfish Genome Browser" --type md` returns only historical preambles and code fences.
- [ ] `rg "lungfish-genome-browser" --type md` returns only historical preambles and code fences.
- [ ] Claude Code memory is reachable from the new project path.

Spec: `docs/superpowers/specs/2026-04-24-repo-rename-lungfish-genome-explorer-design.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

---

## "Done" criteria

- `pwd` from the working copy shows `/Users/dho/Documents/lungfish-genome-explorer`.
- `git remote -v` shows the new URL for `origin`; `git fetch` succeeds.
- `swift build` passes from the new directory.
- `rg "Lungfish Genome Browser" --type md` returns only historical preambles and code fences.
- `rg "lungfish-genome-browser" --type md` returns only historical preambles and code fences.
- The README reads with "Lungfish Genome Explorer" as the product name; bare "Lungfish" survives only where the exception rules in §4.3 allow.
- Claude Code opens a new session against the new directory and finds its memory.
- A PR exists on GitHub titled "chore: rename to Lungfish Genome Explorer" with three commits (prose sweep, README full-name expansion, path sweep).

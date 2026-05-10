# Repository Hygiene Spring Cleaning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean the repository by separating active materials from historical records, making `agents/` canonical, pruning confirmed cruft, enforcing provenance for retained scientific fixtures, updating version/docs, and preparing `v0.4.0-alpha.12` release artifacts.

**Architecture:** Use a conservative active/archive split. Historical docs move to `docs/archive/`; active agent infrastructure becomes canonical under `agents/`; hidden tool-specific agent folders remain as mirrors/adapters while tests and tools still require them. Cleanup is evidence-driven: every deletion needs a reference scan, and every retained scientific fixture needs provenance or quarantine.

**Tech Stack:** SwiftPM, Xcode project metadata, Git, Bash, MkDocs/Read the Docs, existing release scripts, existing Swift and Python test suites.

---

## File Structure

**Create:**
- `docs/archive/README.md`
- `docs/archive/design/README.md`
- `docs/archive/designs/README.md`
- `docs/archive/plans/README.md`
- `docs/archive/research/README.md`
- `docs/archive/reviews/README.md`
- `docs/archive/superpowers/README.md`
- `agents/README.md`
- `agents/definitions/codex/*.md`
- `agents/definitions/claude/*.md`
- `agents/process/*.md`
- `agents/specialists/*.md`
- `docs/release-notes/v0.4.0-alpha.12.md`
- `scripts/testing/audit-fixture-provenance.sh`
- `scripts/testing/write-analysis-fixture-provenance.py`

**Modify:**
- `.gitignore`
- `README.md`
- `PLAN.md`
- `docs/user-manual/STYLE.md`
- `docs/user-manual/illustrations.yaml`
- `docs/user-manual/build/scripts/lint/rules/frontmatter.js`
- `Lungfish.xcodeproj/project.pbxproj`
- `Sources/LungfishCLI/LungfishCLI.swift`
- `Sources/LungfishCLI/Commands/PrimerCommand.swift`
- `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- `Sources/LungfishApp/App/AboutWindowController.swift`
- `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist`
- `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- `scripts/build-app.sh`
- `Tests/LungfishCLITests/CLIRegressionTests.swift`
- `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
- `Tests/LungfishWorkflowTests/Variants/GATKPipelineExecutorTests.swift`
- `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`
- `.github/workflows/ci.yml` if Python release-script tests remain active

**Move with `git mv`:**
- Historical `docs/plans/*` to `docs/archive/plans/`
- Historical `docs/design/*` to `docs/archive/design/`
- Historical `docs/designs/*` to `docs/archive/designs/`
- Historical `docs/reviews/*` to `docs/archive/reviews/`
- Historical `docs/research/*` to `docs/archive/research/`
- Historical `docs/superpowers/{plans,specs,reviews,research,prompts}` entries older than the active May 2026 hygiene and issue-triage materials to the matching `docs/archive/superpowers/` subdirectories
- `docs/process/*.md` to `agents/process/`
- `roles/*.md` to `agents/specialists/`, with normalized numbering

**Delete after reference scan:**
- `docs/user-manual/assets/illustrations/`
- `docs/user-manual/build/scripts/illustrations/` if the old schematic generator is retired
- `Tests/LungfishXCUITests/PrimerTrim/VariantCallingAutoConfirmXCUITests.swift` if it remains outside the Xcode sources build phase
- `Tests/Fixtures/gui-test-fastq/`
- `Tests/Fixtures/metagenomics/`
- ignored local `.DS_Store`, local `node_modules`, `.superpowers/`, and empty worktree scratch directories

## Task 0: Safety Baseline and Work Branch

**Files:**
- No file edits.

- [ ] **Step 1: Confirm starting state**

Run:

```bash
git status --short --branch
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
git rev-parse origin/main
```

Expected:
- Branch is `main`.
- Working tree has no unstaged or staged changes.
- Local `main` includes the committed design spec.

- [ ] **Step 2: Create cleanup branch**

Run:

```bash
git switch -c codex/repo-hygiene-spring-cleaning
```

Expected:

```text
Switched to a new branch 'codex/repo-hygiene-spring-cleaning'
```

- [ ] **Step 3: Capture baseline inventory**

Run:

```bash
git ls-files | wc -l
git ls-files docs/superpowers/specs docs/superpowers/plans docs/superpowers/reviews docs/superpowers/research docs/superpowers/prompts docs/plans docs/design docs/designs docs/reviews docs/research | wc -l
find .codex/agents .claude/agents roles docs/process -maxdepth 2 -type f | sort
```

Expected:
- Counts are recorded in the implementation notes or commit message.
- Agent/process/role files match the audited set.

## Task 1: Add Archive and Agent Scaffolding

**Files:**
- Create: `docs/archive/README.md`
- Create: `docs/archive/design/README.md`
- Create: `docs/archive/designs/README.md`
- Create: `docs/archive/plans/README.md`
- Create: `docs/archive/research/README.md`
- Create: `docs/archive/reviews/README.md`
- Create: `docs/archive/superpowers/README.md`
- Create: `agents/README.md`
- Modify: `.gitignore`

- [ ] **Step 1: Write `docs/archive/README.md`**

Create `docs/archive/README.md` with:

```markdown
# Documentation Archive

This directory preserves historical planning, design, research, and review records.

Archived files are useful for understanding how Lungfish Genome Explorer reached its current shape, but they are not active implementation instructions. Current work should start from the active issue backlog, product specs, release docs, user manual source, and the canonical agent roster in `agents/`.

When moving a record here, preserve the original filename unless a collision requires a narrow disambiguator.
```

- [ ] **Step 2: Write subdirectory README files**

Create each listed subdirectory README with this exact body, changing only the heading:

```markdown
# Archived Plans

These files are historical records. They may describe decisions, alternatives, and implementation context, but they are not current instructions for new work.
```

Use headings:
- `# Archived Design Notes`
- `# Archived Design Proposals`
- `# Archived Plans`
- `# Archived Research`
- `# Archived Reviews`
- `# Archived Superpowers Records`

- [ ] **Step 3: Write initial `agents/README.md`**

Create `agents/README.md` with:

```markdown
# Lungfish Agent Roster

This directory is the canonical home for Lungfish Genome Explorer agent definitions, process roles, and expert specialists.

Tool-specific folders such as `.codex/agents/` and `.claude/agents/` may contain mirror copies for tool discovery. When a definition changes, update the canonical file here first, then update the tool-facing mirror and the tests that validate the relationship.

## Layout

| Path | Purpose |
| --- | --- |
| `definitions/codex/` | Codex agent definitions used for release, issue engagement, and other Codex-native workflows. |
| `definitions/claude/` | Claude manual-writing and documentation agent definitions. |
| `process/` | Lead-agent workflows, review protocols, and operating contracts. |
| `specialists/` | Expert role definitions used for focused review and architecture consultation. |
| `archive/` | Inactive agent experiments or retired prompts retained for context. |

## Dispatch Rules

- Use the smallest agent set that can answer the question or review the work.
- Keep scientific-data provenance salient for imports, exports, transformations, classifiers, extraction, workflow outputs, and bundle generation.
- Record durable review outputs in active issue/product-spec locations when they drive current work; use `docs/archive/` only for historical records.
```

- [ ] **Step 4: Track `agents/` under deny-by-default `.gitignore`**

Modify `.gitignore` near the other top-level allow rules:

```gitignore
!agents/**
```

Run:

```bash
git check-ignore -v agents/README.md || true
git status --short
```

Expected:
- `agents/README.md` is not ignored.
- New archive and agent README files appear as untracked or staged files.

- [ ] **Step 5: Commit scaffolding**

Run:

```bash
git add .gitignore docs/archive agents/README.md
git commit -m "docs: add archive and agent scaffolding"
```

Expected: commit succeeds.

## Task 2: Move Historical Documentation to `docs/archive/`

**Files:**
- Move: `docs/plans/*`
- Move: `docs/design/*`
- Move: `docs/designs/*`
- Move: `docs/reviews/*`
- Move: `docs/research/*`
- Move: selected historical `docs/superpowers/*`
- Keep active: `docs/issues/*`
- Keep active: `docs/product-specs/*`
- Keep active: `docs/release/*`
- Keep active: `docs/release-notes/*`
- Keep active: `docs/user-manual/*`
- Keep active: `docs/superpowers/specs/2026-05-10-repo-hygiene-spring-cleaning-design.md`
- Keep active: `docs/superpowers/plans/2026-05-10-repo-hygiene-spring-cleaning.md`
- Keep active until reconciled: `docs/superpowers/specs/2026-05-08-github-issue-engagement-orchestrator-design.md`
- Keep active until reconciled: `docs/superpowers/plans/2026-05-08-github-issue-engagement-orchestrator.md`
- Keep active until reconciled: `docs/superpowers/reviews/2026-05-08-github-issues-6-13-triage.md`

- [ ] **Step 1: Dry-run archive candidates**

Run:

```bash
git ls-files docs/plans docs/design docs/designs docs/reviews docs/research
find docs/superpowers -maxdepth 2 -type f | sort | grep -v '2026-05-08-github-issue-engagement-orchestrator' | grep -v '2026-05-08-github-issues-6-13-triage' | grep -v '2026-05-10-repo-hygiene-spring-cleaning'
```

Expected:
- Output contains only historical files intended for archive.
- No `docs/issues`, `docs/product-specs`, `docs/release`, `docs/release-notes`, or `docs/user-manual/chapters` paths appear.

- [ ] **Step 2: Move old root-level docs subtrees**

Run:

```bash
mkdir -p docs/archive/plans docs/archive/design docs/archive/designs docs/archive/reviews docs/archive/research
git mv docs/plans/*.md docs/archive/plans/
git mv docs/design/*.md docs/archive/design/
git mv docs/designs/*.md docs/archive/designs/
git mv docs/reviews/* docs/archive/reviews/
git mv docs/research/*.md docs/archive/research/
```

Expected:
- Moves are staged as renames.
- Empty original directories are gone or untracked-empty only.

- [ ] **Step 3: Move historical superpowers records**

Run:

```bash
mkdir -p docs/archive/superpowers/plans docs/archive/superpowers/specs docs/archive/superpowers/reviews docs/archive/superpowers/research docs/archive/superpowers/prompts
find docs/superpowers/plans -maxdepth 1 -type f ! -name '2026-05-08-github-issue-engagement-orchestrator.md' ! -name '2026-05-10-repo-hygiene-spring-cleaning.md' -print0 | xargs -0 -I{} git mv "{}" docs/archive/superpowers/plans/
find docs/superpowers/specs -maxdepth 1 -type f ! -name '2026-05-08-github-issue-engagement-orchestrator-design.md' ! -name '2026-05-10-repo-hygiene-spring-cleaning-design.md' -print0 | xargs -0 -I{} git mv "{}" docs/archive/superpowers/specs/
find docs/superpowers/research -maxdepth 1 -type f -print0 | xargs -0 -I{} git mv "{}" docs/archive/superpowers/research/
find docs/superpowers/prompts -maxdepth 1 -type f -print0 | xargs -0 -I{} git mv "{}" docs/archive/superpowers/prompts/
```

Move historical review directories except the active 2026-05-08 triage file:

```bash
find docs/superpowers/reviews -mindepth 1 -maxdepth 1 ! -name '2026-05-08-github-issues-6-13-triage.md' -print0 | xargs -0 -I{} git mv "{}" docs/archive/superpowers/reviews/
```

Expected:
- Active May 8 and May 10 files remain in `docs/superpowers/`.
- Historical records are staged as renames into `docs/archive/superpowers/`.

- [ ] **Step 4: Update active references outside the archive**

Run:

```bash
rg -n "docs/(plans|design|designs|reviews|research)/|docs/superpowers/(plans|specs|reviews|research|prompts)/" README.md docs Sources Tests scripts .github Package.swift PLAN.md
```

Expected:
- Matches in `docs/archive/` are acceptable.
- Active files outside `docs/archive/` that point to moved paths are updated to the new archive path or to active issue/product-spec paths.

- [ ] **Step 5: Commit archive moves**

Run:

```bash
git add docs .gitignore
git status --short
git commit -m "docs: archive historical planning records"
```

Expected: commit succeeds.

## Task 3: Consolidate Agents Under `agents/`

**Files:**
- Create: `agents/definitions/codex/release-agent.md`
- Create: `agents/definitions/codex/github-issue-engagement-orchestrator.md`
- Create: `agents/definitions/claude/*.md`
- Move: `docs/process/*.md` to `agents/process/`
- Move: `roles/*.md` to `agents/specialists/`
- Keep and validate mirrors: `.codex/agents/*.md`
- Keep and validate mirrors: `.claude/agents/*.md`
- Modify: `PLAN.md`
- Modify: `docs/user-manual/STYLE.md`
- Modify: `docs/user-manual/build/scripts/lint/rules/frontmatter.js`
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`

- [ ] **Step 1: Copy tool-facing definitions to canonical locations**

Run:

```bash
mkdir -p agents/definitions/codex agents/definitions/claude
cp .codex/agents/*.md agents/definitions/codex/
cp .claude/agents/*.md agents/definitions/claude/
git add agents/definitions
```

Expected:
- Canonical copies exist.
- `.codex/agents/` and `.claude/agents/` still contain the tool-facing mirror files.

- [ ] **Step 2: Move process docs**

Run:

```bash
mkdir -p agents/process
git mv docs/process/*.md agents/process/
```

Expected:
- `agents/process/PROJECT-LEAD-AGENT.md`, `agents/process/DEVELOPMENT-LEAD-AGENT.md`, `agents/process/GUI-LEAD-AGENT.md`, `agents/process/USER-ENGAGEMENT-TRIAGE-AGENT.md`, and `agents/process/EXPERT-REVIEW-GROUPS.md` exist.

- [ ] **Step 3: Move and normalize specialist roles**

Run:

```bash
mkdir -p agents/specialists
git mv roles/01-swift-architect.md agents/specialists/01-swift-architect.md
git mv roles/02-ui-ux-lead.md agents/specialists/02-ui-ux-lead.md
git mv roles/03-sequence-viewer.md agents/specialists/03-sequence-viewer.md
git mv roles/04-track-rendering.md agents/specialists/04-track-rendering.md
git mv roles/05-bioinformatics-architect.md agents/specialists/05-bioinformatics-architect.md
git mv roles/06-file-formats.md agents/specialists/06-file-formats.md
git mv roles/07-assembly-specialist.md agents/specialists/07-assembly-specialist.md
git mv roles/08-alignment-expert.md agents/specialists/08-alignment-expert.md
git mv roles/09-primer-design.md agents/specialists/09-primer-design.md
git mv roles/10-pcr-simulation.md agents/specialists/10-pcr-simulation.md
git mv roles/11-primalscheme.md agents/specialists/11-primalscheme.md
git mv roles/12-ncbi-integration.md agents/specialists/12-ncbi-integration.md
git mv roles/13-ena-integration.md agents/specialists/13-ena-integration.md
git mv roles/14-workflow-integration.md agents/specialists/14-workflow-integration.md
git mv roles/15-plugin-architect.md agents/specialists/15-plugin-architect.md
git mv roles/16-workflow-builder.md agents/specialists/16-workflow-builder.md
git mv roles/17-version-control.md agents/specialists/17-version-control.md
git mv roles/18-storage-indexing.md agents/specialists/18-storage-indexing.md
git mv roles/19-testing-qa.md agents/specialists/19-testing-qa.md
git mv roles/20-docs-community.md agents/specialists/20-docs-community.md
git mv roles/21-product-fit-expert.md agents/specialists/21-product-fit-expert.md
git mv roles/21-swift-concurrency-expert.md agents/specialists/22-swift-concurrency-expert.md
git mv roles/22-swift-networking-expert.md agents/specialists/23-swift-networking-expert.md
git mv roles/23-swift-appkit-expert.md agents/specialists/24-swift-appkit-expert.md
git mv roles/24-swift-debugging-expert.md agents/specialists/25-swift-debugging-expert.md
git mv roles/25-swift-state-management-expert.md agents/specialists/26-swift-state-management-expert.md
git mv roles/26-visual-design-artist.md agents/specialists/27-visual-design-artist.md
```

Expected:
- `agents/specialists/` has 27 uniquely numbered role files.
- `roles/` is empty or absent.

- [ ] **Step 4: Update `PLAN.md` specialist section**

Replace the `## Team Structure (20 Specialists)` section heading and role path text with:

```markdown
## Team Structure (27 Specialists)

Role definition files are in `agents/specialists/`:
```

Update each listed role path from `roles/` to `agents/specialists/`, using the normalized numbering from Step 3.

Run:

```bash
rg -n "roles/|20 Specialists|21-swift-concurrency|22-swift-networking|23-swift-appkit|24-swift-debugging|25-swift-state-management|26-visual-design" PLAN.md
```

Expected:
- No stale `roles/` references remain in `PLAN.md`.
- The heading says `27 Specialists`.

- [ ] **Step 5: Update active non-archive references**

Run:

```bash
rg -n "\\.codex/agents|\\.claude/agents|docs/process|roles/" README.md docs Sources Tests scripts .github Package.swift PLAN.md | grep -v 'docs/archive' || true
```

Update active references as follows:
- Canonical references to files in `.codex/agents/` become matching files in `agents/definitions/codex/`.
- Canonical references to files in `.claude/agents/` become matching files in `agents/definitions/claude/`.
- Discovery-specific references may mention both canonical path and mirror path.
- References to files in `docs/process/` become matching files in `agents/process/`.
- References to files in `roles/` become matching files in `agents/specialists/`.

- [ ] **Step 6: Update release-agent tests to validate canonical plus mirror**

In `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`, replace direct single-file reads of `.codex/agents/release-agent.md` with a helper that reads both files and asserts equality:

```swift
private static func releaseAgentPair() throws -> (canonical: String, mirror: String) {
    let root = Self.repositoryRoot()
    let canonical = try String(
        contentsOf: root.appendingPathComponent("agents/definitions/codex/release-agent.md"),
        encoding: .utf8
    )
    let mirror = try String(
        contentsOf: root.appendingPathComponent(".codex/agents/release-agent.md"),
        encoding: .utf8
    )
    return (canonical, mirror)
}
```

Use the canonical string for content assertions and add:

```swift
#expect(agent.canonical == agent.mirror)
```

Run:

```bash
swift test --filter ReleaseBuildConfigurationTests/releaseAgent
```

Expected: release-agent tests pass.

- [ ] **Step 7: Commit agent consolidation**

Run:

```bash
git add agents .codex/agents .claude/agents PLAN.md docs Sources Tests scripts .github .gitignore
git commit -m "docs: make agents canonical"
```

Expected: commit succeeds.

## Task 4: Reconcile User Manual Illustrations

**Files:**
- Modify: `docs/user-manual/illustrations.yaml`
- Modify or archive: `docs/user-manual/build/scripts/illustrations/*`
- Delete: `docs/user-manual/assets/illustrations/`
- Keep: `docs/user-manual/assets/illustrations-imagegen/`
- Keep: `docs/user-manual/reviews/illustrations/2026-05-10-expert-review.md`

- [ ] **Step 1: Confirm active chapter references**

Run:

```bash
rg -n "assets/illustrations/|assets/illustrations-imagegen/" docs/user-manual --glob '!assets/**' --glob '!reviews/**'
```

Expected:
- Chapter Markdown references `assets/illustrations-imagegen/`.
- No active chapter references `assets/illustrations/`.

- [ ] **Step 2: Update `illustrations.yaml` paths**

Replace each:

```yaml
asset: assets/illustrations/
source: assets/illustrations/
```

with:

```yaml
asset: assets/illustrations-imagegen/
source: assets/illustrations-imagegen/
```

Run:

```bash
rg -n "assets/illustrations/" docs/user-manual/illustrations.yaml
rg -n "assets/illustrations-imagegen/" docs/user-manual/illustrations.yaml | head
```

Expected:
- No `assets/illustrations/` references remain in `illustrations.yaml`.
- `assets/illustrations-imagegen/` references exist.

- [ ] **Step 3: Retire old schematic generator if unreferenced**

Run:

```bash
rg -n "build/scripts/illustrations|generate-illustrations|illustrations/package" docs README.md scripts Tests .github Package.swift
```

If the only active references are the generator's own tests/package files, move the old generator to the archive:

```bash
mkdir -p docs/archive/user-manual-illustration-generator
git mv docs/user-manual/build/scripts/illustrations docs/archive/user-manual-illustration-generator/illustrations
```

Expected:
- Active manual build still uses existing image assets and no retired generator path.

- [ ] **Step 4: Delete old illustration asset tree after reference scan**

Run:

```bash
rg -n "assets/illustrations/" docs README.md scripts Tests .github Package.swift | grep -v 'docs/archive' || true
```

If no active references remain:

```bash
git rm -r docs/user-manual/assets/illustrations
```

Expected:
- Only `docs/user-manual/assets/illustrations-imagegen/` remains as the active illustration tree.

- [ ] **Step 5: Build manual**

Run:

```bash
ENABLE_PDF_EXPORT=0 mkdocs build -f docs/user-manual/build/mkdocs.yml -d .docs-site/user-manual-smoke
```

Expected:
- MkDocs build exits 0.
- No missing image warnings.

- [ ] **Step 6: Commit illustration cleanup**

Run:

```bash
git add docs/user-manual docs/archive
git commit -m "docs: consolidate manual illustrations"
```

Expected: commit succeeds.

## Task 5: Clean Tests, Fixtures, and Provenance

**Files:**
- Delete: confirmed unused fixture/test files
- Create: `scripts/testing/audit-fixture-provenance.sh`
- Add provenance sidecars under retained active scientific fixture directories when missing

- [ ] **Step 1: Add provenance audit script**

Create `scripts/testing/audit-fixture-provenance.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
missing=0

check_dir() {
  local dir="$1"
  if [ -d "$ROOT/$dir" ] && [ ! -f "$ROOT/$dir/.lungfish-provenance.json" ]; then
    printf 'missing provenance: %s\n' "$dir" >&2
    missing=1
  fi
}

while IFS= read -r dir; do
  check_dir "$dir"
done <<'DIRS'
Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00
Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00
Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00
Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00
Tests/Fixtures/analyses/spades-2026-01-15T13-00-00
Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00
Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish
DIRS

exit "$missing"
```

Run:

```bash
chmod +x scripts/testing/audit-fixture-provenance.sh
scripts/testing/audit-fixture-provenance.sh
```

Expected:
- Script reports the current missing analysis fixture sidecars before backfill.

- [ ] **Step 2: Reference-scan stale test candidates**

Run:

```bash
rg -n "gui-test-fastq|Fixtures/metagenomics|SampleA\\.lungfishfastq|SampleB\\.lungfishfastq|VariantCallingAutoConfirmXCUITests" Sources Tests docs scripts .github Package.swift Lungfish.xcodeproj
```

Expected:
- Only candidate files themselves or archived references mention the stale paths.
- If an active reference appears, stop and update the cleanup list before deleting.

- [ ] **Step 3: Remove confirmed stale fixture/test files**

If Step 2 confirms no active references:

```bash
git rm -r Tests/Fixtures/gui-test-fastq
git rm -r Tests/Fixtures/metagenomics
git rm Tests/LungfishXCUITests/PrimerTrim/VariantCallingAutoConfirmXCUITests.swift
```

Expected:
- Files are staged as deletions.
- No active build configuration references the removed XCUITest file.

- [ ] **Step 4: Backfill provenance for retained analysis fixtures**

Create `scripts/testing/write-analysis-fixture-provenance.py` with:

```python
#!/usr/bin/env python3
import hashlib
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = [
    "Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00",
    "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00",
    "Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00",
    "Tests/Fixtures/analyses/spades-2026-01-15T13-00-00",
    "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00",
]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fixture_files(directory: Path) -> dict[str, dict[str, object]]:
    records: dict[str, dict[str, object]] = {}
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.name == ".lungfish-provenance.json":
            continue
        rel = path.relative_to(ROOT).as_posix()
        records[rel] = {
            "path": rel,
            "fileSize": path.stat().st_size,
            "checksumSHA256": sha256_file(path),
        }
    return records


def main() -> int:
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    created_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    for rel_dir in FIXTURES:
        directory = ROOT / rel_dir
        if not directory.is_dir():
            continue
        sidecar = directory / ".lungfish-provenance.json"
        files = fixture_files(directory)
        manifest_bytes = json.dumps(files, sort_keys=True, separators=(",", ":")).encode("utf-8")
        record = {
            "schemaVersion": 1,
            "workflowName": "analysis-fixture-curation",
            "toolName": "write-analysis-fixture-provenance.py",
            "toolVersion": "0.4.0-alpha.12",
            "createdAt": created_at,
            "reproducibleCommand": f"git checkout {commit} -- {rel_dir}",
            "argv": ["git", "checkout", commit, "--", rel_dir],
            "options": {
                "fixturePurpose": "Retained deterministic test fixture for Lungfish UI and integration tests",
                "source": "committed repository fixture",
            },
            "runtimeIdentity": {
                "containerImage": None,
                "condaEnvironment": None,
                "operatingSystemVersion": platform.platform(),
                "executablePath": "/usr/bin/git",
            },
            "input": None,
            "output": {
                "path": rel_dir,
                "fileSize": sum(item["fileSize"] for item in files.values()),
                "checksumSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
            },
            "files": files,
            "exitStatus": 0,
            "wallTimeSeconds": 0,
            "stderr": None,
            "warnings": [
                "This sidecar backfills provenance for a retained historical fixture. It records committed file identity and fixture purpose; it does not claim the original biological workflow was re-run."
            ],
        }
        sidecar.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(sidecar.relative_to(ROOT).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Run:

```bash
chmod +x scripts/testing/write-analysis-fixture-provenance.py
scripts/testing/write-analysis-fixture-provenance.py
```

Expected:
- Each retained active analysis fixture has `.lungfish-provenance.json`.
- The warning makes historical backfill limits explicit.

- [ ] **Step 5: Run fixture provenance audit**

Run:

```bash
scripts/testing/audit-fixture-provenance.sh
```

Expected: exits 0 with no stderr.

- [ ] **Step 6: Run affected tests**

Run:

```bash
swift test --filter 'LungfishAppTests|LungfishIntegrationTests|LungfishWorkflowTests'
```

Expected: tests pass or failures are investigated before continuing.

- [ ] **Step 7: Commit fixture cleanup**

Run:

```bash
git add Tests scripts/testing
git commit -m "test: clean stale fixtures and audit provenance"
```

Expected: commit succeeds.

## Task 6: Wire or Archive Python Release Tests

**Files:**
- Modify: `.github/workflows/ci.yml`
- Keep active: `scripts/tests/*.py`

- [ ] **Step 1: Run current Python release tests**

Run:

```bash
python3 -m unittest discover -s scripts/tests
```

Expected:
- Tests pass.
- If a test fails because it asserts stale paths or versions, fix the test or production script in the same task.

- [ ] **Step 2: Add Python release tests to CI fast gate**

In `.github/workflows/ci.yml`, after the current `Run smoke package tests` step, add:

```yaml
      - name: Run release script tests
        run: python3 -m unittest discover -s scripts/tests
```

Run:

```bash
python3 -m unittest discover -s scripts/tests
```

Expected: Python tests pass locally.

- [ ] **Step 3: Commit Python test wiring**

Run:

```bash
git add .github/workflows/ci.yml scripts/tests
git commit -m "ci: run release script tests"
```

Expected: commit succeeds.

## Task 7: Update README, Read the Docs Mention, and Version Metadata

**Files:**
- Modify: `README.md`
- Modify: `Lungfish.xcodeproj/project.pbxproj`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift`
- Modify: `Sources/LungfishCLI/Commands/PrimerCommand.swift`
- Modify: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- Modify: `Sources/LungfishApp/App/AboutWindowController.swift`
- Modify: `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist`
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- Modify: `scripts/build-app.sh`
- Modify: relevant tests under `Tests/`

- [ ] **Step 1: Add README user manual note**

In `README.md`, add a short section after Installation:

```markdown
## User Manual

Primitive documentation is now available on Read the Docs at [lungfish.readthedocs.io](https://lungfish.readthedocs.io/). The manual is early and incomplete, but it is now the canonical place for user-facing workflow documentation as it matures.
```

Run:

```bash
rg -n "Read the Docs|lungfish.readthedocs.io|User Manual" README.md
```

Expected: the README contains the new manual reference.

- [ ] **Step 2: Bump app and CLI version strings**

Replace release version strings used for app/CLI metadata from `0.4.0-alpha.11` to `0.4.0-alpha.12` in:

```text
Lungfish.xcodeproj/project.pbxproj
Sources/LungfishCLI/LungfishCLI.swift
Sources/LungfishCLI/Commands/PrimerCommand.swift
Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift
Sources/LungfishApp/App/AboutWindowController.swift
Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist
Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json
scripts/build-app.sh
Tests/LungfishCLITests/CLIRegressionTests.swift
Tests/LungfishWorkflowTests/CondaManagerTests.swift
Tests/LungfishWorkflowTests/Variants/GATKPipelineExecutorTests.swift
```

Run:

```bash
rg -n "0\\.4\\.0-alpha\\.11" Lungfish.xcodeproj Sources scripts Tests README.md docs/release docs/release-notes
rg -n "0\\.4\\.0-alpha\\.12" Lungfish.xcodeproj Sources scripts Tests README.md docs/release docs/release-notes
```

Expected:
- Active app/CLI/test metadata uses `0.4.0-alpha.12`.
- Historical release notes for previous versions remain unchanged.
- Active review records that describe an old build under test can remain unchanged if they are archived or clearly historical.

- [ ] **Step 3: Update Sparkle release doc examples**

In `docs/release/sparkle-updates.md`, update command examples to use `v0.4.0-alpha.12` for the next release flow while preserving the explanation that each version gets a versioned prerelease tag.

Run:

```bash
rg -n "v0\\.4\\.0-alpha\\.11|v0\\.4\\.0-alpha\\.12" docs/release/sparkle-updates.md
```

Expected: examples point at `v0.4.0-alpha.12`.

- [ ] **Step 4: Run version tests**

Run:

```bash
swift test --filter 'CLIRegressionTests|CondaManagerTests|GATKPipelineExecutorTests|ReleaseBuildConfigurationTests'
python3 -m unittest discover -s scripts/tests
```

Expected: tests pass.

- [ ] **Step 5: Commit README/version update**

Run:

```bash
git add README.md Lungfish.xcodeproj Sources scripts Tests docs/release
git commit -m "chore: bump version for alpha 12"
```

Expected: commit succeeds.

## Task 8: Write Alpha 12 Release Notes

**Files:**
- Create: `docs/release-notes/v0.4.0-alpha.12.md`

- [ ] **Step 1: Inspect changes since alpha 11**

Run:

```bash
git log --oneline v0.4.0-alpha.11..HEAD
```

Expected:
- Output includes the cleanup branch commits and all current main commits since alpha 11.

- [ ] **Step 2: Create release notes**

Create `docs/release-notes/v0.4.0-alpha.12.md` with this structure:

```markdown
# Lungfish 0.4.0-alpha.12

Previous release: v0.4.0-alpha.11

Changes since v0.4.0-alpha.11:

## Repository Hygiene

- Separated active documentation from historical planning records under `docs/archive/`.
- Added a canonical `agents/` roster for Codex, Claude, process, and specialist roles.
- Preserved tool-facing `.codex/agents/` and `.claude/agents/` mirrors for discovery compatibility.
- Reconciled manual illustration assets around the current Read the Docs source tree.
- Removed confirmed stale fixtures and added fixture provenance auditing for retained scientific outputs.

## Documentation

- Added a README link to the early Read the Docs manual at `https://lungfish.readthedocs.io/`.
- Kept current May 2026 review and product-spec issues active while moving older planning records out of the main working surface.

## Release

- Updated app, CLI, managed-tool lock, help book, and test version metadata to v0.4.0-alpha.12.
- Added release-script test coverage to CI.

## Verification

- Swift package build and test gates were run before packaging.
- Release packaging was verified with notarization, stapling, Gatekeeper assessment, SHA-256 checksum recording, and release metadata inspection.
```

If release packaging has not yet run at commit time, keep the Verification section but phrase it as "Release packaging must be verified before publication" until the release artifact commit.

- [ ] **Step 3: Commit release notes**

Run:

```bash
git add docs/release-notes/v0.4.0-alpha.12.md
git commit -m "docs: add alpha 12 release notes"
```

Expected: commit succeeds.

## Task 9: Full Verification

**Files:**
- No planned edits unless verification exposes failures.

- [ ] **Step 1: Check active-reference hygiene**

Run:

```bash
rg -n "docs/(plans|design|designs|reviews|research)/|docs/process/|roles/" README.md docs Sources Tests scripts .github Package.swift PLAN.md | grep -v 'docs/archive' || true
rg -n "assets/illustrations/" docs/user-manual --glob '!docs/archive/**' || true
rg -n "0\\.4\\.0-alpha\\.11" Lungfish.xcodeproj Sources scripts Tests README.md docs/release | grep -v 'docs/archive' || true
```

Expected:
- No active stale path references.
- No active old illustration tree references.
- No active version metadata still set to `0.4.0-alpha.11`.

- [ ] **Step 2: Run package and app build gates**

Run:

```bash
swift package resolve
swift build --product Lungfish
swift build --product lungfish-cli
```

Expected: all commands exit 0.

- [ ] **Step 3: Run tests**

Run:

```bash
swift test
python3 -m unittest discover -s scripts/tests
scripts/testing/audit-fixture-provenance.sh
```

Expected: all commands exit 0.

- [ ] **Step 4: Run XCUITest gate when local Xcode state supports it**

Run:

```bash
bash scripts/testing/run-macos-xcui.sh
```

Expected:
- XCUITest suite exits 0.
- If local simulator or Xcode state blocks the run, record the exact error and do not claim XCUITest passed.

- [ ] **Step 5: Build user manual**

Run:

```bash
ENABLE_PDF_EXPORT=0 mkdocs build -f docs/user-manual/build/mkdocs.yml -d .docs-site/user-manual-smoke
```

Expected: MkDocs build exits 0.

- [ ] **Step 6: Commit verification fixes if needed**

If any verification command required code/docs changes:

```bash
git add -A
git commit -m "chore: fix cleanup verification regressions"
```

Expected: any fix commit is focused and explains the failing gate.

## Task 10: Build, Verify, and Publish Release

**Files:**
- Generated/untracked release artifacts under `build/Release/`
- Possible final edit: `docs/release-notes/v0.4.0-alpha.12.md` if artifact verification details are added

- [ ] **Step 1: Confirm signing inputs**

Run:

```bash
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
test -n "${LUNGFISH_SPARKLE_PUBLIC_ED_KEY:-}"
test -x "${SPARKLE_GENERATE_APPCAST:-}"
```

Expected:
- Developer ID identity is available.
- Notary profile is usable.
- Sparkle public key is set.
- Sparkle `generate_appcast` is executable.

- [ ] **Step 2: Build notarized DMG**

Run with real local signing values:

```bash
bash scripts/release/build-notarized-dmg.sh \
  --signing-identity "$LUNGFISH_SIGNING_IDENTITY" \
  --team-id "$LUNGFISH_TEAM_ID" \
  --notary-profile "$NOTARY_PROFILE" \
  --github-release-tag "v0.4.0-alpha.12" \
  --sparkle-generate-appcast "$SPARKLE_GENERATE_APPCAST" \
  --sparkle-ed-key-file "$SPARKLE_ED_KEY_FILE" \
  --sparkle-publish-release "sparkle-alpha"
```

Expected:
- Script exits 0.
- `build/Release/Lungfish-0.4.0-alpha.12-arm64.dmg` exists.
- `build/Release/release-metadata.txt` exists.
- App and DMG notary logs exist.

- [ ] **Step 3: Independently verify artifact**

Run:

```bash
codesign --verify --deep --strict --verbose=2 build/Release/Lungfish.app
xcrun stapler validate build/Release/Lungfish.app
xcrun stapler validate build/Release/Lungfish-0.4.0-alpha.12-arm64.dmg
spctl -a -vv -t open build/Release/Lungfish-0.4.0-alpha.12-arm64.dmg
shasum -a 256 build/Release/Lungfish-0.4.0-alpha.12-arm64.dmg
sed -n '1,220p' build/Release/release-metadata.txt
```

Expected:
- Codesign and stapler validations pass.
- Gatekeeper assessment accepts the DMG.
- SHA-256 is recorded in release notes or release metadata.
- Metadata points at the current cleanup release commit.

- [ ] **Step 4: Update release notes with artifact verification if needed**

If Task 8 left release verification phrased as future work, update `docs/release-notes/v0.4.0-alpha.12.md` with the artifact SHA-256 and verification summary.

Run:

```bash
git add docs/release-notes/v0.4.0-alpha.12.md
git commit -m "docs: record alpha 12 artifact verification"
```

Expected: commit succeeds if release notes changed.

- [ ] **Step 5: Merge cleanup branch to main and push**

Run:

```bash
git status --short --branch
git switch main
git pull --ff-only origin main
git merge --ff-only codex/repo-hygiene-spring-cleaning
git push origin main
git status --short --branch
```

Expected:
- Fast-forward merge succeeds.
- `main` is pushed to `origin/main`.
- Local `main` is clean and aligned with `origin/main`.

- [ ] **Step 6: Tag and verify release**

Run:

```bash
git tag -a v0.4.0-alpha.12 -m "Lungfish 0.4.0-alpha.12"
git push origin v0.4.0-alpha.12
gh release view v0.4.0-alpha.12
gh release view sparkle-alpha
```

Expected:
- Versioned release exists with the DMG attached.
- Sparkle alpha release contains updated appcast.

## Final Review Checklist

- [ ] `git status --short --branch` shows clean local `main` aligned with `origin/main`.
- [ ] `agents/README.md` is the canonical roster.
- [ ] `.codex/agents/` and `.claude/agents/` mirror canonical definitions where needed.
- [ ] `docs/archive/README.md` explains archive semantics.
- [ ] Active references no longer point at moved historical paths.
- [ ] Retained scientific fixtures have provenance sidecars or are outside active use.
- [ ] `README.md` links to Read the Docs.
- [ ] App/CLI/test metadata reports `0.4.0-alpha.12`.
- [ ] Swift, Python, manual, provenance, and XCUITest gates have documented results.
- [ ] Notarized DMG exists and is independently verified.

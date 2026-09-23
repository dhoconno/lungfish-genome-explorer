# Shared reviewer brief (2026-09-23 fresh-start audit)

Repo: /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/lge-best-practices-audit-0a1b8f (git worktree, HEAD a1f439076).
Product: Lungfish Genome Explorer (LGE), a Swift 6.2 macOS 26 (Apple Silicon) AppKit genomics desktop app + `lungfish-cli`. ~750K lines of Swift across modules
LungfishCore -> LungfishIO -> LungfishWorkflow -> LungfishKit (shared UI kernel) -> 9 feature leaf UI modules -> LungfishApp (composition root) -> Lungfish (exe); LungfishCLI separate.
Most of the code was written by earlier LLM generations at very high velocity (488 commits in the last 18 days). Expect jagged or incomplete features, inconsistencies between features, duplication, overengineering and overtesting.

## Ground rules (binding)
1. FRESH START. Do NOT read `docs/reports/2026-09-05-lge-audit/`, `docs/reports/2026-09-05-release-redesign/` or `docs/superpowers/plans/2026-09-05-*`. Form independent judgments from the code. Other docs may be read as claims to verify, never as evidence.
2. Do NOT modify any source, test, script, config or existing doc. Do NOT commit. The ONLY file you write is your own report at the path you are given.
3. Do NOT run `swift build`, `swift test`, `xcodebuild` or anything that takes the SwiftPM `.build/.lock` unless your prompt explicitly grants it (one reviewer owns builds). Read-only shell (grep, find, git log/blame, wc, python for counting) is fine.
4. Every finding must cite evidence as repo-relative markdown links with line numbers, e.g. [ViewerViewController.swift:812](Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:812). Open the code and trace it; do not infer defects from file names, size or comments alone.
5. Label confidence honestly: **Confirmed** (reproduced by running something), **Traced** (control flow followed end to end in source), **Suspected** (plausible, needs verification). Never overstate. Size alone is not a defect.
6. Prefer depth over breadth: 10-25 well-evidenced findings beat 80 shallow ones. Sample widely, then dig into the worst.
7. Also record what is GOOD and should be preserved, so implementers do not "fix" it away.

## Report format (Markdown)
- Title, scope, method (what you read/ran), and limits.
- Executive summary (5-10 sentences, your overall judgment).
- "Preserve" list.
- Findings table: ID | Priority | Title | Confidence | Effort.
  IDs use your prefix (given in your prompt), e.g. ARC-01.
  Priority: P0 = data loss / wrong scientific results / security / release-breaking; P1 = feature broken or dead-end on a main path, serious perf, high-risk design flaw; P2 = inconsistency, partial feature, maintainability drag; P3 = polish/cleanup.
  Effort: S (<1 day), M (1-3 days), L (>3 days) for an expert LLM agent with review.
- One section per finding: Evidence, Impact / failure scenario, Recommendation (concrete, name files/types), Acceptance test (how an implementer proves it is fixed), Effort.
- "Proposed work packages": group findings into ordered, independently reviewable packages with dependencies, the files touched, and risk. Say which findings should NOT be fixed (accept) and why.
- Keep it scannable. Target 3,000-8,000 words.

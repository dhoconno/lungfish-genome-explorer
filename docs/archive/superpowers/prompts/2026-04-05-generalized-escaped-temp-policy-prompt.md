Implement the generalized escaped-temp fix using these artifacts:
- Spec: `docs/superpowers/specs/2026-04-05-generalized-escaped-temp-policy-design.md`
- Plan: `docs/superpowers/plans/2026-04-05-generalized-escaped-temp-policy.md`

Objective:
- Keep strict enforcement that project-required operations must write temp data under `<project>.lungfish/.tmp/`.
- Avoid false-positive DEBUG crashes for valid fallback/system-temp flows.
- Make escaped-temp assertions evidence-based (policy + metadata), not prefix-only.

Requirements:
1) ProjectTempDirectory policy model
- Add `TempScopePolicy` with:
  - `requireProjectContext`
  - `preferProjectContext`
  - `systemOnly`
- Add a new create API that accepts `contextURL`, `policy`, and caller metadata.
- Throw an explicit error when `requireProjectContext` cannot resolve a `.lungfish` root.
- Keep old APIs as compatibility wrappers.

2) Temp provenance metadata
- On temp dir creation, write `.lungfish-temp-origin.json` containing:
  - prefix, policy, contextPath, resolvedProjectPath, pid, createdAt, caller.

3) DEBUG scanner behavior
- In `AppDelegate` escaped-temp scanner, parse provenance metadata.
- Assert only when a directory in system temp was created with `requireProjectContext` in this app session.
- For matching prefixes without provenance metadata, warn (do not assert) during migration.

4) Callsite migration (initial high-risk)
- Migrate demux/esviritu/taxtriage/orient/spades temp allocations to explicit policy.
- App project workflows should use `requireProjectContext`.
- CLI/no-project workflows should use `preferProjectContext` or `systemOnly` as appropriate.

5) Root discovery robustness
- Ensure project-root detection does not fail due deep nesting.

6) Tests and verification
- Add/extend tests for policy semantics, provenance marker, scanner decision logic, and demux project vs non-project behavior.
- Run targeted tests:
  - `swift test --filter ProjectTempDirectoryTests`
  - `swift test --filter DemultiplexingPipelineTests`
  - `swift test --filter EsVirituPipelineTests`

Constraints:
- Do not loosen release behavior or silently ignore real policy violations.
- Keep backward compatibility while migration is incomplete.
- Prefer minimal, reviewable commits grouped by plan tasks.

Deliverables:
- Code changes implementing the policy architecture.
- Updated tests and passing targeted test evidence.
- Brief summary of migrated callsites and any remaining legacy callsites.

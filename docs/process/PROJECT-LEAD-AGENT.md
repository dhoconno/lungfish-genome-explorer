# Project Lead Agent — Orchestration Specification

## Overview

The Project Lead Agent is the top-level orchestrator for the Lungfish Genome Explorer. It coordinates two lead agents — the **Development Lead Agent** and the **GUI Lead Agent** — ensuring they work in lockstep. Every feature and bug fix flows through this agent, which decides scope, assigns ownership, and mediates cross-team communication.

## Team Structure

```
Project Lead Agent
├── Development Lead Agent (code correctness, architecture, CLI parity)
│   ├── Domain Expert Teams (bioinformatics, genomics, formats)
│   ├── Platform Expert Teams (Swift 6.2, macOS 26, AppKit, concurrency)
│   ├── Adversarial Code Review Team (attack surface, edge cases, misuse)
│   ├── Adversarial Science Review Team (hostile reviewer #2 + skeptical bench biologist)
│   ├── Code Simplification Team (complexity reduction, dead code, abstraction audit)
│   └── CLI Parity Team (every GUI operation has a CLI equivalent)
│
├── GUI Lead Agent (visual quality, behavioral correctness, user simulation)
│   ├── Visual Verification Team (rendering, layout, HIG compliance, dark mode)
│   ├── Behavioral Testing Team (run tools, validate output format/correctness)
│   ├── Biologist Persona Team (simulate bench scientist workflows)
│   ├── Bioinformatician Persona Team (simulate power-user workflows)
│   └── Accessibility & Usability Team (VoiceOver, keyboard nav, discoverability)
│
└── Expert Review Groups (cross-cutting, assembled per feature)
    ├── Performance & Scalability Group
    ├── Data Integrity & Provenance Group
    ├── Security & Input Validation Group
    ├── Error Handling & Recovery Group
    └── Documentation & Onboarding Group
```

## Workflow

### Phase 0: Triage & Scoping
The Project Lead receives a feature request or bug report and:
1. Writes a scope document to `docs/plans/` (survives context compaction)
2. Classifies the work: **Code-only**, **GUI-only**, or **Full-stack** (both)
3. Selects which Expert Review Groups are relevant
4. Assigns primary ownership to Development Lead, GUI Lead, or both

### Phase 1: Parallel Investigation
Both leads investigate simultaneously within their domains:
- **Development Lead** → assembles domain + platform experts, produces architecture plan
- **GUI Lead** → assembles persona + visual teams, produces interaction plan
- Investigation reports written to `docs/plans/`

### Phase 2: Cross-Team Consensus
The Project Lead convenes both leads to:
- Resolve interface contracts (what the GUI expects from the code layer)
- Agree on data models, error shapes, and progress reporting
- Identify CLI test equivalents for every GUI operation
- Write the consensus document to `docs/plans/`

### Phase 3: Phase Breakdown
Project Lead breaks work into phases where:
- Each phase is independently testable and committable
- No phase exceeds ~500 lines of new code
- Dev phases and GUI phases can run in parallel when they don't share files
- **Collision prevention**: No two parallel tasks modify the same file
- Dependencies between phases are explicit
- Every Dev phase includes an adversarial review gate and simplification check
- Every GUI phase includes a behavioral test gate

### Phase 4: Implementation (with Gates)
For each phase, the owning lead executes:

**Development phases:**
1. Expert agent implements code
2. **Adversarial Code Review** — tries to break it (edge cases, malformed input, concurrency races, resource exhaustion)
3. **Adversarial Science Review** (when bioinformatics logic is involved) — hostile reviewer #2 challenges parameter defaults, algorithm fidelity, biological plausibility, and comparison against established tools
4. **Code Simplification** — audits for unnecessary complexity, dead code, premature abstraction, overly defensive patterns
5. Build verification (zero errors, zero warnings)
6. Existing tests pass (zero regressions)
7. New tests pass (including CLI equivalents)
8. Lead sign-off and commit

**GUI phases:**
1. Visual implementation
2. **Visual Verification** — pixel-level checks (overdraw, clipping, alignment, dark mode, resize behavior)
3. **Behavioral Testing** — run the actual tool, verify output format and correctness, check error states
4. **Persona Walkthrough** — biologist or bioinformatician persona runs the workflow end-to-end
5. Lead sign-off and commit

### Phase 5: Expert Group Review
The Project Lead activates the relevant Expert Review Groups:
- Each group reviews the full implementation from their perspective
- Issues logged as findings with severity (critical/major/minor)
- Critical findings block merge; major findings require tracking issues
- Reports written to `docs/reviews/`

### Phase 6: Integration Testing
- CLI tests exercise the same code paths as GUI
- Simulated data tests from genomics experts
- End-to-end workflow tests (import → process → export)
- Performance benchmarks for data transformation operations
- GUI behavioral tests confirm tools produce correct output

### Phase 7: Cross-Team Retrospective
After each major feature:
- What worked, what didn't, what was caught late
- Update this process document if needed
- Archive completed plans to `docs/archive/`

---

## Communication Protocol

### Dev Lead → GUI Lead
- "Here's the new API / data model — here's what your views should expect"
- "This operation now reports progress via OperationCenter — wire up the UI"
- "CLI tests pass for this operation — ready for GUI integration"

### GUI Lead → Dev Lead
- "The biologist persona couldn't discover this feature — needs better naming/placement"
- "This tool returns data in format X but the view expects format Y"
- "Error state Z isn't handled — the view shows a blank panel"

### Project Lead → Both
- "Priority change: pause feature X, focus on bug Y"
- "Expert group found issue — Dev Lead owns the fix, GUI Lead verifies the UX"
- "Phase 3 approved — begin parallel implementation"

---

## Fundamental Principles

### Platform
- **Target**: macOS 26 (Tahoe) exclusively. No backward compatibility.
- **Swift 6.2**: Latest language features, strict concurrency.
- **SwiftUI preferred**, AppKit for custom rendering, hierarchical tables, hover, performance-critical views.

### Apple HIG Compliance
- SF Symbols for all icons
- System colors (`.primary`, `.secondary`, `.accentColor`)
- Dark Mode support in all views
- `beginSheetModal` for dialogs (NEVER `runModal()`)
- Standard keyboard shortcuts
- VoiceOver labels on all custom views

### Operations Panel
Every data transformation MUST:
1. Register with `OperationCenter.shared.start()`
2. Report progress via `OperationCenter.shared.update()`
3. Report completion via `.complete()` or `.fail()`
4. Support cancellation via `.setCancelCallback()`
5. Be visible in the Operations Panel with meaningful status messages

### Logging
All operations log to os.log using `LogSubsystem` constants:
- `.core` for data models/services, `.io` for parsing, `.ui` for rendering
- `.workflow` for tool execution, `.app` for UI/VCs, `.plugin` for plugins

### Provenance
All data transformations MUST record provenance (tool, version, parameters, inputs, outputs, checksums, runtime).

### Concurrency Patterns
- `DispatchQueue.main.async { MainActor.assumeIsolated { } }` for UI updates from background
- `Task.detached` for long-running pipelines
- `@unchecked Sendable` for view models in detached contexts
- Generation counters for stale result prevention

### CLI Parity
Every GUI operation MUST have a CLI equivalent using shared pipeline actors. CLI tests validate the same code paths.

### Testing Requirements
- Tests BEFORE shipping
- Simulated data from genomics experts
- Edge cases: empty files, special characters, very large inputs
- Regression tests for all bug fixes
- Performance tests for data-intensive operations

---

## Anti-Patterns to Avoid

1. **Never implement without a persisted plan** — context can compact at any time
2. **Never skip expert review** — even "simple" fixes can have domain implications
3. **Never modify files being edited by another agent** — causes merge conflicts
4. **Never use `runModal()`** — deprecated on macOS 26
5. **Never use `Task { @MainActor in }` from GCD** — cooperative executor unreliable
6. **Never skip Operations Panel registration** — users need visibility
7. **Never skip provenance recording** — reproducibility is critical for scientific software
8. **Never ship GUI without CLI parity** — untestable code paths are unacceptable
9. **Never ship code that hasn't passed adversarial review** — the attack surface grows with each feature
10. **Never add complexity without justification** — the simplification team exists for a reason

# Haplotype Weak Support Tint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tint weak automated haplotype calls in the genotype summary viewport while rendering manually assigned haplotypes at full opacity.

**Architecture:** Add weak-support metadata to `GenotypeHaplotypeTapeView.Cell` so the existing outline tape can render low-confidence automated calls without changing scientific outputs. Compute weakness in `GenotypeResultViewController` from raw per-sample, per-locus genotype reads: a slot is weak when its supporting reads are fewer than 5 or below 5% of the sample+locus total. Manual per-slot overrides and manual haplotype assignments suppress the weak tint.

**Tech Stack:** Swift, AppKit, XCTest, Lungfish genotype result UI models.

---

### Task 1: Add Weak-Support Tape Slot Tests

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests that configure a haplotype analysis with one strong and one weak called haplotype in the same sample+locus. Assert that the weak slot is marked weak for `3 / 103` reads, that a 4-read slot is marked weak even above 5%, and that a manual override or manual assignment clears the weak marker.

- [ ] **Step 2: Run tests to verify red**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testWeakHaplotypeSlotIsTintedBelowFivePercent --filter GenotypeResultViewportTests/testWeakHaplotypeSlotIsTintedBelowFiveReads --filter GenotypeResultViewportTests/testManualHaplotypeSlotRestoresFullOpacity
```

Expected: compile failure or assertion failure because tape cells do not expose weak-support state yet.

### Task 2: Compute Weak Automated Haplotype Support

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeHaplotypeTapeView.swift`

- [ ] **Step 1: Implement minimal model change**

Extend reference/manual/recombinant tape cells with weak-support state or an equivalent wrapper, preserving existing labels and accessibility.

- [ ] **Step 2: Implement weak-support lookup**

Build a per-sample, per-locus read total from `result.calls`. For each automated haplotype slot, sum reads from matched diagnostic alleles for that haplotype in the same sample and locus. Mark the slot weak when supporting reads are `< 5` or supporting reads divided by locus total is `< 0.05`. Do not mark manual overrides or manual haplotype assignments weak.

- [ ] **Step 3: Render weak automated calls**

Render weak reference cells with a light red tint/washed appearance. Keep manual cells and overridden slots at full opacity.

- [ ] **Step 4: Run focused tests**

Run the same focused `GenotypeResultViewportTests` command. Expected: all three tests pass.

### Task 3: Regression Sweep

**Files:**
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Run broader genotype viewport tests**

Run:

```bash
swift test --filter GenotypeResultViewportTests
```

Expected: pass.

- [ ] **Step 2: Review diff**

Confirm the change is limited to viewport rendering/state and tests, with no CLI workflow or scientific output changes.

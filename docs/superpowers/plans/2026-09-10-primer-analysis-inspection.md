# Primer Analysis Inspection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this bounded task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give users a read-only CLI route to inspect the new durable analysis format and reject corrupted bundles.

**Architecture:** `lungfish-cli primers analysis inspect PATH` invokes the strict IO loader before producing a summary or JSON manifest. It does not execute design tools or alter the bundle.

**Tech Stack:** Swift, ArgumentParser, LungfishIO, XCTest.

**Spec:** `docs/proposals/2026-09-10-pcr-primer-pack.md`, storage subset.

## Global Constraints

- Work only in the isolated `codex/pcr-primer-design` worktree.
- Inspection is read-only, classified explicitly in `ScientificProvenancePolicy`.
- Do not claim tool execution, scheme validation, or biological validity.
- Verify full bundle integrity before outputting success or the JSON manifest.
- Use opaque harmless fixtures generated with the real bundle writer.

## Task 1: Inspect command and integrity checks

**Files:**
- Modify `Sources/LungfishCLI/Commands/PrimerCommand.swift` to register `PrimerAnalysisCommand`.
- Create `Sources/LungfishCLI/Commands/PrimerAnalysisCommand.swift` containing `PrimerAnalysisCommand` and `PrimerAnalysisInspectCommand`.
- Modify `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift` with an exact read-only path policy for `primers analysis inspect`.
- Create `Tests/LungfishCLITests/PrimerAnalysisInspectCommandTests.swift`.

**Interface:**
```swift
struct PrimerAnalysisInspectCommand: ParsableCommand {
    @Argument var bundlePath: String
    @Flag(name: .long) var json = false
    func inspectionOutput() throws -> String
    mutating func run() throws
}
```

- [x] Write tests using real `PrimerAnalysisBundleWriter` output. Parse through `LungfishCLI.parseAsRoot(["primers", "analysis", "inspect", path, "--json"])`, then verify the decoded output retains the analysis UUID and grouping. Confirm all bundle bytes are unchanged after inspection. Corrupt an inventoried file and verify both text and JSON output paths throw. Check the exact provenance policy is read-only.
- [x] Before registering the command, run the existing CLI with the new command path and confirm it rejects the unknown command. The baseline binary rejected `primers analysis inspect` with exit status 64. Run the new XCTest cases with the storage dependency during integrated verification.
- [x] Implement `inspectionOutput()` by calling `PrimerAnalysisBundle.load(from:)`. JSON output encodes only its validated manifest with ISO-8601 dates and sorted keys. Text output includes analysis/run IDs, grouping, input/result/file counts, and the words `Integrity verified`; it makes no scientific validation claim.
- [x] Register the two nested command names `analysis` and `inspect`, preserving existing `primers import` behavior.
- [x] Run the new tests plus the storage and annotation suites, then have Astra review the small integration diff and fix any findings.

No import CLI schema or engine commands are introduced by this task. The durable writer remains a workflow API for future GUI and CLI adapters.

## Verification evidence

- The built CLI displays `primers analysis inspect <bundle-path> [--json]` help with exit status 0.
- Inspecting a nonexistent bundle exits with status 1 and an integrity-loading error, without printing a success summary or manifest.
- Final integrated run: `swift test --jobs 4 --filter 'PrimerAnalysis|SequenceAnnotationTests|AnnotationDatabaseTests|PluginPackRegistryTests|PrimerSchemeBundleTests|ScientificProvenancePolicyTests'` exited 0: 187 XCTest cases and 9 Swift Testing cases passed, zero failures, on 2026-09-10 at 19:11 CDT. Evidence: `.build/primer-analysis-integrated.log`. All four new CLI cases passed.
- Astra reviewed the CLI and annotation integration and approved the final storage changes after the scoped fix review. This verifies the storage/inspection foundation only; engine installation, design workflows, and GUI behavior remain unimplemented and untested.

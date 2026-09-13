# Primer3 Design Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Add an optional managed Primer3 tool and an independently executed Primer3 workflow with durable native outputs and exact provenance for the user's MHC work.

**Architecture:** Manifest-pinned optional tool requirement uses existing conda installer and cancellation-aware process runner. A separate Workflow adapter snapshots FASTA/native MSA inputs, constructs strict Boulder records from explicit options, invokes Primer3, preserves raw outputs and a versioned normalized display artifact, and publishes through the existing analysis bundle writer. Each external invocation has its own canonical provenance artifact; wrapper provenance never substitutes for tool execution evidence.

**Tech Stack:** Swift, Foundation, LungfishIO FASTA/MSA APIs, existing conda runner/provenance and bundle writer, XCTest.

**Spec:** docs/proposals/2026-09-10-pcr-primer-pack.md; parent approved MHC-specific workflow continuation and separate Primer3/PrimalScheme3 adapters.

## Global Constraints

- Work only .worktrees/pcr-primer-design at branch codex/pcr-primer-design, baseline 95c1b27a5. No commits/pushes. Root owns GUI/menu/routing and final integration.
- Primer3 supports independent designs; combined cross-MSA schemes require the separate PrimalScheme3 adapter. Never claim independently generated Primer3 pairs form a validated pool.
- No viral fixtures, prior viral patches, custom terminal coverage optimizer, or unsupported chemistry claims. Internal oligo is an ordinary Primer3 internal probe; no molecular-beacon claim.
- Every created scientific artifact has canonical provenance: exact executed path/argv/version, full resolved Boulder parameters and defaults, input snapshots/checksums/sizes, runtime/conda identities, output paths/checksums/sizes, timing/status/stderr. Publish final payload paths, preserve historical execution paths explicitly.
- Preflight all inputs/options before running. Preserve original identities, use ordinal/UUID keys rather than names. Never silently choose first MSA row or concatenate separate alignments.
- No biological execution during implementation until controller approves synthetic nonpathogen validation. Help/about smoke runs carry no scientific input.

### Task 1: Manifest-backed Primer3 adapter and durable publication

**Files:**
- Modify Sources/LungfishWorkflow/Conda/PluginPack.swift
- Modify Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json
- Modify Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift
- Create Sources/LungfishWorkflow/PrimerDesign/Primer3DesignOptions.swift
- Create Sources/LungfishWorkflow/PrimerDesign/Primer3DesignPipeline.swift
- Create Sources/LungfishWorkflow/PrimerDesign/Primer3DesignResults.swift
- Create Tests/LungfishWorkflowTests/Primer3DesignPipelineTests.swift
- Additional narrowly focused PrimerDesign files allowed where parser/input/runner separation materially improves readability; report exact names before coding.

**Interface:**
```swift
public struct Primer3DesignOptions: Sendable {
  // Explicit product size, target interval, candidate count, length/Tm/GC and internal-oligo choices.
  // Exact public initializer names sent to root before GUI binds.
}
public struct Primer3DesignRequest: Sendable {
  public let inputURLs: [URL]
  public let destinationURL: URL
  public let options: Primer3DesignOptions
  public let invocation: PrimerAnalysisWrapperInvocation
}
public struct Primer3DesignPipeline: Sendable {
  public func run(request: Primer3DesignRequest,
                  progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> URL
}
```

- [x] Step 1: Define exact typed options/input selection/result identities and send root contract before implementation. Read existing MSA coordinate map loader and establish explicit selected template row and conserved-site semantics for MSA mode; do not silently substitute per-row designs. GUI-compatible 1-based inclusive target coordinates are converted once and original/projected coordinates recorded.
- [x] Step 2: Registry RED test: pack pcr-primer-design active optional, contains only verified managed Primer3 for now, exact manifest spec bioconda::primer3=2.6.1=pl5321haef7865_7, executable primer3_core, smoke --about with exit0 and output version. Update exact optional ordering expectation. Run coordinated filtered test to establish RED.
- [x] Step 3: Register fromManifest requirement, version/license/source in JSON only. Metadata GPL-2.0-or-later, https://github.com/primer3-org/primer3. Description states installed Primer3 scope and no PrimalScheme3 capability. No source overlay/hook workaround.
- [x] Step 4: Adapter RED tests use injected runner returning synthetic Boulder text, not installed biological execution. Verify argument construction/input identity, invalid option rejection, numeric finite/range/order validation, target conversion, explicit sequence/MSA selection, duplicate labels, multiple record mapping, strict malformed output rejection, correct right-primer coordinate orientation, internal oligo, zero candidates and per-record error.
- [x] Step 5: Implement preflight/snapshot, Boulder construction, cancellation-aware run via established conda runner, parser and publication. Preserve raw output, input/Boulder snapshots, stderr, canonical execution provenance and normalized JSON. Reject overwrite before running; cancellation/failure never yields success bundle; clean only owned scratch. Tool version from about probe and runtime conda metadata must be factual. Do not use fallback guessed version. Exact argv supplied to Process excludes shell redirection; stream bindings/replay command recorded separately.
- [x] Step 6: GREEN tests verify reopen after relocation/source deletion, provenance presence/full resolved options/final paths, cancellation and runner failure cleanup, malformed output, no-result semantics. No stdout-only fake success. Run relevant registry/adapter/storage/provenance tests under shared build lock.
- [x] Step 7: Astra controller reviews full worker diff and report; root performs an independent Astra review (fresh worker unavailable because the four-thread limit was reached). Root integration/GUI tests occur after contract stability. Keep plan/ledger evidence, no commit.

## Separate PrimalScheme3 runtime assessment

Official Bioconda primalscheme is legacy1.4.1 and must not stand in for primalscheme3. Official PyPI primalscheme3 current3.3.0 requires Python>=3.11,<3.14. Existing installer has no pip-distribution identity/reconciliation contract. Controller will assess a checksum-pinned managed pip artifact/dependency record as a separate task before changing generic installer. Standard version/help checks only during installation validation; no previous custom patches.

## Completion evidence and plan adjustments

Completed implementation and Astra/root review on 2026-09-10 CDT. Final coordinated `.build/primer-design-integrated-10.log`: 173 XCTest cases, one intentional live-installer skip, zero failures; 65 Swift Testing cases, zero failures. The live production runtime installer passed in earlier integrated runs. Root release-contract checks: 52 Python tests passed. No source changes followed this verification.

The checkboxes record completed task outcomes, not a claim that every originally proposed command ran in its planned order. Tests were authored before implementation; early coordinated RED attempts were blocked by unrelated compilation/fixture errors. Actual behavioral failures were retained in integrated logs and fixed before final GREEN. Source freezes were coordinated with root. Primal-specific mid-run cancellation injection was not added; cancellation uses the established runner and propagated task cancellation, while Primer3/runtime cancellation tests ran.

The user subsequently authorized actual human/macaque MHC CLI verification. Twelve genuine genomic inputs were aligned through the existing CLI. Eighteen PrimalScheme3 workflows passed; final Primer3 conserved runs returned 60 pairs across twelve inputs, plus a three-template internal-oligo run with 15 pairs and 15 internal oligos. Original failure results remain preserved. See `docs/features/pcr-primer-design-validation.md` for source hashes, commands, artifacts and limits. No biological performance claim is inferred.

Final scope also includes CLI `primers design primer3` and `primers design primalscheme3`; registry ownership transferred to the separate runtime task. Native MSA snapshots preserve all regular files, including hidden upstream provenance. A throwing directory walk uses accumulated relative components and accurate format labels. Gapped FASTA, source row identities and coordinate maps are validated. Native excluded-position N masking avoids the observed Primer3 tag-list size limit; both primer/internal N limits are explicit zero, and returned coordinates/sequences are checked before publication.

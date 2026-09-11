# PrimalScheme3 Design Workflow Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans; root assigned this adapter to Astra while Sol implements independent Primer3/runtime tasks.

**Goal:** Execute the verified stock PrimalScheme3 interface on explicit MHC alignment inputs and publish complete durable native results with provenance.

**Architecture:** Separate typed request and cancellation-aware injected native runner. Preflight/snapshot all selected alignments, invoke one scheme-create per independent input or one panel-create with all inputs for combined grouping, inventory every native file, and wrap transactionally with canonical external-tool provenance. The existing saved viewer opens published results without installed tools.

**Tech Stack:** Swift, existing FASTA/MSA loader, NativeToolRunner, canonical provenance builder, PrimerAnalysisBundleWriter, XCTest.

**Spec:** docs/proposals/2026-09-10-pcr-primer-pack.md and root approved stock PrimalScheme3 MHC workflow continuation.

## Global Constraints

Only isolated branch codex/pcr-primer-design; no commits/pushes. No prior viral patches/fixtures or custom terminal coverage optimization. Stock version3.3.0 only for verified capabilities; selected override must identify exact supported version. Unsupported uncovered-end exclusion is explicitly unavailable in GUI. Every supplied native output is preserved. Combined grouping executes genuine panel-create with repeated --msa, never relabels independent runs. Exact argv/runtime/timing/status/stderr, all consumed input and final output file identities, options/defaults and saved memberships recorded. No inference of biological validity from exit0.

### Task 1: Request, alignment snapshot and stock execution

Files: new Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift; new Tests/LungfishWorkflowTests/PrimalScheme3DesignPipelineTests.swift. Root owns GUI/results view, sibling owns Primer3 input utilities/runtime install.

Interface: public PrimalScheme3DesignOptions(ampliconSize:Int,poolCount:Int); public PrimalScheme3DesignRequest(inputURLs:[URL],destinationURL:URL,options:,grouping:PrimerAnalysisGrouping,invocation:PrimerAnalysisWrapperInvocation,executableURL:URL?=nil,expectedInputChecksums:[URL:String]=[:]); public pipeline.run(request:progress:(@Sendable(Double,String)->Void)?=nil) async throws -> URL.

- [x] Tests first: exact independent/combined command shape; no overwrite/execution after invalid input; changed inspection token; unequal MSA rows; preserves nested native files and actual memberships; missing output/version or execution failure cannot publish; cancellation; relocation and canonical tool provenance final paths.
- [x] Implement strict options and explicit input snapshots using existing loaders, no implicit alignment of raw unequal FASTA. Preserve source bytes/row identities, uppercase/gap-preserving consumed snapshot and transformation metadata. Bind source inspection token to snapshot before process.
- [x] Version-probe exact binary then run through NativeToolRunner with cancellation and bounded timeout. Use --amplicon-size/--n-pools plus explicit verified mapping/mode flags and list exact resolved defaults. Stock unsupported version fails before scientific run.
- [x] Publish each run native directory, stdout/stderr, canonical toolProvenance JSON and consumed input provenance. Use builder relocatedOutput descriptors and durable replay argv; wrapper invocation remains actual GUI/CLI invocation. All preserved tool outputs get complete manifest file inventory.
- [x] Run coordinated focused tests, independent root review and integration. Record native installation/smoke separately from mocked workflow tests. No scientific fixture execution unless approved benign verification.

## Completion evidence and plan adjustments

Completed implementation and Astra/root review on 2026-09-10 CDT. Final coordinated `.build/primer-design-integrated-10.log`: 173 XCTest cases, one intentional live-installer skip, zero failures; 65 Swift Testing cases, zero failures. The live production runtime installer passed in earlier integrated runs. Root release-contract checks: 52 Python tests passed. No source changes followed this verification.

The checkboxes record completed task outcomes, not a claim that every originally proposed command ran in its planned order. Tests were authored before implementation; early coordinated RED attempts were blocked by unrelated compilation/fixture errors. Actual behavioral failures were retained in integrated logs and fixed before final GREEN. Source freezes were coordinated with root. Primal-specific mid-run cancellation injection was not added; cancellation uses the established runner and propagated task cancellation, while Primer3/runtime cancellation tests ran.

The user subsequently authorized actual human/macaque MHC CLI verification. Twelve genuine genomic inputs were aligned through the existing CLI. Eighteen PrimalScheme3 workflows passed; final Primer3 conserved runs returned 60 pairs across twelve inputs, plus a three-template internal-oligo run with 15 pairs and 15 internal oligos. Original failure results remain preserved. See `docs/features/pcr-primer-design-validation.md` for source hashes, commands, artifacts and limits. No biological performance claim is inferred.

Final options additionally expose independent-only minOverlap (default10), minimumBaseFrequency (default0), highGC (defaultfalse), and coreCount (default1). Combined runs explicitly use stock panel-create Equal mode. Consumed filenames and FASTA headers are unique per input; a versioned row map preserves original headers and indices while bases/order remain unchanged. Original inputs remain byte-exact snapshots. Engine provenance records mapping, full native configuration, version probe, executable hash, actual argv and durable replay; default managed runs require a valid runtime receipt.

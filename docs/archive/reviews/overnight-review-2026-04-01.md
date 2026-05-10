# Overnight Adversarial Code Review — 2026-04-01

## Summary

| Module | Critical | Major | Minor | Suggestion |
|--------|----------|-------|-------|------------|
| LungfishCore + LungfishIO | 4 | 9 | 9 | 6 |
| LungfishWorkflow + LungfishPlugin | 4 | 8 | 9 | 8 |
| LungfishApp + LungfishUI + LungfishCLI | 4 | 5 | 7 | 6 |
| **Total** | **12** | **22** | **25** | **20** |

## Critical Findings (Must Fix)

### Core/IO
- C-1: VCFReader toAnnotation() off-by-one for multi-base variants (end is 1-based inclusive, not half-open)
- C-2: Two conflicting VCFVariant types (LungfishCore vs LungfishIO) with no conversion
- C-3: GeminiProvider leaks API key in URL query string (should use header)
- C-4: OpenAIProvider inserts system prompt twice

### Workflow/Plugin
- C-1: Data race in NativeToolRunner.runPipeline stderr drain (concurrent Array writes)
- C-2: Force-unwrap of terminationContinuation in ProcessManager.spawn
- C-3: try! in AppleContainerRuntime production code
- C-4: fatalError in reachable code path (ToolProvisioningOrchestrator .custom case)

### App/UI/CLI
- C-1: ClassificationWizardSheet ignores user goal selection (hardcodes .profile)
- C-2: AssembleCommand gz-stripping is a no-op (returns original path)
- C-3: Force-cast as! AppleContainerRuntime in AssembleCommand
- C-4: runModal() used in 3 active code paths (macOS 26 deprecation)

## Key Reuse Opportunities Identified
1. Extract WizardSheetHeader/Footer reusable components
2. Consolidate 5 duplicate shell-escape functions
3. Consolidate 3 duplicate version detection patterns
4. Extract shared CLI command base for bioinformatics pipelines
5. Merge two VCFVariant types into one
6. Extract AI provider HTTP helper (3x duplication)
7. Consolidate 3 duplicate PluginOptions types
8. Share drawPlaceholder/drawTrackLabel across tracks
9. Share inputDisplayName across wizard sheets
10. Share file-existence validation across CLI commands

## Dialog Standards Non-Compliance
- EsVirituWizardSheet: No icon, no subtitle, non-standard title format
- TaxTriageWizardSheet: No icon, no subtitle, dimensions 560x580 (exceeds 520x520 max)

## Files Exceeding 500-Line Threshold
- MainSplitViewController.swift: ~2726 lines
- FASTQDatasetViewController.swift: ~2420 lines
- TaxTriageResultViewController.swift: ~2448 lines
- NaoMgsResultViewController.swift: ~1403 lines
- EsVirituResultViewController.swift: ~973 lines
- TaxonomyViewController.swift: ~933 lines

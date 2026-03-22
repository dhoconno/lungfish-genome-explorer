# QA & Testing Strategy Expert Review — 2026-03-21

## Executive Summary
3,663 tests across 148 files. Coverage heavily concentrated in IO (1,192) and App (1,017). Critical structural gaps: LungfishUI (26 tests for 9 source files), LungfishPlugin (78 tests for 10 files), and zero tests for several key subsystems (FormatRegistry, ReferenceFrame, RowPacker, PluginRegistry, ImportService, BgzipReader).

Estimated ~250-300 new tests needed across 25-30 new test files.

---

## Module Coverage Summary

| Module | Source Files | Test Files | Tests | Rating | Top Gap |
|--------|-------------|-----------|-------|--------|---------|
| LungfishCore | 45 | 25 | 862 | GOOD | TempFileManager, SRAService |
| LungfishIO | 53 | 48 | 1,192 | GOOD | FormatRegistry, BgzipReader |
| LungfishUI | 9 | 3 | 26 | **POOR** | ReferenceFrame, RowPacker |
| LungfishPlugin | 10 | 6 | 78 | ADEQUATE | PluginRegistry |
| LungfishWorkflow | 59 | 18 | 306 | ADEQUATE | Tool provisioning, WorkflowRunner |
| LungfishApp | 109 | 40 | 1,017 | ADEQUATE | ImportService, BatchProcessing |
| LungfishCLI | 12 | 2 | 120 | ADEQUATE | Command execution tests |
| Integration | — | 3 | 62 | ADEQUATE | Full workflow, performance |

---

## CRITICAL Gaps (Priority 1 — Do First)

### 1. ReferenceFrame unit tests (LungfishUI) — ~20 tests
- All coordinate math depends on this; off-by-one = every track renders wrong
- Tests: `testScreenPositionForGenomicCoordinate`, `testGenomicPositionForScreenX`, `testZoomIn/Out`, `testPanClamped`, `testBPPerPixelCalculation`, `testVisibleRangeAfterResize`, `testTileIndexForPosition`

### 2. RowPacker unit tests (LungfishUI) — ~15 tests
- Feature packing algorithm; broken = overlapping annotations
- Tests: `testPackNonOverlapping`, `testPackOverlappingCreatesNewRow`, `testMinGapRespected`, `testMaxRowsLimit`, `testPerformance1000Features`

### 3. FormatRegistry unit tests (LungfishIO) — ~11 tests
- 7 source files, 0 tests. Central format detection/dispatch system
- Tests: `testDetectFormatFromExtension`, `testDetectFromMagicBytes`, `testImporterLookup`, `testExporterLookup`, `testBuiltInFormatsCount`

### 4. PluginRegistry unit tests (LungfishPlugin) — ~20 tests
- Plugin lifecycle (register, query, filter) completely untested
- Tests: `testRegisterPlugin`, `testRegisterDuplicateThrows`, `testQueryByCategory`, `testQueryByCapabilities`, `testAllBuiltInPluginsHaveUniqueIds`

### 5. ImportService unit tests (LungfishApp) — ~15 tests
- Primary entry point for user data, zero tests
- Tests: `testDetectFASTAFormat`, `testDetectVCFFormat`, `testDetectGzippedFormat`, `testImportFASTAFile`, `testImportInvalidFile`

### 6. BgzipIndexedFASTAReader regression test (LungfishIO) — ~4 tests
- Documented infinite-loop bug was fixed but has no regression test
- Tests: `testReadUncompressedRangeDoesNotInfiniteLoop`, `testReadPastEndOfData`

---

## HIGH Gaps (Priority 2)

### LungfishIO
- FASTAIndex tests (~4 tests) — .fai index parsing
- GzipSupport tests (~3 tests) — gzip detection/decompression
- BigBed/BigWig reader tests (~8 tests) — binary format readers with R-tree traversal

### LungfishWorkflow
- Tool provisioning tests (~12 tests) — 5 source files, 0 tests
- FASTQIngestionPipeline tests (~8 tests)
- WorkflowRunner tests (~6 tests)
- NativeBundleBuilder tests (~6 tests)

### LungfishApp
- AnnotationSearchIndex tests (~10 tests)
- BatchProcessingEngine tests (~8 tests)
- FASTQIngestionService tests (~6 tests)
- BundleDataProvider tests (~8 tests)
- FASTQDerivativeService tests (~6 tests)

### LungfishCLI
- FetchCommand, AnalyzeCommand, BundleCommand argument parsing (~18 tests)
- CLI integration tests with real execution (~4 tests)

### LungfishCore
- TempFileManager tests (~5 tests)
- SRAService mock-based tests (~4 tests)
- GenomicRegion arithmetic tests (~5 tests)

### Integration
- Full workflow tests (import→view→export) (~6 tests)
- Performance regression benchmarks (~6 tests)

---

## MEDIUM Gaps (Priority 3)

- WorkflowRunner, ProcessManager, NextflowRunner, SnakemakeRunner
- Container runtime tests (with XCTSkip guards)
- ViewerViewController logic extraction and testing
- Settings tab logic tests
- Filter/query builder tests
- FASTQWriter, QualityScore tests
- GenBankReader expanded edge cases
- InputSignature, BuiltInTools tests
- KeychainSecretStorage, BundleViewState tests

---

## Test Quality Assessment

### Strengths
- **Isolation**: Most tests create temp dirs in setUp/tearDown
- **Assertions**: Specific assertions with context messages
- **Mocks**: Well-designed actor-based MockHTTPClient
- **Error paths**: do/catch with specific error type matching

### Weaknesses
- **Singleton state**: DocumentManager.shared, PluginRegistry.shared not reset between tests
- **Brittle assertions**: Some use `contains("50.0% GC")` — formatting change breaks test
- **Missing mocks**: No mock for NativeToolRunner, FileSystemWatcher, ImportService, container runtimes
- **Resource files**: Missing BigBed, BigWig, BAM, bgzip, .fai test fixtures

### Known Flaky Tests
1. `testSRASearch` — depends on NCBI SRA availability
2. `AppleContainerRuntimeIntegrationTests` (9) — require virtualization entitlement
3. `VCFRealFileTests` (5) — skip if files not present
4. `GFF3RealFileTest` (6) — skip if files not available
5. `PrimerTrimFixtureIntegrationTests` — requires cutadapt

---

## CI/CD Test Tiers

| Tier | Tests | Time | Trigger |
|------|-------|------|---------|
| Tier 1 (Fast) | Core, IO (no resources), Plugin, UI | ~30s | Every commit |
| Tier 2 (Medium) | App, CLI, IO (resources), Workflow (no tools) | ~2min | Every PR |
| Tier 3 (Slow) | Integration, Workflow (tools), performance | ~5min | Pre-merge |
| Tier 4 (Infra) | Container, network-dependent | ~10min | Nightly |

---

## Plugin Protocol Compliance Tests Needed
- `testAllPluginsHaveUniqueIds`
- `testAllPluginsHaveVersionString`
- `testAllPluginsHaveDescription`
- `testAllPluginsHaveIconName`
- `testAllPluginsHaveCategory`
- `testPluginCapabilitiesNotEmpty`

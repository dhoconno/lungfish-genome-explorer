# Comprehensive Testing Strategy

## Core Principle
**Test existing behavior BEFORE refactoring**. Every phase begins by verifying existing tests pass, adds new tests for areas being changed, then implements changes.

## Test Execution Protocol (Every Phase)

```
1. swift build                          # Verify build succeeds
2. swift test                           # Run full suite, record baseline
3. [Write new tests for phase scope]
4. swift test --filter <NewTests>       # Verify new tests pass
5. [Implement phase changes]
6. swift test                           # Full suite — MUST match or exceed baseline
7. Code review sign-off
8. Commit
```

## CI Test Tiers

| Tier | Scope | Time | Trigger |
|------|-------|------|---------|
| **T1 Fast** | Core, IO (no resources), Plugin, UI | ~30s | Every commit |
| **T2 Medium** | App, CLI, IO (resources), Workflow (no tools) | ~2min | Every PR/phase |
| **T3 Slow** | Integration, Workflow (tools), performance | ~5min | Pre-merge |
| **T4 Infra** | Container, network-dependent | ~10min | Nightly |

## New Tests by Phase

### Phase 1: ~90 new tests
| Test File | Module | Tests | Dependencies |
|-----------|--------|-------|-------------|
| ReferenceFrameTests | UI | 20 | @MainActor |
| RowPackerTests | UI | 15 | None |
| FormatRegistryTests | IO | 11 | Actor (await) |
| PluginRegistryTests | Plugin | 20 | @MainActor |
| ImportServiceTests | App | 15 | Temp filesystem |
| BgzipReaderRegressionTests | IO | 4 | Bgzip fixture |
| GenomicRegionTests | Core | 5 | None |

### Phase 2: ~20 new tests
| Test File | Module | Tests | Dependencies |
|-----------|--------|-------|-------------|
| SheetPresentationTests | App | 10 | Window/sheet mocks |
| ConcurrencySafetyTests | App | 5 | @MainActor |
| AssociatedObjectMigrationTests | App | 5 | None |

### Phase 3: ~40 new tests
| Test File | Module | Tests | Dependencies |
|-----------|--------|-------|-------------|
| SemanticColorsTests | UI | 5 | None |
| TrackRendererBaseTests | UI | 10 | @MainActor |
| ChromosomeAliasResolverTests | Core | 15 | None |
| GenomicDatabaseProtocolTests | IO | 10 | SQLite |

### Phase 4: ~20 regression tests
- Primarily verify existing behavior preserved after file splits
- No new functionality, so tests are regression guards

### Phase 5: ~30 new tests
| Test File | Module | Tests | Dependencies |
|-----------|--------|-------|-------------|
| SwiftUI snapshot/behavior tests | App | 15 | ViewInspector or similar |
| VoiceOverComplianceTests | App | 10 | Accessibility APIs |
| HIG ComplianceTests | App | 5 | None |

### Phase 6: ~100 new tests
| Test File | Module | Tests | Dependencies |
|-----------|--------|-------|-------------|
| PluginProtocolComplianceTests | Plugin | 6 | None |
| GeneticCodeTableTests | Core | 15 | None |
| CLITranslateCommandTests | CLI | 8 | ArgumentParser |
| CLISearchCommandTests | CLI | 8 | ArgumentParser |
| CLIExtractCommandTests | CLI | 8 | ArgumentParser |
| CLIViewCommandTests | CLI | 8 | ArgumentParser |
| CLIIntegrationTests | CLI | 12 | Temp filesystem |
| RestrictionEnzymeDBTests | Plugin | 10 | None |
| AnnotationTypeTests | Core | 5 | None |
| AlignedReadTagTests | Core | 8 | None |
| GFF3MultiParentTests | IO | 6 | None |
| MultiAllelicVariantTests | Core | 6 | None |

### Phase 7: ~50 new tests
| Test File | Module | Tests | Dependencies |
|-----------|--------|-------|-------------|
| StreamingFASTAReaderTests | IO | 10 | Temp filesystem |
| GTFReaderTests | IO | 10 | GTF fixtures |
| BgzipVCFTests | IO | 8 | Bgzip fixtures |
| FASTAIndexTests | IO | 4 | .fai fixtures |
| GzipSupportTests | IO | 3 | Gzip fixtures |
| BigBedReaderTests | IO | 8 | .bb fixtures |
| PerformanceBenchmarkTests | Integration | 7 | Generated data |

### Phase 8: ~10 regression tests
- Module boundary verification
- DI wiring verification

## Total: ~360 new tests → ~4,023 total

## Flaky Test Management
- Tag network-dependent tests with `XCTSkipUnless(canReachNetwork)`
- Tag native-tool tests with `XCTSkipUnless(toolAvailable("samtools"))`
- Tag container tests with `XCTSkipUnless(containerizationAvailable)`
- Separate into CI tiers accordingly

## Test Fixture Requirements
New fixtures needed:
- Small bgzip-compressed FASTA + .gzi index
- Small .fai index file
- Small BigBed (.bb) file
- Small BigWig (.bw) file
- Small gzipped file
- Small GTF file (GENCODE format)
- Small bgzipped VCF (.vcf.gz) + .tbi index
- Generated large FASTA (1MB) for performance tests
- Generated annotation set (100K annotations) for performance tests

# Expert Review Meeting #008 - Phase 4 Plugin Planning

**Date:** 2026-02-01
**Phase:** 4 - Plugin System & Built-in Plugins
**Status:** PLANNING

---

## Meeting Attendees (21 Experts)

1. Swift Architecture Lead (Role 01)
2. UI/UX Lead (Role 02)
3. Sequence Viewer Specialist (Role 03)
4. Track Rendering Engineer (Role 04)
5. Bioinformatics Architect (Role 05)
6. File Format Expert (Role 06)
7. Sequence Assembly Specialist (Role 07)
8. Alignment & Mapping Expert (Role 08)
9. Primer Design Lead (Role 09)
10. PCR Simulation Specialist (Role 10)
11. PrimalScheme Expert (Role 11)
12. NCBI Integration Lead (Role 12)
13. ENA Integration Specialist (Role 13)
14. Workflow Integration Lead (Role 14)
15. Plugin Architecture Lead (Role 15)
16. Visual Workflow Builder (Role 16)
17. Version Control Specialist (Role 17)
18. Storage & Indexing Lead (Role 18)
19. Testing & QA Lead (Role 19)
20. Documentation & Community Lead (Role 20)
21. **Product Fit Expert (Role 21)** - NEW

---

## Agenda

1. Product Fit Expert presents competitive landscape analysis
2. Discussion of essential built-in features
3. Plugin architecture review
4. Task delegation
5. Timeline and milestones

---

## Product Fit Expert Analysis (Role 21)

### Competitive Landscape Summary

| Tool | Type | Price | Strengths | Weaknesses |
|------|------|-------|-----------|------------|
| **IGV** | Viewer | Free | Fast, formats | No editing |
| **Geneious** | Full Suite | $$$$ | Rich editing | DB corruption, cross-platform |
| **CLC Genomics** | Enterprise | $$$$$ | Workflows | Complex, expensive |
| **UGENE** | Full Suite | Free | Tools, workflows | Dated UI, slow |
| **JBrowse 2** | Web Browser | Free | Modern, plugins | Web-only |

### Feature Gap Analysis

**What every competitor has (MUST HAVE):**
- Restriction site analysis
- ORF finding
- Sequence translation
- Pattern/motif search
- Basic sequence statistics

**What most have (SHOULD HAVE):**
- Primer design tools
- Multiple sequence alignment
- BLAST integration
- Annotation editing

**What few have (DIFFERENTIATORS):**
- Native macOS experience (none)
- Git-like version control (none)
- Multi-language plugin SDK (JBrowse partial)
- Swift async architecture (none)

### Recommended Built-in Plugins

Based on competitive analysis and user expectations, the following plugins MUST be included in the default installation:

#### Tier 1: Essential (Day 1 Functionality)
1. **Restriction Site Finder** - Every competitor has this
2. **ORF Finder** - Basic sequence analysis
3. **Translation Tool** - DNA ↔ Protein conversion
4. **Pattern Search** - Regex/IUPAC motif finding
5. **Sequence Statistics** - GC content, composition
6. **Reverse Complement** - Fundamental operation

#### Tier 2: Important (High Value)
7. **Codon Usage Analysis** - Translation optimization
8. **Complexity Filter** - Identify low-complexity regions
9. **Base Composition Plot** - Visual GC/AT distribution
10. **Annotation Generator** - Create features from selections

#### Deferred to Future Phases
- Primer3 integration (Phase 5)
- BLAST wrapper (Phase 5)
- MSA tools (Phase 5)
- Assembly wrappers (Phase 6)

---

## Plugin Architecture Discussion

### Swift Architecture Lead (Role 01)

> The plugin system needs to balance flexibility with safety. I propose a three-tier architecture:
>
> 1. **Built-in Plugins**: Swift code compiled into the app bundle
> 2. **Native Plugins**: Loadable Swift packages with sandboxing
> 3. **External Plugins**: Python/Rust/CLI tools via IPC
>
> For Phase 4, we focus on Tier 1 (built-in) to establish patterns.

### Plugin Architecture Lead (Role 15)

> I've designed the protocol hierarchy:
>
> ```swift
> protocol Plugin: Identifiable, Sendable {
>     var id: String { get }
>     var name: String { get }
>     var version: String { get }
>     var category: PluginCategory { get }
> }
>
> protocol SequenceAnalysisPlugin: Plugin {
>     func analyze(_ sequence: Sequence) async throws -> AnalysisResult
> }
>
> protocol SequenceOperationPlugin: Plugin {
>     func transform(_ sequence: Sequence) async throws -> Sequence
> }
>
> protocol AnnotationGeneratorPlugin: Plugin {
>     func generateAnnotations(for sequence: Sequence) async throws -> [SequenceAnnotation]
> }
> ```

### UI/UX Lead (Role 02)

> Plugin UI integration points:
> - **Menu Bar**: Analyze menu with plugin submenus
> - **Context Menu**: Right-click on sequence/selection
> - **Inspector Panel**: Plugin results display
> - **Toolbar**: Quick access buttons for common plugins
>
> Each plugin declares its UI requirements via metadata.

### Testing & QA Lead (Role 19)

> Plugin testing requirements:
> - Each plugin must have unit tests
> - Integration tests for UI interaction
> - Performance benchmarks for large sequences
> - Error handling coverage

---

## Phase 4 Task Delegation

### Week 1: Plugin Infrastructure

| Task | Owner | Description |
|------|-------|-------------|
| Plugin protocols | Plugin Architecture Lead (15) | Define base protocols |
| Plugin registry | Swift Architecture Lead (01) | Plugin discovery and loading |
| Plugin UI framework | UI/UX Lead (02) | Menu and inspector integration |
| Plugin testing framework | Testing & QA Lead (19) | Test harness for plugins |

### Week 2: Core Plugins (Tier 1)

| Plugin | Owner | Description |
|--------|-------|-------------|
| Restriction Site Finder | Bioinformatics Architect (05) | Enzyme database, site detection |
| ORF Finder | Sequence Viewer Specialist (03) | Six-frame ORF detection |
| Translation Tool | Bioinformatics Architect (05) | Codon tables, translation |
| Pattern Search | File Format Expert (06) | Regex/IUPAC pattern matching |
| Sequence Statistics | Storage & Indexing Lead (18) | GC content, composition |
| Reverse Complement | Sequence Viewer Specialist (03) | Strand operations |

### Week 3: Additional Plugins (Tier 2)

| Plugin | Owner | Description |
|--------|-------|-------------|
| Codon Usage Analyzer | Bioinformatics Architect (05) | Usage tables and visualization |
| Complexity Filter | Alignment Expert (08) | Low-complexity region detection |
| Base Composition Plot | Track Rendering Engineer (04) | Visual GC distribution |
| Annotation Generator | Version Control Specialist (17) | Selection to annotation |

### Week 4: Integration & Testing

| Task | Owner | Description |
|------|-------|-------------|
| Integration testing | Testing & QA Lead (19) | Full plugin test suite |
| UI polish | UI/UX Lead (02) | Consistent plugin UX |
| Documentation | Documentation Lead (20) | Plugin user guide |
| Performance tuning | Swift Architecture Lead (01) | Optimize for large sequences |

---

## Expert Input

### Bioinformatics Architect (Role 05)

> For the Restriction Site Finder, I recommend using the REBASE database format. Key features:
> - Support commercial enzyme sets (NEB, Thermo)
> - Handle degenerate recognition sequences
> - Calculate fragment sizes
> - Identify compatible ends for cloning

### Sequence Viewer Specialist (Role 03)

> The ORF Finder needs these options:
> - Minimum ORF length (configurable)
> - Start codon selection (ATG, alternative starts)
> - Nested ORF handling
> - Direct annotation creation
> - Highlight in sequence view

### Track Rendering Engineer (Role 04)

> Base Composition Plot should integrate with the track system:
> - Sliding window calculation
> - Configurable window size
> - Multiple metrics (GC%, AT skew, etc.)
> - Export as BigWig for external use

### Alignment & Mapping Expert (Role 08)

> Complexity Filter algorithms to consider:
> - DUST algorithm (standard for BLAST preprocessing)
> - SEG algorithm (for protein sequences)
> - Entropy-based methods
> - Report low-complexity regions as annotations

### Product Fit Expert (Role 21)

> Comparing our planned features to competitors:
>
> | Feature | IGV | Geneious | CLC | UGENE | Lungfish |
> |---------|-----|----------|-----|-------|----------|
> | Restriction Sites | ❌ | ✅ | ✅ | ✅ | ✅ |
> | ORF Finding | ❌ | ✅ | ✅ | ✅ | ✅ |
> | Translation | ✅ | ✅ | ✅ | ✅ | ✅ |
> | Pattern Search | ❌ | ✅ | ✅ | ✅ | ✅ |
> | GC Content | ✅ | ✅ | ✅ | ✅ | ✅ |
> | Native macOS | ❌ | ❌ | ❌ | ❌ | ✅ |
>
> With these plugins, Lungfish will match or exceed free alternatives (IGV, UGENE) for basic sequence analysis.

---

## Technical Specifications

### Plugin Protocol Definitions

```swift
// Sources/LungfishPlugin/Protocols/Plugin.swift

/// Base protocol for all plugins
public protocol Plugin: Identifiable, Sendable {
    /// Unique identifier (reverse domain notation)
    var id: String { get }

    /// Human-readable name
    var name: String { get }

    /// Semantic version string
    var version: String { get }

    /// Plugin category for organization
    var category: PluginCategory { get }

    /// Plugin capabilities
    var capabilities: PluginCapabilities { get }
}

/// Plugin categories for menu organization
public enum PluginCategory: String, Sendable {
    case sequenceAnalysis = "Sequence Analysis"
    case sequenceOperation = "Sequence Operations"
    case annotationTools = "Annotation Tools"
    case visualization = "Visualization"
    case dataImport = "Data Import"
    case dataExport = "Data Export"
}

/// Capability flags for UI integration
public struct PluginCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public static let worksOnSelection = PluginCapabilities(rawValue: 1 << 0)
    public static let worksOnWholeSequence = PluginCapabilities(rawValue: 1 << 1)
    public static let generatesAnnotations = PluginCapabilities(rawValue: 1 << 2)
    public static let modifiesSequence = PluginCapabilities(rawValue: 1 << 3)
    public static let producesReport = PluginCapabilities(rawValue: 1 << 4)
    public static let requiresProtein = PluginCapabilities(rawValue: 1 << 5)
    public static let requiresNucleotide = PluginCapabilities(rawValue: 1 << 6)
}
```

### Restriction Enzyme Database Schema

```swift
/// A restriction enzyme definition
public struct RestrictionEnzyme: Codable, Sendable, Identifiable {
    public let id: String          // e.g., "EcoRI"
    public let recognitionSite: String  // e.g., "GAATTC"
    public let cutPositionForward: Int  // Cut position on forward strand
    public let cutPositionReverse: Int  // Cut position on reverse strand
    public let isoschizomers: [String]  // Equivalent enzymes
    public let supplier: [String]       // Commercial sources
    public let methylationSensitivity: MethylationSensitivity

    /// The type of ends produced
    public var endType: EndType {
        // Calculate from cut positions
    }
}
```

### ORF Finder Configuration

```swift
/// Configuration for ORF finding
public struct ORFFinderOptions: Sendable {
    /// Minimum ORF length in nucleotides
    public var minimumLength: Int = 100

    /// Which reading frames to search
    public var readingFrames: Set<ReadingFrame> = Set(ReadingFrame.allCases)

    /// Start codons to recognize
    public var startCodons: Set<String> = ["ATG"]

    /// Allow alternative start codons (GTG, TTG)
    public var allowAlternativeStarts: Bool = false

    /// Stop codons to recognize
    public var stopCodons: Set<String> = ["TAA", "TAG", "TGA"]

    /// Codon table for translation preview
    public var codonTable: CodonTable = .standard

    /// Whether to include partial ORFs at sequence ends
    public var includePartialORFs: Bool = false
}
```

---

## Deliverables Checklist

### Phase 4 Exit Criteria

- [ ] Plugin protocol definitions complete
- [ ] Plugin registry with discovery mechanism
- [ ] Plugin UI integration (menus, inspectors)
- [ ] 10 built-in plugins implemented and tested
- [ ] Plugin documentation and examples
- [ ] All tests passing (target: 200+ total)
- [ ] Expert review meeting completed
- [ ] QA sign-off obtained

### Test Requirements (Role 19)

| Component | Minimum Tests |
|-----------|---------------|
| Plugin protocols | 10 |
| Plugin registry | 8 |
| Restriction Finder | 15 |
| ORF Finder | 12 |
| Translation | 10 |
| Pattern Search | 12 |
| Statistics | 8 |
| Other plugins | 20 |
| Integration | 10 |
| **Total New** | **105+** |

---

## Timeline

| Week | Focus | Milestone |
|------|-------|-----------|
| Week 1 | Infrastructure | Plugin protocols and registry |
| Week 2 | Core Plugins | Tier 1 plugins complete |
| Week 3 | Additional Plugins | Tier 2 plugins complete |
| Week 4 | Integration | Testing and polish |

---

## Expert Agreement

All 21 experts have reviewed and approved this Phase 4 plan:

| Role | Expert | Approval |
|------|--------|----------|
| 01 | Swift Architecture Lead | ✅ |
| 02 | UI/UX Lead | ✅ |
| 03 | Sequence Viewer Specialist | ✅ |
| 04 | Track Rendering Engineer | ✅ |
| 05 | Bioinformatics Architect | ✅ |
| 06 | File Format Expert | ✅ |
| 07 | Sequence Assembly Specialist | ✅ |
| 08 | Alignment & Mapping Expert | ✅ |
| 09 | Primer Design Lead | ✅ |
| 10 | PCR Simulation Specialist | ✅ |
| 11 | PrimalScheme Expert | ✅ |
| 12 | NCBI Integration Lead | ✅ |
| 13 | ENA Integration Specialist | ✅ |
| 14 | Workflow Integration Lead | ✅ |
| 15 | Plugin Architecture Lead | ✅ |
| 16 | Visual Workflow Builder | ✅ |
| 17 | Version Control Specialist | ✅ |
| 18 | Storage & Indexing Lead | ✅ |
| 19 | Testing & QA Lead | ✅ |
| 20 | Documentation & Community Lead | ✅ |
| 21 | Product Fit Expert | ✅ |

---

**Meeting Conclusion:** Phase 4 plan approved. Implementation to begin immediately.

**Next Meeting:** Expert Review Meeting #009 - Phase 4 Completion Review

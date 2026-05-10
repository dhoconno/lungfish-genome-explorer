# Role: Swift Architecture Lead

## Responsibilities

### Primary Duties
- Design and maintain the overall Swift application architecture
- Define module boundaries and dependency relationships
- Establish coding standards and patterns for the team
- Review architectural decisions from all other roles
- Ensure performance and memory efficiency across the codebase

### Key Deliverables
- Swift Package structure with clearly defined modules
- Architecture decision records (ADRs) for major choices
- Dependency injection and protocol-oriented design patterns
- Memory management guidelines for genomic data
- Build system configuration (Xcode project, SPM)

### Decision Authority
- Final say on module organization and dependencies
- Technology choices for cross-cutting concerns
- Performance optimization strategies
- Swift version and language feature adoption

---

## Technical Scope

### Technologies/Frameworks Owned
- Swift 5.9+ language features (macros, parameter packs)
- Swift Package Manager configuration
- Xcode project setup and schemes
- Swift Concurrency (async/await, actors, Sendable)
- Memory management (ARC, copy-on-write, mmap)

### Module Ownership
```
LungfishGenomeBrowser/
├── Package.swift                    # PRIMARY OWNER
├── LungfishCore/                    # Co-owner with Bioinformatics Architect
├── LungfishIO/                      # Oversight
├── LungfishUI/                      # Oversight
├── LungfishPlugin/                  # Co-owner with Plugin Architect
├── LungfishWorkflow/                # Oversight
└── LungfishApp/                     # Co-owner with UI/UX Lead
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| UI/UX Lead | SwiftUI/AppKit integration patterns |
| Plugin Architect | Plugin loading and sandboxing |
| File Format Expert | C interop for htslib |
| Storage Lead | Data persistence patterns |
| Testing Lead | Test architecture and mocking |

### External Dependencies to Evaluate
- htslib (C library for BAM/CRAM/VCF)
- PythonKit (for Python plugin support)
- Zstandard Swift bindings
- Metal shaders for rendering

---

## Key Decisions to Make

### Architectural Choices

1. **Module Granularity**
   - How fine-grained should modules be?
   - Trade-off: Build time vs. encapsulation
   - Recommendation: 6-8 main modules, internal sub-modules as needed

2. **Dependency Injection Strategy**
   - Protocol-based DI vs. Environment objects vs. Service locator
   - Recommendation: Protocol-based with factory patterns for testability

3. **Concurrency Model**
   - Where to use actors vs. classes with locks
   - Main actor isolation for UI code
   - Recommendation: Actors for all shared mutable state, `@MainActor` for UI

4. **Error Handling**
   - Typed throws (Swift 6) vs. untyped
   - Error recovery and user feedback
   - Recommendation: Define `LungfishError` enum with localized descriptions

### Algorithm Selections
- Memory-efficient sequence storage (2-bit encoding vs. String)
- Index data structures (B-tree vs. R-tree for spatial queries)
- Caching strategies (LRU vs. LFU, memory limits)

### Trade-off Considerations
- **Build time vs. modularity**: More modules = slower builds but better encapsulation
- **Type safety vs. flexibility**: Strict typing vs. Any for plugin data
- **Performance vs. readability**: Unsafe pointers vs. safe abstractions

---

## Success Criteria

### Performance Targets
- App launch to interactive: < 2 seconds
- Open 1GB FASTA file: < 1 second (memory-mapped)
- Render viewport at max zoom: < 16ms (60 fps)
- Memory overhead: < 2x file size for loaded data

### Quality Metrics
- Zero retain cycles in core modules
- 100% Sendable compliance for shared types
- All public APIs documented with DocC
- < 5% code duplication across modules

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Package.swift with all modules | Week 1 |
| 1 | Core protocol definitions | Week 2 |
| 2 | htslib Swift bindings | Week 4 |
| 3 | Actor-based document management | Week 6 |
| 4 | Plugin loading infrastructure | Week 8 |

---

## Reference Materials

### IGV Code References
- `igv/src/main/java/org/igv/` - Overall structure inspiration
- `igv/src/main/java/org/igv/util/` - Utility patterns
- `igv/build.gradle` - Dependency management

### Geneious References
- `geneious-devkit/api-javadoc/` - API design patterns
- Plugin architecture documentation

### External Documentation
- [Swift Package Manager](https://swift.org/package-manager/)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)
- [Memory Management in Swift](https://developer.apple.com/documentation/swift/manual-memory-management)

### Research Papers
- "Efficient Sequence Compression" - 2-bit encoding strategies
- "Memory-Mapped File I/O" - mmap patterns for large files

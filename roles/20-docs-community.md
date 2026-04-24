# Role: Documentation & Community Lead

## Responsibilities

### Primary Duties
- Write comprehensive API documentation
- Create user guides and tutorials
- Develop plugin development documentation
- Manage open source community
- Design onboarding experience

### Key Deliverables
- DocC API documentation
- User manual with screenshots
- Plugin SDK documentation
- Contributing guidelines
- Community forums and support

### Decision Authority
- Documentation structure
- Community guidelines
- Release communication
- Tutorial content priorities

---

## Technical Scope

### Technologies/Frameworks Owned
- DocC documentation framework
- Markdown authoring
- Tutorial creation
- Community platforms

### Component Ownership
```
Documentation/
├── API/
│   ├── LungfishCore.docc/            # PRIMARY OWNER
│   │   ├── LungfishCore.md
│   │   ├── Tutorials/
│   │   └── Resources/
│   ├── LungfishIO.docc/              # PRIMARY OWNER
│   ├── LungfishUI.docc/              # PRIMARY OWNER
│   └── LungfishPlugin.docc/          # PRIMARY OWNER
├── UserGuide/
│   ├── GettingStarted.md             # PRIMARY OWNER
│   ├── ImportingData.md              # PRIMARY OWNER
│   ├── ViewingSequences.md           # PRIMARY OWNER
│   ├── Annotations.md                # PRIMARY OWNER
│   ├── Workflows.md                  # PRIMARY OWNER
│   └── Troubleshooting.md            # PRIMARY OWNER
├── PluginDev/
│   ├── Overview.md                   # PRIMARY OWNER
│   ├── PythonPlugins.md              # PRIMARY OWNER
│   ├── RustPlugins.md                # PRIMARY OWNER
│   ├── SwiftPlugins.md               # PRIMARY OWNER
│   └── CLIWrappers.md                # PRIMARY OWNER
└── Community/
    ├── CONTRIBUTING.md               # PRIMARY OWNER
    ├── CODE_OF_CONDUCT.md            # PRIMARY OWNER
    ├── SECURITY.md                   # PRIMARY OWNER
    └── CHANGELOG.md                  # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| All roles | API documentation |
| Plugin Architect | SDK documentation |
| Testing Lead | Example code validation |
| UI/UX Lead | Screenshot assets |

---

## Key Decisions to Make

### Architectural Choices

1. **Documentation Platform**
   - DocC vs. Jazzy vs. external site
   - Recommendation: DocC for API, GitHub Pages for guides

2. **Community Platform**
   - GitHub Discussions vs. Discord vs. Discourse
   - Recommendation: GitHub Discussions primary

3. **Tutorial Format**
   - Written vs. video vs. interactive
   - Recommendation: Written with video supplements

4. **Versioning Strategy**
   - Documentation per release vs. rolling
   - Recommendation: Versioned docs with latest branch

### Documentation Standards
```markdown
## Documentation Guidelines

### API Documentation
- Every public API must have documentation
- Include at least one code example
- Document all parameters and return values
- Note any thrown errors
- Link to related APIs

### User Guide
- Task-oriented structure (how to...)
- Screenshots for UI operations
- Step-by-step instructions
- Troubleshooting sections

### Code Examples
- Complete, runnable examples
- Error handling included
- Tested in CI
```

---

## Success Criteria

### Coverage Targets
- Public API documentation: 100%
- User guide completeness: All features covered
- Plugin SDK: Complete tutorials for all languages

### Quality Metrics
- Documentation freshness: Updated within 1 week of changes
- Example code: All compiles and runs
- User satisfaction: > 4.0 rating

### Community Metrics
- Issue response time: < 24 hours
- PR review time: < 48 hours
- Community growth: Measured monthly

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Documentation infrastructure | Week 2 |
| 2 | Core API docs | Week 5 |
| 3 | User guide draft | Week 8 |
| 4 | Plugin SDK docs | Week 10 |
| 5 | Community setup | Week 12 |
| 6 | Tutorial videos | Week 15 |

---

## Reference Materials

### Apple Documentation
- [DocC Documentation](https://developer.apple.com/documentation/docc)
- [Swift Documentation Guidelines](https://swift.org/documentation/api-design-guidelines/)

### Open Source Best Practices
- [Open Source Guides](https://opensource.guide/)
- [GitHub Community Guidelines](https://docs.github.com/en/site-policy/github-terms/github-community-guidelines)

---

## Technical Specifications

### DocC Structure
```swift
// LungfishCore.docc/LungfishCore.md

# ``LungfishCore``

Core data models and services for the Lungfish Genome Explorer.

## Overview

LungfishCore provides the foundational types for working with genomic data,
including sequences, annotations, and version history.

## Topics

### Essentials

- <doc:GettingStarted>
- ``Sequence``
- ``SequenceAnnotation``

### Working with Sequences

- ``Sequence``
- ``SequenceAlphabet``
- ``SequenceView``
- ``CodonTable``

### Annotations

- ``SequenceAnnotation``
- ``AnnotationType``
- ``AnnotationInterval``
- ``Strand``

### Version Control

- ``VersionHistory``
- ``SequenceDiff``
- ``Commit``
- ``Branch``

### Services

- ``NCBIService``
- ``ENAService``
- ``ProjectManager``
```

### API Documentation Example
```swift
/// A genomic sequence with efficient storage and manipulation.
///
/// `Sequence` provides a memory-efficient representation of DNA, RNA, or protein
/// sequences using 2-bit encoding for nucleotides. It supports common operations
/// like complement, reverse complement, and translation.
///
/// ## Creating Sequences
///
/// Create a sequence from a string of bases:
///
/// ```swift
/// let dna = Sequence(name: "my_gene", data: Data("ATCGATCG".utf8))
/// print(dna.length)  // 8
/// print(dna.alphabet)  // .dna
/// ```
///
/// ## Transforming Sequences
///
/// Get the complement or reverse complement:
///
/// ```swift
/// let complement = dna.complement()
/// let reverseComplement = dna.reverseComplement()
/// ```
///
/// Translate to protein:
///
/// ```swift
/// let protein = dna.translate(frame: .frame1, codonTable: .standard)
/// ```
///
/// ## Subsequences
///
/// Access portions of the sequence efficiently:
///
/// ```swift
/// let subsequence = dna[100..<200]  // Returns a SequenceView
/// ```
///
/// - Note: Subsequences are views into the original sequence and don't copy data.
///
/// ## Topics
///
/// ### Creating Sequences
///
/// - ``init(name:data:alphabet:)``
/// - ``init(name:data:)``
///
/// ### Properties
///
/// - ``name``
/// - ``length``
/// - ``alphabet``
/// - ``sequenceString``
///
/// ### Transformations
///
/// - ``complement()``
/// - ``reverseComplement()``
/// - ``translate(frame:codonTable:)``
///
/// ### Subsequences
///
/// - ``subscript(_:)``
public struct Sequence: Identifiable, Hashable, Sendable {
    /// The unique identifier for this sequence.
    public let id: UUID

    /// The name or identifier of the sequence.
    ///
    /// This typically corresponds to the FASTA header or GenBank LOCUS name.
    public let name: String

    /// The alphabet (DNA, RNA, or protein) of this sequence.
    public let alphabet: SequenceAlphabet

    /// The number of bases or residues in the sequence.
    public var length: Int { storage.count }

    /// Creates a new sequence with the specified name and data.
    ///
    /// - Parameters:
    ///   - name: The name or identifier for the sequence.
    ///   - data: The raw sequence data as UTF-8 encoded bytes.
    ///   - alphabet: The sequence alphabet. If `nil`, it will be auto-detected.
    ///
    /// - Returns: A new sequence instance.
    public init(name: String, data: Data, alphabet: SequenceAlphabet? = nil) {
        self.id = UUID()
        self.name = name
        self.alphabet = alphabet ?? Self.detectAlphabet(data)
        self.storage = SequenceStorage(data: data, alphabet: self.alphabet)
    }

    /// Returns the complement of this sequence.
    ///
    /// For DNA, this returns A↔T and G↔C substitutions.
    /// For RNA, this returns A↔U and G↔C substitutions.
    ///
    /// - Returns: A new sequence with complementary bases.
    /// - Precondition: The sequence must be DNA or RNA.
    ///
    /// ```swift
    /// let dna = Sequence(name: "test", data: Data("ATCG".utf8))
    /// let comp = dna.complement()
    /// print(comp.sequenceString)  // "TAGC"
    /// ```
    public func complement() -> Sequence {
        precondition(alphabet == .dna || alphabet == .rna, "Can only complement nucleotide sequences")
        // Implementation
    }
}
```

### User Guide Structure
```markdown
# Getting Started with Lungfish

Welcome to Lungfish, the next-generation genome browser for macOS.

## System Requirements

- macOS 14 Sonoma or later
- Apple Silicon Mac (M1 or newer)
- 8 GB RAM minimum (16 GB recommended)
- SSD storage

## Installation

1. Download Lungfish from [releases page](https://github.com/...)
2. Drag Lungfish.app to your Applications folder
3. Open Lungfish from Applications or Spotlight

## Creating Your First Project

### 1. Create a New Project

1. Choose **File → New Project** (⌘N)
2. Enter a project name
3. Choose a location to save the project
4. Click **Create**

![New Project Dialog](images/new-project.png)

### 2. Import Sequences

1. Choose **File → Import** (⌘I)
2. Select your FASTA, GenBank, or other sequence files
3. Click **Import**

Lungfish supports these formats:
- FASTA (.fa, .fasta, .fna)
- GenBank (.gb, .gbk)
- FASTQ (.fq, .fastq)
- And more...

### 3. View Your Sequences

After import, your sequences appear in the document list. Double-click
a sequence to open it in the sequence viewer.

## Next Steps

- [Viewing Sequences](ViewingSequences.md) - Learn about the sequence viewer
- [Adding Annotations](Annotations.md) - Annotate your sequences
- [Running Workflows](Workflows.md) - Automate your analysis
```

### Plugin SDK Documentation
```markdown
# Creating Python Plugins

This guide explains how to create plugins for Lungfish using Python.

## Prerequisites

- Python 3.11 or later
- Lungfish Plugin SDK: `pip install lungfish-sdk`

## Quick Start

### 1. Create Plugin Directory

```bash
mkdir my-plugin
cd my-plugin
```

### 2. Create Plugin File

Create `my_plugin.py`:

```python
from lungfish import Plugin, SequenceOperation

class ReverseComplementPlugin(Plugin):
    """A simple plugin that computes reverse complement."""

    name = "Reverse Complement"
    version = "1.0.0"
    author = "Your Name"

    @SequenceOperation(
        input_types=["dna", "rna"],
        output_type="same",
        description="Compute the reverse complement of a sequence"
    )
    def reverse_complement(self, sequence: str) -> str:
        """Return the reverse complement."""
        complement = {'A': 'T', 'T': 'A', 'G': 'C', 'C': 'G',
                      'a': 't', 't': 'a', 'g': 'c', 'c': 'g'}
        return ''.join(complement.get(base, base) for base in reversed(sequence))
```

### 3. Install the Plugin

Copy `my_plugin.py` to:
```
~/Library/Application Support/Lungfish/Plugins/
```

### 4. Use in Lungfish

1. Restart Lungfish
2. Select a sequence
3. Choose **Operations → Reverse Complement**

## Plugin Types

### Sequence Operations

Transform sequences in various ways:

```python
@SequenceOperation(
    input_types=["dna"],
    output_type="protein",
    parameters=[
        Parameter("frame", int, default=1, description="Reading frame (1-3)")
    ]
)
def translate(self, sequence: str, frame: int = 1) -> str:
    # Implementation
    pass
```

### Annotation Generators

Create annotations on sequences:

```python
@AnnotationGenerator(
    annotation_type="orf",
    target_types=["dna"]
)
def find_orfs(self, sequence: str, min_length: int = 100) -> list:
    # Return list of (start, end, strand, name) tuples
    pass
```

### Database Plugins

Add new data sources:

```python
@DatabasePlugin(
    name="Custom Database"
)
class MyDatabase(Plugin):
    def search(self, query: str) -> list:
        # Return search results
        pass

    def fetch(self, accession: str) -> dict:
        # Return sequence data
        pass
```

## Best Practices

1. **Error Handling**: Always handle errors gracefully
2. **Progress Reporting**: Use progress callbacks for long operations
3. **Documentation**: Include docstrings for all public methods
4. **Testing**: Include unit tests with your plugin

## API Reference

See the [Python SDK Reference](python-sdk-reference.md) for complete API documentation.
```

### Community Guidelines
```markdown
# Contributing to Lungfish

Thank you for your interest in contributing to Lungfish! This document
provides guidelines for contributing to the project.

## Code of Conduct

We are committed to providing a welcoming and inclusive environment.
Please read our [Code of Conduct](CODE_OF_CONDUCT.md).

## How to Contribute

### Reporting Bugs

1. Check existing issues to avoid duplicates
2. Use the bug report template
3. Include:
   - macOS version
   - Lungfish version
   - Steps to reproduce
   - Expected vs actual behavior
   - Sample files if applicable

### Suggesting Features

1. Check existing feature requests
2. Use the feature request template
3. Explain the use case clearly
4. Consider implementation complexity

### Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Write tests for new functionality
4. Ensure all tests pass: `swift test`
5. Follow the code style guide
6. Submit a pull request

## Development Setup

### Requirements

- Xcode 15.2 or later
- Swift 5.9
- macOS 14 Sonoma

### Building

```bash
git clone https://github.com/org/lungfish.git
cd lungfish
xcodebuild build -scheme Lungfish
```

### Running Tests

```bash
xcodebuild test -scheme Lungfish
```

## Code Style

- Follow Swift API Design Guidelines
- Use SwiftLint (configuration provided)
- Document all public APIs
- Write descriptive commit messages

## License

By contributing, you agree that your contributions will be licensed
under the MIT License.
```

### Release Notes Template
```markdown
# Lungfish 1.2.0

Released: January 15, 2025

## Highlights

- **New**: PrimalScheme multiplex primer design
- **Improved**: 50% faster BAM loading
- **Fixed**: Crash when opening large GenBank files

## New Features

### PrimalScheme Integration

Design tiled amplicon panels for sequencing workflows:
- Automatic pool optimization
- Visual coverage display
- ARTIC-compatible export

### Nextflow Support

Run Nextflow workflows directly from Lungfish:
- nf-core pipeline browser
- Automatic parameter UI
- Progress monitoring

## Improvements

- BAM loading is now 50% faster
- Reduced memory usage for large sequences
- Improved sequence viewer performance

## Bug Fixes

- Fixed crash when opening GenBank files > 100 MB
- Fixed annotation colors not saving
- Fixed undo not working for batch operations

## Breaking Changes

- Plugin API v2 required (see migration guide)

## Upgrade Notes

Projects created with Lungfish 1.1 will be automatically migrated.
```

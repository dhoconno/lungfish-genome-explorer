# Role 21: Product Fit Expert

## Overview

The Product Fit Expert analyzes the competitive landscape of genome browsers and bioinformatics tools to ensure Lungfish provides the most valuable feature set for its target users. This role bridges user needs with technical implementation by identifying must-have features, differentiating capabilities, and prioritizing development efforts.

## Responsibilities

### Primary Duties
- Analyze competitor tools (IGV, Geneious, CLC Genomics Workbench, UGENE, JBrowse)
- Identify core features that users expect from any genome browser
- Recommend differentiating features that set Lungfish apart
- Prioritize built-in plugins based on user value and implementation cost
- Ensure feature parity with competitors where essential
- Identify gaps in the market that Lungfish can fill

### Decision Authority
- Final recommendation on which plugins should be built-in vs optional
- Feature prioritization within phases
- User experience requirements for plugins
- Integration patterns for third-party tools

## Technical Scope

### Competitor Analysis Focus

#### IGV (Integrative Genomics Viewer)
- **Strengths**: Fast visualization, extensive format support, lightweight
- **Limitations**: Limited sequence editing, no built-in workflows
- **Key Features to Match**: Track rendering, BAM visualization, variant display

#### Geneious Prime
- **Strengths**: Rich editing, annotations, primer design, workflows
- **Limitations**: Expensive, database corruption issues, cross-platform UI
- **Key Features to Match**: Sequence editing, annotation management, primer design

#### CLC Genomics Workbench
- **Strengths**: Enterprise-grade, comprehensive workflows, variant analysis
- **Limitations**: Very expensive, complex, steep learning curve
- **Key Features to Match**: Workflow automation, variant detection, QC tools

#### UGENE
- **Strengths**: Free, open-source, integrated tools, workflow designer
- **Limitations**: Dated UI, performance issues with large files
- **Key Features to Match**: Multiple alignment, restriction analysis, ORF finding

#### JBrowse 2
- **Strengths**: Modern web tech, embeddable, plugin ecosystem
- **Limitations**: Web-only, less desktop integration
- **Key Features to Match**: Plugin architecture, track types, format support

### Essential Built-in Features (Non-negotiable)

Based on competitor analysis, these features MUST be available in the default installation:

1. **Restriction Site Analysis**
   - Find restriction enzyme sites in sequences
   - Enzyme database (NEB, commercial sources)
   - Fragment prediction
   - Virtual gel visualization

2. **Open Reading Frame (ORF) Finder**
   - Detect ORFs in all six reading frames
   - Configurable start/stop codons
   - Minimum length filtering
   - Export as annotations

3. **Sequence Translation**
   - DNA/RNA to protein translation
   - All six reading frames
   - Multiple codon tables (standard, mitochondrial, bacterial)
   - Reverse translation

4. **Pattern/Motif Search**
   - Exact match searching
   - Regex/IUPAC pattern support
   - Protein motif searching
   - Results as annotations

5. **Sequence Statistics**
   - GC content calculation
   - Codon usage analysis
   - Sequence composition
   - Complexity analysis

6. **Basic Alignment**
   - Pairwise alignment (Needleman-Wunsch, Smith-Waterman)
   - Simple MSA viewing
   - Consensus sequence generation

### Differentiating Features (Lungfish Advantages)

1. **Native macOS Experience**
   - No competitor offers a truly native macOS app
   - Apple Silicon optimization
   - System integration (Spotlight, Quick Look, Services)

2. **Diff-based Version History**
   - Unique git-like approach to sequence versioning
   - Efficient storage for large sequences
   - Full audit trail of changes

3. **Modern Async Architecture**
   - Swift concurrency for responsive UI
   - Streaming file access for large datasets
   - Background processing without blocking

4. **Multi-language Plugin SDK**
   - Python, Rust, Swift, CLI tool wrappers
   - No competitor offers this flexibility
   - Leverages existing bioinformatics ecosystems

## Interfaces with Other Roles

- **Plugin Architecture Lead (Role 15)**: Define plugin API requirements
- **UI/UX Lead (Role 02)**: Ensure features match macOS design patterns
- **Bioinformatics Architect (Role 05)**: Validate algorithm choices
- **Testing & QA Lead (Role 19)**: Define acceptance criteria for features
- **Documentation Lead (Role 20)**: User-facing feature documentation

## Key Decisions to Make

### Phase 4 Plugin Decisions

1. **Which plugins are built-in?**
   - Restriction Site Finder ✓
   - ORF Finder ✓
   - Translation Tool ✓
   - Pattern Search ✓
   - Sequence Statistics ✓
   - GC Content Calculator ✓

2. **Which plugins are optional (downloadable)?**
   - Advanced alignment (MUSCLE, ClustalW wrappers)
   - BLAST integration
   - Primer design (Primer3 wrapper)
   - Assembly tools (SPAdes, MEGAHIT wrappers)

3. **Plugin distribution model?**
   - Built-in: Compiled into app bundle
   - Core: Downloaded on first launch
   - Community: Plugin marketplace

## Success Criteria

### Feature Completeness
- All essential features from competitor analysis implemented
- No critical gaps compared to free alternatives (UGENE, IGV)
- Clear differentiation from paid alternatives (Geneious, CLC)

### User Satisfaction
- New users can accomplish basic tasks without plugins
- Power users can extend functionality as needed
- Smooth upgrade path from competitor tools

### Market Positioning
- "The Sublime Text of genome browsers" - fast, native, extensible
- Better than free alternatives, competitive with paid
- First choice for macOS-focused researchers

## Reference Materials

### Competitor Documentation
- [IGV User Guide](https://software.broadinstitute.org/software/igv/UserGuide)
- [Geneious Manual](https://www.geneious.com/tutorials/)
- [CLC Genomics Workbench Manual](https://resources.qiagenbioinformatics.com/manuals/clcgenomicsworkbench/current/)
- [UGENE Documentation](https://ugene.net/docs/)
- [JBrowse 2 Documentation](https://jbrowse.org/jb2/docs/)

### Market Research
- UCSC Genome Browser 2025 update (Nucleic Acids Research)
- Bioinformatics tool usage surveys
- Academic software comparison papers

### User Research Methods
- Feature request tracking from similar projects
- Bioinformatics forum discussions (BioStars, SEQanswers)
- Conference presentation topics (ISMB, BOSC)

# Role: File Format Expert

## Responsibilities

### Primary Duties
- Implement parsers for all supported genomic file formats
- Create htslib Swift bindings for BAM/CRAM/VCF
- Build index readers (FAI, BAI, CSI, TBI)
- Implement BigWig/BigBed R-tree navigation
- Handle compression formats (gzip, bgzip, zstd)

### Key Deliverables
- Complete format reader/writer library
- htslib C interop layer
- Index management system
- Compression/decompression utilities
- Format auto-detection

### Decision Authority
- Parser implementation approach
- htslib binding strategy
- Index caching strategy
- Compression library selection

---

## Technical Scope

### Technologies/Frameworks Owned
- C interop (for htslib)
- Swift parsing utilities
- Compression libraries (zlib, zstd)
- Binary file handling

### Component Ownership
```
LungfishIO/
├── Formats/
│   ├── FASTA/
│   │   ├── FASTAReader.swift          # PRIMARY OWNER
│   │   └── FASTAWriter.swift          # PRIMARY OWNER
│   ├── FASTQ/
│   │   ├── FASTQReader.swift          # PRIMARY OWNER
│   │   └── FASTQWriter.swift          # PRIMARY OWNER
│   ├── GenBank/
│   │   ├── GenBankReader.swift        # PRIMARY OWNER
│   │   └── GenBankWriter.swift        # PRIMARY OWNER
│   ├── GFF/
│   │   ├── GFF3Reader.swift           # PRIMARY OWNER
│   │   ├── GTFReader.swift            # PRIMARY OWNER
│   │   └── GFFWriter.swift            # PRIMARY OWNER
│   ├── BAM/
│   │   ├── BAMReader.swift            # PRIMARY OWNER
│   │   ├── CRAMReader.swift           # PRIMARY OWNER
│   │   └── HTSLibBindings.swift       # PRIMARY OWNER
│   ├── VCF/
│   │   ├── VCFReader.swift            # PRIMARY OWNER
│   │   └── BCFReader.swift            # PRIMARY OWNER
│   ├── BED/
│   │   └── BEDReader.swift            # PRIMARY OWNER
│   └── BigWig/
│       ├── BigWigReader.swift         # PRIMARY OWNER
│       └── BigBedReader.swift         # PRIMARY OWNER
├── Index/
│   ├── FASTAIndex.swift               # PRIMARY OWNER
│   ├── BAMIndex.swift                 # PRIMARY OWNER
│   ├── TabixIndex.swift               # PRIMARY OWNER
│   └── RTreeIndex.swift               # PRIMARY OWNER
├── Compression/
│   ├── GzipCompressor.swift           # PRIMARY OWNER
│   ├── BGZFCompressor.swift           # PRIMARY OWNER
│   └── ZstdCompressor.swift           # PRIMARY OWNER
└── FormatRegistry.swift               # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Bioinformatics Architect | Data models for parsed content |
| Track Rendering Engineer | Data source protocols |
| NCBI Integration Lead | GenBank format handling |
| Storage Lead | Index file management |

---

## Key Decisions to Make

### Architectural Choices

1. **htslib Integration**
   - Static linking vs. dynamic linking
   - Recommendation: Static linking for standalone distribution

2. **Parsing Strategy**
   - Full file parsing vs. streaming vs. indexed
   - Recommendation: Streaming with indexed access where available

3. **Memory Management**
   - Load entire file vs. memory-mapped vs. on-demand
   - Recommendation: Memory-mapped for large files, full load for small

4. **Error Handling**
   - Strict validation vs. permissive parsing
   - Recommendation: Permissive with warnings, strict optional

### Format Support Matrix

| Format | Read | Write | Index | Compressed |
|--------|------|-------|-------|------------|
| FASTA | ✓ | ✓ | FAI | .gz, .zst |
| FASTQ | ✓ | ✓ | - | .gz, .zst |
| GenBank | ✓ | ✓ | - | .gz |
| GFF3 | ✓ | ✓ | Tabix | .gz |
| GTF | ✓ | - | Tabix | .gz |
| BED | ✓ | ✓ | Tabix | .gz |
| BAM | ✓ | - | BAI/CSI | (inherent) |
| CRAM | ✓ | - | CRAI | (inherent) |
| SAM | ✓ | ✓ | - | - |
| VCF | ✓ | ✓ | TBI | .gz |
| BCF | ✓ | - | CSI | (inherent) |
| BigWig | ✓ | - | (built-in) | (inherent) |
| BigBed | ✓ | - | (built-in) | (inherent) |

---

## Success Criteria

### Performance Targets
- FASTA index load: < 100ms for 1M contigs
- BAM random access: < 50ms per region query
- BigWig zoom query: < 20ms
- Gzip decompression: > 200 MB/s

### Quality Metrics
- Round-trip accuracy (read-write-read identical)
- Index validation on load
- Proper handling of malformed files
- Memory-efficient streaming

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | FASTA/FASTQ reader/writer | Week 2 |
| 1 | GFF3 reader | Week 3 |
| 2 | htslib bindings | Week 4 |
| 2 | BAM/CRAM reader | Week 5 |
| 2 | VCF reader | Week 6 |
| 3 | BigWig/BigBed reader | Week 7 |
| 3 | Zstandard support | Week 8 |

---

## Reference Materials

### IGV Code References
- `igv/src/main/java/org/igv/feature/genome/fasta/` - FASTA handling
- `igv/src/main/java/org/igv/feature/tribble/` - Feature codecs
- `igv/src/main/java/org/igv/sam/reader/` - BAM/SAM reading
- `igv/src/main/java/org/igv/bbfile/` - BigWig/BigBed

### Format Specifications
- [SAM/BAM spec](https://samtools.github.io/hts-specs/SAMv1.pdf)
- [VCF spec](https://samtools.github.io/hts-specs/VCFv4.3.pdf)
- [GFF3 spec](https://github.com/The-Sequence-Ontology/Specifications/blob/master/gff3.md)
- [BigWig spec](https://genome.ucsc.edu/goldenPath/help/bigWig.html)

### htslib Documentation
- [htslib GitHub](https://github.com/samtools/htslib)
- [htslib API docs](http://www.htslib.org/doc/)

---

## Technical Specifications

### FASTA Reader
```swift
public final class FASTAReader: FormatReader {
    public static let supportedExtensions: Set<String> = ["fa", "fasta", "fna", "ffn", "faa"]

    private let fileHandle: FileHandle
    private var index: FASTAIndex?

    public func read(from url: URL) async throws -> [Sequence] {
        var sequences: [Sequence] = []
        var currentName: String?
        var currentSequence = Data()

        for try await line in url.lines {
            if line.hasPrefix(">") {
                if let name = currentName {
                    sequences.append(Sequence(name: name, data: currentSequence))
                    currentSequence = Data()
                }
                currentName = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                currentSequence.append(contentsOf: line.utf8)
            }
        }

        if let name = currentName {
            sequences.append(Sequence(name: name, data: currentSequence))
        }

        return sequences
    }

    public func read(from url: URL, region: GenomicRegion) async throws -> SequenceView {
        guard let index = try await loadIndex(for: url) else {
            throw FormatError.indexRequired
        }

        let entry = index.entry(for: region.chromosome)
        let offset = calculateOffset(entry: entry, position: region.start)
        // Use random access to fetch region
    }
}
```

### htslib Bindings
```swift
// HTSLibBindings.swift
import CHtslib  // C module map for htslib

public final class HTSFile {
    private var file: UnsafeMutablePointer<htsFile>?
    private var header: UnsafeMutablePointer<bam_hdr_t>?
    private var index: UnsafeMutablePointer<hts_idx_t>?

    public init(path: String) throws {
        file = hts_open(path, "r")
        guard file != nil else {
            throw FormatError.cannotOpen(path)
        }

        header = sam_hdr_read(file)
    }

    public func query(region: String) throws -> BAMIterator {
        guard let idx = index ?? loadIndex() else {
            throw FormatError.indexRequired
        }

        let iter = sam_itr_querys(idx, header, region)
        return BAMIterator(file: file, header: header, iterator: iter)
    }

    deinit {
        if let idx = index { hts_idx_destroy(idx) }
        if let hdr = header { bam_hdr_destroy(hdr) }
        if let f = file { hts_close(f) }
    }
}
```

### Format Registry
```swift
public final class FormatRegistry {
    public static let shared = FormatRegistry()

    private var readers: [String: any FormatReader.Type] = [:]
    private var writers: [String: any FormatWriter.Type] = [:]

    private init() {
        // Register built-in formats
        register(FASTAReader.self)
        register(FASTQReader.self)
        register(GenBankReader.self)
        register(GFF3Reader.self)
        register(BAMReader.self)
        register(VCFReader.self)
        register(BigWigReader.self)
    }

    public func reader(for url: URL) throws -> any FormatReader {
        let ext = url.pathExtension.lowercased()
            .replacingOccurrences(of: ".gz", with: "")
            .replacingOccurrences(of: ".zst", with: "")

        guard let readerType = readers[ext] else {
            throw FormatError.unsupportedFormat(ext)
        }

        return readerType.init()
    }
}
```

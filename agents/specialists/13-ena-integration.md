# Role: ENA Integration Specialist

## Responsibilities

### Primary Duties
- Implement ENA Portal API integration
- Build EMBL format parser with full feature support
- Create cross-database linking (NCBI ↔ ENA ↔ DDBJ)
- Design European data compliance features
- Implement ENA browser API for sequence retrieval

### Key Deliverables
- ENA Portal API client
- EMBL format reader/writer
- Unified search across INSDC databases
- Cross-reference resolver
- European server fallback for data access

### Decision Authority
- ENA API endpoint selection
- EMBL parsing strategy
- Cross-database ID mapping approach
- Cache synchronization policy

---

## Technical Scope

### Technologies/Frameworks Owned
- ENA Portal API
- ENA Browser API
- EMBL flat file format
- INSDC cross-references

### Component Ownership
```
LungfishCore/
├── Services/
│   ├── ENA/
│   │   ├── ENAService.swift          # PRIMARY OWNER
│   │   ├── ENAPortalClient.swift     # PRIMARY OWNER
│   │   ├── ENABrowserClient.swift    # PRIMARY OWNER
│   │   ├── EMBLReader.swift          # PRIMARY OWNER
│   │   ├── EMBLWriter.swift          # PRIMARY OWNER
│   │   └── CrossRefResolver.swift    # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── ENA/
│   │   ├── ENASearchView.swift       # PRIMARY OWNER
│   │   ├── ENABrowserView.swift      # PRIMARY OWNER
│   │   └── CrossRefView.swift        # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| NCBI Integration Lead | Cross-database linking |
| File Format Expert | EMBL format handling |
| Storage Lead | Cache management |
| UI/UX Lead | Search interface |

---

## Key Decisions to Make

### Architectural Choices

1. **API Selection**
   - Portal API vs. Browser API vs. both
   - Recommendation: Portal for search, Browser for retrieval

2. **ID Resolution**
   - On-demand vs. cached mapping table
   - Recommendation: On-demand with local cache

3. **European Compliance**
   - GDPR considerations for user tracking
   - Recommendation: No user tracking, anonymous API access

4. **Fallback Strategy**
   - ENA primary vs. NCBI fallback
   - Recommendation: User preference with auto-fallback on failure

### ENA Configuration
```swift
public struct ENAConfig {
    // API endpoints
    public var portalBaseURL: String = "https://www.ebi.ac.uk/ena/portal/api"
    public var browserBaseURL: String = "https://www.ebi.ac.uk/ena/browser/api"

    // Request settings
    public var timeout: TimeInterval = 30.0
    public var retryAttempts: Int = 3

    // Result settings
    public var defaultLimit: Int = 100
    public var maxLimit: Int = 100000

    // Caching
    public var cacheEnabled: Bool = true
    public var cacheTTL: TimeInterval = 86400  // 24 hours
}
```

---

## Success Criteria

### Performance Targets
- Portal search: < 3 seconds
- Sequence fetch: < 5 seconds per record
- Cross-ref resolution: < 1 second
- EMBL parsing: > 10 MB/s

### Quality Metrics
- EMBL feature preservation: 100%
- Cross-reference accuracy: 100%
- API availability handling: Graceful degradation
- Cache hit rate: > 80% for repeated queries

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 3 | ENA Portal client | Week 8 |
| 4 | EMBL reader | Week 9 |
| 4 | ENA search UI | Week 10 |
| 5 | Cross-ref resolver | Week 11 |
| 5 | Unified search | Week 12 |

---

## Reference Materials

### ENA Documentation
- [ENA Portal API](https://www.ebi.ac.uk/ena/portal/api/)
- [ENA Browser API](https://www.ebi.ac.uk/ena/browser/api/)
- [EMBL Format Specification](https://www.ebi.ac.uk/ena/submit/flat-file)

### Cross-Reference Resources
- [INSDC Feature Table](http://www.insdc.org/files/feature_table.html)
- [Accession Number Formats](https://www.ncbi.nlm.nih.gov/Sequin/acc.html)

---

## Technical Specifications

### ENA Portal Client
```swift
public actor ENAPortalClient {
    private let config: ENAConfig
    private let session: URLSession
    private let cache: DiskCache<String, Data>

    public init(config: ENAConfig = ENAConfig()) {
        self.config = config
        self.session = URLSession(configuration: .default)
        self.cache = DiskCache(maxSize: 500_000_000)  // 500MB
    }

    // Search sequences
    public func search(
        query: String,
        dataPortal: DataPortal = .ena,
        result: ResultType = .sequence,
        fields: [String] = ["accession", "description", "sequence_length", "tax_id", "scientific_name"],
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> ENASearchResult {
        var components = URLComponents(string: "\(config.portalBaseURL)/search")!

        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "dataPortal", value: dataPortal.rawValue),
            URLQueryItem(name: "result", value: result.rawValue),
            URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "format", value: "json")
        ]

        let cacheKey = components.url!.absoluteString
        if config.cacheEnabled, let cached = await cache.get(cacheKey) {
            return try JSONDecoder().decode(ENASearchResult.self, from: cached)
        }

        let (data, response) = try await session.data(from: components.url!)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ENAError.searchFailed(response)
        }

        if config.cacheEnabled {
            await cache.set(cacheKey, value: data, ttl: config.cacheTTL)
        }

        return try JSONDecoder().decode(ENASearchResult.self, from: data)
    }

    // Get taxonomy
    public func taxonomy(taxId: Int) async throws -> ENATaxonomy {
        let url = URL(string: "\(config.portalBaseURL)/search")!
            .appending(queryItems: [
                URLQueryItem(name: "query", value: "tax_eq(\(taxId))"),
                URLQueryItem(name: "result", value: "taxon"),
                URLQueryItem(name: "fields", value: "tax_id,scientific_name,common_name,tax_division,lineage"),
                URLQueryItem(name: "format", value: "json")
            ])

        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(ENATaxonomy.self, from: data)
    }

    public enum DataPortal: String {
        case ena
        case metagenome
        case pathogen
    }

    public enum ResultType: String {
        case sequence
        case assembly
        case wgs_set
        case study
        case sample
        case experiment
        case run
        case analysis
        case taxon
    }
}
```

### ENA Browser Client
```swift
public struct ENABrowserClient {
    private let config: ENAConfig
    private let session: URLSession

    // Fetch sequence in various formats
    public func fetch(
        accession: String,
        format: SequenceFormat = .embl
    ) async throws -> Data {
        let url = URL(string: "\(config.browserBaseURL)/\(format.rawValue)/\(accession)")!

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ENAError.fetchFailed(accession, response)
        }

        return data
    }

    // Fetch FASTA
    public func fetchFASTA(accession: String) async throws -> Sequence {
        let data = try await fetch(accession: accession, format: .fasta)
        let reader = FASTAReader()
        let sequences = try reader.parse(data: data)
        guard let sequence = sequences.first else {
            throw ENAError.noSequenceFound(accession)
        }
        return sequence
    }

    // Fetch EMBL with annotations
    public func fetchEMBL(accession: String) async throws -> GenomicDocument {
        let data = try await fetch(accession: accession, format: .embl)
        let reader = EMBLReader()
        let documents = try reader.parse(data: data)
        guard let doc = documents.first else {
            throw ENAError.noSequenceFound(accession)
        }
        return doc
    }

    public enum SequenceFormat: String {
        case fasta
        case embl
        case xml
    }
}
```

### EMBL Reader
```swift
public final class EMBLReader: FormatReader {
    public static let supportedExtensions: Set<String> = ["embl", "dat"]

    public func parse(data: Data) throws -> [GenomicDocument] {
        guard let content = String(data: data, encoding: .utf8) else {
            throw FormatError.invalidEncoding
        }

        var documents: [GenomicDocument] = []
        var currentEntry: EMBLEntry?

        for line in content.components(separatedBy: .newlines) {
            guard line.count >= 2 else { continue }

            let lineType = String(line.prefix(2))
            let lineContent = line.count > 5 ? String(line.dropFirst(5)) : ""

            switch lineType {
            case "ID":
                if let entry = currentEntry {
                    documents.append(try buildDocument(from: entry))
                }
                currentEntry = EMBLEntry()
                currentEntry?.parseID(lineContent)

            case "AC":
                currentEntry?.parseAccession(lineContent)

            case "DE":
                currentEntry?.description += lineContent + " "

            case "KW":
                currentEntry?.parseKeywords(lineContent)

            case "OS":
                currentEntry?.organism = lineContent

            case "OC":
                currentEntry?.parseClassification(lineContent)

            case "RN", "RP", "RX", "RA", "RT", "RL":
                currentEntry?.parseReference(lineType: lineType, content: lineContent)

            case "DR":
                currentEntry?.parseDatabaseReference(lineContent)

            case "FH", "FT":
                currentEntry?.parseFeature(lineType: lineType, content: lineContent)

            case "SQ":
                currentEntry?.parseSequenceHeader(lineContent)

            case "  ":
                currentEntry?.appendSequence(lineContent)

            case "//":
                if let entry = currentEntry {
                    documents.append(try buildDocument(from: entry))
                }
                currentEntry = nil

            default:
                break  // Ignore unknown lines
            }
        }

        return documents
    }

    private func buildDocument(from entry: EMBLEntry) throws -> GenomicDocument {
        let sequence = Sequence(
            name: entry.accession ?? "Unknown",
            data: Data(entry.sequence.utf8),
            alphabet: entry.moleculeType == "AA" ? .protein : .dna
        )

        var annotations: [SequenceAnnotation] = []
        for feature in entry.features {
            annotations.append(SequenceAnnotation(
                type: mapFeatureType(feature.key),
                name: feature.qualifiers["gene"] ?? feature.qualifiers["product"] ?? feature.key,
                intervals: parseLocation(feature.location),
                strand: feature.location.contains("complement") ? .negative : .positive,
                qualifiers: feature.qualifiers.mapValues { .string($0) }
            ))
        }

        return GenomicDocument(
            name: entry.description.trimmingCharacters(in: .whitespaces),
            sequence: sequence,
            annotations: annotations,
            metadata: DocumentMetadata(
                accession: entry.accession,
                organism: entry.organism,
                taxonomy: entry.classification,
                keywords: entry.keywords,
                databaseReferences: entry.dbReferences
            )
        )
    }
}
```

### Cross-Reference Resolver
```swift
public struct CrossRefResolver {
    private let ncbiClient: EntrezClient
    private let enaClient: ENAPortalClient
    private let cache: Cache<String, CrossReference>

    public struct CrossReference {
        public let ncbiAccession: String?
        public let enaAccession: String?
        public let ddbjAccession: String?
        public let uniprotId: String?
        public let geneId: String?
        public let taxId: Int?
    }

    // Resolve accession to all related IDs
    public func resolve(accession: String) async throws -> CrossReference {
        // Check cache
        if let cached = await cache.get(accession) {
            return cached
        }

        // Determine source database from accession format
        let source = identifySource(accession: accession)

        var result = CrossReference(
            ncbiAccession: nil,
            enaAccession: nil,
            ddbjAccession: nil,
            uniprotId: nil,
            geneId: nil,
            taxId: nil
        )

        switch source {
        case .ncbi:
            // Query NCBI for links
            let links = try await ncbiClient.elink(
                sourceDB: .nucleotide,
                targetDB: .protein,
                ids: [accession]
            )
            // Parse and populate result

        case .ena:
            // Query ENA for cross-references
            let enaResult = try await enaClient.search(
                query: "accession=\"\(accession)\"",
                fields: ["accession", "secondary_accession", "db_xref"]
            )
            // Parse and populate result

        case .ddbj, .unknown:
            // Try both
            break
        }

        await cache.set(accession, value: result, ttl: 86400)
        return result
    }

    private func identifySource(accession: String) -> DatabaseSource {
        // NCBI/GenBank: 1 letter + 5 digits, or 2 letters + 6 digits
        // ENA: Same as NCBI (INSDC shared)
        // RefSeq: NM_, NR_, NC_, etc.

        if accession.hasPrefix("NM_") || accession.hasPrefix("NR_") ||
           accession.hasPrefix("NC_") || accession.hasPrefix("XM_") {
            return .ncbi  // RefSeq
        }

        // Standard INSDC - could be any, prefer ENA for European users
        return .ena
    }

    public enum DatabaseSource {
        case ncbi
        case ena
        case ddbj
        case unknown
    }
}
```

### Unified Search View
```swift
public struct UnifiedDatabaseSearchView: View {
    @StateObject private var viewModel = UnifiedSearchViewModel()
    @State private var searchText = ""
    @State private var selectedDatabases: Set<Database> = [.ncbi, .ena]

    public var body: some View {
        VStack(spacing: 0) {
            // Database selection
            HStack {
                ForEach(Database.allCases, id: \.self) { db in
                    Toggle(db.displayName, isOn: Binding(
                        get: { selectedDatabases.contains(db) },
                        set: { if $0 { selectedDatabases.insert(db) } else { selectedDatabases.remove(db) } }
                    ))
                }

                Spacer()

                TextField("Search all databases...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { performSearch() }

                Button("Search", action: performSearch)
            }
            .padding()

            Divider()

            // Results from all databases
            HSplitView {
                ForEach(Array(selectedDatabases), id: \.self) { db in
                    VStack {
                        Text(db.displayName)
                            .font(.headline)

                        if viewModel.isLoading(db) {
                            ProgressView()
                        } else {
                            List(viewModel.results(for: db), selection: $viewModel.selection) { result in
                                DatabaseResultRow(result: result)
                            }
                        }
                    }
                }
            }
        }
    }

    private func performSearch() {
        Task {
            await viewModel.search(
                query: searchText,
                databases: selectedDatabases
            )
        }
    }

    public enum Database: CaseIterable {
        case ncbi, ena, ddbj

        var displayName: String {
            switch self {
            case .ncbi: return "NCBI"
            case .ena: return "ENA"
            case .ddbj: return "DDBJ"
            }
        }
    }
}
```

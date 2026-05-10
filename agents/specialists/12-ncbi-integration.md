# Role: NCBI/Database Integration Lead

## Responsibilities

### Primary Duties
- Implement NCBI Entrez E-utilities integration
- Build GenBank download with full annotation preservation
- Create SRA data access (prefetch, fasterq-dump)
- Design BioProject/BioSample navigation
- Implement taxonomy database access

### Key Deliverables
- Complete Entrez API client
- GenBank parser with annotation fidelity
- SRA download manager with progress
- Taxonomy hierarchy browser
- BLAST integration for sequence search

### Decision Authority
- API rate limiting strategy
- Caching policy for NCBI data
- Annotation mapping decisions
- Download queue management

---

## Technical Scope

### Technologies/Frameworks Owned
- NCBI E-utilities (esearch, efetch, einfo, elink)
- EDirect command-line tools
- SRA toolkit integration
- BLAST+ local/remote

### Component Ownership
```
LungfishCore/
├── Services/
│   ├── NCBI/
│   │   ├── NCBIService.swift         # PRIMARY OWNER
│   │   ├── EntrezClient.swift        # PRIMARY OWNER
│   │   ├── GenBankFetcher.swift      # PRIMARY OWNER
│   │   ├── SRADownloader.swift       # PRIMARY OWNER
│   │   ├── TaxonomyService.swift     # PRIMARY OWNER
│   │   └── BLASTService.swift        # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── NCBI/
│   │   ├── NCBISearchView.swift      # PRIMARY OWNER
│   │   ├── GenBankBrowserView.swift  # PRIMARY OWNER
│   │   ├── SRABrowserView.swift      # PRIMARY OWNER
│   │   └── TaxonomyTreeView.swift    # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| File Format Expert | GenBank parsing |
| ENA Integration | Cross-database linking |
| Storage Lead | Download cache management |
| UI/UX Lead | Search interface design |

---

## Key Decisions to Make

### Architectural Choices

1. **API Access Method**
   - Direct HTTP vs. EDirect CLI vs. BioPython
   - Recommendation: Direct HTTP with async/await for control

2. **Rate Limiting**
   - Fixed delay vs. adaptive vs. API key
   - Recommendation: API key registration + adaptive delay

3. **Caching Strategy**
   - Memory vs. disk vs. database
   - Recommendation: Disk cache with TTL, memory LRU for active

4. **SRA Download**
   - Native implementation vs. SRA toolkit wrapper
   - Recommendation: SRA toolkit wrapper (prefetch + fasterq-dump)

### Entrez Configuration
```swift
public struct EntrezConfig {
    // API settings
    public var apiKey: String?  // Registered NCBI API key
    public var tool: String = "Lungfish"
    public var email: String  // Required by NCBI

    // Rate limiting
    public var requestsPerSecond: Double = 3.0  // 10 with API key
    public var retryAttempts: Int = 3
    public var retryDelay: TimeInterval = 5.0

    // Caching
    public var cacheEnabled: Bool = true
    public var cacheTTL: TimeInterval = 86400  // 24 hours
    public var maxCacheSize: Int = 1_000_000_000  // 1GB
}
```

---

## Success Criteria

### Performance Targets
- Search response: < 2 seconds
- GenBank fetch (single record): < 5 seconds
- Batch download (100 records): < 60 seconds
- SRA prefetch: Limited by network bandwidth
- BLAST search: < 60 seconds for typical query

### Quality Metrics
- Annotation preservation: 100% fidelity
- Search result accuracy: Matches NCBI website
- Download integrity: Checksum validation
- Rate limit compliance: Zero 429 errors

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 3 | Entrez client | Week 7 |
| 3 | GenBank fetcher | Week 8 |
| 4 | Search UI | Week 9 |
| 4 | SRA downloader | Week 10 |
| 5 | BLAST integration | Week 12 |
| 5 | Taxonomy browser | Week 13 |

---

## Reference Materials

### NCBI Documentation
- [Entrez Programming Utilities](https://www.ncbi.nlm.nih.gov/books/NBK25497/)
- [E-utilities Quick Start](https://www.ncbi.nlm.nih.gov/books/NBK25500/)
- [SRA Toolkit](https://github.com/ncbi/sra-tools)

### API References
- [Entrez Database List](https://www.ncbi.nlm.nih.gov/books/NBK25497/table/chapter2.T._entrez_unique_identifiers/)
- [GenBank Format](https://www.ncbi.nlm.nih.gov/Sitemap/samplerecord.html)

---

## Technical Specifications

### Entrez Client
```swift
public actor EntrezClient {
    private let config: EntrezConfig
    private let session: URLSession
    private var lastRequestTime: Date = .distantPast
    private let cache: DiskCache<String, Data>

    private let baseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"

    public init(config: EntrezConfig) {
        self.config = config
        self.session = URLSession(configuration: .default)
        self.cache = DiskCache(maxSize: config.maxCacheSize)
    }

    // Rate-limited request
    private func request(endpoint: String, params: [String: String]) async throws -> Data {
        // Rate limiting
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        let minInterval = 1.0 / config.requestsPerSecond
        if elapsed < minInterval {
            try await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
        }
        lastRequestTime = Date()

        // Build URL
        var components = URLComponents(string: baseURL + endpoint)!
        var queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "tool", value: config.tool))
        queryItems.append(URLQueryItem(name: "email", value: config.email))
        if let apiKey = config.apiKey {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components.queryItems = queryItems

        // Check cache
        let cacheKey = components.url!.absoluteString
        if config.cacheEnabled, let cached = await cache.get(cacheKey) {
            return cached
        }

        // Make request
        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NCBIError.requestFailed(response)
        }

        // Cache response
        if config.cacheEnabled {
            await cache.set(cacheKey, value: data, ttl: config.cacheTTL)
        }

        return data
    }

    // ESearch - search and return IDs
    public func esearch(
        database: EntrezDatabase,
        term: String,
        retmax: Int = 20,
        retstart: Int = 0
    ) async throws -> ESearchResult {
        let data = try await request(endpoint: "esearch.fcgi", params: [
            "db": database.rawValue,
            "term": term,
            "retmax": String(retmax),
            "retstart": String(retstart),
            "retmode": "json"
        ])

        return try JSONDecoder().decode(ESearchResult.self, from: data)
    }

    // EFetch - retrieve records
    public func efetch(
        database: EntrezDatabase,
        ids: [String],
        rettype: String = "gbwithparts",
        retmode: String = "text"
    ) async throws -> Data {
        return try await request(endpoint: "efetch.fcgi", params: [
            "db": database.rawValue,
            "id": ids.joined(separator: ","),
            "rettype": rettype,
            "retmode": retmode
        ])
    }

    // ESummary - document summaries
    public func esummary(
        database: EntrezDatabase,
        ids: [String]
    ) async throws -> ESummaryResult {
        let data = try await request(endpoint: "esummary.fcgi", params: [
            "db": database.rawValue,
            "id": ids.joined(separator: ","),
            "retmode": "json"
        ])

        return try JSONDecoder().decode(ESummaryResult.self, from: data)
    }

    // ELink - find related records
    public func elink(
        sourceDB: EntrezDatabase,
        targetDB: EntrezDatabase,
        ids: [String]
    ) async throws -> ELinkResult {
        let data = try await request(endpoint: "elink.fcgi", params: [
            "dbfrom": sourceDB.rawValue,
            "db": targetDB.rawValue,
            "id": ids.joined(separator: ","),
            "retmode": "json"
        ])

        return try JSONDecoder().decode(ELinkResult.self, from: data)
    }
}

public enum EntrezDatabase: String {
    case nucleotide
    case protein
    case gene
    case sra
    case bioproject
    case biosample
    case taxonomy
    case pubmed
    case assembly
}
```

### GenBank Fetcher
```swift
public struct GenBankFetcher {
    private let client: EntrezClient

    public func search(
        query: String,
        database: EntrezDatabase = .nucleotide,
        limit: Int = 20
    ) async throws -> [GenBankSummary] {
        let searchResult = try await client.esearch(
            database: database,
            term: query,
            retmax: limit
        )

        guard !searchResult.idList.isEmpty else {
            return []
        }

        let summaries = try await client.esummary(
            database: database,
            ids: searchResult.idList
        )

        return summaries.result.map { GenBankSummary(from: $0) }
    }

    public func fetch(
        accessions: [String],
        includeAnnotations: Bool = true
    ) async throws -> [GenomicDocument] {
        let rettype = includeAnnotations ? "gbwithparts" : "fasta"

        let data = try await client.efetch(
            database: .nucleotide,
            ids: accessions,
            rettype: rettype
        )

        let parser = GenBankReader()
        return try parser.parse(data: data)
    }

    public func fetchWithRelated(
        accession: String
    ) async throws -> GenBankFetchResult {
        // Fetch main record
        let mainDoc = try await fetch(accessions: [accession]).first!

        // Find related records
        let links = try await client.elink(
            sourceDB: .nucleotide,
            targetDB: .protein,
            ids: [accession]
        )

        var proteins: [GenomicDocument] = []
        if !links.proteinIds.isEmpty {
            let proteinData = try await client.efetch(
                database: .protein,
                ids: links.proteinIds,
                rettype: "gp"
            )
            proteins = try GenBankReader().parse(data: proteinData)
        }

        return GenBankFetchResult(
            sequence: mainDoc,
            proteins: proteins,
            references: links.pubmedIds
        )
    }
}
```

### SRA Downloader
```swift
public actor SRADownloader {
    private let sratoolsPath: URL
    private var activeDownloads: [String: DownloadTask] = [:]

    public struct DownloadOptions {
        public var outputDirectory: URL
        public var splitFiles: Bool = true      // Split paired reads
        public var compressOutput: Bool = true   // gzip output
        public var threads: Int = 4
        public var minReadLength: Int = 0
        public var maxSpotId: Int?              // Limit for testing
    }

    public func download(
        accession: String,
        options: DownloadOptions,
        progress: @escaping (DownloadProgress) -> Void
    ) async throws -> [URL] {
        // Step 1: Prefetch SRA file
        let sraFile = try await prefetch(accession: accession, progress: progress)

        // Step 2: Extract FASTQ with fasterq-dump
        let fastqFiles = try await fasterqDump(
            sraFile: sraFile,
            options: options,
            progress: progress
        )

        // Step 3: Compress if requested
        if options.compressOutput {
            return try await compressFiles(fastqFiles, progress: progress)
        }

        return fastqFiles
    }

    private func prefetch(
        accession: String,
        progress: @escaping (DownloadProgress) -> Void
    ) async throws -> URL {
        let process = Process()
        process.executableURL = sratoolsPath.appending(path: "prefetch")
        process.arguments = [accession, "--progress"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Monitor progress from output
        for try await line in pipe.fileHandleForReading.bytes.lines {
            if let pct = parseProgress(line) {
                progress(DownloadProgress(phase: .prefetch, percentage: pct))
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SRAError.prefetchFailed(accession)
        }

        return URL(fileURLWithPath: "\(accession)/\(accession).sra")
    }

    private func fasterqDump(
        sraFile: URL,
        options: DownloadOptions,
        progress: @escaping (DownloadProgress) -> Void
    ) async throws -> [URL] {
        let process = Process()
        process.executableURL = sratoolsPath.appending(path: "fasterq-dump")

        var args = [sraFile.path]
        args += ["--outdir", options.outputDirectory.path]
        args += ["--threads", String(options.threads)]
        if options.splitFiles {
            args += ["--split-files"]
        }
        if options.minReadLength > 0 {
            args += ["--min-read-len", String(options.minReadLength)]
        }
        args += ["--progress"]

        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        for try await line in pipe.fileHandleForReading.bytes.lines {
            if let pct = parseProgress(line) {
                progress(DownloadProgress(phase: .extract, percentage: pct))
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SRAError.extractionFailed(sraFile)
        }

        // Find output files
        let contents = try FileManager.default.contentsOfDirectory(
            at: options.outputDirectory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "fastq" }
    }
}
```

### NCBI Search View
```swift
public struct NCBISearchView: View {
    @StateObject private var viewModel = NCBISearchViewModel()
    @State private var searchText = ""
    @State private var selectedDatabase: EntrezDatabase = .nucleotide

    public var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Picker("Database", selection: $selectedDatabase) {
                    Text("Nucleotide").tag(EntrezDatabase.nucleotide)
                    Text("Protein").tag(EntrezDatabase.protein)
                    Text("SRA").tag(EntrezDatabase.sra)
                    Text("Assembly").tag(EntrezDatabase.assembly)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                TextField("Search NCBI...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task {
                            await viewModel.search(query: searchText, database: selectedDatabase)
                        }
                    }

                Button("Search") {
                    Task {
                        await viewModel.search(query: searchText, database: selectedDatabase)
                    }
                }
                .keyboardShortcut(.return)
            }
            .padding()

            Divider()

            // Results
            if viewModel.isLoading {
                ProgressView("Searching NCBI...")
            } else if viewModel.results.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Enter a search term to find sequences")
                )
            } else {
                Table(viewModel.results, selection: $viewModel.selection) {
                    TableColumn("Accession", value: \.accession)
                    TableColumn("Title", value: \.title)
                    TableColumn("Length") { item in
                        Text("\(item.length) bp")
                    }
                    TableColumn("Organism", value: \.organism)
                }
                .contextMenu(forSelectionType: GenBankSummary.ID.self) { selection in
                    Button("Download Selected") {
                        Task {
                            await viewModel.download(selection: selection)
                        }
                    }
                }
            }
        }
    }
}
```

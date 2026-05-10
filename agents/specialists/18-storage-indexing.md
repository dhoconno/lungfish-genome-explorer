# Role: Storage & Indexing Lead

## Responsibilities

### Primary Duties
- Design project file structure and manifest format
- Implement index generation (FAI, BAI, R-tree)
- Build memory-mapped file access system
- Create cache management with LRU eviction
- Design project migration and backup strategies

### Key Deliverables
- Project directory structure specification
- Index file generators and readers
- Memory-mapped data access layer
- Multi-level cache system
- Project backup and recovery tools

### Decision Authority
- Project format specification
- Index format selection
- Cache sizing and eviction policies
- Storage optimization strategies

---

## Technical Scope

### Technologies/Frameworks Owned
- Memory-mapped I/O (mmap)
- Index file formats
- Cache algorithms (LRU, LFU)
- File compression
- Atomic file operations

### Component Ownership
```
LungfishCore/
├── Storage/
│   ├── Project/
│   │   ├── ProjectManager.swift      # PRIMARY OWNER
│   │   ├── ProjectManifest.swift     # PRIMARY OWNER
│   │   ├── ProjectMigrator.swift     # PRIMARY OWNER
│   │   └── ProjectBackup.swift       # PRIMARY OWNER
│   ├── Index/
│   │   ├── FASTAIndex.swift          # PRIMARY OWNER
│   │   ├── BAMIndex.swift            # PRIMARY OWNER
│   │   ├── TabixIndex.swift          # PRIMARY OWNER
│   │   ├── RTreeIndex.swift          # PRIMARY OWNER
│   │   └── IndexManager.swift        # PRIMARY OWNER
│   ├── Cache/
│   │   ├── TileCache.swift           # PRIMARY OWNER
│   │   ├── SequenceCache.swift       # PRIMARY OWNER
│   │   ├── DiskCache.swift           # PRIMARY OWNER
│   │   └── CacheManager.swift        # PRIMARY OWNER
│   └── IO/
│       ├── MemoryMappedFile.swift    # PRIMARY OWNER
│       ├── AsyncFileReader.swift     # PRIMARY OWNER
│       └── AtomicWriter.swift        # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| File Format Expert | Index file formats |
| Version Control Specialist | Object store storage |
| Track Rendering Engineer | Tile cache |
| Sequence Viewer Specialist | Sequence data access |

---

## Key Decisions to Make

### Architectural Choices

1. **Project Format**
   - Single file vs. directory bundle vs. database
   - Recommendation: Directory bundle with JSON manifest

2. **Large File Strategy**
   - Copy into project vs. reference with symlink
   - Recommendation: Symlink large files, copy small

3. **Index Generation**
   - On-demand vs. background vs. at import
   - Recommendation: Background with progress UI

4. **Cache Strategy**
   - Memory-only vs. disk-backed vs. hybrid
   - Recommendation: Hybrid with configurable sizes

### Project Structure
```
my-project.lgb/
├── project.json              # Project manifest
├── .lgb/
│   ├── metadata.sqlite       # Searchable metadata (NOT sequences)
│   ├── history/              # Version history (git-like)
│   │   ├── objects/          # Content-addressed storage
│   │   └── refs/             # Branch/tag references
│   ├── index/                # Generated indices
│   │   ├── sequences/        # FAI files
│   │   └── alignments/       # BAI/CSI files
│   └── cache/                # Tile cache, thumbnails
├── sequences/
│   ├── manifest.json         # Sequence registry
│   ├── imported/             # Copied sequence files
│   └── linked/               # Symlinks to external files
├── annotations/
│   ├── layers.json           # Annotation layer registry
│   └── *.gff3                # Annotation files
├── alignments/
│   ├── manifest.json         # Alignment registry
│   └── linked/               # Symlinks to BAM/CRAM files
└── exports/                  # Export staging area
```

---

## Success Criteria

### Performance Targets
- Project open: < 1 second for 100 documents
- Index load: < 100ms for 1M entries
- Memory-mapped read: < 1ms random access
- Cache hit rate: > 90% for normal use

### Quality Metrics
- Zero data loss on crash (atomic writes)
- Index consistency validation
- Project integrity checks
- Storage efficiency > 80% (vs. raw)

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Project structure | Week 2 |
| 1 | Memory-mapped I/O | Week 3 |
| 2 | FAI index | Week 4 |
| 2 | BAI/CSI index | Week 5 |
| 3 | Tile cache | Week 7 |
| 3 | Cache manager | Week 8 |

---

## Reference Materials

### Index Formats
- [FASTA Index (FAI)](http://www.htslib.org/doc/faidx.html)
- [BAM Index (BAI)](https://samtools.github.io/hts-specs/SAMv1.pdf)
- [Tabix Index (TBI)](http://www.htslib.org/doc/tabix.html)
- [R-tree Index](https://en.wikipedia.org/wiki/R-tree)

### Apple Documentation
- [Memory Mapped Files](https://developer.apple.com/documentation/foundation/nsdata/readingoptions)
- [File Coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator)

---

## Technical Specifications

### Project Manager
```swift
public actor ProjectManager {
    private var openProjects: [UUID: Project] = [:]
    private let fileCoordinator = NSFileCoordinator()

    public func createProject(at url: URL, name: String) async throws -> Project {
        // Create directory structure
        let structure = [
            "",
            ".lgb",
            ".lgb/metadata.sqlite",
            ".lgb/history/objects",
            ".lgb/history/refs",
            ".lgb/index/sequences",
            ".lgb/index/alignments",
            ".lgb/cache",
            "sequences",
            "sequences/imported",
            "sequences/linked",
            "annotations",
            "alignments",
            "alignments/linked",
            "exports"
        ]

        for path in structure {
            let fullPath = url.appending(path: path)
            if path.contains(".") && !path.hasPrefix(".") {
                // It's a file
                if !FileManager.default.fileExists(atPath: fullPath.path) {
                    FileManager.default.createFile(atPath: fullPath.path, contents: nil)
                }
            } else {
                // It's a directory
                try FileManager.default.createDirectory(
                    at: fullPath,
                    withIntermediateDirectories: true
                )
            }
        }

        // Create manifest
        let manifest = ProjectManifest(
            id: UUID(),
            name: name,
            version: "1.0",
            created: Date(),
            modified: Date(),
            sequences: [],
            annotations: [],
            alignments: []
        )

        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: url.appending(path: "project.json"))

        let project = Project(url: url, manifest: manifest)
        openProjects[manifest.id] = project

        return project
    }

    public func openProject(at url: URL) async throws -> Project {
        // Check if already open
        let manifestURL = url.appending(path: "project.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: manifestData)

        if let existing = openProjects[manifest.id] {
            return existing
        }

        let project = Project(url: url, manifest: manifest)
        openProjects[manifest.id] = project

        // Validate project integrity
        try await validateProject(project)

        return project
    }

    public func saveProject(_ project: Project) async throws {
        // Use file coordination for safety
        var coordinatorError: NSError?
        var saveError: Error?

        fileCoordinator.coordinate(
            writingItemAt: project.url,
            options: .forReplacing,
            error: &coordinatorError
        ) { url in
            do {
                // Update modified date
                var manifest = project.manifest
                manifest.modified = Date()

                // Atomic write
                let tempURL = url.appending(path: ".project.json.tmp")
                let data = try JSONEncoder().encode(manifest)
                try data.write(to: tempURL, options: .atomic)
                try FileManager.default.replaceItemAt(
                    url.appending(path: "project.json"),
                    withItemAt: tempURL
                )
            } catch {
                saveError = error
            }
        }

        if let error = coordinatorError ?? saveError {
            throw error
        }
    }

    private func validateProject(_ project: Project) async throws {
        // Check all referenced files exist
        for sequence in project.manifest.sequences {
            let path = project.url.appending(path: sequence.path)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw ProjectError.missingFile(sequence.path)
            }
        }

        // Verify index files
        let indexManager = IndexManager(project: project)
        try await indexManager.validateIndices()
    }
}

public struct ProjectManifest: Codable {
    public var id: UUID
    public var name: String
    public var version: String
    public var created: Date
    public var modified: Date

    public var sequences: [SequenceReference]
    public var annotations: [AnnotationReference]
    public var alignments: [AlignmentReference]

    public struct SequenceReference: Codable, Identifiable {
        public let id: UUID
        public var name: String
        public var path: String  // Relative to project root
        public var format: String
        public var length: Int
        public var indexed: Bool
    }

    public struct AnnotationReference: Codable, Identifiable {
        public let id: UUID
        public var name: String
        public var path: String
        public var format: String
        public var featureCount: Int
    }

    public struct AlignmentReference: Codable, Identifiable {
        public let id: UUID
        public var name: String
        public var path: String
        public var format: String
        public var readCount: Int
        public var indexed: Bool
    }
}

public class Project: ObservableObject {
    public let url: URL
    @Published public var manifest: ProjectManifest

    public lazy var objectStore = ObjectStore(path: url.appending(path: ".lgb/history"))
    public lazy var indexManager = IndexManager(project: self)
    public lazy var cacheManager = CacheManager(project: self)

    public init(url: URL, manifest: ProjectManifest) {
        self.url = url
        self.manifest = manifest
    }
}
```

### Memory-Mapped File
```swift
public final class MemoryMappedFile {
    private let fileHandle: FileHandle
    private let data: Data
    private let length: Int

    public init(url: URL) throws {
        fileHandle = try FileHandle(forReadingFrom: url)

        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        length = attributes[.size] as! Int

        // Memory map the file
        data = try fileHandle.map(offset: 0, length: length)
    }

    deinit {
        try? fileHandle.close()
    }

    public subscript(range: Range<Int>) -> Data {
        precondition(range.lowerBound >= 0 && range.upperBound <= length)
        return data.subdata(in: range)
    }

    public subscript(offset: Int) -> UInt8 {
        precondition(offset >= 0 && offset < length)
        return data[offset]
    }

    public func string(at offset: Int, length: Int, encoding: String.Encoding = .utf8) -> String? {
        let subdata = self[offset..<(offset + length)]
        return String(data: subdata, encoding: encoding)
    }

    public func readLine(from offset: Int) -> (String, Int)? {
        var end = offset
        while end < length && data[end] != 0x0A {  // newline
            end += 1
        }

        if let line = string(at: offset, length: end - offset) {
            return (line, end + 1)
        }
        return nil
    }
}

extension FileHandle {
    func map(offset: Int, length: Int) throws -> Data {
        let fd = self.fileDescriptor

        guard let ptr = mmap(
            nil,
            length,
            PROT_READ,
            MAP_PRIVATE,
            fd,
            off_t(offset)
        ), ptr != MAP_FAILED else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }

        return Data(bytesNoCopy: ptr, count: length, deallocator: .custom { ptr, count in
            munmap(ptr, count)
        })
    }
}
```

### FASTA Index
```swift
public struct FASTAIndex {
    public struct Entry {
        public let name: String
        public let length: Int
        public let offset: Int       // Byte offset to start of sequence
        public let lineBases: Int    // Bases per line
        public let lineBytes: Int    // Bytes per line (including newline)
    }

    public let entries: [String: Entry]
    private let sortedNames: [String]

    public init(url: URL) throws {
        let content = try String(contentsOf: url)
        var entries: [String: Entry] = [:]
        var names: [String] = []

        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t")
            guard parts.count >= 5 else { continue }

            let name = String(parts[0])
            let entry = Entry(
                name: name,
                length: Int(parts[1])!,
                offset: Int(parts[2])!,
                lineBases: Int(parts[3])!,
                lineBytes: Int(parts[4])!
            )

            entries[name] = entry
            names.append(name)
        }

        self.entries = entries
        self.sortedNames = names
    }

    public init(buildFrom fastaURL: URL) throws {
        let file = try MemoryMappedFile(url: fastaURL)
        var entries: [String: Entry] = [:]
        var names: [String] = []

        var offset = 0
        var currentName: String?
        var currentOffset = 0
        var currentLength = 0
        var lineBases = 0
        var lineBytes = 0
        var firstLine = true

        while offset < file.length {
            guard let (line, nextOffset) = file.readLine(from: offset) else { break }

            if line.hasPrefix(">") {
                // Save previous entry
                if let name = currentName {
                    entries[name] = Entry(
                        name: name,
                        length: currentLength,
                        offset: currentOffset,
                        lineBases: lineBases,
                        lineBytes: lineBytes
                    )
                    names.append(name)
                }

                // Start new entry
                currentName = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first
                currentOffset = nextOffset
                currentLength = 0
                firstLine = true
            } else {
                if firstLine {
                    lineBases = line.count
                    lineBytes = nextOffset - offset
                    firstLine = false
                }
                currentLength += line.count
            }

            offset = nextOffset
        }

        // Save last entry
        if let name = currentName {
            entries[name] = Entry(
                name: name,
                length: currentLength,
                offset: currentOffset,
                lineBases: lineBases,
                lineBytes: lineBytes
            )
            names.append(name)
        }

        self.entries = entries
        self.sortedNames = names
    }

    // Calculate byte offset for a position
    public func byteOffset(for entry: Entry, position: Int) -> Int {
        let fullLines = position / entry.lineBases
        let remainder = position % entry.lineBases
        return entry.offset + (fullLines * entry.lineBytes) + remainder
    }

    // Write index to file
    public func write(to url: URL) throws {
        var lines: [String] = []

        for name in sortedNames {
            let entry = entries[name]!
            lines.append("\(entry.name)\t\(entry.length)\t\(entry.offset)\t\(entry.lineBases)\t\(entry.lineBytes)")
        }

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
```

### Cache Manager
```swift
public actor CacheManager {
    private let project: Project
    private let memoryCache: LRUCache<String, Any>
    private let diskCache: DiskCache
    private let maxMemorySize: Int
    private var currentMemorySize: Int = 0

    public init(project: Project, maxMemoryMB: Int = 512) {
        self.project = project
        self.maxMemorySize = maxMemoryMB * 1024 * 1024
        self.memoryCache = LRUCache(capacity: 1000)
        self.diskCache = DiskCache(
            directory: project.url.appending(path: ".lgb/cache"),
            maxSize: 1024 * 1024 * 1024  // 1GB disk cache
        )
    }

    public func get<T: Codable>(_ key: String, type: T.Type) async -> T? {
        // Try memory cache first
        if let value = memoryCache.get(key) as? T {
            return value
        }

        // Try disk cache
        if let data = await diskCache.get(key),
           let value = try? JSONDecoder().decode(T.self, from: data) {
            // Promote to memory cache
            memoryCache.set(key, value: value)
            return value
        }

        return nil
    }

    public func set<T: Codable>(_ key: String, value: T) async {
        // Store in memory cache
        memoryCache.set(key, value: value)

        // Store in disk cache asynchronously
        if let data = try? JSONEncoder().encode(value) {
            await diskCache.set(key, value: data)
            currentMemorySize += data.count

            // Evict if over limit
            if currentMemorySize > maxMemorySize {
                await evictMemoryCache()
            }
        }
    }

    public func invalidate(_ key: String) async {
        memoryCache.remove(key)
        await diskCache.remove(key)
    }

    public func invalidateAll() async {
        memoryCache.clear()
        await diskCache.clear()
        currentMemorySize = 0
    }

    private func evictMemoryCache() async {
        // Evict until under 80% of limit
        let targetSize = Int(Double(maxMemorySize) * 0.8)

        while currentMemorySize > targetSize {
            if let evicted = memoryCache.evictOldest() {
                if let data = try? JSONEncoder().encode(evicted) {
                    currentMemorySize -= data.count
                }
            } else {
                break
            }
        }
    }
}

public final class LRUCache<Key: Hashable, Value> {
    private var cache: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let capacity: Int
    private let lock = NSLock()

    private class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let node = cache[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    public func set(_ key: Key, value: Value) {
        lock.lock()
        defer { lock.unlock() }

        if let node = cache[key] {
            node.value = value
            moveToHead(node)
        } else {
            let node = Node(key: key, value: value)
            cache[key] = node
            addToHead(node)

            if cache.count > capacity {
                if let tail = removeTail() {
                    cache.removeValue(forKey: tail.key)
                }
            }
        }
    }

    public func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }

        if let node = cache.removeValue(forKey: key) {
            removeNode(node)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        cache.removeAll()
        head = nil
        tail = nil
    }

    public func evictOldest() -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let tail = removeTail() else { return nil }
        cache.removeValue(forKey: tail.key)
        return tail.value
    }

    private func moveToHead(_ node: Node) {
        removeNode(node)
        addToHead(node)
    }

    private func addToHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func removeNode(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if node === head { head = node.next }
        if node === tail { tail = node.prev }
    }

    private func removeTail() -> Node? {
        guard let tail = tail else { return nil }
        removeNode(tail)
        return tail
    }
}

public actor DiskCache {
    private let directory: URL
    private let maxSize: Int
    private var currentSize: Int = 0

    public init(directory: URL, maxSize: Int) {
        self.directory = directory
        self.maxSize = maxSize

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        calculateCurrentSize()
    }

    public func get(_ key: String) -> Data? {
        let path = filePath(for: key)
        return try? Data(contentsOf: path)
    }

    public func set(_ key: String, value: Data) {
        let path = filePath(for: key)
        try? value.write(to: path)
        currentSize += value.count

        if currentSize > maxSize {
            evictOldFiles()
        }
    }

    public func remove(_ key: String) {
        let path = filePath(for: key)
        if let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int {
            currentSize -= size
        }
        try? FileManager.default.removeItem(at: path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        currentSize = 0
    }

    private func filePath(for key: String) -> URL {
        let hash = key.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: hash)
    }

    private func calculateCurrentSize() {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                currentSize += size
            }
        }
    }

    private func evictOldFiles() {
        // Get files sorted by modification date
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ).sorted { url1, url2 in
            let date1 = try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let date2 = try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (date1 ?? .distantPast) < (date2 ?? .distantPast)
        }

        // Remove oldest files until under 80% of max
        let targetSize = Int(Double(maxSize) * 0.8)
        for file in files ?? [] {
            if currentSize <= targetSize { break }
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                try? FileManager.default.removeItem(at: file)
                currentSize -= size
            }
        }
    }
}
```

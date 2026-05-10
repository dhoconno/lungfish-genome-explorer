# Role: Version Control Specialist

## Responsibilities

### Primary Duties
- Implement diff-based sequence versioning
- Build git-like content-addressable object storage
- Create history navigation and timeline visualization
- Design merge conflict resolution for sequences
- Develop branch and tag support

### Key Deliverables
- Sequence diff algorithm (VCF-inspired)
- Content-addressable storage system
- Version history viewer
- Merge tool for conflicting edits
- Undo/redo system integration

### Decision Authority
- Diff algorithm selection
- Storage format design
- Conflict resolution strategies
- History retention policies

---

## Technical Scope

### Technologies/Frameworks Owned
- Sequence diff algorithms
- SHA-256 content addressing
- Delta compression
- Merge algorithms

### Component Ownership
```
LungfishCore/
├── Versioning/
│   ├── SequenceDiff.swift            # PRIMARY OWNER
│   ├── DiffEngine.swift              # PRIMARY OWNER
│   ├── ObjectStore.swift             # PRIMARY OWNER
│   ├── VersionHistory.swift          # PRIMARY OWNER
│   ├── Commit.swift                  # PRIMARY OWNER
│   ├── Branch.swift                  # PRIMARY OWNER
│   ├── MergeEngine.swift             # PRIMARY OWNER
│   └── UndoManager.swift             # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── History/
│   │   ├── HistoryView.swift         # PRIMARY OWNER
│   │   ├── TimelineView.swift        # PRIMARY OWNER
│   │   ├── DiffViewer.swift          # PRIMARY OWNER
│   │   └── MergeConflictView.swift   # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Storage Lead | Object storage backend |
| Sequence Viewer Specialist | Diff visualization |
| Bioinformatics Architect | Sequence data models |
| UI/UX Lead | History UI patterns |

---

## Key Decisions to Make

### Architectural Choices

1. **Diff Algorithm**
   - Myers diff vs. patience diff vs. custom
   - Recommendation: Custom for sequences (position-based like VCF)

2. **Storage Format**
   - Full snapshots vs. delta chains vs. hybrid
   - Recommendation: Hybrid with periodic snapshots

3. **Conflict Resolution**
   - Three-way merge vs. manual vs. both
   - Recommendation: Three-way with manual fallback

4. **History Limits**
   - Unlimited vs. time-based vs. count-based
   - Recommendation: Configurable with compression for old versions

### Version Configuration
```swift
public struct VersioningConfig {
    // Storage
    public var objectStorePath: URL
    public var maxDeltaChainLength: Int = 10  // Before snapshot
    public var compressionEnabled: Bool = true

    // History
    public var maxHistoryCount: Int = 1000
    public var historyRetentionDays: Int = 365
    public var autoCommit: Bool = true  // Auto-commit on save
    public var autoCommitDelay: TimeInterval = 30  // Seconds

    // Branches
    public var defaultBranch: String = "main"
    public var maxBranches: Int = 100
}
```

---

## Success Criteria

### Performance Targets
- Diff calculation (10kb sequence): < 50ms
- Commit creation: < 100ms
- History load: < 500ms for 1000 commits
- Checkout: < 200ms for any version

### Quality Metrics
- Diff accuracy: 100% round-trip fidelity
- Storage efficiency: > 90% reduction vs. full copies
- Merge correctness: Validated against known test cases
- Undo reliability: Never lose data

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 3 | Diff engine | Week 7 |
| 3 | Object store | Week 8 |
| 4 | Version history | Week 9 |
| 4 | Undo/redo | Week 10 |
| 5 | Branch support | Week 11 |
| 5 | Merge engine | Week 12 |

---

## Reference Materials

### Git Internals
- [Git Objects](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects)
- [Git Merge Strategies](https://git-scm.com/book/en/v2/Git-Branching-Basic-Branching-and-Merging)

### Diff Algorithms
- [Myers Diff Algorithm](http://www.xmailserver.org/diff2.pdf)
- [Patience Diff](https://alfedenzo.livejournal.com/170301.html)

### VCF Format
- [VCF Specification](https://samtools.github.io/hts-specs/VCFv4.3.pdf)

---

## Technical Specifications

### Sequence Diff
```swift
public struct SequenceDiff: Codable, Hashable {
    public let operations: [DiffOperation]
    public let baseHash: String  // SHA-256 of base sequence
    public let resultHash: String  // SHA-256 of result

    public enum DiffOperation: Codable, Hashable {
        case substitution(position: Int, ref: String, alt: String)
        case insertion(position: Int, sequence: String)
        case deletion(position: Int, length: Int, ref: String)
        case block(start: Int, end: Int, operations: [DiffOperation])

        var position: Int {
            switch self {
            case .substitution(let pos, _, _): return pos
            case .insertion(let pos, _): return pos
            case .deletion(let pos, _, _): return pos
            case .block(let start, _, _): return start
            }
        }

        var vcfString: String {
            switch self {
            case .substitution(let pos, let ref, let alt):
                return "\(pos)\t\(ref)\t\(alt)\tSNP"
            case .insertion(let pos, let seq):
                return "\(pos)\t.\t\(seq)\tINS"
            case .deletion(let pos, let len, let ref):
                return "\(pos)\t\(ref)\t.\tDEL;\(len)"
            case .block(let start, let end, _):
                return "\(start)-\(end)\tBLOCK"
            }
        }
    }

    public var isEmpty: Bool { operations.isEmpty }

    public var operationCount: Int {
        operations.reduce(0) { count, op in
            if case .block(_, _, let subOps) = op {
                return count + subOps.count
            }
            return count + 1
        }
    }

    // Apply diff to base sequence
    public func apply(to sequence: Sequence) throws -> Sequence {
        // Verify base hash
        guard sequence.hash == baseHash else {
            throw VersionError.hashMismatch(expected: baseHash, actual: sequence.hash)
        }

        var result = sequence.sequenceString

        // Apply operations in reverse position order to preserve indices
        for operation in operations.sorted(by: { $0.position > $1.position }) {
            switch operation {
            case .substitution(let pos, _, let alt):
                let index = result.index(result.startIndex, offsetBy: pos)
                result.replaceSubrange(index...index, with: alt)

            case .insertion(let pos, let seq):
                let index = result.index(result.startIndex, offsetBy: pos)
                result.insert(contentsOf: seq, at: index)

            case .deletion(let pos, let len, _):
                let start = result.index(result.startIndex, offsetBy: pos)
                let end = result.index(start, offsetBy: len)
                result.removeSubrange(start..<end)

            case .block(_, _, let subOps):
                // Recursively apply block operations
                for subOp in subOps.sorted(by: { $0.position > $1.position }) {
                    // Apply sub-operation
                }
            }
        }

        let resultSeq = Sequence(name: sequence.name, data: Data(result.utf8))

        // Verify result hash
        guard resultSeq.hash == resultHash else {
            throw VersionError.resultHashMismatch
        }

        return resultSeq
    }

    // Create diff between two sequences
    public static func create(from base: Sequence, to target: Sequence) -> SequenceDiff {
        let baseStr = base.sequenceString
        let targetStr = target.sequenceString

        var operations: [DiffOperation] = []
        var i = 0
        var j = 0

        while i < baseStr.count && j < targetStr.count {
            let baseChar = baseStr[baseStr.index(baseStr.startIndex, offsetBy: i)]
            let targetChar = targetStr[targetStr.index(targetStr.startIndex, offsetBy: j)]

            if baseChar == targetChar {
                i += 1
                j += 1
            } else {
                // Find the type of operation
                let (op, newI, newJ) = findOperation(
                    base: baseStr, target: targetStr,
                    basePos: i, targetPos: j
                )
                operations.append(op)
                i = newI
                j = newJ
            }
        }

        // Handle remaining insertions
        if j < targetStr.count {
            let remaining = String(targetStr[targetStr.index(targetStr.startIndex, offsetBy: j)...])
            operations.append(.insertion(position: i, sequence: remaining))
        }

        // Handle remaining deletions
        if i < baseStr.count {
            let remaining = String(baseStr[baseStr.index(baseStr.startIndex, offsetBy: i)...])
            operations.append(.deletion(position: i, length: remaining.count, ref: remaining))
        }

        return SequenceDiff(
            operations: operations,
            baseHash: base.hash,
            resultHash: target.hash
        )
    }

    private static func findOperation(
        base: String, target: String,
        basePos: Int, targetPos: Int
    ) -> (DiffOperation, Int, Int) {
        // Look ahead to determine operation type
        // This is a simplified version - real implementation would use LCS or similar

        // Check for substitution (single base change)
        if basePos + 1 < base.count && targetPos + 1 < target.count {
            let nextBase = base[base.index(base.startIndex, offsetBy: basePos + 1)]
            let nextTarget = target[target.index(target.startIndex, offsetBy: targetPos + 1)]

            if nextBase == nextTarget {
                let ref = String(base[base.index(base.startIndex, offsetBy: basePos)])
                let alt = String(target[target.index(target.startIndex, offsetBy: targetPos)])
                return (.substitution(position: basePos, ref: ref, alt: alt), basePos + 1, targetPos + 1)
            }
        }

        // Check for insertion in target
        for lookAhead in 1..<min(100, target.count - targetPos) {
            let targetIndex = target.index(target.startIndex, offsetBy: targetPos + lookAhead)
            let targetChar = target[targetIndex]
            let baseChar = base[base.index(base.startIndex, offsetBy: basePos)]

            if targetChar == baseChar {
                let inserted = String(target[target.index(target.startIndex, offsetBy: targetPos)..<targetIndex])
                return (.insertion(position: basePos, sequence: inserted), basePos, targetPos + lookAhead)
            }
        }

        // Check for deletion in base
        for lookAhead in 1..<min(100, base.count - basePos) {
            let baseIndex = base.index(base.startIndex, offsetBy: basePos + lookAhead)
            let baseChar = base[baseIndex]
            let targetChar = target[target.index(target.startIndex, offsetBy: targetPos)]

            if baseChar == targetChar {
                let deleted = String(base[base.index(base.startIndex, offsetBy: basePos)..<baseIndex])
                return (.deletion(position: basePos, length: lookAhead, ref: deleted), basePos + lookAhead, targetPos)
            }
        }

        // Default to substitution
        let ref = String(base[base.index(base.startIndex, offsetBy: basePos)])
        let alt = String(target[target.index(target.startIndex, offsetBy: targetPos)])
        return (.substitution(position: basePos, ref: ref, alt: alt), basePos + 1, targetPos + 1)
    }
}
```

### Object Store
```swift
public actor ObjectStore {
    private let basePath: URL
    private let cache: LRUCache<String, Data>

    public init(path: URL) {
        self.basePath = path
        self.cache = LRUCache(capacity: 100)

        // Ensure directory structure
        try? FileManager.default.createDirectory(
            at: path.appending(path: "objects"),
            withIntermediateDirectories: true
        )
    }

    // Store object and return hash
    public func store(_ data: Data) async throws -> String {
        let hash = sha256(data)

        // Check if already exists
        let path = objectPath(for: hash)
        if FileManager.default.fileExists(atPath: path.path) {
            return hash
        }

        // Compress and store
        let compressed = try compress(data)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try compressed.write(to: path)

        cache.set(hash, value: data)

        return hash
    }

    // Retrieve object by hash
    public func retrieve(_ hash: String) async throws -> Data {
        if let cached = cache.get(hash) {
            return cached
        }

        let path = objectPath(for: hash)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw VersionError.objectNotFound(hash)
        }

        let compressed = try Data(contentsOf: path)
        let data = try decompress(compressed)

        // Verify hash
        guard sha256(data) == hash else {
            throw VersionError.corruptObject(hash)
        }

        cache.set(hash, value: data)

        return data
    }

    // Store a commit
    public func storeCommit(_ commit: Commit) async throws -> String {
        let data = try JSONEncoder().encode(commit)
        return try await store(data)
    }

    // Retrieve a commit
    public func retrieveCommit(_ hash: String) async throws -> Commit {
        let data = try await retrieve(hash)
        return try JSONDecoder().decode(Commit.self, from: data)
    }

    private func objectPath(for hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        let suffix = String(hash.dropFirst(2))
        return basePath.appending(path: "objects/\(prefix)/\(suffix)")
    }

    private func sha256(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func compress(_ data: Data) throws -> Data {
        // Use zstd compression
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    private func decompress(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .zlib) as Data
    }
}

public struct Commit: Codable, Identifiable {
    public let id: String  // SHA-256 hash
    public let parentIds: [String]
    public let author: String
    public let date: Date
    public let message: String?

    // Content references
    public let sequenceHash: String
    public let annotationHashes: [String]
    public let diffHash: String?  // Diff from parent

    // Metadata
    public let documentId: UUID
    public let branch: String
}
```

### Version History
```swift
public class VersionHistory: ObservableObject {
    @Published public var commits: [Commit] = []
    @Published public var currentCommitId: String?
    @Published public var branches: [Branch] = []
    @Published public var currentBranch: String = "main"

    private let store: ObjectStore
    private let documentId: UUID

    public init(store: ObjectStore, documentId: UUID) {
        self.store = store
        self.documentId = documentId
    }

    // Create a new commit
    public func commit(
        sequence: Sequence,
        annotations: [SequenceAnnotation],
        message: String? = nil
    ) async throws -> Commit {
        // Store sequence
        let sequenceData = try JSONEncoder().encode(sequence)
        let sequenceHash = try await store.store(sequenceData)

        // Store annotations
        var annotationHashes: [String] = []
        for annotation in annotations {
            let data = try JSONEncoder().encode(annotation)
            let hash = try await store.store(data)
            annotationHashes.append(hash)
        }

        // Calculate diff from parent if exists
        var diffHash: String?
        if let parentId = currentCommitId,
           let parent = try? await store.retrieveCommit(parentId) {
            let parentSeqData = try await store.retrieve(parent.sequenceHash)
            let parentSeq = try JSONDecoder().decode(Sequence.self, from: parentSeqData)
            let diff = SequenceDiff.create(from: parentSeq, to: sequence)
            let diffData = try JSONEncoder().encode(diff)
            diffHash = try await store.store(diffData)
        }

        // Create commit
        let commit = Commit(
            id: UUID().uuidString,  // Will be replaced with content hash
            parentIds: currentCommitId.map { [$0] } ?? [],
            author: NSFullUserName(),
            date: Date(),
            message: message,
            sequenceHash: sequenceHash,
            annotationHashes: annotationHashes,
            diffHash: diffHash,
            documentId: documentId,
            branch: currentBranch
        )

        let commitHash = try await store.storeCommit(commit)

        // Update state
        await MainActor.run {
            commits.append(commit)
            currentCommitId = commitHash
        }

        // Update branch ref
        try await updateBranchRef(branch: currentBranch, commitId: commitHash)

        return commit
    }

    // Checkout a specific version
    public func checkout(_ commitId: String) async throws -> (Sequence, [SequenceAnnotation]) {
        let commit = try await store.retrieveCommit(commitId)

        // Retrieve sequence
        let sequenceData = try await store.retrieve(commit.sequenceHash)
        let sequence = try JSONDecoder().decode(Sequence.self, from: sequenceData)

        // Retrieve annotations
        var annotations: [SequenceAnnotation] = []
        for hash in commit.annotationHashes {
            let data = try await store.retrieve(hash)
            let annotation = try JSONDecoder().decode(SequenceAnnotation.self, from: data)
            annotations.append(annotation)
        }

        await MainActor.run {
            currentCommitId = commitId
        }

        return (sequence, annotations)
    }

    // Get diff between two commits
    public func diff(from: String, to: String) async throws -> SequenceDiff {
        let fromCommit = try await store.retrieveCommit(from)
        let toCommit = try await store.retrieveCommit(to)

        let fromSeqData = try await store.retrieve(fromCommit.sequenceHash)
        let fromSeq = try JSONDecoder().decode(Sequence.self, from: fromSeqData)

        let toSeqData = try await store.retrieve(toCommit.sequenceHash)
        let toSeq = try JSONDecoder().decode(Sequence.self, from: toSeqData)

        return SequenceDiff.create(from: fromSeq, to: toSeq)
    }

    // Create a new branch
    public func createBranch(_ name: String, from commitId: String? = nil) async throws {
        let branchCommit = commitId ?? currentCommitId ?? ""
        let branch = Branch(name: name, headCommitId: branchCommit, createdAt: Date())

        await MainActor.run {
            branches.append(branch)
        }

        try await saveBranchRef(branch)
    }

    // Merge branches
    public func merge(source: String, into target: String) async throws -> MergeResult {
        let sourceBranch = branches.first { $0.name == source }!
        let targetBranch = branches.first { $0.name == target }!

        // Find common ancestor
        let ancestor = try await findCommonAncestor(
            commit1: sourceBranch.headCommitId,
            commit2: targetBranch.headCommitId
        )

        // Get sequences
        let ancestorSeq = try await checkout(ancestor).0
        let sourceSeq = try await checkout(sourceBranch.headCommitId).0
        let targetSeq = try await checkout(targetBranch.headCommitId).0

        // Three-way merge
        let mergeResult = threeWayMerge(
            ancestor: ancestorSeq,
            source: sourceSeq,
            target: targetSeq
        )

        return mergeResult
    }

    private func threeWayMerge(
        ancestor: Sequence,
        source: Sequence,
        target: Sequence
    ) -> MergeResult {
        let sourceDiff = SequenceDiff.create(from: ancestor, to: source)
        let targetDiff = SequenceDiff.create(from: ancestor, to: target)

        var conflicts: [MergeConflict] = []
        var mergedOperations: [SequenceDiff.DiffOperation] = []

        // Find overlapping operations
        for sourceOp in sourceDiff.operations {
            let overlapping = targetDiff.operations.filter { targetOp in
                rangesOverlap(sourceOp, targetOp)
            }

            if overlapping.isEmpty {
                mergedOperations.append(sourceOp)
            } else {
                // Check if operations are identical
                if overlapping.count == 1 && overlapping[0] == sourceOp {
                    mergedOperations.append(sourceOp)
                } else {
                    conflicts.append(MergeConflict(
                        position: sourceOp.position,
                        sourceOperation: sourceOp,
                        targetOperations: overlapping
                    ))
                }
            }
        }

        // Add non-conflicting target operations
        for targetOp in targetDiff.operations {
            let conflicting = conflicts.contains { $0.targetOperations.contains(targetOp) }
            if !conflicting && !mergedOperations.contains(targetOp) {
                mergedOperations.append(targetOp)
            }
        }

        if conflicts.isEmpty {
            // Apply merged operations
            let merged = try? SequenceDiff(
                operations: mergedOperations,
                baseHash: ancestor.hash,
                resultHash: ""  // Will be calculated
            ).apply(to: ancestor)

            return MergeResult(
                success: true,
                mergedSequence: merged,
                conflicts: []
            )
        } else {
            return MergeResult(
                success: false,
                mergedSequence: nil,
                conflicts: conflicts
            )
        }
    }

    private func rangesOverlap(_ op1: SequenceDiff.DiffOperation, _ op2: SequenceDiff.DiffOperation) -> Bool {
        // Determine the range affected by each operation
        let range1 = operationRange(op1)
        let range2 = operationRange(op2)
        return range1.overlaps(range2)
    }

    private func operationRange(_ op: SequenceDiff.DiffOperation) -> Range<Int> {
        switch op {
        case .substitution(let pos, let ref, _):
            return pos..<(pos + ref.count)
        case .insertion(let pos, _):
            return pos..<pos
        case .deletion(let pos, let len, _):
            return pos..<(pos + len)
        case .block(let start, let end, _):
            return start..<end
        }
    }
}

public struct Branch: Codable, Identifiable {
    public let id: String
    public let name: String
    public var headCommitId: String
    public let createdAt: Date

    public init(name: String, headCommitId: String, createdAt: Date) {
        self.id = UUID().uuidString
        self.name = name
        self.headCommitId = headCommitId
        self.createdAt = createdAt
    }
}

public struct MergeResult {
    public let success: Bool
    public let mergedSequence: Sequence?
    public let conflicts: [MergeConflict]
}

public struct MergeConflict {
    public let position: Int
    public let sourceOperation: SequenceDiff.DiffOperation
    public let targetOperations: [SequenceDiff.DiffOperation]
}
```

### History View
```swift
public struct HistoryView: View {
    @ObservedObject var history: VersionHistory
    @State private var selectedCommit: String?

    public var body: some View {
        HSplitView {
            // Timeline
            List(history.commits, id: \.id, selection: $selectedCommit) { commit in
                CommitRow(commit: commit, isCurrent: commit.id == history.currentCommitId)
            }
            .frame(minWidth: 250)

            // Detail view
            if let commitId = selectedCommit,
               let commit = history.commits.first(where: { $0.id == commitId }) {
                CommitDetailView(commit: commit, history: history)
            } else {
                ContentUnavailableView(
                    "Select a Version",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Choose a version from the timeline to view details")
                )
            }
        }
    }
}

public struct CommitRow: View {
    public let commit: Commit
    public let isCurrent: Bool

    public var body: some View {
        HStack {
            Circle()
                .fill(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading) {
                Text(commit.message ?? "No message")
                    .font(.headline)
                    .lineLimit(1)

                HStack {
                    Text(commit.date, style: .relative)
                    Text("•")
                    Text(commit.author)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if isCurrent {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.accentColor)
            }
        }
    }
}

public struct CommitDetailView: View {
    public let commit: Commit
    @ObservedObject var history: VersionHistory
    @State private var diff: SequenceDiff?
    @State private var isLoading = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading) {
                Text(commit.message ?? "No message")
                    .font(.title2)

                HStack {
                    Label(commit.author, systemImage: "person")
                    Label(commit.date.formatted(), systemImage: "calendar")
                    Label(String(commit.id.prefix(8)), systemImage: "number")
                }
                .font(.caption)
            }

            Divider()

            // Diff viewer
            if isLoading {
                ProgressView("Loading changes...")
            } else if let diff = diff {
                DiffViewer(diff: diff)
            } else if commit.parentIds.isEmpty {
                Text("Initial version - no changes to display")
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Actions
            HStack {
                Button("Checkout This Version") {
                    Task {
                        try? await history.checkout(commit.id)
                    }
                }
                .disabled(commit.id == history.currentCommitId)

                Button("Create Branch Here") {
                    Task {
                        try? await history.createBranch("branch-\(Date().timeIntervalSince1970)", from: commit.id)
                    }
                }
            }
        }
        .padding()
        .task {
            await loadDiff()
        }
    }

    private func loadDiff() async {
        guard let parentId = commit.parentIds.first else { return }

        isLoading = true
        defer { isLoading = false }

        diff = try? await history.diff(from: parentId, to: commit.id)
    }
}

public struct DiffViewer: View {
    public let diff: SequenceDiff

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(diff.operationCount) changes")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(Array(diff.operations.enumerated()), id: \.offset) { _, op in
                    DiffOperationRow(operation: op)
                }
            }
        }
    }
}

public struct DiffOperationRow: View {
    public let operation: SequenceDiff.DiffOperation

    public var body: some View {
        HStack {
            operationIcon

            VStack(alignment: .leading) {
                Text(operationDescription)
                    .font(.system(.body, design: .monospaced))

                Text("Position: \(operation.position)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var operationIcon: some View {
        Group {
            switch operation {
            case .substitution:
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(.orange)
            case .insertion:
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.green)
            case .deletion:
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            case .block:
                Image(systemName: "rectangle.stack")
                    .foregroundColor(.purple)
            }
        }
    }

    private var operationDescription: String {
        switch operation {
        case .substitution(_, let ref, let alt):
            return "\(ref) → \(alt)"
        case .insertion(_, let seq):
            return "+ \(seq.prefix(50))\(seq.count > 50 ? "..." : "")"
        case .deletion(_, _, let ref):
            return "- \(ref.prefix(50))\(ref.count > 50 ? "..." : "")"
        case .block(let start, let end, let ops):
            return "Block [\(start)-\(end)]: \(ops.count) operations"
        }
    }
}
```

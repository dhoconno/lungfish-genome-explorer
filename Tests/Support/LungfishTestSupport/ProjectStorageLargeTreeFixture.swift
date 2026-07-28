import CryptoKit
import Darwin
import Foundation
import LungfishIO
import LungfishWorkflow

public struct ProjectStorageHardLinkUnavailableError: Error, Sendable {
    public let code: Int32

    public init(code: Int32) {
        self.code = code
    }

    public var skipReason: String {
        let symbol: String
        if code == EXDEV {
            symbol = "EXDEV"
        } else if code == EOPNOTSUPP {
            symbol = "EOPNOTSUPP"
        } else {
            symbol = "ENOTSUP"
        }
        return "hard-link-unavailable: errno=\(code) (\(symbol))"
    }
}

public struct ProjectStorageLargeTreeFixture: Sendable {
    public enum Profile: Sendable {
        case ciSemantic
        case releaseRepresentative
    }

    public struct Configuration: Sendable, Equatable {
        public let seed: UInt64
        public let candidateCount: Int
        public let ordinaryFileCount: Int
        public let ordinaryFilesPerCandidate: [Int]
        public let withinCandidateHardLinkIdentityCount: Int
        public let withinCandidateHardLinksPerCandidate: [Int]
        public let crossCandidateHardLinkIdentityCount: Int
        public let externalHardLinkIdentityCount: Int
        public let externalHardLinksPerCandidate: [Int]
        public let sparseFileCount: Int
        public let sparseFilesPerCandidate: [Int]
        public let sparseLogicalBytes: Int64
        public let operationHistoryDecoyObjectCount: Int
        public let hardLinkDirectoryEntryCount: Int
    }

    public let profile: Profile
    public let projectURL: URL
    public let candidateURLs: [URL]
    public let survivorURL: URL
    public let historyURL: URL
    public let sparseFileURLs: [URL]

    private let profileConfiguration: Configuration

    public static let ciSemanticConfiguration = Configuration(
        seed: 0x4C554E4746495348,
        candidateCount: 3,
        ordinaryFileCount: 1_536,
        ordinaryFilesPerCandidate: [512, 512, 512],
        withinCandidateHardLinkIdentityCount: 128,
        withinCandidateHardLinksPerCandidate: [43, 43, 42],
        crossCandidateHardLinkIdentityCount: 128,
        externalHardLinkIdentityCount: 128,
        externalHardLinksPerCandidate: [43, 43, 42],
        sparseFileCount: 32,
        sparseFilesPerCandidate: [11, 11, 10],
        sparseLogicalBytes: 64 * 1_024 * 1_024,
        operationHistoryDecoyObjectCount: 2_048,
        hardLinkDirectoryEntryCount: 768
    )

    public static let releaseRepresentativeConfiguration = Configuration(
        seed: 0x4C554E4746495348,
        candidateCount: 8,
        ordinaryFileCount: 32_768,
        ordinaryFilesPerCandidate:
            [4_096, 4_096, 4_096, 4_096, 4_096, 4_096, 4_096, 4_096],
        withinCandidateHardLinkIdentityCount: 682,
        withinCandidateHardLinksPerCandidate:
            [86, 86, 85, 85, 85, 85, 85, 85],
        crossCandidateHardLinkIdentityCount: 683,
        externalHardLinkIdentityCount: 683,
        externalHardLinksPerCandidate:
            [86, 86, 86, 85, 85, 85, 85, 85],
        sparseFileCount: 128,
        sparseFilesPerCandidate:
            [16, 16, 16, 16, 16, 16, 16, 16],
        sparseLogicalBytes: 1_024 * 1_024 * 1_024,
        operationHistoryDecoyObjectCount: 16_384,
        hardLinkDirectoryEntryCount: 4_096
    )

    public static func configuration(
        for profile: Profile
    ) -> Configuration {
        switch profile {
        case .ciSemantic:
            return ciSemanticConfiguration
        case .releaseRepresentative:
            return releaseRepresentativeConfiguration
        }
    }

    public static func createBaseTree(
        profile: Profile,
        at projectURL: URL
    ) throws -> ProjectStorageLargeTreeFixture {
        let configuration = configuration(for: profile)
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        let canonicalProjectURL = projectURL.resolvingSymlinksInPath()
        let temporary = canonicalProjectURL.appendingPathComponent(
            ".tmp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        var candidates: [URL] = []
        var sparseFiles: [URL] = []
        for candidateIndex in 0..<configuration.candidateCount {
            let candidate = temporary.appendingPathComponent(
                String(format: "candidate-%02d", candidateIndex),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: false
            )
            try bindOwnershipMarker(
                to: candidate,
                projectURL: canonicalProjectURL,
                candidateIndex: candidateIndex
            )
            try createOrdinaryFiles(
                count: configuration.ordinaryFilesPerCandidate[
                    candidateIndex
                ],
                candidateIndex: candidateIndex,
                candidateURL: candidate,
                seed: configuration.seed
            )
            let candidateSparse = try createSparseFiles(
                count: configuration.sparseFilesPerCandidate[
                    candidateIndex
                ],
                logicalBytes: configuration.sparseLogicalBytes,
                candidateIndex: candidateIndex,
                candidateURL: candidate
            )
            sparseFiles.append(contentsOf: candidateSparse)
            candidates.append(candidate)
        }
        let survivor = canonicalProjectURL.appendingPathComponent(
            "survivor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: survivor,
            withIntermediateDirectories: false
        )
        try Data("storage-task9-external-sentinel".utf8).write(
            to: survivor.appendingPathComponent("sentinel.bin")
        )
        let history = canonicalProjectURL.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        )
        try createHistoryDecoys(
            count: configuration.operationHistoryDecoyObjectCount,
            at: history,
            seed: configuration.seed
        )
        return .init(
            profile: profile,
            projectURL: canonicalProjectURL,
            candidateURLs: candidates,
            survivorURL: survivor,
            historyURL: history,
            sparseFileURLs: sparseFiles,
            profileConfiguration: configuration
        )
    }

    public func installHardLinkOverlay() throws {
        for candidateIndex in candidateURLs.indices {
            let count = profileConfiguration
                .withinCandidateHardLinksPerCandidate[candidateIndex]
            let directory = candidateURLs[candidateIndex]
                .appendingPathComponent("hard-links", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for localIndex in 0..<count {
                let source = directory.appendingPathComponent(
                    String(
                        format: "within-source-%02d-%04d.bin",
                        candidateIndex,
                        localIndex
                    )
                )
                let destination = directory.appendingPathComponent(
                    String(
                        format: "within-copy-%02d-%04d.bin",
                        candidateIndex,
                        localIndex
                    )
                )
                try writeHardLinkPayload(
                    index: candidateIndex * 10_000 + localIndex,
                    to: source
                )
                try createHardLink(from: source, to: destination)
            }
        }

        for identityIndex in 0..<profileConfiguration
            .crossCandidateHardLinkIdentityCount {
            let sourceIndex = identityIndex % candidateURLs.count
            let destinationIndex = (identityIndex + 1)
                % candidateURLs.count
            let source = candidateURLs[sourceIndex]
                .appendingPathComponent("hard-links", isDirectory: true)
                .appendingPathComponent(
                    String(
                        format: "cross-source-%05d.bin",
                        identityIndex
                    )
                )
            let destination = candidateURLs[destinationIndex]
                .appendingPathComponent("hard-links", isDirectory: true)
                .appendingPathComponent(
                    String(
                        format: "cross-copy-%05d.bin",
                        identityIndex
                    )
                )
            try writeHardLinkPayload(index: 100_000 + identityIndex, to: source)
            try createHardLink(from: source, to: destination)
        }

        var identityIndex = 0
        for candidateIndex in candidateURLs.indices {
            let count = profileConfiguration
                .externalHardLinksPerCandidate[candidateIndex]
            for _ in 0..<count {
                let source = candidateURLs[candidateIndex]
                    .appendingPathComponent(
                        "hard-links",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        String(
                            format: "external-source-%05d.bin",
                            identityIndex
                        )
                    )
                let destination = survivorURL.appendingPathComponent(
                    String(
                        format: "external-survivor-%05d.bin",
                        identityIndex
                    )
                )
                try writeHardLinkPayload(
                    index: 200_000 + identityIndex,
                    to: source
                )
                try createHardLink(from: source, to: destination)
                identityIndex += 1
            }
        }
    }

    private static func bindOwnershipMarker(
        to candidate: URL,
        projectURL: URL,
        candidateIndex: Int
    ) throws {
        let suffix = String(format: "%012d", candidateIndex + 1)
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            candidate,
            request: .init(
                projectURL: projectURL,
                parentDirectoryURL:
                    candidate.deletingLastPathComponent(),
                prefix: "unused-",
                runID: UUID(
                    uuidString:
                        "00000000-0000-0000-0000-\(suffix)"
                )!,
                processIdentity: .init(
                    processIdentifier: 1,
                    processStartTime: 1,
                    bootSessionID: "storage-task9-fixture"
                ),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "storage-task9-fixture",
                toolVersion: "1"
            )
        )
    }

    private static func createOrdinaryFiles(
        count: Int,
        candidateIndex: Int,
        candidateURL: URL,
        seed: UInt64
    ) throws {
        for index in 0..<count {
            let directory = candidateURL
                .appendingPathComponent("ordinary", isDirectory: true)
                .appendingPathComponent(
                    String(format: "l1-%02d", index % 11),
                    isDirectory: true
                )
                .appendingPathComponent(
                    String(format: "l2-%02d", (index / 11) % 7),
                    isDirectory: true
                )
                .appendingPathComponent(
                    String(format: "l3-%02d", (index / 77) % 5),
                    isDirectory: true
                )
                .appendingPathComponent(
                    String(format: "l4-%02d", (index / 385) % 3),
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var value = seed
                &+ UInt64(candidateIndex &* 1_000_003)
                &+ UInt64(index)
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
            let payload = withUnsafeBytes(of: value.bigEndian) {
                Data($0)
            }
            try payload.write(
                to: directory.appendingPathComponent(
                    String(
                        format: "ordinary-%02d-%06d.dat",
                        candidateIndex,
                        index
                    )
                )
            )
        }
    }

    private static func createSparseFiles(
        count: Int,
        logicalBytes: Int64,
        candidateIndex: Int,
        candidateURL: URL
    ) throws -> [URL] {
        let directory = candidateURL.appendingPathComponent(
            "sparse",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        var files: [URL] = []
        for index in 0..<count {
            let file = directory.appendingPathComponent(
                String(
                    format: "sparse-%02d-%04d.bin",
                    candidateIndex,
                    index
                )
            )
            let descriptor = Darwin.open(
                file.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let result = Darwin.ftruncate(descriptor, logicalBytes)
            let savedErrno = errno
            Darwin.close(descriptor)
            guard result == 0 else {
                throw POSIXError(
                    .init(rawValue: savedErrno) ?? .EIO
                )
            }
            files.append(file)
        }
        return files
    }

    private static func createHistoryDecoys(
        count: Int,
        at history: URL,
        seed: UInt64
    ) throws {
        try FileManager.default.createDirectory(
            at: history,
            withIntermediateDirectories: false
        )
        let directoryCount = count / 8
        let fileCount = count - directoryCount
        var directories: [URL] = []
        directories.reserveCapacity(directoryCount)
        for index in 0..<directoryCount {
            let directory = history.appendingPathComponent(
                String(
                    format: "decoy-directory-%06d-%016llx",
                    index,
                    seed &+ UInt64(index)
                ),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            directories.append(directory)
        }
        for index in 0..<fileCount {
            let parent = directories[index % directories.count]
            let value = seed
                &+ UInt64(index &* 0x9E37)
            try Data(String(format: "%016llx", value).utf8).write(
                to: parent.appendingPathComponent(
                    String(
                        format: "decoy-file-%06d-%016llx",
                        index,
                        value
                    )
                )
            )
        }
    }

    private func writeHardLinkPayload(
        index: Int,
        to url: URL
    ) throws {
        var value = profileConfiguration.seed &+ UInt64(index)
        var payload = Data()
        for _ in 0..<512 {
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
            withUnsafeBytes(of: value.bigEndian) {
                payload.append(contentsOf: $0)
            }
        }
        try payload.write(to: url)
    }

    private func createHardLink(
        from source: URL,
        to destination: URL
    ) throws {
        guard Darwin.link(source.path, destination.path) == 0 else {
            let code = errno
            if code == EOPNOTSUPP || code == ENOTSUP || code == EXDEV {
                throw ProjectStorageHardLinkUnavailableError(code: code)
            }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
    }
}

public enum ProjectStorageFixtureOracle {
    public struct FileIdentity: Hashable, Sendable, Equatable {
        public let device: UInt64
        public let inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    public struct RootRecord: Sendable, Equatable {
        public let identity: FileIdentity
        public let logicalSize: UInt64
        public let allocatedSize: UInt64
        public let modificationSeconds: Int64
        public let modificationNanoseconds: Int64
        public let changeSeconds: Int64
        public let changeNanoseconds: Int64
    }

    public struct ExternalSentinel: Sendable, Equatable {
        public let identity: FileIdentity
        public let logicalSize: UInt64
        public let allocatedSize: UInt64
        public let sha256: String
    }

    public struct TreeRecord: Sendable, Equatable {
        public let identity: FileIdentity
        public let logicalSize: UInt64
        public let allocatedSize: UInt64
        public let linkCount: Int
        public let isRegular: Bool
    }

    public struct FileSystemRecord: Sendable, Equatable {
        public let typeName: String
        public let blockSize: UInt64
    }

    public struct HardLinkTopology: Sendable, Equatable {
        public let candidateIndices: [Int]
        public let candidateOccurrences: Int
        public let survivorOccurrences: Int
        public let linkCount: Int
        public let occurrenceRelativePaths: [String]
    }

    public struct Snapshot: Sendable {
        public let visitedObjects: UInt64
        public let candidateRelativePaths: [String]
        public let ordinaryFileCount: Int
        public let ordinaryFilesPerCandidate: [Int]
        public let sparseFileCount: Int
        public let sparseFilesPerCandidate: [Int]
        public let withinCandidateHardLinkIdentityCount: Int
        public let withinCandidateHardLinksPerCandidate: [Int]
        public let crossCandidateHardLinkIdentityCount: Int
        public let externalHardLinkIdentityCount: Int
        public let externalHardLinksPerCandidate: [Int]
        public let hardLinkDirectoryEntryCount: Int
        public let operationHistoryDescendantCount: Int
        public let maximumCandidateDepth: Int
        public let candidateLogicalBytes: UInt64
        public let candidateReclaimableAllocatedBytes: UInt64
        public let candidateAllocatedBytesWithoutSurvivorExclusion: UInt64
        public let identityMultiplicities: [FileIdentity: Int]
        public let hardLinkTopologies: [FileIdentity: HardLinkTopology]
        public let treeRecords: [String: TreeRecord]
        public let externalSentinels: [String: ExternalSentinel]
        public let sparseFileIdentities: [String: FileIdentity]
        public let candidateRootRecords: [String: RootRecord]
        public let fileSystem: FileSystemRecord
    }

    private struct EntryRecord {
        let path: String
        let candidateIndex: Int?
        let identity: FileIdentity
        let logicalSize: UInt64
        let allocatedSize: UInt64
        let linkCount: Int
        let isRegular: Bool
    }

    public static func inspect(projectURL: URL) throws -> Snapshot {
        let project = projectURL.resolvingSymlinksInPath()
        var visited: UInt64 = 0
        var candidates: [URL] = []
        var survivorRecords: [EntryRecord] = []
        guard let discovery = FileManager.default.enumerator(
            at: project,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let url = discovery.nextObject() as? URL {
            visited += 1
            let relative = relativePath(project, url)
            if relative
                == ProjectOperationHistoryWriter.historyDirectoryName
                || relative.hasPrefix(
                    ProjectOperationHistoryWriter.historyDirectoryName + "/"
                ) {
                discovery.skipDescendants()
                continue
            }
            var information = stat()
            guard Darwin.lstat(url.path, &information) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if information.st_mode & S_IFMT == S_IFDIR,
               try hasDurableOwnershipMarker(
                    candidateURL: url,
                    projectURL: project
               ) {
                candidates.append(url)
                discovery.skipDescendants()
                continue
            }
            if information.st_mode & S_IFMT == S_IFREG,
               information.st_nlink > 1
                    || relative == "survivor/sentinel.bin" {
                survivorRecords.append(
                    try entryRecord(
                        url,
                        relativePath: relative,
                        candidateIndex: nil
                    )
                )
            }
        }
        candidates.sort {
            relativePath(project, $0) < relativePath(project, $1)
        }

        var records: [EntryRecord] = []
        var roots: [String: RootRecord] = [:]
        var maximumDepth = 0
        for (candidateIndex, candidate) in candidates.enumerated() {
            let candidateRelative = relativePath(project, candidate)
            let rootRecord = try entryRecord(
                candidate,
                relativePath: candidateRelative,
                candidateIndex: candidateIndex
            )
            records.append(rootRecord)
            roots[candidateRelative] = try rootSnapshot(candidate)
            guard let enumeration = FileManager.default.enumerator(
                at: candidate,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            while let url = enumeration.nextObject() as? URL {
                visited += 1
                let relativeToCandidate = relativePath(candidate, url)
                maximumDepth = max(
                    maximumDepth,
                    relativeToCandidate.split(separator: "/").count
                )
                records.append(
                    try entryRecord(
                        url,
                        relativePath: relativeToCandidate,
                        candidateIndex: candidateIndex
                    )
                )
            }
        }

        let candidatePaths = candidates.map { relativePath(project, $0) }
        let sparse = records.filter {
            $0.isRegular
                && $0.linkCount == 1
                && $0.logicalSize >= 64 * 1_024 * 1_024
                && $0.allocatedSize < $0.logicalSize
        }
        let sparseIdentitiesSet = Set(sparse.map(\.identity))
        let ordinary = records.filter {
            $0.isRegular
                && $0.linkCount == 1
                && !sparseIdentitiesSet.contains($0.identity)
                && !$0.path.hasSuffix(OwnedWorkDirectoryMarker.fileName)
        }
        let candidateLinks = records.filter {
            $0.isRegular && $0.linkCount > 1
        }
        let survivorLinks = survivorRecords.filter {
            $0.isRegular && $0.linkCount > 1
        }
        let allLinks = candidateLinks + survivorLinks
        let identityMultiplicities = Dictionary(
            (records + survivorRecords).map { ($0.identity, 1) },
            uniquingKeysWith: +
        )
        let linkGroups = Dictionary(grouping: allLinks, by: \.identity)
        let hardLinkTopologies = linkGroups.mapValues { group in
            HardLinkTopology(
                candidateIndices: Set(
                    group.compactMap(\.candidateIndex)
                ).sorted(),
                candidateOccurrences: group.filter {
                    $0.candidateIndex != nil
                }.count,
                survivorOccurrences: group.filter {
                    $0.candidateIndex == nil
                }.count,
                linkCount: group[0].linkCount,
                occurrenceRelativePaths: group.map { record in
                    guard let index = record.candidateIndex else {
                        return record.path
                    }
                    let candidatePath = candidatePaths[index]
                    return record.path == candidatePath
                        ? candidatePath
                        : candidatePath + "/" + record.path
                }.sorted()
            )
        }
        let withinIdentities = Set(
            hardLinkTopologies.compactMap { identity, topology in
                topology.candidateIndices.count == 1
                    && topology.candidateOccurrences == 2
                    && topology.survivorOccurrences == 0
                    ? identity : nil
            }
        )
        let crossIdentities = Set(
            hardLinkTopologies.compactMap { identity, topology in
                topology.candidateIndices.count == 2
                    && topology.candidateOccurrences == 2
                    && topology.survivorOccurrences == 0
                    ? identity : nil
            }
        )
        let externalIdentities = Set(
            hardLinkTopologies.compactMap { identity, topology in
                topology.candidateIndices.count == 1
                    && topology.candidateOccurrences == 1
                    && topology.survivorOccurrences == 1
                    ? identity : nil
            }
        )
        let candidateMultiplicity = Dictionary(
            candidateLinks.map { ($0.identity, 1) },
            uniquingKeysWith: +
        )

        var reclaimableAllocated: UInt64 = 0
        var allocatedWithoutExclusion: UInt64 = 0
        var seenHardLinks: Set<FileIdentity> = []
        for record in records {
            if record.isRegular && record.linkCount > 1 {
                guard seenHardLinks.insert(record.identity).inserted else {
                    continue
                }
                allocatedWithoutExclusion += record.allocatedSize
                if candidateMultiplicity[record.identity] == record.linkCount {
                    reclaimableAllocated += record.allocatedSize
                }
            } else {
                reclaimableAllocated += record.allocatedSize
                allocatedWithoutExclusion += record.allocatedSize
            }
        }

        let history = project.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        )
        let historyCount = try descendantCount(history)
        var sentinelRecords: [String: ExternalSentinel] = [:]
        for record in survivorRecords
        where record.path == "survivor/sentinel.bin" {
            let url = project.appendingPathComponent(record.path)
            sentinelRecords[record.path] = .init(
                identity: record.identity,
                logicalSize: record.logicalSize,
                allocatedSize: record.allocatedSize,
                sha256: try independentSHA256(of: url)
            )
        }
        let sparseIdentities = Dictionary(
            uniqueKeysWithValues: sparse.map { record in
                let candidate = candidates[
                    record.candidateIndex!
                ]
                return (
                    canonicalPlatformPath(
                        candidate.appendingPathComponent(record.path).path
                    ),
                    record.identity
                )
            }
        )
        let fileSystem = try fileSystemRecord(project)
        var treeRecords: [String: TreeRecord] = [:]
        for record in records {
            let path: String
            if let index = record.candidateIndex {
                let candidatePath = candidatePaths[index]
                path = record.path == candidatePath
                    ? candidatePath
                    : candidatePath + "/" + record.path
            } else {
                path = record.path
            }
            treeRecords[path] = .init(
                identity: record.identity,
                logicalSize: record.logicalSize,
                allocatedSize: record.allocatedSize,
                linkCount: record.linkCount,
                isRegular: record.isRegular
            )
        }
        for record in survivorRecords {
            treeRecords[record.path] = .init(
                identity: record.identity,
                logicalSize: record.logicalSize,
                allocatedSize: record.allocatedSize,
                linkCount: record.linkCount,
                isRegular: record.isRegular
            )
        }

        return .init(
            visitedObjects: visited,
            candidateRelativePaths: candidatePaths,
            ordinaryFileCount: ordinary.count,
            ordinaryFilesPerCandidate: countsPerCandidate(
                ordinary,
                candidateCount: candidates.count
            ),
            sparseFileCount: sparse.count,
            sparseFilesPerCandidate: countsPerCandidate(
                sparse,
                candidateCount: candidates.count
            ),
            withinCandidateHardLinkIdentityCount: withinIdentities.count,
            withinCandidateHardLinksPerCandidate: countsPerCandidate(
                identityRepresentatives(
                    candidateLinks.filter {
                        withinIdentities.contains($0.identity)
                    }
                ),
                candidateCount: candidates.count
            ),
            crossCandidateHardLinkIdentityCount: crossIdentities.count,
            externalHardLinkIdentityCount: externalIdentities.count,
            externalHardLinksPerCandidate: countsPerCandidate(
                candidateLinks.filter {
                    externalIdentities.contains($0.identity)
                },
                candidateCount: candidates.count
            ),
            hardLinkDirectoryEntryCount: allLinks.count,
            operationHistoryDescendantCount: historyCount,
            maximumCandidateDepth: maximumDepth,
            candidateLogicalBytes:
                records.reduce(0) { $0 + $1.logicalSize },
            candidateReclaimableAllocatedBytes: reclaimableAllocated,
            candidateAllocatedBytesWithoutSurvivorExclusion:
                allocatedWithoutExclusion,
            identityMultiplicities: identityMultiplicities,
            hardLinkTopologies: hardLinkTopologies,
            treeRecords: treeRecords,
            externalSentinels: sentinelRecords,
            sparseFileIdentities: sparseIdentities,
            candidateRootRecords: roots,
            fileSystem: fileSystem
        )
    }

    private static func entryRecord(
        _ url: URL,
        relativePath: String,
        candidateIndex: Int?
    ) throws -> EntryRecord {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0,
              information.st_size >= 0,
              information.st_blocks >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return .init(
            path: relativePath,
            candidateIndex: candidateIndex,
            identity: .init(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino)
            ),
            logicalSize: UInt64(information.st_size),
            allocatedSize: UInt64(information.st_blocks) * 512,
            linkCount: Int(information.st_nlink),
            isRegular: information.st_mode & S_IFMT == S_IFREG
        )
    }

    private static func hasDurableOwnershipMarker(
        candidateURL: URL,
        projectURL: URL
    ) throws -> Bool {
        let markerURL = candidateURL.appendingPathComponent(
            OwnedWorkDirectoryMarker.fileName
        )
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(
                OwnedWorkDirectoryMarker.self,
                from: data
              ),
              marker.state != .active,
              marker.projectIdentity
                == (try? FileSystemObjectIdentity.noFollow(projectURL)),
              marker.directoryIdentity
                == (try? FileSystemObjectIdentity.noFollow(candidateURL))
        else {
            return false
        }
        return true
    }

    private static func independentSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func rootSnapshot(_ url: URL) throws -> RootRecord {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return .init(
            identity: .init(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino)
            ),
            logicalSize: UInt64(max(information.st_size, 0)),
            allocatedSize: UInt64(max(information.st_blocks, 0)) * 512,
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds:
                Int64(information.st_mtimespec.tv_nsec),
            changeSeconds: Int64(information.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private static func descendantCount(_ root: URL) throws -> Int {
        guard let enumeration = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var count = 0
        while enumeration.nextObject() != nil {
            count += 1
        }
        return count
    }

    private static func countsPerCandidate(
        _ records: [EntryRecord],
        candidateCount: Int
    ) -> [Int] {
        var counts = Array(repeating: 0, count: candidateCount)
        for record in records {
            if let index = record.candidateIndex {
                counts[index] += 1
            }
        }
        return counts
    }

    private static func identityRepresentatives(
        _ records: [EntryRecord]
    ) -> [EntryRecord] {
        var seen: Set<FileIdentity> = []
        return records.filter { seen.insert($0.identity).inserted }
    }

    private static func fileSystemRecord(
        _ url: URL
    ) throws -> FileSystemRecord {
        var information = statfs()
        let result = url.path.withCString {
            statfs($0, &information)
        }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let typeName = withUnsafeBytes(of: information.f_fstypename) {
            bytes -> String in
            let prefix = bytes.prefix { $0 != 0 }
            return String(decoding: prefix, as: UTF8.self)
        }
        return .init(
            typeName: typeName,
            blockSize: UInt64(information.f_bsize)
        )
    }

    private static func relativePath(
        _ root: URL,
        _ child: URL
    ) -> String {
        let rootPath = canonicalPlatformPath(root.path)
        let childPath = canonicalPlatformPath(child.path)
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private static func canonicalPlatformPath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized == "/var" || standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        if standardized == "/tmp" || standardized.hasPrefix("/tmp/") {
            return "/private" + standardized
        }
        return standardized
    }
}

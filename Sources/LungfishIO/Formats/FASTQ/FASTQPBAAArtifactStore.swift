// FASTQPBAAArtifactStore.swift - Durable pbAA cluster artifacts carried by FASTQ bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public struct FASTQPBAAFileFingerprint: Codable, Equatable, Sendable {
    public let displayPath: String
    public let checksumSHA256: String
    public let fileSize: UInt64
    public let fileCount: Int

    public init(
        displayPath: String,
        checksumSHA256: String,
        fileSize: UInt64,
        fileCount: Int = 1
    ) {
        self.displayPath = displayPath
        self.checksumSHA256 = checksumSHA256
        self.fileSize = fileSize
        self.fileCount = max(1, fileCount)
    }

    public func hasSameContent(as other: FASTQPBAAFileFingerprint) -> Bool {
        checksumSHA256 == other.checksumSHA256
            && fileSize == other.fileSize
            && fileCount == other.fileCount
    }

    public static func fingerprint(url: URL, displayPath: String? = nil) throws -> FASTQPBAAFileFingerprint {
        let standardizedURL = url.standardizedFileURL
        let shownPath = displayPath ?? standardizedURL.path
        if isDirectory(standardizedURL) {
            let payloadURLs = sequencePayloadURLs(for: standardizedURL)
            guard !payloadURLs.isEmpty else {
                return try directoryFingerprint(url: standardizedURL, displayPath: shownPath)
            }
            return try aggregateFingerprint(
                urls: payloadURLs,
                rootURL: standardizedURL,
                displayPath: shownPath
            )
        }
        return FASTQPBAAFileFingerprint(
            displayPath: shownPath,
            checksumSHA256: try sha256(of: standardizedURL),
            fileSize: try fileSize(of: standardizedURL),
            fileCount: 1
        )
    }

    private static func sequencePayloadURLs(for url: URL) -> [URL] {
        if FASTQBundle.isBundleURL(url) {
            if let urls = FASTQBundle.resolveAllFASTQURLs(for: url), !urls.isEmpty {
                return urls.map(\.standardizedFileURL).sorted { $0.path < $1.path }
            }
            if let sequenceURL = FASTQBundle.resolvePrimarySequenceURL(for: url) {
                return [sequenceURL.standardizedFileURL]
            }
        }
        if let sequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: url) {
            return [sequenceURL.standardizedFileURL]
        }
        return []
    }

    private static func directoryFingerprint(url: URL, displayPath: String) throws -> FASTQPBAAFileFingerprint {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FASTQPBAAArtifactStoreError.notDirectory(url.path)
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = relativePath(from: url, to: fileURL)
            guard !relative.hasPrefix("artifacts/pbaa-clusters/") else { continue }
            files.append(fileURL.standardizedFileURL)
        }
        return try aggregateFingerprint(urls: files, rootURL: url, displayPath: displayPath)
    }

    private static func aggregateFingerprint(
        urls: [URL],
        rootURL: URL,
        displayPath: String
    ) throws -> FASTQPBAAFileFingerprint {
        let sorted = urls.map(\.standardizedFileURL).sorted { $0.path < $1.path }
        if sorted.count == 1 {
            return FASTQPBAAFileFingerprint(
                displayPath: displayPath,
                checksumSHA256: try sha256(of: sorted[0]),
                fileSize: try fileSize(of: sorted[0]),
                fileCount: 1
            )
        }

        var manifestLines: [String] = []
        var totalSize: UInt64 = 0
        for fileURL in sorted {
            let size = try fileSize(of: fileURL)
            totalSize += size
            manifestLines.append([
                relativePath(from: rootURL, to: fileURL),
                try sha256(of: fileURL),
                String(size),
            ].joined(separator: "\t"))
        }
        let digest = sha256(of: Data((manifestLines.joined(separator: "\n") + "\n").utf8))
        return FASTQPBAAFileFingerprint(
            displayPath: displayPath,
            checksumSHA256: digest,
            fileSize: totalSize,
            fileCount: max(1, sorted.count)
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1_048_576)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.seekToEnd()
    }
}

public struct FASTQPBAAPreprocessingSignature: Codable, Equatable, Sendable {
    public let orientReference: FASTQPBAAFileFingerprint?
    public let forwardPrimer: FASTQPBAAFileFingerprint?
    public let reversePrimer: FASTQPBAAFileFingerprint?
    public let minimumLength: Int
    public let maximumLength: Int

    public init(
        orientReference: FASTQPBAAFileFingerprint?,
        forwardPrimer: FASTQPBAAFileFingerprint?,
        reversePrimer: FASTQPBAAFileFingerprint?,
        minimumLength: Int,
        maximumLength: Int
    ) {
        self.orientReference = orientReference
        self.forwardPrimer = forwardPrimer
        self.reversePrimer = reversePrimer
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
    }

    public func hasSameContent(as other: FASTQPBAAPreprocessingSignature) -> Bool {
        optionalFingerprint(orientReference, hasSameContentAs: other.orientReference)
            && optionalFingerprint(forwardPrimer, hasSameContentAs: other.forwardPrimer)
            && optionalFingerprint(reversePrimer, hasSameContentAs: other.reversePrimer)
            && minimumLength == other.minimumLength
            && maximumLength == other.maximumLength
    }

    private func optionalFingerprint(
        _ lhs: FASTQPBAAFileFingerprint?,
        hasSameContentAs rhs: FASTQPBAAFileFingerprint?
    ) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.hasSameContent(as: rhs)
        default:
            return false
        }
    }
}

public struct FASTQPBAAClusteringSignature: Codable, Equatable, Sendable {
    public let pbaaToolVersion: String
    public let workflowSchemaVersion: String
    public let seed: Int
    public let extraArguments: [String]
    public let extraArgumentsText: String
    public let pbaaContainerReference: String
    public let pbaaContainerExpectedDigest: String
    public let samtoolsContainerReference: String
    public let samtoolsContainerExpectedDigest: String

    public init(
        pbaaToolVersion: String,
        workflowSchemaVersion: String,
        seed: Int,
        extraArguments: [String],
        extraArgumentsText: String,
        pbaaContainerReference: String,
        pbaaContainerExpectedDigest: String,
        samtoolsContainerReference: String,
        samtoolsContainerExpectedDigest: String
    ) {
        self.pbaaToolVersion = pbaaToolVersion
        self.workflowSchemaVersion = workflowSchemaVersion
        self.seed = seed
        self.extraArguments = extraArguments
        self.extraArgumentsText = extraArgumentsText
        self.pbaaContainerReference = pbaaContainerReference
        self.pbaaContainerExpectedDigest = pbaaContainerExpectedDigest
        self.samtoolsContainerReference = samtoolsContainerReference
        self.samtoolsContainerExpectedDigest = samtoolsContainerExpectedDigest
    }
}

public struct FASTQPBAAArtifactSignature: Codable, Equatable, Sendable {
    public let sourceFASTQ: FASTQPBAAFileFingerprint
    public let preparedReads: FASTQPBAAFileFingerprint
    public let guide: FASTQPBAAFileFingerprint
    public let preprocessing: FASTQPBAAPreprocessingSignature
    public let clustering: FASTQPBAAClusteringSignature

    public init(
        sourceFASTQ: FASTQPBAAFileFingerprint,
        preparedReads: FASTQPBAAFileFingerprint,
        guide: FASTQPBAAFileFingerprint,
        preprocessing: FASTQPBAAPreprocessingSignature,
        clustering: FASTQPBAAClusteringSignature
    ) {
        self.sourceFASTQ = sourceFASTQ
        self.preparedReads = preparedReads
        self.guide = guide
        self.preprocessing = preprocessing
        self.clustering = clustering
    }
}

public struct FASTQPBAAArtifactFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let checksumSHA256: String
    public let fileSize: UInt64

    public init(relativePath: String, checksumSHA256: String, fileSize: UInt64) {
        self.relativePath = relativePath
        self.checksumSHA256 = checksumSHA256
        self.fileSize = fileSize
    }
}

public struct FASTQPBAAArtifactManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = "fastq-pbaa-artifact/1"

    public let schemaVersion: String
    public let id: String
    public let displayName: String
    public let sampleName: String
    public let createdAt: Date
    public let signature: FASTQPBAAArtifactSignature
    public let passedConsensusFASTARelativePath: String
    public let provenanceRelativePath: String
    public let rawOutputDirectoryRelativePath: String?
    public let clusterCount: Int
    public let clusteredReadCount: Int
    public let files: [FASTQPBAAArtifactFile]

    public init(
        schemaVersion: String = Self.schemaVersion,
        id: String,
        displayName: String,
        sampleName: String,
        createdAt: Date,
        signature: FASTQPBAAArtifactSignature,
        passedConsensusFASTARelativePath: String,
        provenanceRelativePath: String,
        rawOutputDirectoryRelativePath: String?,
        clusterCount: Int,
        clusteredReadCount: Int,
        files: [FASTQPBAAArtifactFile]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.sampleName = sampleName
        self.createdAt = createdAt
        self.signature = signature
        self.passedConsensusFASTARelativePath = passedConsensusFASTARelativePath
        self.provenanceRelativePath = provenanceRelativePath
        self.rawOutputDirectoryRelativePath = rawOutputDirectoryRelativePath
        self.clusterCount = clusterCount
        self.clusteredReadCount = clusteredReadCount
        self.files = files
    }
}

public struct FASTQPBAAArtifactWriteRequest: Sendable {
    public let bundleURL: URL
    public let id: String?
    public let displayName: String
    public let sampleName: String
    public let signature: FASTQPBAAArtifactSignature
    public let passedConsensusFASTAURL: URL
    public let rawOutputDirectoryURL: URL?
    public let provenanceURL: URL
    public let createdAt: Date

    public init(
        bundleURL: URL,
        id: String? = nil,
        displayName: String,
        sampleName: String,
        signature: FASTQPBAAArtifactSignature,
        passedConsensusFASTAURL: URL,
        rawOutputDirectoryURL: URL?,
        provenanceURL: URL,
        createdAt: Date = Date()
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.id = id
        self.displayName = displayName
        self.sampleName = sampleName
        self.signature = signature
        self.passedConsensusFASTAURL = passedConsensusFASTAURL.standardizedFileURL
        self.rawOutputDirectoryURL = rawOutputDirectoryURL?.standardizedFileURL
        self.provenanceURL = provenanceURL.standardizedFileURL
        self.createdAt = createdAt
    }
}

public struct FASTQPBAAStoredArtifact: Equatable, Sendable {
    public let manifest: FASTQPBAAArtifactManifest
    public let artifactDirectoryURL: URL
    public let manifestURL: URL
    public let passedConsensusFASTAURL: URL
    public let provenanceURL: URL
    public let rawOutputDirectoryURL: URL?

    public init(
        manifest: FASTQPBAAArtifactManifest,
        artifactDirectoryURL: URL
    ) {
        self.manifest = manifest
        self.artifactDirectoryURL = artifactDirectoryURL.standardizedFileURL
        self.manifestURL = artifactDirectoryURL
            .appendingPathComponent(FASTQPBAAArtifactStore.manifestFilename)
            .standardizedFileURL
        self.passedConsensusFASTAURL = artifactDirectoryURL
            .appendingPathComponent(manifest.passedConsensusFASTARelativePath)
            .standardizedFileURL
        self.provenanceURL = artifactDirectoryURL
            .appendingPathComponent(manifest.provenanceRelativePath)
            .standardizedFileURL
        self.rawOutputDirectoryURL = manifest.rawOutputDirectoryRelativePath.map {
            artifactDirectoryURL.appendingPathComponent($0, isDirectory: true).standardizedFileURL
        }
    }
}

public enum FASTQPBAAArtifactCompatibility: String, Codable, Equatable, Sendable {
    case compatible
    case differentGuide
    case staleFASTQ
    case differentPreprocessing
    case differentPBAASettings
    case missingProvenance
    case missingFiles
    case checksumMismatch
    case unsupportedSchema

    public var isReusable: Bool { self == .compatible }
}

public enum FASTQPBAAArtifactStoreError: Error, LocalizedError, Equatable, Sendable {
    case notFASTQBundle(String)
    case notDirectory(String)
    case missingFile(String)
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case .notFASTQBundle(let path):
            return "pbAA artifacts can only be saved inside .lungfishfastq bundles: \(path)"
        case .notDirectory(let path):
            return "Expected a directory: \(path)"
        case .missingFile(let path):
            return "Missing pbAA artifact file: \(path)"
        case .invalidManifest(let path):
            return "Invalid pbAA artifact manifest: \(path)"
        }
    }
}

public enum FASTQPBAAArtifactStore {
    public static let artifactsDirectoryName = "artifacts"
    public static let pbaaClustersDirectoryName = "pbaa-clusters"
    public static let manifestFilename = "pbaa-artifact.json"
    public static let passedConsensusFASTAFilename = "passed_cluster_sequences.fasta"
    public static let provenanceFilename = "pbaa-clustering-provenance.json"
    public static let rawOutputDirectoryName = "raw-pbaa"

    public static func artifactRootURL(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent(artifactsDirectoryName, isDirectory: true)
            .appendingPathComponent(pbaaClustersDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    public static func artifacts(in bundleURL: URL) throws -> [FASTQPBAAStoredArtifact] {
        let root = artifactRootURL(in: bundleURL)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try contents.compactMap { url -> FASTQPBAAStoredArtifact? in
            guard isDirectory(url) else { return nil }
            let manifestURL = url.appendingPathComponent(manifestFilename)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(FASTQPBAAArtifactManifest.self, from: data)
            return FASTQPBAAStoredArtifact(manifest: manifest, artifactDirectoryURL: url)
        }
        .sorted { lhs, rhs in
            if lhs.manifest.createdAt != rhs.manifest.createdAt {
                return lhs.manifest.createdAt > rhs.manifest.createdAt
            }
            return lhs.manifest.id.localizedStandardCompare(rhs.manifest.id) == .orderedAscending
        }
    }

    @discardableResult
    public static func saveArtifact(_ request: FASTQPBAAArtifactWriteRequest) throws -> FASTQPBAAStoredArtifact {
        guard FASTQBundle.isBundleURL(request.bundleURL) else {
            throw FASTQPBAAArtifactStoreError.notFASTQBundle(request.bundleURL.path)
        }
        let id = sanitizedIdentifier(request.id ?? "\(request.sampleName)-\(UUID().uuidString)")
        let root = artifactRootURL(in: request.bundleURL)
        let artifactDirectory = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: artifactDirectory.path) {
            try FileManager.default.removeItem(at: artifactDirectory)
        }
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        let passedURL = artifactDirectory.appendingPathComponent(passedConsensusFASTAFilename)
        try copyReplacingItem(at: request.passedConsensusFASTAURL, to: passedURL)
        let provenanceURL = artifactDirectory.appendingPathComponent(provenanceFilename)
        try copyReplacingItem(at: request.provenanceURL, to: provenanceURL)

        let rawOutputRelativePath: String?
        if let rawOutputDirectoryURL = request.rawOutputDirectoryURL {
            let copiedRaw = artifactDirectory.appendingPathComponent(rawOutputDirectoryName, isDirectory: true)
            try copyReplacingItem(at: rawOutputDirectoryURL, to: copiedRaw)
            rawOutputRelativePath = rawOutputDirectoryName
        } else {
            rawOutputRelativePath = nil
        }

        let counts = try fastaClusterCounts(in: passedURL)
        let files = try artifactFiles(in: artifactDirectory)
        let manifest = FASTQPBAAArtifactManifest(
            id: id,
            displayName: request.displayName,
            sampleName: request.sampleName,
            createdAt: request.createdAt,
            signature: request.signature,
            passedConsensusFASTARelativePath: passedConsensusFASTAFilename,
            provenanceRelativePath: provenanceFilename,
            rawOutputDirectoryRelativePath: rawOutputRelativePath,
            clusterCount: counts.clusterCount,
            clusteredReadCount: counts.clusteredReadCount,
            files: files
        )
        try writeManifest(manifest, to: artifactDirectory)
        return FASTQPBAAStoredArtifact(manifest: manifest, artifactDirectoryURL: artifactDirectory)
    }

    public static func compatibleArtifacts(
        in bundleURL: URL,
        matching signature: FASTQPBAAArtifactSignature
    ) throws -> [FASTQPBAAStoredArtifact] {
        try artifacts(in: bundleURL).filter {
            try compatibility(of: $0, matching: signature) == .compatible
        }
    }

    public static func compatibility(
        of artifact: FASTQPBAAStoredArtifact,
        matching signature: FASTQPBAAArtifactSignature
    ) throws -> FASTQPBAAArtifactCompatibility {
        guard artifact.manifest.schemaVersion == FASTQPBAAArtifactManifest.schemaVersion else {
            return .unsupportedSchema
        }
        guard FileManager.default.fileExists(atPath: artifact.provenanceURL.path) else {
            return .missingProvenance
        }
        guard FileManager.default.fileExists(atPath: artifact.passedConsensusFASTAURL.path) else {
            return .missingFiles
        }
        for file in artifact.manifest.files {
            let url = artifact.artifactDirectoryURL.appendingPathComponent(file.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return file.relativePath == artifact.manifest.provenanceRelativePath ? .missingProvenance : .missingFiles
            }
            let observedSize = try FASTQPBAAFileFingerprint.fileSize(ofRegularFile: url)
            let observedHash = try FASTQPBAAFileFingerprint.sha256OfRegularFile(url)
            guard observedSize == file.fileSize, observedHash == file.checksumSHA256 else {
                return .checksumMismatch
            }
        }

        if !artifact.manifest.signature.sourceFASTQ.hasSameContent(as: signature.sourceFASTQ) {
            return .staleFASTQ
        }
        if !artifact.manifest.signature.guide.hasSameContent(as: signature.guide) {
            return .differentGuide
        }
        if !artifact.manifest.signature.preprocessing.hasSameContent(as: signature.preprocessing)
            || !artifact.manifest.signature.preparedReads.hasSameContent(as: signature.preparedReads) {
            return .differentPreprocessing
        }
        if artifact.manifest.signature.clustering != signature.clustering {
            return .differentPBAASettings
        }
        return .compatible
    }

    private static func writeManifest(
        _ manifest: FASTQPBAAArtifactManifest,
        to artifactDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: artifactDirectory.appendingPathComponent(manifestFilename),
            options: .atomic
        )
    }

    private static func artifactFiles(in artifactDirectory: URL) throws -> [FASTQPBAAArtifactFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: artifactDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FASTQPBAAArtifactStoreError.notDirectory(artifactDirectory.path)
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard url.lastPathComponent != manifestFilename else { continue }
            urls.append(url.standardizedFileURL)
        }
        return try urls.sorted { $0.path < $1.path }.map { url in
            FASTQPBAAArtifactFile(
                relativePath: relativePath(from: artifactDirectory, to: url),
                checksumSHA256: try FASTQPBAAFileFingerprint.sha256OfRegularFile(url),
                fileSize: try FASTQPBAAFileFingerprint.fileSize(ofRegularFile: url)
            )
        }
    }

    private static func fastaClusterCounts(in fastaURL: URL) throws -> (clusterCount: Int, clusteredReadCount: Int) {
        let text = try String(contentsOf: fastaURL, encoding: .utf8)
        var clusterCount = 0
        var readCount = 0
        for line in text.split(separator: "\n") where line.hasPrefix(">") {
            clusterCount += 1
            readCount += parsedReadCount(from: String(line.dropFirst()))
        }
        return (clusterCount, readCount)
    }

    private static func parsedReadCount(from header: String) -> Int {
        let patterns = ["ReadCount-", "readCount=", "read_count=", "reads="]
        for pattern in patterns {
            guard let range = header.range(of: pattern) else { continue }
            let suffix = header[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let value = Int(digits) {
                return value
            }
        }
        return 0
    }

    private static func copyReplacingItem(at sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? UUID().uuidString : collapsed
    }
}

private extension FASTQPBAAFileFingerprint {
    static func sha256OfRegularFile(_ url: URL) throws -> String {
        try sha256(of: url)
    }

    static func fileSize(ofRegularFile url: URL) throws -> UInt64 {
        try fileSize(of: url)
    }
}

private func relativePath(from rootURL: URL, to targetURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    let targetPath = targetURL.standardizedFileURL.path
    guard targetPath.hasPrefix(normalizedRoot) else {
        return targetURL.lastPathComponent
    }
    return String(targetPath.dropFirst(normalizedRoot.count))
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

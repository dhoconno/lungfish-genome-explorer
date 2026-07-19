import Darwin
import Foundation
import LungfishIO

struct FullLengthONTMHCAlignmentPathContext: Sendable {
    let outputDirectoryURL: URL
    let workDirectoryURL: URL
    let artifactsDirectoryURL: URL
    let alignmentDirectoryURL: URL
    let outputDirectoryIdentity: FullLengthONTMHCPathIdentity
    let workDirectoryIdentity: FullLengthONTMHCPathIdentity
    let artifactsDirectoryIdentity: FullLengthONTMHCPathIdentity
}

struct FullLengthONTMHCPublicationPathIdentityContext: Sendable {
    let stagingDirectoryIdentity: FullLengthONTMHCPathIdentity
}

struct FullLengthONTMHCPathIdentity: Sendable, Equatable {
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64
    let type: mode_t
}

struct FullLengthONTMHCAlignmentSafety: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepareDirectories(
        outputDirectoryURL: URL,
        workDirectoryURL: URL
    ) throws -> FullLengthONTMHCAlignmentPathContext {
        try requireDirectoryNoFollow(workDirectoryURL, role: "work directory")
        try ensureDirectoryNoFollow(outputDirectoryURL, role: "output bundle")

        let canonicalOutput = outputDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalWork = workDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard !pathsOverlap(canonicalOutput, canonicalWork) else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Work directory must not overlap output bundle: \(canonicalWork.path) and \(canonicalOutput.path)."
            )
        }

        let artifactsDirectoryURL = canonicalOutput.appendingPathComponent("artifacts", isDirectory: true)
        try ensureDirectoryNoFollow(artifactsDirectoryURL, role: "artifacts directory")
        try requireContained(artifactsDirectoryURL, within: canonicalOutput, role: "artifacts directory")

        let alignmentDirectoryURL = artifactsDirectoryURL.appendingPathComponent("alignments", isDirectory: true)
        if try entryExistsNoFollow(alignmentDirectoryURL) {
            try requireDirectoryNoFollow(alignmentDirectoryURL, role: "alignment publication directory")
            try requireContained(alignmentDirectoryURL, within: canonicalOutput, role: "alignment publication directory")
            try requireSafeDirectoryTree(alignmentDirectoryURL, role: "alignment publication directory")
        }

        return FullLengthONTMHCAlignmentPathContext(
            outputDirectoryURL: canonicalOutput,
            workDirectoryURL: canonicalWork,
            artifactsDirectoryURL: artifactsDirectoryURL.standardizedFileURL,
            alignmentDirectoryURL: alignmentDirectoryURL.standardizedFileURL,
            outputDirectoryIdentity: try pathIdentityNoFollow(canonicalOutput, role: "output bundle"),
            workDirectoryIdentity: try pathIdentityNoFollow(canonicalWork, role: "work directory"),
            artifactsDirectoryIdentity: try pathIdentityNoFollow(artifactsDirectoryURL, role: "artifacts directory")
        )
    }

    func capturePublicationPathIdentities(
        stagingDirectoryURL: URL,
        pathContext: FullLengthONTMHCAlignmentPathContext
    ) throws -> FullLengthONTMHCPublicationPathIdentityContext {
        try revalidatePathContext(pathContext)
        return .init(stagingDirectoryIdentity: try pathIdentityNoFollow(
            stagingDirectoryURL,
            role: "alignment publication staging directory"
        ))
    }

    func revalidatePublicationPathIdentities(
        _ publicationContext: FullLengthONTMHCPublicationPathIdentityContext,
        stagingDirectoryURL: URL,
        pathContext: FullLengthONTMHCAlignmentPathContext
    ) throws {
        try revalidatePathContext(pathContext)
        try requireUnchangedIdentity(
            publicationContext.stagingDirectoryIdentity,
            at: stagingDirectoryURL,
            role: "alignment publication staging directory"
        )
        try requireContained(
            stagingDirectoryURL,
            within: pathContext.outputDirectoryURL,
            role: "alignment publication staging directory"
        )
        try requireSafeDirectoryTree(
            stagingDirectoryURL,
            role: "alignment publication staging directory"
        )
    }

    func revalidatePathContext(_ pathContext: FullLengthONTMHCAlignmentPathContext) throws {
        try requireUnchangedIdentity(
            pathContext.outputDirectoryIdentity,
            at: pathContext.outputDirectoryURL,
            role: "output bundle"
        )
        try requireUnchangedIdentity(
            pathContext.workDirectoryIdentity,
            at: pathContext.workDirectoryURL,
            role: "work directory"
        )
        try requireUnchangedIdentity(
            pathContext.artifactsDirectoryIdentity,
            at: pathContext.artifactsDirectoryURL,
            role: "artifacts directory"
        )
    }

    func requireRegularFileNoFollow(_ url: URL, role: String) throws {
        let metadata = try metadataNoFollow(at: url, role: role)
        guard metadata.type == S_IFREG else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Expected \(role) to be a real regular file (symlinks and special files are not allowed): \(url.path)"
            )
        }
    }

    func requireDirectoryNoFollow(_ url: URL, role: String) throws {
        let metadata = try metadataNoFollow(at: url, role: role)
        guard metadata.type == S_IFDIR else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Expected \(role) to be a real directory (symlinks and special files are not allowed): \(url.path)"
            )
        }
    }

    func requireContained(_ url: URL, within root: URL, role: String) throws {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard contains(canonicalRoot, canonicalURL) else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "\(role.capitalized) escapes the canonical output bundle: \(canonicalURL.path)"
            )
        }
    }

    func requireSafeDirectoryTree(_ root: URL, role: String) throws {
        try requireDirectoryNoFollow(root, role: role)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw FullLengthONTMHCAlignmentSafetyError("Could not inspect \(role): \(root.path)")
        }
        for case let entryURL as URL in enumerator {
            let metadata = try metadataNoFollow(at: entryURL, role: "entry in \(role)")
            guard metadata.type == S_IFREG || metadata.type == S_IFDIR else {
                enumerator.skipDescendants()
                throw FullLengthONTMHCAlignmentSafetyError(
                    "Symlinks and special files are not allowed in \(role): \(entryURL.path)"
                )
            }
        }
    }

    func validateScientificInputs(
        samples: [FullLengthONTMHCSampleAlignmentInput],
        referenceAlleleFASTAURL: URL
    ) throws -> [FullLengthONTMHCSampleAlignmentInput] {
        guard !samples.isEmpty else {
            throw FullLengthONTMHCAlignmentSafetyError("At least one sample alignment is required.")
        }
        try requireRegularFileNoFollow(referenceAlleleFASTAURL, role: "reference allele FASTA")

        var sampleIDs = Set<String>()
        var namespacedIDs = Set<String>()
        for sample in samples {
            guard Self.isSafeIdentifier(sample.sampleID, allowColon: false) else {
                throw FullLengthONTMHCAlignmentSafetyError("Unsafe stable sample ID '\(sample.sampleID)'.")
            }
            guard sampleIDs.insert(sample.sampleID).inserted else {
                throw FullLengthONTMHCAlignmentSafetyError("Duplicate stable sample ID '\(sample.sampleID)'.")
            }
            try requireRegularFileNoFollow(
                sample.originalClustersFASTAURL,
                role: "cluster FASTA for \(sample.sampleID)"
            )
            guard !sample.clusterRecords.isEmpty else {
                throw FullLengthONTMHCAlignmentSafetyError("Sample '\(sample.sampleID)' has no cluster records.")
            }

            for declared in sample.clusterRecords {
                try validateClusterRecord(name: declared.name, sequence: declared.sequence)
                let namespacedID = "\(sample.sampleID)|\(declared.name)"
                guard namespacedIDs.insert(namespacedID).inserted else {
                    throw FullLengthONTMHCAlignmentSafetyError(
                        "Namespaced target collision for '\(namespacedID)'."
                    )
                }
            }
        }
        return samples.sorted { $0.sampleID < $1.sampleID }
    }

    func validateClusterRecord(name: String, sequence: String) throws {
        guard Self.isSafeIdentifier(name, allowColon: true) else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Cluster ID '\(name)' is not an ASCII SAM/FASTA-safe identifier."
            )
        }
        guard !sequence.isEmpty else {
            throw FullLengthONTMHCAlignmentSafetyError("Cluster '\(name)' has an empty sequence.")
        }
        let allowed = Set("ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8)
        guard sequence.utf8.allSatisfy(allowed.contains) else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Cluster '\(name)' contains non-IUPAC nucleotide characters."
            )
        }
    }

    private func ensureDirectoryNoFollow(_ url: URL, role: String) throws {
        if !(try entryExistsNoFollow(url)) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try requireDirectoryNoFollow(url, role: role)
    }

    private func entryExistsNoFollow(_ url: URL) throws -> Bool {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func metadataNoFollow(
        at url: URL,
        role: String
    ) throws -> (type: mode_t, size: off_t) {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                throw FullLengthONTMHCAlignmentSafetyError("Missing \(role): \(url.path)")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (info.st_mode & S_IFMT, info.st_size)
    }

    private func pathIdentityNoFollow(_ url: URL, role: String) throws -> FullLengthONTMHCPathIdentity {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                throw FullLengthONTMHCAlignmentSafetyError("Missing \(role): \(url.path)")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return .init(
            canonicalPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            type: info.st_mode & S_IFMT
        )
    }

    private func requireUnchangedIdentity(
        _ expected: FullLengthONTMHCPathIdentity,
        at url: URL,
        role: String
    ) throws {
        let observed = try pathIdentityNoFollow(url, role: role)
        guard observed == expected else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "\(role.capitalized) identity changed after validation: \(url.path)"
            )
        }
    }

    private func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        contains(lhs, rhs) || contains(rhs, lhs)
    }

    private func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isSafeIdentifier(_ value: String, allowColon: Bool) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, isASCIILetterOrDigit(first) else { return false }
        return bytes.allSatisfy { byte in
            isASCIILetterOrDigit(byte)
                || byte == Character(".").asciiValue
                || byte == Character("_").asciiValue
                || byte == Character("-").asciiValue
                || (allowColon && byte == Character(":").asciiValue)
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}

struct FullLengthONTMHCAlignmentSafetyError: Error, LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

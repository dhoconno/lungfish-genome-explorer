import Darwin
import Foundation
import LungfishIO

struct FullLengthONTMHCAlignmentPathContext: Sendable {
    let outputDirectoryURL: URL
    let workDirectoryURL: URL
    let artifactsDirectoryURL: URL
    let alignmentDirectoryURL: URL
}

struct FullLengthONTMHCAlignmentSafety {
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

        let artifactsDirectoryURL = outputDirectoryURL.appendingPathComponent("artifacts", isDirectory: true)
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
            alignmentDirectoryURL: alignmentDirectoryURL.standardizedFileURL
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

            let sourceRecords = try parseStrictFASTA(sample.originalClustersFASTAURL)
            guard sourceRecords.count == sample.clusterRecords.count else {
                throw FullLengthONTMHCAlignmentSafetyError(
                    "Source FASTA and declared cluster records differ for sample '\(sample.sampleID)'."
                )
            }
            for (source, declared) in zip(sourceRecords, sample.clusterRecords) {
                try validateClusterRecord(name: declared.name, sequence: declared.sequence)
                guard source.name == declared.name, source.sequence == declared.sequence else {
                    throw FullLengthONTMHCAlignmentSafetyError(
                        "Source FASTA and declared cluster records differ for sample '\(sample.sampleID)'."
                    )
                }
                let namespacedID = "\(sample.sampleID)|\(source.name)"
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

    private func parseStrictFASTA(
        _ url: URL
    ) throws -> [(name: String, sequence: String)] {
        var records: [(name: String, sequence: String)] = []
        var currentName: String?
        var sequence = ""

        func flush() throws {
            guard let currentName else { return }
            try validateClusterRecord(name: currentName, sequence: sequence)
            records.append((currentName, sequence))
        }

        try url.forEachLineAutoDecompressing { line in
            if line.hasPrefix(">") {
                try flush()
                let header = String(line.dropFirst())
                guard Self.isSafeIdentifier(header, allowColon: true) else {
                    throw FullLengthONTMHCAlignmentSafetyError(
                        "FASTA header '\(header)' is not an ASCII SAM/FASTA-safe identifier."
                    )
                }
                currentName = header
                sequence = ""
            } else {
                guard currentName != nil else {
                    if line.isEmpty { return }
                    throw FullLengthONTMHCAlignmentSafetyError(
                        "FASTA sequence appears before the first header in \(url.path)."
                    )
                }
                sequence += line
            }
        }
        try flush()
        guard !records.isEmpty else {
            throw FullLengthONTMHCAlignmentSafetyError("Cluster FASTA is empty: \(url.path)")
        }
        return records
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

import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

internal struct FullLengthONTMHCSampleSummary: Sendable, Codable, Equatable {
    let sample: String
    let totalInputReads: Int
    let clusterCount: Int
    let clusteredReads: Int
    let assignedReads: Int
    let unmatchedClusters: Int
    let cdnaClusters: Int
    let savontPreset: String
    let savontStatus: FullLengthONTMHCSavontSampleStatus
    let savontFallbackReason: String?
}

internal struct FullLengthONTMHCSampleExecutionConfiguration: Sendable, Equatable {
    let workerThreads: Int
    let savontThreads: Int
}

internal struct FullLengthONTMHCSavontAttemptResult: Sendable {
    let plan: FullLengthONTMHCSavontRunPlan
    let savontThreads: Int
    let savontSingleStrand: Bool
    let arguments: [String]
    let stderr: String
    let exitCode: Int32
    let startedAt: Date
    let completedAt: Date
}

internal struct FullLengthONTMHCSavontClusteringResult: Sendable {
    let preset: FullLengthONTMHCSavontPreset
    let normalizedFASTAURL: URL
    let completedAttempt: FullLengthONTMHCSavontAttemptResult?
}

internal struct FullLengthONTMHCSavontSelectedClusters: Sendable {
    let preset: FullLengthONTMHCSavontPreset
    let clustersFASTAURL: URL
    let fallbackReason: String?
    let handledSavontFailure: Bool
}

internal struct FullLengthONTMHCSampleResult: Sendable, Codable {
    let originalIndex: Int
    let processingRank: Int
    let sample: String
    let readCount: Int
    let clustersFASTAURL: URL
    let clusterRecords: [FullLengthONTMHCClusterFASTARecord]
    let genotypeRows: [FullLengthONTMHCClusterGenotypeRow]
    let sampleSummary: FullLengthONTMHCSampleSummary
    let unmatchedClusters: [FullLengthONTMHCClusterFASTARecord]
    let cdnaMatchedClusters: [FullLengthONTMHCClusterFASTARecord]
    let closestMatches: [FullLengthONTMHCClosestMatch]
    let steps: [FullLengthONTMHCProvenanceStep]

    func rehydrated(
        originalIndex: Int,
        processingRank: Int,
        readCount: Int,
        prepSteps: [FullLengthONTMHCProvenanceStep],
        reuseStep: FullLengthONTMHCProvenanceStep
    ) -> FullLengthONTMHCSampleResult {
        FullLengthONTMHCSampleResult(
            originalIndex: originalIndex,
            processingRank: processingRank,
            sample: sample,
            readCount: readCount,
            clustersFASTAURL: clustersFASTAURL,
            clusterRecords: clusterRecords,
            genotypeRows: [],
            sampleSummary: FullLengthONTMHCSampleSummary(
                sample: sampleSummary.sample,
                totalInputReads: readCount,
                clusterCount: sampleSummary.clusterCount,
                clusteredReads: sampleSummary.clusteredReads,
                assignedReads: 0,
                unmatchedClusters: 0,
                cdnaClusters: 0,
                savontPreset: sampleSummary.savontPreset,
                savontStatus: sampleSummary.savontStatus,
                savontFallbackReason: sampleSummary.savontFallbackReason
            ),
            unmatchedClusters: [],
            cdnaMatchedClusters: [],
            closestMatches: [],
            steps: prepSteps + steps.filter { !$0.isRegenerablePreparationStep } + [reuseStep]
        )
    }

    func applyingAuthoritativeGenotypingSummary(
        _ summary: FullLengthONTMHCClusterGenotypingSummary
    ) -> FullLengthONTMHCSampleResult {
        let status: FullLengthONTMHCSavontSampleStatus
        if sampleSummary.savontStatus == .handledSavontFailure && clusterRecords.isEmpty {
            status = .handledSavontFailure
        } else {
            status = summary.rows.isEmpty ? .noCall : .called
        }
        return FullLengthONTMHCSampleResult(
            originalIndex: originalIndex,
            processingRank: processingRank,
            sample: sample,
            readCount: readCount,
            clustersFASTAURL: clustersFASTAURL,
            clusterRecords: clusterRecords,
            genotypeRows: summary.rows,
            sampleSummary: FullLengthONTMHCSampleSummary(
                sample: sample,
                totalInputReads: readCount,
                clusterCount: clusterRecords.count,
                clusteredReads: clusterRecords.reduce(0) { $0 + $1.readCount },
                assignedReads: FullLengthONTMHCClusterReportBuilder.assignedReadCount(
                    genotypeRows: summary.rows
                ),
                unmatchedClusters: summary.unmatchedClusters.count,
                cdnaClusters: summary.cdnaMatchedClusters.count,
                savontPreset: sampleSummary.savontPreset,
                savontStatus: status,
                savontFallbackReason: sampleSummary.savontFallbackReason
            ),
            unmatchedClusters: summary.unmatchedClusters,
            cdnaMatchedClusters: summary.cdnaMatchedClusters,
            closestMatches: summary.closestMatches,
            steps: steps
        )
    }
}

internal struct FullLengthONTMHCSampleCheckpoint: Sendable, Codable {
    static let schemaVersion = "full-length-ont-mhc-sample-checkpoint/3"

    let schemaVersion: String
    let signature: FullLengthONTMHCSampleCheckpointSignature
    let result: FullLengthONTMHCSampleResult
    let createdAt: Date

    init(
        signature: FullLengthONTMHCSampleCheckpointSignature,
        result: FullLengthONTMHCSampleResult,
        createdAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.signature = signature
        self.result = result
        self.createdAt = createdAt
    }
}

internal struct FullLengthONTMHCSampleCheckpointSignature: Sendable, Codable, Equatable {
    let sample: String
    let sourceFASTQ: FullLengthONTMHCFileFingerprint
    let preparedFASTQ: FullLengthONTMHCFileFingerprint
    let referenceFASTA: FullLengthONTMHCFileFingerprint
    let orientReference: FullLengthONTMHCFileFingerprint?
    let forwardPrimer: FullLengthONTMHCFileFingerprint?
    let reversePrimer: FullLengthONTMHCFileFingerprint?
    let minimumLength: Int
    let maximumLength: Int
    let savontQualityValueCutoff: Int
    let savontMinimumClusterSize: Int
    let minUnmatchedReads: Int
    let cdnaThreshold: Int
    let workerThreads: Int
    let savontThreads: Int
    let savontToolVersion: String
    let savontCondaEnvironment: String
    let savontPackageSpec: String
}

internal struct FullLengthONTMHCFileFingerprint: Sendable, Codable, Equatable {
    let path: String
    let sha256: String
    let fileSizeBytes: UInt64

    static func fingerprint(url: URL) throws -> FullLengthONTMHCFileFingerprint {
        let standardized = url.standardizedFileURL
        if fullLengthONTMHCPathIsDirectory(standardized) {
            return try directoryFingerprint(url: standardized)
        }
        return FullLengthONTMHCFileFingerprint(
            path: standardized.path,
            sha256: try ProvenanceFileHasher.sha256(of: standardized) {
                try Task.checkCancellation()
            },
            fileSizeBytes: try ProvenanceFileHasher.fileSize(of: standardized)
        )
    }

    private static func directoryFingerprint(url: URL) throws -> FullLengthONTMHCFileFingerprint {
        let fileManager = FileManager.default
        let files = try fileManager.subpathsOfDirectory(atPath: url.path)
            .sorted()
            .map { relativePath -> String in
                let fileURL = url.appendingPathComponent(relativePath)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    return "\(relativePath)\tdirectory\t0"
                }
                let digest = try ProvenanceFileHasher.sha256(of: fileURL) {
                    try Task.checkCancellation()
                }
                let size = try ProvenanceFileHasher.fileSize(of: fileURL)
                return "\(relativePath)\t\(digest)\t\(size)"
            }
        let manifest = files.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        return FullLengthONTMHCFileFingerprint(
            path: url.path,
            sha256: digest,
            fileSizeBytes: UInt64(manifest.utf8.count)
        )
    }
}

internal struct FullLengthONTMHCProvenanceStep: Sendable, Codable {
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let resolvedOptions: [String: ParameterValue]
    let runtimeIdentity: ProvenanceRuntimeIdentity
    let inputs: [URL]
    let outputs: [URL]
    let exitStatus: Int32
    let stderr: String?
    let startedAt: Date
    let completedAt: Date

    private enum CodingKeys: String, CodingKey {
        case toolName
        case toolVersion
        case argv
        case resolvedOptions
        case runtimeIdentity
        case inputs
        case outputs
        case exitStatus
        case stderr
        case startedAt
        case completedAt
    }

    init(
        toolName: String,
        toolVersion: String,
        argv: [String],
        resolvedOptions: [String: ParameterValue] = [:],
        runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
        inputs: [URL],
        outputs: [URL],
        exitStatus: Int32,
        stderr: String?,
        startedAt: Date,
        completedAt: Date
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            toolName: try container.decode(String.self, forKey: .toolName),
            toolVersion: try container.decode(String.self, forKey: .toolVersion),
            argv: try container.decode([String].self, forKey: .argv),
            resolvedOptions: try container.decodeIfPresent(
                [String: ParameterValue].self,
                forKey: .resolvedOptions
            ) ?? [:],
            runtimeIdentity: try container.decodeIfPresent(
                ProvenanceRuntimeIdentity.self,
                forKey: .runtimeIdentity
            ) ?? ProvenanceRuntimeIdentity(),
            inputs: try container.decode([URL].self, forKey: .inputs),
            outputs: try container.decode([URL].self, forKey: .outputs),
            exitStatus: try container.decode(Int32.self, forKey: .exitStatus),
            stderr: try container.decodeIfPresent(String.self, forKey: .stderr),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            completedAt: try container.decode(Date.self, forKey: .completedAt)
        )
    }

    var isRegenerablePreparationStep: Bool {
        switch toolName {
        case "vsearch", "bbduk.sh", "reformat.sh":
            return outputs.isEmpty
        default:
            return false
        }
    }

    func provenanceStep() throws -> ProvenanceStep {
        try ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: resolvedOptions,
            runtimeIdentity: runtimeIdentity,
            inputs: inputs.map {
                try fileDescriptor(url: $0, format: fileFormat(for: $0), role: .input)
            },
            outputs: outputs.map {
                try fileDescriptor(url: $0, format: fileFormat(for: $0), role: .output)
            },
            exitStatus: Int(exitStatus),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func fileFormat(for url: URL) -> FileFormat {
        if SequenceFormat.from(url: url) == .fasta {
            return .fasta
        }
        if SequenceFormat.from(url: url) == .fastq {
            return .fastq
        }
        switch url.pathExtension.lowercased() {
        case "bam":
            return .bam
        case "sam":
            return .sam
        case "json":
            return .json
        case "csv", "tsv", "txt", "log":
            return .text
        default:
            return .unknown
        }
    }

    private func fileDescriptor(url: URL, format: FileFormat?, role: FileRole) throws -> ProvenanceFileDescriptor {
        if fullLengthONTMHCPathIsDirectory(url) {
            return ProvenanceFileDescriptor(path: url.path, format: format, role: role)
        }
        return try ProvenanceFileDescriptor.file(url: url, format: format, role: role)
    }
}

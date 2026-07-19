import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCSampleAlignmentInput: Sendable, Equatable {
    public let sampleID: String
    public let originalClustersFASTAURL: URL
    public let clusterRecords: [FullLengthONTMHCClusterFASTARecord]

    public init(
        sampleID: String,
        originalClustersFASTAURL: URL,
        clusterRecords: [FullLengthONTMHCClusterFASTARecord]
    ) {
        self.sampleID = sampleID
        self.originalClustersFASTAURL = originalClustersFASTAURL.standardizedFileURL
        self.clusterRecords = clusterRecords
    }
}

public struct FullLengthONTMHCCohortAlignmentBuildRequest: Sendable, Equatable {
    public let samples: [FullLengthONTMHCSampleAlignmentInput]
    public let referenceAlleleFASTAURL: URL
    public let threads: Int
    public let outputDirectoryURL: URL
    public let workDirectoryURL: URL
    public let keepIntermediates: Bool
    public let deferTemporaryWorkDirectoryCleanup: Bool
    public let allowEmptyCohort: Bool

    public init(
        samples: [FullLengthONTMHCSampleAlignmentInput],
        referenceAlleleFASTAURL: URL,
        threads: Int,
        outputDirectoryURL: URL,
        workDirectoryURL: URL,
        keepIntermediates: Bool,
        deferTemporaryWorkDirectoryCleanup: Bool = false,
        allowEmptyCohort: Bool = false
    ) {
        self.samples = samples
        self.referenceAlleleFASTAURL = referenceAlleleFASTAURL.standardizedFileURL
        self.threads = max(1, threads)
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.workDirectoryURL = workDirectoryURL.standardizedFileURL
        self.keepIntermediates = keepIntermediates
        self.deferTemporaryWorkDirectoryCleanup = deferTemporaryWorkDirectoryCleanup
        self.allowEmptyCohort = allowEmptyCohort
    }
}

public struct FullLengthONTMHCTargetNamespaceMapping: Sendable, Equatable, Codable {
    public let originalClusterID: String
    public let namespacedTargetID: String

    public init(originalClusterID: String, namespacedTargetID: String) {
        self.originalClusterID = originalClusterID
        self.namespacedTargetID = namespacedTargetID
    }
}

public struct FullLengthONTMHCSampleAlignmentMapping: Sendable, Equatable {
    public let sampleID: String
    public let readGroupID: String
    public let readGroupSample: String
    public let originalClustersFASTAURL: URL
    public let namespacedClustersFASTAURL: URL
    public let samURL: URL
    public let unsortedBAMURL: URL
    public let readGroupBAMURL: URL
    public let sortedBAMURL: URL
    public let targets: [FullLengthONTMHCTargetNamespaceMapping]
}

public struct FullLengthONTMHCCohortAlignmentCommandRecord: Sendable, Equatable {
    public let executableURL: URL
    public let toolVersion: String?
    public let argv: [String]
    public let arguments: [String]
    public let inputs: [URL]
    public let outputs: [URL]
    public let inputDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let outputDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let descriptorCaptureErrors: [FullLengthONTMHCArtifactDescriptorCaptureError]
    public let stdoutLogDescriptor: FullLengthONTMHCArtifactDescriptor
    public let stderrLogDescriptor: FullLengthONTMHCArtifactDescriptor
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String
    public let wasCancelled: Bool
    public let startedAt: Date
    public let completedAt: Date
    public let wallTime: TimeInterval
}

public struct FullLengthONTMHCCohortAlignmentResult: Sendable, Equatable {
    public let bamURL: URL
    public let baiURL: URL
    public let sampleMappings: [FullLengthONTMHCSampleAlignmentMapping]
    public let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let temporaryWorkDirectoryURL: URL
    public let mergedBAMURL: URL
    public private(set) var retainedPublicationDirectoryURL: URL?
    public private(set) var publicationCleanupError: String?
    public let toolVersions: [FullLengthONTMHCToolVersionRecord]
    public let toolVersionDiscoveryRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let artifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let finalArtifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let temporaryArtifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let publicationMappings: [FullLengthONTMHCArtifactPublicationMapping]
    public private(set) var publicationRecord: FullLengthONTMHCAlignmentDirectoryPublicationRecord?
    public let transformationRecords: [FullLengthONTMHCInProcessTransformationRecord]
    public private(set) var cleanupDiagnostics: [FullLengthONTMHCCleanupDiagnostic]
    public let requiresTemporaryWorkDirectoryCleanup: Bool

    mutating func attachCleanup(
        retainedPublicationDirectoryURL: URL?,
        publicationCleanupError: String?,
        diagnostics: [FullLengthONTMHCCleanupDiagnostic]
    ) {
        self.retainedPublicationDirectoryURL = retainedPublicationDirectoryURL
        self.publicationCleanupError = publicationCleanupError
        cleanupDiagnostics = diagnostics
    }

    mutating func attachPublicationRecord(
        _ record: FullLengthONTMHCAlignmentDirectoryPublicationRecord
    ) {
        publicationRecord = record
    }
}

public struct FullLengthONTMHCBAMViewResult: Sendable, Equatable {
    public let samURL: URL
    public let commandRecord: FullLengthONTMHCCohortAlignmentCommandRecord
}

public struct FullLengthONTMHCCohortAlignmentBuildError: Error, LocalizedError, Sendable {
    public let message: String
    public let retainedWorkDirectoryURL: URL
    public let retainedPublicationDirectoryURL: URL?
    public let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let toolVersions: [FullLengthONTMHCToolVersionRecord]
    public let toolVersionDiscoveryRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let artifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let plannedPublicationMappings: [FullLengthONTMHCArtifactPublicationMapping]
    public let publicationRecord: FullLengthONTMHCAlignmentDirectoryPublicationRecord?
    public let transformationRecords: [FullLengthONTMHCInProcessTransformationRecord]
    public let wasCancelled: Bool

    public var errorDescription: String? { message }
}

public struct FullLengthONTMHCAlignmentDirectoryPublication: Sendable, Equatable {
    public let retiredDirectoryURL: URL?
    public let record: FullLengthONTMHCAlignmentDirectoryPublicationRecord

    public init(
        retiredDirectoryURL: URL?,
        record: FullLengthONTMHCAlignmentDirectoryPublicationRecord
    ) {
        self.retiredDirectoryURL = retiredDirectoryURL
        self.record = record
    }
}

public protocol FullLengthONTMHCAlignmentDirectoryPublishing: Sendable {
    func acquirePublicationLock(
        artifactsDirectoryURL: URL
    ) throws -> any FullLengthONTMHCAlignmentPublicationLock

    func publish(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    ) throws -> FullLengthONTMHCAlignmentDirectoryPublication

    func cleanupRetiredDirectory(at url: URL) throws
}

public extension FullLengthONTMHCAlignmentDirectoryPublishing {
    func acquirePublicationLock(
        artifactsDirectoryURL: URL
    ) throws -> any FullLengthONTMHCAlignmentPublicationLock {
        try DarwinFullLengthONTMHCAlignmentPublicationLock.acquire(
            artifactsDirectoryURL: artifactsDirectoryURL
        )
    }

    func cleanupRetiredDirectory(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public struct DarwinAtomicAlignmentDirectoryPublisher: FullLengthONTMHCAlignmentDirectoryPublishing {
    public init() {}

    public func publish(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    ) throws -> FullLengthONTMHCAlignmentDirectoryPublication {
        let sourceURL = stagedDirectoryURL.standardizedFileURL
        let destinationURL = finalDirectoryURL.standardizedFileURL
        let startedAt = Date()
        let finalExists = FileManager.default.fileExists(atPath: destinationURL.path)
        let mode: FullLengthONTMHCAlignmentDirectoryPublicationMode = finalExists ? .replace : .create
        let flags = UInt32(finalExists ? RENAME_SWAP : RENAME_EXCL)
        let status = sourceURL.path.withCString { stagedPath in
            destinationURL.path.withCString { finalPath in
                renameatx_np(AT_FDCWD, stagedPath, AT_FDCWD, finalPath, flags)
            }
        }
        let code = status == 0 ? nil : (POSIXErrorCode(rawValue: errno) ?? .EIO)
        let completedAt = Date()
        let record = FullLengthONTMHCAlignmentDirectoryPublicationRecord(
            mode: mode,
            sourceDirectoryURL: sourceURL,
            finalDirectoryURL: destinationURL,
            exitStatus: status,
            errorMessage: code.map { POSIXError($0).localizedDescription },
            startedAt: startedAt,
            completedAt: completedAt
        )
        guard status == 0 else {
            throw FullLengthONTMHCAlignmentDirectoryPublicationError(record: record)
        }
        return FullLengthONTMHCAlignmentDirectoryPublication(
            retiredDirectoryURL: finalExists ? sourceURL : nil,
            record: record
        )
    }
}

public struct FullLengthONTMHCCohortAlignmentBuilder: @unchecked Sendable {
    private let executableDirectoryURL: URL?
    private let minimap2ExecutableURL: URL?
    private let samtoolsExecutableURL: URL?
    private let alignmentDirectoryPublisher: any FullLengthONTMHCAlignmentDirectoryPublishing
    private let workDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning
    private let artifactDescriptorProvider: any FullLengthONTMHCArtifactDescriptorProviding
    private let prepublicationObserver: @Sendable (FullLengthONTMHCCohortAlignmentResult) -> Void
    private let sourceSnapshotObserver: @Sendable (String, URL) -> Void
    private let fileManager: FileManager

    public init(
        executableDirectoryURL: URL? = nil,
        alignmentDirectoryPublisher: any FullLengthONTMHCAlignmentDirectoryPublishing = DarwinAtomicAlignmentDirectoryPublisher(),
        workDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner(),
        fileManager: FileManager = .default
    ) {
        self.executableDirectoryURL = executableDirectoryURL?.standardizedFileURL
        self.minimap2ExecutableURL = nil
        self.samtoolsExecutableURL = nil
        self.alignmentDirectoryPublisher = alignmentDirectoryPublisher
        self.workDirectoryCleaner = workDirectoryCleaner
        self.artifactDescriptorProvider = DefaultFullLengthONTMHCArtifactDescriptorProvider()
        self.prepublicationObserver = { _ in }
        self.sourceSnapshotObserver = { _, _ in }
        self.fileManager = fileManager
    }

    public init(
        minimap2ExecutableURL: URL,
        samtoolsExecutableURL: URL,
        alignmentDirectoryPublisher: any FullLengthONTMHCAlignmentDirectoryPublishing = DarwinAtomicAlignmentDirectoryPublisher(),
        workDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner(),
        fileManager: FileManager = .default
    ) {
        self.executableDirectoryURL = nil
        self.minimap2ExecutableURL = minimap2ExecutableURL.standardizedFileURL
        self.samtoolsExecutableURL = samtoolsExecutableURL.standardizedFileURL
        self.alignmentDirectoryPublisher = alignmentDirectoryPublisher
        self.workDirectoryCleaner = workDirectoryCleaner
        self.artifactDescriptorProvider = DefaultFullLengthONTMHCArtifactDescriptorProvider()
        self.prepublicationObserver = { _ in }
        self.sourceSnapshotObserver = { _, _ in }
        self.fileManager = fileManager
    }

    init(
        executableDirectoryURL: URL? = nil,
        alignmentDirectoryPublisher: any FullLengthONTMHCAlignmentDirectoryPublishing = DarwinAtomicAlignmentDirectoryPublisher(),
        workDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner(),
        fileManager: FileManager = .default,
        artifactDescriptorProvider: any FullLengthONTMHCArtifactDescriptorProviding,
        prepublicationObserver: @escaping @Sendable (FullLengthONTMHCCohortAlignmentResult) -> Void = { _ in },
        sourceSnapshotObserver: @escaping @Sendable (String, URL) -> Void = { _, _ in }
    ) {
        self.executableDirectoryURL = executableDirectoryURL?.standardizedFileURL
        self.minimap2ExecutableURL = nil
        self.samtoolsExecutableURL = nil
        self.alignmentDirectoryPublisher = alignmentDirectoryPublisher
        self.workDirectoryCleaner = workDirectoryCleaner
        self.artifactDescriptorProvider = artifactDescriptorProvider
        self.prepublicationObserver = prepublicationObserver
        self.sourceSnapshotObserver = sourceSnapshotObserver
        self.fileManager = fileManager
    }

    public func build(
        _ request: FullLengthONTMHCCohortAlignmentBuildRequest
    ) async throws -> FullLengthONTMHCCohortAlignmentResult {
        let temporaryWorkDirectoryURL = request.workDirectoryURL.appendingPathComponent(
            "full-length-ont-mhc-cohort-alignment-\(UUID().uuidString)",
            isDirectory: true
        )
        var commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord] = []
        var publicationDirectoryURL: URL?
        var toolVersions: [FullLengthONTMHCToolVersionRecord] = []
        var toolVersionDiscoveryRecords: [FullLengthONTMHCCohortAlignmentCommandRecord] = []
        var artifactDescriptors: [FullLengthONTMHCArtifactDescriptor] = []
        var transformationRecords: [FullLengthONTMHCInProcessTransformationRecord] = []
        var plannedPublicationMappings: [FullLengthONTMHCArtifactPublicationMapping] = []
        var publicationRecord: FullLengthONTMHCAlignmentDirectoryPublicationRecord?
        let runtimeIdentity = ProvenanceRuntimeIdentity()

        do {
            let safety = FullLengthONTMHCAlignmentSafety(fileManager: fileManager)
            let pathContext = try safety.prepareDirectories(
                outputDirectoryURL: request.outputDirectoryURL,
                workDirectoryURL: request.workDirectoryURL
            )
            let samples: [FullLengthONTMHCSampleAlignmentInput]
            if request.samples.isEmpty && request.allowEmptyCohort {
                try safety.requireRegularFileNoFollow(
                    request.referenceAlleleFASTAURL,
                    role: "reference allele FASTA"
                )
                samples = []
            } else {
                samples = try safety.validateScientificInputs(
                    samples: request.samples,
                    referenceAlleleFASTAURL: request.referenceAlleleFASTAURL
                )
            }
            try fileManager.createDirectory(
                at: temporaryWorkDirectoryURL,
                withIntermediateDirectories: true
            )
            try safety.requireDirectoryNoFollow(
                temporaryWorkDirectoryURL,
                role: "temporary cohort alignment work directory"
            )
            try safety.requireContained(
                temporaryWorkDirectoryURL,
                within: pathContext.workDirectoryURL,
                role: "temporary cohort alignment work directory"
            )
            let logsDirectoryURL = temporaryWorkDirectoryURL.appendingPathComponent("logs", isDirectory: true)
            try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: false)
            try safety.requireDirectoryNoFollow(logsDirectoryURL, role: "command log directory")

            let minimap2URL = try executableURL(named: "minimap2")
            let samtoolsURL = try executableURL(named: "samtools")
            artifactDescriptors.append(try artifactDescriptorProvider.descriptor(
                for: request.referenceAlleleFASTAURL,
                role: .referenceFASTA,
                phase: .input
            ))
            let rawMinimap2VersionRecord = try await executeToolVersionDiscovery(
                executableURL: minimap2URL,
                temporaryWorkDirectoryURL: temporaryWorkDirectoryURL,
                logsDirectoryURL: logsDirectoryURL
            )
            toolVersionDiscoveryRecords.append(rawMinimap2VersionRecord)
            artifactDescriptors.append(contentsOf: rawMinimap2VersionRecord.capturedArtifactDescriptors)
            let minimap2Version = try parsedToolVersion(
                toolName: "minimap2",
                discoveryCommand: rawMinimap2VersionRecord
            )
            toolVersionDiscoveryRecords[toolVersionDiscoveryRecords.count - 1] = minimap2Version.discoveryCommand
            toolVersions.append(minimap2Version)
            let rawSamtoolsVersionRecord = try await executeToolVersionDiscovery(
                executableURL: samtoolsURL,
                temporaryWorkDirectoryURL: temporaryWorkDirectoryURL,
                logsDirectoryURL: logsDirectoryURL
            )
            toolVersionDiscoveryRecords.append(rawSamtoolsVersionRecord)
            artifactDescriptors.append(contentsOf: rawSamtoolsVersionRecord.capturedArtifactDescriptors)
            let samtoolsVersion = try parsedToolVersion(
                toolName: "samtools",
                discoveryCommand: rawSamtoolsVersionRecord
            )
            toolVersionDiscoveryRecords[toolVersionDiscoveryRecords.count - 1] = samtoolsVersion.discoveryCommand
            toolVersions.append(samtoolsVersion)

            var mappings: [FullLengthONTMHCSampleAlignmentMapping] = []
            var namespacedTargets = Set<String>()
            for (index, sample) in samples.enumerated() {
                let sampleDirectory = temporaryWorkDirectoryURL.appendingPathComponent(
                    String(format: "%04d-%@", index + 1, sample.sampleID),
                    isDirectory: true
                )
                try fileManager.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
                let namespacedFASTAURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).namespaced-clusters.fa")
                let snapshotFASTAURL = sampleDirectory.appendingPathComponent(
                    "\(sample.sampleID).source-snapshot.\(sample.originalClustersFASTAURL.lastPathComponent)"
                )
                let samURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).sam")
                let unsortedBAMURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).unsorted.bam")
                let readGroupBAMURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).rg.bam")
                let sortedBAMURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).sorted.bam")
                let snapshot = try FullLengthONTMHCFASTAInputSnapshotter().snapshot(
                    sourceURL: sample.originalClustersFASTAURL,
                    to: snapshotFASTAURL
                )
                transformationRecords.append(snapshot.transformation)
                artifactDescriptors.append(contentsOf: snapshot.transformation.capturedArtifactDescriptors)
                sourceSnapshotObserver(sample.sampleID, snapshot.url)
                let namespacing = try writeNamespacedFASTA(
                    sample: sample,
                    snapshot: snapshot,
                    to: namespacedFASTAURL,
                    namespacedTargets: &namespacedTargets
                )
                let targets = namespacing.mappings
                transformationRecords.append(namespacing.transformation)
                artifactDescriptors.append(contentsOf: namespacing.transformation.capturedArtifactDescriptors)
                mappings.append(FullLengthONTMHCSampleAlignmentMapping(
                    sampleID: sample.sampleID,
                    readGroupID: sample.sampleID,
                    readGroupSample: sample.sampleID,
                    originalClustersFASTAURL: sample.originalClustersFASTAURL,
                    namespacedClustersFASTAURL: namespacedFASTAURL,
                    samURL: samURL,
                    unsortedBAMURL: unsortedBAMURL,
                    readGroupBAMURL: readGroupBAMURL,
                    sortedBAMURL: sortedBAMURL,
                    targets: targets
                ))
            }

            for mapping in mappings {
                try await run(
                    executableURL: minimap2URL,
                    arguments: [
                        "-a", "-x", "splice", "--eqx",
                        "-t", String(request.threads),
                        "-N", "100", "--secondary=yes",
                        mapping.namespacedClustersFASTAURL.path,
                        request.referenceAlleleFASTAURL.path,
                    ],
                    inputs: [mapping.namespacedClustersFASTAURL, request.referenceAlleleFASTAURL],
                    outputs: [mapping.samURL],
                    stdoutURL: mapping.samURL,
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
                try await run(
                    executableURL: samtoolsURL,
                    arguments: ["view", "-b", "-o", mapping.unsortedBAMURL.path, mapping.samURL.path],
                    inputs: [mapping.samURL],
                    outputs: [mapping.unsortedBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
                try await run(
                    executableURL: samtoolsURL,
                    arguments: [
                        "addreplacerg",
                        "-r", "ID:\(mapping.sampleID)",
                        "-r", "SM:\(mapping.sampleID)",
                        "-o", mapping.readGroupBAMURL.path,
                        mapping.unsortedBAMURL.path,
                    ],
                    inputs: [mapping.unsortedBAMURL],
                    outputs: [mapping.readGroupBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
                try await run(
                    executableURL: samtoolsURL,
                    arguments: ["sort", "-o", mapping.sortedBAMURL.path, mapping.readGroupBAMURL.path],
                    inputs: [mapping.readGroupBAMURL],
                    outputs: [mapping.sortedBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
            }

            let mergedBAMURL = temporaryWorkDirectoryURL.appendingPathComponent("cohort.merged.bam")
            if mappings.isEmpty {
                let emptySAMURL = temporaryWorkDirectoryURL.appendingPathComponent("empty-cohort.sam")
                let transformationStartedAt = Date()
                try "@HD\tVN:1.6\tSO:unsorted\n".write(
                    to: emptySAMURL,
                    atomically: true,
                    encoding: .utf8
                )
                let emptySAMDescriptor = try artifactDescriptorProvider.descriptor(
                    for: emptySAMURL,
                    role: .commandInput,
                    phase: .temporary
                )
                let transformationCompletedAt = Date()
                transformationRecords.append(FullLengthONTMHCInProcessTransformationRecord(
                    workflowName: "lungfish-in-process:create-empty-mhc-cohort-sam",
                    workflowVersion: WorkflowRun.currentAppVersion,
                    argv: [
                        "lungfish-in-process", "create-empty-mhc-cohort-sam",
                        "--sam-version", "1.6",
                        emptySAMURL.path,
                    ],
                    resolvedOptions: [
                        "samVersion": "1.6",
                        "sortOrder": "unsorted",
                        "reason": "no-clusters",
                    ],
                    inputs: [],
                    outputs: [emptySAMDescriptor],
                    exitStatus: 0,
                    startedAt: transformationStartedAt,
                    completedAt: transformationCompletedAt,
                    wallTime: transformationCompletedAt.timeIntervalSince(transformationStartedAt)
                ))
                artifactDescriptors.append(emptySAMDescriptor)
                try await run(
                    executableURL: samtoolsURL,
                    arguments: ["view", "-b", "-o", mergedBAMURL.path, emptySAMURL.path],
                    inputs: [emptySAMURL],
                    outputs: [mergedBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
            } else {
                try await run(
                    executableURL: samtoolsURL,
                    arguments: ["merge", "-f", "-o", mergedBAMURL.path] + mappings.map { $0.sortedBAMURL.path },
                    inputs: mappings.map(\.sortedBAMURL),
                    outputs: [mergedBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
            }

            let artifactsDirectoryURL = pathContext.artifactsDirectoryURL
            let alignmentDirectoryURL = pathContext.alignmentDirectoryURL
            let publicationLock = try alignmentDirectoryPublisher.acquirePublicationLock(
                artifactsDirectoryURL: artifactsDirectoryURL
            )
            defer { publicationLock.release() }
            try safety.revalidatePathContext(pathContext)
            if fileManager.fileExists(atPath: alignmentDirectoryURL.path) {
                try safety.requireDirectoryNoFollow(
                    alignmentDirectoryURL,
                    role: "alignment publication directory"
                )
                try safety.requireSafeDirectoryTree(
                    alignmentDirectoryURL,
                    role: "alignment publication directory"
                )
            }
            let stagingDirectoryURL = artifactsDirectoryURL.appendingPathComponent(
                ".alignments-replacement-\(UUID().uuidString)",
                isDirectory: true
            )
            publicationDirectoryURL = stagingDirectoryURL
            try FullLengthONTMHCAlignmentDirectorySnapshotter(fileManager: fileManager).snapshot(
                existingDirectoryURL: fileManager.fileExists(atPath: alignmentDirectoryURL.path)
                    ? alignmentDirectoryURL
                    : nil,
                to: stagingDirectoryURL
            )
            try safety.requireDirectoryNoFollow(stagingDirectoryURL, role: "alignment publication staging directory")
            try safety.requireContained(
                stagingDirectoryURL,
                within: pathContext.outputDirectoryURL,
                role: "alignment publication staging directory"
            )
            try safety.requireSafeDirectoryTree(stagingDirectoryURL, role: "alignment publication staging directory")
            let publicationPathIdentityContext = try safety.capturePublicationPathIdentities(
                stagingDirectoryURL: stagingDirectoryURL,
                pathContext: pathContext
            )
            let publicationPathIdentityValidator: @Sendable () throws -> Void = {
                try safety.revalidatePublicationPathIdentities(
                    publicationPathIdentityContext,
                    stagingDirectoryURL: stagingDirectoryURL,
                    pathContext: pathContext
                )
            }
            let stagedBAMURL = stagingDirectoryURL.appendingPathComponent("genotyping-evidence.bam")
            let stagedBAIURL = stagingDirectoryURL.appendingPathComponent("genotyping-evidence.bam.bai")

            try await run(
                executableURL: samtoolsURL,
                arguments: ["sort", "-o", stagedBAMURL.path, mergedBAMURL.path],
                inputs: [mergedBAMURL],
                outputs: [stagedBAMURL],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords,
                pathIdentityValidator: publicationPathIdentityValidator
            )
            try await run(
                executableURL: samtoolsURL,
                arguments: ["index", stagedBAMURL.path, stagedBAIURL.path],
                inputs: [stagedBAMURL],
                outputs: [stagedBAIURL],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords,
                pathIdentityValidator: publicationPathIdentityValidator
            )
            try await run(
                executableURL: samtoolsURL,
                arguments: ["quickcheck", stagedBAMURL.path],
                inputs: [stagedBAMURL],
                outputs: [],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords,
                pathIdentityValidator: publicationPathIdentityValidator
            )
            try await run(
                executableURL: samtoolsURL,
                arguments: ["idxstats", stagedBAMURL.path],
                inputs: [stagedBAMURL, stagedBAIURL],
                outputs: [],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords,
                pathIdentityValidator: publicationPathIdentityValidator
            )

            try publicationPathIdentityValidator()
            let stagedBAMDescriptor = try artifactDescriptorProvider.descriptor(
                for: stagedBAMURL,
                role: .evidenceBAM,
                phase: .staging
            )
            try publicationPathIdentityValidator()
            let stagedBAIDescriptor = try artifactDescriptorProvider.descriptor(
                for: stagedBAIURL,
                role: .evidenceBAI,
                phase: .staging
            )
            artifactDescriptors.append(contentsOf: [stagedBAMDescriptor, stagedBAIDescriptor])

            let finalBAMURL = alignmentDirectoryURL.appendingPathComponent("genotyping-evidence.bam")
            let finalBAIURL = alignmentDirectoryURL.appendingPathComponent("genotyping-evidence.bam.bai")
            let finalBAMDescriptor = stagedBAMDescriptor.relocated(
                to: finalBAMURL,
                role: .evidenceBAM,
                phase: .final
            )
            let finalBAIDescriptor = stagedBAIDescriptor.relocated(
                to: finalBAIURL,
                role: .evidenceBAI,
                phase: .final
            )
            let finalArtifactDescriptors = [finalBAMDescriptor, finalBAIDescriptor]
            let plannedFinalBAMDescriptor = stagedBAMDescriptor.relocated(
                to: finalBAMURL,
                role: .evidenceBAM,
                phase: .planned
            )
            let plannedFinalBAIDescriptor = stagedBAIDescriptor.relocated(
                to: finalBAIURL,
                role: .evidenceBAI,
                phase: .planned
            )
            plannedPublicationMappings = [
                FullLengthONTMHCArtifactPublicationMapping(
                    stagedDescriptor: stagedBAMDescriptor,
                    finalDescriptor: plannedFinalBAMDescriptor,
                    isPublished: false
                ),
                FullLengthONTMHCArtifactPublicationMapping(
                    stagedDescriptor: stagedBAIDescriptor,
                    finalDescriptor: plannedFinalBAIDescriptor,
                    isPublished: false
                ),
            ]
            let publicationMappings = [
                FullLengthONTMHCArtifactPublicationMapping(
                    stagedDescriptor: stagedBAMDescriptor,
                    finalDescriptor: finalBAMDescriptor
                ),
                FullLengthONTMHCArtifactPublicationMapping(
                    stagedDescriptor: stagedBAIDescriptor,
                    finalDescriptor: finalBAIDescriptor
                ),
            ]
            let versionByExecutablePath = Dictionary(
                uniqueKeysWithValues: toolVersions.map {
                    ($0.discoveryCommand.executableURL.standardizedFileURL.path, $0.version)
                }
            )
            let versionedCommandRecords = commandRecords.map {
                $0.replacingToolVersion(with: versionByExecutablePath[$0.executableURL.standardizedFileURL.path])
            }
            artifactDescriptors.append(contentsOf: versionedCommandRecords.flatMap(\.capturedArtifactDescriptors))
            let publishedArtifactDescriptors = artifactDescriptors + finalArtifactDescriptors
            let temporaryArtifactDescriptors = publishedArtifactDescriptors.filter { $0.phase == .temporary }
            var precomputedResult = FullLengthONTMHCCohortAlignmentResult(
                bamURL: finalBAMURL,
                baiURL: finalBAIURL,
                sampleMappings: mappings,
                commandRecords: versionedCommandRecords,
                temporaryWorkDirectoryURL: temporaryWorkDirectoryURL,
                mergedBAMURL: mergedBAMURL,
                retainedPublicationDirectoryURL: nil,
                publicationCleanupError: nil,
                toolVersions: toolVersions,
                toolVersionDiscoveryRecords: toolVersionDiscoveryRecords,
                runtimeIdentity: runtimeIdentity,
                artifactDescriptors: publishedArtifactDescriptors,
                finalArtifactDescriptors: finalArtifactDescriptors,
                temporaryArtifactDescriptors: temporaryArtifactDescriptors,
                publicationMappings: publicationMappings,
                publicationRecord: nil,
                transformationRecords: transformationRecords,
                cleanupDiagnostics: [],
                requiresTemporaryWorkDirectoryCleanup: !request.keepIntermediates
                    && request.deferTemporaryWorkDirectoryCleanup
            )

            try Task.checkCancellation()
            prepublicationObserver(precomputedResult)
            try Task.checkCancellation()
            try publicationPathIdentityValidator()
            try Task.checkCancellation()
            let publicationStartedAt = Date()
            let publicationMode: FullLengthONTMHCAlignmentDirectoryPublicationMode = fileManager
                .fileExists(atPath: alignmentDirectoryURL.path) ? .replace : .create
            let publication: FullLengthONTMHCAlignmentDirectoryPublication
            do {
                publication = try alignmentDirectoryPublisher.publish(
                    stagedDirectoryURL: stagingDirectoryURL,
                    finalDirectoryURL: alignmentDirectoryURL
                )
                publicationRecord = publication.record
            } catch let error as FullLengthONTMHCAlignmentDirectoryPublicationError {
                publicationRecord = error.record
                throw error
            } catch {
                let record = FullLengthONTMHCAlignmentDirectoryPublicationRecord(
                    mode: publicationMode,
                    sourceDirectoryURL: stagingDirectoryURL,
                    finalDirectoryURL: alignmentDirectoryURL,
                    exitStatus: -1,
                    errorMessage: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription,
                    startedAt: publicationStartedAt,
                    completedAt: Date()
                )
                publicationRecord = record
                throw FullLengthONTMHCAlignmentDirectoryPublicationError(record: record)
            }
            publicationDirectoryURL = nil
            precomputedResult.attachPublicationRecord(publication.record)
            var retainedPublicationDirectoryURL: URL?
            var publicationCleanupError: String?
            var cleanupDiagnostics: [FullLengthONTMHCCleanupDiagnostic] = []
            if let retiredDirectoryURL = publication.retiredDirectoryURL {
                do {
                    try alignmentDirectoryPublisher.cleanupRetiredDirectory(at: retiredDirectoryURL)
                } catch {
                    retainedPublicationDirectoryURL = retiredDirectoryURL
                    publicationCleanupError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    cleanupDiagnostics.append(.init(
                        kind: .retiredPublicationDirectory,
                        retainedDirectoryURL: retiredDirectoryURL,
                        message: publicationCleanupError ?? error.localizedDescription,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
            if !request.keepIntermediates && !request.deferTemporaryWorkDirectoryCleanup {
                do {
                    try workDirectoryCleaner.removeWorkDirectory(at: temporaryWorkDirectoryURL)
                } catch {
                    cleanupDiagnostics.append(.init(
                        kind: .temporaryWorkDirectory,
                        retainedDirectoryURL: temporaryWorkDirectoryURL,
                        message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }

            precomputedResult.attachCleanup(
                retainedPublicationDirectoryURL: retainedPublicationDirectoryURL,
                publicationCleanupError: publicationCleanupError,
                diagnostics: cleanupDiagnostics
            )
            return precomputedResult
        } catch {
            if let error = error as? FullLengthONTMHCCohortAlignmentBuildError {
                throw error
            }
            let versionByExecutablePath = Dictionary(
                uniqueKeysWithValues: toolVersions.map {
                    ($0.discoveryCommand.executableURL.standardizedFileURL.path, $0.version)
                }
            )
            let versionedCommandRecords = commandRecords.map {
                $0.replacingToolVersion(with: versionByExecutablePath[$0.executableURL.standardizedFileURL.path])
            }
            var retainedArtifactDescriptors = artifactDescriptors
            retainedArtifactDescriptors.append(contentsOf: versionedCommandRecords.flatMap(\.capturedArtifactDescriptors))
            let wasCancelled = error is CancellationError
                || Task.isCancelled
                || versionedCommandRecords.last?.wasCancelled == true
            throw FullLengthONTMHCCohortAlignmentBuildError(
                message: wasCancelled
                    ? "Cohort alignment build was cancelled."
                    : ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription),
                retainedWorkDirectoryURL: temporaryWorkDirectoryURL,
                retainedPublicationDirectoryURL: publicationDirectoryURL,
                commandRecords: versionedCommandRecords,
                toolVersions: toolVersions,
                toolVersionDiscoveryRecords: toolVersionDiscoveryRecords,
                runtimeIdentity: runtimeIdentity,
                artifactDescriptors: retainedArtifactDescriptors,
                plannedPublicationMappings: plannedPublicationMappings,
                publicationRecord: publicationRecord,
                transformationRecords: transformationRecords,
                wasCancelled: wasCancelled
            )
        }
    }

    public func viewHeaderAndAlignments(
        in bamURL: URL,
        temporaryWorkDirectoryURL: URL,
        samtoolsVersion: String
    ) async throws -> FullLengthONTMHCBAMViewResult {
        let samtoolsURL = try executableURL(named: "samtools")
        let outputURL = temporaryWorkDirectoryURL.appendingPathComponent(
            "final-genotyping-evidence-view-\(UUID().uuidString).sam"
        )
        let runner = FullLengthONTMHCAlignmentProcessRunner(fileManager: fileManager)
        let record = try await runner.execute(.init(
            executableURL: samtoolsURL,
            arguments: ["view", "-h", bamURL.standardizedFileURL.path],
            inputs: [bamURL.standardizedFileURL],
            outputs: [],
            stdoutURL: outputURL,
            workingDirectoryURL: temporaryWorkDirectoryURL,
            logsDirectoryURL: temporaryWorkDirectoryURL.appendingPathComponent("logs", isDirectory: true),
            toolVersion: samtoolsVersion,
            temporaryRootURL: temporaryWorkDirectoryURL,
            pathIdentityValidator: nil
        ))
        if record.wasCancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard record.exitStatus == 0 else {
            throw BuildFailure(
                "samtools failed with exit status \(record.exitStatus): \(record.stderr)"
            )
        }
        try Task.checkCancellation()
        return FullLengthONTMHCBAMViewResult(
            samURL: outputURL.standardizedFileURL,
            commandRecord: record
        )
    }

    public func cleanupTemporaryWorkDirectory(
        for result: FullLengthONTMHCCohortAlignmentResult
    ) -> FullLengthONTMHCCleanupDiagnostic? {
        guard result.requiresTemporaryWorkDirectoryCleanup,
              fileManager.fileExists(atPath: result.temporaryWorkDirectoryURL.path) else {
            return nil
        }
        do {
            try workDirectoryCleaner.removeWorkDirectory(at: result.temporaryWorkDirectoryURL)
            return nil
        } catch {
            return FullLengthONTMHCCleanupDiagnostic(
                kind: .temporaryWorkDirectory,
                retainedDirectoryURL: result.temporaryWorkDirectoryURL,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                publishedArtifactsRemainValid: true
            )
        }
    }

    private func writeNamespacedFASTA(
        sample: FullLengthONTMHCSampleAlignmentInput,
        snapshot: FullLengthONTMHCFASTAInputSnapshot,
        to url: URL,
        namespacedTargets: inout Set<String>
    ) throws -> (
        mappings: [FullLengthONTMHCTargetNamespaceMapping],
        transformation: FullLengthONTMHCInProcessTransformationRecord
    ) {
        let startedAt = Date()
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            throw BuildFailure("Could not create namespaced cluster FASTA at \(url.path).")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var mappings: [FullLengthONTMHCTargetNamespaceMapping] = []
        var currentName: String?
        var currentSequence = ""
        var recordIndex = 0
        let safety = FullLengthONTMHCAlignmentSafety(fileManager: fileManager)

        func flushCurrentRecord() throws {
            guard let currentName else { return }
            try safety.validateClusterRecord(name: currentName, sequence: currentSequence)
            guard recordIndex < sample.clusterRecords.count else {
                throw FullLengthONTMHCAlignmentSafetyError(
                    "Source FASTA and declared cluster records differ for sample '\(sample.sampleID)'."
                )
            }
            let declared = sample.clusterRecords[recordIndex]
            guard currentName == declared.name, currentSequence == declared.sequence else {
                throw FullLengthONTMHCAlignmentSafetyError(
                    "Source FASTA and declared cluster records differ for sample '\(sample.sampleID)'."
                )
            }
            let targetID = "\(sample.sampleID)|\(currentName)"
            guard namespacedTargets.insert(targetID).inserted else {
                throw BuildFailure("Namespaced target collision for '\(targetID)'.")
            }
            mappings.append(.init(originalClusterID: currentName, namespacedTargetID: targetID))
            try handle.write(contentsOf: Data(">\(targetID)\n".utf8))
            let bytes = Array(currentSequence.utf8)
            for start in stride(from: 0, to: bytes.count, by: 80) {
                let end = min(start + 80, bytes.count)
                try handle.write(contentsOf: Data(bytes[start..<end]))
                try handle.write(contentsOf: Data("\n".utf8))
            }
            recordIndex += 1
        }

        try snapshot.url.forEachLineAutoDecompressing { line in
            if line.hasPrefix(">") {
                try flushCurrentRecord()
                currentName = String(line.dropFirst())
                currentSequence = ""
            } else {
                guard currentName != nil else {
                    if line.isEmpty { return }
                    throw FullLengthONTMHCAlignmentSafetyError(
                        "FASTA sequence appears before the first header in \(snapshot.url.path)."
                    )
                }
                currentSequence += line
            }
        }
        try flushCurrentRecord()
        guard recordIndex == sample.clusterRecords.count, recordIndex > 0 else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Source FASTA and declared cluster records differ for sample '\(sample.sampleID)'."
            )
        }
        try handle.synchronize()
        try handle.close()
        let outputDescriptor = try artifactDescriptorProvider.descriptor(
            for: url,
            role: .namespacedClusterFASTA,
            phase: .temporary
        )
        let completedAt = Date()
        let transformation = FullLengthONTMHCInProcessTransformationRecord(
            workflowName: "lungfish-in-process:namespace-mhc-cluster-fasta",
            workflowVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "namespace-mhc-cluster-fasta",
                "--sample-id", sample.sampleID,
                "--separator", "|",
                "--line-width", "80",
                snapshot.url.path,
                url.path,
            ],
            resolvedOptions: [
                "sampleID": sample.sampleID,
                "separator": "|",
                "lineWidth": "80",
                "snapshotFASTAIsAuthoritative": "true",
                "sequenceAlphabet": "IUPAC-DNA",
            ],
            inputs: [snapshot.descriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTime: completedAt.timeIntervalSince(startedAt)
        )
        return (mappings, transformation)
    }

    private func executableURL(named name: String) throws -> URL {
        let explicitlyResolvedURL: URL?
        switch name {
        case "minimap2":
            explicitlyResolvedURL = minimap2ExecutableURL
        case "samtools":
            explicitlyResolvedURL = samtoolsExecutableURL
        default:
            explicitlyResolvedURL = nil
        }
        if let explicitlyResolvedURL {
            guard fileManager.isExecutableFile(atPath: explicitlyResolvedURL.path) else {
                throw BuildFailure("Executable '\(name)' is missing at \(explicitlyResolvedURL.path).")
            }
            return explicitlyResolvedURL
        }
        if let executableDirectoryURL {
            let candidate = executableDirectoryURL.appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: candidate.path) else {
                throw BuildFailure("Executable '\(name)' is missing from \(executableDirectoryURL.path).")
            }
            return candidate
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw BuildFailure("Executable '\(name)' was not found on PATH.")
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        stdoutURL: URL? = nil,
        workingDirectoryURL: URL,
        commandRecords: inout [FullLengthONTMHCCohortAlignmentCommandRecord],
        pathIdentityValidator: (@Sendable () throws -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let runner = FullLengthONTMHCAlignmentProcessRunner(fileManager: fileManager)
        let record = try await runner.execute(.init(
            executableURL: executableURL,
            arguments: arguments,
            inputs: inputs,
            outputs: outputs,
            stdoutURL: stdoutURL,
            workingDirectoryURL: workingDirectoryURL,
            logsDirectoryURL: workingDirectoryURL.appendingPathComponent("logs", isDirectory: true),
            toolVersion: nil,
            temporaryRootURL: workingDirectoryURL,
            pathIdentityValidator: pathIdentityValidator
        ))
        commandRecords.append(record)
        if record.wasCancelled { throw CancellationError() }
        guard record.exitStatus == 0 else {
            throw BuildFailure(
                "\(executableURL.lastPathComponent) failed with exit status \(record.exitStatus): \(record.stderr)"
            )
        }
        guard record.descriptorCaptureErrors.isEmpty else {
            let details = record.descriptorCaptureErrors.map {
                "\($0.path): \($0.message)"
            }.joined(separator: "; ")
            throw BuildFailure(
                "\(executableURL.lastPathComponent) output validation failed after exit status 0: \(details)"
            )
        }
        for output in outputs {
            do {
                try FullLengthONTMHCAlignmentSafety(fileManager: fileManager)
                    .requireRegularFileNoFollow(output, role: "declared process output")
            } catch {
                throw BuildFailure(
                    "\(executableURL.lastPathComponent) exited successfully without creating \(output.path)."
                )
            }
        }
    }

    private func executeToolVersionDiscovery(
        executableURL: URL,
        temporaryWorkDirectoryURL: URL,
        logsDirectoryURL: URL
    ) async throws -> FullLengthONTMHCCohortAlignmentCommandRecord {
        let runner = FullLengthONTMHCAlignmentProcessRunner(fileManager: fileManager)
        return try await runner.execute(.init(
            executableURL: executableURL,
            arguments: ["--version"],
            inputs: [],
            outputs: [],
            stdoutURL: nil,
            workingDirectoryURL: temporaryWorkDirectoryURL,
            logsDirectoryURL: logsDirectoryURL,
            toolVersion: nil,
            temporaryRootURL: temporaryWorkDirectoryURL,
            pathIdentityValidator: nil
        ))
    }

    private func parsedToolVersion(
        toolName: String,
        discoveryCommand rawRecord: FullLengthONTMHCCohortAlignmentCommandRecord
    ) throws -> FullLengthONTMHCToolVersionRecord {
        if rawRecord.wasCancelled { throw CancellationError() }
        guard rawRecord.exitStatus == 0 else {
            throw BuildFailure(
                "Could not discover \(toolName) version (exit \(rawRecord.exitStatus)): \(rawRecord.stderr)"
            )
        }
        guard let version = rawRecord.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw BuildFailure("Could not discover \(toolName) version: empty version output.")
        }
        return FullLengthONTMHCToolVersionRecord(
            toolName: toolName,
            version: version,
            discoveryCommand: rawRecord.replacingToolVersion(with: version)
        )
    }

}

private struct BuildFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

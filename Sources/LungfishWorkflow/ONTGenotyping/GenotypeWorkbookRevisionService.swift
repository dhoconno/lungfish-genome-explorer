import Darwin
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

public enum GenotypeWorkbookRevisionError: Error, LocalizedError, Equatable, Sendable {
    case invalidWorkbook(String)
    case missingRevision(String)
    case missingCurrentWorkbook(String)
    case workbookOverrideFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkbook(let path):
            return "The selected file is not a readable .xlsx workbook: \(path)"
        case .missingRevision(let id):
            return "Workbook revision \(id) does not exist."
        case .missingCurrentWorkbook(let path):
            return "Current workbook does not exist: \(path)"
        case .workbookOverrideFailed(let message):
            return "Could not update current.xlsx from haplotype overrides: \(message)"
        }
    }
}

public struct GenotypeWorkbookHaplotypeCall: Codable, Equatable, Sendable {
    public let sample: String
    public let locus: String
    public let haplotype1: String
    public let haplotype2: String
    public let status: String
    public let notes: String

    public init(
        sample: String,
        locus: String,
        haplotype1: String,
        haplotype2: String,
        status: String,
        notes: String
    ) {
        self.sample = sample
        self.locus = locus
        self.haplotype1 = haplotype1
        self.haplotype2 = haplotype2
        self.status = status
        self.notes = notes
    }

    public static func isWritableCurrentWorkbookLocus(_ locus: String) -> Bool {
        switch canonicalCurrentWorkbookLocus(locus) {
        case "MHC-A", "MHC-B", "MHC-DQ", "MHC-DP":
            return true
        default:
            return false
        }
    }

    public static func canonicalCurrentWorkbookLocus(_ locus: String) -> String {
        let trimmed = locus.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "MHC-DQA" || trimmed == "MHC-DQB" {
            return "MHC-DQ"
        }
        if trimmed == "MHC-DPA" || trimmed == "MHC-DPB" {
            return "MHC-DP"
        }
        return trimmed
    }
}

public struct GenotypeWorkbookRevisionProvenanceContext: Equatable, Sendable {
    public let toolName: String
    public let toolKind: String
    public let argv: [String]
    public let durableReplayArgv: [String]

    public init(
        toolName: String,
        toolKind: String,
        argv: [String],
        durableReplayArgv: [String]? = nil
    ) {
        self.toolName = toolName
        self.toolKind = toolKind
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv ?? argv
    }
}

public struct GenotypeWorkbookRevisionService {
    private enum WorkbookPublicationMechanism {
        case renameSwap
        case journaledThreeRename
    }

    private struct SourceWorkbookWitness {
        let device: dev_t
        let inode: ino_t
        let sizeBytes: Int64
        let sha256: String
    }

    private struct WorkbookOverrideExecutionRecord: Codable {
        let executable: String
        let argv: [String]
        let exitStatus: Int32
        let startedAt: Date
        let completedAt: Date
        let wallTimeSeconds: Double
        let stdout: String
        let stderr: String
    }

    private struct WorkbookRollbackFailureReceipt: Codable {
        let schemaVersion: Int
        let workflow: String
        let createdAt: Date
        let argv: [String]
        let priorGenerationPath: String?
        let failedPublishedGenerationPath: String?
        let originalError: String
        let rollbackError: String
        let exitStatus: Int
    }

    private struct WorkbookCandidateUpdateConfiguration: Codable {
        struct Tint: Codable {
            let red: Double
            let green: Double
            let blue: Double
            let alpha: Double
        }

        struct Sample: Codable {
            let sample: String
            let mappedReadCount: Int?
            let totalReadCount: Int?
            let retainedPercent: Double?

            private enum CodingKeys: String, CodingKey {
                case sample
                case mappedReadCount = "mapped_read_count"
                case totalReadCount = "total_read_count"
                case retainedPercent = "retained_percent"
            }
        }

        struct KnownCall: Codable {
            let callID: String
            let readsBySample: [String: Int]

            private enum CodingKeys: String, CodingKey {
                case callID = "call_id"
                case readsBySample = "reads_by_sample"
            }
        }

        let candidateJSONPath: String?
        let candidateFASTAPath: String?
        let candidateGenBankPath: String?
        let unnameableJSONPath: String?
        let unnameableFASTAPath: String?
        let unnameableGenBankPath: String?
        let usesTwoSheetMHCContract: Bool
        let normalizedUnmatchedRows: [FullLengthONTMHCNormalizedUnmatchedRow]
        let knownAlleleDisplayNames: [String: String]
        let samples: [Sample]
        let knownCalls: [KnownCall]
        let tints: [String: Tint]
        let ooxmlAlphaSemantics: String

        private enum CodingKeys: String, CodingKey {
            case candidateJSONPath = "candidate_json_path"
            case candidateFASTAPath = "candidate_fasta_path"
            case candidateGenBankPath = "candidate_genbank_path"
            case unnameableJSONPath = "unnameable_json_path"
            case unnameableFASTAPath = "unnameable_fasta_path"
            case unnameableGenBankPath = "unnameable_genbank_path"
            case usesTwoSheetMHCContract = "uses_two_sheet_mhc_contract"
            case normalizedUnmatchedRows = "normalized_unmatched_rows"
            case knownAlleleDisplayNames = "known_allele_display_names"
            case samples
            case knownCalls = "known_calls"
            case tints
            case ooxmlAlphaSemantics = "ooxml_alpha_semantics"
        }
    }

    private let fileManager: FileManager
    private let dateProvider: @Sendable () -> Date
    private let userProvider: @Sendable () -> String
    private let pythonExecutableURL: URL?
    private let publicationFailureInjector: (@Sendable (String) throws -> Void)?
    private let bundleCloneAttemptObserver: (@Sendable () -> Void)?
    private let forceBundleCloneFallback: Bool
    private let bundleCopyPrimitive: (@Sendable (URL, URL, UInt32) -> Int32)?
    private let workbookAttestationRootURL: URL?
    private let directorySwapPrimitive: ONTGenotypeDirectoryRenamePrimitive?
    private let directoryMovePrimitive: ONTGenotypeDirectoryRenamePrimitive?
    private let workbookAtomicRenamePrimitive: ONTGenotypeAtomicRenamePrimitive?
    private let workbookMarkerWriteFailureInjector: (@Sendable (String) throws -> Void)?

    public init(
        fileManager: FileManager = .default,
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        userProvider: @escaping @Sendable () -> String = { NSUserName() },
        pythonExecutableURL: URL? = nil,
        publicationFailureInjector: (@Sendable (String) throws -> Void)? = nil,
        bundleCloneAttemptObserver: (@Sendable () -> Void)? = nil,
        forceBundleCloneFallback: Bool = false,
        bundleCopyPrimitive: (@Sendable (URL, URL, UInt32) -> Int32)? = nil,
        workbookAttestationRootURL: URL? = nil,
        directorySwapPrimitive: ONTGenotypeDirectoryRenamePrimitive? = nil,
        directoryMovePrimitive: ONTGenotypeDirectoryRenamePrimitive? = nil,
        workbookAtomicRenamePrimitive: ONTGenotypeAtomicRenamePrimitive? = nil,
        workbookMarkerWriteFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.userProvider = userProvider
        self.pythonExecutableURL = pythonExecutableURL
        self.publicationFailureInjector = publicationFailureInjector
        self.bundleCloneAttemptObserver = bundleCloneAttemptObserver
        self.forceBundleCloneFallback = forceBundleCloneFallback
        self.bundleCopyPrimitive = bundleCopyPrimitive
        self.workbookAttestationRootURL = workbookAttestationRootURL
        self.directorySwapPrimitive = directorySwapPrimitive
        self.directoryMovePrimitive = directoryMovePrimitive
        self.workbookAtomicRenamePrimitive = workbookAtomicRenamePrimitive
        self.workbookMarkerWriteFailureInjector = workbookMarkerWriteFailureInjector
    }

    public func ensureCurrentWorkbook(
        in bundleURL: URL
    ) throws -> ONTGenotypeResultBundleManifest {
        let bundle = bundleURL.standardizedFileURL
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        if let currentWorkbookPath = manifest.currentWorkbookPath {
            let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentWorkbookPath, in: bundle)
            if fileManager.fileExists(atPath: currentURL.path) {
                return manifest
            }
        }

        let primaryURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle)
        let currentURL = defaultCurrentWorkbookURL(in: bundle)
        try fileManager.createDirectory(
            at: currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try replaceFile(at: currentURL, withCopyOf: primaryURL)

        let provenancePath = nextProvenancePath(action: "initial-current-copy", in: bundle)
        let revision = try makeRevision(
            role: .initialCurrentCopy,
            path: relativePath(from: bundle, to: currentURL),
            label: "Initial editable workbook",
            sourceFilename: primaryURL.lastPathComponent,
            predecessorID: nil,
            predecessorPath: relativePath(from: bundle, to: primaryURL),
            workbookURL: currentURL,
            provenancePath: provenancePath
        )
        let updated = manifestWithWorkbookFields(
            manifest,
            currentWorkbookPath: relativePath(from: bundle, to: currentURL),
            revisions: (manifest.workbookRevisions ?? []) + [revision]
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundle)
        try writeProvenance(
            action: "initial-current-copy",
            bundleURL: bundle,
            sourceWorkbookURL: primaryURL,
            previousCurrentURL: nil,
            snapshotURL: nil,
            importedSourceURL: nil,
            newCurrentURL: currentURL,
            manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
            provenancePath: provenancePath,
            startedAt: dateProvider(),
            additionalInputURLs: []
        )
        return updated
    }

    public func applyHaplotypeOverrides(
        _ calls: [GenotypeWorkbookHaplotypeCall],
        annotationSidecarURL: URL?,
        into bundleURL: URL,
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext? = nil
    ) throws -> ONTGenotypeResultBundleManifest {
        let workflowStartedAt = dateProvider()
        let bundle = bundleURL.standardizedFileURL
        try checkCancellation()
        let publicationLock = try DarwinFullLengthONTMHCRunLock.acquire(outputDirectoryURL: bundle)
        defer { publicationLock.release() }
        let workbookPublicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: bundle)
        defer { workbookPublicationLock.release() }
        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: bundle,
            attestationRootURL: workbookAttestationRootURL
        )
        try recoverWorkbookRollbackFailureIfNeeded(for: bundle)
        try validateSourceBundleTree(bundle)
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        let originalManifestData = try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: bundle))
        let sourceWorkbookURL: URL
        if let currentPath = manifest.currentWorkbookPath {
            let candidate = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundle)
            guard fileManager.fileExists(atPath: candidate.path) else {
                throw GenotypeWorkbookRevisionError.missingCurrentWorkbook(candidate.path)
            }
            sourceWorkbookURL = candidate
        } else {
            sourceWorkbookURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle)
        }
        try validateRegularBundleFile(sourceWorkbookURL, in: bundle, role: "workbook update source")
        let candidateInputs = try candidateArtifactInputURLs(from: manifest, in: bundle)
        let sidecar = try loadAnnotationSidecarIfPresent(annotationSidecarURL)
        let configuration = try makeCandidateConfiguration(
            manifest: manifest,
            bundleURL: bundle,
            sidecar: sidecar
        )
        try validateOptionalUpdatesDirectory(in: bundle)
        try checkCancellation()

        let stageDirectory = bundle.deletingLastPathComponent().appendingPathComponent(
            ".\(bundle.lastPathComponent).workbook-update-\(UUID().uuidString).staging",
            isDirectory: true
        )
        try createAdjacentStageDirectory(stageDirectory, for: bundle)
        var removeStageOnExit = true
        defer {
            if removeStageOnExit { try? fileManager.removeItem(at: stageDirectory) }
        }
        try publicationFailureInjector?("after-stage-created")

        let updateID = "\(timestampSlug())-update-current-workbook-\(UUID().uuidString.prefix(8))"
        let callsName = "haplotype-calls.json"
        let configName = "candidate-config.json"
        let runtimeName = "openpyxl-runtime.json"
        let stagedCallsURL = stageDirectory.appendingPathComponent(callsName)
        let stagedConfigurationURL = stageDirectory.appendingPathComponent(configName)
        let stagedRuntimeRecordURL = stageDirectory.appendingPathComponent(runtimeName)
        let stagedSourceWorkbookURL = stageDirectory.appendingPathComponent("source-workbook.xlsx")
        let patchedURL = stageDirectory.appendingPathComponent("current.xlsx")
        let scriptURL = stageDirectory.appendingPathComponent("apply-current-workbook-overrides.py")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeStagedFile(try JSONEncoder().encode(calls), to: stagedCallsURL)
        try writeStagedFile(try encoder.encode(configuration), to: stagedConfigurationURL)
        try writeStagedFile(Data(workbookOverrideScript.utf8), to: scriptURL)
        let sourceWorkbookWitness = try snapshotRegularFileNoFollow(
            from: sourceWorkbookURL,
            to: stagedSourceWorkbookURL
        )
        let scriptArguments = [
            stagedSourceWorkbookURL.path,
            patchedURL.path,
            stagedCallsURL.path,
            annotationSidecarURL?.path ?? "",
            stagedConfigurationURL.path,
        ]
        try checkCancellation()
        let executionRecord = try runPythonScript(scriptURL: scriptURL, arguments: scriptArguments)
        try writeStagedFile(try encoder.encode(executionRecord), to: stagedRuntimeRecordURL)
        try validateWorkbook(patchedURL)
        try publicationFailureInjector?("after-python-before-source-conflict-check")
        try checkCancellation()

        let cloneBundleURL = stageDirectory.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
        try copyBundleTreeNoFollow(from: bundle, to: cloneBundleURL)
        try validateSourceBundleTree(cloneBundleURL)
        let cloneUpdatesURL = cloneBundleURL
            .appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
            .appendingPathComponent(updateID, isDirectory: true)
        try fileManager.createDirectory(at: cloneUpdatesURL, withIntermediateDirectories: true)
        let cloneCallsURL = cloneUpdatesURL.appendingPathComponent(callsName)
        let cloneConfigurationURL = cloneUpdatesURL.appendingPathComponent(configName)
        let cloneRuntimeURL = cloneUpdatesURL.appendingPathComponent(runtimeName)
        let cloneScriptURL = cloneUpdatesURL.appendingPathComponent("apply-current-workbook-overrides.py")
        let cloneSourceWorkbookURL = cloneUpdatesURL.appendingPathComponent("source-workbook.xlsx")
        let clonePatchedWorkbookURL = cloneUpdatesURL.appendingPathComponent("generated-current-workbook.xlsx")
        let cloneAnnotationURL = cloneUpdatesURL.appendingPathComponent("annotations.json")
        try fileManager.copyItem(at: stagedCallsURL, to: cloneCallsURL)
        try fileManager.copyItem(at: stagedConfigurationURL, to: cloneConfigurationURL)
        try fileManager.copyItem(at: stagedRuntimeRecordURL, to: cloneRuntimeURL)
        try fileManager.copyItem(at: scriptURL, to: cloneScriptURL)
        try fileManager.copyItem(at: stagedSourceWorkbookURL, to: cloneSourceWorkbookURL)
        try fileManager.copyItem(at: patchedURL, to: clonePatchedWorkbookURL)

        let cloneCandidateInputs = candidateInputs.map { input in
            ONTGenotypeResultBundle.resolvedURL(for: relativePath(from: bundle, to: input), in: cloneBundleURL)
        }
        var additionalInputs = [cloneCallsURL, cloneConfigurationURL, cloneRuntimeURL, cloneScriptURL] + cloneCandidateInputs
        var pythonInputURLs = [cloneScriptURL, cloneCallsURL, cloneConfigurationURL] + cloneCandidateInputs
        var durableAnnotationPath = ""
        if let annotationSidecarURL, fileManager.fileExists(atPath: annotationSidecarURL.path) {
            try fileManager.copyItem(at: annotationSidecarURL, to: cloneAnnotationURL)
            additionalInputs.append(cloneAnnotationURL)
            pythonInputURLs.append(cloneAnnotationURL)
            durableAnnotationPath = cloneAnnotationURL.path
        }
        let durableExecutableArgv = executionRecord.executable == "/usr/bin/env"
            ? [executionRecord.executable, "python3"]
            : [executionRecord.executable]
        let durableReplayArgv = durableExecutableArgv + [
            cloneScriptURL.path,
            cloneSourceWorkbookURL.path,
            clonePatchedWorkbookURL.path,
            cloneCallsURL.path,
            durableAnnotationPath,
            cloneConfigurationURL.path,
        ]
        let pythonStep = try makePythonProvenanceStep(
            executionRecord: executionRecord,
            sourceWorkbookURL: cloneSourceWorkbookURL,
            patchedWorkbookURL: clonePatchedWorkbookURL,
            inputURLs: pythonInputURLs,
            durableReplayArgv: durableReplayArgv
        )
        let cloneManifest = try importRevisedWorkbook(
            from: clonePatchedWorkbookURL,
            into: cloneBundleURL,
            label: "Applied haplotype overrides",
            provenanceAction: "update-current-workbook",
            additionalInputURLs: additionalInputs,
            additionalExplicitOptions: candidateProvenanceOptions(configuration),
            operationStartedAt: workflowStartedAt,
            additionalProvenanceSteps: [pythonStep],
            provenanceContext: provenanceContext
        )
        guard let provenancePath = cloneManifest.workbookRevisions?.last?.provenancePath else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed("Workbook update provenance path is missing.")
        }
        let cloneManifestURL = ONTGenotypeResultBundle.manifestURL(in: cloneBundleURL)
        let revisedManifestData = try Data(contentsOf: cloneManifestURL)
        let retainedManifestURL = cloneUpdatesURL.appendingPathComponent("revision-manifest.json")
        try revisedManifestData.write(to: retainedManifestURL, options: .atomic)
        let cloneProvenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: cloneBundleURL)
        try relocateProvenancePaths(in: cloneProvenanceURL, from: cloneBundleURL, to: bundle)
        try originalManifestData.write(to: cloneManifestURL, options: .atomic)
        try syncDirectoryTree(cloneBundleURL)
        try checkCancellation()
        try requireUnchangedRegularFileNoFollow(
            sourceWorkbookURL,
            witness: sourceWorkbookWitness
        )

        let oldCurrentPath = manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath
        let newCurrentPath = cloneManifest.currentWorkbookPath ?? cloneManifest.primaryWorkbookPath
        var workbookTransaction = ONTGenotypeWorkbookUpdateTransaction(
            transactionID: updateID,
            finalBundlePath: bundle.path,
            stagingBundlePath: cloneBundleURL.path,
            transactionRootPath: stageDirectory.path,
            rotationTemporaryPath: stageDirectory.appendingPathComponent(
                ".publication-rotation", isDirectory: true
            ).path,
            workflowName: "Genotype Workbook Update",
            toolName: provenanceContext?.toolName ?? "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: provenanceContext?.argv ?? [
                "lungfish-internal", "update-current-workbook", "--bundle", bundle.path,
            ],
            durableReplayArgv: provenanceContext?.durableReplayArgv ?? [
                "lungfish-internal", "update-current-workbook", "--bundle", bundle.path,
            ],
            resolvedOptions: [
                "annotationSidecar": annotationSidecarURL?.path ?? "none",
                "candidateVisibilityFiltersApplied": "false",
                "haplotypeCallCount": String(calls.count),
                "mhcCandidateTints": configuration.tints.keys.sorted().map { key in
                    let tint = configuration.tints[key]!
                    return "\(key)=\(tint.red),\(tint.green),\(tint.blue),\(tint.alpha)"
                }.joined(separator: ";"),
                "ooxmlAlphaSemantics": configuration.ooxmlAlphaSemantics,
            ],
            runtimeIdentity: [
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "runtime": "native-macos",
            ],
            createdAt: workflowStartedAt,
            oldManifest: ONTGenotypeWorkbookUpdateRecovery.descriptor(
                for: originalManifestData,
                path: ONTGenotypeResultBundleManifest.filename
            ),
            newManifest: ONTGenotypeWorkbookUpdateRecovery.descriptor(
                for: revisedManifestData,
                path: ONTGenotypeResultBundleManifest.filename
            ),
            oldCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor(
                path: oldCurrentPath,
                sizeBytes: sourceWorkbookWitness.sizeBytes,
                sha256: sourceWorkbookWitness.sha256
            ),
            newCurrentWorkbook: try ONTGenotypeWorkbookUpdateRecovery.descriptor(
                for: ONTGenotypeResultBundle.resolvedURL(for: newCurrentPath, in: cloneBundleURL),
                path: newCurrentPath
            ),
            oldGenerationIdentity: try ONTGenotypeWorkbookUpdateRecovery.directoryIdentity(
                for: bundle,
                path: bundle.path
            ),
            newGenerationIdentity: try ONTGenotypeWorkbookUpdateRecovery.directoryIdentity(
                for: cloneBundleURL,
                path: cloneBundleURL.path
            ),
            transactionRootIdentity: try ONTGenotypeWorkbookUpdateRecovery.directoryIdentity(
                for: stageDirectory,
                path: stageDirectory.path
            ),
            finalParentIdentity: try ONTGenotypeWorkbookUpdateRecovery.directoryIdentity(
                for: bundle.deletingLastPathComponent(),
                path: bundle.deletingLastPathComponent().path
            )
        )
        guard workbookTransaction.oldManifest != workbookTransaction.newManifest,
              workbookTransaction.oldCurrentWorkbook != workbookTransaction.newCurrentWorkbook else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook publication transaction cannot distinguish the old and new generations."
            )
        }
        try publicationFailureInjector?("before-transaction-marker-source-conflict-check")
        try requireUnchangedRegularFileNoFollow(
            sourceWorkbookURL,
            witness: sourceWorkbookWitness
        )
        workbookTransaction = try ONTGenotypeWorkbookUpdateRecovery.createAttestation(
            for: workbookTransaction,
            attestationRootURL: workbookAttestationRootURL
        )
        do {
            try ONTGenotypeWorkbookUpdateRecovery.write(
                workbookTransaction,
                for: bundle,
                attestationRootURL: workbookAttestationRootURL,
                atomicRenamePrimitive: workbookAtomicRenamePrimitive,
                markerWriteFailureInjector: workbookMarkerWriteFailureInjector
            )
        } catch let error as ONTGenotypeWorkbookUpdateRecoveryError {
            if case .recoveryRequired = error {
                removeStageOnExit = false
                throw error
            }
            try? ONTGenotypeWorkbookUpdateRecovery.removeUnpublishedAttestation(
                for: workbookTransaction,
                attestationRootURL: workbookAttestationRootURL
            )
            throw error
        } catch {
            try? ONTGenotypeWorkbookUpdateRecovery.removeUnpublishedAttestation(
                for: workbookTransaction,
                attestationRootURL: workbookAttestationRootURL
            )
            throw error
        }
        do {
            try publicationFailureInjector?("after-transaction-marker-hard-stop")
        } catch {
            removeStageOnExit = false
            throw error
        }

        do {
            try publicationFailureInjector?("before-exchange-source-conflict-check")
            try requireUnchangedRegularFileNoFollow(
                sourceWorkbookURL,
                witness: sourceWorkbookWitness
            )
        } catch {
            try ONTGenotypeWorkbookUpdateRecovery.discardPreparedTransactionAssumingLock(
                workbookTransaction,
                for: bundle,
                attestationRootURL: workbookAttestationRootURL
            )
            throw error
        }
        removeStageOnExit = false

        let publicationStartedAt = Date()
        try ONTGenotypeWorkbookUpdateRecovery.validatePreparedDirectoryIdentitiesAssumingLock(
            workbookTransaction,
            for: bundle
        )
        let publicationMechanism = try exchangeDirectoriesNoSync(
            cloneBundleURL,
            bundle,
            transaction: workbookTransaction,
            protectedOldWorkbookURL: sourceWorkbookURL,
            protectedOldWorkbookWitness: sourceWorkbookWitness
        )
        try ONTGenotypeWorkbookUpdateRecovery.validateExchangedDirectoryIdentitiesAssumingLock(
            workbookTransaction,
            for: bundle
        )
        let retiredOldWorkbookURL = cloneBundleURL.appendingPathComponent(
            workbookTransaction.oldCurrentWorkbook.path
        )
        func requireRetiredOldWorkbookUnchanged() throws {
            try requireUnchangedRegularFileNoFollow(
                retiredOldWorkbookURL,
                witness: sourceWorkbookWitness
            )
        }
        try syncDirectory(bundle.deletingLastPathComponent())
        let publicationCompletedAt = Date()
        do {
            try publicationFailureInjector?("after-exchange-hard-stop")
        } catch {
            throw error
        }
        var finalManifestCommitted = false
        do {
            try requireRetiredOldWorkbookUnchanged()
            try publicationFailureInjector?("post-exchange")
            try publicationFailureInjector?("before-final-provenance")
            let finalProvenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: bundle)
            try appendFinalPublicationStep(
                to: finalProvenanceURL,
                bundleURL: bundle,
                workflowStartedAt: workflowStartedAt,
                publicationStartedAt: publicationStartedAt,
                publicationCompletedAt: publicationCompletedAt,
                mechanism: publicationMechanism
            )
            try syncFile(finalProvenanceURL)
            try syncDirectoryTree(bundle)
            try publicationFailureInjector?("before-revision-manifest")
            try requireRetiredOldWorkbookUnchanged()
            let finalManifestURL = ONTGenotypeResultBundle.manifestURL(in: bundle)
            try revisedManifestData.write(to: finalManifestURL, options: .atomic)
            try syncFile(finalManifestURL)
            try syncDirectory(bundle)
            finalManifestCommitted = true
            try publicationFailureInjector?("after-revision-manifest-hard-stop")
            do {
                try requireRetiredOldWorkbookUnchanged()
            } catch {
                let manualEditConflict = error
                _ = try exchangeDirectoriesNoSync(
                    cloneBundleURL,
                    bundle,
                    transaction: workbookTransaction,
                    protectedOldWorkbookURL: nil,
                    protectedOldWorkbookWitness: nil
                )
                try ONTGenotypeWorkbookUpdateRecovery.validatePreparedDirectoryIdentitiesAssumingLock(
                    workbookTransaction,
                    for: bundle
                )
                try syncDirectory(bundle.deletingLastPathComponent())
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: bundle,
                    attestationRootURL: workbookAttestationRootURL
                )
                removeStageOnExit = false
                throw manualEditConflict
            }
            try ONTGenotypeWorkbookUpdateRecovery.finalizeCommittedTransactionAssumingLock(
                workbookTransaction,
                for: bundle,
                attestationRootURL: workbookAttestationRootURL
            )
            removeStageOnExit = false
            return try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: revisedManifestData)
        } catch {
            if finalManifestCommitted { throw error }
            let publicationError = error
            do {
                try publicationFailureInjector?("before-rollback-exchange")
                try ONTGenotypeWorkbookUpdateRecovery.validateExchangedDirectoryIdentitiesAssumingLock(
                    workbookTransaction,
                    for: bundle
                )
                _ = try exchangeDirectoriesNoSync(
                    cloneBundleURL,
                    bundle,
                    transaction: workbookTransaction,
                    protectedOldWorkbookURL: nil,
                    protectedOldWorkbookWitness: nil
                )
                try ONTGenotypeWorkbookUpdateRecovery.validatePreparedDirectoryIdentitiesAssumingLock(
                    workbookTransaction,
                    for: bundle
                )
            } catch let rollbackError {
                let receiptURL = try retainWorkbookRollbackFailureGenerations(
                    liveBundleURL: bundle,
                    priorBundleURL: cloneBundleURL,
                    originalError: publicationError,
                    rollbackError: rollbackError
                )
                removeStageOnExit = false
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Workbook publication failed (\(publicationError.localizedDescription)); rollback failed (\(rollbackError.localizedDescription)). Recovery receipt: \(receiptURL.path)"
                )
            }
            do {
                try syncDirectory(bundle.deletingLastPathComponent())
            } catch {
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: bundle,
                    attestationRootURL: workbookAttestationRootURL
                )
                removeStageOnExit = false
                throw publicationError
            }
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: bundle,
                attestationRootURL: workbookAttestationRootURL
            )
            removeStageOnExit = false
            throw publicationError
        }
    }

    public func importRevisedWorkbook(
        from sourceURL: URL,
        into bundleURL: URL,
        label: String? = nil,
        provenanceAction: String = "import",
        additionalInputURLs: [URL] = [],
        additionalExplicitOptions: [String: ParameterValue] = [:],
        operationStartedAt: Date? = nil,
        additionalProvenanceSteps: [ProvenanceStep] = [],
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext? = nil
    ) throws -> ONTGenotypeResultBundleManifest {
        let source = sourceURL.standardizedFileURL
        try validateWorkbook(source)

        let bundle = bundleURL.standardizedFileURL
        let originalManifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        let originalCurrentData: Data?
        if let originalCurrentPath = originalManifest.currentWorkbookPath {
            originalCurrentData = try? Data(
                contentsOf: ONTGenotypeResultBundle.resolvedURL(for: originalCurrentPath, in: bundle)
            )
        } else {
            originalCurrentData = nil
        }
        let startedAt = operationStartedAt ?? dateProvider()
        var manifest = try ensureCurrentWorkbook(in: bundle)
        let currentPath = manifest.currentWorkbookPath ?? defaultCurrentWorkbookRelativePath
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundle)
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw GenotypeWorkbookRevisionError.missingCurrentWorkbook(currentURL.path)
        }
        let previousCurrentRevision = latestCurrentWorkbookRevision(in: manifest)
        let provenancePath = nextProvenancePath(action: provenanceAction, in: bundle)

        do {
            let currentSHA256 = try ProvenanceFileHasher.sha256(of: currentURL)
            let snapshotRole: ONTGenotypeWorkbookRevisionRole = .externalEditSnapshot
            let snapshotRevision = try snapshotCurrentWorkbook(
                currentURL: currentURL,
                bundleURL: bundle,
                label: previousCurrentRevision?.sha256 == currentSHA256
                    ? "Previous current workbook"
                    : "External workbook edit before import",
                role: snapshotRole,
                predecessor: previousCurrentRevision,
                provenancePath: provenancePath
            )
            try replaceFile(at: currentURL, withCopyOf: source)
            let importedRevision = try makeRevision(
                role: .imported,
                path: currentPath,
                label: normalizedLabel(label, fallback: "Imported workbook"),
                sourceFilename: source.lastPathComponent,
                predecessorID: snapshotRevision.id,
                predecessorPath: snapshotRevision.path,
                workbookURL: currentURL,
                provenancePath: provenancePath
            )
            manifest = manifestWithWorkbookFields(
                manifest,
                currentWorkbookPath: currentPath,
                revisions: (manifest.workbookRevisions ?? []) + [snapshotRevision, importedRevision]
            )
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
            try writeProvenance(
                action: provenanceAction,
                bundleURL: bundle,
                sourceWorkbookURL: try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle),
                previousCurrentURL: currentURL,
                snapshotURL: ONTGenotypeResultBundle.resolvedURL(for: snapshotRevision.path, in: bundle),
                importedSourceURL: source,
                newCurrentURL: currentURL,
                manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
                provenancePath: provenancePath,
                startedAt: startedAt,
                additionalInputURLs: additionalInputURLs,
                additionalExplicitOptions: additionalExplicitOptions,
                additionalProvenanceSteps: additionalProvenanceSteps,
                provenanceContext: provenanceContext
            )
            return manifest
        } catch {
            if let originalCurrentData, let originalCurrentPath = originalManifest.currentWorkbookPath {
                let originalCurrentURL = ONTGenotypeResultBundle.resolvedURL(for: originalCurrentPath, in: bundle)
                try? fileManager.createDirectory(
                    at: originalCurrentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? originalCurrentData.write(to: originalCurrentURL, options: .atomic)
            } else if let originalCurrentData {
                try? originalCurrentData.write(to: currentURL, options: .atomic)
            } else if fileManager.fileExists(atPath: currentURL.path) && originalManifest.currentWorkbookPath == nil {
                try? fileManager.removeItem(at: currentURL)
            }
            try? ONTGenotypeResultBundle.writeManifest(originalManifest, to: bundle)
            throw error
        }
    }

    public func restoreWorkbookRevision(
        id revisionID: String,
        in bundleURL: URL
    ) throws -> ONTGenotypeResultBundleManifest {
        let bundle = bundleURL.standardizedFileURL
        var manifest = try ensureCurrentWorkbook(in: bundle)
        guard let revision = manifest.workbookRevisions?.first(where: { $0.id == revisionID }) else {
            throw GenotypeWorkbookRevisionError.missingRevision(revisionID)
        }
        let sourceURL = ONTGenotypeResultBundle.resolvedURL(for: revision.path, in: bundle)
        try validateWorkbook(sourceURL)
        let currentPath = manifest.currentWorkbookPath ?? defaultCurrentWorkbookRelativePath
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundle)
        let startedAt = dateProvider()
        let provenancePath = nextProvenancePath(action: "restore", in: bundle)
        let snapshotRevision = try snapshotCurrentWorkbook(
            currentURL: currentURL,
            bundleURL: bundle,
            label: "Previous current workbook before restore",
            role: .externalEditSnapshot,
            predecessor: latestCurrentWorkbookRevision(in: manifest),
            provenancePath: provenancePath
        )
        try replaceFile(at: currentURL, withCopyOf: sourceURL)
        let restoredRevision = try makeRevision(
            role: .restored,
            path: currentPath,
            label: "Restored \(revision.label)",
            sourceFilename: sourceURL.lastPathComponent,
            predecessorID: snapshotRevision.id,
            predecessorPath: snapshotRevision.path,
            workbookURL: currentURL,
            provenancePath: provenancePath
        )
        manifest = manifestWithWorkbookFields(
            manifest,
            currentWorkbookPath: currentPath,
            revisions: (manifest.workbookRevisions ?? []) + [snapshotRevision, restoredRevision]
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        try writeProvenance(
            action: "restore",
            bundleURL: bundle,
            sourceWorkbookURL: try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle),
            previousCurrentURL: currentURL,
            snapshotURL: ONTGenotypeResultBundle.resolvedURL(for: snapshotRevision.path, in: bundle),
            importedSourceURL: sourceURL,
            newCurrentURL: currentURL,
            manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
            provenancePath: provenancePath,
            startedAt: startedAt,
            additionalInputURLs: []
        )
        return manifest
    }

    private func runPythonScript(
        scriptURL: URL,
        arguments: [String]
    ) throws -> WorkbookOverrideExecutionRecord {
        let process = Process()
        let executable: String
        let processArguments: [String]
        if let pythonExecutableURL {
            process.executableURL = pythonExecutableURL
            executable = pythonExecutableURL.path
            processArguments = [scriptURL.path] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            executable = "/usr/bin/env"
            processArguments = ["python3", scriptURL.path] + arguments
        }
        process.arguments = processArguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let startedAt = Date()
        try process.run()
        var cancelled = false
        while process.isRunning {
            if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
                cancelled = true
                process.terminate()
                break
            }
            Darwin.usleep(50_000)
        }
        process.waitUntilExit()
        let completedAt = Date()
        let wallTime = completedAt.timeIntervalSince(startedAt)
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? out.trimmingCharacters(in: .whitespacesAndNewlines)
                : err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(message)
        }
        return WorkbookOverrideExecutionRecord(
            executable: executable,
            argv: [executable] + processArguments,
            exitStatus: process.terminationStatus,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTimeSeconds: wallTime,
            stdout: out,
            stderr: err
        )
    }

    private func loadAnnotationSidecarIfPresent(_ url: URL?) throws -> GenotypeAnnotationSidecar? {
        guard let url, fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(GenotypeAnnotationSidecar.self, from: Data(contentsOf: url))
    }

    private func makeCandidateConfiguration(
        manifest: ONTGenotypeResultBundleManifest,
        bundleURL: URL,
        sidecar: GenotypeAnnotationSidecar?
    ) throws -> WorkbookCandidateUpdateConfiguration {
        let artifacts = manifest.mhcCandidateArtifacts
        var normalizedUnmatchedRows: [FullLengthONTMHCNormalizedUnmatchedRow] = []
        var workbookSamples: [WorkbookCandidateUpdateConfiguration.Sample] = []
        var workbookKnownCalls: [WorkbookCandidateUpdateConfiguration.KnownCall] = []
        let knownAlleleDisplayNames = try loadKnownAlleleDisplayNames(
            from: manifest.mhcReferenceVisualizations,
            in: bundleURL
        )
        if let artifacts {
            let workbookProjection = try loadWorkbookCSVProjection(
                manifest: manifest,
                bundleURL: bundleURL
            )
            workbookSamples = workbookProjection.samples
            workbookKnownCalls = workbookProjection.knownCalls
            guard artifacts.schemaVersion == 1 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Unsupported MHC candidate artifact schema \(artifacts.schemaVersion)."
                )
            }
            guard Self.allPresentOrAllAbsent([
                artifacts.candidateJSON, artifacts.candidateFASTA, artifacts.candidateGenBank,
            ]), Self.allPresentOrAllAbsent([
                artifacts.unnameableJSON, artifacts.unnameableFASTA, artifacts.unnameableGenBank,
            ]) else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "MHC candidate JSON, FASTA, and GenBank artifacts must be declared as complete sets."
                )
            }
            if let candidateJSON = artifacts.candidateJSON {
                let document = try decodeAndValidate(
                    ONTMHCCandidateAllelesDocument.self,
                    reference: candidateJSON,
                    in: bundleURL
                )
                try validateCandidateDocumentSchema(document.schemaVersion, label: "candidate")
                try validateArtifact(document.sequenceFASTA, equals: artifacts.candidateFASTA, label: "candidate FASTA")
                try validateCandidateLabels(document.candidates)
            }
            if let unnameableJSON = artifacts.unnameableJSON {
                let document = try decodeAndValidate(
                    ONTMHCUnnameableClustersDocument.self,
                    reference: unnameableJSON,
                    in: bundleURL
                )
                try validateCandidateDocumentSchema(document.schemaVersion, label: "un-nameable")
                try validateArtifact(document.sequenceFASTA, equals: artifacts.unnameableFASTA, label: "un-nameable FASTA")
            }
            let candidates = try artifacts.candidateJSON.map {
                try decodeAndValidate(
                    ONTMHCCandidateAllelesDocument.self,
                    reference: $0,
                    in: bundleURL
                )
            }
            let unnameable = try artifacts.unnameableJSON.map {
                try decodeAndValidate(
                    ONTMHCUnnameableClustersDocument.self,
                    reference: $0,
                    in: bundleURL
                )
            }
            if let schemaVersion = candidates?.schemaVersion ?? unnameable?.schemaVersion {
                if let candidates, let unnameable,
                   candidates.schemaVersion != unnameable.schemaVersion {
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                        "Candidate and un-nameable workbook documents must use the same schema version."
                    )
                }
                let placeholderFASTA = candidates?.sequenceFASTA ?? unnameable!.sequenceFASTA
                let candidateDocument = candidates ?? ONTMHCCandidateAllelesDocument(
                    schemaVersion: schemaVersion,
                    createdAt: unnameable?.createdAt ?? "",
                    thresholds: unnameable?.thresholds ?? .defaults,
                    inputs: [],
                    evidence: [],
                    sequenceFASTA: placeholderFASTA,
                    candidates: [],
                    observations: []
                )
                let unnameableDocument = unnameable ?? ONTMHCUnnameableClustersDocument(
                    schemaVersion: schemaVersion,
                    createdAt: candidates?.createdAt ?? "",
                    thresholds: candidates?.thresholds ?? .defaults,
                    sequenceFASTA: placeholderFASTA,
                    clusters: [],
                    observations: []
                )
                let projection = try FullLengthONTMHCWorkbookProjection(
                    candidateDocument: candidateDocument,
                    unnameableDocument: unnameableDocument,
                    sampleOrder: Array(Set((candidateDocument.observations + unnameableDocument.observations).map(\.sampleID))).sorted()
                )
                normalizedUnmatchedRows = try projection.normalizedUnmatchedRows(
                    candidateFASTARecords: try artifacts.candidateFASTA.map {
                        try FullLengthONTMHCClusterGenotyper.readFASTARecords(
                            from: try validatedArtifactURL($0, in: bundleURL)
                        )
                    } ?? [],
                    unnameableFASTARecords: try artifacts.unnameableFASTA.map {
                        try FullLengthONTMHCClusterGenotyper.readFASTARecords(
                            from: try validatedArtifactURL($0, in: bundleURL)
                        )
                    } ?? [],
                    candidateGenBankRecords: try artifacts.candidateGenBank.map {
                        try GenBankReader(url: try validatedArtifactURL($0, in: bundleURL)).readAllSync()
                    } ?? [],
                    unnameableGenBankRecords: try artifacts.unnameableGenBank.map {
                        try GenBankReader(url: try validatedArtifactURL($0, in: bundleURL)).readAllSync()
                    } ?? [],
                    knownAlleleDisplayNames: knownAlleleDisplayNames
                )
            }
        }

        let settings = sidecar?.settings.mhcCandidateDisplay ?? .default
        let tints: [String: WorkbookCandidateUpdateConfiguration.Tint] = Dictionary(
            uniqueKeysWithValues: ONTMHCCandidateTintCategory.allCases.map { category in
            let color = settings.tints[category] ?? ONTMHCCandidateDisplaySettings.defaultTints[category]!
            return (
                category.rawValue,
                WorkbookCandidateUpdateConfiguration.Tint(
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    alpha: color.alpha
                )
            )
        })
        return WorkbookCandidateUpdateConfiguration(
            candidateJSONPath: artifacts?.candidateJSON.map { ONTGenotypeResultBundle.resolvedURL(for: $0.path, in: bundleURL).path },
            candidateFASTAPath: artifacts?.candidateFASTA.map { ONTGenotypeResultBundle.resolvedURL(for: $0.path, in: bundleURL).path },
            candidateGenBankPath: artifacts?.candidateGenBank.map { ONTGenotypeResultBundle.resolvedURL(for: $0.path, in: bundleURL).path },
            unnameableJSONPath: artifacts?.unnameableJSON.map { ONTGenotypeResultBundle.resolvedURL(for: $0.path, in: bundleURL).path },
            unnameableFASTAPath: artifacts?.unnameableFASTA.map { ONTGenotypeResultBundle.resolvedURL(for: $0.path, in: bundleURL).path },
            unnameableGenBankPath: artifacts?.unnameableGenBank.map { ONTGenotypeResultBundle.resolvedURL(for: $0.path, in: bundleURL).path },
            usesTwoSheetMHCContract: artifacts != nil,
            normalizedUnmatchedRows: normalizedUnmatchedRows,
            knownAlleleDisplayNames: knownAlleleDisplayNames,
            samples: workbookSamples,
            knownCalls: workbookKnownCalls,
            tints: tints,
            ooxmlAlphaSemantics: "The leading OOXML ARGB byte is alpha: 00 is transparent and FF is opaque; RGB and alpha are rounded from the exact bundle RGBA values."
        )
    }

    private static func allPresentOrAllAbsent<T>(_ values: [T?]) -> Bool {
        values.allSatisfy { $0 == nil } || values.allSatisfy { $0 != nil }
    }

    private func loadWorkbookCSVProjection(
        manifest: ONTGenotypeResultBundleManifest,
        bundleURL: URL
    ) throws -> (
        samples: [WorkbookCandidateUpdateConfiguration.Sample],
        knownCalls: [WorkbookCandidateUpdateConfiguration.KnownCall]
    ) {
        let longURL = try validatedWorkbookCSVURL(
            manifest.longSummaryCSVPath,
            field: "long_summary_csv_path",
            in: bundleURL
        )
        let sampleURL = try validatedWorkbookCSVURL(
            manifest.sampleSummaryCSVPath,
            field: "sample_summary_csv_path",
            in: bundleURL
        )
        let longRows = try workbookCSVRows(
            at: longURL,
            requiredHeaders: ["sample", "genotype", "passed_unique_reads"]
        )
        let sampleRows = try workbookCSVRows(
            at: sampleURL,
            requiredHeaders: ["sample"]
        )

        var knownReads: [String: [String: Int]] = [:]
        var reportSamples: [String: (mapped: Int, total: Int?, retainedPercent: Double?)] = [:]
        for row in longRows {
            let sample = row["sample", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let callID = row["genotype", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sample.isEmpty, !callID.isEmpty else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Full-length MHC long-summary CSV contains an empty sample or genotype."
                )
            }
            let reads = try requiredWorkbookCSVInt(row["passed_unique_reads"], field: "passed_unique_reads")
            knownReads[callID, default: [:]][sample, default: 0] += reads
            let total = try optionalWorkbookCSVInt(row["sample_total_reads"], field: "sample_total_reads")
            let retained = try optionalWorkbookCSVDouble(
                row["sample_unique_retained_percent"],
                field: "sample_unique_retained_percent"
            )
            let current = reportSamples[sample]
            reportSamples[sample] = (
                mapped: (current?.mapped ?? 0) + reads,
                total: current?.total ?? total,
                retainedPercent: current?.retainedPercent ?? retained
            )
        }

        var samples: [WorkbookCandidateUpdateConfiguration.Sample] = []
        var seenSamples = Set<String>()
        for row in sampleRows {
            let sample = row["sample", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sample.isEmpty, seenSamples.insert(sample).inserted else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Full-length MHC sample-summary CSV contains an empty or duplicate sample."
                )
            }
            let mapped = try optionalWorkbookCSVInt(
                row["passed_unique_reads"] ?? row["passed_alignments"],
                field: "passed_unique_reads"
            ) ?? reportSamples[sample]?.mapped
            let total = try optionalWorkbookCSVInt(row["sample_total_reads"], field: "sample_total_reads")
                ?? reportSamples[sample]?.total
            let retained = try optionalWorkbookCSVDouble(
                row["sample_unique_retained_percent"],
                field: "sample_unique_retained_percent"
            ) ?? reportSamples[sample]?.retainedPercent
            samples.append(.init(
                sample: sample,
                mappedReadCount: mapped,
                totalReadCount: total,
                retainedPercent: retained
            ))
        }
        for sample in reportSamples.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where seenSamples.insert(sample).inserted {
            let summary = reportSamples[sample]!
            samples.append(.init(
                sample: sample,
                mappedReadCount: summary.mapped,
                totalReadCount: summary.total,
                retainedPercent: summary.retainedPercent
            ))
        }
        let knownCalls = knownReads.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).map {
            WorkbookCandidateUpdateConfiguration.KnownCall(
                callID: $0,
                readsBySample: knownReads[$0] ?? [:]
            )
        }
        return (samples, knownCalls)
    }

    private func validatedWorkbookCSVURL(
        _ path: String,
        field: String,
        in bundleURL: URL
    ) throws -> URL {
        let url: URL
        do {
            url = try BundleManifest.validatedBundleMemberURL(for: path, in: bundleURL, field: field)
            try validateRegularBundleFile(url, in: bundleURL, role: "workbook \(field)")
        } catch {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(error.localizedDescription)
        }
        return url
    }

    private func workbookCSVRows(
        at url: URL,
        requiredHeaders: Set<String>
    ) throws -> [[String: String]] {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not read workbook CSV input \(url.path): \(error.localizedDescription)"
            )
        }
        let lines = content.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard let headerLine = lines.first else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed("Workbook CSV input is empty: \(url.path)")
        }
        let headers = DelimitedLineParser.fields(in: headerLine, delimiter: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(headers).count == headers.count,
              requiredHeaders.isSubset(of: Set(headers)) else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook CSV input has missing or duplicate headers: \(url.path)"
            )
        }
        return try lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { line in
            let fields = DelimitedLineParser.fields(in: line, delimiter: ",")
            guard fields.count == headers.count else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Workbook CSV row has \(fields.count) fields; expected \(headers.count): \(url.path)"
                )
            }
            return Dictionary(uniqueKeysWithValues: zip(headers, fields))
        }
    }

    private func requiredWorkbookCSVInt(_ value: String?, field: String) throws -> Int {
        guard let parsed = try optionalWorkbookCSVInt(value, field: field) else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed("Workbook CSV field \(field) is required.")
        }
        return parsed
    }

    private func optionalWorkbookCSVInt(_ value: String?, field: String) throws -> Int? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let parsed = Int(text), parsed >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed("Workbook CSV field \(field) is not a nonnegative integer.")
        }
        return parsed
    }

    private func optionalWorkbookCSVDouble(_ value: String?, field: String) throws -> Double? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let parsed = Double(text), parsed.isFinite else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed("Workbook CSV field \(field) is not finite numeric data.")
        }
        return parsed
    }

    private func loadKnownAlleleDisplayNames(
        from artifacts: ONTMHCReferenceVisualizationArtifacts?,
        in bundleURL: URL
    ) throws -> [String: String] {
        guard let artifacts else { return [:] }
        guard artifacts.schemaVersion == 1 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Unsupported MHC reference visualization schema \(artifacts.schemaVersion)."
            )
        }
        let reference = artifacts.recordsJSON
        let url = try validatedArtifactURL(reference, in: bundleURL)
        let document: ONTMHCReferenceVisualizationArtifact
        do {
            document = try JSONDecoder().decode(
                ONTMHCReferenceVisualizationArtifact.self,
                from: Data(contentsOf: url)
            ).validated()
        } catch {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Malformed MHC reference visualization artifact \(reference.path): \(error.localizedDescription)"
            )
        }
        guard document.records.count == artifacts.recordCount else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "MHC reference visualization record count does not match the manifest."
            )
        }
        return Dictionary(uniqueKeysWithValues: document.records.map { record in
            let trimmed = record.alleleName.trimmingCharacters(in: .whitespacesAndNewlines)
            return (record.rawReferenceID, trimmed.isEmpty ? record.rawReferenceID : trimmed)
        })
    }

    private func validateCandidateDocumentSchema(_ schemaVersion: Int, label: String) throws {
        guard schemaVersion == 1 || schemaVersion == 2 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Unsupported \(label) workbook document schema \(schemaVersion)."
            )
        }
    }

    private func candidateArtifactInputURLs(
        from manifest: ONTGenotypeResultBundleManifest,
        in bundleURL: URL
    ) throws -> [URL] {
        guard let artifacts = manifest.mhcCandidateArtifacts else { return [] }
        let references = [
            artifacts.candidateJSON,
            artifacts.candidateFASTA,
            artifacts.candidateGenBank,
            artifacts.unnameableJSON,
            artifacts.unnameableFASTA,
            artifacts.unnameableGenBank,
            manifest.mhcReferenceVisualizations?.recordsJSON,
        ].compactMap { $0 }
        for reference in references {
            _ = try validatedArtifactURL(reference, in: bundleURL)
        }
        let csvURLs = try [
            (manifest.longSummaryCSVPath, "long_summary_csv_path"),
            (manifest.sampleSummaryCSVPath, "sample_summary_csv_path"),
        ].map { path, field in
            try validatedWorkbookCSVURL(path, field: field, in: bundleURL)
        }
        return references.map { ONTGenotypeResultBundle.resolvedURL(for: $0.path, in: bundleURL) }
            + csvURLs
    }

    private func decodeAndValidate<T: Decodable>(
        _ type: T.Type,
        reference: ONTMHCArtifactReference,
        in bundleURL: URL
    ) throws -> T {
        let url = try validatedArtifactURL(reference, in: bundleURL)
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Malformed MHC candidate artifact \(reference.path): \(error.localizedDescription)"
            )
        }
    }

    private func validatedArtifactURL(
        _ reference: ONTMHCArtifactReference,
        in bundleURL: URL
    ) throws -> URL {
        let url = ONTGenotypeResultBundle.resolvedURL(for: reference.path, in: bundleURL)
        do {
            try validateRegularBundleFile(url, in: bundleURL, role: "workbook candidate input")
            guard Int64(try ProvenanceFileHasher.fileSize(of: url)) == reference.sizeBytes,
                  try ProvenanceFileHasher.sha256(of: url) == reference.sha256 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "MHC candidate artifact checksum or size does not match the manifest: \(reference.path)"
                )
            }
            return url
        } catch let error as GenotypeWorkbookRevisionError {
            throw error
        } catch {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(error.localizedDescription)
        }
    }

    private func validateRegularBundleFile(_ url: URL, in bundleURL: URL, role: String) throws {
        let safety = FullLengthONTMHCAlignmentSafety()
        try safety.requireDirectoryNoFollow(bundleURL, role: "genotype bundle")
        let descriptor = try safety.openRegularFileNoFollow(url, within: bundleURL, role: role)
        Darwin.close(descriptor)
    }

    private func validateArtifact(
        _ documentReference: ONTMHCArtifactReference,
        equals manifestReference: ONTMHCArtifactReference?,
        label: String
    ) throws {
        guard documentReference == manifestReference else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "The \(label) reference in JSON does not match the bundle manifest."
            )
        }
    }

    private func validateCandidateLabels(_ candidates: [ONTMHCCandidateRecord]) throws {
        for candidate in candidates {
            switch candidate.classification {
            case .novel:
                guard candidate.snpCount > 0,
                      candidate.provisionalName.hasSuffix("_\(candidate.snpCount)nt_nov") else {
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                        "Candidate \(candidate.stableClusterID) has a prohibited or non-authoritative novel label."
                    )
                }
            case .extension:
                guard candidate.provisionalName.hasSuffix("_ext") else {
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                        "Candidate \(candidate.stableClusterID) has a non-authoritative extension label."
                    )
                }
            }
        }
    }

    private func checkCancellation() throws {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            throw CancellationError()
        }
    }

    private var defaultCurrentWorkbookRelativePath: String {
        "artifacts/workbooks/current.xlsx"
    }

    private func defaultCurrentWorkbookURL(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    private func snapshotCurrentWorkbook(
        currentURL: URL,
        bundleURL: URL,
        label: String,
        role: ONTGenotypeWorkbookRevisionRole,
        predecessor: ONTGenotypeWorkbookRevision?,
        provenancePath: String
    ) throws -> ONTGenotypeWorkbookRevision {
        let snapshotURL = revisionsDirectory(in: bundleURL)
            .appendingPathComponent("\(timestampSlug())-\(safeFilenameStem(label))-\(UUID().uuidString.prefix(8)).xlsx")
        try fileManager.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: currentURL, to: snapshotURL)
        return try makeRevision(
            role: role,
            path: relativePath(from: bundleURL, to: snapshotURL),
            label: label,
            sourceFilename: currentURL.lastPathComponent,
            predecessorID: predecessor?.id,
            predecessorPath: predecessor?.path,
            workbookURL: snapshotURL,
            provenancePath: provenancePath
        )
    }

    private func makeRevision(
        role: ONTGenotypeWorkbookRevisionRole,
        path: String,
        label: String,
        sourceFilename: String?,
        predecessorID: String?,
        predecessorPath: String?,
        workbookURL: URL,
        provenancePath: String?
    ) throws -> ONTGenotypeWorkbookRevision {
        ONTGenotypeWorkbookRevision(
            id: "\(role.rawValue)-\(UUID().uuidString)",
            role: role,
            path: path,
            label: label,
            sourceFilename: sourceFilename,
            createdAt: ISO8601DateFormatter().string(from: dateProvider()),
            user: userProvider(),
            predecessorID: predecessorID,
            predecessorPath: predecessorPath,
            sha256: try ProvenanceFileHasher.sha256(of: workbookURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: workbookURL)),
            provenancePath: provenancePath
        )
    }

    private func writeProvenance(
        action: String,
        bundleURL: URL,
        sourceWorkbookURL: URL,
        previousCurrentURL: URL?,
        snapshotURL: URL?,
        importedSourceURL: URL?,
        newCurrentURL: URL,
        manifestURL: URL,
        provenancePath: String,
        startedAt: Date,
        additionalInputURLs: [URL],
        additionalExplicitOptions: [String: ParameterValue] = [:],
        additionalProvenanceSteps: [ProvenanceStep] = [],
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext? = nil
    ) throws {
        let completedAt = dateProvider()
        let inputURLs = ([sourceWorkbookURL, previousCurrentURL, importedSourceURL].compactMap { $0 } + additionalInputURLs)
        let outputURLs = [snapshotURL, newCurrentURL, manifestURL].compactMap { $0 }
        let inputs = try inputURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .input) }
        let outputs = try outputURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .output) }
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: bundleURL)
        let provenanceDescriptor = ProvenanceFileDescriptor(path: provenanceURL.path, role: .log)
        let defaultArgv = [
            "Lungfish.app",
            "genotype-workbook",
            action,
            "--bundle", bundleURL.path,
            "--current-workbook", newCurrentURL.path,
        ]
        let argv = provenanceContext?.argv ?? defaultArgv
        let durableReplayArgv = provenanceContext?.durableReplayArgv ?? argv
        let toolName = provenanceContext?.toolName ?? "Lungfish.app"
        let toolKind = provenanceContext?.toolKind ?? "app"
        var explicitOptions: [String: ParameterValue] = [
            "action": .string(action),
            "bundle": .file(bundleURL),
            "currentWorkbook": .file(newCurrentURL),
        ]
        if !additionalInputURLs.isEmpty {
            explicitOptions["additionalInputs"] = .array(additionalInputURLs.map { .file($0) })
        }
        explicitOptions.merge(additionalExplicitOptions) { _, new in new }
        let envelope = ProvenanceEnvelope(
            createdAt: completedAt,
            workflowName: "Genotype Workbook Revision",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(name: toolName, version: WorkflowRun.currentAppVersion, kind: toolKind),
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            options: ProvenanceOptions(
                explicit: explicitOptions,
                resolvedDefaults: [
                    "currentWorkbookPath": .string(defaultCurrentWorkbookRelativePath),
                    "historyDirectory": .string("artifacts/workbooks/revisions"),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputs + outputs + [provenanceDescriptor],
            output: ProvenanceFileDescriptor(path: bundleURL.path, role: .output),
            outputs: outputs + [provenanceDescriptor],
            steps: additionalProvenanceSteps + [
                ProvenanceStep(
                    toolName: "\(toolName) genotype workbook \(action)",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    inputs: inputs,
                    outputs: outputs,
                    exitStatus: 0,
                    wallTimeSeconds: completedAt.timeIntervalSince(startedAt)
                )
            ],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: provenanceURL)
    }

    private func candidateProvenanceOptions(
        _ configuration: WorkbookCandidateUpdateConfiguration
    ) -> [String: ParameterValue] {
        let tintValues = Dictionary(uniqueKeysWithValues: configuration.tints.map { key, tint in
            (
                key,
                ParameterValue.dictionary([
                    "red": .number(tint.red),
                    "green": .number(tint.green),
                    "blue": .number(tint.blue),
                    "alpha": .number(tint.alpha),
                ])
            )
        })
        return [
            "mhcCandidateTints": .dictionary(tintValues),
            "mhcCandidateVisibilityFiltersApplied": .boolean(false),
            "mhcTwoSheetWorkbookContract": .boolean(configuration.usesTwoSheetMHCContract),
            "mhcNormalizedUnmatchedRowCount": .integer(configuration.normalizedUnmatchedRows.count),
            "mhcKnownAlleleDisplayNameCount": .integer(configuration.knownAlleleDisplayNames.count),
            "mhcWorkbookSampleCount": .integer(configuration.samples.count),
            "mhcWorkbookKnownCallCount": .integer(configuration.knownCalls.count),
            "ooxmlAlphaSemantics": .string(configuration.ooxmlAlphaSemantics),
        ]
    }

    private func makePythonProvenanceStep(
        executionRecord: WorkbookOverrideExecutionRecord,
        sourceWorkbookURL: URL,
        patchedWorkbookURL: URL,
        inputURLs: [URL],
        durableReplayArgv: [String]
    ) throws -> ProvenanceStep {
        let metadata = (try? JSONSerialization.jsonObject(with: Data(executionRecord.stdout.utf8))) as? [String: Any]
        let pythonVersion = metadata?["python_version"] as? String ?? "unknown"
        let openpyxlVersion = metadata?["openpyxl_version"] as? String ?? "unknown"
        let inputs = try ([sourceWorkbookURL] + inputURLs).map {
            try ProvenanceFileDescriptor.file(url: $0, role: .input)
        }
        let output = ProvenanceFileDescriptor(
            path: defaultCurrentWorkbookRelativePath,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: patchedWorkbookURL),
            fileSize: UInt64(try ProvenanceFileHasher.fileSize(of: patchedWorkbookURL)),
            format: .unknown,
            role: .output,
            originPath: patchedWorkbookURL.path
        )
        return ProvenanceStep(
            toolName: "python openpyxl workbook candidate update",
            toolVersion: pythonVersion,
            argv: executionRecord.argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: durableReplayArgv.map(shellEscape).joined(separator: " "),
            resolvedOptions: [
                "pythonVersion": .string(pythonVersion),
                "openpyxlVersion": .string(openpyxlVersion),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(
                executablePath: executionRecord.executable,
                condaEnvironment: "openpyxl",
                condaPrefix: URL(fileURLWithPath: executionRecord.executable)
                    .deletingLastPathComponent().deletingLastPathComponent().path
            ),
            inputs: inputs,
            outputs: [output],
            exitStatus: Int(executionRecord.exitStatus),
            wallTimeSeconds: executionRecord.wallTimeSeconds,
            stderr: executionRecord.stderr,
            startedAt: executionRecord.startedAt,
            completedAt: executionRecord.completedAt
        )
    }

    private func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:-"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func validateOptionalUpdatesDirectory(in bundleURL: URL) throws {
        let safety = FullLengthONTMHCAlignmentSafety()
        let paths = [
            (bundleURL.appendingPathComponent("artifacts", isDirectory: true), "bundle artifacts directory"),
            (bundleURL.appendingPathComponent("artifacts/workbooks", isDirectory: true), "bundle workbooks directory"),
            (bundleURL.appendingPathComponent("artifacts/workbooks/updates", isDirectory: true), "workbook updates directory"),
        ]
        for (url, role) in paths {
            guard try safety.requireOptionalDirectoryEntryNoFollow(url, role: role) else { continue }
            if role == "workbook updates directory" {
                try safety.requireSafeDirectoryTree(url, role: role)
            }
        }
    }

    private func retainWorkbookRollbackFailureGenerations(
        liveBundleURL: URL,
        priorBundleURL: URL,
        originalError: Error,
        rollbackError: Error
    ) throws -> URL {
        let parent = liveBundleURL.deletingLastPathComponent()
        let priorPath = fileManager.fileExists(atPath: priorBundleURL.path) ? priorBundleURL.path : nil
        let failedPath = fileManager.fileExists(atPath: liveBundleURL.path) ? liveBundleURL.path : nil
        let receiptURL = workbookRollbackFailureReceiptURL(for: liveBundleURL)
        let receipt = WorkbookRollbackFailureReceipt(
            schemaVersion: 1,
            workflow: "update-current-workbook rollback recovery",
            createdAt: Date(),
            argv: [
                "lungfish-internal", "recover-workbook-update",
                "--bundle", liveBundleURL.path,
            ],
            priorGenerationPath: priorPath,
            failedPublishedGenerationPath: failedPath,
            originalError: originalError.localizedDescription,
            rollbackError: rollbackError.localizedDescription,
            exitStatus: 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        let receiptDescriptor = try ProvenanceFileDescriptor.file(url: receiptURL, role: .output)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: receiptURL)
        let failureText = "\(originalError.localizedDescription); rollback: \(receipt.rollbackError)"
        let envelope = ProvenanceEnvelope(
            workflowName: "Genotype Workbook Rollback Recovery",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "Lungfish.app",
                version: WorkflowRun.currentAppVersion,
                kind: "app"
            ),
            argv: receipt.argv,
            durableReplayArgv: receipt.argv,
            options: ProvenanceOptions(explicit: [
                "action": .string("recover-workbook-update"),
                "bundle": .file(liveBundleURL),
                "priorGeneration": priorPath.map { .file(URL(fileURLWithPath: $0)) } ?? .string("unavailable"),
                "failedPublishedGeneration": failedPath.map { .file(URL(fileURLWithPath: $0)) } ?? .string("unavailable"),
            ]),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: [receiptDescriptor],
            output: receiptDescriptor,
            outputs: [receiptDescriptor],
            steps: [ProvenanceStep(
                toolName: "lungfish-internal quarantine-workbook-generations",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: receipt.argv,
                durableReplayArgv: receipt.argv,
                resolvedOptions: [
                    "priorGenerationPath": .string(priorPath ?? "unavailable"),
                    "failedPublishedGenerationPath": .string(failedPath ?? "unavailable"),
                ],
                outputs: [receiptDescriptor],
                exitStatus: 1,
                stderr: failureText
            )],
            exitStatus: 1,
            stderr: failureText
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: provenanceURL)
        try syncFile(receiptURL)
        try syncFile(provenanceURL)
        try syncDirectory(parent)
        return receiptURL
    }

    private func recoverWorkbookRollbackFailureIfNeeded(for bundleURL: URL) throws {
        let receiptURL = workbookRollbackFailureReceiptURL(for: bundleURL)
        guard fileManager.fileExists(atPath: receiptURL.path) else { return }
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: receiptURL)
        let receipt = try JSONDecoder().decode(
            WorkbookRollbackFailureReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
        if !fileManager.fileExists(atPath: bundleURL.path) {
            guard let priorPath = receipt.priorGenerationPath else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "A prior workbook update rollback failure requires recovery: \(receiptURL.path)"
                )
            }
            let priorURL = URL(fileURLWithPath: priorPath, isDirectory: true)
            try validateSourceBundleTree(priorURL)
            guard Darwin.renameatx_np(
                AT_FDCWD, priorURL.path,
                AT_FDCWD, bundleURL.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not restore the prior workbook generation from \(priorURL.path) (errno \(errno))."
                )
            }
        }
        try fileManager.removeItem(at: receiptURL)
        if fileManager.fileExists(atPath: provenanceURL.path) {
            try fileManager.removeItem(at: provenanceURL)
        }
        try syncDirectory(bundleURL.deletingLastPathComponent())
    }

    private func workbookRollbackFailureReceiptURL(for bundleURL: URL) -> URL {
        bundleURL.deletingLastPathComponent().appendingPathComponent(
            ".\(bundleURL.lastPathComponent).workbook-update-failure.json"
        )
    }

    private func validateSourceBundleTree(_ bundleURL: URL) throws {
        let safety = FullLengthONTMHCAlignmentSafety()
        try safety.requireDirectoryNoFollow(bundleURL, role: "genotype bundle")
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                enumerationError = GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not safely enumerate genotype bundle entry \(url.path): \(error.localizedDescription)"
                )
                return false
            }
        ) else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not safely enumerate genotype bundle: \(bundleURL.path)"
            )
        }
        while let url = enumerator.nextObject() as? URL {
            var info = stat()
            guard Darwin.lstat(url.path, &info) == 0 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not inspect genotype bundle entry without following links: \(url.path) (errno \(errno))."
                )
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                let descriptor = try safety.openRegularFileNoFollow(
                    url,
                    within: bundleURL,
                    role: "genotype bundle file"
                )
                Darwin.close(descriptor)
            case S_IFDIR:
                try validateDirectoryPathNoFollow(url, within: bundleURL)
            default:
                enumerator.skipDescendants()
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Symlinks and special files are not allowed in workbook update source bundles: \(url.path)"
                )
            }
        }
        if let enumerationError { throw enumerationError }

        for (relativePath, role) in [
            ("artifacts", "bundle artifacts directory"),
            ("artifacts/workbooks", "bundle workbooks directory"),
            ("artifacts/workbooks/revisions", "workbook revisions directory"),
            ("artifacts/workbooks/provenance", "workbook provenance directory"),
            ("artifacts/workbooks/updates", "workbook updates directory"),
        ] {
            let url = bundleURL.appendingPathComponent(relativePath, isDirectory: true)
            if try safety.requireOptionalDirectoryEntryNoFollow(url, role: role) {
                try validateDirectoryPathNoFollow(url, within: bundleURL)
            }
        }
    }

    private func copyBundleTreeNoFollow(from sourceURL: URL, to destinationURL: URL) throws {
        bundleCloneAttemptObserver?()
        let cloneFlags = UInt32(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_EXCL
        )
        let fallbackFlags = UInt32(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL
        )
        let copy: @Sendable (URL, URL, UInt32) -> Int32 = bundleCopyPrimitive ?? { source, destination, flags in
            Darwin.copyfile(source.path, destination.path, nil, copyfile_flags_t(flags))
        }
        if !forceBundleCloneFallback, copy(sourceURL, destinationURL, cloneFlags) == 0 {
            return
        }
        if fileManager.fileExists(atPath: destinationURL.path) { try fileManager.removeItem(at: destinationURL) }
        _ = fallbackFlags // Kept explicit to document that metadata-copy fallback is intentionally avoided.
        try copyDirectoryTreeByDescriptorNoFollow(from: sourceURL, to: destinationURL)
    }

    private func copyDirectoryTreeByDescriptorNoFollow(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceDescriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not open workbook bundle fallback source: \(sourceURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(sourceDescriptor) }
        guard Darwin.mkdir(destinationURL.path, S_IRWXU) == 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not create workbook bundle fallback destination: \(destinationURL.path) (errno \(errno))."
            )
        }
        let destinationDescriptor = Darwin.open(
            destinationURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDescriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not open workbook bundle fallback destination: \(destinationURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(destinationDescriptor) }
        try copyDirectoryContentsByDescriptorNoFollow(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        try copyExtendedAttributesByDescriptorNoFollow(
            from: sourceDescriptor,
            to: destinationDescriptor,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not sync workbook bundle fallback destination: \(destinationURL.path) (errno \(errno))."
            )
        }
    }

    private func copyDirectoryContentsByDescriptorNoFollow(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let enumerationDescriptor = Darwin.dup(sourceDescriptor)
        guard enumerationDescriptor >= 0, let stream = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not enumerate workbook bundle fallback source: \(sourceURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.closedir(stream) }
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            let sourceChild = sourceURL.appendingPathComponent(name)
            let destinationChild = destinationURL.appendingPathComponent(name)
            var sourceInfo = stat()
            let inspectStatus = name.withCString {
                Darwin.fstatat(sourceDescriptor, $0, &sourceInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard inspectStatus == 0 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not inspect workbook bundle fallback source: \(sourceChild.path) (errno \(errno))."
                )
            }
            if sourceInfo.st_mode & S_IFMT == S_IFREG,
               try isAppleDoubleCompanionNoFollow(
                   name: name,
                   directoryDescriptor: sourceDescriptor
               ) {
                continue
            }
            switch sourceInfo.st_mode & S_IFMT {
            case S_IFREG:
                try copyRegularFileByDescriptorNoFollow(
                    name: name,
                    sourceDescriptor: sourceDescriptor,
                    destinationDescriptor: destinationDescriptor,
                    expected: sourceInfo,
                    sourceURL: sourceChild,
                    destinationURL: destinationChild
                )
            case S_IFDIR:
                guard name.withCString({ Darwin.mkdirat(destinationDescriptor, $0, S_IRWXU) }) == 0 else {
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                        "Could not create workbook bundle fallback directory: \(destinationChild.path) (errno \(errno))."
                    )
                }
                let sourceChildDescriptor = name.withCString {
                    Darwin.openat(
                        sourceDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                let destinationChildDescriptor = name.withCString {
                    Darwin.openat(
                        destinationDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard sourceChildDescriptor >= 0, destinationChildDescriptor >= 0 else {
                    if sourceChildDescriptor >= 0 { Darwin.close(sourceChildDescriptor) }
                    if destinationChildDescriptor >= 0 { Darwin.close(destinationChildDescriptor) }
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                        "Could not open workbook bundle fallback directory: \(sourceChild.path) (errno \(errno))."
                    )
                }
                do {
                    var openedInfo = stat()
                    guard Darwin.fstat(sourceChildDescriptor, &openedInfo) == 0,
                          openedInfo.st_dev == sourceInfo.st_dev,
                          openedInfo.st_ino == sourceInfo.st_ino else {
                        throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                            "Workbook bundle directory changed during fallback copy: \(sourceChild.path)."
                        )
                    }
                    try copyDirectoryContentsByDescriptorNoFollow(
                        sourceDescriptor: sourceChildDescriptor,
                        destinationDescriptor: destinationChildDescriptor,
                        sourceURL: sourceChild,
                        destinationURL: destinationChild
                    )
                    try copyExtendedAttributesByDescriptorNoFollow(
                        from: sourceChildDescriptor,
                        to: destinationChildDescriptor,
                        sourceURL: sourceChild,
                        destinationURL: destinationChild
                    )
                    guard Darwin.fsync(destinationChildDescriptor) == 0 else {
                        throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                            "Could not sync workbook bundle fallback directory: \(destinationChild.path) (errno \(errno))."
                        )
                    }
                    Darwin.close(sourceChildDescriptor)
                    Darwin.close(destinationChildDescriptor)
                } catch {
                    Darwin.close(sourceChildDescriptor)
                    Darwin.close(destinationChildDescriptor)
                    throw error
                }
            default:
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Symlinks and special files are not allowed in workbook bundle fallback copy: \(sourceChild.path)"
                )
            }
        }
    }

    private func copyRegularFileByDescriptorNoFollow(
        name: String,
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        expected: stat,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let input = name.withCString {
            Darwin.openat(sourceDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard input >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not open workbook bundle fallback file: \(sourceURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(input) }
        var openedInfo = stat()
        guard Darwin.fstat(input, &openedInfo) == 0,
              openedInfo.st_mode & S_IFMT == S_IFREG,
              openedInfo.st_dev == expected.st_dev,
              openedInfo.st_ino == expected.st_ino else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook bundle file changed during fallback copy: \(sourceURL.path)."
            )
        }
        let output = name.withCString {
            Darwin.openat(
                destinationDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard output >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not create workbook bundle fallback file: \(destinationURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(output) }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var copied: off_t = 0
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not read workbook bundle fallback file: \(sourceURL.path) (errno \(errno))."
                )
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                }
                guard written > 0 else {
                    if errno == EINTR { continue }
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                        "Could not write workbook bundle fallback file: \(destinationURL.path) (errno \(errno))."
                    )
                }
                offset += written
                copied += off_t(written)
            }
        }
        var after = stat()
        try copyExtendedAttributesByDescriptorNoFollow(
            from: input,
            to: output,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        guard Darwin.fstat(input, &after) == 0,
              after.st_dev == expected.st_dev,
              after.st_ino == expected.st_ino,
              after.st_size == expected.st_size,
              copied == expected.st_size,
              Darwin.fsync(output) == 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook bundle file changed or failed to sync during fallback copy: \(sourceURL.path)."
            )
        }
    }

    private func isAppleDoubleCompanionNoFollow(
        name: String,
        directoryDescriptor: Int32
    ) throws -> Bool {
        guard name.hasPrefix("._"), name.count > 2 else { return false }
        let baseName = String(name.dropFirst(2))
        var baseInfo = stat()
        let baseStatus = baseName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &baseInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard baseStatus == 0,
              baseInfo.st_mode & S_IFMT == S_IFREG || baseInfo.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        let descriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not inspect AppleDouble companion during fallback copy: \(name) (errno \(errno))."
            )
        }
        defer { Darwin.close(descriptor) }
        var header = [UInt8](repeating: 0, count: 8)
        let count = Darwin.pread(descriptor, &header, header.count, 0)
        guard count == header.count else { return false }
        return header == [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]
    }

    private func copyExtendedAttributesByDescriptorNoFollow(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let listSize = Darwin.flistxattr(sourceDescriptor, nil, 0, 0)
        if listSize < 0 {
            if errno == ENOTSUP { return }
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not list fallback-copy metadata for \(sourceURL.path) (errno \(errno))."
            )
        }
        guard listSize > 0 else { return }
        var names = [CChar](repeating: 0, count: listSize)
        let actualListSize = Darwin.flistxattr(sourceDescriptor, &names, names.count, 0)
        guard actualListSize == listSize else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Fallback-copy metadata changed while reading \(sourceURL.path)."
            )
        }
        var offset = 0
        while offset < actualListSize {
            let name = names.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1
            if name == "com.apple.provenance" { continue }
            let valueSize = name.withCString {
                Darwin.fgetxattr(sourceDescriptor, $0, nil, 0, 0, 0)
            }
            guard valueSize >= 0 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not size fallback-copy metadata \(name) for \(sourceURL.path) (errno \(errno))."
                )
            }
            var value = [UInt8](repeating: 0, count: valueSize)
            let readSize = name.withCString { attributeName in
                value.withUnsafeMutableBytes { bytes in
                    Darwin.fgetxattr(
                        sourceDescriptor,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
            }
            guard readSize == valueSize else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Fallback-copy metadata \(name) changed while reading \(sourceURL.path)."
                )
            }
            let writeStatus = name.withCString { attributeName in
                value.withUnsafeBytes { bytes in
                    Darwin.fsetxattr(
                        destinationDescriptor,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
            }
            guard writeStatus == 0 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not preserve fallback-copy metadata \(name) at \(destinationURL.path) (errno \(errno))."
                )
            }
        }
    }

    private func validateDirectoryPathNoFollow(_ directoryURL: URL, within rootURL: URL) throws {
        let root = rootURL.standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        let rootComponents = root.pathComponents
        let directoryComponents = directory.pathComponents
        guard directoryComponents.count >= rootComponents.count,
              Array(directoryComponents.prefix(rootComponents.count)) == rootComponents else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook update directory escapes its bundle: \(directory.path)"
            )
        }
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not open genotype bundle without following links: \(root.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(descriptor) }
        for component in directoryComponents.dropFirst(rootComponents.count) {
            let next = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not traverse workbook update directory without following links: \(directory.path) (errno \(errno))."
                )
            }
            Darwin.close(descriptor)
            descriptor = next
        }
    }

    private func createAdjacentStageDirectory(_ stageURL: URL, for bundleURL: URL) throws {
        let parent = bundleURL.deletingLastPathComponent()
        try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(parent, role: "workbook update parent")
        var info = stat()
        guard Darwin.lstat(stageURL.path, &info) != 0, errno == ENOENT else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook update staging path already exists or is unsafe: \(stageURL.path)"
            )
        }
        guard Darwin.mkdir(stageURL.path, S_IRWXU) == 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not create workbook update staging directory: \(stageURL.path) (errno \(errno))."
            )
        }
        try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(stageURL, role: "workbook update staging directory")
    }

    private func snapshotRegularFileNoFollow(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> SourceWorkbookWitness {
        let sourceDescriptor = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not open current workbook snapshot source without following links: \(sourceURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(sourceDescriptor) }
        var before = stat()
        guard Darwin.fstat(sourceDescriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Current workbook snapshot source is not a regular file: \(sourceURL.path)"
            )
        }
        let destinationDescriptor = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not create immutable workbook input snapshot: \(destinationURL.path) (errno \(errno))."
            )
        }
        defer { Darwin.close(destinationDescriptor) }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(sourceDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not read current workbook snapshot: \(sourceURL.path) (errno \(errno))."
                )
            }
            hasher.update(data: Data(buffer[0..<count]))
            totalBytes += Int64(count)
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                }
                guard written > 0 else {
                    if errno == EINTR { continue }
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                        "Could not write immutable workbook input snapshot: \(destinationURL.path) (errno \(errno))."
                    )
                }
                offset += written
            }
        }
        var after = stat()
        guard Darwin.fstat(sourceDescriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              totalBytes == Int64(after.st_size),
              Darwin.fsync(destinationDescriptor) == 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Current workbook changed while its immutable input snapshot was being created."
            )
        }
        return SourceWorkbookWitness(
            device: before.st_dev,
            inode: before.st_ino,
            sizeBytes: totalBytes,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func requireUnchangedRegularFileNoFollow(
        _ url: URL,
        witness: SourceWorkbookWitness
    ) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Current workbook changed or became unavailable before publication: \(url.path)"
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == witness.device,
              info.st_ino == witness.inode,
              Int64(info.st_size) == witness.sizeBytes else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Current workbook changed while the update was being prepared; the manual edit was preserved."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not verify the current workbook before publication: \(url.path)"
                )
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == witness.sha256 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Current workbook changed while the update was being prepared; the manual edit was preserved."
            )
        }
    }

    private func writeStagedFile(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Could not create staged workbook update file: \(url.path) (errno \(errno))."
            )
        }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                    guard count > 0 else {
                        throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                            "Could not write staged workbook update file: \(url.path) (errno \(errno))."
                        )
                    }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Could not sync staged workbook update file: \(url.path) (errno \(errno))."
                )
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
    }

    private func relocateProvenancePaths(in url: URL, from sourceRoot: URL, to destinationRoot: URL) throws {
        let data = try Data(contentsOf: url)
        guard var text = String(data: data, encoding: .utf8) else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed("Workbook provenance is not UTF-8 JSON.")
        }
        text = text.replacingOccurrences(of: sourceRoot.path, with: destinationRoot.path)
        text = text.replacingOccurrences(
            of: sourceRoot.path.replacingOccurrences(of: "/", with: "\\/"),
            with: destinationRoot.path.replacingOccurrences(of: "/", with: "\\/")
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        guard !text.contains(sourceRoot.path) else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook provenance still references the staging bundle after path relocation."
            )
        }
        let relocated = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(text.utf8))
        guard relocated.output?.path == destinationRoot.path else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook provenance bundle relocation failed (source \(sourceRoot.path), recorded \(relocated.output?.path ?? "nil"))."
            )
        }
    }

    private func exchangeDirectoriesNoSync(
        _ lhs: URL,
        _ rhs: URL,
        transaction: ONTGenotypeWorkbookUpdateTransaction,
        protectedOldWorkbookURL: URL?,
        protectedOldWorkbookWitness: SourceWorkbookWitness?
    ) throws -> WorkbookPublicationMechanism {
        try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(lhs, role: "staged workbook bundle")
        try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(rhs, role: "published workbook bundle")
        let lhsIdentity = try ONTGenotypeWorkbookUpdateRecovery.directoryIdentity(for: lhs, path: lhs.path)
        let rhsIdentity = try ONTGenotypeWorkbookUpdateRecovery.directoryIdentity(for: rhs, path: rhs.path)
        if try ONTGenotypeWorkbookUpdateRecovery.swapDirectoriesAssumingLock(
            transaction,
            for: rhs,
            lhs: lhs,
            expectedLHS: lhsIdentity,
            rhs: rhs,
            expectedRHS: rhsIdentity,
            attestationRootURL: workbookAttestationRootURL,
            renamePrimitive: directorySwapPrimitive
        ) {
            return .renameSwap
        }
        let temporary = URL(
            fileURLWithPath: transaction.rotationTemporaryPath,
            isDirectory: true
        ).standardizedFileURL
        let expectedTemporary = URL(
            fileURLWithPath: transaction.transactionRootPath,
            isDirectory: true
        ).appendingPathComponent(".publication-rotation", isDirectory: true).standardizedFileURL
        guard temporary == expectedTemporary else {
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                "Workbook publication rotation temporary path is invalid."
            )
        }
        try ONTGenotypeWorkbookUpdateRecovery.moveDirectoryNoReplaceAssumingLock(
            transaction,
            for: rhs,
            source: lhs,
            expected: lhsIdentity,
            destination: temporary,
            attestationRootURL: workbookAttestationRootURL,
            renamePrimitive: directoryMovePrimitive
        )
        try publicationFailureInjector?("after-rotation-stage-to-temporary-hard-stop")
        if let protectedOldWorkbookURL, let protectedOldWorkbookWitness {
            do {
                try requireUnchangedRegularFileNoFollow(
                    protectedOldWorkbookURL,
                    witness: protectedOldWorkbookWitness
                )
            } catch {
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: rhs,
                    attestationRootURL: workbookAttestationRootURL
                )
                throw error
            }
        }
        try ONTGenotypeWorkbookUpdateRecovery.moveDirectoryNoReplaceAssumingLock(
            transaction,
            for: rhs,
            source: rhs,
            expected: rhsIdentity,
            destination: lhs,
            attestationRootURL: workbookAttestationRootURL,
            renamePrimitive: directoryMovePrimitive
        )
        try publicationFailureInjector?("after-rotation-final-to-stage-hard-stop")
        if let protectedOldWorkbookWitness {
            let stagedOldWorkbook = lhs.appendingPathComponent(
                transaction.oldCurrentWorkbook.path
            )
            do {
                try requireUnchangedRegularFileNoFollow(
                    stagedOldWorkbook,
                    witness: protectedOldWorkbookWitness
                )
            } catch {
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: rhs,
                    attestationRootURL: workbookAttestationRootURL
                )
                throw error
            }
        }
        try ONTGenotypeWorkbookUpdateRecovery.moveDirectoryNoReplaceAssumingLock(
            transaction,
            for: rhs,
            source: temporary,
            expected: lhsIdentity,
            destination: rhs,
            attestationRootURL: workbookAttestationRootURL,
            renamePrimitive: directoryMovePrimitive
        )
        try publicationFailureInjector?("after-rotation-temporary-to-final-hard-stop")
        return .journaledThreeRename
    }

    private func appendFinalPublicationStep(
        to provenanceURL: URL,
        bundleURL: URL,
        workflowStartedAt: Date,
        publicationStartedAt: Date,
        publicationCompletedAt: Date,
        mechanism: WorkbookPublicationMechanism
    ) throws {
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: provenanceURL))
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL)
        let outputs = [try ProvenanceFileDescriptor.file(url: currentURL, role: .output)]
        let mechanismFields: (toolName: String, subcommand: String) = switch mechanism {
        case .renameSwap:
            ("lungfish-internal atomic workbook bundle exchange", "atomic-workbook-bundle-exchange")
        case .journaledThreeRename:
            ("lungfish-internal ExFAT journaled three-rename workbook rotation v2", "exfat-journaled-three-rename-v2")
        }
        let publicationStep = ProvenanceStep(
            toolName: mechanismFields.toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-internal", mechanismFields.subcommand,
                "--bundle", bundleURL.path,
            ],
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: publicationCompletedAt.timeIntervalSince(publicationStartedAt),
            startedAt: publicationStartedAt,
            completedAt: publicationCompletedAt
        )
        let completedAt = Date()
        let updated = ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: completedAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: envelope.files,
            output: envelope.output,
            outputs: envelope.outputs,
            steps: envelope.steps + [publicationStep],
            wallTimeSeconds: completedAt.timeIntervalSince(workflowStartedAt),
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: envelope.signatures,
            legacyWorkflowRun: envelope.legacyRun
        )
        try ProvenanceWriter(signingProvider: nil).write(updated, toSidecar: provenanceURL)
    }

    private func syncFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func syncDirectoryTree(_ root: URL) throws {
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)
        var directories = [root]
        while let url = enumerator?.nextObject() as? URL {
            var info = stat()
            guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            switch info.st_mode & S_IFMT {
            case S_IFREG: try syncFile(url)
            case S_IFDIR: directories.append(url)
            default:
                throw GenotypeWorkbookRevisionError.workbookOverrideFailed(
                    "Symlinks and special files are not allowed in workbook bundle publication: \(url.path)"
                )
            }
        }
        for directory in directories.reversed() { try syncDirectory(directory) }
    }

    private func validateWorkbook(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "xlsx",
              let handle = try? FileHandle(forReadingFrom: url) else {
            throw GenotypeWorkbookRevisionError.invalidWorkbook(url.path)
        }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        guard magic == Data([0x50, 0x4b, 0x03, 0x04])
            || magic == Data([0x50, 0x4b, 0x05, 0x06])
            || magic == Data([0x50, 0x4b, 0x07, 0x08]) else {
            throw GenotypeWorkbookRevisionError.invalidWorkbook(url.path)
        }
    }

    private func replaceFile(at destinationURL: URL, withCopyOf sourceURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporaryURL)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.init(rawValue: code) ?? .EIO)])
        }
    }

    private func manifestWithWorkbookFields(
        _ manifest: ONTGenotypeResultBundleManifest,
        currentWorkbookPath: String,
        revisions: [ONTGenotypeWorkbookRevision]
    ) -> ONTGenotypeResultBundleManifest {
        ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: manifest.deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: manifest.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            presetID: manifest.presetID,
            presetVersion: manifest.presetVersion,
            createdAt: manifest.createdAt,
            activeHaplotypeAnalysisRevisionID: manifest.activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: manifest.haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: manifest.mhcCandidateArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
    }

    private func latestCurrentWorkbookRevision(
        in manifest: ONTGenotypeResultBundleManifest
    ) -> ONTGenotypeWorkbookRevision? {
        guard let currentPath = manifest.currentWorkbookPath else { return nil }
        return manifest.workbookRevisions?.last { $0.path == currentPath }
    }

    private func revisionsDirectory(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("artifacts/workbooks/revisions", isDirectory: true)
    }

    private func nextProvenancePath(action: String, in bundleURL: URL) -> String {
        let url = bundleURL
            .appendingPathComponent("artifacts/workbooks/provenance", isDirectory: true)
            .appendingPathComponent("\(timestampSlug())-\(safeFilenameStem(action))-\(UUID().uuidString.prefix(8)).lungfish-provenance.json")
        return relativePath(from: bundleURL, to: url)
    }

    private func timestampSlug() -> String {
        ISO8601DateFormatter()
            .string(from: dateProvider())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func normalizedLabel(_ label: String?, fallback: String) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func safeFilenameStem(_ value: String) -> String {
        let sanitized = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workbook" : collapsed
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return filePath
    }
}

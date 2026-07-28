import Darwin
import Foundation
import LungfishCore
import LungfishIO

public struct ProjectStorageScanner {
    static let maximumTrackedHardLinkIdentities = 65_536

    private struct Candidate {
        let url: URL
        let category: ProjectStorageEntry.Category
        let exactOwnedPattern: Bool
    }

    private struct MeasuredTree {
        let logicalBytes: UInt64
        let allocatedBytes: UInt64
        let unsafeReason: String?
        let unsafeCode: ProjectStorageClassification.Code?

        init(
            logicalBytes: UInt64,
            allocatedBytes: UInt64,
            unsafeReason: String?,
            unsafeCode: ProjectStorageClassification.Code? = nil
        ) {
            self.logicalBytes = logicalBytes
            self.allocatedBytes = allocatedBytes
            self.unsafeReason = unsafeReason
            self.unsafeCode = unsafeCode
        }
    }

    private struct HardLinkAuthority {
        var expectedLinkCount: UInt64
        var expectedCountAgrees: Bool
        var removableOccurrences: UInt64
        var pendingEntryIndex: Int
        var pendingOccurrences: UInt64
        var countedAllocation: (entryIndex: Int, bytes: UInt64)?
    }

    private final class ScanMetrics {
        // Logical directory-enumerator yields, not lstat calls: one increment
        // for every project-discovery yield before pruning, plus one for every
        // candidate-subtree yield before that entry's lstat. Project and
        // candidate roots measured separately are excluded; the yielded
        // operation-history root is included and its pruned descendants are
        // excluded.
        var visitedObjects: UInt64 = 0
        var candidateEntries: UInt64 = 0
        var trackedHardLinkIdentities: UInt64 = 0
        var retainedScannerRecords: UInt64 = 0

        func record(
            with instrumentation: ProjectStorageInstrumentation,
            in interval: ProjectStorageInstrumentation.Interval
        ) {
            instrumentation.count(
                .visitedObjects,
                visitedObjects,
                in: interval
            )
            instrumentation.count(
                .candidateEntries,
                candidateEntries,
                in: interval
            )
            instrumentation.count(
                .trackedHardLinkIdentities,
                trackedHardLinkIdentities,
                in: interval
            )
            instrumentation.count(
                .retainedScannerRecords,
                retainedScannerRecords,
                in: interval
            )
        }

        func retain(
            candidates: Int,
            entries: Int,
            hardLinkIdentities: Int
        ) {
            candidateEntries = UInt64(candidates)
            trackedHardLinkIdentities = UInt64(hardLinkIdentities)
            retainedScannerRecords = saturatedSum([
                UInt64(candidates),
                UInt64(entries),
                UInt64(hardLinkIdentities),
            ])
        }

        private func saturatedSum(_ values: [UInt64]) -> UInt64 {
            values.reduce(into: 0) { total, value in
                let (next, overflow) =
                    total.addingReportingOverflow(value)
                total = overflow ? .max : next
            }
        }
    }

    private let processInspector: (Int32) throws -> OwnedProcessIdentity?
    private let lockProbe: (URL) throws -> OwnedRunLockProbe
    private let cancellationCheck: () throws -> Void
    private let legacyWorkbookClassifier:
        ProjectStorageLegacyWorkbookClassifier
    private let instrumentation: ProjectStorageInstrumentation
    private let hardLinkIdentityLimit: Int

    public init() {
        self.processInspector = {
            try OwnedProcessIdentity.inspect(processIdentifier: $0)
        }
        self.lockProbe = { try OwnedRunLock.probe(at: $0) }
        self.cancellationCheck = { try Task.checkCancellation() }
        self.legacyWorkbookClassifier = .init()
        self.instrumentation = .production(
            subsystem: LogSubsystem.workflow
        )
        self.hardLinkIdentityLimit =
            Self.maximumTrackedHardLinkIdentities
    }

    init(
        processInspector:
            @escaping (Int32) throws -> OwnedProcessIdentity? = {
                try OwnedProcessIdentity.inspect(
                    processIdentifier: $0
                )
            },
        lockProbe: @escaping (URL) throws -> OwnedRunLockProbe = {
            try OwnedRunLock.probe(at: $0)
        },
        cancellationCheck: @escaping () throws -> Void = {
            try Task.checkCancellation()
        },
        workbookAttestationRootURL: URL? = nil,
        callerHeldRunLocks: [OwnedRunLock] = [],
        callerHeldWorkbookPublicationLocks:
            [ONTGenotypeBundlePublicationLock] = [],
        instrumentation: ProjectStorageInstrumentation = .production(
            subsystem: LogSubsystem.workflow
        ),
        maximumTrackedHardLinkIdentities: Int =
            Self.maximumTrackedHardLinkIdentities
    ) {
        self.processInspector = processInspector
        self.lockProbe = { lockURL in
            if callerHeldRunLocks.contains(where: {
                $0.authorizesRevalidation(of: lockURL)
            }) {
                return .unlocked
            }
            return try lockProbe(lockURL)
        }
        self.cancellationCheck = cancellationCheck
        self.legacyWorkbookClassifier = .init(
            attestationRootURL: workbookAttestationRootURL,
            cancellationCheck: cancellationCheck,
            callerHeldPublicationLocks:
                callerHeldWorkbookPublicationLocks
        )
        self.instrumentation = instrumentation
        self.hardLinkIdentityLimit = max(
            0,
            maximumTrackedHardLinkIdentities
        )
    }

    public func scan(
        projectURL: URL,
        progress: ((ProjectStorageScanProgress) -> Void)? = nil
    ) throws -> ProjectStorageScanResult {
        let interval = instrumentation.begin(.scan)
        let metrics = ScanMetrics()
        do {
            let result = try performScan(
                projectURL: projectURL,
                progress: progress,
                metrics: metrics
            )
            metrics.record(with: instrumentation, in: interval)
            instrumentation.end(interval, outcome: .success)
            return result
        } catch {
            metrics.record(with: instrumentation, in: interval)
            instrumentation.end(
                interval,
                outcome: error is CancellationError
                    ? .cancelled
                    : .failure
            )
            throw error
        }
    }

    private func performScan(
        projectURL: URL,
        progress: ((ProjectStorageScanProgress) -> Void)?,
        metrics: ScanMetrics
    ) throws -> ProjectStorageScanResult {
        try cancellationCheck()
        let project = projectURL.standardizedFileURL
        let projectDescriptor: Int32
        do {
            projectDescriptor =
                try NoFollowFileSystem.openDirectoryHierarchy(project)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(project.path)
        }
        defer { Darwin.close(projectDescriptor) }
        var projectInformation = stat()
        guard Darwin.fstat(projectDescriptor, &projectInformation) == 0,
              projectInformation.st_mode & S_IFMT == S_IFDIR else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(project.path)
        }
        let projectIdentity = FileSystemObjectIdentity(
            from: projectInformation
        )
        var visited: UInt64 = 0
        var classified: UInt64 = 0
        var measuredLogical: UInt64 = 0
        var measuredAllocated: UInt64 = 0
        func report(
            _ visitedSnapshot: UInt64,
            _ relativePath: String
        ) {
            progress?(
                .init(
                    visitedFileSystemObjects: visitedSnapshot,
                    classifiedEntries: classified,
                    logicalBytes: measuredLogical,
                    allocatedBytes: measuredAllocated,
                    currentRelativePath: relativePath
                )
            )
        }

        var candidates: [Candidate] = []
        var entries: [ProjectStorageEntry] = []
        var hardLinkAuthorities:
            [FileSystemObjectIdentity: HardLinkAuthority] = [:]
        defer {
            metrics.visitedObjects = visited
            metrics.retain(
                candidates: candidates.count,
                entries: entries.count,
                hardLinkIdentities: hardLinkAuthorities.count
            )
        }
        try discoverCandidates(
            projectURL: project,
            candidates: &candidates,
            visited: &visited,
            report: report
        )
        candidates.sort {
            relativePath(from: project, to: $0.url)
                < relativePath(from: project, to: $1.url)
        }
        entries.reserveCapacity(candidates.count)
        for candidate in candidates {
            try cancellationCheck()
            let relative = relativePath(
                from: project,
                to: candidate.url
            )
            var rootInformation = stat()
            guard Darwin.lstat(
                candidate.url.path,
                &rootInformation
            ) == 0 else {
                if errno == ENOENT { continue }
                entries.append(
                    unavailableEntry(
                        projectIdentity: projectIdentity,
                        relativePath: relative,
                        candidate: candidate,
                        reason:
                            "The candidate could not be inspected "
                            + "(errno \(errno))."
                    )
                )
                continue
            }
            let identity = FileSystemObjectIdentity(
                from: rootInformation
            )
            let entryIndex = entries.count
            let measured: MeasuredTree
            if rootInformation.st_mode & S_IFMT == S_IFDIR {
                measured = try measureTree(
                    candidate.url,
                    projectURL: project,
                    expectedRootIdentity: identity,
                    entryIndex: entryIndex,
                    priorEntries: entries,
                    hardLinkAuthorities: &hardLinkAuthorities,
                    visited: &visited,
                    report: report
                )
            } else {
                let single = try measureSingleEntry(
                    rootInformation,
                    identity: identity,
                    entryIndex: entryIndex,
                    priorEntries: entries,
                    hardLinkAuthorities: &hardLinkAuthorities
                )
                measured = .init(
                    logicalBytes: single.logicalBytes,
                    allocatedBytes: single.allocatedBytes,
                    unsafeReason:
                        single.unsafeReason
                        ?? "The candidate is not a real directory.",
                    unsafeCode: single.unsafeCode
                )
            }
            measuredLogical = try adding(
                measuredLogical,
                measured.logicalBytes
            )
            measuredAllocated = try adding(
                measuredAllocated,
                measured.allocatedBytes
            )

            var classification: ProjectStorageClassification
            if let unsafeReason = measured.unsafeReason {
                classification = .notRemovable(
                    measured.unsafeCode ?? .unsafeFileSystemObject,
                    reason: unsafeReason
                )
            } else if !candidate.exactOwnedPattern {
                classification = .notRemovable(
                    .unknownOwnedPattern,
                    reason:
                        "The path resembles Lungfish work but is not an "
                        + "exact owned pattern."
                )
            } else {
                switch candidate.category {
                case .workbookArchive:
                    classification =
                        try legacyWorkbookClassifier.classify(
                            archiveURL: candidate.url,
                            projectURL: project
                        )
                case .workflowStaging, .temporary:
                    classification = classifyOwnedWork(
                        candidate.url,
                        projectURL: project
                    )
                }
            }
            try cancellationCheck()
            var finalInformation = stat()
            if Darwin.lstat(
                candidate.url.path,
                &finalInformation
            ) != 0
                || FileSystemObjectIdentity(from: finalInformation)
                    != identity {
                classification = .notRemovable(
                    .identityChanged,
                    reason:
                        "The candidate identity changed during preview."
                )
            }
            classified = try adding(classified, 1)
            entries.append(
                .init(
                    projectIdentity: projectIdentity,
                    relativePath: relative,
                    identity: identity,
                    category: candidate.category,
                    logicalBytes: measured.logicalBytes,
                    allocatedBytes: measured.allocatedBytes,
                    modificationDate: modificationDate(
                        rootInformation
                    ),
                    classification: classification
                )
            )
            report(visited, relative)
        }
        guard try FileSystemObjectIdentity.noFollow(project)
            == projectIdentity else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(
                project.path
            )
        }
        adjustEntriesForSurvivingHardLinks(
            &entries,
            authorities: hardLinkAuthorities,
            projectIdentity: projectIdentity
        )
        return .init(
            projectIdentity: projectIdentity,
            entries: entries
        )
    }

    private func discoverCandidates(
        projectURL: URL,
        candidates: inout [Candidate],
        visited: inout UInt64,
        report: (UInt64, String) -> Void
    ) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        var enumerationFailure: String?
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                enumerationFailure =
                    "\(url.path): \(error.localizedDescription)"
                return false
            }
        ) else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(
                projectURL.path
            )
        }
        while let url = enumerator.nextObject() as? URL {
            visited = try adding(visited, 1)
            try cancellationCheck()
            let relative = relativePath(from: projectURL, to: url)
            report(visited, relative)
            if relative == ProjectOperationHistoryWriter
                .historyDirectoryName
                || relative.hasPrefix(
                    ProjectOperationHistoryWriter
                        .historyDirectoryName + "/"
                ) {
                enumerator.skipDescendants()
                continue
            }
            if relative == ".tmp" {
                var information = stat()
                if Darwin.lstat(url.path, &information) != 0
                    || information.st_mode & S_IFMT != S_IFDIR {
                    candidates.append(
                        Candidate(
                            url: url,
                            category: .temporary,
                            exactOwnedPattern: false
                        )
                    )
                    enumerator.skipDescendants()
                }
                continue
            }
            if relative.hasPrefix(".tmp/"),
               !String(relative.dropFirst(".tmp/".count))
                    .contains("/") {
                candidates.append(
                    Candidate(
                        url: url,
                        category: .temporary,
                        exactOwnedPattern: true
                    )
                )
                enumerator.skipDescendants()
                continue
            }
            if let reserved = reservedCandidate(url) {
                candidates.append(reserved)
                enumerator.skipDescendants()
                continue
            }
            var information = stat()
            if Darwin.lstat(url.path, &information) == 0,
               information.st_mode & S_IFMT == S_IFDIR,
               url.pathExtension.lowercased().hasPrefix("lungfish") {
                enumerator.skipDescendants()
            }
        }
        if let enumerationFailure {
            throw OwnedWorkDirectoryMarkerError.unsafePath(
                "Project storage enumeration failed at "
                    + enumerationFailure
            )
        }
    }

    private func reservedCandidate(_ url: URL) -> Candidate? {
        let name = url.lastPathComponent
        let archivePrefix =
            ".lungfish-workbook-generation-archive-"
        if name.hasPrefix(archivePrefix) {
            let identifier = String(name.dropFirst(archivePrefix.count))
            let exact = identifier.range(
                of:
                    #"^\d{4}-\d{2}-\d{2}T\d{6}(?:-\d+)?Z-update-current-workbook-[0-9A-Fa-f]{8}$"#,
                options: .regularExpression
            ) != nil && isCalendarValidArchiveIdentifier(identifier)
            return Candidate(
                url: url,
                category: .workbookArchive,
                exactOwnedPattern: exact
            )
        }
        if name.hasPrefix(
            ".lungfish-workbook-cleanup-pending-"
        ) || name.contains(".workbook-cleanup-state-") {
            return Candidate(
                url: url,
                category: .workbookArchive,
                exactOwnedPattern: false
            )
        }
        let stagingPrefixPattern =
            #"^\..+\.lungfishgenotype\.run-staging-"#
        if name.range(
            of: stagingPrefixPattern,
            options: .regularExpression
        ) != nil {
            let exactPattern =
                #"^\..+\.lungfishgenotype\.run-staging-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
            return Candidate(
                url: url,
                category: .workflowStaging,
                exactOwnedPattern: name.range(
                    of: exactPattern,
                    options: .regularExpression
                ) != nil
            )
        }
        guard name.hasPrefix(".") else { return nil }
        for suffix in [
            ".cohort-alignment-work",
            ".candidate-artifact-work",
        ] where name.hasSuffix(suffix) {
            let exactPattern =
                #"^\..+\.lungfishgenotype\#(suffix)$"#
            return Candidate(
                url: url,
                category: .workflowStaging,
                exactOwnedPattern: name.range(
                    of: exactPattern,
                    options: .regularExpression
                ) != nil
            )
        }
        return nil
    }

    private func isCalendarValidArchiveIdentifier(
        _ identifier: String
    ) -> Bool {
        guard identifier.count >= 18 else { return false }
        let base = String(identifier.prefix(17)) + "Z"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: base) else {
            return false
        }
        return formatter.string(from: date) == base
    }

    private func classifyOwnedWork(
        _ url: URL,
        projectURL: URL
    ) -> ProjectStorageClassification {
        let marker: OwnedWorkDirectoryMarker
        do {
            marker = try OwnedWorkDirectoryMarkerStore.load(
                from: url,
                expectedProjectURL: projectURL
            )
        } catch OwnedWorkDirectoryMarkerError.missingMarker {
            return .notRemovable(
                .missingOwnershipMarker,
                reason:
                    "The owned work-directory marker is missing."
            )
        } catch {
            return .notRemovable(
                .invalidOwnershipMarker,
                reason:
                    "The ownership marker is invalid: "
                    + error.localizedDescription
            )
        }
        if marker.keepIntermediates {
            return .notRemovable(
                .explicitlyRetained,
                reason:
                    "Keep Intermediates explicitly retains this work."
            )
        }
        if marker.state != .active {
            if let lockRelativePath = marker.lockRelativePath {
                let lockURL = projectURL.appendingPathComponent(
                    lockRelativePath
                )
                do {
                    if try lockProbe(lockURL) == .held {
                        return .notRemovable(
                            .heldLock,
                            reason: "The recorded run lock is held."
                        )
                    }
                } catch {
                    return .notRemovable(
                        .unsafeLock,
                        reason:
                            "The recorded run lock is unsafe or unavailable: "
                            + error.localizedDescription
                    )
                }
            }
            if operationHistoryClaimsLiveWork(
                marker: marker,
                directoryURL: url,
                projectURL: projectURL
            ) {
                return .notRemovable(
                    .liveOperationHistory,
                    reason:
                        "Append-only operation history still claims "
                        + "this work."
                )
            }
            return .removable(
                .completedOwnedWork,
                reason:
                    "The owned work directory has a terminal marker."
            )
        }

        let currentProcess: OwnedProcessIdentity?
        do {
            currentProcess = try processInspector(
                marker.processIdentifier
            )
        } catch {
            return .notRemovable(
                .liveProcess,
                reason:
                    "The creating process identity could not be "
                    + "conclusively inspected."
            )
        }
        if let currentProcess {
            if marker.matchesProcessIdentity(currentProcess) {
                return .notRemovable(
                    .liveProcess,
                    reason:
                        "The creating process is still live."
                )
            }
            return .notRemovable(
                .liveProcess,
                reason:
                    "The recorded process identifier has been reused by "
                    + "another live process; automatic orphan cleanup "
                    + "fails closed."
            )
        }
        guard let lockRelativePath = marker.lockRelativePath else {
            return .notRemovable(
                .unsafeLock,
                reason:
                    "An active orphan has no recorded lock to prove "
                    + "unlocked."
            )
        }
        let lockURL = projectURL.appendingPathComponent(
            lockRelativePath
        )
        do {
            switch try lockProbe(lockURL) {
            case .unlocked:
                break
            case .held:
                return .notRemovable(
                    .heldLock,
                    reason: "The recorded run lock is held."
                )
            case .missing:
                return .notRemovable(
                    .unsafeLock,
                    reason:
                        "The recorded run lock is missing, so unlocked "
                        + "state is not proven."
                )
            }
        } catch {
            return .notRemovable(
                .unsafeLock,
                reason:
                    "The recorded run lock is unsafe or unavailable: "
                    + error.localizedDescription
            )
        }
        if operationHistoryClaimsLiveWork(
            marker: marker,
            directoryURL: url,
            projectURL: projectURL
        ) {
            return .notRemovable(
                .liveOperationHistory,
                reason:
                    "Append-only operation history still claims live work."
            )
        }
        return .removable(
            .conclusivelyOrphanedOwnedWork,
            reason:
                "The creating process is conclusively dead, the lock is "
                + "unlocked, and no live operation history remains."
        )
    }

    private func operationHistoryClaimsLiveWork(
        marker: OwnedWorkDirectoryMarker,
        directoryURL: URL,
        projectURL: URL
    ) -> Bool {
        let operation = ProjectOperationHistoryWriter(
            projectURL: projectURL
        ).operationDirectoryURL(for: marker.runID)
        var information = stat()
        guard Darwin.lstat(operation.path, &information) == 0 else {
            return errno != ENOENT
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            return true
        }
        let terminal = operation.appendingPathComponent(
            GenotypingCleanupJournal.terminalPayloadName
        )
        var terminalInformation = stat()
        guard Darwin.lstat(
            terminal.path,
            &terminalInformation
        ) == 0,
            terminalInformation.st_mode & S_IFMT == S_IFREG else {
            return true
        }
        struct Terminal: Decodable {
            struct Entry: Decodable {
                let path: String
                let disposition: String
                let error: String?
            }
            let schemaVersion: Int
            let runID: UUID
            let entries: [Entry]
        }
        guard let data = try? readBoundedRegularFileNoFollow(
                terminal,
                maximumBytes: 16 * 1_024 * 1_024
              ),
              let decoded = try? JSONDecoder().decode(
                Terminal.self,
                from: data
              ),
              decoded.schemaVersion == 1,
              decoded.runID == marker.runID else {
            return true
        }
        let matchingEntries = decoded.entries.filter {
            canonicalPlatformPath($0.path)
                == canonicalPlatformPath(directoryURL.path)
        }
        guard matchingEntries.count == 1,
              let entry = matchingEntries.first else {
            return true
        }
        switch entry.disposition {
        case "completed", "failed":
            return false
        case "removed", "already-removed", "intermediates-removed",
             "retained-by-request", "retained-cleanup-failed",
             "retained-identity-mismatch", "retained-rollback-recovery":
            // Removed-but-present is contradictory. Every retained outcome
            // still claims the directory. Both fail closed.
            return true
        default:
            return true
        }
    }

    private func canonicalPlatformPath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized == "/var" || standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        if standardized == "/tmp" || standardized.hasPrefix("/tmp/") {
            return "/private" + standardized
        }
        return standardized
    }

    private func readBoundedRegularFileNoFollow(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let parentDescriptor = try NoFollowFileSystem
            .openDirectoryHierarchy(
                url.standardizedFileURL.deletingLastPathComponent()
            )
        defer { Darwin.close(parentDescriptor) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= Int64(maximumBytes) else {
            throw CocoaError(.fileReadTooLarge)
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard data.count <= maximumBytes - count else {
                throw CocoaError(.fileReadTooLarge)
            }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              data.count == Int(after.st_size) else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    private func measureTree(
        _ root: URL,
        projectURL: URL,
        expectedRootIdentity: FileSystemObjectIdentity,
        entryIndex: Int,
        priorEntries: [ProjectStorageEntry],
        hardLinkAuthorities:
            inout [FileSystemObjectIdentity: HardLinkAuthority],
        visited: inout UInt64,
        report: (UInt64, String) -> Void
    ) throws -> MeasuredTree {
        var rootInformation = stat()
        guard Darwin.lstat(root.path, &rootInformation) == 0,
              FileSystemObjectIdentity(from: rootInformation)
                == expectedRootIdentity else {
            return .init(
                logicalBytes: 0,
                allocatedBytes: 0,
                unsafeReason:
                    "The candidate identity changed before measurement."
            )
        }
        let rootMeasurement = try measureSingleEntry(
            rootInformation,
            identity: expectedRootIdentity,
            entryIndex: entryIndex,
            priorEntries: priorEntries,
            hardLinkAuthorities: &hardLinkAuthorities
        )
        if rootMeasurement.unsafeCode == .resourceLimitExceeded {
            return rootMeasurement
        }
        var logical = rootMeasurement.logicalBytes
        var allocated = rootMeasurement.allocatedBytes
        var unsafeReason: String?
        var enumerationFailure: String?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                enumerationFailure =
                    "\(url.path): \(error.localizedDescription)"
                return false
            }
        ) else {
            return .init(
                logicalBytes: 0,
                allocatedBytes: 0,
                unsafeReason:
                    "The candidate tree is unsafe or unreadable."
            )
        }
        while let url = enumerator.nextObject() as? URL {
            visited = try adding(visited, 1)
            try cancellationCheck()
            report(
                visited,
                relativePath(from: projectURL, to: url)
            )
            var information = stat()
            guard Darwin.lstat(url.path, &information) == 0 else {
                unsafeReason =
                    "The candidate tree changed or became unreadable."
                enumerator.skipDescendants()
                continue
            }
            let type = information.st_mode & S_IFMT
            let identity = FileSystemObjectIdentity(from: information)
            let measured = try measureSingleEntry(
                information,
                identity: identity,
                entryIndex: entryIndex,
                priorEntries: priorEntries,
                hardLinkAuthorities: &hardLinkAuthorities
            )
            if measured.unsafeCode == .resourceLimitExceeded {
                return .init(
                    logicalBytes: 0,
                    allocatedBytes: 0,
                    unsafeReason: measured.unsafeReason,
                    unsafeCode: .resourceLimitExceeded
                )
            }
            logical = try adding(logical, measured.logicalBytes)
            allocated = try adding(
                allocated,
                measured.allocatedBytes
            )
            if type != S_IFREG && type != S_IFDIR {
                unsafeReason =
                    "The candidate contains an unsafe symbolic link or "
                    + "special file."
                enumerator.skipDescendants()
            }
        }
        if let enumerationFailure {
            unsafeReason =
                "The candidate tree could not be completely inspected: "
                + enumerationFailure
        }
        var finalInformation = stat()
        guard Darwin.lstat(root.path, &finalInformation) == 0,
              FileSystemObjectIdentity(from: finalInformation)
                == expectedRootIdentity else {
            return .init(
                logicalBytes: logical,
                allocatedBytes: allocated,
                unsafeReason:
                    "The candidate identity changed while it was measured."
            )
        }
        return .init(
            logicalBytes: logical,
            allocatedBytes: allocated,
            unsafeReason: unsafeReason
        )
    }

    private func measureSingleEntry(
        _ information: stat,
        identity: FileSystemObjectIdentity,
        entryIndex: Int,
        priorEntries: [ProjectStorageEntry],
        hardLinkAuthorities:
            inout [FileSystemObjectIdentity: HardLinkAuthority]
    ) throws -> MeasuredTree {
        guard information.st_size >= 0,
              information.st_blocks >= 0 else {
            return .init(
                logicalBytes: 0,
                allocatedBytes: 0,
                unsafeReason:
                    "The candidate reported invalid filesystem sizes."
            )
        }
        let blocks = UInt64(information.st_blocks)
        guard blocks <= UInt64.max / 512 else {
            return .init(
                logicalBytes: 0,
                allocatedBytes: 0,
                unsafeReason:
                    "The candidate allocated size overflowed."
            )
        }
        let allocatedBytes = blocks * 512
        if information.st_mode & S_IFMT == S_IFREG,
           information.st_nlink > 1 {
            let firstObservation = hardLinkAuthorities[identity] == nil
            if firstObservation,
               hardLinkAuthorities.count >= hardLinkIdentityLimit {
                return .init(
                    logicalBytes: 0,
                    allocatedBytes: 0,
                    unsafeReason:
                        "Hard-link identity tracking exceeded the "
                        + "\(formattedIdentityLimit)-entry safety limit.",
                    unsafeCode: .resourceLimitExceeded
                )
            }
            try recordHardLinkOccurrence(
                identity: identity,
                expectedLinkCount: UInt64(information.st_nlink),
                allocatedBytes: allocatedBytes,
                entryIndex: entryIndex,
                priorEntries: priorEntries,
                authorities: &hardLinkAuthorities
            )
            return .init(
                logicalBytes:
                    firstObservation ? UInt64(information.st_size) : 0,
                allocatedBytes:
                    firstObservation ? allocatedBytes : 0,
                unsafeReason: nil
            )
        }
        return .init(
            logicalBytes: UInt64(information.st_size),
            allocatedBytes: allocatedBytes,
            unsafeReason: nil
        )
    }

    private var formattedIdentityLimit: String {
        let digits = String(hardLinkIdentityLimit)
        var reversed: [Character] = []
        reversed.reserveCapacity(digits.count + digits.count / 3)
        for (index, digit) in digits.reversed().enumerated() {
            if index > 0, index.isMultiple(of: 3) {
                reversed.append(",")
            }
            reversed.append(digit)
        }
        return String(reversed.reversed())
    }

    private func adjustEntriesForSurvivingHardLinks(
        _ entries: inout [ProjectStorageEntry],
        authorities:
            [FileSystemObjectIdentity: HardLinkAuthority],
        projectIdentity: FileSystemObjectIdentity
    ) {
        for initialAuthority in authorities.values {
            var authority = initialAuthority
            finalizePendingHardLinkOccurrences(
                &authority,
                entries: entries
            )
            guard !authority.expectedCountAgrees
                    || authority.removableOccurrences
                        != authority.expectedLinkCount else {
                continue
            }
            guard let allocation = authority.countedAllocation else {
                continue
            }
            guard entries.indices.contains(allocation.entryIndex) else {
                continue
            }
            let entry = entries[allocation.entryIndex]
            entries[allocation.entryIndex] = ProjectStorageEntry(
                projectIdentity: projectIdentity,
                relativePath: entry.relativePath,
                identity: entry.identity,
                category: entry.category,
                logicalBytes: entry.logicalBytes,
                allocatedBytes:
                    entry.allocatedBytes >= allocation.bytes
                    ? entry.allocatedBytes - allocation.bytes
                    : 0,
                modificationDate: entry.modificationDate,
                classification: entry.classification
            )
        }
    }

    private func recordHardLinkOccurrence(
        identity: FileSystemObjectIdentity,
        expectedLinkCount: UInt64,
        allocatedBytes: UInt64,
        entryIndex: Int,
        priorEntries: [ProjectStorageEntry],
        authorities:
            inout [FileSystemObjectIdentity: HardLinkAuthority]
    ) throws {
        guard var authority = authorities[identity] else {
            authorities[identity] = HardLinkAuthority(
                expectedLinkCount: expectedLinkCount,
                expectedCountAgrees: true,
                removableOccurrences: 0,
                pendingEntryIndex: entryIndex,
                pendingOccurrences: 1,
                countedAllocation: (entryIndex, allocatedBytes)
            )
            return
        }
        if authority.expectedLinkCount != expectedLinkCount {
            authority.expectedCountAgrees = false
        }
        if authority.pendingEntryIndex == entryIndex {
            let (occurrences, overflow) =
                authority.pendingOccurrences.addingReportingOverflow(1)
            if overflow {
                authority.expectedCountAgrees = false
            } else {
                authority.pendingOccurrences = occurrences
            }
        } else {
            finalizePendingHardLinkOccurrences(
                &authority,
                entries: priorEntries
            )
            authority.pendingEntryIndex = entryIndex
            authority.pendingOccurrences = 1
        }
        authorities[identity] = authority
    }

    private func finalizePendingHardLinkOccurrences(
        _ authority: inout HardLinkAuthority,
        entries: [ProjectStorageEntry]
    ) {
        guard entries.indices.contains(authority.pendingEntryIndex) else {
            authority.expectedCountAgrees = false
            authority.pendingOccurrences = 0
            return
        }
        if entries[authority.pendingEntryIndex]
            .classification.isRemovable {
            let (occurrences, overflow) =
                authority.removableOccurrences.addingReportingOverflow(
                    authority.pendingOccurrences
                )
            if overflow {
                authority.expectedCountAgrees = false
            } else {
                authority.removableOccurrences = occurrences
            }
        }
        authority.pendingOccurrences = 0
    }

    private func unavailableEntry(
        projectIdentity: FileSystemObjectIdentity,
        relativePath: String,
        candidate: Candidate,
        reason: String
    ) -> ProjectStorageEntry {
        .init(
            projectIdentity: projectIdentity,
            relativePath: relativePath,
            identity: .init(device: 0, inode: 0),
            category: candidate.category,
            logicalBytes: 0,
            allocatedBytes: 0,
            modificationDate: .distantPast,
            classification: .notRemovable(
                .inspectionFailed,
                reason: reason
            )
        )
    }

    private func relativePath(
        from root: URL,
        to url: URL
    ) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func modificationDate(_ information: stat) -> Date {
        Date(
            timeIntervalSince1970:
                TimeInterval(information.st_mtimespec.tv_sec)
                + TimeInterval(
                    information.st_mtimespec.tv_nsec
                ) / 1_000_000_000
        )
    }

    private func adding(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw CocoaError(.fileReadTooLarge)
        }
        return value
    }
}

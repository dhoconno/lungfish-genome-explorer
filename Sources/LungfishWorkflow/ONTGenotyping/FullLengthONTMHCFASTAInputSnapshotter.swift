import CryptoKit
import Darwin
import Foundation

struct FullLengthONTMHCFASTAInputSnapshot: Sendable {
    let url: URL
    let descriptor: FullLengthONTMHCArtifactDescriptor
    let transformation: FullLengthONTMHCInProcessTransformationRecord
}

struct FullLengthONTMHCFASTAInputSnapshotter {
    private static let bufferSize = 64 * 1_024

    func snapshot(sourceURL: URL, to snapshotURL: URL) throws -> FullLengthONTMHCFASTAInputSnapshot {
        let startedAt = Date()
        let sourceDescriptor = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Could not open source cluster FASTA without following links: \(sourceURL.path)"
            )
        }
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? sourceHandle.close() }

        var initialInfo = stat()
        guard Darwin.fstat(sourceDescriptor, &initialInfo) == 0,
              initialInfo.st_mode & S_IFMT == S_IFREG else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Source cluster FASTA is not a stable regular file: \(sourceURL.path)"
            )
        }

        let destinationDescriptor = Darwin.open(
            snapshotURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let destinationHandle = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
        var shouldRemoveSnapshot = true
        defer {
            try? destinationHandle.close()
            if shouldRemoveSnapshot { try? FileManager.default.removeItem(at: snapshotURL) }
        }

        var hasher = SHA256()
        var byteSize: UInt64 = 0
        while let data = try sourceHandle.read(upToCount: Self.bufferSize), !data.isEmpty {
            hasher.update(data: data)
            byteSize += UInt64(data.count)
            try destinationHandle.write(contentsOf: data)
        }
        try destinationHandle.synchronize()

        var finalSourceInfo = stat()
        var snapshotInfo = stat()
        guard Darwin.fstat(sourceDescriptor, &finalSourceInfo) == 0,
              Darwin.fstat(destinationDescriptor, &snapshotInfo) == 0,
              snapshotInfo.st_mode & S_IFMT == S_IFREG,
              sameIdentityAndContentMetadata(initialInfo, finalSourceInfo),
              byteSize == UInt64(initialInfo.st_size),
              byteSize == UInt64(snapshotInfo.st_size) else {
            throw FullLengthONTMHCAlignmentSafetyError(
                "Source cluster FASTA changed while its immutable snapshot was being captured: \(sourceURL.path)"
            )
        }

        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let inputDescriptor = FullLengthONTMHCArtifactDescriptor(
            path: sourceURL.standardizedFileURL.path,
            sha256: sha256,
            byteSize: byteSize,
            role: .sourceClusterFASTA,
            phase: .input
        )
        let outputDescriptor = FullLengthONTMHCArtifactDescriptor(
            path: snapshotURL.standardizedFileURL.path,
            sha256: sha256,
            byteSize: byteSize,
            role: .snapshotClusterFASTA,
            phase: .temporary
        )
        let completedAt = Date()
        shouldRemoveSnapshot = false
        return .init(
            url: snapshotURL.standardizedFileURL,
            descriptor: outputDescriptor,
            transformation: .init(
                workflowName: "lungfish-in-process:snapshot-mhc-cluster-fasta",
                workflowVersion: WorkflowRun.currentAppVersion,
                argv: [
                    "lungfish-in-process", "snapshot-mhc-cluster-fasta",
                    "--buffer-bytes", String(Self.bufferSize),
                    "--require-stable-source", "true",
                    sourceURL.standardizedFileURL.path,
                    snapshotURL.standardizedFileURL.path,
                ],
                resolvedOptions: [
                    "bufferBytes": String(Self.bufferSize),
                    "copyMode": "streaming",
                    "followSymlinks": "false",
                    "requireStableSource": "true",
                    "snapshotIsAuthoritative": "true",
                ],
                inputs: [inputDescriptor],
                outputs: [outputDescriptor],
                exitStatus: 0,
                startedAt: startedAt,
                completedAt: completedAt,
                wallTime: completedAt.timeIntervalSince(startedAt)
            )
        )
    }

    private func sameIdentityAndContentMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

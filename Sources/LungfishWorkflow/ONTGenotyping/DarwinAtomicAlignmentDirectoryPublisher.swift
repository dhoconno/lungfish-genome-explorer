import Foundation
import Darwin
import LungfishCore
import LungfishIO

public struct DarwinAtomicAlignmentDirectoryPublisher: FullLengthONTMHCAlignmentDirectoryPublishing {
    private let operations: PortableRename.Operations?

    public init() {
        operations = nil
    }

    init(operations: PortableRename.Operations) {
        self.operations = operations
    }

    /// Publishes with `RENAME_EXCL`, or with `RENAME_SWAP` when the
    /// alignments already exist. On ExFAT, FAT and SMB, which reject both,
    /// `PortableRename` reserves the name or rotates through a tombstone.
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
        let outcome = sourceURL.path.withCString { stagedPath in
            destinationURL.path.withCString { finalPath in
                PortableRename.renameatxNPReporting(
                    AT_FDCWD, stagedPath, AT_FDCWD, finalPath, flags,
                    operations: operations ?? .current
                )
            }
        }
        let code = outcome.status == 0 ? nil : POSIXErrorCode(rawValue: errno) ?? .EIO
        let record = FullLengthONTMHCAlignmentDirectoryPublicationRecord(
            mode: mode,
            sourceDirectoryURL: sourceURL,
            finalDirectoryURL: destinationURL,
            exitStatus: outcome.status,
            errorMessage: code.map { POSIXError($0).localizedDescription },
            startedAt: startedAt,
            completedAt: Date(),
            atomicMechanism: Self.recordedMechanism(outcome.mechanism)
        )
        guard outcome.status == 0 else {
            throw FullLengthONTMHCAlignmentDirectoryPublicationError(record: record)
        }
        return FullLengthONTMHCAlignmentDirectoryPublication(
            retiredDirectoryURL: finalExists ? sourceURL : nil,
            record: record
        )
    }

    private static func recordedMechanism(_ mechanism: PortableRename.Mechanism) -> String {
        switch mechanism {
        case .nativeExclusive, .nativeSwap: return "renameatx_np"
        case .reservationFallback: return "exclusive-directory-reservation-then-rename"
        case .rotationFallback: return mechanism.rawValue
        }
    }
}

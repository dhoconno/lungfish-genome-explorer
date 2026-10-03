import Foundation
import Darwin
import LungfishIO

private struct DarwinFullLengthONTMHCAlignmentDirectoryRenamer:
    FullLengthONTMHCAlignmentDirectoryRenaming
{
    func rename(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL,
        flags: UInt32
    ) -> FullLengthONTMHCAlignmentDirectoryRenameAttempt {
        let status = stagedDirectoryURL.path.withCString { stagedPath in
            finalDirectoryURL.path.withCString { finalPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    stagedPath,
                    AT_FDCWD,
                    finalPath,
                    flags
                )
            }
        }
        return FullLengthONTMHCAlignmentDirectoryRenameAttempt(
            status: status,
            errorCode: status == 0 ? nil : errno
        )
    }
}

public struct DarwinAtomicAlignmentDirectoryPublisher: FullLengthONTMHCAlignmentDirectoryPublishing {
    private let renamer: any FullLengthONTMHCAlignmentDirectoryRenaming

    public init() {
        renamer = DarwinFullLengthONTMHCAlignmentDirectoryRenamer()
    }

    init(renamer: any FullLengthONTMHCAlignmentDirectoryRenaming) {
        self.renamer = renamer
    }

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
        var attempt = renamer.rename(
            stagedDirectoryURL: sourceURL,
            finalDirectoryURL: destinationURL,
            flags: flags
        )
        var usedUnsupportedExclusiveRenameFallback = false
        if mode == .create,
           attempt.status != 0,
           attempt.errorCode == ENOTSUP {
            usedUnsupportedExclusiveRenameFallback = true
            let reservationStatus = destinationURL.path.withCString {
                mkdir($0, mode_t(S_IRWXU))
            }
            if reservationStatus != 0 {
                attempt = FullLengthONTMHCAlignmentDirectoryRenameAttempt(
                    status: -1,
                    errorCode: errno
                )
            } else {
                attempt = renamer.rename(
                    stagedDirectoryURL: sourceURL,
                    finalDirectoryURL: destinationURL,
                    flags: 0
                )
                if attempt.status != 0 {
                    _ = destinationURL.path.withCString { rmdir($0) }
                }
            }
        }
        let status = attempt.status
        let code = attempt.errorCode.map { POSIXErrorCode(rawValue: $0) ?? .EIO }
        let completedAt = Date()
        let record = FullLengthONTMHCAlignmentDirectoryPublicationRecord(
            mode: mode,
            sourceDirectoryURL: sourceURL,
            finalDirectoryURL: destinationURL,
            exitStatus: status,
            errorMessage: code.map { POSIXError($0).localizedDescription },
            startedAt: startedAt,
            completedAt: completedAt,
            atomicMechanism: usedUnsupportedExclusiveRenameFallback
                ? "exclusive-directory-reservation-then-rename"
                : "renameatx_np"
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

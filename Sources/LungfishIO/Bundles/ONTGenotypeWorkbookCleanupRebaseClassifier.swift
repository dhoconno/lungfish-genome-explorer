import CryptoKit
import Darwin
import Foundation

enum ONTGenotypeWorkbookCleanupRebaseClassifier {
    enum Decision: Equatable {
        case exact(device: dev_t, inode: ino_t)
        case rebased(device: dev_t, inode: ino_t)
        case reject
    }

    static func classify(
        before: stat,
        postDescriptor: stat,
        postPath: stat,
        mechanism: PortableExclusiveRename.Mechanism,
        originalNameIsAbsent: Bool
    ) -> Decision {
        guard originalNameIsAbsent,
              sameKernelIdentity(postDescriptor, postPath) else {
            return .reject
        }
        if sameKernelIdentity(before, postDescriptor) {
            return .exact(
                device: postDescriptor.st_dev,
                inode: postDescriptor.st_ino
            )
        }
        guard mechanism == .reservationFallback,
              before.st_mode & S_IFMT == S_IFREG,
              postDescriptor.st_mode & S_IFMT == S_IFREG,
              before.st_size == 0,
              postDescriptor.st_size == 0,
              stableMetadataMatches(before, postDescriptor) else {
            return .reject
        }
        return .rebased(
            device: postDescriptor.st_dev,
            inode: postDescriptor.st_ino
        )
    }

    static func sameKernelIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    }

    static func identityAndStableMetadataMatch(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        sameKernelIdentity(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mode & mode_t(0o7777) == rhs.st_mode & mode_t(0o7777)
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func stableMetadataMatches(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
            && lhs.st_size == rhs.st_size
            && lhs.st_mode & mode_t(0o7777) == rhs.st_mode & mode_t(0o7777)
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

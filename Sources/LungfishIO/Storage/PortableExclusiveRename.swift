import Darwin
import Foundation

/// Preserves create-only rename semantics on filesystems that do not
/// implement Darwin's `RENAME_EXCL` extension.
///
/// The preferred path is still one kernel-level exclusive rename. When a
/// filesystem reports `ENOTSUP` or `EOPNOTSUPP`, Lungfish first creates the
/// destination entry exclusively and then replaces only that reservation with
/// an ordinary same-filesystem rename.
///
/// The reservation fallback is used only while the caller holds its
/// cooperative publication lock. Source and reservation witnesses are checked
/// immediately before `renameat`, but ordinary rename still leaves one
/// unavoidable syscall-sized race after that validation. The lock plus an
/// unpredictable random tombstone name form the trust boundary for that gap;
/// callers that detach cleanup entries must also validate the post-rename
/// descriptor/path witnesses.
public enum PortableExclusiveRename {
    enum Mechanism: String, Equatable, Sendable {
        case nativeExclusive = "renameatx_np"
        case reservationFallback = "reservation-renameat"
    }

    struct Outcome: Equatable, Sendable {
        let status: Int32
        let mechanism: Mechanism
    }

    /// A borrowed regular-file descriptor and the metadata captured before the
    /// publication operation. The caller retains descriptor ownership.
    struct RegularSourceWitness {
        let descriptor: Int32
        let expected: stat
    }

    struct Operations: Sendable {
        typealias NativeRenamer = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            Int32,
            UnsafePointer<CChar>,
            UInt32
        ) -> Int32
        typealias OrdinaryRenamer = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            Int32,
            UnsafePointer<CChar>
        ) -> Int32
        typealias DirectoryReservationCreator = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            mode_t
        ) -> Int32
        typealias PathInspector = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            UnsafeMutablePointer<stat>,
            Int32
        ) -> Int32
        typealias DescriptorCloser = @Sendable (Int32) -> Int32
        typealias EntryRemover = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            Int32
        ) -> Int32

        var nativeRename: NativeRenamer
        var ordinaryRename: OrdinaryRenamer
        var createDirectoryReservation: DirectoryReservationCreator
        var inspectDirectoryReservation: PathInspector
        var closeDescriptor: DescriptorCloser
        var removeEntry: EntryRemover
        var afterReservationCreated: @Sendable () -> Void
        var afterFinalWitnessValidation: @Sendable () -> Void

        init(
            nativeRename: @escaping NativeRenamer = {
                Darwin.renameatx_np($0, $1, $2, $3, $4)
            },
            ordinaryRename: @escaping OrdinaryRenamer = {
                Darwin.renameat($0, $1, $2, $3)
            },
            createDirectoryReservation: @escaping DirectoryReservationCreator = {
                Darwin.mkdirat($0, $1, $2)
            },
            inspectDirectoryReservation: @escaping PathInspector = {
                Darwin.fstatat($0, $1, $2, $3)
            },
            closeDescriptor: @escaping DescriptorCloser = {
                Darwin.close($0)
            },
            removeEntry: @escaping EntryRemover = {
                Darwin.unlinkat($0, $1, $2)
            },
            afterReservationCreated: @escaping @Sendable () -> Void = {},
            afterFinalWitnessValidation: @escaping @Sendable () -> Void = {}
        ) {
            self.nativeRename = nativeRename
            self.ordinaryRename = ordinaryRename
            self.createDirectoryReservation = createDirectoryReservation
            self.inspectDirectoryReservation = inspectDirectoryReservation
            self.closeDescriptor = closeDescriptor
            self.removeEntry = removeEntry
            self.afterReservationCreated = afterReservationCreated
            self.afterFinalWitnessValidation = afterFinalWitnessValidation
        }

        static let darwin = Operations()
    }

    public static func renameatxNP(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        _ flags: UInt32
    ) -> Int32 {
        renameatxNPReporting(
            sourceParent,
            sourceName,
            destinationParent,
            destinationName,
            flags
        ).status
    }

    static func renameatxNPReporting(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        _ flags: UInt32,
        sourceWitness: RegularSourceWitness? = nil,
        operations: Operations = .darwin
    ) -> Outcome {
        let status = retryOnInterruption {
            operations.nativeRename(
                sourceParent,
                sourceName,
                destinationParent,
                destinationName,
                flags
            )
        }
        guard status != 0 else {
            return Outcome(status: 0, mechanism: .nativeExclusive)
        }
        let code = errno
        guard flags == UInt32(RENAME_EXCL),
              isUnsupportedExclusiveRename(code) else {
            errno = code
            return Outcome(status: status, mechanism: .nativeExclusive)
        }
        return fallbackExclusiveRenameReporting(
            sourceParent,
            sourceName,
            destinationParent,
            destinationName,
            sourceWitness: sourceWitness,
            operations: operations
        )
    }

    /// Completes an exclusive rename after the native filesystem has already
    /// reported that `RENAME_EXCL` is unsupported.
    public static func fallbackExclusiveRename(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>
    ) -> Int32 {
        fallbackExclusiveRenameReporting(
            sourceParent,
            sourceName,
            destinationParent,
            destinationName,
            sourceWitness: nil,
            operations: .darwin
        ).status
    }

    static func fallbackExclusiveRenameReporting(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        sourceWitness: RegularSourceWitness?,
        operations: Operations
    ) -> Outcome {
        var sourceInfo = stat()
        guard retryFstatat(
            sourceParent,
            sourceName,
            &sourceInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return fallbackFailure(errno)
        }

        switch sourceInfo.st_mode & S_IFMT {
        case S_IFREG:
            return fallbackRegularFileRename(
                sourceParent,
                sourceName,
                destinationParent,
                destinationName,
                pathInformation: sourceInfo,
                sourceWitness: sourceWitness,
                operations: operations
            )
        case S_IFDIR:
            guard sourceWitness == nil else {
                return fallbackFailure(ESTALE)
            }
            return fallbackDirectoryRename(
                sourceParent,
                sourceName,
                destinationParent,
                destinationName,
                operations: operations
            )
        default:
            return fallbackFailure(ENOTSUP)
        }
    }

    public static func isUnsupportedExclusiveRename(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP
    }

    private static func fallbackRegularFileRename(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        pathInformation: stat,
        sourceWitness borrowedWitness: RegularSourceWitness?,
        operations: Operations
    ) -> Outcome {
        let witness: RegularSourceWitness
        let ownsSourceDescriptor: Bool
        if let borrowedWitness {
            witness = borrowedWitness
            ownsSourceDescriptor = false
        } else {
            let descriptor = retryOnInterruption {
                Darwin.openat(
                    sourceParent,
                    sourceName,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                return fallbackFailure(errno)
            }
            var descriptorInformation = stat()
            guard retryFstat(descriptor, &descriptorInformation) == 0 else {
                let code = errno
                _ = operations.closeDescriptor(descriptor)
                return fallbackFailure(code)
            }
            witness = RegularSourceWitness(
                descriptor: descriptor,
                expected: descriptorInformation
            )
            ownsSourceDescriptor = true
        }

        guard sameIdentityAndMetadata(pathInformation, witness.expected),
              sameIdentityAndMetadata(
                  parent: sourceParent,
                  name: sourceName,
                  descriptor: witness.descriptor,
                  expected: witness.expected
              ) else {
            closeOwnedSource(
                witness.descriptor,
                owned: ownsSourceDescriptor,
                operations: operations
            )
            return fallbackFailure(ESTALE)
        }

        let reservationDescriptor = retryOnInterruption {
            Darwin.openat(
                destinationParent,
                destinationName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard reservationDescriptor >= 0 else {
            let code = errno
            closeOwnedSource(
                witness.descriptor,
                owned: ownsSourceDescriptor,
                operations: operations
            )
            return fallbackFailure(code)
        }

        var reservationInformation = stat()
        guard retryFstat(reservationDescriptor, &reservationInformation) == 0 else {
            let code = errno
            _ = operations.closeDescriptor(reservationDescriptor)
            closeOwnedSource(
                witness.descriptor,
                owned: ownsSourceDescriptor,
                operations: operations
            )
            return fallbackFailure(code)
        }

        operations.afterReservationCreated()

        guard sameIdentityAndMetadata(
                  parent: sourceParent,
                  name: sourceName,
                  descriptor: witness.descriptor,
                  expected: witness.expected
              ),
              sameIdentity(
                  parent: destinationParent,
                  name: destinationName,
                  descriptor: reservationDescriptor,
                  expected: reservationInformation
              ) else {
            finishFailedReservation(
                code: ESTALE,
                destinationParent: destinationParent,
                destinationName: destinationName,
                reservationDescriptor: reservationDescriptor,
                reservationInformation: reservationInformation,
                sourceDescriptor: witness.descriptor,
                ownsSourceDescriptor: ownsSourceDescriptor,
                operations: operations
            )
            return fallbackFailure(ESTALE)
        }

        // Both witnesses were checked above. This injected checkpoint is
        // intentionally the final instruction before the ordinary rename and
        // documents the syscall-sized cooperative-lock/random-name trust gap.
        operations.afterFinalWitnessValidation()
        let status = retryOnInterruption {
            operations.ordinaryRename(
                sourceParent,
                sourceName,
                destinationParent,
                destinationName
            )
        }
        guard status == 0 else {
            let code = errno
            finishFailedReservation(
                code: code,
                destinationParent: destinationParent,
                destinationName: destinationName,
                reservationDescriptor: reservationDescriptor,
                reservationInformation: reservationInformation,
                sourceDescriptor: witness.descriptor,
                ownsSourceDescriptor: ownsSourceDescriptor,
                operations: operations
            )
            return fallbackFailure(code)
        }

        _ = operations.closeDescriptor(reservationDescriptor)
        closeOwnedSource(
            witness.descriptor,
            owned: ownsSourceDescriptor,
            operations: operations
        )
        return Outcome(status: 0, mechanism: .reservationFallback)
    }

    private static func fallbackDirectoryRename(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        operations: Operations
    ) -> Outcome {
        let reservationStatus = retryOnInterruption {
            operations.createDirectoryReservation(
                destinationParent,
                destinationName,
                S_IRWXU
            )
        }
        guard reservationStatus == 0 else {
            return fallbackFailure(errno)
        }

        var reservationInformation = stat()
        let inspectionStatus = retryOnInterruption {
            operations.inspectDirectoryReservation(
                destinationParent,
                destinationName,
                &reservationInformation,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectionStatus == 0 else {
            let code = errno
            while operations.removeEntry(
                destinationParent,
                destinationName,
                AT_REMOVEDIR
            ) != 0, errno == EINTR {}
            return fallbackFailure(code)
        }

        let status = retryOnInterruption {
            operations.ordinaryRename(
                sourceParent,
                sourceName,
                destinationParent,
                destinationName
            )
        }
        guard status == 0 else {
            let code = errno
            removeReservationIfUnchanged(
                parent: destinationParent,
                name: destinationName,
                expected: reservationInformation,
                operations: operations
            )
            return fallbackFailure(code)
        }
        return Outcome(status: 0, mechanism: .reservationFallback)
    }

    private static func finishFailedReservation(
        code: Int32,
        destinationParent: Int32,
        destinationName: UnsafePointer<CChar>,
        reservationDescriptor: Int32,
        reservationInformation: stat,
        sourceDescriptor: Int32,
        ownsSourceDescriptor: Bool,
        operations: Operations
    ) {
        removeReservationIfUnchanged(
            parent: destinationParent,
            name: destinationName,
            expected: reservationInformation,
            operations: operations
        )
        _ = operations.closeDescriptor(reservationDescriptor)
        closeOwnedSource(
            sourceDescriptor,
            owned: ownsSourceDescriptor,
            operations: operations
        )
        errno = code
    }

    private static func closeOwnedSource(
        _ descriptor: Int32,
        owned: Bool,
        operations: Operations
    ) {
        if owned {
            _ = operations.closeDescriptor(descriptor)
        }
    }

    private static func sameIdentityAndMetadata(
        parent: Int32,
        name: UnsafePointer<CChar>,
        descriptor: Int32,
        expected: stat
    ) -> Bool {
        var nameInformation = stat()
        guard retryFstatat(parent, name, &nameInformation, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentityAndMetadata(nameInformation, expected) else {
            return false
        }
        var descriptorInformation = stat()
        guard retryFstat(descriptor, &descriptorInformation) == 0 else {
            return false
        }
        return sameIdentityAndMetadata(descriptorInformation, expected)
    }

    private static func sameIdentityAndMetadata(
        parent: Int32,
        name: UnsafePointer<CChar>,
        expected: stat
    ) -> Bool {
        var information = stat()
        guard retryFstatat(parent, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            return false
        }
        return sameIdentityAndMetadata(information, expected)
    }

    private static func sameIdentityAndMetadata(_ current: stat, _ expected: stat) -> Bool {
        sameIdentity(current, expected)
            && current.st_size == expected.st_size
            && permissionBits(current.st_mode) == permissionBits(expected.st_mode)
            && current.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec
            && current.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
            && current.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec
            && current.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
    }

    private static func sameIdentity(
        parent: Int32,
        name: UnsafePointer<CChar>,
        descriptor: Int32,
        expected: stat
    ) -> Bool {
        var nameInformation = stat()
        guard retryFstatat(parent, name, &nameInformation, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentity(nameInformation, expected) else {
            return false
        }
        var descriptorInformation = stat()
        guard retryFstat(descriptor, &descriptorInformation) == 0 else {
            return false
        }
        return sameIdentity(descriptorInformation, expected)
    }

    private static func sameIdentity(
        parent: Int32,
        name: UnsafePointer<CChar>,
        expected: stat
    ) -> Bool {
        var information = stat()
        guard retryFstatat(parent, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            return false
        }
        return sameIdentity(information, expected)
    }

    private static func sameIdentity(_ current: stat, _ expected: stat) -> Bool {
        current.st_dev == expected.st_dev
            && current.st_ino == expected.st_ino
            && current.st_mode & S_IFMT == expected.st_mode & S_IFMT
    }

    private static func permissionBits(_ mode: mode_t) -> mode_t {
        mode & mode_t(0o7777)
    }

    private static func retryFstat(_ descriptor: Int32, _ information: UnsafeMutablePointer<stat>) -> Int32 {
        retryOnInterruption {
            Darwin.fstat(descriptor, information)
        }
    }

    private static func retryFstatat(
        _ parent: Int32,
        _ name: UnsafePointer<CChar>,
        _ information: UnsafeMutablePointer<stat>,
        _ flags: Int32
    ) -> Int32 {
        retryOnInterruption {
            Darwin.fstatat(parent, name, information, flags)
        }
    }

    private static func retryOnInterruption(_ operation: () -> Int32) -> Int32 {
        while true {
            let status = operation()
            if status == -1, errno == EINTR {
                continue
            }
            return status
        }
    }

    private static func fallbackFailure(_ code: Int32) -> Outcome {
        errno = code
        return Outcome(status: -1, mechanism: .reservationFallback)
    }

    private static func removeReservationIfUnchanged(
        parent: Int32,
        name: UnsafePointer<CChar>,
        expected: stat,
        operations: Operations
    ) {
        var current = stat()
        guard retryFstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentity(current, expected) else {
            return
        }
        let flags = current.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0
        while operations.removeEntry(parent, name, flags) != 0, errno == EINTR {}
    }
}

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
public enum PortableRename {
    /// How a rename was carried out, for provenance and diagnostics.
    public enum Mechanism: String, Equatable, Sendable {
        /// One kernel `renameatx_np` with `RENAME_EXCL` (or no flag).
        case nativeExclusive = "renameatx_np"
        /// The name was reserved exclusively, then replaced by an ordinary rename.
        case reservationFallback = "reservation-renameat"
        /// One kernel `renameatx_np` with `RENAME_SWAP`.
        case nativeSwap = "renameatx_np-swap"
        /// Three exclusive renames through a hidden tombstone name. Not atomic,
        /// see ``PortableRename/swap(_:_:)``.
        case rotationFallback = "tombstone-rotation"
    }

    package struct Outcome: Equatable, Sendable {
        package let status: Int32
        package let mechanism: Mechanism

        package init(status: Int32, mechanism: Mechanism) {
            self.status = status
            self.mechanism = mechanism
        }
    }

    /// A borrowed regular-file descriptor and the metadata captured before the
    /// publication operation. The caller retains descriptor ownership.
    package struct RegularSourceWitness {
        package let descriptor: Int32
        package let expected: stat

        package init(descriptor: Int32, expected: stat) {
            self.descriptor = descriptor
            self.expected = expected
        }
    }

    package struct Operations: Sendable {
        package typealias NativeRenamer = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            Int32,
            UnsafePointer<CChar>,
            UInt32
        ) -> Int32
        package typealias OrdinaryRenamer = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            Int32,
            UnsafePointer<CChar>
        ) -> Int32
        package typealias DirectoryReservationCreator = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            mode_t
        ) -> Int32
        package typealias PathInspector = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            UnsafeMutablePointer<stat>,
            Int32
        ) -> Int32
        package typealias DescriptorCloser = @Sendable (Int32) -> Int32
        package typealias EntryRemover = @Sendable (
            Int32,
            UnsafePointer<CChar>,
            Int32
        ) -> Int32

        package var nativeRename: NativeRenamer
        package var ordinaryRename: OrdinaryRenamer
        package var createDirectoryReservation: DirectoryReservationCreator
        package var inspectDirectoryReservation: PathInspector
        package var closeDescriptor: DescriptorCloser
        package var removeEntry: EntryRemover
        package var afterReservationCreated: @Sendable () -> Void
        package var afterFinalWitnessValidation: @Sendable () -> Void

        package init(
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

        /// The real system calls. A Debug build honours
        /// `LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS=1`, which makes every
        /// flagged rename take its fallback, as on ExFAT.
        package static let darwin = Operations.forEnvironment(ProcessInfo.processInfo.environment)
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

    package static func renameatxNPReporting(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        _ flags: UInt32,
        sourceWitness: RegularSourceWitness? = nil,
        operations: Operations = .current
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
            return Outcome(status: 0, mechanism: flags == UInt32(RENAME_SWAP) ? .nativeSwap : .nativeExclusive)
        }
        let code = errno
        if flags == UInt32(RENAME_SWAP), isUnsupportedExclusiveRename(code) {
            return fallbackSwapReporting(
                sourceParent,
                sourceName,
                destinationParent,
                destinationName,
                operations: operations
            )
        }
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

    /// The kernel call alone, with no fallback. For a caller that must record
    /// that it is falling back (in provenance, say) before it does so. On an
    /// unsupported flag it then calls ``fallbackExclusiveRename(_:_:_:_:)`` or
    /// ``fallbackSwap(_:_:_:_:)``. Everyone else calls ``renameatxNP(_:_:_:_:_:)``.
    public static func nativeRenameatx(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        _ flags: UInt32
    ) -> Int32 {
        let operations = Operations.current
        return retryOnInterruption {
            operations.nativeRename(sourceParent, sourceName, destinationParent, destinationName, flags)
        }
    }

    /// Completes a swap after the native filesystem has already reported that
    /// `RENAME_SWAP` is unsupported.
    public static func fallbackSwap(
        _ firstParent: Int32,
        _ firstName: UnsafePointer<CChar>,
        _ secondParent: Int32,
        _ secondName: UnsafePointer<CChar>
    ) -> Int32 {
        fallbackSwapReporting(firstParent, firstName, secondParent, secondName, operations: .current).status
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
            operations: .current
        ).status
    }

    package static func fallbackExclusiveRenameReporting(
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
        case S_IFLNK:
            guard sourceWitness == nil else {
                return fallbackFailure(ESTALE)
            }
            return fallbackSymbolicLinkRename(
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

    /// Reserves the name with an exclusive `symlinkat`, then renames the
    /// source link over that reservation. ExFAT stores symbolic links.
    private static func fallbackSymbolicLinkRename(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        operations: Operations
    ) -> Outcome {
        let reservationStatus = retryOnInterruption {
            Darwin.symlinkat(".lungfish-rename-reservation", destinationParent, destinationName)
        }
        guard reservationStatus == 0 else {
            return fallbackFailure(errno)
        }
        var reservationInformation = stat()
        guard retryFstatat(destinationParent, destinationName, &reservationInformation, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            while operations.removeEntry(destinationParent, destinationName, 0) != 0, errno == EINTR {}
            return fallbackFailure(code)
        }
        let status = retryOnInterruption {
            operations.ordinaryRename(sourceParent, sourceName, destinationParent, destinationName)
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

    /// Whether `code` means the volume does not support a rename flag
    /// (`RENAME_EXCL` or `RENAME_SWAP`), as on ExFAT, FAT and SMB.
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

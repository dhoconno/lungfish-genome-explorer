import Darwin
import Foundation

/// Preserves create-only rename semantics on filesystems that do not
/// implement Darwin's `RENAME_EXCL` extension.
///
/// The preferred path is still one kernel-level exclusive rename. When a
/// filesystem reports `ENOTSUP` or `EOPNOTSUPP`, Lungfish first creates the
/// destination entry exclusively and then replaces only that reservation with
/// an ordinary same-filesystem rename. A destination that already exists when
/// the reservation is acquired is never replaced. Callers use this fallback
/// only while holding their normal workflow or transaction lock because the
/// reservation-plus-rename sequence is not one indivisible kernel operation.
public enum PortableExclusiveRename {
    public static func renameatxNP(
        _ sourceParent: Int32,
        _ sourceName: UnsafePointer<CChar>,
        _ destinationParent: Int32,
        _ destinationName: UnsafePointer<CChar>,
        _ flags: UInt32
    ) -> Int32 {
        let status = Darwin.renameatx_np(
            sourceParent,
            sourceName,
            destinationParent,
            destinationName,
            flags
        )
        guard status != 0 else { return 0 }
        let code = errno
        guard flags == UInt32(RENAME_EXCL),
              isUnsupportedExclusiveRename(code) else {
            errno = code
            return status
        }
        return fallbackExclusiveRename(
            sourceParent,
            sourceName,
            destinationParent,
            destinationName
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
        var sourceInfo = stat()
        guard Darwin.fstatat(
            sourceParent,
            sourceName,
            &sourceInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return -1
        }

        let sourceType = sourceInfo.st_mode & S_IFMT
        let reservationInfo: stat
        if sourceType == S_IFDIR {
            guard Darwin.mkdirat(
                destinationParent,
                destinationName,
                S_IRWXU
            ) == 0 else {
                return -1
            }
            var createdInfo = stat()
            guard Darwin.fstatat(
                destinationParent,
                destinationName,
                &createdInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                let code = errno
                _ = Darwin.unlinkat(
                    destinationParent,
                    destinationName,
                    AT_REMOVEDIR
                )
                errno = code
                return -1
            }
            reservationInfo = createdInfo
        } else if sourceType == S_IFREG {
            let descriptor = Darwin.openat(
                destinationParent,
                destinationName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { return -1 }
            var createdInfo = stat()
            guard Darwin.fstat(descriptor, &createdInfo) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                _ = Darwin.unlinkat(destinationParent, destinationName, 0)
                errno = code
                return -1
            }
            guard Darwin.close(descriptor) == 0 else {
                let code = errno
                removeReservationIfUnchanged(
                    parent: destinationParent,
                    name: destinationName,
                    expected: createdInfo
                )
                errno = code
                return -1
            }
            reservationInfo = createdInfo
        } else {
            errno = ENOTSUP
            return -1
        }

        guard Darwin.renameat(
            sourceParent,
            sourceName,
            destinationParent,
            destinationName
        ) == 0 else {
            let code = errno
            removeReservationIfUnchanged(
                parent: destinationParent,
                name: destinationName,
                expected: reservationInfo
            )
            errno = code
            return -1
        }
        return 0
    }

    public static func isUnsupportedExclusiveRename(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP
    }

    private static func removeReservationIfUnchanged(
        parent: Int32,
        name: UnsafePointer<CChar>,
        expected: stat
    ) {
        var current = stat()
        guard Darwin.fstatat(
            parent,
            name,
            &current,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        current.st_dev == expected.st_dev,
        current.st_ino == expected.st_ino,
        current.st_mode & S_IFMT == expected.st_mode & S_IFMT else {
            return
        }
        let flags = current.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0
        _ = Darwin.unlinkat(parent, name, flags)
    }
}

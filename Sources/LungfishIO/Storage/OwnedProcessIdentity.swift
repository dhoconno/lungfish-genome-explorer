import Darwin
import Foundation

public struct OwnedProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let processStartTime: UInt64
    public let bootSessionID: String

    public init(
        processIdentifier: Int32,
        processStartTime: UInt64,
        bootSessionID: String
    ) {
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.bootSessionID = bootSessionID
    }

    public static func current() throws -> Self {
        guard let identity = try inspect(
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        ) else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "current-process",
                operation: "read process identity",
                code: ESRCH
            )
        }
        return identity
    }

    /// Returns the complete identity of a live process, or `nil` when the PID
    /// no longer exists. A caller must compare every field; PID alone is never
    /// sufficient authority.
    public static func inspect(processIdentifier pid: Int32) throws -> Self? {
        var processInfo = proc_bsdinfo()
        errno = 0
        let result = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            if errno == ESRCH {
                return nil
            }
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "pid:\(pid)",
                operation: "read process start identity",
                code: errno
            )
        }

        var bootSessionSize = 0
        guard sysctlbyname(
            "kern.bootsessionuuid",
            nil,
            &bootSessionSize,
            nil,
            0
        ) == 0, bootSessionSize > 1 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "kern.bootsessionuuid",
                operation: "read boot session identity",
                code: errno
            )
        }
        var bootSessionBytes = [UInt8](repeating: 0, count: bootSessionSize)
        let bootStatus = bootSessionBytes.withUnsafeMutableBytes { bytes in
            sysctlbyname(
                "kern.bootsessionuuid",
                bytes.baseAddress,
                &bootSessionSize,
                nil,
                0
            )
        }
        guard bootStatus == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "kern.bootsessionuuid",
                operation: "read boot session identity",
                code: errno
            )
        }
        let bootID = String(
            decoding: bootSessionBytes.prefix { $0 != 0 },
            as: UTF8.self
        )
        guard UUID(uuidString: bootID) != nil else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "kern.bootsessionuuid",
                operation: "validate boot session identity",
                code: EINVAL
            )
        }

        let processStart = UInt64(processInfo.pbi_start_tvsec) * 1_000_000
            + UInt64(processInfo.pbi_start_tvusec)
        return Self(
            processIdentifier: pid,
            processStartTime: processStart,
            bootSessionID: bootID
        )
    }
}

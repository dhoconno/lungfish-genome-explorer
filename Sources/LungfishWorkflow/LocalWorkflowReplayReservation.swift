import Foundation
import Darwin

/// Exclusive creation for a fresh attempt's private history directory or run bundle.
public enum LocalWorkflowReplayReservation {
    public static func reserveDirectory(at url: URL) throws {
        guard url.isFileURL else { throw LocalWorkflowReplayError.unavailable("A local run directory is required.") }
        let result = url.path.withCString { Darwin.mkdir($0, 0o700) }
        if result != 0 {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

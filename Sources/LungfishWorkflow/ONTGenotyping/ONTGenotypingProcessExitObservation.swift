import Foundation
import Darwin
import LungfishCore
import LungfishIO

final class ONTGenotypingProcessExitObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: Int32?

    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    func record(status: Int32) {
        lock.lock()
        if storedStatus == nil {
            storedStatus = status
        }
        lock.unlock()
    }
}

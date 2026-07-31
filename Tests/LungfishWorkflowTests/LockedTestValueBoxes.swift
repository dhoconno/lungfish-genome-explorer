import Foundation

final class LockedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: URL?

    func set(_ value: URL) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

final class LockedBooleanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

import Darwin
import Foundation
import XCTest
@testable import LungfishIO

final class PortableExclusiveRenameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PortableExclusiveRenameTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReportingWrapperIdentifiesNativeAndReservationFallback() throws {
        let source = try makeFile("source", contents: "payload")
        let nativeDestination = root.appendingPathComponent("native")
        let fallbackDestination = root.appendingPathComponent("fallback")

        let native = withPaths(source, nativeDestination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(nativeRename: { _, _, _, _, _ in 0 })
            )
        }
        XCTAssertEqual(native, .init(status: 0, mechanism: .nativeExclusive))

        let fallback = withPaths(source, fallbackDestination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(nativeRename: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                })
            )
        }
        XCTAssertEqual(fallback, .init(status: 0, mechanism: .reservationFallback))
        XCTAssertEqual(try text(at: fallbackDestination), "payload")
    }

    func testFallbackWithoutBorrowedWitnessOpensHoldsAndClosesItsSourceDescriptor() throws {
        let source = try makeFile("source", contents: "payload")
        let destination = root.appendingPathComponent("destination")
        let identity = try fileInfo(at: source)
        let observedDescriptor = LockedValue<Int32?>(nil)

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    afterReservationCreated: {
                        observedDescriptor.value = openDescriptor(matching: identity)
                    }
                )
            )
        }

        XCTAssertEqual(outcome, .init(status: 0, mechanism: .reservationFallback))
        let descriptor = try XCTUnwrap(observedDescriptor.value)
        XCTAssertEqual(Darwin.fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testFallbackValidatesButNeverClosesBorrowedSourceDescriptor() throws {
        let source = try makeFile("source", contents: "payload")
        let destination = root.appendingPathComponent("destination")
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        let expected = try descriptorInfo(descriptor)

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                sourceWitness: .init(descriptor: descriptor, expected: expected),
                operations: .init(nativeRename: unsupportedNativeRename)
            )
        }

        XCTAssertEqual(outcome, .init(status: 0, mechanism: .reservationFallback))
        XCTAssertGreaterThanOrEqual(Darwin.fcntl(descriptor, F_GETFD), 0)

        var mismatched = expected
        mismatched.st_size += 1
        let invalidDestination = root.appendingPathComponent("invalid")
        let invalid = withPaths(destination, invalidDestination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                sourceWitness: .init(descriptor: descriptor, expected: mismatched),
                operations: .init(nativeRename: unsupportedNativeRename)
            )
        }
        XCTAssertEqual(invalid.status, -1)
        XCTAssertEqual(errno, ESTALE)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidDestination.path))
        XCTAssertGreaterThanOrEqual(Darwin.fcntl(descriptor, F_GETFD), 0)
    }

    func testFallbackHoldsAndRevalidatesRegularSourceAndReservation() throws {
        let source = try makeFile("source", contents: "payload")
        let destination = root.appendingPathComponent("destination")
        let sourceIdentity = try fileInfo(at: source)
        let heldSource = LockedValue<Int32?>(nil)
        let heldReservation = LockedValue<Int32?>(nil)
        let finalValidationCompleted = LockedValue(false)
        let renameObservedFinalValidation = LockedValue(false)

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    ordinaryRename: { sourceParent, sourceName, destinationParent, destinationName in
                        renameObservedFinalValidation.value = finalValidationCompleted.value
                        heldSource.value = openDescriptor(matching: sourceIdentity)
                        let reservationInfo = try! descriptorRelativeFileInfo(
                            parent: destinationParent,
                            name: destinationName
                        )
                        heldReservation.value = openDescriptor(matching: reservationInfo)
                        return Darwin.renameat(
                            sourceParent,
                            sourceName,
                            destinationParent,
                            destinationName
                        )
                    },
                    afterFinalWitnessValidation: {
                        finalValidationCompleted.value = true
                    }
                )
            )
        }

        XCTAssertEqual(outcome.status, 0)
        XCTAssertNotNil(heldSource.value)
        XCTAssertNotNil(heldReservation.value)
        XCTAssertTrue(renameObservedFinalValidation.value)
        XCTAssertEqual(Darwin.fcntl(try XCTUnwrap(heldSource.value), F_GETFD), -1)
        XCTAssertEqual(Darwin.fcntl(try XCTUnwrap(heldReservation.value), F_GETFD), -1)
    }

    func testFallbackRejectsSourceNameSubstitutionAfterReservation() throws {
        let source = try makeFile("source", contents: "original")
        let heldOriginal = root.appendingPathComponent("held-original")
        let destination = root.appendingPathComponent("destination")
        let finalValidationWasCalled = LockedValue(false)

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    closeDescriptor: { descriptor in
                        let status = Darwin.close(descriptor)
                        errno = EBADF
                        return status
                    },
                    removeEntry: { parent, name, flags in
                        let status = Darwin.unlinkat(parent, name, flags)
                        errno = ENOSPC
                        return status
                    },
                    afterReservationCreated: {
                        try! FileManager.default.moveItem(at: source, to: heldOriginal)
                        try! Data("replacement".utf8).write(to: source)
                    },
                    afterFinalWitnessValidation: {
                        finalValidationWasCalled.value = true
                    }
                )
            )
        }

        XCTAssertEqual(outcome, .init(status: -1, mechanism: .reservationFallback))
        XCTAssertEqual(errno, ESTALE)
        XCTAssertEqual(try text(at: heldOriginal), "original")
        XCTAssertEqual(try text(at: source), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(finalValidationWasCalled.value)
    }

    func testFallbackPreservesExistingDestinationErrnoAcrossOwnedSourceClose() throws {
        let source = try makeFile("source", contents: "original")
        let destination = try makeFile("destination", contents: "existing")

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    closeDescriptor: { descriptor in
                        let status = Darwin.close(descriptor)
                        errno = EBADF
                        return status
                    }
                )
            )
        }

        XCTAssertEqual(outcome.status, -1)
        XCTAssertEqual(errno, EEXIST)
        XCTAssertEqual(try text(at: source), "original")
        XCTAssertEqual(try text(at: destination), "existing")
    }

    func testFallbackRejectsReservationNameSubstitutionBeforeRename() throws {
        let source = try makeFile("source", contents: "original")
        let destination = root.appendingPathComponent("destination")
        let displacedReservation = root.appendingPathComponent("displaced-reservation")

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    afterReservationCreated: {
                        try! FileManager.default.moveItem(
                            at: destination,
                            to: displacedReservation
                        )
                        try! Data("sentinel".utf8).write(to: destination)
                    }
                )
            )
        }

        XCTAssertEqual(outcome.status, -1)
        XCTAssertEqual(errno, ESTALE)
        XCTAssertEqual(try text(at: source), "original")
        XCTAssertEqual(try text(at: destination), "sentinel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedReservation.path))
    }

    func testFallbackAfterFinalValidationRaceLeavesDetectionToCallerPostRenameWitness() throws {
        let source = try makeFile("source", contents: "original")
        let originalAfterSwap = root.appendingPathComponent("original-after-swap")
        let destination = root.appendingPathComponent("destination")
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        let expected = try descriptorInfo(descriptor)

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                sourceWitness: .init(descriptor: descriptor, expected: expected),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    afterFinalWitnessValidation: {
                        try! FileManager.default.moveItem(at: source, to: originalAfterSwap)
                        try! Data("replacement".utf8).write(to: source)
                    }
                )
            )
        }

        XCTAssertEqual(outcome, .init(status: 0, mechanism: .reservationFallback))
        XCTAssertEqual(try text(at: destination), "replacement")
        let held = try descriptorInfo(descriptor)
        let detached = try fileInfo(at: destination)
        XCTAssertNotEqual(held.st_ino, detached.st_ino)
        XCTAssertEqual(try text(at: originalAfterSwap), "original")
    }

    func testFallbackFailureRemovesOnlyItsVerifiedReservation() throws {
        let source = try makeFile("source", contents: "original")
        let destination = root.appendingPathComponent("destination")
        let displacedReservation = root.appendingPathComponent("displaced-reservation")

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    ordinaryRename: { _, _, _, _ in
                        try! FileManager.default.moveItem(
                            at: destination,
                            to: displacedReservation
                        )
                        try! Data("sentinel".utf8).write(to: destination)
                        errno = EBUSY
                        return -1
                    }
                )
            )
        }

        XCTAssertEqual(outcome.status, -1)
        XCTAssertEqual(errno, EBUSY)
        XCTAssertEqual(try text(at: source), "original")
        XCTAssertEqual(try text(at: destination), "sentinel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedReservation.path))
    }

    func testFallbackPreservesPrimaryErrnoAcrossDescriptorAndReservationCleanup() throws {
        let source = try makeFile("source", contents: "original")
        let destination = root.appendingPathComponent("destination")

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    ordinaryRename: { _, _, _, _ in
                        errno = EACCES
                        return -1
                    },
                    closeDescriptor: { descriptor in
                        let status = Darwin.close(descriptor)
                        errno = EBADF
                        return status
                    },
                    removeEntry: { parent, name, flags in
                        let status = Darwin.unlinkat(parent, name, flags)
                        errno = ENOENT
                        return status
                    }
                )
            )
        }

        XCTAssertEqual(outcome.status, -1)
        XCTAssertEqual(errno, EACCES)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try text(at: source), "original")
    }

    func testDirectoryFallbackRetainsLegacyMetadataMutationSemantics() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let afterReservationWasCalled = LockedValue(false)
        let afterFinalValidationWasCalled = LockedValue(false)

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    createDirectoryReservation: { parent, name, mode in
                        let status = Darwin.mkdirat(parent, name, mode)
                        XCTAssertEqual(status, 0)
                        XCTAssertEqual(Darwin.chmod(source.path, S_IRWXU), 0)
                        return status
                    },
                    afterReservationCreated: {
                        afterReservationWasCalled.value = true
                    },
                    afterFinalWitnessValidation: {
                        afterFinalValidationWasCalled.value = true
                    }
                )
            )
        }

        XCTAssertEqual(outcome, .init(status: 0, mechanism: .reservationFallback))
        XCTAssertFalse(afterReservationWasCalled.value)
        XCTAssertFalse(afterFinalValidationWasCalled.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try text(at: destination.appendingPathComponent("payload.txt")),
            "payload"
        )
    }

    func testDirectoryFallbackPostReservationStatFailureRemovesReservationAndPreservesErrno() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let removalWasCalled = LockedValue(false)

        let outcome = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNPReporting(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL),
                operations: .init(
                    nativeRename: unsupportedNativeRename,
                    inspectDirectoryReservation: { _, _, _, _ in
                        errno = EIO
                        return -1
                    },
                    removeEntry: { parent, name, flags in
                        removalWasCalled.value = true
                        let status = Darwin.unlinkat(parent, name, flags)
                        errno = ENOTEMPTY
                        return status
                    }
                )
            )
        }

        XCTAssertEqual(outcome, .init(status: -1, mechanism: .reservationFallback))
        XCTAssertEqual(errno, EIO)
        XCTAssertTrue(removalWasCalled.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLegacyIntegerWrapperPreservesExistingCallContract() throws {
        let source = try makeFile("source", contents: "payload")
        let destination = root.appendingPathComponent("destination")
        let success = withPaths(source, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNP(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL)
            )
        }
        XCTAssertEqual(success, 0)

        let secondSource = try makeFile("second-source", contents: "other")
        let failure = withPaths(secondSource, destination) { sourcePath, destinationPath in
            PortableExclusiveRename.renameatxNP(
                AT_FDCWD,
                sourcePath,
                AT_FDCWD,
                destinationPath,
                UInt32(RENAME_EXCL)
            )
        }
        XCTAssertEqual(failure, -1)
        XCTAssertEqual(errno, EEXIST)
        XCTAssertEqual(try text(at: destination), "payload")
        XCTAssertEqual(try text(at: secondSource), "other")
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func text(at url: URL) throws -> String {
        try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
    }

    private func fileInfo(at url: URL) throws -> stat {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        return information
    }

    private func descriptorInfo(_ descriptor: Int32) throws -> stat {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        return information
    }

    private func withPaths<Result>(
        _ source: URL,
        _ destination: URL,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result
    ) -> Result {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                body(sourcePath, destinationPath)
            }
        }
    }
}

private func descriptorRelativeFileInfo(
    parent: Int32,
    name: UnsafePointer<CChar>
) throws -> stat {
    var information = stat()
    guard Darwin.fstatat(parent, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
    return information
}

private func openDescriptor(matching expected: stat) -> Int32? {
    for descriptor in 3 ..< 256 {
        var information = stat()
        if Darwin.fstat(Int32(descriptor), &information) == 0,
           information.st_dev == expected.st_dev,
           information.st_ino == expected.st_ino {
            return Int32(descriptor)
        }
    }
    return nil
}

private func unsupportedNativeRename(
    _: Int32,
    _: UnsafePointer<CChar>,
    _: Int32,
    _: UnsafePointer<CChar>,
    _: UInt32
) -> Int32 {
    errno = ENOTSUP
    return -1
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

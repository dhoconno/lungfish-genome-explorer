import Foundation
import XCTest
@testable import LungfishWorkflow

final class GenotypeWorkbookManagedRuntimeProbeTests: XCTestCase {
    func testProbeDrainsNoisyStderrWithoutHanging() throws {
        guard let python = openpyxlPythonURL() else {
            throw XCTSkip("The managed test runtime must provide openpyxl")
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("noisy-python")
        try writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "-c" ]; then
              dd if=/dev/zero bs=1024 count=32 1>&2 2>/dev/null
              exec "\(python.path)" "$@"
            fi
            exec "\(python.path)" "$@"
            """,
            to: wrapper
        )

        let identity = try GenotypeWorkbookManagedRuntimeProbe.probe(
            pythonExecutableURL: wrapper,
            timeout: 5
        )

        XCTAssertFalse(try XCTUnwrap(identity["pythonVersion"]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(identity["openpyxlVersion"]).isEmpty)
    }

    func testProbeCancellationTerminatesProcessWithoutHanging() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("hanging-python")
        try writeExecutable(
            """
            #!/bin/sh
            trap '' TERM
            while true; do
              printf 'still-running\\n' 1>&2
            done
            """,
            to: wrapper
        )
        let checks = LockedCounter()
        let started = Date()

        XCTAssertThrowsError(
            try GenotypeWorkbookManagedRuntimeProbe.probe(
                pythonExecutableURL: wrapper,
                timeout: 10,
                cancellationCheck: {
                    checks.incrementAndGet() > 2
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testProbeTerminatesSustainedStderrAtBoundedOutputLimit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("overflowing-python")
        try writeExecutable(
            """
            #!/bin/sh
            trap '' TERM
            while true; do
              printf '0123456789abcdef0123456789abcdef\\n' 1>&2
            done
            """,
            to: wrapper
        )
        let started = Date()

        XCTAssertThrowsError(
            try GenotypeWorkbookManagedRuntimeProbe.probe(
                pythonExecutableURL: wrapper,
                timeout: 10
            )
        ) { error in
            guard case let GenotypeWorkbookManagedRuntimeProbeError
                .outputLimitExceeded(stream, maximumBytes, diagnostic) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stream, "stderr")
            XCTAssertLessThanOrEqual(diagnostic.utf8.count, maximumBytes)
            XCTAssertLessThanOrEqual(maximumBytes, 131_072)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkbookRuntimeProbe-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func openpyxlPythonURL() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"]
                .map(URL.init(fileURLWithPath:)),
            URL(
                fileURLWithPath:
                    "/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
            ),
        ].compactMap { $0 }
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            let process = Process()
            process.executableURL = candidate
            process.arguments = ["-c", "import openpyxl"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return candidate }
        }
        return nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func incrementAndGet() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

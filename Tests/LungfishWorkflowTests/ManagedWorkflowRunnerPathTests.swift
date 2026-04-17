import XCTest
@testable import LungfishWorkflow

final class ManagedWorkflowRunnerPathTests: XCTestCase {

    func testNextflowRunnerIgnoresFallbackExecutableWhenManagedCopyMissing() async {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-nextflow-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let fakeBin = tempHome.appendingPathComponent("fake-bin", isDirectory: true)
        let fakeExecutable = fakeBin.appendingPathComponent("nextflow")
        try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try? "#!/bin/bash\necho host nextflow\n".write(
            to: fakeExecutable,
            atomically: true,
            encoding: .utf8
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeExecutable.path
        )
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(fakeBin.path):\(originalPATH ?? "")", 1)
        defer {
            if let originalPATH {
                setenv("PATH", originalPATH, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let runner = NextflowRunner(
            processManager: .shared,
            homeDirectoryProvider: { tempHome }
        )

        let available = await runner.isAvailable()

        XCTAssertFalse(available)
    }

    func testSnakemakeRunnerIgnoresFallbackExecutableWhenManagedCopyMissing() async {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-snakemake-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let fakeBin = tempHome.appendingPathComponent("fake-bin", isDirectory: true)
        let fakeExecutable = fakeBin.appendingPathComponent("snakemake")
        try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try? "#!/bin/bash\necho host snakemake\n".write(
            to: fakeExecutable,
            atomically: true,
            encoding: .utf8
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeExecutable.path
        )
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(fakeBin.path):\(originalPATH ?? "")", 1)
        defer {
            if let originalPATH {
                setenv("PATH", originalPATH, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let runner = SnakemakeRunner(
            processManager: .shared,
            homeDirectoryProvider: { tempHome }
        )

        let available = await runner.isAvailable()

        XCTAssertFalse(available)
    }
}

import XCTest
import CryptoKit
@testable import LungfishWorkflow

final class ManagedToolSourceInstallerTests: XCTestCase {
    func testSuccessfulBrackenInstallPublishesScriptsPayloadAndDurableRecord() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()

        let record = try await fixture.installer().install(
            sourceOverlay: fixture.overlay,
            environmentURL: fixture.environmentURL
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken-build").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.environmentURL.appendingPathComponent("bin/src/kmer2read_distr").path))
        XCTAssertEqual(record.source, fixture.overlay)
        XCTAssertEqual(record.exitStatus, 0)
        XCTAssertEqual(record.runtime.environmentPath, fixture.environmentURL.path)
        XCTAssertEqual(
            record.runtime.condaPackages,
            [
                .init(name: "cxx-compiler", version: "1.9.0", build: "h1", subdir: "osx-arm64"),
                .init(name: "llvm-openmp", version: "21.1.8", build: "h2", subdir: "osx-arm64"),
                .init(name: "python", version: "3.11.13", build: "h3", subdir: "osx-arm64"),
            ]
        )
        XCTAssertEqual(
            record.commands.map(\.argv),
            [
                ["URLSession.download", fixture.overlay.sourceURL.absoluteString, fixture.downloadDestinationPath],
                ["/usr/bin/tar", "-tzf", fixture.downloadDestinationPath],
                ["/usr/bin/tar", "-xzf", fixture.downloadDestinationPath, "-C", fixture.extractedPath],
                [
                    fixture.environmentURL.appendingPathComponent("bin/c++").path,
                    "-O3", "-std=c++11", "-Xpreprocessor", "-fopenmp",
                    fixture.stagedSourcePath("kmer2read_distr.cpp"),
                    fixture.stagedSourcePath("ctime.cpp"),
                    fixture.stagedSourcePath("kraken_processing.cpp"),
                    fixture.stagedSourcePath("taxonomy.cpp"),
                    "-L", fixture.environmentURL.appendingPathComponent("lib").path,
                    "-lomp", "-Wl,-rpath,@loader_path/../../lib", "-o", fixture.stagedSourcePath("kmer2read_distr"),
                ],
                [fixture.stagedBinPath("bracken"), "--help"],
                [fixture.stagedBinPath("bracken-build"), "-v"],
                [fixture.stagedSourcePath("kmer2read_distr"), "--help"],
            ]
        )
        XCTAssertTrue(record.installedFiles.allSatisfy { $0.sizeBytes > 0 && $0.sha256.count == 64 })
        XCTAssertNotNil(record.wallTimeSeconds)
        XCTAssertLessThanOrEqual(record.stderr.count, ManagedToolSourceInstallationRecord.maximumStderrLength)

        let recordURL = fixture.environmentURL
            .appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        XCTAssertEqual(try ManagedToolSourceInstallationRecord.load(from: recordURL), record)
    }

    func testChecksumMismatchPublishesNothing() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()

        let invalidOverlay = PackToolSourceOverlay(
            kind: .bracken,
            version: "3.1",
            sourceURL: fixture.overlay.sourceURL,
            sha256: String(repeating: "0", count: 64)
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: invalidOverlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("share/lungfish/managed-tools/bracken.json").path))
    }

    func testUnsafeArchiveMemberIsRejectedBeforeExtraction() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        fixture.archiveListingOverride = "../escaped-file\n"

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escaped-file").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
    }

    func testCompileFailurePreservesPreviouslyPublishedOverlay() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()
        let priorBin = fixture.environmentURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: priorBin, withIntermediateDirectories: true)
        try Data("prior bracken\n".utf8).write(to: priorBin.appendingPathComponent("bracken"))
        fixture.compileShouldFail = true

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertEqual(try Data(contentsOf: priorBin.appendingPathComponent("bracken")), Data("prior bracken\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("share/lungfish/managed-tools/bracken.json").path))
    }

    func testCancellationPublishesNothing() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()
        fixture.cancelDuringCompile = true

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("share/lungfish/managed-tools/bracken.json").path))
    }
}

private final class SourceInstallerFixture: @unchecked Sendable {
    let root: URL
    let environmentURL: URL
    let archiveURL: URL
    private(set) var overlay = PackToolSourceOverlay(
        kind: .bracken,
        version: "3.1",
        sourceURL: URL(string: "https://example.test/Bracken-v3.1.tar.gz")!,
        sha256: ""
    )
    var archiveListingOverride: String?
    var compileShouldFail = false
    var cancelDuringCompile = false

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedToolSourceInstallerTests-\(UUID().uuidString)", isDirectory: true)
        environmentURL = root.appendingPathComponent("env", isDirectory: true)
        archiveURL = root.appendingPathComponent("bracken-v3.1.tar.gz")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeSafeArchive() throws {
        let source = root.appendingPathComponent("Bracken-3.1", isDirectory: true)
        let src = source.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for script in ["bracken", "bracken-build"] {
            let url = source.appendingPathComponent(script)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for script in ["est_abundance.py", "generate_kmer_distribution.py"] {
            try "#!/usr/bin/env python3\n".write(to: src.appendingPathComponent(script), atomically: true, encoding: .utf8)
        }
        for sourceFile in ["kmer2read_distr.cpp", "ctime.cpp", "kraken_processing.cpp", "taxonomy.cpp"] {
            try "int main() { return 0; }\n".write(
                to: src.appendingPathComponent(sourceFile),
                atomically: true,
                encoding: .utf8
            )
        }
        _ = try run(executable: "/usr/bin/tar", arguments: ["-czf", archiveURL.path, "-C", root.path, "Bracken-3.1"])
        let condaMeta = environmentURL.appendingPathComponent("conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: condaMeta, withIntermediateDirectories: true)
        for package in [
            ("cxx-compiler", "1.9.0", "h1"),
            ("llvm-openmp", "21.1.8", "h2"),
            ("python", "3.11.13", "h3"),
        ] {
            let metadata = "{\"name\":\"\(package.0)\",\"version\":\"\(package.1)\",\"build\":\"\(package.2)\",\"subdir\":\"osx-arm64\"}"
            try metadata.write(
                to: condaMeta.appendingPathComponent("\(package.0)-\(package.1)-\(package.2).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        overlay = PackToolSourceOverlay(
            kind: .bracken,
            version: "3.1",
            sourceURL: overlay.sourceURL,
            sha256: SHA256.hash(data: try Data(contentsOf: archiveURL)).map { String(format: "%02x", $0) }.joined()
        )
    }

    var downloadDestinationPath: String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/source.tar.gz").path
    }

    var extractedPath: String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/extract").path
    }

    func stagedBinPath(_ name: String) -> String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/publish/bin/\(name)").path
    }

    func stagedSourcePath(_ name: String) -> String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/publish/bin/src/\(name)").path
    }

    func installer() -> ManagedToolSourceInstaller {
        ManagedToolSourceInstaller(
            downloader: { [archiveURL] _, destination in
                try FileManager.default.copyItem(at: archiveURL, to: destination)
            },
            processRunner: { [weak self] invocation in
                guard let self else { throw CancellationError() }
                if invocation.executable.lastPathComponent == "tar", let listing = self.archiveListingOverride,
                   invocation.arguments.contains("-tzf") {
                    return .init(exitStatus: 0, stdout: listing, stderr: "")
                }
                if invocation.executable.lastPathComponent.contains("c++") {
                    if self.cancelDuringCompile { throw CancellationError() }
                    if self.compileShouldFail { return .init(exitStatus: 1, stdout: "", stderr: "compile failed") }
                    if let output = invocation.arguments.enumerated().first(where: { $0.element == "-o" }).flatMap({ index, _ in
                        invocation.arguments.dropFirst(index + 1).first
                    }) {
                        let outputURL = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try "#!/bin/sh\nexit 0\n".write(to: outputURL, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
                    }
                    return .init(exitStatus: 0, stdout: "", stderr: "")
                }
                if invocation.executable.lastPathComponent == "bracken" || invocation.executable.lastPathComponent == "bracken-build" || invocation.executable.lastPathComponent == "kmer2read_distr" {
                    return .init(exitStatus: 0, stdout: "help", stderr: "")
                }
                let result = try run(executable: invocation.executable.path, arguments: invocation.arguments, workingDirectory: invocation.workingDirectory)
                return .init(exitStatus: result.status, stdout: result.stdout, stderr: result.stderr)
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
    }

    private func run(executable: String, arguments: [String], workingDirectory: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}

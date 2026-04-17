// ImportFastqCommandTests.swift - Tests for the `lungfish import fastq` CLI subcommand
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

private actor StubManagedDatabaseRegistry: ManagedDatabaseProvisioning {
    var installedIDs: Set<String> = []
    var installCalls: [String] = []

    func requiredDatabaseManifest(for id: String) async -> BundledDatabase? {
        BundledDatabase(
            id: id,
            displayName: "Human Read Scrubber Database",
            tool: "sra-human-scrubber",
            version: "20250916v2",
            filename: "human_filter.db.20250916v2",
            releaseDate: "2025-09-16",
            description: "Stub manifest",
            sourceUrl: "https://github.com/ncbi/sra-human-scrubber",
            releasesUrl: "https://github.com/ncbi/sra-human-scrubber/releases"
        )
    }

    func isDatabaseInstalled(_ id: String) async -> Bool {
        installedIDs.contains(id)
    }

    func installManagedDatabase(
        _ id: String,
        reinstall: Bool = false,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        installCalls.append(id)
        installedIDs.insert(id)
        progress?(1.0, "Installed")
        return URL(fileURLWithPath: "/tmp/\(id)")
    }

    func currentInstallCalls() -> [String] {
        installCalls
    }
}

private final class StubLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func currentLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

final class ImportFastqCommandTests: XCTestCase {
    private func makeManagedPigzHome(script: String) throws -> (home: URL, pigzURL: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "import-fastq-pigz-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/pigz/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let pigzURL = binDir.appendingPathComponent("pigz")
        try script.write(to: pigzURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pigzURL.path)
        return (home, pigzURL)
    }

    func testParseMinimalArguments() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.input, ["/data/fastq_dir"])
        XCTAssertEqual(command.project, "/projects/Test.lungfish")
        XCTAssertEqual(command.recipe, "none")
        XCTAssertFalse(command.dryRun)
    }

    func testParseExplicitFilePaths() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/sample_R1.fastq.gz",
            "/data/sample_R2.fastq.gz",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.input, ["/data/sample_R1.fastq.gz", "/data/sample_R2.fastq.gz"])
        XCTAssertEqual(command.project, "/projects/Test.lungfish")
    }

    func testParseSingleFilePath() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/reads.fastq.gz",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.input, ["/data/reads.fastq.gz"])
    }

    func testParseFullArguments() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--recipe", "vsp2",
            "--quality-binning", "illumina4",
            "--threads", "16",
            "--log-dir", "/tmp/logs",
            "--dry-run",
        ])
        XCTAssertEqual(command.recipe, "vsp2")
        XCTAssertEqual(command.qualityBinning, "illumina4")
        XCTAssertEqual(command.threads, 16)
        XCTAssertEqual(command.logDir, "/tmp/logs")
        XCTAssertTrue(command.dryRun)
    }

    func testParseDefaultThreads() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertNil(command.threads)
    }

    func testParseDefaultQualityBinning() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.qualityBinning, "illumina4")
    }

    func testParseShortProjectFlag() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "-p", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.project, "/projects/Test.lungfish")
    }

    func testParseNewFlags() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--platform", "illumina",
            "--recipe", "vsp2",
            "--no-optimize-storage",
            "--compression", "maximum",
            "--force",
        ])
        XCTAssertEqual(command.platform, "illumina")
        XCTAssertTrue(command.noOptimizeStorage)
        XCTAssertEqual(command.compression, "maximum")
        XCTAssertTrue(command.force)
    }

    func testParseDefaultNewFlags() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertNil(command.platform)
        XCTAssertFalse(command.noOptimizeStorage)
        XCTAssertEqual(command.compression, "balanced")
        XCTAssertFalse(command.force)
    }

    func testParsePlatformONT() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--platform", "ont",
        ])
        XCTAssertEqual(command.platform, "ont")
    }

    func testParsePlatformPacBio() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--platform", "pacbio",
        ])
        XCTAssertEqual(command.platform, "pacbio")
    }

    func testParseCompressionFast() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--compression", "fast",
        ])
        XCTAssertEqual(command.compression, "fast")
    }

    func testParseRecursiveFlag() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/sequencing_run/",
            "--project", "/projects/Test.lungfish",
            "--recursive",
        ])
        XCTAssertTrue(command.recursive)
    }

    func testParseRecursiveDefaultFalse() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertFalse(command.recursive)
    }

    func testParseAllFlagsCombined() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--platform", "ultima",
            "--recipe", "vsp2",
            "--quality-binning", "none",
            "--no-optimize-storage",
            "--compression", "fast",
            "--threads", "4",
            "--log-dir", "/tmp/logs",
            "--force",
            "--dry-run",
        ])
        XCTAssertEqual(command.platform, "ultima")
        XCTAssertEqual(command.recipe, "vsp2")
        XCTAssertEqual(command.qualityBinning, "none")
        XCTAssertTrue(command.noOptimizeStorage)
        XCTAssertEqual(command.compression, "fast")
        XCTAssertEqual(command.threads, 4)
        XCTAssertEqual(command.logDir, "/tmp/logs")
        XCTAssertTrue(command.force)
        XCTAssertTrue(command.dryRun)
    }

    func testRequiredManagedDatabaseIDsCanonicalizesLegacyHumanScrubberAliasToDeacon() throws {
        let recipe = ProcessingRecipe(
            name: "Human scrub",
            steps: [
                FASTQDerivativeOperation(
                    kind: .humanReadScrub,
                    createdAt: .distantPast,
                    humanScrubDatabaseID: "sra-human-scrubber"
                ),
            ]
        )

        let ids = ImportCommand.FastqSubcommand.requiredManagedDatabaseIDs(
            legacyRecipe: recipe,
            newRecipe: nil
        )

        XCTAssertEqual(ids, ["deacon-panhuman"])
    }

    func testRequiredManagedDatabaseIDsCanonicalizeDeaconRecipeDatabase() throws {
        let recipe = Recipe(
            formatVersion: 1,
            id: "test-deacon",
            name: "Deacon scrub",
            platforms: [.illumina],
            requiredInput: .paired,
            steps: [
                RecipeStep(
                    type: "deacon-scrub",
                    params: ["database": .string("deacon")]
                ),
            ]
        )

        let ids = ImportCommand.FastqSubcommand.requiredManagedDatabaseIDs(
            legacyRecipe: nil,
            newRecipe: recipe
        )

        XCTAssertEqual(ids, ["deacon-panhuman"])
    }

    func testInstallRequiredManagedDatabasesInstallsMissingHumanScrubber() async throws {
        let registry = StubManagedDatabaseRegistry()
        let sink = StubLineSink()

        try await ImportCommand.FastqSubcommand.installRequiredManagedDatabases(
            requiredIDs: ["deacon-panhuman"],
            formatter: TerminalFormatter(useColors: false),
            isQuiet: false,
            databaseRegistry: registry,
            emit: { line in sink.append(line) }
        )

        let installCalls = await registry.currentInstallCalls()
        let emitted = sink.currentLines()
        XCTAssertEqual(installCalls, ["deacon-panhuman"])
        XCTAssertTrue(emitted.contains(where: { $0.contains("Installing required database") }))
    }

    func testManagedPigzExecutableURLUsesManagedEnvironmentLayout() throws {
        let (home, pigzURL) = try makeManagedPigzHome(script: "#!/bin/sh\nexit 0\n")

        let resolved = ImportCommand.FastqSubcommand.managedPigzExecutableURL(homeDirectory: home)

        XCTAssertEqual(resolved, pigzURL)
    }

    func testManagedPigzExecutableURLDoesNotFallBackToSystemGunzip() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "import-fastq-pigz-missing-\(UUID().uuidString)",
            isDirectory: true
        )

        let resolved = ImportCommand.FastqSubcommand.managedPigzExecutableURL(homeDirectory: home)

        XCTAssertNil(resolved)
    }

    func testDetectPlatformFromCompressedFASTQThrowsWhenManagedPigzMissing() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "import-fastq-pigz-missing-\(UUID().uuidString)",
            isDirectory: true
        )
        let pair = SamplePair(
            sampleName: "sample",
            r1: URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
            r2: nil
        )

        XCTAssertThrowsError(
            try ImportCommand.FastqSubcommand.detectPlatformFromPairs([pair], homeDirectory: home)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("Managed pigz is required"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testDetectPlatformFromCompressedFASTQThrowsWhenManagedPigzFails() throws {
        let (home, _) = try makeManagedPigzHome(script: """
        #!/bin/sh
        exit 1
        """)
        let pair = SamplePair(
            sampleName: "sample",
            r1: URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
            r2: nil
        )

        XCTAssertThrowsError(
            try ImportCommand.FastqSubcommand.detectPlatformFromPairs([pair], homeDirectory: home)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("Managed pigz failed"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }
}

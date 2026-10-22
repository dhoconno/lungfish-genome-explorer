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

    /// Quality binning defaults to "none" everywhere; it is
    /// lossy and irreversible once originals are removed, so it is opt-in only.
    func testParseDefaultQualityBinning() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.qualityBinning, "none")
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
            "--clumping-tool", "trim-galore",
            "--compression", "maximum",
            "--force",
        ])
        XCTAssertEqual(command.platform, "illumina")
        XCTAssertTrue(command.noOptimizeStorage)
        XCTAssertEqual(command.clumpingTool, "trim-galore")
        XCTAssertEqual(command.compression, "maximum")
        XCTAssertTrue(command.force)
    }

    /// `--name` overrides the output bundle name for a single-sample import.
    func testParseNameOption() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/sample_R1.fastq.gz",
            "--project", "/projects/Test.lungfish",
            "--name", "S1_L001 2",
        ])
        XCTAssertEqual(command.name, "S1_L001 2")
    }

    func testParseCanonicalVSP2TargetEnrichmentWithTrimGalore() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--recipe", "vsp2-target-enrichment",
            "--clumping-tool", "trim-galore",
        ])

        XCTAssertEqual(command.recipe, "vsp2-target-enrichment")
        XCTAssertEqual(command.clumpingTool, "trim-galore")
    }

    func testParseDefaultNewFlags() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.platform, "auto")
        XCTAssertFalse(command.noOptimizeStorage)
        XCTAssertNil(command.clumpingTool)
        XCTAssertEqual(command.compression, "balanced")
        XCTAssertFalse(command.force)
    }

    /// With no storage flag the import asks nothing, so the platform decides
    /// and an Unknown import is not reordered. Before the fix the command
    /// passed an explicit request even with no flag, so an Unknown import
    /// that was asked could not be told from one that was not.
    func testOnlyAStorageFlagIsAStorageRequest() {
        let request = ImportCommand.FastqSubcommand.requestedOptimizeStorage
        XCTAssertNil(request(false, nil))
        XCTAssertEqual(request(false, .bbtools), true)
        XCTAssertEqual(request(false, .trimGalore), true)
        XCTAssertEqual(request(false, .auto), true)
        XCTAssertEqual(request(false, ClumpingTool.none), false)
        XCTAssertEqual(request(true, ClumpingTool.none), false)
    }

    func testParseClumpingToolAliases() throws {
        XCTAssertEqual(try ImportCommand.FastqSubcommand.parseClumpingTool("auto"), .auto)
        XCTAssertEqual(try ImportCommand.FastqSubcommand.parseClumpingTool("clumpify.sh"), .bbtools)
        XCTAssertEqual(try ImportCommand.FastqSubcommand.parseClumpingTool("trim_galore"), .trimGalore)
        XCTAssertEqual(try ImportCommand.FastqSubcommand.parseClumpingTool("skip"), .none)
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

    func testParseSampleSheetOption() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "--samplesheet", "/data/run/samples.csv",
            "--project", "/projects/Test.lungfish",
            "--platform", "illumina",
        ])

        XCTAssertEqual(command.samplesheet, "/data/run/samples.csv")
        XCTAssertTrue(command.input.isEmpty)
    }

    func testTopLevelImportFastqAliasParsesSampleSheetOption() throws {
        let command = try ImportFastqCommand.parse([
            "--samplesheet", "/data/run/samples.csv",
            "--project", "/projects/Test.lungfish",
            "--platform", "illumina",
        ])

        XCTAssertEqual(command.command.samplesheet, "/data/run/samples.csv")
        XCTAssertTrue(command.command.input.isEmpty)
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

    // The raw values "illumina4"/"eightLevel" are kept for
    // backward-compatible provenance/CLI parsing, but the user-visible help
    // must describe the real level counts, not the misleading names.
    // clumpify.sh quantize=0,8,13,22,27,32,37 ("illumina4") yields 7 levels;
    // quantize=2 ("eightLevel") yields roughly 21 levels on a 0-40 Phred
    // range, not 4 or 8.
    func testQualityBinningHelpDescribesActualLevelCounts() {
        // ArgumentParser word-wraps help text to terminal width, so compare
        // with whitespace collapsed rather than requiring an exact substring.
        let help = ImportCommand.FastqSubcommand.helpMessage()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertTrue(help.contains("illumina4"), help)
        XCTAssertTrue(help.contains("7 quality levels"), help)
        XCTAssertTrue(help.contains("eightLevel"), help)
        XCTAssertTrue(help.contains("21 quality levels"), help)
        XCTAssertFalse(help.contains("4-level"), help)
        XCTAssertFalse(help.contains("8-level"), help)
    }

    func testResolveImportRecipeMapsVSP2AliasToDeclarativeRecipe() throws {
        let resolved = try ImportCommand.FastqSubcommand.resolveImportRecipe(named: "vsp2")

        XCTAssertEqual(resolved.newRecipe?.id, "illumina-paired-cleanup")
        XCTAssertEqual(resolved.newRecipe?.resolution?.preset?.id, "vsp2-target-enrichment")
        XCTAssertNil(resolved.legacyRecipe)
    }

    /// `--no-remove-duplicates` reaches the resolver as an option and beats the preset (CHTC lane C2-MERGED).
    func testSwitchOptionsReachTheResolver() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/tmp/reads", "--project", "/tmp/project.lungfish",
            "--recipe", "wastewater-metagenomics", "--no-remove-duplicates",
        ])
        XCTAssertEqual(command.importOptions.switchOptions, ["removeDuplicates": false])
        XCTAssertEqual(command.importOptions.switchOptionArguments, ["--no-remove-duplicates"])
        let resolved = try ImportCommand.FastqSubcommand.resolveImportRecipe(
            named: command.recipe, switchOptions: command.importOptions.switchOptions
        )
        let recipe = try XCTUnwrap(resolved.newRecipe)
        XCTAssertEqual(recipe.resolutionLines, [
            "Recipe 'wastewater-metagenomics' runs illumina-paired-cleanup with preset wastewater-metagenomics (Wastewater metagenomics).",
            "Remove duplicate reads: off (option)",
            "Remove ribosomal RNA reads: on (preset)",
        ])
        XCTAssertEqual(recipe.activeSteps.first?.type, "fastp-trim")
        XCTAssertTrue(recipe.activeSteps.contains { $0.type == "deacon-ribo-filter" })
    }

    /// A switch option for a recipe without that switch, or for no recipe file, is refused by name.
    func testSwitchOptionForARecipeWithoutTheSwitchIsRefused() {
        for name in ["illumina-amplicon-merge", "none", "wgs"] {
            XCTAssertThrowsError(try ImportCommand.FastqSubcommand.resolveImportRecipe(
                named: name, switchOptions: ["removeRibosomalRNA": true]
            ), name) { error in
                XCTAssertTrue(error.localizedDescription.contains("--remove-ribosomal-rna"), error.localizedDescription)
            }
        }
    }

    // C0 found a bare release lungfish-cli that loaded no recipe files. `--recipe vsp2` then
    // fell back to the legacy "Illumina VSP2 Target Enrichment" chain and said nothing.
    // A name that stands for a recipe file must never run a different recipe than the one asked for.
    func testVSP2AliasNeverFallsBackToLegacyRecipe() {
        XCTAssertThrowsError(
            try ImportCommand.FastqSubcommand.resolveImportRecipe(named: "vsp2", recipes: [])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("illumina-paired-cleanup"), error.localizedDescription)
        }
    }

    func testRecipeFileNamesNeverResolveToALegacyRecipeWhenNoRecipeFileLoads() throws {
        for name in ["vsp2", "VSP2", " vsp2 ", "vsp2-target-enrichment", "illumina-amplicon-merge"] {
            XCTAssertThrowsError(
                try ImportCommand.FastqSubcommand.resolveImportRecipe(named: name, recipes: []),
                name
            ) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("found no recipe files"), "\(name): \(message)")
                XCTAssertTrue(message.contains("Contents/MacOS/lungfish-cli"), "\(name): \(message)")
            }
        }
        for name in ImportCommand.FastqSubcommand.legacyRecipeNames {
            let resolved = try ImportCommand.FastqSubcommand.resolveImportRecipe(named: name, recipes: [])
            XCTAssertNil(resolved.newRecipe, name)
            XCTAssertNotNil(resolved.legacyRecipe, name)
        }
    }

    func testMissingRecipeFileNamesTheRecipeFilesThatDidLoad() throws {
        let loaded = RecipeRegistryV2.builtinRecipes().filter { $0.id != "illumina-paired-cleanup" }
        XCTAssertFalse(loaded.isEmpty, "the other bundled recipe files should load")
        XCTAssertThrowsError(
            try ImportCommand.FastqSubcommand.resolveImportRecipe(named: "vsp2", recipes: loaded)
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("illumina-paired-cleanup"), message)
            for recipe in loaded {
                XCTAssertTrue(message.contains(recipe.id), message)
            }
        }
    }

    func testRecipeHelpListsOnlyNamesThatResolveWhenNoRecipeFileLoads() throws {
        let names = ImportCommand.FastqSubcommand.availableRecipeNames(recipes: [])
        XCTAssertEqual(names, ["wgs", "hifi"])
        for name in names {
            let resolved = try ImportCommand.FastqSubcommand.resolveImportRecipe(named: name, recipes: [])
            XCTAssertNotNil(resolved.legacyRecipe, "\(name) is listed in the help but does not resolve")
        }
        let discussion = ImportCommand.FastqSubcommand.recipeHelpDiscussion(recipes: [])
        XCTAssertFalse(discussion.contains("alias of"), discussion)
        XCTAssertTrue(discussion.contains("found no recipe files"), discussion)
    }

    func testResolveImportRecipeRejectsBareAmpliconAlias() throws {
        XCTAssertThrowsError(try ImportCommand.FastqSubcommand.resolveImportRecipe(named: "amplicon")) { error in
            guard case BatchImportError.unsupportedRecipe(let name, let reason) = error else {
                return XCTFail("Expected BatchImportError.unsupportedRecipe, got \(error)")
            }
            XCTAssertEqual(name, "amplicon")
            XCTAssertTrue(reason.contains("primer removal"), reason)
        }
    }

    // The help used to list `vsp2, wgs, hifi` while the recipe IDs that
    // resolve read like `vsp2-target-enrichment`. The list is now generated
    // from the registry, and every name it shows must resolve.
    func testRecipeHelpListsEveryNameThatResolves() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        XCTAssertFalse(recipes.isEmpty, "the bundled recipe files should load")
        let names = ImportCommand.FastqSubcommand.availableRecipeNames(recipes: recipes)
        XCTAssertTrue(names.contains("vsp2-target-enrichment"), names.joined(separator: ", "))
        XCTAssertTrue(names.contains("wastewater-metagenomics"), names.joined(separator: ", "))
        XCTAssertTrue(names.contains("illumina-paired-cleanup"), names.joined(separator: ", "))
        XCTAssertTrue(names.contains("illumina-amplicon-merge"), names.joined(separator: ", "))
        XCTAssertTrue(names.contains("vsp2"), names.joined(separator: ", "))
        XCTAssertTrue(names.contains("wgs"), names.joined(separator: ", "))
        XCTAssertTrue(names.contains("hifi"), names.joined(separator: ", "))
        XCTAssertEqual(names.count, Set(names).count, "no name is listed twice")
        for name in names {
            let resolved = try ImportCommand.FastqSubcommand.resolveImportRecipe(named: name, recipes: recipes)
            XCTAssertTrue(
                resolved.newRecipe != nil || resolved.legacyRecipe != nil,
                "\(name) is listed in the help but does not resolve"
            )
        }
    }

    func testRecipeHelpIsRenderedFromTheRegistry() {
        let help = ImportCommand.FastqSubcommand.helpMessage()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        for name in ImportCommand.FastqSubcommand.availableRecipeNames() {
            XCTAssertTrue(help.contains(name), "help does not list \(name): \(help)")
        }
        XCTAssertTrue(help.contains("vsp2: alias of vsp2-target-enrichment"), help)
        XCTAssertFalse(help.contains("Processing recipe: vsp2, wgs, hifi, none"), help)
    }

    func testResolveImportRecipeAcceptsExactIlluminaAmpliconMergeID() throws {
        let resolved = try ImportCommand.FastqSubcommand.resolveImportRecipe(named: "illumina-amplicon-merge")

        XCTAssertEqual(resolved.newRecipe?.id, "illumina-amplicon-merge")
        XCTAssertNil(resolved.legacyRecipe)
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

    func testRequiredManagedDatabaseIDsIncludesDeaconRibokmersRecipeDatabase() throws {
        let recipe = Recipe(
            formatVersion: 1,
            id: "test-ribo",
            name: "Deacon rRNA",
            platforms: [.illumina],
            requiredInput: .paired,
            steps: [
                RecipeStep(
                    type: "deacon-ribo-filter",
                    params: ["database": .string("deacon-ribokmers")]
                ),
            ]
        )

        let ids = ImportCommand.FastqSubcommand.requiredManagedDatabaseIDs(
            legacyRecipe: nil,
            newRecipe: recipe
        )

        XCTAssertEqual(ids, ["deacon-ribokmers"])
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

    /// Regression: `--name` is rejected outright when more than one
    /// sample is detected, before any tool subprocess is invoked, so it can
    /// never silently rename the wrong sample in a multi-sample import.
    func testNameOptionRejectedWithMultipleDetectedSamples() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "import-fastq-name-multi-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleA = tempDir.appendingPathComponent("SampleA_R1.fastq.gz")
        let sampleB = tempDir.appendingPathComponent("SampleB_R1.fastq.gz")
        try Data().write(to: sampleA)
        try Data().write(to: sampleB)

        let projectDir = tempDir.appendingPathComponent("Test.lungfish")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let command = try ImportCommand.FastqSubcommand.parse([
            sampleA.path, sampleB.path,
            "--project", projectDir.path,
            "--name", "OverrideName",
            "--dry-run",
        ])

        do {
            try await command.run()
            XCTFail("Expected --name with multiple detected samples to throw")
        } catch {
            // ArgumentParser's ExitCode-based errors don't carry the printed
            // message, so we only assert that it refused rather than
            // silently applying the override to an arbitrary sample.
        }
    }

    // MARK: - --clumpify-heap-gb (L5-RECORDS Fix 6)

    func testParseClumpifyHeapGB() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir", "--project", "/projects/Test.lungfish", "--clumpify-heap-gb", "4",
        ])
        XCTAssertEqual(command.clumpifyHeapGB, 4)
    }

    /// The exit code of a dry run of one detected sample with `--clumpify-heap-gb value`, or nil when it did not fail.
    private func exitCodeOfDryRun(clumpifyHeapGB value: String) async throws -> Int32? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "import-fastq-heap-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sample = tempDir.appendingPathComponent("SampleA_R1.fastq.gz")
        try Data().write(to: sample)
        let projectDir = tempDir.appendingPathComponent("Test.lungfish")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let command = try ImportCommand.FastqSubcommand.parse([
            sample.path, "--project", projectDir.path, "--clumpify-heap-gb", value, "--dry-run",
        ])
        do {
            try await command.run()
            return nil
        } catch let error as ExitCode {
            return error.rawValue
        }
    }

    func testAClumpifyHeapBelowOneEndsWithExitCode3() async throws {
        let code = try await exitCodeOfDryRun(clumpifyHeapGB: "0")
        XCTAssertEqual(code, 3, "--clumpify-heap-gb 0 must end the command with the input error exit code")
    }

    /// The heap is multiplied by a GiB in bytes, so a large enough value overflowed and trapped. A value above this
    /// host's physical memory is refused with the input error exit code, before anything multiplies it.
    func testAClumpifyHeapBeyondTheHostEndsWithExitCode3NotACrash() async throws {
        for value in ["100000", String(Int.max)] {
            let code = try await exitCodeOfDryRun(clumpifyHeapGB: value)
            XCTAssertEqual(code, 3, "--clumpify-heap-gb \(value) exceeds this host's memory and must be refused")
        }
    }
}

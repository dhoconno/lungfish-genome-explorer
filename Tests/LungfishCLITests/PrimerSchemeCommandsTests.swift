import ArgumentParser
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class PrimerSchemeCommandsTests: XCTestCase {
    func testOlivarUserVisibleTextUsesTheProjectSpelling() throws {
        let configuration = OlivarDesignCommand.configuration
        for text in [configuration.abstract, configuration.discussion] {
            XCTAssertFalse(text.contains("OliVar"), text)
            XCTAssertTrue(text.contains("Olivar"), text)
        }
        let help = OlivarDesignCommand.helpMessage()
        XCTAssertFalse(help.contains("OliVar"))
    }

    func testOlivarParsesNativeSemanticsAndTypedAdvancedOptions() throws {
        let command = try OlivarDesignCommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--msa", "/tmp/b.fasta",
            "--output", "/tmp/result.lungfishprimeranalysis",
            "--grouping", "combined", "--amplicon-size", "400",
            "--amplicon-size-min", "360", "--amplicon-size-max", "440",
            "--workers", "3", "--minimum-variant-frequency", "0.02",
            "--degenerate", "--minimum-complexity", "0.5", "--seed", "12",
            "--risk-variation", "2.5",
        ])
        let options = try command.makeOptions()
        XCTAssertEqual(options.engine, .olivar)
        XCTAssertEqual(options.mode, .tiled)
        XCTAssertEqual(options.grouping, .combined)
        XCTAssertEqual(options.nominalAmpliconLength, 400)
        XCTAssertEqual(options.minimumAmpliconLength, 360)
        XCTAssertEqual(options.maximumAmpliconLength, 440)
        XCTAssertEqual(options.olivar?.minimumVariantFrequency, 0.02)
        XCTAssertEqual(options.olivar?.minimumComplexity, 0.5)
        XCTAssertEqual(options.olivar?.riskWeights.variation, 2.5)
        XCTAssertTrue(options.olivar?.degenerate == true)
        XCTAssertTrue(options.olivar?.suppliedOptionNames.contains("minimumVariantFrequency") == true)
    }

    func testVarVAMPParsesQPCRProbeControlsWithoutComplementingThreshold() throws {
        let command = try VarVAMPDesignCommand.parse([
            "--msa", "/tmp/a.lungfishmsa",
            "--output", "/tmp/result.lungfishprimeranalysis",
            "--mode", "qpcr", "--amplicon-size", "120",
            "--amplicon-size-min", "70", "--amplicon-size-max", "200",
            "--consensus-threshold", "0.92", "--workers", "2",
            "--probe-size-min", "21", "--probe-size-opt", "25",
            "--probe-size-max", "29", "--probe-tm-min", "65",
            "--probe-tm-opt", "68", "--probe-tm-max", "71",
            "--probe-distance-min", "5", "--probe-distance-max", "14",
        ])
        let options = try command.makeOptions()
        XCTAssertEqual(options.mode, .qpcr)
        XCTAssertEqual(options.varvamp?.cumulativeConsensusThreshold, 0.92)
        XCTAssertEqual(options.varvamp?.configOverrides.probeSizes,
                       .init(minimum: 21, maximum: 29, optimum: 25))
        XCTAssertEqual(options.varvamp?.configOverrides.probeTemperature,
                       .init(minimum: 65, maximum: 71, optimum: 68))
        XCTAssertEqual(options.varvamp?.configOverrides.probeDistance,
                       .init(minimum: 5, maximum: 14))
    }

    func testVarVAMPQPCRDefaultsToNativeAmpliconBoundsWithoutRecordingThemAsRequested() throws {
        let argv = ["--msa", "/tmp/a.lungfishmsa",
                    "--output", "/tmp/result.lungfishprimeranalysis", "--mode", "qpcr",
                    "--consensus-threshold", "0.92"]
        let command = try VarVAMPDesignCommand.parse(argv)
        let options = try command.makeOptions(argv: ["lungfish-cli", "primers", "design", "varvamp"] + argv)
        XCTAssertEqual(options.mode, .qpcr)
        XCTAssertEqual(options.minimumAmpliconLength, 70)
        XCTAssertEqual(options.maximumAmpliconLength, 200)
        XCTAssertEqual(options.nominalAmpliconLength, 135)
        XCTAssertNil(options.requestedMinimumAmpliconLength)
        XCTAssertNil(options.requestedMaximumAmpliconLength)
        for name in ["nominalAmpliconLength", "minimumAmpliconLength", "maximumAmpliconLength",
                     "requestedMinimumAmpliconLength", "requestedMaximumAmpliconLength"] {
            XCTAssertFalse(options.suppliedOptionNames.contains(name), name)
        }
    }

    func testVarVAMPTiledKeepsNominalRelativeBoundsAndQPCRHonoursExplicitOnes() throws {
        let tiledArgv = ["--msa", "/tmp/a.lungfishmsa",
                         "--output", "/tmp/result.lungfishprimeranalysis"]
        let tiled = try VarVAMPDesignCommand.parse(tiledArgv).makeOptions(argv: tiledArgv)
        XCTAssertEqual(tiled.mode, .tiled)
        XCTAssertEqual(tiled.nominalAmpliconLength, 400)
        XCTAssertEqual(tiled.minimumAmpliconLength, 360)
        XCTAssertEqual(tiled.maximumAmpliconLength, 440)

        // An explicit nominal keeps the 90%/110% derivation even in qPCR mode.
        let nominalArgv = tiledArgv + ["--mode", "qpcr", "--consensus-threshold", "0.92",
                                       "--amplicon-size", "120"]
        let nominal = try VarVAMPDesignCommand.parse(nominalArgv).makeOptions(argv: nominalArgv)
        XCTAssertEqual(nominal.nominalAmpliconLength, 120)
        XCTAssertEqual(nominal.minimumAmpliconLength, 108)
        XCTAssertEqual(nominal.maximumAmpliconLength, 132)
        XCTAssertTrue(nominal.suppliedOptionNames.contains("nominalAmpliconLength"))

        let explicitArgv = tiledArgv + ["--mode", "qpcr", "--consensus-threshold", "0.92",
                                        "--amplicon-size-min", "90", "--amplicon-size-max", "180"]
        let explicit = try VarVAMPDesignCommand.parse(explicitArgv).makeOptions(argv: explicitArgv)
        XCTAssertEqual(explicit.minimumAmpliconLength, 90)
        XCTAssertEqual(explicit.maximumAmpliconLength, 180)
        XCTAssertEqual(explicit.requestedMinimumAmpliconLength, 90)
        XCTAssertEqual(explicit.requestedMaximumAmpliconLength, 180)
        XCTAssertTrue(explicit.suppliedOptionNames.contains("minimumAmpliconLength"))
    }

    func testVarVAMPHelpStatesTheNativeQPCRAmpliconDefaults() throws {
        let help = VarVAMPDesignCommand.helpMessage()
        XCTAssertTrue(help.contains("70"), help)
        XCTAssertTrue(help.contains("200"), help)
    }

    func testVarVAMPRejectsCombinedGroupingAndMissingQPCRThreshold() throws {
        let combined = try VarVAMPDesignCommand.parse([
            "--msa", "/tmp/a.fasta", "--output", "/tmp/out.lungfishprimeranalysis",
            "--grouping", "combined",
        ])
        XCTAssertThrowsError(try combined.makeOptions())

        let missing = try VarVAMPDesignCommand.parse([
            "--msa", "/tmp/a.fasta", "--output", "/tmp/out.lungfishprimeranalysis",
            "--mode", "qpcr", "--amplicon-size", "120",
            "--amplicon-size-min", "70", "--amplicon-size-max", "200",
        ])
        XCTAssertThrowsError(try missing.makeOptions())
    }

    func testOmittedBoundsFollowChangedNominalSizeWithoutClampingExplicitBounds() throws {
        let derived = try OlivarDesignCommand.parse([
            "--msa", "/tmp/a.fasta", "--output", "/tmp/out.lungfishprimeranalysis",
            "--amplicon-size", "1000",
        ]).makeOptions()
        XCTAssertEqual(derived.minimumAmpliconLength, 900)
        XCTAssertEqual(derived.maximumAmpliconLength, 1100)
        XCTAssertNil(derived.requestedMinimumAmpliconLength)
        XCTAssertNil(derived.requestedMaximumAmpliconLength)

        let explicit = try OlivarDesignCommand.parse([
            "--msa", "/tmp/a.fasta", "--output", "/tmp/out.lungfishprimeranalysis",
            "--amplicon-size", "1000", "--amplicon-size-min", "875",
            "--amplicon-size-max", "1125",
        ]).makeOptions()
        XCTAssertEqual(explicit.minimumAmpliconLength, 875)
        XCTAssertEqual(explicit.maximumAmpliconLength, 1125)
        XCTAssertEqual(explicit.requestedMinimumAmpliconLength, 875)
        XCTAssertEqual(explicit.requestedMaximumAmpliconLength, 1125)
    }

    func testEqualsSyntaxRecordsExplicitDefaultValuedCommonAndEngineOptions() throws {
        let workers = PrimerSchemeDesignOptions.defaultWorkers
        let varvampArguments = [
            "--msa=/tmp/a.fasta", "--output=/tmp/out.lungfishprimeranalysis",
            "--mode=tiled", "--grouping=independent", "--amplicon-size=400",
            "--workers=\(workers)", "--maximum-primer-ambiguities=2",
        ]
        let varvamp = try VarVAMPDesignCommand.parse(varvampArguments)
        let options = try varvamp.makeOptions(argv: varvampArguments)
        let common = try XCTUnwrap(options.provenanceOptions["common"]?.dictionaryValue)
        let supplied = try XCTUnwrap(common["supplied"]?.dictionaryValue)
        XCTAssertEqual(supplied["engine"]?.stringValue, "varvamp")
        XCTAssertEqual(supplied["mode"]?.stringValue, "tiled")
        XCTAssertEqual(supplied["grouping"]?.stringValue, "independent")
        XCTAssertEqual(supplied["nominalAmpliconLength"]?.integerValue, 400)
        XCTAssertEqual(supplied["workers"]?.integerValue, workers)
        let native = try XCTUnwrap(options.provenanceOptions["varvamp"]?.dictionaryValue)
        XCTAssertEqual(native["supplied"]?.dictionaryValue?["maximumPrimerAmbiguities"]?.integerValue,
                       2)

        let olivarArguments = [
            "--msa=/tmp/a.fasta", "--output=/tmp/out.lungfishprimeranalysis",
            "--grouping=independent", "--amplicon-size=400", "--workers=\(workers)",
            "--minimum-complexity=0.4",
        ]
        let olivar = try OlivarDesignCommand.parse(olivarArguments)
        let olivarOptions = try olivar.makeOptions(argv: olivarArguments)
        let olivarNative = try XCTUnwrap(
            olivarOptions.provenanceOptions["olivar"]?.dictionaryValue?["supplied"]?
                .dictionaryValue)
        XCTAssertEqual(olivarNative["minimumComplexity"]?.numberValue, 0.4)
        XCTAssertEqual(olivarOptions.provenanceOptions["common"]?.dictionaryValue?["supplied"]?
            .dictionaryValue?["grouping"]?.stringValue, "independent")
    }

    func testHelpNamesLGEAdapterAndNativeSizeSemantics() throws {
        let olivar = OlivarDesignCommand.helpMessage()
        XCTAssertTrue(olivar.contains("LGE adapter"))
        XCTAssertTrue(olivar.contains("including primer sites"))
        XCTAssertTrue(olivar.contains("nominal"))

        let varvamp = VarVAMPDesignCommand.helpMessage()
        XCTAssertTrue(varvamp.contains("cumulative"))
        XCTAssertTrue(varvamp.contains("--opt-length"))
        XCTAssertTrue(varvamp.contains("QAMPLICON_LENGTH"))
    }

    func testExistingPrimalSchemeDefaultsRemainUnchanged() throws {
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/a.fasta", "--output", "/tmp/out.lungfishprimeranalysis",
        ])
        XCTAssertEqual(command.ampliconSize, 400)
        XCTAssertNil(command.ampliconSizeMinimum)
        XCTAssertNil(command.ampliconSizeMaximum)
        XCTAssertEqual(command.minimumBaseFrequency, 0)
        XCTAssertEqual(command.grouping, "independent")
        XCTAssertEqual(command.poolCount, 2)
        XCTAssertEqual(command.coreCount, PrimalScheme3DesignOptions.defaultCoreCount)
    }

    func testPrimerDesignRegistersNewEngineSubcommands() {
        let names = PrimerDesignCommand.configuration.subcommands.compactMap {
            $0.configuration.commandName
        }
        XCTAssertTrue(names.contains("olivar"))
        XCTAssertTrue(names.contains("varvamp"))
    }

    // MARK: - Off-target screening sources

    /// `--screen-against` is the non-terminal route to off-target screening: the
    /// user names sequences and LGE builds the database, so the chosen paths must
    /// reach the options as screening sources, not as a database prefix.
    func testVarVAMPScreenAgainstCarriesSourcesAndLeavesTheDatabasePrefixUnset() throws {
        let root = try makeScreeningFixtures()
        let command = try VarVAMPDesignCommand.parse([
            "--msa", "/tmp/a.lungfishmsa",
            "--output", "/tmp/result.lungfishprimeranalysis",
            "--screen-against", root.appendingPathComponent("exclusion.fasta").path,
            "--screen-against", root.appendingPathComponent("second.fna").path,
        ])
        let options = try command.makeOptions()
        XCTAssertEqual(options.varvamp?.screeningSourcePaths, [
            root.appendingPathComponent("exclusion.fasta").path,
            root.appendingPathComponent("second.fna").path,
        ])
        XCTAssertNil(options.varvamp?.blastDatabasePath)
        XCTAssertTrue(options.varvamp?.suppliedOptionNames.contains("screeningSourcePaths") == true)
    }

    func testOlivarScreenAgainstCarriesSources() throws {
        let root = try makeScreeningFixtures()
        let command = try OlivarDesignCommand.parse([
            "--msa", "/tmp/a.lungfishmsa",
            "--output", "/tmp/result.lungfishprimeranalysis",
            "--screen-against", root.appendingPathComponent("exclusion.fasta").path,
        ])
        let options = try command.makeOptions()
        XCTAssertEqual(options.olivar?.screeningSourcePaths,
                       [root.appendingPathComponent("exclusion.fasta").path])
        XCTAssertNil(options.olivar?.blastDatabasePath)
        XCTAssertTrue(options.olivar?.suppliedOptionNames.contains("screeningSourcePaths") == true)
    }

    /// Building a database and reusing an existing one are different routes to the
    /// same engine option, so asking for both is a mistake, not a merge.
    func testScreenAgainstAndBlastDatabaseAreMutuallyExclusive() throws {
        let root = try makeScreeningFixtures()
        let fasta = root.appendingPathComponent("exclusion.fasta").path
        let varvamp = try VarVAMPDesignCommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--output", "/tmp/r.lungfishprimeranalysis",
            "--screen-against", fasta, "--blast-database", "/tmp/db/existing",
        ])
        XCTAssertThrowsError(try varvamp.makeOptions()) { error in
            XCTAssertTrue("\(error)".contains("not both"), "\(error)")
        }
        let olivar = try OlivarDesignCommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--output", "/tmp/r.lungfishprimeranalysis",
            "--screen-against", fasta, "--blast-database", "/tmp/db/existing",
        ])
        XCTAssertThrowsError(try olivar.makeOptions()) { error in
            XCTAssertTrue("\(error)".contains("not both"), "\(error)")
        }
    }

    func testScreenAgainstRejectsDocumentsThatAreNotSequenceSources() throws {
        let root = try makeScreeningFixtures()
        let command = try VarVAMPDesignCommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--output", "/tmp/r.lungfishprimeranalysis",
            "--screen-against", root.appendingPathComponent("screen.nin").path,
        ])
        XCTAssertThrowsError(try command.makeOptions()) { error in
            XCTAssertTrue("\(error)".contains("--screen-against"), "\(error)")
        }
    }

    func testDesignHelpExplainsThatLGEBuildsTheScreeningDatabase() {
        for help in [VarVAMPDesignCommand.helpMessage(), OlivarDesignCommand.helpMessage()] {
            XCTAssertTrue(help.contains("--screen-against"), help)
            XCTAssertTrue(help.contains("makeblastdb"), help)
        }
    }

    /// `--screen-against` validates the chosen documents, so the fixtures must be
    /// real files on disk.
    private func makeScreeningFixtures() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(">exclusion\nACGTACGTACGT\n".utf8)
            .write(to: root.appendingPathComponent("exclusion.fasta"))
        try Data(">second\nTTGACCGTAGGC\n".utf8)
            .write(to: root.appendingPathComponent("second.fna"))
        try Data("not-a-sequence".utf8).write(to: root.appendingPathComponent("screen.nin"))
        return root
    }
}

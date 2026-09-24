import ArgumentParser
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class PrimerSchemeCommandsTests: XCTestCase {
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
}

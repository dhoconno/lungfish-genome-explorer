import XCTest
@testable import LungfishWorkflow

final class VariantCallingPlatformTests: XCTestCase {
    // MARK: - Platform parsing

    func testCLIValuesAcceptClair3NamesAndPlainAliases() {
        XCTAssertEqual(VariantCallingPlatform(cliValue: "ont"), .ont)
        XCTAssertEqual(VariantCallingPlatform(cliValue: "Nanopore"), .ont)
        XCTAssertEqual(VariantCallingPlatform(cliValue: "hifi"), .hifi)
        XCTAssertEqual(VariantCallingPlatform(cliValue: "PacBio"), .hifi)
        XCTAssertEqual(VariantCallingPlatform(cliValue: "ilmn"), .ilmn)
        XCTAssertEqual(VariantCallingPlatform(cliValue: "illumina"), .ilmn)
        XCTAssertNil(VariantCallingPlatform(cliValue: "iontorrent"))
        XCTAssertNil(VariantCallingPlatform(cliValue: ""))
    }

    func testReadGroupPlatformMapsSAMSpellings() {
        XCTAssertEqual(VariantCallingPlatform(readGroupPlatform: "ONT"), .ont)
        XCTAssertEqual(VariantCallingPlatform(readGroupPlatform: "OXFORD_NANOPORE"), .ont)
        XCTAssertEqual(VariantCallingPlatform(readGroupPlatform: "PACBIO"), .hifi)
        XCTAssertEqual(VariantCallingPlatform(readGroupPlatform: "ILLUMINA"), .ilmn)
        XCTAssertNil(VariantCallingPlatform(readGroupPlatform: "ASSEMBLY"))
        XCTAssertNil(VariantCallingPlatform(readGroupPlatform: "CDNA"))
    }

    func testDetectFromBAMHeaderNeedsOneAgreedPlatform() {
        let ont = """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:20
        @RG\tID:rg1\tSM:s\tPL:ONT
        """
        XCTAssertEqual(VariantCallingPlatform.detect(fromBAMHeader: ont), .ont)

        let mixed = """
        @RG\tID:rg1\tPL:ONT
        @RG\tID:rg2\tPL:ILLUMINA
        """
        XCTAssertNil(VariantCallingPlatform.detect(fromBAMHeader: mixed))

        let noReadGroups = "@HD\tVN:1.6\n@SQ\tSN:chr1\tLN:20\n"
        XCTAssertNil(VariantCallingPlatform.detect(fromBAMHeader: noReadGroups))
        XCTAssertEqual(VariantCallingPlatform.readGroupPlatformValues(fromBAMHeader: mixed), ["ILLUMINA", "ONT"])
    }

    // MARK: - Clair3 model resolution

    private let modelsDirectory = URL(fileURLWithPath: "/envs/clair3/bin/models", isDirectory: true)
    private let shipped = ["hifi", "hifi_revio", "ilmn", "ont", "r1041_e82_400bps_sup_v500", "r941_prom_sup_g5014"]

    private func resolve(
        _ requested: String?,
        platform: VariantCallingPlatform,
        descriptions: [String] = [],
        available: [String]? = nil,
        weightsPresent: @escaping (URL) -> Bool = { _ in true }
    ) throws -> URL {
        try Clair3ModelResolver.resolve(
            requestedModel: requested,
            platform: platform,
            readGroupDescriptions: descriptions,
            modelsDirectory: modelsDirectory,
            availableModels: available ?? shipped,
            directoryHoldsWeights: weightsPresent
        )
    }

    func testShippedModelNameResolvesInsideModelsDirectory() throws {
        let url = try resolve("r941_prom_sup_g5014", platform: .ont)
        XCTAssertEqual(url.path, "/envs/clair3/bin/models/r941_prom_sup_g5014")
    }

    func testAbsoluteModelPathIsUsedWhenItHoldsWeights() throws {
        let url = try resolve("/Users/me/models/custom", platform: .ont)
        XCTAssertEqual(url.path, "/Users/me/models/custom")

        XCTAssertThrowsError(try resolve("/Users/me/models/empty", platform: .ont, weightsPresent: { _ in false })) { error in
            XCTAssertEqual(
                error as? Clair3ModelResolver.ResolutionError,
                .modelDirectoryMissingWeights("/Users/me/models/empty")
            )
        }
    }

    func testUnknownModelNameListsModelsShippedForThePlatform() {
        XCTAssertThrowsError(try resolve("r1041_e82_400bps_sup_v5.0.0", platform: .ont)) { error in
            XCTAssertEqual(
                error as? Clair3ModelResolver.ResolutionError,
                .unknownModel(
                    requested: "r1041_e82_400bps_sup_v5.0.0",
                    platform: .ont,
                    available: ["ont", "r1041_e82_400bps_sup_v500", "r941_prom_sup_g5014"]
                )
            )
        }
    }

    func testEmptyModelFallsBackToPlatformDefaultDirectory() throws {
        XCTAssertEqual(try resolve(nil, platform: .hifi).lastPathComponent, "hifi")
        XCTAssertEqual(try resolve("  ", platform: .ilmn).lastPathComponent, "ilmn")
        XCTAssertEqual(try resolve(nil, platform: .ont).lastPathComponent, "ont")
    }

    func testEmptyModelPrefersDoradoBasecallerModelFromReadGroupDescription() throws {
        let url = try resolve(
            nil,
            platform: .ont,
            descriptions: ["basecall_model=dna_r10.4.1_e8.2_400bps_sup@v5.0.0 runid=abc"]
        )
        XCTAssertEqual(url.lastPathComponent, "r1041_e82_400bps_sup_v500")

        // A basecaller version Clair3 does not ship falls back to the generic model.
        let fallback = try resolve(
            nil,
            platform: .ont,
            descriptions: ["basecall_model=dna_r10.4.1_e8.2_400bps_hac@v4.3.0"]
        )
        XCTAssertEqual(fallback.lastPathComponent, "ont")
    }

    func testMissingPlatformDefaultIsAClearError() {
        XCTAssertThrowsError(try resolve(nil, platform: .ilmn, available: ["ont", "hifi"])) { error in
            XCTAssertEqual(
                error as? Clair3ModelResolver.ResolutionError,
                .noModelForPlatform(.ilmn, available: ["hifi", "ont"])
            )
        }
    }

    func testBasecallerModelNameConversion() {
        XCTAssertEqual(
            Clair3ModelResolver.basecallerModelName(fromReadGroupDescriptions: [
                "basecall_model=dna_r10.4.1_e8.2_400bps_hac@v5.2.0",
            ]),
            "r1041_e82_400bps_hac_v520"
        )
        XCTAssertNil(Clair3ModelResolver.basecallerModelName(fromReadGroupDescriptions: ["guppy 6.4"]))
        XCTAssertNil(Clair3ModelResolver.basecallerModelName(fromReadGroupDescriptions: []))
    }
}

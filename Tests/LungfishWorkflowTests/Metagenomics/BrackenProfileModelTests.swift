import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class BrackenProfileModelTests: XCTestCase {
    func testAutomaticRankUsesStableRRNADatabaseCapabilities() {
        let silva = BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-special-silva",
            installationRecipe: .kraken2Special(type: .silva),
            request: .automatic
        )
        let greengenesByRecipe = BrackenDatabaseCapabilities.resolve(
            catalogID: nil,
            installationRecipe: .kraken2Special(type: .greengenes),
            request: .automatic
        )

        XCTAssertEqual(silva.rank, .genus)
        XCTAssertEqual(silva.source, .catalogIdentity)
        XCTAssertEqual(greengenesByRecipe.rank, .genus)
        XCTAssertEqual(greengenesByRecipe.source, .installationRecipe)
    }

    func testAutomaticRankDefaultsToSpeciesForOrdinaryDatabase() {
        let resolution = BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-standard-8",
            installationRecipe: .archive(url: URL(string: "https://example.invalid/db.tar.gz")!),
            request: .automatic
        )

        XCTAssertEqual(resolution.rank, .species)
        XCTAssertEqual(resolution.source, .catalogIdentity)
    }

    func testKnownCatalogIdentityPrecedesAConflictingRecipe() {
        let resolution = BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-standard-8",
            installationRecipe: .kraken2Special(type: .silva),
            request: .automatic
        )

        XCTAssertEqual(resolution.rank, .species)
        XCTAssertEqual(resolution.source, .catalogIdentity)
    }

    func testExplicitRankIsNeverRewrittenByDatabaseCapability() {
        let explicitSpecies = BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-special-silva",
            installationRecipe: .kraken2Special(type: .silva),
            request: .explicit(.species)
        )
        let explicitGenus = BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-standard-8",
            installationRecipe: nil,
            request: .explicit(.genus)
        )

        XCTAssertEqual(explicitSpecies.rank, .species)
        XCTAssertEqual(explicitSpecies.source, .explicitRequest)
        XCTAssertEqual(explicitGenus.rank, .genus)
        XCTAssertEqual(explicitGenus.source, .explicitRequest)
    }

    func testSupportedBrackenLevelMappingNeverFallsBackToSpecies() {
        let supported: [(TaxonomicRank, String)] = [
            (.domain, "D"),
            (.phylum, "P"),
            (.`class`, "C"),
            (.order, "O"),
            (.family, "F"),
            (.genus, "G"),
            (.species, "S"),
        ]
        for (rank, expected) in supported {
            XCTAssertEqual(BrackenDatabaseCapabilities.levelCode(for: rank), expected)
        }

        for unsupported in [
            TaxonomicRank.unclassified,
            .root,
            .kingdom,
            .intermediate("S1"),
            .unknown("X"),
        ] {
            XCTAssertNil(BrackenDatabaseCapabilities.levelCode(for: unsupported))
        }
    }

    func testAutomaticProfileRequestKeepsResolvedReadLengthAt150() {
        XCTAssertEqual(BrackenProfileRequest.automaticDefault.rank, .automatic)
        XCTAssertEqual(BrackenProfileRequest.automaticDefault.readLength, 150)
        XCTAssertEqual(BrackenProfileRequest.automaticDefault.threshold, 10)
    }

    func testProfileConfigRoundTripPreservesStableDatabaseIdentityAndRequest() throws {
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: [URL(fileURLWithPath: "/data/reads.fastq")],
            isPairedEnd: false,
            databaseName: "SILVA",
            databaseVersion: "built-test",
            databasePath: URL(fileURLWithPath: "/db/silva"),
            databaseDigest: "sha256:fixture",
            databaseCatalogID: "kraken2-special-silva",
            databaseInstallationRecipe: .kraken2Special(type: .silva),
            brackenProfileRequest: .automaticDefault,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let decoded = try JSONDecoder().decode(
            ClassificationConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded.goal, .profile)
        XCTAssertEqual(decoded.databaseCatalogID, "kraken2-special-silva")
        XCTAssertEqual(decoded.databaseInstallationRecipe, .kraken2Special(type: .silva))
        XCTAssertEqual(decoded.brackenProfileRequest, .automaticDefault)
    }

    func testLegacyConfigWithoutCapabilityFieldsStillDecodes() throws {
        let json = #"{"confidence":0.2,"databaseName":"Legacy","databasePath":"file:///db/legacy","databaseVersion":"v1","goal":"profile","inputFiles":["file:///data/reads.fastq"],"isPairedEnd":false,"memoryMapping":false,"minimumHitGroups":2,"outputDirectory":"file:///output","quickMode":false,"threads":4}"#

        let decoded = try JSONDecoder().decode(
            ClassificationConfig.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.goal, .profile)
        XCTAssertNil(decoded.databaseCatalogID)
        XCTAssertNil(decoded.databaseInstallationRecipe)
        XCTAssertNil(decoded.brackenProfileRequest)
    }

    func testProfileOutcomeCodablePreservesCompletedAndDegradedEvidence() throws {
        let resolution = BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-special-silva",
            installationRecipe: .kraken2Special(type: .silva),
            request: .automatic,
            readLength: 150,
            threshold: 10
        )
        let outcomes: [BrackenProfileOutcome] = [
            .notRequested,
            .completed(resolution: resolution, toolVersion: "3.0.1"),
            .degraded(
                resolution: resolution,
                reason: .rankAbsentFromReport,
                message: "The Kraken report has no genus rows.",
                toolVersion: "3.0.1"
            ),
        ]

        let decoded = try JSONDecoder().decode(
            [BrackenProfileOutcome].self,
            from: JSONEncoder().encode(outcomes)
        )

        XCTAssertEqual(decoded, outcomes)
        XCTAssertEqual(decoded.map(\.state), [.notRequested, .completed, .degraded])
        XCTAssertEqual(decoded.last?.resolution?.readLength, 150)
        XCTAssertEqual(decoded.last?.reason, .rankAbsentFromReport)
    }
}

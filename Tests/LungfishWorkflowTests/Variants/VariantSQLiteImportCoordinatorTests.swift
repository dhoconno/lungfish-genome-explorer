import XCTest
import os
@testable import LungfishWorkflow
@testable import LungfishIO

final class VariantSQLiteImportCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantSQLiteImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCoordinatorResumesInterruptedIndexBuild() async throws {
        let vcfURL = try createViralVCF()
        let dbURL = tempDir.appendingPathComponent("resume-index.db")

        _ = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            importSemantics: .viralFrequency,
            importProfile: .ultraLowMemory,
            deferIndexBuild: true
        )
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "indexing")

        let coordinator = VariantSQLiteImportCoordinator()
        let result = try await coordinator.importNormalizedVCF(
            request: VariantSQLiteImportRequest(
                normalizedVCFURL: vcfURL,
                outputDatabaseURL: dbURL,
                sourceFile: vcfURL.lastPathComponent,
                importProfile: .ultraLowMemory,
                importSemantics: .viralFrequency
            )
        )

        XCTAssertTrue(result.didResumeIndexBuild)
        XCTAssertFalse(result.didResumeMaterialization)
        XCTAssertEqual(result.variantCount, 2)
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "complete")
    }

    func testCoordinatorResumesInterruptedMaterialization() async throws {
        let vcfURL = try createViralVCF()
        let dbURL = tempDir.appendingPathComponent("resume-materialize.db")

        _ = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            importSemantics: .viralFrequency,
            importProfile: .ultraLowMemory
        )

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        _ = try? VariantDatabase.materializeVariantInfo(
            existingDBURL: dbURL,
            progressHandler: { _, _ in
                cancelFlag.withLock { $0 = true }
            },
            shouldCancel: {
                cancelFlag.withLock { $0 }
            }
        )

        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "complete")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "materialize_state"), "materializing")

        let coordinator = VariantSQLiteImportCoordinator()
        let result = try await coordinator.importNormalizedVCF(
            request: VariantSQLiteImportRequest(
                normalizedVCFURL: vcfURL,
                outputDatabaseURL: dbURL,
                sourceFile: vcfURL.lastPathComponent,
                importProfile: .ultraLowMemory,
                importSemantics: .viralFrequency
            )
        )

        XCTAssertFalse(result.didResumeIndexBuild)
        XCTAssertTrue(result.didResumeMaterialization)
        XCTAssertEqual(result.variantCount, 2)
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "materialize_state"), "complete")

        let db = try VariantDatabase(url: dbURL)
        XCTAssertFalse(db.variantInfoSkipped)
        let variants = db.query(chromosome: "chr1", start: 0, end: 1_000)
        XCTAssertEqual(variants.count, 2)
        XCTAssertFalse(db.infoValues(variantId: try XCTUnwrap(variants.first?.id)).isEmpty)
    }

    func testResumeMaterializationWhenDisabled() async throws {
        let vcfURL = try createViralVCF()
        let dbURL = tempDir.appendingPathComponent("resume-materialize-disabled.db")

        _ = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            importSemantics: .viralFrequency,
            importProfile: .ultraLowMemory
        )

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        _ = try? VariantDatabase.materializeVariantInfo(
            existingDBURL: dbURL,
            progressHandler: { _, _ in
                cancelFlag.withLock { $0 = true }
            },
            shouldCancel: {
                cancelFlag.withLock { $0 }
            }
        )

        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "materialize_state"), "materializing")

        let coordinator = VariantSQLiteImportCoordinator()
        let result = try await coordinator.importNormalizedVCF(
            request: VariantSQLiteImportRequest(
                normalizedVCFURL: vcfURL,
                outputDatabaseURL: dbURL,
                sourceFile: vcfURL.lastPathComponent,
                importProfile: .ultraLowMemory,
                importSemantics: .viralFrequency,
                materializeVariantInfo: false
            )
        )

        XCTAssertTrue(result.didResumeMaterialization)
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "materialize_state"), "complete")

        let db = try VariantDatabase(url: dbURL)
        XCTAssertFalse(db.variantInfoSkipped)
        let variants = db.query(chromosome: "chr1", start: 0, end: 1_000)
        XCTAssertEqual(variants.count, 2)
        XCTAssertFalse(db.infoValues(variantId: try XCTUnwrap(variants.first?.id)).isEmpty)
    }

    private func createViralVCF() throws -> URL {
        let vcfURL = tempDir.appendingPathComponent("viral.vcf")
        try """
        ##fileformat=VCFv4.3
        ##contig=<ID=chr1,length=20>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t2\tvar1\tA\tG\t50\tPASS\tAF=0.5;DP=20
        chr1\t5\tvar2\tC\tT\t45\tPASS\tAF=0.4;DP=18
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        return vcfURL
    }
}

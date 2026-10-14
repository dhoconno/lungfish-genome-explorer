import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI

/// Phase 2.10 lane B35, panel decision R2. Two smart cohorts of one sidecar
/// that resolve to one `cohort_id` would be exported twice under that id, and a
/// reader of the LabKey table could not tell them apart. `genotype
/// export-labkey` refuses such a sidecar before it writes any file, names every
/// cohort that shares an id and exits with status 3 (`CLIExitCode.inputError`).
///
/// The ids here are Python `uuid.uuid5` values, as in
/// `GenotypeCohortIdentityExportTests`, so they share no code with the Swift
/// derivation. A stored id is written into the sidecar file as JSON.
final class GenotypeCohortIdCollisionTests: XCTestCase {
    typealias Pins = GenotypeCohortListingPinTests
    typealias Identity = GenotypeCohortIdentityExportTests

    /// The id of the third cohort named "Errors at MHC-A" in scope "bundle".
    static let errorsThirdID = "a93ed129-7806-592e-81b8-66fbf6128a02"
    /// Stored ids that no derivation produces.
    static let sharedID = Identity.storedElsewhereID
    static let otherSharedID = "c2d9e1a4-58f3-4b6e-8d07-1e3a5b9c7f20"

    // MARK: - The refusal

    func testExportRefusesTwoCohortsThatStoreOneIdWithExitStatusThree() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-exit")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundleWithSharedID(in: root)

        let attempt = try await Self.attemptExport(bundle, into: root.appendingPathComponent("labkey", isDirectory: true))

        XCTAssertEqual((attempt.error as? ExitCode)?.rawValue, 3, "\(String(describing: attempt.error))")
    }

    func testRefusalCreatesNoOutputFolderAndNoFile() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-nofolder")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundleWithSharedID(in: root)
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)

        let attempt = try await Self.attemptExport(bundle, into: outputDir)

        XCTAssertNotNil(attempt.error, "the export refuses")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.path), "so no folder and no file exist")
    }

    /// An earlier export in the folder stays as it was, and the bundle and the
    /// folder beside it gain no record, lock or sidecar.
    func testRefusalLeavesAnExistingOutputFolderAndTheBundleAsTheyWere() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-existing")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundleWithSharedID(in: root)
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for name in LabKeyExporter.filenames.values {
            try Data("an earlier export\n".utf8).write(to: outputDir.appendingPathComponent(name))
        }
        let folderBefore = try Identity.treeDigest(of: outputDir)
        let bundleBefore = try Identity.treeDigest(of: bundle)
        let besideBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

        let attempt = try await Self.attemptExport(bundle, into: outputDir)

        XCTAssertNotNil(attempt.error, "the export refuses")
        XCTAssertEqual(try Identity.treeDigest(of: outputDir), folderBefore)
        XCTAssertEqual(try Identity.treeDigest(of: bundle), bundleBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), besideBefore)
    }

    func testRefusalNamesBothCohortsWithTheirNameScopeAndSharedId() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-names")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundleWithSharedID(in: root)

        let attempt = try await Self.attemptExport(bundle, into: root.appendingPathComponent("labkey", isDirectory: true))

        XCTAssertEqual(attempt.standardError, """
        Cannot export because smart cohorts share a cohort_id, and a reader of smart_cohorts.csv could not tell them apart. No file was written.
          \(Self.sharedID) is the id of cohort 2 "Needs review" (scope bundle) and cohort 5 "Errors at MHC-A" (scope bundle).

        """)
    }

    /// Two cohorts with one scope and name differ only by their place in the file.
    func testRefusalTellsTwoCohortsOfOneScopeAndNameApartByPlace() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-twins")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Pins.makeBundle(in: root, smartCohorts: Self.twinsOfErrors(count: 2))
        try Identity.storeIDs([Identity.errorsID, Identity.errorsID], in: bundle)

        let attempt = try await Self.attemptExport(bundle, into: root.appendingPathComponent("labkey", isDirectory: true))

        XCTAssertEqual((attempt.error as? ExitCode)?.rawValue, 3)
        XCTAssertTrue(
            attempt.standardError.contains(
                "\(Identity.errorsID) is the id of cohort 1 \"Errors at MHC-A\" (scope bundle) and cohort 2 \"Errors at MHC-A\" (scope bundle)."
            ),
            attempt.standardError
        )
    }

    func testRefusalNamesEveryCohortOfAThreeWayCollision() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-three")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Pins.makeBundle(in: root, smartCohorts: Self.twinsOfErrors(count: 3))
        try Identity.storeIDs([Self.sharedID, Self.sharedID, Self.sharedID], in: bundle)

        let attempt = try await Self.attemptExport(bundle, into: root.appendingPathComponent("labkey", isDirectory: true))

        XCTAssertTrue(
            attempt.standardError.contains(
                "\(Self.sharedID) is the id of cohort 1 \"Errors at MHC-A\" (scope bundle), cohort 2 \"Errors at MHC-A\" (scope bundle) and cohort 3 \"Errors at MHC-A\" (scope bundle)."
            ),
            attempt.standardError
        )
    }

    /// Each shared id has a line, in the order the ids first appear in the file.
    func testRefusalListsEveryIdThatTwoCohortsShare() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-groups")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Identity.makeFiveCohortBundle(in: root)
        try Identity.storeIDs([Self.otherSharedID, Self.sharedID, Self.otherSharedID, Self.sharedID, nil], in: bundle)

        let attempt = try await Self.attemptExport(bundle, into: root.appendingPathComponent("labkey", isDirectory: true))

        XCTAssertEqual(attempt.standardError, """
        Cannot export because smart cohorts share a cohort_id, and a reader of smart_cohorts.csv could not tell them apart. No file was written.
          \(Self.otherSharedID) is the id of cohort 1 "Incomplete haplotypes" (scope bundle) and cohort 3 "Homozygous" (scope bundle).
          \(Self.sharedID) is the id of cohort 2 "Needs review" (scope bundle) and cohort 4 "Recombinants" (scope bundle).

        """)
    }

    /// A UUID reads from either case, so ids stored as upper and lower case
    /// text are one id.
    func testIdsStoredInUpperAndLowerCaseAreOneIdAndRefused() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-case")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Identity.makeFiveCohortBundle(in: root)
        try Identity.storeIDs([nil, Self.sharedID.uppercased(), nil, nil, Self.sharedID], in: bundle)

        let attempt = try await Self.attemptExport(bundle, into: root.appendingPathComponent("labkey", isDirectory: true))

        XCTAssertEqual((attempt.error as? ExitCode)?.rawValue, 3)
        XCTAssertTrue(attempt.standardError.contains("\(Self.sharedID) is the id of cohort 2 "), attempt.standardError)
    }

    // MARK: - What the refusal leaves alone

    /// Two cohorts with one scope and name that derive one id cannot be built.
    /// A cohort that stores no id derives the id of its place among the cohorts
    /// of its scope and name, and moves past any id that a cohort stores or an
    /// earlier cohort derived (`resolvedIDs`). So only two stored ids can be
    /// equal, and these arrangements give distinct ids that the export writes,
    /// as it did before the refusal.
    func testCohortsOfOneScopeAndNameThatStoreNoSharedIdAreStillExported() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-derived")
        defer { TestTempDirectory.cleanup(root) }

        let storedFirstPlace = try Pins.makeBundle(
            in: root.appendingPathComponent("a", isDirectory: true).createdFolder(),
            smartCohorts: Self.twinsOfErrors(count: 2)
        )
        try Identity.storeIDs([nil, Identity.errorsID], in: storedFirstPlace)
        let afterStoredFirstPlace = Identity.rows(try await Identity.export(storedFirstPlace, root: root))
        XCTAssertEqual(
            afterStoredFirstPlace.map { $0.id },
            [Identity.errorsSecondID, Identity.errorsID],
            "the cohort without an id moves past the id the other one stores"
        )

        let storedSecondPlace = try Pins.makeBundle(
            in: root.appendingPathComponent("b", isDirectory: true).createdFolder(),
            smartCohorts: Self.twinsOfErrors(count: 3)
        )
        try Identity.storeIDs([nil, nil, Identity.errorsSecondID], in: storedSecondPlace)
        let afterStoredSecondPlace = Identity.rows(try await Identity.export(storedSecondPlace, root: root))
        XCTAssertEqual(
            afterStoredSecondPlace.map { $0.id },
            [Identity.errorsID, Self.errorsThirdID, Identity.errorsSecondID]
        )
    }

    // MARK: - The check itself

    func testCollisionsAreEmptyWhenEveryCohortHasItsOwnId() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T10:00:00Z")
        XCTAssertEqual(LabKeyExporter.cohortIDCollisions(in: sidecar), [])

        sidecar.smartCohorts = Pins.builtInCohorts + [Pins.analystCohort]
        XCTAssertEqual(LabKeyExporter.cohortIDCollisions(in: sidecar), [])

        sidecar.smartCohorts = Self.twinsOfErrors(count: 3)
        XCTAssertEqual(LabKeyExporter.cohortIDCollisions(in: sidecar), [], "twins that store no id derive three ids")
    }

    func testCollisionsGroupCohortsByIdWithTheirPlacesInSidecarOrder() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T10:00:00Z")
        sidecar.smartCohorts = Pins.builtInCohorts + [Pins.analystCohort]
        let shared = try XCTUnwrap(UUID(uuidString: Self.sharedID))
        sidecar.smartCohorts[4].id = shared
        sidecar.smartCohorts[1].id = shared

        let collisions = LabKeyExporter.cohortIDCollisions(in: sidecar)

        XCTAssertEqual(collisions, [
            GenotypeLabKeyCohortIDCollision(id: shared, cohorts: [
                .init(place: 2, name: "Needs review", scope: "bundle"),
                .init(place: 5, name: "Errors at MHC-A", scope: "bundle"),
            ]),
        ])
    }

    /// `writeAll` is the last guard before a CSV is written, for any caller
    /// that does not go through `run`.
    func testWriteAllWritesNothingForTwoCohortsThatShareAnId() async throws {
        let root = try TestTempDirectory.make(prefix: "cohort-refuse-writeall")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Self.makeBundleWithSharedID(in: root)
        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundle)
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let exporter = LabKeyExporter(outputDir: outputDir, bundleURL: bundle, result: nil, sidecar: sidecar)

        let attempt = try await Self.capturingStandardError { _ = try exporter.writeAll() }

        XCTAssertEqual((attempt.error as? ExitCode)?.rawValue, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDir.path), [])
    }

    // MARK: - Fixture

    /// The five cohorts of `Pins.makeBundle`, with "Needs review" and "Errors at
    /// MHC-A" storing `sharedID`.
    static func makeBundleWithSharedID(in root: URL) throws -> URL {
        let bundle = try Identity.makeFiveCohortBundle(in: root)
        try Identity.storeIDs([nil, sharedID, nil, nil, sharedID], in: bundle)
        return bundle
    }

    /// `count` cohorts named "Errors at MHC-A" in scope "bundle" that differ by
    /// their predicate, in sidecar order.
    static func twinsOfErrors(count: Int) -> [GenotypeCohortSmartFilter] {
        let predicates: [SmartCohortPredicate] = [.hasErrorAt(locus: "MHC-A"), .hasAnyComment, .needsHaplotypeReview]
        return predicates.prefix(count).map { predicate in
            var cohort = Pins.analystCohort
            cohort.predicate = predicate
            return cohort
        }
    }

    /// What an operation threw and what it wrote on standard error.
    struct Attempt {
        let error: Error?
        let standardError: String
    }

    /// Runs `genotype export-labkey` on `bundle` and keeps what it threw and wrote on standard error.
    static func attemptExport(_ bundle: URL, into outputDir: URL) async throws -> Attempt {
        let command = try GenotypeExportLabKeySubcommand.parse([
            "--bundle", bundle.path, "--output-dir", outputDir.path,
        ])
        return try await capturingStandardError { try await command.run() }
    }

    /// Runs `operation` with standard error pointed at a file, so a long message cannot fill a pipe.
    static func capturingStandardError(_ operation: () async throws -> Void) async throws -> Attempt {
        let folder = try TestTempDirectory.make(prefix: "cohort-refuse-stderr")
        defer { TestTempDirectory.cleanup(folder) }
        let url = folder.appendingPathComponent("stderr.txt")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let saved = dup(STDERR_FILENO)
        dup2(descriptor, STDERR_FILENO)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        close(descriptor)
        return Attempt(error: thrown, standardError: try String(contentsOf: url, encoding: .utf8))
    }
}

private extension URL {
    /// This folder, created with its parents, for a test that builds two bundles.
    func createdFolder() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}

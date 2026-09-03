import XCTest
@testable import LungfishWorkflow

/// Covers the whitespace staging that keeps `bbmerge.sh` usable for projects
/// whose path contains a space.
///
/// Regression context: bbtools' wrapper scripts end with
/// `CMD="java ... jgi.BBMerge $@"; eval $CMD`, so every argument is re-split by
/// the shell no matter how carefully the caller built its argv array. A project
/// named "Amplicon genotyping results" therefore made bbmerge die with
/// "Unknown parameter genotyping" before reading a single read.
final class IlluminaAmpliconPairMergeStagingTests: XCTestCase {

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name) \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeFASTQ(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "@READ/1\nACGT\n+\nIIII\n@READ/2\nACGT\n+\nIIII\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    // MARK: - Whitespace detection

    func testDetectsWhitespaceInAnyRunPath() throws {
        XCTAssertTrue(
            IlluminaAmpliconPairMerger.pathContainsWhitespace(
                URL(fileURLWithPath: "/Users/x/Amplicon genotyping results/run")
            )
        )
        XCTAssertFalse(
            IlluminaAmpliconPairMerger.pathContainsWhitespace(
                URL(fileURLWithPath: "/Users/x/amplicon-genotyping-results/run")
            )
        )
        // Tabs and newlines re-split under `eval` exactly like spaces do.
        XCTAssertTrue(
            IlluminaAmpliconPairMerger.pathContainsWhitespace(
                URL(fileURLWithPath: "/Users/x/tabbed\tdir/run")
            )
        )
    }

    // MARK: - Plan selection

    func testPlanRunsInPlaceWhenNoPathHasWhitespace() throws {
        // Every other fixture here deliberately carries a space, so this one
        // builds its own clean root to prove the untouched in-place branch.
        let clean = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbmerge-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: clean) }
        try XCTSkipIf(
            IlluminaAmpliconPairMerger.pathContainsWhitespace(clean),
            "System temp directory itself contains whitespace"
        )
        let fastqURL = try writeFASTQ(named: "sample.fastq", in: clean)

        let plan = try IlluminaAmpliconPairMerger.MergeStaging.plan(
            fastqURL: fastqURL,
            workingDirectory: clean,
            stem: "sample"
        )
        addTeardownBlock { plan.cleanUp() }

        XCTAssertNil(plan.temporaryRoot)
        XCTAssertEqual(plan.runInputURL, fastqURL)
        XCTAssertEqual(plan.runMergedURL, plan.finalMergedURL)
        XCTAssertEqual(plan.runUnmergedURL, plan.finalUnmergedURL)
    }

    func testPlanMovesRunOffWhitespacePathsButKeepsFinalDestinations() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let fastqURL = try writeFASTQ(named: "WD1 S148.fastq", in: working)

        let plan = try IlluminaAmpliconPairMerger.MergeStaging.plan(
            fastqURL: fastqURL,
            workingDirectory: working,
            stem: "WD1-S148"
        )
        addTeardownBlock { plan.cleanUp() }

        let temporaryRoot = try XCTUnwrap(plan.temporaryRoot)
        XCTAssertFalse(IlluminaAmpliconPairMerger.pathContainsWhitespace(temporaryRoot))
        // Everything bbmerge is handed must be whitespace free, including the
        // input, because `eval` splits the `in=` value just as readily.
        for url in [plan.runInputURL, plan.runMergedURL, plan.runUnmergedURL, plan.runStderrURL] {
            XCTAssertFalse(
                IlluminaAmpliconPairMerger.pathContainsWhitespace(url),
                "\(url.path) would be re-split by the wrapper's eval"
            )
        }
        // Callers keep their contract: results land in the working directory.
        XCTAssertEqual(plan.finalMergedURL.deletingLastPathComponent().standardizedFileURL, working.standardizedFileURL)
        XCTAssertEqual(plan.finalUnmergedURL.deletingLastPathComponent().standardizedFileURL, working.standardizedFileURL)
        XCTAssertNotEqual(plan.runMergedURL, plan.finalMergedURL)
    }

    func testStagedInputIsReadableAndMatchesTheSource() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let fastqURL = try writeFASTQ(named: "WD1 S148.fastq", in: working)

        let plan = try IlluminaAmpliconPairMerger.MergeStaging.plan(
            fastqURL: fastqURL,
            workingDirectory: working,
            stem: "WD1-S148"
        )
        addTeardownBlock { plan.cleanUp() }

        let staged = try String(contentsOf: plan.runInputURL, encoding: .utf8)
        let original = try String(contentsOf: fastqURL, encoding: .utf8)
        XCTAssertEqual(staged, original)
    }

    func testCleanUpRemovesTheTemporaryRoot() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let fastqURL = try writeFASTQ(named: "WD1 S148.fastq", in: working)

        let plan = try IlluminaAmpliconPairMerger.MergeStaging.plan(
            fastqURL: fastqURL,
            workingDirectory: working,
            stem: "WD1-S148"
        )
        let temporaryRoot = try XCTUnwrap(plan.temporaryRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryRoot.path))

        plan.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.path))
    }

    // MARK: - Result adoption

    func testAdoptResultsMovesOutputsBackIntoTheWorkingDirectory() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let fastqURL = try writeFASTQ(named: "WD1 S148.fastq", in: working)

        let plan = try IlluminaAmpliconPairMerger.MergeStaging.plan(
            fastqURL: fastqURL,
            workingDirectory: working,
            stem: "WD1-S148"
        )
        addTeardownBlock { plan.cleanUp() }

        try "merged".write(to: plan.runMergedURL, atomically: true, encoding: .utf8)
        try "unmerged".write(to: plan.runUnmergedURL, atomically: true, encoding: .utf8)
        try "log".write(to: plan.runStderrURL, atomically: true, encoding: .utf8)

        try plan.adoptResults()

        XCTAssertEqual(try String(contentsOf: plan.finalMergedURL, encoding: .utf8), "merged")
        XCTAssertEqual(try String(contentsOf: plan.finalUnmergedURL, encoding: .utf8), "unmerged")
        XCTAssertEqual(try String(contentsOf: plan.finalStderrURL, encoding: .utf8), "log")
    }

    func testAdoptResultsToleratesOutputsBBMergeNeverWrote() throws {
        // bbmerge omits `outu` entirely when every pair merged, so a missing
        // run-side file is normal and must not fail the adoption.
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let fastqURL = try writeFASTQ(named: "WD1 S148.fastq", in: working)

        let plan = try IlluminaAmpliconPairMerger.MergeStaging.plan(
            fastqURL: fastqURL,
            workingDirectory: working,
            stem: "WD1-S148"
        )
        addTeardownBlock { plan.cleanUp() }

        try "merged".write(to: plan.runMergedURL, atomically: true, encoding: .utf8)
        try plan.adoptResults()

        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.finalMergedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.finalUnmergedURL.path))
    }

    // MARK: - End to end

    func testMergeSucceedsOnASpacedPath() async throws {
        let bbmergeURL = try Self.locateBBMerge()
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let fastqURL = working.appendingPathComponent("WD1 S148 L001.fastq")
        try Self.interleavedFASTQText().write(to: fastqURL, atomically: true, encoding: .utf8)

        let outcome = try await IlluminaAmpliconPairMerger.prepareForMapping(
            fastqURL: fastqURL,
            bbmergeURL: bbmergeURL,
            workingDirectory: working.appendingPathComponent("merge work", isDirectory: true),
            stem: "WD1-S148-L001",
            threads: 1
        )

        XCTAssertTrue(outcome.didMerge)
        XCTAssertGreaterThan(outcome.mappingReadCount, 0)
        XCTAssertFalse(
            outcome.stderr.contains("Unknown parameter"),
            "bbmerge re-split an argument: \(outcome.stderr)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.mappingFASTQURL.path))
        // The mapping FASTQ must live where the caller asked, not in staging.
        XCTAssertTrue(outcome.mappingFASTQURL.path.hasPrefix(working.path))
    }

    func testProvenanceRecordsTheArgvThatActuallyRan() async throws {
        let bbmergeURL = try Self.locateBBMerge()
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let fastqURL = working.appendingPathComponent("WD1 S148 L001.fastq")
        try Self.interleavedFASTQText().write(to: fastqURL, atomically: true, encoding: .utf8)

        let outcome = try await IlluminaAmpliconPairMerger.prepareForMapping(
            fastqURL: fastqURL,
            bbmergeURL: bbmergeURL,
            workingDirectory: working.appendingPathComponent("merge work", isDirectory: true),
            stem: "WD1-S148-L001",
            threads: 1
        )

        // Provenance must reproduce the run, so it records the staged argv
        // rather than the project paths bbmerge never saw.
        let stagingRoot = try XCTUnwrap(outcome.stagingRoot)
        XCTAssertTrue(outcome.arguments.contains { $0.hasPrefix("in=\(stagingRoot.path)/") })
        XCTAssertTrue(outcome.arguments.contains { $0.hasPrefix("out=\(stagingRoot.path)/") })
        XCTAssertFalse(outcome.arguments.contains { $0.contains(" ") })
        // And the staging root is gone by the time the caller sees it, which is
        // exactly why the record has to name it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testUnstagedRunRecordsNoStagingRoot() async throws {
        let bbmergeURL = try Self.locateBBMerge()
        let clean = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbmerge-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: clean) }
        try XCTSkipIf(
            IlluminaAmpliconPairMerger.pathContainsWhitespace(clean),
            "System temp directory itself contains whitespace"
        )
        let fastqURL = clean.appendingPathComponent("sample.fastq")
        try Self.interleavedFASTQText().write(to: fastqURL, atomically: true, encoding: .utf8)

        let outcome = try await IlluminaAmpliconPairMerger.prepareForMapping(
            fastqURL: fastqURL,
            bbmergeURL: bbmergeURL,
            workingDirectory: clean.appendingPathComponent("merge", isDirectory: true),
            stem: "sample",
            threads: 1
        )

        XCTAssertNil(outcome.stagingRoot)
        XCTAssertTrue(outcome.arguments.contains("in=\(fastqURL.path)"))
    }

    // MARK: - Support


    /// Interleaved pairs whose mates overlap end to end, so bbmerge has
    /// something real to join rather than exiting on an empty input.
    private static func interleavedFASTQText() -> String {
        let insert = "ACGTTGCAAGGCTTACCGGTTACAGGATCCATTGCAACGTTGCAAGGCTTACCGGTTACA"
        let mate = reverseComplement(insert)
        var text = ""
        for index in 0..<50 {
            let name = "M01472:632:000000000:1:1114:\(index):20282"
            text += "@\(name) 1:N:0:148\n\(insert)\n+\n\(String(repeating: "I", count: insert.count))\n"
            text += "@\(name) 2:N:0:148\n\(mate)\n+\n\(String(repeating: "I", count: mate.count))\n"
        }
        return text
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base in
            switch base {
            case "A": return Character("T")
            case "C": return Character("G")
            case "G": return Character("C")
            case "T": return Character("A")
            default: return base
            }
        })
    }

    /// Returns the managed `bbmerge.sh`, skipping when the bbtools env is absent.
    private static func locateBBMerge() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home
            .appendingPathComponent(".lungfish/conda/envs/bbtools/bin/bbmerge.sh")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("bbtools conda environment is not installed")
        }
        return candidate
    }
}

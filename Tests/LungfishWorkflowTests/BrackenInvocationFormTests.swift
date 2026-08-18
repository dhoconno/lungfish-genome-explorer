// BrackenInvocationFormTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Unit coverage for Bracken CLI dialect detection, kmer-distribution
// resolution, and argument construction. These run with no conda install: the
// usage strings are fixtures captured from the two real CLI forms, and the
// directory listing is injected.

import XCTest
@testable import LungfishWorkflow

final class BrackenInvocationFormTests: XCTestCase {

    // MARK: - Fixtures

    /// Verbatim `bracken --help` output from `bioconda::bracken=1.0.0=1`, whose
    /// `bin/bracken` is `exec python est_abundance.py "$@"`.
    private static let wrapperUsage = """
        usage: est_abundance.py [-h] -i INPUT -k KMER_DISTR -o OUTPUT
                                [-l {K,P,C,O,F,G,S}] [-t THRESH]

        options:
          -h, --help            show this help message and exit
          -i, --input INPUT     Input kraken report file.
          -k, --kmer_distr KMER_DISTR
                                Kmer distribution file.
          -o, --output OUTPUT   Output modified kraken report file with abundance
                                estimates
          -l, --level {K,P,C,O,F,G,S}
                                Level to push all reads to.
          -t, --thresh, --threshold THRESH
                                Threshold for the minimum number of reads kraken must
                                assign to a classification for that classification to
                                be considered in the final abundance estimation.
        """

    /// Representative `bracken -h` output from the real Bracken 2.x/3.x driver.
    private static let realDriverUsage = """
        Usage: bracken -d MY_DB -i INPUT.kreport -o OUTPUT.bracken -r READ_LEN -l LEVEL -t THRESHOLD
          MY_DB          location of Kraken database
          INPUT.kreport  Kraken REPORT file
          OUTPUT.bracken file name for Bracken default output
          READ_LEN       read length to get all classifications for
          LEVEL          level to estimate abundance at [options: D,P,C,O,F,G,S]
          THRESHOLD      number of reads required PRIOR to abundance estimation
        """

    // MARK: - Dialect detection

    func testWrapperUsageDetectsKmerDistributionDialect() {
        XCTAssertEqual(BrackenInvocation.dialect(fromHelpText: Self.wrapperUsage), .kmerDistribution)
    }

    func testRealDriverUsageDetectsDatabaseDialect() {
        XCTAssertEqual(BrackenInvocation.dialect(fromHelpText: Self.realDriverUsage), .database)
    }

    /// A usage text naming the inner script wins even if `-d` appears elsewhere:
    /// the wrapper is the authority on its own CLI.
    func testInnerScriptNameWinsOverStrayDatabaseFlag() {
        let text = "usage: est_abundance.py [-h] -i INPUT -k KMER_DISTR\n  see also -d in bracken 3"
        XCTAssertEqual(BrackenInvocation.dialect(fromHelpText: text), .kmerDistribution)
    }

    /// Empty or unreadable help (probe failed) must not be assumed to accept `-d`.
    func testEmptyHelpFallsBackToWrapperDialect() {
        XCTAssertEqual(BrackenInvocation.dialect(fromHelpText: ""), .kmerDistribution)
    }

    /// `-d` must be matched as a whole token, not inside a longer flag.
    func testLongerFlagsDoNotCountAsDatabaseFlag() {
        XCTAssertEqual(BrackenInvocation.dialect(fromHelpText: "Usage: tool --dbstats -db2 -i IN"), .kmerDistribution)
        XCTAssertEqual(BrackenInvocation.dialect(fromHelpText: "Usage: tool --db PATH -i IN"), .database)
    }

    // MARK: - Kmer distribution resolution

    private let viralDistributions = [
        "database50mers.kmer_distrib", "database75mers.kmer_distrib",
        "database100mers.kmer_distrib", "database150mers.kmer_distrib",
        "database200mers.kmer_distrib", "database250mers.kmer_distrib",
        "database300mers.kmer_distrib",
    ]

    func testExactReadLengthIsPreferred() throws {
        let resolution = try BrackenInvocation.resolveKmerDistribution(
            databasePath: URL(fileURLWithPath: "/db"),
            readLength: 150,
            availableFilenames: viralDistributions
        )
        XCTAssertEqual(resolution.url.lastPathComponent, "database150mers.kmer_distrib")
        XCTAssertEqual(resolution.readLength, 150)
        XCTAssertFalse(resolution.isSubstituted)
    }

    func testNearestReadLengthIsSubstitutedWhenExactIsMissing() throws {
        let resolution = try BrackenInvocation.resolveKmerDistribution(
            databasePath: URL(fileURLWithPath: "/db"),
            readLength: 120,
            availableFilenames: viralDistributions
        )
        // 120 is 20 from 100 and 30 from 150, so 100 wins.
        XCTAssertEqual(resolution.url.lastPathComponent, "database100mers.kmer_distrib")
        XCTAssertEqual(resolution.readLength, 100)
        XCTAssertTrue(resolution.isSubstituted)
        XCTAssertEqual(resolution.requestedReadLength, 120)
    }

    /// An exact tie breaks toward the larger N so the substitution is never
    /// needlessly coarser than an equally distant alternative.
    func testEquidistantReadLengthsBreakTowardLargerN() throws {
        let resolution = try BrackenInvocation.resolveKmerDistribution(
            databasePath: URL(fileURLWithPath: "/db"),
            readLength: 125,
            availableFilenames: viralDistributions
        )
        XCTAssertEqual(resolution.readLength, 150)
    }

    func testMissingDistributionThrowsActionableErrorNamingTheDatabase() {
        XCTAssertThrowsError(
            try BrackenInvocation.resolveKmerDistribution(
                databasePath: URL(fileURLWithPath: "/db/viral"),
                readLength: 150,
                availableFilenames: ["hash.k2d", "taxo.k2d", "opts.k2d"]
            )
        ) { error in
            guard case BrackenInvocationError.noKmerDistribution(let path, let requested) =
                    error as? BrackenInvocationError ?? .noKmerDistribution(databasePath: "", requestedReadLength: 0)
            else {
                return XCTFail("expected noKmerDistribution, got \(error)")
            }
            XCTAssertEqual(path, "/db/viral")
            XCTAssertEqual(requested, 150)
            let message = (error as? BrackenInvocationError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("/db/viral"), "error must name the database path: \(message)")
            XCTAssertTrue(message.contains("bracken-build"), "error must be actionable: \(message)")
        }
    }

    // MARK: - Filename parsing

    func testDistributionFilenameParsing() {
        XCTAssertEqual(BrackenInvocation.readLength(fromDistributionFilename: "database150mers.kmer_distrib"), 150)
        XCTAssertNil(BrackenInvocation.readLength(fromDistributionFilename: "hash.k2d"))
        XCTAssertNil(BrackenInvocation.readLength(fromDistributionFilename: "databasemers.kmer_distrib"))
        XCTAssertNil(BrackenInvocation.readLength(fromDistributionFilename: "databaseXYZmers.kmer_distrib"))
        XCTAssertNil(BrackenInvocation.readLength(fromDistributionFilename: "database-1mers.kmer_distrib"))
        XCTAssertEqual(BrackenInvocation.distributionFilename(readLength: 75), "database75mers.kmer_distrib")
    }

    // MARK: - Argument construction

    func testDatabaseDialectKeepsTheHistoricalArgumentForm() {
        let args = BrackenInvocation.arguments(
            dialect: .database,
            databasePath: URL(fileURLWithPath: "/db"),
            distributionURL: URL(fileURLWithPath: "/db/database150mers.kmer_distrib"),
            reportURL: URL(fileURLWithPath: "/out/r.kreport"),
            outputURL: URL(fileURLWithPath: "/out/r.bracken"),
            readLength: 150,
            levelCode: "S",
            threshold: 10
        )
        XCTAssertEqual(
            args,
            ["-d", "/db", "-i", "/out/r.kreport", "-o", "/out/r.bracken", "-r", "150", "-l", "S", "-t", "10"]
        )
    }

    func testWrapperDialectUsesKmerDistributionAndOmitsDatabaseAndReadLength() {
        let args = BrackenInvocation.arguments(
            dialect: .kmerDistribution,
            databasePath: URL(fileURLWithPath: "/db"),
            distributionURL: URL(fileURLWithPath: "/db/database150mers.kmer_distrib"),
            reportURL: URL(fileURLWithPath: "/out/r.kreport"),
            outputURL: URL(fileURLWithPath: "/out/r.bracken"),
            readLength: 150,
            levelCode: "S",
            threshold: 10
        )
        XCTAssertEqual(
            args,
            ["-i", "/out/r.kreport", "-k", "/db/database150mers.kmer_distrib",
             "-o", "/out/r.bracken", "-l", "S", "-t", "10"]
        )
        XCTAssertFalse(args.contains("-d"), "the passthrough wrapper has no -d and errors when given one")
        XCTAssertFalse(args.contains("-r"), "read length is already baked into the -k distribution file")
    }

    // MARK: - Known upstream crash signature

    func testUnclassifiedReadsCrashIsRecognised() {
        let stderr = """
            Traceback (most recent call last):
              File "/env/bin/est_abundance.py", line 456, in <module>
                main()
              File "/env/bin/est_abundance.py", line 381, in main
                print("\\t  >> Unclassified reads: %i" % u_reads)
            UnboundLocalError: cannot access local variable 'u_reads' where it is not associated with a value
            """
        XCTAssertTrue(BrackenInvocation.isUnclassifiedReadsCrash(stderr: stderr))
    }

    func testOtherCrashesAreNotMistakenForTheKnownSignature() {
        XCTAssertFalse(BrackenInvocation.isUnclassifiedReadsCrash(stderr: ""))
        XCTAssertFalse(BrackenInvocation.isUnclassifiedReadsCrash(
            stderr: "UnboundLocalError: cannot access local variable 'total_reads'"
        ))
        XCTAssertFalse(BrackenInvocation.isUnclassifiedReadsCrash(
            stderr: "AttributeError: 'int' object has no attribute 'children'"
        ))
    }
}

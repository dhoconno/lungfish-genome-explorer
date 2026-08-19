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

    // MARK: - Level support

    /// The real driver accepts every rank the app can resolve, including `D`.
    func testDatabaseDialectSupportsEveryResolvableLevel() {
        for code in ["D", "K", "P", "C", "O", "F", "G", "S"] {
            XCTAssertTrue(BrackenInvocation.supportsLevelCode(code, dialect: .database), code)
            XCTAssertNil(
                BrackenInvocation.unsupportedLevelDiagnostic(
                    levelCode: code, rankDisplayName: "rank", dialect: .database
                )
            )
        }
    }

    /// `est_abundance.py`'s argparse choices are K,P,C,O,F,G,S: everything the
    /// real driver takes except `D`.
    func testWrapperDialectSupportsEveryLevelExceptDomain() {
        for code in ["K", "P", "C", "O", "F", "G", "S"] {
            XCTAssertTrue(BrackenInvocation.supportsLevelCode(code, dialect: .kmerDistribution), code)
        }
        XCTAssertFalse(BrackenInvocation.supportsLevelCode("D", dialect: .kmerDistribution))
    }

    /// Domain must degrade with an explanatory diagnostic rather than being
    /// rewritten to kingdom. `D` and `K` are distinct ranks in both Kraken2
    /// reports and est_abundance.py's own level list, and a single report
    /// commonly carries both -- on the shared SARS-CoV-2 fixture `D` is Viruses
    /// (10239) while `K` is Orthornavirae (2732396), so a silent substitution
    /// would profile a different taxon and label it as the requested domain.
    func testDomainIsRejectedRatherThanRewrittenToKingdom() throws {
        let diagnostic = try XCTUnwrap(
            BrackenInvocation.unsupportedLevelDiagnostic(
                levelCode: "D", rankDisplayName: "Domain", dialect: .kmerDistribution
            )
        )
        XCTAssertTrue(diagnostic.contains("D"), diagnostic)
        XCTAssertTrue(diagnostic.contains("Domain"), diagnostic)
        XCTAssertTrue(
            diagnostic.contains("K, O"),
            "diagnostic should list the accepted codes: \(diagnostic)"
        )

        // The argument builder must never emit a translated level: whatever the
        // caller passes is what runs, so an unsupported rank has to be caught by
        // the preflight rather than quietly rewritten here.
        let args = BrackenInvocation.arguments(
            dialect: .kmerDistribution,
            databasePath: URL(fileURLWithPath: "/db"),
            distributionURL: URL(fileURLWithPath: "/db/database150mers.kmer_distrib"),
            reportURL: URL(fileURLWithPath: "/out/r.kreport"),
            outputURL: URL(fileURLWithPath: "/out/r.bracken"),
            readLength: 150,
            levelCode: "G",
            threshold: 10
        )
        XCTAssertEqual(args[args.firstIndex(of: "-l")! + 1], "G")
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

    // MARK: - Provenance argv rendering

    /// A space-joined argv is ambiguous exactly where it matters: a database path containing
    /// a space reads as two arguments, so the recorded command is not the command that ran.
    func testProvenanceArgvQuotesArgumentsContainingSpaces() {
        let rendered = ClassificationPipeline.shellQuotedArgv([
            "bracken",
            "-d", "/Volumes/My Drive/kraken2/viral",
            "-r", "150",
        ])

        XCTAssertEqual(rendered, "bracken -d '/Volumes/My Drive/kraken2/viral' -r 150")
    }

    func testProvenanceArgvLeavesPlainArgumentsUnquoted() {
        XCTAssertEqual(
            ClassificationPipeline.shellQuotedArgv(["bracken", "-d", "/tmp/viral", "-l", "S"]),
            "bracken -d /tmp/viral -l S"
        )
    }

    /// An embedded single quote uses the standard `'\''` escape, so the rendered string can be
    /// pasted back into a shell and yield the same argument.
    func testProvenanceArgvEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(
            ClassificationPipeline.shellQuotedArgv(["/tmp/dave's db"]),
            #"'/tmp/dave'\''s db'"#
        )
    }

    // MARK: - Substituted read length

    /// A completed profile can carry a note, which is how the nearest-read-length
    /// substitution reaches the user instead of living only in the system log.
    func testCompletedOutcomeCarriesASubstitutionMessage() {
        let resolution = BrackenProfileResolution(
            request: .automatic,
            rank: .species,
            source: .compatibilityDefault,
            readLength: 100,
            threshold: 10
        )
        let outcome = BrackenProfileOutcome.completed(
            resolution: resolution,
            toolVersion: "3.1",
            message: "used the nearest available read length 150"
        )

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.message, "used the nearest available read length 150")
        XCTAssertNil(BrackenProfileOutcome.completed(resolution: resolution).message)
    }
}

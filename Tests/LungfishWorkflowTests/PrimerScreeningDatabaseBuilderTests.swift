import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimerScreeningDatabaseBuilderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeFASTA(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Source classification

    func testClassifiesFASTAReferenceBundleAndRejectsOtherDocuments() throws {
        let fasta = try writeFASTA("panel.fasta", ">a\nACGT\n")
        XCTAssertEqual(PrimerScreeningSource.classify(fasta)?.kind, .fasta)
        for accepted in ["fa", "fna", "ffn", "frn", "fas"] {
            let url = try writeFASTA("panel." + accepted, ">a\nACGT\n")
            XCTAssertEqual(PrimerScreeningSource.classify(url)?.kind, .fasta, accepted)
        }
        // A BAM or a database prefix is not a sequence source the user can screen against.
        for rejected in ["reads.bam", "screen.nin", "notes.txt"] {
            let url = try writeFASTA(rejected, "x")
            XCTAssertNil(PrimerScreeningSource.classify(url), rejected)
        }
    }

    func testDisplayNameDropsTheBundleExtension() {
        let source = PrimerScreeningSource(
            url: URL(fileURLWithPath: "/p/Reference Sequences/mamu-class-i-exclusion.lungfishref"),
            kind: .referenceBundle)
        XCTAssertEqual(source.displayName, "mamu-class-i-exclusion")
    }

    // MARK: - FASTA assembly

    func testUngappingStripsAlignmentGapsAndConvertsUracil() {
        XCTAssertEqual(PrimerScreeningDatabaseBuilder.ungapped("ac-g.t"), "ACGT")
        XCTAssertEqual(PrimerScreeningDatabaseBuilder.ungapped("ACGU"), "ACGT")
        XCTAssertEqual(PrimerScreeningDatabaseBuilder.ungapped("AC GT\t"), "ACGT")
    }

    /// BLAST truncates a defline at the first space, so the identifier must be one
    /// whitespace-free token, and it must never be cut inside that token.
    func testSanitizedTitleKeepsTheWholeFirstTokenWithoutTruncation() {
        let source = PrimerScreeningSource(url: URL(fileURLWithPath: "/p/x.fasta"), kind: .fasta)
        let header = "Mamu-A1_004_01_longer_than_twenty_four_characters description here"
        let title = PrimerScreeningDatabaseBuilder.sanitizedTitle(header, source: source)
        XCTAssertEqual(title, "Mamu-A1_004_01_longer_than_twenty_four_characters")
        XCTAssertFalse(title.contains(" "))
        // An accession with pipes and colons stays intact; BLAST carries those.
        XCTAssertEqual(
            PrimerScreeningDatabaseBuilder.sanitizedTitle("gi|123|ref|NC_045512.2|", source: source),
            "gi|123|ref|NC_045512.2|")
        // A header with no usable token falls back to the document name.
        XCTAssertEqual(PrimerScreeningDatabaseBuilder.sanitizedTitle("   ", source: source), "x")
    }

    func testCombinedFASTAUngapsAlignmentRowsAndRecordsEverySequence() throws {
        let aligned = try writeFASTA("rows.fasta", ">row-a\nAC-GT\n>row-b\nACGGT\n")
        let sources = [PrimerScreeningSource(url: aligned, kind: .fasta)]
        let (text, records) = try PrimerScreeningDatabaseBuilder.combinedFASTA(sources: sources)
        XCTAssertEqual(text, ">row-a\nACGT\n>row-b\nACGGT\n")
        XCTAssertEqual(records.map(\.title), ["row-a", "row-b"])
        XCTAssertEqual(records.map(\.length), [4, 5])
        XCTAssertEqual(records.map(\.sourcePath), [aligned.path, aligned.path])
        XCTAssertTrue(records.allSatisfy { $0.sha256.count == 64 })
    }

    /// Screening FASTA rows need not be equal length: a screening set is a pile of
    /// real sequences, not an alignment.
    func testCombinedFASTAAcceptsUnequalLengthRecords() throws {
        let url = try writeFASTA("mixed.fasta", ">short\nACGT\n>long\nACGTACGTACGT\n")
        let (_, records) = try PrimerScreeningDatabaseBuilder.combinedFASTA(
            sources: [.init(url: url, kind: .fasta)])
        XCTAssertEqual(records.map(\.length), [4, 12])
    }

    func testCombinedFASTARejectsDuplicateTitlesAndEmptySources() throws {
        let duplicate = try writeFASTA("dup.fasta", ">same\nACGT\n>same\nTTTT\n")
        XCTAssertThrowsError(try PrimerScreeningDatabaseBuilder.combinedFASTA(
            sources: [.init(url: duplicate, kind: .fasta)])) { error in
            XCTAssertEqual(error as? PrimerScreeningDatabaseError, .duplicateTitle("same"))
        }
        let empty = try writeFASTA("empty.fasta", "\n")
        XCTAssertThrowsError(try PrimerScreeningDatabaseBuilder.combinedFASTA(
            sources: [.init(url: empty, kind: .fasta)])) { error in
            XCTAssertEqual(error as? PrimerScreeningDatabaseError, .emptySource("empty"))
        }
    }

    // MARK: - Build contract

    func testBuildRefusesAWhitespaceStagingRootBecauseBLASTCannotReadIt() async throws {
        let source = try writeFASTA("panel.fasta", ">a\nACGT\n")
        let builder = PrimerScreeningDatabaseBuilder(
            resolveExecutable: { URL(fileURLWithPath: "/bin/echo") },
            run: { _, _, _ in (0, "", []) }, readVersion: { _ in "test" })
        do {
            _ = try await builder.build(
                sources: [.init(url: source, kind: .fasta)],
                stagingRoot: root.appendingPathComponent("has space", isDirectory: true))
            XCTFail("expected a whitespace refusal")
        } catch let error as PrimerScreeningDatabaseError {
            guard case .buildFailed(let reason) = error else { return XCTFail("wrong case") }
            XCTAssertTrue(reason.contains("whitespace"), reason)
        }
    }

    func testBuildRefusesAnEmptySourceList() async throws {
        let builder = PrimerScreeningDatabaseBuilder(
            resolveExecutable: { URL(fileURLWithPath: "/bin/echo") },
            run: { _, _, _ in (0, "", []) }, readVersion: { _ in "test" })
        do {
            _ = try await builder.build(sources: [], stagingRoot: root.appendingPathComponent("db"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PrimerScreeningDatabaseError, .noSources)
        }
    }

    /// The argv must name the generated FASTA and the prefix inside the staging
    /// root, because those are the paths provenance replays.
    func testBuildPassesTheGeneratedFASTAAndPrefixToMakeblastdb() async throws {
        let source = try writeFASTA("panel.fasta", ">a\nACGT\n>b\nTTTT\n")
        let staging = root.appendingPathComponent("db", isDirectory: true)
        let captured = CapturedInvocation()
        let builder = PrimerScreeningDatabaseBuilder(
            resolveExecutable: { URL(fileURLWithPath: "/opt/env/bin/makeblastdb") },
            run: { executable, arguments, workingDirectory in
                await captured.record(executable: executable, arguments: arguments,
                                      workingDirectory: workingDirectory)
                // Stand in for the real tool by writing the required components.
                let prefix = arguments[arguments.firstIndex(of: "-out")! + 1]
                for suffix in ["nhr", "nin", "nsq"] {
                    try Data("x".utf8).write(to: URL(fileURLWithPath: prefix + "." + suffix))
                }
                return (0, "", [executable.path] + arguments)
            },
            readVersion: { _ in "makeblastdb: 2.17.0+" })
        let database = try await builder.build(
            sources: [.init(url: source, kind: .fasta)], stagingRoot: staging)

        let arguments = await captured.arguments
        let executableName = await captured.executable?.lastPathComponent
        XCTAssertEqual(executableName, "makeblastdb")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-dbtype")! + 1], "nucl")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-in")! + 1], database.fastaURL.path)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-out")! + 1], database.prefix)
        XCTAssertTrue(database.prefix.hasPrefix(staging.path + "/"), database.prefix)
        XCTAssertEqual(database.records.map(\.title), ["a", "b"])
        XCTAssertEqual(database.makeblastdbVersion, "makeblastdb: 2.17.0+")
        XCTAssertEqual(try String(contentsOf: database.fastaURL, encoding: .utf8), ">a\nACGT\n>b\nTTTT\n")
    }

    func testBuildFailsWhenMakeblastdbWritesNoDatabaseComponents() async throws {
        let source = try writeFASTA("panel.fasta", ">a\nACGT\n")
        let builder = PrimerScreeningDatabaseBuilder(
            resolveExecutable: { URL(fileURLWithPath: "/opt/env/bin/makeblastdb") },
            run: { executable, arguments, _ in (0, "", [executable.path] + arguments) },
            readVersion: { _ in "test" })
        do {
            _ = try await builder.build(sources: [.init(url: source, kind: .fasta)],
                                        stagingRoot: root.appendingPathComponent("db"))
            XCTFail("expected a missing-component failure")
        } catch let error as PrimerScreeningDatabaseError {
            guard case .buildFailed(let reason) = error else { return XCTFail("wrong case") }
            XCTAssertTrue(reason.contains(".nhr"), reason)
        }
    }

    func testBuildSurfacesTheToolDiagnosticOnFailure() async throws {
        let source = try writeFASTA("panel.fasta", ">a\nACGT\n")
        let builder = PrimerScreeningDatabaseBuilder(
            resolveExecutable: { URL(fileURLWithPath: "/opt/env/bin/makeblastdb") },
            run: { _, _, _ in (1, "BLAST options error: File does not exist\n", []) },
            readVersion: { _ in "test" })
        do {
            _ = try await builder.build(sources: [.init(url: source, kind: .fasta)],
                                        stagingRoot: root.appendingPathComponent("db"))
            XCTFail("expected a build failure")
        } catch let error as PrimerScreeningDatabaseError {
            guard case .buildFailed(let reason) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(reason, "BLAST options error: File does not exist")
        }
    }

    func testExecutableResolutionRequiresMakeblastdbInTheEnvironment() throws {
        let prefix = root.appendingPathComponent("env", isDirectory: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try PrimerScreeningDatabaseBuilder.executable(inEnvironmentPrefix: prefix))
        let tool = prefix.appendingPathComponent("bin/makeblastdb")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertEqual(
            try PrimerScreeningDatabaseBuilder.executable(inEnvironmentPrefix: prefix).path, tool.path)
    }

    // MARK: - Provenance

    func testProvenanceNamesTheScreenedSequencesAndTheBuildCommand() throws {
        let source = PrimerScreeningSource(
            url: URL(fileURLWithPath: "/p/Reference Sequences/exclusion.lungfishref"),
            kind: .referenceBundle)
        let database = PrimerScreeningDatabase(
            prefix: "/tmp/lge/screening-db",
            fastaURL: URL(fileURLWithPath: "/tmp/lge/screening-sources.fasta"),
            records: [.init(sourcePath: source.url.path, sourceKind: "referenceBundle",
                            title: "exclusion-1", length: 120, sha256: String(repeating: "a", count: 64))],
            makeblastdbArgv: ["/opt/env/bin/makeblastdb", "-in", "/tmp/lge/screening-sources.fasta"],
            makeblastdbVersion: "makeblastdb: 2.17.0+", sources: [source])
        let options = database.provenanceOptions
        XCTAssertEqual(options["screeningSourcePaths"], .array([.string(source.url.path)]))
        XCTAssertEqual(options["screeningSourceKinds"], .array([.string("referenceBundle")]))
        XCTAssertEqual(options["screeningSequenceCount"], .integer(1))
        XCTAssertEqual(options["screeningDatabaseBuiltByLGE"], .boolean(true))
        XCTAssertEqual(options["screeningDatabaseToolVersion"], .string("makeblastdb: 2.17.0+"))
        guard case .string(let json)? = options["screeningSequencesJSON"] else {
            return XCTFail("screened sequences must be recorded")
        }
        XCTAssertTrue(json.contains("exclusion-1"), json)
    }
}

/// Collects one invocation from the `@Sendable` runner closure.
private actor CapturedInvocation {
    private(set) var executable: URL?
    private(set) var arguments: [String] = []
    private(set) var workingDirectory: URL?

    func record(executable: URL, arguments: [String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

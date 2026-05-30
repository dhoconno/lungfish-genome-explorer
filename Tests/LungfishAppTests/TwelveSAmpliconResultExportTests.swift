import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

final class TwelveSAmpliconResultExportTests: XCTestCase {
    func testCSVExportInvokesCLIWithVisibleFiltersAndRequiresProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("hilo-12s.csv")
        let runner = StubTwelveSExportCLIRunner(writesOutput: true, writesProvenance: true)
        let snapshot = try makeSnapshot(in: root)

        let result = try TwelveSAmpliconResultExportService(runner: runner).export(
            snapshot: snapshot,
            format: .csv,
            to: outputURL
        )

        XCTAssertEqual(result.outputURL, outputURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))
        XCTAssertEqual(runner.invocations.count, 1)
        let arguments = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(arguments.prefix(2), ["fastq", "12s-export"])
        XCTAssertEqual(try value(after: "--bundle", in: arguments), snapshot.bundleURL.path)
        XCTAssertEqual(try value(after: "--export-format", in: arguments), "csv")
        XCTAssertEqual(try value(after: "--output", in: arguments), outputURL.path)
        XCTAssertEqual(try value(after: "--min-exact-reads", in: arguments), "10")
        XCTAssertEqual(try value(after: "--filter", in: arguments), "homo")
        XCTAssertEqual(try value(after: "--taxon-group", in: arguments), "Mammal")
        XCTAssertEqual(try value(after: "--exclude-taxon-group", in: arguments), "Fish")
        XCTAssertTrue(arguments.contains("--exclude-human"))
        XCTAssertTrue(arguments.contains("--require-alternate-matches"))
        XCTAssertEqual(try value(after: "--min-unresolved-reads", in: arguments), "5")
        XCTAssertEqual(try value(after: "--chimera-status", in: arguments), "candidate")
        XCTAssertTrue(arguments.contains("--force"))
    }

    func testExportFailsIfCLIOmitsProvenanceSidecar() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("hilo-12s.tsv")
        let runner = StubTwelveSExportCLIRunner(writesOutput: true, writesProvenance: false)

        XCTAssertThrowsError(
            try TwelveSAmpliconResultExportService(runner: runner).export(
                snapshot: makeSnapshot(in: root),
                format: .tsv,
                to: outputURL
            )
        ) { error in
            XCTAssertEqual(
                error as? TwelveSAmpliconResultExportError,
                .missingProvenance(outputURL.appendingPathExtension("lungfish-provenance.json").path)
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSCLIExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSnapshot(in root: URL) throws -> TwelveSAmpliconResultExportSnapshot {
        let bundleURL = root.appendingPathComponent("hilo-12s.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return TwelveSAmpliconResultExportSnapshot(
            bundleURL: bundleURL,
            analysisName: "hilo-12s",
            sampleNames: ["SampleA", "Blank"],
            filters: TwelveSResultDisplayState(
                minimumExactReads: 10,
                filterText: "homo",
                includedTaxonGroups: ["Mammal"],
                excludedTaxonGroups: ["Fish"],
                excludeHuman: true,
                requireAlternateMatches: true,
                minimumUnresolvedReads: 5,
                chimeraFilter: .candidate
            ),
            rows: [],
            unresolvedRows: []
        )
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(
                domain: "TwelveSAmpliconResultExportTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"]
            )
        }
        return arguments[arguments.index(after: index)]
    }
}

private final class StubTwelveSExportCLIRunner: TwelveSAmpliconResultExportRunning {
    private(set) var invocations: [[String]] = []
    let writesOutput: Bool
    let writesProvenance: Bool

    init(writesOutput: Bool, writesProvenance: Bool) {
        self.writesOutput = writesOutput
        self.writesProvenance = writesProvenance
    }

    func run(arguments: [String]) throws -> LungfishCLIRunner.Output {
        invocations.append(arguments)
        let outputURL = URL(fileURLWithPath: try value(after: "--output", in: arguments))
        if writesOutput {
            try Data("scientific_name,total_exact_reads\n".utf8).write(to: outputURL)
        }
        if writesProvenance {
            let argv = ["lungfish-cli"] + arguments
            let envelope = try ProvenanceRunBuilder(
                workflowName: "lungfish fastq 12s-export",
                workflowVersion: "test",
                toolName: "lungfish-cli",
                toolVersion: "test"
            )
            .argv(argv)
            .durableReplayArgv(argv)
            .reproducibleCommand(argv.joined(separator: " "))
            .output(outputURL, format: .text, role: .report)
            .runtime(ProvenanceRuntimeIdentity(user: "test"))
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
            try ProvenanceWriter(signingProvider: nil).write(
                envelope,
                toSidecar: outputURL.appendingPathExtension("lungfish-provenance.json")
            )
        }
        return LungfishCLIRunner.Output(stdout: "", stderr: "", status: 0)
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(
                domain: "StubTwelveSExportCLIRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"]
            )
        }
        return arguments[arguments.index(after: index)]
    }
}

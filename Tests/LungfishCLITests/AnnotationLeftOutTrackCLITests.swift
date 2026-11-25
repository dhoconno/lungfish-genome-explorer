// AnnotationLeftOutTrackCLITests.swift - The CLI routes that write annotations name each track they could not read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-MISSING-TRACK (S1, BIO-EXPORT-MISSING-TRACK-17 rows 1 to 3). A bundle's manifest can list an
// annotation track whose database is missing. `bundle export-gff3`, `convert --include-annotations` and
// `extract sequence --bundle` wrote the other tracks' features with no word of the one left out. Each now still
// writes the other tracks and names the missing one in its completion message on standard output, in one standard
// error line per track and in its record as `left_out_tracks`. The built lungfish-cli runs each route, and the
// extraction runs against a stand-in bgzip and samtools, so no real tool and no network are needed.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class AnnotationLeftOutTrackCLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "annotation-left-out-track")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Row 1, bundle export-gff3

    func testGFF3ExportOfABundleWithOneMissingDatabaseWritesTheOtherTracksAndNamesTheMissingOne() throws {
        let bundle = try Self.makeBundle(in: root, removing: ["track-c"])
        let output = root.appendingPathComponent("NG-4tracks.gff3")

        let run = try runCLI(["bundle", "export-gff3", bundle.path, "-o", output.path])

        XCTAssertEqual(run.status, 0, "the export still writes. \(run.stdout) \(run.stderr)")
        let text = try String(contentsOf: output, encoding: .utf8)
        for gene in ["geneA", "geneB", "geneD"] {
            XCTAssertTrue(text.contains("Name=\(gene)") || text.contains("=\(gene)"), "the file holds \(gene)")
        }
        XCTAssertFalse(text.contains("geneC"), "the missing track's gene cannot be in the file")
        XCTAssertTrue(run.stdout.contains("two-parent c"), "the completion message names the missing track. \(run.stdout)")
        XCTAssertTrue(
            run.stderr.contains("two-parent c: its annotation database is missing or cannot be read"),
            "one standard error line names the missing track. \(run.stderr)"
        )
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(envelope.options.resolvedDefaults["left_out_tracks"], .array([.string("two-parent c")]))
    }

    /// BIO item 6. With every database missing the export refuses, and its words say why instead of "has no
    /// annotations to export".
    func testGFF3ExportOfABundleWithEveryDatabaseMissingRefusesAndNamesEachTrack() throws {
        let bundle = try Self.makeBundle(in: root, removing: Set(Self.tracks.map(\.id)))
        let output = root.appendingPathComponent("none.gff3")

        let run = try runCLI(["bundle", "export-gff3", bundle.path, "-o", output.path])

        XCTAssertNotEqual(run.status, 0, "nothing can be written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let words = run.stdout + run.stderr
        XCTAssertFalse(words.contains("has no annotations to export"), "the bundle has annotations. \(words)")
        for track in Self.tracks {
            XCTAssertTrue(words.contains(track.name), "the refusal names \(track.name). \(words)")
        }
    }

    // MARK: - Row 2, convert --include-annotations

    func testGenBankConvertOfABundleWithOneMissingDatabaseWritesTheOtherTracksAndNamesTheMissingOne() async throws {
        let bundle = try Self.makeBundle(in: root, removing: ["track-c"])
        let output = root.appendingPathComponent("NG-4tracks.gb")

        let run = try runCLI([
            "convert", bundle.path, "--to", output.path, "--to-format", "genbank", "--include-annotations",
        ])

        XCTAssertEqual(run.status, 0, "the conversion still writes. \(run.stdout) \(run.stderr)")
        let records = try await GenBankReader(url: output).readAll()
        XCTAssertEqual(records.flatMap(\.annotations).count, 3, "the file holds the gene of each track that was read")
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(["geneA", "geneB", "geneD"].allSatisfy(text.contains), "the file holds the other tracks' genes")
        XCTAssertFalse(text.contains("geneC"), "the missing track's gene cannot be in the file")
        XCTAssertTrue(run.stdout.contains("two-parent c"), "the completion message names the missing track. \(run.stdout)")
        XCTAssertTrue(
            run.stderr.contains("two-parent c: its annotation database is missing or cannot be read"),
            "one standard error line names the missing track. \(run.stderr)"
        )
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(envelope.options.resolvedDefaults["left_out_tracks"], .array([.string("two-parent c")]))
    }

    // MARK: - Row 3, extract sequence --bundle

    func testRegionBundleOfABundleWithOneMissingDatabaseKeepsTheOtherTracksAndNamesTheMissingOne() throws {
        let bundle = try Self.makeBundle(in: root, removing: ["track-c"])
        let output = root.appendingPathComponent("Extractions/Whole.lungfishref", isDirectory: true)

        let run = try runCLI(
            ["extract", "sequence", bundle.path, "chr1:1-60", "--bundle", "--output", output.path],
            environment: ["LUNGFISH_CONDA_ROOT": try stubCondaRoot().path]
        )

        XCTAssertEqual(run.status, 0, "the extraction still writes. \(run.stdout) \(run.stderr)")
        let manifest = try BundleManifest.load(from: output)
        XCTAssertEqual(manifest.annotations.map(\.name), ["genes a", "genes b", "genes d"], "the other tracks are kept")
        XCTAssertTrue(run.stdout.contains("two-parent c"), "the completion message names the missing track. \(run.stdout)")
        XCTAssertTrue(
            run.stderr.contains("two-parent c: its annotation database is missing or cannot be read"),
            "one standard error line names the missing track. \(run.stderr)"
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: output.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["left_out_tracks"], .array([.string("two-parent c")]))
    }

    // MARK: - ANNOT-EXPORT-3, convert to FASTA and the extraction's JSON event

    /// BIO and UX review SF-2. A FASTA file never holds annotations, so no track is missing from it. The app adds
    /// `--include-annotations` to every bundle export, so `convert` reads the databases for a FASTA export too, and it
    /// must not word the missing track as a loss in its message, on standard error, in its record or in its JSON.
    func testConvertToFastaOfABundleWithAMissingDatabaseAddsNoLeftOutWords() throws {
        let bundle = try Self.makeBundle(in: root, removing: ["track-c"])
        let output = root.appendingPathComponent("NG-4tracks.fa")

        let run = try runCLI(["convert", bundle.path, "--to", output.path, "--to-format", "fasta", "--include-annotations"])

        XCTAssertEqual(run.status, 0, "\(run.stdout) \(run.stderr)")
        XCTAssertFalse(run.stdout.contains("annotation track"), "a FASTA file holds no annotations. \(run.stdout)")
        XCTAssertFalse(run.stderr.contains("warning:"), "no track is missing from a FASTA file. \(run.stderr)")
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertNil(envelope.options.resolvedDefaults["left_out_tracks"], "the record writes no left-out key")

        let json = try runCLI([
            "convert", bundle.path, "--to", output.path, "--to-format", "fasta", "--include-annotations",
            "--force", "--format", "json", "--quiet",
        ])
        XCTAssertEqual(json.status, 0, "\(json.stdout) \(json.stderr)")
        XCTAssertFalse(json.stdout.contains("leftOutTracks"), "the JSON has no left-out field. \(json.stdout)")
    }

    /// SWIFT and ARCH review SF-2 (c). The app's extraction row shows the `complete` event's message, so the event
    /// stream of `extract sequence --bundle --format json` has to name the missing track and say to extract again
    /// (BIO and UX review SF-3).
    func testRegionBundleJSONCompleteEventNamesTheMissingTrack() throws {
        let bundle = try Self.makeBundle(in: root, removing: ["track-c"])
        let output = root.appendingPathComponent("Extractions/Json.lungfishref", isDirectory: true)

        let run = try runCLI(
            ["extract", "sequence", bundle.path, "chr1:1-60", "--bundle", "--output", output.path, "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": try stubCondaRoot().path]
        )

        XCTAssertEqual(run.status, 0, "the extraction still writes. \(run.stdout) \(run.stderr)")
        let messages = run.stdout.split(separator: "\n").compactMap { line -> String? in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["message"] as? String
        }
        // The run also reports "Bundle ready: <name>" as progress, so the complete event is the one with the period.
        let complete = try XCTUnwrap(messages.first { $0.hasPrefix("Bundle ready.") }, "the complete event carries words. \(run.stdout)")
        XCTAssertTrue(complete.contains("two-parent c"), "the complete event names the missing track. \(complete)")
        XCTAssertTrue(complete.contains("Reopen the bundle"), complete)
        XCTAssertTrue(complete.hasSuffix("Then extract again."), "the words tell the person to extract again. \(complete)")
    }

    // MARK: - Fixture

    /// 60 bases of `chr1`.
    static let sequence = "ACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT"

    /// The four tracks of the walk's `NG-4tracks`, one gene each. The walk's `W2-miss1` removes the third one's database.
    static let tracks: [(id: String, name: String, gene: String, start: Int, end: Int)] = [
        ("track-a", "genes a", "geneA", 0, 12),
        ("track-b", "genes b", "geneB", 12, 24),
        ("track-c", "two-parent c", "geneC", 24, 36),
        ("track-d", "genes d", "geneD", 36, 48),
    ]

    /// A reference bundle with a plain FASTA genome and the four tracks, whose databases named in `removed` are deleted.
    static func makeBundle(in root: URL, removing removed: Set<String>) throws -> URL {
        let bundle = root.appendingPathComponent("NG-4tracks.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        let annotations = bundle.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        try ">chr1\n\(sequence)\n".write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t\(sequence.count)\t6\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        var manifest = BundleManifest(
            formatVersion: "1.0",
            name: "NG-4tracks",
            identifier: "org.lungfish.tests.left-out-track",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [ChromosomeInfo(
                    name: "chr1", length: Int64(sequence.count), offset: 6,
                    lineBases: sequence.count, lineWidth: sequence.count + 1
                )]
            )
        )
        for track in tracks {
            let bed = root.appendingPathComponent("\(track.id).bed")
            let database = annotations.appendingPathComponent("\(track.id).db")
            try [
                "chr1", "\(track.start)", "\(track.end)", track.gene, "0", "+", "\(track.start)", "\(track.end)", "0", "1",
                "\(track.end - track.start)", "0", "gene", "ID=\(track.gene);Name=\(track.gene)",
            ].joined(separator: "\t").appending("\n").write(to: bed, atomically: true, encoding: .utf8)
            let count = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: database)
            manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
                id: track.id, name: track.name, path: "annotations/\(track.id).db",
                databasePath: "annotations/\(track.id).db", annotationType: .gene, featureCount: count
            ))
        }
        try manifest.save(to: bundle)
        for id in removed {
            try FileManager.default.removeItem(at: annotations.appendingPathComponent("\(id).db"))
        }
        return bundle
    }

    /// A conda root whose bgzip gzips its last argument and whose samtools writes a `.fai` for `faidx` and answers
    /// every other call with a version. The CLI reads the root from `LUNGFISH_CONDA_ROOT`, so the stand-ins win.
    private func stubCondaRoot() throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        for last in "$@"; do :; done
        gzip -f "$last"
        """
        let samtools = """
        #!/bin/sh
        if [ "$1" = "faidx" ]; then
          name=$(gzip -dc "$2" | head -n 1 | cut -c 2- | cut -d ' ' -f 1)
          length=$(gzip -dc "$2" | tail -n +2 | tr -d '\\n' | wc -c | tr -d ' ')
          printf '%s\\t%s\\t0\\t%s\\t%s\\n' "$name" "$length" "$length" "$length" > "$2.fai"
          exit 0
        fi
        echo "samtools 1.20"
        exit 0
        """
        for (path, script) in [("envs/htslib/bin/bgzip", bgzip), ("envs/samtools/bin/samtools", samtools)] {
            let binary = condaRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return condaRoot
    }

    /// Runs the built lungfish-cli and returns its exit status, standard output and standard error.
    private func runCLI(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            CLISIGTERMHarness.cliBinaryURL(for: Self.self),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: environment)
        process.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

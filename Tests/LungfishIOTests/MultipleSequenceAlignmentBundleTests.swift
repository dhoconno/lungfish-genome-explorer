import Foundation
import LungfishCore
import SQLite3
import XCTest
@testable import LungfishIO

final class MultipleSequenceAlignmentBundleTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("msa-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace, FileManager.default.fileExists(atPath: workspace.path) {
            try FileManager.default.removeItem(at: workspace)
        }
    }

    func testImportsAcceptedP0FormatsIntoNativeBundle() throws {
        let fixtures: [(filename: String, source: String, format: MultipleSequenceAlignmentBundle.SourceFormat)] = [
            (
                "aligned.fasta",
                """
                >sampleA
                ATG-C
                >sampleB
                AT-CC
                >sampleC
                ATGGC
                """,
                .alignedFASTA
            ),
            (
                "example.aln",
                """
                CLUSTAL W multiple sequence alignment

                sampleA    ATG-C
                sampleB    AT-CC
                sampleC    ATGGC

                sampleA    TA
                sampleB    TA
                sampleC    CA
                """,
                .clustal
            ),
            (
                "example.phy",
                """
                3 5
                sampleA ATG-C
                sampleB AT-CC
                sampleC ATGGC
                """,
                .phylip
            ),
            (
                "example-sequential.phy",
                """
                3 5
                sampleA
                ATG-C
                sampleB
                AT-CC
                sampleC
                ATGGC
                """,
                .phylip
            ),
            (
                "example.nexus",
                """
                #NEXUS
                begin data;
                  dimensions ntax=3 nchar=5;
                  format datatype=dna gap=- missing=?;
                  matrix
                  sampleA ATG-C
                  sampleB AT-CC
                  sampleC ATGGC
                  ;
                end;
                """,
                .nexus
            ),
            (
                "example.sto",
                """
                # STOCKHOLM 1.0
                sampleA ATG-C
                sampleB AT-CC
                sampleC ATGGC
                //
                """,
                .stockholm
            ),
            (
                "example.a2m",
                """
                >sampleA
                ATg-C
                >sampleB
                AT-CC
                >sampleC
                ATGGC
                """,
                .a2mA3m
            ),
        ]

        for fixture in fixtures {
            let inputURL = try writeInput(named: fixture.filename, contents: fixture.source)
            let bundleURL = workspace.appendingPathComponent("\(fixture.filename).lungfishmsa", isDirectory: true)
            let result = try MultipleSequenceAlignmentBundle.importAlignment(
                from: inputURL,
                to: bundleURL,
                options: .init(
                    name: fixture.filename,
                    argv: ["lungfish", "import", "msa", inputURL.path, "--output", bundleURL.path, "--name", fixture.filename],
                    reproducibleCommand: "lungfish import msa \(inputURL.path) --output \(bundleURL.path) --name \(fixture.filename)"
                )
            )

            XCTAssertEqual(result.manifest.bundleKind, "multiple-sequence-alignment")
            XCTAssertEqual(result.manifest.sourceFormat, fixture.format)
            XCTAssertEqual(result.manifest.rowCount, 3)
            XCTAssertEqual(result.manifest.alignedLength, fixture.format == .clustal ? 7 : 5)
            XCTAssertEqual(result.rows.count, 3)
            XCTAssertEqual(result.rows[0].ungappedLength, fixture.format == .clustal ? 6 : 4)
            XCTAssertFalse(result.manifest.consensus.isEmpty)
            XCTAssertEqual(result.manifest.variableSiteCount, fixture.format == .clustal ? 2 : 1)
            XCTAssertEqual(result.manifest.parsimonyInformativeSiteCount, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("alignment/primary.aligned.fasta").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("alignment/source.original").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("metadata/rows.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("cache/alignment-index.sqlite").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".viewstate.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
            XCTAssertEqual(try sqliteTableCount(at: bundleURL.appendingPathComponent("cache/alignment-index.sqlite")), 3)
        }
    }

    func testRectangularFormatsRejectUnequalRowLengths() throws {
        let inputURL = try writeInput(
            named: "bad.fasta",
            contents: """
            >sampleA
            ATG-C
            >sampleB
            AT-CC
            >sampleC
            ATGG
            """
        )
        let bundleURL = workspace.appendingPathComponent("bad.lungfishmsa", isDirectory: true)

        XCTAssertThrowsError(
            try MultipleSequenceAlignmentBundle.importAlignment(
                from: inputURL,
                to: bundleURL,
                options: .init(name: "bad")
            )
        ) { error in
            guard case MultipleSequenceAlignmentBundle.ImportError.unequalAlignedLengths = error else {
                return XCTFail("Expected unequalAlignedLengths, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
    }

    func testManifestAndProvenanceUseFinalPathsAndChecksumsWithoutTmpPaths() throws {
        let inputURL = try writeInput(
            named: "provenance.fasta",
            contents: """
            >sampleA
            AAGT
            >sampleB
            ACGT
            >sampleC
            ACGC
            """
        )
        let bundleURL = workspace.appendingPathComponent("FinalMSA.lungfishmsa", isDirectory: true)
        let argv = ["lungfish", "import", "msa", inputURL.path, "--output", bundleURL.path, "--name", "FinalMSA"]

        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(
            from: inputURL,
            to: bundleURL,
            options: .init(name: "FinalMSA", argv: argv, wallTimeSeconds: 12.5)
        )

        XCTAssertEqual(bundle.manifest.name, "FinalMSA")
        XCTAssertEqual(bundle.manifest.rowCount, 3)
        XCTAssertEqual(bundle.manifest.alignedLength, 4)
        XCTAssertEqual(bundle.manifest.consensus, "ACGT")
        XCTAssertEqual(bundle.manifest.variableSiteCount, 2)
        XCTAssertEqual(bundle.manifest.parsimonyInformativeSiteCount, 0)
        XCTAssertEqual(bundle.manifest.checksums["alignment/primary.aligned.fasta"], try sha256(at: bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")))
        XCTAssertEqual(bundle.manifest.fileSizes["alignment/source.original"], try fileSize(at: bundleURL.appendingPathComponent("alignment/source.original")))

        let provenance = try decode(MultipleSequenceAlignmentBundle.Provenance.self, from: bundleURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertEqual(provenance.toolName, "lungfish import msa")
        XCTAssertEqual(provenance.toolVersion, MultipleSequenceAlignmentBundle.toolVersion)
        XCTAssertEqual(provenance.argv, argv)
        XCTAssertTrue(provenance.reproducibleCommand.contains(inputURL.path))
        XCTAssertEqual(provenance.options.name, "FinalMSA")
        XCTAssertEqual(provenance.options.sourceFormat, "auto")
        XCTAssertEqual(provenance.input.path, bundleURL.appendingPathComponent("alignment/source.original").path)
        XCTAssertEqual(provenance.inputFiles?.first?.path, inputURL.path)
        XCTAssertEqual(provenance.inputFiles?.first?.checksumSHA256, try sha256(at: inputURL))
        XCTAssertEqual(provenance.output.path, bundleURL.path)
        XCTAssertNotEqual(provenance.output.checksumSHA256, bundle.manifest.checksums["alignment/primary.aligned.fasta"])
        XCTAssertGreaterThan(provenance.output.fileSize, try fileSize(at: bundleURL.appendingPathComponent("alignment/source.original")))
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.wallTimeSeconds, 12.5)
        XCTAssertEqual(provenance.warnings, bundle.manifest.warnings)

        let provenanceText = try String(contentsOf: bundleURL.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertFalse(provenanceText.contains("/tmp/"), "Provenance must not point at temporary staging paths")
    }

    func testImportWritesCoordinateMapsAndRehydratedAnnotations() throws {
        let inputURL = try writeInput(
            named: "annotated.fasta",
            contents: """
            >seqA
            A-CG-T
            >seqB
            ATCGGT
            """
        )
        let bundleURL = workspace.appendingPathComponent("Annotated.lungfishmsa", isDirectory: true)

        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(
            from: inputURL,
            to: bundleURL,
            options: .init(
                name: "Annotated",
                sourceAnnotations: [
                    MultipleSequenceAlignmentBundle.SourceAnnotationInput(
                        rowName: "seqA",
                        sourceSequenceName: "seqA",
                        sourceFilePath: inputURL.path,
                        sourceTrackID: "genes",
                        sourceTrackName: "Genes",
                        sourceAnnotationID: "gene-alpha",
                        name: "gene-alpha",
                        type: "gene",
                        strand: "+",
                        intervals: [AnnotationInterval(start: 1, end: 4)],
                        qualifiers: ["product": ["alpha"]],
                        note: "source feature"
                    ),
                ]
            )
        )

        let coordinateMaps = try bundle.loadCoordinateMaps()
        let seqAMap = try XCTUnwrap(coordinateMaps.first { $0.rowName == "seqA" })
        XCTAssertEqual(seqAMap.alignmentToUngapped, [0, nil, 1, 2, nil, 3])
        XCTAssertEqual(seqAMap.ungappedToAlignment, [0, 2, 3, 5])

        let annotationStore = try bundle.loadAnnotationStore()
        XCTAssertEqual(annotationStore.sourceAnnotations.count, 1)
        let annotation = try XCTUnwrap(annotationStore.sourceAnnotations.first)
        XCTAssertEqual(annotation.rowName, "seqA")
        XCTAssertEqual(annotation.sourceIntervals, [AnnotationInterval(start: 1, end: 4)])
        XCTAssertEqual(annotation.alignedIntervals, [
            AnnotationInterval(start: 2, end: 4),
            AnnotationInterval(start: 5, end: 6),
        ])
        XCTAssertEqual(annotation.qualifiers["product"], ["alpha"])

        let seqBMap = try XCTUnwrap(coordinateMaps.first { $0.rowName == "seqB" })
        let projected = MultipleSequenceAlignmentBundle.projectAnnotation(
            annotation,
            to: seqBMap,
            conflictPolicy: .append
        )
        XCTAssertEqual(projected.origin, .projected)
        XCTAssertEqual(projected.rowName, "seqB")
        XCTAssertEqual(projected.sourceAnnotationID, "gene-alpha")
        XCTAssertEqual(projected.sourceIntervals, [
            AnnotationInterval(start: 2, end: 4),
            AnnotationInterval(start: 5, end: 6),
        ])
        XCTAssertTrue(projected.warnings.contains { $0.contains("split into 2 intervals") })

        XCTAssertTrue(bundle.manifest.capabilities.contains("coordinate-maps"))
        XCTAssertTrue(bundle.manifest.capabilities.contains("annotation-retention"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("metadata/coordinate-maps.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("metadata/annotations.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("metadata/annotations.sqlite").path))
        XCTAssertEqual(try sqliteTableCount(at: bundleURL.appendingPathComponent("metadata/annotations.sqlite"), table: "annotation_records"), 1)
        XCTAssertEqual(bundle.manifest.checksums["metadata/coordinate-maps.json"], try sha256(at: bundleURL.appendingPathComponent("metadata/coordinate-maps.json")))
        XCTAssertEqual(bundle.manifest.checksums["metadata/annotations.json"], try sha256(at: bundleURL.appendingPathComponent("metadata/annotations.json")))
        XCTAssertEqual(bundle.manifest.checksums["metadata/annotations.sqlite"], try sha256(at: bundleURL.appendingPathComponent("metadata/annotations.sqlite")))
    }

    func testAnnotationStoreLoadsFromSQLiteWhenJSONSnapshotIsMissing() throws {
        let inputURL = try writeInput(
            named: "sqlite-backed-annotations.fasta",
            contents: """
            >seqA
            A-CG-T
            >seqB
            ATCGGT
            """
        )
        let bundleURL = workspace.appendingPathComponent("SQLiteAnnotations.lungfishmsa", isDirectory: true)
        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(
            from: inputURL,
            to: bundleURL,
            options: .init(
                sourceAnnotations: [
                    MultipleSequenceAlignmentBundle.SourceAnnotationInput(
                        rowName: "seqA",
                        sourceSequenceName: "seqA",
                        sourceFilePath: inputURL.path,
                        sourceTrackID: "genes",
                        sourceTrackName: "Genes",
                        sourceAnnotationID: "gene-alpha",
                        name: "gene-alpha",
                        type: "gene",
                        strand: "+",
                        intervals: [AnnotationInterval(start: 1, end: 4)],
                        qualifiers: ["product": ["alpha"]],
                        note: "source feature"
                    ),
                ]
            )
        )

        try FileManager.default.removeItem(at: bundleURL.appendingPathComponent("metadata/annotations.json"))

        let store = try bundle.loadAnnotationStore()
        XCTAssertEqual(store.sourceAnnotations.count, 1)
        XCTAssertEqual(store.sourceAnnotations.first?.name, "gene-alpha")
        XCTAssertEqual(store.sourceAnnotations.first?.sourceTrackName, "Genes")
        XCTAssertEqual(store.sourceAnnotations.first?.qualifiers["product"], ["alpha"])
    }

    func testManualAnnotationAuthoringAndProjectionPersistWithEditProvenance() throws {
        let inputURL = try writeInput(
            named: "manual-projection.fasta",
            contents: """
            >seqA
            A-CG-T
            >seqB
            ATCGGT
            """
        )
        let bundleURL = workspace.appendingPathComponent("ManualProjection.lungfishmsa", isDirectory: true)
        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(from: inputURL, to: bundleURL)

        let manual = try bundle.makeAnnotationFromAlignedSelection(
            rowID: bundle.rows[0].id,
            alignedIntervals: [AnnotationInterval(start: 2, end: 6)],
            name: "selection-feature",
            type: "gene",
            strand: "+",
            qualifiers: ["created_by": ["test"]]
        )
        let authored = try bundle.appendingAnnotations(
            [manual],
            editDescription: "Add annotation from MSA selection",
            argv: ["lungfish-gui", "msa", "add-annotation"]
        )

        let targetMap = try XCTUnwrap(authored.loadCoordinateMaps().first { $0.rowName == "seqB" })
        let projected = MultipleSequenceAlignmentBundle.projectAnnotation(
            manual,
            to: targetMap,
            conflictPolicy: .append
        )
        let updated = try authored.appendingAnnotations(
            [projected],
            editDescription: "Apply MSA annotation to selected rows",
            argv: ["lungfish-gui", "msa", "apply-annotation"]
        )

        let store = try updated.loadAnnotationStore()
        XCTAssertEqual(store.sourceAnnotations.map(\.origin), [.manual])
        XCTAssertEqual(store.sourceAnnotations.first?.sourceIntervals, [AnnotationInterval(start: 1, end: 4)])
        XCTAssertEqual(store.projectedAnnotations.count, 1)
        XCTAssertEqual(store.projectedAnnotations.first?.rowName, "seqB")
        XCTAssertEqual(store.projectedAnnotations.first?.sourceIntervals, [
            AnnotationInterval(start: 2, end: 4),
            AnnotationInterval(start: 5, end: 6),
        ])

        XCTAssertTrue(updated.manifest.capabilities.contains("annotation-authoring"))
        XCTAssertTrue(updated.manifest.capabilities.contains("annotation-projection"))
        XCTAssertEqual(
            updated.manifest.checksums["metadata/annotations.json"],
            try sha256(at: bundleURL.appendingPathComponent("metadata/annotations.json"))
        )
        XCTAssertEqual(
            updated.manifest.checksums["metadata/annotations.sqlite"],
            try sha256(at: bundleURL.appendingPathComponent("metadata/annotations.sqlite"))
        )
        XCTAssertEqual(
            updated.manifest.checksums["metadata/annotation-edit-provenance.json"],
            try sha256(at: bundleURL.appendingPathComponent("metadata/annotation-edit-provenance.json"))
        )
        XCTAssertEqual(try sqliteTableCount(at: bundleURL.appendingPathComponent("metadata/annotations.sqlite"), table: "annotation_records"), 2)

        let provenanceText = try String(
            contentsOf: bundleURL.appendingPathComponent("metadata/annotation-edit-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenanceText.contains("Apply MSA annotation to selected rows"))
        let editProvenance = try decode(
            MultipleSequenceAlignmentBundle.AnnotationEditProvenance.self,
            from: bundleURL.appendingPathComponent("metadata/annotation-edit-provenance.json")
        )
        XCTAssertEqual(editProvenance.bundlePath, bundleURL.path)
        XCTAssertEqual(editProvenance.output.path, bundleURL.appendingPathComponent("metadata/annotations.sqlite").path)
        XCTAssertEqual(editProvenance.files["metadata/annotations.sqlite"]?.checksumSHA256, try sha256(at: bundleURL.appendingPathComponent("metadata/annotations.sqlite")))
        XCTAssertFalse(provenanceText.contains("/tmp/"))
    }

    private func writeInput(named filename: String, contents: String) throws -> URL {
        let url = workspace.appendingPathComponent(filename)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func sha256(at url: URL) throws -> String {
        try MultipleSequenceAlignmentBundle.sha256Hex(for: Data(contentsOf: url))
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func sqliteTableCount(at url: URL, table: String = "alignment_rows") throws -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }

        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(table)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
}

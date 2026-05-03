import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

final class MSACommandTests: XCTestCase {
    func testActionsSubcommandEmitsJSONRegistry() throws {
        let command = try MSACommand.ActionsSubcommand.parse([
            "--category", "annotation",
            "--cli-backed",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let output = recorder.joined()
        XCTAssertTrue(output.contains(#""schemaVersion" : 1"#))
        XCTAssertTrue(output.contains(#""id" : "msa.annotation.project""#))
        XCTAssertFalse(output.contains(#""id" : "msa.selection.block""#))
    }

    func testActionsSubcommandEmitsTSVWithProvenanceColumn() throws {
        let command = try MSACommand.ActionsSubcommand.parse([
            "--data-changing",
            "--format", "tsv",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let lines = recorder.lines()
        XCTAssertEqual(lines.first, "id\ttitle\tcategory\tpriority\tstatus\tprovenanceRequired\tcliCommand")
        XCTAssertTrue(lines.contains { $0.hasPrefix("msa.transform.mask-columns\t") && $0.contains("\ttrue\tlungfish msa mask columns") })
    }

    func testDescribeSubcommandEmitsSpecificAction() throws {
        let command = try MSACommand.DescribeSubcommand.parse([
            "msa.alignment.mafft",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let output = recorder.joined()
        XCTAssertTrue(output.contains(#""id" : "msa.alignment.mafft""#))
        XCTAssertTrue(output.contains("lungfish align mafft"))
        XCTAssertTrue(output.contains(#""requiresProvenance" : true"#))
    }

    func testExportSubcommandWritesSelectedAlignedFASTAAndProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("input.fasta")
        try """
        >seq1
        ACGT--
        >seq2
        A-GTAA

        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: sourceURL,
            to: bundleURL,
            options: .init(name: "input")
        )

        let outputURL = tempDir.appendingPathComponent("selected.fa")
        let command = try MSACommand.ExportSubcommand.parse([
            bundleURL.path,
            "--output-format", "aligned-fasta",
            "--output", outputURL.path,
            "--rows", "seq1",
            "--columns", "2-4",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let exported = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(exported, ">seq1\nCGT\n")

        let provenanceURL = outputURL.appendingPathExtension("lungfish-provenance.json")
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""actionID" : "msa.export.aligned-fasta""#))
        XCTAssertTrue(provenance.contains(#""rows" : "seq1""#))
        XCTAssertTrue(provenance.contains(#""columns" : "2-4""#))
        XCTAssertTrue(
            provenance.contains(outputURL.path)
                || provenance.contains(outputURL.path.replacingOccurrences(of: "/", with: "\\/"))
        )

        let events = recorder.joined()
        XCTAssertTrue(events.contains(#""event":"msaActionStart""#))
        XCTAssertTrue(events.contains(#""event":"msaActionComplete""#))
        XCTAssertTrue(events.contains(outputURL.path.replacingOccurrences(of: "/", with: "\\/")))
    }

    func testExportSubcommandDistinguishesUngappedAndAlignedFASTAOutputs() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("input.fasta")
        try """
        >seq1
        A-CGT
        >seq2
        AT-GT

        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: sourceURL,
            to: bundleURL,
            options: .init(name: "input")
        )

        let fastaURL = tempDir.appendingPathComponent("ungapped.fa")
        let fasta = try MSACommand.ExportSubcommand.parse([
            bundleURL.path,
            "--output-format", "fasta",
            "--output", fastaURL.path,
            "--rows", "seq1",
            "--format", "json",
        ])
        try fasta.executeForTesting { _ in }

        XCTAssertEqual(
            try String(contentsOf: fastaURL, encoding: .utf8),
            ">seq1\nACGT\n"
        )
        var provenance = try normalizedFileText(at: fastaURL.appendingPathExtension("lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""actionID" : "msa.export.fasta""#))
        XCTAssertTrue(provenance.contains(#""sequenceLayout" : "ungapped""#))

        let alignedURL = tempDir.appendingPathComponent("aligned.fa")
        let aligned = try MSACommand.ExportSubcommand.parse([
            bundleURL.path,
            "--output-format", "aligned-fasta",
            "--output", alignedURL.path,
            "--rows", "seq1",
            "--format", "json",
        ])
        try aligned.executeForTesting { _ in }

        XCTAssertEqual(
            try String(contentsOf: alignedURL, encoding: .utf8),
            ">seq1\nA-CGT\n"
        )
        provenance = try normalizedFileText(at: alignedURL.appendingPathExtension("lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""actionID" : "msa.export.aligned-fasta""#))
        XCTAssertTrue(provenance.contains(#""sequenceLayout" : "aligned""#))
    }

    func testMSAActionJSONEventsCarryStableOperationID() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT
            >seq2
            A-GT

            """,
            name: "event-fixture"
        )
        let outputURL = tempDir.appendingPathComponent("event.fa")
        let command = try MSACommand.ExportSubcommand.parse([
            bundleURL.path,
            "--output-format", "fasta",
            "--output", outputURL.path,
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let events = try recorder.lines().map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertTrue(events.contains { ($0["event"] as? String) == "msaActionStart" })
        XCTAssertTrue(events.contains { ($0["event"] as? String) == "msaActionProgress" })
        XCTAssertTrue(events.contains { ($0["event"] as? String) == "msaActionComplete" })
        let operationIDs = Set(events.compactMap { $0["operationID"] as? String })
        XCTAssertEqual(operationIDs.count, 1)
        XCTAssertFalse(operationIDs.first?.isEmpty ?? true)
        let completion = try XCTUnwrap(events.first { ($0["event"] as? String) == "msaActionComplete" })
        XCTAssertEqual(completion["output"] as? String, outputURL.path)
    }

    func testExportSubcommandWritesPHYLIPNEXUSCLUSTALStockholmAndA2M() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT
            >seq2
            A-GT

            """,
            name: "format-fixture"
        )

        let cases: [(format: String, filename: String, expectedSnippet: String)] = [
            ("phylip", "out.phy", "2 4\nseq1 ACGT\nseq2 A-GT\n"),
            ("nexus", "out.nex", "#NEXUS\nbegin data;\ndimensions ntax=2 nchar=4;"),
            ("clustal", "out.aln", "CLUSTAL W multiple sequence alignment\n\nseq1    ACGT\nseq2    A-GT\n"),
            ("stockholm", "out.sto", "# STOCKHOLM 1.0\nseq1 ACGT\nseq2 A-GT\n//\n"),
            ("a2m", "out.a2m", ">seq1\nACGT\n>seq2\nA-GT\n"),
        ]

        for item in cases {
            let outputURL = tempDir.appendingPathComponent(item.filename)
            let command = try MSACommand.ExportSubcommand.parse([
                bundleURL.path,
                "--output-format", item.format,
                "--output", outputURL.path,
                "--format", "json",
            ])

            try command.executeForTesting { _ in }

            let text = try String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertTrue(text.contains(item.expectedSnippet), "Missing expected snippet for \(item.format):\n\(text)")
            let provenance = try String(
                contentsOf: outputURL.appendingPathExtension("lungfish-provenance.json"),
                encoding: .utf8
            )
            XCTAssertTrue(provenance.contains(#""outputFormat" : "\#(item.format)""#))
            XCTAssertFalse(provenance.contains("/tmp/"))
        }
    }

    func testExportSubcommandWarnsWhenAnnotationsCannotBeRepresented() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT
            >seq2
            A-GT

            """,
            name: "annotated-export-fixture"
        )
        let addCommand = try MSACommand.AddSubcommand.parse([
            bundleURL.path,
            "--row", "seq1",
            "--columns", "2-3",
            "--name", "feature",
            "--type", "gene",
            "--format", "json",
        ])
        try addCommand.executeForTesting { _ in }

        let outputURL = tempDir.appendingPathComponent("annotated.phy")
        let exportCommand = try MSACommand.ExportSubcommand.parse([
            bundleURL.path,
            "--output-format", "phylip",
            "--output", outputURL.path,
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try exportCommand.executeForTesting { recorder.append($0) }

        let events = recorder.joined()
        XCTAssertTrue(events.contains(#""event":"msaActionWarning""#))
        XCTAssertTrue(events.contains("does not preserve MSA annotations"))
        XCTAssertTrue(events.contains(#""warningCount":1"#))

        let provenance = try String(
            contentsOf: outputURL.appendingPathExtension("lungfish-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains(#""warnings" : ["#))
        XCTAssertTrue(provenance.contains("does not preserve MSA annotations"))
        XCTAssertFalse(provenance.contains("/tmp/"))
    }

    func testConsensusSubcommandWritesConsensusFASTAAndProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT
            >seq2
            ACGT
            >seq3
            ACAT

            """,
            name: "consensus-fixture"
        )

        let outputURL = tempDir.appendingPathComponent("consensus.fa")
        let command = try MSACommand.ConsensusSubcommand.parse([
            bundleURL.path,
            "--output", outputURL.path,
            "--name", "fixture-consensus",
            "--threshold", "0.6",
            "--gap-policy", "omit",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), ">fixture-consensus\nACGT\n")
        let provenance = try String(
            contentsOf: outputURL.appendingPathExtension("lungfish-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains(#""actionID" : "msa.transform.consensus""#))
        XCTAssertTrue(provenance.contains(#""threshold" : 0.6"#))
        XCTAssertTrue(provenance.contains(#""gapPolicy" : "omit""#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testConsensusSubcommandWritesReferenceBundleWithConsensusMetadataAndProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT-
            >seq2
            A-TA-
            >seq3
            ACCG-

            """,
            name: "consensus-reference-fixture"
        )

        let outputURL = tempDir.appendingPathComponent("consensus.lungfishref", isDirectory: true)
        let command = try MSACommand.ConsensusSubcommand.parse([
            bundleURL.path,
            "--output-kind", "reference",
            "--output", outputURL.path,
            "--name", "fixture-consensus",
            "--threshold", "0.6",
            "--gap-policy", "omit",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let manifest = try BundleManifest.load(from: outputURL)
        XCTAssertEqual(manifest.name, "fixture-consensus")
        XCTAssertEqual(manifest.genome?.path, "genome/sequence.fa")
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), ["fixture-consensus"])
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.length), [4])
        let fasta = try String(
            contentsOf: outputURL.appendingPathComponent("genome/sequence.fa"),
            encoding: .utf8
        )
        XCTAssertEqual(fasta, ">fixture-consensus\nACNN\n")
        XCTAssertFalse(fasta.split(separator: "\n").filter { !$0.hasPrefix(">") }.joined().contains("-"))

        let consensusMetadata = try jsonObject(
            at: outputURL.appendingPathComponent("metadata/msa-consensus.json")
        )
        XCTAssertEqual(consensusMetadata["sourceBundlePath"] as? String, bundleURL.path)
        XCTAssertEqual(consensusMetadata["threshold"] as? Double, 0.6)
        XCTAssertEqual(consensusMetadata["gapPolicy"] as? String, "omit")
        XCTAssertEqual(consensusMetadata["outputSequenceName"] as? String, "fixture-consensus")
        XCTAssertEqual(consensusMetadata["alignmentColumns"] as? [Int], [0, 1, 2, 3])

        let provenanceURL = outputURL.appendingPathComponent(".lungfish-provenance.json")
        let provenanceText = try normalizedFileText(at: provenanceURL)
        let provenance = try jsonObject(at: provenanceURL)
        XCTAssertEqual(provenance["workflowName"] as? String, "multiple-sequence-alignment-consensus-reference")
        XCTAssertEqual(provenance["toolName"] as? String, "lungfish msa consensus")
        XCTAssertEqual(provenance["toolVersion"] as? String, MultipleSequenceAlignmentBundle.toolVersion)
        XCTAssertNotEqual(provenance["toolVersion"] as? String, "lungfish-cli")
        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        XCTAssertEqual(options["outputKind"] as? String, "reference")
        XCTAssertEqual(options["threshold"] as? Double, 0.6)
        XCTAssertEqual(options["gapPolicy"] as? String, "omit")
        XCTAssertEqual(options["selectedColumnCount"] as? Int, 5)
        XCTAssertEqual(options["outputTotalLength"] as? Int, 4)
        try assertReferenceOutputBundleRecord(
            provenance,
            outputURL: outputURL,
            expectedChecksum: visibleDirectoryChecksum(at: outputURL),
            expectedFileSize: visibleDirectorySize(at: outputURL)
        )
        try assertFinalFileRecordsHaveChecksumsAndSizes(
            provenance,
            keys: ["outputFiles", "metadataFiles"],
            rootedAt: outputURL
        )
        XCTAssertFalse(provenanceText.contains("/tmp/"))
        XCTAssertFalse(provenanceText.contains("/.tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testExtractSubcommandWritesDerivedMSABundleWithSelectionProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT--
            >seq2
            A-GTAA
            >seq3
            ACGTAA

            """,
            name: "extract-fixture"
        )

        let outputURL = tempDir.appendingPathComponent("selected.lungfishmsa", isDirectory: true)
        let command = try MSACommand.ExtractSubcommand.parse([
            bundleURL.path,
            "--output-kind", "msa",
            "--output", outputURL.path,
            "--rows", "seq1,seq2",
            "--columns", "2-4",
            "--name", "selected-region",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let derived = try MultipleSequenceAlignmentBundle.load(from: outputURL)
        XCTAssertEqual(derived.manifest.name, "selected-region")
        XCTAssertEqual(derived.rows.map(\.displayName), ["seq1_columns_2-4", "seq2_columns_2-4"])
        let primary = try String(
            contentsOf: outputURL.appendingPathComponent("alignment/primary.aligned.fasta"),
            encoding: .utf8
        )
        XCTAssertEqual(primary, ">seq1_columns_2-4\nCGT\n>seq2_columns_2-4\n-GT\n")
        let provenance = try normalizedFileText(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-extract""#))
        XCTAssertTrue(provenance.contains(#""rows" : "seq1,seq2""#))
        XCTAssertTrue(provenance.contains(#""columns" : "2-4""#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        let sourceRowMap = try normalizedFileText(at: outputURL.appendingPathComponent("metadata/source-row-map.json"))
        XCTAssertTrue(sourceRowMap.contains(bundleURL.appendingPathComponent("alignment/primary.aligned.fasta").path))
        XCTAssertFalse(sourceRowMap.contains("/tmp/"))
        XCTAssertFalse(sourceRowMap.contains("/.tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testExtractSubcommandFastaOutputWritesUngappedSequencesAndProvenanceLayout() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT--
            >seq2
            A-GTAA

            """,
            name: "fasta-extract-fixture"
        )

        let outputURL = tempDir.appendingPathComponent("selected.fa")
        let command = try MSACommand.ExtractSubcommand.parse([
            bundleURL.path,
            "--output-kind", "fasta",
            "--output", outputURL.path,
            "--rows", "seq2",
            "--columns", "1-4",
            "--name", "selected-fasta",
            "--format", "json",
        ])

        try command.executeForTesting { _ in }

        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8),
            ">seq2_columns_1-4\nAGT\n"
        )
        let provenance = try normalizedFileText(at: outputURL.appendingPathExtension("lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""outputKind" : "fasta""#))
        XCTAssertTrue(provenance.contains(#""sequenceLayout" : "ungapped""#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
    }

    func testExtractSubcommandWritesReferenceBundleWithUngappedSequencesCoordinateMapAndProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT--
            >seq2
            A-GTAA
            >seq3
            ACGTAA

            """,
            name: "reference-extract-fixture"
        )

        let outputURL = tempDir.appendingPathComponent("selected.lungfishref", isDirectory: true)
        let command = try MSACommand.ExtractSubcommand.parse([
            bundleURL.path,
            "--output-kind", "reference",
            "--output", outputURL.path,
            "--rows", "seq1,seq2",
            "--columns", "2-5",
            "--name", "selected-reference",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let manifest = try BundleManifest.load(from: outputURL)
        XCTAssertEqual(manifest.name, "selected-reference")
        XCTAssertEqual(manifest.genome?.path, "genome/sequence.fa")
        XCTAssertEqual(manifest.genome?.indexPath, "genome/sequence.fa.fai")
        XCTAssertNil(manifest.genome?.gzipIndexPath)
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), ["seq1_columns_2-5", "seq2_columns_2-5"])
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.length), [3, 3])

        let fasta = try String(
            contentsOf: outputURL.appendingPathComponent("genome/sequence.fa"),
            encoding: .utf8
        )
        XCTAssertEqual(fasta, ">seq1_columns_2-5\nCGT\n>seq2_columns_2-5\nGTA\n")
        XCTAssertFalse(fasta.split(separator: "\n").filter { !$0.hasPrefix(">") }.joined().contains("-"))

        let selection = try jsonObject(
            at: outputURL.appendingPathComponent("metadata/msa-selection.json")
        )
        XCTAssertEqual(selection["sourceBundlePath"] as? String, bundleURL.path)
        XCTAssertEqual(selection["rows"] as? String, "seq1,seq2")
        XCTAssertEqual(selection["columns"] as? String, "2-5")
        XCTAssertEqual(selection["selectedRowCount"] as? Int, 2)
        XCTAssertEqual(selection["selectedColumnCount"] as? Int, 4)

        let coordinateMap = try jsonObject(
            at: outputURL.appendingPathComponent("metadata/msa-coordinate-map.json")
        )
        XCTAssertEqual(coordinateMap["sourceBundlePath"] as? String, bundleURL.path)
        let rowMaps = try XCTUnwrap(coordinateMap["rows"] as? [[String: Any]])
        XCTAssertEqual(rowMaps.count, 2)
        XCTAssertEqual(rowMaps[0]["outputSequenceName"] as? String, "seq1_columns_2-5")
        XCTAssertEqual(rowMaps[0]["alignmentColumns"] as? [Int], [1, 2, 3])
        XCTAssertEqual(rowMaps[0]["sourceUngappedCoordinates"] as? [Int], [1, 2, 3])
        XCTAssertEqual(rowMaps[1]["outputSequenceName"] as? String, "seq2_columns_2-5")
        XCTAssertEqual(rowMaps[1]["alignmentColumns"] as? [Int], [2, 3, 4])
        XCTAssertEqual(rowMaps[1]["sourceUngappedCoordinates"] as? [Int], [1, 2, 3])

        let provenanceURL = outputURL.appendingPathComponent(".lungfish-provenance.json")
        let provenanceText = try normalizedFileText(at: provenanceURL)
        let provenance = try jsonObject(at: provenanceURL)
        XCTAssertEqual(provenance["workflowName"] as? String, "multiple-sequence-alignment-extract-reference")
        XCTAssertEqual(provenance["toolName"] as? String, "lungfish msa extract")
        XCTAssertEqual(provenance["toolVersion"] as? String, MultipleSequenceAlignmentBundle.toolVersion)
        XCTAssertNotEqual(provenance["toolVersion"] as? String, "lungfish-cli")
        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        XCTAssertEqual(options["outputKind"] as? String, "reference")
        XCTAssertEqual(options["rows"] as? String, "seq1,seq2")
        XCTAssertEqual(options["columns"] as? String, "2-5")
        XCTAssertEqual(options["selectedColumnCount"] as? Int, 4)
        XCTAssertEqual(options["outputSequenceCount"] as? Int, 2)
        XCTAssertEqual(options["outputTotalLength"] as? Int, 6)
        try assertReferenceOutputBundleRecord(
            provenance,
            outputURL: outputURL,
            expectedChecksum: visibleDirectoryChecksum(at: outputURL),
            expectedFileSize: visibleDirectorySize(at: outputURL)
        )
        try assertFinalFileRecordsHaveChecksumsAndSizes(
            provenance,
            keys: ["outputFiles", "metadataFiles"],
            rootedAt: outputURL
        )
        XCTAssertTrue(provenanceText.contains("genome/sequence.fa"))
        XCTAssertTrue(provenanceText.contains(outputURL.path))
        XCTAssertFalse(provenanceText.contains("/tmp/"))
        XCTAssertFalse(provenanceText.contains("/.tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testExtractReferenceBundlePropagatesMSAAnnotationsIntoReferenceSQLiteTrack() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT--
            >seq2
            A-GTAA

            """,
            name: "annotated-reference-extract-fixture"
        )
        let addCommand = try MSACommand.AddSubcommand.parse([
            bundleURL.path,
            "--row", "seq1",
            "--columns", "2-4",
            "--name", "lifted-gene",
            "--type", "gene",
            "--strand", "+",
            "--qualifier", "ID=gene-1",
            "--format", "json",
        ])
        try addCommand.executeForTesting { _ in }

        let outputURL = tempDir.appendingPathComponent("annotated-selection.lungfishref", isDirectory: true)
        let command = try MSACommand.ExtractSubcommand.parse([
            bundleURL.path,
            "--output-kind", "reference",
            "--output", outputURL.path,
            "--rows", "seq1",
            "--columns", "2-5",
            "--name", "annotated-selection",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let manifest = try BundleManifest.load(from: outputURL)
        XCTAssertEqual(manifest.annotations.count, 1)
        XCTAssertEqual(manifest.annotations.first?.id, "msa_lifted_annotations")
        XCTAssertEqual(manifest.annotations.first?.databasePath, "annotations/msa_lifted_annotations.db")
        XCTAssertEqual(manifest.annotations.first?.featureCount, 1)

        let dbURL = outputURL.appendingPathComponent("annotations/msa_lifted_annotations.db")
        let db = try AnnotationDatabase(url: dbURL)
        let records = db.queryByRegion(chromosome: "seq1_columns_2-5", start: 0, end: 3)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.name, "lifted-gene")
        XCTAssertEqual(records.first?.type, "gene")
        XCTAssertEqual(records.first?.start, 0)
        XCTAssertEqual(records.first?.end, 3)
        XCTAssertEqual(records.first?.strand, "+")
        XCTAssertTrue(records.first?.attributes?.contains("source_msa_annotation_id=") ?? false)

        let provenance = try String(
            contentsOf: outputURL.appendingPathComponent(".lungfish-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains("msa_lifted_annotations.db"))
        XCTAssertTrue(provenance.contains(#""propagatedAnnotationCount" : 1"#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testMaskColumnsSubcommandWritesDerivedBundleWithMaskMetadataAndProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGTAA
            >seq2
            A-GTTA

            """,
            name: "mask-fixture"
        )

        let outputURL = tempDir.appendingPathComponent("masked.lungfishmsa", isDirectory: true)
        let command = try MSACommand.MaskColumnsSubcommand.parse([
            bundleURL.path,
            "--ranges", "2-3,6",
            "--output", outputURL.path,
            "--name", "masked-region",
            "--reason", "low-confidence region",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let derived = try MultipleSequenceAlignmentBundle.load(from: outputURL)
        XCTAssertEqual(derived.manifest.name, "masked-region")
        XCTAssertEqual(derived.rows.map(\.displayName), ["seq1", "seq2"])
        XCTAssertTrue(derived.manifest.capabilities.contains("column-masks"))
        let primary = try String(
            contentsOf: outputURL.appendingPathComponent("alignment/primary.aligned.fasta"),
            encoding: .utf8
        )
        XCTAssertEqual(primary, ">seq1\nACGTAA\n>seq2\nA-GTTA\n")

        let maskMetadata = try String(
            contentsOf: outputURL.appendingPathComponent("metadata/masks.json"),
            encoding: .utf8
        )
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 2"#))
        XCTAssertTrue(maskMetadata.contains(#""endColumn" : 3"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 6"#))
        XCTAssertTrue(maskMetadata.contains(#""maskedColumnCount" : 3"#))
        XCTAssertTrue(maskMetadata.contains(#""reason" : "low-confidence region""#))

        let provenance = try normalizedFileText(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-mask-columns""#))
        XCTAssertTrue(provenance.contains(#""toolName" : "lungfish msa mask columns""#))
        XCTAssertTrue(provenance.contains(#""ranges" : "2-3,6""#))
        XCTAssertTrue(provenance.contains(#""maskedColumnCount" : 3"#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        let sourceRowMap = try normalizedFileText(at: outputURL.appendingPathComponent("metadata/source-row-map.json"))
        XCTAssertTrue(sourceRowMap.contains(bundleURL.appendingPathComponent("alignment/primary.aligned.fasta").path))
        XCTAssertFalse(sourceRowMap.contains("/tmp/"))
        XCTAssertFalse(sourceRowMap.contains("/.tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testMaskColumnsSubcommandSupportsGapThresholdSelectorWithProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            A-CG
            >seq2
            AT-G
            >seq3
            A--G

            """,
            name: "gap-mask-fixture"
        )

        let outputURL = tempDir.appendingPathComponent("gap-masked.lungfishmsa", isDirectory: true)
        let command = try MSACommand.MaskColumnsSubcommand.parse([
            bundleURL.path,
            "--gap-threshold", "0.5",
            "--output", outputURL.path,
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let maskMetadata = try String(
            contentsOf: outputURL.appendingPathComponent("metadata/masks.json"),
            encoding: .utf8
        )
        XCTAssertTrue(maskMetadata.contains(#""mode" : "gap-threshold""#))
        XCTAssertTrue(maskMetadata.contains(#""gapThreshold" : 0.5"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 2"#))
        XCTAssertTrue(maskMetadata.contains(#""endColumn" : 3"#))
        XCTAssertTrue(maskMetadata.contains(#""maskedColumnCount" : 2"#))

        let provenance = try String(contentsOf: outputURL.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-mask-columns""#))
        XCTAssertTrue(provenance.contains(#""selector" : "gap-threshold""#))
        XCTAssertTrue(provenance.contains(#""gapThreshold" : 0.5"#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testMaskColumnsSubcommandSupportsAnnotationSelectorWithProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT
            >seq2
            A-GT

            """,
            name: "annotation-mask-fixture"
        )
        let addCommand = try MSACommand.AddSubcommand.parse([
            bundleURL.path,
            "--row", "seq1",
            "--columns", "2-3",
            "--name", "mask-feature",
            "--type", "gene",
            "--format", "json",
        ])
        try addCommand.executeForTesting { _ in }
        let annotated = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let annotation = try XCTUnwrap(annotated.loadAnnotationStore().sourceAnnotations.first)

        let outputURL = tempDir.appendingPathComponent("annotation-masked.lungfishmsa", isDirectory: true)
        let command = try MSACommand.MaskColumnsSubcommand.parse([
            bundleURL.path,
            "--annotation", annotation.id,
            "--output", outputURL.path,
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let maskMetadata = try String(
            contentsOf: outputURL.appendingPathComponent("metadata/masks.json"),
            encoding: .utf8
        )
        XCTAssertTrue(maskMetadata.contains(#""mode" : "annotation""#))
        XCTAssertTrue(maskMetadata.contains(#""sourceAnnotationID" : "\#(annotation.id)""#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 2"#))
        XCTAssertTrue(maskMetadata.contains(#""endColumn" : 3"#))
        XCTAssertTrue(maskMetadata.contains(#""maskedColumnCount" : 2"#))

        let provenance = try String(contentsOf: outputURL.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""selector" : "annotation""#))
        XCTAssertTrue(provenance.contains(annotation.id))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testMaskColumnsSubcommandSupportsCodonPositionSelectorWithProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ATG-AACTGA
            >seq2
            ATGAAACTGA

            """,
            name: "codon-mask-fixture"
        )
        let addCommand = try MSACommand.AddSubcommand.parse([
            bundleURL.path,
            "--row", "seq1",
            "--columns", "1-10",
            "--name", "orf1",
            "--type", "CDS",
            "--format", "json",
        ])
        try addCommand.executeForTesting { _ in }
        let annotated = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let annotation = try XCTUnwrap(annotated.loadAnnotationStore().sourceAnnotations.first)

        let outputURL = tempDir.appendingPathComponent("codon-masked.lungfishmsa", isDirectory: true)
        let command = try MSACommand.MaskColumnsSubcommand.parse([
            bundleURL.path,
            "--codon-position", "3",
            "--output", outputURL.path,
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let maskMetadata = try String(
            contentsOf: outputURL.appendingPathComponent("metadata/masks.json"),
            encoding: .utf8
        )
        XCTAssertTrue(maskMetadata.contains(#""mode" : "codon-position""#))
        XCTAssertTrue(maskMetadata.contains(#""codonPosition" : 3"#))
        XCTAssertTrue(maskMetadata.contains(#""sourceAnnotationID" : "\#(annotation.id)""#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 3"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 7"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 10"#))
        XCTAssertTrue(maskMetadata.contains(#""maskedColumnCount" : 3"#))

        let provenance = try String(contentsOf: outputURL.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""selector" : "codon-position""#))
        XCTAssertTrue(provenance.contains(#""codonPosition" : 3"#))
        XCTAssertTrue(provenance.contains(annotation.id))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testMaskColumnsSubcommandSupportsConservationAndParsimonySelectorsWithProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGTA
            >seq2
            ACGTA
            >seq3
            ATGCA
            >seq4
            ATGCG

            """,
            name: "site-class-mask-fixture"
        )

        let conservationURL = tempDir.appendingPathComponent("low-conservation.lungfishmsa", isDirectory: true)
        let conservation = try MSACommand.MaskColumnsSubcommand.parse([
            bundleURL.path,
            "--conservation-below", "0.75",
            "--output", conservationURL.path,
            "--format", "json",
        ])
        try conservation.executeForTesting { _ in }

        var maskMetadata = try String(
            contentsOf: conservationURL.appendingPathComponent("metadata/masks.json"),
            encoding: .utf8
        )
        XCTAssertTrue(maskMetadata.contains(#""mode" : "conservation-below""#))
        XCTAssertTrue(maskMetadata.contains(#""conservationThreshold" : 0.75"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 2"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 4"#))
        XCTAssertTrue(maskMetadata.contains(#""maskedColumnCount" : 2"#))
        var provenance = try normalizedFileText(at: conservationURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""selector" : "conservation-below""#))
        XCTAssertTrue(provenance.contains(#""conservationThreshold" : 0.75"#))
        XCTAssertFalse(provenance.contains("/.tmp/"))

        let parsimonyURL = tempDir.appendingPathComponent("parsimony-uninformative.lungfishmsa", isDirectory: true)
        let parsimony = try MSACommand.MaskColumnsSubcommand.parse([
            bundleURL.path,
            "--parsimony-uninformative",
            "--output", parsimonyURL.path,
            "--format", "json",
        ])
        try parsimony.executeForTesting { _ in }

        maskMetadata = try String(
            contentsOf: parsimonyURL.appendingPathComponent("metadata/masks.json"),
            encoding: .utf8
        )
        XCTAssertTrue(maskMetadata.contains(#""mode" : "parsimony-uninformative""#))
        XCTAssertTrue(maskMetadata.contains(#""siteClass" : "parsimony-uninformative""#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 1"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 3"#))
        XCTAssertTrue(maskMetadata.contains(#""startColumn" : 5"#))
        XCTAssertTrue(maskMetadata.contains(#""maskedColumnCount" : 3"#))
        provenance = try normalizedFileText(at: parsimonyURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""selector" : "parsimony-uninformative""#))
        XCTAssertTrue(provenance.contains(#""siteClass" : "parsimony-uninformative""#))
        XCTAssertFalse(provenance.contains("/.tmp/"))
    }

    func testTrimColumnsSubcommandWritesDerivedBundlesForGapOnlyAndThreshold() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            A-CGT
            >seq2
            A-C-T
            >seq3
            A-G-T

            """,
            name: "trim-fixture"
        )

        let gapOnlyURL = tempDir.appendingPathComponent("gap-only.lungfishmsa", isDirectory: true)
        let gapOnly = try MSACommand.TrimColumnsSubcommand.parse([
            bundleURL.path,
            "--gap-only",
            "--output", gapOnlyURL.path,
            "--name", "gap-only-trimmed",
            "--format", "json",
        ])
        let gapOnlyRecorder = LineRecorder()

        try gapOnly.executeForTesting { gapOnlyRecorder.append($0) }

        let gapOnlyPrimary = try String(
            contentsOf: gapOnlyURL.appendingPathComponent("alignment/primary.aligned.fasta"),
            encoding: .utf8
        )
        XCTAssertEqual(gapOnlyPrimary, ">seq1\nACGT\n>seq2\nAC-T\n>seq3\nAG-T\n")
        let gapOnlyMetadata = try String(
            contentsOf: gapOnlyURL.appendingPathComponent("metadata/trim.json"),
            encoding: .utf8
        )
        XCTAssertTrue(gapOnlyMetadata.contains(#""mode" : "gap-only""#))
        XCTAssertTrue(gapOnlyMetadata.contains(#""removedColumnCount" : 1"#))
        XCTAssertTrue(gapOnlyMetadata.contains(#""startColumn" : 2"#))
        XCTAssertTrue(gapOnlyRecorder.joined().contains(#""event":"msaActionComplete""#))

        let thresholdURL = tempDir.appendingPathComponent("gap-threshold.lungfishmsa", isDirectory: true)
        let threshold = try MSACommand.TrimColumnsSubcommand.parse([
            bundleURL.path,
            "--gap-threshold", "0.5",
            "--output", thresholdURL.path,
            "--format", "json",
        ])
        let thresholdRecorder = LineRecorder()

        try threshold.executeForTesting { thresholdRecorder.append($0) }

        let thresholdPrimary = try String(
            contentsOf: thresholdURL.appendingPathComponent("alignment/primary.aligned.fasta"),
            encoding: .utf8
        )
        XCTAssertEqual(thresholdPrimary, ">seq1\nACT\n>seq2\nACT\n>seq3\nAGT\n")
        let thresholdMetadata = try String(
            contentsOf: thresholdURL.appendingPathComponent("metadata/trim.json"),
            encoding: .utf8
        )
        XCTAssertTrue(thresholdMetadata.contains(#""mode" : "gap-threshold""#))
        XCTAssertTrue(thresholdMetadata.contains(#""gapThreshold" : 0.5"#))
        XCTAssertTrue(thresholdMetadata.contains(#""removedColumnCount" : 2"#))

        let provenance = try normalizedFileText(at: thresholdURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-trim-columns""#))
        XCTAssertTrue(provenance.contains(#""toolName" : "lungfish msa trim columns""#))
        XCTAssertTrue(provenance.contains(#""gapThreshold" : 0.5"#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        let sourceRowMap = try normalizedFileText(at: thresholdURL.appendingPathComponent("metadata/source-row-map.json"))
        XCTAssertTrue(sourceRowMap.contains(bundleURL.appendingPathComponent("alignment/primary.aligned.fasta").path))
        XCTAssertFalse(sourceRowMap.contains("/tmp/"))
        XCTAssertFalse(sourceRowMap.contains("/.tmp/"))
        XCTAssertTrue(thresholdRecorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testDistanceSubcommandWritesIdentityAndPDistanceMatricesWithProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = try makeMSABundle(
            in: tempDir,
            contents: """
            >seq1
            ACGT
            >seq2
            A-GT
            >seq3
            ACAT

            """,
            name: "distance-fixture"
        )

        let identityURL = tempDir.appendingPathComponent("identity.tsv")
        let identity = try MSACommand.DistanceSubcommand.parse([
            bundleURL.path,
            "--model", "identity",
            "--output", identityURL.path,
            "--format", "json",
        ])
        let identityRecorder = LineRecorder()

        try identity.executeForTesting { identityRecorder.append($0) }

        let identityMatrix = try String(contentsOf: identityURL, encoding: .utf8)
        XCTAssertEqual(
            identityMatrix,
            "row\tseq1\tseq2\tseq3\nseq1\t1.000000\t1.000000\t0.750000\nseq2\t1.000000\t1.000000\t0.666667\nseq3\t0.750000\t0.666667\t1.000000\n"
        )
        var provenance = try String(
            contentsOf: identityURL.appendingPathExtension("lungfish-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-distance-matrix""#))
        XCTAssertTrue(provenance.contains(#""actionID" : "msa.phylogenetics.distance-matrix""#))
        XCTAssertTrue(provenance.contains(#""distanceModel" : "identity""#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertTrue(identityRecorder.joined().contains(#""event":"msaActionComplete""#))

        let pDistanceURL = tempDir.appendingPathComponent("p-distance.tsv")
        let pDistance = try MSACommand.DistanceSubcommand.parse([
            bundleURL.path,
            "--model", "p-distance",
            "--columns", "3-4",
            "--output", pDistanceURL.path,
            "--format", "json",
        ])
        let pDistanceRecorder = LineRecorder()

        try pDistance.executeForTesting { pDistanceRecorder.append($0) }

        let pDistanceMatrix = try String(contentsOf: pDistanceURL, encoding: .utf8)
        XCTAssertEqual(
            pDistanceMatrix,
            "row\tseq1\tseq2\tseq3\nseq1\t0.000000\t0.000000\t0.500000\nseq2\t0.000000\t0.000000\t0.500000\nseq3\t0.500000\t0.500000\t0.000000\n"
        )
        provenance = try String(
            contentsOf: pDistanceURL.appendingPathExtension("lungfish-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains(#""distanceModel" : "p-distance""#))
        XCTAssertTrue(provenance.contains(#""columns" : "3-4""#))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertTrue(pDistanceRecorder.joined().contains(#""event":"msaActionComplete""#))
    }

    func testAnnotateAddSubcommandWritesSQLiteAnnotationStoreAndProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("input.fasta")
        try """
        >seq1
        A-CG-T
        >seq2
        ATCGGT

        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: sourceURL,
            to: bundleURL,
            options: .init(name: "input")
        )

        let command = try MSACommand.AddSubcommand.parse([
            bundleURL.path,
            "--row", "seq1",
            "--columns", "3-6",
            "--name", "selection-feature",
            "--type", "gene",
            "--strand", "+",
            "--qualifier", "created_by=cli-test",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try command.executeForTesting { recorder.append($0) }

        let updated = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let store = try updated.loadAnnotationStore()
        XCTAssertEqual(store.sourceAnnotations.count, 1)
        let annotation = try XCTUnwrap(store.sourceAnnotations.first)
        XCTAssertEqual(annotation.origin, .manual)
        XCTAssertEqual(annotation.rowName, "seq1")
        XCTAssertEqual(annotation.name, "selection-feature")
        XCTAssertEqual(annotation.type, "gene")
        XCTAssertEqual(annotation.strand, "+")
        XCTAssertEqual(annotation.qualifiers["created_by"], ["cli-test"])
        XCTAssertEqual(annotation.sourceIntervals, [AnnotationInterval(start: 1, end: 4)])
        XCTAssertEqual(annotation.alignedIntervals, [
            AnnotationInterval(start: 2, end: 4),
            AnnotationInterval(start: 5, end: 6),
        ])

        XCTAssertTrue(updated.manifest.capabilities.contains("annotation-authoring"))
        XCTAssertEqual(
            updated.manifest.checksums["metadata/annotations.sqlite"],
            try sha256(at: bundleURL.appendingPathComponent("metadata/annotations.sqlite"))
        )

        let provenanceURL = bundleURL.appendingPathComponent("metadata/annotation-edit-provenance.json")
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-annotation-add""#))
        XCTAssertTrue(provenance.contains(#""toolName" : "lungfish msa annotate add""#))
        XCTAssertTrue(provenance.contains(#""--strand""#))
        XCTAssertTrue(provenance.contains(#""created_by=cli-test""#))
        XCTAssertFalse(provenance.contains("/tmp/"))

        let events = recorder.joined()
        XCTAssertTrue(events.contains(#""event":"msaActionStart""#))
        XCTAssertTrue(events.contains(#""event":"msaActionComplete""#))
        XCTAssertTrue(events.contains(#""actionID":"msa.annotation.add""#))
    }

    func testAnnotateProjectSubcommandProjectsAnnotationAcrossRowsWithProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("input.fasta")
        try """
        >seq1
        A-CG-T
        >seq2
        ATCGGT

        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: sourceURL,
            to: bundleURL,
            options: .init(name: "input")
        )

        let addCommand = try MSACommand.AddSubcommand.parse([
            bundleURL.path,
            "--row", "seq1",
            "--columns", "3-6",
            "--name", "selection-feature",
            "--type", "gene",
            "--strand", "+",
            "--format", "json",
        ])
        try addCommand.executeForTesting { _ in }

        let authored = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let sourceAnnotation = try XCTUnwrap(authored.loadAnnotationStore().sourceAnnotations.first)
        let projectCommand = try MSACommand.ProjectSubcommand.parse([
            bundleURL.path,
            "--source-annotation", sourceAnnotation.id,
            "--target-rows", "seq2",
            "--conflict-policy", "append",
            "--format", "json",
        ])
        let recorder = LineRecorder()

        try projectCommand.executeForTesting { recorder.append($0) }

        let updated = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let store = try updated.loadAnnotationStore()
        XCTAssertEqual(store.sourceAnnotations.count, 1)
        XCTAssertEqual(store.projectedAnnotations.count, 1)
        let projected = try XCTUnwrap(store.projectedAnnotations.first)
        XCTAssertEqual(projected.origin, .projected)
        XCTAssertEqual(projected.rowName, "seq2")
        XCTAssertEqual(projected.name, "selection-feature")
        XCTAssertEqual(projected.projection?.sourceRowName, "seq1")
        XCTAssertEqual(projected.projection?.targetRowName, "seq2")
        XCTAssertEqual(projected.projection?.conflictPolicy, .append)
        XCTAssertEqual(projected.sourceIntervals, [
            AnnotationInterval(start: 2, end: 4),
            AnnotationInterval(start: 5, end: 6),
        ])
        XCTAssertEqual(projected.alignedIntervals, [
            AnnotationInterval(start: 2, end: 4),
            AnnotationInterval(start: 5, end: 6),
        ])
        XCTAssertTrue(updated.manifest.capabilities.contains("annotation-projection"))

        let provenanceURL = bundleURL.appendingPathComponent("metadata/annotation-edit-provenance.json")
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-annotation-project""#))
        XCTAssertTrue(provenance.contains(#""toolName" : "lungfish msa annotate project""#))
        XCTAssertTrue(provenance.contains(sourceAnnotation.id))
        XCTAssertTrue(provenance.contains(#""seq2""#))
        XCTAssertFalse(provenance.contains("/tmp/"))

        let events = recorder.joined()
        XCTAssertTrue(events.contains(#""event":"msaActionStart""#))
        XCTAssertTrue(events.contains(#""event":"msaActionComplete""#))
        XCTAssertTrue(events.contains(#""actionID":"msa.annotation.project""#))
    }

    func testAnnotateEditAndDeleteSubcommandsMutateSQLiteStoreWithProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/MSACommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("input.fasta")
        try """
        >seq1
        A-CG-T

        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: sourceURL,
            to: bundleURL,
            options: .init(name: "input")
        )

        let addCommand = try MSACommand.AddSubcommand.parse([
            bundleURL.path,
            "--row", "seq1",
            "--columns", "3-6",
            "--name", "selection-feature",
            "--type", "gene",
            "--strand", "+",
            "--format", "json",
        ])
        try addCommand.executeForTesting { _ in }
        let added = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let original = try XCTUnwrap(added.loadAnnotationStore().sourceAnnotations.first)

        let editCommand = try MSACommand.EditSubcommand.parse([
            bundleURL.path,
            "--annotation", original.id,
            "--name", "curated-feature",
            "--type", "CDS",
            "--strand", "-",
            "--note", "reviewed in alignment",
            "--format", "json",
        ])
        let editRecorder = LineRecorder()

        try editCommand.executeForTesting { editRecorder.append($0) }

        let edited = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let editedAnnotation = try XCTUnwrap(edited.loadAnnotationStore().sourceAnnotations.first)
        XCTAssertEqual(editedAnnotation.id, original.id)
        XCTAssertEqual(editedAnnotation.name, "curated-feature")
        XCTAssertEqual(editedAnnotation.type, "CDS")
        XCTAssertEqual(editedAnnotation.strand, "-")
        XCTAssertEqual(editedAnnotation.note, "reviewed in alignment")
        XCTAssertEqual(editedAnnotation.sourceIntervals, original.sourceIntervals)
        XCTAssertEqual(editedAnnotation.alignedIntervals, original.alignedIntervals)

        var provenance = try String(
            contentsOf: bundleURL.appendingPathComponent("metadata/annotation-edit-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-annotation-edit""#))
        XCTAssertTrue(provenance.contains(#""toolName" : "lungfish msa annotate edit""#))
        XCTAssertTrue(provenance.contains(original.id))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertTrue(editRecorder.joined().contains(#""actionID":"msa.annotation.edit""#))
        XCTAssertTrue(editRecorder.joined().contains(#""event":"msaActionComplete""#))

        let deleteCommand = try MSACommand.DeleteSubcommand.parse([
            bundleURL.path,
            "--annotation", original.id,
            "--format", "json",
        ])
        let deleteRecorder = LineRecorder()

        try deleteCommand.executeForTesting { deleteRecorder.append($0) }

        let deleted = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        XCTAssertEqual(try deleted.loadAnnotationStore().allAnnotations, [])
        provenance = try String(
            contentsOf: bundleURL.appendingPathComponent("metadata/annotation-edit-provenance.json"),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-annotation-delete""#))
        XCTAssertTrue(provenance.contains(#""toolName" : "lungfish msa annotate delete""#))
        XCTAssertTrue(provenance.contains(original.id))
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertTrue(deleteRecorder.joined().contains(#""actionID":"msa.annotation.delete""#))
        XCTAssertTrue(deleteRecorder.joined().contains(#""event":"msaActionComplete""#))
    }
}

private final class LineRecorder {
    private var storage: [String] = []

    func append(_ line: String) {
        storage.append(line)
    }

    func lines() -> [String] {
        storage
    }

    func joined() -> String {
        storage.joined(separator: "\n")
    }
}

private func sha256(at url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return MultipleSequenceAlignmentBundle.sha256Hex(for: data)
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func normalizedFileText(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: "\\/", with: "/")
}

private func assertReferenceOutputBundleRecord(
    _ provenance: [String: Any],
    outputURL: URL,
    expectedChecksum: String,
    expectedFileSize: Int64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let outputBundle = try XCTUnwrap(provenance["outputBundle"] as? [String: Any], file: file, line: line)
    XCTAssertEqual(outputBundle["path"] as? String, outputURL.path, file: file, line: line)
    XCTAssertEqual(outputBundle["checksumSHA256"] as? String, expectedChecksum, file: file, line: line)
    XCTAssertEqual(jsonInt64(outputBundle["fileSize"]), expectedFileSize, file: file, line: line)
}

private func assertFinalFileRecordsHaveChecksumsAndSizes(
    _ provenance: [String: Any],
    keys: [String],
    rootedAt outputURL: URL,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    for key in keys {
        let records = try XCTUnwrap(provenance[key] as? [[String: Any]], file: file, line: line)
        XCTAssertFalse(records.isEmpty, file: file, line: line)
        for record in records {
            let path = try XCTUnwrap(record["path"] as? String, file: file, line: line)
            XCTAssertTrue(path.hasPrefix(outputURL.path + "/"), file: file, line: line)
            XCTAssertFalse(path.contains("/.tmp/"), file: file, line: line)
            let checksum = try XCTUnwrap(record["checksumSHA256"] as? String, file: file, line: line)
            XCTAssertEqual(checksum.count, 64, file: file, line: line)
            XCTAssertGreaterThan(jsonInt64(record["fileSize"]) ?? 0, 0, file: file, line: line)
        }
    }
}

private func visibleDirectoryChecksum(at url: URL) throws -> String {
    let entries = try visibleDirectoryFileRecords(at: url)
        .map { "\($0.relativePath)\t\($0.fileSize)\t\($0.checksum)" }
        .sorted()
        .joined(separator: "\n")
    return MultipleSequenceAlignmentBundle.sha256Hex(for: Data(entries.utf8))
}

private func visibleDirectorySize(at url: URL) throws -> Int64 {
    try visibleDirectoryFileRecords(at: url).reduce(Int64(0)) { $0 + $1.fileSize }
}

private func visibleDirectoryFileRecords(at url: URL) throws -> [(relativePath: String, fileSize: Int64, checksum: String)] {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var records: [(relativePath: String, fileSize: Int64, checksum: String)] = []
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { continue }
        let relativePath = String(fileURL.path.dropFirst(url.path.count + 1))
        let data = try Data(contentsOf: fileURL)
        records.append((
            relativePath: relativePath,
            fileSize: Int64(values.fileSize ?? data.count),
            checksum: MultipleSequenceAlignmentBundle.sha256Hex(for: data)
        ))
    }
    return records
}

private func jsonInt64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber {
        return number.int64Value
    }
    if let value = value as? Int64 {
        return value
    }
    if let value = value as? Int {
        return Int64(value)
    }
    return nil
}

private func makeMSABundle(in tempDir: URL, contents: String, name: String) throws -> URL {
    let sourceURL = tempDir.appendingPathComponent("\(name).fasta")
    try contents.write(to: sourceURL, atomically: true, encoding: .utf8)
    let bundleURL = tempDir.appendingPathComponent("\(name).lungfishmsa", isDirectory: true)
    _ = try MultipleSequenceAlignmentBundle.importAlignment(
        from: sourceURL,
        to: bundleURL,
        options: .init(name: name)
    )
    return bundleURL
}

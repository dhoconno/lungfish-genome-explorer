import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class TreeCommandTests: XCTestCase {
    func testInferIQTreeResolverFindsManagedPluginPackExecutableWhenPathDoesNotIncludeIt() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/TreeCommandManagedIQTreeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let homeDirectory = tempDir.appendingPathComponent("home", isDirectory: true)
        let managedBin = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/iqtree/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        let managedIQTree = try writeFakeIQTreeExecutable(in: managedBin)

        let resolved = try TreeCommand.InferIQTreeSubcommand.resolveIQTreeExecutableForTesting(
            iqtreePath: nil,
            environment: ["PATH": "/usr/bin:/bin"],
            managedHomeDirectory: homeDirectory
        )

        XCTAssertEqual(resolved.path, managedIQTree.standardizedFileURL.path)
    }

    func testInferIQTreeCreatesNativeTreeBundleArtifactsAndProvenance() async throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/TreeCommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let msaSourceURL = tempDir.appendingPathComponent("input.aligned.fasta")
        try """
        >A
        ACGT
        >B
        ACGA

        """.write(to: msaSourceURL, atomically: true, encoding: .utf8)
        let msaBundleURL = projectURL.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: msaSourceURL,
            to: msaBundleURL,
            options: .init(name: "Input")
        )

        let fakeIQTreeURL = try writeFakeIQTreeExecutable(in: tempDir)
        let outputURL = projectURL.appendingPathComponent("Phylogenetic Trees/Test Tree.lungfishtree", isDirectory: true)
        let command = try TreeCommand.InferIQTreeSubcommand.parse([
            msaBundleURL.path,
            "--project", projectURL.path,
            "--output", outputURL.path,
            "--name", "Test Tree",
            "--model", "GTR+G",
            "--bootstrap", "1000",
            "--seed", "42",
            "--iqtree-path", fakeIQTreeURL.path,
            "--format", "json",
        ])
        let recorder = TreeLineRecorder()

        try await command.executeForTesting { recorder.append($0) }

        let bundle = try PhylogeneticTreeBundle.load(from: outputURL)
        XCTAssertEqual(bundle.manifest.name, "Test Tree")
        XCTAssertEqual(Set(bundle.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)), ["A", "B"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("artifacts/iqtree/run.iqtree").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("artifacts/iqtree/run.log").path))

        let provenance = try String(contentsOf: outputURL.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""workflowName" : "phylogenetic-tree-infer-iqtree""#))
        let provenanceJSON = try jsonObject(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertEqual(provenanceJSON["toolName"] as? String, "lungfish tree infer iqtree")
        XCTAssertEqual(provenanceJSON["toolVersion"] as? String, PhylogeneticTreeBundleImporter.toolVersion)
        let externalTool = try XCTUnwrap(provenanceJSON["externalTool"] as? [String: Any])
        XCTAssertEqual(externalTool["toolName"] as? String, "iqtree3")
        XCTAssertEqual(externalTool["toolVersion"] as? String, "3.1.1")
        XCTAssertEqual(externalTool["executablePath"] as? String, fakeIQTreeURL.path)
        XCTAssertEqual(externalTool["exitStatus"] as? Int, 0)
        XCTAssertNotNil(externalTool["wallTimeSeconds"])
        XCTAssertTrue((externalTool["stdout"] as? String)?.contains("fake iqtree stdout") == true)
        XCTAssertTrue((externalTool["stderr"] as? String)?.contains("fake iqtree stderr") == true)
        XCTAssertTrue((externalTool["reproducibleCommand"] as? String)?.contains("artifacts/iqtree/input.aligned.fasta") == true)
        XCTAssertTrue((externalTool["argv"] as? [String])?.contains(outputURL.appendingPathComponent("artifacts/iqtree/input.aligned.fasta").path) == true)
        XCTAssertTrue(provenance.contains(msaBundleURL.path) || provenance.contains(msaBundleURL.path.replacingOccurrences(of: "/", with: "\\/")))
        XCTAssertTrue(provenance.contains(#""model" : "GTR+G""#))
        XCTAssertTrue(provenance.contains(#""bootstrap" : "1000""#))
        XCTAssertTrue(
            provenance.contains("artifacts/iqtree/run.iqtree")
                || provenance.contains("artifacts\\/iqtree\\/run.iqtree")
        )
        XCTAssertTrue(
            provenance.contains("artifacts/iqtree/input.aligned.fasta")
                || provenance.contains("artifacts\\/iqtree\\/input.aligned.fasta")
        )
        XCTAssertFalse(provenance.contains("/tmp/"))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertFalse(provenance.contains("\\/.tmp\\/"))

        XCTAssertTrue(recorder.joined().contains(#""event":"treeInferenceComplete""#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(".tmp").path))
    }

    func testInferIQTreeFailureCapturesStderrAndRemovesOutputBundle() async throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/TreeCommandFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let msaSourceURL = tempDir.appendingPathComponent("input.aligned.fasta")
        try """
        >A
        ACGT
        >B
        ACGA

        """.write(to: msaSourceURL, atomically: true, encoding: .utf8)
        let msaBundleURL = projectURL.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: msaSourceURL,
            to: msaBundleURL,
            options: .init(name: "Input")
        )

        let fakeIQTreeURL = try writeFailingIQTreeExecutable(in: tempDir)
        let outputURL = projectURL.appendingPathComponent("Phylogenetic Trees/Failed Tree.lungfishtree", isDirectory: true)
        let command = try TreeCommand.InferIQTreeSubcommand.parse([
            msaBundleURL.path,
            "--project", projectURL.path,
            "--output", outputURL.path,
            "--iqtree-path", fakeIQTreeURL.path,
            "--format", "json",
        ])
        let recorder = TreeLineRecorder()

        do {
            try await command.executeForTesting { recorder.append($0) }
            XCTFail("Expected IQ-TREE failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("simulated IQ-TREE failure"), error.localizedDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(".tmp").path))
        XCTAssertTrue(recorder.joined().contains(#""event":"treeInferenceFailed""#))
        XCTAssertTrue(recorder.joined().contains("simulated IQ-TREE failure"))
    }

    func testInferIQTreeSupportsRowColumnSelectionAndRecordsFinalPayloadProvenance() async throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/TreeCommandSelectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let msaSourceURL = tempDir.appendingPathComponent("input.aligned.fasta")
        try """
        >A
        ACGT
        >B
        ACGA
        >C
        TTGG

        """.write(to: msaSourceURL, atomically: true, encoding: .utf8)
        let msaBundleURL = projectURL.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: msaSourceURL,
            to: msaBundleURL,
            options: .init(name: "Input")
        )

        let fakeIQTreeURL = try writeFakeIQTreeExecutable(in: tempDir)
        let outputURL = projectURL.appendingPathComponent("Phylogenetic Trees/Selected Tree.lungfishtree", isDirectory: true)
        let command = try TreeCommand.InferIQTreeSubcommand.parse([
            msaBundleURL.path,
            "--project", projectURL.path,
            "--output", outputURL.path,
            "--name", "Selected Tree",
            "--rows", "A,C",
            "--columns", "2-3",
            "--iqtree-path", fakeIQTreeURL.path,
            "--format", "json",
        ])
        let recorder = TreeLineRecorder()

        try await command.executeForTesting { recorder.append($0) }

        let storedInputURL = outputURL.appendingPathComponent("artifacts/iqtree/input.aligned.fasta")
        XCTAssertEqual(try String(contentsOf: storedInputURL, encoding: .utf8), """
        >A
        CG
        >C
        TG
        """ + "\n")

        let provenance = try String(contentsOf: outputURL.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertTrue(provenance.contains(#""rows" : "A,C""#))
        XCTAssertTrue(provenance.contains(#""columns" : "2-3""#))
        XCTAssertTrue(provenance.contains(#""selectedRowCount" : "2""#))
        XCTAssertTrue(provenance.contains(#""selectedAlignedLength" : "2""#))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertFalse(provenance.contains("\\/.tmp\\/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"treeInferenceComplete""#))
    }

    func testInferIQTreePassesCuratedAndAdvancedOptionsToIQTreeAndProvenance() async throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/TreeCommandIQTreeOptionsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let msaSourceURL = tempDir.appendingPathComponent("input.aligned.fasta")
        try """
        >A
        ACGT
        >B
        ACGA

        """.write(to: msaSourceURL, atomically: true, encoding: .utf8)
        let msaBundleURL = projectURL.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: msaSourceURL,
            to: msaBundleURL,
            options: .init(name: "Input")
        )

        let fakeIQTreeURL = try writeFakeIQTreeExecutable(in: tempDir)
        let outputURL = projectURL.appendingPathComponent("Phylogenetic Trees/Options Tree.lungfishtree", isDirectory: true)
        let command = try TreeCommand.InferIQTreeSubcommand.parse([
            msaBundleURL.path,
            "--project", projectURL.path,
            "--output", outputURL.path,
            "--name", "Options Tree",
            "--model", "JC",
            "--sequence-type", "DNA",
            "--bootstrap", "1000",
            "--alrt", "1000",
            "--seed", "12345",
            "--threads", "2",
            "--safe",
            "--keep-identical",
            "--extra-iqtree-options", "-bnni --pathogen",
            "--iqtree-path", fakeIQTreeURL.path,
            "--format", "json",
        ])

        try await command.executeForTesting { _ in }

        let provenanceJSON = try jsonObject(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        let options = try XCTUnwrap(provenanceJSON["options"] as? [String: String])
        XCTAssertEqual(options["model"], "JC")
        XCTAssertEqual(options["sequenceType"], "DNA")
        XCTAssertEqual(options["bootstrap"], "1000")
        XCTAssertEqual(options["alrt"], "1000")
        XCTAssertEqual(options["safeMode"], "true")
        XCTAssertEqual(options["keepIdenticalSequences"], "true")
        XCTAssertEqual(options["advancedArguments"], "-bnni --pathogen")

        let externalTool = try XCTUnwrap(provenanceJSON["externalTool"] as? [String: Any])
        let externalArguments = try XCTUnwrap(externalTool["arguments"] as? [String])
        XCTAssertTrue(externalArguments.contains("-st"))
        XCTAssertTrue(externalArguments.contains("DNA"))
        XCTAssertTrue(externalArguments.contains("-B"))
        XCTAssertTrue(externalArguments.contains("1000"))
        XCTAssertTrue(externalArguments.contains("-alrt"))
        XCTAssertTrue(externalArguments.contains("-safe"))
        XCTAssertTrue(externalArguments.contains("-keep-ident"))
        XCTAssertTrue(externalArguments.contains("-bnni"))
        XCTAssertTrue(externalArguments.contains("--pathogen"))
    }

    func testSubtreeExportWritesNewickAndProvenance() throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/TreeCommandSubtreeExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("source.nwk")
        try "((A:0.1,B:0.2)Clade:0.3,C:0.4);".write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("Tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(
            from: sourceURL,
            to: bundleURL,
            options: .init(name: "Tree")
        )

        let outputURL = tempDir.appendingPathComponent("clade.nwk")
        let command = try TreeCommand.ExportSubcommand.SubtreeSubcommand.parse([
            bundleURL.path,
            "--label", "Clade",
            "--output", outputURL.path,
            "--format", "json",
        ])
        let recorder = TreeLineRecorder()

        try command.executeForTesting { recorder.append($0) }

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "(A:0.1,B:0.2)Clade:0.3;\n")
        let provenanceURL = outputURL.appendingPathExtension("lungfish-provenance.json")
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        let provenanceJSON = try jsonObject(at: provenanceURL)
        XCTAssertEqual(provenanceJSON["workflowName"] as? String, "phylogenetic-tree-subtree-export")
        XCTAssertEqual(provenanceJSON["toolName"] as? String, "lungfish tree export subtree")
        XCTAssertEqual((provenanceJSON["inputBundle"] as? [String: Any])?["path"] as? String, bundleURL.path)
        XCTAssertEqual((provenanceJSON["outputFile"] as? [String: Any])?["path"] as? String, outputURL.path)
        XCTAssertEqual((provenanceJSON["options"] as? [String: Any])?["selectionMode"] as? String, "label")
        XCTAssertEqual((provenanceJSON["options"] as? [String: Any])?["label"] as? String, "Clade")
        XCTAssertEqual((provenanceJSON["options"] as? [String: Any])?["selectedTipCount"] as? Int, 2)
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertFalse(provenance.contains("\\/.tmp\\/"))
        XCTAssertTrue(recorder.joined().contains(#""event":"treeExportComplete""#))
    }

    private func writeFakeIQTreeExecutable(in directory: URL, expectedInput: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent("iqtree3")
        let expectedInputCheck: String
        if let expectedInput {
            let expectedURL = directory.appendingPathComponent("expected-iqtree-input.fasta")
            try expectedInput.write(to: expectedURL, atomically: true, encoding: .utf8)
            expectedInputCheck = """
            if ! cmp -s "$input" "\(expectedURL.path)"; then
              echo "unexpected IQ-TREE input" >&2
              cat "$input" >&2
              exit 3
            fi
            """
        } else {
            expectedInputCheck = ""
        }
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "IQ-TREE multicore version 3.1.1"
          exit 0
        fi
        prefix=""
        input=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --prefix)
              prefix="$2"
              shift 2
              ;;
            -s)
              input="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        if [ -z "$prefix" ]; then
          echo "missing prefix" >&2
          exit 2
        fi
        \(expectedInputCheck)
        printf "fake iqtree stdout\\n"
        printf "fake iqtree stderr\\n" >&2
        printf "(A:0.1,B:0.2);\\n" > "$prefix.treefile"
        printf "IQ-TREE report\\n" > "$prefix.iqtree"
        printf "IQ-TREE log\\n" > "$prefix.log"
        exit 0
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writeFailingIQTreeExecutable(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("iqtree3-fails")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "IQ-TREE multicore version 3.1.1"
          exit 0
        fi
        printf "simulated IQ-TREE failure\\n" >&2
        exit 7
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}

private final class TreeLineRecorder {
    private var storage: [String] = []

    func append(_ line: String) {
        storage.append(line)
    }

    func joined() -> String {
        storage.joined(separator: "\n")
    }
}

import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class ScientificFASTQProvenancePolicyTests: XCTestCase {
    func testFASTQOperationToolsThatChangeDataRequireProvenance() {
        let missing = FASTQOperationToolID.allCases.filter { tool in
            tool.createsOrModifiesScientificData && !tool.requiresProvenance
        }

        XCTAssertTrue(
            missing.isEmpty,
            "FASTQ tools missing provenance: \(missing.map(\.rawValue).joined(separator: ", "))"
        )
    }

    func testRefreshQCSummaryIsReadOnlyForProvenancePolicy() {
        XCTAssertFalse(FASTQOperationToolID.refreshQCSummary.createsOrModifiesScientificData)
        XCTAssertFalse(FASTQOperationToolID.refreshQCSummary.requiresProvenance)
    }

    func testOrientDerivativeFromVirtualSourceRecordsDurableInputProvenance() async throws {
        let fixture = try ManagedToolFixture()
        defer { fixture.cleanup() }

        let projectURL = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let rootBundleURL = projectURL.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("reads.fastq")
        try """
        @read-1
        ACGT
        +
        IIII
        @read-2
        TGCA
        +
        IIII

        """.write(to: rootFASTQURL, atomically: true, encoding: .utf8)

        let sourceBundleURL = projectURL.appendingPathComponent("virtual-source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try "read-1\nread-2\n".write(
            to: sourceBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        let sourceManifest = FASTQDerivedBundleManifest(
            name: "virtual-source",
            parentBundleRelativePath: "../\(rootBundleURL.lastPathComponent)",
            rootBundleRelativePath: "../\(rootBundleURL.lastPathComponent)",
            rootFASTQFilename: rootFASTQURL.lastPathComponent,
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [FASTQDerivativeOperation(kind: .subsampleCount, count: 2)],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 2),
            cachedStatistics: .placeholder(readCount: 2, baseCount: 8),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(sourceManifest, in: sourceBundleURL)

        let referenceURL = projectURL.appendingPathComponent("reference.fa")
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let service = FASTQDerivativeService(runner: fixture.runner)
        let extraArguments = ["--id", "0.97"]
        let orientBundleURL = try await service.createDerivative(
            from: sourceBundleURL,
            request: .orient(
                referenceURL: referenceURL,
                wordLength: 11,
                dbMask: "none",
                saveUnoriented: true,
                extraArguments: extraArguments
            ),
            progress: nil
        )

        let provenanceURL = orientBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: provenanceURL))
        XCTAssertFalse(envelope.argv.contains { containsTempPathLeak($0) })
        XCTAssertFalse(
            containsTempPathLeak(envelope.reproducibleCommand),
            "Final orient reproducible command must not retain temp materialized or staging paths"
        )
        let topLevelInputPaths = envelope.files.filter { $0.role == .input }.map(\.path)
        let stepInputPaths = envelope.steps.flatMap { step in
            step.inputs.filter { $0.role == .input }.map(\.path)
        }
        let inputPaths = Set(topLevelInputPaths + stepInputPaths)
        XCTAssertTrue(inputPaths.contains(sourceBundleURL.path))
        XCTAssertFalse(inputPaths.contains { $0.contains("materialized-") || $0.contains("fastq-derive-") })

        XCTAssertEqual(envelope.options.explicit["forwardCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.explicit["reverseComplementedCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.explicit["unmatchedCount"]?.integerValue, 1)
        XCTAssertEqual(
            envelope.options.explicit["extraArguments"]?.arrayValue?.compactMap(\.stringValue),
            extraArguments
        )
        let orientMapPath = orientBundleURL.appendingPathComponent("orient-map.tsv").path
        let previewPath = orientBundleURL.appendingPathComponent("preview.fastq").path
        XCTAssertTrue(envelope.outputs.contains { $0.path == orientMapPath })
        XCTAssertTrue(envelope.outputs.contains { $0.path == previewPath })
        let vsearchSteps = envelope.steps.filter { $0.toolName == "vsearch" }
        let appSteps = envelope.steps.filter { $0.toolName == "Lungfish App" }
        XCTAssertFalse(appSteps.flatMap(\.argv).contains { containsTempPathLeak($0) })
        XCTAssertTrue(appSteps.contains { $0.outputs.contains { $0.path == orientMapPath } })
        XCTAssertTrue(appSteps.contains { $0.outputs.contains { $0.path == previewPath } })
        XCTAssertFalse(vsearchSteps.contains { $0.outputs.contains { $0.path == orientMapPath || $0.path == previewPath } })
        XCTAssertTrue(vsearchSteps.flatMap(\.outputs).allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        for step in vsearchSteps {
            let durableStepArgv = try XCTUnwrap(step.durableReplayArgv)
            XCTAssertFalse(durableStepArgv.contains { containsTempPathLeak($0) })
            XCTAssertFalse(containsTempPathLeak(step.reproducibleCommand))
            XCTAssertTrue(durableStepArgv.contains("--id"))
            XCTAssertTrue(durableStepArgv.contains("0.97"))
        }
        let vsearchOutputPaths = vsearchSteps.flatMap(\.outputs).map(\.path)
        XCTAssertTrue(vsearchOutputPaths.contains { $0.hasSuffix("vsearch-oriented.fastq") })
        XCTAssertTrue(vsearchOutputPaths.contains { $0.hasSuffix("vsearch-orient-results.tsv") })
        XCTAssertTrue(vsearchOutputPaths.contains { $0.hasSuffix("vsearch-unoriented.fastq") })
        XCTAssertFalse(vsearchOutputPaths.contains { containsTempPathLeak($0) })

        let provenanceJSON = try jsonObject(at: provenanceURL)
        let durableReplayArgv = try XCTUnwrap(provenanceJSON["durableReplayArgv"] as? [String])
        XCTAssertFalse(durableReplayArgv.contains { containsTempPathLeak($0) })
        let stepsJSON = try XCTUnwrap(provenanceJSON["steps"] as? [[String: Any]])
        for stepJSON in stepsJSON {
            guard stepJSON["toolName"] as? String == "Lungfish App" else { continue }
            let durableStepArgv = try XCTUnwrap(stepJSON["durableReplayArgv"] as? [String])
            XCTAssertFalse(durableStepArgv.contains { containsTempPathLeak($0) })
        }

        let explicitOptions = try XCTUnwrap(provenanceJSON["options"] as? [String: Any])["explicit"] as? [String: Any]
        let optionsText = String(data: try JSONSerialization.data(withJSONObject: explicitOptions ?? [:]), encoding: .utf8) ?? ""
        XCTAssertFalse(containsTempPathLeak(optionsText), "Rehydrated options must not leak staging paths")

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: orientBundleURL))
        let manifestCommands = ([manifest.operation] + manifest.lineage)
            .compactMap { (operation: FASTQDerivativeOperation) in operation.toolCommand }
        XCTAssertFalse(manifestCommands.isEmpty)
        XCTAssertFalse(
            manifestCommands.contains { containsTempPathLeak($0) },
            "Final orient manifest command strings must not retain temp materialized or staging paths"
        )
        XCTAssertTrue(
            manifest.operation.toolCommand?.contains(sourceBundleURL.path) == true,
            "Final orient manifest command should identify the durable source bundle"
        )
        XCTAssertFalse(
            manifest.operation.toolCommand?.contains("lungfish-orient-") == true,
            "Final orient manifest command must not retain staging paths when saving unoriented reads"
        )
        XCTAssertFalse(manifest.operation.toolCommand?.contains("--fastqout") == true)
        XCTAssertFalse(manifest.operation.toolCommand?.contains("--notmatched") == true)
        XCTAssertTrue(
            manifest.operation.toolCommand?.contains("--save-unoriented") == true,
            "GUI orient manifest command should describe the app-owned unoriented output"
        )
        XCTAssertTrue(manifest.operation.toolCommand?.contains("--extra-args") == true)
        XCTAssertTrue(manifest.operation.toolCommand?.contains("--id") == true)
        XCTAssertTrue(
            manifest.operation.toolCommand?.contains("unoriented.fastq") == true,
            "GUI orient manifest command should point at the durable sibling payload"
        )

        let derivativesURL = sourceBundleURL.appendingPathComponent("derivatives", isDirectory: true)
        let unorientedBundleURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: derivativesURL,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix("unoriented-")
                    && $0.pathExtension == FASTQBundle.directoryExtension
            }
        )
        let unorientedProvenanceURL = unorientedBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unorientedProvenanceURL.path))
        let unorientedEnvelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: unorientedProvenanceURL))
        let expectedUnorientedPayloadPath = unorientedBundleURL
            .appendingPathComponent("unoriented.fastq")
            .standardizedFileURL
            .path
        XCTAssertTrue(
            unorientedEnvelope.outputs.contains {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == expectedUnorientedPayloadPath
            }
        )
        XCTAssertEqual(
            unorientedEnvelope.options.explicit["extraArguments"]?.arrayValue?.compactMap(\.stringValue),
            extraArguments
        )
        let unorientedAppSteps = unorientedEnvelope.steps.filter { $0.toolName == "Lungfish App" }
        let unorientedVsearchSteps = unorientedEnvelope.steps.filter { $0.toolName == "vsearch" }
        XCTAssertTrue(unorientedAppSteps.contains { step in
            step.outputs.contains { URL(fileURLWithPath: $0.path).standardizedFileURL.path == expectedUnorientedPayloadPath }
        })
        XCTAssertFalse(unorientedVsearchSteps.contains { step in
            step.outputs.contains { URL(fileURLWithPath: $0.path).standardizedFileURL.path == expectedUnorientedPayloadPath }
        })
        for step in unorientedVsearchSteps {
            let durableStepArgv = try XCTUnwrap(step.durableReplayArgv)
            XCTAssertFalse(durableStepArgv.contains { containsTempPathLeak($0) })
            XCTAssertFalse(containsTempPathLeak(step.reproducibleCommand))
            XCTAssertTrue(durableStepArgv.contains("--id"))
            XCTAssertTrue(durableStepArgv.contains("0.97"))
        }
        let unorientedVsearchOutputPaths = unorientedVsearchSteps.flatMap(\.outputs).map(\.path)
        XCTAssertTrue(unorientedVsearchOutputPaths.contains { $0.hasSuffix("vsearch-oriented.fastq") })
        XCTAssertTrue(unorientedVsearchOutputPaths.contains { $0.hasSuffix("vsearch-orient-results.tsv") })
        XCTAssertTrue(unorientedVsearchOutputPaths.contains { $0.hasSuffix("vsearch-unoriented.fastq") })
        XCTAssertFalse(unorientedVsearchOutputPaths.contains { containsTempPathLeak($0) })
        let unorientedJSON = try jsonObject(at: unorientedProvenanceURL)
        let unorientedStepsJSON = try XCTUnwrap(unorientedJSON["steps"] as? [[String: Any]])
        for stepJSON in unorientedStepsJSON {
            guard stepJSON["toolName"] as? String == "Lungfish App" else { continue }
            let unorientedDurableStepArgv = try XCTUnwrap(stepJSON["durableReplayArgv"] as? [String])
            XCTAssertFalse(unorientedDurableStepArgv.contains { containsTempPathLeak($0) })
        }
    }

    func testOrientDerivativeFromFASTASourceRecordsAppConversionForUnorientedPayload() async throws {
        let fixture = try ManagedToolFixture()
        defer { fixture.cleanup() }

        let projectURL = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let sourceBundleURL = projectURL.appendingPathComponent("source-fasta.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        let sourceFASTAURL = sourceBundleURL.appendingPathComponent("reads.fasta")
        try """
        >read-1
        ACGT
        >read-2
        TGCA

        """.write(to: sourceFASTAURL, atomically: true, encoding: .utf8)

        let referenceURL = projectURL.appendingPathComponent("reference.fa")
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let service = FASTQDerivativeService(runner: fixture.runner)
        let orientBundleURL = try await service.createDerivative(
            from: sourceBundleURL,
            request: .orient(
                referenceURL: referenceURL,
                wordLength: 11,
                dbMask: "none",
                saveUnoriented: true
            ),
            progress: nil
        )

        let orientEnvelope = try ProvenanceEnvelopeReader.decode(
            Data(contentsOf: orientBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        let orientAppSteps = orientEnvelope.steps.filter { $0.toolName == "Lungfish App" }
        let orientBridgeStep = try XCTUnwrap(orientAppSteps.first { step in
            step.argv.contains("lungfish-app-action:fastq-synthetic-fastq-from-fasta")
        })
        let orientBridgeOutput = try XCTUnwrap(orientBridgeStep.outputs.first { output in
            output.path.hasSuffix("bridged-source.fastq")
        })
        let previewStep = try XCTUnwrap(orientAppSteps.first { step in
            step.argv.contains("lungfish-app-action:fastq-preview-from-orientation-map")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: orientBridgeOutput.path))
        XCTAssertTrue(previewStep.argv.contains(orientBridgeOutput.path))
        XCTAssertTrue(previewStep.dependsOn.contains(orientBridgeStep.id))
        XCTAssertTrue(previewStep.inputs.contains { input in
            input.path == orientBridgeOutput.path
                && input.role == .input
                && input.checksumSHA256 == orientBridgeOutput.checksumSHA256
                && input.fileSize == orientBridgeOutput.fileSize
        })
        XCTAssertFalse(previewStep.inputs.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == sourceFASTAURL.standardizedFileURL.path
        })

        let derivativesURL = sourceBundleURL.appendingPathComponent("derivatives", isDirectory: true)
        let unorientedBundleURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: derivativesURL,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix("unoriented-")
                    && $0.pathExtension == FASTQBundle.directoryExtension
            }
        )
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: unorientedBundleURL))
        guard case .fullFASTA(let fastaFilename) = manifest.payload else {
            return XCTFail("Expected FASTA unoriented payload")
        }
        XCTAssertEqual(fastaFilename, "unoriented.fasta")
        XCTAssertEqual(manifest.sequenceFormat, .fasta)

        let outputPath = unorientedBundleURL.appendingPathComponent(fastaFilename).standardizedFileURL.path
        let envelope = try ProvenanceEnvelopeReader.decode(
            Data(contentsOf: unorientedBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertFalse(envelope.argv.contains { containsTempPathLeak($0) })
        XCTAssertTrue(envelope.outputs.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == outputPath && $0.format == .fasta
        })
        let appSteps = envelope.steps.filter { $0.toolName == "Lungfish App" }
        XCTAssertTrue(appSteps.contains { step in
            step.argv.contains("lungfish-app-action:fastq-synthetic-fastq-from-fasta")
                && step.inputs.contains {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path
                        == sourceFASTAURL.standardizedFileURL.path
                }
                && step.outputs.contains {
                    $0.path.hasSuffix("bridged-source.fastq")
                        && FileManager.default.fileExists(atPath: $0.path)
                }
        })
        let vsearchInputs = envelope.steps
            .filter { $0.toolName == "vsearch" }
            .flatMap(\.inputs)
        XCTAssertTrue(vsearchInputs.contains {
            $0.path.hasSuffix("bridged-source.fastq")
                && FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertTrue(appSteps.contains { step in
            step.argv.contains("lungfish-app-action:fastq-orient-unmatched-fastq-to-fasta-payload")
                && step.outputs.contains {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path == outputPath && $0.format == .fasta
                }
        })
        XCTAssertFalse(envelope.steps.filter { $0.toolName == "vsearch" }.contains { step in
            step.outputs.contains { URL(fileURLWithPath: $0.path).standardizedFileURL.path == outputPath }
        })
    }
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func containsTempPathLeak(_ value: String) -> Bool {
    value.contains("materialized-")
        || value.contains("fastq-derive-")
        || value.contains("lungfish-orient-")
}

private struct ManagedToolFixture {
    let root: URL
    let runner: NativeToolRunner

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-provenance-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        try Self.install(script: Self.seqkitScript(), tool: "seqkit", environment: "seqkit", homeDirectory: homeDirectory)
        try Self.install(script: Self.vsearchScript(), tool: "vsearch", environment: "vsearch", homeDirectory: homeDirectory)

        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func install(script: String, tool: String, environment: String, homeDirectory: URL) throws {
        let binURL = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let toolURL = binURL.appendingPathComponent(tool)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }

    private static func seqkitScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "version" ]; then
          echo "seqkit v2.8.2"
          exit 0
        fi
        if [ "$1" = "grep" ]; then
          shift
          ids=""
          out=""
          inputs=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -f)
                ids="$2"
                shift 2
                ;;
              -o)
                out="$2"
                shift 2
                ;;
              *)
                inputs="$inputs $1"
                shift
                ;;
            esac
          done
          first_input=$(echo "$inputs" | awk '{print $1}')
          cp "$first_input" "$out"
          exit 0
        fi
        if [ "$1" = "stats" ]; then
          file="$3"
          printf 'file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n'
          printf '%s\tFASTQ\tDNA\t2\t8\t4\t4.0\t4\n' "$file"
          exit 0
        fi
        exit 1
        """
    }

    private static func vsearchScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "vsearch v2.30.5"
          exit 0
        fi
        fastqout=""
        tabbedout=""
        notmatched=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --fastqout)
              fastqout="$2"
              shift 2
              ;;
            --tabbedout)
              tabbedout="$2"
              shift 2
              ;;
            --notmatched)
              notmatched="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        printf '@read-1\nACGT\n+\nIIII\n@read-2\nTGCA\n+\nIIII\n' > "$fastqout"
        printf 'read-1\t+\tref\nread-2\t-\tref\nread-3\t?\t*\n' > "$tabbedout"
        if [ -n "$notmatched" ]; then
          printf '@read-3\nTTTT\n+\nIIII\n' > "$notmatched"
        fi
        printf 'vsearch completed\n' >&2
        exit 0
        """
    }
}

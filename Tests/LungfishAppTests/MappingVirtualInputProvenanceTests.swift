// MappingVirtualInputProvenanceTests.swift - Virtual FASTQ inputs keep durable provenance on the live mapping path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// A mapping run whose input is a virtual FASTQ bundle reads a materialized
/// copy of that bundle's reads. Its provenance must still name the durable
/// inputs (the bundle, its derived manifest, the root FASTQ the reads come
/// from and the payload that selects them), and every file it names must
/// outlive the run. A record that points only at a scratch file the window
/// deletes when the run ends reproduces nothing.
///
/// The window path is driven through its production composition. The request
/// comes from `MappingWizardSheet.buildRunPlan`, and
/// `AppDelegate.resolveManagedMappingInputs` turns it into the request the
/// pipeline runs, exactly as `runSingleManagedMappingAwaitingCompletion` does.
/// `ManagedMappingPipeline` then runs with a stand-in mapper (micromamba)
/// and a stand-in samtools. The CLI-shaped control builds the request the way
/// `lungfish-cli map` does, so the same pipeline and the same assertions show
/// the fixture is sound.
@MainActor
final class MappingVirtualInputProvenanceTests: XCTestCase {

    func testWindowMappingOfVirtualBundleRecordsDurableBundleInputs() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        let analysisDirectory = try fixture.makeAnalysisDirectory()
        let request = try fixture.windowRequest(outputDirectory: analysisDirectory)

        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: request, progress: { _ in })
        _ = try await fixture.pipeline.run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason
        )
        // The window removes its scratch directory when the run ends.
        try FileManager.default.removeItem(at: resolved.scratchDirectory)

        try fixture.assertMapperReadMaterializedVirtualReads()
        try fixture.assertDurableVirtualInputProvenance(in: analysisDirectory)
    }

    func testWindowMappingRecordsTheSameInputsAsTheCLIForTheSameVirtualBundle() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        let windowDirectory = try fixture.makeAnalysisDirectory()
        let windowRequest = try fixture.windowRequest(outputDirectory: windowDirectory)
        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: windowRequest, progress: { _ in })
        _ = try await fixture.pipeline.run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason
        )
        try FileManager.default.removeItem(at: resolved.scratchDirectory)
        let windowReads = try fixture.readsSeenByMapper()

        let cliDirectory = try fixture.makeAnalysisDirectory()
        let cliShaped = try await fixture.cliShapedRequest(outputDirectory: cliDirectory)
        _ = try await fixture.pipeline.run(
            request: cliShaped.request,
            inputLayoutReason: cliShaped.layoutReason
        )
        let cliReads = try fixture.readsSeenByMapper()

        XCTAssertEqual(windowReads, cliReads, "the window and the CLI mapped different reads")

        let window = try XCTUnwrap(MappingProvenance.load(from: windowDirectory))
        let cli = try XCTUnwrap(MappingProvenance.load(from: cliDirectory))
        XCTAssertEqual(
            Self.comparableInputs(of: window, analysisDirectory: windowDirectory),
            Self.comparableInputs(of: cli, analysisDirectory: cliDirectory),
            "the window and the CLI recorded different input sets"
        )
        XCTAssertEqual(
            window.steps.map(\.toolName),
            cli.steps.map(\.toolName),
            "the window and the CLI recorded different steps"
        )
        XCTAssertNotNil(window.mapperInvocation.durableReplayArgv, "the window recorded no durable replay command")
        XCTAssertNotNil(cli.mapperInvocation.durableReplayArgv)
        XCTAssertEqual(
            Self.materializedInputChecksum(of: window),
            Self.materializedInputChecksum(of: cli),
            "the window and the CLI recorded different materialized reads"
        )
        XCTAssertNotNil(Self.materializedInputChecksum(of: cli))
    }

    func testCLIShapedRequestRecordsDurableBundleInputs() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        let analysisDirectory = try fixture.makeAnalysisDirectory()
        let cliShaped = try await fixture.cliShapedRequest(outputDirectory: analysisDirectory)
        _ = try await fixture.pipeline.run(
            request: cliShaped.request,
            inputLayoutReason: cliShaped.layoutReason
        )

        try fixture.assertMapperReadMaterializedVirtualReads()
        try fixture.assertDurableVirtualInputProvenance(in: analysisDirectory)
    }

    /// The recorded inputs with the run's own directory and the random part
    /// of a materialized file name masked, so two runs compare.
    private static func comparableInputs(
        of provenance: MappingProvenance,
        analysisDirectory: URL
    ) -> [String] {
        let analysisPrefix = analysisDirectory.standardizedFileURL.path + "/"
        return provenance.inputFiles
            .map { record -> String in
                var path = URL(fileURLWithPath: record.path).standardizedFileURL.path
                if path.hasPrefix(analysisPrefix) {
                    path = "<analysis>/" + path.dropFirst(analysisPrefix.count)
                }
                path = path.replacingOccurrences(
                    of: #"materialized-[0-9A-Fa-f-]+\."#,
                    with: "materialized.",
                    options: .regularExpression
                )
                return "\(record.role.rawValue) \(path)"
            }
            .sorted()
    }

    private static func materializedInputChecksum(of provenance: MappingProvenance) -> String? {
        provenance.inputFiles.first { $0.path.contains("/materialized-") }?.sha256
    }
}

/// A project with a root FASTQ bundle of three Illumina reads and a virtual
/// oriented bundle over it (read 1 forward, read 3 reverse-complemented,
/// read 2 left out), plus a stand-in mapper and samtools. Orient
/// materialization is pure Swift, so no real tool runs.
private struct StandInMappingFixture {
    let rootURL: URL
    let projectURL: URL
    let rootFASTQURL: URL
    let virtualBundleURL: URL
    let referenceURL: URL
    let readsSeenByMapperURL: URL
    let pipeline: ManagedMappingPipeline

    struct CLIShapedRequest {
        let request: MappingRunRequest
        let layoutReason: String
    }

    static let readIDs = [
        "A00488:385:HKGCLDRXX:1:1101:1000:1000",
        "A00488:385:HKGCLDRXX:1:1101:1001:1000",
        "A00488:385:HKGCLDRXX:1:1101:1002:1000",
    ]
    static let sequences = [
        String(repeating: "ACGTTGCA", count: 18) + "ACGTAC",
        String(repeating: "GGGCCCAA", count: 18) + "GGGCCC",
        String(repeating: "TTTAAACC", count: 18) + "TTTAAC",
    ]

    static func record(_ index: Int, sequence: String? = nil) -> String {
        let bases = sequence ?? sequences[index]
        return "@\(readIDs[index]) 1:N:0:1\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n"
    }

    static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return "N"
            }
        })
    }

    static func make() throws -> StandInMappingFixture {
        let fileManager = FileManager.default
        let root = try TestTempDirectory.make(prefix: "mapping-virtual-provenance")
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)

        let rootBundle = imports.appendingPathComponent("run.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFASTQ = rootBundle.appendingPathComponent("run.fastq")
        try (record(0) + record(1) + record(2)).write(to: rootFASTQ, atomically: true, encoding: .utf8)

        let virtualBundle = imports.appendingPathComponent("run-oriented.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: virtualBundle, withIntermediateDirectories: true)
        try "\(readIDs[0])\t+\n\(readIDs[2])\t-\n".write(
            to: virtualBundle.appendingPathComponent("orient-map.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try record(0).write(
            to: virtualBundle.appendingPathComponent("preview.fastq"),
            atomically: true,
            encoding: .utf8
        )
        let operation = FASTQDerivativeOperation(kind: .orient)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "run-oriented",
                parentBundleRelativePath: "@/Imports/run.lungfishfastq",
                rootBundleRelativePath: "@/Imports/run.lungfishfastq",
                rootFASTQFilename: "run.fastq",
                payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 300),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: virtualBundle
        )

        let reference = project.appendingPathComponent("reference.fa")
        try ">chr1\n\(String(repeating: "ACGTTGCA", count: 20))\n".write(
            to: reference,
            atomically: true,
            encoding: .utf8
        )

        // Stand-in mapper: the managed minimap2 environment exists, and a
        // stand-in micromamba answers the version probe, copies the reads it
        // was given aside, and writes a header-only SAM.
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let mapperBin = condaRoot.appendingPathComponent("envs/minimap2/bin", isDirectory: true)
        try fileManager.createDirectory(at: mapperBin, withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: mapperBin.appendingPathComponent("minimap2"))
        let readsSeen = root.appendingPathComponent("reads-seen-by-mapper.fastq")
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try writeExecutable(micromambaScript(readsSeenPath: readsSeen.path), to: micromamba)
        let condaManager = CondaManager(
            rootPrefix: condaRoot,
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )

        let samtoolsHome = try ManagedSamtoolsHome.makeStub(
            rootURL: root,
            namePrefix: "samtools-home",
            script: samtoolsScript
        )
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: samtoolsHome.homeURL)

        return StandInMappingFixture(
            rootURL: root,
            projectURL: project,
            rootFASTQURL: rootFASTQ,
            virtualBundleURL: virtualBundle,
            referenceURL: reference,
            readsSeenByMapperURL: readsSeen,
            pipeline: ManagedMappingPipeline(condaManager: condaManager, nativeToolRunner: runner)
        )
    }

    func cleanUp() {
        TestTempDirectory.cleanup(rootURL)
    }

    func makeAnalysisDirectory() throws -> URL {
        try AnalysesFolder.createAnalysisDirectory(tool: MappingTool.minimap2.rawValue, in: projectURL)
    }

    /// The request the Map Reads dialog hands to `runManagedMapping`, bound
    /// to its analysis directory as `runSingleManagedMappingAwaitingCompletion`
    /// binds it.
    func windowRequest(outputDirectory: URL) throws -> MappingRunRequest {
        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [virtualBundleURL],
            mode: .perBundle,
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: projectURL,
            outputDirectory: projectURL.appendingPathComponent("mapping-probe", isDirectory: true),
            runToken: "probe",
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 2,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
        let request = try XCTUnwrap(plan.requests.first)
        return request.withOutputDirectory(outputDirectory)
    }

    /// The request `lungfish-cli map` builds: inputs resolved one to one,
    /// materialized inside the run's output directory, and the original
    /// bundle carried as `originalInputFASTQURLs`.
    func cliShapedRequest(outputDirectory: URL) async throws -> CLIShapedRequest {
        let resolvedInputs = try await CLISequenceInputMaterialization.resolveExecutionInputs(
            for: [virtualBundleURL],
            tempDirectory: outputDirectory.appendingPathComponent(".lungfish-map-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared),
            operationName: "mapping"
        )
        let layoutResolution = FASTQInputLayoutResolver.resolve(
            inputURLs: resolvedInputs.inputURLs,
            pairedFiles: false
        )
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: resolvedInputs.inputURLs,
            originalInputFASTQURLs: [virtualBundleURL.standardizedFileURL],
            inputMaterializationStartedAt: resolvedInputs.materializationStartedAt,
            inputMaterializationEndedAt: resolvedInputs.materializationEndedAt,
            referenceFASTAURL: referenceURL,
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: "run-oriented",
            pairedEnd: false,
            threads: 2,
            inputLayout: layoutResolution.layout
        )
        return CLIShapedRequest(request: request, layoutReason: layoutResolution.reason)
    }

    /// The read names and bases the stand-in mapper was handed, in order.
    func readsSeenByMapper() throws -> [String] {
        let lines = try String(contentsOf: readsSeenByMapperURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var reads: [String] = []
        var index = 0
        while index + 1 < lines.count, lines[index].hasPrefix("@") {
            let name = String(lines[index].dropFirst().split(separator: " ").first ?? "")
            reads.append("\(name) \(lines[index + 1])")
            index += 4
        }
        return reads
    }

    /// The mapper read the oriented reads, not the bundle's one-read
    /// preview and not the three-read root FASTQ.
    func assertMapperReadMaterializedVirtualReads(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try readsSeenByMapper(),
            [
                "\(Self.readIDs[0]) \(Self.sequences[0])",
                "\(Self.readIDs[2]) \(Self.reverseComplement(Self.sequences[2]))",
            ],
            file: file,
            line: line
        )
    }

    /// The run's provenance names the virtual bundle, its derived manifest,
    /// the root FASTQ and the orient map, every file it names still exists
    /// once the run is over, and none of them lives in the project's scratch
    /// folder.
    func assertDurableVirtualInputProvenance(
        in analysisDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let provenance = try XCTUnwrap(
            MappingProvenance.load(from: analysisDirectory),
            "mapping-provenance.json was not written",
            file: file,
            line: line
        )
        let recordedInputs = provenance.inputFiles
            .filter { $0.role == .input }
            .map { Self.canonicalPath($0.path) }
        let durableInputs = [
            virtualBundleURL,
            FASTQBundle.derivedManifestURL(in: virtualBundleURL),
            rootFASTQURL,
            virtualBundleURL.appendingPathComponent("orient-map.tsv"),
        ].map { Self.canonicalPath($0.path) }
        for durableInput in durableInputs {
            XCTAssertTrue(
                recordedInputs.contains(durableInput),
                "provenance inputs omit durable input \(durableInput); recorded inputs: \(recordedInputs)",
                file: file,
                line: line
            )
        }
        for record in provenance.inputFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: record.path),
                "provenance names \(record.path), which no longer exists after the run",
                file: file,
                line: line
            )
        }
        let scratchPrefix = Self.canonicalPath(projectURL.appendingPathComponent(".tmp").path) + "/"
        XCTAssertEqual(
            recordedInputs.filter { $0.hasPrefix(scratchPrefix) },
            [],
            "provenance names a file in the project's scratch folder",
            file: file,
            line: line
        )
        XCTAssertFalse(
            provenance.steps.filter { $0.toolName == CLISequenceInputMaterialization.materializationToolName }.isEmpty,
            "provenance records no materialization step; steps: \(provenance.steps.map(\.toolName))",
            file: file,
            line: line
        )

        let envelope = try XCTUnwrap(
            ProvenanceRecorder.findProvenanceEnvelope(for: analysisDirectory)?.envelope,
            "the canonical provenance envelope was not written",
            file: file,
            line: line
        )
        let envelopeFiles = envelope.files.map { Self.canonicalPath($0.path) }
        XCTAssertTrue(
            envelopeFiles.contains(Self.canonicalPath(virtualBundleURL.path)),
            "the provenance envelope omits the virtual bundle; envelope files: \(envelopeFiles)",
            file: file,
            line: line
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func micromambaScript(readsSeenPath: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "2.0.0"
          exit 0
        fi
        if [ "$1" != "run" ]; then
          echo "stand-in micromamba: unexpected arguments: $*" >&2
          exit 64
        fi
        shift
        if [ "$1" = "-n" ]; then
          shift 2
        fi
        tool="$1"
        shift
        if [ "$tool" != "minimap2" ]; then
          echo "stand-in micromamba: unexpected tool $tool" >&2
          exit 64
        fi
        if [ "$1" = "--version" ]; then
          echo "2.28-r1209"
          exit 0
        fi
        out=""
        last=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then
            out="$2"
            shift 2
            continue
          fi
          last="$1"
          shift
        done
        cat "$last" > '\(readsSeenPath)'
        printf '@HD\\tVN:1.6\\tSO:unsorted\\n@SQ\\tSN:chr1\\tLN:160\\n' > "$out"
        exit 0
        """
    }

    private static let samtoolsScript = """
        #!/bin/sh
        sub="$1"
        if [ "$sub" = "--version" ]; then
          echo "samtools 1.21"
          exit 0
        fi
        shift
        case "$sub" in
          view|sort)
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            if [ -n "$out" ]; then
              : > "$out"
            fi
            ;;
          index)
            bam=""
            for arg in "$@"; do
              bam="$arg"
            done
            : > "$bam.bai"
            ;;
          flagstat)
            echo "2 + 0 in total (QC-passed reads + QC-failed reads)"
            echo "2 + 0 primary"
            echo "2 + 0 mapped (100.00% : N/A)"
            echo "2 + 0 primary mapped (100.00% : N/A)"
            ;;
          coverage)
            printf '#rname\\tstartpos\\tendpos\\tnumreads\\tcovbases\\tcoverage\\tmeandepth\\tmeanbaseq\\tmeanmapq\\n'
            printf 'chr1\\t1\\t160\\t2\\t160\\t100.0\\t2.0\\t30.0\\t60.0\\n'
            ;;
        esac
        exit 0
        """
}

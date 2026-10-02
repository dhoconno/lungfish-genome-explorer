// SidebarReassembleInputsTests.swift - Reassemble hands the assembly wizard the inputs of the original run, and nothing else
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Reassemble on an assembly made in process hands the assembly wizard the
/// inputs the user chose for that run, and nothing else (R3, lane 1q-2).
///
/// Each original run is written the way `AssemblyRunner.runManagedAssemblyOperation`
/// writes one once its assembler has run: the in-process input resolution,
/// the input records and steps it keeps for provenance, and
/// `ProvenanceBuilder.build` with the requested inputs. The input records
/// keep lineage too. Before this fix Reassemble handed the wizard every
/// recorded file that still existed, so a Reassemble of a virtual subset
/// assembled the subset, the whole root FASTQ and the copy the first run
/// materialized.
@MainActor
final class SidebarReassembleInputsTests: XCTestCase {

    private var root: URL!
    private var project: URL!
    private var shapes: AssemblyBundleShapes!
    /// A virtual subset of `shapes.single` that keeps s1 and s3.
    private var subset: URL!
    private var sidebar: SidebarViewController!

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "sidebar-reassemble-inputs")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        shapes = try AssemblyBundleShapes(in: project)
        subset = try Self.writeSubset(of: shapes.single, rootFASTQFilename: "single.fastq", keeping: ["s1", "s3"])
        sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
    }

    override func tearDown() async throws {
        sidebar?.closeProject()
        sidebar = nil
        TestTempDirectory.cleanup(root)
    }

    func testTheWizardReceivesExactlyTheInputsOfTheOriginalRun() async throws {
        let cases: [(shape: String, inputs: [URL])] = [
            ("physical single-file bundle", [shapes.single]),
            ("multi-file bundle", [shapes.multiFile]),
            ("fullPaired bundle", [shapes.paired]),
            ("virtual subset bundle", [subset]),
            ("two loose FASTQ files", shapes.looseFiles),
        ]
        for (index, testCase) in cases.enumerated() {
            let original = try await assembleInProcess(testCase.inputs, name: "original-\(index)")
            XCTAssertEqual(
                original.provenance.requestedInputs,
                testCase.inputs.map(\.standardizedFileURL.path),
                "\(testCase.shape): the run records what it was asked to assemble"
            )

            let launch = try openedWizard(forAssembly: original.bundle, label: testCase.shape)
            XCTAssertEqual(paths(launch.inputFiles), paths(testCase.inputs), "\(testCase.shape): the wizard's inputs")
            XCTAssertEqual(paths([launch.outputDirectory]), paths([project]), testCase.shape)
            XCTAssertEqual(launch.initialTool, .spades, testCase.shape)

            let reassembled = try await assembleInProcess(launch.inputFiles, name: "reassembled-\(index)")
            XCTAssertEqual(reassembled.reads, original.reads, "\(testCase.shape): the reads assembled again")
            XCTAssertEqual(reassembled.pairing, original.pairing, testCase.shape)
        }
    }

    /// The defect. The subset's record also keeps the root FASTQ it was cut
    /// from and the copy the run materialized, so Reassemble assembled seven
    /// reads (s1 and s3, then s1 to s3, then s1 and s3 again). Reassemble from
    /// the sidebar now assembles the original run's two.
    func testReassembleFromTheSidebarAssemblesTheReadsOfTheOriginalRun() async throws {
        let original = try await assembleInProcess([subset], name: "subset-assembly")
        XCTAssertEqual(original.reads, [["s1", "s3"]])
        let lineage = original.provenance.inputs.compactMap(\.originalPath)
        XCTAssertTrue(
            paths(lineage.map { URL(fileURLWithPath: $0) }).contains(paths([shapes.single.appendingPathComponent("single.fastq")])[0]),
            "the record keeps the root FASTQ as lineage: \(lineage)"
        )
        XCTAssertTrue(
            lineage.contains { $0.contains("/.lungfish-assembly-inputs/") },
            "the record keeps the materialized copy as lineage: \(lineage)"
        )

        sidebar.openProject(at: project)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = sidebar
        defer {
            window.contentViewController = nil
            window.close()
        }
        XCTAssertTrue(sidebar.selectItem(forURL: original.bundle))

        var presented: [[URL]] = []
        sidebar.reassembleSelectedSidebarBundle(presentWizard: { presentingWindow, inputFiles, outputDirectory, initialTool in
            XCTAssertTrue(presentingWindow === window)
            XCTAssertEqual(self.paths([outputDirectory]), self.paths([self.project]))
            XCTAssertEqual(initialTool, .spades)
            presented.append(inputFiles)
        })
        XCTAssertEqual(presented.count, 1)
        let inputFiles = try XCTUnwrap(presented.first)
        XCTAssertEqual(paths(inputFiles), paths([subset]))

        let reassembled = try await assembleInProcess(inputFiles, name: "subset-reassembled")
        XCTAssertEqual(reassembled.reads.joined().count, original.reads.joined().count)
        XCTAssertEqual(reassembled.reads, [["s1", "s3"]])
    }

    /// An assembly recorded before `requested_inputs` existed names its
    /// inputs among their lineage. Reassemble reads them back from what the
    /// record keeps, and they resolve to the reads of the original run. A
    /// one-file bundle is named by its file and a mate pair by its R1 and R2
    /// files, as the record names them.
    func testAnAssemblyRecordedBeforeTheFixReassemblesItsOwnReads() async throws {
        let cases: [(shape: String, inputs: [URL], wizardInputs: [URL], wizardPairsByName: Bool)] = [
            ("physical single-file bundle", [shapes.single], [shapes.single.appendingPathComponent("single.fastq")], false),
            ("multi-file bundle", [shapes.multiFile], [shapes.multiFile], false),
            ("fullPaired bundle", [shapes.paired], shapes.pairedFiles, true),
            ("virtual subset bundle", [subset], [subset], false),
            ("two loose FASTQ files", shapes.looseFiles, shapes.looseFiles, false),
        ]
        for (index, testCase) in cases.enumerated() {
            let original = try await assembleInProcess(
                testCase.inputs,
                name: "older-\(index)",
                recordRequestedInputs: false
            )
            XCTAssertNil(original.provenance.requestedInputs, testCase.shape)

            let launch = try openedWizard(forAssembly: original.bundle, label: testCase.shape)
            XCTAssertEqual(paths(launch.inputFiles), paths(testCase.wizardInputs), "\(testCase.shape): the wizard's inputs")

            let reassembled = try await assembleInProcess(
                launch.inputFiles,
                name: "older-reassembled-\(index)",
                pairedEnd: testCase.wizardPairsByName
            )
            XCTAssertEqual(reassembled.reads, original.reads, "\(testCase.shape): the reads assembled again")
            XCTAssertEqual(reassembled.pairing, original.pairing, testCase.shape)
        }
    }

    /// Assembling the inputs that are left would not reassemble the original
    /// reads, so Reassemble says which input is gone instead.
    func testReassembleRefusesWhenAnInputOfTheOriginalRunIsGone() async throws {
        let original = try await assembleInProcess(shapes.looseFiles, name: "loose-assembly")
        try FileManager.default.removeItem(at: shapes.looseFiles[1])

        guard case .refuse(let reason) = sidebar.reassemblePlan(forBundleAt: original.bundle, title: "loose-assembly") else {
            return XCTFail("Reassemble opened the wizard on the remaining input alone")
        }
        XCTAssertTrue(reason.contains("loose_b.fastq"), reason)
    }

    /// An input no longer at its recorded path is still looked up by name in
    /// the project, its FASTQ folder and its Reads folder, as before.
    func testAMovedInputIsStillFoundByNameInTheProject() async throws {
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("loose_a.fastq")
        try FileManager.default.copyItem(at: shapes.looseFiles[0], to: moved)
        let original = try await assembleInProcess([moved], name: "moved-assembly")
        try FileManager.default.removeItem(at: moved)

        sidebar.openProject(at: project)
        let launch = try openedWizard(forAssembly: original.bundle, label: "moved input")
        XCTAssertEqual(paths(launch.inputFiles), paths([shapes.looseFiles[0]]))
    }

    // MARK: - Helpers

    private struct InProcessAssembly {
        let bundle: URL
        let provenance: AssemblyProvenance
        /// The record names of each file the assembler was handed.
        let reads: [[String]]
        let pairing: AssemblyReadPairing
    }

    /// What the wizard opens with.
    private struct Launch {
        let inputFiles: [URL]
        let outputDirectory: URL
        let initialTool: AssemblyTool
    }

    private struct Refused: Error {}

    /// An in-process assembly of `inputs` into the project, written as
    /// `AssemblyRunner.runManagedAssemblyOperation` writes one once its
    /// assembler has run. With `recordRequestedInputs` false the record is
    /// the one a run wrote before this fix.
    private func assembleInProcess(
        _ inputs: [URL],
        name: String,
        pairedEnd: Bool = false,
        recordRequestedInputs: Bool = true
    ) async throws -> InProcessAssembly {
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: inputs,
            projectName: name,
            outputDirectory: project,
            pairedEnd: pairedEnd,
            threads: 1
        ).normalizedForExecution()
        let executionRequest = AssemblyRunner.executionRequest(for: request)
        let resolved = try await AssemblyRunner.materializedManagedAssemblyRequestResult(
            from: executionRequest,
            tempDirectory: executionRequest.outputDirectory
                .appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
            materialize: { bundleURL, tempDirectory, _ in
                try Self.materializeSubset(bundleURL, into: tempDirectory)
            }
        )
        let ran = resolved.request
        let provenance = ProvenanceBuilder.build(
            request: ran,
            result: AssemblyResult(
                tool: ran.tool,
                readType: ran.readType,
                contigsPath: ran.outputDirectory.appendingPathComponent("contigs.fasta"),
                graphPath: nil,
                logPath: nil,
                assemblerVersion: "4.2.0",
                commandLine: try ManagedAssemblyPipeline.buildCommand(for: ran).shellCommand,
                outputDirectory: ran.outputDirectory,
                statistics: AssemblyStatistics(
                    contigCount: 1,
                    totalLengthBP: 20,
                    largestContigBP: 20,
                    smallestContigBP: 20,
                    n50: 20,
                    l50: 1,
                    n90: 20,
                    gcFraction: 0.5,
                    meanLengthBP: 20
                ),
                wallTimeSeconds: 1
            ),
            inputRecords: AssemblyRunner.managedAssemblyInputRecords(
                originalInputURLs: resolved.originalInputURLs,
                executionInputURLs: ran.inputURLs
            ),
            requestedInputURLs: recordRequestedInputs ? executionRequest.inputURLs : nil,
            steps: try AssemblyRunner.managedAssemblyMaterializationSteps(
                originalInputURLs: resolved.originalInputURLs,
                executionInputURLs: ran.inputURLs,
                startedAt: resolved.materializationStartedAt,
                endedAt: resolved.materializationEndedAt
            )
        )
        let bundle = project.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try Self.writeAssemblyBundle(at: bundle, provenance: provenance)
        return InProcessAssembly(
            bundle: bundle,
            provenance: provenance,
            reads: try ran.inputURLs.map(AssemblyBundleShapes.readNames(in:)),
            pairing: ran.readPairing
        )
    }

    private func openedWizard(
        forAssembly bundle: URL,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Launch {
        switch sidebar.reassemblePlan(forBundleAt: bundle, title: bundle.deletingPathExtension().lastPathComponent) {
        case .open(let inputFiles, let outputDirectory, let initialTool):
            return Launch(inputFiles: inputFiles, outputDirectory: outputDirectory, initialTool: initialTool)
        case .refuse(let reason):
            XCTFail("\(label): Reassemble refused, \(reason)", file: file, line: line)
            throw Refused()
        }
    }

    /// Paths with symbolic links resolved (the temporary folder lives behind /var).
    private func paths(_ urls: [URL]) -> [String] {
        urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    }

    /// The app's materializer for the one virtual payload these tests use, a
    /// read-ID subset, written in Swift so that no managed seqkit is needed.
    nonisolated private static func materializeSubset(_ bundleURL: URL, into tempDirectory: URL) throws -> URL {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL),
              case .subset(let readIDListFilename) = manifest.payload else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: bundleURL.path])
        }
        let readIDs = Set(
            try String(contentsOf: bundleURL.appendingPathComponent(readIDListFilename), encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
        )
        let rootFASTQ = FASTQBundle.resolveBundle(relativePath: manifest.rootBundleRelativePath, from: bundleURL)
            .appendingPathComponent(manifest.rootFASTQFilename)
        let kept = try AssemblyBundleShapes.readNames(in: rootFASTQ).filter(readIDs.contains)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let outputURL = tempDirectory.appendingPathComponent("\(bundleURL.deletingPathExtension().lastPathComponent).fastq")
        try AssemblyBundleShapes.fastq(kept).write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    /// A virtual bundle beside `rootBundle` that keeps `readIDs` of its one
    /// file, as the FASTQ dashboard's subset operations write one.
    private static func writeSubset(
        of rootBundle: URL,
        rootFASTQFilename: String,
        keeping readIDs: [String]
    ) throws -> URL {
        let rootName = rootBundle.deletingPathExtension().lastPathComponent
        let bundle = rootBundle.deletingLastPathComponent()
            .appendingPathComponent("\(rootName)-subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try (readIDs.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try AssemblyBundleShapes.fastq([readIDs[0]])
            .write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "s")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "\(rootName)-subset",
                parentBundleRelativePath: "@/Imports/\(rootBundle.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(rootBundle.lastPathComponent)",
                rootFASTQFilename: rootFASTQFilename,
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: readIDs.count, baseCount: Int64(readIDs.count * 10)),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    /// A `.lungfishref` the sidebar lists, holding `provenance` as
    /// `assembly/provenance.json`.
    private static func writeAssemblyBundle(at bundle: URL, provenance: AssemblyProvenance) throws {
        let assembly = bundle.appendingPathComponent("assembly", isDirectory: true)
        try FileManager.default.createDirectory(at: assembly, withIntermediateDirectories: true)
        try provenance.save(to: assembly)
        let manifest = """
        {
          "formatVersion": 1,
          "name": "\(bundle.deletingPathExtension().lastPathComponent)",
          "identifier": "\(UUID().uuidString)",
          "createdDate": "2026-01-01T00:00:00Z",
          "modifiedDate": "2026-01-01T00:00:00Z",
          "annotations": [],
          "variants": [],
          "tracks": []
        }
        """
        try Data(manifest.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
    }
}

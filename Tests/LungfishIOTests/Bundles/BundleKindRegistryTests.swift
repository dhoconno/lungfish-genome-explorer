// BundleKindRegistryTests.swift - The bundle kind registry against the code and files that define each kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The registry holds facts that other code already applies, so these tests tie every fact to its
// source. Typed constants and real writers prove the extension and manifest names. The app's
// Info.plist proves the UTType identifiers. The committed parity answers of Phase 2.6 lane B1
// (Tests/Fixtures/bundle-kinds), recorded from the real sidebar, deletion planner and copier,
// prove the presentation, deletion and copy facts, so the registry cannot drift from what the
// app does today before a caller reads it.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class BundleKindRegistryTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-kind-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        try super.tearDownWithError()
    }

    private static let ids: [BundleKindID] = [
        .project, .reference, .fastq, .multipleSequenceAlignment, .phylogeneticTree, .primerScheme,
        .primerAnalysis, .mhcReference, .genotypeResult, .twelveSResult, .twelveSReference, .czIdResult,
        .workflowRun, .workflowBundle, .workflowPackage,
    ]

    private func descriptor(_ id: BundleKindID, file: StaticString = #filePath, line: UInt = #line) throws -> BundleKindDescriptor {
        try XCTUnwrap(BundleKindRegistry.descriptor(for: id), "No descriptor for \(id)", file: file, line: line)
    }

    // MARK: - Shape

    func testRegistryHoldsTheFifteenKindsInInventoryOrderWithUniqueIDs() {
        XCTAssertEqual(BundleKindRegistry.all.map(\.id), Self.ids)
        XCTAssertEqual(Set(BundleKindRegistry.all.map(\.id)).count, 15)
        XCTAssertEqual(Set(Self.ids.map(\.rawValue)).count, 15)
    }

    func testFolderExtensionsAreLowercaseAndUniqueWhenLowercased() {
        let extensions = BundleKindRegistry.all.flatMap(\.folderExtensions)
        XCTAssertEqual(extensions.count, 15, "Each kind has one folder extension today")
        XCTAssertEqual(Set(extensions.map { $0.lowercased() }).count, extensions.count)
        for ext in extensions {
            XCTAssertEqual(ext, ext.lowercased(), "\(ext) must be spelled in lowercase")
            XCTAssertFalse(ext.hasPrefix("."), "\(ext) must not carry a dot")
            XCTAssertTrue(ext.hasPrefix("lungfish"), "\(ext) must be a Lungfish extension")
        }
    }

    func testEveryDescriptorFieldIsFilled() {
        for d in BundleKindRegistry.all {
            let name = d.id.rawValue
            XCTAssertFalse(name.isEmpty)
            XCTAssertEqual(name, name.lowercased(), "\(name) is a lowercase token")
            XCTAssertFalse(d.folderExtensions.isEmpty, "\(name) has no folder extension")
            XCTAssertFalse(d.sidebarSymbolName.isEmpty, "\(name) has no sidebar symbol")
            XCTAssertNotEqual(d.manifestFileName, "", "\(name) names an empty manifest")
            XCTAssertNotEqual(d.utTypeIdentifier, "", "\(name) names an empty UTType")
            XCTAssertTrue(d.appStateFileNames.allSatisfy { !$0.isEmpty && !$0.contains("/") }, "\(name) app state is a file name")
            if case .frozenException(let paths) = d.sidecarNaming {
                XCTAssertFalse(paths.isEmpty, "\(name) is an exception with no record names")
                XCTAssertTrue(paths.allSatisfy { !$0.isEmpty })
            }
            if case .copied(let folder, let requiresAnalyses) = d.copy {
                XCTAssertFalse(requiresAnalyses && !folder.hasPrefix("Analyses"), "\(name) requires Analyses but lands elsewhere")
            }
            if d.recognition == .extensionAndManifest {
                XCTAssertNotNil(d.manifestFileName, "\(name) is gated on a manifest it does not name")
            }
            XCTAssertEqual(d.role == .project, d.id == .project, "Only the project has the project role")
        }
    }

    // MARK: - Names against typed constants and real writers

    func testFolderExtensionsEqualTheTypedDirectoryExtensions() throws {
        let typed: [(BundleKindID, String)] = [
            (.project, ProjectFile.fileExtension),
            (.fastq, FASTQBundle.directoryExtension),
            (.multipleSequenceAlignment, MultipleSequenceAlignmentBundle.directoryExtension),
            (.mhcReference, MHCAmpliconReferenceBundle.directoryExtension),
            (.genotypeResult, ONTGenotypeResultBundle.directoryExtension),
            (.twelveSResult, TwelveSAmpliconResultBundle.directoryExtension),
            (.twelveSReference, TwelveSReferenceBundle.directoryExtension),
        ]
        for (id, constant) in typed {
            XCTAssertEqual(try descriptor(id).folderExtensions, [constant], "\(id)")
        }
    }

    func testManifestFileNamesEqualTheTypedConstants() throws {
        let typed: [(BundleKindID, String)] = [
            (.reference, BundleManifest.filename),
            (.primerAnalysis, PrimerAnalysisManifest.filename),
            (.mhcReference, MHCAmpliconReferenceBundleManifest.manifestFilename),
            (.genotypeResult, ONTGenotypeResultBundleManifest.filename),
            (.twelveSResult, TwelveSAmpliconResultBundleManifest.filename),
            (.twelveSReference, TwelveSReferenceBundleManifest.manifestFilename),
        ]
        for (id, constant) in typed {
            XCTAssertEqual(try descriptor(id).manifestFileName, constant, "\(id)")
        }
        // A read bundle has no single manifest. derived.manifest.json belongs to a derived bundle only.
        XCTAssertNil(try descriptor(.fastq).manifestFileName)
        XCTAssertNil(try descriptor(.workflowBundle).manifestFileName)
    }

    @MainActor
    func testManifestAppStateAndRecordNamesExistInBundlesTheRealWritersMake() throws {
        let project = try ProjectFile.create(at: scratch.appendingPathComponent("Probe.lungfish"), name: "Probe")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.url.appendingPathComponent(try XCTUnwrap(descriptor(.project).manifestFileName)).path
        ))

        let alignment = scratch.appendingPathComponent("aligned.fasta")
        try ">a\nACGT\n>b\nACGA\n".write(to: alignment, atomically: true, encoding: .utf8)
        let msaBundle = scratch.appendingPathComponent("Probe.lungfishmsa", isDirectory: true)
        try MultipleSequenceAlignmentBundle.importAlignment(from: alignment, to: msaBundle)

        let newick = scratch.appendingPathComponent("tree.nwk")
        try "((A:0.1,B:0.2):0.3,C:0.4);".write(to: newick, atomically: true, encoding: .utf8)
        let treeBundle = scratch.appendingPathComponent("Probe.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: treeBundle)

        for (id, bundle) in [(BundleKindID.multipleSequenceAlignment, msaBundle), (.phylogeneticTree, treeBundle)] {
            let d = try descriptor(id)
            var names = d.appStateFileNames + [try XCTUnwrap(d.manifestFileName)]
            if case .frozenException(let paths) = d.sidecarNaming {
                names += paths
            }
            for name in names {
                XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(name).path), "\(id) should hold \(name)")
            }
        }
    }

    func testPrimerSchemeAndReferenceFixturesHoldTheNamedManifests() throws {
        let root = repositoryRoot()
        let scheme = root.appendingPathComponent("Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers")
        let reference = root.appendingPathComponent("TestData/TestGenome.lungfishref")
        let mhc = root.appendingPathComponent("Sources/LungfishWorkflow/Resources/MCMHaplotyping/MCM-MHC-miSeq-20260617.lungfishmhcref")
        let schemeDescriptor = try descriptor(.primerScheme)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scheme.appendingPathComponent(try XCTUnwrap(schemeDescriptor.manifestFileName)).path))
        if case .frozenException(let paths) = schemeDescriptor.sidecarNaming {
            for path in paths {
                XCTAssertTrue(FileManager.default.fileExists(atPath: scheme.appendingPathComponent(path).path), path)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.appendingPathComponent(try XCTUnwrap(descriptor(.reference).manifestFileName)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mhc.appendingPathComponent(try XCTUnwrap(descriptor(.mhcReference).manifestFileName)).path))
    }

    func testCopyFoldersEqualTheTypedFolderNames() throws {
        func folder(_ id: BundleKindID) throws -> String? {
            if case .copied(let folder, _) = try descriptor(id).copy { return folder }
            return nil
        }
        XCTAssertEqual(try folder(.reference), ReferenceSequenceFolder.folderName)
        XCTAssertEqual(try folder(.primerScheme), PrimerSchemesFolder.folderName)
        XCTAssertEqual(try folder(.primerAnalysis), AnalysesFolder.directoryName)
        XCTAssertEqual(try folder(.genotypeResult), AnalysesFolder.directoryName)
        XCTAssertEqual(try folder(.twelveSResult), AnalysesFolder.directoryName)
        XCTAssertEqual(try folder(.multipleSequenceAlignment), "\(AnalysesFolder.directoryName)/Multiple Sequence Alignments")
    }

    func testAppStateNamesAreTheViewStateFilesOfTheReferenceAndTheGenotypeResultOnly() throws {
        // The alignment and tree .viewstate.json sits inside the manifest checksums, so it is not declared app state (S11).
        let expected: [BundleKindID: [String]] = [
            .reference: [BundleViewState.filename],
            .genotypeResult: [GenotypeResultViewState.filename],
        ]
        for id in BundleKindRegistry.all.map(\.id) {
            let names = try descriptor(id).appStateFileNames
            XCTAssertEqual(names, expected[id] ?? [], "\(id)")
        }
        // A hidden name keeps the file out of every directory digest.
        XCTAssertTrue(GenotypeResultViewState.filename.hasPrefix("."))
        XCTAssertNotEqual(GenotypeResultViewState.filename, BundleViewState.filename, "the reference viewer must never decode it")
    }

    func testIsAppStateFileNamesOnlyTheDeclaredFileDirectlyInsideItsKind() {
        let root = URL(fileURLWithPath: "/Projects/Fixture.lungfish", isDirectory: true)
        for descriptor in BundleKindRegistry.all {
            guard let ext = descriptor.folderExtensions.first else { continue }
            let folder = root.appendingPathComponent("Item.\(ext)", isDirectory: true)
            let shouted = root.appendingPathComponent("Item.\(ext.uppercased())", isDirectory: true)
            for name in descriptor.appStateFileNames {
                XCTAssertTrue(BundleKindRegistry.isAppStateFile(at: folder.appendingPathComponent(name)), "\(descriptor.id) \(name)")
                XCTAssertTrue(BundleKindRegistry.isAppStateFile(at: shouted.appendingPathComponent(name)), "\(descriptor.id) \(name) in \(shouted.lastPathComponent)")
                XCTAssertFalse(
                    BundleKindRegistry.isAppStateFile(at: folder.appendingPathComponent("nested").appendingPathComponent(name)),
                    "\(descriptor.id) \(name) below the root is not app state"
                )
                // The temporary file of an atomic write of the state file counts too, because the watcher
                // reports it before the rename. A longer name that is not that temporary file does not.
                XCTAssertTrue(
                    BundleKindRegistry.isAppStateFile(at: folder.appendingPathComponent("\(name).sb-e7881877-TeusD9")),
                    "\(descriptor.id) \(name) temporary file of an atomic write"
                )
                XCTAssertFalse(
                    BundleKindRegistry.isAppStateFile(at: folder.appendingPathComponent("\(name)x")),
                    "\(descriptor.id) \(name)x is a different file"
                )
            }
            XCTAssertFalse(BundleKindRegistry.isAppStateFile(at: folder.appendingPathComponent("manifest.json")), "\(descriptor.id)")
        }
        // The temporary file of a write of any other file stays a real change.
        XCTAssertFalse(BundleKindRegistry.isAppStateFile(at: root.appendingPathComponent("Item.lungfishref/manifest.json.sb-e7881877-TeusD9")))
        // The alignment's .viewstate.json sits inside the manifest checksums, so it is not app state (S11).
        XCTAssertFalse(BundleKindRegistry.isAppStateFile(at: root.appendingPathComponent("Aln.lungfishmsa/.viewstate.json")))
        // A folder of no kind declares none.
        XCTAssertFalse(BundleKindRegistry.isAppStateFile(at: root.appendingPathComponent("Plain/.viewstate.json")))
    }

    func testOnlyTheAlignmentTreePrimerAndPrimerAnalysisFormatsKeepTheirOwnRecordNames() {
        let exceptions = BundleKindRegistry.all.filter {
            if case .frozenException = $0.sidecarNaming { return true }
            return false
        }.map(\.id)
        XCTAssertEqual(exceptions, [.multipleSequenceAlignment, .phylogeneticTree, .primerScheme, .primerAnalysis])
        let records = BundleKindRegistry.all.compactMap { descriptor -> [String]? in
            if case .frozenException(let paths) = descriptor.sidecarNaming { return paths }
            return nil
        }
        XCTAssertEqual(records, [[".lungfish-provenance.json"], [".lungfish-provenance.json"], ["PROVENANCE.md"], ["provenance/wrapper.json"]])
        XCTAssertEqual(BundleKindDescriptor.SidecarNaming.rootRecordFileName, ".lungfish-provenance.json")
        XCTAssertEqual(BundleKindDescriptor.SidecarNaming.layoutFolderName, "provenance")
    }

    // MARK: - UTType identifiers against the Info.plist

    func testUTTypeIdentifiersEqualTheInfoPlist() throws {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent("Lungfish-Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        var extensionsByIdentifier: [String: Set<String>] = [:]
        for entry in exported {
            guard let identifier = entry["UTTypeIdentifier"] as? String else { continue }
            let tags = entry["UTTypeTagSpecification"] as? [String: Any]
            let value = tags?["public.filename-extension"]
            let extensions = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
            extensionsByIdentifier[identifier] = Set(extensions)
        }

        for d in BundleKindRegistry.all {
            guard let identifier = d.utTypeIdentifier else { continue }
            XCTAssertEqual(extensionsByIdentifier[identifier], Set(d.folderExtensions), "\(d.id) declares \(identifier)")
        }
        let claimed = Set(BundleKindRegistry.all.compactMap(\.utTypeIdentifier))
        let lungfishDeclarations = extensionsByIdentifier.filter { _, extensions in
            extensions.contains { $0.hasPrefix("lungfish") }
        }
        XCTAssertEqual(Set(lungfishDeclarations.keys), claimed, "Every Lungfish folder type in the plist belongs to a descriptor")
        XCTAssertEqual(claimed.count, 6)
    }

    // MARK: - Facts against the frozen parity answers

    func testPresentationDeletionCopyAndRecognitionEqualWhatTheAppDoesToday() throws {
        let answers = try ParityAnswers()
        for d in BundleKindRegistry.all {
            let ext = try XCTUnwrap(d.folderExtensions.first)
            let lower = "lower-\(ext)", upper = "upper-\(ext)", bare = "nomanifest-\(ext)"
            let label = "\(d.id)"

            // Sidebar symbol and presentation. A nested project is a generic package, so its symbol is the root row's.
            // A scan answer reads "type symbol <name> atomic" or "type symbol <name> walked".
            let symbolRow = d.role == .project ? answers["sidebar.scanRoot", lower] : answers["sidebar.scanNode", lower]
            XCTAssertEqual(symbolRow.split(separator: " ").dropFirst(2).first.map(String.init), d.sidebarSymbolName, label)
            let node = answers["sidebar.scanNode", lower]
            XCTAssertEqual(node.hasSuffix(" atomic"), d.presentation == .atomicPackage, label)
            // A hidden kind is not listed. The committed alignment is listed outside Analyses/ although it
            // carries analysis-metadata.json, which hid every folder outside Analyses/ before 2.9 (risk R11).
            let notListed = d.presentation == .hiddenPackage
            XCTAssertEqual(answers["sidebar.listed", lower] == "false", notListed, label)

            // Deletion, in every spelling, because the planner lowercases.
            let expectedDeletion = d.deletion.isOpaqueProjectObject ? "opaqueObject" : "walkedInside"
            for probe in [lower, upper, bare] {
                XCTAssertEqual(answers["deletion.object", probe], expectedDeletion, "\(label) \(probe)")
            }

            // Copy, in every spelling that keeps the manifest.
            let expectedCopy: String
            switch d.copy {
            case .refused:
                expectedCopy = "nil"
            case .copied(let folder, let requiresAnalyses):
                expectedCopy = "folder=\"\(folder)\" analysesOnly=\(requiresAnalyses)"
            }
            for probe in [lower, upper] {
                let answer = answers["copier.kind", probe]
                XCTAssertTrue(expectedCopy == "nil" ? answer == "nil" : answer.hasSuffix(expectedCopy), "\(label) \(probe) copier said \(answer)")
            }

            // Recognition. Removing the manifest changes some reader's answer only for a gated kind.
            let sidebarChanges = answers["sidebar.classification", lower] != answers["sidebar.classification", bare]
            let recognizerChanges = answers["typedRecognizers", lower] != answers["typedRecognizers", bare]
            XCTAssertEqual(sidebarChanges || recognizerChanges, d.recognition == .extensionAndManifest, label)
            XCTAssertEqual(answers["typedRecognizers", lower], answers["typedRecognizers", upper], "\(label) recognizers lowercase the extension")
        }
    }

    // MARK: - Lookups

    func testLookupByExtensionIsExactOrLowercasedAndReadsNoFiles() throws {
        let reference = try descriptor(.reference)
        XCTAssertEqual(BundleKindRegistry.descriptor(forExactExtension: "lungfishref"), reference)
        XCTAssertNil(BundleKindRegistry.descriptor(forExactExtension: "LUNGFISHREF"), "An exact lookup keeps a case-sensitive site's answer")
        XCTAssertEqual(BundleKindRegistry.descriptor(forLowercasedExtension: "LUNGFISHREF"), reference)
        XCTAssertEqual(BundleKindRegistry.descriptor(forLowercasedExtension: "LungfishRef"), reference)
        for unknown in ["", "lungfish2", "zlungfishref", "lungfishbundle", ".lungfishref", "ref"] {
            XCTAssertNil(BundleKindRegistry.descriptor(forLowercasedExtension: unknown), unknown)
        }

        // Neither folder exists, so a lookup that opened the file system would find nothing to open.
        let missing = scratch.appendingPathComponent("never-created.LUNGFISHMSA")
        XCTAssertNil(BundleKindRegistry.descriptor(forExactExtensionOf: missing))
        XCTAssertEqual(BundleKindRegistry.descriptor(forLowercasedExtensionOf: missing)?.id, .multipleSequenceAlignment)
        for d in BundleKindRegistry.all {
            for ext in d.folderExtensions {
                XCTAssertEqual(BundleKindRegistry.descriptor(forExactExtension: ext), d)
                XCTAssertEqual(BundleKindRegistry.descriptor(forLowercasedExtension: ext.uppercased()), d)
            }
        }
    }

    func testManifestGatedRecognitionReadsTheManifestOnlyForTheKindsThatNeedOne() throws {
        func folder(_ name: String, files: [String] = []) throws -> URL {
            let url = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                try Data("{}".utf8).write(to: url.appendingPathComponent(file))
            }
            return url
        }
        // A gated kind needs its manifest, whatever the case of its extension.
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: try folder("a.lungfishtax", files: ["cz-id-manifest.json"]))?.id, .czIdResult)
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: try folder("b.LUNGFISHTAX", files: ["cz-id-manifest.json"]))?.id, .czIdResult)
        XCTAssertNil(BundleKindRegistry.recognizedKind(at: try folder("c.lungfishtax")))
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: try folder("d.lungfishmhcref", files: ["mhc-reference.json"]))?.id, .mhcReference)
        XCTAssertNil(BundleKindRegistry.recognizedKind(at: try folder("e.lungfishmhcref")))
        XCTAssertNil(BundleKindRegistry.recognizedKind(at: try folder("f.lungfish12sref")))
        // A kind recognized by extension alone needs nothing inside, and a missing folder is still that kind.
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: try folder("g.lungfishref"))?.id, .reference)
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: scratch.appendingPathComponent("absent.lungfishgenotype"))?.id, .genotypeResult)
        XCTAssertNil(BundleKindRegistry.recognizedKind(at: try folder("h.lungfishunknown", files: ["manifest.json"])))
        let tax = try descriptor(.czIdResult)
        XCTAssertTrue(tax.recognizes(folder: try folder("i.anything", files: ["cz-id-manifest.json"])), "recognizes(folder:) leaves the extension to the caller")
        XCTAssertFalse(tax.recognizes(folder: try folder("j.anything")))
    }

    // MARK: - Identifier

    func testBundleKindIDCodesAsABareStringAndDecodesUnknownIDs() throws {
        struct Holder: Codable, Equatable {
            let kind: BundleKindID
        }
        let encoded = try JSONEncoder().encode(Holder(kind: .reference))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"{"kind":"reference"}"#)
        XCTAssertEqual(try JSONDecoder().decode(Holder.self, from: encoded).kind, .reference)

        let future = try JSONDecoder().decode(Holder.self, from: Data(#"{"kind":"zarr-store"}"#.utf8))
        XCTAssertEqual(future.kind.rawValue, "zarr-store")
        XCTAssertNil(BundleKindRegistry.descriptor(for: future.kind), "An unknown kind decodes and finds no descriptor")
        XCTAssertEqual(BundleKindID(rawValue: "reference"), .reference)
        XCTAssertEqual(Set(Self.ids).count, 15)
        XCTAssertEqual("\(BundleKindID.twelveSReference)", "12s-reference")
    }

    // MARK: - Helpers

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Bundles
            .deletingLastPathComponent() // LungfishIOTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    /// The committed answers of BundleKindParityTests, by table and probe id.
    private struct ParityAnswers {
        private var rows: [String: String] = [:]

        init() throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/bundle-kinds/parity-expected.tsv")
            let text = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
            for line in text.components(separatedBy: "\n") where !line.hasPrefix("#") {
                let columns = line.components(separatedBy: "\t")
                if columns.count == 3, columns[0] != "probe" { rows["\(columns[0])\t\(columns[1])"] = columns[2] }
            }
        }

        subscript(table: String, probe: String) -> String {
            rows["\(table)\t\(probe)"] ?? "missing \(table) \(probe)"
        }
    }
}

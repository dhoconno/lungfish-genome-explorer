// FASTQPlanSheetTests.swift - The plan sheet's clumping defaults, its line, the no-executor build and the plan it writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishPortable
import LungfishTestSupport
import LungfishWorkflow

/// CHTC C4 lane U milestone 2, C4-12 as UX-XC26 words it. Each assertion reads a control, the argv or a written file.
@MainActor
final class FASTQPlanSheetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQPlanSheetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let popupTitles = ["BBTools clumpify", "Trim Galore --clumpify"]

    /// The plan's defaults do not depend on the batch's size: a 1 MB and a 200 GB Illumina batch both open with the box
    /// on and BBTools clumpify once the platform is detected, and the command asks for `bbtools`. Each file starts with
    /// Illumina headers and is sparse after them.
    func testPlanSheetDefaultsToBBToolsForEveryBatchSize() async throws {
        let fixture = try writeFixture()
        let headers = try Data(contentsOf: PlatformHeaderFixtures.url("illumina-novaseq6000.fastq"))
        var argvs: [[String]] = []
        for (name, bytes) in [("small_R1.fastq", Int64(1_048_576)), ("large_R1.fastq", Int64(200) * 1_000_000_000)] {
            let reads = root.appendingPathComponent(name)
            FileManager.default.createFile(atPath: reads.path, contents: headers)
            let handle = try FileHandle(forWritingTo: reads)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
            let sheet = makeSheet(inputs: [reads], fixture: fixture)
            await sheet.platformDetection?.value
            XCTAssertEqual(sheet.clumpifyCheckbox.state, .on, name)
            XCTAssertEqual(sheet.clumpingToolPopup.itemTitles, Self.popupTitles, name)
            XCTAssertEqual(sheet.clumpingToolPopup.titleOfSelectedItem, "BBTools clumpify", name)
            let request = try XCTUnwrap(sheet.request(planFolder: root.appendingPathComponent("plan")), name)
            XCTAssertEqual(Self.value(after: "--clumping-tool", in: request.arguments), "bbtools", name)
            argvs.append(Array(request.arguments.drop { $0 != "--write-plan" }))
        }
        XCTAssertEqual(argvs[0], argvs[1], "both batches give the same command after their reads")
    }

    /// The written plan names the tool the sheet shows with source `option`, as an import from the Import sheet does,
    /// and the box clear writes `none`. The sheet's argv runs through the command line's own `import fastq`.
    func testPlanSheetWritesTheToolItShows() async throws {
        let fixture = try writeFixture()
        let sheet = makeSheet(inputs: [fixture.readsFolder], fixture: fixture)
        await sheet.platformDetection?.value
        XCTAssertEqual(sheet.clumpifyCheckbox.state, .on, "the fixture's reads are Illumina reads")

        let onFolder = root.appendingPathComponent("plan-on", isDirectory: true)
        let onRequest = try XCTUnwrap(sheet.request(planFolder: onFolder))
        XCTAssertFalse(onRequest.arguments.contains("auto"))
        try await Self.runThroughCLI(onRequest.arguments)
        let on = try Self.clumping(in: onFolder.appendingPathComponent("S1/plan.json"))
        XCTAssertEqual(on["requested"] as? String, "bbtools")
        XCTAssertEqual(on["resolved"] as? String, "bbtools")
        XCTAssertEqual(on["resolvedSource"] as? String, "option")
        XCTAssertEqual(on["reason"] as? String, "explicit clumping tool selection")

        sheet.clumpifyCheckbox.performClick(nil)
        let offFolder = root.appendingPathComponent("plan-off", isDirectory: true)
        let offRequest = try XCTUnwrap(sheet.request(planFolder: offFolder))
        XCTAssertTrue(offRequest.arguments.contains("--no-optimize-storage"))
        XCTAssertNil(Self.value(after: "--clumping-tool", in: offRequest.arguments))
        try await Self.runThroughCLI(offRequest.arguments)
        let off = try Self.clumping(in: offFolder.appendingPathComponent("S1/plan.json"))
        XCTAssertEqual(off["requested"] as? String, "none")
        XCTAssertEqual(off["resolved"] as? String, "none")
    }

    /// The line under the popup is UX's BBTools sentence for BBTools, the Import sheet's disclosure for Trim Galore,
    /// and hidden with the box clear.
    func testPlanSheetBBToolsLineFollowsTheTool() throws {
        let fixture = try writeFixture()
        let sheet = makeSheet(inputs: [fixture.readsFolder], fixture: fixture)
        XCTAssertEqual(sheet.clumpingToolLineLabel.stringValue, FASTQPlanSheetModel.bbtoolsLine)
        XCTAssertEqual(
            sheet.clumpingToolLineLabel.stringValue,
            "On the run machine, clumpify splits a large sample into more groups to fit the memory the plan gives it."
        )
        XCTAssertFalse(sheet.clumpingToolLineLabel.isHidden)

        sheet.clumpingToolPopup.selectItem(withTitle: "Trim Galore --clumpify")
        sheet.clumpingToolPopup.sendAction(sheet.clumpingToolPopup.action, to: sheet.clumpingToolPopup.target)
        XCTAssertEqual(sheet.clumpingToolLineLabel.stringValue, ClumpingTool.trimGalore.importSheetDisclosure)
        XCTAssertFalse(sheet.clumpingToolLineLabel.isHidden)
        let request = try XCTUnwrap(sheet.request(planFolder: root.appendingPathComponent("plan")))
        XCTAssertEqual(Self.value(after: "--clumping-tool", in: request.arguments), "trim-galore")

        sheet.clumpifyCheckbox.performClick(nil)
        XCTAssertTrue(sheet.clumpingToolLineLabel.isHidden)
        XCTAssertFalse(sheet.clumpingToolPopup.isEnabled)
    }

    /// A build whose executor folder holds no executor keeps the sheet open, shows UX's sentence after the clumping
    /// controls and before the buttons, gives the write button the same sentence as its help, and writes nothing.
    func testPlanSheetWithNoExecutorShowsSentenceAndWritesNothing() throws {
        let fixture = try writeFixture()
        let emptyFolder = root.appendingPathComponent("LinuxExecutor/x86_64", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("chosen-plan", isDirectory: true)
        var chooserCalls = 0
        var written: [FASTQPlanSheetRequest] = []
        let sheet = FASTQPlanSheet(
            inputs: [fixture.readsFolder], executorFolder: emptyFolder,
            imageFiles: (fixture.image, fixture.toolManifest),
            chooseFolder: { _, done in chooserCalls += 1; done(destination) },
            onWrite: { written.append($0) }
        )
        sheet.loadViewIfNeeded()
        sheet.stagingField.stringValue = Fixture.stagingFolder
        sheet.stagingField.sendAction(sheet.stagingField.action, to: sheet.stagingField.target)

        let sentence = "This build of Lungfish has no Linux executor, so it cannot write a plan for a run on another "
            + "machine. Release builds include it."
        XCTAssertEqual(sheet.noExecutorLabel.stringValue, sentence)
        XCTAssertFalse(sheet.noExecutorLabel.isHidden)
        XCTAssertEqual(sheet.writeButton.accessibilityHelp(), sentence)
        XCTAssertFalse(sheet.writeButton.isEnabled)
        let stack = try XCTUnwrap(sheet.noExecutorLabel.superview as? NSStackView)
        let order = stack.arrangedSubviews
        let sentenceIndex = try XCTUnwrap(order.firstIndex(of: sheet.noExecutorLabel))
        XCTAssertTrue(order[sentenceIndex - 1] is NSGridView, "the sentence follows the clumping controls")
        XCTAssertTrue(order[sentenceIndex + 1].subviews.contains(sheet.writeButton), "and comes before the buttons")

        sheet.writeButton.performClick(nil)
        sheet.writeClicked(nil)
        XCTAssertEqual(chooserCalls, 0)
        XCTAssertTrue(written.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let withExecutor = makeSheet(inputs: [fixture.readsFolder], fixture: fixture)
        XCTAssertTrue(withExecutor.noExecutorLabel.isHidden)
        XCTAssertTrue(withExecutor.writeButton.isEnabled)
        XCTAssertNil(withExecutor.writeButton.accessibilityHelp())
    }

    // MARK: The platform-first default (C5 D8 B)

    /// A long-read batch opens with the box clear once its platform is detected, and the popup and its label disabled
    /// while it is. The box stays tickable: ticking it enables the popup and asks for BBTools clumpify, and the sheet adds
    /// no sentence of its own.
    func testPlanSheetClearsBoxForLongReadBatch() async throws {
        let fixture = try writeFixture()
        let sheet = makeSheet(inputs: [PlatformHeaderFixtures.url("ont-minknow-full.fastq")], fixture: fixture)
        await sheet.platformDetection?.value
        XCTAssertEqual(sheet.clumpifyCheckbox.state, .off)
        XCTAssertTrue(sheet.clumpifyCheckbox.isEnabled, "the box stays tickable")
        XCTAssertFalse(sheet.clumpingToolPopup.isEnabled)
        XCTAssertFalse(sheet.clumpingToolLabel.isEnabled)
        XCTAssertTrue(sheet.clumpingToolLineLabel.isHidden)
        let clear = try XCTUnwrap(sheet.request(planFolder: root.appendingPathComponent("plan")))
        XCTAssertTrue(clear.arguments.contains("--no-optimize-storage"))
        XCTAssertNil(Self.value(after: "--clumping-tool", in: clear.arguments))

        sheet.clumpifyCheckbox.performClick(nil)
        XCTAssertEqual(sheet.clumpifyCheckbox.state, .on)
        XCTAssertTrue(sheet.clumpingToolPopup.isEnabled)
        let ticked = try XCTUnwrap(sheet.request(planFolder: root.appendingPathComponent("plan")))
        XCTAssertEqual(Self.value(after: "--clumping-tool", in: ticked.arguments), "bbtools")
        XCTAssertFalse(ticked.arguments.contains("--no-optimize-storage"))
    }

    func testPlanSheetArgvClumpsAnIlluminaBatch() async throws {
        try await assertPlanArgv(for: "illumina-novaseq6000.fastq", clumps: true)
    }

    func testPlanSheetArgvClumpsAnElementBatch() async throws {
        try await assertPlanArgv(for: "element-aviti.fastq", clumps: true)
    }

    func testPlanSheetArgvClumpsAnMGIBatch() async throws {
        try await assertPlanArgv(for: "mgi-dnbseq.fastq", clumps: true)
    }

    func testPlanSheetArgvSkipsClumpingForAnONTBatch() async throws {
        try await assertPlanArgv(for: "ont-minknow-full.fastq", clumps: false)
    }

    func testPlanSheetArgvSkipsClumpingForAPacBioBatch() async throws {
        try await assertPlanArgv(for: "pacbio-revio-ccs.fastq", clumps: false)
    }

    func testPlanSheetArgvSkipsClumpingForAnUnknownBatch() async throws {
        try await assertPlanArgv(for: "sra-renamed-short.fastq", clumps: false)
    }

    /// The box the sheet opens with for the batch `fixtureName` follows `ClumpingTool.automaticChoice(for:)` of the
    /// platform the Import flow detects, and the argv asks for BBTools clumpify or `--no-optimize-storage`.
    private func assertPlanArgv(
        for fixtureName: String, clumps: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let fixture = try writeFixture()
        let reads = PlatformHeaderFixtures.url(fixtureName)
        let platform = FASTQPlanSheetModel.detectedPlatform(of: [reads])
        XCTAssertEqual(
            ClumpingTool.automaticChoice(for: platform).tool != .none, clumps,
            "\(fixtureName) reads as \(platform)", file: file, line: line
        )
        let sheet = makeSheet(inputs: [reads], fixture: fixture)
        await sheet.platformDetection?.value
        XCTAssertEqual(sheet.clumpifyCheckbox.state, clumps ? .on : .off, fixtureName, file: file, line: line)
        let request = try XCTUnwrap(sheet.request(planFolder: root.appendingPathComponent("plan")), file: file, line: line)
        XCTAssertEqual(
            Self.value(after: "--clumping-tool", in: request.arguments), clumps ? "bbtools" : nil, fixtureName,
            file: file, line: line
        )
        XCTAssertEqual(request.arguments.contains("--no-optimize-storage"), !clumps, fixtureName, file: file, line: line)
    }

    /// The Import sheet offers no Automatic: its popup holds BBTools clumpify and Trim Galore only.
    func testImportSheetOffersNoAutomatic() throws {
        let sheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: URL(fileURLWithPath: "/data/S1_R1.fastq.gz"), r2: URL(fileURLWithPath: "/data/S1_R2.fastq.gz"))],
            detectedPlatform: .illumina
        )
        sheet.loadViewIfNeeded()
        let popup = try XCTUnwrap(Self.descendants(of: sheet.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("BBTools clumpify") })
        XCTAssertEqual(popup.itemTitles, Self.popupTitles)
        XCTAssertFalse(popup.itemTitles.contains("Automatic"))
    }

    // MARK: Helpers

    private func makeSheet(inputs: [URL], fixture: Fixture) -> FASTQPlanSheet {
        let sheet = FASTQPlanSheet(
            inputs: inputs, executorFolder: fixture.executorFolder, imageFiles: (fixture.image, fixture.toolManifest)
        )
        sheet.loadViewIfNeeded()
        sheet.stagingField.stringValue = Fixture.stagingFolder
        sheet.stagingField.sendAction(sheet.stagingField.action, to: sheet.stagingField.target)
        return sheet
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Runs the sheet's argv as `lungfish-cli` would, after its `import fastq` words.
    private static func runThroughCLI(_ arguments: [String]) async throws {
        XCTAssertEqual(Array(arguments.prefix(2)), ["import", "fastq"])
        let command = try ImportCommand.FastqSubcommand.parse(Array(arguments.dropFirst(2)))
        try await command.run()
    }

    private static func clumping(in plan: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: plan)) as? [String: Any]
        return try XCTUnwrap(object?["clumping"] as? [String: Any], "plan.json has no clumping entry")
    }

    /// Two paired samples, an executor stand-in with its `manifest.json`, a tool manifest and the `image.json` that pins
    /// it, as `ImportFastqPlanOptionsTests` writes them.
    private struct Fixture {
        var readsFolder: URL
        var executorFolder: URL
        var image: URL
        var toolManifest: URL

        static let stagingFolder = "/staging/groups/g/1/lge-test"
    }

    private func writeFixture() throws -> Fixture {
        let reads = root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        // Illumina headers, so the sheet opens with the box on for these short reads (D8 B).
        for (index, sample) in ["S1", "S2"].enumerated() {
            for mate in [1, 2] {
                let header = { (y: Int) in "@A00488:61:HMLGNDSXX:4:1101:\(1000 + index):\(y) \(mate):N:0:ATCACG+TTAGGC" }
                try "\(header(5678))\nACGTACGTAC\n+\nFFFFFFFFFF\n\(header(5679))\nTTGGCCAATT\n+\nFFFFFFFFFF\n"
                    .write(to: reads.appendingPathComponent("\(sample)_R\(mate).fastq"), atomically: true, encoding: .utf8)
            }
        }
        let executorFolder = root.appendingPathComponent("executor", isDirectory: true)
        try FileManager.default.createDirectory(at: executorFolder, withIntermediateDirectories: true)
        let executor = Data("executor stand-in".utf8)
        try executor.write(to: executorFolder.appendingPathComponent("lungfish-executor"))
        let digest = String(repeating: "b", count: 64)
        let manifest: [String: Any] = [
            "sha256": PortableDigest.sha256Hex(of: executor), "size": executor.count,
            "lgeVersion": "2026.10.22", "lgeCommit": "74ae0db3400d6b7519550e33dafc369e081fa114",
            "targetTriple": "x86_64-swift-linux-musl", "toolchainID": "swift-6.2", "toolchainSHA256": digest,
            "staticLinuxSDKID": "swift-6.2-static-linux", "staticLinuxSDKSHA256": digest,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: executorFolder.appendingPathComponent("manifest.json"))
        let tools = [("clumpify.sh", "39.13", "he5f24ec_0", "bbmap"), ("reformat.sh", "39.13", "he5f24ec_0", "bbmap"),
                     ("java", "25.0.2", "h1602c4f_26", "openjdk"), ("bgzip", "1.21", "h3ff9d97_0", "htslib"),
                     ("pigz", "2.8", "h421ea60_1", "pigz"), ("seqkit", "2.10.0", "h9ee0642_0", "seqkit"),
                     ("gzip", "1.13", "h8359307_0", "gzip"), ("fastp", "1.0.1", "h43da1c4_0", "fastp")]
        let toolManifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/bin/\($0.0)", condaPackage: $0.3)
        }).encoded()
        let toolManifestURL = root.appendingPathComponent("image-manifest.json")
        try toolManifest.write(to: toolManifestURL)
        let image: [String: Any] = [
            "schemaVersion": 1,
            "sif": ["fileName": "lge-tools-test.sif", "sha256": String(repeating: "e", count: 64), "size": 396_402_688],
            "imageManifest": ["sha256": PortableDigest.sha256Hex(of: toolManifest), "size": toolManifest.count],
        ]
        let imageURL = root.appendingPathComponent("image.json")
        try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]).write(to: imageURL)
        return Fixture(readsFolder: reads, executorFolder: executorFolder, image: imageURL, toolManifest: toolManifestURL)
    }
}

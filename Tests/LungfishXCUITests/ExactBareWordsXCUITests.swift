import AppKit
import XCTest

/// Owner row 21 (DEMUX-EXACT-BARE-NO-FLOOR) on the packaged copy, by the release smoke's route (Phase 3.4 lane EXBARE, BIO
/// ruling C2, `STB-R1-BIO.md:112-119`). A person who picks Exact Bare Barcode must be told that no chance check ran, so the
/// test walks row 21 as a person does and reads what the screen and the disk hold and not the dialog's state: the caption
/// under the engine, the Operations row, the Log's warning, `chanceCheck` in the run folder's record, and the reads that
/// EB01 and EB02 get, which make it a real Exact Bare run on the packaged bytes and not a picture of words.
///
/// The dialog carries no accessibility identifier, so every control is found by its label. The test writes its own bundle
/// of 2,000 reads and the custom definition `custom-8mers.csv`, and counts the 8 and 8 reads from that input. It reads
/// clauses and not whole strings, so a rewrap cannot turn it red but a changed word can. It runs only on the gate's
/// candidate (`ReleaseAppSmokeRobot` skips without one), and a skip counts as not run.
final class ExactBareWordsXCUITests: XCTestCase {
    /// The caption under the engine (`FASTQOperationDialogState+ChanceCaption.swift`), by its first and last sentences and
    /// the clause that says what can go wrong.
    private static let captionOpening = "Exact Bare Barcode does not check for chance matches."
    private static let captionReason = "it can make sample files from chance matches"
    private static let captionClosing = "Use it only on reads that carry the barcodes in their sequence."
    /// The Operations row starts with the cause (`FASTQDemultiplexChanceNotice.rowPrefix`) and ends with the completion.
    private static let rowClause = "Not checked for chance matches."
    private static let rowCompletion = "Done in"
    /// The Log's warning starts with the caption's first sentence and asks for a check of the sample files.
    private static let logOpening = "Exact Bare Barcode does not check for chance matches."
    private static let logClosing = "Check the sample files against the samples you expect."

    /// Synchronous, because an XCTest interrupt of a test whose class has async set-up or tear-down hung for 11 minutes
    /// in `_interruptTest` (lane RESCANFIX, `SidebarRescanSelectionXCUITests`).
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testExactBarePickShowsTheCaptionAndItsRunSaysNotCheckedForChanceMatches() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseExactBare")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        try robot.openWritableProject(project) { try ExactBareFixture.add(to: $0) }
        let app = robot.app

        // The 8 and 8 come from the input the app holds, read back from the disk.
        let input = ExactBareFixture.readsURL(in: project)
        let expected = try ExactBareFixture.countsByBarcode(inFASTQAt: input)
        XCTAssertEqual(expected, ExactBareFixture.expectedCounts, "The input holds 8 reads of EB01 and 8 reads of EB02")
        XCTAssertEqual(try ExactBareFixture.readCount(ofFASTQAt: input), ExactBareFixture.readTotal, "The input holds 2,000 reads")

        ReleaseSmokeFixtures.openSidebarItem(containing: ExactBareFixture.bundleName, in: app)
        guard app.descendants(matching: .any)["fastq-dataset-view"].firstMatch.waitForExistence(timeout: 15) else {
            robot.failShowingScreen("The \(ExactBareFixture.bundleName) bundle shows no FASTQ dataset view")
            return
        }
        guard openDemultiplexDialog(robot) else { return }

        // Row 21, the caption. Exact Bare Barcode is picked and the words under the engine say no chance check runs.
        guard click("Exact Bare Barcode", in: robot) else { return }
        for clause in [Self.captionOpening, Self.captionReason, Self.captionClosing] {
            XCTAssertTrue(staticText(containing: clause, in: app).waitForExistence(timeout: 10),
                          "The dialog's caption under Exact Bare Barcode holds \"\(clause)\"")
        }

        // The Custom Definition is the project's custom-8mers.csv, chosen from the Project File picker.
        guard click("Custom Definition", in: robot) else { return }
        // SwiftUI draws the Project File picker as a pop-up whose value is the chosen item's words, and the words "Project File"
        // belong to a static text beside it (gate run 2 of lane EXBARE, real-app-tests.log, the tree under the first failure).
        let projectFile = app.popUpButtons.matching(NSPredicate(format: "value == %@", "Choose project file")).firstMatch
        guard projectFile.waitForExistence(timeout: 10) else {
            robot.failShowingScreen("The dialog shows no Project File picker for the custom definition")
            return
        }
        projectFile.click()
        let definition = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", ExactBareFixture.definitionName)).firstMatch
        guard definition.waitForExistence(timeout: 5) else {
            robot.failShowingScreen("The Project File picker lists no \(ExactBareFixture.definitionName)")
            return
        }
        definition.click()
        guard let run = robot.firstOf([app.sheets.buttons["Run"].firstMatch, app.dialogs.buttons["Run"].firstMatch,
                                       app.windows.buttons["Run"].firstMatch], timeout: 10, hittable: true) else {
            robot.failShowingScreen("The dialog shows no Run button")
            return
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: run)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "Run is live for Exact Bare Barcode with \(ExactBareFixture.definitionName)")
        run.click()

        // Row 21, the Operations row. The panel is shown when the run did not show it, and a finished row ends in the completion.
        if !app.descendants(matching: .any)["operations-table"].firstMatch.waitForExistence(timeout: 3) {
            robot.menu("Operations", item: "Show Operations Panel")
        }
        let finished = NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
                                   "operations-detail-", Self.rowCompletion, Self.rowCompletion)
        let row = app.staticTexts.matching(finished).firstMatch
        guard row.waitForExistence(timeout: 60) else {
            robot.failShowingScreen("No Operations row finished with \"\(Self.rowCompletion)\" within 60 s of Run")
            return
        }
        let rowWords = "\(row.label) \(String(describing: row.value ?? ""))"
        XCTAssertTrue(rowWords.contains(Self.rowClause), "The finished Operations row holds \"\(Self.rowClause)\" and reads \"\(rowWords)\"")

        // Row 21, the Log. Its warning starts with the caption's first sentence and ends by asking for a check of the samples.
        let toggle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "operations-detail-toggle-")).firstMatch
        guard toggle.waitForExistence(timeout: 10) else {
            robot.failShowingScreen("The Operations row shows no Log button")
            return
        }
        toggle.click()
        let inspector = app.descendants(matching: .any)["operations-log-inspector"].firstMatch
        guard inspector.waitForExistence(timeout: 10) else {
            robot.failShowingScreen("The Log button opens no Operations log")
            return
        }
        for clause in [Self.logOpening, Self.logClosing] {
            // The Log is a text view whose value is its text. Only text views and static texts are asked, since CONTAINS cannot
            // match a value that is a number.
            let inTextView = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", clause)).firstMatch
            let inStaticText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", clause, clause)).firstMatch
            XCTAssertNotNil(robot.firstOf([inTextView, inStaticText], timeout: 10), "The Log of the run holds \"\(clause)\"")
        }

        // Row 21, the disk. The run folder's record says no chance check ran, and EB01 and EB02 each hold the reads of the input.
        let written = NSPredicate { _, _ in !ExactBareFixture.runFolders(in: project).isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 30), .completed,
                       "The run writes a run folder with a demultiplex manifest")
        let folders = ExactBareFixture.runFolders(in: project)
        XCTAssertEqual(folders.count, 1, "The run writes one run folder, not \(folders.map(\.lastPathComponent))")
        guard let runFolder = folders.first else { return }
        let checks = try ExactBareFixture.chanceChecks(inRecordAt: runFolder.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertEqual(checks, ["none"], "The run folder's record says chanceCheck is none")
        for (barcode, count) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(try ExactBareFixture.readCount(ofBarcode: barcode, in: runFolder), count,
                           "\(barcode) holds the \(count) reads of the input that carry it")
        }
    }

    /// Tools > Demultiplexing > Demultiplex Barcodes… on the bundle selected in the sidebar (the route of `AssemblyRobot`).
    @MainActor
    private func openDemultiplexDialog(_ robot: ReleaseAppSmokeRobot) -> Bool {
        let app = robot.app
        let tools = app.menuBars.menuBarItems["Tools"]
        guard tools.waitForExistence(timeout: 5) else {
            robot.failShowingScreen("The menu bar has no Tools menu")
            return false
        }
        tools.click()
        let category = app.menuItems["Demultiplexing"]
        guard category.waitForExistence(timeout: 5) else {
            robot.failShowingScreen("The Tools menu has no Demultiplexing submenu")
            return false
        }
        category.click()
        let tool = app.menuItems["Demultiplex Barcodes\u{2026}"]
        guard tool.waitForExistence(timeout: 5), tool.isEnabled else {
            robot.failShowingScreen("The Demultiplexing submenu has no live Demultiplex Barcodes\u{2026} item")
            return false
        }
        tool.click()
        return true
    }

    /// The static text that holds `clause` in its label or its value.
    @MainActor
    private func staticText(containing clause: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", clause, clause)).firstMatch
    }

    /// The dialog's segmented pickers carry no identifier, and AppKit names a segment as a radio button or a button.
    @MainActor
    private func click(_ title: String, in robot: ReleaseAppSmokeRobot) -> Bool {
        let app = robot.app
        let candidates = [app.radioButtons[title].firstMatch, app.segmentedControls.buttons[title].firstMatch, app.buttons[title].firstMatch]
        guard let control = robot.firstOf(candidates, timeout: 10, hittable: true) else {
            robot.failShowingScreen("The dialog shows no \(title) control within 10 s")
            return false
        }
        control.click()
        return true
    }
}

/// The input of the test, written into the project before it opens: a FASTQ bundle of 2,000 reads of 100 bases and the
/// custom definition of the walk (`custom-8mers.csv`, EB01 `GATCGTAC` and EB02 `CTAGAGTC`). The background reads carry
/// neither barcode in either orientation, and 8 reads carry EB01 and 8 carry EB02, so a real Exact Bare run makes 8 and 8.
nonisolated enum ExactBareFixture {
    static let bundleName = "EXACTBARE-2000"
    static let definitionName = "custom-8mers.csv"
    static let barcodes: [(id: String, sequence: String)] = [("EB01", "GATCGTAC"), ("EB02", "CTAGAGTC")]
    static let expectedCounts = ["EB01": 8, "EB02": 8]
    static let readTotal = 2000
    static let readLength = 100
    static let readsPerBarcode = 8

    static func readsURL(in project: URL) -> URL {
        project.appendingPathComponent("\(bundleName).lungfishfastq/reads.fastq")
    }

    static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return base
            }
        })
    }

    /// Whether `read` holds `barcode` or its reverse complement as an exact match anywhere, as Exact Bare Barcode looks.
    static func carries(_ read: String, _ barcode: String) -> Bool {
        read.contains(barcode) || read.contains(reverseComplement(barcode))
    }

    static func countsByBarcode(in reads: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for barcode in barcodes { counts[barcode.id] = reads.filter { carries($0, barcode.sequence) }.count }
        return counts
    }

    static func sequences(inFASTQ text: String) -> [String] {
        let lines = text.split(separator: "\n").map(String.init)
        return stride(from: 1, to: lines.count, by: 4).map { lines[$0] }
    }

    static func countsByBarcode(inFASTQAt url: URL) throws -> [String: Int] {
        countsByBarcode(in: sequences(inFASTQ: try String(contentsOf: url, encoding: .utf8)))
    }

    static func readCount(ofFASTQAt url: URL) throws -> Int {
        sequences(inFASTQ: try String(contentsOf: url, encoding: .utf8)).count
    }

    /// 2,000 reads from a fixed seed. The background reads are drawn again until they carry no barcode, and a read that
    /// takes a barcode is spliced and kept only when it then carries that one barcode alone.
    static func makeReads() -> [String] {
        var generator = ExactBareGenerator(state: 0x4558_4143_5442_4152)
        let alphabet = Array("ACGT")
        func randomRead() -> String {
            var bases: [Character] = []
            for _ in 0..<readLength { bases.append(alphabet[Int(generator.next() % 4)]) }
            return String(bases)
        }
        func cleanRead() -> String {
            while true {
                let read = randomRead()
                if !barcodes.contains(where: { carries(read, $0.sequence) }) { return read }
            }
        }
        var reads: [String] = []
        for barcode in barcodes {
            var made = 0
            while made < readsPerBarcode {
                var bases = Array(cleanRead())
                let start = 10 + Int(generator.next() % UInt64(readLength - barcode.sequence.count - 20))
                bases.replaceSubrange(start..<(start + barcode.sequence.count), with: Array(barcode.sequence))
                let read = String(bases)
                guard barcodes.filter({ carries(read, $0.sequence) }).map(\.id) == [barcode.id] else { continue }
                reads.append(read)
                made += 1
            }
        }
        while reads.count < readTotal { reads.append(cleanRead()) }
        for index in stride(from: reads.count - 1, to: 0, by: -1) {
            reads.swapAt(index, Int(generator.next() % UInt64(index + 1)))
        }
        return reads
    }

    /// The bundle with cached statistics, so the dashboard opens with no seqkit (as `ReleaseSmokeFixtures.addFASTQBundle`),
    /// and `Barcode Definitions/custom-8mers.csv`, where the dialog's Project File picker looks.
    static func add(to project: URL) throws {
        let reads = makeReads()
        let bundle = project.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let quality = String(repeating: "I", count: readLength)
        let text = reads.enumerated().map { "@read\($0.offset + 1)\n\($0.element)\n+\n\(quality)\n" }.joined()
        try text.write(to: readsURL(in: project), atomically: true, encoding: .utf8)
        let bases = reads.count * readLength
        let gc = reads.reduce(0) { total, read in total + read.filter { $0 == "G" || $0 == "C" }.count }
        let statistics: [String: Any] = ["readCount": reads.count, "baseCount": bases, "meanReadLength": Double(readLength),
                                         "minReadLength": readLength, "maxReadLength": readLength, "medianReadLength": readLength,
                                         "n50ReadLength": readLength, "meanQuality": 40.0, "q20Percentage": 100.0,
                                         "q30Percentage": 100.0, "gcContent": Double(gc) / Double(bases),
                                         "readLengthHistogram": ["\(readLength)": reads.count], "qualityScoreHistogram": [40, bases],
                                         "perPositionQuality": [Any]()]
        try JSONSerialization.data(withJSONObject: ["computedStatistics": statistics], options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("reads.fastq.lungfish-meta.json"))
        let definitions = project.appendingPathComponent("Barcode Definitions", isDirectory: true)
        try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
        let rows = barcodes.map { "\($0.id),\($0.sequence)" }.joined(separator: "\n")
        try "id,sequence\n\(rows)\n".write(to: definitions.appendingPathComponent(definitionName), atomically: true, encoding: .utf8)
    }

    /// Every folder of the project that holds a `demux-manifest.json`, which is a demultiplex run folder.
    static func runFolders(in project: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) else { return [] }
        // A run folder holds the manifest and the run's own record side by side.
        return walker.compactMap { ($0 as? URL).flatMap { $0.lastPathComponent == "demux-manifest.json" ? $0.deletingLastPathComponent() : nil } }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".lungfish-provenance.json").path) }
    }

    /// The reads of the sample file that `barcode` got in the run folder (`<barcode>.lungfishfastq/<barcode>.fastq`).
    static func readCount(ofBarcode barcode: String, in runFolder: URL) throws -> Int {
        let manager = FileManager.default
        let bundles = try manager.contentsOfDirectory(at: runFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lungfishfastq" && $0.lastPathComponent.hasPrefix(barcode) }
        guard bundles.count == 1, let bundle = bundles.first else {
            throw NSError(domain: "ExactBareFixture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The run folder holds \(bundles.count) sample bundles for \(barcode), not one"])
        }
        let files = try manager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fastq" && $0.lastPathComponent != "preview.fastq" }
        guard files.count == 1, let file = files.first else {
            throw NSError(domain: "ExactBareFixture", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(bundle.lastPathComponent) holds \(files.count) FASTQ files, not one"])
        }
        return try readCount(ofFASTQAt: file)
    }

    /// The text values under every `chanceCheck` of the record, however the record nests it. A value tagged with its type
    /// reads as the value alone, and a name and value pair reads as its value.
    static func chanceChecks(inRecordAt url: URL) throws -> [String] {
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return Array(Set(chanceCheckValues(in: document, underChanceCheck: false))).sorted()
    }

    private static func chanceCheckValues(in value: Any, underChanceCheck: Bool) -> [String] {
        if let object = value as? [String: Any] {
            let named = object.values.contains { ($0 as? String) == "chanceCheck" }
            return object.flatMap { chanceCheckValues(in: $0.value, underChanceCheck: underChanceCheck || named || $0.key == "chanceCheck") }
        }
        if let list = value as? [Any] { return list.flatMap { chanceCheckValues(in: $0, underChanceCheck: underChanceCheck) } }
        guard underChanceCheck else { return [] }
        let leaf = String(describing: value)
        return ["string", "chanceCheck"].contains(leaf) ? [] : [leaf]
    }
}

/// SplitMix64, so the input is the same on every run.
nonisolated struct ExactBareGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

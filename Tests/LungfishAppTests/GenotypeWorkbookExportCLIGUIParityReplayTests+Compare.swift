// GenotypeWorkbookExportCLIGUIParityReplayTests+Compare.swift - How the workbook parity class compares two workbooks and two Excel export folders
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B1, manager decision MGR-12.35-B1C items 1 and 2. These functions belong to the B1 class
// alone and are no shared policy.
//
// - The workbook (item 1). `workbookDifferences` reads each .xlsx through the goldens' own XLSX normalization,
//   `Normalizer.xlsx_parts` with `mask_core_xml_times` (`scripts/golden/normalize.py`), run by the managed Python. Zip
//   entry order and entry times are not compared, the times in `docProps/core.xml` are masked, and every other part
//   must also be byte-equal once each side's own root is read as the goldens' root token.
// - The Excel service's folder (item 2). `exportFolderDifferences` pairs `<out>.export-<UUID>/` on two sides by name
//   with the UUID masked, and compares each pair of files byte for byte once each side's own root path is read as one
//   token. The folder's UUID is a run UUID, which the contract's masks number (`docs/contracts/CLI-EQUIVALENCE.md`,
//   row Masks), and `replay.sh` names it in its own paths, so the folder's own name is read with its UUID masked too.
//   `request.json` holds the request the leaf read as base64, so the root is read inside each decoded input, as the
//   goldens' `Normalizer.request` (rule R16) reads it.
// - The receipt's `output`, `replayScript` and `request` descriptors are checked against each side's own file
//   (`assertDescriptorsMatchOwnFiles`), not across sides.

import Foundation
import LungfishKitTestSupport
import XCTest

extension GenotypeWorkbookExportCLIGUIParityReplayTests {
    /// The goldens' scripts, whose `normalize.py` holds `Normalizer.xlsx_parts` and `mask_core_xml_times`.
    static let goldenScripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/golden", isDirectory: true)

    /// The id the harness gives the workbook when its bytes differ. Item 1 compares the workbook in this class.
    static var workbookDifferenceID: String { "differs: \(outputName)" }

    /// The receipt values that this class checks against each side's own file instead of across sides (items 1, 2).
    /// The workbook's digest and size are among them, since its zip holds run times and so its deflated size moves by a
    /// byte between runs.
    static let receiptValuesCheckedPerSide = [
        "output.sha256", "output.sizeBytes", "replayScript.sha256", "replayScript.sizeBytes", "request.sha256",
        "request.sizeBytes",
    ]

    /// Whether a difference the harness found C against C' is one this class compares itself (items 1 and 2). The
    /// workbook, the files of the Excel service's folder, which the harness cannot pair by their UUID names, and the
    /// receipt's digests and sizes of those files.
    static func isComparedByThisClass(_ difference: RouteParityDifference) -> Bool {
        if difference.id == workbookDifferenceID || difference.id.contains(outputName + ".export-") { return true }
        let receipt = "differs: \(outputName).provenance.json at "
        return receiptValuesCheckedPerSide.contains { difference.id == receipt + $0 }
    }

    // MARK: - The workbook (item 1)

    /// The parts of an .xlsx as the goldens read them, each as its SHA-256. `normalized` is `Normalizer.xlsx_parts`.
    /// `relocated` is the same reader with the root token alone, which shows every part but `docProps/core.xml`
    /// byte-equal.
    static func workbookParts(of workbook: URL, root: URL, python: URL) throws
        -> (normalized: [String: String], relocated: [String: String]) {
        let text = try runPython(python, script: workbookPartsScript,
            arguments: [goldenScripts.path, workbook.path, root.standardizedFileURL.path])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: String]])
        return (try XCTUnwrap(object["normalized"]), try XCTUnwrap(object["relocated"]))
    }

    /// How two workbooks differ under the goldens' XLSX normalization, empty when they match.
    static func workbookDifferences(_ a: URL, root rootA: URL, _ b: URL, root rootB: URL, python: URL) throws -> [String] {
        let partsA = try workbookParts(of: a, root: rootA, python: python)
        let partsB = try workbookParts(of: b, root: rootB, python: python)
        let normalized = Set(partsA.normalized.keys).union(partsB.normalized.keys).sorted()
            .filter { partsA.normalized[$0] != partsB.normalized[$0] }
            .map { "\($0) differs under xlsx_parts" }
        let relocated = Set(partsA.relocated.keys).union(partsB.relocated.keys).sorted()
            .filter { $0 != "docProps/core.xml" && partsA.relocated[$0] != partsB.relocated[$0] }
            .map { "\($0) differs byte for byte" }
        return normalized + relocated
    }

    static let workbookPartsScript = #"""
import hashlib, json, sys
sys.path.insert(0, sys.argv[1])
from normalize import Normalizer
data = open(sys.argv[2], "rb").read()
normalizer = Normalizer(run_root=sys.argv[3], lock_sha256=None)
def digests(parts):
    return {name: hashlib.sha256(content).hexdigest() for name, content in parts.items()}
print(json.dumps({"normalized": digests(normalizer.xlsx_parts(data)),
                  "relocated": digests(normalizer.xlsx_parts(data, relocate_only=True))}, sort_keys=True))
"""#

    /// The negative control of item 1. Copies a workbook with the text of its first string cell changed, every other
    /// entry as it was, and prints the part it changed.
    static let changeOneCellScript = #"""
import re, sys, zipfile
pattern = re.compile(rb"(<t\b[^>]*>)([^<]+)(</t>)")
with zipfile.ZipFile(sys.argv[1]) as source:
    infos = source.infolist()
    names = sorted(i.filename for i in infos if i.filename == "xl/sharedStrings.xml" or i.filename.startswith("xl/worksheets/"))
    part = next(name for name in names if pattern.search(source.read(name)))
    with zipfile.ZipFile(sys.argv[2], "w") as target:
        for info in infos:
            content = source.read(info.filename)
            if info.filename == part:
                content = pattern.sub(lambda m: m.group(1) + m.group(2) + b" changed" + m.group(3), content, count=1)
            target.writestr(info, content)
print(part)
"""#

    // MARK: - The Excel service's folder (item 2)

    /// A side's `<out>.export-<UUID>/` folders by their name with the UUID masked.
    static func exportFolders(in root: URL) throws -> [String: [URL]] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(outputName + ".export-") }
        return Dictionary(grouping: names.map { root.appendingPathComponent($0, isDirectory: true) }) {
            RouteParityHarness.maskedID($0.lastPathComponent)
        }
    }

    /// How the Excel service's folders of two sides differ, empty when they match. The folders pair by name with the
    /// UUID masked and hold the same file names, and each pair of files is byte-equal once each side's own root path
    /// and its own folder's name are read as tokens.
    static func exportFolderDifferences(_ rootA: URL, _ rootB: URL) throws -> [String] {
        let foldersA = try exportFolders(in: rootA)
        let foldersB = try exportFolders(in: rootB)
        var found = Set(foldersA.keys).symmetricDifference(foldersB.keys).sorted().map { "\($0) is on one side only" }
        for name in Set(foldersA.keys).intersection(foldersB.keys).sorted() {
            guard let a = foldersA[name], let b = foldersB[name], a.count == 1, b.count == 1 else {
                found.append("\(name) names more than one folder on a side")
                continue
            }
            let filesA = try files(in: a[0])
            let filesB = try files(in: b[0])
            found += filesA.symmetricDifference(filesB).sorted().map { "\(name)/\($0) is on one side only" }
            for file in filesA.intersection(filesB).sorted() {
                let bytesA = tokenized(try Data(contentsOf: a[0].appendingPathComponent(file)), root: rootA, folder: a[0])
                let bytesB = tokenized(try Data(contentsOf: b[0].appendingPathComponent(file)), root: rootB, folder: b[0])
                if bytesA != bytesB { found.append("\(name)/\(file) differs" + firstDifferingLine(bytesA, bytesB)) }
            }
        }
        return found
    }

    /// The first line two texts hold differently, as the detail of a difference, or nothing for bytes.
    private static func firstDifferingLine(_ a: Data, _ b: Data) -> String {
        guard let textA = String(data: a, encoding: .utf8), let textB = String(data: b, encoding: .utf8) else { return "" }
        let linesA = textA.components(separatedBy: "\n")
        let linesB = textB.components(separatedBy: "\n")
        guard let index = (0..<max(linesA.count, linesB.count)).first(where: {
            ($0 < linesA.count ? linesA[$0] : nil) != ($0 < linesB.count ? linesB[$0] : nil)
        }) else { return "" }
        func line(_ lines: [String]) -> String { index < lines.count ? String(lines[index].prefix(240)) : "(none)" }
        return " at line \(index + 1): \(line(linesA)) | \(line(linesB))"
    }

    /// The files under a folder, by their path from it.
    private static func files(in folder: URL) throws -> Set<String> {
        let fileManager = FileManager.default
        return Set(try fileManager.subpathsOfDirectory(atPath: folder.path).filter { path in
            var isFolder: ObjCBool = false
            let exists = fileManager.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isFolder)
            return exists && !isFolder.boolValue
        })
    }

    /// A file's bytes with each spelling of its side's root read as `<ROOT>`, then its folder's name with the UUID
    /// masked. A file that is not UTF-8 text keeps its bytes. A request holds each input it witnesses as base64
    /// (`GenotypeExcelExportService.ProvenanceRequest.InputWitness.data`), so the root is read in each decoded UTF-8
    /// input and the input encoded again, as the goldens read an export folder's `request.json`
    /// (`Normalizer.request`, rule R16). The raw input is also compared on its own as `input-<n>.bin`.
    private static func tokenized(_ data: Data, root: URL, folder: URL) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let spellings = [root.resolvingSymlinksInPath().standardizedFileURL.path, root.standardizedFileURL.path]
        func rootToken(_ text: String) -> String {
            spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: "<ROOT>") }
        }
        var rooted = rootToken(text)
        for encoded in witnessedInputs(in: data) {
            guard let raw = Data(base64Encoded: encoded), raw.base64EncodedString() == encoded,
                  let payload = String(data: raw, encoding: .utf8) else { continue }
            rooted = rooted.replacingOccurrences(of: encoded, with: Data(rootToken(payload).utf8).base64EncodedString())
        }
        let name = folder.lastPathComponent
        return Data(rooted.replacingOccurrences(of: name, with: RouteParityHarness.maskedID(name)).utf8)
    }

    /// The base64 `data` of each input a request witnesses, or none for any other file.
    private static func witnessedInputs(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inputs = object["inputs"] as? [[String: Any]] else { return [] }
        return inputs.compactMap { $0["data"] as? String }
    }

    // MARK: - Each side's own files

    /// The receipt's `output`, `replayScript` and `request` descriptors state the side's own file, under the side's
    /// root, with its SHA-256 and size.
    static func assertDescriptorsMatchOwnFiles(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let receipt = try receipt(in: root)
        for key in ["output", "replayScript", "request"] {
            let descriptor = try XCTUnwrap(receipt[key] as? [String: Any], key, file: file, line: line)
            let path = try XCTUnwrap(descriptor["path"] as? String, key, file: file, line: line)
            XCTAssertNotEqual(relative(path, under: root), path, "\(key) is the side's own file", file: file, line: line)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(descriptor["sha256"] as? String, digest(data), "\(key) sha256", file: file, line: line)
            XCTAssertEqual(descriptor["sizeBytes"] as? Int, data.count, "\(key) size", file: file, line: line)
        }
    }

    /// Runs a script with the managed Python and returns its standard output.
    static func runPython(_ python: URL, script: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", script] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: "python exited \(process.terminationStatus): \(String(decoding: error, as: UTF8.self))",
            ])
        }
        return String(decoding: output, as: UTF8.self)
    }
}

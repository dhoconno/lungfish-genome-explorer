import Foundation
import LungfishIO

extension GenotypeEditableWorkbookService {
    private struct ThreeSheetManifest: Codable {
        let schemaVersion: Int
        let role: String
        let callEditingSupported: Bool
        let sheetOrder: [String]
        let callTargets: [String: CallTarget]
        let noteTargets: [String: NoteTarget]
        let immutableCells: [String: ManifestCell]
        let expectedFormulas: [String: [String: String]]
        let identityCells: [String: IdentityCell]
        let allowedNoteGrammarVersion: Int
    }
    private struct CallTarget: Codable {
        let sampleID: String
        let locus: String
        let h1: CallSlot
        let h2: CallSlot
    }
    private struct CallSlot: Codable {
        let valueCell: String
        let actionCell: String
        let baselineAvailable: Bool
        let pipeline: String?
        let effective: String
    }
    private struct NoteTarget: Codable {
        let sheet: String
        let cell: String
        let target: [String: JSONValue]
        let rawSupport: Int?
        let reviewEligible: Bool
        let currentComment: String?
        let currentReview: String?
        let generatedText: String
    }
    private struct ManifestCell: Codable {
        let type: String
        let value: JSONValue
        let hyperlink: String?
    }
    private struct IdentityCell: Codable {
        let sheet: String
        let cell: String
        let value: JSONValue
    }
    private struct ThreeSheetParsed: Codable {
        let sheetOrder: [String]
        let cells: [String: String]
        let mergedRanges: [String: [String]]
        let definedNames: [String: String]
        let externalLinks: [String]
        let runtime: Runtime
    }
    private struct PhysicalCell: Codable, Equatable {
        let type: String
        let value: JSONValue
        let hyperlink: String?
        let comment: String?
    }
    private struct NoteEdit {
        let reviewOperation: String
        let reviewValue: String
        let commentOperation: String
        let commentValue: String
    }
    private enum JSONValue: Codable, Equatable {
        case string(String), int(Int), double(Double), bool(Bool), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let value = try? c.decode(Bool.self) { self = .bool(value) }
            else if let value = try? c.decode(Int.self) { self = .int(value) }
            else if let value = try? c.decode(Double.self) { self = .double(value) }
            else { self = .string(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let x): try c.encode(x)
            case .int(let x): try c.encode(x)
            case .double(let x): try c.encode(x)
            case .bool(let x): try c.encode(x)
            case .null: try c.encodeNil()
            }
        }
        var string: String? { if case .string(let x) = self { return x }; return nil }
    }

    func attestThreeSheetWorkbook(workbookURL: URL, bundleURL: URL, scientificInputURLs: [URL], trustedManifest: Data) throws {
        let manifest = try decodeManifest(trustedManifest)
        guard manifest.schemaVersion == 2, manifest.role == "editable-current", manifest.allowedNoteGrammarVersion == 2 else { throw reject("Unsupported trusted workbook manifest.") }
        let parsed = try parseThreeSheet(workbookURL)
        _ = try validateThreeSheet(parsed, manifest: manifest, allowChanges: false)
        var inputs = [try witness(bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename), in: bundleURL)]
        if let sidecar = try sidecarData(in: bundleURL) { inputs.append(Witness(path: GenotypeAnnotationSidecar.filename, sha256: Self.hash(sidecar), size: sidecar.count)) }
        for url in scientificInputURLs where !inputs.contains(where: { $0.path == relative(url, in: bundleURL) }) { inputs.append(try witness(url, in: bundleURL)) }
        let baseline = Baseline(schemaVersion: 2, callEditingSupported: manifest.callEditingSupported, workbook: try witness(workbookURL, in: bundleURL), inputs: inputs, document: Document(sheets: [:], evidence: [:]), trustedManifest: trustedManifest, workbookSnapshot: try encoder.encode(parsed))
        let output = bundleURL.appendingPathComponent(Self.baselinePath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(baseline).write(to: output, options: .atomic)
    }

    func inspectThreeSheet(baseline: Baseline, baselineData: Data, bundleURL: URL, workbookURL: URL, workbookData: Data, startedAt: Date) throws -> Inspection {
        guard let trusted = baseline.trustedManifest else { throw reject("Trusted layout manifest is missing.") }
        let manifest = try decodeManifest(trusted)
        guard manifest.schemaVersion == 2, manifest.role == "editable-current", manifest.allowedNoteGrammarVersion == 2,
              baseline.callEditingSupported == manifest.callEditingSupported else { throw reject("Trusted layout manifest does not match the v2 baseline.") }
        let parsed = try parseThreeSheet(workbookURL)
        guard let snapshotData = baseline.workbookSnapshot,
              let snapshot = try? JSONDecoder().decode(ThreeSheetParsed.self, from: snapshotData),
              parsed.definedNames == snapshot.definedNames else { throw reject("Defined names changed from the attested layout.") }
        let changes = try validateThreeSheet(parsed, manifest: manifest, allowChanges: true)
        guard Self.hash(try Self.readRegular(workbookURL)) == Self.hash(workbookData) else { throw reject("Excel saved during inspection. Inspect again.") }
        let result = Inspection(changes: changes, workbookURL: workbookURL, workbookSHA256: Self.hash(workbookData), bundleURL: bundleURL.standardizedFileURL, baselineSHA256: Self.hash(baselineData), workbookData: workbookData, baseline: baseline, runtime: parsed.runtime, parsedData: try encoder.encode(parsed), wallTimeSeconds: Date().timeIntervalSince(startedAt))
        try revalidate(result)
        return result
    }

    private func decodeManifest(_ data: Data) throws -> ThreeSheetManifest {
        do { return try JSONDecoder().decode(ThreeSheetManifest.self, from: data) }
        catch { throw reject("Trusted layout manifest is invalid: \(error.localizedDescription)") }
    }

    private func parseThreeSheet(_ workbook: URL) throws -> ThreeSheetParsed {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-three-sheet-inspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("inspect-workbook.py"), output = directory.appendingPathComponent("inspection.json"), errorURL = directory.appendingPathComponent("stderr.txt")
        try Data(Self.threeSheetReaderScript.utf8).write(to: script); try Data().write(to: errorURL)
        let errors = try FileHandle(forWritingTo: errorURL); defer { try? errors.close() }
        let process = Process(); process.executableURL = pythonExecutableURL; process.arguments = [script.path, workbook.path, output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw reject(String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)) }
        return try JSONDecoder().decode(ThreeSheetParsed.self, from: Data(contentsOf: output))
    }

    private func validateThreeSheet(_ parsed: ThreeSheetParsed, manifest: ThreeSheetManifest, allowChanges: Bool) throws -> [Change] {
        guard parsed.sheetOrder == manifest.sheetOrder else { throw reject("Worksheet set or order changed; restore the generated three-sheet layout.") }
        guard parsed.externalLinks.isEmpty else { throw reject("External links are not allowed in editable workbooks.") }
        var physical: [String: PhysicalCell] = [:]
        for (key, data) in parsed.cells { physical[key] = try JSONDecoder().decode(PhysicalCell.self, from: Data(data.utf8)) }
        let noteCells = Set(manifest.noteTargets.values.map { $0.sheet + "!" + $0.cell })
        guard !physical.contains(where: { $0.value.comment != nil && !noteCells.contains($0.key) }) else { throw reject("A Note was added outside a trusted annotation target.") }
        var permitted = Set(manifest.immutableCells.keys)
        for (_, target) in manifest.callTargets { for slot in [target.h1, target.h2] { permitted.insert("Haplotype Calls!" + slot.valueCell); permitted.insert("Haplotype Calls!" + slot.actionCell) } }
        for (_, target) in manifest.noteTargets { permitted.insert(target.sheet + "!" + target.cell) }
        for (sheet, formulas) in manifest.expectedFormulas { for address in formulas.keys { permitted.insert(sheet + "!" + address) } }
        guard Set(physical.keys).isSubset(of: permitted) else { throw reject("A value, formula, link, or Note was added outside a trusted editable target.") }
        for (key, expected) in manifest.immutableCells {
            if expected.value == .string(""), expected.hyperlink == nil, physical[key] == nil { continue }
            guard let actual = physical[key], actual.type == expected.type, actual.value == expected.value, actual.hyperlink == expected.hyperlink else { throw reject("Read-only scientific cell changed: \(key).") }
        }
        for (sheet, formulas) in manifest.expectedFormulas { for (address, formula) in formulas {
            guard let actual = physical[sheet + "!" + address], actual.type == "f", actual.value == .string(formula), actual.hyperlink == nil else { throw reject("Generated formula changed: \(sheet)!\(address).") }
        }}
        for (_, identity) in manifest.identityCells {
            guard physical[identity.sheet + "!" + identity.cell]?.value == identity.value else { throw reject("A trusted target is missing, duplicated, or physically reordered.") }
        }
        var changes: [Change] = []
        for id in manifest.callTargets.keys.sorted() {
            let target = manifest.callTargets[id]!
            for (slotName, slot, slotValue) in [("h1", target.h1, HaplotypeSlot.h1), ("h2", target.h2, HaplotypeSlot.h2)] {
                let valueCell = physical["Haplotype Calls!" + slot.valueCell]
                let actionCell = physical["Haplotype Calls!" + slot.actionCell]
                guard valueCell?.type != "f", valueCell?.hyperlink == nil, actionCell?.type != "f", actionCell?.hyperlink == nil else { throw reject("New formulas or links are not allowed in call targets.") }
                let value = valueCell?.value.string ?? ""
                let action = actionCell?.value.string ?? ""
                guard action == "Use entered call" || action == "Use pipeline call" else { throw reject("Unknown \(slotName.uppercased()) import action.") }
                if value == slot.effective && action == "Use entered call" { continue }
                guard allowChanges else { throw reject("Generated workbook does not match its trusted manifest.") }
                guard manifest.callEditingSupported, slot.baselineAvailable else { throw reject("H1/H2 overrides are unavailable without an attested pipeline baseline.") }
                if action == "Use pipeline call" {
                    changes.append(Change(kind: .call, target: nil, sample: target.sampleID, locus: target.locus, slot: slotValue, baseline: slot.pipeline, before: slot.effective, value: nil, passedUniqueReads: nil))
                } else {
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw reject("A nonempty call was blanked. Enter a call or choose Use pipeline call.") }
                    changes.append(Change(kind: .call, target: nil, sample: target.sampleID, locus: target.locus, slot: slotValue, baseline: slot.pipeline, before: slot.effective, value: value, passedUniqueReads: nil))
                }
            }
        }
        for id in manifest.noteTargets.keys.sorted() {
            let note = manifest.noteTargets[id]!, key = note.sheet + "!" + note.cell
            guard let current = physical[key]?.comment else { continue }
            guard let edit = try parseNote(current, generatedText: note.generatedText) else { continue }
            let target = try normalizedTarget(note.target)
            for (kind, operation, value, before) in [(Change.Kind.review, edit.reviewOperation, edit.reviewValue, note.currentReview), (.comment, edit.commentOperation, edit.commentValue, note.currentComment)] {
                if operation == "keep" { guard value.isEmpty else { throw reject("A keep Note operation cannot carry a value.") }; continue }
                guard allowChanges else { throw reject("Generated workbook Note does not match its trusted manifest.") }
                guard operation == "set" || operation == "clear", operation == "set" ? !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : value.isEmpty else { throw reject("Note operations require set with a value or clear without one.") }
                let proposed: String? = operation == "clear" ? nil : value
                if kind == .review {
                    guard note.reviewEligible, case .cell = target else { throw reject("Reviews require an eligible exact cell target.") }
                    if let proposed { guard (proposed == "false-positive" && (note.rawSupport ?? 0) > 0) || (proposed == "false-negative" && note.rawSupport == 0) else { throw reject("Review disposition does not match attested raw evidence.") } }
                }
                changes.append(Change(kind: kind, target: target, sample: target.sample ?? "", locus: target.locus ?? "", slot: nil, baseline: nil, before: before, value: proposed, passedUniqueReads: note.rawSupport))
            }
        }
        return changes
    }

    private func normalizedTarget(_ value: [String: JSONValue]) throws -> GenotypeAnnotationSidecar.MatrixTarget {
        guard let kind = value["kind"]?.string else { throw reject("Trusted Note target has no kind.") }
        let sample = value["sampleID"]?.string, locus = value["locus"]?.string, genotype = value["genotype"]?.string, stable = value["stableClusterID"]?.string
        switch kind {
        case "sample": guard let sample else { throw reject("Trusted sample target is incomplete.") }; return .column(sample: sample)
        case "row": guard let locus, let genotype else { throw reject("Trusted row target is incomplete.") }; return .row(locus: locus, genotype: genotype, stableClusterID: stable)
        case "cell": guard let sample, let locus, let genotype else { throw reject("Trusted cell target is incomplete.") }; return .cell(locus: locus, genotype: genotype, sample: sample, stableClusterID: stable)
        default: throw reject("Unknown trusted Note target kind.")
        }
    }

    private func parseNote(_ text: String, generatedText baseline: String) throws -> NoteEdit? {
        let startRegex = try NSRegularExpression(pattern: #"(?m)^\[LGE Edit v2\]$"#)
        let endRegex = try NSRegularExpression(pattern: #"(?m)^\[/LGE Edit v2\]$"#)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let starts = startRegex.matches(in: text, range: fullRange), ends = endRegex.matches(in: text, range: fullRange)
        let baselineRange = NSRange(baseline.startIndex..<baseline.endIndex, in: baseline)
        let baselineStart = startRegex.firstMatch(in: baseline, range: baselineRange).flatMap { Range($0.range, in: baseline) }
        let baselineGenerated = String(baseline[..<(baselineStart?.lowerBound ?? baseline.endIndex)]).trimmingCharacters(in: .newlines)
        guard !starts.isEmpty || !ends.isEmpty else {
            if text.trimmingCharacters(in: .newlines) == baselineGenerated || text.isEmpty { return nil }
            throw reject("Generated Note text changed or its edit block is missing.")
        }
        guard starts.count == 1, ends.count == 1,
              let startRange = Range(starts[0].range, in: text), let endRange = Range(ends[0].range, in: text), startRange.lowerBound < endRange.lowerBound else { throw reject("A Note must contain exactly one valid LGE Edit v2 block.") }
        let generated = String(text[..<startRange.lowerBound]).trimmingCharacters(in: .newlines)
        guard generated == baselineGenerated, text[endRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw reject("Generated Note text changed.") }
        let body = String(text[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .newlines)
        let pattern = #"^Review operation: (keep|set|clear)\nReview value: (\"(?:[^\"\\]|\\.)*\")\nComment operation: (keep|set|clear)\nComment value: (\"(?:[^\"\\]|\\.)*\")$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, range: range), match.range == range else { throw reject("Malformed LGE Edit v2 Note block.") }
        func capture(_ index: Int) throws -> String { let r = Range(match.range(at: index), in: body)!; return String(body[r]) }
        func jsonString(_ index: Int) throws -> String { try JSONDecoder().decode(String.self, from: Data(try capture(index).utf8)) }
        return try NoteEdit(reviewOperation: capture(1), reviewValue: jsonString(2), commentOperation: capture(3), commentValue: jsonString(4))
    }
}

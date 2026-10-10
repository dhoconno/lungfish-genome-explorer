// DemoProjectProvenanceProjection.swift - The committed expected file for the demo provenance read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The expected file holds what the reader decodes from the released bytes and
// nothing the reading machine fills in. It is written once, on unchanged
// code, with LUNGFISH_CAPTURE_DEMO_PROVENANCE=1, and it is never rewritten to
// make a failing run pass. The Phase 2.4 writer lanes must leave it as it is.

import Foundation

struct DemoProvenanceExpectedFile: Codable, Equatable {
    /// 1 held the sidecar facts, the finder and the lineage. 2 adds the
    /// command, the explicit options, the decoded status and the steps.
    static let currentFormatVersion = 2

    struct Archive: Codable, Equatable {
        var id: String
        var version: String
        var bytes: Int64
        var sha256: String
    }

    struct Descriptor: Codable, Equatable {
        var path: String
        var role: String
        var sha256: String?
        var size: UInt64?
    }

    struct EmbeddedRun: Codable, Equatable {
        var status: String
        var stepCount: Int
    }

    /// One tool invocation of a sidecar. The shell export is built from the
    /// replay argv of these steps, and the tool versions live only here.
    struct Step: Codable, Equatable {
        var toolName: String
        var toolVersion: String
        var argv: [String]
        var durableReplayArgv: [String]?
        var exitStatus: Int?
        var inputs: [Descriptor]
        var outputs: [Descriptor]
    }

    /// One provenance sidecar as the reader decodes it.
    struct Sidecar: Codable, Equatable {
        var sidecar: String
        var decodedBy: String
        var strictAccepts: Bool
        var workflowName: String
        var toolName: String
        var toolVersion: String
        var argv: [String]
        var durableReplayArgv: [String]?
        var reproducibleCommand: String
        var exitStatus: Int?
        var rawStatus: String?
        var decodedStatus: String
        var embeddedRun: EmbeddedRun?
        var explicitOptions: String
        var files: [Descriptor]
        var outputs: [Descriptor]
        var steps: [Step]
    }

    /// The sidecar `findProvenanceEnvelope` returns for one item, nil when it finds none.
    struct FinderPin: Codable, Equatable {
        var selection: String
        var isBundle: Bool
        var sidecar: String?
    }

    struct LineageLink: Codable, Equatable {
        var sidecar: String?
        var workflowName: String
    }

    /// The records `ProvenanceLineageResolver` walks for one sidecar, upstream first.
    struct LineagePin: Codable, Equatable {
        var sidecar: String
        var chain: [LineageLink]
    }

    var formatVersion: Int
    var readingNotes: [String]
    var archive: Archive
    var sidecars: [Sidecar]
    var finder: [FinderPin]
    var lineage: [LineagePin]

    static let notes = [
        "Captured with LUNGFISH_CAPTURE_DEMO_PROVENANCE=1 on code that had not changed any writer (Phase 2.4 lane W1B), then recaptured once in the commit that added the command, options, decoded status and steps. The test refuses to overwrite this file. Later lanes leave it unedited.",
        "Each sidecar entry is what the tolerant reader decodes from the released bytes. It holds no value the reading Mac fills in, such as runtime identity, appVersion, operating system or createdAt.",
        "A path that starts with @/ is inside the installed project. <tool-root> and <storage-root> are the managed roots. <tmp> is a system temporary folder that the bytes record literally. <workspace> is the placeholder as the reader leaves it while the scratch file it names is missing.",
        "decodedBy names the first reader step that accepts the bytes. strictAccepts is the result of loadCanonical. rawStatus is the top-level status string of the file. decodedStatus is the status of the run that the decoded record reports, which must not move when a writer stops embedding a run. embeddedRun is the legacyWorkflowRun block, when the file has one.",
        "reproducibleCommand is the top-level command text. explicitOptions is options.explicit as compact JSON with sorted keys and unescaped slashes. steps lists each tool invocation with its tool, version, argv, replay argv, exit status, inputs and outputs.",
        "finder lists the sidecar that findProvenanceEnvelope returns for each bundle folder and each payload file, with no sidecar when it finds none. lineage lists the records ProvenanceLineageResolver walks for each sidecar, upstream first.",
    ]

    // MARK: - Reading and comparing

    static func load(from url: URL) throws -> DemoProvenanceExpectedFile {
        try JSONDecoder().decode(DemoProvenanceExpectedFile.self, from: Data(contentsOf: url))
    }

    /// Everything the comparison covers, one line for each changed value, naming the
    /// sidecar or selection and the field. The reading notes are prose and are left out.
    func differences(from expected: DemoProvenanceExpectedFile) -> [String] {
        var lines: [String] = []
        if formatVersion != expected.formatVersion {
            lines.append("formatVersion expected \(expected.formatVersion) actual \(formatVersion)")
        }
        if archive != expected.archive {
            lines.append("archive expected \(expected.archive) actual \(archive)")
        }
        lines += Self.compare(expected.sidecars, sidecars, key: \.sidecar, label: "sidecar")
        lines += Self.compare(expected.finder, finder, key: \.selection, label: "finder")
        lines += Self.compare(expected.lineage, lineage, key: \.sidecar, label: "lineage")
        return lines
    }

    private static func compare<Item: Equatable>(
        _ expected: [Item],
        _ actual: [Item],
        key: KeyPath<Item, String>,
        label: String
    ) -> [String] {
        var lines: [String] = []
        let expectedByKey = Dictionary(expected.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { first, _ in first })
        let actualByKey = Dictionary(actual.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { first, _ in first })
        for name in Set(expectedByKey.keys).union(actualByKey.keys).sorted() {
            switch (expectedByKey[name], actualByKey[name]) {
            case (nil, _?):
                lines.append("\(label) \(name) is new")
            case (_?, nil):
                lines.append("\(label) \(name) is gone")
            case (let was?, let now?) where was != now:
                for change in fieldChanges(was, now) {
                    lines.append("\(label) \(name) \(change)")
                }
            default:
                break
            }
        }
        if expected.count != actual.count {
            lines.append("\(label) count expected \(expected.count) actual \(actual.count)")
        }
        return lines
    }

    /// One line for each field whose value differs, found by reflection so a
    /// field added to a pin cannot be forgotten. A changed step names the step.
    private static func fieldChanges<Item>(_ expected: Item, _ actual: Item) -> [String] {
        var lines: [String] = []
        for (was, now) in zip(Mirror(reflecting: expected).children, Mirror(reflecting: actual).children) {
            let field = was.label ?? "?"
            if let wasSteps = was.value as? [Step], let nowSteps = now.value as? [Step] {
                lines += stepChanges(wasSteps, nowSteps)
                continue
            }
            let (wasText, nowText) = (text(of: was.value), text(of: now.value))
            guard wasText != nowText else { continue }
            let (wasShown, nowShown) = windows(wasText, nowText)
            lines.append("field \(field) expected \(wasShown) actual \(nowShown)")
        }
        return lines
    }

    private static func stepChanges(_ expected: [Step], _ actual: [Step]) -> [String] {
        guard expected.count == actual.count else {
            return ["field steps expected \(expected.count) steps actual \(actual.count)"]
        }
        var lines: [String] = []
        for (index, pair) in zip(expected, actual).enumerated() where pair.0 != pair.1 {
            for change in fieldChanges(pair.0, pair.1) {
                lines.append("step \(index + 1) (\(pair.0.toolName)) \(change)")
            }
        }
        return lines
    }

    private static func text(of value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return "none" }
            return text(of: wrapped)
        }
        return (value as? String) ?? "\(value)"
    }

    /// The neighbourhood of the first difference, so a long command or option
    /// string reads as a short message.
    private static func windows(_ expected: String, _ actual: String) -> (String, String) {
        let was = Array(expected)
        let now = Array(actual)
        var first = 0
        while first < min(was.count, now.count), was[first] == now[first] { first += 1 }
        let start = max(0, first - 40)
        func clip(_ characters: [Character]) -> String {
            let from = min(start, characters.count)
            let to = min(characters.count, first + 80)
            let body = from < to ? String(characters[from ..< to]) : ""
            return (from > 0 ? "..." : "") + body + (to < characters.count ? "..." : "")
        }
        return (clip(was), clip(now))
    }

    // MARK: - Writing

    /// A layout a person can review: one line per file descriptor, one line per
    /// argv. The test decodes it with `JSONDecoder`, so only the content matters.
    func render() -> String {
        var lines = ["{"]
        lines.append("  \"formatVersion\": \(formatVersion),")
        lines.append("  \"readingNotes\": [")
        lines += Self.joined(readingNotes.map { "    " + Self.literal($0) })
        lines.append("  ],")
        lines.append(
            "  \"archive\": {\"id\": \(Self.literal(archive.id)), \"version\": \(Self.literal(archive.version)), "
                + "\"bytes\": \(archive.bytes), \"sha256\": \(Self.literal(archive.sha256))},"
        )
        lines.append("  \"sidecars\": [")
        lines += Self.joined(sidecars.map(Self.render(sidecar:)))
        lines.append("  ],")
        lines.append("  \"finder\": [")
        lines += Self.joined(finder.map { pin in
            var fields = [
                "\"selection\": \(Self.literal(pin.selection))",
                "\"isBundle\": \(pin.isBundle)",
            ]
            if let sidecar = pin.sidecar { fields.append("\"sidecar\": \(Self.literal(sidecar))") }
            return "    {" + fields.joined(separator: ", ") + "}"
        })
        lines.append("  ],")
        lines.append("  \"lineage\": [")
        lines += Self.joined(lineage.map { pin in
            let chain = pin.chain.map { link in
                var fields: [String] = []
                if let sidecar = link.sidecar { fields.append("\"sidecar\": \(Self.literal(sidecar))") }
                fields.append("\"workflowName\": \(Self.literal(link.workflowName))")
                return "{" + fields.joined(separator: ", ") + "}"
            }
            return "    {\"sidecar\": \(Self.literal(pin.sidecar)), \"chain\": [\n      "
                + chain.joined(separator: ",\n      ") + "\n    ]}"
        })
        lines.append("  ]")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(sidecar: Sidecar) -> String {
        var fields = [
            "\"sidecar\": \(literal(sidecar.sidecar))",
            "\"decodedBy\": \(literal(sidecar.decodedBy))",
            "\"strictAccepts\": \(sidecar.strictAccepts)",
            "\"workflowName\": \(literal(sidecar.workflowName))",
            "\"toolName\": \(literal(sidecar.toolName))",
            "\"toolVersion\": \(literal(sidecar.toolVersion))",
            "\"argv\": \(list(sidecar.argv))",
        ]
        if let durable = sidecar.durableReplayArgv { fields.append("\"durableReplayArgv\": \(list(durable))") }
        fields.append("\"reproducibleCommand\": \(literal(sidecar.reproducibleCommand))")
        if let exitStatus = sidecar.exitStatus { fields.append("\"exitStatus\": \(exitStatus)") }
        if let rawStatus = sidecar.rawStatus { fields.append("\"rawStatus\": \(literal(rawStatus))") }
        fields.append("\"decodedStatus\": \(literal(sidecar.decodedStatus))")
        if let run = sidecar.embeddedRun {
            fields.append("\"embeddedRun\": {\"status\": \(literal(run.status)), \"stepCount\": \(run.stepCount)}")
        }
        fields.append("\"explicitOptions\": \(literal(sidecar.explicitOptions))")
        fields.append("\"files\": " + descriptors(sidecar.files))
        fields.append("\"outputs\": " + descriptors(sidecar.outputs))
        fields.append("\"steps\": " + steps(sidecar.steps))
        return "    {\n      " + fields.joined(separator: ",\n      ") + "\n    }"
    }

    private static func steps(_ items: [Step]) -> String {
        guard !items.isEmpty else { return "[]" }
        let blocks = items.map { step -> String in
            var fields = [
                "\"toolName\": \(literal(step.toolName))",
                "\"toolVersion\": \(literal(step.toolVersion))",
            ]
            if let exitStatus = step.exitStatus { fields.append("\"exitStatus\": \(exitStatus)") }
            fields.append("\"argv\": \(list(step.argv))")
            if let durable = step.durableReplayArgv { fields.append("\"durableReplayArgv\": \(list(durable))") }
            fields.append("\"inputs\": " + descriptors(step.inputs, indent: 12))
            fields.append("\"outputs\": " + descriptors(step.outputs, indent: 12))
            return "        {\n          " + fields.joined(separator: ",\n          ") + "\n        }"
        }
        return "[\n" + blocks.joined(separator: ",\n") + "\n      ]"
    }

    /// One line per descriptor, `indent` spaces in, closing bracket two to the left.
    private static func descriptors(_ items: [Descriptor], indent: Int = 8) -> String {
        guard !items.isEmpty else { return "[]" }
        let pad = String(repeating: " ", count: indent)
        let rows = items.map { item -> String in
            var fields = ["\"path\": \(literal(item.path))", "\"role\": \(literal(item.role))"]
            if let sha256 = item.sha256 { fields.append("\"sha256\": \(literal(sha256))") }
            if let size = item.size { fields.append("\"size\": \(size)") }
            return pad + "{" + fields.joined(separator: ", ") + "}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n" + String(repeating: " ", count: indent - 2) + "]"
    }

    private static func joined(_ items: [String]) -> [String] {
        items.enumerated().map { index, item in item + (index < items.count - 1 ? "," : "") }
    }

    private static func list(_ values: [String]) -> String {
        "[" + values.map(literal).joined(separator: ", ") + "]"
    }

    /// A JSON string literal that keeps slashes readable.
    private static func literal(_ value: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

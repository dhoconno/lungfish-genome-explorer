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
    static let currentFormatVersion = 1

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
        var exitStatus: Int?
        var rawStatus: String?
        var embeddedRun: EmbeddedRun?
        var files: [Descriptor]
        var outputs: [Descriptor]
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
        "Captured once with LUNGFISH_CAPTURE_DEMO_PROVENANCE=1 on code that had not changed any writer (Phase 2.4 lane W1B). The test refuses to overwrite this file. Later lanes leave it unedited.",
        "Each sidecar entry is what the tolerant reader decodes from the released bytes. It holds no value the reading Mac fills in, such as runtime identity, appVersion, operating system or createdAt.",
        "A path that starts with @/ is inside the installed project. <tool-root> and <storage-root> are the managed roots. <tmp> is any system temporary folder, whether the bytes record it literally or as the <workspace> placeholder.",
        "decodedBy names the first reader step that accepts the bytes. strictAccepts is the result of loadCanonical. rawStatus is the top-level status string of the file. embeddedRun is the legacyWorkflowRun block, when the file has one.",
        "finder lists the sidecar that findProvenanceEnvelope returns for each bundle folder and each payload file, with no sidecar when it finds none. lineage lists the records ProvenanceLineageResolver walks for each sidecar, upstream first.",
    ]

    // MARK: - Reading and comparing

    static func load(from url: URL) throws -> DemoProvenanceExpectedFile {
        try JSONDecoder().decode(DemoProvenanceExpectedFile.self, from: Data(contentsOf: url))
    }

    /// Everything the comparison covers. The reading notes are prose and are left out.
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
                let wasFields = Mirror(reflecting: was).children.map { "\($0.value)" }
                let nowFields = Mirror(reflecting: now).children.map { "\($0.value)" }
                let names = Mirror(reflecting: was).children.map { $0.label ?? "?" }
                for index in names.indices where wasFields[index] != nowFields[index] {
                    lines.append("\(label) \(name) field \(names[index]) expected \(wasFields[index]) actual \(nowFields[index])")
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
        if let exitStatus = sidecar.exitStatus { fields.append("\"exitStatus\": \(exitStatus)") }
        if let rawStatus = sidecar.rawStatus { fields.append("\"rawStatus\": \(literal(rawStatus))") }
        if let run = sidecar.embeddedRun {
            fields.append("\"embeddedRun\": {\"status\": \(literal(run.status)), \"stepCount\": \(run.stepCount)}")
        }
        fields.append("\"files\": " + descriptors(sidecar.files))
        fields.append("\"outputs\": " + descriptors(sidecar.outputs))
        return "    {\n      " + fields.joined(separator: ",\n      ") + "\n    }"
    }

    private static func descriptors(_ items: [Descriptor]) -> String {
        guard !items.isEmpty else { return "[]" }
        let rows = items.map { item -> String in
            var fields = ["\"path\": \(literal(item.path))", "\"role\": \(literal(item.role))"]
            if let sha256 = item.sha256 { fields.append("\"sha256\": \(literal(sha256))") }
            if let size = item.size { fields.append("\"size\": \(size)") }
            return "        {" + fields.joined(separator: ", ") + "}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n      ]"
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

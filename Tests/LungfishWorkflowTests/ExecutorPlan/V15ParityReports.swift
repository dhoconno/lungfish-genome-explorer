// V15ParityReports.swift - C4-4 D-4: the recipe steps' reports parsed and compared, not their bytes (CHTC C4 lane W)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishPortable

/// The findings and the PARITY-REPORTED lines of one report comparison.
struct V15ReportComparison {
    var findings: [V15Finding] = []
    var reported: [String] = []
}

/// C4-4 D-4 (SWIFT SW4-8 and SW4-9, BIO B-D4-1 to B-D4-3, QA Q4-7 to Q4-10, CHTC CH-6, UX U4-6). A report states its own run's
/// command line and times, so its bytes differ between two Mac runs; its counts and rates do not, and are compared exactly.
enum V15Reports {
    /// What a removed key holds, so the log says why the key is set aside (QA Q4-7).
    enum KeyClass: String {
        case commandLine = "command line"
        case path
        case time
        case rate = "rate computed from a time"
    }

    /// fastp's JSON: the one key that states the run's own command line. Every other key compares, the version included.
    static let fastpRemoved: [String: KeyClass] = ["command": .commandLine]

    /// deacon's summary: the five keys that hold a path, its elapsed time and the four rates computed from that time. Every
    /// other key compares, the version included (CHTC CH-6, from the summary of `SCR/x/x0/h1.lungfish`).
    static let deaconRemoved: [String: KeyClass] = [
        "index": .path, "input": .path, "input2": .path, "output": .path, "output2": .path,
        "time": .time, "seqs_per_second": .rate, "bp_per_second": .rate, "seqs_per_second_total": .rate, "bp_per_second_total": .rate,
    ]

    private enum Kind: String {
        case fastp
        case deacon
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func kind(of object: [String: Any]) -> Kind? {
        if object["summary"] is [String: Any], object["command"] is String { return .fastp }
        if object["seqs_in"] != nil, object["version"] is String { return .deacon }
        return nil
    }

    /// Both copies parsed, the named keys of the report's kind set aside and printed with both values, and every other leaf
    /// compared exactly with no tolerance. A key on one route only, a copy that does not parse and a copy of neither kind fail.
    static func compare(adopted: Data, mac: Data, label: String) -> V15ReportComparison {
        var result = V15ReportComparison()
        let parsedAdopted = parse(adopted), parsedMac = parse(mac)
        guard var a = parsedAdopted, var m = parsedMac else {
            result.findings.append(V15Finding(
                key: label, adopted: parsedAdopted == nil ? "does not parse" : "parses", mac: parsedMac == nil ? "does not parse" : "parses",
                why: "D-4: each route's report copy must parse as a JSON object (BIO B-D4-2)"))
            return result
        }
        guard let kind = kind(of: a), kind == Self.kind(of: m) else {
            result.findings.append(V15Finding(
                key: label, adopted: Self.kind(of: a)?.rawValue ?? "neither", mac: Self.kind(of: m)?.rawValue ?? "neither",
                why: "D-4: the report copies are neither a fastp JSON nor a deacon summary of one kind on both routes"))
            return result
        }
        let removed = kind == .fastp ? fastpRemoved : deaconRemoved
        for (key, keyClass) in removed.sorted(by: { $0.key < $1.key }) {
            result.reported.append("PARITY-REPORTED line=V15-28 report=\(label) key=\(key) class=\(keyClass.rawValue) "
                                   + "adopted=\(V15Comparison.render(a[key])) mac=\(V15Comparison.render(m[key]))")
            a.removeValue(forKey: key)
            m.removeValue(forKey: key)
        }
        compareTrees(a, m, path: label, into: &result.findings)
        return result
    }

    private static func compareTrees(_ adopted: Any?, _ mac: Any?, path: String, into findings: inout [V15Finding]) {
        switch (adopted, mac) {
        case (nil, nil):
            return
        case (nil, _), (_, nil):
            findings.append(V15Finding(key: path, adopted: V15Comparison.render(adopted), mac: V15Comparison.render(mac),
                                       why: "D-4: the key is on one route's report only, and the removed list does not name it"))
        case let (a as [String: Any], m as [String: Any]):
            for key in Set(a.keys).union(m.keys).sorted() {
                compareTrees(a[key], m[key], path: path + "." + key, into: &findings)
            }
        case let (a as [Any], m as [Any]):
            if a.count != m.count {
                findings.append(V15Finding(key: path, adopted: "\(a.count) items", mac: "\(m.count) items",
                                           why: "D-4: the arrays differ in length"))
            }
            for index in 0..<min(a.count, m.count) {
                compareTrees(a[index], m[index], path: path + "[\(index)]", into: &findings)
            }
        default:
            if !V15Comparison.equal(adopted, mac) {
                findings.append(V15Finding(key: path, adopted: V15Comparison.render(adopted), mac: V15Comparison.render(mac),
                                           why: "D-4: the value differs, compared exactly with no tolerance, and the removed list does not name the key"))
            }
        }
    }

    /// QA Q4-8: the copy's hash and size equal the record's `checksumSHA256` and `fileSize` (integrity inside one route), so a
    /// report swapped after it was recorded fails here before its bytes are parsed.
    static func integrity(of data: Data, record: [String: Any], label: String, route: V15Route) -> [V15Finding] {
        var found: [V15Finding] = []
        let digest = PortableDigest.sha256Hex(of: data)
        let recordedDigest = record["checksumSHA256"] as? String
        if recordedDigest != digest {
            found.append(V15Finding(
                key: label + ".checksumSHA256", adopted: route == .adopted ? digest : "-", mac: route == .mac ? digest : "-",
                why: "D-4: the \(route.rawValue) route's report copy hashes to \(digest) and its record says \(recordedDigest ?? "nothing") (QA Q4-8)"))
        }
        let recordedSize = (record["fileSize"] as? NSNumber)?.intValue
        if recordedSize != data.count {
            found.append(V15Finding(
                key: label + ".fileSize", adopted: route == .adopted ? "\(data.count)" : "-", mac: route == .mac ? "\(data.count)" : "-",
                why: "D-4: the \(route.rawValue) route's report copy holds \(data.count) bytes and its record says \(recordedSize.map(String.init) ?? "nothing") (QA Q4-8)"))
        }
        return found
    }
}

extension V15Comparison {
    /// A report copy: a recipe step's output under the bundle's `metadata/recipe-step-artifacts/`.
    static func isReportPath(_ path: String) -> Bool { path.contains("/metadata/recipe-step-artifacts/") }

    func isReportFile(_ object: [String: Any]) -> Bool {
        guard object["checksumSHA256"] != nil || object["fileSize"] != nil, let path = object["path"] as? String else { return false }
        return Self.isReportPath(path)
    }

    /// C4-4 D-4: the report copies of each paired step, read from the two bundles and paired by step and position among the
    /// step's report outputs, never by name (the copy names are D-3's, row W1-1). Each copy is checked against its record, then
    /// the two are parsed and compared.
    mutating func compareReportCopies(
        pairs: [(label: String, adopted: [String: Any]?, mac: [String: Any]?)], adoptedBundle: URL, macBundle: URL
    ) {
        func reports(_ step: [String: Any]) -> [[String: Any]] {
            (step["outputs"] as? [[String: Any]] ?? []).filter { Self.isReportPath($0["path"] as? String ?? "") }
        }
        func read(_ record: [String: Any], in bundle: URL) -> Data? {
            guard let path = record["path"] as? String else { return nil }
            let name = (path as NSString).lastPathComponent
            return try? Data(contentsOf: bundle.appendingPathComponent("metadata/recipe-step-artifacts").appendingPathComponent(name))
        }
        for pair in pairs {
            guard let adoptedStep = pair.adopted, let macStep = pair.mac else { continue }
            let adoptedReports = reports(adoptedStep), macReports = reports(macStep)
            let key = "envelope.steps[\(pair.label)].outputs"
            if adoptedReports.count != macReports.count {
                findings.append(V15Finding(key: key, adopted: "\(adoptedReports.count) reports", mac: "\(macReports.count) reports",
                                           why: "D-4: the paired steps hold different numbers of report copies"))
            }
            for (index, reportPair) in zip(adoptedReports, macReports).enumerated() {
                let label = "\(key).report[\(index)]"
                guard let adoptedData = read(reportPair.0, in: adoptedBundle), let macData = read(reportPair.1, in: macBundle) else {
                    findings.append(V15Finding(
                        key: label, adopted: Self.render(reportPair.0["path"]), mac: Self.render(reportPair.1["path"]),
                        why: "D-4: a report copy is not in its bundle's metadata/recipe-step-artifacts/"))
                    continue
                }
                findings += V15Reports.integrity(of: adoptedData, record: reportPair.0, label: label, route: .adopted)
                findings += V15Reports.integrity(of: macData, record: reportPair.1, label: label, route: .mac)
                let result = V15Reports.compare(adopted: adoptedData, mac: macData, label: label)
                findings += result.findings
                reported += result.reported
            }
        }
    }
}

// V15ParityComparison.swift - The one comparison of an adopted bundle with a Mac import under the V15 list (CHTC C4 lane P)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
@testable import LungfishPortable

/// One line the comparison failed on, with both values and why.
struct V15Finding: Sendable, CustomStringConvertible {
    let key: String
    let adopted: String
    let mac: String
    let why: String

    var description: String { "PARITY-FINDING key=\(key) adopted=\(adopted) mac=\(mac) why=\(why)" }
}

/// SWIFT's S-4: each record's JSON tree walked key by key against the closed list.
struct V15Comparison {
    /// The roots `stripRoot` removes from a path token, for each route (XC-10).
    var roots: [V15Route: [String]]
    /// The last path components of the payload and of the files that hold its values (XC-1).
    var payloadFileNames: Set<String>
    var findings: [V15Finding] = []
    var reported: [String] = []

    init(roots: [V15Route: [String]], payloadFileNames: Set<String>) {
        self.roots = roots
        self.payloadFileNames = payloadFileNames
    }

    // MARK: The one function of XC-10

    /// Strips a route's root from a path token, whether the path is the whole token or follows a key such as `in=`, to
    /// leave the plan's relative path. Nothing else rewrites a token.
    static func stripRoot(_ token: String, roots: [String]) -> String {
        for root in roots.sorted(by: { $0.count > $1.count }) where !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if token.hasPrefix(prefix) { return String(token.dropFirst(prefix.count)) }
            if let equals = token.firstIndex(of: "="), token[token.index(after: equals)...].hasPrefix(prefix) {
                let key = token[...equals]
                return String(key) + String(token[token.index(after: equals)...].dropFirst(prefix.count))
            }
        }
        return token
    }

    // MARK: Records

    /// The envelopes, with the steps paired by role, plan order and tool id (QA ruling 2).
    mutating func compareEnvelopes(adopted: [String: Any], mac: [String: Any], adoptedRoles: V15StepRoles, macRoles: V15StepRoles) {
        var adoptedTop = adopted
        var macTop = mac
        adoptedTop.removeValue(forKey: "steps")
        macTop.removeValue(forKey: "steps")
        walk(adoptedTop, macTop, path: ["envelope"])
        let pairs = V15StepRoles.pair(adoptedRoles, macRoles)
        for pair in pairs {
            switch (pair.adopted, pair.mac) {
            case let (adoptedStep?, macStep?):
                compareStep(adoptedStep, macStep, label: pair.label, adoptedRoles: adoptedRoles, macRoles: macRoles)
            case let (adoptedStep?, nil):
                findings.append(V15Finding(key: "envelope.steps[\(pair.label)]", adopted: Self.render(adoptedStep["toolName"]),
                                           mac: "absent", why: "a step only the adopt route holds, and the list does not name it"))
            case let (nil, macStep?):
                findings.append(V15Finding(key: "envelope.steps[\(pair.label)]", adopted: "absent",
                                           mac: Self.render(macStep["toolName"]), why: "a step only the Mac route holds, and the list does not name it"))
            case (nil, nil):
                break
            }
        }
    }

    mutating func compareSidecars(adopted: [String: Any], mac: [String: Any]) {
        walk(adopted, mac, path: ["sidecar"])
    }

    private mutating func compareStep(
        _ adopted: [String: Any], _ mac: [String: Any], label: String, adoptedRoles: V15StepRoles, macRoles: V15StepRoles
    ) {
        let path = ["envelope", "steps[\(label)]"]
        for key in Set(adopted.keys).union(mac.keys).sorted() {
            let keyPath = path + [key]
            switch key {
            case "id":
                continue
            case "parentStepID":
                let a = (adopted[key] as? String).map { adoptedRoles.role(ofID: $0) }
                let m = (mac[key] as? String).map { macRoles.role(ofID: $0) }
                if a != m {
                    findings.append(V15Finding(key: Self.joined(keyPath), adopted: a ?? "absent", mac: m ?? "absent",
                                               why: "the parent link names a different role (QA ruling 2)"))
                }
            case "dependsOn":
                let a = Set(((adopted[key] as? [String]) ?? []).map { adoptedRoles.role(ofID: $0) })
                let m = Set(((mac[key] as? [String]) ?? []).map { macRoles.role(ofID: $0) })
                if a != m {
                    findings.append(V15Finding(key: Self.joined(keyPath), adopted: a.sorted().description, mac: m.sorted().description,
                                               why: "dependsOn names different roles (QA ruling 2)"))
                }
            default:
                walk(adopted[key], mac[key], path: keyPath)
            }
        }
        // XC-4: a Mac step that records no version fails and never passes as an unlisted key.
        let version = mac["toolVersion"] as? String
        if version == nil || version == "unknown" || version?.isEmpty == true {
            findings.append(V15Finding(key: Self.joined(path + ["toolVersion"]), adopted: Self.render(adopted["toolVersion"]),
                                       mac: Self.render(mac["toolVersion"]), why: "the Mac step records no version (XC-4)"))
        }
    }

    // MARK: The walk

    mutating func walk(_ adopted: Any?, _ mac: Any?, path: [String], tag: String? = nil) {
        if let line = Self.line(for: path, tag: tag) {
            apply(line, adopted, mac, path: path)
            return
        }
        switch (adopted, mac) {
        case (nil, nil):
            return
        case (nil, _), (_, nil):
            findings.append(V15Finding(key: Self.joined(path), adopted: Self.render(adopted), mac: Self.render(mac),
                                       why: "the key is on one route only, and the list does not name it"))
        case let (a as [String: Any], m as [String: Any]):
            let fileTag = isPayloadFile(a) || isPayloadFile(m) ? "payload-file" : nil
            for key in Set(a.keys).union(m.keys).sorted() {
                walk(a[key], m[key], path: path + [key], tag: fileTag)
            }
        case let (a as [Any], m as [Any]):
            if a.count != m.count {
                findings.append(V15Finding(key: Self.joined(path), adopted: "\(a.count) items", mac: "\(m.count) items",
                                           why: "the arrays differ in length, and the list does not name the key"))
            }
            for index in 0..<min(a.count, m.count) {
                walk(a[index], m[index], path: path + ["[\(index)]"])
            }
        default:
            if !Self.equal(adopted, mac) {
                findings.append(V15Finding(key: Self.joined(path), adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "the values differ, and the list does not name the key"))
            }
        }
    }

    private mutating func apply(_ line: V15Line, _ adopted: Any?, _ mac: Any?, path: [String]) {
        let key = Self.joined(path)
        switch line.rule {
        case .notCompared(let mustCarry):
            for route in mustCarry where (route == .adopted ? adopted : mac) == nil {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "\(line.id) must be present on the \(route.rawValue) route"))
            }
        case .reported:
            reported.append("PARITY-REPORTED line=\(line.id) key=\(key) adopted=\(Self.render(adopted)) mac=\(Self.render(mac))")
        case .routeValues(let expectedAdopted, let expectedMac):
            for (route, value, expected) in [(V15Route.adopted, adopted, expectedAdopted), (.mac, mac, expectedMac)] {
                let held = value as? String
                let isNull = value is NSNull
                if expected == nil ? !isNull : held != expected {
                    findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                               why: "\(line.id) allows \(expected ?? "null") on the \(route.rawValue) route"))
                }
            }
        case .nullOnAdoptedNumberOnMac:
            if !(adopted is NSNull) || !(mac is NSNumber) {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "\(line.id) allows null on the adopted route and the host's number on the Mac"))
            }
        case .argv:
            compareArgv(adopted, mac, key: key)
        case .byRole:
            // Steps compare their ids in `compareStep`; an id outside a step is unlisted.
            if !Self.equal(adopted, mac) {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "an id outside a paired step, which the list does not name"))
            }
        }
    }

    private mutating func compareArgv(_ adopted: Any?, _ mac: Any?, key: String) {
        func tokens(_ value: Any?) -> [String]? {
            if let list = value as? [String] { return list }
            if let text = value as? String { return text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
            return nil
        }
        guard let a = tokens(adopted), let m = tokens(mac) else {
            if !(adopted == nil && mac == nil) {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "the argv is on one route only"))
            }
            return
        }
        let strippedA = a.map { Self.stripRoot($0, roots: roots[.adopted] ?? []) }
        let strippedM = m.map { Self.stripRoot($0, roots: roots[.mac] ?? []) }
        var differs = strippedA.count != strippedM.count
        for index in 0..<min(strippedA.count, strippedM.count) where !differs {
            if index == 0 {
                differs = (strippedA[0] as NSString).lastPathComponent != (strippedM[0] as NSString).lastPathComponent
            } else {
                differs = strippedA[index] != strippedM[index]
            }
        }
        if differs {
            findings.append(V15Finding(key: key, adopted: strippedA.description, mac: strippedM.description,
                                       why: "the argv differs token by token after the root is stripped (XC-10)"))
        }
    }

    private func isPayloadFile(_ object: [String: Any]) -> Bool {
        guard object["checksumSHA256"] != nil || object["fileSize"] != nil, let path = object["path"] as? String else { return false }
        return payloadFileNames.contains((path as NSString).lastPathComponent)
    }

    // MARK: Matching and values

    static func line(for path: [String], tag: String?) -> V15Line? {
        V15ParityList.lines.first { line in
            line.patterns.contains { pattern in
                let parts = pattern.split(separator: ".").map(String.init)
                if parts.first == "payload-file" { return tag == "payload-file" && parts.last == path.last }
                return matches(parts[...], path[...])
            }
        }
    }

    private static func matches(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            for start in path.indices.dropFirst() where matches(pattern.dropFirst(), path[start...]) { return true }
            return false
        }
        guard let first = path.first else { return false }
        let component: Bool
        if head == "*" {
            component = true
        } else if head.hasSuffix("[]"), let bracket = first.firstIndex(of: "[") {
            component = String(first[..<bracket]) == String(head.dropLast(2))
        } else {
            component = head == first
        }
        return component && matches(pattern.dropFirst(), path.dropFirst())
    }

    static func joined(_ path: [String]) -> String {
        path.reduce("") { $0.isEmpty ? $1 : ($1.hasPrefix("[") ? $0 + $1 : $0 + "." + $1) }
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
        }
    }

    static func render(_ value: Any?) -> String {
        guard let value else { return "absent" }
        if value is NSNull { return "null" }
        if let text = value as? String { return "\"\(text.prefix(240))\"" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(String(decoding: data, as: UTF8.self).prefix(240))
        }
        return "\(value)"
    }

    static func jsonObject(_ url: URL) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt, userInfo: [NSFilePathErrorKey: url.path])
        }
        return object
    }
}

/// Each envelope step's role on its route (QA ruling 2): the runner, the adopt step, the counter step, the statistics
/// step, or its tool id with its plan-order position among the steps of that tool.
struct V15StepRoles {
    let route: V15Route
    let steps: [[String: Any]]
    private(set) var roles: [String: String] = [:]
    private(set) var problems: [String] = []

    /// The Mac route's runner is the one step every other step names as its parent, whose tool is the import.
    static func mac(_ steps: [[String: Any]], importToolName: String) -> V15StepRoles {
        var result = V15StepRoles(route: .mac, steps: steps)
        let ids = steps.compactMap { $0["id"] as? String }
        let runners = steps.filter { step in
            guard let id = step["id"] as? String, step["toolName"] as? String == importToolName else { return false }
            return steps.allSatisfy { ($0["id"] as? String) == id || ($0["parentStepID"] as? String) == id }
        }
        if runners.count != 1 { result.problems.append("the Mac route holds \(runners.count) runner steps, and must hold one") }
        if let runner = runners.first?["id"] as? String { result.roles[runner] = V15Roles.runner }
        for (index, step) in steps.enumerated() where result.roles[ids[safe: index] ?? ""] == nil {
            let argv = step["argv"] as? [String] ?? []
            if step["toolName"] as? String == "seqkit", argv.count > 1, argv[1] == "stats", let id = step["id"] as? String {
                result.roles[id] = V15Roles.statistics
            }
        }
        result.numberTheRest()
        return result
    }

    /// The adopt route's runner is the executor's step, its adopt step the last, and the node steps hold the record's
    /// steps in order, so the counter and statistics steps are found by the record's kinds.
    static func adopted(
        _ steps: [[String: Any]], executorToolName: String, adoptToolName: String, nodeKinds: [String]
    ) -> V15StepRoles {
        var result = V15StepRoles(route: .adopted, steps: steps)
        let runners = steps.filter { $0["toolName"] as? String == executorToolName }
        if runners.count != 1 { result.problems.append("the adopt route holds \(runners.count) runner steps, and must hold one") }
        if let runner = runners.first?["id"] as? String { result.roles[runner] = V15Roles.runner }
        if let last = steps.last, last["toolName"] as? String == adoptToolName, let id = last["id"] as? String {
            result.roles[id] = V15Roles.adoptStep
        } else {
            result.problems.append("the adopt route's last step is not \(adoptToolName)")
        }
        for (index, kind) in nodeKinds.enumerated() where index < steps.count {
            guard let id = steps[index]["id"] as? String else { continue }
            if kind == "qualityCount" { result.roles[id] = V15Roles.counter }
            if kind == "statistics" { result.roles[id] = V15Roles.statistics }
        }
        result.numberTheRest()
        return result
    }

    private init(route: V15Route, steps: [[String: Any]]) {
        self.route = route
        self.steps = steps
    }

    private mutating func numberTheRest() {
        var seen: [String: Int] = [:]
        for step in steps {
            guard let id = step["id"] as? String, roles[id] == nil else { continue }
            let tool = step["toolName"] as? String ?? "unnamed"
            seen[tool, default: 0] += 1
            roles[id] = "\(tool)#\(seen[tool]!)"
        }
    }

    func role(ofID id: String) -> String { roles[id] ?? "unknown step \(id)" }

    /// The steps of both routes paired by role, the route-only steps of the list left out.
    static func pair(_ adopted: V15StepRoles, _ mac: V15StepRoles) -> [(label: String, adopted: [String: Any]?, mac: [String: Any]?)] {
        func listed(_ role: String, _ route: V15Route) -> Bool {
            V15ParityList.routeOnlySteps.contains { $0.route == route && $0.role == role }
        }
        var order: [String] = []
        var byRole: [String: (adopted: [String: Any]?, mac: [String: Any]?)] = [:]
        for (roles, route) in [(mac, V15Route.mac), (adopted, .adopted)] {
            for step in roles.steps {
                guard let id = step["id"] as? String else { continue }
                let role = roles.role(ofID: id)
                if listed(role, route) { continue }
                if byRole[role] == nil { order.append(role) }
                var entry = byRole[role] ?? (nil, nil)
                if route == .mac { entry.mac = step } else { entry.adopted = step }
                byRole[role] = entry
            }
        }
        return order.map { (label: $0, adopted: byRole[$0]?.adopted, mac: byRole[$0]?.mac) }
    }
}

/// QA ruling 3, condition 1: the test's own parse of `seqkit stats -a -T`, mapped by column name to the Mac keys as
/// `FASTQBatchImporter.computeAndCacheStatistics` maps them, with Q20 and Q30 from the counted bases as the Mac takes
/// them. Values compare exactly, with no tolerance.
enum V15Statistics {
    /// Columns the Mac keeps, each with the sidecar keys that hold its value.
    static let columns: [(column: String, keys: [String])] = [
        ("num_seqs", ["computedStatistics.readCount", "seqkitStats.numSeqs"]),
        ("sum_len", ["computedStatistics.baseCount", "seqkitStats.sumLen"]),
        ("min_len", ["computedStatistics.minReadLength", "seqkitStats.minLen"]),
        ("avg_len", ["computedStatistics.meanReadLength", "seqkitStats.avgLen"]),
        ("max_len", ["computedStatistics.maxReadLength", "seqkitStats.maxLen"]),
        ("Q2", ["computedStatistics.medianReadLength"]),
        ("N50", ["computedStatistics.n50ReadLength"]),
        ("AvgQual", ["computedStatistics.meanQuality", "seqkitStats.averageQuality"]),
        ("GC(%)", ["computedStatistics.gcContent", "seqkitStats.gcPercentage"]),
    ]

    /// Every value the node's statistics step printed and counted, against the Mac sidecar's typed values.
    static func compare(standardOutput: String, counts: FASTQQualityFractions, macSidecar: PersistedFASTQMetadata) -> [V15Finding] {
        let lines = standardOutput.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            return [V15Finding(key: "statistics.standardOutput", adopted: "\(lines.count) lines", mac: "-", why: "no seqkit table")]
        }
        let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let row = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let table = Dictionary(zip(header, row).map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
        guard let stats = macSidecar.computedStatistics, let seqkit = macSidecar.seqkitStats else {
            return [V15Finding(key: "computedStatistics", adopted: "-", mac: "absent", why: "the Mac sidecar holds no statistics")]
        }
        let mac: [String: Double] = [
            "computedStatistics.readCount": Double(stats.readCount), "seqkitStats.numSeqs": Double(seqkit.numSeqs),
            "computedStatistics.baseCount": Double(stats.baseCount), "seqkitStats.sumLen": Double(seqkit.sumLen),
            "computedStatistics.minReadLength": Double(stats.minReadLength), "seqkitStats.minLen": Double(seqkit.minLen),
            "computedStatistics.meanReadLength": stats.meanReadLength, "seqkitStats.avgLen": seqkit.avgLen,
            "computedStatistics.maxReadLength": Double(stats.maxReadLength), "seqkitStats.maxLen": Double(seqkit.maxLen),
            "computedStatistics.medianReadLength": Double(stats.medianReadLength),
            "computedStatistics.n50ReadLength": Double(stats.n50ReadLength),
            "computedStatistics.meanQuality": stats.meanQuality, "seqkitStats.averageQuality": seqkit.averageQuality,
            "computedStatistics.gcContent": stats.gcContent, "seqkitStats.gcPercentage": seqkit.gcPercentage,
            "computedStatistics.q20Percentage": stats.q20Percentage, "seqkitStats.q20Percentage": seqkit.q20Percentage,
            "computedStatistics.q30Percentage": stats.q30Percentage, "seqkitStats.q30Percentage": seqkit.q30Percentage,
        ]
        var findings: [V15Finding] = []
        func check(_ key: String, node: Double?, text: String) {
            guard let node else {
                findings.append(V15Finding(key: key, adopted: text, mac: "\(mac[key] ?? .nan)", why: "the node's value does not parse"))
                return
            }
            if node != mac[key] {
                findings.append(V15Finding(key: key, adopted: "\(node)", mac: "\(mac[key] ?? .nan)",
                                           why: "the node's seqkit stats value differs from the Mac sidecar (QA ruling 3)"))
            }
        }
        for (column, keys) in columns {
            let text = table[column] ?? "absent"
            let value = Double(text)
            for key in keys {
                check(key, node: key == "computedStatistics.gcContent" ? value.map { $0 / 100.0 } : value, text: text)
            }
        }
        // The Mac replaces seqkit's whole-percent Q20 and Q30 with the counted bases when the count covers seqkit's bases.
        let sumLen = Int64(table["sum_len"] ?? "")
        let q20: Double?
        let q30: Double?
        if let sumLen, counts.baseCount == sumLen, counts.baseCount > 0 {
            q20 = counts.q20Percentage
            q30 = counts.q30Percentage
        } else {
            q20 = Double(table["Q20(%)"] ?? "")
            q30 = Double(table["Q30(%)"] ?? "")
        }
        for key in ["computedStatistics.q20Percentage", "seqkitStats.q20Percentage"] { check(key, node: q20, text: "\(counts.q20Count)") }
        for key in ["computedStatistics.q30Percentage", "seqkitStats.q30Percentage"] { check(key, node: q30, text: "\(counts.q30Count)") }
        return findings
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

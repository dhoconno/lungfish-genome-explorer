// V15ParityStoredOrder.swift - V15-29 (the adopt's not-inferred platform) and V15-30 (lines that follow clumpify's stored order), BIOQA-X1
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The two objects that hold the key being walked, one for each route, as `walk` passes them down: the step entry that holds a
/// checksum, the statistics object that holds a distribution.
typealias V15Siblings = (adopted: [String: Any], mac: [String: Any])

/// BIOQA-X1 R2, V15-30's four conditions. Above 1 clumpify group the stored order follows which of KmerSort3's two fetch threads
/// finishes first, so two imports of one sample can store the same reads in another order. The lines that follow the stored order
/// print as PARITY-REPORTED while all four conditions hold, and compare as unlisted keys otherwise.
/// - S1. The hook found E2 and E3 equal and E4 different (`e4Differs`), and sets it before `compareEnvelopes`.
/// - S2. Both records show the same `clumpifyGroups` launch by launch (V15-21), one above 1 (`groups`).
/// - S3. A checksum is of an output of a launch above 1 group or an input of `bgzip#1`, with an equal `fileSize` (`entries`).
/// - S4. The three distributions come from `seqkit head -n 100000` (`FASTQBatchImporter.swift:2404-2441`), and the
///   `readLengthHistogram` sums are equal. Whole-file values stay compared.
struct V15StoredOrder {
    /// The most reads a sidecar distribution is drawn from.
    static let sampleLimit = 100_000
    /// The label of the BBTools writer step, whose input follows the stored order.
    static let writerLabel = "bgzip#1"
    static let distributions: Set<String> = ["readLengthHistogram", "qualityScoreHistogram", "perPositionQuality"]

    /// S1.
    var e4Differs = false
    /// S2: the group count of each clumpify launch by the label of its step, when both routes show the same count for every launch and
    /// one is above 1. Empty otherwise.
    var groups: [String: Int] = [:]
    /// S3: the role and stripped path of each output of a launch above 1 group and of each input of the writer, for each route.
    var entries: [V15Route: Set<String>] = [:]

    /// S1 and S2 hold.
    var holds: Bool { e4Differs && !groups.isEmpty }

    static func entryKey(role: String, path: String) -> String { role + "\u{1F}" + path }

    /// Whether V15-30 passes the key at `path`: a checksum of a step's entry (S3) or one of the sidecar's three distributions (S4).
    func excuses(path: [String], adopted: Any?, mac: Any?, siblings: V15Siblings?) -> Bool {
        guard holds, let siblings, adopted != nil, mac != nil else { return false }
        if path.count == 5, path[0] == "envelope", path[1].hasPrefix("steps["), path[1].hasSuffix("]"), path[4] == "checksumSHA256" {
            let label = String(path[1].dropFirst("steps[".count).dropLast())
            let listed = path[2] == "outputs" ? (groups[label] ?? 0) > 1 : (path[2] == "inputs" && label == Self.writerLabel)
            guard listed, let size = siblings.adopted["fileSize"] else { return false }
            return V15Comparison.equal(size, siblings.mac["fileSize"])
        }
        if path.count == 3, path[0] == "sidecar", path[1] == "computedStatistics", Self.distributions.contains(path[2]) {
            guard let sampled = Self.sampledReads(siblings.adopted) else { return false }
            return sampled == Self.sampledReads(siblings.mac)
        }
        return false
    }

    /// S4: the reads a sidecar's distributions are drawn from, the sum of its `readLengthHistogram`, or nil when the sum is 0 or above
    /// the first 100,000 stored reads.
    static func sampledReads(_ statistics: [String: Any]) -> Int? {
        guard let histogram = statistics["readLengthHistogram"] as? [String: Any] else { return nil }
        let counts = histogram.values.compactMap { ($0 as? NSNumber)?.intValue }
        guard counts.count == histogram.count else { return nil }
        let total = counts.reduce(0, +)
        return (1...sampleLimit).contains(total) ? total : nil
    }
}

extension V15Comparison {
    // MARK: V15-29, BIOQA-X1 R1

    /// QV-25 for a value of any depth: every `{"type", "value"}` object opened, the nested ones too. `untyped` opens only the top.
    static func untypedDeep(_ value: Any?) -> Any? {
        switch untyped(value) {
        case let list as [Any]: return list.map { untypedDeep($0) ?? NSNull() }
        case let object as [String: Any]: return object.mapValues { untypedDeep($0) ?? NSNull() }
        case let other: return other
        }
    }

    /// V15-29. Equal values pass. Otherwise the adopted route must hold exactly the JSON value `expected` gives for the key's last
    /// name and the Mac route a value, and both print as PARITY-REPORTED. Anything else is a finding.
    mutating func applyAdoptedValue(
        _ line: V15Line, _ expected: [String: String], _ typedAdopted: Any?, _ typedMac: Any?, path: [String]
    ) {
        let key = Self.joined(path)
        let adopted = Self.untypedDeep(typedAdopted), mac = Self.untypedDeep(typedMac)
        if Self.equal(adopted, mac) { return }
        if let name = path.last, let text = expected[name], Self.render(adopted, whole: true) == text, mac != nil, !(mac is NSNull) {
            reported.append("PARITY-REPORTED line=\(line.id) key=\(key) adopted=\(Self.render(adopted)) mac=\(Self.render(mac))")
        } else {
            findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                       why: "\(line.id) allows an equal value, or the adopt's not-inferred value against a value on the Mac (BIOQA-X1 R1)"))
        }
    }

    // MARK: V15-30, BIOQA-X1 R2

    /// V15-30. Printed and never failing while S1 to S4 hold; otherwise the key compares as an unlisted one.
    mutating func applyStoredOrder(
        _ line: V15Line, _ typedAdopted: Any?, _ typedMac: Any?, path: [String], siblings: V15Siblings?
    ) {
        if storedOrder.excuses(path: path, adopted: typedAdopted, mac: typedMac, siblings: siblings) {
            reported.append("PARITY-REPORTED line=\(line.id) key=\(Self.joined(path)) adopted=\(Self.render(typedAdopted)) mac=\(Self.render(typedMac))")
        } else {
            walkValues(typedAdopted, typedMac, path: path)
        }
    }

    /// S2 and S3, read from the paired steps of the two envelopes before the walk. S1 is set by the hook before `compareEnvelopes`.
    mutating func readStoredOrder(adoptedRoles: V15StepRoles, macRoles: V15StepRoles) {
        var read = V15StoredOrder(e4Differs: storedOrder.e4Differs)
        defer { storedOrder = read }
        guard read.e4Differs else { return }
        let pairs = V15StepRoles.pair(adoptedRoles, macRoles)
        func groupCount(_ step: [String: Any]?) -> Int? {
            (Self.untyped((step?["resolvedOptions"] as? [String: Any])?["clumpifyGroups"]) as? NSNumber)?.intValue
        }
        var counts: [String: (adopted: Int?, mac: Int?)] = [:]
        for pair in pairs where pair.label.hasPrefix("clumpify.sh#") {
            counts[pair.label] = (groupCount(pair.adopted), groupCount(pair.mac))
        }
        guard !counts.isEmpty, counts.values.allSatisfy({ $0.adopted != nil && $0.adopted == $0.mac }),
              counts.values.contains(where: { ($0.adopted ?? 0) > 1 }) else { return }
        read.groups = counts.mapValues { $0.adopted ?? 0 }
        for pair in pairs {
            let above = (read.groups[pair.label] ?? 0) > 1
            guard above || pair.label == V15StoredOrder.writerLabel else { continue }
            for (route, step) in [(V15Route.adopted, pair.adopted), (V15Route.mac, pair.mac)] {
                for entry in step?[above ? "outputs" : "inputs"] as? [[String: Any]] ?? [] {
                    let role = entry["role"] as? String ?? ""
                    let path = Self.stripRoot(entry["path"] as? String ?? "", roots: roots[route] ?? [], names: names[route] ?? V15RouteNames())
                    read.entries[route, default: []].insert(V15StoredOrder.entryKey(role: role, path: path))
                }
            }
        }
    }

    /// The `[role path]` name of an entry of the run's `files` or `outputs` that V15-30's S3 lists for `route`, or nil.
    private func storedOrderName(_ entry: [String: Any], _ route: V15Route) -> String? {
        let role = entry["role"] as? String ?? ""
        let path = Self.stripRoot(entry["path"] as? String ?? "", roots: roots[route] ?? [], names: names[route] ?? V15RouteNames())
        return storedOrder.entries[route]?.contains(V15StoredOrder.entryKey(role: role, path: path)) == true ? "[\(role) \(path)]" : nil
    }

    /// S3 for the run's `files` and `outputs`: an adopted entry and a Mac entry of one listed role and path, with different digests and
    /// an equal `fileSize`, print as PARITY-REPORTED and leave both lists, so `compareEntries` pairs the rest as before. They go first,
    /// since `compareEntries` reports a pair of one role and path with two digests as a finding (C4-4 D-2).
    mutating func setStoredOrderEntriesAside(adopted: inout [String: Any], mac: inout [String: Any]) {
        guard storedOrder.holds else { return }
        for list in ["files", "outputs"] {
            guard var a = adopted[list] as? [[String: Any]], var m = mac[list] as? [[String: Any]] else { continue }
            let adoptedNames = a.map { storedOrderName($0, .adopted) }, macNames = m.map { storedOrderName($0, .mac) }
            var taken = Set<Int>()
            var pairs: [(adopted: Int, mac: Int)] = []
            for ai in a.indices {
                guard let name = adoptedNames[ai], a[ai]["fileSize"] != nil else { continue }
                for mi in m.indices where !taken.contains(mi) && macNames[mi] == name {
                    guard a[ai]["checksumSHA256"] as? String != m[mi]["checksumSHA256"] as? String,
                          Self.equal(a[ai]["fileSize"], m[mi]["fileSize"]) else { continue }
                    taken.insert(mi)
                    pairs.append((ai, mi))
                    break
                }
            }
            for pair in pairs {
                reported.append("PARITY-REPORTED line=V15-30 key=\(Self.joined(["envelope", list, adoptedNames[pair.adopted] ?? ""])) "
                                + "adopted=\(Self.describe(a[pair.adopted])) mac=\(Self.describe(m[pair.mac]))")
            }
            for index in pairs.map(\.adopted).sorted(by: >) { a.remove(at: index) }
            for index in pairs.map(\.mac).sorted(by: >) { m.remove(at: index) }
            adopted[list] = a
            mac[list] = m
        }
    }
}
